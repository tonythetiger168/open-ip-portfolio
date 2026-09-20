// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for ACE_Lite_top -- AXI4 master model with ACE-Lite
// fields (SNOOP/DOMAIN/BAR). Checks: reset state, burst write/read compare,
// byte-strobe merge, barrier transaction ordering, SLVERR + irq injection,
// back-to-back transactions, ready backpressure.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module ACE_Lite_tb;
  localparam int DW = 32, AW = 32;

  localparam logic [1:0] AXI_OKAY   = 2'b00;
  localparam logic [1:0] AXI_SLVERR = 2'b10;

  logic clk = 0, rst_n = 0;
  // AW
  logic awvalid = 0, awready;
  logic [AW-1:0] awaddr = 0;
  logic [7:0] awlen = 0;
  logic [2:0] awsize = 0;
  logic [1:0] awburst = 0;
  logic [2:0] awsnoop = 0;
  logic [1:0] awdomain = 0, awbar = 0;
  // W
  logic wvalid = 0, wready;
  logic [DW-1:0] wdata = 0;
  logic [DW/8-1:0] wstrb = 0;
  logic wlast = 0;
  // B
  logic bvalid, bready = 0;
  logic [1:0] bresp;
  // AR
  logic arvalid = 0, arready;
  logic [AW-1:0] araddr = 0;
  logic [7:0] arlen = 0;
  logic [2:0] arsize = 0;
  logic [1:0] arburst = 0;
  logic [3:0] arsnoop = 0;
  logic [1:0] ardomain = 0, arbar = 0;
  // R
  logic rvalid, rready = 0;
  logic [DW-1:0] rdata;
  logic [1:0] rresp;
  logic rlast;
  logic irq;

  int errors = 0;
  int irq_seen = 0;

  ACE_Lite_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awlen(awlen),
    .awsize(awsize), .awburst(awburst), .awsnoop(awsnoop),
    .awdomain(awdomain), .awbar(awbar),
    .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
    .bvalid(bvalid), .bready(bready), .bresp(bresp),
    .arvalid(arvalid), .arready(arready), .araddr(araddr), .arlen(arlen),
    .arsize(arsize), .arburst(arburst), .arsnoop(arsnoop),
    .ardomain(ardomain), .arbar(arbar),
    .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp), .rlast(rlast),
    .irq(irq)
  );

  always #5 clk = ~clk;

  always @(posedge clk) if (irq) irq_seen++;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probes, immediate
  // assertions. The timeout guard is chunked (see bottom of file).
  // =====================================================================
  localparam int ACEL_FSM_TOTAL = 5;  // W_IDLE/W_DATA/W_RESP + R_IDLE/R_DATA
  logic [2:0] wfsm_seen = '0;         // write-FSM visited-state bitmap
  logic [1:0] rfsm_seen = '0;         // read-FSM visited-state bitmap
  wire [1:0] dut_wstate = dut.wstate;   // hierarchical FSM probes
  wire       dut_rstate = dut.rstate;

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
  // checks; all values read coherently pre-NBA). rst_obs gates out the
  // t=0 sample (this block can run before the DUT's initial reset settle
  // on the very first posedge).
  logic        p_rstn = 1, rst_obs = 0;
  logic        p_bvalid = 0, p_bready = 0;
  logic [1:0]  p_bresp  = 0;
  logic        p_rvalid = 0, p_rready = 0, p_rlast = 0;
  logic [1:0]  p_rresp  = 0;
  logic [31:0] p_rdata  = 0;
  logic        p_irq = 0;
  always @(posedge clk) begin
    if (!rst_n) rst_obs <= 1'b1;
    if (rst_obs) begin
      if (!p_rstn) begin
        // A1: no response channel activity during reset
        sva_check(bvalid === 1'b0 && rvalid === 1'b0,
                  "A1 reset: b/rvalid low");
      end else begin
        // A2: bvalid held stable until bready
        sva_check(!(p_bvalid && !p_bready) ||
                  (bvalid && bresp === p_bresp),
                  "A2 bvalid/bresp held until bready");
        // A3: rvalid held stable until rready
        sva_check(!(p_rvalid && !p_rready) ||
                  (rvalid && rdata === p_rdata && rresp === p_rresp &&
                   rlast === p_rlast),
                  "A3 rvalid/rdata/rresp held until rready");
        // A4: rlast only together with rvalid
        sva_check(!rlast || rvalid, "A4 rlast implies rvalid");
        // A5: bresp/rresp only OKAY(00)/SLVERR(10)
        sva_check((!bvalid || (bresp !== 2'b01 && bresp !== 2'b11)) &&
                  (!rvalid || (rresp !== 2'b01 && rresp !== 2'b11)),
                  "A5 b/rresp legal");
        // A6: exactly one write-channel phase output active
        sva_check((awready + wready + bvalid) == 1,
                  "A6 one write phase hot");
        // A7: irq is a single-cycle pulse (no back-to-back)
        sva_check(!(irq && p_irq), "A7 irq single-cycle pulse");
      end
    end
    p_bvalid <= bvalid; p_bready <= bready; p_bresp <= bresp;
    p_rvalid <= rvalid; p_rready <= rready; p_rlast <= rlast;
    p_rresp  <= rresp;  p_rdata  <= rdata;
    p_irq <= irq;
    p_rstn <= rst_n;
  end

  // ---- CRV scoreboard of the 256-word memory -------------------------
  logic [31:0] model [0:255];

  // address-time error class (matches RTL werr_q/rerr_q equation)
  function automatic logic crv_err(input logic [31:0] a,
                                   input logic [1:0]  b,
                                   input logic [2:0]  s);
    return (b != 2'b01) || (s > 3'd2) || (|a[31:10]);
  endfunction

  // ---- CRV write burst: random ACE-Lite side fields, data, strb ------
  task automatic crv_write(input logic [31:0] addr, input logic [7:0] len,
                           input logic [1:0] burst, input logic [2:0] size,
                           input bit stall, input bit rand_strb = 1);
    logic        err;
    logic [31:0] a, d;
    logic [3:0]  st;
    begin
      err = crv_err(addr, burst, size);
      @(negedge clk);
      awvalid = 1; awaddr = addr; awlen = len; awsize = size;
      awburst = burst;
      awsnoop  = 3'($urandom_range(0, 7));   // side fields: functional no-ops,
      awdomain = 2'($urandom_range(0, 3));   // randomized for toggle coverage
      awbar    = 2'($urandom_range(0, 3));
      while (!awready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) awvalid = 0;
      for (int i = 0; i <= len; i++) begin
        if (stall) repeat ($urandom_range(0, 2)) @(negedge clk);
        d  = $urandom;
        st = rand_strb ? 4'($urandom_range(0, 15)) : 4'hF;
        wvalid = 1; wdata = d; wstrb = st; wlast = (i == len);
        while (!wready) @(negedge clk);
        @(posedge clk);
        @(negedge clk) wvalid = 0; wlast = 0;
        // scoreboard update: the DUT writes every accepted beat when !err
        // (mid-burst addresses alias through waddr_q[9:2])
        a = addr + 32'(i) * 4;
        if (!err)
          for (int b = 0; b < 4; b++)
            if (st[b]) model[a[9:2]][8*b +: 8] = d[8*b +: 8];
      end
      bready = 0;
      while (!bvalid) @(negedge clk);
      if (bresp !== (err ? AXI_SLVERR : AXI_OKAY)) begin
        errors++;
        $display("ERROR: CRV ACE_Lite write @%h bresp=%b exp_slverr=%b",
                 addr, bresp, err);
      end
      if (stall) repeat (2) @(negedge clk);
      bready = 1;
      @(posedge clk);
      @(negedge clk) bready = 0;
    end
  endtask

  // ---- CRV read burst: per-beat data compare vs scoreboard -----------
  task automatic crv_read(input logic [31:0] addr, input logic [7:0] len,
                          input logic [1:0] burst, input logic [2:0] size,
                          input bit stall);
    logic        err;
    logic [31:0] a, exp;
    begin
      err = crv_err(addr, burst, size);
      @(negedge clk);
      arvalid = 1; araddr = addr; arlen = len; arsize = size;
      arburst = burst;
      arsnoop  = 4'($urandom_range(0, 15));
      ardomain = 2'($urandom_range(0, 3));
      arbar    = 2'($urandom_range(0, 3));
      while (!arready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) arvalid = 0;
      for (int i = 0; i <= len; i++) begin
        rready = 0;
        while (!rvalid) @(negedge clk);
        a   = addr + 32'(i) * 4;
        exp = err ? 32'h0 : model[a[9:2]];
        if (rdata !== exp) begin
          errors++;
          $display("ERROR: CRV ACE_Lite read @%h beat%0d got=%h exp=%h",
                   addr, i, rdata, exp);
        end
        if (rlast !== (i == len)) begin
          errors++;
          $display("ERROR: CRV ACE_Lite read @%h beat%0d rlast=%b",
                   addr, i, rlast);
        end
        if (rresp !== (err ? AXI_SLVERR : AXI_OKAY)) begin
          errors++;
          $display("ERROR: CRV ACE_Lite read @%h beat%0d rresp=%b",
                   addr, i, rresp);
        end
        if (stall) repeat ($urandom_range(0, 1)) @(negedge clk);
        rready = 1;
        @(posedge clk);
        @(negedge clk) rready = 0;
      end
    end
  endtask
