# open-ip-portfolio

Open-source SystemVerilog protocol IP portfolio (Apache-2.0) — 117 protocols,
each with a synthesizable RTL design, a self-checking testbench, and
open-toolchain build flows (Icarus Verilog simulation + Yosys synthesis).

## Directory layout

```
rtl/                     one <PROTOCOL>_top.sv per protocol (synthesizable SV)
tb/                      self-checking testbenches (print TEST PASSED/FAILED)
syn/                     per-protocol Yosys scripts, DC TCL, SDC constraints
sim/                     per-protocol simulator filelists
Makefile.<PROTOCOL>      per-protocol entry: make -f Makefile.<P> sim|syn
releases/                standalone per-protocol packages: open_ip_<P>.zip
gen_framework.py         framework generator (templates kept in sync with rtl/)
docs/                    portfolio review and methodology notes
setup_tools.sh           installs iverilog / yosys if missing
```

## Protocol catalog (117)

### AMBA & ARM interconnect (16)

| Protocol | Build | Standalone package |
|---|---|---|
| ACE | `make -f Makefile.ACE sim` | [open_ip_ACE.zip](releases/open_ip_ACE.zip) |
| ACE-Lite | `make -f Makefile.ACE_Lite sim` | [open_ip_ACE_Lite.zip](releases/open_ip_ACE_Lite.zip) |
| AHB | `make -f Makefile.AHB sim` | [open_ip_AHB.zip](releases/open_ip_AHB.zip) |
| APB | `make -f Makefile.APB sim` | [open_ip_APB.zip](releases/open_ip_APB.zip) |
| ARM LTI (Local Translation Interface) | `make -f Makefile.ARM_Local_Translation_Interface sim` | [open_ip_ARM_Local_Translation_Interface.zip](releases/open_ip_ARM_Local_Translation_Interface.zip) |
| ARM Q-Channel (Low Power Interface) | `make -f Makefile.ARM_Q_Channel_Low_Power_Interface sim` | [open_ip_ARM_Q_Channel_Low_Power_Interface.zip](releases/open_ip_ARM_Q_Channel_Low_Power_Interface.zip) |
| ARM SWD (Serial Wire Debug) | `make -f Makefile.ARM_Serial_Wire_Debug sim` | [open_ip_ARM_Serial_Wire_Debug.zip](releases/open_ip_ARM_Serial_Wire_Debug.zip) |
| ATB | `make -f Makefile.ATB sim` | [open_ip_ATB.zip](releases/open_ip_ATB.zip) |
| AVSBus (Adaptive Voltage Scaling) | `make -f Makefile.AVSBus__Adaptive_Voltage_Scaling_ sim` | [open_ip_AVSBus__Adaptive_Voltage_Scaling_.zip](releases/open_ip_AVSBus__Adaptive_Voltage_Scaling_.zip) |
| AXI | `make -f Makefile.AXI sim` | [open_ip_AXI.zip](releases/open_ip_AXI.zip) |
| AXI-Stream | `make -f Makefile.AXI_Stream sim` | [open_ip_AXI_Stream.zip](releases/open_ip_AXI_Stream.zip) |
| AXI4 | `make -f Makefile.AXI4 sim` | [open_ip_AXI4.zip](releases/open_ip_AXI4.zip) |
| AXI4-Lite | `make -f Makefile.AXI4_Lite sim` | [open_ip_AXI4_Lite.zip](releases/open_ip_AXI4_Lite.zip) |
| CCIX (Cache Coherent Interconnect) | `make -f Makefile.CCIX_Cache_Coherent_Interconnect sim` | [open_ip_CCIX_Cache_Coherent_Interconnect.zip](releases/open_ip_CCIX_Cache_Coherent_Interconnect.zip) |
| CHI | `make -f Makefile.CHI sim` | [open_ip_CHI.zip](releases/open_ip_CHI.zip) |
| CXS (CCIX Stream Interface) | `make -f Makefile.CXS_CCIX_Stream_Interface sim` | [open_ip_CXS_CCIX_Stream_Interface.zip](releases/open_ip_CXS_CCIX_Stream_Interface.zip) |

