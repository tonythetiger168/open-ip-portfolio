// SPDX-License-Identifier: Apache-2.0
// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module ONFI_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
`ifdef VERILATOR
  // Clock-aligned host timing (see W4_MEMORY.md RISK-1): under the 5.006
  // timing-scheduler pathology, #delay coroutine resumptions suffer
  // unbounded lag/jitter, which skews host bit cells off the DUT sampling
  // grid and eventually corrupts a frame (rx_err, no echo, TB parks in
  // recv). Clock-edge waits land exactly on the DUT grid and are immune.
  `define BDLY(ns) bdly(((ns) + 5) / 10)
`else
  `define BDLY(ns) #(ns)
`endif
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  ONFI_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probes, immediate
  // assertions. The timeout guard is chunked (see bottom of file).
  //
  // FSM probe paths (DUT is not a wrapper; probe the RTL directly):
  //   dut.tstate (T_IDLE/T_CALC/T_DATA, 3 states)
  //   dut.rstate (R_IDLE/R_DATA, 2 states)
  //
  // Shadow model (BUG-ONFI-1 v2.5.1 FIXED, rtl/ONFI_top.sv echo-copy):
  // the loop bound is now HB+MAXB+2, so tx_mem[0..15] is an exact copy
  // of buf_mem[2..17] in both simulators (no OOB-mask clobber of
  // tx_mem[0..3]). exp_txm predicts the echoed bytes the DUT will
  // actually send; sh_buf tracks the DUT receive buffer across frames.
  // =====================================================================
  localparam int CRV_FSM_TOTAL = 5;   // tstate(3) + rstate(2)
  logic [2:0] t_seen = '0;
  logic [1:0] r_seen = '0;
  wire  [1:0] dut_tstate = dut.tstate;
  wire        dut_rstate = dut.rstate;

  logic [7:0] sh_buf  [0:22];         // shadow of DUT buf_mem[0:22]
  logic [7:0] exp_txm [0:15];         // predicted echo content (shadow)
  int         exp_len = 0;

  int sva_total = 0, sva_fail = 0;
  // counted immediate assertion: every evaluation is one check
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

  // FSM coverage: sample both DUT state registers every clock
  always @(posedge clk) begin
    t_seen[dut_tstate] <= 1'b1;
    r_seen[dut_rstate] <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic p_irq = 0, p_rxerr = 0;
  int rst_cyc = 0;   // consecutive reset clocks (skip the fall-edge cycle)
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (from the 2nd reset clock on)
      if (rst_cyc >= 1)
        sva_check(dut.busy === 1'b0 && dut.irq === 1'b0 &&
                  dut.oe_q === 1'b0 && dut.rx_err === 1'b0,
                  "A1 reset: outputs quiescent");
      rst_cyc <= rst_cyc + 1;
    end else begin
      rst_cyc <= 0;
      // A2/A3: FSM state encodings legal
      sva_check(dut_tstate <= 2'd2, "A2 tstate encoding legal");
      sva_check(dut_rstate <= 1'd1, "A3 rstate encoding legal");
      // A4: busy is exactly "either FSM out of idle"
      sva_check(dut.busy === ((dut_tstate != 2'd0) || (dut_rstate != 1'd0)),
                "A4 busy == FSMs not idle");
      // A5: irq is a single-cycle pulse
      sva_check(!(p_irq && dut.irq), "A5 irq single-cycle pulse");
      // A6: rx_err is sticky until reset
      sva_check(!p_rxerr || dut.rx_err, "A6 rx_err sticky");
      // A7: tx pad driven only while the TX FSM is active
      sva_check(!dut.oe_q || (dut_tstate != 2'd0), "A7 tx driven only in TX");
    end
    p_irq   <= dut.irq;
    p_rxerr <= dut.rx_err;
  end
`endif

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; `BDLY(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; `BDLY(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; `BDLY(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; `BDLY(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; `BDLY(BIT); end
      end
      c = ~c;
`ifdef VERILATOR
      // v2.5.1 FIXED shadow: track the DUT receive buffer and predict
      // the echoed bytes (exact tx_mem[0..15] = buf_mem[2..17] copy)
      sh_buf[1] = HB + plen;
      for (int i = 0; i < HB; i++)   sh_buf[2 + i] = hdr[i];
      for (int i = 0; i < plen; i++) sh_buf[HB + 2 + i] = pl[i];
      for (int k = 0; k < 4; k++)    sh_buf[2 + HB + plen + k] = c[8*k +: 8];
      for (int j = 0; j < HB + plen; j++)
        exp_txm[j] = sh_buf[2 + j];
      exp_len = HB + plen;
`endif
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; `BDLY(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; `BDLY(BIT); end
      host_oe = 0;
    end
  endtask

`ifdef VERILATOR
  // runtime-bound clock wait: keeps Verilator from unrolling the loop.
  // Waits on the NEGATIVE edge: posedge resumptions contend with the DUT
  // always_ff wakeups under the 5.006 timing scheduler and intermittently
  // land a full clock late (bit-cell skew -> corrupted frames, RISK-1);
  // negedge is scheduler-quiet and also places host drives / TB samples
  // half a cycle away from the DUT's posedge sampling grid.
  task automatic bdly(input int n);
    repeat (n) @(negedge clk);
  endtask
`endif
  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    int wto;
    begin
      plen = 0; sh = 0;
`ifdef VERILATOR
      // Timing-scheduler pathology (5.006): wait() coroutine resumptions
      // are lost intermittently. Poll the level on clock edges instead,
      // bounded so a missing echo reports diagnostics instead of parking.
      wto = 0;
      while (tx !== 1'b0 && wto < 200000) begin @(negedge clk); wto++; end
      if (tx !== 1'b0) begin
        errors++;
        $display("ERROR: no echo (rx_err=%b tstate=%0d rstate=%0d ridx=%0d rbitc=%0d)",
                 dut.rx_err, dut.tstate, dut.rstate, dut.ridx, dut.rbitc);
        plen = -1;
        return;
      end
`else
      wait (tx === 1'b0);
`endif
      `BDLY(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; `BDLY(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; `BDLY(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          `BDLY(BIT);
        end
      end
      `BDLY(BIT*40);
`ifdef VERILATOR
      // Echo drain (RISK-1 root cause): the fixed tail above is not
      // cycle-exact against the DUT TX grid (extra T_END cell + tick phase),
      // so the next host frame can begin while tstate != T_IDLE; its start
      // edge then fails the start_edge guard and the frame is never armed
      // (rx_err + no echo). Wait for the TX FSM to drain on the quiet edge.
      wto = 0;
      while (dut.tstate !== 2'd0 && wto < 200000) begin @(negedge clk); wto++; end
`endif
    end
  endtask

`ifdef VERILATOR
  // ---- v2.5 CRV helpers ------------------------------------------------
  // frame with a deliberate protocol error:
  //   mode 1: corrupt CRC (stored, no echo, rx_err set)
  //   mode 2: bad STP byte, frame aborted (ignored, rx_err set)
  //   mode 3: bad END byte (stored, no echo, rx_err set)
  task automatic send_tlp_bad(input int plen, input int mode);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; `BDLY(BIT);
      fb = (mode == 2) ? 8'hFA : 8'hFB;
      for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; `BDLY(BIT); end
      if (mode == 2) begin
        host_oe = 0; `BDLY(BIT*4);     // abort: nothing else on the wire
      end else begin
        fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; `BDLY(BIT); end
        c = 32'hFFFFFFFF;
        for (int i=0;i<HB;i++) begin
          fb = hdr[i];
          for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; `BDLY(BIT); end
        end
        for (int i=0;i<plen;i++) begin
          fb = pl[i];
          for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; `BDLY(BIT); end
        end
        c = ~c;
        // shadow: bytes are stored even when the CRC/END check fails
        sh_buf[1] = HB + plen;
        for (int i = 0; i < HB; i++)   sh_buf[2 + i] = hdr[i];
        for (int i = 0; i < plen; i++) sh_buf[HB + 2 + i] = pl[i];
        for (int k = 0; k < 4; k++)
          sh_buf[2 + HB + plen + k] = (mode == 1) ? (c[8*k +: 8] ^ (k == 0)) : c[8*k +: 8];
        if (mode == 1) c = c ^ 32'h1;          // corrupt CRC: no rx_done
        for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; `BDLY(BIT); end
        fb = (mode == 3) ? 8'hFC : 8'hFD;      // corrupt END: no rx_done
        for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; `BDLY(BIT); end
        host_oe = 0;
      end
    end
  endtask

  // receive an echo and compare against the BUG-ONFI-1 shadow prediction
  task automatic crv_recv_cmp(input int plen, input int tag);
    int rlen2;
    begin
      recv_tlp(rlen2);
      if (rlen2 !== plen) begin
        errors++; $display("ERROR: CRV#%0d plen got=%0d exp=%0d", tag, rlen2, plen);
      end
      for (int i = 0; i < HB; i++) begin
        if (hdr[i] !== exp_txm[i]) begin
          errors++;
          $display("ERROR: CRV#%0d hdr[%0d] got=%h exp=%h", tag, i, hdr[i], exp_txm[i]);
        end
      end
      for (int i = 0; i < plen; i++) begin
        if (pl[i] !== exp_txm[HB+i]) begin
          errors++;
          $display("ERROR: CRV#%0d pl[%0d] got=%h exp=%h", tag, i, pl[i], exp_txm[HB+i]);
        end
      end
    end
  endtask
`endif

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: ONFI plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: ONFI pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: ONFI rx_err set"); end
`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed test above untouched) ----
    // 110 frames: random header/payload, random payload length 0..8
    // (rejection-weighted boundaries 0 and 8), echo compared against the
    // BUG-ONFI-1 shadow prediction; ~1 in 8 frames is an error injection
    // (bad CRC / bad STP / bad END -> no echo, sticky rx_err), then a
    // reset recovery: rx_err must clear and a clean frame must echo.
    begin : crv_phase
      int n_ok = 0, n_bad = 0;
      for (int i = 0; i < 23; i++) sh_buf[i] = 8'h00;   // 2-state init
      for (int t = 0; t < 110; t++) begin
        for (int i = 0; i < HB; i++) hdr[i] = $urandom_range(0, 255);
        for (int i = 0; i < 8; i++)  pl[i]  = $urandom_range(0, 255);
        rlen = $urandom_range(0, 8);
        // rejection sampling: over-weight boundary lengths 0 and 8
        if ($urandom_range(0, 9) < 3) rlen = ($urandom_range(0, 1) == 0) ? 0 : 8;
        if ($urandom_range(0, 7) == 0) begin
          // error injection: rotating corruption mode, no echo allowed
          n_bad++;
          send_tlp_bad(rlen, 1 + (n_bad % 3));
          `BDLY(BIT*80);
          if (dut.rx_err !== 1'b1) begin
            errors++; $display("ERROR: CRV#%0d rx_err not set (mode %0d)", t, 1 + (n_bad % 3));
          end
          if (tx !== 1'b1) begin
            errors++; $display("ERROR: CRV#%0d echo after bad frame", t);
          end
        end else begin
          n_ok++;
          send_tlp(rlen);
          crv_recv_cmp(rlen, t);
        end
      end
      // recovery: reset clears rx_err, device still echoes correctly
      // (deassert on the quiet edge, away from the DUT sampling grid)
      rst_n = 0; repeat(5) @(negedge clk);
      rst_n = 1; repeat(5) @(negedge clk);
      if (dut.rx_err !== 1'b0) begin
        errors++; $display("ERROR: CRV rx_err not cleared by reset");
      end
      for (int i = 0; i < HB; i++) hdr[i] = $urandom_range(0, 255);
      for (int i = 0; i < 8; i++)  pl[i]  = $urandom_range(0, 255);
      send_tlp(8);
      crv_recv_cmp(8, 999);
      $display("CRV: 110 frames (ok=%0d bad=%0d) + reset recovery", n_ok, n_bad);
    end
`endif

    if (errors == 0) $display("TEST PASSED: ONFI");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < 3; s++) visited += t_seen[s];
      for (int s = 0; s < 2; s++) visited += r_seen[s];
      $display("FSM_COV: %0d/%0d", visited, CRV_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end
`ifdef VERILATOR
  // Random phase adds traffic: extend the guard. The timeout is chunked
  // into 1-us delays: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (see docs/COVERAGE.md note 1).
  // Host timing is clock-aligned (BDLY above), so nominal test traffic is
  // ~17 ms of sim time; the guard allows >50x headroom for the scheduler
  // pathology (see W4_MEMORY.md RISK-1). Chunked per docs/COVERAGE.md n.1.
  initial begin
    repeat (100000) #10000;  // 1 s in 10-us chunks
    $display("TIMEOUT"); $finish;
  end

`else
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
`endif
endmodule
