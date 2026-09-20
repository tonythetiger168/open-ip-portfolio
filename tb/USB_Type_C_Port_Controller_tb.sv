// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for USB_Type_C_Port_Controller_top -- SystemVerilog
// TB plays the Type-C port partner: drives cc1/cc2 3-level enums through
// attach / detach / flipped-plug / glitch / fault scenarios and exercises
// the 8x8 register command port (RO readback, RW role, RW1C status).
// IP design implementation v1.0 -- Apache-2.0
`timescale 1ns/1ps
module USB_Type_C_Port_Controller_tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  logic [1:0] cc1, cc2;
  logic attached, orientation, vbus_en;
  logic [2:0] reg_addr;
  logic [7:0] reg_wdata, reg_rdata;
  logic reg_rd, reg_wr, irq;

  int errors = 0;

  localparam logic [1:0] CC_OPEN = 2'b00;
  localparam logic [1:0] CC_RD   = 2'b01;
  localparam logic [1:0] CC_RA   = 2'b10;
  localparam logic [1:0] CC_BAD  = 2'b11;

  USB_Type_C_Port_Controller_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .cc1(cc1), .cc2(cc2),
    .attached(attached), .orientation(orientation), .vbus_en(vbus_en),
    .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
    .reg_rd(reg_rd), .reg_wr(reg_wr),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // register port tasks
  // ------------------------------------------------------------------
  task automatic reg_write(input logic [2:0] a, input logic [7:0] d);
    begin
      @(negedge clk);
      reg_addr <= a; reg_wdata <= d; reg_wr <= 1'b1;
      @(negedge clk);
      reg_wr <= 1'b0;
    end
  endtask

  task automatic reg_read(input logic [2:0] a, input logic [7:0] exp);
    logic [7:0] got;
    begin
      @(negedge clk);
      reg_addr <= a; reg_rd <= 1'b1;
      @(posedge clk); #1 got = reg_rdata;
      @(negedge clk);
      reg_rd <= 1'b0;
      if (got !== exp) begin
        errors++;
        $display("ERROR: reg read @%0d got=%h exp=%h", a, got, exp);
      end
    end
  endtask

  task automatic chk(input logic cond, input string msg);
    begin
      if (!cond) begin
        errors++;
        $display("ERROR: %s", msg);
      end
    end
  endtask

  task automatic clear_ints;
    begin
      reg_write(3'd3, 8'h07);       // W1C all sticky interrupt bits
      reg_write(3'd2, 8'h01);       // W1C fault status
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
  localparam int TCPC_FSM_TOTAL = 3;   // ST_UNATTACHED/ST_ATTACHWAIT/ST_ATTACHED
  logic [2:0] fsm_seen = '0;           // visited-state bitmap
  wire  [1:0] dut_state = dut.state;   // hierarchical FSM probe

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

  // FSM coverage: sample DUT state register every clock
  always @(posedge clk) fsm_seen[dut_state] <= 1'b1;

  // output-invariant assertion suite (sampled coherently pre-NBA)
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(attached === 1'b0 && vbus_en === 1'b0 && irq === 1'b0 &&
                orientation === 1'b0, "A1 reset: outputs quiescent");
    end else begin
      // A2: state register holds a legal enum encoding
      sva_check(dut_state <= 2'd2, "A2 state encoding legal");
      // A3: vbus_en == attached && source-role
      sva_check(vbus_en === (attached && dut.role_src_q), "A3 vbus_en == attached&&src");
      // A4: attached output == (state == ST_ATTACHED)
      sva_check(attached === (dut_state == 2'd2), "A4 attached == ST_ATTACHED");
      // A5: irq == live fault OR any sticky int bit
      sva_check(irq === ((cc1 == 2'b11) || (cc2 == 2'b11) || (|dut.int_sticky)),
                "A5 irq composition");
      // A6: debounce counters stay inside their programmed ranges
      sva_check(dut.deb_cnt <= 7'd99 && dut.rel_cnt <= 4'd9, "A6 debounce ranges");
      // A7: unattached implies vbus off
      sva_check((dut_state != 2'd0) || (vbus_en === 1'b0), "A7 unattached => vbus off");
    end
  end

  // ---- constrained-random scenario tasks ------------------------------
  // attach+detach cycle on a random pin with random hold time
  task automatic crv_cycle(input bit pin2, input int hold);
    begin
      if (pin2) cc2 = CC_RD; else cc1 = CC_RD;
      repeat (hold) @(posedge clk);
      chk(attached === 1'b1, "CRV attach after full debounce");
      chk(orientation === pin2, "CRV orientation matches wired CC pin");
      chk(irq === 1'b1, "CRV irq after attach event");
      reg_read(3'd3, 8'h01);                    // INT_STAT attach bit
      clear_ints;
      @(posedge clk); #1;
      chk(irq === 1'b0, "CRV irq cleared after attach W1C");
      cc1 = CC_OPEN; cc2 = CC_OPEN;
      repeat (15) @(posedge clk);
      chk(attached === 1'b0, "CRV detach after release debounce");
      chk(irq === 1'b1, "CRV irq after detach event");
      reg_read(3'd3, 8'h02);                    // INT_STAT detach bit
      clear_ints;
    end
  endtask

  // glitch: Rd pulse shorter than the 100-clk debounce must not attach
  task automatic crv_glitch(input bit pin2, input int hold);
    begin
      if (pin2) cc2 = CC_RD; else cc1 = CC_RD;
      repeat (hold) @(posedge clk);
      chk(attached === 1'b0, "CRV glitch must not attach");
      cc1 = CC_OPEN; cc2 = CC_OPEN;
      repeat (20) @(posedge clk);
      chk(attached === 1'b0, "CRV still unattached after glitch");
      reg_read(3'd3, 8'h00);                    // no attach/detach events
    end
  endtask

  // abnormal CC level: live irq + sticky fault, cleared by W1C
  task automatic crv_fault(input bit pin2, input int hold);
    begin
      if (pin2) cc2 = CC_BAD; else cc1 = CC_BAD;
      repeat (hold) @(posedge clk);
      chk(irq === 1'b1, "CRV irq on CC fault");
      reg_read(3'd2, 8'h01);                    // FAULT_STAT sticky
      reg_read(3'd3, 8'h04);                    // INT_STAT fault bit
      cc1 = CC_OPEN; cc2 = CC_OPEN;
      repeat (2) @(posedge clk);
      chk(irq === 1'b1, "CRV irq sticky after fault removed");
      clear_ints;
      @(posedge clk); #1;
      chk(irq === 1'b0, "CRV irq cleared after fault W1C");
      reg_read(3'd2, 8'h00);
    end
  endtask

  // non-sink levels (Ra-only or Rd on both pins): never an attach
  task automatic crv_nonsink(input int mode);
    begin
      case (mode)
        0: cc1 = CC_RA;
        1: cc2 = CC_RA;
        default: begin cc1 = CC_RD; cc2 = CC_RD; end
      endcase
      repeat (120) @(posedge clk);
      chk(attached === 1'b0, "CRV Ra-only/both-Rd must not attach");
      chk(irq === 1'b0, "CRV no events for non-sink levels");
      // CC_STATUS readback with hot CC levels (toggles reg_rdata upper bits)
      case (mode)
        0: reg_read(3'd0, {1'b0, orientation, 2'b00, CC_OPEN, CC_RA});
        1: reg_read(3'd0, {1'b0, orientation, 2'b00, CC_RA, CC_OPEN});
        default: reg_read(3'd0, {1'b0, orientation, 2'b00, CC_RD, CC_RD});
      endcase
      cc1 = CC_OPEN; cc2 = CC_OPEN;
      repeat (5) @(posedge clk);
    end
  endtask

  // detach-glitch: brief open pulse on the active pin is rejected
  task automatic crv_detach_glitch(input bit pin2, input int gap);
    begin
      if (pin2) cc2 = CC_RD; else cc1 = CC_RD;
      repeat (110) @(posedge clk);
      chk(attached === 1'b1, "CRV detach-glitch: attached first");
      clear_ints;
      cc1 = CC_OPEN; cc2 = CC_OPEN;
      repeat (gap) @(posedge clk);              // < 10 clk open pulse
      if (pin2) cc2 = CC_RD; else cc1 = CC_RD;
      repeat (12) @(posedge clk);
      chk(attached === 1'b1, "CRV short release must not detach");
      chk(irq === 1'b0, "CRV no detach event after short release");
      cc1 = CC_OPEN; cc2 = CC_OPEN;
      repeat (15) @(posedge clk);
      chk(attached === 1'b0, "CRV detach-glitch: final detach");
      clear_ints;
    end
  endtask

  // role toggle while attached: vbus_en follows ROLE_CTRL
  task automatic crv_role(input bit pin2, input logic role);
    begin
      if (pin2) cc2 = CC_RD; else cc1 = CC_RD;
      repeat (110) @(posedge clk);
      chk(attached === 1'b1, "CRV role: attached");
      clear_ints;
      reg_write(3'd1, {7'b0, role});
      reg_read (3'd1, {7'b0, role});
      @(posedge clk); #1;
      chk(vbus_en === role, "CRV vbus_en follows role while attached");
      reg_write(3'd1, 8'h01);                   // restore source role
      cc1 = CC_OPEN; cc2 = CC_OPEN;
      repeat (15) @(posedge clk);
      clear_ints;
    end
  endtask

  // writes to RO registers must be ignored (covers the write-default arm)
  task automatic crv_ro_write;
    logic [7:0] junk;
    begin
      junk = $urandom_range(0, 255);
      reg_write(3'd0, junk);
      reg_write(3'd4, ~junk);
      reg_write(3'd7, junk | 8'h80);   // force wdata bit7 toggle
      reg_read(3'd7, 8'hC7);                    // DEVICE_ID unharmed
      reg_read(3'd4, 8'd100);                   // DEBOUNCE unharmed
      // CC_STATUS idle unharmed (orientation holds its last resolved value)
      reg_read(3'd0, {1'b0, orientation, 2'b00, CC_OPEN, CC_OPEN});
    end
  endtask
`endif

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  initial begin
    cc1 = CC_OPEN; cc2 = CC_OPEN;
    reg_addr = '0; reg_wdata = '0; reg_rd = 0; reg_wr = 0;
    rst_n = 0; repeat (4) @(posedge clk);
    rst_n = 1; repeat (2) @(posedge clk);

    // CHECK 1: reset state + RO register readback
    chk(attached === 1'b0 && vbus_en === 1'b0 && orientation === 1'b0
        && irq === 1'b0, "reset state outputs");
    reg_read(3'd7, 8'hC7);          // DEVICE_ID
    reg_read(3'd4, 8'd100);         // DEBOUNCE
    reg_read(3'd1, 8'h01);          // ROLE_CTRL default = source
    reg_read(3'd0, 8'h00);          // CC_STATUS idle
    $display("CHECK 1 done: reset state (errors=%0d)", errors);

    // CHECK 2: attach on cc1 (normal plug), debounce, status readback
    cc1 = CC_RD;
    repeat (50) @(posedge clk);
    chk(attached === 1'b0, "attached before debounce done");
    repeat (70) @(posedge clk);
    chk(attached === 1'b1, "attached after debounce");
    chk(orientation === 1'b0, "orientation=0 for cc1 attach");
    chk(vbus_en === 1'b1, "vbus_en on (source role)");
    chk(irq === 1'b1, "irq after attach event");
    reg_read(3'd0, {1'b1, 1'b0, 2'b10, CC_OPEN, CC_RD}); // CC_STATUS
    reg_read(3'd3, 8'h01);          // INT_STAT attach bit
    clear_ints;
    @(posedge clk); #1;
    chk(irq === 1'b0, "irq cleared by W1C");
    $display("CHECK 2 done: cc1 attach (errors=%0d)", errors);

    // CHECK 3: detach (cc1 back to OPEN), back-to-back cycle
    cc1 = CC_OPEN;
    repeat (3) @(posedge clk);
    chk(attached === 1'b1, "still attached during detach debounce");
    repeat (15) @(posedge clk);
    chk(attached === 1'b0, "detached after release debounce");
    chk(vbus_en === 1'b0, "vbus_en off after detach");
    chk(irq === 1'b1, "irq after detach event");
    reg_read(3'd3, 8'h02);          // INT_STAT detach bit
    clear_ints;
    $display("CHECK 3 done: detach (errors=%0d)", errors);

    // CHECK 4: attach on cc2 (flipped plug) -> orientation=1
    cc2 = CC_RD;
    repeat (120) @(posedge clk);
    chk(attached === 1'b1, "attached cc2");
    chk(orientation === 1'b1, "orientation=1 for cc2 attach");
    chk(vbus_en === 1'b1, "vbus_en on cc2 attach");
    reg_read(3'd5, 8'h01);          // ORIENT reg
    reg_read(3'd6, 8'h01);          // VBUS_STAT reg
    clear_ints;
    $display("CHECK 4 done: cc2 flipped attach (errors=%0d)", errors);

    // CHECK 5: role register write/readback; sink role drops vbus_en
    reg_write(3'd1, 8'h00);         // role = sink
    reg_read (3'd1, 8'h00);
    @(posedge clk); #1;
    chk(vbus_en === 1'b0, "vbus_en off in sink role");
    chk(attached === 1'b1, "still attached in sink role");
    reg_write(3'd1, 8'h01);         // role = source
    reg_read (3'd1, 8'h01);
    @(posedge clk); #1;
    chk(vbus_en === 1'b1, "vbus_en back in source role");
    $display("CHECK 5 done: role ctrl (errors=%0d)", errors);

    // CHECK 6: fault injection (abnormal CC level) -> irq + sticky status
    cc1 = CC_BAD;
    repeat (4) @(posedge clk);
    chk(irq === 1'b1, "irq on CC fault");
    reg_read(3'd2, 8'h01);          // FAULT_STAT sticky
    reg_read(3'd3, 8'h04);          // INT_STAT fault bit
    cc1 = CC_OPEN;
    repeat (2) @(posedge clk);
    chk(irq === 1'b1, "irq sticky after fault removed");
    clear_ints;
    @(posedge clk); #1;
    chk(irq === 1'b0, "irq cleared after fault W1C");
    reg_read(3'd2, 8'h00);
    $display("CHECK 6 done: fault injection (errors=%0d)", errors);

    // CHECK 7: glitch rejection - short Rd pulse must not attach
    cc2 = CC_OPEN;                  // detach first (clean slate)
    repeat (15) @(posedge clk);
    clear_ints;
    cc1 = CC_RD;
    repeat (50) @(posedge clk);     // shorter than 100 clk debounce
    cc1 = CC_OPEN;
    repeat (20) @(posedge clk);
    chk(attached === 1'b0, "glitch attach rejected");
    reg_read(3'd3, 8'h00);          // no attach/detach events
    $display("CHECK 7 done: glitch rejection (errors=%0d)", errors);

    // CHECK 8: third consecutive attach/detach cycle still works
    cc1 = CC_RD;
    repeat (120) @(posedge clk);
    chk(attached === 1'b1 && vbus_en === 1'b1, "cycle-3 attach");
    cc1 = CC_OPEN;
    repeat (15) @(posedge clk);
    chk(attached === 1'b0 && vbus_en === 1'b0, "cycle-3 detach");
    clear_ints;
    $display("CHECK 8 done: cycle 3 (errors=%0d)", errors);

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    begin : crv_phase
      int n_cyc = 0, n_glt = 0, n_flt = 0, n_ns = 0, n_dg = 0, n_role = 0, n_ro = 0;
      int roll;
      bit pin2;
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 19);
        pin2 = $urandom_range(0, 1);
        if (roll < 5) begin
          n_cyc++;  crv_cycle(pin2, $urandom_range(105, 140));
        end else if (roll < 8) begin
          n_glt++;  crv_glitch(pin2, $urandom_range(1, 99));
        end else if (roll < 11) begin
          n_flt++;  crv_fault(pin2, $urandom_range(1, 5));
        end else if (roll < 14) begin
          n_ns++;   crv_nonsink($urandom_range(0, 2));
        end else if (roll < 16) begin
          n_dg++;   crv_detach_glitch(pin2, $urandom_range(1, 9));
        end else if (roll < 19) begin
          n_role++; crv_role(pin2, $urandom_range(0, 1));
        end else begin
          n_ro++;   crv_ro_write;
        end
      end
      $display("CRV: 120 txns (cycle=%0d glitch=%0d fault=%0d nonsink=%0d det_glitch=%0d role=%0d ro_wr=%0d)",
               n_cyc, n_glt, n_flt, n_ns, n_dg, n_role, n_ro);
    end
`endif
    if (errors == 0) $display("TEST PASSED: USB Type-C Port Controller");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < TCPC_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, TCPC_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // CRV phase adds ~0.4 ms of stimulus: extend the guard. The timeout is
  // chunked into 1-us delays: with Verilator 5.006 a single long-pending
  // #delay event corrupts the --timing delay heap (docs/COVERAGE.md note 1).
  initial begin
    repeat (2000) #1000;    // 2 ms in 1-us chunks
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #200000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif
endmodule
