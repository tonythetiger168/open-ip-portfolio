// SPDX-License-Identifier: Apache-2.0
// FlexRay-specific part of tb/FlexRay_apb_tb.sv. A second FlexRay_top (the
// peer, driven directly, coldstart node in slot 1) shares the channel with
// the DUT: bus = DUT & peer & line, where `line` is a bit-level frame driver
// (BFM) for frames in free slots, long frames and faults. Covered: DUT
// integration on the peer's sync frames, payloads both ways through TX and
// RX (null frames, all-ones / all-zeros data, 64 cycles for every cycle
// count), frames up to 64 words, slots up to 63, every error kind, sync
// loss, the DUT as time master, TX and RX overflow, RX popped in the very
// clock the next frame is captured, every interrupt bit masked, enabled and
// cleared one by one.
logic line = 1;
logic p_rst = 0;
wire  p_txd, p_en;
wire  bus = (tx_en ? txd : 1'b1) & (p_en ? p_txd : 1'b1) & line;
assign rxd = bus;

// cluster configuration, mirrored into the DUT's CFG0 / CFG1
logic [3:0] k_spc = 0, k_tss = 5;
logic [9:0] k_slot = 400, k_nit = 1000;
logic [5:0] k_ap = 4, k_nslots = 3;
logic [7:0] k_corr = 64;
logic       k_chan_b = 0;
logic [3:0] d_plen = 8, p_plen = 8;
logic [5:0] d_my = 2, p_my = 1;
logic       d_sync = 0, d_cold = 0, p_sync = 1, p_cold = 1;
function automatic int bt();                // clocks per bit
  return 8 * (int'(k_spc) + 1);
endfunction

logic         p_tx_valid = 0;
logic [127:0] p_tx_data = 0;
wire          p_tx_ready, p_tx_done, p_rx_valid, p_rx_null, p_rx_sync, p_rx_startup, p_synced;
wire          p_cycle_start;
wire  [5:0]   p_rx_id, p_rx_cycle, p_cycle, p_slot;
wire  [6:0]   p_rx_len;
wire  [127:0] p_rx_data;
wire  [4:0]   p_err;

FlexRay_top u_peer (
  .clk(PCLK), .rst_n(PRESETN & p_rst), .rxd(bus), .txd(p_txd), .tx_en(p_en),
  .cfg_spc(k_spc), .cfg_tss(k_tss), .cfg_slot(k_slot), .cfg_ap(k_ap), .cfg_nslots(k_nslots),
  .cfg_nit(k_nit), .cfg_plen(p_plen), .cfg_my_slot(p_my), .cfg_sync(p_sync), .cfg_cold(p_cold),
  .cfg_chan_b(k_chan_b), .cfg_corr(k_corr),
  .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_data(p_tx_data), .tx_done(p_tx_done),
  .rx_valid(p_rx_valid), .rx_id(p_rx_id), .rx_cycle(p_rx_cycle), .rx_len(p_rx_len),
  .rx_null(p_rx_null), .rx_sync(p_rx_sync), .rx_startup(p_rx_startup), .rx_data(p_rx_data),
  .synced(p_synced), .cycle(p_cycle), .slot(p_slot), .cycle_start(p_cycle_start),
  .err_coding(p_err[0]), .err_hcrc(p_err[1]), .err_fcrc(p_err[2]), .err_slot(p_err[3]),
  .err_sync(p_err[4]));

// ---- peer host and monitor
task automatic p_queue(input logic [127:0] d);
  @(negedge PCLK);
  p_tx_data = d; p_tx_valid = 1;
  @(posedge PCLK);
  while (!p_tx_ready) @(posedge PCLK);
  @(negedge PCLK) p_tx_valid = 0;
endtask
int           p_rx_cnt = 0, p_data_cnt = 0, p_err_cnt = 0;
logic [127:0] p_last_data;
logic [5:0]   p_last_cyc;
logic         p_last_startup;
logic [5:0]   p_tx_cyc;                     // cycle count of the peer's last frame
logic         p_en_q = 0;
always @(negedge PCLK) begin
  if (p_rx_valid) begin
    p_rx_cnt++;
    if (!p_rx_null) begin p_data_cnt++; p_last_data = p_rx_data; end
    p_last_cyc = p_rx_cycle; p_last_startup = p_rx_startup;
  end
  if (|p_err) p_err_cnt++;
  if (p_en && !p_en_q) p_tx_cyc = p_cycle;
  p_en_q = p_en;
end

// ---- protocol helpers (independent of the RTL)
function automatic logic [10:0] hcrc(input logic sy, input logic st, input logic [10:0] id,
                                     input logic [6:0] len);
  logic [19:0] d;
  logic [10:0] c;
  logic        fb;
  d = {sy, st, id, len};
  c = 11'h01A;
  for (int i = 19; i >= 0; i--) begin
    fb = d[i] ^ c[10];
    c  = {c[9:0], 1'b0};
    if (fb) c = c ^ 11'h385;
  end
  return c;
endfunction
function automatic logic [23:0] fcrc_bit(input logic [23:0] c, input logic b);
  logic fb;
  fb = b ^ c[23];
  c  = {c[22:0], 1'b0};
  if (fb) c = c ^ 24'h5D6DCB;
  return c;
endfunction
function automatic logic [127:0] trim(input int words, input logic [127:0] d);
  for (int i = 0; i < 16; i++) if (i >= 2 * words) d[8*i +: 8] = 8'h0;
  return d;
endfunction

// ---- BFM: one frame in slot sl at the peer's action point; data byte i =
// seed + i; faults: hc / fc flip a CRC bit, bss_at = byte with a LOW BSS
logic [7:0] b_seed;
task automatic bfm_frame(input int sl, input logic [10:0] id, input int len,
                         input bit hc = 0, input bit fc = 0, input int bss_at = -1);
  bit          bits [0:4095];
  int          nb;
  logic [39:0] h;
  logic [23:0] c;
  logic [7:0]  b;
  @(negedge PCLK);
  while (p_slot != 6'(sl - 1)) @(negedge PCLK);
  h = {1'b0, 1'b0, 1'b1, 1'b0, 1'b0, id, 7'(len), hcrc(0, 0, id, 7'(len)) ^ {10'd0, hc}, p_cycle};
  nb = 0;
  for (int i = 0; i < int'(k_tss); i++) begin bits[nb] = 0; nb++; end
  bits[nb] = 1; nb++;
  c = k_chan_b ? 24'hABCDEF : 24'hFEDCBA;
  for (int i = 0; i < 5 + 2 * len + 3; i++) begin
    if (i < 5) b = h[39 - 8 * i -: 8];
    else if (i < 5 + 2 * len) b = b_seed + 8'(i - 5);
    else begin
      if (i == 5 + 2 * len) c = c ^ {23'd0, fc};
      b = c[23 - 8 * (i - 5 - 2 * len) -: 8];
    end
    bits[nb] = (i == bss_at) ? 1'b0 : 1'b1; nb++;
    bits[nb] = 0; nb++;
    for (int j = 7; j >= 0; j--) begin
      bits[nb] = b[j]; nb++;
      if (i < 5 + 2 * len) c = fcrc_bit(c, b[j]);
    end
  end
  bits[nb] = 0; nb++;
  bits[nb] = 1; nb++;
  while (!(p_slot == 6'(sl) && u_peer.sc == 17'(int'(k_ap) * bt()))) @(negedge PCLK);
  for (int i = 0; i < nb; i++) begin line = bits[i]; cycles(bt()); end
  line = 1;
endtask
function automatic logic [127:0] bfm_data(input int len);
  logic [127:0] d;
  for (int i = 0; i < 16; i++) d[8*i +: 8] = b_seed + 8'(i);
  return trim(len, d);
endfunction

// ---- DUT host through the registers
localparam logic [31:0] F_TX = 32'h1 << FLAG_TX_FULL;
localparam logic [31:0] F_RX = 32'h1 << FLAG_RX_AVAIL;
`define B(N) (32'h1 << IRQ_``N)
localparam logic [31:0] NOISE = `B(CYCLE) | `B(RX_AVAIL) | `B(RX_OVF);   // from the running cluster

task automatic set_cfg;
  wr(A_CFG0, {2'b0, k_nslots, k_ap, k_slot, k_tss, k_spc});
  wr(A_CFG1, {1'b0, k_corr, k_chan_b, d_cold, d_sync, d_my, d_plen, k_nit});
endtask
task automatic d_tx(input logic [127:0] d);
  wr(A_TX0, d[31:0]); wr(A_TX1, d[63:32]); wr(A_TX2, d[95:64]); wr(A_TX3, d[127:96]);
endtask
// wait for a frame in RX and check it field by field (pops)
// cyc < 0: the cycle count of the peer's last frame
task automatic rx_check(input logic [5:0] id, input int cyc, input logic [6:0] len,
                        input logic nul, input logic sy, input logic st, input logic [127:0] d,
                        input string what);
  poll(A_FLAGS, F_RX, F_RX, 100_000);
  if (cyc < 0) cyc = int'(p_tx_cyc);
  rd(A_RX0); if (rdv !== d[31:0])   fail($sformatf("%s: RX0 %h, expected %h", what, rdv, d[31:0]));
  rd(A_RX1); if (rdv !== d[63:32])  fail($sformatf("%s: RX1 %h, expected %h", what, rdv, d[63:32]));
  rd(A_RX2); if (rdv !== d[95:64])  fail($sformatf("%s: RX2 %h, expected %h", what, rdv, d[95:64]));
  rd(A_RX3); if (rdv !== d[127:96]) fail($sformatf("%s: RX3 %h, expected %h", what, rdv, d[127:96]));
  rd_exp(A_RX4, {10'h0, st, sy, nul, len, 6'(cyc), id});
endtask
// IRQ_STATUS must read m outside the bits in `ign`; then clear all
task automatic expect_irq(input logic [31:0] m, input logic [31:0] ign, input string what);
  rd(A_IRQ_STATUS);
  if ((rdv & ~ign) !== (m & ~ign)) fail($sformatf("%s: IRQ_STATUS %h, expected %h", what, rdv & ~ign, m & ~ign));
  walk();
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask
// every set bit alone: enable, pin, clear
task automatic walk;
  logic [31:0] m;
  rd(A_IRQ_STATUS); m = rdv;
  if (irq !== 0) fail("irq with all interrupts masked");
  for (int i = 0; i < 11; i++)
    if (m[i]) begin
      wr(A_IRQ_ENABLE, 32'h1 << i);
      if (irq !== 1) fail($sformatf("irq bit %0d does not reach the pin", i));
      wr(A_IRQ_STATUS, 32'h1 << i);
      wr(A_IRQ_ENABLE, 0);
      rd(A_IRQ_STATUS);
      if (rdv[i] && !NOISE[i]) fail($sformatf("irq bit %0d not cleared", i));
    end
endtask
task automatic at_cycle_start;
  @(negedge PCLK);
  while (!p_cycle_start) @(negedge PCLK);
endtask
task automatic in_slot(input int sl);
  @(negedge PCLK);
  while (p_slot != 6'(sl)) @(negedge PCLK);
endtask
// drop everything in RX, clear all interrupts
task automatic flush;
  rd(A_RX4);
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask

task automatic ip_func;
  logic [127:0] d, e;
  logic [31:0]  seen;
  int           c;
  // ---- configuration 1: 3 slots of 400 bits, NIT 1000 (room for long
  // frames in slot 3); peer = time master in slot 1, DUT in slot 2
  set_cfg();
  @(negedge PCLK) p_rst = 1;
  rd_exp(A_RX4, 0);                          // empty: reset value, no pop
  c = 0;
  do begin at_cycle_start(); cycles(bt()); rd(A_STATUS); c++; end
  while (!(rdv[0] && rdv[6:1] == p_cycle && rdv[12:7] == p_slot) && c < 8);
  if (c >= 8) fail("DUT does not integrate");
  in_slot(3); flush();

  // ---- payloads both ways for 66 cycles: every cycle count; the peer
  // alternates data and null frames, the DUT sends every second cycle
  seen = 0;
  for (int i = 0; i < 66; i++) begin
    case (i % 4)
      0: d = {128{1'b1}};
      1: d = 128'h0;
      2: d = {$urandom, $urandom, $urandom, $urandom};
      default: d = 0;
    endcase
    if (i % 4 != 3) p_queue(d);             // both for the next cycle
    if (i % 2 == 0) begin e = {$urandom, $urandom, $urandom, $urandom}; d_tx(e); c = p_data_cnt; end
    at_cycle_start();
    rx_check(6'd1, -1, 7'd8, i % 4 == 3, 1, 1, i % 4 == 3 ? 128'h0 : trim(8, d), "peer frame");
    in_slot(3);
    if (i % 2 == 0 && (p_data_cnt != c + 1 || p_last_data !== e))
      fail($sformatf("peer did not receive the DUT payload in cycle %0d", i));
    rd(A_IRQ_STATUS); seen |= rdv; wr(A_IRQ_STATUS, IRQ_ALL);
  end
  if (seen !== (`B(CYCLE) | `B(SENT) | `B(TX_DONE) | `B(RX_AVAIL)))
    fail($sformatf("traffic: interrupts %h", seen));
  if (p_err_cnt != 0) fail("peer saw errors");

  // ---- long frames from the BFM in slot 3 (non-sync, non-startup): 63, 64, 0 words
  for (int k = 0; k < 3; k++) begin
    in_slot(2); flush();
    b_seed = $urandom;
    bfm_frame(3, 11'd3, k == 0 ? 63 : k == 1 ? 64 : 0);
    rx_check(6'd3, p_cycle, k == 0 ? 7'd63 : k == 1 ? 7'd64 : 7'd0, 0, 0, 0,
             bfm_data(k == 0 ? 63 : k == 1 ? 64 : 0), "BFM frame");
  end

  // ---- errors, one per cycle
  in_slot(2); flush();
  b_seed = 1; bfm_frame(3, 11'd3, 2, 1);  at_cycle_start(); expect_irq(`B(ERR_HCRC), NOISE, "header CRC");
  b_seed = 2; bfm_frame(3, 11'd3, 2, 0, 1); at_cycle_start(); expect_irq(`B(ERR_FCRC), NOISE, "frame CRC");
  b_seed = 3; bfm_frame(3, 11'd3, 2, 0, 0, 4); at_cycle_start(); expect_irq(`B(ERR_CODING), NOISE, "coding");
  b_seed = 4; bfm_frame(3, 11'd5, 2);     at_cycle_start(); expect_irq(`B(ERR_SLOT), NOISE, "slot");
  
  // ---- TX overflow: the first payload goes to the core at once, the
  // second waits (TX_FULL), the third is dropped; sent in two cycles
  in_slot(3);
  d = {4{32'h1111_1111}}; e = {4{32'h2222_2222}};
  c = p_data_cnt;
  d_tx(d); d_tx(e); rd(A_FLAGS); if ((rdv & F_TX) == 0) fail("TX overflow: TX_FULL"); d_tx({4{32'h3333_3333}});
  at_cycle_start(); at_cycle_start();
  if (p_data_cnt != c + 1 || p_last_data !== d) fail("TX overflow: first payload");
  rd(A_FLAGS); if ((rdv & F_TX) != 0) fail("TX overflow: TX_FULL after the handshake");
  at_cycle_start();
  if (p_data_cnt != c + 2 || p_last_data !== e) fail("TX overflow: second payload");
  expect_irq(`B(SENT) | `B(TX_DONE) | `B(TX_OVF), NOISE, "TX overflow");

  // ---- RX overflow: two peer frames unread, the second is dropped
  in_slot(2); flush(); c = p_cycle + 1;
  p_queue({4{32'hA5A5_5A5A}}); in_slot(3); in_slot(2);
  p_queue({4{32'h0F0F_F0F0}}); in_slot(3); in_slot(2);
  expect_irq(`B(RX_AVAIL) | `B(RX_OVF), `B(CYCLE), "RX overflow");
  rx_check(6'd1, c, 7'd8, 0, 1, 1, {4{32'hA5A5_5A5A}}, "RX overflow");

  // ---- pop RX in the very clock the next frame is captured
  in_slot(2); flush();
  in_slot(1); c = p_cycle;
  poll(A_FLAGS, F_RX, F_RX, 100_000);        // a null frame from the peer, unread
  in_slot(2);
  p_queue({4{32'hC3C3_3C3C}});
  rd_exp(A_RX0, 0);
  while (!(dut.u_core.dst == 7 && dut.u_core.strobe && dut.u_core.v_n && dut.u_core.slot_s == 1))
    @(negedge PCLK);
  apb_now(0, A_RX4, 0, 0);                   // access phase sees rx_valid
  if (rdv !== {10'h0, 1'b1, 1'b1, 1'b1, 7'd8, 6'(c), 6'd1}) fail($sformatf("pop at capture: first frame %h", rdv));
  rx_check(6'd1, 6'(c + 1), 7'd8, 0, 1, 1, {4{32'hC3C3_3C3C}}, "pop at capture");
  expect_irq(`B(RX_AVAIL), `B(CYCLE), "pop at capture");

  // ---- sync loss: the time master stops; then the DUT becomes the
  // time master and the peer integrates on its frames
  @(negedge PCLK) p_rst = 0;
  c = 0;
  rd(A_STATUS);
  while (rdv[0] && c < 50_000) begin rd(A_STATUS); c++; end
  expect_irq(`B(CYCLE) | `B(ERR_SYNC), `B(RX_AVAIL) | `B(RX_OVF), "sync loss");
  flush();
  d_cold = 1; d_sync = 1; p_cold = 0; p_sync = 0; set_cfg();
  @(negedge PCLK) p_rst = 1;
  for (int i = 0; i < 3; i++) at_cycle_start();
  if (!p_synced) fail("peer did not integrate on the DUT");
  at_cycle_start(); flush(); c = p_rx_cnt;
  d_tx({4{32'h5555_AAAA}});
  at_cycle_start(); in_slot(3);
  if (p_last_data !== {4{32'h5555_AAAA}} || !p_last_startup) fail("DUT as time master: frame");
  flush(); in_slot(2);
  rx_check(6'd1, -1, 7'd8, 1, 0, 0, 128'h0, "peer null frame, not sync");

  // ---- configuration 2: 63 slots, the BFM in slots 62 and 63
  @(negedge PCLK) p_rst = 0;
  wr(A_CFG1, 0);                             // DUT listens: loses sync at its cycle end
  c = 0;
  rd(A_STATUS);
  while (rdv[0] && c < 50_000) begin rd(A_STATUS); c++; end
  k_slot = 120; k_nslots = 63; k_nit = 30; k_ap = 6; d_plen = 0; p_plen = 0;
  d_cold = 0; d_sync = 0; p_cold = 1; p_sync = 1;
  cycles(30 * bt());
  set_cfg();
  @(negedge PCLK) p_rst = 1;
  at_cycle_start(); in_slot(2); flush();
  rx_check(6'd1, -1, 7'd0, 1, 1, 1, 128'h0, "63 slots: peer");
  b_seed = $urandom; bfm_frame(62, 11'd62, 1);
  rx_check(6'd62, p_cycle, 7'd1, 0, 0, 0, bfm_data(1), "slot 62");
  b_seed = $urandom; bfm_frame(63, 11'd63, 0);
  rx_check(6'd63, p_cycle, 7'd0, 0, 0, 0, 128'h0, "slot 63");
  rx_check(6'd1, -1, 7'd0, 1, 1, 1, 128'h0, "63 slots: peer again");
  // leave a frame and an interrupt pending: the final reset clears them
  at_cycle_start();
endtask
