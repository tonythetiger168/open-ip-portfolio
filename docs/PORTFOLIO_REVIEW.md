# IP Portfolio Review (v2.1, measured rebuild)

All numbers in this document are **measured from the repository at `main` @ f8fb0f2** by `work/collect_metrics.py` (raw data: `work/metrics.json`): RTL/TB line counts and FSM enum parsing are static source analysis; cell/DFF counts come from actual `yosys` synthesis runs; sim status comes from actual `iverilog` runs of the self-checking testbenches. No hand-entered values.

## Overview

| Metric | Value |
|---|---|
| Protocols (each with `Makefile.<P>`, `rtl/<P>_top.sv`, `tb/<P>_tb.sv`, `syn/<P>_yosys.ys`) | 117 |
| Simulation (iverilog, self-checking TB) | 117/117 PASS |
| Synthesis (yosys `proc; opt; fsm; opt; memory; opt; techmap; opt; flatten`) | 117/117 OK |
| RTL carrying "IP design implementation" header marker | 48/117 |
| Total TB error checkpoints (`errors++` sites) | 820 |
| SystemVerilog assertions (`assert`) in TBs | 0 (known limitation, see below) |

## Family summary

| Family | Protocols | RTL lines (top) | FSM states (sum) | TB checkpoints | yosys cells (sum) | sim | syn |
|---|---|---|---|---|---|---|---|
| AMBA | 11 | 1647 | 44 | 86 | 188757 | 11/11 | 11/11 |
| Debug & Trace | 3 | 304 | 24 | 9 | 2375 | 3/3 | 3/3 |
| Interconnect | 12 | 1546 | 40 | 102 | 207053 | 12/12 | 12/12 |
| Memory (DRAM) | 21 | 878 | 147 | 113 | 1235129 | 21/21 | 21/21 |
| Storage | 11 | 4706 | 214 | 92 | 663707 | 11/11 | 11/11 |
| USB | 9 | 3596 | 116 | 81 | 40729 | 9/9 | 9/9 |
| MIPI | 17 | 4857 | 153 | 79 | 84546 | 17/17 | 17/17 |
| Display & Video | 5 | 1599 | 53 | 63 | 11596 | 5/5 | 5/5 |
| Networking | 9 | 1717 | 24 | 44 | 40035 | 9/9 | 9/9 |
| Automotive | 4 | 1008 | 64 | 28 | 8028 | 4/4 | 4/4 |
| Telecom & Wireless | 2 | 951 | 11 | 67 | 9826 | 2/2 | 2/2 |
| Serial & Peripheral | 10 | 1381 | 49 | 37 | 8444 | 10/10 | 10/10 |
| Power | 1 | 171 | 5 | 16 | 881 | 1/1 | 1/1 |
| Security | 1 | 289 | 5 | 0 | 22171 | 1/1 | 1/1 |
| SerDes | 1 | 203 | 5 | 3 | 825 | 1/1 | 1/1 |
| **Total** | **117** | **24853** | **954** | **820** | **2524102** | **117/117** | **117/117** |

Column definitions: **RTL lines** = total lines of `rtl/<P>_top.sv`. **FSM states** = sum of member counts of all `typedef enum` declarations in the top RTL and its Makefile `DEPS` dependencies (per-enum breakdown in parentheses; `0 (no enum)` means the design uses non-enum or no explicit state encoding). **TB checks** = number of `errors++` self-checking checkpoints in `tb/<P>_tb.sv`. **Cells/DFF** = yosys `stat` on the flattened top module; DFF counts all `$_DFF*`/`$_SDFF*`/`$_FF` cell types. **SVA** = `assert` occurrences in the TB (0 everywhere: checking is done procedurally via `errors++` counters instead of concurrent assertions).

