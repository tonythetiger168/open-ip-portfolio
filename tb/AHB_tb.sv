// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for AHB_top -- AHB-Lite master model
// Checks: reset state / pipelined overlapped write+read bursts / BUSY cycle /
//         slow-region wait states / two-cycle ERROR response + irq / IDLE resume
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module AHB_tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  logic          hsel;
  logic [1:0]    htrans;
  logic [AW-1:0] haddr;
  logic          hwrite;
  logic [2:0]    hsize;
  logic [DW-1:0] hwdata;
  logic [DW-1:0] hrdata;
  logic          hready;
  logic          hreadyout;
  logic          hresp;
  logic          irq;

  int errors = 0;

  // single-slave bus: master-side hready is this slave's hreadyout
  assign hready = hreadyout;

  AHB_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .hsel(hsel), .htrans(htrans), .haddr(haddr), .hwrite(hwrite),
    .hsize(hsize), .hwdata(hwdata), .hrdata(hrdata),
    .hready(hready), .hreadyout(hreadyout), .hresp(hresp), .irq(irq)
  );

  always #5 clk = ~clk;

  task automatic chk(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s @%0t", msg, $time);
    end
  endtask

  task automatic bus_idle(input int n);
    hsel = 1'b0; htrans = 2'b00; hwrite = 1'b0; haddr = '0;
    repeat (n) @(negedge clk);
  endtask

  // ----------------------------------------------------------------------
  // pipelined write burst x4: every data phase overlaps the next address
  // phase; in the fast region every cycle must complete (hreadyout==1)
  // ----------------------------------------------------------------------
  task automatic pipe_write4(input logic [AW-1:0] base,
                             input logic [DW-1:0] d0, d1, d2, d3);
    @(negedge clk);
    hsel = 1; hwrite = 1; htrans = 2'b10; haddr = base;     hwdata = '0; #1;
    chk(hreadyout === 1'b1, "pipe_w: idle cycle must be ready");
    @(negedge clk); // data phase w0 || address phase w1 (overlap)
    htrans = 2'b11; haddr = base + 4;  hwdata = d0; #1;
    chk(hreadyout === 1'b1 && hresp === 1'b0, "pipe_w: beat0 not single-cycle OKAY");
    @(negedge clk); // data phase w1 || address phase w2
    htrans = 2'b11; haddr = base + 8;  hwdata = d1; #1;
    chk(hreadyout === 1'b1 && hresp === 1'b0, "pipe_w: beat1 not single-cycle OKAY");
    @(negedge clk); // data phase w2 || address phase w3
    htrans = 2'b11; haddr = base + 12; hwdata = d2; #1;
    chk(hreadyout === 1'b1 && hresp === 1'b0, "pipe_w: beat2 not single-cycle OKAY");
    @(negedge clk); // data phase w3 || bus returns to IDLE
    htrans = 2'b00; hsel = 0; hwrite = 0; hwdata = d3; #1;
    chk(hreadyout === 1'b1 && hresp === 1'b0, "pipe_w: beat3 not single-cycle OKAY");
    @(negedge clk); #1;
  endtask

  // ----------------------------------------------------------------------
  // pipelined read burst x4 with full data comparison
  // ----------------------------------------------------------------------
  task automatic pipe_read4(input logic [AW-1:0] base,
                            input logic [DW-1:0] e0, e1, e2, e3);
    @(negedge clk);
    hsel = 1; hwrite = 0; htrans = 2'b10; haddr = base; #1;
    @(negedge clk); // data phase r0 || address phase r1
    htrans = 2'b11; haddr = base + 4; #1;
    chk(hreadyout === 1'b1, "pipe_r: beat0 not single-cycle");
    chk(hrdata === e0, "pipe_r: beat0 data mismatch");
    @(negedge clk); // data phase r1 || address phase r2
    htrans = 2'b11; haddr = base + 8; #1;
    chk(hrdata === e1, "pipe_r: beat1 data mismatch");
    @(negedge clk); // data phase r2 || address phase r3
    htrans = 2'b11; haddr = base + 12; #1;
    chk(hrdata === e2, "pipe_r: beat2 data mismatch");
    @(negedge clk); // data phase r3 || IDLE
    htrans = 2'b00; hsel = 0; #1;
    chk(hrdata === e3, "pipe_r: beat3 data mismatch");
    @(negedge clk); #1;
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions. The timeout guard is chunked (see bottom of file).
  // =====================================================================
  localparam int AHB_FSM_TOTAL = 3;   // S_NORM / S_SLOW / S_ERR2 (rtl enum)
  logic [2:0] fsm_seen = '0;          // visited-state bitmap
  wire  [1:0] dut_state = dut.state;  // hierarchical FSM probe

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
  logic p_hresp = 0, p_hreadyout = 0, p_irq = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(hreadyout === 1'b1 && hresp === 1'b0 && irq === 1'b0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: irq only together with an ERROR response
      sva_check(!irq || hresp, "A2 irq implies hresp ERROR");
      // A3: ERROR cycle1 (ready low) is always followed by cycle2
      sva_check(!(p_hresp && !p_hreadyout) || (hresp && hreadyout),
                "A3 two-cycle ERROR response");
      // A4: FSM holds a legal enum encoding
      sva_check(dut_state <= 2'd2, "A4 state encoding legal");
      // A5: read data is zero during an ERROR response
      sva_check(!hresp || (hrdata === '0), "A5 hrdata zero on ERROR");
      // A6: irq is a single-cycle pulse
      sva_check(!(p_irq && irq), "A6 irq single-cycle pulse");
    end
    p_hresp <= hresp; p_hreadyout <= hreadyout; p_irq <= irq;
  end

  // ---- single NONSEQ transfer with expected-region checks (CRV) ------
  // exp_wait: 0 = fast (single cycle), 1 = slow (one wait state),
  //           2 = reserved (two-cycle ERROR response)
  task automatic crv_xfer(input logic [31:0] a, input logic w,
                          input logic [31:0] d, input int exp_wait,
                          input logic [31:0] exp_rd);
    begin
      @(negedge clk);
      hsel = 1; hwrite = w; htrans = 2'b10; haddr = a; hwdata = '0;
      hsize = $urandom_range(0, 7);    // hsize ignored by the DUT; random
                                         // values close its toggle points
      #1;
      chk(hreadyout === 1'b1, "crv: idle cycle must be ready");
      @(negedge clk);                    // data phase cycle 1
      htrans = 2'b00; hsel = 0; hwdata = d; #1;
      if (exp_wait == 0) begin
        chk(hreadyout === 1'b1 && hresp === 1'b0,
            "crv fast: single-cycle OKAY");
        if (!w) chk(hrdata === exp_rd, "crv fast: read data mismatch");
        @(negedge clk); #1;
      end else if (exp_wait == 1) begin
        chk(hreadyout === 1'b0 && hresp === 1'b0,
            "crv slow: wait cycle must be OKAY");
        @(negedge clk); #1;              // completion cycle
        chk(hreadyout === 1'b1 && hresp === 1'b0,
            "crv slow: second cycle must complete");
        if (!w) chk(hrdata === exp_rd, "crv slow: read data mismatch");
        @(negedge clk); #1;
      end else begin
        chk(hresp === 1'b1 && hreadyout === 1'b0,
            "crv err: cycle1 ERROR/stall");
        chk(irq === 1'b1, "crv err: irq event expected");
        @(negedge clk); #1;              // ERROR cycle 2
        chk(hresp === 1'b1 && hreadyout === 1'b1,
            "crv err: cycle2 ERROR/complete");
        @(negedge clk); #1;              // recovery
        chk(hresp === 1'b0 && hreadyout === 1'b1,
            "crv err: must recover to OKAY/ready");
      end
    end
  endtask
`endif

  initial begin
    hsel = 0; htrans = 2'b00; haddr = '0; hwrite = 0;
    hsize = 3'b010; hwdata = '0;

    // ---------------- 1. reset state ----------------
    rst_n = 0; repeat (4) @(posedge clk);
    #1;
    chk(hreadyout === 1'b1, "reset: hreadyout must be 1");
    chk(hresp     === 1'b0, "reset: hresp must be OKAY");
    chk(hrdata    === '0,   "reset: hrdata must be 0");
    chk(irq       === 1'b0, "reset: irq must be 0");
    rst_n = 1; repeat (2) @(posedge clk);

    // ---------------- 2. pipelined overlapped write burst x4 ------------
    pipe_write4(32'h0000_0000, 32'hDEAD_0001, 32'hDEAD_0002,
                32'hDEAD_0003, 32'hDEAD_0004);
    bus_idle(1);

    // ---------------- 3. pipelined read burst x4 + compare --------------
    pipe_read4(32'h0000_0000, 32'hDEAD_0001, 32'hDEAD_0002,
               32'hDEAD_0003, 32'hDEAD_0004);

    // ---------------- 4. BUSY transfer inside a burst -------------------
    @(negedge clk);
    hsel = 1; hwrite = 1; htrans = 2'b10; haddr = 32'h40; hwdata = '0; #1;
    @(negedge clk);              // data phase w0 || BUSY address phase
    htrans = 2'b01; haddr = 32'h7C; hwdata = 32'hB050_0001; #1;
    chk(hreadyout === 1'b1 && hresp === 1'b0, "busy: BUSY must not stall slave");
    @(negedge clk);              // BUSY occupies address phase; no data phase
    htrans = 2'b10; haddr = 32'h44; hwdata = 32'hFFFF_FFFF; #1;
    chk(hreadyout === 1'b1 && hresp === 1'b0, "busy: recovery after BUSY");
    @(negedge clk);              // data phase w1 || IDLE
    htrans = 2'b00; hsel = 0; hwdata = 32'hB050_0002; #1;
    chk(hreadyout === 1'b1, "busy: beat after BUSY must complete");
    @(negedge clk); #1;
    // 0x7C was on the bus during BUSY: it must be untouched (still 0)
    pipe_read4(32'h0078, 32'h0, 32'h0, 32'h0, 32'h0);

    // ---------------- 5. slow region wait state -------------------------
    @(negedge clk);
    hsel = 1; hwrite = 1; htrans = 2'b10; haddr = 32'h404; hwdata = '0; #1;
    @(negedge clk);              // data phase, wait cycle
    htrans = 2'b00; hsel = 0; hwdata = 32'h5100_0001; #1;
    chk(hreadyout === 1'b0, "slow: first data cycle must insert wait");
    chk(hresp === 1'b0, "slow: wait cycle must be OKAY");
    @(negedge clk); #1;          // completion cycle
    chk(hreadyout === 1'b1, "slow: second data cycle must complete");
    @(negedge clk); #1;
    // slow read back
    @(negedge clk);
    hsel = 1; hwrite = 0; htrans = 2'b10; haddr = 32'h404; #1;
    @(negedge clk);
    htrans = 2'b00; hsel = 0; #1;
    chk(hreadyout === 1'b0, "slow rd: wait cycle expected");
    @(negedge clk); #1;
    chk(hreadyout === 1'b1 && hrdata === 32'h5100_0001, "slow rd: data mismatch");

    // ---------------- 6. ERROR response (reserved address) --------------
    @(negedge clk);
    hsel = 1; hwrite = 0; htrans = 2'b10; haddr = 32'h800; #1;
    @(negedge clk);              // ERROR cycle 1
    htrans = 2'b00; hsel = 0; #1;
    chk(hresp === 1'b1 && hreadyout === 1'b0, "error: cycle1 resp=ERROR readyout=0");
    chk(irq === 1'b1, "error: irq event expected on ERROR response");
    @(negedge clk); #1;          // ERROR cycle 2
    chk(hresp === 1'b1 && hreadyout === 1'b1, "error: cycle2 resp=ERROR readyout=1");
    @(negedge clk); #1;          // recovered
    chk(hresp === 1'b0 && hreadyout === 1'b1, "error: must recover to OKAY/ready");

    // ---------------- 7. IDLE then resume; registers intact -------------
    bus_idle(3);
    pipe_write4(32'h0080, 32'hCAFE_0001, 32'hCAFE_0002,
                32'hCAFE_0003, 32'hCAFE_0004);
    pipe_read4(32'h0080, 32'hCAFE_0001, 32'hCAFE_0002,
               32'hCAFE_0003, 32'hCAFE_0004);
    // fast-region word @0x40 must still hold BUSY-test data
    pipe_read4(32'h0040, 32'hB050_0001, 32'hB050_0002, 32'h0, 32'h0);

    bus_idle(2);
`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 256-word random init sweep (resyncs the scoreboard model) + 120
    // randomized single NONSEQ transfers: random read/write, random
    // data, address classes = fast / slow alias / boundaries / reserved
    // (error injection: two-cycle ERROR + irq expected).
    begin : crv_phase
      int n_wr = 0, n_rd = 0, n_err = 0;
      int roll;
      logic [31:0] c_addr, c_data;
      logic        c_wrn;
      logic [31:0] model [0:255];   // scoreboard of the register file
      for (int i = 0; i < 256; i++) begin
        c_data = $urandom;
        model[i] = c_data;
        crv_xfer(32'(i * 4), 1'b1, c_data, 0, '0);
      end
      for (int t = 0; t < 120; t++) begin
        c_wrn  = $urandom_range(0, 1);
        c_data = $urandom;
        roll   = $urandom_range(0, 19);
        if (roll < 9)
          c_addr = 32'($urandom_range(0, 255) * 4);          // fast region
        else if (roll < 12)
          c_addr = 32'(1024 + $urandom_range(0, 255) * 4);   // slow alias
        else if (roll < 14)
          c_addr = 32'($urandom_range(240, 255) * 4);        // fast boundary
        else if (roll < 17)
          c_addr = $urandom | 32'h0000_0800;                 // reserved
        else
          c_addr = 32'(1792 + $urandom_range(0, 15) * 4);    // slow boundary
        if (c_addr[11]) begin
          // reserved region: two-cycle ERROR + irq, memory untouched
          n_err++;
          crv_xfer(c_addr, c_wrn, c_data, 2, '0);
        end else if (c_wrn) begin
          n_wr++;
          crv_xfer(c_addr, 1'b1, c_data, (c_addr[11:10] == 2'b01) ? 1 : 0,
                   '0);
          model[c_addr[9:2]] = c_data;
        end else begin
          n_rd++;
          crv_xfer(c_addr, 1'b0, '0, (c_addr[11:10] == 2'b01) ? 1 : 0,
                   model[c_addr[9:2]]);
        end
      end
      $display("CRV: 256 init + 120 txns (wr=%0d rd=%0d err=%0d)",
               n_wr, n_rd, n_err);
    end
`endif
    if (errors == 0) $display("TEST PASSED: AHB");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < AHB_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, AHB_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // timeout guard
`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived
  // (verified with a minimal repro).
  initial begin
    repeat (500) #1000;   // 500 us in 1-us chunks
    errors++;
    $display("ERROR: TIMEOUT guard fired");
    $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
`else
  initial begin
    #50000;
    errors++;
    $display("ERROR: TIMEOUT guard fired");
    $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
`endif

endmodule
