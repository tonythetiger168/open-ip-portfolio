# TV／STB／IPCAM 平台 bus／host 逐項矩陣

2026-11-01 15:00 Asia/Taipei。盤點表 v0.2 是候選能力，非凍結規格。線速、頻寬、clock、DMA channels、CPU及PHY選型均待定；ETA未知。

本repo main基線 `e6a39a36d131c916688735a9874dfafb30474203`。表格來源open-ip固定df9d0ed早於本輪main；本輪重新讀取九個RTL角色，不能把表格報告coverage當成本輪重跑。無AGENTS.md／CLAUDE.md（recursive tree檢查）；已讀CONTRIBUTING與既有總計畫。

|項目／表格列|current|未凍結 required|gap|本輪 update|acceptance（未註實跑均待執行）|evidence|
|---|---|---|---|---|---|---|
|AXI4；TV #1; STB #1; IPCAM #1|memory subordinate、256 words、ID0、每方向 single outstanding；預設32-bit|多manager AXI memory fabric|不是 interconnect/DMA；無 ID routing、QoS、firewall；DW 參數不能推定128-bit|隔離 fabric/manager 設計，既有 core 不改 ports|來源ID/response routing、4KB、並行read/write、stall、error、drain|rtl/AXI4_top.sv @ e6a39a3；https://github.com/tonythetiger168/open-ip-portfolio/blob/df9d0ed755c80d40aa42c4de55d6fd163c105c90/docs/ip/AXI4.md|
|AXI4_Lite；TV #2; STB #2; IPCAM #2|register-memory subordinate；AW後才接W|AXI-Lite CSR crossbar及APB bridge|沒有 bridge/decoder；無 AxPROT；參數不能推定泛用寬度|定義 AW/W獨立snapshot及錯誤轉換，待RTL|AW-first/W-first、B/R stall stability、strobe、PSLVERR轉換|rtl/AXI4_Lite_top.sv @ e6a39a3；https://github.com/tonythetiger168/open-ip-portfolio/blob/df9d0ed755c80d40aa42c4de55d6fd163c105c90/docs/ip/AXI4_Lite.md|
|AXI_Stream；TV #3; STB #3; IPCAM #3|只有16-entry capture sink，無TKEEP/TUSER；滿後到reset才清|source/sink adapter、stream fabric及DMA|無SOF/packing/有效lane/回收及frame ownership|沿用既有capture用途；新增media adapter/DMA合約，不把sink命名為DMA|SOF/EOL、tail mask、stall、overflow drop、pattern→DMA→buffer→sink|rtl/AXI_Stream_top.sv @ e6a39a3；https://github.com/tonythetiger168/open-ip-portfolio/blob/df9d0ed755c80d40aa42c4de55d6fd163c105c90/docs/ip/AXI_Stream.md|
|APB；TV #4; STB #4; IPCAM #4|APB_top是APB3 memory completer；APB_apb則APB4 CSR wrapper|peripheral decoder/router；AXI→APB另外設計|completer不是decoder；wrapper不是bridge|新增同域雙4KB APB4 router RTL原型|16 directed checks、default-error mutation偵測、generic synthesis；coverage/STA待驗|rtl/APB_top.sv @ e6a39a3；https://github.com/tonythetiger168/open-ip-portfolio/blob/df9d0ed755c80d40aa42c4de55d6fd163c105c90/docs/ip/APB.md|
|I2C；TV #12; STB #12; IPCAM #12|7-bit target，預設0x50；SCL為input|sensor/tuner I2C host|無SCL生成及host command/recovery|提出獨立host及CSR/START/STOP/stretch/arbitration合約|獨立target的NACK/stretch/repeated START/last NACK/stuck-bus/abort|rtl/I2C_top.sv @ e6a39a3；https://github.com/tonythetiger168/open-ip-portfolio/blob/df9d0ed755c80d40aa42c4de55d6fd163c105c90/docs/ip/I2C.md|
|SPI；TV #13; STB #13; IPCAM #13|mode0 8-bit target；SCLK/CSn input|peripheral SPI host|無SCLK/CS生成；main MISO未依CS釋放，PR13修復未合併|獨立host合約，避免與PR13重複改同一core|四mode edge/CS timing/underflow/abort；mode0先實作則CAP限定|rtl/SPI_top.sv @ e6a39a3；https://github.com/tonythetiger168/open-ip-portfolio/blob/df9d0ed755c80d40aa42c4de55d6fd163c105c90/docs/ip/SPI.md|
|QSPI；TV #8; STB #8; IPCAM #8|standard/quad target；SCLK/CSn input|boot-flash host；XIP另議|無opcode/address/dummy引擎、bootROM/XIP；main OE未以CS gating|提出phase descriptor、IO OE、flash profile及寫擦權限合約|獨立flash model read/dummy/turnaround/address/掉電；XIP另驗|rtl/QSPI_top.sv @ e6a39a3；https://github.com/tonythetiger168/open-ip-portfolio/blob/df9d0ed755c80d40aa42c4de55d6fd163c105c90/docs/ip/QSPI.md|
|MDIO；TV #11; STB #11; IPCAM #11|Clause22 PHY target，預設地址0x0C；MDC input|MAC-side station-management host|無MDC生成、host read/write及TA檢查|提出Clause22 host合約；Clause45不支援|PHYAD/REGAD、TA Z0/no-device、read/write、divider/abort|rtl/MDIO_top.sv @ e6a39a3；https://github.com/tonythetiger168/open-ip-portfolio/blob/df9d0ed755c80d40aa42c4de55d6fd163c105c90/docs/ip/MDIO.md|
|SDIO；TV #25; STB #25; IPCAM #22|function1 card、CMD52/53 byte mode、count1..32；sd_clk input|Wi-Fi module SDIO host（選配）|無enumeration/function0/CCCR、SDCLK、host DMA；VIP fixed response不補足|提出host初始化、CMD52/53、IRQ、CRC與timeout合約|獨立card enumerate/CCCR/R4/R5/data/CRC/busy/IRQ/abort；真實模組另驗|rtl/SDIO_top.sv @ e6a39a3；https://github.com/tonythetiger168/open-ip-portfolio/blob/df9d0ed755c80d40aa42c4de55d6fd163c105c90/docs/ip/SDIO.md|
|DMA / shared fabric；三表 #1–4 的系統缺口；inventory無獨立DMA列|本repo未找到可用media 2D DMA或多manager AXI fabric|AXI manager、2D stride、多plane、ring/cache/domain/ownership|sink/subordinate/VIP不能替代DMA；DDR service bound與吞吐待定|參照ORCA draft PR3，共用contract保持proposed；本輪不覆寫該工作|pattern→DMA→buffer→sink；4KB/IDs/errors/abort drain/secure隔離；RTL待執行|repo recursive tree；ORCA PR #3（提案、不是驗證證據）|

