# Display：IP表格對照 checkpoint

時間：2026-11-01 14:59（Asia/Taipei）。branch：codex/display-design-2026-10-26。來源main：e6a39a36d131c916688735a9874dfafb30474203。本次提交SHA以本檔所屬commit為準，避免自引用。既有draft PR #7延續。

完成：新增docs/design/display_ip_table_matrix.md，逐一對應TV／STB／IPCAM表格項目，以current→required→gap→update→acceptance→evidence追蹤。共享表格不覆寫；規格／性能需求尚未凍結不擅自填入承諾。

| 階段 | 本輪狀態 |
|---|---|
| design | 表格矩陣、數值／lane／frame與memory介面缺口；沿用既有設計並澄清過時README／能力敘述 |
| RTL | 未修改；保留既有資產與他人PR，不宣稱全部IP實作完成 |
| verified | Python 3.14.8，執行PQ設計分支tools/display_adapter_reference.py，4 tests OK（4096碼×2policy、通道重排、alpha端點、非法輸入）；不是RTL／畫質驗證。既有RTL/QoR/coverage只列repository-reported，本輪未重跑 |
| physical | 未跑合成、STA、功耗或板測；沒有新PPA數字 |

阻塞：SKU rate/尺寸/precision／timebase／DMA worst latency、PQ來源授權確認與既有PR #1審查、PHY/panel/HDCP licensed integration。下一步：凍結跨repo adapter profile、保留原golden建立逐拍獨立oracle，再實作必要RTL與邊界回歸。ETA：未知，待上述合約與工具基線確認。

共享來源SHA256：TV 04f55cd29527e199920d004e8e3de4b9fd663ea5e6ac0d9506912b25c3944f1f；STB 6a341ec22bffc987f6a9ff883fd1f532c32f38c7d32d497b9ed6425d60351635；IPCAM 69ae106cafb9411f8a32201f8536206796a6def42ba45a6ae3a07dbd07867922；inventory 188e63e772c08f525c0604e23231afaedc3f826bf081af56b2ae128c9b856093。
中央每小時讀取本檔；本工作未新增排程、不自行傳訊其他聊天、不自動合併。

## 先前checkpoint（歷史）

# 2026-11-01 跟進

時間：2026-11-01 05:08（Asia/Taipei，巡檢記錄時間）。核對main：df9d0ed755c80d40aa42c4de55d6fd163c105c90。本PR仍draft／open、未合併；巡檢時無review／conversation／inline comment。本輪保留main新資產，只更新本工作設計與進度。

- design：同步AXIS line/frame profile、CSR既有語意、film／LP／OBMC重用及HDMI能力邊界（各repo詳見設計文件）。
- RTL：本輪未修改RTL；上游新增RTL只按來源盤點，不冒稱本輪完成。
- verified：總repo新增Python reference，實跑5 tests／OK、64組rate各1000點＋24h closed-form端點；不是硬體驗證。RTL／QoR未重跑。
- physical：未執行合成／STA／功耗或板測。
- 待決：G1 byte packing／frame SOF／timebase／epoch owner、DEI新增讀鏈cache與worst DDR latency、PHY/panel/broadcast及HDCP/CAS。
- 下一步：先凍結line→frame adapter profile及CSR版本，再獨立scoreboard／RTL原型；保留既有golden及所有上游資產。不自動合併、不付費。

以下保留10-26歷史進度，不代表最新main仍停留在舊成熟度。

# Display 設計工作進度

日期：2026-10-26（Asia/Taipei）。來源main：5480c40221b8c2a5e57c6228122fd1de8d3f9c3e。本工作獨立分支：codex/display-design-2026-10-26；以draft PR審查，不改main、不自動合併。

## 完成與成熟度
- docs/design/display_broadcast_integration.md：design，待審查。
- docs/design/display_maturity.csv：design，待審查。
- 既有RTL／verified僅引用既有報告，不代表本輪重跑；physical未執行。
- 已讀總計畫與本repo改善計畫、相關源碼／報告；tree未發現AGENTS.md／CLAUDE.md。盤點時open PR為空。

## 本輪檢查
- 靜態核對：成熟度、來源SHA、介面／CSR、clock/reset/power、估算假設、abort/recovery、安全、依賴與驗證矩陣。
- 設計數學以整數重新計算active pixel rate／DDR payload／storage，未執行RTL模擬、合成、STA、QoR或板測；不新增測試PASS或PPA結果。
- 原golden／QoR工具保持，下一階段先重現與增量測試，不重建既有工具。

## 待驗收／阻塞／下一步
G1平台stream packing/timebase／descriptor／CSR epoch待跨domain凍結；DMA worst latency與QoS未提供；PHY／panel／broadcast SKU、HDCP/CAS產品決策未完成。先審查本設計，再進reference／wrapper／RTL與獨立scoreboard，不以文件完成代表硬體完成。

提交SHA以承載本檔的Git commit為準（避免自引用SHA）；draft PR及後續commit可由分支查閱。本檔為display獨立進度，未覆寫共用進度檔。
