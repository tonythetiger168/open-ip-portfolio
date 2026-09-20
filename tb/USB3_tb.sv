// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for USB3_top -- SystemVerilog
// Host-side link partner model: LFPS handshake, DPH/DPP bulk transfers,
// ACK/NRDY/LBAD transaction packets, error injection.
// IP design verification v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module USB3_tb;

  localparam logic [7:0] SYM_IDLE = 8'h00;
  localparam logic [7:0] SYM_LFPS = 8'hAA;
  localparam logic [7:0] SYM_DPH  = 8'hBC;
  localparam logic [7:0] SYM_TP   = 8'h4B;
  localparam logic [7:0] SYM_DPP  = 8'h5A;
  localparam logic [7:0] SYM_END  = 8'h3C;

  localparam logic [3:0] TYPE_DATA = 4'h1;
  localparam logic [3:0] TP_ACK    = 4'hA;
  localparam logic [3:0] TP_NRDY   = 4'h5;
  localparam logic [3:0] TP_LBAD   = 4'hB;

  logic       clk = 0, rst_n = 0;
  logic [7:0] rx_p, rx_n;
  logic [7:0] tx_p, tx_n;
  logic       link_up, irq;

  int errors = 0;

  // payload staging (filled before bulk_out, compared in bulk_in)
  logic [31:0] dbuf    [0:15];
  logic [31:0] exp_buf [0:15];

  USB3_top dut (
    .clk(clk), .rst_n(rst_n),
    .rx_p(rx_p), .rx_n(rx_n),
    .tx_p(tx_p), .tx_n(tx_n),
    .link_up(link_up), .irq(irq)
  );

  always #5 clk = ~clk;

  // count DUT-transmitted LFPS cycles before link up
  int dut_lfps_cycles;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) dut_lfps_cycles <= 0;
    else if (!link_up && tx_p === SYM_LFPS) dut_lfps_cycles <= dut_lfps_cycles + 1;
  end

  // ------------------------------------------------------------------
  // CRC functions (mirror DUT)
  // ------------------------------------------------------------------
  function automatic logic [4:0] crc5_16(input logic [15:0] d);
    logic [4:0] c;
    logic       fb;
    begin
      c = 5'h1F;
      for (int i = 0; i < 16; i++) begin
        fb = d[i] ^ c[0];
        c  = {fb, c[4], c[3] ^ fb, c[2], c[1]};
      end
      crc5_16 = ~c;
    end
  endfunction

  function automatic logic [31:0] crc32_b(input logic [31:0] c_in,
                                          input logic [7:0]  d);
    logic [31:0] c;
    logic        fb;
    begin
      c = c_in;
      for (int i = 0; i < 8; i++) begin
        fb = d[i] ^ c[0];
        c  = c >> 1;
        if (fb) c = c ^ 32'hEDB8_8320;
      end;
      crc32_b = c;
    end
  endfunction

  // ------------------------------------------------------------------
  // symbol driver (host -> DUT), one symbol per clk
  // ------------------------------------------------------------------
  task automatic tx_sym(input logic [7:0] s);
    begin
      @(negedge clk);
      rx_p <= s;
      rx_n <= ~s;
    end
  endtask

  // ------------------------------------------------------------------
  // packet builders
  // ------------------------------------------------------------------
  task automatic send_dph(input logic [3:0] typ, input logic [2:0] seq,
                          input logic [1:0] blk);
    logic [7:0] s1, s2;
    begin
      s1 = {4'h0, typ};
      s2 = {seq, blk, 3'b000};
      tx_sym(SYM_DPH);
      tx_sym(s1);
      tx_sym(s2);
      tx_sym(crc5_16({s2, s1}));
    end
  endtask

  task automatic send_dpp(input logic corrupt);
    logic [31:0] c, f;
    logic [7:0]  b;
    begin
      tx_sym(SYM_DPP);
      c = 32'hFFFF_FFFF;
      for (int i = 0; i < 16; i++) begin
        for (int j = 0; j < 4; j++) begin
          b = dbuf[i][8*j +: 8];
          tx_sym(b);
          c = crc32_b(c, b);
        end
      end
      f = ~c;
      if (corrupt) f = f ^ 32'h0000_0001;
      tx_sym(f[7:0]);
      tx_sym(f[15:8]);
      tx_sym(f[23:16]);
      tx_sym(f[31:24]);
      tx_sym(SYM_END);
    end
  endtask

  task automatic send_tp(input logic [3:0] typ, input logic [2:0] seq,
                         input logic rtry, input logic [1:0] blk,
                         input logic in_req);
    logic [7:0] s1, s2;
    begin
      s1 = {4'h0, typ};
      s2 = {seq, rtry, blk, in_req, 1'b0};
      tx_sym(SYM_TP);
      tx_sym(s1);
      tx_sym(s2);
      tx_sym(crc5_16({s2, s1}));
      tx_sym(SYM_END);
    end
  endtask

  // ------------------------------------------------------------------
  // receivers (DUT -> host)
  // ------------------------------------------------------------------
  task automatic recv_tp(output logic [3:0] typ, output logic [2:0] seq,
                         output logic rtry, output logic [1:0] blk);
    logic [7:0] s1, s2, c5, es;
    int t;
    begin
      typ = 4'h0; seq = 3'd0; rtry = 1'b0; blk = 2'd0;
      t = 0;
      while (tx_p !== SYM_TP && t < 400) begin @(negedge clk); t = t + 1; end
      if (t >= 400) begin
        errors++;
        $display("ERROR: timeout waiting for transaction packet");
      end else begin
        @(negedge clk); s1 = tx_p;
        @(negedge clk); s2 = tx_p;
        @(negedge clk); c5 = tx_p;
        @(negedge clk); es = tx_p;
        if (c5 !== crc5_16({s2, s1})) begin
          errors++; $display("ERROR: TP CRC5 mismatch, got %h exp %h",
                             c5, crc5_16({s2, s1}));
        end
        if (es !== SYM_END) begin
          errors++; $display("ERROR: TP END framing missing, got %h", es);
        end
        typ  = s1[3:0];
        seq  = s2[7:5];
        rtry = s2[4];
        blk  = s2[3:2];
      end
    end
  endtask

  // receive one device IN data packet and compare against exp_buf
  task automatic recv_dpp(input logic [2:0] exp_seq, input logic [1:0] exp_blk);
    logic [7:0]  s1, s2, c5, sym;
    logic [31:0] c, word, crc_r;
    int t;
    begin
      t = 0;
      while (tx_p !== SYM_DPH && t < 400) begin @(negedge clk); t = t + 1; end
      if (t >= 400) begin
        errors++;
        $display("ERROR: timeout waiting for IN DPH");
      end else begin
        @(negedge clk); s1 = tx_p;
        @(negedge clk); s2 = tx_p;
        @(negedge clk); c5 = tx_p;
        if (s1[3:0] !== TYPE_DATA) begin
          errors++; $display("ERROR: IN DPH type %h != DATA", s1[3:0]);
        end
        if (s2[7:5] !== exp_seq) begin
          errors++; $display("ERROR: IN seq %0d, expected %0d", s2[7:5], exp_seq);
        end
        if (s2[4:3] !== exp_blk) begin
          errors++; $display("ERROR: IN blk %0d, expected %0d", s2[4:3], exp_blk);
        end
        if (c5 !== crc5_16({s2, s1})) begin
          errors++; $display("ERROR: IN DPH CRC5 mismatch");
        end
        @(negedge clk); sym = tx_p;
        if (sym !== SYM_DPP) begin
          errors++; $display("ERROR: IN DPP start missing, got %h", sym);
        end
        c = 32'hFFFF_FFFF;
        for (int i = 0; i < 16; i++) begin
          word = 32'd0;
          for (int j = 0; j < 4; j++) begin
            @(negedge clk); sym = tx_p;
            c = crc32_b(c, sym);
            word[8*j +: 8] = sym;
          end
          if (word !== exp_buf[i]) begin
            errors++;
            $display("ERROR: IN data dword %0d: got %h exp %h",
                     i, word, exp_buf[i]);
          end
        end
        crc_r = 32'd0;
        for (int j = 0; j < 4; j++) begin
          @(negedge clk); crc_r[8*j +: 8] = tx_p;
        end
        if (crc_r !== ~c) begin
          errors++; $display("ERROR: IN CRC32 got %h exp %h", crc_r, ~c);
        end
        @(negedge clk);
        if (tx_p !== SYM_END) begin
          errors++; $display("ERROR: IN END framing missing, got %h", tx_p);
        end
      end
    end
  endtask

  // ------------------------------------------------------------------
  // high-level transactions
  // ------------------------------------------------------------------
  task automatic bulk_out(input logic [1:0] blk, input logic [2:0] seq,
                          input logic corrupt, input logic [3:0] exp_typ,
                          input logic exp_retry);
    logic [3:0] typ;
    logic [2:0] rseq;
    logic       rtry;
    logic [1:0] rblk;
    begin
      send_dph(TYPE_DATA, seq, blk);
      send_dpp(corrupt);
      recv_tp(typ, rseq, rtry, rblk);
      if (typ !== exp_typ) begin
        errors++;
        $display("ERROR: OUT blk%0d seq%0d: TP %h, expected %h",
                 blk, seq, typ, exp_typ);
      end
      if (rseq !== seq) begin
        errors++;
        $display("ERROR: OUT blk%0d: ACK seq %0d, expected %0d", blk, rseq, seq);
      end
      if (exp_typ == TP_ACK && rtry !== exp_retry) begin
        errors++;
        $display("ERROR: OUT blk%0d: retry flag %b, expected %b",
                 blk, rtry, exp_retry);
      end
      tx_sym(SYM_IDLE);
      tx_sym(SYM_IDLE);
    end
  endtask

  // request an IN transfer, verify data, complete with host ACK
  task automatic bulk_in(input logic [1:0] blk, input logic [2:0] dseq);
    begin
      send_tp(TP_ACK, 3'd0, 1'b0, blk, 1'b1);   // IN request
      tx_sym(SYM_IDLE);
      recv_dpp(dseq, blk);
      send_tp(TP_ACK, dseq, 1'b0, blk, 1'b0);   // host ACK completes transfer
      tx_sym(SYM_IDLE);
    end
  endtask

  task automatic fill_pattern(input logic [31:0] base);
    begin
      for (int i = 0; i < 16; i++) begin
        dbuf[i]    = base + i;
        exp_buf[i] = base + i;
      end
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [3:0] typ;
  logic [2:0] rseq;
  logic       rtry;
  logic [1:0] rblk;
  int         t;
  logic       quiet;

  initial begin
    rx_p = SYM_IDLE;
    rx_n = ~SYM_IDLE;
    rst_n = 0;
    repeat (5) @(negedge clk);

    // ---- check 1: reset state -------------------------------------
    if (tx_p !== SYM_IDLE) begin
      errors++; $display("ERROR: reset tx_p=%h, expected idle", tx_p);
    end
    if (link_up !== 1'b0) begin
      errors++; $display("ERROR: reset link_up=%b", link_up);
    end
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: reset irq=%b", irq);
    end
    rst_n = 1;

    // ---- check 2: LFPS handshake (Polling.LFPS burst/idle -> U0) ---
    repeat (40) tx_sym(SYM_IDLE);          // RXDET dwell
    repeat (2) begin                        // 2 Polling.LFPS bursts
      repeat (16) tx_sym(SYM_LFPS);
      repeat (16) tx_sym(SYM_IDLE);
    end
    t = 0;
    while (!link_up && t < 400) begin tx_sym(SYM_IDLE); t = t + 1; end
    if (!link_up) begin
      errors++; $display("ERROR: LFPS handshake did not reach U0");
    end
    if (dut_lfps_cycles < 16) begin
      errors++;
      $display("ERROR: DUT transmitted only %0d LFPS cycles", dut_lfps_cycles);
    end
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: irq set during error-free link training");
    end
    repeat (4) tx_sym(SYM_IDLE);

    // ---- check 3: bulk OUT block0 seq0 -> ACK ----------------------
    fill_pattern(32'hA500_0000);
    bulk_out(2'd0, 3'd0, 1'b0, TP_ACK, 1'b0);

    // ---- check 4: IN request for never-written block -> NRDY -------
    send_tp(TP_ACK, 3'd0, 1'b0, 2'd1, 1'b1);
    tx_sym(SYM_IDLE);
    recv_tp(typ, rseq, rtry, rblk);
    if (typ !== TP_NRDY) begin
      errors++;
      $display("ERROR: IN of unwritten block: TP %h, expected NRDY", typ);
    end
    tx_sym(SYM_IDLE);
    tx_sym(SYM_IDLE);

    // ---- check 5: bulk IN block0 with LBAD -> retransmission -------
    send_tp(TP_ACK, 3'd0, 1'b0, 2'd0, 1'b1);   // IN request blk0
    tx_sym(SYM_IDLE);
    recv_dpp(3'd0, 2'd0);                       // first attempt
    send_tp(TP_LBAD, 3'd0, 1'b0, 2'd0, 1'b0);   // host reports bad packet
    tx_sym(SYM_IDLE);
    recv_dpp(3'd0, 2'd0);                       // retransmission, same seq
    send_tp(TP_ACK, 3'd0, 1'b0, 2'd0, 1'b0);    // host ACK completes
    tx_sym(SYM_IDLE);

    // ---- check 6: back-to-back bulk OUT blocks 1,2 -----------------
    fill_pattern(32'h5A00_1000);
    bulk_out(2'd1, 3'd1, 1'b0, TP_ACK, 1'b0);
    fill_pattern(32'hC300_2000);
    bulk_out(2'd2, 3'd2, 1'b0, TP_ACK, 1'b0);

    // ---- check 7: bulk IN readback blocks 1,2 (OUT->IN compare) ----
    for (int i = 0; i < 16; i++) exp_buf[i] = 32'h5A00_1000 + i;
    bulk_in(2'd1, 3'd1);
    for (int i = 0; i < 16; i++) exp_buf[i] = 32'hC300_2000 + i;
    bulk_in(2'd2, 3'd2);

    // ---- check 8: bad CRC32 injection -> LBAD + irq, then retry ----
    fill_pattern(32'h1234_5000);
    bulk_out(2'd3, 3'd3, 1'b1, TP_LBAD, 1'b0);  // corrupted CRC32
    repeat (2) tx_sym(SYM_IDLE);
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not set after bad-CRC32 injection");
    end
    bulk_out(2'd3, 3'd3, 1'b0, TP_ACK, 1'b0);   // host retransmission
    for (int i = 0; i < 16; i++) exp_buf[i] = 32'h1234_5000 + i;
    bulk_in(2'd3, 3'd3);                        // verify recovered data

    // ---- check 9: out-of-order seq injection -> NRDY ---------------
    fill_pattern(32'hDEAD_0000);
    bulk_out(2'd0, 3'd6, 1'b0, TP_NRDY, 1'b0);  // expected seq is 4

    // ---- check 10: duplicate seq -> ACK with retry flag ------------
    fill_pattern(32'hFFFF_0000);
    bulk_out(2'd0, 3'd3, 1'b0, TP_ACK, 1'b1);   // duplicate of seq3

    // ---- check 11: buffer not corrupted by 9/10, readback block0 ---
    for (int i = 0; i < 16; i++) exp_buf[i] = 32'hA500_0000 + i;
    bulk_in(2'd0, 3'd4);

    // ---- check 12: after final ACK link stays quiet (no resend) ----
    quiet = 1'b1;
    repeat (300) begin
      @(negedge clk);
      if (tx_p !== SYM_IDLE) quiet = 1'b0;
    end
    if (!quiet) begin
      errors++; $display("ERROR: DUT retransmitted after host ACK");
    end

    // ---- summary ----------------------------------------------------
    if (errors == 0)
      $display("TEST PASSED: USB3");
    else
      $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // timeout guard
  initial begin
    #3000000;
    $display("ERROR: TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end

endmodule
