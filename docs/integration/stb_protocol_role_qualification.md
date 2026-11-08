# TV／STB／IPCAM：控制器角色資格與更新驗收

日期：2026-11-01（Asia/Taipei）。來源 main：`e6a39a36d131c916688735a9874dfafb30474203`。本文件是 **design／qualification** 更新，未新增 RTL、未重跑模擬或合成、未做 physical signoff。現有 educational slice 的驗證不能視為產品控制器驗收。

## 已核實角色及要求

| IP | current：實際角色 | required：產品使用角色 | gap／update：下一個獨立交付 | acceptance：不可省略的驗收 |
|---|---|---|---|---|
| I2C | target，SCL input，位址預設 0x50 | sensor／tuner／DDC controller | 新獨立 master 模組；保留既有 target ABI | start/repeated-start/stop、7-bit address、ACK/NACK、clock stretching、timeout/cancel、reset釋放開漏pin；獨立target scoreboard |
| SPI | mode-0 slave，SCLK/CS input | 外部裝置 controller | 新master；mode與word size由SKU凍結，不假設現有slave可反接 | pin-level命令／資料比對、CS setup/hold、clock divider邊界、FIFO under/overflow、abort後CS釋放 |
| QSPI | 標準／quad slave，SCLK/CS input | boot-flash host（XIP另立需求） | host command/address/dummy/data FSM與flash profile；不能只反轉方向 | 獨立flash model，read/program/erase與WIP timeout；boot read故障與reset恢復；XIP若啟用需另驗cache/bus/stall |
| MDIO | Clause-22 PHY target，MDC input，PHY_ADDR預設0x0C | MAC側PHY management controller | MDC generator、Clause-22 command/turnaround、bounded completion | 外部PHY model、read/write、TA錯誤、無回應timeout、output-enable與開漏釋放、divider最值 |
| SDIO | card側function 1 subset，CMD52/53 byte mode | Wi-Fi module host（若選SDIO） | host init／CMD／data／interrupt與DMA；module profile凍結後實作 | 真實模組相容性；response/CRC/timeout、IRQ、CMD53 fixed/increment、block mode若宣告則測試；abort/reset無DMA越界 |
| AXI4 | 256-word memory subordinate，ID0，單方向一筆outstanding | interconnect／DMA／memory initiator | 以新模組實作decode、arbitration、routing、error target；既有target僅可作測試端點 | concurrent masters、backpressure、response routing、ordering、starvation上界、unmapped/misaligned/error注入與reset drain |
| HDMI_2_1 | 640x480 internal-pattern TMDS source、簡化serial model | STB外部video TX；TV RX另立 | 沿用既有[display PR #7](https://github.com/tonythetiger168/open-ip-portfolio/pull/7)，不重做同一設計 | external pixel/timing、FIFO starvation、HPD/DDC、packet oracle、PHY contract與目標mode測量；RX/FRL/HDCP各自選型及驗收 |

以上產品角色是整合需求／選配，不代表SKU已凍結。未選定的頻率、lane、解析度、FIFO深度與timeout值均待產品／板級／平台合約確定；不得用本表虛構效能承諾。SDIO host若改採PCIe/USB Wi-Fi則撤除此選配需求。

## 證據

每列均以同一main快照核對RTL header與方向：
- [`I2C_top.sv`](https://github.com/tonythetiger168/open-ip-portfolio/blob/e6a39a36d131c916688735a9874dfafb30474203/rtl/I2C_top.sv)
- [`SPI_top.sv`](https://github.com/tonythetiger168/open-ip-portfolio/blob/e6a39a36d131c916688735a9874dfafb30474203/rtl/SPI_top.sv)
- [`QSPI_top.sv`](https://github.com/tonythetiger168/open-ip-portfolio/blob/e6a39a36d131c916688735a9874dfafb30474203/rtl/QSPI_top.sv)
- [`MDIO_top.sv`](https://github.com/tonythetiger168/open-ip-portfolio/blob/e6a39a36d131c916688735a9874dfafb30474203/rtl/MDIO_top.sv)
- [`SDIO_top.sv`](https://github.com/tonythetiger168/open-ip-portfolio/blob/e6a39a36d131c916688735a9874dfafb30474203/rtl/SDIO_top.sv)
- [`AXI4_top.sv`](https://github.com/tonythetiger168/open-ip-portfolio/blob/e6a39a36d131c916688735a9874dfafb30474203/rtl/AXI4_top.sv)
- [`HDMI_2_1_top.sv`](https://github.com/tonythetiger168/open-ip-portfolio/blob/e6a39a36d131c916688735a9874dfafb30474203/rtl/HDMI_2_1_top.sv)

遞迴tree未發現AGENTS.md或CLAUDE.md。已檢查open PR：#7已承載HDMI／panel／broadcast設計；本次不修改其路徑，也不將未合併設計當main能力。其他進行中crypto、IDE、cross-check PR不在本文件變更範圍。

## 共用介面交付門檻

1. 每個新增host使用獨立、versioned CAP/CSR；既有target wrapper位址不原地改角色。
2. 在新增RTL前明定clock/reset、CDC、pin output-enable、ownership、IRQ W1C、bounded timeout及abort/drain語意。
3. DMA或外部輸入不可任意指定host實體位址；descriptor長度／buffer邊界／security domain需檢查。reset/power-off後不保留舊transaction權限。
4. reference model、directed/error/backpressure/reset測試、source SHA和raw logs一併交付。coverage記錄分母、exclusion與測試情境，不能只報百分比。
5. RTL verified與physical分開：synthesis/STA/CDC/RDC/IO timing、PHY電氣與板級驗證尚需獨立gate。

## 進度與下一步

本輪完成source-role核對與可審查的更新／驗收矩陣。下一步由platform domain認領host與fabric模組，display沿用PR #7；先凍結真正需要的host和clock/pin profile，再安排增量實作。未提交RTL進度百分比或完成日期；ETA目前未知。
