// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for TileLink__TL_UL_TL_C__top (TL-UL slave)
// TB acts as a TileLink master model: PutFull/PutPartial/Get, source echo
// checks, mask merge, d_ready backpressure hold, illegal opcode/size/mask/
// alignment/range error injection (d_error + irq), back-to-back requests.
// ============================================================================
`timescale 1ns/1ps
module TileLink__TL_UL_TL_C__tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  logic          a_valid, a_ready;
  logic [2:0]    a_opcode, a_param, a_size;
  logic [7:0]    a_source;
  logic [AW-1:0] a_address;
  logic [3:0]    a_mask;
  logic [DW-1:0] a_data;
  logic          d_valid, d_ready;
  logic [2:0]    d_opcode, d_size;
  logic [7:0]    d_source;
  logic [DW-1:0] d_data;
  logic          d_error, irq;

  int errors = 0;

  TileLink__TL_UL_TL_C__top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .a_valid(a_valid), .a_ready(a_ready), .a_opcode(a_opcode),
    .a_param(a_param), .a_size(a_size), .a_source(a_source),
    .a_address(a_address), .a_mask(a_mask), .a_data(a_data),
    .d_valid(d_valid), .d_ready(d_ready), .d_opcode(d_opcode),
    .d_size(d_size), .d_source(d_source), .d_data(d_data),
    .d_error(d_error), .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // passive response recorder (used by the pipelined back-to-back test)
  // ------------------------------------------------------------------
  logic [2:0]  r_op  [0:255];
  logic [7:0]  r_src [0:255];
  logic        r_err [0:255];
  logic [31:0] r_dat [0:255];
  int rn = 0;
  always @(posedge clk) begin
    if (d_valid && d_ready) begin
      r_op[rn]  = d_opcode;
      r_src[rn] = d_source;
      r_err[rn] = d_error;
      r_dat[rn] = d_data;
      rn++;
    end
  end

  // ------------------------------------------------------------------
  // master-model helpers
  // ------------------------------------------------------------------
  task automatic tl_idle;
    begin
      @(negedge clk);
      a_valid <= 1'b0;
    end
  endtask

  // issue one A beat (held until a_ready), then wait for the D response.
  // Checks d_opcode/d_size/d_source/d_error; read data compared when !exp_err.
  task automatic tl_xact(input logic [2:0] op, input logic [31:0] addr,
                         input logic [31:0] data, input logic [3:0] mask,
                         input logic [2:0] size, input logic [7:0] src,
                         input logic        exp_err,
                         input logic [31:0] exp_data);
    int to;
    begin
      @(negedge clk);
      a_valid  <= 1'b1;
      a_opcode <= op; a_param <= 3'd0; a_size <= size; a_source <= src;
      a_address <= addr; a_mask <= mask; a_data <= data;
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (a_ready) to = 100; else to++;
      end
      if (to != 100) begin errors++; $display("ERROR: a_ready timeout op=%0d @%h", op, addr); end
      tl_idle();
      // wait for D response
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (d_valid) to = 100; else to++;
      end
      if (to != 100) begin
        errors++; $display("ERROR: d_valid timeout op=%0d @%h", op, addr);
      end else begin
        if (d_error !== exp_err) begin
          errors++; $display("ERROR: d_error=%b exp %b op=%0d @%h", d_error, exp_err, op, addr);
        end
        if (d_source !== src) begin
          errors++; $display("ERROR: source echo exp %h got %h", src, d_source);
        end
        if (d_size !== size) begin
          errors++; $display("ERROR: size echo exp %0d got %0d", size, d_size);
        end
        if (!exp_err) begin
          if (op == 3'd4) begin
            if (d_opcode !== 3'd1) begin
              errors++; $display("ERROR: Get d_opcode exp AccessAckData got %0d", d_opcode);
            end
            if (d_data !== exp_data) begin
              errors++; $display("ERROR: Get data @%h exp %h got %h", addr, exp_data, d_data);
            end
          end else begin
            if (d_opcode !== 3'd0) begin
              errors++; $display("ERROR: Put d_opcode exp AccessAck got %0d", d_opcode);
            end
          end
        end
      end
      // response consumed (d_ready=1); settle
      @(posedge clk);
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [31:0] held_data;
  int to;

  initial begin
    a_valid = 0; a_opcode = 0; a_param = 0; a_size = 3'd2; a_source = 0;
    a_address = 0; a_mask = 4'hF; a_data = 0; d_ready = 1;
    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // CHECK 1: reset / idle state
    if (d_valid !== 1'b0 || irq !== 1'b0) begin
      errors++; $display("ERROR: bad reset state d_valid=%b irq=%b", d_valid, irq);
    end
    if (a_ready !== 1'b1) begin
      errors++; $display("ERROR: a_ready must be high when idle");
    end

    // CHECK 2: PutFull + Get data path, distinct source ids
    tl_xact(3'd0, 32'h0000_0010, 32'hDEAD_BEEF, 4'hF, 3'd2, 8'h11, 1'b0, 32'h0);
    tl_xact(3'd4, 32'h0000_0010, 32'h0,        4'hF, 3'd2, 8'h22, 1'b0, 32'hDEAD_BEEF);
    tl_xact(3'd0, 32'h0000_0014, 32'h1234_5678, 4'hF, 3'd2, 8'h33, 1'b0, 32'h0);
    tl_xact(3'd4, 32'h0000_0014, 32'h0,        4'hF, 3'd2, 8'h44, 1'b0, 32'h1234_5678);

    // CHECK 3: PutPartial mask merge
    tl_xact(3'd0, 32'h0000_0020, 32'hAABB_CCDD, 4'hF,    3'd2, 8'h01, 1'b0, 32'h0);
    tl_xact(3'd1, 32'h0000_0020, 32'h0000_1234, 4'b0011, 3'd2, 8'h02, 1'b0, 32'h0);
    tl_xact(3'd4, 32'h0000_0020, 32'h0,         4'hF,    3'd2, 8'h03, 1'b0, 32'hAABB_1234);

    // CHECK 4: d_ready backpressure -- d_valid & payload must hold
    @(negedge clk);
    a_valid <= 1'b1; a_opcode <= 3'd4; a_size <= 3'd2; a_source <= 8'h55;
    a_address <= 32'h0000_0010; a_mask <= 4'hF; a_data <= 32'h0;
    d_ready <= 1'b0;
    to = 0;
    while (to < 50) begin
      @(posedge clk);
      if (a_ready) to = 100; else to++;
    end
    tl_idle();
    to = 0;
    while (to < 50) begin
      @(posedge clk);
      if (d_valid) to = 100; else to++;
    end
    if (to != 100) begin errors++; $display("ERROR: d_valid timeout (backpressure test)"); end
    held_data = d_data;
    if (d_data !== 32'hDEAD_BEEF) begin
      errors++; $display("ERROR: backpressure data exp DEAD_BEEF got %h", d_data);
    end
    repeat (4) begin
      @(posedge clk);
      if (!d_valid) begin errors++; $display("ERROR: d_valid dropped under backpressure"); end
      if (d_data !== held_data) begin
        errors++; $display("ERROR: d_data changed while d_ready low");
      end
    end
    @(negedge clk);
    d_ready <= 1'b1;
    @(posedge clk); @(posedge clk);

    // CHECK 5: error injection -- illegal opcode (2=Intent reserved)
    tl_xact(3'd2, 32'h0000_0010, 32'h0, 4'hF, 3'd2, 8'h66, 1'b1, 32'h0);
    // illegal size (3 = 8B > bus width)
    tl_xact(3'd4, 32'h0000_0010, 32'h0, 4'hF, 3'd3, 8'h67, 1'b1, 32'h0);
    // misaligned address
    tl_xact(3'd4, 32'h0000_0012, 32'h0, 4'hF, 3'd2, 8'h68, 1'b1, 32'h0);
    // Get with non-full mask (mask/size inconsistency)
    tl_xact(3'd4, 32'h0000_0010, 32'h0, 4'h3, 3'd2, 8'h69, 1'b1, 32'h0);
    // PutPartial with zero mask
    tl_xact(3'd1, 32'h0000_0010, 32'h0, 4'h0, 3'd2, 8'h6A, 1'b1, 32'h0);
    // out-of-range address (>= 0x100)
    tl_xact(3'd4, 32'h0000_0100, 32'h0, 4'hF, 3'd2, 8'h6B, 1'b1, 32'h0);
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not set after illegal requests");
    end

    // CHECK 6: errors must not corrupt the regfile
    tl_xact(3'd4, 32'h0000_0010, 32'h0, 4'hF, 3'd2, 8'h70, 1'b0, 32'hDEAD_BEEF);
    tl_xact(3'd4, 32'h0000_0020, 32'h0, 4'hF, 3'd2, 8'h71, 1'b0, 32'hAABB_1234);

    // CHECK 7: pipelined back-to-back requests -- a_valid held across beats,
    // payload swapped every accepted cycle (1 request + 1 response per clk)
    begin
      int i, base;
      base = rn;
      for (i = 0; i < 4; i++) begin
        @(negedge clk);
        a_valid <= 1'b1; a_opcode <= 3'd0; a_size <= 3'd2;
        a_source <= 8'h80 + i[7:0];
        a_address <= 32'h0000_0040 + i[31:0]*4;
        a_mask <= 4'hF; a_data <= 32'h9000_0000 + i[31:0];
        to = 0;
        while (to < 50) begin
          @(posedge clk);
          if (a_ready) to = 100; else to++;
        end
        if (to != 100) begin errors++; $display("ERROR: b2b a_ready timeout %0d", i); end
      end
      tl_idle();
      // wait for all 4 in-order responses (recorded concurrently)
      to = 0;
      while (rn < base + 4 && to < 100) begin @(posedge clk); to++; end
      if (rn < base + 4) begin
        errors++; $display("ERROR: b2b got %0d/4 responses", rn - base);
      end else begin
        for (i = 0; i < 4; i++) begin
          if (r_err[base+i] || r_op[base+i] !== 3'd0 ||
              r_src[base+i] !== (8'h80 + i[7:0])) begin
            errors++; $display("ERROR: b2b resp %0d err=%b op=%0d src=%h",
                               i, r_err[base+i], r_op[base+i], r_src[base+i]);
          end
        end
      end
      repeat (2) @(posedge clk);
      // verify back-to-back writes landed
      tl_xact(3'd4, 32'h0000_0040, 32'h0, 4'hF, 3'd2, 8'h90, 1'b0, 32'h9000_0000);
      tl_xact(3'd4, 32'h0000_004C, 32'h0, 4'hF, 3'd2, 8'h91, 1'b0, 32'h9000_0003);
    end

    repeat (2) @(posedge clk);
    if (errors == 0) $display("TEST PASSED: TileLink__TL_UL_TL_C_");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // TIMEOUT guard
  initial begin
    #300000;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end

endmodule