## AMBA

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| ACE | 265 | 8 (wstate_t=3, rstate_t=2, sstate_t=3) | 1/1 | 284 | 13 | 0 | 22839 | 3821 | PASS | PASS |
| ACE Lite | 166 | 5 (wstate_t=3, rstate_t=2) | 1/1 | 198 | 6 | 0 | 27716 | 8246 | PASS | PASS |
| AHB | 140 | 3 (state_t=3) | 3/1 | 190 | 2 | 0 | 25737 | 8206 | PASS | PASS |
| APB | 107 | 2 (state_t=2) | 3/0 | 189 | 2 | 0 | 25729 | 8205 | PASS | PASS |
| AXI | 262 | 5 (wstate_t=3, rstate_t=2) | 3/1 | 356 | 20 | 0 | 28620 | 8292 | PASS | PASS |
| AXI4 | 256 | 5 (wstate_t=3, rstate_t=2) | 3/1 | 325 | 18 | 0 | 28457 | 8308 | PASS | PASS |
| AXI4 Lite | 164 | 5 (wstate_t=3, rstate_t=2) | 3/1 | 248 | 13 | 0 | 27457 | 8238 | PASS | PASS |
| AXI Stream | 43 | 0 (no enum) | 1/0 | 74 | 4 | 0 | 1677 | 517 | PASS | PASS |
| CHI | 76 | 3 (c_t=3) | 1/0 | 83 | 3 | 0 | 208 | 46 | PASS | PASS |
| ARM Local Translation Interface | 76 | 3 (c_t=3) | 1/0 | 83 | 3 | 0 | 208 | 46 | PASS | PASS |
| ARM Q Channel Low Power Interface | 92 | 5 (state_t=5) | 2/1 | 155 | 2 | 0 | 109 | 11 | PASS | PASS |

## Debug & Trace

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| ARM Serial Wire Debug | 137 | 8 (tx_t=4, rx_t=4) | 4/0 | 51 | 1 | 0 | 527 | 63 | PASS | PASS |
| ATB | 57 | 0 (no enum) | 1/0 | 75 | 5 | 0 | 1734 | 531 | PASS | PASS |
| JTAG | 110 | 16 (tap_t=16) | 4/0 | 107 | 3 | 0 | 114 | 4 | PASS | PASS |

## Interconnect

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| Avalon MM | 171 | 3 (avs_t=3) | 1/1 | 292 | 17 | 0 | 140483 | 8238 | PASS | PASS |
| Avalon ST | 39 | 0 (no enum) | 1/0 | 70 | 3 | 0 | 1677 | 517 | PASS | PASS |
| CCIX Cache Coherent Interconnect | 76 | 3 (c_t=3) | 1/0 | 83 | 3 | 0 | 208 | 46 | PASS | PASS |
| CXS CCIX Stream Interface | 76 | 3 (c_t=3) | 1/0 | 83 | 3 | 0 | 208 | 46 | PASS | PASS |
| CXL | 203 | 5 (t_t=3, r_t=2) | 6/0 | 87 | 3 | 0 | 825 | 107 | PASS | PASS |
| OCP | 148 | 4 (state_t=4) | 1/1 | 256 | 13 | 0 | 26787 | 8230 | PASS | PASS |
| OCP IP Open Core Protocol | 194 | 6 (ocp_t=6) | 1/0 | 362 | 18 | 0 | 1599 | 320 | PASS | PASS |
| PCIe | 203 | 5 (t_t=3, r_t=2) | 6/0 | 87 | 3 | 0 | 825 | 107 | PASS | PASS |
| TileLink (TL UL TL C) | 124 | 2 (tls_t=2) | 1/0 | 260 | 18 | 0 | 6868 | 2095 | PASS | PASS |
| UALink | 76 | 3 (c_t=3) | 1/0 | 83 | 3 | 0 | 208 | 46 | PASS | PASS |
| UCIe | 76 | 3 (c_t=3) | 1/0 | 83 | 3 | 0 | 208 | 46 | PASS | PASS |
| Wishbone | 160 | 3 (svc_t=3) | 1/0 | 244 | 15 | 0 | 27157 | 8294 | PASS | PASS |

