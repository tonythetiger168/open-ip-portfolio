// ============================================================================
// pq_pkg.sv - 共用參數與資料格式定義
// 對應技術版圖報告「五層架構」:
//   L0 內容中繼資料層 / L1 OS合成層 / L2 SoC PQ引擎層 / L3 面板層 / L4 校正閉環層
// ----------------------------------------------------------------------------
// 資料格式約定:
//   pixel channel : 16-bit unsigned, Q0.16 正規化 [0, 1)  (0xFFFF = full scale)
//   nits          : 16-bit unsigned integer
//   tone slope    : 16-bit Q0.16 (0 .. ~1.0)
//   correction gain: 16-bit Q2.14 (0 .. ~4.0, 16384 = 1.0)
//   offset        : 16-bit Q0.16
// 資料流介面: valid-only (無 backpressure; 升級請加 ready/Credit)
// 每個模組的 sof 輸入與其 pixel 輸入同拍對齊, sof 輸出與其 pixel 輸出對齊。
// ============================================================================
package pq_pkg;

  // ---- 影像幾何 (本 functional demo 用小尺寸; 真實設計例化時改參數) ----
  parameter int P_H_ACTIVE = 32;                 // 每行像素
  parameter int P_V_ACTIVE = 16;                 // 每幀行數
  parameter int P_ZONES_X  = 4;                  // 水平分區數 (須整除 H_ACTIVE)
  parameter int P_ZONES_Y  = 2;                  // 垂直分區數 (須整除 V_ACTIVE)
  parameter int P_NZONES   = P_ZONES_X * P_ZONES_Y;
  parameter int P_LUT_N    = 17;                 // 3D LUT 每軸節點數
  parameter int P_LUT_SIZE = P_LUT_N**3;         // 4913 entries

  // ---- L0: metadata 封包格式 (128-bit, 與 pixel 流無關的獨立小封包) ----
  // [ 15:  0] fmt            : 0=SDR, 1=HDR10, 2=DolbyVision(L1+L2)
  // [ 31: 16] content_max_nits  (L1 max / MaxCLL 用途)
  // [ 47: 32] content_min_nits  (L1 min, x0.001 nits)
  // [ 63: 48] mastering_peak_nits
  // [ 79: 64] max_fall
  // [ 95: 80] trim_gain  Q2.14   (L2 artistic trim, 16384=1.0)
  // [111: 96] trim_offset Q0.16
  // [127:112] reserved
  parameter int P_META_W   = 128;
  localparam logic [15:0] META_FMT_SDR  = 16'd0;
  localparam logic [15:0] META_FMT_HDR10= 16'd1;
  localparam logic [15:0] META_FMT_DV   = 16'd2;

  // ---- L1: BT.2390 風格 piecewise tone mapping 預設 ----
  // 參考 ITU-R BT.2390 EETF: 線性段 + hermite spline; 本實作以
  // 「knee 以下恆等、knee 以上線性壓縮」的 2 段式近似 (knee 為可配參數)。
  parameter logic [15:0] P_KNEE_DEFAULT = 16'hC000;  // 75% code

  // ---- L2a: 3x3 高斯核 (和=16, >>4) ----
  //        1 2 1
  //        2 4 2
  //        1 2 1

  // ---- L4: 校正取樣數 ----
  parameter int P_CAL_SAMPLES = 64;

endpackage
