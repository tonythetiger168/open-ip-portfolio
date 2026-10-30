// SPDX-License-Identifier: Apache-2.0
// IP part of UFS_apb_tb: the link partner of the core TB (training answer,
// COMMAND UPIUs sent bit-serially on rx_p, every RESPONSE / DATA UPIU checked
// for CRC-32, EOF, task tag, status / sense and data against a shadow of the
// LUN0 medium). Training timeout and a bad training dword, TEST UNIT READY,
// WRITE10 / READ10, CRC and EOF errors, illegal commands, a command while
// busy and random traffic, each error checked in IRQ_STATUS.ERR (masked and
// on the irq pin); PRESETN mid-response and retraining.
  localparam logic [31:0] SOF   = 32'h5546_5301;
  localparam logic [31:0] EOFR  = 32'h5546_5302;
  localparam logic [31:0] TRAIN = 32'hBC3C_5A5A;
  localparam int bc = 1;
  initial begin rx_p = 1'b1; rx_n = 1'b0; refclk = 0; end
  always #3 refclk = ~refclk;
  logic irq_seen = 0, tx_act = 0;
  logic [31:0] tpay [0:7];
  logic [31:0] rpay [0:7];
  logic [31:0] wdata [0:3];
  logic [31:0] shadow [0:255];
  logic [31:0] tb_crc, rcrc, rhdr;
  logic [7:0]  rlen;
  always @(posedge PCLK) begin
    if (dut.c_irq)      irq_seen <= 1'b1;
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
      $display("ERROR: %s @%0t", msg, $time);
    end
  endtask

  task automatic send_word(input logic [31:0] wd, input bit upd);
    for (int i = 31; i >= 0; i--) begin
      @(negedge PCLK); rx_p = wd[i]; rx_n = ~wd[i];
      repeat (bc - 1) @(negedge PCLK);
      if (upd) tb_crc = crc_step(tb_crc, wd[i]);
    end
  endtask

  task automatic line_idle;
    begin @(negedge PCLK); rx_p = 1'b1; rx_n = 1'b0; end
  endtask

  // send one frame: SOF HDR payload[0..n-1] CRC32 EOF (n words of tpay)
  task automatic send_raw(input logic [31:0] hdr, input int n, input bit corrupt, input bit bad_eof);
    logic [31:0] c;
    begin
      send_word(SOF, 0);
      tb_crc = 32'hFFFF_FFFF;
      send_word(hdr, 1);
      for (int i = 0; i < n; i++) send_word(tpay[i], 1);
      c = tb_crc ^ 32'hFFFF_FFFF;
      if (corrupt) c = c ^ 32'h0000_0001;
      send_word(c, 0);
      send_word(bad_eof ? 32'h5546_5303 : EOFR, 0);
      line_idle();
    end
  endtask

  task automatic recv_word(output logic [31:0] wd);
    for (int i = 31; i >= 0; i--) begin
      repeat (bc) @(posedge PCLK); #1; wd[i] = tx_p;
    end
  endtask

  // bit-level scan for SOF so dword alignment is recovered
  task automatic wait_sof;
    logic [31:0] s; int cnt;
    begin
      s = 32'hFFFF_FFFF; cnt = 0;
      while ((s !== SOF) && (cnt < 4000)) begin
        repeat (bc) @(posedge PCLK); #1; s = {s[30:0], tx_p}; cnt++;
      end
      if (s !== SOF) begin
        errors++;
        $display("ERROR: timeout waiting for response SOF @%0t", $time);
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

  // wait for the DUT to listen for the training answer, then answer
  task automatic train(input bit bad_second);
    int cnt;
    begin
      cnt = 0;
      while (dut.u_core.lp_state !== 2'd2 && cnt < 20000) begin @(posedge PCLK); cnt++; end
      repeat (40) @(posedge PCLK);
      send_word(TRAIN, 0);
      send_word(bad_second ? 32'hBC3C_5A5B : TRAIN, 0);
      line_idle();
      repeat (4) @(posedge PCLK);
      if (!bad_second) check(dut.u_core.link_up === 1'b1, "LINKUP not reached after training exchange");
      else             check(dut.u_core.link_up === 1'b0, "LINKUP on a bad second training dword");
    end
  endtask

  // COMMAND UPIU: CDB = {op, lba}, {xfer, 0}; WRITE10 data from wdata[]
  task automatic cmd_raw(input logic [7:0] op, input logic [23:0] lba, input logic [7:0] xfer,
                         input logic [7:0] tt, input logic [7:0] lun, input int ndat,
                         input bit corrupt);
    begin
      tpay[0] = {op, lba};
      tpay[1] = {xfer, 24'($urandom)};       // reserved CDB fields: ignored
      tpay[2] = $urandom;
      tpay[3] = $urandom;
      for (int i = 0; i < ndat; i++) tpay[4+i] = wdata[i];
      send_raw({8'h01, tt, lun, 8'(4 + ndat)}, 4 + ndat, corrupt, 0);
    end
  endtask

  task automatic expect_resp(input logic [7:0] tt, input bit good);
    begin
      recv_frame(rhdr);
      check(rhdr === {8'h81, tt, 8'h00, 8'd1} || (!good && rhdr[31:24] === 8'h81 && rhdr[23:16] === tt),
            "RESPONSE UPIU header");
      check(rpay[0] === (good ? 32'h0 : 32'h0005_0001), "RESPONSE status/sense");
    end
  endtask

  // no frame may follow (dropped command)
  task automatic expect_silent(input string what);
    begin
      repeat (2) @(posedge PCLK);             // let the last EOF bit go by
      tx_act = 0;
      repeat (300) @(posedge PCLK);
      check(tx_act === 1'b0, {what, ": DUT responded"});
    end
  endtask

  task automatic write10(input int lba, input int n, input logic [7:0] tt);
    begin
      irq_seen = 0;
      cmd_raw(8'h2A, 24'(lba), 8'(n), tt, 8'h00, n, 0);
      expect_resp(tt, 1);
      for (int j = 0; j < n; j++) shadow[lba + j] = wdata[j];
      check(irq_seen === 1'b0, "irq on a good WRITE10");
    end
  endtask

  task automatic read10(input int lba, input int n, input logic [7:0] tt);
    begin
      cmd_raw(8'h28, 24'(lba), 8'(n), tt, 8'h00, 0, 0);
      expect_resp(tt, 1);
      recv_frame(rhdr);
      check(rhdr === {8'h02, tt, 8'h00, 8'(n)}, "DATA UPIU header");
      for (int j = 0; j < n; j++)
        if (rpay[j] !== shadow[lba + j]) begin
          errors++; $display("ERROR: READ10 lba %0d+%0d got %h exp %h", lba, j, rpay[j], shadow[lba + j]);
        end
    end
  endtask

  // a command answered with CHECK CONDITION / ILLEGAL REQUEST + irq
  task automatic illegal(input logic [7:0] op, input logic [23:0] lba, input logic [7:0] xfer,
                         input logic [7:0] lun, input int ndat, input string what);
    begin
      irq_seen = 0;
      cmd_raw(op, lba, xfer, 8'h5C, lun, ndat, 0);
      recv_frame(rhdr);
      check(rhdr === {8'h81, 8'h5C, lun, 8'd1}, {what, ": RESPONSE header"});
      check(rpay[0] === 32'h0005_0001, {what, ": not CHECK / ILLEGAL REQUEST"});
      check(irq_seen === 1'b1, {what, ": no irq"});
    end
  endtask


  // ERR latched (and nothing else); w1c clears it; irq pin follows the enable
  task automatic err_check(input bit en, input string what);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
    if (irq !== en) fail({what, ": irq pin vs enable"});
    wr(A_IRQ_STATUS, 1 << IRQ_ERR);
    rd_exp(A_IRQ_STATUS, 0);
    if (irq !== 1'b0) fail({what, ": irq pin after clear"});
  endtask

  task automatic ip_func;
    for (int i = 0; i < 256; i++) shadow[i] = 32'h0;
    rd_exp(A_FLAGS, 0);
    // ---- link training: no answer -> retrain; bad 2nd dword; good ----
    while (dut.u_core.lp_state !== 2'd2) @(posedge PCLK);
    repeat (4200) @(posedge PCLK);
    check(dut.u_core.lp_state === 2'd1 || dut.u_core.lp_state === 2'd2, "no retrain after the response timeout");
    train(1);
    train(0);
    repeat (20) @(posedge PCLK);
    rd_exp(A_IRQ_STATUS, 0);

    // ---- every medium bit 0 -> 1 -> 0 (the medium is not reset) ----
    for (int j = 0; j < 4; j++) wdata[j] = 32'hFFFF_FFFF;
    for (int a = 0; a < 256; a += 4) write10(a, 4, 8'(a));
    for (int a = 0; a < 256; a += 8) read10(a, 8, 8'(a + 1));
    for (int j = 0; j < 4; j++) wdata[j] = 32'h0;
    for (int a = 0; a < 256; a += 4) write10(a, 4, 8'(a + 2));

    // ---- good traffic: no ERR ----
    cmd_raw(8'h00, 24'h0, 8'd0, 8'hA5, 8'h00, 0, 0);       // TEST UNIT READY
    expect_resp(8'hA5, 1);
    wdata[0] = 32'hDEAD_BEEF; wdata[1] = 32'h1234_5678;
    wdata[2] = 32'hCAFE_F00D; wdata[3] = 32'h0BAD_5EED;
    for (int n = 1; n <= 4; n++) begin write10(16 * n, n, 8'(n)); read10(16 * n, n, 8'(n + 8)); end
    write10(252, 4, 8'hFC); read10(248, 8, 8'hFD);
    rd_exp(A_IRQ_STATUS, 0);

    // ---- errors, masked ----
    irq_seen = 0;
    wdata[0] = 32'hFFFF_0000;
    cmd_raw(8'h2A, 24'd16, 8'd1, 8'h04, 8'h00, 1, 1);      // CRC error: dropped
    expect_silent("CRC error");
    check(irq_seen === 1'b1, "no irq on CRC-corrupted frame");
    err_check(0, "CRC error");
    tpay[0] = {8'h00, 24'h0}; for (int i = 1; i < 4; i++) tpay[i] = 0;
    send_raw({8'h01, 8'h05, 8'h00, 8'd4}, 4, 0, 1);         // bad EOF
    expect_silent("bad EOF");
    err_check(0, "bad EOF");
    illegal(8'h00, 24'h0, 8'd0, 8'h01, 0, "LUN 1");
    err_check(0, "LUN 1");

    // ---- errors on the irq pin ----
    wr(A_IRQ_ENABLE, 1 << IRQ_ERR);
    illegal(8'h2A, 24'd254, 8'd3, 8'h00, 3, "WRITE10 past the medium");
    err_check(1, "WRITE10 past the medium");
    illegal(8'h28, 24'd0, 8'd9, 8'h00, 0, "READ10 length 9");
    err_check(1, "READ10 length 9");
    illegal(8'h77, 24'h0, 8'd0, 8'h00, 0, "unknown opcode");
    err_check(1, "unknown opcode");
    foreach (tpay[i]) tpay[i] = 32'h0;
    irq_seen = 0;
    send_raw({8'h02, 8'h08, 8'h00, 8'd2}, 2, 0, 0);        // non-command UPIU: ignored
    expect_silent("non-command UPIU");
    rd_exp(A_IRQ_STATUS, 0);

    // ---- a command arriving while the response is still on the wire ----
    irq_seen = 0;
    fork
      begin
        cmd_raw(8'h28, 24'd248, 8'd8, 8'h71, 8'h00, 0, 0);
        wdata[0] = 32'h1111_2222;
        cmd_raw(8'h2A, 24'd248, 8'd1, 8'h72, 8'h00, 1, 0);   // dropped: busy
      end
      begin
        expect_resp(8'h71, 1);
        recv_frame(rhdr);
        check(rhdr === {8'h02, 8'h71, 8'h00, 8'd8}, "busy: DATA UPIU header / task tag");
        for (int j = 0; j < 8; j++) check(rpay[j] === shadow[248 + j], "busy: DATA UPIU data");
      end
    join
    expect_silent("command while busy");
    err_check(1, "command while busy");
    read10(248, 8, 8'h73);
    wr(A_IRQ_ENABLE, 0);

    // ---- random traffic ----
    for (int i = 0; i < 30; i++) begin
      int s, lba, n;
      logic [7:0] tt;
      tt  = 8'($urandom);
      s   = $urandom_range(0, 7);
      n   = $urandom_range(1, 4);
      lba = $urandom_range(0, 256 - n);
      for (int j = 0; j < 4; j++) wdata[j] = $urandom();
      if (s < 4) write10(lba, n, tt);
      else begin n = $urandom_range(1, 8); read10($urandom_range(0, 256 - n), n, tt); end
    end
    rd_exp(A_IRQ_STATUS, 0);

    // ---- PRESETN while the DATA UPIU is on the wire, then retrain ----
    cmd_raw(8'h28, 24'd0, 8'd8, 8'h44, 8'h00, 0, 0);
    wait_sof();
    repeat (300) @(posedge PCLK);
    @(negedge PCLK) PRESETN = 0;
    repeat (3) @(posedge PCLK);
    check(tx_p === 1'b1 && dut.u_core.link_up === 1'b0, "reset did not idle the link");
    @(negedge PCLK) PRESETN = 1;
    check_reset_values();
    train(0);
    repeat (20) @(posedge PCLK);
    read10(0, 8, 8'h45);                                    // medium is not reset

    // leave ERR pending (masked) for the final reset
    illegal(8'h01, 24'h0, 8'd0, 8'h00, 0, "unknown opcode 01");
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
  endtask
