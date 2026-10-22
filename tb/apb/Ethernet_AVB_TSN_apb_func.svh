// SPDX-License-Identifier: Apache-2.0
// TSN-specific part of tb/Ethernet_AVB_TSN_apb_tb.sv. Four TB queues feed
// q_valid / q_len and are popped by q_pop; every selected frame is checked
// against its queue head (class, length) and its timestamp against the
// time read back through TIME. Covered through the registers: time set
// near the 64-bit wrap and back, positive and negative adjustments,
// fractional increments, strict priority, a gate control list written
// through GCL_WR and run from GCL_BASE (STATUS checked against the written
// gates, the CYCLE interrupt), the shapers through CBS_IDLE / CREDIT with
// both credit limits on every class, every interrupt bit masked, enabled
// and cleared one by one.
int fqb [0:3][0:255];
int fh [0:3], ft [0:3];
initial for (int c = 0; c < 4; c++) begin fh[c] = 0; ft[c] = 0; end
function automatic int fqn(input int c); return ft[c] - fh[c]; endfunction
function automatic int fqh(input int c); return fqb[c][fh[c] % 256]; endfunction
bit chk_prio = 0;
int n_sent = 0;
logic [63:0] last_ts = 0;
initial begin q_valid = 0; q_len = 0; end
task automatic upd;
  for (int c = 0; c < 4; c++) begin
    q_valid[c] = fqn(c) != 0;
    q_len[11*c +: 11] = fqn(c) != 0 ? 11'(fqh(c)) : 11'($urandom);
  end
