// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for JTAG_top: IDCODE / USER / BYPASS scans
// Reference: OpenCores jtag test sequences -- SystemVerilog
`timescale 1ns/1ps
module JTAG_tb;
  logic clk = 0, rst_n = 0;
  logic tck = 0, tms = 1, tdi = 0, trst_n = 0;
  logic tdo;
  logic tdo_s;
  int errors = 0;

  JTAG_top dut (
    .clk(clk), .rst_n(rst_n), .tck(tck), .tms(tms), .tdi(tdi),
    .trst_n(trst_n), .tdo(tdo), .irq());

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSM probed: dut.tap_q (IEEE 1149.1 TAP, 16 states).
  // =====================================================================
  localparam int JTAG_FSM_TOTAL = 16;  // TLR..UPD_IR
  logic [15:0] fsm_seen = '0;          // visited-state bitmap
  wire  [3:0]  dut_state = dut.tap_q;

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

  // FSM coverage: sample TAP state every TCK
  always @(posedge tck) fsm_seen[dut_state] <= 1'b1;

  // reference next-state function (mirror of the TAP FSM)
  function automatic logic [3:0] tap_next(input logic [3:0] s, input logic m);
    case (s)
      4'd0:  tap_next = m ? 4'd0  : 4'd1;    // TLR
      4'd1:  tap_next = m ? 4'd2  : 4'd1;    // RTI
      4'd2:  tap_next = m ? 4'd9  : 4'd3;    // SEL_DR
      4'd3:  tap_next = m ? 4'd5  : 4'd4;    // CAP_DR
      4'd4:  tap_next = m ? 4'd5  : 4'd4;    // SH_DR
      4'd5:  tap_next = m ? 4'd8  : 4'd6;    // EX1_DR
      4'd6:  tap_next = m ? 4'd7  : 4'd6;    // PAUSE_DR
      4'd7:  tap_next = m ? 4'd8  : 4'd4;    // EX2_DR
      4'd8:  tap_next = m ? 4'd2  : 4'd1;    // UPD_DR
      4'd9:  tap_next = m ? 4'd0  : 4'd10;   // SEL_IR
      4'd10: tap_next = m ? 4'd12 : 4'd11;   // CAP_IR
      4'd11: tap_next = m ? 4'd12 : 4'd11;   // SH_IR
      4'd12: tap_next = m ? 4'd15 : 4'd13;   // EX1_IR
      4'd13: tap_next = m ? 4'd14 : 4'd13;   // PAUSE_IR
      4'd14: tap_next = m ? 4'd15 : 4'd11;   // EX2_IR
      4'd15: tap_next = m ? 4'd2  : 4'd1;    // UPD_IR
      default: tap_next = 4'd0;
    endcase
  endfunction

  // output-invariant assertion suite (TCK domain, pre-NBA)
  logic [3:0] state_q = '0, state_qq = '0;
  logic       tms_q = 1'b1;
  logic [3:0] ir_q_q = '0;
  logic       trst_n_q = 1'b1, irq_q = 1'b0;
  always @(posedge tck) begin
    if (!trst_n) begin
      // A1: TAP forced to TLR during test-reset
      if (!trst_n_q) sva_check(dut_state == 4'd0, "A1 trst: TAP in TLR");
    end else begin
      // A2: state transition matches the reference next-state function
      //     (skipped for the first TCK after a test-reset release)
      if (trst_n_q)
        sva_check(dut_state == tap_next(state_q, tms_q), "A2 TAP transition legal");
      // A3: irq asserted exactly in UPD_DR
      sva_check(dut.irq === (dut_state == 4'd8), "A3 irq == UPD_DR");
      // A4: tdo never X
      sva_check(!$isunknown(tdo), "A4 tdo never X");
      // A5: irq is a single-TCK pulse (UPD_DR left after one cycle)
      sva_check(!(dut.irq && irq_q), "A5 irq single-cycle pulse");
      // A6: ir_q changes only right after UPD_IR
      sva_check((dut.ir_q === ir_q_q) || (state_q == 4'd15),
                "A6 ir_q updates only at UPD_IR");
    end
    state_qq <= state_q;
    state_q  <= dut_state;
    tms_q    <= tms;
    ir_q_q   <= dut.ir_q;
    trst_n_q <= trst_n;
    irq_q    <= dut.irq;
  end
`endif

  task automatic jcyc(input logic tms_v, input logic tdi_v);
    begin
      tms = tms_v; tdi = tdi_v;
      #100 tck = 1'b1; #100;
      tck = 1'b0; #10 tdo_s = tdo; #90;
    end
  endtask

  task automatic goto_rti;
    begin
      for (int i = 0; i < 5; i++) jcyc(1'b1, 1'b0);   // TLR
      jcyc(1'b0, 1'b0);                               // RTI
    end
  endtask

  // shift IR (4 bits, LSB first), last bit exits to UPDATE_IR
  task automatic load_ir(input logic [3:0] op);
    begin
      jcyc(1'b1, 1'b0);                 // SEL_DR
      jcyc(1'b1, 1'b0);                 // SEL_IR
      jcyc(1'b0, 1'b0);                 // -> CAP_IR
      jcyc(1'b0, 1'b0);                 // CAP_IR: capture 0101, -> SH_IR
      jcyc(1'b0, op[0]);                // shift 1
      jcyc(1'b0, op[1]);                // shift 2
      jcyc(1'b0, op[2]);                // shift 3
      jcyc(1'b1, op[3]);                // shift 4 + exit
      jcyc(1'b1, 1'b0);                 // UPD_IR
      jcyc(1'b0, 1'b0);                 // RTI
    end
  endtask

  task automatic scan_dr(input int n, input logic [31:0] din,
                         output logic [31:0] dout);
    logic [31:0] tmp;
    begin
      jcyc(1'b1, 1'b0);                 // SEL_DR
      jcyc(1'b0, 1'b0);                 // -> CAP_DR
      jcyc(1'b0, 1'b0);                 // CAP_DR: capture, -> SH_DR
      for (int k = 0; k < n; k++) begin
        jcyc(k == n-1, din[k]);         // shift bit k, TDO shows pre-shift LSB
        tmp[k] = tdo_s;
      end
      jcyc(1'b1, 1'b0);                 // EX1_DR -> UPD_DR
      jcyc(1'b0, 1'b0);                 // -> RTI
      dout = tmp;
    end
  endtask

  logic [31:0] rd;
  initial begin
    rst_n = 0; trst_n = 0;
    #200;
    rst_n = 1; trst_n = 1;
    #500;

    // ---- IDCODE scan ----
    goto_rti;
    load_ir(4'b0001);                      // IDCODE
    scan_dr(32, 32'h0, rd);
    if (rd !== 32'h1CAF_0001) begin
      errors++; $display("ERROR: JTAG IDCODE got=%h exp=1CAF0001", rd);
    end

    // ---- USER reg write 0xA5 then read back ----
    goto_rti;
    load_ir(4'b0010);                      // USER
    scan_dr(8, 32'h0000_00A5, rd);
    goto_rti;
    load_ir(4'b0010);
    scan_dr(8, 32'h0, rd);
    if (rd[7:0] !== 8'hA5) begin
      errors++; $display("ERROR: JTAG USER got=%h exp=A5", rd[7:0]);
    end

    // ---- BYPASS: scanned value = {din[6:0], capture_bit} = din<<1 ----
    goto_rti;
    load_ir(4'b1111);                      // BYPASS
    scan_dr(8, 32'h0000_003C, rd);         // pattern 00111100 LSB-first
    if (rd[7:0] !== 8'h78) begin           // capture(0) first, then din[0..6]
      errors++; $display("ERROR: JTAG BYPASS got=%h exp=78", rd[7:0]);
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 100 randomized scan transactions: random IR (IDCODE/USER/BYPASS/
    // reserved), random DR data; USER write+readback self-check, BYPASS
    // shift model, IDCODE constant. Plus random TMS walks to sweep all
    // 16 TAP states (pause/exit paths included).
    begin : crv_phase
      int n_id = 0, n_usr = 0, n_byp = 0, n_rsv = 0;
      logic [3:0] op;
      logic [31:0] din_c;
      logic [7:0]  uv;
      int roll;
      for (int t = 0; t < 100; t++) begin
        roll = $urandom_range(0, 9);
        goto_rti;
        if (roll < 3) begin
          // IDCODE: constant readback, random don't-care shift-in
          n_id++;
          load_ir(4'b0001);
          din_c = $urandom;
          scan_dr(32, din_c, rd);
          if (rd !== 32'h1CAF_0001) begin
            errors++; $display("ERROR: CRV IDCODE got=%h", rd);
          end
        end else if (roll < 6) begin
          // USER: write random byte, read back in a second scan
          n_usr++;
          uv = $urandom_range(0, 255);
          load_ir(4'b0010);
          scan_dr(8, {24'h0, uv}, rd);
          goto_rti;
          load_ir(4'b0010);
          scan_dr(8, 32'h0, rd);
          if (rd[7:0] !== uv) begin
            errors++; $display("ERROR: CRV USER got=%h exp=%h", rd[7:0], uv);
          end
        end else if (roll < 8) begin
          // BYPASS: out = {din[6:0], capture(0)} == din<<1 (8-bit window)
          n_byp++;
          din_c = $urandom_range(0, 255);
          load_ir(4'b1111);
          scan_dr(8, din_c, rd);
          if (rd[7:0] !== ((din_c << 1) & 8'hFF)) begin
            errors++; $display("ERROR: CRV BYPASS got=%h exp=%h",
                               rd[7:0], ((din_c << 1) & 8'hFF));
          end
        end else begin
          // reserved IR (error class): DR falls back to BYPASS
          n_rsv++;
          op = $urandom_range(0, 15);
          if (op == 4'b0001 || op == 4'b0010 || op == 4'b1111) op = 4'b0000;
          din_c = $urandom_range(0, 255);
          load_ir(op);
          scan_dr(8, din_c, rd);
          if (rd[7:0] !== ((din_c << 1) & 8'hFF)) begin
            errors++; $display("ERROR: CRV reserved-IR BYPASS got=%h exp=%h",
                               rd[7:0], ((din_c << 1) & 8'hFF));
          end
        end
        // random TMS walk (state sweep), then re-synchronize at RTI
        for (int w = 0; w < 24; w++) jcyc($urandom_range(0, 1), $urandom_range(0, 1));
      end
      goto_rti;
      // error injection: async test-reset mid-scan, then re-scan IDCODE
      load_ir(4'b0010);
      jcyc(1'b1, 1'b0);               // SEL_DR mid-sequence
      trst_n = 1'b0;
      for (int i = 0; i < 3; i++) jcyc(1'b0, 1'b0);
      trst_n = 1'b1;
      #50;
      goto_rti;
      load_ir(4'b0001);
      scan_dr(32, 32'h0, rd);
      if (rd !== 32'h1CAF_0001) begin
        errors++; $display("ERROR: CRV IDCODE after mid-scan TRST got=%h", rd);
      end
      $display("CRV: 100 scans (idcode=%0d user=%0d bypass=%0d reserved=%0d) + TMS walks",
               n_id, n_usr, n_byp, n_rsv);
    end
`endif

    if (errors == 0) $display("TEST PASSED: JTAG");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < JTAG_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, JTAG_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard: a single long-pending #delay event corrupts the
  // 5.006 --timing delay heap once many short-delay resumptions interleave;
  // chunked delays keep all heap entries short-lived (see docs/COVERAGE.md)
  initial begin
    repeat (10000) #1000;  // 10 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #5_000_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
