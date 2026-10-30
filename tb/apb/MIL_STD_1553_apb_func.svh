// SPDX-License-Identifier: Apache-2.0
// MIL-STD-1553-specific part of tb/MIL_STD_1553_apb_tb.sv. Two bare cores share
// the dual buses with the DUT: P (bus controller, later RT 5) and Q (RT 26),
// plus a word BFM for responses no core gives (other status bits, word and
// word count errors). The DUT is first RT 5: BC-RT, RT-BC, RT-RT both ways,
// broadcast, every mode code, status bits, illegal commands and receive
// errors, with RT_MSG checked against the core's reports and the buffer read
// and written through MEM_ADDR / MEM_WDATA / CMD / MEM_RDATA. Then the DUT is
// the BC: every message type and every BC error. Every interrupt bit is
// masked, enabled and cleared one by one.
logic [7:0] half = 8;
logic f_a_p = 0, f_a_n = 0, f_b_p = 0, f_b_n = 0;
wire  pa_p, pa_n, pb_p, pb_n, qa_p, qa_n, qb_p, qb_n;
wire  bus_a_p = tx_a_p | pa_p | qa_p | f_a_p, bus_a_n = tx_a_n | pa_n | qa_n | f_a_n;
wire  bus_b_p = tx_b_p | pb_p | qb_p | f_b_p, bus_b_n = tx_b_n | pb_n | qb_n | f_b_n;
always @* begin rx_a_p = bus_a_p; rx_a_n = bus_a_n; rx_b_p = bus_b_p; rx_b_n = bus_b_n; end

