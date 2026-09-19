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

    if (errors == 0) $display("TEST PASSED: ACE_Lite");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #200000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
