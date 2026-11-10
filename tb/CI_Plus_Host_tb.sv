// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of CI_Plus_Host_top (STB SoC, AXI4 manager).
// A CAM model (tb/ci_cam_model.svh) on the card pins checks the bus cycle
// timing and implements the attribute memory (CIS, COR) and the EN 50221
// command interface. Covers: no card, DET, power-up (RESET length, READY),
// CIS read to memory with WAIT# cycles, COR write (I/O mode), interface
// reset, host-to-module messages (with FR taken away once, and a TX that
// gives up after FR_MAX polls), module-to-host messages (polling, RX_LEN,
// the buffer held until rx_arm, a message longer than RX_MAX), a bus
// timeout, AXI read and write errors, IREQ, the transport stream bypassed
// and routed through the CAM, card removal during a TX (the DMA flushed),
// power-off, reset. Prints LAT lines.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module CI_Plus_Host_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  wire         ci_vcc_en, ci_reset, ci_cd_n;
  wire  [14:0] ci_a;
  wire  [7:0]  ci_d_o, ci_d_i;
  wire         ci_d_oe, ci_ce_n, ci_reg_n, ci_oe_n, ci_we_n, ci_iord_n, ci_iowr_n, ci_wait_n, ci_ireq_n;
  logic [7:0]  ts_in_data = 0;
  logic        ts_in_valid = 0, ts_in_sop = 0;
  wire  [7:0]  ts_out_data, ci_mo_data;
  wire         ts_out_valid, ts_out_sop, ci_mo_val, ci_mo_strt;
  logic [7:0]  ci_mi_data = 0;
  logic        ci_mi_val = 0, ci_mi_strt = 0;
  logic        enable = 0, ts_route = 0, poll = 0;
  logic [3:0]  setup = 1, hold = 1;
  logic [7:0]  strobe = 3;
  logic [15:0] wait_max = 0, rst_clks = 50, poll_div = 20, fr_max = 0;
  logic [31:0] cis_addr = 32'h0010_0000, tx_addr = 32'h0020_0000, rx_addr = 32'h0030_0000;
  logic [15:0] cis_len = 0, tx_len = 0, rx_max = 64;
  logic [14:0] cor_addr = 15'h0FFE;
  logic [7:0]  cor_val = 8'h0F;
  logic        power_on = 0, power_off = 0, cis_read = 0, cor_write = 0, if_reset = 0, tx_start = 0, rx_arm = 0;
  wire         powered, ready, io_mode, busy, rx_full, rx_ovf, tx_fail, err, present;
  wire  [7:0]  last_st;
  wire  [15:0] rx_len, tx_cnt, rx_cnt, ts_cnt, to_cnt;
  wire         det, rdy, cfg, tx_done, rx, ireq, bus_to, err_irq;
  CI_Plus_Host_top dut (.*);
`define CAM_CLK clk
  `include "ci_cam_model.svh"

