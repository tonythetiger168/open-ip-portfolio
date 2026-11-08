// SPDX-License-Identifier: Apache-2.0
// Smartcard_7816-specific part of tb/Smartcard_7816_apb_tb.sv. An
// soc_ss_axi_mem subordinate sits on the AXI4 manager pins m_*; a card model
// sits on the card pins (VCC, RST, CLK, open-drain I/O with a pull-up,
// detect). Covered through the registers: activation ignored with no card,
// DET and STATUS.present, activation (RST low for RST_CLKS card clocks),
// an ATR in the RX ring (WR_IDX / RD_IDX, RX_COUNTS), T=0 TX with GUARD,
// TX repetitions (TX_COUNTS), a TX failing after 4 repetitions
// (STATUS.tx_fail, PERR), an RX parity error signalled and repeated, T=1
// parity flags, the waiting time (TIMEOUT), the ring full and the FIFO
// full (OVF_CNT), AXI read and write errors (ERR, STATUS.err), deactivation
// by command (RST, CLK, VCC order), the inverse convention, card removal
// during a TX, irq masking.
// Coverage closure: a TX buffer at 0x7FFF_FFFC (1 beat, then 16 beats from
// 0x8000_0000) and an RX ring across 0x8000_0000, then both back at low
// addresses; ENABLE dropped while active; an interrupt left pending for the
// reset that follows, FLAGS read.
`include "apb/tv_apb_common.svh"

// ---------------- card model ----------------
logic        c_low = 0;                            // the card pulls I/O low
assign sc_io_in = !(sc_io_oe_low || c_low);
initial sc_det = 1'b0;
int          c_etu = 16;                           // card clocks per ETU (TIMING.etu)
bit          c_t1 = 0, c_inv = 0;
bit          c_busy = 0;                           // the card is sending
int          c_nak = 0;                            // characters to reject next
logic [7:0]  c_rxq [$];                            // characters the card received
int          c_now = 0;                            // card clocks
int          c_last = -1, c_gap = 1 << 30;         // start-to-start spacing
time         c_clk_t = 0;                          // last CLK rise
always @(posedge sc_clk) begin c_now++; c_clk_t = $time; end
task automatic cclk(input int n); repeat (n) @(posedge sc_clk); endtask
function automatic bit c_lvl(input logic [7:0] d, input int k, input bit badp);
  if (k < 8) return c_inv ? !d[7 - k] : d[k];
  return c_inv ? !((^d) ^ badp) : ((^d) ^ badp);
endfunction
task automatic c_send(input logic [7:0] d, input bit badp, output bit naked);
  c_busy = 1;
  c_low = 1; cclk(c_etu);
  for (int k = 0; k < 9; k++) begin c_low = !c_lvl(d, k, badp); cclk(c_etu); end
  c_low = 0;
  cclk(c_etu + c_etu / 4);
  naked = !sc_io_in;
  cclk(c_etu - c_etu / 4 + c_etu / 2);
  c_busy = 0;
endtask
task automatic c_char(input logic [7:0] d, input bit badp_first);
  bit n, bp;
  bp = badp_first;
  forever begin
    c_send(d, bp, n);
    if (!(n && !c_t1)) break;
    bp = 0;
    cclk(c_etu);
  end
endtask
initial forever begin                              // the card's receiver
  @(negedge sc_io_in);
  if (c_busy || !sc_vcc_en || !sc_rst_n) continue;
  begin
    logic [7:0] d;
    logic [8:0] b;
    bit bad;
    if (c_last >= 0 && c_now - c_last < c_gap) c_gap = c_now - c_last;
    c_last = c_now;
    cclk(c_etu / 2);
    if (sc_io_in) continue;
    for (int k = 0; k < 9; k++) begin cclk(c_etu); b[k] = sc_io_in; end
    for (int i = 0; i < 8; i++) d[i] = c_inv ? !b[7 - i] : b[i];
    bad = (^d) != (c_inv ? !b[8] : b[8]);
    if (!c_t1 && (bad || c_nak > 0)) begin
      if (!bad) c_nak--;
      cclk(c_etu);
      c_low = 1; cclk(c_etu + c_etu / 2); c_low = 0;
    end else c_rxq.push_back(d);
  end
end

// ---------------- register-level helpers ----------------
logic [31:0] sc_rb;                                // RING_BASE
int          sc_rw, sc_idx;                        // RING_WORDS, next ring word software reads
logic [31:0] sc_ta;                                // TX_ADDR
logic [7:0]  sc_d [];                              // byte lists
task automatic sc_ring(input logic [31:0] b, input int n);
  sc_rb = b; sc_rw = n;
  rd(A_WR_IDX); sc_idx = int'(rdv[15:0]);
  wr(A_RING_BASE, b); wr(A_RING_WORDS, n); wr(A_RD_IDX, sc_idx);
endtask
task automatic sc_timing(input int etu, input int guard);
  c_etu = etu;
  wr(A_TIMING, {8'd0, 8'(guard), 16'(etu)});
endtask
// the card sends d (first character with bad parity when bp0)
task automatic sc_card(input logic [7:0] d [], input bit bp0);
  foreach (d[i]) c_char(d[i], bp0 && i == 0);
endtask
// ring words software reads next, with the T=1 parity flags in pf
task automatic sc_rx_chk(input logic [7:0] d [], input logic [31:0] pf, input string what);
  int t;
  t = 0;
  forever begin
    rd(A_WR_IDX);
    if ((int'(rdv[15:0]) - sc_idx + sc_rw) % sc_rw >= d.size() || t > 200) break;
    cycles(20); t++;
  end
  foreach (d[i]) begin
    logic [31:0] w;
    w = mem.peek(sc_rb + 32'(4 * ((sc_idx + i) % sc_rw)));
    if (w !== {23'b0, pf[i], d[i]}) begin fail($sformatf("%s: ring word %0d = %h, expected %h", what, i, w, {23'b0, pf[i], d[i]})); break; end
  end
  sc_idx = (sc_idx + d.size()) % sc_rw;
  wr(A_RD_IDX, sc_idx);
endtask
task automatic sc_activate(input int rst_clks, input string what);
  int t0;
  wr(A_CMD, 1);
  t0 = c_now;
  wait (sc_rst_n === 1'b1);
  if (c_now - t0 < rst_clks - 1 || c_now - t0 > rst_clks + 1)
    fail($sformatf("%s: RST low for %0d card clocks, RST_CLKS %0d", what, c_now - t0, rst_clks));
  cycles(3);
  rd(A_STATUS);
  if (rdv[1:0] !== 2'b11) fail($sformatf("%s: STATUS %h", what, rdv));
endtask
// put d in the TX buffer at sc_ta and send it; chk compares what the card got
task automatic sc_tx(input logic [7:0] d [], input bit exp_fail, input bit chk, input int guard, input string what);
  for (int i = 0; i < d.size(); i += 4) begin
    logic [31:0] w;
    w = 0;
    for (int j = 0; j < 4 && i + j < d.size(); j++) w[8 * j +: 8] = d[i + j];
    mem.poke(sc_ta + 32'(i), w);
  end
  wr(A_TX_ADDR, sc_ta); wr(A_TX_LEN, d.size());
  c_rxq.delete(); c_gap = 1 << 30; c_last = -1;
  wr(A_CMD, 4);
  rd(A_STATUS);
  if (rdv[2] !== 1'b1) fail({what, ": STATUS.tx_busy low after CMD.tx_start"});
  poll(A_STATUS, 32'h4, 32'h0, 100000);
  cclk(2 * c_etu);
  rd(A_STATUS);
  if (rdv[3] !== exp_fail) fail($sformatf("%s: STATUS.tx_fail %b", what, rdv[3]));
  if (chk && !exp_fail) begin
    if (c_rxq.size() != d.size()) fail($sformatf("%s: card got %0d of %0d characters", what, c_rxq.size(), d.size()));
    else foreach (d[i]) if (c_rxq[i] !== d[i]) begin fail($sformatf("%s: character %0d %h, expected %h", what, i, c_rxq[i], d[i])); break; end
    if (d.size() > 1 && c_nak == 0 && c_gap < (12 + guard) * c_etu - 1)
      fail($sformatf("%s: characters %0d card clocks apart, expected %0d", what, c_gap, (12 + guard) * c_etu));
  end
endtask

task automatic ip_func;
  // no card: activation ignored
  wr(A_CTRL, 1);                                    // enable, CLK_DIV 0
  sc_timing(16, 0); wr(A_WAITS, {16'd40, 16'd0});
  sc_ta = 32'h0010_0000;
  sc_ring(32'h0040_0000, 8);
  wr(A_CMD, 1);
  cycles(20);
  rd(A_STATUS);
  if (rdv[1:0] !== 2'b00 || sc_vcc_en !== 1'b0) fail("powered without a card");
  // card inserted
  sc_det = 1; cycles(4);
  rd(A_STATUS);
  if (rdv[5] !== 1'b1) fail("STATUS.present low with a card");
  tv_irq(IRQ_DET, "card inserted");
  // activation and an ATR
  sc_activate(40, "cold reset");
  cclk(3 * c_etu);
  sc_d = new[6]; sc_d = '{8'h3B, 8'h95, 8'h11, 8'h81, 8'h01, 8'h46};
  sc_card(sc_d, 0);
  sc_rx_chk(sc_d, 0, "ATR");
  rd_exp(A_RX_COUNTS, 6);
  tv_irq(IRQ_RX, "ATR");
  // T=0 command header with GUARD 2
  sc_timing(16, 2);
  sc_d = new[7]; sc_d = '{8'hA0, 8'hA4, 8'h00, 8'h00, 8'h02, 8'h3F, 8'h00};
  sc_tx(sc_d, 0, 1, 2, "T=0 TX");
  tv_irq(IRQ_TX_DONE, "T=0 TX");
  sc_timing(16, 0);
  // two characters rejected: sent again
  c_nak = 2;
  sc_d = new[5]; sc_d = '{8'h00, 8'hC0, 8'h00, 8'h00, 8'h1A};
  sc_tx(sc_d, 0, 1, 0, "TX with repetitions");
  rd_exp(A_TX_COUNTS, 2);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // five rejections: the TX fails
  c_nak = 5;
  sc_d = new[3]; sc_d = '{8'h11, 8'h22, 8'h33};
  sc_tx(sc_d, 1, 0, 0, "TX failing");
  tv_irq_pin(IRQ_PERR, "TX failing");
  c_nak = 0;
  cclk(20 * c_etu);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // an RX parity error: signalled, repeated, stored once
  sc_d = new[2]; sc_d = '{8'h90, 8'h00};
  sc_card(sc_d, 1);
  sc_rx_chk(sc_d, 0, "RX repetition");
  rd_exp(A_RX_COUNTS, {16'd1, 16'd8});
  tv_irq_pin(IRQ_PERR, "RX parity error");
  wr(A_IRQ_STATUS, IRQ_ALL);
  // T=1: no signalling, the parity flag is stored
  wr(A_CTRL, 5); c_t1 = 1;
  sc_d = new[2]; sc_d = '{8'h5A, 8'hA5};
  sc_card(sc_d, 1);
  sc_rx_chk(sc_d, 1, "T=1 parity flag");
  rd_exp(A_RX_COUNTS, {16'd2, 16'd10});
  sc_d = new[3]; sc_d = '{8'h00, 8'h01, 8'hFE};
  sc_tx(sc_d, 0, 1, 0, "T=1 TX");
  wr(A_CTRL, 1); c_t1 = 0;
  wr(A_IRQ_STATUS, IRQ_ALL);
  // waiting time: 30 ETU without a character
  wr(A_WAITS, {16'd40, 16'd30});
  cclk(40 * c_etu);
  tv_irq(IRQ_TIMEOUT, "waiting time");
  sc_d = new[1]; sc_d = '{8'h61};
  sc_card(sc_d, 0);
  cclk(20 * c_etu);
  tv_no_irq(IRQ_TIMEOUT, "20 ETU after a character");
  cclk(15 * c_etu);
  tv_irq(IRQ_TIMEOUT, "35 ETU after a character");
  wr(A_WAITS, {16'd40, 16'd0});
  sc_rx_chk(sc_d, 0, "waiting time");
  wr(A_IRQ_STATUS, IRQ_ALL);
  // ring full: 8 characters wait in the FIFO, the 9th is dropped
  wr(A_RD_IDX, (sc_idx + 1) % sc_rw);
  for (int i = 0; i < 9; i++) c_char(8'(8'h30 + i), 0);
  cycles(50);
  rd_exp(A_TX_COUNTS, {16'd1, 16'd6});
  rd(A_WR_IDX);
  if (int'(rdv[15:0]) != sc_idx) fail("ring written while full");
  wr(A_RD_IDX, sc_idx);
  sc_d = new[7]; sc_d = '{8'h30, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36};
  sc_rx_chk(sc_d, 0, "ring full (first 7)");
  sc_d = new[1]; sc_d = '{8'h37};
  sc_rx_chk(sc_d, 0, "ring full (8th)");
  wr(A_IRQ_STATUS, IRQ_ALL);
  // AXI errors: an RX ring write and a TX buffer read
  mem.err_lo = sc_rb + 32'(4 * sc_idx); mem.err_hi = mem.err_lo + 4;
  c_char(8'h77, 0);
  cycles(50);
  rd(A_STATUS);
  if (rdv[4] !== 1'b1) fail("no STATUS.err after an RX write error");
  tv_irq(IRQ_ERR, "RX write error");
  sc_idx = (sc_idx + 1) % sc_rw; wr(A_RD_IDX, sc_idx);
  mem.err_lo = sc_ta; mem.err_hi = sc_ta + 4;
  sc_d = new[2]; sc_d = '{8'h01, 8'h02};
  sc_tx(sc_d, 0, 0, 0, "TX read error");
  if (c_rxq.size() != 2 || c_rxq[0] !== 8'hEF || c_rxq[1] !== 8'hBE) fail("TX read error: DEADBEEF bytes not sent");
  tv_irq(IRQ_ERR, "TX read error");
  mem.err_lo = '1; mem.err_hi = '1;
  // address / burst sweep: 68 bytes at 0x7FFF_FFFC are read as 1 beat
  // (ARLEN 0), then 16 beats (ARLEN 15) from 0x8000_0000 after the 4 KB
  // split; the 8-word ring at 0x7FFF_FFF0 is written across 0x8000_0000, so
  // every AxADDR bit 2..31 rises; the low addresses that follow lower them
  sc_ta = 32'h7FFF_FFFC;
  sc_d = new[68];
  foreach (sc_d[i]) sc_d[i] = (i % 2) ? 8'(~(i * 37)) : 8'(i * 37);
  sc_tx(sc_d, 0, 1, 0, "sweep TX");
  wr(A_IRQ_STATUS, IRQ_ALL);
  sc_ring(32'h7FFF_FFF0, 8);                        // WR_IDX stays below RING_WORDS
  for (int k = 0; k < 2; k++) begin
    sc_d = new[4]; sc_d = '{8'hFF, 8'h00, 8'hAA, 8'h55};
    sc_card(sc_d, 0);
    sc_rx_chk(sc_d, 0, "sweep ring");
  end
  sc_ring(32'h0000_0010, 8);
  sc_d = new[1]; sc_d = '{8'h3C};
  sc_card(sc_d, 0);
  sc_rx_chk(sc_d, 0, "low ring");
  sc_ta = 32'h0000_0008;
  sc_d = new[2]; sc_d = '{8'hC3, 8'h3C};
  sc_tx(sc_d, 0, 1, 0, "low TX");
  wr(A_IRQ_STATUS, IRQ_ALL);
  // deactivation by command: RST low, then CLK stops, then VCC off
  begin
    time tr, tc, tv;
    wr(A_CMD, 2);
    wait (!sc_rst_n); tr = $time;
    wait (!sc_vcc_en); tv = $time; tc = c_clk_t;
    if (!(tr < tc && tc < tv)) fail($sformatf("deactivation order RST %0t CLK %0t VCC %0t", tr, tc, tv));
    rd(A_STATUS);
    if (rdv[1:0] !== 2'b00 || sc_clk !== 1'b0) fail("not deactivated");
  end
  // inverse convention, CLK_DIV 1, a longer ETU and RST
  wr(A_CTRL, 3 | (1 << 3)); c_inv = 1;
  sc_timing(31, 0); wr(A_WAITS, {16'd300, 16'd0});
  sc_activate(300, "inverse");
  cclk(3 * c_etu);
  sc_d = new[3]; sc_d = '{8'h3F, 8'h94, 8'h11};
  sc_card(sc_d, 0);
  sc_rx_chk(sc_d, 0, "inverse ATR");
  sc_d = new[1]; sc_d = '{8'hC3};
  sc_card(sc_d, 1);                                  // bad parity: signalled and repeated
  sc_rx_chk(sc_d, 0, "inverse RX");
  sc_d = new[4]; sc_d = '{8'h80, 8'h10, 8'h0F, 8'h55};
  sc_tx(sc_d, 0, 1, 0, "inverse TX");
  wr(A_IRQ_STATUS, IRQ_ALL);
  // card removal during a TX: deactivation, the TX ends with tx_fail
  for (int i = 0; i < 8; i++) mem.poke(sc_ta + 32'(4 * i), $urandom);
  wr(A_TX_LEN, 32);
  wr(A_CMD, 4);
  cclk(30 * c_etu);
  sc_det = 0;
  wait (!sc_vcc_en);
  cycles(10);
  rd(A_STATUS);
  if (rdv[3:2] !== 2'b10 || rdv[5] !== 1'b0) fail($sformatf("card removal during a TX: STATUS %h", rdv));
  tv_irq(IRQ_DET, "card removed");
  wr(A_CTRL, 1); c_inv = 0;
  sc_timing(16, 0); wr(A_WAITS, {16'd40, 16'd0});
  // ENABLE dropped while active: deactivation, WR_IDX cleared
  sc_det = 1; cycles(4);
  sc_activate(40, "warm");
  wr(A_CTRL, 0);
  wait (!sc_vcc_en);
  cycles(4);
  rd_exp(A_WR_IDX, 0);
  // an activation for the reset that follows, DET left pending
  wr(A_CTRL, 1);
  wr(A_CMD, 1);
  cycles(30);
  tv_irq_pin(IRQ_DET, "card inserted");
  rd_exp(A_FLAGS, 0);
  sc_det = 0;                                        // no card after the reset (no DET then)
  if (mem.errors != 0) fail("AXI rule violations");
endtask