endtask
task automatic enq(input int c, input int len); fqb[c][ft[c] % 256] = len; ft[c]++; endtask
logic [3:0] qv_q;
always @(posedge PCLK) qv_q <= q_valid;
always @(negedge PCLK) if (PRESETN && q_pop != 0) begin : b_pop
  int c;
  c = q_pop[3] ? 3 : q_pop[2] ? 2 : q_pop[1] ? 1 : 0;
  if (!$onehot(q_pop)) fail($sformatf("q_pop %b not one-hot", q_pop));
  if (tx_tc !== 2'(c)) fail($sformatf("tx_tc %0d, popped class %0d", tx_tc, c));
  if (fqn(c) == 0) fail($sformatf("class %0d popped while empty", c));
  else begin
    if (tx_len !== 11'(fqh(c))) fail($sformatf("class %0d length %0d, expected %0d", c, tx_len, fqh(c)));
    fh[c]++;
  end
  if (chk_prio) for (int h = c + 1; h < 4; h++)
    if (qv_q[h]) fail($sformatf("class %0d sent while class %0d waited", c, h));
  last_ts = tx_ts; n_sent++;
  upd();
end
task automatic drain(input int limit);
  int g;
  g = 0;
  while ((fqn(0) + fqn(1) + fqn(2) + fqn(3)) != 0 && g < limit) begin
    @(negedge PCLK); g++;
  end
  if (g >= limit) fail("queues not drained");
endtask
task automatic rd_time(output logic [63:0] t);
  logic [31:0] h;
  rd(A_TIME1); h = rdv;
  rd(A_TIME0); t[31:0] = rdv;
  rd(A_TIME1);
  if (rdv != h) begin h = rdv; rd(A_TIME0); t[31:0] = rdv; end
  t[63:32] = h;
endtask
task automatic set_time(input logic [63:0] t);
  wr(A_TIME_SET0, t[31:0]); wr(A_TIME_SET1, t[63:32]);
endtask

`define B(N) (32'h1 << IRQ_``N)
// IRQ_STATUS must read m; then every set bit alone: enable, pin, clear
task automatic irq_check(input logic [31:0] m, input string what);
  rd(A_IRQ_STATUS);
  if (rdv !== m) fail($sformatf("%s: IRQ_STATUS %h, expected %h", what, rdv, m));
  if (irq !== 0) fail("irq with all interrupts masked");
  for (int i = 0; i < 32; i++)
    if (m[i]) begin
      wr(A_IRQ_ENABLE, 32'h1 << i);
      if (irq !== 1) fail($sformatf("irq bit %0d does not reach the pin", i));
      wr(A_IRQ_STATUS, 32'h1 << i);
      if (irq !== 0) fail($sformatf("irq bit %0d not cleared", i));
    end
  wr(A_IRQ_ENABLE, 0);
  rd_exp(A_IRQ_STATUS, 0);
endtask

// credits of class c: one read of the 80-bit CREDIT field
task automatic credit(input int c, output logic signed [19:0] v);
  logic [95:0] all;
  rd(A_CREDIT0); all[31:0] = rdv;
  rd(A_CREDIT1); all[63:32] = rdv;
  rd(A_CREDIT2); all[95:64] = rdv;
  v = all[20*c +: 20];
endtask

// idle slope of class c (CBS_IDLE: 36 bits over two words)
logic [35:0] idle_v = 0;
task automatic set_idle(input int c, input int v);
  idle_v[9*c +: 9] = 9'(v);
  wr(A_CBS_IDLE0, idle_v[31:0]); wr(A_CBS_IDLE1, {28'd0, idle_v[35:32]});
endtask

task automatic ip_func;
  logic [63:0] t0, t1;
  logic signed [19:0] cr;
  upd();
  irq_check(0, "idle");
  // all gates open, not running, line idle (the entry is left wherever the
  // register tests' brief gcl_en = 1 stopped it)
  rd(A_STATUS);
  if ((rdv & 32'h1F1) !== 32'hF0) fail($sformatf("STATUS %h", rdv));

  // time: set, read back, wrap, adjust both ways, fractions
  rd_exp(A_FLAGS, 0);
  set_time(64'hFFFF_FFFF_FFF0_FFFF);
  rd_time(t0);
  if (t0 < 64'hFFFF_FFFF_FFF0_FFFF || t0 > 64'hFFFF_FFFF_FFF1_03FF) fail($sformatf("time after set %h", t0));
  for (int i = 0; i < 16; i++) begin             // frames with high timestamps
    enq($urandom % 4, $urandom_range(300, 0)); upd();
    drain(1000);
    if (last_ts[63:20] != 44'hFFF_FFFF_FFFF) fail($sformatf("timestamp %h", last_ts));
    cycles($urandom % 50);
  end
  poll(A_TIME1, 32'hFFFF_FFFF, 32'h0, 60000);      // wrapped
  for (int i = 0; i < 16; i++) begin             // and low ones
    enq($urandom % 4, $urandom_range(300, 0)); upd();
    drain(1000);
    if (last_ts[63:24] != 0) fail($sformatf("timestamp %h", last_ts));
    cycles($urandom % 50);
  end
  set_time(64'h0000_0001_000F_0000);
  rd_time(t0);
  wr(A_TIME_ADJ, 32'h8000_0000);                 // -2^31 ns
  rd_time(t1);
  if (t1 - t0 + 64'h8000_0000 > 64'd2000) fail($sformatf("negative adjustment: %h -> %h", t0, t1));
  wr(A_TIME_ADJ, 32'h7FFF_FFFF);
  rd_time(t0);
  if (t0 - t1 - 64'h7FFF_FFFF > 64'd2000) fail($sformatf("positive adjustment: %h -> %h", t1, t0));
  wr(A_CFG0, {4'h0, 3'h0, 1'b0, 16'h8000, 8'd8});   // 8.5 ns per clock
  rd_time(t0); cycles(1000); rd_time(t1);
  if (t1 - t0 < 64'd8500 || t1 - t0 > 64'd9500) fail($sformatf("8.5 ns increment: %0d ns in 1000+ clocks", t1 - t0));
  wr(A_CFG0, 32'h8);
  set_time(64'h0);

  // strict priority
  chk_prio = 1;
  for (int i = 0; i < 40; i++) begin
    enq($urandom % 4, $urandom_range(2047, 0));
    if (i % 5 == 4) upd();
  end
  upd(); drain(200_000);
  chk_prio = 0;
  irq_check(`B(TX), "frames sent");

  // gate control list: 4 entries, frames on all classes
  wr(A_GCL_WR, {1'b0, 3'd7, 4'hF, 24'hFF_FFFF});
  wr(A_GCL_WR, {1'b0, 3'd0, 4'h0, 24'h0});
  begin : b_gcl
    logic [3:0] gs [0:3];
    gs[0] = 4'b1000; gs[1] = 4'b0111; gs[2] = 4'b0101; gs[3] = 4'b1110;
    for (int k = 0; k < 4; k++) wr(A_GCL_WR, {1'b0, 3'(k), gs[k], 24'(4000 + 1000 * k)});
    wr(A_CFG1, 20000);
    rd_time(t0);
    wr(A_GCL_BASE0, 32'(t0 + 64'd3000)); wr(A_GCL_BASE1, 32'((t0 + 64'd3000) >> 32));
    wr(A_CFG0, {4'h0, 3'd3, 1'b1, 16'h0, 8'd8});
    poll(A_STATUS, 32'h1, 32'h1, 200);
    for (int i = 0; i < 60; i++) begin
      enq($urandom % 4, $urandom_range(300, 0)); upd();
      rd(A_STATUS);
      if (rdv[0] && rdv[7:4] !== gs[rdv[3:1]]) fail($sformatf("STATUS %h: gates of entry %0d are %b", rdv, rdv[3:1], gs[rdv[3:1]]));
      cycles($urandom % 200);
    end
    drain(200_000);
  end
  irq_check(`B(CYCLE) | `B(TX), "schedule");
  wr(A_CFG0, 32'h8);
  poll(A_STATUS, 32'h1F1, 32'hF0, 2000);         // stopped, gates open, line idle

  // shapers: each class saturates high (waiting behind a long frame of
  // another class) and low (a long frame at idle slope 1)
  for (int c = 0; c < 4; c++) begin
    wr(A_CFG0, {4'(1 << c), 3'd0, 1'b0, 16'h0, 8'd8});
    idle_v = 0;
    set_idle(c, 256);
    enq(c == 0 ? 1 : 0, 2047); upd();
    cycles(5);
    enq(c, 100); upd();
    cycles(2067);
    credit(c, cr);
    if (cr != 20'sh7FFFF) fail($sformatf("class %0d credit %h, expected the upper limit", c, cr));
    drain(10_000);
    cycles(200);                                 // line idle, queue empty: credit to 0
    set_idle(c, 1);
    enq(c, 2047); upd();
    cycles(2080);
    credit(c, cr);
    // saturated during the frame, recovering by 1 per clock since its end
    if (cr > -20'sd524288 + 20'sd64) fail($sformatf("class %0d credit %h, expected the lower limit", c, cr));
    set_idle(c, 256);
    drain(10_000);
    cycles(2100);
    credit(c, cr);
    if (cr != 0) fail($sformatf("class %0d credit %h, expected 0 after recovery", c, cr));
  end
  wr(A_CFG0, 32'h8);
  wr(A_CBS_IDLE0, 0); wr(A_CBS_IDLE1, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  if (n_sent < 100) fail($sformatf("only %0d frames sent", n_sent));
endtask