## Memory (DRAM)

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| DDR | 31 | 7 (d_t=7) | 0/0 | 131 | 21 | 0 | 13756 | 4203 | PASS | PASS |
| DDR4 | 28 | 7 (d_t=7) | 0/0 | 52 | 1 | 0 | 13756 | 4203 | PASS | PASS |
| DDR5 | 28 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 27454 | 8375 | PASS | PASS |
| DDR6 | 28 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 27454 | 8375 | PASS | PASS |
| DDR7 | 28 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 27454 | 8375 | PASS | PASS |
| GDDR5 | 28 | 7 (d_t=7) | 0/0 | 52 | 1 | 0 | 13756 | 4203 | PASS | PASS |
| GDDR6 | 28 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 27452 | 8375 | PASS | PASS |
| GDDR7 | 28 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 27452 | 8375 | PASS | PASS |
| HBM | 28 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 109713 | 33407 | PASS | PASS |
| HBM2 | 33 | 7 (d_t=7) | 0/0 | 150 | 23 | 0 | 109713 | 33407 | PASS | PASS |
| HBM3 | 28 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 109713 | 33407 | PASS | PASS |
| HBM3E | 28 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 109713 | 33407 | PASS | PASS |
| HBM4 | 28 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 219310 | 66783 | PASS | PASS |
| HBM5 | 28 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 219310 | 66783 | PASS | PASS |
| LPDDR | 32 | 7 (d_t=7) | 0/0 | 131 | 21 | 0 | 13756 | 4203 | PASS | PASS |
| LPDDR4 | 41 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 27402 | 8353 | PASS | PASS |
| LPDDR5 | 41 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 27402 | 8353 | PASS | PASS |
| LPDDR5X | 41 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 27402 | 8353 | PASS | PASS |
| LPDDR6 | 41 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 27402 | 8353 | PASS | PASS |
| LPDDR7 | 41 | 7 (d_t=7) | 0/0 | 73 | 3 | 0 | 27402 | 8353 | PASS | PASS |
| DFI 5 0 (MC PHY Interface) | 241 | 7 (init_t=3, lp_t=4) | 1/0 | 256 | 1 | 0 | 28357 | 8269 | PASS | PASS |

## Storage

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| eMMC | 422 | 9 (hstate_t=9) | 1/3 | 456 | 0 | 0 | 7909 | 436 | PASS | PASS |
| NVMe | 203 | 5 (t_t=3, r_t=2) | 6/0 | 87 | 3 | 0 | 825 | 107 | PASS | PASS |
| ONFI | 203 | 5 (t_t=3, r_t=2) | 6/0 | 87 | 3 | 0 | 825 | 107 | PASS | PASS |
| SAS | 521 | 53 (oob_t=5, tx_t=6, rx_t=5, sq_t=6, hob_t=7, dob_t=7, rxw_t=4, hf_t=5, df_t=8) | 6/2 | 170 | 16 | 0 | 19590 | 953 | PASS | PASS |
| SAS 4 (Serial Attached SCSI) | 665 | 25 (oob_t=5, tx_t=7, rxl_t=2, rf_t=5, sq_t=6) | 6/0 | 488 | 36 | 0 | 154976 | 1196 | PASS | PASS |
| SATA | 651 | 31 (hob_t=7, dob_t=7, rxw_t=4, hf_t=5, df_t=8) | 12/1 | 198 | 9 | 0 | 38946 | 2751 | PASS | PASS |
| SD | 520 | 12 (hstate_t=12) | 2/5 | 608 | 0 | 0 | 13344 | 554 | PASS | PASS |
| SDIO | 354 | 12 (state_t=12) | 1/0 | 376 | 21 | 0 | 89834 | 1546 | PASS | PASS |
| Toggle Mode NAND | 419 | 14 (state_t=10, op_t=4) | 2/0 | 241 | 1 | 0 | 83289 | 8758 | PASS | PASS |
| UFS | 302 | 42 (lp_e=4, rx_e=5, tx_e=2, hob_t=7, dob_t=7, rxw_t=4, hf_t=5, df_t=8) | 2/1 | 251 | 3 | 0 | 217966 | 8909 | PASS | PASS |
| UniPro Mem | 446 | 6 (rstate_t=4, tstate_t=2) | 1/0 | 379 | 0 | 0 | 36203 | 2836 | PASS | PASS |

