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

    if (errors == 0) $display("TEST PASSED: AXI4_Lite");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // ------------------------------------------------------------------
  // timeout guard
  // ------------------------------------------------------------------
  initial begin
    #200000;
    $display("ERROR: TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
endmodule
