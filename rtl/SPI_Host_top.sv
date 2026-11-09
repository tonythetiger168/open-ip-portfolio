// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SPI_Host: SPI controller (master), modes 0..3, 8-bit frames, MSB first
// ----------------------------------------------------------------------------
// The controller role that the SPI_top target does not cover (sensor,
// display panel, PMIC and NOR-flash control).
// - start (ignored while busy) sends TX_DATA and receives RX_DATA in one
//   8-bit frame; DONE pulses when it ends.
// - CPOL: SCLK idle level. CPHA 0: data changes on the trailing edge and is
//   sampled on the leading edge (the first bit is presented before the
//   first edge); CPHA 1: changes on the leading edge, sampled on the
//   trailing edge.
// - Half an SCLK period is DIV + 1 clocks. Targets that sample on their own
//   clock (as SPI_top does) need at least 3.
// - Chip select: csn[i] = !CS[i] (software keeps it asserted across frames
//   of one transaction); NCS selects.
// ============================================================================
module SPI_Host_top #(
  parameter int NCS = 2
) (
  input  logic           clk,
  input  logic           rst_n,
  // SPI pins
  output logic           sclk,
  output logic           mosi,
  input  logic           miso,
  output logic [NCS-1:0] csn,
  // control
  input  logic [15:0]    div,
  input  logic           cpol,
  input  logic           cpha,
  input  logic [NCS-1:0] cs,
  input  logic [7:0]     tx_data,
  input  logic           start,
  output logic [7:0]     rx_data,
  output logic           busy,
  output logic           done
);
  logic [15:0] cnt;
  logic [4:0]  edge_n;          // edges made in this frame (16 per frame)
  logic [7:0]  sh_o, sh_i;
  logic        cpol_q, cpha_q;

  assign csn = ~cs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk <= 1'b0; mosi <= 1'b0; cnt <= '0; edge_n <= '0; sh_o <= '0; sh_i <= '0;
      cpol_q <= 1'b0; cpha_q <= 1'b0; rx_data <= '0; busy <= 1'b0; done <= 1'b0;
    end else begin
      done <= 1'b0;
      if (!busy) begin
        sclk <= cpol;                              // idle level follows CPOL
        if (start) begin
          busy <= 1'b1; cnt <= div; edge_n <= '0; cpol_q <= cpol; cpha_q <= cpha;
          sh_o <= tx_data;
          if (!cpha) mosi <= tx_data[7];           // CPHA 0: first bit before the first edge
        end
      end else if (cnt != 16'd0) begin
        cnt <= cnt - 16'd1;
      end else begin
        cnt <= div;
        if (edge_n == 5'd16) begin                 // trailing half period done
          busy <= 1'b0; done <= 1'b1; rx_data <= sh_i;
        end else begin
          edge_n <= edge_n + 5'd1;
          sclk <= ~sclk;
          // edge_n even: leading edge, odd: trailing edge
          if (edge_n[0] == cpha_q) sh_i <= {sh_i[6:0], miso};        // sample
          else if (cpha_q) begin mosi <= sh_o[7]; sh_o <= {sh_o[6:0], 1'b0}; end
          else if (edge_n != 5'd15) begin mosi <= sh_o[6]; sh_o <= {sh_o[6:0], 1'b0}; end
        end
      end
    end
  end
  wire _unused = &{1'b0, cpol_q};
endmodule
