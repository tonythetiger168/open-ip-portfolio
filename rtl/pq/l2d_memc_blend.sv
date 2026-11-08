// ============================================================================
// L2 SoC PQ 引擎層 - 子單元 D: memc_blend
// 對應版圖: MEMC 動態補償的「插值合成」功能單元
//   (運動估計 MV 產生為獨立 NPU/DSP 單元, 此處為接收 MV 後的
//    compensated frame blending 硬體)
// 功能: out = prev*(1-a) + cur*a , a = mv_frac/256 (per-pixel 相位)
// 流水線: 1 級
// ============================================================================
module l2d_memc_blend
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic        in_sof,
  input  logic [47:0] in_cur,     // 本幀 (經 LUT3D)
  input  logic [47:0] in_prev,    // 前幀 (外部 frame buffer 讀回)
  input  logic [7:0]  in_mvfrac,  // 0..255
  output logic        out_valid,
  output logic        out_sof,
  output logic [47:0] out_pix
);

  genvar ch;
  generate
    for (ch = 0; ch < 3; ch++) begin : g_b
      wire [15:0] c = in_cur [16*ch +: 16];
      wire [15:0] p = in_prev[16*ch +: 16];
      wire [31:0] mix = p * (16'd256 - {8'd0, in_mvfrac})
                      + c * {8'd0, in_mvfrac};
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) out_pix[16*ch +: 16] <= '0;
        else if (in_valid) out_pix[16*ch +: 16] <= mix[23:8];
      end
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_sof   <= 1'b0;
    end else begin
      out_valid <= in_valid;
      out_sof   <= in_valid & in_sof;
    end
  end

endmodule
