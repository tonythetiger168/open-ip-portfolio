// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for AXI_top -- AXI3-style master model
// Task-ized 5-channel handshake drivers (W channel carries WID);
// scoreboard memory model;
// checks: reset state, burst write/read compare x4 (len=0/1/3/15, INCR+FIXED,
// nonzero IDs echoed on bid/rid), wvalid gaps, bvalid/rvalid hold under
// backpressure, rready mid-burst revoke, out-of-range SLVERR injection
// (AW-time and mid-burst), WID mismatch (no interleave) -> SLVERR, illegal
// size -> DECERR, early wlast -> SLVERR, consecutive transactions.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module AXI_tb;
  localparam int DW = 32, AW = 32;
  localparam logic [1:0] OKAY   = 2'b00;
  localparam logic [1:0] SLVERR = 2'b10;
  localparam logic [1:0] DECERR = 2'b11;
  localparam logic [1:0] FIXED  = 2'b00;
  localparam logic [1:0] INCR   = 2'b01;

  logic clk = 0, rst_n = 0;
  logic [3:0]      awid;
  logic [AW-1:0]   awaddr;
  logic [3:0]      awlen;
  logic [2:0]      awsize;
  logic [1:0]      awburst;
  logic            awvalid;
  logic            awready;
  logic [3:0]      wid;
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
  logic [3:0]      arlen;
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

  AXI_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
    .awburst(awburst), .awvalid(awvalid), .awready(awready),
    .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
    .wvalid(wvalid), .wready(wready),
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
                        input logic [3:0] len, input logic [1:0] burst,
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

  task automatic axi_w(input logic [3:0] id, input logic [DW-1:0] data,
                       input logic last, input bit stall_en);
    begin
      if (stall_en) repeat ($urandom_range(0, 2)) @(negedge clk);  // wvalid gap
      @(negedge clk);
      wid <= id; wvalid <= 1'b1; wdata <= data; wstrb <= 4'hF; wlast <= last;
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
                        input logic [3:0] len, input logic [1:0] burst,
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
                                 input logic [3:0] len, input logic [1:0] burst,
                                 input logic [31:0] base, input logic [1:0] exp,
                                 input bit stalls, input bit update_model);
    logic [31:0] a;
    begin
      axi_aw(id, addr, len, burst, 3'd2);
      for (int i = 0; i <= len; i++) begin
        axi_w(id, base + i, (i == len), stalls);
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
                                input logic [3:0] len, input logic [1:0] burst,
                                input logic [1:0] exp, input bit stalls,
                                input bit check_model);
    logic [31:0] a, save_d;
    int stall;
    begin
      rready <= 1'b0;
      axi_ar(id, addr, len, burst, 3'd2);
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
    axi_write_burst(4'h3, 32'h000, 4'd0,  INCR, 32'hA500_0000, OKAY, 1'b1, 1'b1);
    axi_read_burst (4'h3, 32'h000, 4'd0,  INCR, OKAY, 1'b1, 1'b1);
    check_irq(1'b0, "after t1");

    axi_write_burst(4'h5, 32'h040, 4'd1,  INCR, 32'hB600_0000, OKAY, 1'b1, 1'b1);
    axi_read_burst (4'h5, 32'h040, 4'd1,  INCR, OKAY, 1'b1, 1'b1);

    axi_write_burst(4'h0, 32'h080, 4'd3,  INCR, 32'hC700_0000, OKAY, 1'b1, 1'b1);
    axi_read_burst (4'h0, 32'h080, 4'd3,  INCR, OKAY, 1'b1, 1'b1);

    axi_write_burst(4'hA, 32'h100, 4'd15, INCR, 32'hD800_0000, OKAY, 1'b1, 1'b1);
    axi_read_burst (4'hA, 32'h100, 4'd15, INCR, OKAY, 1'b1, 1'b1);
    check_irq(1'b0, "after t4");

    // ---- check 3: FIXED burst (all beats same address, last write wins) ----
    axi_write_burst(4'h1, 32'h200, 4'd3, FIXED, 32'h1234_5000, OKAY, 1'b0, 1'b1);
    axi_read_burst (4'h1, 32'h200, 4'd3, FIXED, OKAY, 1'b1, 1'b1);

    // ---- check 4: end-of-range boundary, exactly filling to 0x3FC ----
    axi_write_burst(4'h2, 32'h3F0, 4'd3, INCR, 32'hEE00_0000, OKAY, 1'b0, 1'b1);
    axi_read_burst (4'h2, 32'h3F0, 4'd3, INCR, OKAY, 1'b1, 1'b1);
    check_irq(1'b0, "before error tests");

    // ---- check 5: mid-burst out-of-range (write then read at 0x3F8 len 3) ----
    axi_write_burst(4'h0, 32'h3F8, 4'd3, INCR, 32'h0BAD_0000, SLVERR, 1'b0, 1'b1);
    check_irq(1'b1, "mid-burst write SLVERR");
    axi_read_burst (4'h0, 32'h3F8, 4'd3, INCR, OKAY, 1'b1, 1'b1);

    // ---- check 6: out-of-range address injection, whole burst SLVERR ----
    axi_write_burst(4'h0, 32'h2000, 4'd1, INCR, 32'hDEAD_0000, SLVERR, 1'b0, 1'b0);
    axi_read_burst (4'h0, 32'h3000, 4'd0, INCR, SLVERR, 1'b0, 1'b0);
    check_irq(1'b1, "oob SLVERR");

    // ---- check 7: WID mismatch (interleave not supported) -> SLVERR ----
    axi_aw(4'h4, 32'h2C0, 4'd1, INCR, 3'd2);   // declares 2 beats, ID=4
    axi_w(4'h4, 32'hAAAA_0000, 1'b0, 1'b0);    // matching WID: written
    axi_w(4'h9, 32'hBBBB_0000, 1'b1, 1'b0);    // wrong WID: dropped, SLVERR
    axi_b(SLVERR, 4'h4, 1'b1);
    check_irq(1'b1, "wid mismatch");
    // beat 0 must have landed, beat 1 must not
    axi_read_burst(4'h4, 32'h2C0, 4'd0, INCR, OKAY, 1'b0, 1'b0);
    if (rdata_seen !== 32'hAAAA_0000) begin
      errors++; $display("ERROR: wid-mismatch survivor got=%h exp=AAAA0000",
                         rdata_seen);
    end

    // ---- check 8: illegal size (>DW) -> DECERR, memory untouched ----
    axi_aw(4'h0, 32'h000, 4'd0, INCR, 3'd3);
    axi_w(4'h0, 32'hFFFF_FFFF, 1'b1, 1'b0);
    axi_b(DECERR, 4'h0, 1'b0);
    axi_ar(4'h0, 32'h000, 4'd0, INCR, 3'd7);
    begin
      rready <= 1'b0;
      @(negedge clk);
      while (!rvalid) @(negedge clk);
      if (rresp !== DECERR) begin
        errors++; $display("ERROR: rresp=%b exp=DECERR (bad arsize)", rresp);
      end
      rready <= 1'b1; @(posedge clk); @(negedge clk); rready <= 1'b0;
    end
    check_irq(1'b1, "DECERR size");
    axi_read_burst(4'h0, 32'h000, 4'd0, INCR, OKAY, 1'b0, 1'b1); // intact

    // ---- check 9: wlast protocol error (early wlast) -> SLVERR + irq ----
    axi_aw(4'h0, 32'h280, 4'd2, INCR, 3'd2);   // declares 3 beats
    axi_w(4'h0, 32'h1111_0000, 1'b0, 1'b0);
    axi_w(4'h0, 32'h2222_0000, 1'b1, 1'b0);    // wlast one beat early
    axi_b(SLVERR, 4'h0, 1'b1);
    check_irq(1'b1, "early wlast");

    // ---- check 10: consecutive back-to-back transactions ----
    axi_write_burst(4'h6, 32'h300, 4'd1, INCR, 32'h5A00_0000, OKAY, 1'b0, 1'b1);
    axi_write_burst(4'h7, 32'h308, 4'd1, INCR, 32'h5B00_0000, OKAY, 1'b0, 1'b1);
    axi_read_burst (4'h6, 32'h300, 4'd3, INCR, OKAY, 1'b1, 1'b1);

    if (errors == 0) $display("TEST PASSED: AXI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // captured read data for spot checks
  logic [31:0] rdata_seen;
  always @(posedge clk) if (rvalid && rready) rdata_seen <= rdata;

  // ------------------------------------------------------------------
  // timeout guard
  // ------------------------------------------------------------------
  initial begin
    #500000;
    $display("ERROR: TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
endmodule
