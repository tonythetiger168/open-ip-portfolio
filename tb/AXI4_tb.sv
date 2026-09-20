// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for AXI4_top -- AXI4 master model
// Task-ized 5-channel handshake drivers; scoreboard memory model;
// checks: reset state, burst write/read compare (len=0/1/3/15, INCR+FIXED),
// wvalid gaps, bvalid/rvalid hold under backpressure, rready mid-burst revoke,
// out-of-range SLVERR injection (AW-time and mid-burst), DECERR on nonzero ID,
// wlast protocol-error injection + irq, consecutive back-to-back transactions.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module AXI4_tb;
  localparam int DW = 32, AW = 32;
  localparam logic [1:0] OKAY   = 2'b00;
  localparam logic [1:0] SLVERR = 2'b10;
  localparam logic [1:0] DECERR = 2'b11;
  localparam logic [1:0] FIXED  = 2'b00;
  localparam logic [1:0] INCR   = 2'b01;

  logic clk = 0, rst_n = 0;
  logic [3:0]      awid;
  logic [AW-1:0]   awaddr;
  logic [7:0]      awlen;
  logic [2:0]      awsize;
  logic [1:0]      awburst;
  logic            awvalid;
  logic            awready;
  logic [DW-1:0]   wdata;
  logic [DW/8-1:0] wstrb;
  logic            wlast;
  logic            wvalid;
  logic            wready;
  logic [3:0]      bid;
  logic [1:0]      bresp;
  logic            bvalid;
  logic            bready;
  logic [3:0]      arid;
  logic [AW-1:0]   araddr;
  logic [7:0]      arlen;
  logic [2:0]      arsize;
  logic [1:0]      arburst;
  logic            arvalid;
  logic            arready;
  logic [3:0]      rid;
  logic [DW-1:0]   rdata;
  logic [1:0]      rresp;
  logic            rlast;
  logic            rvalid;
  logic            rready;
  logic            irq;

  int errors = 0;
  logic [31:0] model [0:255];   // scoreboard of expected memory contents

  AXI4_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
    .awburst(awburst), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid),
    .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
    .arburst(arburst), .arvalid(arvalid), .arready(arready),
    .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
    .rvalid(rvalid), .rready(rready),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // channel tasks (all stimulus driven / sampled on negedge => race-free)
  // ------------------------------------------------------------------
  task automatic axi_aw(input logic [3:0] id, input logic [AW-1:0] addr,
                        input logic [7:0] len, input logic [1:0] burst);
    begin
      @(negedge clk);
      awid <= id; awaddr <= addr; awlen <= len;
      awsize <= 3'd2; awburst <= burst; awvalid <= 1'b1;
      while (!awready) @(negedge clk);
      @(posedge clk);            // address accepted here
      @(negedge clk);
      awvalid <= 1'b0;
    end
  endtask

  task automatic axi_w(input logic [DW-1:0] data, input logic last,
                       input bit stall_en);
    begin
      if (stall_en) repeat ($urandom_range(0, 2)) @(negedge clk);  // wvalid gap
      @(negedge clk);
      wvalid <= 1'b1; wdata <= data; wstrb <= 4'hF; wlast <= last;
      while (!wready) @(negedge clk);
      @(posedge clk);            // beat accepted here
      @(negedge clk);
      wvalid <= 1'b0; wlast <= 1'b0;
    end
  endtask

  task automatic axi_b(input logic [1:0] exp, input logic [3:0] exp_id,
                       input bit hold);
    begin
      bready <= 1'b0;
      @(negedge clk);
      while (!bvalid) @(negedge clk);
      if (bresp !== exp) begin
        errors++; $display("ERROR: bresp=%b exp=%b", bresp, exp);
      end
      if (bid !== exp_id) begin
        errors++; $display("ERROR: bid=%h exp=%h", bid, exp_id);
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

  task automatic axi_ar(input logic [3:0] id, input logic [AW-1:0] addr,
                        input logic [7:0] len, input logic [1:0] burst);
    begin
      @(negedge clk);
      arid <= id; araddr <= addr; arlen <= len;
      arsize <= 3'd2; arburst <= burst; arvalid <= 1'b1;
      while (!arready) @(negedge clk);
      @(posedge clk);            // address accepted here
      @(negedge clk);
      arvalid <= 1'b0;
    end
  endtask

  // per-beat read-response expectation for OKAY-class bursts that may run
  // out of range mid-burst
  task automatic check_rresp_beat(input bit in_range, input int beat);
    begin
      if (in_range) begin
        if (rresp !== OKAY) begin
          errors++; $display("ERROR: rresp beat%0d=%b exp=OKAY", beat, rresp);
        end
      end else begin
        if (rresp !== SLVERR) begin
          errors++; $display("ERROR: rresp beat%0d=%b exp=SLVERR (oob)", beat, rresp);
        end
      end
    end
  endtask

  // full write burst + response check; scoreboard updated for every in-range
  // beat when update_model=1 (mirrors DUT: error bursts drop failing beats)
  task automatic axi_write_burst(input logic [3:0] id, input logic [31:0] addr,
                                 input logic [7:0] len, input logic [1:0] burst,
                                 input logic [31:0] base, input logic [1:0] exp,
                                 input bit stalls, input bit update_model);
    logic [31:0] a;
    begin
      axi_aw(id, addr, len, burst);
      for (int i = 0; i <= len; i++) begin
        axi_w(base + i, (i == len), stalls);
        a = (burst == INCR) ? addr + i*4 : addr;
        if (update_model && (a < 1024) && (a[1:0] == 0) &&
            (exp == OKAY || exp == SLVERR))
          model[a[9:2]] = base + i;
      end
      axi_b(exp, id, stalls);
    end
  endtask

  // full read burst with per-beat response/data checks and rready stalls
  task automatic axi_read_burst(input logic [3:0] id, input logic [31:0] addr,
                                input logic [7:0] len, input logic [1:0] burst,
                                input logic [1:0] exp, input bit stalls,
                                input bit check_model);
    logic [31:0] a, save_d;
    int stall;
    begin
      rready <= 1'b0;
      axi_ar(id, addr, len, burst);
      for (int i = 0; i <= len; i++) begin
        @(negedge clk);
        while (!rvalid) @(negedge clk);
        a = (burst == INCR) ? addr + i*4 : addr;
        if (exp == OKAY)
          check_rresp_beat(a < 1024, i);
        else if (rresp !== exp) begin
          errors++; $display("ERROR: rresp beat%0d=%b exp=%b", i, rresp, exp);
        end
        if (rlast !== (i == len)) begin
          errors++; $display("ERROR: rlast beat%0d=%b exp=%b", i, rlast, (i == len));
        end
        if (rid !== id) begin
          errors++; $display("ERROR: rid=%h exp=%h", rid, id);
        end
        if ((rresp === OKAY) && check_model) begin
          if (rdata !== model[a[9:2]]) begin
            errors++;
            $display("ERROR: rdata @%h beat%0d got=%h exp=%h",
                     a, i, rdata, model[a[9:2]]);
          end
        end
        // random rready backpressure: rvalid/rdata must be held stable
        stall = (stalls && (i < len)) ? $urandom_range(0, 3) : 0;
        save_d = rdata;
        repeat (stall) begin
          @(negedge clk);
          if (!rvalid) begin
            errors++; $display("ERROR: rvalid dropped under backpressure beat%0d", i);
          end
          if (rdata !== save_d) begin
            errors++; $display("ERROR: rdata unstable under backpressure beat%0d", i);
          end
        end
        rready <= 1'b1;
        @(posedge clk);          // beat accepted here
        @(negedge clk);
        rready <= 1'b0;
      end
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
  localparam int AXI4_FSM_TOTAL = 5;  // W_IDLE/W_DATA/W_RESP + R_IDLE/R_DATA
  logic [3:0] wfsm_seen = '0;         // write-FSM visited-state bitmap
  logic [1:0] rfsm_seen = '0;         // read-FSM visited-state bitmap
  wire  [1:0] dut_wstate = dut.wstate;  // hierarchical FSM probes
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
  logic [3:0]  p_bid    = 0;
  logic        p_rvalid = 0, p_rready = 0, p_rlast = 0;
  logic [1:0]  p_rresp  = 0;
  logic [3:0]  p_rid    = 0;
  logic [31:0] p_rdata  = 0;
  logic        p_irq    = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: no response channel activity during reset
      sva_check(bvalid === 1'b0 && rvalid === 1'b0, "A1 reset: b/rvalid low");
    end else begin
      // A2: bvalid held stable until bready (payload must not change)
      sva_check(!(p_bvalid && !p_bready) ||
                (bvalid && bresp === p_bresp && bid === p_bid),
                "A2 bvalid/bresp/bid held until bready");
      // A3: rvalid held stable until rready (payload must not change)
      sva_check(!(p_rvalid && !p_rready) ||
                (rvalid && rdata === p_rdata && rresp === p_rresp &&
                 rlast === p_rlast && rid === p_rid),
                "A3 rvalid/rdata/rresp held until rready");
      // A4: bresp only OKAY/SLVERR/DECERR (2'b01 unused by AXI4 slave)
      sva_check(!bvalid || (bresp !== 2'b01), "A4 bresp legal");
      // A5: rresp only OKAY/SLVERR/DECERR
      sva_check(!rvalid || (rresp !== 2'b01), "A5 rresp legal");
      // A6: rlast only together with rvalid
      sva_check(!rlast || rvalid, "A6 rlast implies rvalid");
      // A7: irq is sticky until reset
      sva_check(!p_irq || irq, "A7 irq sticky");
      // A8: write FSM holds a legal enum encoding
      sva_check(dut_wstate <= 2'd2, "A8 wstate encoding legal");
      // A9: OKAY responses only for ID 0 (nonzero IDs get DECERR)
      sva_check(!(bvalid && bresp === OKAY) || (bid === 4'h0),
                "A9 OKAY bresp implies bid==0");
      sva_check(!(rvalid && rresp === OKAY) || (rid === 4'h0),
                "A9b OKAY rresp implies rid==0");
    end
    p_bvalid <= bvalid; p_bready <= bready; p_bresp <= bresp; p_bid <= bid;
    p_rvalid <= rvalid; p_rready <= rready; p_rlast <= rlast;
    p_rresp  <= rresp;  p_rid    <= rid;    p_rdata <= rdata;
    p_irq    <= irq;
  end

  // ---- W-channel beat with explicit byte strobes (CRV only) ---------
  task automatic axi_w_strb(input logic [DW-1:0] data, input logic [3:0] strb,
                            input logic last, input bit stall_en);
    begin
      if (stall_en) repeat ($urandom_range(0, 2)) @(negedge clk);
      @(negedge clk);
      wvalid <= 1'b1; wdata <= data; wstrb <= strb; wlast <= last;
      while (!wready) @(negedge clk);
      @(posedge clk);            // beat accepted here
      @(negedge clk);
      wvalid <= 1'b0; wlast <= 1'b0;
    end
  endtask

  // ---- expected-response model --------------------------------------
  // decode error at address time: nonzero ID, reserved burst encoding,
  // size > 32-bit, or len > 15 (mirrors the DUT decerr() function)
  function automatic logic crv_decerr(input logic [3:0] id,
                                      input logic [1:0] burst,
                                      input logic [2:0] size,
                                      input logic [7:0] len);
    crv_decerr = (id != 4'h0) || (burst == 2'b11) || (size > 3'd2) ||
                 (len[7:4] != 4'h0);
  endfunction
  // slave error at address time: out of range, misaligned, or WRAP
  function automatic logic crv_slverr(input logic [31:0] addr,
                                      input logic [1:0] burst);
    crv_slverr = (addr[31:10] != '0) || (addr[1:0] != 2'b00) ||
                 (burst == 2'b10);
  endfunction

  // ---- AW/AR channel tasks with explicit size (CRV only; the directed
  //      axi_aw/axi_ar hardcode size=2 and stay untouched) ------------
  task automatic crv_aw(input logic [3:0] id, input logic [AW-1:0] addr,
                        input logic [7:0] len, input logic [1:0] burst,
                        input logic [2:0] size);
    begin
      @(negedge clk);
      awid <= id; awaddr <= addr; awlen <= len;
      awsize <= size; awburst <= burst; awvalid <= 1'b1;
      while (!awready) @(negedge clk);
      @(posedge clk);            // address accepted here
      @(negedge clk);
      awvalid <= 1'b0;
    end
  endtask

  task automatic crv_ar(input logic [3:0] id, input logic [AW-1:0] addr,
                        input logic [7:0] len, input logic [1:0] burst,
                        input logic [2:0] size);
    begin
      @(negedge clk);
      arid <= id; araddr <= addr; arlen <= len;
      arsize <= size; arburst <= burst; arvalid <= 1'b1;
      while (!arready) @(negedge clk);
      @(posedge clk);            // address accepted here
      @(negedge clk);
      arvalid <= 1'b0;
    end
  endtask

  // copy of the directed axi_read_burst flow, but with explicit AR size
  task automatic crv_read_burst(input logic [3:0] id, input logic [31:0] addr,
                                input logic [7:0] len, input logic [1:0] burst,
                                input logic [2:0] size, input logic [1:0] exp,
                                input bit stalls, input bit check_model);
    logic [31:0] a, save_d;
    int stall;
    begin
      rready <= 1'b0;
      crv_ar(id, addr, len, burst, size);
      for (int i = 0; i <= len; i++) begin
        @(negedge clk);
        while (!rvalid) @(negedge clk);
        a = (burst == INCR) ? addr + i*4 : addr;
        if (exp == OKAY)
          check_rresp_beat(a < 1024, i);
        else if (rresp !== exp) begin
          errors++; $display("ERROR: rresp beat%0d=%b exp=%b", i, rresp, exp);
        end
        if (rlast !== (i == len)) begin
          errors++; $display("ERROR: rlast beat%0d=%b exp=%b", i, rlast, (i == len));
        end
        if (rid !== id) begin
          errors++; $display("ERROR: rid=%h exp=%h", rid, id);
        end
        if ((rresp === OKAY) && check_model) begin
          if (rdata !== model[a[9:2]]) begin
            errors++;
            $display("ERROR: rdata @%h beat%0d got=%h exp=%h",
                     a, i, rdata, model[a[9:2]]);
          end
        end
        stall = (stalls && (i < len)) ? $urandom_range(0, 3) : 0;
        save_d = rdata;
        repeat (stall) begin
          @(negedge clk);
          if (!rvalid) begin
            errors++; $display("ERROR: rvalid dropped under backpressure beat%0d", i);
          end
          if (rdata !== save_d) begin
            errors++; $display("ERROR: rdata unstable under backpressure beat%0d", i);
          end
        end
        rready <= 1'b1;
        @(posedge clk);          // beat accepted here
        @(negedge clk);
        rready <= 1'b0;
      end
    end
  endtask
`endif

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  initial begin
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    wlast = 0;
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

    // ---- check 2: burst write/read compare x4 (len boundary 0 and 15) ----
    axi_write_burst(4'h0, 32'h000, 8'd0,  INCR, 32'hA500_0000, OKAY, 1'b1, 1'b1);
    axi_read_burst (4'h0, 32'h000, 8'd0,  INCR, OKAY, 1'b1, 1'b1);
    check_irq(1'b0, "after t1");

    axi_write_burst(4'h0, 32'h040, 8'd1,  INCR, 32'hB600_0000, OKAY, 1'b1, 1'b1);
    axi_read_burst (4'h0, 32'h040, 8'd1,  INCR, OKAY, 1'b1, 1'b1);

    axi_write_burst(4'h0, 32'h080, 8'd3,  INCR, 32'hC700_0000, OKAY, 1'b1, 1'b1);
    axi_read_burst (4'h0, 32'h080, 8'd3,  INCR, OKAY, 1'b1, 1'b1);

    axi_write_burst(4'h0, 32'h100, 8'd15, INCR, 32'hD800_0000, OKAY, 1'b1, 1'b1);
    axi_read_burst (4'h0, 32'h100, 8'd15, INCR, OKAY, 1'b1, 1'b1);
    check_irq(1'b0, "after t4");

    // ---- check 3: FIXED burst (all beats same address, last write wins) ----
    axi_write_burst(4'h0, 32'h200, 8'd3, FIXED, 32'h1234_5000, OKAY, 1'b0, 1'b1);
    axi_read_burst (4'h0, 32'h200, 8'd3, FIXED, OKAY, 1'b1, 1'b1);

    // ---- check 4: end-of-range boundary, exactly filling to 0x3FC ----
    axi_write_burst(4'h0, 32'h3F0, 8'd3, INCR, 32'hEE00_0000, OKAY, 1'b0, 1'b1);
    axi_read_burst (4'h0, 32'h3F0, 8'd3, INCR, OKAY, 1'b1, 1'b1);
    check_irq(1'b0, "before error tests");

    // ---- check 5: mid-burst out-of-range (write then read at 0x3F8 len 3) ----
    // beats 0x3F8/0x3FC OK, beats 0x400/0x404 out of range
    axi_write_burst(4'h0, 32'h3F8, 8'd3, INCR, 32'h0BAD_0000, SLVERR, 1'b0, 1'b1);
    check_irq(1'b1, "mid-burst write SLVERR");
    axi_read_burst (4'h0, 32'h3F8, 8'd3, INCR, OKAY, 1'b1, 1'b1);

    // ---- check 6: out-of-range address injection, whole burst SLVERR ----
    axi_write_burst(4'h0, 32'h2000, 8'd1, INCR, 32'hDEAD_0000, SLVERR, 1'b0, 1'b0);
    axi_read_burst (4'h0, 32'h3000, 8'd0, INCR, SLVERR, 1'b0, 1'b0);
    check_irq(1'b1, "oob SLVERR");

    // ---- check 7: nonzero ID -> DECERR, memory untouched ----
    axi_write_burst(4'h5, 32'h000, 8'd0, INCR, 32'hFFFF_0000, DECERR, 1'b0, 1'b0);
    axi_read_burst (4'h7, 32'h000, 8'd0, INCR, DECERR, 1'b0, 1'b0);
    check_irq(1'b1, "DECERR id");
    // location 0x000 must still hold the check-2 data
    axi_read_burst (4'h0, 32'h000, 8'd0, INCR, OKAY, 1'b0, 1'b1);

    // ---- check 8: wlast protocol error (early wlast) -> SLVERR + irq ----
    axi_aw(4'h0, 32'h280, 8'd2, INCR);       // declares 3 beats
    axi_w(32'h1111_0000, 1'b0, 1'b0);
    axi_w(32'h2222_0000, 1'b1, 1'b0);        // wlast one beat early
    axi_b(SLVERR, 4'h0, 1'b1);
    check_irq(1'b1, "early wlast");

    // ---- check 9: consecutive back-to-back transactions ----
    axi_write_burst(4'h0, 32'h2C0, 8'd1, INCR, 32'h5A00_0000, OKAY, 1'b0, 1'b1);
    axi_write_burst(4'h0, 32'h2C8, 8'd1, INCR, 32'h5B00_0000, OKAY, 1'b0, 1'b1);
    axi_read_burst (4'h0, 32'h2C0, 8'd3, INCR, OKAY, 1'b1, 1'b1);

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 220 randomized transactions, ~50/50 write/read. Randomized: burst
    // len 1..16, INCR/FIXED/WRAP/reserved burst, ID 0 vs nonzero, address
    // class (in-range aligned / boundary / out-of-range / misaligned),
    // per-beat byte strobes, and backpressure stalls. The scoreboard
    // memory model is updated exactly where the DUT writes (address-time
    // OKAY class + in-range beat), and reads compare against it.
    begin : crv_phase
      int n_wr = 0, n_rd = 0;
      int n_okay = 0, n_slv = 0, n_dec = 0;
      logic [3:0]  c_id;
      logic [31:0] c_addr, c_base, c_a, c_d;
      logic [7:0]  c_len;
      logic [1:0]  c_burst;
      logic [3:0]  c_strb;
      logic        c_stall, c_wrn;
      logic        c_dec, c_slv, c_awok;
      int          roll;
      logic [2:0]  c_size;
      // scoreboard sync: directed check 8 (early-wlast injection) drives
      // its beats manually and never updates the model, but the DUT does
      // write both locations before flagging SLVERR (mem[0x280]=0x1111_0000,
      // mem[0x284]=0x2222_0000). Resync so random read-backs compare
      // against the true DUT contents.
      model[32'h280 >> 2] = 32'h1111_0000;
      model[32'h284 >> 2] = 32'h2222_0000;
      for (int t = 0; t < 220; t++) begin
        // ---- randomize transaction attributes (procedural constraints)
        c_wrn   = $urandom_range(0, 1);
        c_id    = ($urandom_range(0, 9) < 8) ? 4'h0 : $urandom_range(1, 15);
        c_stall = $urandom_range(0, 1);
        c_base  = $urandom;
        // len: mostly legal 0..15, sometimes >15 (DECERR, long bursts
        // also toggle the len/beat-counter high bits)
        c_len   = ($urandom_range(0, 19) < 18) ? 8'($urandom_range(0, 15))
                                               : 8'(16 + $urandom_range(0, 239));
        // size: mostly 2 (32-bit); sometimes legal 0/1, sometimes >2
        // (DECERR) so the size input bits toggle
        roll    = $urandom_range(0, 9);
        c_size  = (roll < 7) ? 3'd2 :
                  (roll < 8) ? 3'($urandom_range(0, 1))
                             : 3'(3 + $urandom_range(0, 4));
        roll    = $urandom_range(0, 19);
        if      (roll < 14) c_burst = INCR;
        else if (roll < 18) c_burst = FIXED;
        else if (roll < 19) c_burst = 2'b10;   // WRAP -> SLVERR
        else                c_burst = 2'b11;   // reserved -> DECERR
        roll = $urandom_range(0, 19);
        if (roll < 10) begin
          c_addr = $urandom_range(0, 255) * 4;             // aligned in-range
        end else if (roll < 13) begin
          c_addr = $urandom_range(240, 255) * 4;           // range boundary
        end else if (roll < 15) begin
          c_addr = 1024 + $urandom_range(0, 4095) * 4;     // out of range
        end else if (roll < 17) begin
          c_addr = $urandom | 32'hFFFF_0000;               // oob, high bits
        end else begin
          c_addr = $urandom_range(0, 255) * 4 +
                   $urandom_range(1, 3);                   // misaligned
        end
        c_dec  = crv_decerr(c_id, c_burst, c_size, c_len);
        c_slv  = crv_slverr(c_addr, c_burst);
        c_awok = !c_dec && !c_slv;   // address-time OKAY class
        if (c_dec) n_dec++; else if (c_slv) n_slv++; else n_okay++;

        if (c_wrn) begin
          // ---- randomized write burst -------------------------------
          logic [1:0] bexp;
          n_wr++;
          // bresp: SLVERR if an INCR burst runs out of range mid-burst
          bexp = c_dec ? DECERR :
                 c_slv ? SLVERR :
                 ((c_burst == INCR) && (c_len[7:4] == 4'h0) &&
                  ((c_addr + c_len * 4) >= 1024)) ? SLVERR : OKAY;
          crv_aw(c_id, c_addr, c_len, c_burst, c_size);
          for (int i = 0; i <= c_len; i++) begin
            c_strb = $urandom_range(0, 15);
            c_d    = c_base + i;
            axi_w_strb(c_d, c_strb, (i == c_len), c_stall);
            // scoreboard update: only where the DUT actually writes
            c_a = (c_burst == INCR) ? c_addr + i * 4 : c_addr;
            if (c_awok && (c_a < 1024))
              for (int b = 0; b < 4; b++)
                if (c_strb[b]) model[c_a[9:2]][8*b +: 8] = c_d[8*b +: 8];
          end
          axi_b(bexp, c_id, c_stall);
        end else begin
          // ---- randomized read burst --------------------------------
          n_rd++;
          if (c_awok)
            // per-beat rresp check covers mid-burst out-of-range; data
            // compared against the scoreboard model on OKAY beats
            crv_read_burst(c_id, c_addr, c_len, c_burst, c_size,
                           OKAY, c_stall, 1'b1);
          else
            crv_read_burst(c_id, c_addr, c_len, c_burst, c_size,
                           c_dec ? DECERR : SLVERR, c_stall, 1'b0);
        end
      end
      // ---- targeted toggle closure: max-length violation bursts ------
      // len=0xA5 (>15 -> DECERR) makes the beat counters and len
      // registers toggle their high bits [7:4] deterministically.
      crv_aw(4'h0, 32'h0000_0040, 8'hA5, INCR, 3'd2);
      for (int i = 0; i <= 8'hA5; i++)
        axi_w_strb($urandom, 4'hF, (i == 8'hA5), 1'b0);
      axi_b(DECERR, 4'h0, 1'b0);
      crv_read_burst(4'h0, 32'h0000_0040, 8'hA5, INCR, 3'd2,
                     DECERR, 1'b0, 1'b0);
      $display("CRV: 220 txns (wr=%0d rd=%0d | okay=%0d slverr=%0d decerr=%0d)",
               n_wr, n_rd, n_okay, n_slv, n_dec);
    end
`endif
    if (errors == 0) $display("TEST PASSED: AXI4");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < 3; s++) visited += wfsm_seen[s];
      for (int s = 0; s < 2; s++) visited += rfsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, AXI4_FSM_TOTAL);
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
    #500000;
    $display("ERROR: TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif
endmodule
