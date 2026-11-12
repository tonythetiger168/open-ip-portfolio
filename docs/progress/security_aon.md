# Security／AON 工作進度
- 日期：2026-10-26（Asia/Taipei）
- 分支：codex/security-aon-design-20261026；base commit：5480c40221b8c2a5e57c6228122fd1de8d3f9c3e
- 完成：docs/design/security_crypto_contract.md、docs/design/security_aon_threat_matrix.md；另附16項威脅矩陣。
- 階段：design提案可審查；RTL未新增；verified未成立；physical未執行。
- 本提交SHA由本分支git history／PR head識別（避免文件自引用SHA）。
- 檢查：PowerShell檢查矩陣16個ID、manifest欄位合計256 bytes、mailbox欄位合計64 bytes；結果符合。此為文件格式檢查，非功能測試。RTL／簽章／formal／UPF／PPA均NOT RUN。
- 阻塞：OTP/TRNG macro與provisioning、verifier實作來源、CPU隔離、NoC identity、memory map、power sequencing／UPF／DFT尚待選型與consumer審查。
- 下一步：透過orca總合約PR完成G1審查，再建獨立reference及負例；不得由設計完成推論secure boot成立。
- 只更新本領域docs/progress/security_aon.md，依本工作指示避免共用進度檔衝突。未合併、未付費、未搬移專有RTL。

## 2026-11-01 後續檢查（design，未凍結）
三個安全PR（orca #5、acme #1、portfolio #6）讀取時仍open/draft、未合併且無conversation comments或reviews；這不是審查通過。
main基線：orca 3d66ab0c9b16a4a35907d7729cafe3abebec379a；acme 4d2f610dd34ecdf234c6a0760de7bfc0d11e83e6；portfolio df9d0ed755c80d40aa42c4de55d6fd163c105c90。recursive tree仍未找到AGENTS.md／CLAUDE.md。設計分支保留原基線，未將其他工作main的RTL混入本PR。
acme最新CSR blob仍為9f2674a30d0ddcd34ecf3ba2d7e6f2eebdeadcb2，沒有PMP CSR；README里程碑不能代表最新SIMD／CPU驗證。本輪未跑CPU測試。
portfolio新增AES_GCM_top（blob fa400bc8bc563cf2daaed6733011d4cd60408825），介面已有AES-128/256、sl_key/sl_valid、clr及tag_ok。不能再籠統稱「沒有sideload介面」；但介面本身沒有證明key manager、lifecycle、ROM驗簽或隔離成立。SHA/HMAC top仍限msg_len<=64，不能做完整映像streaming hash。
AES-GCM原始註解明確表示tag驗證前會輸出plaintext；tag_in在訊息結束時使用。整合必須如下：
- PROD固定key_sel=1、tag_len=0（16-byte tag），只接受受授權key slot；key、IV、tag、長度、owner及epoch在接受job時由可信wrapper snapshot。外部master不能於運算中改tag_in；sl_valid不代表caller有權。
- 明文只進安全quarantine buffer，非可信CPU、DMA、display、encoder及網路不可讀／不可觀察；最後只有同job epoch/sequence、done && tag_ok && !err && !clr、預期長度完全吻合才可發布ownership。out_last不能當作驗證完成。
- 超容量在開始前拒絕。不得將大訊息任意切成獨立GCM以規避buffer限制；若採chunk AEAD，需另定signed metadata／AAD綁定object、chunk index、總長、最後chunk、版本與防重排政策。
- err/clr/timeout/reset／key失效時隔離buffer，清除並完成cache維護後才可重用；掉電後殘值亦不可重映射。異常同拍優先於release。reset epoch不是秘密nonce，不可拿它替代跨斷電IV唯一性。
- GCM加密IV在同key下不得重用；持久counter／裝置分域的分配及斷電原子性仍待設計。不能只以TRNG或volatile sequence保證唯一。
- mailbox原64B payload沒有epoch欄位；epoch必須在可信queue wrapper與completion sideband配對，不接受caller自報。sequence到u32上限需drain、失效舊epoch再建新session，禁止靜默wrap。傳輸epoch不授予安全權限。
新增S17：GCM未驗證明文／tag替換／reset後完成事件重播。驗收應含壞tag每bit翻轉、tag_in運算中改寫、backpressure、溢位、owner切換、reset/err/clr與done同拍、cache及NoC旁路；只有受限host模型測試已跑，RTL/system/physical NOT RUN。
參考模型位於orca PR #5的dv/security/gcm_quarantine_model.py；命令python -m unittest discover -s dv/security -p test_gcm_quarantine.py -v。Python 3.14.8實跑8個tests通過（含4種failure flags子案例）；模型沒有執行AES/GHASH、沒有連接RTL，tag_ok由測試注入，bytearray清空不能證明硬體或Python heap零化。此證據只支持release政策範例，不能將S17或整體安全標為verified。
下一步：由crypto／platform consumer審查quarantine容量、snapshot wrapper、identity與epoch sideband，再建立RTL scoreboard及負例。OTP/TRNG、PMP／獨立隔離域、可信verifier、UPF／DFT仍未解決。