// ---- partner P: BC (p_bc = 1) or RT p_addr
logic        p_bc = 1, p_start = 0, p_bus = 0;
logic [4:0]  p_addr = 5'd5;
logic [2:0]  p_type = 0;
logic [15:0] p_c1 = 0, p_c2 = 0;
logic        p_msg, p_busy, p_done, p_enr, p_ead, p_ewd, p_ewc;
logic [15:0] p_s1, p_s2, p_mcmd;
logic [5:0]  p_cnt;
MIL_STD_1553_top u_p (
  .clk(PCLK), .rst_n(PRESETN), .cfg_half(half), .cfg_bc(p_bc), .cfg_resp_timeout(8'd28),
  .tx_a_p(pa_p), .tx_a_n(pa_n), .tx_b_p(pb_p), .tx_b_n(pb_n),
  .rx_a_p(bus_a_p), .rx_a_n(bus_a_n), .rx_b_p(bus_b_p), .rx_b_n(bus_b_n),
  .host_rd(1'b0), .host_wr(1'b0), .host_addr(11'd0), .host_wdata(16'd0), .host_rdata(),
  .cfg_rt_addr(p_addr), .cfg_bcast_en(1'b1), .cfg_sr(1'b0), .cfg_busy(1'b0), .cfg_ssf(1'b0),
  .cfg_tf(1'b0), .cfg_vector(16'h0), .cfg_bit_word(16'h0),
  .rt_msg(p_msg), .rt_msg_cmd(p_mcmd), .rt_msg_bus(), .rt_msg_err(), .rt_msg_why(), .rt_msg_bcast(),
  .rt_msg_cnt(), .mc_sync(), .mc_selftest(), .mc_reset(), .mc_sync_data(), .mc_data(),
  .rt_tx_shut(), .rt_tf_inh(),
  .bc_start(p_start), .bc_type(p_type), .bc_bus(p_bus), .bc_cmd1(p_c1), .bc_cmd2(p_c2),
  .bc_busy(p_busy), .bc_done(p_done), .bc_err_noresp(p_enr), .bc_err_addr(p_ead), .bc_err_word(p_ewd),
  .bc_err_wc(p_ewc), .bc_stat1(p_s1), .bc_stat2(p_s2), .bc_cnt(p_cnt));
// ---- partner Q: RT 26 with settable status bits
logic        q_sr = 0, q_busy = 0, q_ssf = 0, q_tf = 0;
logic [4:0]  q_addr = 5'd26;
logic        q_msg;
MIL_STD_1553_top u_q (
  .clk(PCLK), .rst_n(PRESETN), .cfg_half(half), .cfg_bc(1'b0), .cfg_resp_timeout(8'd28),
  .tx_a_p(qa_p), .tx_a_n(qa_n), .tx_b_p(qb_p), .tx_b_n(qb_n),
  .rx_a_p(bus_a_p), .rx_a_n(bus_a_n), .rx_b_p(bus_b_p), .rx_b_n(bus_b_n),
  .host_rd(1'b0), .host_wr(1'b0), .host_addr(11'd0), .host_wdata(16'd0), .host_rdata(),
  .cfg_rt_addr(q_addr), .cfg_bcast_en(1'b1), .cfg_sr(q_sr), .cfg_busy(q_busy), .cfg_ssf(q_ssf),
  .cfg_tf(q_tf), .cfg_vector(16'h0), .cfg_bit_word(16'h0),
  .rt_msg(q_msg), .rt_msg_cmd(), .rt_msg_bus(), .rt_msg_err(), .rt_msg_why(), .rt_msg_bcast(),
  .rt_msg_cnt(), .mc_sync(), .mc_selftest(), .mc_reset(), .mc_sync_data(), .mc_data(),
  .rt_tx_shut(), .rt_tf_inh(),
  .bc_start(1'b0), .bc_type(3'd0), .bc_bus(1'b0), .bc_cmd1(16'd0), .bc_cmd2(16'd0),
  .bc_busy(), .bc_done(), .bc_err_noresp(), .bc_err_addr(), .bc_err_word(),
  .bc_err_wc(), .bc_stat1(), .bc_stat2(), .bc_cnt());

function automatic logic [15:0] cw(input int rt, input bit tr, input int sa, input int wc);
  return {5'(rt), tr, 5'(sa), 5'(wc)};
endfunction
function automatic logic [15:0] stw(input int rt, input bit me = 0, input bit sr = 0, input bit bcr = 0,
                                    input bit busy = 0, input bit ssf = 0, input bit tf = 0);
  return {5'(rt), me, 1'b0, sr, 3'b000, bcr, busy, ssf, 1'b0, tf};
endfunction

// ---- RT reports of the DUT core, in order; RT_MSG must give them back
logic [27:0] rq [$];
int n_rt = 0, n_bc = 0;
always @(negedge PCLK)
  if (dut.u_core.rt_msg)
    rq.push_back({dut.u_core.rt_msg_cnt, dut.u_core.rt_msg_bcast, dut.u_core.rt_msg_why,
                  dut.u_core.rt_msg_err, dut.u_core.rt_msg_bus, dut.u_core.rt_msg_cmd});

task automatic irq_bit(input int b, input string what);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ %s not set", what));
  wr(A_IRQ_ENABLE, 0);
  @(negedge PCLK); if (irq !== 0) fail($sformatf("irq with IRQ_ENABLE = 0 (%s)", what));
  wr(A_IRQ_ENABLE, 32'd1 << b);
  @(negedge PCLK); if (irq !== 1) fail($sformatf("irq not raised by %s", what));
  wr(A_IRQ_STATUS, 32'd1 << b);
  wr(A_IRQ_ENABLE, 0);
  rd(A_IRQ_STATUS); if (rdv[b]) fail($sformatf("IRQ %s not cleared", what));
endtask

// the next RT report; why / err / cnt checked when given (>= 0)
task automatic rt_take(input logic [15:0] cmd, input int why = -1, input int cnt = -1);
  logic [27:0] e;
  poll(A_FLAGS, 32'h1, 32'h1, 200);
  rd(A_RT_MSG);
  e = rq.size() ? rq.pop_front() : 28'hx;
  if (rdv !== {4'h0, e}) fail($sformatf("RT_MSG %h, expected %h", rdv, e));
  if (rdv[15:0] !== cmd) fail($sformatf("RT_MSG command %h, expected %h", rdv[15:0], cmd));
  if (why >= 0 && (rdv[20:18] !== 3'(why) || rdv[17] !== (why != 0)))
    fail($sformatf("RT_MSG %h: why %0d expected", rdv, why));
  if (cnt >= 0 && rdv[27:22] !== 6'(cnt)) fail($sformatf("RT_MSG %h: %0d words expected", rdv, cnt));
  n_rt++;
endtask
task automatic rt_none;
  rd(A_FLAGS);
  if (rdv[0] || rq.size()) fail("unexpected RT report");
endtask

// ---- message buffer through the registers
task automatic mem_wr(input logic [10:0] a, input logic [15:0] d);
  wr(A_MEM_ADDR, a); wr(A_MEM_WDATA, d); wr(A_CMD, 32'h2);
endtask
task automatic mem_rd(input logic [10:0] a);
  wr(A_MEM_ADDR, a); wr(A_CMD, 32'h4); rd(A_MEM_RDATA);
endtask
task automatic mem_exp(input logic [10:0] a, input logic [15:0] e, input string what);
  mem_rd(a);
  if (rdv !== {16'd0, e}) fail($sformatf("%s: MEM[%h] = %h, expected %h", what, a, rdv, e));
endtask

// ---- partner P as BC
task automatic p_run(input int ty, input bit bus, input logic [15:0] c1, input logic [15:0] c2 = 0);
  int k;
  @(negedge PCLK);
  p_type = 3'(ty); p_bus = bus; p_c1 = c1; p_c2 = c2; p_start = 1;
  @(negedge PCLK) p_start = 0;
  k = 0;
  while (!p_done && k < 200000) begin @(negedge PCLK); k++; end
  if (!p_done) fail("P: no bc_done");
  cycles(16 * half);
endtask
task automatic p_expect(input string what, input logic [3:0] err, input logic [15:0] s1,
                        input logic [15:0] s2 = 0, input int cnt = 0);
  if ({p_enr, p_ead, p_ewd, p_ewc} !== err) fail($sformatf("%s: P errors %b, expected %b", what, {p_enr, p_ead, p_ewd, p_ewc}, err));
  if (p_s1 !== s1) fail($sformatf("%s: P status 1 %h, expected %h", what, p_s1, s1));
  if (p_s2 !== s2) fail($sformatf("%s: P status 2 %h, expected %h", what, p_s2, s2));
  if (p_cnt !== 6'(cnt)) fail($sformatf("%s: P words %0d, expected %0d", what, p_cnt, cnt));
endtask

// ---- DUT as BC
task automatic d_go(input int ty, input bit bus, input logic [15:0] c1, input logic [15:0] c2 = 0);
  wr(A_BC_CMD, {c2, c1});
  wr(A_BC_CTRL, {28'd0, bus, 3'(ty)});
  wr(A_CMD, 32'h1);
endtask
task automatic d_wait;
  poll(A_IRQ_STATUS, 32'h1, 32'h1, 20000);
  wr(A_IRQ_STATUS, 32'h1);
  rd(A_BC_STATUS);
  if (rdv[0]) fail("BC_STATUS: busy after BC_DONE");
  n_bc++;
endtask
task automatic d_expect(input string what, input logic [3:0] err, input logic [15:0] s1,
                        input logic [15:0] s2 = 0, input int cnt = 0);
  rd_exp(A_BC_STATUS, {21'd0, 6'(cnt), err[0], err[1], err[2], err[3], 1'b0});
  rd_exp(A_BC_STAT, {s2, s1});
  if (errors) $display("  (%s)", what);
endtask
task automatic d_run(input string what, input int ty, input bit bus, input logic [15:0] c1,
                     input logic [15:0] c2, input logic [3:0] err, input logic [15:0] s1,
                     input logic [15:0] s2 = 0, input int cnt = 0);
  int e0;
  e0 = errors;
  d_go(ty, bus, c1, c2); d_wait();
  cycles(16 * half);
  rd_exp(A_BC_STATUS, {21'd0, 6'(cnt), err[0], err[1], err[2], err[3], 1'b0});
  rd_exp(A_BC_STAT, {s2, s1});
  if (errors != e0) $display("  in %s", what);
endtask

// ---- word BFM
logic f_lvl = 0, f_on = 0, f_bus = 0;
always @* begin
  f_a_p = f_on && !f_bus && f_lvl;  f_a_n = f_on && !f_bus && !f_lvl;
  f_b_p = f_on && f_bus && f_lvl;   f_b_n = f_on && f_bus && !f_lvl;
end
task automatic f_half(input int l);
  @(posedge PCLK); #1;
  f_on = l != 2; f_lvl = l == 1;
  for (int i = 0; i < half - 1; i++) @(posedge PCLK);
endtask
task automatic f_word(input bit bus, input bit cmd, input logic [15:0] d, input bit perr = 0);
  logic [16:0] w;
  w = {d, ~^d ^ perr};
  f_bus = bus;
  for (int i = 0; i < 3; i++) f_half(cmd);
  for (int i = 0; i < 3; i++) f_half(!cmd);
  for (int i = 0; i < 17; i++) begin f_half(w[16 - i]); f_half(!w[16 - i]); end
endtask
task automatic f_idle(input int halves);
  for (int i = 0; i < halves; i++) f_half(2);
endtask
// answer the DUT BC as an RT: status, then n data words (perr: the last one's parity)
task automatic f_rt(input bit bus, input logic [15:0] st, input int n, input bit perr = 0);
  @(negedge PCLK);
  while (!dut.u_core.e_act) @(negedge PCLK);
  while (dut.u_core.e_act) @(negedge PCLK);
  f_idle(6);
  f_word(bus, 1'b1, st, perr && n == 0);          // status: command sync
  for (int i = 0; i < n; i++) f_word(bus, 1'b0, 16'(i * 16'h1111 + 16'h0F0F), perr && i == n - 1);
  f_idle(2);
endtask

// answer an RT-RT transfer as the receiver: after Q's words, the status word
task automatic f_rx(input bit bus, input logic [15:0] st);
  @(negedge PCLK);
  while (!u_q.e_act) @(negedge PCLK);
  while (u_q.e_act) @(negedge PCLK);
  f_idle(6);
  f_word(bus, 1'b1, st);
  f_idle(2);
endtask

task automatic ip_func;
  logic [15:0] v [0:31];
  logic [15:0] c, c2;
  wr(A_TIMING, {16'd0, 8'd28, half});
  wr(A_CTRL, {21'd0, 4'b0000, 5'd5, 1'b1, 1'b0});          // RT 5
  wr(A_IRQ_STATUS, IRQ_ALL);
  cycles(100);

  // ================= DUT as RT 5, P as BC
  // BC-RT, 32 words, bus A
  for (int k = 0; k < 32; k++) begin v[k] = $urandom; u_p.ram[{1'b1, 5'd0, 5'(k)}] = v[k]; end
  c = cw(5, 0, 3, 0);
  p_run(0, 0, c); p_expect("BC-RT", 0, stw(5));
  rt_take(c, 0, 32);
  for (int k = 0; k < 32; k++) mem_exp({1'b0, 5'd3, 5'(k)}, v[k], "BC-RT");
  // RT-BC, 17 words, bus B; the words written through MEM_WDATA
  for (int k = 0; k < 17; k++) begin v[k] = $urandom; mem_wr({1'b1, 5'd7, 5'(k)}, v[k]); end
  c = cw(5, 1, 7, 17);
  p_run(1, 1, c); p_expect("RT-BC", 0, stw(5), 0, 17);
  rt_take(c, 0, 17);
  for (int k = 0; k < 17; k++)
    if (u_p.ram[{1'b0, 5'd0, 5'(k)}] !== v[k]) fail($sformatf("RT-BC word %0d", k));
  // all-ones / all-zeros words through the buffer
  mem_wr(11'h7FF, 16'hFFFF); mem_exp(11'h7FF, 16'hFFFF, "ones");
  mem_wr(11'h7FF, 16'h0000); mem_exp(11'h7FF, 16'h0000, "zeros");
  // status bits
  wr(A_CTRL, {21'd0, 4'b1111, 5'd5, 1'b1, 1'b0});
  c = cw(5, 0, 30, 2);
  p_run(0, 0, c); p_expect("busy BC-RT", 0, stw(5, 0, 1, 0, 1, 1, 1));
  rt_take(c, 0);
  wr(A_CTRL, {21'd0, 4'b0000, 5'd5, 1'b1, 1'b0});
  // RT-RT: Q transmits to the DUT, then the DUT to Q
  for (int k = 0; k < 9; k++) begin v[k] = $urandom; u_q.ram[{1'b1, 5'd9, 5'(k)}] = v[k]; end
  c = cw(5, 0, 9, 9); c2 = cw(26, 1, 9, 9);
  p_run(2, 1, c, c2); p_expect("RT-RT to DUT", 0, stw(26), stw(5), 9);
  rt_take(c, 0, 9);
  for (int k = 0; k < 9; k++) mem_exp({1'b0, 5'd9, 5'(k)}, v[k], "RT-RT to DUT");
  for (int k = 0; k < 5; k++) begin v[k] = $urandom; mem_wr({1'b1, 5'd4, 5'(k)}, v[k]); end
  c = cw(26, 0, 4, 5); c2 = cw(5, 1, 4, 5);
  p_run(2, 0, c, c2); p_expect("RT-RT from DUT", 0, stw(5), stw(26), 5);
  rt_take(c2, 0, 5);
  for (int k = 0; k < 5; k++)
    if (u_q.ram[{1'b0, 5'd4, 5'(k)}] !== v[k]) fail($sformatf("RT-RT from DUT word %0d", k));
  // RT-RT with no transmitter: the DUT flags it (why 4)
  c = cw(5, 0, 9, 3); c2 = cw(12, 1, 9, 3);
  p_run(2, 0, c, c2);
  rt_take(c, 4, 0);
  // broadcast BC-RT, then transmit status shows it
  for (int k = 0; k < 4; k++) begin v[k] = $urandom; u_p.ram[{1'b1, 5'd0, 5'(k)}] = v[k]; end
  c = cw(31, 0, 2, 4);
  p_run(0, 1, c);
  rt_take(c, 0, 4);
  rd(A_RT_MSG);                                           // nothing left: reads the old report
  for (int k = 0; k < 4; k++) mem_exp({1'b0, 5'd2, 5'(k)}, v[k], "broadcast");
  c = cw(5, 1, 0, 2);
  p_run(3, 0, c); p_expect("status after broadcast", 0, stw(5, 0, 0, 1));
  rt_take(c, 0, 0);
  // broadcast disabled: ignored
  wr(A_CTRL, {21'd0, 4'b0000, 5'd5, 1'b0, 1'b0});
  p_run(0, 0, cw(31, 0, 2, 4));
  rt_none();
  wr(A_CTRL, {21'd0, 4'b0000, 5'd5, 1'b1, 1'b0});

  // ---- mode codes
  wr(A_IRQ_STATUS, IRQ_ALL);
  c = cw(5, 1, 0, 1); p_run(3, 0, c); rt_take(c, 0); irq_bit(IRQ_SYNC, "SYNC");
  c = cw(5, 1, 31, 3); p_run(3, 1, c); rt_take(c, 0); irq_bit(IRQ_SELF_TEST, "SELF_TEST");
  c = cw(5, 1, 0, 8); p_run(3, 0, c); rt_take(c, 0); irq_bit(IRQ_RT_RESET, "RT_RESET");
  u_p.ram[{1'b1, 5'd0, 5'd0}] = 16'hFFFF;
  c = cw(5, 0, 0, 17); p_run(5, 0, c); rt_take(c, 0, 1); irq_bit(IRQ_SYNC_DATA, "SYNC_DATA");
  rd_exp(A_RT_STATUS, {13'd0, 16'hFFFF, 3'b000});
  u_p.ram[{1'b1, 5'd0, 5'd0}] = 16'h0000;
  c = cw(31, 0, 0, 17); p_run(5, 1, c); rt_take(c, 0, 1);
  rd_exp(A_RT_STATUS, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // transmitter shutdown / override, terminal flag inhibit / override
  c = cw(5, 1, 0, 4); p_run(3, 0, c); rt_take(c, 0);      // shuts bus B down
  rd_exp(A_RT_STATUS, 32'h2);
  c = cw(5, 1, 0, 4); p_run(3, 1, c); p_expect("shut down", 4'b1000, 0);
  rt_take(c, 0);                                          // received, no reply
  c = cw(5, 1, 0, 5); p_run(3, 0, c); rt_take(c, 0);
  c = cw(5, 1, 0, 4); p_run(3, 1, c); rt_take(c, 0);      // shuts bus A down
  rd_exp(A_RT_STATUS, 32'h1);
  c = cw(5, 1, 0, 5); p_run(3, 1, c); rt_take(c, 0);
  rd_exp(A_RT_STATUS, 0);
  wr(A_CTRL, {21'd0, 4'b1000, 5'd5, 1'b1, 1'b0});          // terminal flag
  c = cw(5, 1, 0, 6); p_run(3, 0, c); p_expect("inhibit", 0, stw(5));
  rt_take(c, 0);
  rd_exp(A_RT_STATUS, 32'h4);
  c = cw(5, 1, 0, 7); p_run(3, 0, c); p_expect("override", 0, stw(5, 0, 0, 0, 0, 0, 1));
  rt_take(c, 0);
  rd_exp(A_RT_STATUS, 0);
  wr(A_CTRL, {21'd0, 4'b0000, 5'd5, 1'b1, 1'b0});
  // vector, BIT word, last command, transmit status
  wr(A_WORDS, 32'h5A3C_C3A5);
  c = cw(5, 1, 0, 16); p_run(4, 0, c); p_expect("vector", 0, stw(5), 0, 1);
  if (u_p.ram[{1'b0, 5'd0, 5'd0}] !== 16'hC3A5) fail("vector word");
  rt_take(c, 0, 1);
  c = cw(5, 1, 0, 19); p_run(4, 1, c); p_expect("BIT word", 0, stw(5), 0, 1);
  if (u_p.ram[{1'b0, 5'd0, 5'd0}] !== 16'h5A3C) fail("BIT word");
  rt_take(c, 0, 1);
  c2 = c;
  c = cw(5, 1, 0, 18); p_run(4, 0, c); p_expect("last command", 0, stw(5), 0, 1);
  if (u_p.ram[{1'b0, 5'd0, 5'd0}] !== c2) fail("last command word");
  rt_take(c, 0, 1);
  c = cw(5, 1, 0, 2); p_run(3, 1, c); p_expect("transmit status", 0, stw(5));
  rt_take(c, 0);
  // illegal: mode code 0 and 20, message error in the status word
  c = cw(5, 1, 0, 0); p_run(3, 0, c); p_expect("illegal 0", 0, stw(5, 1));
  rt_take(c, 3);
  c = cw(5, 1, 31, 20); p_run(3, 0, c); p_expect("illegal 20", 0, stw(5, 1));
  rt_take(c, 3);

  // ---- receive errors from the BFM as BC
  f_word(0, 1, cw(5, 0, 6, 2)); f_word(0, 0, 16'h1234, 1); f_word(0, 0, 16'h5678); f_idle(30);
  rt_take(cw(5, 0, 6, 2), 1);
  f_word(1, 1, cw(5, 0, 6, 3)); f_word(1, 0, 16'h1234); f_word(1, 0, 16'h5678); f_idle(30);
  rt_take(cw(5, 0, 6, 3), 2, 2);
  // a report waiting; RT_MSG read on the clock the next one is captured
  c = cw(5, 1, 0, 2); p_run(3, 0, c);
  c2 = cw(5, 1, 0, 18);
  fork
    p_run(4, 1, c2);
    begin
      @(negedge PCLK);
      while (!(dut.u_core.rs == 3'd4 && !dut.u_core.e_act && dut.u_core.ti != 0 && !dut.u_core.e_load)) @(negedge PCLK);
      apb_now(0, A_RT_MSG, 0, 0);                            // the report is due on this clock
      if (rdv[15:0] !== c) fail($sformatf("RT_MSG %h popped with the next capture", rdv));
      void'(rq.pop_front());
    end
  join
  rt_take(c2, 0, 1);
  // report overflow: two messages, none read
  wr(A_IRQ_STATUS, IRQ_ALL);
  p_run(3, 0, cw(5, 1, 0, 1));
  p_run(3, 0, cw(5, 1, 0, 2));
  irq_bit(IRQ_RT_MSG_OVF, "RT_MSG_OVF");
  irq_bit(IRQ_RT_MSG_AVAIL, "RT_MSG_AVAIL");
  rt_take(cw(5, 1, 0, 1), 0);
  rq.delete();
  wr(A_IRQ_STATUS, IRQ_ALL);

  // ================= DUT as BC; P is RT 5, Q RT 26, the BFM RT 13
  p_bc = 0;
  wr(A_CTRL, {21'd0, 4'b0000, 5'd0, 1'b1, 1'b1});
  cycles(100);
  // BC-RT to Q, 32 words from the buffer, bus A
  for (int k = 0; k < 32; k++) begin v[k] = $urandom; mem_wr({1'b1, 5'd0, 5'(k)}, v[k]); end
  c = cw(26, 0, 11, 0);
  d_go(0, 0, c);
  poll(A_IRQ_STATUS, 32'h1, 32'h1, 20000);
  irq_bit(IRQ_BC_DONE, "BC_DONE");
  rd_exp(A_BC_STATUS, 0); rd_exp(A_BC_STAT, stw(26));
  for (int k = 0; k < 32; k++)
    if (u_q.ram[{1'b0, 5'd11, 5'(k)}] !== v[k]) fail($sformatf("DUT BC-RT word %0d", k));
  // RT-BC from Q, 32 words, bus B, read back through MEM_RDATA
  for (int k = 0; k < 32; k++) begin v[k] = $urandom; u_q.ram[{1'b1, 5'd12, 5'(k)}] = v[k]; end
  d_run("DUT RT-BC", 1, 1, cw(26, 1, 12, 0), 0, 0, stw(26), 0, 32);
  for (int k = 0; k < 32; k++) mem_exp({1'b0, 5'd0, 5'(k)}, v[k], "DUT RT-BC");
  // RT-RT: Q to P
  for (int k = 0; k < 6; k++) begin v[k] = $urandom; u_q.ram[{1'b1, 5'd8, 5'(k)}] = v[k]; end
  d_run("DUT RT-RT", 2, 0, cw(5, 0, 8, 6), cw(26, 1, 8, 6), 0, stw(26), stw(5), 6);
  for (int k = 0; k < 6; k++)
    if (u_p.ram[{1'b0, 5'd8, 5'(k)}] !== v[k]) fail($sformatf("DUT RT-RT word %0d", k));
  // RT-RT P to Q, then Q to the BFM as receiver (every status bit), then Q to P again
  for (int k = 0; k < 3; k++) begin v[k] = $urandom; u_p.ram[{1'b1, 5'd8, 5'(k)}] = v[k]; end
  d_run("DUT RT-RT P to Q", 2, 1, cw(26, 0, 8, 3), cw(5, 1, 8, 3), 0, stw(5), stw(26), 3);
  for (int k = 0; k < 3; k++)
    if (u_q.ram[{1'b0, 5'd8, 5'(k)}] !== v[k]) fail($sformatf("DUT RT-RT P to Q word %0d", k));
  fork d_go(2, 0, cw(13, 0, 8, 2), cw(26, 1, 8, 2)); f_rx(0, 16'h6FFF); join
  d_wait(); d_expect("BFM receiver", 0, stw(26), 16'h6FFF, 2);
  d_run("DUT RT-RT again", 2, 0, cw(5, 0, 8, 6), cw(26, 1, 8, 6), 0, stw(26), stw(5), 6);
  // Q's status bits, broadcast received, message error
  {q_sr, q_busy, q_ssf, q_tf} = 4'hF;
  d_run("Q status", 3, 1, cw(26, 1, 0, 2), 0, 0, stw(26, 0, 1, 0, 1, 1, 1));
  {q_sr, q_busy, q_ssf, q_tf} = 4'h0;
  d_run("DUT broadcast", 0, 0, cw(31, 0, 1, 2), 0, 0, 0);
  d_run("Q status bcast", 3, 0, cw(26, 1, 0, 2), 0, 0, stw(26, 0, 0, 1));
  d_run("Q illegal", 3, 0, cw(26, 1, 0, 0), 0, 0, stw(26, 1));
  // mode codes with a data word, both directions
  mem_wr({1'b1, 5'd0, 5'd0}, 16'h8421);
  d_run("DUT sync with data", 5, 1, cw(26, 0, 0, 17), 0, 0, stw(26));
  d_run("DUT last command", 4, 0, cw(26, 1, 0, 18), 0, 0, stw(26), 0, 1);
  mem_exp({1'b0, 5'd0, 5'd0}, cw(26, 0, 0, 17), "last command");
  // P (RT 5) on bus B
  d_run("DUT BC-RT to P", 0, 1, cw(5, 0, 1, 1), 0, 0, stw(5));
  // BFM as RT 13: the status bits Q never sets, then each BC error
  fork d_go(1, 0, cw(13, 1, 1, 4)); f_rt(0, 16'h6BF7, 4); join
  d_wait(); d_expect("BFM status", 0, 16'h6BF7, 0, 4);          // all but ME, busy (no data)
  for (int k = 0; k < 4; k++) mem_exp({1'b0, 5'd0, 5'(k)}, 16'(k * 16'h1111 + 16'h0F0F), "BFM words");
  fork d_go(1, 1, cw(13, 1, 1, 4)); f_rt(1, 16'h7000, 4); join
  d_wait(); d_expect("status address", 4'b0100, 16'h7000);
  fork d_go(1, 0, cw(13, 1, 1, 4)); f_rt(0, 16'h6800, 4, 1); join
  d_wait(); d_expect("word error", 4'b0010, 16'h6800, 0, 3);
  fork d_go(1, 0, cw(13, 1, 1, 4)); f_rt(0, 16'h6800, 2); join
  d_wait(); d_expect("word count", 4'b0001, 16'h6800, 0, 2);
  d_run("no response", 0, 0, cw(12, 0, 1, 1), 0, 4'b1000, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CTRL, 32'h2);
  if (rq.size()) fail($sformatf("%0d RT reports not read", rq.size()));
  $display("MIL_STD_1553_apb: %0d RT reports, %0d BC messages", n_rt, n_bc + 1);
endtask
