# open-ip-portfolio

Open-source SystemVerilog protocol IP portfolio (Apache-2.0) — **125 protocol
IPs**, each with a synthesizable RTL core, an APB4 register wrapper, self-checking
testbenches for both, a coverage checker (reference model, SVA and functional
coverage), and open-toolchain build flows (Icarus Verilog simulation, Yosys
synthesis, Verilator coverage).

> **Scope, honestly.** Every design here is an *educational slice*: a
> compact, readable implementation of the protocol's core transaction flow —
> not a full-spec, production-hardened controller. Some catalog entries are
> **parameterized variants of a shared core** rather than independent
> implementations (e.g. DDR4/DDR5/HBM3 each carry their own copy of one
> memory-controller design, with their own timing and channel count). See
> [below](#design-organization-cores-vs-variants).

## Directory layout

```
rtl/                     <P>_top.sv core and <P>_apb.sv APB4 wrapper per protocol
tb/                      self-checking testbenches (print TEST PASSED/FAILED)
tb/apb/                  IP-specific parts of the wrapper testbenches
tb/func/                 pin-level / cycle-exact functional tests (DDR4, LPDDR4, Avalon-MM, 1-Wire)
tb/cov/                  Verilator coverage checkers (<P>_sva.sv, <P>_apb_sva.sv)
syn/                     per-protocol Yosys scripts, DC TCL, SDC constraints
sim/                     per-protocol simulator filelists
Makefile.<PROTOCOL>      per-protocol entry: make -f Makefile.<P> sim|syn|apb[|func]
releases/                standalone per-protocol packages: open_ip_<P>.zip
scripts/apb/             APB wrapper generator and register specs (specs/<P>.json)
scripts/cov/             five-metric coverage flow (run_cov.sh, run_all.sh)
scripts/ci_regression.sh sim + syn + apb + func regression run by CI
scripts/package_releases.py  rebuilds releases/ from the current tree
scripts/gen_filelists.py     rebuilds sim/filelist_<P>.f from the Makefiles
scripts/mut/run_mut.py       mutation testing of the testbenches (Icarus or the Verilator flow)
docs/ip/                 one page per IP: ports, register map, coverage
docs/                    coverage closure, portfolio review, methodology notes
gen_framework.py         original v1 generator (frozen: out of sync with rtl/ and tb/)
setup_tools.sh           installs iverilog / yosys if missing
```

## Protocol catalog (125)

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

### Memory & DRAM (27)

| Protocol | Build | Standalone package |
|---|---|---|
| DDR | `make -f Makefile.DDR sim` | [open_ip_DDR.zip](releases/open_ip_DDR.zip) |
| DDR4 | `make -f Makefile.DDR4 sim` | [open_ip_DDR4.zip](releases/open_ip_DDR4.zip) |
| DDR4-Lite | `make -f Makefile.DDR4_Lite sim` | [open_ip_DDR4_Lite.zip](releases/open_ip_DDR4_Lite.zip) |
| DDR5 | `make -f Makefile.DDR5 sim` | [open_ip_DDR5.zip](releases/open_ip_DDR5.zip) |
| DDR6 | `make -f Makefile.DDR6 sim` | [open_ip_DDR6.zip](releases/open_ip_DDR6.zip) |
| DDR7 | `make -f Makefile.DDR7 sim` | [open_ip_DDR7.zip](releases/open_ip_DDR7.zip) |
| DFI 5.0 (MC-PHY Interface) | `make -f Makefile.DFI_5_0__MC_PHY_Interface_ sim` | [open_ip_DFI_5_0__MC_PHY_Interface_.zip](releases/open_ip_DFI_5_0__MC_PHY_Interface_.zip) |
| GDDR5 | `make -f Makefile.GDDR5 sim` | [open_ip_GDDR5.zip](releases/open_ip_GDDR5.zip) |
| GDDR6 | `make -f Makefile.GDDR6 sim` | [open_ip_GDDR6.zip](releases/open_ip_GDDR6.zip) |
| GDDR7 | `make -f Makefile.GDDR7 sim` | [open_ip_GDDR7.zip](releases/open_ip_GDDR7.zip) |
| GDDR7-Lite | `make -f Makefile.GDDR7_Lite sim` | [open_ip_GDDR7_Lite.zip](releases/open_ip_GDDR7_Lite.zip) |
| HBM | `make -f Makefile.HBM sim` | [open_ip_HBM.zip](releases/open_ip_HBM.zip) |
| HBM2 | `make -f Makefile.HBM2 sim` | [open_ip_HBM2.zip](releases/open_ip_HBM2.zip) |
| HBM3 | `make -f Makefile.HBM3 sim` | [open_ip_HBM3.zip](releases/open_ip_HBM3.zip) |
| HBM3E | `make -f Makefile.HBM3E sim` | [open_ip_HBM3E.zip](releases/open_ip_HBM3E.zip) |
| HBM3E-Lite | `make -f Makefile.HBM3E_Lite sim` | [open_ip_HBM3E_Lite.zip](releases/open_ip_HBM3E_Lite.zip) |
| HBM4 | `make -f Makefile.HBM4 sim` | [open_ip_HBM4.zip](releases/open_ip_HBM4.zip) |
| HBM5 | `make -f Makefile.HBM5 sim` | [open_ip_HBM5.zip](releases/open_ip_HBM5.zip) |
| LPDDR | `make -f Makefile.LPDDR sim` | [open_ip_LPDDR.zip](releases/open_ip_LPDDR.zip) |
| LPDDR4 | `make -f Makefile.LPDDR4 sim` | [open_ip_LPDDR4.zip](releases/open_ip_LPDDR4.zip) |
| LPDDR5 | `make -f Makefile.LPDDR5 sim` | [open_ip_LPDDR5.zip](releases/open_ip_LPDDR5.zip) |
| LPDDR5X | `make -f Makefile.LPDDR5X sim` | [open_ip_LPDDR5X.zip](releases/open_ip_LPDDR5X.zip) |
| LPDDR5X-Lite | `make -f Makefile.LPDDR5X_Lite sim` | [open_ip_LPDDR5X_Lite.zip](releases/open_ip_LPDDR5X_Lite.zip) |
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
| HDCP 2.3 (Content Protection) ⚠️¹ | `make -f Makefile.HDCP_2_3_Content_Protection sim` | [open_ip_HDCP_2_3_Content_Protection.zip](releases/open_ip_HDCP_2_3_Content_Protection.zip) |
| HDMI 2.1 | `make -f Makefile.HDMI_2_1 sim` | [open_ip_HDMI_2_1.zip](releases/open_ip_HDMI_2_1.zip) |
| I2S | `make -f Makefile.I2S sim` | [open_ip_I2S.zip](releases/open_ip_I2S.zip) |
| I2S Audio | `make -f Makefile.I2S_Audio sim` | [open_ip_I2S_Audio.zip](releases/open_ip_I2S_Audio.zip) |

### Ethernet & networking (8)

| Protocol | Build | Standalone package |
|---|---|---|
| Ethernet | `make -f Makefile.Ethernet sim` | [open_ip_Ethernet.zip](releases/open_ip_Ethernet.zip) |
| Ethernet AVB/TSN | `make -f Makefile.Ethernet_AVB_TSN sim` | [open_ip_Ethernet_AVB_TSN.zip](releases/open_ip_Ethernet_AVB_TSN.zip) |
| Ethernet PCS (802.3 cl. 119, 400GBASE-R: 256b/257b, scrambler, AM, FEC interleave) | `make -f Makefile.Ethernet_PCS sim` | [open_ip_Ethernet_PCS.zip](releases/open_ip_Ethernet_PCS.zip) |
| Ethernet RS(544,514) FEC (KP4, 100G..1.6T) | `make -f Makefile.Ethernet_RS_FEC sim` | [open_ip_Ethernet_RS_FEC.zip](releases/open_ip_Ethernet_RS_FEC.zip) |
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

### Security & crypto (4)

| Protocol | Build | Standalone package |
|---|---|---|
| CSE | `make -f Makefile.CSE sim` | [open_ip_CSE.zip](releases/open_ip_CSE.zip) |
| Crypto (Security Engine) | `make -f Makefile.Crypto___Security_Engine sim` | [open_ip_Crypto___Security_Engine.zip](releases/open_ip_Crypto___Security_Engine.zip) |
| ML-KEM (FIPS 203 post-quantum KEM) | `make -f Makefile.ML_KEM sim` | [open_ip_ML_KEM.zip](releases/open_ip_ML_KEM.zip) |
| Root of Trust (lifecycle, secure boot, DICE key) | `make -f Makefile.Root_of_Trust sim` | [open_ip_Root_of_Trust.zip](releases/open_ip_Root_of_Trust.zip) |

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

> ¹ **HDCP 2.3 requires a separate license from DCP LLC for any commercial
> implementation** — this repository contains no such license and no device
> keys. See [Protocol licensing notice](#protocol-licensing-notice-important).

## Design organization: cores vs. variants

The catalog has **125 entries, each with its own RTL core** in
`rtl/<P>_top.sv`. Up to v2.5.1, 29 entries were byte-level renamed copies of
5 shared templates (CHI, UART, CAN, the 2-wire serial shifter and the frame
echo template). All of them have since been rewritten as implementations of
their own protocol, each with its own testbench and checker; no two cores
share more than about 20% of their statements now (checked 2026-10-24 by a
statement-level diff of every former cluster).

The one family that still shares structure is memory: the 20 DRAM
controllers (DDR, DDR4-7, LPDDR, LPDDR4-7, LPDDR5X, GDDR5-7, HBM, HBM2-5,
HBM3E) are separate files, but grew from one controller design and are
80-95% statement-identical within a sub-family; they differ in timing, bank
and channel count and command encoding. The 4 Lite cores (DDR4_Lite,
LPDDR5X_Lite, HBM3E_Lite, GDDR7_Lite) are a second, larger design (see
[docs/DDR_Lite_NOTES.md](docs/DDR_Lite_NOTES.md)). A bug in one memory
controller is therefore likely to exist in its siblings. The retired shared
cores `MEMCH` / `MEMCORE` have been removed (see git history).

Note the distinction from *same-family different implementations*, which are
**not** counted as clones: e.g. `RFFE` vs `MIPI_RFFE`, `SPMI` vs `MIPI_SPMI`,
`I3C` vs `MIPI_I3C`, `USB` vs `USB2` vs `USB2_0`, `SD` vs `SDIO` vs `eMMC`,
`SAS` vs `SAS_4` vs `SATA` vs `UFS` — these share a protocol family but have
substantively different RTL (100+ differing statements each).

## Setup

Tested on a clean Ubuntu 24.04 container. Versions used for the published results:

| Tool | Version | Needed for |
|---|---|---|
| Icarus Verilog | 12.0 | `make sim`, `make apb`, CI |
| Yosys | 0.33 | `make syn`, `make apb`, CI |
| Verilator | 5.052 | coverage flow (`scripts/cov/`) only |
| Python 3 + `pyslang` 12.0.0 | 3.10+ | coverage flow (FSM cover generation), APB generator |

```sh
# Icarus Verilog + Yosys (what CI installs); needs root
sudo sh setup_tools.sh         # or: sudo apt-get install -y iverilog yosys

# Verilator 5.052: distribution packages are too old (Ubuntu 24.04 ships 5.020,
# which silently drops covergroups), so build it from source (~25 min on 4 cores)
sudo apt-get install -y git make autoconf g++ flex bison libfl-dev help2man python3
git clone -b v5.052 --depth 1 https://github.com/verilator/verilator.git
cd verilator && autoconf && ./configure && make -j"$(nproc)" && sudo make install && cd ..

# Python dependency of scripts/cov/ and scripts/apb/
pip install pyslang==12.0.0    # add --break-system-packages on a PEP 668 distro, or use a venv
```

`scripts/cov/run_cov.sh` refuses to run with a Verilator older than 5.052 or
without `pyslang`.

## Quick start

```sh
# simulate one protocol (Icarus Verilog, SystemVerilog 2012)
make -f Makefile.I2C sim        # -> TEST PASSED: I2C

# synthesize one protocol (Yosys)
make -f Makefile.I2C syn        # -> 0 errors, cell count report

# APB4 register wrapper: wrapper test + synthesis
make -f Makefile.I2C apb        # -> TEST PASSED: I2C_apb

# pin-level functional test, where tb/func has one (the TB plays the device)
make -f Makefile.DDR4 func      # -> TEST PASSED: DDR4_func

# full regression (what CI runs): sim + syn + apb (+ func) for all 125 IPs, in parallel (~50 min on 4 cores)
bash scripts/ci_regression.sh   # logs in work/ci_*.log

# five-metric coverage (Verilator)
bash scripts/cov/run_cov.sh I2C        # one core  -> RESULT: CLOSED
bash scripts/cov/run_cov.sh I2C_apb    # its wrapper
bash scripts/cov/run_all.sh 4          # all 250 runs, 4 in parallel

# standalone package workflow (core + wrapper, sim / syn / apb)
unzip releases/open_ip_SAS.zip && cd open_ip_SAS && make sim
```

## Verification status

- **Five-metric closure (Verilator 5.052):** every IP's testbench reaches
  100% line, toggle, FSM, SVA and functional coverage, and so does every
  IP's APB4 register wrapper (`rtl/<P>_apb.sv`, register map in
  `docs/ip/<P>.md`): 125 cores and 125 wrappers, 250/250 closed. Results,
  exclusions and how to run: [docs/COVERAGE_CLOSURE.md](docs/COVERAGE_CLOSURE.md).
  CI runs both: `.github/workflows/regression.yml` (iverilog / yosys
  sim + syn + apb, plus a check that generated files are up to date) and
  `.github/workflows/coverage.yml` (this five-metric flow over all 250
  runs, in 8 shards; any IP that is not CLOSED fails the build).
  `.github/workflows/mutation.yml` runs `scripts/mut/run_mut.py --flow cov`
  weekly: 8 operator mutants per core (relational, logical, constant bit,
  +/-1), each run through the testbench and its checker, with every
  surviving mutant listed in the job summary.
  The v2.5.1 numbers below are the earlier four-metric flow.
- **Sign-off checks beyond coverage** (UCIe, PCIe, ML-KEM, Ethernet RS-FEC,
  Ethernet PCS, Root of Trust so far): lint, mutation, formal (bounded proofs; exhaustive checks of the
  ML-KEM and RS-FEC arithmetic and the PCS functions and gearboxes), area and logic depth, and the list of what a production
  sign-off would still need: [docs/SIGNOFF.md](docs/SIGNOFF.md).

### Earlier four-metric flow (v2.5.1)

- Constrained-random verification: **117/117 protocols closed** on all
  four coverage metrics (LINE / TOGGLE / FSM / SVA-subset assertions);
  ≈1091 provably-unreachable points waiver-listed with per-point
  justification. Master scoreboard: [docs/COVERAGE.md](docs/COVERAGE.md);
  per-wave reports: [docs/coverage/](docs/coverage/) (W1-W6)
- Simulation: **117/117 PASS** (iverilog 11.0), all testbenches
  self-checking with error injection; full regression re-run at
  integration. Verilator 5.006 coverage runs: 117/117 PASS
  (Toggle_Mode_NAND closed by tool-limitation waiver — Verilator
  BLKLOOPINIT codegen bug, functional evidence via iverilog + FSM 10/10
  + SVA 348856/348856)
- Synthesis: **117/117 PASS** (yosys 0.23), zero errors
- CRV found 16 real RTL bugs (echo-copy out-of-bounds in 11 protocols,
  serial-read LSB/MSB drive bugs, QSPI MOSI contention, CXL-family
  STP/LEN framing, SPMI bus wedge, 1-Wire reset detection, ...). In
  **v2.5.1 all 16 are fixed** (fix groups A/B/C), each proven by a
  mutant check (reverting the fix re-fails the testbench) plus full
  iverilog + Verilator-coverage regression — see the RTL bug table in
  [docs/COVERAGE.md](docs/COVERAGE.md). Post-fix CXL-family raw LINE is
  124/139 (89.2%) on all five clones (CXL was 95.7% in v2.5, clones
  89.1%): the v2.5.1 stimulus re-rolled the Verilator 5.006
  attribution-artifact region (rx_err arms now zero-attributed, lines
  159-176 waived with execution proven by shadow-verified echo frames);
  waiver-adjusted closure remains 100%
- Highlights: real AES-128 (CSE, NIST vectors) reused by HDCP 2.3;
  real SHA-256+HMAC (Crypto, RFC 4231 vectors); parameterized serial bit
  rate (`BIT_CLKS`) on SAS/SATA/SDIO/UFS/SAS-4 with functional
  coverage at BIT_CLKS=4; `ram_style="block"` attributes on large memories
- Known limitation: verification covers the open-source flow only
  (iverilog/Verilator/yosys); no commercial tools (VCS/DC) available in
  this environment

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

### Protocol licensing notice (important)

The Apache-2.0 license covers **this repository's RTL code only**. Some
protocols are additionally governed by their respective consortiums, and
**shipping a compliant product may require a separate license or membership
that this repository does not grant**:

- **HDCP 2.3** — implementing HDCP in a product requires a license from
  **DCP LLC** (https://www.digital-cp.com). This repository contains no such
  license and no HDCP device keys. The RTL here is provided for
  **education, research, and interoperability evaluation only**.
- **USB (USB 2.0/3.x/4/PD/Type-C)** — the USB-IF trademark and logo program
  is members-only; the trademark does not restrict implementing the
  protocol, but branding/certifying a product as "USB" requires USB-IF
  membership and compliance certification.
- **MIPI (CSI-2/DSI/I3C/SPMI/RFFE/UniPro/…)** — MIPI Alliance specifications
  are distributed to members; implementing the protocols is not restricted
  by trademark law, but claiming MIPI conformance requires membership.
- Similar considerations may apply to HDMI (HDMI LA), Bluetooth (Bluetooth
  SIG), CAN (ISO/Bosch), DisplayPort (VESA), JEDEC memory standards, and
  others — **it is the adopter's responsibility to obtain whatever
  protocol-level licenses their product needs**.

Nothing in this section limits your Apache-2.0 rights to the code itself.