## USB

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| USB | 593 | 15 (rs_t=7, ts_t=5, cs_t=3) | 4/1 | 410 | 1 | 0 | 3472 | 237 | PASS | PASS |
| USB2 | 678 | 19 (ch_t=4, rs_t=7, ts_t=5, cs_t=3) | 5/2 | 499 | 2 | 0 | 3711 | 267 | PASS | PASS |
| USB2 0 | 251 | 7 (tx_t=4, rx_t=3) | 5/0 | 140 | 8 | 0 | 17413 | 267 | PASS | PASS |
| USB3 | 582 | 36 (link_state_t=3, rx_state_t=15, tx_state_t=18) | 3/1 | 426 | 24 | 0 | 9658 | 2846 | PASS | PASS |
| USB3 2 | 203 | 5 (t_t=3, r_t=2) | 6/0 | 87 | 3 | 0 | 825 | 107 | PASS | PASS |
| USB4 | 203 | 5 (t_t=3, r_t=2) | 6/0 | 87 | 3 | 0 | 825 | 107 | PASS | PASS |
| USB PD | 485 | 18 (rx_st_t=5, tx_st_t=8, pe_st_t=5) | 3/0 | 334 | 16 | 0 | 1750 | 237 | PASS | PASS |
| USB Type C Port Controller | 175 | 3 (st_t=3) | 1/0 | 195 | 2 | 0 | 270 | 19 | PASS | PASS |
| eUSB2 | 426 | 8 (pstate_t=2, rstate_t=6) | 4/2 | 374 | 22 | 0 | 2805 | 168 | PASS | PASS |

## MIPI

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| CSE | 364 | 4 (cstate_t=4) | 1/0 | 177 | 0 | 0 | 31069 | 1965 | PASS | PASS |
| CSI 2 | 295 | 8 (state_t=8) | 1/0 | 247 | 3 | 0 | 18549 | 4267 | PASS | PASS |
| C PHY | 345 | 8 (tstate_t=4, rstate_t=4) | 2/1 | 328 | 1 | 0 | 2586 | 99 | PASS | PASS |
| DigRF | 94 | 4 (st_t=4) | 2/0 | 85 | 4 | 0 | 254 | 34 | PASS | PASS |
| DSI | 477 | 18 (state_t=13, rb_t=5) | 1/0 | 359 | 2 | 0 | 4023 | 464 | PASS | PASS |
| D PHY | 586 | 33 (tstate_t=18, rstate_t=15) | 2/1 | 491 | 1 | 0 | 1105 | 75 | PASS | PASS |
| HSI | 94 | 4 (st_t=4) | 2/0 | 85 | 4 | 0 | 254 | 34 | PASS | PASS |
| I3C | 113 | 7 (st_t=7) | 2/0 | 83 | 8 | 0 | 335 | 31 | PASS | PASS |
| MIPI I3C | 454 | 15 (state_t=15) | 2/0 | 276 | 8 | 0 | 2277 | 195 | PASS | PASS |
| MIPI RFFE | 268 | 7 (state_t=7) | 2/0 | 226 | 2 | 0 | 2926 | 182 | PASS | PASS |
| MIPI SLIMbus | 94 | 4 (st_t=4) | 2/0 | 85 | 4 | 0 | 254 | 34 | PASS | PASS |
| MIPI SoundWire | 94 | 4 (st_t=4) | 2/0 | 85 | 4 | 0 | 254 | 34 | PASS | PASS |
| MIPI SPMI | 307 | 8 (state_t=8) | 2/0 | 227 | 3 | 0 | 1822 | 181 | PASS | PASS |
| M PHY | 348 | 7 (tstate_t=4, rstate_t=3) | 2/1 | 283 | 1 | 0 | 1076 | 79 | PASS | PASS |
| RFFE | 94 | 4 (st_t=4) | 2/0 | 85 | 4 | 0 | 254 | 34 | PASS | PASS |
| SPMI | 105 | 6 (st_t=6) | 2/0 | 91 | 4 | 0 | 320 | 40 | PASS | PASS |
| UniPro | 725 | 12 (rxs_t=3, fstate_t=9) | 5/2 | 444 | 26 | 0 | 17188 | 1543 | PASS | PASS |

