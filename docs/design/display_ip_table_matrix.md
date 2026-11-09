# TV／STB／IPCAM 表格對照：Display

更新時間：2026-11-01 14:59（Asia/Taipei）。資料來源：共享 TV-IP-table.md／STB-IP-table.md／IPCAM-IP-table.md 及 IP-inventory.json（v0.2，2026-11-01）。共享表格為候選盤點，非凍結產品規格；本工作不覆寫共享表格。來源main：e6a39a36d131c916688735a9874dfafb30474203。遞迴tree未發現AGENTS.md／CLAUDE.md。性能／頻率／bit depth／延遲／產品PHY未凍結者為待定；不把README、教育slice或目標當量產證據。

| 表格項目 | current 現況 | required 要求 | gap 缺口 | update 本輪更新 | acceptance 驗收 | evidence 證據 |
|---|---|---|---|---|---|---|
| TV#21 HDMI | 固定640×480 TMDS internal-pattern TX、AVI/SPD、10 clocks/pixel邏輯serialization | TV外部HDMI RX；port數/mode/bpc/FRL需求待定 | TX demo不能填RX角色；RX PHY/clock recovery／EDID sink／audio／HDCP receiver未建立 | 明記TV RX獨立build/license/external decision，禁止用TX逆向命名替代 | 真實RX來源多mode／loss/relock／packet/EDID／protected routing；PHY/board／認證獨立 | rtl/HDMI_2_1_top.sv；docs/design/display_broadcast_integration.md |
| STB#21 HDMI | 同一TX教育slice；有APB4 wrapper，沒有external video ingress | STB TX external stream、可配置timing／audio／DDC master，mode待定 | FIFO/deadline、packet動態ECC、serializer／PLL／電氣／FRL缺；APB不是pixel transport | 沿用display FIFO／timed sink設計；定義低水位與mute/relock；不重做demo encoder | source→timing sink pattern oracle、underflow整行black、HPD bounce、malformed EDID timeout、audio drift、板級PHY | docs/ip/HDMI_2_1.md；Makefile.HDMI_2_1；原coverage只涵蓋demo |
| TV/STB#22 HDCP（與security交接） | HDCP_2_3_Content_Protection_top有TX message FSM／AES-CTR，但pairing用AES替代RSA-OAEP等簡化 | 合法授權、credentials／provisioning、正確crypto與HDMI角色／版本、安全key隔離 | 教育authentication不等於完整HDCP；TV RX與repeater角色未建立；certification未知 | 本文件僅display integration邊界，不覆寫security設計：不安全sink依policy mute，key只opaque handle | 獨立標準向量／負向auth／repeater topology／timeout／key lifecycle及licensed測試；不能同源TB互證完整規格 | rtl/HDCP_2_3_Content_Protection_top.sv註解明列KDF／pairing簡化；docs/ip/HDCP_2_3_Content_Protection.md |
| TV panel／STB broadcast（系統gap非已列完IP） | 現有總計畫有integration design，無完整panel/TCON／demod/TS/CAS宣告 | 依SKU選panel與broadcast標準，時序與audio契約待定 | PHY、panel power、STC/PCR/PTS、protected DMA／driver | 保留AON power handshake、channel-change flush、demux/security交接；不新增空殼controller | panel rail/backlight波形；TS loss/resync／PTS wrap、AV drift與domain隔離 | docs/design/display_broadcast_integration.md；共享表gaps |

IPCAM表沒有HDMI/HDCP分派，不自動要求camera產品整合。design：矩陣及整合。RTL：本輪未改HDMI/HDCP。verified：原per-IP coverage為repository-reported，本輪未重跑；不能外推PHY。physical：未做。ETA未知，需SKU／PHY採購與licensed testing決策。共享表固定df9d0ed7，本輪main已e6a39a36，證據以各自SHA註明，未覆寫其他protocol/security檔案。