## 角色與報告解讀

所有 protocol wrapper 的 APB4 slave 是控制面，不表示資料面能host。docs/test_suites 的 Sufficient／100% mutation僅針對其model與mutant集合，不能提升為system/production驗證。既有來源claim未在本輪重跑，不抹除既有證據，也不把其算入本輪結果。

open-ip主線SPI MISO CS-high釋放缺口已在PR #13有修復提案，本輪不重複修改。AXI4/AXI-Lite的地址步進/索引仍固定32-bit shape，不因DW參數宣稱128-bit相容；AXI read資料mux與同址write並行的stall stability需獨立回歸。QSPI output-enable未依CS gating也列後續，不擅自宣稱修復。

## 本機來源指紋

四份原始資料已讀取；表格以IP-inventory.json交叉核對。未更動OneDrive來源。

|檔案|SHA256|
|---|---|
|TV-IP-table.md|507245f9887a89de320a8e0305e1d1d9af3069a2117630d69b0cf690de802a64|
|STB-IP-table.md|bd7c72c16257a1064430dff58249a4152abb50402a9af0dd6e8d8986f633ab0c|
|IPCAM-IP-table.md|c1ae61dbb72cae11ea1ffcb4bc0ef1833fd7e228787712c2f06ae7f25e88fa18|
|IP-inventory.json|188e63e772c08f525c0604e23231afaedc3f826bf081af56b2ae128c9b856093|