## Display & Video

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| DisplayPort2 | 726 | 32 (lt_state_t=14, pat_t=4, aux_state_t=14) | 3/3 | 630 | 30 | 0 | 2560 | 245 | PASS | PASS |
| HDCP 2 3 Content Protection | 321 | 10 (state_t=10) | 1/1 | 383 | 1 | 0 | 4203 | 563 | PASS | PASS |
| HDMI 2 1 | 306 | 7 (mode_t=7) | 1/4 | 400 | 25 | 0 | 1943 | 88 | PASS | PASS |
| MIPI DBI (Display Bus Interface) | 94 | 4 (st_t=4) | 2/0 | 85 | 4 | 0 | 254 | 34 | PASS | PASS |
| MIPI DPI (Display Pixel Interface) | 152 | 0 (no enum) | 1/0 | 302 | 3 | 0 | 2636 | 207 | PASS | PASS |

## Networking

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| Ethernet | 203 | 5 (t_t=3, r_t=2) | 6/0 | 87 | 3 | 0 | 825 | 107 | PASS | PASS |
| FC | 203 | 5 (t_t=3, r_t=2) | 6/0 | 87 | 3 | 0 | 825 | 107 | PASS | PASS |
| GMII | 77 | 0 (no enum) | 3/0 | 65 | 1 | 0 | 559 | 156 | PASS | PASS |
| Interlaken v1 2 | 203 | 5 (t_t=3, r_t=2) | 6/0 | 87 | 3 | 0 | 825 | 107 | PASS | PASS |
| MDIO | 85 | 0 (no enum) | 2/0 | 93 | 2 | 0 | 1978 | 559 | PASS | PASS |
| RGMII | 106 | 0 (no enum) | 4/0 | 66 | 1 | 0 | 833 | 229 | PASS | PASS |
| UEC | 203 | 5 (t_t=3, r_t=2) | 6/0 | 87 | 3 | 0 | 825 | 107 | PASS | PASS |
| XGMII | 96 | 0 (no enum) | 3/0 | 65 | 1 | 0 | 1779 | 203 | PASS | PASS |
| eCPRI over Ethernet | 541 | 4 (txst_t=4) | 3/4 | 412 | 27 | 0 | 31586 | 3888 | PASS | PASS |

## Automotive

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| CAN | 252 | 16 (tx_t=8, rx_t=8) | 4/0 | 76 | 7 | 0 | 2007 | 281 | PASS | PASS |
| Ethernet AVB TSN | 252 | 16 (tx_t=8, rx_t=8) | 4/0 | 76 | 7 | 0 | 2007 | 281 | PASS | PASS |
| FlexRay | 252 | 16 (tx_t=8, rx_t=8) | 4/0 | 76 | 7 | 0 | 2007 | 281 | PASS | PASS |
| LIN | 252 | 16 (tx_t=8, rx_t=8) | 4/0 | 76 | 7 | 0 | 2007 | 281 | PASS | PASS |

## Telecom & Wireless

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| Bluetooth5 | 472 | 8 (ls_t=2, rxs_t=4, txs_t=2) | 5/0 | 507 | 46 | 0 | 4635 | 645 | PASS | PASS |
| CPRI v8 0 (eCPRI over CPR) | 479 | 3 (state_t=3) | 2/3 | 519 | 21 | 0 | 5191 | 1219 | PASS | PASS |

