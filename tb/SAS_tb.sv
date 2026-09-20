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

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // =====================================================================
  // FSM probe: oob(5) + tx(6) + rx(5) + sequencer(6) = 22 states
  localparam int SAS_FSM_TOTAL = 22;
  logic [21:0] fsm_seen = '0;
  always @(posedge clk) begin
    if (dut.oob_state < 5) fsm_seen[dut.oob_state]        <= 1'b1;
    if (dut.tx_state  < 6) fsm_seen[5  + dut.tx_state]    <= 1'b1;
    if (dut.rx_state  < 5) fsm_seen[11 + dut.rx_state]    <= 1'b1;
    if (dut.sq_state  < 6) fsm_seen[16 + dut.sq_state]    <= 1'b1;
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
  logic pulse_q = 1'b0, phy_q = 1'b0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: line idle and link down in reset
      if (rst_cyc > 0)
        sva_check((tx_p === 1'b0) && (dut.phy_ready === 1'b0) &&
                  (irq === 1'b0), "A1 reset: idle/down");
      rst_cyc++;
    end else begin
      // A2: complementary differential drive
      sva_check(tx_n === ~tx_p, "A2 tx_n == ~tx_p");
      // A3: irq is exactly the registered error-pulse OR
      sva_check(irq === pulse_q, "A3 irq is registered err pulse");
      // A4: phy_ready is sticky once the link is up
      if (phy_q) sva_check(dut.phy_ready === 1'b1, "A4 phy_ready sticky");
      // A5: FSM state encodings in range
      sva_check((dut.oob_state < 5) && (dut.tx_state < 6) &&
                (dut.rx_state < 5) && (dut.sq_state < 6),
                "A5 FSM encodings valid");
      // A6: write data always follows the initiator sequence pattern
      if (dut.wr_evt)
        sva_check(((dut.wr_data - 32'h5A5A_0000) % 32'h0001_0101) === 32'd0,
                  "A6 wr_data sequence pattern");
    end
    pulse_q <= dut.crc_err_pulse | dut.proto_err_pulse | dut.tmo_err_pulse;
    phy_q   <= dut.phy_ready;
  end

  // generalized CRV bit-flip injection: one random bit of any frame dword
  // in HDR/PAY/CRC/EOF (SOF excluded: dropping SOF only causes a link
  // timeout, exercised separately by the directed SQ_TMO path)
  logic        crv_armed = 1'b0, crv_fired = 1'b0;
  logic [5:0]  crv_bit = 6'd0;
  logic [1:0]  crv_dw  = 2'd0;    // target dword index after SOF
  logic [1:0]  dw_cnt  = 2'd0;
  logic [1:0]  crv_skip = 2'd0;   // frames to skip after arming
  logic        in_frame = 1'b0;
  logic [2:0]  txs_q = 3'd0;      // state edge detect (negedge domain)

  // error-class counters (diagnostics + CRV self-check)
  int ce_n = 0, pe_n = 0, te_n = 0, dbg_n = 0;
  int ft_w = 0, ft_rd = 0, ft_rs = 0, ft_x = 0;
  always @(posedge clk) begin
    if (rst_n && dut.crc_err_pulse)   ce_n++;
    if (rst_n && dut.proto_err_pulse) pe_n++;
    if (rst_n && dut.tmo_err_pulse)   te_n++;
  end
`endif

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
`ifdef VERILATOR
    // frame-tracked injection: count in-frame dwords from SOF, fire on the
    // crv_dw-th dword (0=HDR, 1=PAY/CRC, 2=CRC/EOF, 3=EOF of len-1 frames)
    if (crv_armed) begin
      txs_q <= dut.tx_state;
      if ((dut.tx_state == 1 /*TS_SOF*/) && (txs_q != 1)) begin
        if (crv_skip == 2'd0) begin
          in_frame <= 1'b1; dw_cnt <= 2'd0; // next dword (HDR) is index 0
        end else crv_skip <= crv_skip - 2'd1;
      end else if (dut.tx_state == 0 /*TS_ALIGN*/) begin
        in_frame <= 1'b0;
      end else if (in_frame && (dut.tx_bit_cnt == 6'd31)) begin
        dw_cnt <= dw_cnt + 2'd1;            // dword completes -> next index
      end
      if (in_frame && (dut.tx_state >= 2) && (dw_cnt == crv_dw) &&
          (dut.tx_bit_cnt == crv_bit)) begin
        corrupt   <= 1'b1;     // corrupts the bit sampled next posedge
        crv_armed <= 1'b0;
        crv_fired <= 1'b1;
        case (dut.f_type)
          8'h01:   ft_w++;
          8'h02:   ft_rd++;
          8'h83:   ft_rs++;
          default: ft_x++;
        endcase
      end
    end else begin
      in_frame <= 1'b0;
    end
`endif
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

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized error-injection transactions: the DUT initiator runs
    // its write/read-verify sequence over the loopback link; each iteration
    // flips one random bit (position 0..31) of a random frame dword
    // (HDR/PAY/CRC/EOF of a write, read-request or read-response frame).
    // Checks per iteration: injection fired, DUT flagged the bad frame
    // (irq from crc/proto error), and the link stayed alive (a subsequent
    // transaction completed, ok or caught-mismatch).
    begin : crv_phase
      int n_inj = 0, n_irq = 0, n_alive = 0;
      int okmm_before, ce_before;
      int t2;
      for (int i = 0; i < 120; i++) begin
        crv_bit     = $urandom_range(0, 31);
        crv_dw      = $urandom_range(0, 3);
        crv_skip    = $urandom_range(0, 2);
        irq_before  = irq_cnt;
        ce_before   = dut.crc_err_cnt;
        okmm_before = dut.ok_cnt + dut.mm_cnt;
        crv_fired   = 1'b0;
        crv_armed   = 1'b1;
        t2 = 0;
        while (!crv_fired && t2 < 4000) begin @(posedge clk); t2++; end
        crv_armed = 1'b0;
        if (!crv_fired) begin
          errors++; $display("ERROR: CRV %0d injection window never occurred", i);
          continue;
        end
        n_inj++;
        // DUT must flag the corrupted frame
        t2 = 0;
        while (irq_cnt == irq_before && t2 < 3000) begin @(posedge clk); t2++; end
        if (irq_cnt == irq_before) begin
          errors++; $display("ERROR: CRV %0d no irq after bit-flip injection", i);
        end else n_irq++;
        // link must stay alive: a later transaction completes
        t2 = 0;
        while ((dut.ok_cnt + dut.mm_cnt) == okmm_before && t2 < 8000) begin
          @(posedge clk); t2++;
        end
        if ((dut.ok_cnt + dut.mm_cnt) == okmm_before) begin
          errors++; $display("ERROR: CRV %0d link stuck after injection", i);
        end else n_alive++;
      end
      $display("CRV: %0d bit-flip injections, %0d flagged, %0d link-alive, crc_err_cnt=%0d",
               n_inj, n_irq, n_alive, dut.crc_err_cnt);
      $display("CRV: error classes crc=%0d proto=%0d tmo=%0d; frames wr=%0d rdreq=%0d rdrsp=%0d x=%0d", ce_n, pe_n, te_n, ft_w, ft_rd, ft_rs, ft_x);
    end
`endif

    if (errors == 0) $display("TEST PASSED: SAS");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < SAS_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, SAS_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Chunked timeout: Verilator 5.006 corrupts the --timing delay heap on a
  // single long-pending #delay once many short-delay resumptions interleave.
  initial begin
    repeat (30000) #1000;   // 30 ms in 1-us chunks
    $display("TIMEOUT");
    $finish;
  end
`else
  initial begin
    #2000000;
    $display("TIMEOUT");
    $finish;
  end
`endif
endmodule
