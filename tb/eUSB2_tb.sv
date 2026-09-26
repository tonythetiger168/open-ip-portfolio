// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for eUSB2_top -- SystemVerilog
// Link-partner model: drives eD+/eD- single-ended NRZI bit streams (control
// packets, data frames, squelch/SE1 scenarios) and checks the retimed dp/dm
// output plus register read responses.
// IP design verification v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module eUSB2_tb;

  logic clk = 0, rst_n = 0;
  logic edp, edm;
  logic dp, dm, squelch, irq;

  int errors = 0;

  // host-side bit-stream state
  logic tb_cur;          // currently driven state: 1 = J, 0 = K
  int   ones_tb;         // consecutive 1-bits (for stuffing)

  eUSB2_top dut (
    .clk(clk), .rst_n(rst_n),
    .edp(edp), .edm(edm),
    .dp(dp), .dm(dm),
    .squelch(squelch), .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // retime monitor: dp/dm must equal eD+/eD- delayed by exactly 1 clk
  // ------------------------------------------------------------------
  logic mon_en = 1'b0;
  logic edp_d = 1'b0, edm_d = 1'b0;
  int   retime_errs = 0;
  always @(posedge clk) begin
    if (mon_en && ({dp, dm} !== {edp_d, edm_d}))
      retime_errs = retime_errs + 1;
    edp_d <= edp;
    edm_d <= edm;
  end

  // ------------------------------------------------------------------
  // CRC8 (mirror DUT), poly 0x07, init 0xFF, MSB-first
  // ------------------------------------------------------------------
  function automatic logic [7:0] crc8_b(input logic [7:0] c_in,
                                        input logic [7:0] d);
    logic [7:0] c;
    logic       fb;
    begin
      c = c_in;
      for (int i = 7; i >= 0; i--) begin
        fb = d[i] ^ c[7];
        c  = {c[6:0], 1'b0};
        if (fb) c = c ^ 8'h07;
      end
      crc8_b = c;
    end
  endfunction

  // ------------------------------------------------------------------
  // bit-stream drivers (one bit cell per clk)
  // ------------------------------------------------------------------
  task automatic drive(input logic p, input logic m);
    begin
      @(negedge clk);
      edp <= p;
      edm <= m;
    end
  endtask

  task automatic send_bit(input logic b);
    begin
      if (!b) tb_cur = ~tb_cur;      // NRZI: 0 = toggle
      drive(tb_cur, ~tb_cur);
    end
  endtask

  task automatic send_byte(input logic [7:0] d);
    begin
      for (int i = 0; i < 8; i++) begin
        send_bit(d[i]);              // LSB first
        if (d[i]) begin
          ones_tb = ones_tb + 1;
          if (ones_tb == 6) begin
            send_bit(1'b0);          // bit stuffing
            ones_tb = 0;
          end
        end else begin
          ones_tb = 0;
        end
      end
    end
  endtask

  task automatic send_sync;
    begin
      repeat (7) send_bit(1'b0);     // KJKJKJKK from idle J
      send_bit(1'b1);
      ones_tb = 0;
    end
  endtask

  task automatic send_eop;
    begin
      drive(1'b0, 1'b0);             // SE0
      drive(1'b0, 1'b0);             // SE0
      drive(1'b1, 1'b0);             // J
      tb_cur  = 1'b1;
      ones_tb = 0;
    end
  endtask

  // ------------------------------------------------------------------
  // control packet transactions (PID 8'hC3)
  // ------------------------------------------------------------------
  task automatic ctrl_write(input logic [2:0] addr, input logic [7:0] data,
                            input logic corrupt);
    logic [7:0] cmd, c;
    begin
      cmd = {1'b0, addr, 4'b0000};
      send_sync;
      send_byte(8'hC3);
      send_byte(cmd);
      send_byte(data);
      c = crc8_b(crc8_b(8'hFF, cmd), data);
      if (corrupt) c = c ^ 8'h01;
      send_byte(c);
      send_eop;
      repeat (3) drive(1'b1, 1'b0);
    end
  endtask

  task automatic ctrl_read_req(input logic [2:0] addr);
    logic [7:0] cmd;
    begin
      cmd = {1'b1, addr, 4'b0000};
      send_sync;
      send_byte(8'hC3);
      send_byte(cmd);
      send_byte(crc8_b(8'hFF, cmd));
      send_eop;
    end
  endtask

  // receive and verify a read-response frame on dp/dm
  task automatic recv_resp(input logic [2:0] exp_addr,
                           input logic [7:0] exp_data);
    logic       prev, cur, b;
    int         zeros, ones, nbits, nb, t, guard;
    logic [7:0] sh;
    logic [7:0] bytes [0:3];
    logic       sync_done, eop_seen;
    begin
      t = 0;
      while ({dp, dm} !== 2'b01 && t < 300) begin  // wait for K (sync start)
        @(negedge clk); t = t + 1;
      end
      if (t >= 300) begin
        errors++;
        $display("ERROR: timeout waiting for read response");
      end else begin
        prev = 1'b0;                  // first cell already observed: K
        zeros = 1;                    // first K cell = sync bit 0
        ones = 0; nbits = 0; nb = 0; sh = 8'h00; guard = 0;
        sync_done = 1'b0; eop_seen = 1'b0;
        while (!eop_seen && guard < 300) begin
          @(negedge clk); guard = guard + 1;
          if ({dp, dm} == 2'b00) begin
            eop_seen = 1'b1;
          end else if ({dp, dm} == 2'b11) begin
            errors++;
            $display("ERROR: SE1 inside read response");
            eop_seen = 1'b1;
          end else begin
            cur  = dp;
            b    = (cur == prev);
            prev = cur;
            if (!sync_done) begin
              if (!b) begin
                zeros = zeros + 1;
              end else begin
                if (zeros == 7) sync_done = 1'b1;
                zeros = 0;
              end
            end else if (ones == 6) begin
              if (!b) begin
                ones = 0;             // stuffed bit dropped
              end else begin
                errors++;
                $display("ERROR: bit-stuff error in read response");
                ones = 0;
              end
            end else begin
              sh = {b, sh[7:1]};
              nbits = nbits + 1;
              if (b) ones = ones + 1; else ones = 0;
              if (nbits == 8) begin
                if (nb < 4) begin
                  bytes[nb] = sh;
                  nb = nb + 1;
                end
                nbits = 0;
              end
            end
          end
        end
        if (guard >= 300) begin
          errors++;
          $display("ERROR: read response EOP missing");
        end
        if (nb != 4) begin
          errors++;
          $display("ERROR: response byte count %0d, expected 4", nb);
        end else begin
          if (bytes[0] !== 8'h3C) begin
            errors++;
            $display("ERROR: response PID %h, expected 3C", bytes[0]);
          end
          if (bytes[1] !== {1'b1, exp_addr, 4'b0000}) begin
            errors++;
            $display("ERROR: response cmd %h, addr mismatch", bytes[1]);
          end
          if (bytes[2] !== exp_data) begin
            errors++;
            $display("ERROR: read data %h, expected %h", bytes[2], exp_data);
          end
          if (bytes[3] !== crc8_b(crc8_b(8'hFF, bytes[1]), bytes[2])) begin
            errors++;
            $display("ERROR: response CRC8 %h mismatch", bytes[3]);
          end
        end
      end
      repeat (4) drive(1'b1, 1'b0);   // let DUT return to retime mode
    end
  endtask

  task automatic ctrl_read(input logic [2:0] addr, input logic [7:0] exp);
    begin
      ctrl_read_req(addr);
      recv_resp(addr, exp);
    end
  endtask

  // non-control USB2 data frame (content irrelevant; retime-checked)
  task automatic send_data_frame;
    begin
      send_sync;
      send_byte(8'h3C);               // DATA0-style PID
      send_byte(8'h11);
      send_byte(8'hFE);               // long 1-runs exercise stuffing
      send_byte(8'hFF);
      send_byte(8'h55);
      send_byte(8'h9A);
      send_eop;
    end
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions.
  // =====================================================================
  localparam int EUSB2_FSM_TOTAL = 8;  // pstate(2) + rstate(6)
  logic [7:0] fsm_seen = '0;           // visited-state bitmap
  wire        dut_pstate = dut.pstate; // hierarchical FSM probes
  wire  [2:0] dut_rstate = dut.rstate;

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
    fsm_seen[dut_pstate]     <= 1'b1;
    fsm_seen[2 + dut_rstate] <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic irq_q = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(squelch === 1'b0 && irq === 1'b0 && {dp, dm} === 2'b00,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: state registers hold legal enum encodings
      sva_check(dut.pstate <= 1'd1 && dut_rstate <= 3'd5, "A2 state encodings legal");
      // A3: irq is sticky once set (cleared only by reset)
      sva_check(!irq_q || irq, "A3 irq sticky");
      // A4: squelch silences the outputs unless a response owns the mux
      sva_check(!squelch || dut.resp_active || ({dp, dm} === 2'b00),
                "A4 squelch silences dp/dm");
      // A5: response FSM active only while resp_active is set
      sva_check((dut_rstate == 3'd0) || (dut.resp_active === 1'b1),
                "A5 rstate active implies resp_active");
      // A6: response frames never drive illegal SE1
      sva_check(!dut.resp_active || ({dp, dm} !== 2'b11), "A6 response never SE1");
      // A7: during squelched SE0 the count stays at/above the threshold
      // (K resets se0_cnt while squelch holds, so gate on the SE0 line)
      sva_check(!(squelch && ({edp, edm} == 2'b00)) || (dut.se0_cnt >= dut.regfile[0]),
                "A7 squelch threshold held during SE0");
    end
    irq_q <= irq;
  end

  // ---- constrained-random scenario tasks ------------------------------
  logic [7:0] reg_model [0:7];   // TB shadow of the DUT register file
  bit         first_err = 0;     // irq is sticky: only first error checks 0->1

  task automatic crv_irq_expect;
    begin
      if (!first_err) begin
        if (irq !== 1'b1) begin
          errors++; $display("ERROR: CRV irq not set on first error injection");
        end
        first_err = 1;
      end else if (irq !== 1'b1) begin
        errors++; $display("ERROR: CRV irq dropped (must be sticky)");
      end
    end
  endtask

  // good register write + readback
  task automatic crv_wr_rd(input logic [2:0] a, input logic [7:0] d);
    begin
      ctrl_write(a, d, 1'b0);
      reg_model[a] = d;
      ctrl_read(a, reg_model[a]);
    end
  endtask

  // corrupted-CRC write must be ignored
  task automatic crv_wr_bad(input logic [2:0] a, input logic [7:0] d);
    begin
      ctrl_write(a, d, 1'b1);
      ctrl_read(a, reg_model[a]);       // old value retained
      crv_irq_expect;
    end
  endtask

  // truncated control write (no CRC byte) -> irq, register untouched
  task automatic crv_trunc(input logic [2:0] a, input logic [7:0] d);
    logic [7:0] cmd;
    begin
      cmd = {1'b0, a, 4'b0000};
      send_sync;
      send_byte(8'hC3);
      send_byte(cmd);
      send_byte(d);
      send_eop;                          // EOP before CRC -> truncated
      repeat (3) drive(1'b1, 1'b0);
      ctrl_read(a, reg_model[a]);
      crv_irq_expect;
    end
  endtask

  // random data frame with retime monitor
  task automatic crv_data;
    begin
      mon_en = 1'b1;
      send_sync;
      send_byte(8'h3C);
      for (int i = 0; i < 6; i++) send_byte($urandom_range(0, 255));
      send_eop;
      repeat (3) drive(1'b1, 1'b0);
      mon_en = 1'b0;
    end
  endtask

  // bit-stuff violation inside a data frame -> irq
  task automatic crv_stuff;
    begin
      mon_en = 1'b0;                     // DUT drops the frame; mux follows input
      send_sync;
      send_byte(8'h3C);
      for (int i = 0; i < 7; i++) send_bit(1'b1);  // 7 raw ones: violation
      send_eop;
      repeat (3) drive(1'b1, 1'b0);
      crv_irq_expect;
    end
  endtask

  // SE1 injection -> irq
  task automatic crv_se1;
    begin
      drive(1'b1, 1'b1);
      drive(1'b1, 1'b0);
      drive(1'b1, 1'b0);
      crv_irq_expect;
    end
  endtask

  // squelch cycle with random threshold: SE0 > thr silences, only J exits
  task automatic crv_squelch(input logic [7:0] thr);
    begin
      ctrl_write(3'd0, thr, 1'b0);
      reg_model[0] = thr;
      repeat (thr + 4) drive(1'b0, 1'b0);
      if (squelch !== 1'b1) begin
        errors++; $display("ERROR: CRV squelch not detected (thr=%0d)", thr);
      end
      if ({dp, dm} !== 2'b00) begin
        errors++; $display("ERROR: CRV outputs not silenced during squelch");
      end
      drive(1'b0, 1'b1); drive(1'b0, 1'b1);      // K must not clear
      if (squelch !== 1'b1) begin
        errors++; $display("ERROR: CRV squelch cleared by K");
      end
      repeat (3) drive(1'b1, 1'b0);              // J exits squelch
      if (squelch !== 1'b0) begin
        errors++; $display("ERROR: CRV squelch did not clear on J");
      end
      retime_errs = 0;                            // recovery retime check
      crv_data;
      if (retime_errs != 0) begin
        errors++; $display("ERROR: CRV retime mismatch after squelch");
      end
    end
  endtask
`endif

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  initial begin
    edp = 1'b1; edm = 1'b0;           // idle J
    tb_cur = 1'b1; ones_tb = 0;
    rst_n = 0;
    repeat (5) @(negedge clk);

    // ---- check 1: reset state --------------------------------------
    if ({dp, dm} !== 2'b00) begin
      errors++; $display("ERROR: reset dp/dm=%b%b, expected SE0", dp, dm);
    end
    if (squelch !== 1'b0) begin
      errors++; $display("ERROR: reset squelch=%b", squelch);
    end
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: reset irq=%b", irq);
    end
    rst_n = 1;

    // ---- check 2: idle J retimed to dp/dm --------------------------
    repeat (4) drive(1'b1, 1'b0);
    if ({dp, dm} !== 2'b10) begin
      errors++; $display("ERROR: idle J not retimed, dp/dm=%b%b", dp, dm);
    end

    // ---- check 3: control register write/read x3 (back-to-back) ----
    ctrl_write(3'd1, 8'hA5, 1'b0);
    ctrl_write(3'd2, 8'h3C, 1'b0);
    ctrl_write(3'd3, 8'hFF, 1'b0);
    ctrl_read(3'd1, 8'hA5);
    ctrl_read(3'd2, 8'h3C);
    ctrl_read(3'd3, 8'hFF);

    // ---- check 4: squelch-threshold register write/read ------------
    ctrl_write(3'd0, 8'd6, 1'b0);
    ctrl_read(3'd0, 8'd6);

    if (irq !== 1'b0) begin
      errors++; $display("ERROR: irq set during error-free operations");
    end

    // ---- check 5: end-to-end retime of USB2 data frames ------------
    retime_errs = 0;
    repeat (2) drive(1'b1, 1'b0);
    mon_en = 1'b1;
    send_data_frame;
    repeat (2) drive(1'b1, 1'b0);
    send_data_frame;                // consecutive frames
    repeat (3) drive(1'b1, 1'b0);
    mon_en = 1'b0;
    if (retime_errs != 0) begin
      errors++;
      $display("ERROR: %0d retime mismatches on data frames", retime_errs);
    end

    // ---- check 6: squelch scenario (threshold now 6) ---------------
    repeat (10) drive(1'b0, 1'b0);    // long SE0 -> signal loss
    if (squelch !== 1'b1) begin
      errors++; $display("ERROR: squelch not detected after long SE0");
    end
    if ({dp, dm} !== 2'b00) begin
      errors++; $display("ERROR: outputs not silenced during squelch");
    end
    drive(1'b0, 1'b1);                // K while squelched: squelch holds
    drive(1'b0, 1'b1);
    if (squelch !== 1'b1) begin
      errors++; $display("ERROR: squelch cleared by K (only J may clear)");
    end
    if ({dp, dm} !== 2'b00) begin
      errors++; $display("ERROR: outputs not silenced during squelched K");
    end
    repeat (3) drive(1'b1, 1'b0);     // J: exit squelch
    if (squelch !== 1'b0) begin
      errors++; $display("ERROR: squelch did not clear on J");
    end
    retime_errs = 0;                  // recovery: retime works again
    mon_en = 1'b1;
    send_data_frame;
    repeat (3) drive(1'b1, 1'b0);
    mon_en = 1'b0;
    if (retime_errs != 0) begin
      errors++;
      $display("ERROR: %0d retime mismatches after squelch", retime_errs);
    end

    // ---- check 7: SE1 injection -> irq ------------------------------
    drive(1'b1, 1'b1);                // illegal single-ended state
    drive(1'b1, 1'b0);
    drive(1'b1, 1'b0);
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not set after SE1 injection");
    end

    // ---- check 8: bad CRC8 control write is ignored -----------------
    ctrl_write(3'd4, 8'h77, 1'b1);    // corrupted CRC8
    ctrl_read(3'd4, 8'h00);           // register must keep reset value

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    begin : crv_phase
      int n_wr = 0, n_bad = 0, n_tr = 0, n_dat = 0, n_stf = 0, n_se1 = 0,
          n_sq = 0, n_rd = 0;
      int roll;
      // shadow model starts from the directed-test end state
      reg_model[0] = 8'd6;  reg_model[1] = 8'hA5; reg_model[2] = 8'h3C;
      reg_model[3] = 8'hFF; reg_model[4] = 8'h00; reg_model[5] = 8'h00;
      reg_model[6] = 8'h00; reg_model[7] = 8'h00;
      retime_errs = 0;
      // forced boundary txns for toggle closure (all regs full-swing,
      // one long-SE0 squelch to walk se0_cnt above 128)
      crv_wr_rd(3'd0, 8'hFF);   // threshold 255 (rewritten per squelch txn)
      crv_wr_rd(3'd1, 8'hFF);
      crv_wr_rd(3'd4, 8'hFF);
      crv_wr_rd(3'd5, 8'hFF);
      crv_wr_rd(3'd6, 8'hFF);
      crv_wr_rd(3'd7, 8'hFF);
      crv_squelch(8'd132);      // se0_cnt walks 0..136 -> bits [7:5] toggle
      for (int t = 0; t < 100; t++) begin
        roll = $urandom_range(0, 99);
        if (roll < 30) begin
          n_wr++;  crv_wr_rd($urandom_range(0, 7), $urandom_range(0, 255));
        end else if (roll < 42) begin
          n_bad++; crv_wr_bad($urandom_range(0, 7), $urandom_range(0, 255));
        end else if (roll < 50) begin
          n_tr++;  crv_trunc($urandom_range(0, 7), $urandom_range(0, 255));
        end else if (roll < 65) begin
          n_dat++; crv_data;
        end else if (roll < 73) begin
          n_stf++; crv_stuff;
        end else if (roll < 80) begin
          n_se1++; crv_se1;
        end else if (roll < 90) begin
          n_sq++;  crv_squelch($urandom_range(1, 20));
        end else begin : p_rd
          logic [2:0] ra;
          ra = $urandom_range(0, 7);
          n_rd++;  ctrl_read(ra, reg_model[ra]);
        end
      end
      if (retime_errs != 0) begin
        errors++; $display("ERROR: CRV %0d retime mismatches", retime_errs);
      end
      $display("CRV: 100 txns (wr_rd=%0d bad_crc=%0d trunc=%0d data=%0d stuff=%0d se1=%0d squelch=%0d read=%0d)",
               n_wr, n_bad, n_tr, n_dat, n_stf, n_se1, n_sq, n_rd);
    end
`endif
    // ---- summary -----------------------------------------------------
    if (errors == 0)
      $display("TEST PASSED: eUSB2");
    else
      $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < EUSB2_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, EUSB2_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // timeout guard
`ifdef VERILATOR
  // CRV phase adds ~0.2 ms of stimulus: the guard is chunked into 1-us
  // delays: with Verilator 5.006 a single long-pending #delay event
  // corrupts the --timing delay heap (docs/COVERAGE.md note 1).
  initial begin
    repeat (3000) #1000;    // 3 ms in 1-us chunks
    $display("ERROR: TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #2000000;
    $display("ERROR: TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif

endmodule
