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

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // =====================================================================
  // FSM probe: host-OOB(7) + device-OOB(7) + rx-engine(4) + host-cmd(5)
  // + device-cmd(8) = 31 states
  localparam int SATA_FSM_TOTAL = 31;
  logic [30:0] fsm_seen = '0;
  always @(posedge clk) begin
    if (dut.hstate  < 7) fsm_seen[dut.hstate]         <= 1'b1;
    if (dut.dstate  < 7) fsm_seen[7  + dut.dstate]    <= 1'b1;
    if (dut.rxw     < 4) fsm_seen[14 + dut.rxw]       <= 1'b1;
    if (dut.hfstate < 5) fsm_seen[18 + dut.hfstate]   <= 1'b1;
    if (dut.dfstate < 8) fsm_seen[23 + dut.dfstate]   <= 1'b1;
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
  logic err_q = 1'b0, link_q = 1'b0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: link down and no errors after reset
      if (rst_cyc > 0)
        sva_check((dut.link_ready === 1'b0) && (irq === 1'b0) &&
                  (dut.host_done === 1'b0), "A1 reset: link down/idle");
      rst_cyc++;
    end else begin
      // A2: complementary differential drive
      sva_check(tx_n === ~tx_p, "A2 tx_n == ~tx_p");
      // A3: irq is exactly the registered error OR
      sva_check(irq === err_q, "A3 irq is registered err pulse");
      // A4: link_ready is sticky once up
      if (link_q) sva_check(dut.link_ready === 1'b1, "A4 link_ready sticky");
      // A5: FSM encodings in range
      sva_check((dut.hstate <= 6) && (dut.dstate <= 6) &&
                (dut.hfstate <= 4) && (dut.dfstate <= 7),
                "A5 FSM encodings valid");
      // A6: captured-dword counter bounded by the 16-dword IDENTIFY
      sva_check(dut.hnd <= 6'd16, "A6 hnd <= 16");
    end
    err_q  <= dut.rx_err | dut.e_proto;
    link_q <= dut.link_ready;
  end

  // CRV FIS-poison injector: one random bit of a random dword (SOF/dw0..dw4 /
  // CRC / EOF; widx 0=SOF) of the (crv_skip+1)-th host-source frame.
  logic       crv_armed = 1'b0, crv_fired = 1'b0;
  logic [2:0] crv_widx = 3'd0;
  logic [5:0] crv_bit  = 6'd0;
  logic       crv_skip = 1'b0;
  logic       in_hfrm  = 1'b0, busy_q = 1'b0;
  always @(negedge clk) begin
    busy_q <= dut.tx_busy;
    if (crv_armed) begin
      if (dut.tx_busy && !busy_q && dut.tx_src_host) begin
        if (crv_skip) crv_skip <= 1'b0;
        else          in_hfrm  <= 1'b1;
      end
      if (!dut.tx_busy) in_hfrm <= 1'b0;
      // widx==0 targets the SOF dword: fire at frame start (the bit index
      // into SOF is pseudo-random from the arming-time phase anyway)
      if (in_hfrm && dut.tx_busy && (dut.tx_widx == crv_widx) &&
          ((crv_widx == 3'd0) || (dut.tx_bitcnt == crv_bit))) begin
        inj       <= 1'b1;      // flips the bit sampled next posedge
        crv_armed <= 1'b0;
        crv_fired <= 1'b1;
      end
    end
    if (crv_fired && !crv_armed) begin
      inj       <= 1'b0;        // one-clk pulse (directed phase has ended)
      crv_fired <= 1'b0;
    end
  end
`endif

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

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized transactions against a 64-dword shadow model:
    //  - ~45% random write + read-back (lba 0..60, random data + corners)
    //  - ~25% poisoned write: one bit flip in the command or data FIS ->
    //    host must time out with errf, irq must pulse, buffer unpolluted,
    //    link must recover (verified by write+read-back after)
    //  - ~10% poisoned read command (same checks)
    //  - ~10% read-back of a previously written random lba
    //  - ~10% unknown host command -> device error status (errf, 8'h51)
    begin : crv_phase
      logic [31:0] shadow [0:63];
      bit          written [0:63];
      logic [31:0] dw [0:3];
      logic [5:0]  lba;
      logic [7:0]  ucmd;
      int n_rw = 0, n_pw = 0, n_pr = 0, n_ro = 0, n_uc = 0;
      int t2, wlba, sel;
      for (int i = 0; i < 64; i++) begin shadow[i] = 32'h0; written[i] = 0; end
      // seed the shadow with the directed phase's surviving writes
      shadow[8]=32'h1111_0001; shadow[9]=32'h2222_0002;
      shadow[10]=32'h3333_0003; shadow[11]=32'h4444_0004;
      shadow[16]=32'hFACE_0001; shadow[17]=32'hFACE_0002;
      shadow[18]=32'hFACE_0003; shadow[19]=32'hFACE_0004;
      shadow[40]=32'hCAFE_0001; shadow[41]=32'hCAFE_0002;
      shadow[42]=32'hCAFE_0003; shadow[43]=32'hCAFE_0004;
      for (int i = 0; i < 64; i++)
        if ((i>=8 && i<12) || (i>=16 && i<20) || (i>=40 && i<44)) written[i]=1;
      for (int i = 0; i < 120; i++) begin
        // NB: assign the random selector to a temp first -- Verilator 5.006
        // duplicates $urandom_range calls inlined in case expressions
        sel = $urandom_range(0, 19);
        case (sel)
          0,1,2,3,4,5,6,7,8: begin
            // ---- random write + read-back ----
            n_rw++;
            lba = $urandom_range(0, 60);
            for (int j = 0; j < 4; j++) begin
              dw[j] = $urandom();
              if ($urandom_range(0, 11) == 0) dw[j] = 32'h0;
              if ($urandom_range(0, 11) == 0) dw[j] = 32'hFFFF_FFFF;
            end
            sata_cmd(8'h35, lba, dw[0], dw[1], dw[2], dw[3]);
            check_status(8'h50, "CRV write");
            for (int j = 0; j < 4; j++) shadow[lba + j] = dw[j];
            written[lba] = 1;
            sata_cmd(8'h25, lba, 32'h0, 32'h0, 32'h0, 32'h0);
            check_status(8'h50, "CRV read-back");
            check_rd(shadow[lba], shadow[lba+1], shadow[lba+2], shadow[lba+3],
                     "CRV rw");
          end
          9,10,11,12,13: begin
            // ---- poisoned write (cmd FIS or data FIS) ----
            n_pw++;
            lba = $urandom_range(0, 60);
            for (int j = 0; j < 4; j++) dw[j] = $urandom();
            crv_widx  = $urandom_range(0, 7);
            crv_bit   = $urandom_range(0, 31);
            crv_skip  = $urandom_range(0, 1);
            crv_armed = 1'b1;
            irq_before = irq_cnt;
            sata_cmd(8'h35, lba, dw[0], dw[1], dw[2], dw[3]);
            t2 = 0; while (!crv_fired && t2 < 100) begin @(posedge clk); t2++; end
            if (crv_armed) begin
              errors++; $display("ERROR: CRV %0d poison window never occurred", i);
              crv_armed = 1'b0;
            end
            if (irq_cnt == irq_before) begin
              errors++; $display("ERROR: CRV %0d poisoned write raised no irq", i);
            end
            if (dut.host_errf !== 1'b1) begin
              errors++; $display("ERROR: CRV %0d poisoned write not errf", i);
            end
            // buffer unpolluted + link alive: read-back must give shadow
            sata_cmd(8'h25, lba, 32'h0, 32'h0, 32'h0, 32'h0);
            check_status(8'h50, "CRV unpolluted read");
            check_rd(shadow[lba], shadow[lba+1], shadow[lba+2], shadow[lba+3],
                     "CRV unpolluted");
            // recovery: fresh write + read-back
            for (int j = 0; j < 4; j++) dw[j] = $urandom();
            sata_cmd(8'h35, lba, dw[0], dw[1], dw[2], dw[3]);
            check_status(8'h50, "CRV recovery write");
            for (int j = 0; j < 4; j++) shadow[lba + j] = dw[j];
            written[lba] = 1;
            sata_cmd(8'h25, lba, 32'h0, 32'h0, 32'h0, 32'h0);
            check_status(8'h50, "CRV recovery read");
            check_rd(shadow[lba], shadow[lba+1], shadow[lba+2], shadow[lba+3],
                     "CRV recovery");
          end
          14,15: begin
            // ---- poisoned read command ----
            n_pr++;
            wlba = 8;
            for (int j = 0; j < 64; j++) if (written[j]) wlba = j;
            lba = $urandom_range(0, 60);
            if (written[lba]) wlba = lba;
            crv_widx  = $urandom_range(0, 7);
            crv_bit   = $urandom_range(0, 31);
            crv_skip  = 1'b0;
            crv_armed = 1'b1;
            irq_before = irq_cnt;
            sata_cmd(8'h25, wlba[5:0], 32'h0, 32'h0, 32'h0, 32'h0);
            t2 = 0; while (!crv_fired && t2 < 100) begin @(posedge clk); t2++; end
            if (crv_armed) begin
              errors++; $display("ERROR: CRV %0d rd-poison window never occurred", i);
              crv_armed = 1'b0;
            end
            if (irq_cnt == irq_before) begin
              errors++; $display("ERROR: CRV %0d poisoned read raised no irq", i);
            end
            if (dut.host_errf !== 1'b1) begin
              errors++; $display("ERROR: CRV %0d poisoned read not errf", i);
            end
            // link alive: plain read-back
            sata_cmd(8'h25, wlba[5:0], 32'h0, 32'h0, 32'h0, 32'h0);
            check_status(8'h50, "CRV rd-poison recovery");
            check_rd(shadow[wlba], shadow[wlba+1], shadow[wlba+2],
                     shadow[wlba+3], "CRV rd-poison recovery data");
          end
          16,17: begin
            // ---- read-back of a previously written lba ----
            n_ro++;
            wlba = 8;
            for (int j = 0; j < 64; j++) if (written[j]) wlba = j;
            lba = $urandom_range(0, 60);
            if (written[lba]) wlba = lba;
            sata_cmd(8'h25, wlba[5:0], 32'h0, 32'h0, 32'h0, 32'h0);
            check_status(8'h50, "CRV read-only");
            check_rd(shadow[wlba], shadow[wlba+1], shadow[wlba+2],
                     shadow[wlba+3], "CRV read-only data");
          end
          default: begin
            // ---- unknown host command -> device error status ----
            n_uc++;
            do ucmd = $urandom_range(0, 255);
            while (ucmd == 8'hEC || ucmd == 8'h25 || ucmd == 8'h35);
            sata_cmd(ucmd, 6'd0, 32'h0, 32'h0, 32'h0, 32'h0);
            if (dut.host_errf !== 1'b1 || dut.host_status !== 8'h51) begin
              errors++;
              $display("ERROR: CRV %0d unknown cmd %h status got=%h errf=%b",
                       i, ucmd, dut.host_status, dut.host_errf);
            end
          end
        endcase
      end
      $display("CRV: 120 txns (rw=%0d poison-wr=%0d poison-rd=%0d rd-only=%0d unknown-cmd=%0d)",
               n_rw, n_pw, n_pr, n_ro, n_uc);
    end
`endif

    if (errors == 0) $display("TEST PASSED: SATA");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < SATA_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, SATA_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Chunked timeout: Verilator 5.006 corrupts the --timing delay heap on a
  // single long-pending #delay once many short-delay resumptions interleave.
  initial begin
    repeat (40000) #1000;   // 40 ms in 1-us chunks
    $display("TIMEOUT");
    $finish;
  end
`else
  initial begin
    #20_000_000;
    $display("TIMEOUT");
    $finish;
  end
`endif
endmodule