## Serial & Peripheral

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| GPIO | 34 | 0 (no enum) | 1/0 | 75 | 4 | 0 | 65 | 16 | PASS | PASS |
| I2C | 142 | 7 (st_t=7) | 2/0 | 108 | 7 | 0 | 327 | 30 | PASS | PASS |
| I2S | 76 | 0 (no enum) | 3/0 | 78 | 3 | 0 | 245 | 104 | PASS | PASS |
| I2S Audio | 237 | 0 (no enum) | 1/1 | 248 | 2 | 0 | 2578 | 212 | PASS | PASS |
| PWM | 36 | 0 (no enum) | 1/0 | 55 | 1 | 0 | 920 | 96 | PASS | PASS |
| QSPI | 89 | 0 (no enum) | 2/0 | 102 | 3 | 0 | 180 | 32 | PASS | PASS |
| SPI | 50 | 0 (no enum) | 1/0 | 70 | 3 | 0 | 79 | 21 | PASS | PASS |
| UART | 137 | 8 (tx_t=4, rx_t=4) | 4/0 | 51 | 1 | 0 | 527 | 63 | PASS | PASS |
| WTB | 472 | 26 (rstate_t=9, tstate_t=12, sstate_t=5) | 4/2 | 305 | 9 | 0 | 2817 | 551 | PASS | PASS |
| 1 Wire | 108 | 8 (st_t=8) | 2/0 | 86 | 4 | 0 | 706 | 48 | PASS | PASS |

## Power

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| AVSBus (Adaptive Voltage Scaling) | 171 | 5 (avstate_t=5) | 1/1 | 250 | 16 | 0 | 881 | 104 | PASS | PASS |

## Security

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| Crypto (Security Engine) | 289 | 5 (sstate_t=5) | 1/0 | 211 | 0 | 0 | 22171 | 2326 | PASS | PASS |

## SerDes

| Protocol | RTL lines | FSM states (measured) | always_ff/comb | TB lines | TB checks | SVA | yosys cells | DFF | sim | syn |
|---|---|---|---|---|---|---|---|---|---|---|
| JESD204C | 203 | 5 (t_t=3, r_t=2) | 6/0 | 87 | 3 | 0 | 825 | 107 | PASS | PASS |

## Known limitations

- **No SystemVerilog assertions (SVA = 0 in every TB).** Checking is procedural: each testbench drives stimulus and increments an `errors` counter at explicit checkpoints (`errors++` + `ERROR:` messages), printing `TEST PASSED`/`TEST FAILED` at the end. Any previous SVA column in this document was fictitious and has been removed.
- **Educational slices.** The RTL is a simplified educational slice of each protocol (see the header comments in `rtl/*_top.sv`, e.g. "Educational slice of DDR5"), not a full spec-compliant implementation. 48/117 tops carry the "IP design implementation" marker; the remainder are generated simplified/reference slices (e.g. "simplified", "sink monitor with FIFO capture" style headers).
- **Toolchain boundary.** Simulation is Icarus Verilog (`iverilog -g2012`); synthesis is yosys generic `techmap` (no ASIC/FPGA library mapping, no timing). Cell/DFF counts are post-`techmap`/`flatten` generic gate counts, useful for relative size comparison only. iverilog emits harmless warnings (sized-hex truncation, missing timescale) on some TBs.
- **FSM state counting** is limited to `typedef enum` declarations in the top RTL and its direct Makefile dependencies; state machines encoded with plain `localparam` constants (if any) are not counted and show as `0 (no enum)`.

## Reproduction

```sh
sh setup_tools.sh                 # install iverilog + yosys
python3 work/collect_metrics.py   # -> work/metrics.json (sim+syn for all 117)
python3 work/build_doc.py         # regenerate this document
make -f Makefile.<P> sim          # single-protocol simulation
make -f Makefile.<P> syn          # single-protocol synthesis
```
