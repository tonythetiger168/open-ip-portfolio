// SPDX-License-Identifier: Apache-2.0
// LIN-specific part of tb/LIN_apb_tb.sv. A second LIN_top (the peer, driven
// directly) shares the bus with the DUT: bus = txd & p_txd & line, where
// `line` is a bit-level driver for faulty headers and responses. Frames in
// all four role combinations (DUT or peer as commander, DUT publishing or
// subscribing), responses written ahead or after reading PID, ignored
// frames, every error kind, overflow of all four streams, auto-baud with the
// measured bit time in STATUS, every interrupt bit masked, enabled and
// cleared one by one.
logic line = 1;
logic p_rst = 0;
wire  p_txd;
wire  bus = txd & p_txd & line;
assign rxd = bus;

localparam int BT = 20;                     // clocks per bit (DUT CFG and peer)
task automatic bits(input int n); cycles(n * BT); endtask

logic        p_hdr_valid = 0;
logic [5:0]  p_hdr_id = 0;
logic        p_rsp_valid = 0, p_rsp_pub = 0, p_rsp_enh = 0;
logic [2:0]  p_rsp_len = 0;
logic [63:0] p_rsp_data = 0;
logic [15:0] p_cfg = 16'(BT);
wire         p_hdr_ready, p_pid_valid, p_rsp_ready, p_tx_done, p_rx_valid;
wire  [5:0]  p_pid_id, p_rx_id;
wire  [2:0]  p_rx_len;
wire  [63:0] p_rx_data;
wire  [5:0]  p_unused_err;
wire  [15:0] p_unused_bt;

