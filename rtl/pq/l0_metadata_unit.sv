// ============================================================================
// L0 內容中繼資料層: metadata_unit
// 對應版圖: HDR10 static (ST2086/MaxCLL) 與 Dolby Vision L1/L2 動態中繼資料
// 功能: 解析 128-bit metadata 封包, 產生 L1/L2 層使用的 tone mapping 參數
//       - tone_slope (Q0.16) = display_peak / content_max (飽和 1.0)
//       - tone_knee  (Q0.16) knee 點 (BT.2390 風格, 可配)
//       - trim_gain/trim_offset (L2 artistic trim)
// 流水線: 3 級  (s1 鎖存封包 -> s2 計算 -> s3 輸出參數有效脈衝)
// ============================================================================
module l0_metadata_unit
(
  input  logic                     clk,
  input  logic                     rst_n,
  // metadata 封包
  input  logic                     meta_valid,
  input  logic [pq_pkg::P_META_W-1:0]      meta,
  // 顯示器能力 (config, 例: 300 nits)
  input  logic [15:0]              display_peak_nits,
  // 輸出參數
  output logic                     params_valid,
  output logic [15:0]              tone_knee,
  output logic [15:0]              tone_slope,   // Q0.16
  output logic [15:0]              trim_gain,    // Q2.14
  output logic [15:0]              trim_offset,  // Q0.16
  output logic [15:0]              content_max_nits
);

  // ---- s1: 鎖存封包 ----
  logic [15:0] fmt_r, cmax_r, cmin_r, mpeak_r, mfall_r, tgain_r, toff_r;
  logic        v1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v1 <= 1'b0;
      fmt_r <= '0; cmax_r <= '0; cmin_r <= '0;
      mpeak_r <= '0; mfall_r <= '0; tgain_r <= '0; toff_r <= '0;
    end else begin
      v1 <= meta_valid;
      if (meta_valid) begin
        fmt_r   <= meta[15:0];
        cmax_r  <= meta[31:16];
        cmin_r  <= meta[47:32];
        mpeak_r <= meta[63:48];
        mfall_r <= meta[79:64];
        tgain_r <= meta[95:80];
        toff_r  <= meta[111:96];
      end
    end
  end

  // ---- s2: 計算 tone slope ----
  // slope = min(1.0, display_peak/content_max) 以 Q0.16 表示
  // SDR 內容 (fmt=0): slope=1.0, trim neutral
  logic [15:0] slope_c, knee_c, tgain_c, toff_c, cmax_c;
  logic        v2;
  logic [31:0] slope_wide;
  always_comb begin
    slope_wide = '0;
    if (fmt_r == pq_pkg::META_FMT_SDR) begin
      slope_c  = 16'hFFFF;
      tgain_c  = 16'd16384;        // 1.0 in Q2.14
      toff_c   = 16'd0;
      cmax_c   = 16'd100;          // SDR 視為 100 nits
    end else begin
      slope_wide = (32'd65536 * {16'd0, display_peak_nits}) /
                   {16'd0, (cmax_r == 16'd0 ? 16'd1 : cmax_r)};
      slope_c  = (slope_wide >= 32'd65536) ? 16'hFFFF : slope_wide[15:0];
      tgain_c  = tgain_r;
      toff_c   = toff_r;
      cmax_c   = cmax_r;
    end
    knee_c = pq_pkg::P_KNEE_DEFAULT;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v2 <= 1'b0;
      tone_knee  <= '0;
      tone_slope <= '0;
      trim_gain  <= '0;
      trim_offset<= '0;
      content_max_nits <= '0;
    end else begin
      v2 <= v1;
      if (v1) begin
        tone_knee   <= knee_c;
        tone_slope  <= slope_c;
        trim_gain   <= tgain_c;
        trim_offset <= toff_c;
        content_max_nits <= cmax_c;
      end
    end
  end

  // ---- s3: 有效脈衝 ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) params_valid <= 1'b0;
    else        params_valid <= v2;
  end

endmodule
