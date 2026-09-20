// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking loopback testbench for SAS_top -- SystemVerilog
// OOB completion -> register write/read loopback compare -> CRC error
// injection (1 payload bit flip) -> post-error link recovery.
// -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module SAS_tb;
  logic clk = 0, rst_n = 0, refclk = 0;
  logic tx_n, tx_p, rx_n, rx_p, irq;
  logic corrupt = 1'b0;          // 1-clk loopback bit flip (error injection)
  int   errors = 0;
  int   irq_cnt = 0;

  SAS_top dut (
    .clk(clk), .rst_n(rst_n),
    .tx_n(tx_n), .tx_p(tx_p),
    .rx_n(rx_n), .rx_p(rx_p),
    .refclk(refclk), .irq(irq)
  );

  always #5 clk    = ~clk;
  always #3 refclk = ~refclk;

  // direct loopback with injectable corruption on rx_p
  assign rx_p = tx_p ^ corrupt;
  assign rx_n = tx_n;

  always @(posedge clk) if (rst_n && irq) irq_cnt++;

  // -------- scoreboard model of the DUT initiator sequencer -----------------
  // txn n writes reg[n % 16] with 32'h5A5A_0000 + n*32'h0001_0101
  function automatic logic [31:0] exp_data(input int n);
    return 32'h5A5A_0000 + n * 32'h0001_0101;
  endfunction

  int  wr_evt_cnt = 0;
  logic inj_started = 1'b0;      // stop exact model checks once injecting
  always @(posedge clk) begin
    if (rst_n && dut.wr_evt && !inj_started) begin
      if (dut.wr_data !== exp_data(wr_evt_cnt)) begin
        errors++;
        $display("ERROR: write txn %0d data got=%h exp=%h",
                 wr_evt_cnt, dut.wr_data, exp_data(wr_evt_cnt));
      end
      if (dut.wr_addr !== (wr_evt_cnt % 16)) begin
        errors++;
        $display("ERROR: write txn %0d addr got=%0d exp=%0d",
                 wr_evt_cnt, dut.wr_addr, wr_evt_cnt % 16);
      end
      wr_evt_cnt++;
    end
  end

  // -------- CRC error injection: flip 1 payload bit of a write frame --------
  logic       armed = 1'b0, inj_fired = 1'b0;
  logic [3:0]  inj_addr = 4'd0;
  logic [31:0] inj_old  = 32'd0;
  always @(negedge clk) begin
    corrupt <= 1'b0;
    if (armed && dut.tx_pay_active && dut.cur_is_write &&
        (dut.tx_bit_cnt == 6'd10)) begin
      corrupt   <= 1'b1;         // corrupts the bit sampled next posedge
      armed     <= 1'b0;
      inj_fired <= 1'b1;
      inj_addr  <= dut.f_dst[3:0];
      inj_old   <= dut.regs[dut.f_dst[3:0]];
    end
  end

  int t;
  int ok_before;
  int irq_before;

  initial begin
    // (a) reset / initial state
    rst_n = 0; repeat (10) @(posedge clk);
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: irq high during reset");
    end
    if (tx_p !== 1'b0) begin
      errors++; $display("ERROR: tx_p not idle during reset");
    end
    if (dut.phy_ready !== 1'b0) begin
      errors++; $display("ERROR: phy_ready high right after reset");
    end
    rst_n = 1;

    // (a2) OOB handshake must complete -> PHY READY
    t = 0;
    while (!dut.phy_ready && t < 3000) begin @(posedge clk); t++; end
    if (!dut.phy_ready) begin
      errors++; $display("ERROR: OOB sequence did not reach PHY READY");
    end else begin
      $display("INFO: OOB complete, PHY READY after %0d clks", t);
    end
    if (irq_cnt != 0) begin
      errors++; $display("ERROR: irq during OOB/link bring-up");
    end

    // (b) >= 4 successful register write + read-verify loopback transactions
    t = 0;
    while (dut.ok_cnt < 4 && t < 8000) begin @(posedge clk); t++; end
    if (dut.ok_cnt < 4) begin
      errors++; $display("ERROR: fewer than 4 verified write/read transactions");
    end
    if (wr_evt_cnt < 4) begin
      errors++; $display("ERROR: fewer than 4 write events observed (%0d)",
                         wr_evt_cnt);
    end
    // read back register file and compare against model (txns 0..3 -> addr 0..3)
    for (int a = 0; a < 4; a++) begin
      if (dut.regs[a] !== exp_data(a)) begin
        errors++;
        $display("ERROR: regfile[%0d] got=%h exp=%h", a, dut.regs[a], exp_data(a));
      end
    end
    $display("INFO: %0d write/read loopback transactions verified", dut.ok_cnt);

    // (c) CRC error injection on the next write frame payload
    inj_started = 1'b1;
    armed       = 1'b1;
    irq_before  = irq_cnt;
    ok_before   = dut.ok_cnt;
    t = 0;
    while (!inj_fired && t < 4000) begin @(posedge clk); t++; end
    if (!inj_fired) begin
      errors++; $display("ERROR: injection window never occurred");
    end
    // DUT must flag the corrupted frame
    t = 0;
    while (irq_cnt == irq_before && t < 600) begin @(posedge clk); t++; end
    if (irq_cnt == irq_before) begin
      errors++; $display("ERROR: no irq after CRC error injection");
    end
    if (dut.crc_err_cnt < 1) begin
      errors++; $display("ERROR: crc_err_cnt did not increment");
    end
    repeat (60) @(posedge clk);
    // corrupted write must have been discarded: register not polluted
    if (dut.regs[inj_addr] !== inj_old) begin
      errors++;
      $display("ERROR: regfile[%0d] polluted by bad-CRC frame: got=%h exp=%h",
               inj_addr, dut.regs[inj_addr], inj_old);
    end

    // (d) link must keep working after the error
    t = 0;
    while (dut.ok_cnt < ok_before + 2 && t < 8000) begin @(posedge clk); t++; end
    if (dut.ok_cnt < ok_before + 2) begin
      errors++; $display("ERROR: link did not recover after CRC error");
    end
    // the stale read-back of the dropped write must be caught by the verifier
    if (dut.mm_cnt < 1) begin
      errors++; $display("ERROR: read-verify mismatch of dropped write not caught");
    end
    $display("INFO: post-error link alive, ok_cnt=%0d mm_cnt=%0d crc_err=%0d",
             dut.ok_cnt, dut.mm_cnt, dut.crc_err_cnt);

    if (errors == 0) $display("TEST PASSED: SAS");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #2000000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