### USB (9)

| Protocol | Build | Standalone package |
|---|---|---|
| USB | `make -f Makefile.USB sim` | [open_ip_USB.zip](releases/open_ip_USB.zip) |
| USB 2.0 | `make -f Makefile.USB2_0 sim` | [open_ip_USB2_0.zip](releases/open_ip_USB2_0.zip) |
| USB 3.2 | `make -f Makefile.USB3_2 sim` | [open_ip_USB3_2.zip](releases/open_ip_USB3_2.zip) |
| USB PD (Power Delivery) | `make -f Makefile.USB_PD sim` | [open_ip_USB_PD.zip](releases/open_ip_USB_PD.zip) |
| USB Type-C Port Controller | `make -f Makefile.USB_Type_C_Port_Controller sim` | [open_ip_USB_Type_C_Port_Controller.zip](releases/open_ip_USB_Type_C_Port_Controller.zip) |
| USB2 | `make -f Makefile.USB2 sim` | [open_ip_USB2.zip](releases/open_ip_USB2.zip) |
| USB3 | `make -f Makefile.USB3 sim` | [open_ip_USB3.zip](releases/open_ip_USB3.zip) |
| USB4 | `make -f Makefile.USB4 sim` | [open_ip_USB4.zip](releases/open_ip_USB4.zip) |
| eUSB2 | `make -f Makefile.eUSB2 sim` | [open_ip_eUSB2.zip](releases/open_ip_eUSB2.zip) |

### MIPI (18)

| Protocol | Build | Standalone package |
|---|---|---|
| C-PHY | `make -f Makefile.C_PHY sim` | [open_ip_C_PHY.zip](releases/open_ip_C_PHY.zip) |
| CSI-2 | `make -f Makefile.CSI_2 sim` | [open_ip_CSI_2.zip](releases/open_ip_CSI_2.zip) |
| D-PHY | `make -f Makefile.D_PHY sim` | [open_ip_D_PHY.zip](releases/open_ip_D_PHY.zip) |
| DSI | `make -f Makefile.DSI sim` | [open_ip_DSI.zip](releases/open_ip_DSI.zip) |
| DigRF | `make -f Makefile.DigRF sim` | [open_ip_DigRF.zip](releases/open_ip_DigRF.zip) |
| I3C | `make -f Makefile.I3C sim` | [open_ip_I3C.zip](releases/open_ip_I3C.zip) |
| M-PHY | `make -f Makefile.M_PHY sim` | [open_ip_M_PHY.zip](releases/open_ip_M_PHY.zip) |
| MIPI DBI (Display Bus Interface) | `make -f Makefile.MIPI_DBI__Display_Bus_Interface_ sim` | [open_ip_MIPI_DBI__Display_Bus_Interface_.zip](releases/open_ip_MIPI_DBI__Display_Bus_Interface_.zip) |
| MIPI DPI (Display Pixel Interface) | `make -f Makefile.MIPI_DPI__Display_Pixel_Interface_ sim` | [open_ip_MIPI_DPI__Display_Pixel_Interface_.zip](releases/open_ip_MIPI_DPI__Display_Pixel_Interface_.zip) |
| MIPI I3C | `make -f Makefile.MIPI_I3C sim` | [open_ip_MIPI_I3C.zip](releases/open_ip_MIPI_I3C.zip) |
| MIPI RFFE | `make -f Makefile.MIPI_RFFE sim` | [open_ip_MIPI_RFFE.zip](releases/open_ip_MIPI_RFFE.zip) |
| MIPI SLIMbus | `make -f Makefile.MIPI_SLIMbus sim` | [open_ip_MIPI_SLIMbus.zip](releases/open_ip_MIPI_SLIMbus.zip) |
| MIPI SPMI | `make -f Makefile.MIPI_SPMI sim` | [open_ip_MIPI_SPMI.zip](releases/open_ip_MIPI_SPMI.zip) |
| MIPI SoundWire | `make -f Makefile.MIPI_SoundWire sim` | [open_ip_MIPI_SoundWire.zip](releases/open_ip_MIPI_SoundWire.zip) |
| RFFE | `make -f Makefile.RFFE sim` | [open_ip_RFFE.zip](releases/open_ip_RFFE.zip) |
| SPMI | `make -f Makefile.SPMI sim` | [open_ip_SPMI.zip](releases/open_ip_SPMI.zip) |
| UniPro | `make -f Makefile.UniPro sim` | [open_ip_UniPro.zip](releases/open_ip_UniPro.zip) |
| UniPro_Mem (memory-mapped) | `make -f Makefile.UniPro_Mem sim` | [open_ip_UniPro_Mem.zip](releases/open_ip_UniPro_Mem.zip) |

