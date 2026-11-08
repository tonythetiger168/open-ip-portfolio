// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Open picture-quality stages used by PQ_MEMC_top (written for this
// repository; see rtl/pq/README.md for the optional build against the
// private pq-pipeline-sv stages instead).
// - pq_meta_decode: 128-bit HDR metadata to tone-curve parameters
// - pq_eetf:        2-segment tone curve (knee / slope) and trim gain / offset
// - pq_blend:       frame blend prev * (256 - a) + cur * a >> 8
// Pixels are {R, G, B} with 16-bit channels in [0, 1) (Q0.16).
// ============================================================================

// Metadata layout (16-bit fields, field 0 at bits 15:0): 0 format (0 SDR,
// 1 HDR10, 2 Dolby Vision), 1 content peak nits, 2 content min, 3 mastering
// peak, 4 mastering average, 5 trim gain (Q2.14), 6 trim offset (Q0.16).
// SDR: neutral curve, content peak reported as 100. Otherwise slope =
// min(1, display peak / content peak) in Q0.16 (content peak 0 counts as 1).
// The knee is fixed at 0.75. Parameters update two clocks after LOAD, with a
// one-clock VALID pulse.
module pq_meta_decode (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         load,
  input  logic [127:0] meta,
  input  logic [15:0]  peak_nits,
  output logic         valid,
  output logic [15:0]  knee,
  output logic [15:0]  slope,
  output logic [15:0]  gain,
  output logic [15:0]  offset,
  output logic [15:0]  cmax
);
  logic [127:0] m;
  logic         ld1;
  logic [31:0]  ratio;
  wire  [15:0]  fmt  = m[15:0];
  wire  [15:0]  peak = (m[31:16] == 16'd0) ? 16'd1 : m[31:16];
  assign ratio = {peak_nits, 16'd0} / {16'd0, peak};
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m <= '0; ld1 <= 1'b0; valid <= 1'b0;
      knee <= '0; slope <= '0; gain <= '0; offset <= '0; cmax <= '0;
    end else begin
      ld1   <= load;
      valid <= ld1;
      if (load) m <= meta;
      if (ld1) begin
        knee <= 16'hC000;
        if (fmt == 16'd0) begin
          slope <= 16'hFFFF; gain <= 16'd16384; offset <= 16'd0; cmax <= 16'd100;
        end else begin
          slope  <= (ratio[31:16] != 16'd0) ? 16'hFFFF : ratio[15:0];
          gain   <= m[95:80];
          offset <= m[111:96];
          cmax   <= m[31:16];
        end
      end
    end
  end
endmodule

// y = x above the knee compressed: x <= knee ? x : knee + (x - knee) * slope,
// then out = min(1, y * gain + offset). Four clocks from IN_VALID to
// OUT_VALID; the parameters must be stable while pixels are in flight.
module pq_eetf (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic [47:0] in_pix,
  input  logic [15:0] knee,
  input  logic [15:0] slope,
  input  logic [15:0] gain,
  input  logic [15:0] offset,
  output logic        out_valid,
  output logic [47:0] out_pix
);
  logic [3:0]  v;
  logic [47:0] x1;
  logic [47:0] y2;
  logic [95:0] t3;                                   // y * gain per channel, 32 bits each
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v <= '0; x1 <= '0; y2 <= '0; t3 <= '0; out_pix <= '0;
    end else begin
      v <= {v[2:0], in_valid};
      x1 <= in_pix;
      for (int c = 0; c < 3; c++) begin
        logic [15:0] xc, yc;
        logic [31:0] p;
        logic [33:0] s;
        xc = x1[16*c +: 16];
        p  = {16'd0, xc - knee} * {16'd0, slope};
        yc = (xc > knee) ? knee + p[31:16] : xc;
        y2[16*c +: 16] <= yc;
        t3[32*c +: 32] <= {16'd0, y2[16*c +: 16]} * {16'd0, gain};
        s  = {2'b00, t3[32*c +: 32]} + {18'd0, offset, 14'd0};   // Q2.30
        out_pix[16*c +: 16] <= (s[33:30] != 4'd0) ? 16'hFFFF : s[29:14];
      end
    end
  end
  assign out_valid = v[3];
endmodule

// out = (prev * (256 - a) + cur * a) >> 8 per channel, one clock.
module pq_blend (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic [47:0] cur,
  input  logic [47:0] prev,
  input  logic [7:0]  a,
  output logic        out_valid,
  output logic [47:0] out_pix
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0; out_pix <= '0;
    end else begin
      out_valid <= in_valid;
      for (int c = 0; c < 3; c++) begin
        logic [24:0] s;
        s = {9'd0, prev[16*c +: 16]} * (25'd256 - {17'd0, a}) + {9'd0, cur[16*c +: 16]} * {17'd0, a};
        out_pix[16*c +: 16] <= s[23:8];
      end
    end
  end
endmodule
