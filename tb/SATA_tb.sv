// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for SATA_top -- SystemVerilog
// Loopback (tx_p -> rx_p). Drives DUT host command hold-registers through
// hierarchical references (dut.host_req/...), checks OOB link-up, IDENTIFY,
// sector-buffer write/readback, CRC error injection and link recovery.
// -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module SATA_tb;
  logic clk = 0, rst_n = 0, refclk = 0;
  logic tx_n, tx_p, rx_n, rx_p, irq;
  logic inj = 0;               // loopback corrupt enable (1 clk = 1 bit flip)
  int   errors = 0;
  int   irq_cnt = 0;

  SATA_top dut (
    .clk(clk), .rst_n(rst_n),
    .tx_n(tx_n), .tx_p(tx_p),
    .rx_n(rx_n), .rx_p(rx_p),
    .refclk(refclk), .irq(irq)
  );

  assign rx_p = inj ? ~tx_p : tx_p;   // loopback with injection point
  assign rx_n = tx_n;

  always #5 clk    = ~clk;
  always #7 refclk = ~refclk;

  // irq pulse counter
  always @(posedge clk) if (irq) irq_cnt <= irq_cnt + 1;

  // expected IDENTIFY device info dword k (mirrors RTL ident_dw)
  function automatic logic [31:0] ident_exp(input int k);
    ident_exp = {8'hEC, 8'h5A, k[7:0], ~k[7:0]};
  endfunction

  // IDENTIFY data-frame monitor: checks every D2H data FIS as it is captured
  logic ident_mon = 0;
  always @(posedge clk) begin
    if (dut.hseen && ident_mon) begin
      for (int j = 0; j < 4; j++) begin
        logic [31:0] got;
        case (j)
          0:       got = dut.hrd0;
          1:       got = dut.hrd1;
          2:       got = dut.hrd2;
          default: got = dut.hrd3;
        endcase
        if (got !== ident_exp(dut.hseq * 4 + j)) begin
          errors++;
          $display("ERROR: IDENTIFY dword %0d got=%h exp=%h",
                   dut.hseq * 4 + j, got, ident_exp(dut.hseq * 4 + j));
        end
      end
    end
  end

  // issue one host command and wait for completion handshake
  task automatic sata_cmd(input logic [7:0]  cmd, input logic [5:0] lba,
                          input logic [31:0] w0, w1, w2, w3);
    begin
      @(negedge clk);
      dut.host_cmd = cmd; dut.host_lba = lba;
      dut.hw0 = w0; dut.hw1 = w1; dut.hw2 = w2; dut.hw3 = w3;
      dut.host_req = 1'b1;
      wait (dut.host_done === 1'b1);
      @(negedge clk);
      dut.host_req = 1'b0;
      wait (dut.host_done === 1'b0);
    end
  endtask

  task automatic check_status(input logic [7:0] exp_sts, input string tag);
    if (dut.host_status !== exp_sts || dut.host_errf !== 1'b0) begin
      errors++;
      $display("ERROR: %s status got=%h errf=%b exp=%h",
               tag, dut.host_status, dut.host_errf, exp_sts);
    end
  endtask

  task automatic check_rd(input logic [31:0] e0, e1, e2, e3, input string tag);
    if (dut.hrd0 !== e0 || dut.hrd1 !== e1 ||
        dut.hrd2 !== e2 || dut.hrd3 !== e3) begin
      errors++;
      $display("ERROR: %s readback got=%h %h %h %h exp=%h %h %h %h", tag,
               dut.hrd0, dut.hrd1, dut.hrd2, dut.hrd3, e0, e1, e2, e3);
    end
  endtask

  initial begin
    int irq_before;
    rst_n = 0; repeat (10) @(posedge clk);
    rst_n = 1;

    // (a) post-reset initial state: link down, no irq
    repeat (20) @(posedge clk);
    if (dut.link_ready !== 1'b0) begin
      errors++;
      $display("ERROR: link_ready high right after reset");
    end
    if (irq_cnt != 0) begin
      errors++;
      $display("ERROR: irq asserted during reset/OOB start");
    end

    // OOB sequence: COMRESET -> COMINIT -> COMWAKE -> COMWAKE -> ALIGNp
    wait (dut.link_ready === 1'b1);
    repeat (10) @(posedge clk);
    $display("INFO: OOB complete, LINK READY at t=%0t", $time);
    if (irq_cnt != 0) begin
      errors++;
      $display("ERROR: irq asserted during link bring-up");
    end

    // (b1) IDENTIFY full path: 16 dwords in 4 data FIS frames + status
    ident_mon = 1;
    sata_cmd(8'hEC, 6'd0, 32'h0, 32'h0, 32'h0, 32'h0);
    ident_mon = 0;
    check_status(8'h50, "IDENTIFY");
    if (dut.hnd !== 6'd16) begin
      errors++;
      $display("ERROR: IDENTIFY dword count got=%0d exp=16", dut.hnd);
    end

    // (b2)+(d) sector buffer write -> read back, round 1 (lba 8)
    sata_cmd(8'h35, 6'd8, 32'h1111_0001, 32'h2222_0002,
                          32'h3333_0003, 32'h4444_0004);
    check_status(8'h50, "WRITE DMA r1");
    sata_cmd(8'h25, 6'd8, 32'h0, 32'h0, 32'h0, 32'h0);
    check_status(8'h50, "READ DMA r1");
    check_rd(32'h1111_0001, 32'h2222_0002, 32'h3333_0003, 32'h4444_0004,
             "round1");

    // (d) round 2 (lba 40): link idle -> re-issue back to back
    sata_cmd(8'h35, 6'd40, 32'hCAFE_0001, 32'hCAFE_0002,
                           32'hCAFE_0003, 32'hCAFE_0004);
    check_status(8'h50, "WRITE DMA r2");
    sata_cmd(8'h25, 6'd40, 32'h0, 32'h0, 32'h0, 32'h0);
    check_status(8'h50, "READ DMA r2");
    check_rd(32'hCAFE_0001, 32'hCAFE_0002, 32'hCAFE_0003, 32'hCAFE_0004,
             "round2");

    // seed lba 16 with known data
    sata_cmd(8'h35, 6'd16, 32'h5EED_0001, 32'h5EED_0002,
                           32'h5EED_0003, 32'h5EED_0004);
    check_status(8'h50, "WRITE DMA seed");

    // (c) CRC error injection: flip one payload bit of the write-command
    // FIS on the loopback path. DUT must drop the frame, raise irq and
    // time out the host command; the sector buffer must stay unpolluted.
    irq_before = irq_cnt;
    fork
      begin : inj_proc
        wait (dut.tx_busy === 1'b1 && dut.tx_widx == 3'd2 &&
              dut.tx_bitcnt == 6'd12);
        @(negedge clk); inj = 1'b1;
        @(negedge clk); inj = 1'b0;
      end
      begin : cmd_proc
        sata_cmd(8'h35, 6'd16, 32'hDEAD_0001, 32'hDEAD_0002,
                               32'hDEAD_0003, 32'hDEAD_0004);
      end
    join
    if (irq_cnt == irq_before) begin
      errors++;
      $display("ERROR: CRC injection did not raise irq");
    end
    if (dut.host_errf !== 1'b1) begin
      errors++;
      $display("ERROR: poisoned write was not reported as failed");
    end

    // unpolluted check + link recovery: read lba 16 must return seed data
    sata_cmd(8'h25, 6'd16, 32'h0, 32'h0, 32'h0, 32'h0);
    check_status(8'h50, "READ DMA unpolluted");
    check_rd(32'h5EED_0001, 32'h5EED_0002, 32'h5EED_0003, 32'h5EED_0004,
             "unpolluted");

    // link fully recovered: successful write/read after the error
    sata_cmd(8'h35, 6'd16, 32'hFACE_0001, 32'hFACE_0002,
                           32'hFACE_0003, 32'hFACE_0004);
    check_status(8'h50, "WRITE DMA recovery");
    sata_cmd(8'h25, 6'd16, 32'h0, 32'h0, 32'h0, 32'h0);
    check_status(8'h50, "READ DMA recovery");
    check_rd(32'hFACE_0001, 32'hFACE_0002, 32'hFACE_0003, 32'hFACE_0004,
             "recovery");

    if (errors == 0) $display("TEST PASSED: SATA");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
