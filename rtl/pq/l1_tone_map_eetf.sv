// ============================================================================
// L1 OS/GPU 合成層: tone_map_eetf
// 對應版圖: Windows DXGI pre-composite tone mapping / BT.2390 EETF
// 功能: 對每通道做 2 段式 EETF (knee 以下恆等, knee 以上以 tone_slope 壓縮),
//       再套用 L0 給的 Dolby L2 artistic trim (gain/offset)。
// 公式 (per channel, Q0.16):
//   y  = x                , x <= knee
//   y  = knee + (x-knee)*slope , x >  knee
//   y' = clamp(y * trim_gain(Q2.14) >> 14 + trim_offset)
// 流水線: 4 級 / 通道  (s1 取差與旗標 -> s2 乘 slope -> s3 加 base
//                      -> s4 trim gain/offset + clamp)
// ============================================================================
module l1_tone_map_eetf
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic        in_sof,
  input  logic [47:0] in_pix,      // {r,g,b} Q0.16
  input  logic [15:0] tone_knee,
  input  logic [15:0] tone_slope,  // Q0.16
  input  logic [15:0] trim_gain,   // Q2.14
  input  logic [15:0] trim_offset, // Q0.16
  output logic        out_valid,
  output logic        out_sof,
  output logic [47:0] out_pix
);

  logic [3:0] vsh;
  logic [3:0] sofsh;

  // s1
  logic [15:0] t1   [0:2];
  logic        hi1  [0:2];
  logic [15:0] din1 [0:2];
  // s2
  logic [31:0] prod2[0:2];
  logic        hi2  [0:2];
  logic [15:0] din2 [0:2];
  // s3
  logic [15:0] y3   [0:2];

  genvar ch;
  generate
    for (ch = 0; ch < 3; ch++) begin : g_ch
      wire [15:0] x = in_pix[16*ch +: 16];

      // s1: 差值與區段旗標
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          t1[ch]  <= '0; hi1[ch] <= 1'b0; din1[ch] <= '0;
        end else if (in_valid) begin
          hi1[ch]  <= (x > tone_knee);
          t1[ch]   <= (x > tone_knee) ? (x - tone_knee) : x;
          din1[ch] <= x;
        end
      end

      // s2: 乘以 slope (Q0.16 * Q0.16 -> Q0.32)
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          prod2[ch] <= '0; hi2[ch] <= 1'b0; din2[ch] <= '0;
        end else if (vsh[0]) begin
          prod2[ch] <= t1[ch] * {16'd0, tone_slope};
          hi2[ch]   <= hi1[ch];
          din2[ch]  <= din1[ch];
        end
      end

      // s3: 加回 base (knee 或 0)
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) y3[ch] <= '0;
        else if (vsh[1])
          y3[ch] <= hi2[ch] ? (tone_knee + prod2[ch][31:16]) : din2[ch];
      end

      // s4: trim + clamp
      logic [31:0] tr;
      logic [17:0] sum4;
      always_comb begin
        tr   = (y3[ch] * {16'd0, trim_gain}) >> 14;
        sum4 = {2'b00, tr[15:0]} + {2'b00, trim_offset};
      end
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) out_pix[16*ch +: 16] <= '0;
        else if (vsh[2])
          out_pix[16*ch +: 16] <= (|sum4[17:16]) ? 16'hFFFF : sum4[15:0];
      end
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vsh   <= 4'b0;
      sofsh <= 4'b0;
    end else begin
      vsh   <= {vsh[2:0], in_valid};
      sofsh <= {sofsh[2:0], in_valid & in_sof};
    end
  end
  assign out_valid = vsh[3];
  assign out_sof   = sofsh[3];

endmodule
