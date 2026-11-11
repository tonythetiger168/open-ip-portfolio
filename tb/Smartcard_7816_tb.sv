// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of Smartcard_7816_top (STB SoC, AXI4 manager).
// A card model on the card pins (VCC, RST, CLK, open-drain I/O, detect)
// checks the activation (RST held low for RST_CLKS card clocks while CLK
// runs), answers with an ATR, receives the characters the core sends and
// checks their timing (start to start 12 + GUARD ETU), and can signal
// parity errors (T=0) a chosen number of times. Every character the card
// sends is checked against the RX ring in the AXI4 memory model when its
// RX interrupt fires. Covers: direct and inverse convention, T=0 parity
// error signalling in both directions and character repetition, a TX that
// fails after 4 repetitions, T=1 parity flags, the waiting time (TIMEOUT),
// the ring full (characters wait) and the FIFO full (OVF_CNT), AXI read and
// write errors, deactivation by command and by card removal (RST, CLK,
// VCC order), DET, reset. Prints LAT lines.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module Smartcard_7816_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  wire         sc_vcc_en, sc_rst_n, sc_clk, sc_io_oe_low;
  logic        card_low = 0;
  wire         sc_io_in = !(sc_io_oe_low || card_low);
  logic        sc_det = 0;
  logic        enable = 0, inverse = 0, t1 = 0;
  logic [7:0]  clk_div = 1, guard = 0;
  logic [15:0] etu = 16, wt = 0, rst_clks = 40;
  logic [31:0] ring_base = 32'h0040_0000, tx_addr = 32'h0010_0000;
  logic [15:0] ring_words = 8, rd_idx = 0, tx_len = 0;
  logic        activate = 0, deactivate = 0, tx_start = 0;
  wire         active, powered, tx_busy, tx_fail, err, present;
  wire  [15:0] wr_idx, rx_cnt, perr_cnt, retx_cnt, ovf_cnt;
  wire         rx, tx_done, perr, det, timeout, err_irq;
  Smartcard_7816_top dut (.*);

