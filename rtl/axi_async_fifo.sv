// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// axi_async_fifo: dual-clock FIFO with gray-code pointers
// ----------------------------------------------------------------------------
//  - Write side on w_clk, read side on r_clk, each with its own active-low
//    asynchronous reset (assert both together; a FIFO reset on one side
//    alone loses the pointer agreement).
//  - Binary pointers with one extra wrap bit; the gray copies cross through
//    two-flop synchronizers. Full when the write gray pointer equals the
//    synchronized read gray pointer with its two top bits inverted; empty
//    when the read gray pointer equals the synchronized write gray pointer.
//  - DEPTH a power of two, at least 4. r_data is the head entry (valid when
//    r_valid). Valid / ready on both sides.
// ============================================================================
module axi_async_fifo #(
  parameter int W     = 8,
  parameter int DEPTH = 8
)(
  input  logic         w_clk,
  input  logic         w_rst_n,
  input  logic         w_valid,
  output logic         w_ready,
  input  logic [W-1:0] w_data,
  input  logic         r_clk,
  input  logic         r_rst_n,
  output logic         r_valid,
  input  logic         r_ready,
  output logic [W-1:0] r_data
);
  localparam int AB = $clog2(DEPTH);
  if (DEPTH < 4 || (1 << AB) != DEPTH) begin : g_bad_depth
    $error("axi_async_fifo: DEPTH %0d must be a power of two, at least 4", DEPTH);
  end
  logic [W-1:0] mem [DEPTH];
  logic [AB:0]  wb, wg, rb, rg;                 // binary / gray pointers
  logic [AB:0]  wg_r1, wg_r2, rg_w1, rg_w2;     // synchronized gray
  function automatic logic [AB:0] b2g(input logic [AB:0] b);
    b2g = b ^ (b >> 1);
  endfunction

  assign w_ready = wg != {~rg_w2[AB:AB-1], rg_w2[AB-2:0]};
  assign r_valid = rg != wg_r2;
  assign r_data  = mem[rb[AB-1:0]];

  always_ff @(posedge w_clk or negedge w_rst_n) begin
    if (!w_rst_n) begin
      wb <= '0; wg <= '0; rg_w1 <= '0; rg_w2 <= '0;
    end else begin
      rg_w1 <= rg; rg_w2 <= rg_w1;
      if (w_valid && w_ready) begin
        mem[wb[AB-1:0]] <= w_data;
        wb <= wb + 1'b1;
        wg <= b2g(wb + 1'b1);
      end
    end
  end
  always_ff @(posedge r_clk or negedge r_rst_n) begin
    if (!r_rst_n) begin
      rb <= '0; rg <= '0; wg_r1 <= '0; wg_r2 <= '0;
    end else begin
      wg_r1 <= wg; wg_r2 <= wg_r1;
      if (r_valid && r_ready) begin
        rb <= rb + 1'b1;
        rg <= b2g(rb + 1'b1);
      end
    end
  end
endmodule