### Memory & DRAM (23)

| Protocol | Build | Standalone package |
|---|---|---|
| DDR | `make -f Makefile.DDR sim` | [open_ip_DDR.zip](releases/open_ip_DDR.zip) |
| DDR4 | `make -f Makefile.DDR4 sim` | [open_ip_DDR4.zip](releases/open_ip_DDR4.zip) |
| DDR5 | `make -f Makefile.DDR5 sim` | [open_ip_DDR5.zip](releases/open_ip_DDR5.zip) |
| DDR6 | `make -f Makefile.DDR6 sim` | [open_ip_DDR6.zip](releases/open_ip_DDR6.zip) |
| DDR7 | `make -f Makefile.DDR7 sim` | [open_ip_DDR7.zip](releases/open_ip_DDR7.zip) |
| DFI 5.0 (MC-PHY Interface) | `make -f Makefile.DFI_5_0__MC_PHY_Interface_ sim` | [open_ip_DFI_5_0__MC_PHY_Interface_.zip](releases/open_ip_DFI_5_0__MC_PHY_Interface_.zip) |
| GDDR5 | `make -f Makefile.GDDR5 sim` | [open_ip_GDDR5.zip](releases/open_ip_GDDR5.zip) |
| GDDR6 | `make -f Makefile.GDDR6 sim` | [open_ip_GDDR6.zip](releases/open_ip_GDDR6.zip) |
| GDDR7 | `make -f Makefile.GDDR7 sim` | [open_ip_GDDR7.zip](releases/open_ip_GDDR7.zip) |
| HBM | `make -f Makefile.HBM sim` | [open_ip_HBM.zip](releases/open_ip_HBM.zip) |
| HBM2 | `make -f Makefile.HBM2 sim` | [open_ip_HBM2.zip](releases/open_ip_HBM2.zip) |
| HBM3 | `make -f Makefile.HBM3 sim` | [open_ip_HBM3.zip](releases/open_ip_HBM3.zip) |
| HBM3E | `make -f Makefile.HBM3E sim` | [open_ip_HBM3E.zip](releases/open_ip_HBM3E.zip) |
| HBM4 | `make -f Makefile.HBM4 sim` | [open_ip_HBM4.zip](releases/open_ip_HBM4.zip) |
| HBM5 | `make -f Makefile.HBM5 sim` | [open_ip_HBM5.zip](releases/open_ip_HBM5.zip) |
| LPDDR | `make -f Makefile.LPDDR sim` | [open_ip_LPDDR.zip](releases/open_ip_LPDDR.zip) |
| LPDDR4 | `make -f Makefile.LPDDR4 sim` | [open_ip_LPDDR4.zip](releases/open_ip_LPDDR4.zip) |
| LPDDR5 | `make -f Makefile.LPDDR5 sim` | [open_ip_LPDDR5.zip](releases/open_ip_LPDDR5.zip) |
| LPDDR5X | `make -f Makefile.LPDDR5X sim` | [open_ip_LPDDR5X.zip](releases/open_ip_LPDDR5X.zip) |
| LPDDR6 | `make -f Makefile.LPDDR6 sim` | [open_ip_LPDDR6.zip](releases/open_ip_LPDDR6.zip) |
| LPDDR7 | `make -f Makefile.LPDDR7 sim` | [open_ip_LPDDR7.zip](releases/open_ip_LPDDR7.zip) |
| ONFI | `make -f Makefile.ONFI sim` | [open_ip_ONFI.zip](releases/open_ip_ONFI.zip) |
| Toggle Mode NAND | `make -f Makefile.Toggle_Mode_NAND sim` | [open_ip_Toggle_Mode_NAND.zip](releases/open_ip_Toggle_Mode_NAND.zip) |