`define PULSE(s) begin @(negedge clk); s = 1; @(negedge clk); s = 0; end

  // ---------------- RX ring checker ----------------
  logic [31:0] expq [$];
  int          m_idx = 0, n_rx = 0, n_txd = 0, n_perr = 0, n_det = 0, n_to = 0, n_err_irq = 0;
  bit          auto_consume = 1;
  always @(posedge clk) if (rst_n) begin
    n_txd += tx_done; n_perr += perr; n_det += det; n_to += timeout; n_err_irq += err_irq;
    if (rx) begin
      logic [31:0] e;
      n_rx++;
      if (expq.size() == 0) fail("RX without an expected character");
      else begin
        e = expq.pop_front();
        if (!err_irq && mem.peek(ring_base + 32'(4 * m_idx)) !== e)
          fail($sformatf("ring word %0d: %h, expected %h", m_idx, mem.peek(ring_base + 32'(4 * m_idx)), e));
      end
      m_idx = (m_idx + 1) % ring_words;
      if (auto_consume) rd_idx <= 16'(m_idx);
    end
  end

  // ---------------- card model ----------------
  bit          c_inv = 0;                          // the card's convention
  bit          c_busy = 0;                         // the card is sending
  int          c_nak = 0;                          // parity errors to signal on the next characters received
  logic [7:0]  c_rxq [$];                          // characters the card received
  int          c_rx_bad = 0;                       // received with bad parity (and signalled)
  int          c_last_start = -1, c_min_gap = 1 << 30;
  int          c_now = 0;                          // card clocks
  always @(posedge sc_clk) c_now++;
  task automatic cclk(input int n); repeat (n) @(posedge sc_clk); endtask
  function automatic bit lvl(input logic [7:0] d, input int k, input bit badp);   // k 0..8
    if (k < 8) return c_inv ? !d[7 - k] : d[k];
    return c_inv ? !((^d) ^ badp) : ((^d) ^ badp);
  endfunction
  // send one character; returns 1 when the core signalled a parity error
  task automatic c_send(input logic [7:0] d, input bit badp, output bit naked);
    c_busy = 1;
    card_low = 1; cclk(etu);
    for (int k = 0; k < 9; k++) begin card_low = !lvl(d, k, badp); cclk(etu); end
    card_low = 0;                                  // 10 ETU
    cclk(etu + etu / 4);                           // 11.25 ETU
    naked = !sc_io_in;
    cclk(etu - etu / 4 + etu / 2);                 // 12.5 ETU
    c_busy = 0;
  endtask
  // send with the T=0 repetition: a signalled character is sent again
  task automatic c_char(input logic [7:0] d, input bit badp_first);
    bit n, bp;
    bp = badp_first;
    forever begin
      c_send(d, bp, n);
      if (!(n && !t1)) break;
      bp = 0;
      cclk(etu);
    end
  endtask
  // the card's receiver
  initial forever begin
    @(negedge sc_io_in);
    if (c_busy || !sc_vcc_en || !sc_rst_n) continue;
    begin
      logic [7:0] d;
      logic [8:0] b;
      bit bad;
      if (c_last_start >= 0 && c_now - c_last_start < c_min_gap) c_min_gap = c_now - c_last_start;
      c_last_start = c_now;
      cclk(etu / 2);
      if (sc_io_in) continue;
      for (int k = 0; k < 9; k++) begin cclk(etu); b[k] = sc_io_in; end
      for (int i = 0; i < 8; i++) d[i] = c_inv ? !b[7 - i] : b[i];
      bad = (^d) != (c_inv ? !b[8] : b[8]);
      if (bad) c_rx_bad++;
      if (!t1 && (bad || c_nak > 0)) begin         // 9.5 ETU: signal from 10.5 to 12 ETU
        if (!bad) c_nak--;
        cclk(etu);
        card_low = 1; cclk(etu + etu / 2); card_low = 0;
      end else c_rxq.push_back(d);
    end
  end
  // expected ring word of a character the card sends
  task automatic exp_rx(input logic [7:0] d, input bit badp);
    expq.push_back({23'b0, badp, d});
  endtask
  task automatic card_says(input logic [7:0] d []);
    foreach (d[i]) begin
      exp_rx(d[i], 0);
      c_char(d[i], 0);
    end
  endtask
  task automatic drain(input string what);
    int t;
    t = 0;
    while ((expq.size() != 0 || dut.re_busy || !dut.f_empty) && t < 200000) begin clks(1); t++; end
    if (expq.size() != 0) fail($sformatf("%s: %0d characters never reached the ring", what, expq.size()));
  endtask

  int tr, tc, tv;                                 // deactivation step times
  bit tx_chk = 1;                                 // do_tx compares what the card got
  // ---------------- core side helpers ----------------
  task automatic do_activate(input string what);
    int t0, lowc;
    `PULSE(activate)
    t0 = c_now;
    wait (sc_rst_n === 1'b1);
    lowc = c_now - t0;
    if (!sc_vcc_en) fail({what, ": RST high without VCC"});
    if (lowc < rst_clks - 1 || lowc > rst_clks + 1) fail($sformatf("%s: RST low for %0d card clocks, RST_CLKS %0d", what, lowc, rst_clks));
    clks(2);
    if (!active) fail({what, ": not active after RST"});
  endtask
  task automatic do_tx(input logic [7:0] d [], input string what, input bit exp_fail);
    int n0;
    for (int i = 0; i < d.size(); i += 4) begin
      logic [31:0] w;
      w = 0;
      for (int j = 0; j < 4 && i + j < d.size(); j++) w[8 * j +: 8] = d[i + j];
      mem.poke(tx_addr + 32'(i), w);
    end
    tx_len = 16'(d.size());
    n0 = n_txd;
    c_rxq.delete(); c_min_gap = 1 << 30; c_last_start = -1;
    `PULSE(tx_start)
    wait (n_txd != n0);
    clks(2);
    cclk(2 * etu);
    if (tx_fail !== exp_fail) fail($sformatf("%s: tx_fail %b", what, tx_fail));
    if (!exp_fail && tx_chk) begin
      if (c_rxq.size() != d.size()) fail($sformatf("%s: card got %0d of %0d characters", what, c_rxq.size(), d.size()));
      else foreach (d[i]) if (c_rxq[i] !== d[i]) fail($sformatf("%s: character %0d %h, expected %h", what, i, c_rxq[i], d[i]));
      if (d.size() > 1 && c_nak == 0 && c_min_gap < (12 + guard) * etu - 1)
        fail($sformatf("%s: characters %0d card clocks apart, expected %0d", what, c_min_gap, (12 + guard) * etu));
    end
  endtask

  initial begin
    logic [7:0] atr [];
    lat_master = "smartcard";
    clks(3);
    rst_n = 1;
    clks(2);
    // no card: activate is ignored
    enable = 1;
    `PULSE(activate)
    clks(20);
    if (sc_vcc_en || powered) fail("powered without a card");
    // card inserted: DET
    sc_det = 1; clks(4);
    if (n_det != 1 || !present) fail("DET / present on insertion");
    // activation and a direct-convention ATR
    do_activate("cold reset");
    atr = new[6]; atr = '{8'h3B, 8'h95, 8'h11, 8'h81, 8'h01, 8'h46};
    cclk(3 * etu);
    card_says(atr);
    drain("ATR");
    if (rx_cnt != 6) fail($sformatf("RX_CNT %0d after the ATR", rx_cnt));
    // T=0 command header, spacing with GUARD 2
    guard = 2;
    atr = new[7]; atr = '{8'hA0, 8'hA4, 8'h00, 8'h00, 8'h02, 8'h3F, 8'h00};
    do_tx(atr, "T=0 TX", 0);
    guard = 0;
    // the card signals parity errors on two characters: both sent again
    c_nak = 2;
    atr = new[5]; atr = '{8'h00, 8'hC0, 8'h00, 8'h00, 8'h1A};
    do_tx(atr, "TX with repetitions", 0);
    if (retx_cnt != 2) fail($sformatf("RETX_CNT %0d", retx_cnt));
    // five errors on one character: the TX fails (PERR)
    begin
      int p0;
      p0 = n_perr;
      c_nak = 5;
      atr = new[3]; atr = '{8'h11, 8'h22, 8'h33};
      do_tx(atr, "TX failing", 1);
      if (n_perr != p0 + 1) fail("no PERR for a failed TX");
      c_nak = 0;
      cclk(20 * etu);
    end
    // the card sends a character with bad parity: signalled, repeated, stored once
    exp_rx(8'h90, 0);
    c_char(8'h90, 1);
    exp_rx(8'h00, 0);
    c_char(8'h00, 0);
    drain("RX repetition");
    if (perr_cnt != 1) fail($sformatf("PERR_CNT %0d", perr_cnt));
    // T=1: no signalling, the parity flag is stored
    t1 = 1;
    exp_rx(8'h5A, 1);
    c_char(8'h5A, 1);
    exp_rx(8'hA5, 0);
    c_char(8'hA5, 0);
    drain("T=1 parity flag");
    if (perr_cnt != 2) fail($sformatf("PERR_CNT %0d after T=1", perr_cnt));
    atr = new[3]; atr = '{8'h00, 8'h01, 8'hFE};
    do_tx(atr, "T=1 TX", 0);
    t1 = 0;
    // waiting time: 30 ETU without a character
    begin
      int t0;
      t0 = n_to;
      wt = 30;
      cclk(40 * etu);
      if (n_to != t0 + 1) fail($sformatf("%0d TIMEOUTs in 40 ETU with WT 30", n_to - t0));
      exp_rx(8'h61, 0);
      c_char(8'h61, 0);
      cclk(20 * etu);
      if (n_to != t0 + 1) fail("TIMEOUT before WT after a character");
      cclk(15 * etu);
      if (n_to != t0 + 2) fail("no TIMEOUT WT after a character");
      wt = 0;
      drain("waiting time");
    end
    // ring full: characters wait in the FIFO, the 9th that finds it full is dropped
    begin
      auto_consume = 0;
      rd_idx = 16'((m_idx + 1) % ring_words);      // no room
      for (int i = 0; i < 9; i++) begin
        if (i < 8) exp_rx(8'(8'h30 + i), 0);
        c_char(8'(8'h30 + i), 0);
      end
      clks(50);
      if (ovf_cnt != 1) fail($sformatf("OVF_CNT %0d", ovf_cnt));
      auto_consume = 1;
      rd_idx = 16'(m_idx);
      drain("ring full");
    end
    // AXI errors: an RX ring write and a TX buffer read
    begin
      int e0;
      e0 = n_err_irq;
      mem.err_lo = ring_base + 32'(4 * m_idx); mem.err_hi = mem.err_lo + 4;
      exp_rx(8'h77, 0);
      c_char(8'h77, 0);
      drain("RX AXI error");
      if (n_err_irq != e0 + 1 || !err) fail("ERR after an RX write error");
      mem.err_lo = tx_addr; mem.err_hi = tx_addr + 4;
      atr = new[2]; atr = '{8'h01, 8'h02};
      tx_chk = 0;
      do_tx(atr, "TX read error", 0);
      tx_chk = 1;
      if (c_rxq.size() != 2 || c_rxq[0] !== 8'hEF || c_rxq[1] !== 8'hBE) fail("TX read error: DEADBEEF bytes not sent");
      if (n_err_irq != e0 + 2) fail("ERR after a TX read error");
      mem.err_lo = '1; mem.err_hi = '1;
    end
    // deactivation by command: RST low, then CLK stops, then VCC off
    begin
      `PULSE(deactivate)
      fork
        begin wait (!sc_rst_n); tr = $time; end
        begin clks(1); wait (!dut.clk_run); tc = $time; end
        begin wait (!sc_vcc_en); tv = $time; end
      join
      if (!(tr < tc && tc < tv)) fail($sformatf("deactivation order RST %0d CLK %0d VCC %0d", tr, tc, tv));
      if (active || sc_clk) fail("not deactivated");
    end
    // inverse convention: the card answers 3F and the core sends inverse characters
    inverse = 1; c_inv = 1;
    do_activate("inverse");
    cclk(3 * etu);
    atr = new[3]; atr = '{8'h3F, 8'h94, 8'h11};
    card_says(atr);
    exp_rx(8'hC3, 0);
    c_char(8'hC3, 1);                              // bad parity: signalled and repeated
    drain("inverse RX");
    atr = new[4]; atr = '{8'h80, 8'h10, 8'h0F, 8'h55};
    do_tx(atr, "inverse TX", 0);
    // card removal during a TX: deactivation, the TX ends with tx_fail
    begin
      int d0;
      d0 = n_det;
      for (int i = 0; i < 8; i++) mem.poke(tx_addr + 32'(4 * i), $urandom);
      tx_len = 32;
      `PULSE(tx_start)
      cclk(30 * etu);
      sc_det = 0;
      wait (!sc_vcc_en);
      clks(10);
      if (!tx_fail || tx_busy) fail("TX not ended by the card removal");
      if (n_det != d0 + 1) fail("no DET on removal");
    end
    inverse = 0; c_inv = 0;
    // reset in the middle of an activation
    sc_det = 1; clks(4);
    `PULSE(activate)
    clks(30);
    rst_n = 0;
    clks(2);
    if (sc_vcc_en || sc_rst_n || sc_io_oe_low || m_awvalid || m_arvalid) fail("not idle in reset");
    rst_n = 1; m_idx = 0; rd_idx = 0; expq.delete();
    clks(3);
    do_activate("after reset");
    cclk(2 * etu);
    atr = new[2]; atr = '{8'h3B, 8'h00};
    card_says(atr);
    drain("after reset");
    lat_summary();
    finish("Smartcard_7816");
  end
  initial begin
    #50ms;
    $display("TEST FAILED: Smartcard_7816 (timeout)");
    $finish;
  end
endmodule
