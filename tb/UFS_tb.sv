// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for UFS_top -- SystemVerilog
// Exercises: link training handshake, TEST UNIT READY, WRITE10 -> READ10
// readback compare, CRC error injection (frame dropped + storage unchanged),
// unknown-opcode injection (sense/status error + irq), repeat transactions.
// Open IP design implementation v2.4
// -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module UFS_tb;
  localparam logic [31:0] SOF   = 32'h5546_5301;
  localparam logic [31:0] EOFR  = 32'h5546_5302;
  localparam logic [31:0] TRAIN = 32'hBC3C_5A5A;

  logic clk = 0, rst_n = 0, refclk = 0;
  logic tx_n, tx_p, rx_n, rx_p, irq;
  int   errors = 0;
  logic irq_seen = 0, tx_act = 0;

  logic [31:0] tpay [0:7];       // frame payload to transmit
  logic [31:0] rpay [0:7];       // received frame payload
  logic [31:0] wdata [0:3];      // WRITE10 data pattern
  logic [31:0] tb_crc, rcrc, rhdr;
  logic [7:0]  rlen;

  UFS_top dut (
    .clk(clk), .rst_n(rst_n),
    .tx_n(tx_n), .tx_p(tx_p), .rx_n(rx_n), .rx_p(rx_p),
    .refclk(refclk), .irq(irq)
  );

  always #5 clk = ~clk;
  always #3 refclk = ~refclk;

  // monitors: latch irq pulses and any TX activity
  always @(posedge clk) begin
    if (irq)            irq_seen <= 1'b1;
    if (tx_p === 1'b0)  tx_act   <= 1'b1;
  end

  // ------------------------ helpers ------------------------
  function automatic logic [31:0] crc_step(input logic [31:0] c, input logic b);
    logic fb;
    begin
      fb       = c[0] ^ b;
      crc_step = (c >> 1) ^ (fb ? 32'hEDB8_8320 : 32'h0000_0000);
    end
  endfunction

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s", msg);
    end
  endtask

  task automatic send_word(input logic [31:0] wd, input bit upd);
    for (int i = 31; i >= 0; i--) begin
      @(negedge clk); rx_p = wd[i]; rx_n = ~wd[i];
      if (upd) tb_crc = crc_step(tb_crc, wd[i]);
    end
  endtask

  // send one UniPro frame: SOF HDR payload[0..n-1] CRC32 EOF
  task automatic send_frame(input logic [7:0] ftype, input logic [7:0] tt,
                            input logic [7:0] lun, input logic [7:0] n,
                            input bit corrupt);
    logic [31:0] c;
    begin
      send_word(SOF, 0);
      tb_crc = 32'hFFFF_FFFF;
      send_word({ftype, tt, lun, n}, 1);
      for (int i = 0; i < n; i++) send_word(tpay[i], 1);
      c = tb_crc ^ 32'hFFFF_FFFF;
      if (corrupt) c = c ^ 32'h0000_0001;
      send_word(c, 0);
      send_word(EOFR, 0);
      @(negedge clk); rx_p = 1'b1; rx_n = 1'b0;   // back to idle
    end
  endtask

  task automatic recv_word(output logic [31:0] wd);
    for (int i = 31; i >= 0; i--) begin
      @(posedge clk); #1; wd[i] = tx_p;
    end
  endtask

  // bit-level scan for SOF so dword alignment is recovered
  task automatic wait_sof;
    logic [31:0] s; int cnt;
    begin
      s = 32'hFFFF_FFFF; cnt = 0;
      while ((s !== SOF) && (cnt < 4000)) begin
        @(posedge clk); #1; s = {s[30:0], tx_p}; cnt++;
      end
      if (s !== SOF) begin
        errors++;
        $display("ERROR: timeout waiting for response SOF");
      end
    end
  endtask

  // receive one frame into rhdr/rpay, verify CRC32 and EOF
  task automatic recv_frame(output logic [31:0] hdr);
    logic [31:0] w; logic [31:0] c; logic [31:0] tmp;
    begin
      wait_sof();
      recv_word(hdr);
      c = 32'hFFFF_FFFF;
      for (int i = 31; i >= 0; i--) c = crc_step(c, hdr[i]);
      rlen = hdr[7:0];
      if (rlen > 8) begin
        errors++;
        $display("ERROR: response len %0d out of range", rlen);
      end else begin
        for (int i = 0; i < rlen; i++) begin
          // NB: recv into a temp first -- Icarus vvp crashes when an unpacked
          // array element is passed directly as a task output argument.
          recv_word(tmp);
          rpay[i] = tmp;
          for (int j = 31; j >= 0; j--) c = crc_step(c, tmp[j]);
        end
      end
      recv_word(rcrc);
      check(rcrc === (c ^ 32'hFFFF_FFFF), "response CRC32 mismatch");
      recv_word(w);
      check(w === EOFR, "response EOF marker mismatch");
    end
  endtask

  task automatic wait_linkup;
    int cnt;
    begin
      cnt = 0;
      while ((dut.link_up !== 1'b1) && (cnt < 6000)) begin
        @(posedge clk); cnt++;
      end
    end
  endtask

  // build CDB payload and send a COMMAND UPIU; WRITE10 data from wdata[]
  task automatic ufs_cmd(input logic [7:0] op, input logic [23:0] lba,
                         input logic [7:0] n, input logic [7:0] tt,
                         input bit corrupt);
    begin
      tpay[0] = {op, lba};
      tpay[1] = {n, 24'h0};
      tpay[2] = 32'h0;
      tpay[3] = 32'h0;
      if (op == 8'h2A)
        for (int i = 0; i < n; i++) tpay[4+i] = wdata[i];
      send_frame(8'h01, tt, 8'h00, (op == 8'h2A) ? (8'd4 + n) : 8'd4, corrupt);
    end
  endtask

  task automatic expect_resp(input logic [7:0] tt, input logic [31:0] exp_p0);
    begin
      recv_frame(rhdr);
      check(rhdr[31:24] === 8'h81, "RESPONSE UPIU type mismatch");
      check(rhdr[23:16] === tt,    "RESPONSE task tag not echoed");
      check(rpay[0] === exp_p0,    "RESPONSE status/sense mismatch");
    end
  endtask

  // ------------------------ stimulus ------------------------
  initial begin
    rx_p = 1'b1; rx_n = 1'b0;
    rst_n = 0;
    repeat (8) @(posedge clk);
    // (a) reset / initial state
    check(irq === 1'b0,          "irq asserted during reset");
    check(tx_p === 1'b1,         "tx_p not idle during reset");
    check(dut.link_up === 1'b0,  "link_up asserted before training");
    rst_n = 1;

    // link training: host (DUT) emits TRAIN bursts, peer (TB) answers
    repeat (350) @(posedge clk);
    for (int r = 0; r < 4; r++) send_word(TRAIN, 0);
    @(negedge clk); rx_p = 1'b1; rx_n = 1'b0;
    wait_linkup();
    check(dut.link_up === 1'b1, "LINKUP not reached after training exchange");
    repeat (20) @(posedge clk);

    // (b1) TEST UNIT READY
    ufs_cmd(8'h00, 24'h0, 8'd0, 8'h01, 1'b0);
    expect_resp(8'h01, 32'h0000_0000);

    // (b2) WRITE10: 4 dwords at LBA 16
    wdata[0] = 32'hDEAD_BEEF; wdata[1] = 32'h1234_5678;
    wdata[2] = 32'hCAFE_F00D; wdata[3] = 32'h0BAD_5EED;
    ufs_cmd(8'h2A, 24'd16, 8'd4, 8'h02, 1'b0);
    expect_resp(8'h02, 32'h0000_0000);

    // (b3) READ10 readback + data compare
    ufs_cmd(8'h28, 24'd16, 8'd4, 8'h03, 1'b0);
    expect_resp(8'h03, 32'h0000_0000);
    recv_frame(rhdr);
    check(rhdr[31:24] === 8'h02, "READ10 not followed by DATA UPIU");
    check(rhdr[7:0]   === 8'd4,  "DATA UPIU length mismatch");
    for (int i = 0; i < 4; i++)
      check(rpay[i] === wdata[i], "READ10 readback data mismatch");

    // (c1) CRC error injection: corrupted WRITE10 must be dropped + irq
    wdata[0] = 32'hFFFF_0000; wdata[1] = 32'hFFFF_1111;
    wdata[2] = 32'hFFFF_2222; wdata[3] = 32'hFFFF_3333;
    irq_seen = 0;
    ufs_cmd(8'h2A, 24'd16, 8'd4, 8'h04, 1'b1);
    tx_act = 0;
    repeat (600) @(posedge clk);             // a response would take ~160 clk
    check(irq_seen === 1'b1, "no irq on CRC-corrupted frame");
    check(tx_act   === 1'b0, "DUT transmitted after CRC-corrupted frame");

    // storage must be unchanged: read back the original pattern
    ufs_cmd(8'h28, 24'd16, 8'd4, 8'h05, 1'b0);
    expect_resp(8'h05, 32'h0000_0000);
    recv_frame(rhdr);
    check(rhdr[31:24] === 8'h02, "no DATA UPIU after CRC-injection READ10");
    check(rpay[0] === 32'hDEAD_BEEF, "storage corrupted by bad-CRC WRITE10 [0]");
    check(rpay[1] === 32'h1234_5678, "storage corrupted by bad-CRC WRITE10 [1]");
    check(rpay[2] === 32'hCAFE_F00D, "storage corrupted by bad-CRC WRITE10 [2]");
    check(rpay[3] === 32'h0BAD_5EED, "storage corrupted by bad-CRC WRITE10 [3]");

    // (c2) unknown opcode injection: error RESPONSE (sense!=0) + irq
    irq_seen = 0;
    ufs_cmd(8'hFF, 24'h0, 8'd0, 8'h06, 1'b0);
    recv_frame(rhdr);
    check(rhdr[31:24] === 8'h81,      "unknown opcode: no RESPONSE UPIU");
    check(rpay[0][15:0]  !== 16'h0000, "unknown opcode: status not error");
    check(rpay[0][31:16] !== 16'h0000, "unknown opcode: sense is zero");
    check(irq_seen === 1'b1,           "no irq on unknown opcode");

    // (d) link still healthy: second WRITE10/READ10 pair, LBA 64, 2 dwords
    wdata[0] = 32'hAAAA_5555; wdata[1] = 32'h5555_AAAA;
    ufs_cmd(8'h2A, 24'd64, 8'd2, 8'h07, 1'b0);
    expect_resp(8'h07, 32'h0000_0000);
    ufs_cmd(8'h28, 24'd64, 8'd2, 8'h08, 1'b0);
    expect_resp(8'h08, 32'h0000_0000);
    recv_frame(rhdr);
    check(rhdr[31:24] === 8'h02 && rhdr[7:0] === 8'd2, "2nd DATA UPIU header bad");
    check(rpay[0] === 32'hAAAA_5555, "2nd readback mismatch [0]");
    check(rpay[1] === 32'h5555_AAAA, "2nd readback mismatch [1]");

    if (errors == 0) $display("TEST PASSED: UFS");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
