# 2026-11-01 安全IP實測證據
目標main commit：e6a39a36d131c916688735a9874dfafb30474203。透過已連接GitHub讀取固定commit的RTL、TB與向量，在獨立本機snapshot測試，沒有讀取額外憑證，沒有變更main。本報告不是本設計分支整體RTL回歸。
環境：Windows WSL Ubuntu；Icarus Verilog 12.0；Verilator 5.032僅確認版本、本輪未執行coverage。每個core命令：
```sh
iverilog -g2012 -I tb -I formal -s <IP>_tb -o work/<IP>.vvp rtl/<IP>_top.sv tb/<IP>_tb.sv
timeout 60 vvp work/<IP>.vvp
```
|IP|結果|log摘要|限制|
|---|---|---|---|
|Root_of_Trust|PASS，exit 0|boot cases: 52；TEST PASSED: Root_of_Trust|只測現有digest-pinned slice，不測公鑰驗簽／OTA／真實OTP|
|AES_GCM|PASS，exit 0|758 cases, 0 errors；TEST PASSED: AES_GCM|沒有產品quarantine/firewall／持久IV驗證|
|SHA3|PASS with warning，exit 0|vectors: 642 cases；692 cases, 166 err pulses, 453 done pulses；TEST PASSED|readmemh警告向量字數不足8192宣告範圍；保留警告，未改TB掩蓋；err pulses包含負例，不能解釋成166失敗|
|HDCP_2_3_Content_Protection|INCOMPLETE，exit 124|60秒host timeout，未輸出TEST PASSED|不能列PASS，不能僅據timeout判RTL功能錯；需較快sim／獨立長測|
最初shell迴圈因PowerShell/native引號傳遞導致IP變數空值而編譯失敗；修正為固定保存的shell script再重跑，以上為重跑結果。原失敗不是RTL結果。
SHA3 warning未驗證所有未填array位置永不讀取，因此不據此宣稱完整向量/coverage驗收。HDCP包含65536-word counter exhaustion場景及組合AES，尚不能確認timeout是host性能或RTL活性。
本輪未跑APB wrapper、formal、mutation、coverage重收斂、PPA、STA、UPF、DFT、FPGA或實體entropy；不得沿用來源100% coverage為本次結果。
前次orca host quarantine模型8 tests已通過；本次不是新增AES/GHASH模型證據。
