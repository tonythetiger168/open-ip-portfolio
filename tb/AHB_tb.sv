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
    if (errors == 0) $display("TEST PASSED: AHB");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // timeout guard
  initial begin
    #50000;
    errors++;
    $display("ERROR: TIMEOUT guard fired");
    $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

endmodule
