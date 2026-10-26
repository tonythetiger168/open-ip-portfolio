# Protocol IP 產品化改善計畫

日期：2026-10-26（Asia/Taipei）。狀態：設計立項，未宣稱 RTL、PPA 或量產驗收完成。
本計畫涵蓋 TV／STB／IPCAM 共用平台。實作前重讀最新 main、AGENTS.md／CLAUDE.md、相關 PR 與驗證報告；來源衝突以具體 RTL、較新報告及可重現結果判定。不得把 VIP、行為 PHY、命名或 coverage 百分比等同完整協定或產品成熟度。

## 成熟度規則
catalog、shared-core variant、VIP、behavioral PHY 與 production controller 分開記錄；每項建立 supported/unsupported/features/ports/license/evidence，統一README前後數量。
## 優先工作
CSI：保留packet ECC/CRC演算法，從單bit/clock模型改接真實PHY byte/lane介面；lane merge/RAW unpack/VC/FIFO/錯誤恢復。
Ethernet：現有MAC已有preamble/FCS/filter/PAUSE，不再稱為純echo；新增descriptor DMA、CDC/FIFO、MDIO/link、statistics、driver及外接PHY驗證。
HDMI：現有640x480 TMDS demo source；新增外部stream、可配置timing、serializer/PHY contract、DDC/EDID/CEC/audio/InfoFrame。FRL、RX、HDCP產品授權/金鑰獨立立項。
DDR/LPDDR：現有模型化memory與CA框架不能替代真實controller/PHY/training；設計DFI/AXI adapter，評估授權與FPGA controller，禁止冒稱JEDEC實體相容。
Crypto：現有AES/SHA/HMAC可重用，但SHA/HMAC訊息長度與key介面需審計；補streaming/chaining、zeroization、key isolation。RoT/secure boot由安全工作整合。
周邊：APB/AXI、I2C/UART/SPI/GPIO/PWM、SD/eMMC、I2S/USB依SKU精選，先修正協定完整性與driver，不擴充更多空殼命名。
交付 docs/design/media_protocol_productization.md 與每項成熟度CSV；驗證應使用獨立VIP/公開向量，不能同源互相證明。

## 共通交付與驗收
- 設計交付：block diagram、模組責任、介面／CSR、資料格式、clock/reset/power、吞吐／頻寬估算、錯誤／abort／recovery、安全邊界、依賴及驗證矩陣。
- 依序進行參考模型、RTL、獨立 scoreboard、CRV、SVA、coverage（保留 raw 數據與逐條 waiver）、適用控制形式驗證與 mutation、系統端到端測試。
- 效能以實測 cycles、配置與工具版本記錄；假設頻率與估算 PPA 必須標明，合成／STA／板級驗證未做不得宣稱完成。
- 每次更新 docs/PROGRESS_TV_STB_IPCAM.md：台北時間、commit、完成／待驗收／阻塞、測試命令與結果、下一步。無結果不得填 PASS。
- 設計工作使用 codex/ 分支與 draft PR；不自動合併，不新增付費服務。跨 repo 介面變更須列出所有 consumer 與相容性。