### Storage & storage hosts (9)

| Protocol | Build | Standalone package |
|---|---|---|
| FC | `make -f Makefile.FC sim` | [open_ip_FC.zip](releases/open_ip_FC.zip) |
| NVMe | `make -f Makefile.NVMe sim` | [open_ip_NVMe.zip](releases/open_ip_NVMe.zip) |
| SAS | `make -f Makefile.SAS sim` | [open_ip_SAS.zip](releases/open_ip_SAS.zip) |
| SAS-4 (Serial Attached SCSI) | `make -f Makefile.SAS_4__Serial_Attached_SCSI_ sim` | [open_ip_SAS_4__Serial_Attached_SCSI_.zip](releases/open_ip_SAS_4__Serial_Attached_SCSI_.zip) |
| SATA | `make -f Makefile.SATA sim` | [open_ip_SATA.zip](releases/open_ip_SATA.zip) |
| SD | `make -f Makefile.SD sim` | [open_ip_SD.zip](releases/open_ip_SD.zip) |
| SDIO | `make -f Makefile.SDIO sim` | [open_ip_SDIO.zip](releases/open_ip_SDIO.zip) |
| UFS | `make -f Makefile.UFS sim` | [open_ip_UFS.zip](releases/open_ip_UFS.zip) |
| eMMC | `make -f Makefile.eMMC sim` | [open_ip_eMMC.zip](releases/open_ip_eMMC.zip) |

### Display, audio & content protection (5)

| Protocol | Build | Standalone package |
|---|---|---|
| DisplayPort 2 | `make -f Makefile.DisplayPort2 sim` | [open_ip_DisplayPort2.zip](releases/open_ip_DisplayPort2.zip) |
| HDCP 2.3 (Content Protection) | `make -f Makefile.HDCP_2_3_Content_Protection sim` | [open_ip_HDCP_2_3_Content_Protection.zip](releases/open_ip_HDCP_2_3_Content_Protection.zip) |
| HDMI 2.1 | `make -f Makefile.HDMI_2_1 sim` | [open_ip_HDMI_2_1.zip](releases/open_ip_HDMI_2_1.zip) |
| I2S | `make -f Makefile.I2S sim` | [open_ip_I2S.zip](releases/open_ip_I2S.zip) |
| I2S Audio | `make -f Makefile.I2S_Audio sim` | [open_ip_I2S_Audio.zip](releases/open_ip_I2S_Audio.zip) |

### Ethernet & networking (6)

| Protocol | Build | Standalone package |
|---|---|---|
| Ethernet | `make -f Makefile.Ethernet sim` | [open_ip_Ethernet.zip](releases/open_ip_Ethernet.zip) |
| Ethernet AVB/TSN | `make -f Makefile.Ethernet_AVB_TSN sim` | [open_ip_Ethernet_AVB_TSN.zip](releases/open_ip_Ethernet_AVB_TSN.zip) |
| GMII | `make -f Makefile.GMII sim` | [open_ip_GMII.zip](releases/open_ip_GMII.zip) |
| MDIO | `make -f Makefile.MDIO sim` | [open_ip_MDIO.zip](releases/open_ip_MDIO.zip) |
| RGMII | `make -f Makefile.RGMII sim` | [open_ip_RGMII.zip](releases/open_ip_RGMII.zip) |
| XGMII | `make -f Makefile.XGMII sim` | [open_ip_XGMII.zip](releases/open_ip_XGMII.zip) |

