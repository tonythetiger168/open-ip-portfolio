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
