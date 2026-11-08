// SPDX-License-Identifier: Apache-2.0
// PTP-specific part of tb/PTP_apb_tb.sv. The clock is set, stepped, snapped
// and trimmed through the registers; pps, the target compare and an external
// event are checked against the time on the t_sec / t_ns pins. PTP event
// frames (layer 2, with their FCS) are driven on the RX and TX GMII streams
// and their timestamps read from RXTS / TXTS (the expected value is the pin
// time of the SFD clock -/+ the latency), with times that set and clear every
// bit, the FIFOs filled to an overflow, transports disabled, and every
// interrupt bit masked, enabled and cleared one by one.
localparam logic [31:0] GIGA_NS = 32'd1_000_000_000;

initial begin ext_evt = 0; rx_dv = 0; rx_er = 0; rxd = 0; tx_en = 0; tx_er = 0; txd = 0; end

// pin time at the clock the core acts on a command / input
logic [47:0] ck_sec;
logic [29:0] ck_ns;
always @(posedge PCLK) if (dut.u_core.snap) begin ck_sec = t_sec; ck_ns = t_ns; end

task automatic cmd(input int b);
  wr(A_CMD, 32'd1 << b);
endtask
task automatic set_time(input logic [47:0] s, input logic [29:0] n);
  wr(A_SET0, s[31:0]); wr(A_SET1, {16'd0, s[47:32]}); wr(A_SET2, {2'b0, n});
  cmd(0);
  cycles(2);                                              // CMD pulses the clock after the write
  if (t_sec !== s || t_ns > n + 30'd24) fail($sformatf("time_set: %0d.%09d", t_sec, t_ns));
endtask
task automatic snap_check;
  cmd(2);
  rd(A_SNAP0); if (rdv !== ck_sec[31:0]) fail("SNAP0");
  rd(A_SNAP1); if (rdv !== {16'd0, ck_sec[47:32]}) fail("SNAP1");
  rd(A_SNAP2); if (rdv !== {2'b0, ck_ns}) fail("SNAP2");
endtask
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

// ---------------- GMII frames ----------------
logic [7:0] gb [0:127];
int         gn;
function automatic logic [31:0] g_crc8(input logic [31:0] c, input logic [7:0] b);
  logic [31:0] x;
  x = c ^ {24'd0, b};
  for (int i = 0; i < 8; i++) x = {1'b0, x[31:1]} ^ (x[0] ? 32'hEDB8_8320 : 32'h0);
  return x;
endfunction
// layer-2 PTP event message (64 bytes with the FCS)
task automatic g_build(input logic [3:0] mt, input logic [7:0] dom, input logic [15:0] seq);
  logic [31:0] c;
  gn = 0;
  for (int i = 0; i < 6; i++) begin gb[gn] = i == 0 ? 8'h01 : i == 1 ? 8'h1B : i == 2 ? 8'h19 : 8'h00; gn++; end
  for (int i = 0; i < 6; i++) begin gb[gn] = 8'($urandom) & 8'hFE; gn++; end
  gb[gn] = 8'h88; gb[gn + 1] = 8'hF7; gn += 2;
  for (int i = 0; i < 44; i++) begin
    gb[gn] = i == 0 ? {4'h0, mt} : i == 1 ? 8'h02 : i == 4 ? dom : i == 30 ? seq[15:8] : i == 31 ? seq[7:0] : 8'($urandom);
    gn++;
  end
  while (gn < 60) begin gb[gn] = 8'h00; gn++; end
  c = 32'hFFFF_FFFF;
  for (int i = 0; i < gn; i++) c = g_crc8(c, gb[i]);
  c = ~c;
  for (int i = 0; i < 4; i++) begin gb[gn] = c[8 * i +: 8]; gn++; end
endtask
int g_er = -1;                         // byte index driven with er = 1
// drive the frame on stream s (0 RX, 1 TX); es / en: pin time of the SFD clock
task automatic g_send(input int s, output logic [47:0] es, output logic [29:0] en);
  @(negedge PCLK);
  for (int i = 0; i < 8; i++) begin
    if (s == 0) begin rx_dv = 1; rxd = i == 7 ? 8'hD5 : 8'h55; end else begin tx_en = 1; txd = i == 7 ? 8'hD5 : 8'h55; end
    if (i == 7) begin es = t_sec; en = t_ns; end
    @(negedge PCLK);
  end
  for (int i = 0; i < gn; i++) begin
    if (s == 0) begin rxd = gb[i]; rx_er = i == g_er; end else begin txd = gb[i]; tx_er = i == g_er; end
    @(negedge PCLK);
  end
  rx_dv = 0; tx_en = 0; rx_er = 0; tx_er = 0;
  cycles(3);
endtask
// expected entry for a frame on stream s with SFD time es.en
function automatic logic [127:0] g_exp(input int s, input logic [3:0] mt, input logic [7:0] dom,
                                       input logic [15:0] seq, input logic [47:0] es, input logic [29:0] en,
                                       input logic [15:0] lat);
  logic [31:0] n;
  logic [47:0] sc;
  n = {2'b0, en}; sc = es;
  if (s == 0) begin
    if (n < {16'd0, lat}) begin n = n + GIGA_NS - lat; sc = sc - 1; end else n = n - lat;
  end else begin
    n = n + lat;
    if (n >= GIGA_NS) begin n = n - GIGA_NS; sc = sc + 1; end
  end
  return {4'd0, seq, dom, mt, sc[31:0], 16'd0, sc[47:32], n};
endfunction
// read one timestamp of stream s and compare it
task automatic ts_read(input int s, input logic [127:0] e, input string what);
  logic [11:0] a;
  a = s == 0 ? A_RXTS0 : A_TXTS0;
  poll(A_FLAGS, 32'd1 << s, 32'd1 << s, 50);
  for (int w = 0; w < 4; w++) begin
    rd(a + 12'(4 * w));
    if (rdv !== e[32 * (3 - w) +: 32]) fail($sformatf("%s: %s%0d = %h, expected %h", what, s == 0 ? "RXTS" : "TXTS", w, rdv, e[32 * (3 - w) +: 32]));
  end
endtask

task automatic ip_func;
  logic [47:0] es;
  logic [29:0] en;
  logic [127:0] q [0:1][0:7];
  logic [15:0] rl, tl;

  // 1. clock: set, snap, step both ways, rate trim
  wr(A_INC, 8); wr(A_INC_FRAC, 32'h8000_0000);
  set_time(48'h1234_5678_9ABC, 30'd5000);
  snap_check();
  wr(A_STEP, 32'd1000); cmd(1);
  snap_check();
  wr(A_STEP, -32'sd2000); cmd(1);
  snap_check();
  wr(A_INC_FRAC, 0);
  set_time(48'd7, 30'd999_999_000);                       // the second carries: SEC_TICK
  cycles(140);
  if (t_sec !== 48'd8) fail("seconds did not carry");
  irq_bit(IRQ_SEC_TICK, "SEC_TICK");

  // 2. pps: high while ns < width
  wr(A_PPS, {1'b0, 30'd4000, 1'b1});
  set_time(48'd9, 30'd0);
  @(negedge PCLK); if (pps !== 1) fail("pps low at the start of the second");
  while (t_ns < 30'd4100) @(negedge PCLK);
  if (pps !== 0) fail("pps high after the width");
  wr(A_PPS, 0);

  // 3. target: in the future, disarmed, in the past
  set_time(48'd20, 30'd1000);
  wr(A_TARGET0, 20); wr(A_TARGET1, 0); wr(A_TARGET2, 3000);
  cmd(3);
  rd_exp(A_STATUS, 1);
  while (target_hit !== 1 && t_ns < 30'd5000) @(negedge PCLK);
  if (target_hit !== 1 || t_ns < 30'd3000) fail("target_hit");
  rd_exp(A_STATUS, 0);
  irq_bit(IRQ_TARGET, "TARGET");
  wr(A_TARGET2, 30'd900_000_000); cmd(3); rd_exp(A_STATUS, 1);
  cmd(4); rd_exp(A_STATUS, 0);
  wr(A_TARGET0, 0); cmd(3); cycles(3); rd_exp(A_STATUS, 0);  // in the past: hits at once
  wr(A_IRQ_STATUS, IRQ_ALL);

  // 4. external event
  set_time(48'd30, 30'd0);
  #3 ext_evt = 1;
  cycles(4);
  ext_evt = 0;
  rd(A_EVT0); if (rdv !== 30) fail("EVT0");
  rd(A_EVT1); if (rdv !== 0) fail("EVT1");
  rd(A_EVT2); if (rdv > 64 || rdv < 8) fail($sformatf("EVT2 = %0d", rdv));
  irq_bit(IRQ_EVENT, "EVENT");

  // 5. timestamps, snapshots and events with every bit of the time set, then
  // cleared; latencies that borrow (RX) and carry (TX) a second
  for (int r = 0; r < 4; r++) begin
    logic [7:0] dom;
    logic [15:0] seq;
    case (r)
      0: begin rl = 16'hFFFF; tl = 16'h0001; dom = 8'hFF; seq = 16'hFFFF; set_time(48'hFFFF_FFFF_FFFE, 30'h3B9A_C000); end
      1: begin rl = 16'h0000; tl = 16'h0000; dom = 8'h00; seq = 16'h0000; set_time(48'd1, 30'h1FFF_F000); end
      2: begin rl = 16'h7FFE; tl = 16'hFFFF; dom = 8'h5A; seq = 16'hA5A5; set_time(48'd2, 30'd5); end
      default: begin rl = 16'h0001; tl = 16'h8001; dom = 8'hA5; seq = 16'h5A5A; set_time(48'd3, 30'd999_990_000); end
    endcase
    wr(A_LAT, {tl, rl});
    snap_check();
    #3 ext_evt = 1;
    cycles(4);
    ext_evt = 0;
    rd(A_EVT0); rd(A_EVT1); rd(A_EVT2);
    for (int s = 0; s < 2; s++) begin
      g_build(4'(r), dom, seq);
      g_send(s, es, en);
      q[s][0] = g_exp(s, gb[14][3:0], gb[18], {gb[44], gb[45]}, es, en, s == 0 ? rl : tl);
      ts_read(s, q[s][0], $sformatf("timestamp %0d", r));
    end
  end
  rl = 0; tl = 0; wr(A_LAT, 0);
  for (int r = 0; r < 12; r++) begin                      // random times: the low bits
    set_time(48'(r), 30'($urandom_range(0, 999_000_000)));
    snap_check();
    #3 ext_evt = 1;
    cycles(3 + r % 2);
    ext_evt = 0;
    rd(A_EVT2);
    g_build(4'(r % 4), 8'($urandom), 16'($urandom));
    g_send(r % 2, es, en);
    ts_read(r % 2, g_exp(r % 2, gb[14][3:0], gb[18], {gb[44], gb[45]}, es, en, 0), "random time");
  end
  irq_bit(IRQ_RXTS_AVAIL, "RXTS_AVAIL");
  irq_bit(IRQ_TXTS_AVAIL, "TXTS_AVAIL");

  // 6. fill: the wrapper register plus the core FIFO, then one more overflows
  set_time(48'd40, 30'd0);
  for (int s = 0; s < 2; s++) begin
    for (int i = 0; i < 6; i++) begin
      g_build(4'(i % 4), 8'(i), 16'(100 + i));
      g_send(s, es, en);
      if (i < 5) q[s][i] = g_exp(s, gb[14][3:0], gb[18], {gb[44], gb[45]}, es, en, s == 0 ? rl : tl);
    end
    rd(A_FLAGS); if (!rdv[s]) fail("FLAGS: no timestamp waiting");
    irq_bit(s == 0 ? IRQ_RX_OVF : IRQ_TX_OVF, s == 0 ? "RX_OVF" : "TX_OVF");
    for (int i = 0; i < 5; i++) ts_read(s, q[s][i], $sformatf("FIFO entry %0d", i));
    rd(A_FLAGS); if (rdv[s]) fail("FLAGS: still a timestamp after the drain");
    rd(s == 0 ? A_RXTS3 : A_TXTS3);                       // the popping read, while empty
    rd(A_FLAGS); if (rdv[s]) fail("FLAGS: a timestamp after reading the empty register");
  end

  // 7. transports disabled, an errored byte: no timestamp
  wr(A_TSU_CFG, 32'h6);
  g_build(0, 0, 0);
  g_send(0, es, en); g_send(1, es, en);
  cycles(5);
  rd(A_FLAGS); if (rdv[1:0] !== 0) fail("timestamp with layer 2 disabled");
  wr(A_TSU_CFG, 32'h7);
  g_er = 20;
  g_send(0, es, en); g_send(1, es, en);
  g_er = -1;
  cycles(5);
  rd(A_FLAGS); if (rdv[1:0] !== 0) fail("timestamp of a frame with an er byte");
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask
