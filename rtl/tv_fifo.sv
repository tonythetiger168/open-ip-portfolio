// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv_fifo: small synchronous FIFO shared by the TV SoC IPs (show-ahead:
// rdata is the head word while !empty). A push while full or a pop while
// empty is ignored. clr empties it.
// ============================================================================
module tv_fifo #(
  parameter int W     = 32,
  parameter int DEPTH = 16                  // power of two
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         clr,
  input  logic         push,
  input  logic [W-1:0] wdata,
  input  logic         pop,
  output logic [W-1:0] rdata,
  output logic         empty,
  output logic         full,
  output logic [$clog2(DEPTH):0] count
);
  localparam int AW = $clog2(DEPTH);
  logic [W-1:0]  mem [DEPTH];
  logic [AW-1:0] wp, rp;
  wire do_push = push && !full;
  wire do_pop  = pop && !empty;
  assign empty = (count == 0);
  assign full  = (count == (AW+1)'(DEPTH));
  assign rdata = mem[rp];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp <= '0; rp <= '0; count <= '0;
    end else if (clr) begin
      wp <= '0; rp <= '0; count <= '0;
    end else begin
      if (do_push) wp <= wp + AW'(1);
      if (do_pop)  rp <= rp + AW'(1);
      count <= count + (AW+1)'(do_push) - (AW+1)'(do_pop);
    end
  end
  always_ff @(posedge clk) if (do_push && !clr) mem[wp] <= wdata;
endmodule
