// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for AXI4_Lite_top -- AXI4-Lite master model
// Task-ized 5-channel single-beat handshake drivers; scoreboard model;
// checks: reset state, write/read compare x4 (with wvalid gaps, bready/rready
// backpressure hold), byte-strobe partial write, out-of-range and misaligned
// SLVERR injection + irq, error address leaves memory untouched, consecutive
// back-to-back transactions.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module AXI4_Lite_tb;
  localparam int DW = 32, AW = 32;
  localparam logic [1:0] OKAY   = 2'b00;
  localparam logic [1:0] SLVERR = 2'b10;

  logic clk = 0, rst_n = 0;
  logic [AW-1:0]   awaddr;
  logic            awvalid;
  logic            awready;
  logic [DW-1:0]   wdata;
  logic [DW/8-1:0] wstrb;
  logic            wvalid;
  logic            wready;
  logic [1:0]      bresp;
  logic            bvalid;
  logic            bready;
  logic [AW-1:0]   araddr;
  logic            arvalid;
  logic            arready;
  logic [DW-1:0]   rdata;
  logic [1:0]      rresp;
  logic            rvalid;
  logic            rready;
  logic            irq;

  int errors = 0;
  logic [31:0] model [0:255];   // scoreboard of expected memory contents

  AXI4_Lite_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
    .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .araddr(araddr), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // channel tasks (all stimulus driven / sampled on negedge => race-free)
  // ------------------------------------------------------------------
  task automatic axi_aw(input logic [AW-1:0] addr);
    begin
      @(negedge clk);
      awaddr <= addr; awvalid <= 1'b1;
      while (!awready) @(negedge clk);
      @(posedge clk);            // address accepted here
      @(negedge clk);
      awvalid <= 1'b0;
    end
  endtask

  task automatic axi_w(input logic [DW-1:0] data, input logic [DW/8-1:0] strb,
                       input bit stall_en);
    begin
      if (stall_en) repeat ($urandom_range(0, 2)) @(negedge clk);  // wvalid gap
      @(negedge clk);
      wvalid <= 1'b1; wdata <= data; wstrb <= strb;
      while (!wready) @(negedge clk);
      @(posedge clk);            // beat accepted here
      @(negedge clk);
      wvalid <= 1'b0;
    end
  endtask

  task automatic axi_b(input logic [1:0] exp, input bit hold);
    begin
      bready <= 1'b0;
      @(negedge clk);
      while (!bvalid) @(negedge clk);
      if (bresp !== exp) begin
        errors++; $display("ERROR: bresp=%b exp=%b", bresp, exp);
      end
      if (hold) begin            // bvalid must stay until bready
        repeat (3) begin
          @(negedge clk);
          if (!bvalid) begin
            errors++; $display("ERROR: bvalid dropped before bready");
          end
          if (bresp !== exp) begin
            errors++; $display("ERROR: bresp changed while bready low");
          end
        end
      end
      bready <= 1'b1;
      @(posedge clk);            // response accepted here
      @(negedge clk);
      bready <= 1'b0;
    end
  endtask

  task automatic axi_ar(input logic [AW-1:0] addr);
    begin
      @(negedge clk);
      araddr <= addr; arvalid <= 1'b1;
      while (!arready) @(negedge clk);
      @(posedge clk);            // address accepted here
      @(negedge clk);
      arvalid <= 1'b0;
    end
  endtask

  // full single-beat write + response check
  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data,
                           input logic [3:0] strb, input logic [1:0] exp,
                           input bit stalls, input bit update_model);
    logic [31:0] merged;
    begin
      axi_aw(addr);
      axi_w(data, strb, stalls);
      if (update_model && (addr < 1024) && (addr[1:0] == 0)) begin
        merged = model[addr[9:2]];
        for (int b = 0; b < 4; b++)
          if (strb[b]) merged[8*b +: 8] = data[8*b +: 8];
        model[addr[9:2]] = merged;
      end
      axi_b(exp, stalls);
    end
  endtask

  // full single-beat read with response/data check and rready stall
  task automatic axi_read(input logic [31:0] addr, input logic [1:0] exp,
                          input bit stalls, input bit check_model);
    logic [31:0] save_d;
    int stall;
    begin
      rready <= 1'b0;
      axi_ar(addr);
      @(negedge clk);
      while (!rvalid) @(negedge clk);
      if (rresp !== exp) begin
        errors++; $display("ERROR: rresp @%h =%b exp=%b", addr, rresp, exp);
      end
      if ((rresp === OKAY) && check_model) begin
        if (rdata !== model[addr[9:2]]) begin
          errors++;
          $display("ERROR: rdata @%h got=%h exp=%h", addr, rdata, model[addr[9:2]]);
        end
      end
      // random rready backpressure: rvalid/rdata must be held stable
      stall = stalls ? $urandom_range(0, 3) : 0;
      save_d = rdata;
      repeat (stall) begin
        @(negedge clk);
        if (!rvalid) begin
          errors++; $display("ERROR: rvalid dropped under backpressure");
        end
        if (rdata !== save_d) begin
          errors++; $display("ERROR: rdata unstable under backpressure");
        end
      end
      rready <= 1'b1;
      @(posedge clk);            // beat accepted here
      @(negedge clk);
      rready <= 1'b0;
    end
  endtask

  task automatic check_irq(input logic exp, input string tag);
    begin
      if (irq !== exp) begin
        errors++; $display("ERROR: irq=%b exp=%b [%s]", irq, exp, tag);
      end
    end
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probes, immediate
  // assertions. The timeout guard is chunked (see bottom of file).
  // =====================================================================
  localparam int AXI4L_FSM_TOTAL = 5;  // W_IDLE/W_DATA/W_RESP + R_IDLE/R_DATA
  logic [3:0] wfsm_seen = '0;          // write-FSM visited-state bitmap
  logic [1:0] rfsm_seen = '0;          // read-FSM visited-state bitmap
  wire  [1:0] dut_wstate = dut.wstate; // hierarchical FSM probes
  wire        dut_rstate = dut.rstate;

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
    wfsm_seen[dut_wstate] <= 1'b1;
    rfsm_seen[dut_rstate] <= 1'b1;
  end

  // output-invariant assertion suite (prev-cycle samples for stability
  // checks; all values read coherently pre-NBA)
  logic        p_bvalid = 0, p_bready = 0;
  logic [1:0]  p_bresp  = 0;
  logic        p_rvalid = 0, p_rready = 0;
  logic [1:0]  p_rresp  = 0;
  logic [31:0] p_rdata  = 0;
  logic        p_irq    = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: no response channel activity during reset
      sva_check(bvalid === 1'b0 && rvalid === 1'b0, "A1 reset: b/rvalid low");
    end else begin
      // A2: bvalid/bresp held until bready
      sva_check(!(p_bvalid && !p_bready) || (bvalid && bresp === p_bresp),
                "A2 bvalid/bresp held until bready");
      // A3: rvalid/rdata/rresp held until rready
      sva_check(!(p_rvalid && !p_rready) ||
                (rvalid && rdata === p_rdata && rresp === p_rresp),
                "A3 rvalid/rdata/rresp held until rready");
      // A4: bresp only OKAY/SLVERR
      sva_check(!bvalid || (bresp[0] === 1'b0), "A4 bresp legal");
      // A5: rresp only OKAY/SLVERR
      sva_check(!rvalid || (rresp[0] === 1'b0), "A5 rresp legal");
      // A6: exactly one write-channel phase output active
      sva_check((awready + wready + bvalid) == 1, "A6 one write phase hot");
      // A7: irq is sticky until reset
      sva_check(!p_irq || irq, "A7 irq sticky");
      // A8: write FSM holds a legal enum encoding
      sva_check(dut_wstate <= 2'd2, "A8 wstate encoding legal");
    end
    p_bvalid <= bvalid; p_bready <= bready; p_bresp <= bresp;
    p_rvalid <= rvalid; p_rready <= rready; p_rresp <= rresp;
    p_rdata  <= rdata;  p_irq    <= irq;
  end
`endif

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  initial begin
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    for (int i = 0; i < 256; i++) model[i] = 32'h0;

    // ---- check 1: reset state ----
    rst_n = 0; repeat (4) @(posedge clk);
    @(negedge clk); rst_n = 1;
    @(negedge clk);
    if (awready !== 1'b1) begin errors++; $display("ERROR: awready!=1 after reset"); end
    if (arready !== 1'b1) begin errors++; $display("ERROR: arready!=1 after reset"); end
    if (wready  !== 1'b0) begin errors++; $display("ERROR: wready!=0 after reset"); end
    if (bvalid  !== 1'b0) begin errors++; $display("ERROR: bvalid!=0 after reset"); end
    if (rvalid  !== 1'b0) begin errors++; $display("ERROR: rvalid!=0 after reset"); end
    check_irq(1'b0, "reset");

    // ---- check 2: write/read compare x4 with backpressure ----
    axi_write(32'h000, 32'hA500_0001, 4'hF, OKAY, 1'b1, 1'b1);
    axi_read (32'h000, OKAY, 1'b1, 1'b1);
    axi_write(32'h040, 32'hB600_0002, 4'hF, OKAY, 1'b1, 1'b1);
    axi_read (32'h040, OKAY, 1'b1, 1'b1);
    axi_write(32'h080, 32'hC700_0003, 4'hF, OKAY, 1'b0, 1'b1);
    axi_read (32'h080, OKAY, 1'b1, 1'b1);
    axi_write(32'h3FC, 32'hD800_0004, 4'hF, OKAY, 1'b1, 1'b1);  // last word
    axi_read (32'h3FC, OKAY, 1'b1, 1'b1);
    check_irq(1'b0, "after basic rw");

    // ---- check 3: byte-strobe partial write ----
    axi_write(32'h000, 32'hFFFF_0000, 4'h3, OKAY, 1'b0, 1'b1); // low half
    axi_read (32'h000, OKAY, 1'b0, 1'b1);
    axi_write(32'h000, 32'h0000_FFFF, 4'hC, OKAY, 1'b0, 1'b1); // high half
    axi_read (32'h000, OKAY, 1'b0, 1'b1);

    // ---- check 4: out-of-range SLVERR injection (write + read) + irq ----
    axi_write(32'h2000, 32'hDEAD_BEEF, 4'hF, SLVERR, 1'b0, 1'b0);
    check_irq(1'b1, "write oob");
    axi_read (32'h3000, SLVERR, 1'b1, 1'b0);
    check_irq(1'b1, "read oob");

    // ---- check 5: misaligned address -> SLVERR ----
    axi_write(32'h042, 32'h1234_5678, 4'hF, SLVERR, 1'b0, 1'b0);
    axi_read (32'h082, SLVERR, 1'b0, 1'b0);

    // ---- check 6: error accesses leave memory untouched ----
    axi_read (32'h040, OKAY, 1'b0, 1'b1);   // still check-2 data
    axi_read (32'h080, OKAY, 1'b0, 1'b1);

    // ---- check 7: consecutive back-to-back transactions ----
    axi_write(32'h100, 32'h5A00_0000, 4'hF, OKAY, 1'b0, 1'b1);
    axi_write(32'h104, 32'h5B00_0000, 4'hF, OKAY, 1'b0, 1'b1);
    axi_read (32'h100, OKAY, 1'b0, 1'b1);
    axi_read (32'h104, OKAY, 1'b0, 1'b1);

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 140 randomized single-beat transactions, ~50/50 write/read.
    // Randomized: data, byte strobes, backpressure stalls, and address
    // class (in-range aligned / range boundary / out-of-range /
    // out-of-range high bits / misaligned). Error classes expect SLVERR;
    // the directed scoreboard model is already in sync (all directed
    // in-range writes used update_model=1) and is maintained by
    // axi_write for in-range writes.
    begin : crv_phase
      int n_wr = 0, n_rd = 0, n_okay = 0, n_slv = 0;
      int roll;
      logic [31:0] c_addr, c_data;
      logic [3:0]  c_strb;
      logic        c_wrn, c_stall, c_ok;
      for (int t = 0; t < 140; t++) begin
        c_wrn   = $urandom_range(0, 1);
        c_data  = $urandom;
        c_strb  = $urandom_range(0, 15);
        c_stall = $urandom_range(0, 1);
        roll    = $urandom_range(0, 19);
        if (roll < 10)
          c_addr = 32'($urandom_range(0, 255) * 4);          // aligned in-range
        else if (roll < 13)
          c_addr = 32'($urandom_range(240, 255) * 4);        // range boundary
        else if (roll < 15)
          c_addr = 32'(1024 + $urandom_range(0, 4095) * 4);  // out of range
        else if (roll < 17)
          c_addr = $urandom | 32'hFFFF_0000;                 // oob, high bits
        else
          c_addr = 32'($urandom_range(0, 255) * 4 +
                       $urandom_range(1, 3));                // misaligned
        c_ok = (c_addr[31:10] == '0) && (c_addr[1:0] == 2'b00);
        if (c_ok) n_okay++; else n_slv++;
        if (c_wrn) begin
          n_wr++;
          axi_write(c_addr, c_data, c_strb, c_ok ? OKAY : SLVERR,
                    c_stall, 1'b1);
        end else begin
          n_rd++;
          axi_read(c_addr, c_ok ? OKAY : SLVERR, c_stall, 1'b1);
        end
      end
      // ---- targeted toggle closure: all-ones/all-zeros patterns make
      // every wdata/rdata bit toggle deterministically (the RNG mix is
      // not guaranteed to hit all 32 data bits on the read path)
      axi_write(32'h020, 32'hFFFF_FFFF, 4'hF, OKAY, 1'b0, 1'b1);
      axi_read (32'h020, OKAY, 1'b0, 1'b1);
      axi_write(32'h020, 32'h0000_0000, 4'hF, OKAY, 1'b0, 1'b1);
      axi_read (32'h020, OKAY, 1'b0, 1'b1);
      $display("CRV: 140 txns (wr=%0d rd=%0d | okay=%0d slverr=%0d)",
               n_wr, n_rd, n_okay, n_slv);
    end
`endif
    if (errors == 0) $display("TEST PASSED: AXI4_Lite");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < 3; s++) visited += wfsm_seen[s];
      for (int s = 0; s < 2; s++) visited += rfsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, AXI4L_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // ------------------------------------------------------------------
  // timeout guard
  // ------------------------------------------------------------------
`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived
  // (verified with a minimal repro).
  initial begin
    repeat (2000) #1000;   // 2 ms in 1-us chunks
    $display("ERROR: TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #200000;
    $display("ERROR: TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif
endmodule
