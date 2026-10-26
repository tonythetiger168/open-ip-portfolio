# Crypto primitive 與 RoT 接口設計
日期：2026-10-26；design，RTL未新增／verified未成立／physical未執行。
基線 5480c40221b8c2a5e57c6228122fd1de8d3f9c3e。已讀 rtl/Crypto___Security_Engine_top.sv及docs/ip/Crypto___Security_Engine.md；此引擎SHA-256/HMAC接受0..64-byte訊息、4×128-bit message/key port、busy時寫入以irq告警。reset有清register邏輯，並不等同工作期間zeroize、key隔離、scan保護或secure boot。
## 產品化接口
保留既有 educational top 不改語意；新增wrapper／版本能力位前先審查。RoT合約由orca docs/design/security_aon_contract.md持有，本repo不接收acme專有RTL。
streaming SHA介面提案：INIT、UPDATE、FINAL、ABORT、ZEROIZE；8-bit byte valid／ready 或32-bit data+keep（僅末beat允許連續低位keep），64-bit總byte計數，重複FINAL／長度溢位拒絕。固定big-endian SHA word編碼，資料bus byte lane規則另以known-answer測試凍結；一次一context，無任意state讀回；不把逐塊重新start當成chaining。
HMAC長key先hash、短key補零，由wrapper處理；獨立RFC vectors需含0、55、56、63、64、65、127、128及長key。現有msg_len>64拒絕是功能邊界，不能作映像hash engine。
key manager→engine使用private sideload valid/ready、slot/use/epoch與key bits，僅授權安全域，無APB key讀回。PROD禁用一般key_we路徑；需要developer mode時由硬體lifecycle選擇，不能由任意CSR切換。AES mode／nonce管理／key size須逐項審計，不因catalog命名宣稱AEAD或DRM。
ZEROIZE搶占優先於start，清key、schedule、digest、中間state、FIFO、valid；完成握手前拒絕命令。reset/fatal失效所有slots；跨域使用受保護通道，掉電隔離。一般crypto加速與boot hash可共享datapath但必須互斥、清context、驗權，不能讓低權限客戶觀測boot state。
驗簽需要ECDSA-P256完整實作及ROM安全parser；現有SHA/HMAC不提供此能力。TRNG為外部實體macro，測試PRNG不能頂替。signature、OTP、antirollback、OTA不由此top自行成立。
## 驗證及效能
採獨立library與公開向量，不以同源gen_framework算法作golden；stream backpressure、padding邊界、busy衝突、ABORT／ZEROIZE每state、非法lifecycle、sideload reset均需測試，細項見同目錄security_aon_threat_matrix.md。
估算hash throughput = 64*f_clk/C_block（bytes/s）；64round只能界定compression工作，不含wrapper與padding、HMAC額外passes。C_block／fmax／area／power均未量測；無PPA或認證聲明。
交付依賴：protocol工作負責streaming/chaining wrapper與vectors；Security負責key policy及RoT；Integration負責APB/firewall／DFT／power。新CSR遵循總合約VERSION/CAP/W1C/error；physical base未指定。G1先凍結接口，G2再做reference/RTL/scoreboard，不擅自更改其他協定top。
