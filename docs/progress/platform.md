# 平台工作進度 — bus／DMA／host／shared UVM

## 2026-11-01 15:17 Asia/Taipei：SoC 整合用 fixture 與 coverage 計畫

主變更 commit：`22ab912f703a48c93b454b1548bd7d93839e5911`。分支 `codex/platform-bus-host-20261101`；沿用 [open-ip #22](https://github.com/tonythetiger168/open-ip-portfolio/pull/22)／[open-vip #15](https://github.com/tonythetiger168/open-vip-portfolio/pull/15)，draft、未合併。遠端7份RTL／bench／runner／policy source blob已核對與實測pins一致。

本輪未寫中央verification/，未取代integration的產品top/filelist責任。open-ip的integration/platform/baseline.json、slice.f與docs/design/platform_slice_baseline.md提供有界hierarchy/source pins、clock/reset/address/IRQ/adapter契約及缺dependency。paired VIP的docs/design/platform_shared_uvm_plan.md提供bus/memory/RAL/virtual seq、獨立scoreboard、reset/drain/QoS/ownership與adapter的共同UVM計畫。

|項目|design|RTL／實作|verified|physical|
|---|---|---|---|---|
|APB bounded fixture|content-pinned v0.1，非產品SoC|router＋full-word adapter＋兩個既有APB_top，無stub|Icarus elaboration、9 seed-runs、replay／negative mutation及lint通過，僅此scope|新增slice未合成／STA／板測|
|完整TV/STB/IPCAM SoC|待integration提供real top/fingerprint|CPU/AXI bridge/fabric/DMA/stream/frame/QoS未在此整合|BLOCKED，不能用fixture labels代替SoC gate|未做|
|shared UVM env/RAL/vseq|需求追溯與campaign/oracle合約可審查|本輪未落地可驗收UVM env，只有procedural seeded harness|UVM elaboration/regression BLOCKED|不適用|
|六類100% closure|逐產品/config/scope的目標，raw/核准排除/effective分列|新增export政策檢查器，未提供tool DB exporter/parser|12個synthetic policy tests通過；六類rawDB均未產出，OPEN/BLOCKED|不適用|

實跑：`python3 ipcheck/platform/run_slice.py --ip-dir ../open-ip-portfolio --evidence-dir reports/platform_slice`。Icarus12.0，TV/STB/IPCAM只是相同fixture的三個labels；seeds1/7/42每run209 transactions、739/741/739 checks，9 runs共1881 transactions。TV seed7 replay完全相同；移除partial-write拒絕的mutant被response及memory golden抓到。原APB_top blob 5b55a2c...與上游一致，沒有修改；3個RTL及bench/runner/policy、filelist有hash gate。Verilator5.032 fixture lint exit0。初次runner的800 check門檻誤設已修成每transaction至少3個必要檢查後重跑，只有最終結果列PASS。

`python -m unittest discover -s ipcheck/platform/coverage -p test_check_export.py -v`：Windows Python3.14.8，12 tests通過。synthetic all-hit只驗政策，不能列產品coverage。raw sim logs、seeds/replay/mutation、source/tool/command與coverage_status.json在paired VIP reports/platform_slice/；本repo保留核心結果副本。

六類規則：line、FSM states+arcs、toggle雙向、branch、SVA、functional逐產品/config/scope閉合；只同source/config/tool/instrumentation與point inventory可合併。SVA attempts/antecedent/nonvacuous pass/cover witness分列，assertion零失敗；功能bins合法且追溯需求。unsupported、缺RTL、未寫sequence不能waive成100%，沒有rawDB不報百分比。核准排除保留raw與effective分母，approval身份及DB來源仍需中央review/exporter核驗。

阻塞／下一步：integration提供真實產品top/filelist及缺IP解決狀態後，實作UVM agents/RAL predictor/vseq，再選可提供FSM arc/branch/SVA非vacuous等六類資料的工具，做directed/mutation→CRV→holes closure。目前沒有已配置可用UVM library、完整SoC/DMA/DDR服務界限或六類exporter；ETA未知。沒有UVM PASS、SoC PASS、coverage100%或PPA宣稱。未另建排程、未自行傳訊其他聊天、未付費／自動合併；中央可每小時讀本檔與PR head。

## 先前紀錄（15:04）


更新：2026-11-01 15:04 Asia/Taipei。分支：`codex/platform-bus-host-20261101`。本輪主變更 commit：`5244020dd4fb5c5ae74d46206a431d261f662c80`。

Draft PR：[open-ip-portfolio #22](https://github.com/tonythetiger168/open-ip-portfolio/pull/22)。配對交付：[open-vip-portfolio #15](https://github.com/tonythetiger168/open-vip-portfolio/pull/15)。遠端 compare 確認相對 main behind=0，diff 只有本工作新增路徑及 README 修正。未合併，不直接修改 main；GitHub寫入成功，無未推送的功能變更。

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