LIN_top u_peer (
  .clk(PCLK), .rst_n(PRESETN & p_rst), .rxd(bus), .txd(p_txd),
  .cfg_bit(p_cfg), .cfg_autobaud(1'b0),
  .hdr_valid(p_hdr_valid), .hdr_ready(p_hdr_ready), .hdr_id(p_hdr_id),
  .pid_valid(p_pid_valid), .pid_id(p_pid_id), .rsp_ready(p_rsp_ready),
  .rsp_valid(p_rsp_valid), .rsp_pub(p_rsp_pub), .rsp_len(p_rsp_len), .rsp_enh(p_rsp_enh),
  .rsp_data(p_rsp_data), .tx_done(p_tx_done),
  .rx_valid(p_rx_valid), .rx_id(p_rx_id), .rx_len(p_rx_len), .rx_data(p_rx_data),
  .err_bit(p_unused_err[0]), .err_sync(p_unused_err[1]), .err_parity(p_unused_err[2]),
  .err_frame(p_unused_err[3]), .err_chk(p_unused_err[4]), .err_timeout(p_unused_err[5]),
  .bit_time(p_unused_bt));

function automatic logic [7:0] pid_of(input logic [5:0] id);
  return {~(id[1] ^ id[3] ^ id[4] ^ id[5]), id[0] ^ id[1] ^ id[2] ^ id[4], id};
endfunction
function automatic logic [7:0] csum(input logic [5:0] id, input logic enh, input logic [2:0] len,
                                    input logic [63:0] d);
  int s;
  s = (enh && id < 60) ? int'(pid_of(id)) : 0;
  for (int i = 0; i <= int'(len); i++) begin
    s = s + int'(d[8*i +: 8]);
    if (s > 255) s = s - 255;
  end
  return ~8'(s);
endfunction
function automatic logic [63:0] trim(input logic [2:0] len, input logic [63:0] d);
  for (int i = 0; i < 8; i++) if (i > int'(len)) d[8*i +: 8] = 8'h0;
  return d;
endfunction

// ---- peer host: role per frame (0 ignore, 1 publish, 2 subscribe)
int          p_role = 0, p_dly = 2;
logic [2:0]  p_len = 0;
logic        p_enh = 1;
logic [63:0] p_data = 0;
always @(negedge PCLK) if (p_pid_valid && p_role != 0) begin : peer_host
  repeat (p_dly) @(negedge PCLK);
  p_rsp_pub = p_role == 1; p_rsp_len = p_len; p_rsp_enh = p_enh; p_rsp_data = p_data;
  p_rsp_valid = 1;
  @(negedge PCLK) p_rsp_valid = 0;
end
int          p_rx_cnt = 0, p_tx_cnt = 0;
logic [5:0]  p_last_id;
logic [2:0]  p_last_len;
logic [63:0] p_last_data;
always @(negedge PCLK) begin
  if (p_rx_valid) begin p_rx_cnt++; p_last_id = p_rx_id; p_last_len = p_rx_len; p_last_data = p_rx_data; end
  if (p_tx_done) p_tx_cnt++;
end

// ---- peer header
task automatic p_header(input logic [5:0] id);
  @(negedge PCLK);
  p_hdr_id = id; p_hdr_valid = 1;
  @(posedge PCLK);
  while (!p_hdr_ready) @(posedge PCLK);
  @(negedge PCLK) p_hdr_valid = 0;
endtask

// ---- bit-level line driver
task automatic l_bits(input logic v, input int n); line = v; cycles(n * BT); endtask
task automatic l_byte(input logic [7:0] b, input logic stop = 1);
  l_bits(0, 1);
  for (int i = 0; i < 8; i++) l_bits(b[i], 1);
  l_bits(stop, 1);
  line = 1;
endtask
task automatic l_header(input logic [7:0] pid, input logic [7:0] sync = 8'h55, input logic stop = 1);
  l_bits(0, 13); l_bits(1, 1); l_byte(sync); l_byte(pid, stop);
endtask

// ---- DUT host through the registers
localparam logic [31:0] F_PID = 32'h1 << FLAG_PID_AVAIL;
localparam logic [31:0] F_RX  = 32'h1 << FLAG_RX_AVAIL;
localparam logic [31:0] F_RSP = 32'h1 << FLAG_RSP_FULL;
task automatic d_rsp(input logic pub, input logic [2:0] len, input logic enh, input logic [63:0] d);
  wr(A_RSP0, d[31:0]);
  wr(A_RSP1, d[63:32]);
  wr(A_RSP2, {27'h0, enh, pub, len});
endtask
task automatic pid_check(input logic [5:0] id);
  poll(A_FLAGS, F_PID, F_PID, 60 * BT);
  rd_exp(A_PID, {26'h0, id});                // pops
endtask
task automatic rx_check(input logic [5:0] id, input logic [2:0] len, input logic [63:0] d);
  logic [63:0] t;
  t = trim(len, d);
  poll(A_FLAGS, F_RX, F_RX, 200 * BT);
  rd_exp(A_RX0, t[31:0]);
  rd_exp(A_RX1, t[63:32]);
  rd_exp(A_RX2, {23'h0, len, id});           // pops
endtask
// wait until both nodes are idle and the bus has been quiet for 3 bits
task automatic settle;
  int q, g;
  q = 0; g = 0;
  while (q < 3 * BT && g < 300 * BT) begin
    @(negedge PCLK); g++;
    q = (bus && dut.u_core.fst == 0 && u_peer.fst == 0 && dut.u_core.tst == 0 && u_peer.tst == 0) ? q + 1 : 0;
  end
  if (g >= 300 * BT) fail("nodes not idle");
endtask
task automatic expect_irq(input logic [31:0] m, input string what);
  rd(A_IRQ_STATUS);
  if (rdv !== m) fail($sformatf("%s: IRQ_STATUS %h, expected %h", what, rdv, m));
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask

`define B(N) (32'h1 << IRQ_``N)

// DUT commander and publisher (response written ahead), peer subscribes
task automatic f_dut_pub(input logic [5:0] id, input logic [2:0] len, input logic enh, input logic [63:0] d);
  int c;
  c = p_rx_cnt;
  p_role = 2; p_dly = 0; p_len = len; p_enh = enh;
  d_rsp(1, len, enh, d);
  wr(A_HDR, {26'h0, id});
  pid_check(id);
  settle();
  if (p_rx_cnt != c + 1 || p_last_id !== id || p_last_len !== len || p_last_data !== trim(len, d))
    fail($sformatf("peer did not receive id %0d", id));
  expect_irq(`B(SENT) | `B(HDR_DONE) | `B(PID_AVAIL) | `B(RSP_DONE), "DUT publishes");
endtask
// peer commander and publisher, DUT subscribes after reading PID
task automatic f_peer_pub(input logic [5:0] id, input logic [2:0] len, input logic enh, input logic [63:0] d);
  p_role = 1; p_dly = 4 * BT; p_len = len; p_enh = enh; p_data = d;   // after the DUT decides
  p_header(id);
  pid_check(id);
  d_rsp(0, len, enh, 64'h0);
  rx_check(id, len, d);
  settle();
  expect_irq(`B(PID_AVAIL) | `B(RSP_DONE) | `B(RX_AVAIL), "DUT subscribes");
endtask
// peer commander, DUT publishes after reading PID
task automatic f_dut_late_pub(input logic [5:0] id, input logic [2:0] len, input logic [63:0] d);
  int c;
  c = p_rx_cnt;
  p_role = 2; p_dly = 0; p_len = len; p_enh = 1;
  p_header(id);
  pid_check(id);
  d_rsp(1, len, 1, d);
  settle();
  if (p_rx_cnt != c + 1 || p_last_data !== trim(len, d)) fail($sformatf("peer did not receive id %0d", id));
  expect_irq(`B(SENT) | `B(PID_AVAIL) | `B(RSP_DONE), "DUT publishes late");
endtask
// DUT commander and subscriber, peer publishes
task automatic f_dut_sub(input logic [5:0] id, input logic [2:0] len, input logic [63:0] d);
  p_role = 1; p_dly = 2 * BT; p_len = len; p_enh = 0; p_data = d;
  d_rsp(0, len, 0, 64'h0);
  wr(A_HDR, {26'h0, id});
  pid_check(id);
  rx_check(id, len, d);
  settle();
  expect_irq(`B(HDR_DONE) | `B(PID_AVAIL) | `B(RSP_DONE) | `B(RX_AVAIL), "DUT commander subscribes");
endtask

// IRQ_STATUS must read m; then every set bit alone: enable, pin, clear
task automatic walk(input logic [31:0] m);
  rd_exp(A_IRQ_STATUS, m);
  if (irq !== 0) fail("irq with all interrupts masked");
  for (int i = 0; i < 15; i++)
    if (m[i]) begin
      wr(A_IRQ_ENABLE, 32'h1 << i);
      if (irq !== 1) fail($sformatf("irq bit %0d does not reach the pin", i));
      wr(A_IRQ_STATUS, 32'h1 << i);
      if (irq !== 0) fail($sformatf("irq bit %0d not cleared", i));
    end
  wr(A_IRQ_ENABLE, 0);
  rd_exp(A_IRQ_STATUS, 0);
endtask

task automatic ip_func;
  logic [63:0] d;
  logic [2:0]  l;
  wr(A_CFG, BT);
  @(negedge PCLK) p_rst = 1;
  bits(4);
  rd_exp(A_RX2, 0);                          // empty: reset value, no pop
  rd_exp(A_PID, 0);

  // ---- frames in all role combinations, all interrupts masked
  f_dut_pub(6'h01, 7, 1, 64'h0807_0605_0403_0201);
  f_peer_pub(6'h02, 7, 1, 64'hFFFF_FFFF_FFFF_FFFF);
  f_dut_late_pub(6'h3C, 1, 64'hA55A);        // diagnostic ID: classic checksum
  f_dut_sub(6'h3F, 0, 64'h00);
  for (int i = 0; i < 12; i++) begin
    d = {$urandom, $urandom}; l = $urandom;
    case (i % 4)
      0: f_dut_pub($urandom, l, $urandom, d);
      1: f_peer_pub($urandom, l, $urandom, d);
      2: f_dut_late_pub($urandom, l, d);
      default: f_dut_sub($urandom, l, d);
    endcase
  end

  // ignored frame: nobody answers the DUT's header
  p_role = 0;
  wr(A_HDR, 6'h10); pid_check(6'h10); settle();
  expect_irq(`B(HDR_DONE) | `B(PID_AVAIL), "ignored");

  // ---- errors
  // timeout: DUT subscribes, nobody publishes
  p_role = 0;
  d_rsp(0, 3, 1, 0); wr(A_HDR, 6'h11); pid_check(6'h11);
  settle();
  walk(`B(ERR_TIMEOUT) | `B(HDR_DONE) | `B(PID_AVAIL) | `B(RSP_DONE));
  // checksum: peer publishes enhanced, DUT expects classic
  p_role = 1; p_dly = 4 * BT; p_len = 1; p_enh = 1; p_data = 64'h1234;
  p_header(6'h12); pid_check(6'h12); d_rsp(0, 1, 0, 0); settle();
  walk(`B(ERR_CHK) | `B(PID_AVAIL) | `B(RSP_DONE));
  // sync byte 0x54
  p_role = 0;
  l_header(pid_of(6'h13), 8'h54); settle();
  walk(`B(ERR_SYNC));
  // parity
  l_header(pid_of(6'h14) ^ 8'h80); settle();
  walk(`B(ERR_PARITY));
  // PID stop bit dominant
  l_header(pid_of(6'h15), 8'h55, 0); settle();
  walk(`B(ERR_FRAME));
  // bit error: the DUT's break delimiter forced dominant
  fork wr(A_HDR, 6'h16); begin bits(13); cycles(BT / 4); l_bits(0, 1); line = 1; end join
  settle();
  walk(`B(ERR_BIT) | `B(ERR_SYNC) | `B(HDR_DONE));

  // ---- overflows
  // HDR: the first is taken, the second waits, the third is dropped; the
  // two headers' PIDs arrive unread: the second PID is dropped
  p_role = 0;
  wr(A_HDR, 6'h20); wr(A_HDR, 6'h21); wr(A_HDR, 6'h22);
  rd_exp(A_FLAGS, 32'h1 << FLAG_HDR_FULL);
  settle(); bits(40); settle();
  walk(`B(HDR_DONE) | `B(HDR_OVF) | `B(PID_AVAIL) | `B(PID_OVF));
  rd_exp(A_PID, 6'h20);
  rd_exp(A_FLAGS, 0);
  // RSP written twice ahead: the second is dropped, the first answers the
  // next header
  d_rsp(1, 0, 1, 64'h77); d_rsp(1, 0, 1, 64'h88);
  rd_exp(A_FLAGS, F_RSP);
  p_role = 2; p_dly = 0; p_len = 0; p_enh = 1;
  p_header(6'h23); pid_check(6'h23); settle();
  if (p_last_data !== 64'h77) fail("RSP written ahead not used");
  walk(`B(SENT) | `B(PID_AVAIL) | `B(RSP_DONE) | `B(RSP_OVF));
  // RX: two subscribed frames, none read: the second is dropped
  p_role = 1; p_dly = 0; p_len = 0; p_enh = 1;
  p_data = 64'h31; d_rsp(0, 0, 1, 0); p_header(6'h24); settle();
  p_data = 64'h32; d_rsp(0, 0, 1, 0); p_header(6'h25); settle();
  walk(`B(PID_AVAIL) | `B(PID_OVF) | `B(RSP_DONE) | `B(RX_AVAIL) | `B(RX_OVF));
  rd(A_PID);
  rx_check(6'h24, 0, 64'h31);
  rd_exp(A_FLAGS, 0);

  // ---- pop PID in the very clock the next PID is captured
  p_role = 0;
  p_header(6'h2A); pid_check(6'h2A);
  p_header(6'h2B); poll(A_FLAGS, F_PID, F_PID, 60 * BT);
  wr(A_IRQ_STATUS, IRQ_ALL);
  p_header(6'h2C);
  while (!(dut.u_core.fst == 3 && dut.u_core.r_busy && dut.u_core.r_cnt == 0 && dut.u_core.r_k == 9))
    @(negedge PCLK);
  apb_now(0, A_PID, 0, 0);                   // access phase sees pid_valid
  if (rdv !== 32'h2B) fail("pop at capture: first PID");
  walk(`B(PID_AVAIL));
  rd_exp(A_PID, 6'h2C);
  settle();
  // same for RX
  p_role = 1; p_dly = 0; p_len = 0; p_enh = 1; p_data = 64'h41;
  d_rsp(0, 0, 1, 0); p_header(6'h2D); pid_check(6'h2D); settle();
  p_data = 64'h42; d_rsp(0, 0, 1, 0); p_header(6'h2E); pid_check(6'h2E);
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd_exp(A_RX0, 64'h41);
  while (!(dut.u_core.fst == 5 && dut.u_core.r_busy && dut.u_core.r_cnt == 0 && dut.u_core.r_k == 9
           && dut.u_core.r_idx == 1))
    @(negedge PCLK);
  apb_now(0, A_RX2, 0, 0);
  if (rdv !== 32'h2D) fail("pop at capture: first RX");
  walk(`B(RX_AVAIL));
  rx_check(6'h2E, 0, 64'h42);
  settle();

  // ---- the longest bit time: one header at 65535 clocks per bit, then a
  // header at the normal rate restarts both nodes
  p_role = 0;
  wr(A_CFG, 16'hFFFF); p_cfg = 16'hFFFF;
  p_header(6'h2F); poll(A_FLAGS, F_PID, F_PID, 1_000_000); rd_exp(A_PID, 6'h2F);
  rd_exp(A_STATUS, 16'hFFFF);
  wr(A_CFG, BT); p_cfg = 16'(BT);
  p_header(6'h30); pid_check(6'h30);
  rd_exp(A_STATUS, BT);
  settle();
  wr(A_IRQ_STATUS, IRQ_ALL);

  // ---- auto-baud: peer at 23 clocks per bit, DUT measures it
  wr(A_CFG, 32'h1_0000 | BT);
  p_cfg = 16'(BT + 3);
  f_peer_pub(6'h26, 2, 1, 64'hC0FFEE);
  rd_exp(A_STATUS, BT + 3);
  p_cfg = 16'(BT);
  wr(A_CFG, BT);
  // a header left pending: the final reset clears PID_AVAIL
  p_role = 0;
  p_header(6'h31); pid_check(6'h31);
endtask
