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
