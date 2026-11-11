# Security／AON 領域進度
日期：2026-11-01（Asia/Taipei）。供中央每小時讀取；不另建重複排程。
分支：codex/security-aon-design-20261026；draft PR：https://github.com/tonythetiger168/open-ip-portfolio/pull/6。
本輪parent commit：d91ff8e9d9e8569de2bffa5a5278d2c2f2d62943；本輪commit以PR head／git history精確識別，避免文件自引用hash。
最新main核對：e6a39a36d131c916688735a9874dfafb30474203；設計分支未混入他人RTL。
## 本輪交付
docs/design/security_ip_table_matrix.md：14列current→required→gap→update→acceptance→evidence，來源表v0.2、hash及產品項次均已記錄。
新增docs/verification/security_core_evidence_20261101.md；校正RoT已存在但只做OTP digest pinning，非完整signed OTA；HDCP明確教育slice。
## 階段與真實測試
- design：可審查提案，未跨consumer凍結。
- RTL：既有core存在；本輪沒有改RTL，沒有宣稱新AON／RoT產品wrapper已實作。
- verified：固定main snapshot的RoT 52 boot cases、AES-GCM 758 cases、SHA3 692 cases實跑通過（SHA3保留readmemh warning）；HDCP host 60秒timeout/exit124，INCOMPLETE。詳細命令／限制見證據文件。 文件對照列數檢查：acme=3、8051=3、portfolio=14，共20列符合來源產品範圍。
- physical：PPA／STA／UPF／DFT／板級均NOT RUN。
## 阻塞、下一步與ETA
真實OTP/TRNG、簽章verifier與immutable ROM、quarantine/IV管理、HDCP授權IP/credentials與TV RX角色缺口；HDCP長測未完成。下一步分離digest demo與產品ROM，完善scoreboard並定位長測timeout。
ETA：未知（SKU性能／電源／授權與依賴未定），不給未驗證日期承諾。不自動合併、不付費、不公開專有內容。