### Chip-to-chip & die-to-die (8)

| Protocol | Build | Standalone package |
|---|---|---|
| CXL | `make -f Makefile.CXL sim` | [open_ip_CXL.zip](releases/open_ip_CXL.zip) |
| Interlaken v1.2 | `make -f Makefile.Interlaken_v1_2 sim` | [open_ip_Interlaken_v1_2.zip](releases/open_ip_Interlaken_v1_2.zip) |
| JESD204C | `make -f Makefile.JESD204C sim` | [open_ip_JESD204C.zip](releases/open_ip_JESD204C.zip) |
| PCIe | `make -f Makefile.PCIe sim` | [open_ip_PCIe.zip](releases/open_ip_PCIe.zip) |
| TileLink (TL-UL / TL-C) | `make -f Makefile.TileLink__TL_UL_TL_C_ sim` | [open_ip_TileLink__TL_UL_TL_C_.zip](releases/open_ip_TileLink__TL_UL_TL_C_.zip) |
| UALink | `make -f Makefile.UALink sim` | [open_ip_UALink.zip](releases/open_ip_UALink.zip) |
| UCIe | `make -f Makefile.UCIe sim` | [open_ip_UCIe.zip](releases/open_ip_UCIe.zip) |
| UEC | `make -f Makefile.UEC sim` | [open_ip_UEC.zip](releases/open_ip_UEC.zip) |

### Other on-chip interconnect (6)

| Protocol | Build | Standalone package |
|---|---|---|
| Avalon-MM | `make -f Makefile.Avalon_MM sim` | [open_ip_Avalon_MM.zip](releases/open_ip_Avalon_MM.zip) |
| Avalon-ST | `make -f Makefile.Avalon_ST sim` | [open_ip_Avalon_ST.zip](releases/open_ip_Avalon_ST.zip) |
| OCP | `make -f Makefile.OCP sim` | [open_ip_OCP.zip](releases/open_ip_OCP.zip) |
| OCP-IP (Open Core Protocol) | `make -f Makefile.OCP_IP_Open_Core_Protocol sim` | [open_ip_OCP_IP_Open_Core_Protocol.zip](releases/open_ip_OCP_IP_Open_Core_Protocol.zip) |
| WTB | `make -f Makefile.WTB sim` | [open_ip_WTB.zip](releases/open_ip_WTB.zip) |
| Wishbone | `make -f Makefile.Wishbone sim` | [open_ip_Wishbone.zip](releases/open_ip_Wishbone.zip) |

### High-speed serial & fronthaul (3)

| Protocol | Build | Standalone package |
|---|---|---|
| CPRI v8.0 (eCPRI over CPRI) | `make -f Makefile.CPRI_v8_0__eCPRI_over_CPR_ sim` | [open_ip_CPRI_v8_0__eCPRI_over_CPR_.zip](releases/open_ip_CPRI_v8_0__eCPRI_over_CPR_.zip) |
| HSI | `make -f Makefile.HSI sim` | [open_ip_HSI.zip](releases/open_ip_HSI.zip) |
| eCPRI over Ethernet | `make -f Makefile.eCPRI_over_Ethernet sim` | [open_ip_eCPRI_over_Ethernet.zip](releases/open_ip_eCPRI_over_Ethernet.zip) |

### Automotive & industrial (3)

| Protocol | Build | Standalone package |
|---|---|---|
| CAN | `make -f Makefile.CAN sim` | [open_ip_CAN.zip](releases/open_ip_CAN.zip) |
| FlexRay | `make -f Makefile.FlexRay sim` | [open_ip_FlexRay.zip](releases/open_ip_FlexRay.zip) |
| LIN | `make -f Makefile.LIN sim` | [open_ip_LIN.zip](releases/open_ip_LIN.zip) |

### Wireless (1)

