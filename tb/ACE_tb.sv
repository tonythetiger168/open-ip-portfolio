// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for ACE_top -- AXI4 master model + snoop (AC/CR/CD)
// interconnect model. Checks: reset state, burst write/read compare,
// snoop dirty-hit data return, snoop miss, MakeUnique invalidation,
// SLVERR error injection + irq, back-to-back transactions.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module ACE_tb;
  localparam int DW = 32, AW = 32;

  localparam logic [1:0] AXI_OKAY   = 2'b00;
  localparam logic [1:0] AXI_SLVERR = 2'b10;
  localparam logic [3:0] SNP_READSHARED = 4'b0000;
  localparam logic [3:0] SNP_READCLEAN  = 4'b0001;
  localparam logic [3:0] SNP_MAKEUNIQUE = 4'b0111;

  logic clk = 0, rst_n = 0;
  // AW
  logic awvalid = 0, awready;
  logic [AW-1:0] awaddr = 0;
  logic [7:0]  awlen = 0;
  logic [2:0]  awsize = 0;
  logic [1:0]  awburst = 0;
  logic [2:0]  awsnoop = 0;
  logic [1:0]  awdomain = 0, awbar = 0;
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
  // AC
  logic acvalid = 0, acready;
  logic [AW-1:0] acaddr = 0;
  logic [3:0] acsnoop = 0;
  // CR
  logic crvalid, crready = 0;
  logic [4:0] crresp;
  // CD
  logic cdvalid, cdready = 0;
  logic [DW-1:0] cddata;
  logic cdlast;
  logic irq;

  int errors = 0;
  int irq_seen = 0;

  ACE_top #(.DW(DW), .AW(AW)) dut (
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
    .acvalid(acvalid), .acready(acready), .acaddr(acaddr), .acsnoop(acsnoop),
    .crvalid(crvalid), .crready(crready), .crresp(crresp),
    .cdvalid(cdvalid), .cdready(cdready), .cddata(cddata), .cdlast(cdlast),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // irq monitor
  always @(posedge clk) if (irq) irq_seen++;

  // -------------------------------------------------
  // AXI write burst: data = base+i for beat i
  // -------------------------------------------------
  task automatic axi_write(input logic [AW-1:0] addr, input logic [7:0] len,
                           input logic [DW-1:0] base, input logic [1:0] burst,
                           input logic [1:0] exp_resp);
    int stall;
    begin
      // AW
      @(negedge clk);
      awvalid = 1; awaddr = addr; awlen = len; awsize = 3'd2;
      awburst = burst; awsnoop = 3'b000; awdomain = 2'b01; awbar = 2'b00;
      while (!awready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) awvalid = 0;
      // W beats (with occasional wvalid stall)
      for (int i = 0; i <= len; i++) begin
        stall = ($random & 1);
        repeat (stall) @(negedge clk);
        wvalid = 1; wdata = base + i; wstrb = 4'hF; wlast = (i == len);
        while (!wready) @(negedge clk);
        @(posedge clk);
        @(negedge clk) wvalid = 0; wlast = 0;
      end
      // B (bready backpressure: hold low a couple of cycles)
      bready = 0;
      while (!bvalid) @(negedge clk);
      if (bresp !== exp_resp) begin
        errors++;
        $display("ERROR: ACE write @%h bresp=%b exp=%b", addr, bresp, exp_resp);
      end
      repeat (2) @(negedge clk);
      bready = 1;
      @(posedge clk);
      @(negedge clk) bready = 0;
    end
  endtask

  // -------------------------------------------------
  // AXI read burst: compare data = base+i, check rlast/rresp
  // -------------------------------------------------
  task automatic axi_read(input logic [AW-1:0] addr, input logic [7:0] len,
                          input logic [DW-1:0] base, input logic [1:0] exp_resp,
                          input bit exp_zero);
    logic [DW-1:0] exp;
    begin
      @(negedge clk);
      arvalid = 1; araddr = addr; arlen = len; arsize = 3'd2;
      arburst = 2'b01; arsnoop = 4'h0; ardomain = 2'b01; arbar = 2'b00;
      while (!arready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) arvalid = 0;
      for (int i = 0; i <= len; i++) begin
        rready = 0;
        while (!rvalid) @(negedge clk);
        exp = exp_zero ? 32'h0 : base + i;
        if (rdata !== exp) begin
          errors++;
          $display("ERROR: ACE read @%h beat%0d got=%h exp=%h", addr, i, rdata, exp);
        end
        if (rlast !== (i == len)) begin
          errors++;
          $display("ERROR: ACE read @%h beat%0d rlast=%b", addr, i, rlast);
        end
        if (rresp !== exp_resp) begin
          errors++;
          $display("ERROR: ACE read @%h beat%0d rresp=%b exp=%b", addr, i, rresp, exp_resp);
        end
        repeat ($random & 1) @(negedge clk);  // rready backpressure
        rready = 1;
        @(posedge clk);
        @(negedge clk) rready = 0;
      end
    end
  endtask

  // -------------------------------------------------
  // Snoop transaction: returns crresp; if DataTransfer, returns CD data
  // -------------------------------------------------
  task automatic do_snoop(input logic [AW-1:0] addr, input logic [3:0] stype,
                          output logic [4:0] resp, output logic [DW-1:0] dat);
    begin
      @(negedge clk);
      acvalid = 1; acaddr = addr; acsnoop = stype;
      while (!acready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) acvalid = 0;
      // CR
      while (!crvalid) @(negedge clk);
      resp = crresp;
      @(negedge clk) crready = 1;
      @(posedge clk);
      @(negedge clk) crready = 0;
      // CD if DataTransfer
      dat = '0;
      if (resp[0]) begin
        while (!cdvalid) @(negedge clk);
        dat = cddata;
        if (cdlast !== 1'b1) begin
          errors++;
          $display("ERROR: ACE snoop @%h cdlast not set on single-beat CD", addr);
        end
        @(negedge clk) cdready = 1;
        @(posedge clk);
        @(negedge clk) cdready = 0;
      end
    end
  endtask

  logic [4:0] sresp;
  logic [DW-1:0] sdat_q;

  initial begin
    // ---------------- 1. reset state check ----------------
    rst_n = 0; repeat (4) @(posedge clk);
    @(negedge clk);
    if (bvalid !== 0 || rvalid !== 0 || crvalid !== 0 || cdvalid !== 0) begin
      errors++;
      $display("ERROR: ACE reset state bvalid=%b rvalid=%b crvalid=%b cdvalid=%b",
               bvalid, rvalid, crvalid, cdvalid);
    end
    rst_n = 1; repeat (2) @(posedge clk);

    // ---------------- 2. burst write then read-back compare ----------------
    axi_write(32'h0000_0040, 8'd3,  32'hA5A5_0000, 2'b01, AXI_OKAY);
    axi_read (32'h0000_0040, 8'd3,  32'hA5A5_0000, AXI_OKAY, 0);
    axi_write(32'h0000_0100, 8'd15, 32'h1111_0000, 2'b01, AXI_OKAY);  // max len
    axi_read (32'h0000_0100, 8'd15, 32'h1111_0000, AXI_OKAY, 0);
    axi_write(32'h0000_0004, 8'd0,  32'h5A5A_5A5A, 2'b01, AXI_OKAY);  // single beat
    axi_read (32'h0000_0004, 8'd0,  32'h5A5A_5A5A, AXI_OKAY, 0);

    // ---------------- 3. snoop ReadShared hit on dirty line ----------------
    axi_write(32'h0000_0200, 8'd0, 32'hDEAD_BEEF, 2'b01, AXI_OKAY);
    do_snoop(32'h0000_0200, SNP_READSHARED, sresp, sdat_q);
    if (sresp[0] !== 1'b1 || sresp[2] !== 1'b1 || sresp[3] !== 1'b1) begin
      errors++;
      $display("ERROR: ACE snoop dirty hit crresp=%b (exp DataTransfer+PassDirty+IsShared)", sresp);
    end
    if (sdat_q !== 32'hDEAD_BEEF) begin
      errors++;
      $display("ERROR: ACE snoop CD data got=%h exp=DEADBEEF", sdat_q);
    end

    // ---------------- 4. snoop miss (never-written address) ----------------
    do_snoop(32'h0000_3000, SNP_READSHARED, sresp, sdat_q);
    if (sresp !== 5'b00000) begin
      errors++;
      $display("ERROR: ACE snoop miss crresp=%b exp=00000", sresp);
    end

    // ---------------- 5. MakeUnique invalidation ----------------
    axi_write(32'h0000_0400, 8'd0, 32'hCAFE_F00D, 2'b01, AXI_OKAY);
    do_snoop(32'h0000_0400, SNP_MAKEUNIQUE, sresp, sdat_q);
    if (sresp !== 5'b00000) begin
      errors++;
      $display("ERROR: ACE MakeUnique crresp=%b exp=00000 (no data)", sresp);
    end
    // line must be invalidated: re-snoop misses now
    do_snoop(32'h0000_0400, SNP_READSHARED, sresp, sdat_q);
    if (sresp !== 5'b00000) begin
      errors++;
      $display("ERROR: ACE post-MakeUnique snoop crresp=%b exp=00000", sresp);
    end
    // and AXI read of invalidated line reads as miss (zero)
    axi_read(32'h0000_0400, 8'd0, 32'h0, AXI_OKAY, 1);

    // ---------------- 6. error injection: out-of-range -> SLVERR + irq ----
    irq_seen = 0;
    axi_write(32'h0002_0000, 8'd0, 32'hBAD0_BAD0, 2'b01, AXI_SLVERR);
    axi_read (32'h0002_0000, 8'd0, 32'h0, AXI_SLVERR, 0);
    repeat (2) @(posedge clk);
    if (irq_seen == 0) begin
      errors++;
      $display("ERROR: ACE irq not asserted on SLVERR protocol error");
    end

    // ---------------- 7. back-to-back transactions ----------------
    axi_write(32'h0000_0080, 8'd1, 32'h0ACE_0000, 2'b01, AXI_OKAY);
    axi_write(32'h0000_00C0, 8'd1, 32'h0ACE_1000, 2'b01, AXI_OKAY);
    axi_read (32'h0000_0080, 8'd1, 32'h0ACE_0000, AXI_OKAY, 0);
    axi_read (32'h0000_00C0, 8'd1, 32'h0ACE_1000, AXI_OKAY, 0);
    // snoop ReadClean on clean line (written by back-to-back, still dirty)
    do_snoop(32'h0000_0080, SNP_READCLEAN, sresp, sdat_q);
    if (sresp[0] !== 1'b1 || sdat_q !== 32'h0ACE_0000) begin
      errors++;
      $display("ERROR: ACE back-to-back snoop resp=%b data=%h", sresp, sdat_q);
    end

    if (errors == 0) $display("TEST PASSED: ACE");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #200000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
