# 平台工作進度 — bus／DMA／host

更新：2026-11-01 15:00–15:10 Asia/Taipei。分支：`codex/platform-bus-host-20261101`。本輪主變更 commit：`5244020dd4fb5c5ae74d46206a431d261f662c80`。

Draft PR：[open-ip-portfolio #22](https://github.com/tonythetiger168/open-ip-portfolio/pull/22)。配對交付：[open-vip-portfolio #15](https://github.com/tonythetiger168/open-vip-portfolio/pull/15)。未合併，不直接修改 main；GitHub寫入成功，無未推送的功能變更。

## 基線與來源

- 本repo main：`e6a39a36d131c916688735a9874dfafb30474203`；已讀最新recursive tree、CONTRIBUTING及既有TV/STB/IPCAM總計畫。tree未發現AGENTS/CLAUDE；使用者要求的codex分支優先於CONTRIBUTING示例分支名。
- 已讀OneDrive四份來源，SHA256與三表列號在 docs/design/platform_bus_host_matrix.md/json。9個相關IP對應27個表格列，另列DMA/fabric缺口；原表是候選能力，不是凍結需求。
- open-ip open PR #13含SPI CS-high tri-state修復，#19是PCIe/CXL IDE，#6/#7屬安全/顯示設計；不重複修改其路徑。open-vip讀取時沒有open PR。PR claim未算入本輪實測。

## 狀態

|項目|design|RTL|verified|physical|
|---|---|---|---|---|
|逐項bus/host矩陣、五種host契約|可審查提案，待consumer ACK|host未新增|host未驗|未做|
|雙window APB router|受限原型契約已寫明|open-ip新增隔離原型|16 directed checks；1 mutant偵測；lint通過，僅此範圍|generic synthesis完成；無cell PPA/STA/板測|
|AXI fabric／AXI→APB／stream adapter／DMA|需求與介面缺口已列；ORCA PR3仍proposed|本輪未實作|未做端到端RTL驗證|未做|
|host responder／獨立VIP擴充|角色與驗收契約已列|僅APB router bench新增，五host responder待做|既有suite未重跑|不適用／板測未做|

## 實際測試與證據

命令（Linux兩repo相鄰）：`python3 ipcheck/platform/run.py --ip-dir ../open-ip-portfolio --evidence-dir reports/platform`（在open-vip執行）。Icarus12.0／WSL Python3.14.4：16 checks通過、exit0；移除default-error-response的mutant使checker報錯並exit1，runner確認偵測成功。Yosys0.52 generic synth／check -assert exit0；Verilator5.032 lint exit0。原始logs、commands與RTL/bench SHA256在reports/platform。

未執行原有全repo回歸、五項coverage closure、formal、CDC/RDC、STA、PHY/板測；Verilator5.032低於repo coverage基準5.052。沒有實測線速/頻寬/cycles/PPA，16 checks不可延伸為完整AMBA或production驗收。

## 阻塞、下一步與ETA

1. 五host的SKU模式、pin電壓／線速、clock、PIO/DMA、driver、security policy需consumer決策；ETA未知。
2. APB router仍缺五項coverage／formal與clocked系統整合；下一步可加隨機APB manager/獨立target、reset/quiesce驗證。完整驗收ETA未知。
3. AXI fabric／DMA缺DDR最大服務間隔、QoS、IOMMU/cache/ownership簽認；不能把平均模型當deadline保證。ETA未知。
4. 下一個host需選一種落地，並同步加入反向responder及wire monitor；不任意修改他人現有core/ports。啟動實作與完成時間待排程，ETA未知。
5. 中央已授權每小時追蹤；本工作供中央讀此檔與PR head，有實質變更才更新。未另建重複排程、未自行傳訊其他聊天。

本檔記錄前一個可審查主變更commit；最新含進度記錄的提交以PR head為準，避免自引用SHA。