`endif

  // -------------------------------------------------
  // AXI write burst: data = base+i, per-beat strobe, optional barrier
  // -------------------------------------------------
  task automatic axi_write(input logic [AW-1:0] addr, input logic [7:0] len,
                           input logic [DW-1:0] base, input logic [1:0] burst,
                           input logic [DW/8-1:0] strb, input logic [1:0] bar,
                           input logic [1:0] exp_resp);
    begin
      @(negedge clk);
      awvalid = 1; awaddr = addr; awlen = len; awsize = 3'd2;
      awburst = burst; awsnoop = 3'b000; awdomain = 2'b01; awbar = bar;
      while (!awready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) awvalid = 0;
      for (int i = 0; i <= len; i++) begin
        repeat ($random & 1) @(negedge clk);   // wvalid stall
        wvalid = 1; wdata = base + i; wstrb = strb; wlast = (i == len);
        while (!wready) @(negedge clk);
        @(posedge clk);
        @(negedge clk) wvalid = 0; wlast = 0;
      end
      bready = 0;
      while (!bvalid) @(negedge clk);
      if (bresp !== exp_resp) begin
        errors++;
        $display("ERROR: ACE_Lite write @%h bresp=%b exp=%b", addr, bresp, exp_resp);
      end
      repeat (2) @(negedge clk);               // bvalid backpressure
      bready = 1;
      @(posedge clk);
      @(negedge clk) bready = 0;
    end
  endtask

  // -------------------------------------------------
  // AXI read burst: compare data = base+i, optional barrier
  // -------------------------------------------------
  task automatic axi_read(input logic [AW-1:0] addr, input logic [7:0] len,
                          input logic [DW-1:0] base, input logic [1:0] bar,
                          input logic [1:0] exp_resp);
    logic [DW-1:0] exp;
    begin
      @(negedge clk);
      arvalid = 1; araddr = addr; arlen = len; arsize = 3'd2;
      arburst = 2'b01; arsnoop = 4'h0; ardomain = 2'b01; arbar = bar;
      while (!arready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) arvalid = 0;
      for (int i = 0; i <= len; i++) begin
        rready = 0;
        while (!rvalid) @(negedge clk);
        exp = base + i;
        if (rdata !== exp) begin
          errors++;
          $display("ERROR: ACE_Lite read @%h beat%0d got=%h exp=%h", addr, i, rdata, exp);
        end
        if (rlast !== (i == len)) begin
          errors++;
          $display("ERROR: ACE_Lite read @%h beat%0d rlast=%b", addr, i, rlast);
        end
        if (rresp !== exp_resp) begin
          errors++;
          $display("ERROR: ACE_Lite read @%h beat%0d rresp=%b exp=%b", addr, i, rresp, exp_resp);
        end
        repeat ($random & 1) @(negedge clk);   // rready backpressure
        rready = 1;
        @(posedge clk);
        @(negedge clk) rready = 0;
      end
    end
  endtask

  initial begin
    // ---------------- 1. reset state check ----------------
    rst_n = 0; repeat (4) @(posedge clk);
    @(negedge clk);
    if (bvalid !== 0 || rvalid !== 0 || irq !== 0) begin
      errors++;
      $display("ERROR: ACE_Lite reset state bvalid=%b rvalid=%b irq=%b", bvalid, rvalid, irq);
    end
    rst_n = 1; repeat (2) @(posedge clk);

    // ---------------- 2. burst write / read-back compare ----------------
    axi_write(32'h0000_0040, 8'd3,  32'hA5A5_0000, 2'b01, 4'hF, 2'b00, AXI_OKAY);
    axi_read (32'h0000_0040, 8'd3,  32'hA5A5_0000, 2'b00, AXI_OKAY);
    axi_write(32'h0000_0100, 8'd15, 32'h1111_0000, 2'b01, 4'hF, 2'b00, AXI_OKAY); // max len
    axi_read (32'h0000_0100, 8'd15, 32'h1111_0000, 2'b00, AXI_OKAY);
    axi_write(32'h0000_0004, 8'd0,  32'h5A5A_5A5A, 2'b01, 4'hF, 2'b00, AXI_OKAY); // single
    axi_read (32'h0000_0004, 8'd0,  32'h5A5A_5A5A, 2'b00, AXI_OKAY);

    // ---------------- 3. byte-strobe merge ----------------
    axi_write(32'h0000_0010, 8'd0, 32'hAABB_CCDD, 2'b01, 4'hF, 2'b00, AXI_OKAY);
    axi_write(32'h0000_0010, 8'd0, 32'h0000_EE11, 2'b01, 4'h3, 2'b00, AXI_OKAY);
    axi_read (32'h0000_0010, 8'd0, 32'hAABB_EE11, 2'b00, AXI_OKAY);

    // ---------------- 4. barrier write then read: in-order completion ------
    axi_write(32'h0000_0204, 8'd0, 32'h1234_5678, 2'b01, 4'hF, 2'b00, AXI_OKAY);
    axi_write(32'h0000_0200, 8'd0, 32'hBA22_1E22, 2'b01, 4'hF, 2'b01, AXI_OKAY); // barrier
    // transactions after a barrier must observe everything before it
    axi_read (32'h0000_0200, 8'd0, 32'hBA22_1E22, 2'b01, AXI_OKAY);              // barrier read
    axi_read (32'h0000_0204, 8'd0, 32'h1234_5678, 2'b00, AXI_OKAY);

    // ---------------- 5. error injection: out-of-range -> SLVERR + irq ----
    irq_seen = 0;
    axi_write(32'h0000_1000, 8'd0, 32'hBAD0_BAD0, 2'b01, 4'hF, 2'b00, AXI_SLVERR);
    axi_read (32'h0000_1000, 8'd0, 32'h0000_0000, 2'b00, AXI_SLVERR);
    repeat (2) @(posedge clk);
    if (irq_seen == 0) begin
      errors++;
      $display("ERROR: ACE_Lite irq not asserted on SLVERR protocol error");
    end
    // unsupported burst type -> SLVERR as well
    axi_write(32'h0000_0080, 8'd1, 32'h0000_0000, 2'b10, 4'hF, 2'b00, AXI_SLVERR);

    // ---------------- 6. back-to-back transactions ----------------
    axi_write(32'h0000_0300, 8'd1, 32'h0ACE_2000, 2'b01, 4'hF, 2'b00, AXI_OKAY);
    axi_write(32'h0000_0340, 8'd1, 32'h0ACE_3000, 2'b01, 4'hF, 2'b00, AXI_OKAY);
    axi_read (32'h0000_0300, 8'd1, 32'h0ACE_2000, 2'b00, AXI_OKAY);
    axi_read (32'h0000_0340, 8'd1, 32'h0ACE_3000, 2'b00, AXI_OKAY);

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 256-word init sweep (resyncs the scoreboard) + 140 randomized
    // burst transactions, ~50/50 write/read. Randomized: burst len
    // (0..255, mostly short, sometimes long for counter toggle), burst
    // type (mostly INCR, sometimes illegal -> SLVERR), size (mostly 2,
    // sometimes >2 -> SLVERR), address class (in-range / boundary /
    // out-of-range / oob-high-bits / misaligned), per-beat data +
    // strobes, ACE-Lite side fields, and backpressure stalls.
    begin : crv_phase
      int n_wr = 0, n_rd = 0;
      int roll;
      logic [31:0] c_addr;
      logic [7:0]  c_len;
      logic [1:0]  c_burst;
      logic [2:0]  c_size;
      logic        c_stall;
      // resync sweep: full-strobe write of every word so both the DUT
      // memory and the scoreboard are fully overwritten
      for (int i = 0; i < 256; i++)
        crv_write(32'(i * 4), 8'd0, 2'b01, 3'd2, 1'b0, 1'b0);
      for (int t = 0; t < 140; t++) begin
        c_stall = $urandom_range(0, 1);
        // length class
        roll  = $urandom_range(0, 19);
        c_len = (roll < 13) ? 8'($urandom_range(0, 15)) :
                (roll < 18) ? 8'(16 + $urandom_range(0, 47))
                            : 8'(64 + $urandom_range(0, 191));
        // burst type: mostly INCR, sometimes illegal -> SLVERR
        roll    = $urandom_range(0, 19);
        c_burst = (roll < 15) ? 2'b01 : 2'($urandom_range(0, 3));
        // size: mostly 32-bit, sometimes >2 -> SLVERR
        roll   = $urandom_range(0, 9);
        c_size = (roll < 8) ? 3'd2 : 3'(3 + $urandom_range(0, 4));
        // address class
        roll = $urandom_range(0, 19);
        if (roll < 10)
          c_addr = 32'($urandom_range(0, 255) * 4);           // in-range
        else if (roll < 13)
          c_addr = 32'($urandom_range(240, 255) * 4);         // boundary
        else if (roll < 16)
          c_addr = 32'(1024 + $urandom_range(0, 4095) * 4);   // out of range
        else if (roll < 18)
          c_addr = $urandom | 32'hFFFF_0000;                  // oob high bits
        else
          c_addr = 32'($urandom_range(0, 255) * 4) +
                   32'($urandom_range(1, 3));                 // misaligned
        if ($urandom_range(0, 1)) begin
          n_wr++;
          crv_write(c_addr, c_len, c_burst, c_size, c_stall);
        end else begin
          n_rd++;
          crv_read(c_addr, c_len, c_burst, c_size, c_stall);
        end
      end
      // ---- targeted toggle closure: all-ones/all-zeros patterns make
      // every wdata/rdata bit toggle deterministically (uses the
      // directed tasks; placed last, scoreboard no longer needed)
      axi_write(32'h020, 8'd0, 32'hFFFF_FFFF, 2'b01, 4'hF, 2'b00, AXI_OKAY);
      axi_read (32'h020, 8'd0, 32'hFFFF_FFFF, 2'b00, AXI_OKAY);
      axi_write(32'h020, 8'd0, 32'h0000_0000, 2'b01, 4'hF, 2'b00, AXI_OKAY);
      axi_read (32'h020, 8'd0, 32'h0000_0000, 2'b00, AXI_OKAY);
      $display("CRV: 256 init + 140 txns (wr=%0d rd=%0d)", n_wr, n_rd);
    end
`endif
    if (errors == 0) $display("TEST PASSED: ACE_Lite");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < 3; s++) visited += wfsm_seen[s];
      for (int s = 0; s < 2; s++) visited += rfsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, ACEL_FSM_TOTAL);
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
    repeat (5000) #1000;   // 5 ms in 1-us chunks
    $display("TIMEOUT");
    $finish;
  end
`else
  initial begin
    #200000;
    $display("TIMEOUT");
    $finish;
  end
`endif
endmodule
