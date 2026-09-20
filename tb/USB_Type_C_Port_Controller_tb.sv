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

    if (errors == 0) $display("TEST PASSED: USB Type-C Port Controller");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #200000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
endmodule