| Protocol | Build | Standalone package |
|---|---|---|
| Bluetooth 5 | `make -f Makefile.Bluetooth5 sim` | [open_ip_Bluetooth5.zip](releases/open_ip_Bluetooth5.zip) |

### Security & crypto (2)

| Protocol | Build | Standalone package |
|---|---|---|
| CSE | `make -f Makefile.CSE sim` | [open_ip_CSE.zip](releases/open_ip_CSE.zip) |
| Crypto (Security Engine) | `make -f Makefile.Crypto___Security_Engine sim` | [open_ip_Crypto___Security_Engine.zip](releases/open_ip_Crypto___Security_Engine.zip) |

### Low-speed & board-level (8)

| Protocol | Build | Standalone package |
|---|---|---|
| 1-Wire | `make -f Makefile._1_Wire sim` | [open_ip__1_Wire.zip](releases/open_ip__1_Wire.zip) |
| GPIO | `make -f Makefile.GPIO sim` | [open_ip_GPIO.zip](releases/open_ip_GPIO.zip) |
| I2C | `make -f Makefile.I2C sim` | [open_ip_I2C.zip](releases/open_ip_I2C.zip) |
| JTAG | `make -f Makefile.JTAG sim` | [open_ip_JTAG.zip](releases/open_ip_JTAG.zip) |
| PWM | `make -f Makefile.PWM sim` | [open_ip_PWM.zip](releases/open_ip_PWM.zip) |
| QSPI | `make -f Makefile.QSPI sim` | [open_ip_QSPI.zip](releases/open_ip_QSPI.zip) |
| SPI | `make -f Makefile.SPI sim` | [open_ip_SPI.zip](releases/open_ip_SPI.zip) |
| UART | `make -f Makefile.UART sim` | [open_ip_UART.zip](releases/open_ip_UART.zip) |


## Quick start

```sh
# simulate one protocol (Icarus Verilog, SystemVerilog 2012)
make -f Makefile.I2C sim        # -> TEST PASSED: I2C

# synthesize one protocol (Yosys)
make -f Makefile.I2C syn        # -> 0 errors, cell count report

# full regression: 117/117 sim + syn PASS
for m in Makefile.*; do make -f $m sim; done

# standalone package workflow
unzip releases/open_ip_SAS.zip && cd open_ip_SAS && make sim
```

## Verification status (v2.4)

- Simulation: **117/117 PASS** (iverilog 11.0), all testbenches self-checking
  with error injection; key fixes proven by mutant (negative) testing
- Synthesis: **117/117 PASS** (yosys 0.23), zero errors
- Highlights: real AES-128 (CSE, NIST vectors) reused by HDCP 2.3;
  real SHA-256+HMAC (Crypto, RFC 4231 vectors); parameterized serial bit
  rate (`BIT_CLKS`) on SAS/SATA/SDIO/UFS/eMMC/SAS-4 with functional
  coverage at BIT_CLKS=4; `ram_style="block"` attributes on large memories
- Known limitation: verification covers the open-source flow only
  (iverilog/yosys); no commercial tools (VCS/DC) available in this environment

## License

**Apache License 2.0** (`SPDX-License-Identifier: Apache-2.0`). See [LICENSE](LICENSE)
and the SPDX tag in each source file header.

In plain terms:

- ✅ Commercial use allowed — you may integrate these IP designs into
  proprietary ASIC/FPGA products, tape out, and sell chips. **No royalties, no
  feedback obligation, no requirement to open-source your own design.**
- ✅ Modification and redistribution allowed (keep the license text and
  copyright notice)
- ✅ Explicit patent grant from every contributor, with a retaliation clause
  that protects both users and contributors
- ⚠️ Provided **as-is, without warranty**; trademarks are not licensed

Every source file carries an SPDX short identifier
(`// SPDX-License-Identifier: Apache-2.0`), following the Linux kernel and
OpenTitan convention, so automated license scanners (FOSSology, scancode,
GitHub) detect compliance without parsing full headers.
