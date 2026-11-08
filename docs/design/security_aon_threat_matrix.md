# 安全／AON 威脅與驗證矩陣
日期：2026-10-26。S01–S16狀態為 design／NOT RUN；S17僅host-model政策範例已測，其餘NOT RUN；沒有 RTL／verified／physical 完成證據。矩陣是驗收規格，不是測試結果。合約見 security_aon_contract.md（acme／portfolio 請見總 repo 同名文件）。

|ID|資產／攻擊|控制與判準|獨立證據／負例|層級／責任|
|---|---|---|---|---|
|S01|flash image被改／偽造 signer|ROM 只 release 合法簽章且 digest吻合映像|獨立 crypto library known-answer；每 byte flip、錯 key、r/s=0/out-of-range、非法公鑰|model/firmware；Security|
|S02|manifest parser越界|拒 schema、flags、長度、尾端／加總溢位；無 memory副作用|host fuzz＋ASan，0/255/256/320、最大 u64、重疊 region；mutation刪bounds check應被捕獲|model/ROM；Security|
|S03|TOCTOU／DMA覆寫已驗證code|驗證後目的區RX且全路徑不可寫|每 master在hash/lock/jump邊界寫入；assert release=>auth && policy_locked；CPU cache旁路檢查|RTL/SVA/system；Integration|
|S04|downgrade／key撤銷|所有 component >= OTP floor； revoked key永不啟動|低/等/高版本、跨component混裝、撤銷後reset／recovery|model/ROM；Security|
|S05|OTA撕裂／掉電變磚|永遠存在>=floor的signed recovery或fail closed|每 flash page、metadata byte、OTP bit programming邊界切電；重啟多次及journal序號邊界|model/board；Security/storage|
|S06|秘密經APB/debug/scan讀出|key只有sideload；讀回零／denied|每 lifecycle×master×port；scan netlist taint／門級觀察；reset中斷zeroize|RTL/formal/physical；Security/DFT|
|S07|entropy stuck／偏置|health alarm後不輸出秘密／nonce；狀態清除|stuck0/1、週期源、startup timeout、失效後重啟；實體entropy原始樣本分析|RTL/macro/board；TRNG owner|
|S08|AXI burst跨域／identity偽造|整burst拒絕、target零副作用、response正確|地址wrap/4KiB邊界、各len/size/strobe/ID、AW/W交錯、AxPROT偽造、coherent bypass|CRV/scoreboard/SVA；Platform|
|S09|policy更新時競爭|quiesce+drain後原子切換；warm reset不清lock|update與AR/AW/W/B/R、timeout同拍；形式驗證outstanding非零不commit|formal/RTL；Security|
|S10|frame descriptor換包／privacy外流|snapshot+buffer ownership+擴展精度bounds|修改ring/plane/stride/domain、abort後重用、cache stale、poisoned frame；禁止未遮罩資料流出|system；Camera/Platform/Codec|
|S11|ICP被入侵提升權限|ICP只sensor/3A資產；無OTP/key/policy/主域release權|所有 denied address scan、mailbox pointer／opcode/replay fuzz；CPU privilege fault注入|RTL/firmware；AON|
|S12|mailbox reset replay／偽deadline|epoch/seq有效且回覆一次，跨reset失效|seq wrap、queue full、AON/主域不同reset、長度64以外、deadline過期|model/CDC/system；AON|
|S13|sleep中遺失寫入／wake遺失|drain前不關電；sticky event保存|每state插wake/busy/reset、pwr_ack stuck、PLL不lock；timeout安全隔離；有界進展假設明列|RTL/SVA/power-aware；PMU|
|S14|retention污染／brownout|完整性異常cold boot；不恢復key|retained bit flip、reset因果交叉、供電斜率/跌落實測|power-aware/board；PMU|
|S15|scan/debug lifecycle繞過|PROD closed；RMA先zeroize；test退出POR|非法OTP decode、X propagation、scan enable glitch／warm reset；netlist不可觀測key|formal/gate/physical；DFT|
|S16|fault skip驗簽／side-channel|release條件不可被單一軟體旗標跳過；評估殘留風險|控制FSM非法態、done/error同拍mutation；電壓/clock glitch與洩漏實驗另立scope|RTL/physical；Security|

|S17|GCM未驗證明文／tag替換／舊completion|可信wrapper固定完整tag、snapshot；明文quarantine，auth成功且epoch/seq/length吻合才release|host release模型8 tests通過；AES/GHASH、RTL、NoC/cache旁路及實體清除NOT RUN；見設計文件2026-11-01增補|design/host-model；Security/Platform/Crypto|

## 驗證順序與證據格式
1. 先建立可執行 manifest／OTA／policy reference；簽章結果來自獨立已知實作，不能抄 RTL中間值作 golden。
2. RTL 後接獨立 AXI monitor／scoreboard、CRV（記 seed）、SVA安全與有界活性；formal 假設包含slave response公平性，不能假設所有請求合法。每個assert至少有觸發cover，防 vacuity。
3. mutation 至少移除 auth、bounds、floor、lock、drain、zeroize gate，各負例必須失敗；未殺 mutation逐項waiver。
4. coverage 報 raw line/branch/FSM/assert／cross bins（master×region×R/W/X×power×lifecycle）；每 waiver列原因、owner和殘餘風險，不能以100%代表安全。
5. 系統端到端：ROM→AON→主CPU→DMA→OTA→斷電→recovery；板級／實體 entropy／UPF／STA／DFT另附工具版本與配置。

每份報告必含 source SHA、tool/version、command、seed、configuration、expected/actual、log hash／artifact位置、日期及waiver。design 轉 RTL需有實作差異；RTL轉verified需相應可重現測試；verified轉physical需實體流程／板級證據。2026-11-01新增S17 host模型政策測試；S01–S16以及全部RTL／crypto／system／physical驗證仍未執行。
