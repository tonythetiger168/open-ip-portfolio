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

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // =====================================================================
  // FSM probe: link-training(4) + rx-decoder(5) + tx-serializer(2) = 11
  localparam int UFS_FSM_TOTAL = 11;
  logic [10:0] fsm_seen = '0;
  always @(posedge clk) begin
    if (dut.lp_state < 4) fsm_seen[dut.lp_state]      <= 1'b1;
    if (dut.rx_state < 5) fsm_seen[4 + dut.rx_state]  <= 1'b1;
    if (dut.tx_state < 2) fsm_seen[9 + dut.tx_state]  <= 1'b1;
  end

  int sva_total = 0, sva_fail = 0;
  task automatic sva_check(input bit cond, input string name);
    begin
      sva_total++;
      if (!cond) begin
        sva_fail++;
        errors++;
        $display("SVA_FAIL: %s @%0t", name, $time);
      end
    end
  endtask

  // output-invariant assertion suite (sampled at posedge, pre-NBA coherent)
  int  rst_cyc = 0;
  logic irq_q = 1'b0, link_q = 1'b0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: link down and idle after reset
      if (rst_cyc > 0)
        sva_check((dut.link_up === 1'b0) && (irq === 1'b0) &&
                  (tx_p === 1'b1), "A1 reset: link down/idle");
      rst_cyc++;
    end else begin
      // A2: complementary differential drive
      sva_check(tx_n === ~tx_p, "A2 tx_n == ~tx_p");
      // A3: FSM encodings in range
      sva_check((dut.lp_state < 4) && (dut.rx_state < 5) &&
                (dut.tx_state < 2), "A3 FSM encodings valid");
      // A4: link_up is sticky once trained
      if (link_q) sva_check(dut.link_up === 1'b1, "A4 link_up sticky");
      // A5: irq is a single-cycle pulse
      if (irq_q) sva_check(irq === 1'b0, "A5 irq pulse width");
      // A6: TX serializer index bounded by frame length
      if (dut.tx_state == 1)
        sva_check(dut.tx_idx < dut.tx_total, "A6 tx_idx < tx_total");
    end
    irq_q  <= irq;
    link_q <= dut.link_up;
  end
`endif

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

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized UPIU transactions vs a 256-dword shadow medium:
    //  - ~35% WRITE10 (random lba 0..255-n, n 1..4, corners) + READ10 verify
    //  - ~25% READ10 of a previously written region, shadow compare
    //  - ~15% CRC-corrupted WRITE10: irq, no response, storage unchanged
    //  - ~10% unknown opcode: CHECK CONDITION + ILLEGAL REQUEST + irq
    //  - ~10% out-of-range request (lba+n>256 / n=0 / n>8): CHECK + irq
    //  - ~5%  malformed CDB (len<4): irq, no response
    //  - ~5%  oversize frame (len=9): dropped at header, irq, no response
    begin : crv_phase
      logic [31:0] shadow [0:255];
      bit          written [0:256];   // region-start markers (conservative)
      logic [7:0]  tt, op, nn;
      int          lba, wl, sel;
      int n_wr = 0, n_rd = 0, n_ce = 0, n_uo = 0, n_oor = 0, n_mc = 0, n_ol = 0;
      for (int i = 0; i < 256; i++) begin shadow[i] = 32'h0; written[i] = 0; end
      written[256] = 0;
      // directed phase survivors
      shadow[16] = 32'hDEAD_BEEF; shadow[17] = 32'h1234_5678;
      shadow[18] = 32'hCAFE_F00D; shadow[19] = 32'h0BAD_5EED;
      shadow[64] = 32'hAAAA_5555; shadow[65] = 32'h5555_AAAA;
      written[16] = 1; written[64] = 1;
      for (int i = 0; i < 120; i++) begin
        tt  = $urandom_range(1, 255);
        sel = $urandom_range(0, 19);
        if (sel < 7) begin
          // ---- WRITE10 + READ10 verify ----
          n_wr++;
          nn  = $urandom_range(1, 4);
          lba = $urandom_range(0, 256 - nn);
          for (int j = 0; j < 4; j++) begin
            wdata[j] = $urandom();
            if ($urandom_range(0, 11) == 0) wdata[j] = 32'h0;
            if ($urandom_range(0, 11) == 0) wdata[j] = 32'hFFFF_FFFF;
          end
          ufs_cmd(8'h2A, lba[23:0], nn, tt, 1'b0);
          expect_resp(tt, 32'h0000_0000);
          for (int j = 0; j < nn; j++) shadow[lba + j] = wdata[j];
          written[lba] = 1;
          ufs_cmd(8'h28, lba[23:0], nn, tt, 1'b0);
          expect_resp(tt, 32'h0000_0000);
          recv_frame(rhdr);
          check(rhdr[31:24] === 8'h02, "CRV wr: no DATA UPIU");
          check(rhdr[7:0] === nn,     "CRV wr: DATA len mismatch");
          for (int j = 0; j < nn; j++)
            check(rpay[j] === shadow[lba+j], "CRV wr: readback mismatch");
        end else if (sel < 12) begin
          // ---- READ10 of a previously written region ----
          n_rd++;
          wl = 16;
          for (int j = 0; j < 256; j++) if (written[j]) wl = j;
          lba = $urandom_range(0, 255);
          if (written[lba]) wl = lba;
          nn  = $urandom_range(1, 2);
          ufs_cmd(8'h28, wl[23:0], nn, tt, 1'b0);
          expect_resp(tt, 32'h0000_0000);
          recv_frame(rhdr);
          check(rhdr[31:24] === 8'h02, "CRV rd: no DATA UPIU");
          for (int j = 0; j < nn; j++)
            check(rpay[j] === shadow[wl+j], "CRV rd: data mismatch");
        end else if (sel < 15) begin
          // ---- CRC-corrupted WRITE10: dropped, storage unchanged ----
          n_ce++;
          nn  = $urandom_range(1, 4);
          lba = $urandom_range(0, 256 - nn);
          for (int j = 0; j < 4; j++) wdata[j] = $urandom();
          irq_seen = 0;
          ufs_cmd(8'h2A, lba[23:0], nn, tt, 1'b1);
          tx_act = 0;
          repeat (600) @(posedge clk);
          check(irq_seen === 1'b1, "CRV crc: no irq");
          check(tx_act   === 1'b0, "CRV crc: DUT responded to bad frame");
          // verify via READ10 that shadow contents survived
          ufs_cmd(8'h28, lba[23:0], nn, tt, 1'b0);
          expect_resp(tt, 32'h0000_0000);
          recv_frame(rhdr);
          for (int j = 0; j < nn; j++)
            check(rpay[j] === shadow[lba+j], "CRV crc: storage polluted");
        end else if (sel < 17) begin
          // ---- unknown opcode ----
          n_uo++;
          do op = $urandom_range(0, 255);
          while (op == 8'h00 || op == 8'h28 || op == 8'h2A);
          irq_seen = 0;
          ufs_cmd(op, 24'h0, 8'd0, tt, 1'b0);
          recv_frame(rhdr);
          check(rhdr[31:24] === 8'h81,       "CRV unk: no RESPONSE UPIU");
          check(rpay[0][15:0]  === 16'h0001, "CRV unk: status not CHECK");
          check(rpay[0][31:16] === 16'h0005, "CRV unk: sense not ILLEGAL");
          check(irq_seen === 1'b1,           "CRV unk: no irq");
        end else if (sel < 18) begin
          // ---- malformed CDB (len 0..3): dropped, no response ----
          n_mc++;
          irq_seen = 0;
          send_frame(8'h01, tt, 8'h00, $urandom_range(0, 3), 1'b0);
          tx_act = 0;
          repeat (600) @(posedge clk);
          check(irq_seen === 1'b1, "CRV malformed: no irq");
          check(tx_act   === 1'b0, "CRV malformed: DUT responded");
        end else if (sel < 19) begin
          // ---- out-of-range request: CHECK CONDITION + irq ----
          n_oor++;
          if ($urandom_range(0, 1)) begin
            // WRITE10 with lba + n > 256
            nn  = $urandom_range(1, 4);
            lba = 256 - nn + $urandom_range(1, 8);
            for (int j = 0; j < 4; j++) wdata[j] = $urandom();
            irq_seen = 0;
            ufs_cmd(8'h2A, lba[23:0], nn, tt, 1'b0);
          end else begin
            // READ10 with n == 0 or n > 8
            nn  = ($urandom_range(0, 1)) ? 8'd0 : $urandom_range(9, 255);
            irq_seen = 0;
            ufs_cmd(8'h28, 24'd0, nn, tt, 1'b0);
          end
          recv_frame(rhdr);
          check(rhdr[31:24] === 8'h81,       "CRV oor: no RESPONSE UPIU");
          check(rpay[0][15:0]  === 16'h0001, "CRV oor: status not CHECK");
          check(rpay[0][31:16] === 16'h0005, "CRV oor: sense not ILLEGAL");
          check(irq_seen === 1'b1,           "CRV oor: no irq");
        end else begin
          // ---- oversize frame (len=9): dropped at header ----
          n_ol++;
          irq_seen = 0;
          begin
            logic [31:0] c;
            send_word(SOF, 0);
            tb_crc = 32'hFFFF_FFFF;
            send_word({8'h01, tt, 8'h00, 8'd9}, 1);
            for (int j = 0; j < 9; j++) send_word($urandom(), 1);
            c = tb_crc ^ 32'hFFFF_FFFF;
            send_word(c, 0);
            send_word(EOFR, 0);
            @(negedge clk); rx_p = 1'b1; rx_n = 1'b0;
          end
          tx_act = 0;
          repeat (600) @(posedge clk);
          check(irq_seen === 1'b1, "CRV oversize: no irq");
          check(tx_act   === 1'b0, "CRV oversize: DUT responded");
        end
      end
      $display("CRV: 120 txns (wr=%0d rd=%0d crc-err=%0d unk-op=%0d oor=%0d malformed=%0d oversize=%0d)",
               n_wr, n_rd, n_ce, n_uo, n_oor, n_mc, n_ol);
    end
`endif

    if (errors == 0) $display("TEST PASSED: UFS");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < UFS_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, UFS_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Chunked timeout: Verilator 5.006 corrupts the --timing delay heap on a
  // single long-pending #delay once many short-delay resumptions interleave.
  initial begin
    repeat (15000) #1000;   // 15 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