`define PULSE(s) begin @(negedge clk); s = 1; @(negedge clk); s = 0; end

  int n_det = 0, n_rdy = 0, n_cfg = 0, n_txd = 0, n_rx = 0, n_ireq = 0, n_to = 0, n_err = 0;
  always @(posedge clk) if (rst_n) begin
    n_det += det; n_rdy += rdy; n_cfg += cfg; n_txd += tx_done; n_rx += rx;
    n_ireq += ireq; n_to += bus_to; n_err += err_irq;
  end
  always @(negedge clk) begin cam_setup = setup; cam_strobe = strobe; end

  logic [7:0] bl [];                               // byte lists
  // wait for an interrupt counter to move from c0
  int wt_n;
`define WAIT_CNT(c, c0, max, what) begin wt_n = 0; while (c == c0 && wt_n < max) begin clks(1); wt_n++; end if (c == c0) fail({what, ": timed out"}); end
  function automatic logic [7:0] mbyte(input logic [31:0] a, input int i);
    logic [31:0] w;
    w = mem.peek(a + 32'(4 * (i / 4)));
    return w[8 * (i % 4) +: 8];
  endfunction
  task automatic put_bytes(input logic [31:0] a, input logic [7:0] d []);
    for (int i = 0; i < d.size(); i += 4) begin
      logic [31:0] w;
      w = 0;
      for (int j = 0; j < 4 && i + j < d.size(); j++) w[8 * j +: 8] = d[i + j];
      mem.poke(a + 32'(i), w);
    end
  endtask
  task automatic power_up(input string what);
    int r0;
    r0 = n_rdy;
    `PULSE(power_on)
    while (n_rdy == r0) begin
      clks(1);
      if (!ci_vcc_en) begin fail({what, ": no power"}); break; end
    end
    if (cam_rst_len < rst_clks || cam_rst_len > rst_clks + 1) fail($sformatf("%s: RESET high %0d clocks, RST_CLKS %0d", what, cam_rst_len, rst_clks));
    if (!ready) fail({what, ": not ready"});
  endtask
  bit cis_chk = 1;                                 // do_cis compares the bytes
  task automatic do_cis(input int n, input string what);
    int c0;
    for (int i = 0; i < n + 4; i++) mem.poke(cis_addr + 32'(4 * i), 32'hA5A5_A5A5);
    cis_len = 16'(n);
    c0 = n_cfg;
    `PULSE(cis_read)
    `WAIT_CNT(n_cfg, c0, 200000, what)
    if (cis_chk) for (int i = 0; i < n; i++)
      if (mbyte(cis_addr, i) !== cam_attr[2 * i]) begin
        fail($sformatf("%s: byte %0d = %h, CIS %h", what, i, mbyte(cis_addr, i), cam_attr[2 * i])); break;
      end
    if (cis_chk) for (int i = n; i < ((n + 3) / 4) * 4; i++) if (mbyte(cis_addr, i) !== 8'h00) fail($sformatf("%s: pad byte %0d not 0", what, i));
    if (mem.peek(cis_addr + 32'(4 * ((n + 3) / 4))) !== 32'hA5A5_A5A5) fail({what, ": written past the end"});
  endtask
  task automatic do_tx(input logic [7:0] d [], input bit exp_fail, input string what);
    int t0, m0;
    put_bytes(tx_addr, d);
    tx_len = 16'(d.size());
    t0 = n_txd; m0 = cam_in_n.size();
    `PULSE(tx_start)
    `WAIT_CNT(n_txd, t0, 400000, what)
    clks(2);
    if (tx_fail !== exp_fail) fail($sformatf("%s: tx_fail %b", what, tx_fail));
    if (!exp_fail) begin
      if (cam_in_n.size() != m0 + 1) fail({what, ": the CAM got no message"});
      else begin
        int n;
        n = cam_in_n.pop_back();
        if (n != d.size()) fail($sformatf("%s: CAM got %0d bytes of %0d", what, n, d.size()));
        for (int i = n - 1; i >= 0; i--) begin
          logic [7:0] b;
          b = cam_in.pop_back();
          if (b !== d[i]) fail($sformatf("%s: byte %0d = %h, expected %h", what, i, b, d[i]));
        end
      end
    end else if (cam_in_n.size() != m0) fail({what, ": a message reached the CAM"});
  endtask
  // the CAM sends d; check the RX buffer (store bytes stored)
  task automatic do_rx(input logic [7:0] d [], input int store, input string what);
    int r0;
    for (int i = 0; i < 24; i++) mem.poke(rx_addr + 32'(4 * i), 32'h5A5A_5A5A);
    r0 = n_rx;
    cam_send(d);
    `WAIT_CNT(n_rx, r0, 400000, what)
    clks(2);
    if (rx_len != d.size()) fail($sformatf("%s: RX_LEN %0d, sent %0d", what, rx_len, d.size()));
    if (rx_ovf !== (d.size() > store)) fail($sformatf("%s: rx_ovf %b", what, rx_ovf));
    if (!rx_full) fail({what, ": rx_full low"});
    for (int i = 0; i < store && i < d.size(); i++)
      if (mbyte(rx_addr, i) !== d[i]) begin fail($sformatf("%s: byte %0d = %h, expected %h", what, i, mbyte(rx_addr, i), d[i])); break; end
    if (store < d.size() && mem.peek(rx_addr + 32'(4 * ((store + 3) / 4))) !== 32'h5A5A_5A5A) fail({what, ": stored past RX_MAX"});
    if (cam_out_q.size() != 0) fail({what, ": message not read to the end"});
  endtask
  // a TS packet of n bytes; returns what came out
  logic [7:0] ts_got [$];
  bit         ts_sop_seen = 0;
  always @(posedge clk) if (ts_out_valid) begin ts_got.push_back(ts_out_data); if (ts_out_sop) ts_sop_seen = 1; end
  task automatic ts_packet(input int n);
    ts_got.delete(); ts_sop_seen = 0;
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      ts_in_valid = 1; ts_in_sop = (i == 0); ts_in_data = (i == 0) ? 8'h47 : 8'(i * 13);
    end
    @(negedge clk); ts_in_valid = 0; ts_in_sop = 0;
    clks(4);
  endtask

  initial begin
    lat_master = "ci_host";
    for (int i = 0; i < 64; i++) cam_attr[2 * i] = 8'(i * 7 + 1);
    cam_attr[0] = 8'h1D; cam_attr[2] = 8'h04;
    clks(3);
    rst_n = 1;
    clks(2);
    // every configuration pin both ways (no card)
    begin
      logic [31:0] k_cis, k_tx, k_rx;
      logic [14:0] k_cor;
      logic [7:0]  k_cv;
      k_cis = cis_addr; k_tx = tx_addr; k_rx = rx_addr; k_cor = cor_addr; k_cv = cor_val;
      wait_max = '1; rst_clks = '1; poll_div = '1; fr_max = '1; cis_addr = '1; cis_len = '1; cor_addr = '1; cor_val = '1;
      tx_addr = '1; tx_len = '1; rx_addr = '1; rx_max = '1; ts_route = 1; poll = 1; setup = '1; hold = '1; strobe = '1;
      clks(3);
      wait_max = '0; rst_clks = '0; poll_div = '0; fr_max = '0; cis_addr = '0; cis_len = '0; cor_addr = '0; cor_val = '0;
      tx_addr = '0; tx_len = '0; rx_addr = '0; rx_max = '0; ts_route = 0; poll = 0; setup = '0; hold = '0; strobe = '0;
      clks(3);
      wait_max = 0; rst_clks = 50; poll_div = 20; fr_max = 0; cis_addr = k_cis; tx_addr = k_tx; rx_addr = k_rx;
      cor_addr = k_cor; cor_val = k_cv; rx_max = 64; setup = 1; hold = 1; strobe = 3;
    end
    // no card: power-on ignored
    enable = 1;
    `PULSE(power_on)
    clks(10);
    if (ci_vcc_en || powered) fail("powered without a card");
    // insertion: DET
    cam_cd_n = 0; clks(4);
    if (n_det != 1 || !present) fail("DET / present on insertion");
    power_up("power-up");
    // CIS read with WAIT# cycles: 10 bytes (a partial last word)
    cam_wait = 6;
    do_cis(10, "CIS read");
    if (cam_cycles != 10) fail($sformatf("%0d bus cycles for a 10-byte CIS", cam_cycles));
    cam_wait = 0;
    // COR write: I/O mode
    begin
      int c0;
      c0 = n_cfg;
      `PULSE(cor_write)
      `WAIT_CNT(n_cfg, c0, 1000, "COR write")
      if (cam_cor !== cor_val || !cam_io || !io_mode) fail("COR not written / no I/O mode");
    end
    // interface reset
    begin
      int c0;
      c0 = n_cfg;
      cam_rs_dly = 100;
      `PULSE(if_reset)
      clks(30);
      if (cam_fr) fail("FR during the interface reset");
      `WAIT_CNT(n_cfg, c0, 5000, "interface reset")
      if (!last_st[6]) fail("LAST_ST without FR after the interface reset");
    end
    // a host-to-module message, setup 0 / hold 0 / strobe 2
    setup = 0; hold = 0; strobe = 2;
    bl = new[7]; bl = '{8'h9F, 8'h80, 8'h10, 8'h01, 8'h02, 8'h03, 8'h04};
    do_tx(bl, 0, "TX");
    setup = 1; hold = 1; strobe = 3;
    // FR taken away once after HC: HC cleared and the transfer started over
    cam_steal = 1;
    bl = new[70];
    foreach (bl[i]) bl[i] = 8'(i * 11 + 3);
    do_tx(bl, 0, "TX with FR taken away");
    if (cam_steal != 0) fail("FR steal not exercised");
    // FR never comes: TX fails after FR_MAX polls
    cam_fr_off = 1; fr_max = 5;
    bl = new[3]; bl = '{8'h01, 8'h02, 8'h03};
    do_tx(bl, 1, "TX without FR");
    cam_fr_off = 0; fr_max = 0;
    if (tx_cnt != 2) fail($sformatf("TX_CNT %0d", tx_cnt));
    // module-to-host messages: polling
    poll = 1;
    bl = new[9]; bl = '{8'h9F, 8'h80, 8'h11, 8'h03, 8'hAA, 8'hBB, 8'hCC, 8'hDD, 8'hEE};
    do_rx(bl, 64, "RX");
    // a second message waits until rx_arm
    begin
      int r0;
      r0 = n_rx;
      bl = new[5]; bl = '{8'h01, 8'h02, 8'h03, 8'h04, 8'h05};
      cam_send(bl);
      clks(2000);
      if (n_rx != r0) fail("RX while the buffer is full");
      `PULSE(rx_arm)
      `WAIT_CNT(n_rx, r0, 100000, "RX after rx_arm")
      clks(2);
      for (int i = 0; i < 5; i++) if (mbyte(rx_addr, i) !== bl[i]) fail("second RX message");
      `PULSE(rx_arm)
    end
    // longer than RX_MAX: the first 8 bytes stored, all of it read
    rx_max = 8;
    bl = new[21];
    foreach (bl[i]) bl[i] = 8'(i * 5 + 1);
    do_rx(bl, 8, "RX over RX_MAX");
    `PULSE(rx_arm)
    rx_max = 64;
    poll = 0;
    if (rx_cnt != 3) fail($sformatf("RX_CNT %0d", rx_cnt));
    // bus timeout: WAIT# longer than WAIT_MAX, bytes read as FF
    begin
      int t0;
      t0 = n_to;
      cam_wait = 200; wait_max = 20;
      cis_len = 2;
      mem.poke(cis_addr, 0);
      t0 = n_cfg;
      `PULSE(cis_read)
      `WAIT_CNT(n_cfg, t0, 5000, "CIS with timeouts")
      t0 = n_to - 2;
      clks(2);
      if (n_to != t0 + 2 || to_cnt != 2) fail($sformatf("%0d timeouts, TO_CNT %0d", n_to - t0, to_cnt));
      if (mem.peek(cis_addr) !== 32'h0000_FFFF) fail($sformatf("timed-out bytes %h", mem.peek(cis_addr)));
      cam_wait = 0; wait_max = 0;
    end
    // AXI errors: a CIS write and a TX read
    begin
      int e0;
      e0 = n_err;
      mem.err_lo = cis_addr; mem.err_hi = cis_addr + 4;
      cis_chk = 0;
      do_cis(3, "CIS with an AXI error");
      cis_chk = 1;
      if (n_err != e0 + 1 || !err) fail("no ERR for a CIS write error");
      mem.err_lo = tx_addr; mem.err_hi = tx_addr + 4;
      bl = new[4]; bl = '{8'h01, 8'h02, 8'h03, 8'h04};
      put_bytes(tx_addr, bl);
      bl = '{8'hEF, 8'hBE, 8'hAD, 8'hDE};           // DEADBEEF goes out
      do_tx(bl, 0, "TX with an AXI error");
      if (n_err != e0 + 2) fail("no ERR for a TX read error");
      mem.err_lo = '1; mem.err_hi = '1;
    end
    // IREQ in I/O mode
    begin
      int q0;
      q0 = n_ireq;
      cam_irq = 1; clks(10); cam_irq = 0; clks(5);
      if (n_ireq != q0 + 1) fail("no IREQ");
    end
    // transport stream: routed through the CAM, then bypassed
    ts_route = 1;
    ts_packet(188);
    if (ts_got.size() != 188 || !ts_sop_seen) fail($sformatf("TS through the CAM: %0d bytes", ts_got.size()));
    else for (int i = 1; i < 188; i++) if (ts_got[i] !== ~8'(i * 13)) begin fail($sformatf("TS byte %0d not from the CAM", i)); break; end
    if (ts_cnt != 1) fail($sformatf("TS_CNT %0d", ts_cnt));
    ts_route = 0;
    ts_packet(188);
    if (ts_got.size() != 188 || ts_got[5] !== 8'(5 * 13)) fail("TS bypass");
    // ---------------- corner cases ----------------
    // polling while the CAM has nothing (STATUS without DA), with the
    // reserved STATUS bits set
    cam_st_x = 6'h3F;
    poll = 1; clks(300); poll = 0; clks(50);
    cam_st_x = 6'h00;
    // a CIS read of 0 bytes ends at once
    begin
      int c0;
      c0 = n_cfg; cis_len = 0;
      `PULSE(cis_read)
      `WAIT_CNT(n_cfg, c0, 1000, "CIS of 0 bytes")
    end
    // an interface reset that never sees FR gives up after FR_MAX polls
    begin
      int c0;
      c0 = n_cfg; cam_fr_off = 1; fr_max = 3;
      `PULSE(if_reset)
      `WAIT_CNT(n_cfg, c0, 20000, "interface reset without FR")
      cam_fr_off = 0; fr_max = 0;
      c0 = n_cfg;
      `PULSE(if_reset)
      `WAIT_CNT(n_cfg, c0, 20000, "interface reset")
    end
    // the slowest bus cycle: SETUP 15, STROBE 255, HOLD 15
    setup = 15; strobe = 255; hold = 15;
    do_cis(2, "CIS, slowest cycles");
    setup = 1; strobe = 3; hold = 1;
    // a TX whose buffer reads are held off: the DATA writes wait
    fork
      begin
        bl = new[9];
        foreach (bl[i]) bl[i] = 8'(i * 3 + 7);
        do_tx(bl, 0, "TX with reads held");
      end
      begin force m_arvalid = 1'b0; clks(800); release m_arvalid; end
    join
    // a CIS and an RX message with the writes held off: the engine's FIFO
    // fills and the bus waits for it
    fork
      do_cis(200, "CIS with writes held");
      begin force m_awvalid = 1'b0; clks(3000); release m_awvalid; end
    join
    rx_max = 255; poll = 1;
    fork
      begin
        bl = new[200];
        foreach (bl[i]) bl[i] = 8'(i * 7 + 2);
        do_rx(bl, 200, "RX with writes held");
      end
      begin force m_awvalid = 1'b0; clks(3000); release m_awvalid; end
    join
    `PULSE(rx_arm)
    // RX_MAX 0: nothing stored; then a 65535-byte message (RX_LEN all ones)
    rx_max = 0;
    bl = new[3]; bl = '{8'h31, 8'h32, 8'h33};
    do_rx(bl, 0, "RX with RX_MAX 0");
    `PULSE(rx_arm)
    rx_max = 8;
    bl = new[65535];
    foreach (bl[i]) bl[i] = 8'($urandom);
    do_rx(bl, 8, "RX of 65535 bytes");
    `PULSE(rx_arm)
    rx_max = 64; poll = 0;
    // the top of the address space: a CIS, a TX and an RX
    cis_addr = 32'hFFFF_F000; tx_addr = 32'hFFFF_E000; rx_addr = 32'hFFFF_D000;
    do_cis(8, "CIS at the top");
    bl = new[5]; bl = '{8'h11, 8'h22, 8'h33, 8'h44, 8'h55};
    do_tx(bl, 0, "TX at the top");
    poll = 1;
    do_rx(bl, 64, "RX at the top");
    `PULSE(rx_arm)
    poll = 0;
    cis_addr = 32'h0010_0000; tx_addr = 32'h0020_0000; rx_addr = 32'h0030_0000;
    // power off during a CIS read that saw an AXI error: the job is flushed,
    // ERR set; then during an RX message
    begin
      mem.err_lo = cis_addr; mem.err_hi = cis_addr + 4;
      cis_len = 100;
      `PULSE(cis_read)
      clks(400);
      `PULSE(power_off)
      clks(400);
      if (busy || !err || ci_vcc_en) fail("power-off during a CIS read");
      mem.err_lo = '1; mem.err_hi = '1;
      power_up("power-up after the CIS abort");
      begin
        int c0;
        c0 = n_cfg;
        `PULSE(cor_write)
        `WAIT_CNT(n_cfg, c0, 1000, "COR write")
        c0 = n_cfg;
        `PULSE(if_reset)
        `WAIT_CNT(n_cfg, c0, 20000, "interface reset")
      end
      bl = new[120];
      foreach (bl[i]) bl[i] = 8'(i);
      cam_send(bl);
      poll = 1;
      clks(400);
      `PULSE(power_off)
      clks(400);
      poll = 0;
      if (busy || ci_vcc_en) fail("power-off during an RX message");
      cam_out_q.delete(); cam_pend.delete(); cam_pend_n.delete();
      power_up("power-up after the RX abort");
      begin
        int c0;
        c0 = n_cfg;
        `PULSE(cor_write)
        `WAIT_CNT(n_cfg, c0, 1000, "COR write")
        c0 = n_cfg;
        `PULSE(if_reset)
        `WAIT_CNT(n_cfg, c0, 20000, "interface reset")
      end
    end
    // (long runs: +cov_long, coverage only) 65540 one-byte TX and RX
    // messages, 65540 bus timeouts and 65540 TS packets through the CAM:
    // every count saturates; the reset at the end clears them
    if ($test$plusargs("cov_long")) begin
      poll_div = 0;
      bl = new[1];
      for (int i = 0; i < 65540; i++) begin bl[0] = 8'($urandom); do_tx(bl, 0, "TX run"); end
      poll = 1;
      for (int i = 0; i < 65540; i++) begin bl[0] = 8'($urandom); do_rx(bl, 64, "RX run"); `PULSE(rx_arm) end
      poll = 0;
      cam_wait = 100; wait_max = 1; cis_chk = 0;
      do_cis(65535, "timeout run"); do_cis(8, "timeout run");
      cam_wait = 0; wait_max = 0; cis_chk = 1;
      ts_route = 1;
      for (int i = 0; i < 65540; i++) begin
        @(negedge clk); ts_in_valid = 1; ts_in_sop = 1; ts_in_data = 8'($urandom);
      end
      @(negedge clk); ts_in_valid = 0; ts_in_sop = 0;
      clks(6);
      ts_route = 0; poll_div = 20;
      if (tx_cnt != 16'hFFFF || rx_cnt != 16'hFFFF || to_cnt != 16'hFFFF || ts_cnt != 16'hFFFF)
        fail($sformatf("counter runs: TX %0d RX %0d TO %0d TS %0d", tx_cnt, rx_cnt, to_cnt, ts_cnt));
    end
    // card removal during a TX: the DMA is flushed, tx_fail
    begin
      int t0;
      bl = new[200];
      foreach (bl[i]) bl[i] = 8'(i);
      put_bytes(tx_addr, bl);
      tx_len = 200;
      t0 = n_txd;
      `PULSE(tx_start)
      clks(300);
      cam_cd_n = 1;
      `WAIT_CNT(n_txd, t0, 5000, "TX ended by the removal")
      clks(10);
      if (!tx_fail || ci_vcc_en || io_mode || busy) fail("removal during a TX");
      if (dut.e_busy) fail("DMA not flushed");
    end
    // re-insert, power up, CIS: the DMA still works
    cam_cd_n = 0; clks(4);
    power_up("power-up after removal");
    do_cis(17, "CIS after removal");
    // power-off command
    `PULSE(power_off)
    clks(2);
    if (ci_vcc_en || ready) fail("power-off");
    // reset during a CIS read
    power_up("power-up before reset");
    cis_len = 40;
    `PULSE(cis_read)
    clks(100);
    rst_n = 0;
    clks(2);
    if (ci_vcc_en || !ci_ce_n || m_awvalid || m_arvalid) fail("not idle in reset");
    rst_n = 1;
    clks(5);
    power_up("power-up after reset");
    do_cis(5, "CIS after reset");
    errors += cam_errors;
    lat_summary();
    finish("CI_Plus_Host");
  end
  initial begin
    #2s;
    $display("TEST FAILED: CI_Plus_Host (timeout)");
    $finish;
  end
endmodule
