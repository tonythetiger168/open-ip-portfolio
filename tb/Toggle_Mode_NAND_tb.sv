// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for Toggle_Mode_NAND_top -- NAND host model
// The dq bus is modelled as tri1 (pull-up); the host drives it only
// during command/address/data-in cycles, the DUT drives it during
// data-output cycles while re_n is low.
// Checks:
//   1. reset state: rb_n=1, irq=0, dq released (reads pulled-up FF)
//   2. Read ID (0x90): 5-byte ID compare
//   3. Page Program (0x80+0x10) -> Page Read (0x00+0x30) readback
//      compare on 3 pages; program rb_n busy ~200 clk, read ~25 clk
//   4. Read Status (0x70): bit6 ready / bit0 fail semantics
//   5. Block Erase (0x60+0xD0): rb_n ~1000 clk, erased page reads FF
//   6. protected block (pages 12..15) program -> status fail, array FF
//   7. bad command sequence injection (0x30 / unknown 0xAB in idle)
//      -> ignored + irq; 0xFF Reset clears irq
`timescale 1ns/1ps
module Toggle_Mode_NAND_tb;

  logic clk = 0, rst_n = 0;
  logic ce_n, cle, ale, we_n, re_n;
  tri1  [7:0] dq;
  wire        dqs;
  logic       rb_n, irq;

  logic       host_oe;
  logic [7:0] host_dq;
  assign dq = host_oe ? host_dq : 8'hzz;

  int errors = 0;

  localparam logic [39:0] DEV_ID = {8'h2C, 8'hA5, 8'h90, 8'h16, 8'h54};

  Toggle_Mode_NAND_top dut (
    .clk(clk), .rst_n(rst_n),
    .ce_n(ce_n), .cle(cle), .ale(ale), .we_n(we_n), .re_n(re_n),
    .dq(dq), .dqs(dqs), .rb_n(rb_n), .irq(irq)
  );

  always #5 clk = ~clk;

  task automatic check(input logic cond, input string msg);
    begin
      if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
    end
  endtask

  // one host write cycle (command / address / data-in selected by cle/ale)
  task automatic h_wr(input logic [7:0] d, input logic c, input logic a);
    begin
      @(negedge clk); ce_n = 0; cle = c; ale = a;
                      host_oe = 1; host_dq = d; we_n = 1;
      repeat (2) @(negedge clk); we_n = 0;          // setup
      repeat (4) @(negedge clk); we_n = 1;          // hold, latch on rise
      repeat (4) @(negedge clk);                    // keep dq stable for sync
      cle = 0; ale = 0; host_oe = 0;
    end
  endtask

  // one host read cycle (data out while re_n low)
  task automatic h_rd(output logic [7:0] d);
    begin
      @(negedge clk); ce_n = 0; cle = 0; ale = 0; host_oe = 0; re_n = 1;
      repeat (2) @(negedge clk); re_n = 0;
      repeat (4) @(negedge clk);                    // pad turnaround + sync
      d = dq;                                       // sample while re_n low
      @(negedge clk); re_n = 1;
      repeat (4) @(negedge clk);                    // let ptr advance
    end
  endtask

  // data pattern generator (8-bit truncation)
  function automatic logic [7:0] pat(input logic [7:0] s, input int i);
    return s + i * 8'h11;
  endfunction

  task automatic h_cmd(input logic [7:0] d);  h_wr(d, 1'b1, 1'b0); endtask
  task automatic h_addr(input logic [7:0] d); h_wr(d, 1'b0, 1'b1); endtask
  task automatic h_din(input logic [7:0] d);  h_wr(d, 1'b0, 1'b0); endtask

  // wait for a busy pulse and return its width in clk cycles
  task automatic busy_width(output int w);
    begin
      w = 0;
      while (rb_n !== 1'b0) @(posedge clk);         // wait for busy
      while (rb_n === 1'b0) begin @(posedge clk); w++; end
    end
  endtask

  task automatic nand_reset;
    begin
      rst_n = 0;
      ce_n = 1; cle = 0; ale = 0; we_n = 1; re_n = 1;
      host_oe = 0; host_dq = 0;
      repeat (5) @(negedge clk);
      rst_n = 1;
      repeat (3) @(negedge clk);
    end
  endtask

  task automatic read_id;
    logic [7:0] b;
    begin
      h_cmd(8'h90);
      h_addr(8'h00);
      for (int i = 0; i < 5; i++) begin
        h_rd(b);
        check(b === DEV_ID[39-8*i -: 8],
              $sformatf("Read ID byte %0d: got %02h", i, b));
      end
    end
  endtask

  task automatic read_status(output logic [7:0] s);
    begin
      h_cmd(8'h70);
      h_rd(s);
    end
  endtask

  task automatic page_program(input logic [3:0] page,
                              input logic [5:0] col,
                              input logic [7:0] seed,
                              input int n,
                              output int busy);
    begin
      h_cmd(8'h80);
      h_addr({2'b00, col});       // col cycle 0
      h_addr(8'h00);              // col cycle 1
      h_addr({4'b0000, page});    // row cycle 0
      h_addr(8'h00);              // row cycle 1
      h_addr(8'h00);              // row cycle 2
      for (int i = 0; i < n; i++) h_din(seed + 8'(i*8'h11));
      h_cmd(8'h10);
      busy_width(busy);
    end
  endtask

  task automatic page_read(input logic [3:0] page,
                           input logic [5:0] col,
                           input logic [7:0] seed,
                           input int n,
                           input logic [7:0] fill,
                           input logic use_fill,
                           output int busy);
    logic [7:0] b;
    begin
      h_cmd(8'h00);
      h_addr({2'b00, col});
      h_addr(8'h00);
      h_addr({4'b0000, page});
      h_addr(8'h00);
      h_addr(8'h00);
      h_cmd(8'h30);
      busy_width(busy);
      check(busy >= 20 && busy <= 30,
            $sformatf("read busy %0d clk (expected ~25)", busy));
      for (int i = 0; i < n; i++) begin
        h_rd(b);
        if (use_fill) check(b === fill,
              $sformatf("page %0d byte %0d: got %02h exp %02h", page, i, b, fill));
        else check(b === pat(seed, i),
              $sformatf("page %0d byte %0d: got %02h", page, i, b));
      end
    end
  endtask

  logic [7:0] st;
  int  bw;

  initial begin
    nand_reset;

    // -- check 1: reset state --------------------------------------
    check(rb_n === 1'b1, "reset: rb_n != 1");
    check(irq === 1'b0,  "reset: irq != 0");
    check(dq === 8'hFF,  "reset: dq not released (tri1 pull-up expected)");

    // -- check 2: Read ID -------------------------------------------
    read_id;
    check(irq === 1'b0, "irq set after Read ID");

    // -- check 3: program -> readback on 3 pages ---------------------
    page_program(4'd0, 6'd0, 8'h10, 64, bw);
    check(bw >= 195 && bw <= 210,
          $sformatf("program busy %0d clk (expected ~200)", bw));
    page_program(4'd1, 6'd0, 8'hA0, 64, bw);
    page_program(4'd5, 6'd4, 8'h55, 60, bw);        // partial page @col4
    read_status(st);
    check(st === 8'h40, $sformatf("status after good prog: %02h", st));

    page_read(4'd0, 6'd0, 8'h10, 64, 8'h00, 1'b0, bw);
    page_read(4'd1, 6'd0, 8'hA0, 64, 8'h00, 1'b0, bw);
    page_read(4'd5, 6'd4, 8'h55, 60, 8'h00, 1'b0, bw);
    check(irq === 1'b0, "irq set after prog/read");

    // -- check 4: erase block 0 -> pages 0..3 all FF ------------------
    h_cmd(8'h60);
    h_addr(8'h00);                                  // row = page 0
    h_addr(8'h00);
    h_addr(8'h00);
    h_cmd(8'hD0);
    busy_width(bw);
    check(bw >= 990 && bw <= 1010,
          $sformatf("erase busy %0d clk (expected ~1000)", bw));
    read_status(st);
    check(st === 8'h40, $sformatf("status after erase: %02h", st));
    page_read(4'd0, 6'd0, 8'h00, 64, 8'hFF, 1'b1, bw);
    page_read(4'd3, 6'd0, 8'h00, 64, 8'hFF, 1'b1, bw);

    // -- check 5: protected block program -> fail, array untouched ----
    page_program(4'd12, 6'd0, 8'h77, 64, bw);
    read_status(st);
    check(st === 8'h41,
          $sformatf("status after protected prog: %02h (exp 41)", st));
    page_read(4'd12, 6'd0, 8'h00, 64, 8'hFF, 1'b1, bw); // still erased

    // -- check 6: bad command sequence injection ----------------------
    h_cmd(8'h30);                                   // confirm w/o 0x00
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "0x30 in idle: irq not raised");
    h_cmd(8'hAB);                                   // unknown opcode
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "unknown cmd: irq not raised");
    h_cmd(8'hFF);                                   // reset clears irq
    busy_width(bw);
    check(irq === 1'b0, "irq not cleared by 0xFF reset");
    check(rb_n === 1'b1, "rb_n not ready after reset");
    read_id;                                        // target still alive
    check(irq === 1'b0, "irq set at end of test");

    if (errors == 0) $display("TEST PASSED: Toggle_Mode_NAND");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5000000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
