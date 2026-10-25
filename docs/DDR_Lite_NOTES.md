# DDR4_Lite — 給 open-ip-portfolio 的第一個「有代碼」的 DDR IP

## 背景

v2.5.1 的記憶體家族是 20 個 29-42 行 wrapper（DDR/DDR4-7、LPDDR4-7/5X、
GDDR5-7、HBM/HBM2-5/HBM3E）共用一個 144 行單 bank 教育模型 MEMCORE——
換言之**沒有任何一代 DDR 有自己的設計代碼**，「DDR5」「HBM3E」只有名字和
5 個時序參數不同。這個目錄提供一個結構上貨真價實的 DDR4-lite 控制器，
作為家族共用核心的升級候選（v2.6 可讓 20 個 wrapper 參數化到本核心，
或先作為獨立新條目加入）。

## 本核心有什麼（MEMCORE 沒有的）

| 特性 | MEMCORE (144 行) | DDR4_Lite (544 行) | 量產 DDR4 |
|---|---|---|---|
| bank 數 | 1（文件自承） | 4，獨立 open-row | 4/bank group ×2 |
| open-page 政策 | 無（單行暫存器） | per-bank hit/miss | ✓ |
| tRCD/tRP/tRC/tRAS/tRRD | 只有 tRCD/tRP 簡化計時 | 全部，per-bank + global | ✓ |
| tWR/tWTR | 無 | ✓ | ✓ |
| refresh | 無 | tREFI 平均間隔 + PREA/REF/tRFC + 超時 sticky irq | ✓ |
| mode register | 無 | MR0..MR7 檔案，MRW/MRR，MR0 CL / MR1 CWL 生效 | ✓ |
| PHY 命令腳位 | RAS/CAS/WE 簡化 | DDR4 ACT_n 編碼（ACT/RD/WR/PRE/PREA/REF/MRS） | ✓ |
| dq/dqs burst | 無（直讀陣列） | BL8×16 腳位級 burst + dqs | DDR 邊沿 |
| trace 埠 | ✓ | ✓ | n/a |

## 刻意簡化（教育切片定位，文件內已逐條揭露）

SDR 化 dqs（每 beat 一上升沿）、無 DLL/leveling/ZQ/DBI/ECC/bank group/
2T/CA parity、refresh 只在引擎 idle 時服務、陣列內建於模型內、
單命令引擎（一次一筆 transaction）。

## 檔案

- `DDR4_Lite_top.sv` — 核心（544 行，iverilog -g2012 相容語法子集）
- `DDR4_Lite_tb.sv` — 驗證：S1 單筆讀寫 / S2 4-bank 交錯 / S3 row conflict /
  S4 mode register / S5 隨機流量+refresh / S6 協定錯誤 irq；
  PHY 腳位級時序 monitor（tRP/tRCD/tRC/tRAS/tRRD/tRFC/PREA→REF）+
  refresh liveness + scoreboard
- `policy_model.py` — 引擎排程規則的 Python 週期級鏡像（已跑：4368 cycles、
  11 refreshes、0 時序違例）

## 驗證狀態（重要）

| 項目 | 狀態 |
|---|---|
| lint（begin/end、單驅動、宣告、可合成性、索引界） | ✅ 全綠 |
| Python 政策模型（排程規則隨機場景） | ✅ PASS |
| **iverilog 模擬** | ⏳ **未跑——本環境無 simulator，必須進 CI 才算數** |
| Verilator lint | ⏳ 未跑 |

進 repo 後請以既有 framework 方式加入（rtl/ + tb/ + Makefile），
第一個 CI run 之前不要標記為 PASS。

## 跑法

```
iverilog -g2012 -o ddr4_lite.vvp DDR4_Lite_top.sv DDR4_Lite_tb.sv
vvp ddr4_lite.vvp        # 期望最後一行 SIM_PASS
```

## 分協定家族（2026-09-28 新增，選項 B）

三個協定各自的 lite 核心，每個都有**貨真價實、可驗證的協定差異**，
不是改名殼：

| | LPDDR5X_Lite (515 行) | HBM3E_Lite (493 行) | GDDR7_Lite (526 行) |
|---|---|---|---|
| 核心特徵 | 8 bank、**WCK 寫時脈**（寫路徑 toggle）、**per-bank refresh**（PBREF 單 bank 更新、其餘 7 bank 保持 open）、**DVFS/FSP 雙頻點暫存器檔**（FSPW 切換即改 CL/CWL） | **8 pseudo-channel × 4 bank = 32 獨立 open-row 項**、位址 [21:19]=PC、**32 項輪轉 per-bank refresh**（每次 tREFI 刷一項）、無 DLL | **雙通道**（2ch×4bank）、**PAM3 訊號模式**（MR0[0]）：16 pins × 2-bit 三進位 symbol lane，nibble↔trit LUT 編解碼（v=9t0+3t1+t2，16/27 組合合法、其餘報錯）、BL6（96 trits=32 nibbles=128 bits）|
| 資料通路 | 陣列存資料位元 | 同左 | 陣列存資料位元（**物理正確**：PAM3 編碼在線上不在陣列）；寫路徑 encode→bus→decode 回存，讀路徑依當前模式 re-encode——**寫讀往返同時驗證編解碼兩個 LUT**，模式切換後舊資料仍正確 |
| 各自 TB 重點 | PBREF 隔離性（被刷 bank 資料存活、相鄰 bank hit 路徑）、FSP 切換 + MRR 驗證、WCK 活動計數 | 8 PC sweep、同 bank 不同 PC 獨立性、32 項輪轉 liveness、pc_act 覆蓋 8'hFF | PAM2/PAM3 往返、BL6 beat 計數監控、PAM2 時上層 lane 必須 Z、模式切回後舊資料一致性 |

PAM3 LUT 已窮舉驗證：16 值編解碼往返 ✓、11 個非法組合（27-16）正確判錯 ✓。

驗證狀態與 DDR4_Lite 相同：lint ✅、政策模型（DDR4 引擎已週期級驗證；
三個 fork 沿用同一骨架）✅、**iverilog 待 CI 跑** ⏳。
