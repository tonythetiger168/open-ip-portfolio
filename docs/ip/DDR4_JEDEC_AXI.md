# DDR4 controller on JEDEC pins with an AXI4 subordinate port (for vendor device models such as Micron's)

Protocol IP `DDR4_JEDEC_AXI`, version 0.1. Apache-2.0.

| Item | Value |
|---|---|
| Core | `DDR4_JEDEC_AXI_top` (`rtl/DDR4_JEDEC_AXI_top.sv`) |
| Register interface | APB4 slave `DDR4_JEDEC_AXI_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5D4A0001 (code 0x5D4A, version 0.1) |
| Registers | 12 words, 0x000 to 0x02C |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 45 pass-through |

## Overview

DDR4_JEDEC_AXI_top: AXI4 subordinate DDR4 memory controller (JEDEC pins) AXI4 front end + ddr4_jedec_ctrl. Unlike DDR4_AXI (whose core keeps its own small array), the storage is the DDR4 device on the pins: a vendor model (Micron ddr4_model) or tb/ddr4_dev_model behind a PHY (tb/ddr4_phy_beh in simulation).

- AXI4: 32-bit data, IDW-bit ID, INCR / FIXED / WRAP, 1..256 beats,
AxSIZE 0..2. One write burst and one read burst in service at a time
(AW and AR independent). SLVERR for AxSIZE > 2 (no DRAM access) and for
a WLAST on the wrong beat (the burst sends nothing more: its buffered
block is dropped; blocks it already sent stay written).
- Beats are gathered into DRAM bursts (BL8 x 16*NDEV bits = BB bytes):
a write burst is issued when the next beat leaves the BB-byte block or
after the last beat; WSTRB becomes DM_n (no read-modify-write). Reads
issue one DRAM burst per BB-byte block and keep up to 4 in flight.
- The host port takes a read or a write burst per grant; a request keeps
the grant until the controller accepts it (or a write error withdraws
it), then the other side gets the next turn.

Features:

- Drives real JESD79-4 command pins (RESET_n, CKE, CS_n, ACT_n, RAS_n/A16, CAS_n/A15, WE_n/A14, BG, BA, A[13:0], ODT), so a vendor device model such as Micron's ddr4_model can sit behind the PHY. tb/ddr4_dev_model is the portfolio's stand-in and checks the same timings.
- Power-up per JESD79-4: RESET_n low, CKE low then high, tXPR, MRS MR3 MR6 MR5 MR4 MR2 MR1 MR0 (tMRD apart, tMOD after MR0), ZQCL, tZQinit, then STATUS.init_done. MR0 sets BL8, CL, WR and DLL reset; MR2 CWL; MR5 A10 enables DM_n; MR6 tCCD_L.
- Open-page policy. Per bank tRCD, tRP, tRAS, tRC, tRTP, tWR; across bank groups tRRD_S/L, tCCD_S/L, tWTR_S/L; tFAW; read-to-write turnaround. Every constraint is a down counter just wide enough for its largest load.
- All-bank REF every tREFI, with PREA first when a bank is open, then tRFC.
- Address map from the bottom bit: byte in the BL8 burst, column[9:3], BG, BA, row. Bank groups next to the column bits give a linear stream tCCD_S. The 1 GB device (8 Gb x16, 2 BG x 4 BA, 64K rows, 1K columns) aliases through the 4 GB AXI space.
- AXI4: 32-bit data, IDW-bit ID, INCR / FIXED / WRAP, 1..256 beats, AxSIZE 0..2. One write and one read burst in service at a time. Beats are gathered into DRAM bursts of 16*NDEV bytes; WSTRB becomes DM_n (no read-modify-write). Up to 4 DRAM read bursts in flight. SLVERR on AxSIZE > 2 (the DRAM is not accessed) and on a WLAST on the wrong beat (the burst's buffered block is dropped).

The AXI4 subordinate port (s_*) and the controller-to-PHY pins (p_*) pass through the wrapper unchanged; the registers only read the controller's status.
Simulation PHY: tb/ddr4_phy_beh.sv, behavioural (DQS, DQ, DM_n, CL / CWL), timed in ps. In silicon the controller would sit behind a DFI PHY.
Limits (v0.1): one request in service at a time, in order; no lookahead ACT or reordering, so latency under load is pessimistic. No auto-precharge, BC4, write leveling, read training, CRC, parity, DBI, gear-down or power-down.
Micron model: ddr4_dev_model has the pins of Micron's DDR4 model by signal name. The SoC testbench (SoC-tb-regress-builder vip/micron/) connects the Micron model instead when its files are present. Micron's license does not allow the model in this repository.

## Files

| File | Content |
|---|---|
| `rtl/DDR4_JEDEC_AXI_top.sv` | protocol core |
| `rtl/DDR4_JEDEC_AXI_apb.sv` | APB4 register wrapper (generated) |
| `tb/DDR4_JEDEC_AXI_tb.sv` | core testbench |
| `tb/DDR4_JEDEC_AXI_apb_tb.sv`, `tb/apb/DDR4_JEDEC_AXI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/DDR4_JEDEC_AXI_sva.sv`, `tb/cov/DDR4_JEDEC_AXI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/DDR4_JEDEC_AXI.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`DDR4_JEDEC_AXI_apb` has the core's parameters and passes them to `DDR4_JEDEC_AXI_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NDEV` | int | `1` |
| `IDW` | int | `4` |
| `ROWB` | int | `16` |
| `COLB` | int | `10` |
| `BGB` | int | `1` |
| `BAB` | int | `2` |
| `CL` | int | `22` |
| `CWL` | int | `16` |
| `T_RCD` | int | `22` |
| `T_RP` | int | `22` |
| `T_RAS` | int | `52` |
| `T_RC` | int | `74` |
| `T_RRD_S` | int | `9` |
| `T_RRD_L` | int | `11` |
| `T_FAW` | int | `48` |
| `T_CCD_S` | int | `4` |
| `T_CCD_L` | int | `8` |
| `T_WTR_S` | int | `4` |
| `T_WTR_L` | int | `12` |
| `T_WR` | int | `24` |
| `T_RTP` | int | `12` |
| `T_RFC` | int | `560` |
| `T_REFI` | int | `12480` |
| `T_MRD` | int | `8` |
| `T_MOD` | int | `24` |
| `T_ZQINIT` | int | `1024` |
| `T_XPR` | int | `576` |
| `T_RESET` | int | `64` |
| `T_CKE` | int | `64` |
| `DQW` | int | `16 * NDEV` |
| `BB` | int | `DQW` |

## Wrapper pins

Pins of `DDR4_JEDEC_AXI_apb`. Widths of the pass-through pins are at the default parameters.

| Pin | Dir | Width | Description |
|---|---|---|---|
| `PCLK` | input | 1 | APB clock; also the core clock |
| `PRESETN` | input | 1 | APB reset, active low; also the core reset |
| `PSEL` | input | 1 | slave select |
| `PENABLE` | input | 1 | access phase |
| `PWRITE` | input | 1 | 1 = write, 0 = read |
| `PADDR` | input | 12 | byte address; bits [1:0] must be 0 |
| `PWDATA` | input | 32 | write data |
| `PSTRB` | input | 4 | write byte strobes |
| `PRDATA` | output | 32 | read data |
| `PREADY` | output | 1 | always high in the access phase (no wait states) |
| `PSLVERR` | output | 1 | error: unmapped or misaligned address |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `s_awid` | input | 4 | protocol pin, core port `s_awid` |
| `s_awaddr` | input | 32 | protocol pin, core port `s_awaddr` |
| `s_awlen` | input | 8 | protocol pin, core port `s_awlen` |
| `s_awsize` | input | 3 | protocol pin, core port `s_awsize` |
| `s_awburst` | input | 2 | protocol pin, core port `s_awburst` |
| `s_awvalid` | input | 1 | protocol pin, core port `s_awvalid` |
| `s_awready` | output | 1 | protocol pin, core port `s_awready` |
| `s_wdata` | input | 32 | protocol pin, core port `s_wdata` |
| `s_wstrb` | input | 4 | protocol pin, core port `s_wstrb` |
| `s_wlast` | input | 1 | protocol pin, core port `s_wlast` |
| `s_wvalid` | input | 1 | protocol pin, core port `s_wvalid` |
| `s_wready` | output | 1 | protocol pin, core port `s_wready` |
| `s_bid` | output | 4 | protocol pin, core port `s_bid` |
| `s_bresp` | output | 2 | protocol pin, core port `s_bresp` |
| `s_bvalid` | output | 1 | protocol pin, core port `s_bvalid` |
| `s_bready` | input | 1 | protocol pin, core port `s_bready` |
| `s_arid` | input | 4 | protocol pin, core port `s_arid` |
| `s_araddr` | input | 32 | protocol pin, core port `s_araddr` |
| `s_arlen` | input | 8 | protocol pin, core port `s_arlen` |
| `s_arsize` | input | 3 | protocol pin, core port `s_arsize` |
| `s_arburst` | input | 2 | protocol pin, core port `s_arburst` |
| `s_arvalid` | input | 1 | protocol pin, core port `s_arvalid` |
| `s_arready` | output | 1 | protocol pin, core port `s_arready` |
| `s_rid` | output | 4 | protocol pin, core port `s_rid` |
| `s_rdata` | output | 32 | protocol pin, core port `s_rdata` |
| `s_rresp` | output | 2 | protocol pin, core port `s_rresp` |
| `s_rlast` | output | 1 | protocol pin, core port `s_rlast` |
| `s_rvalid` | output | 1 | protocol pin, core port `s_rvalid` |
| `s_rready` | input | 1 | protocol pin, core port `s_rready` |
| `p_reset_n` | output | 1 | protocol pin, core port `p_reset_n` |
| `p_cke` | output | 1 | protocol pin, core port `p_cke` |
| `p_odt` | output | 1 | protocol pin, core port `p_odt` |
| `p_cs_n` | output | 1 | protocol pin, core port `p_cs_n` |
| `p_act_n` | output | 1 | protocol pin, core port `p_act_n` |
| `p_ras_n` | output | 1 | protocol pin, core port `p_ras_n` |
| `p_cas_n` | output | 1 | protocol pin, core port `p_cas_n` |
| `p_we_n` | output | 1 | protocol pin, core port `p_we_n` |
| `p_bg` | output | 2 | protocol pin, core port `p_bg` |
| `p_ba` | output | 2 | protocol pin, core port `p_ba` |
| `p_a` | output | 14 | protocol pin, core port `p_a` |
| `p_wr` | output | 1 | protocol pin, core port `p_wr` |
| `p_wdata` | output | 128 | protocol pin, core port `p_wdata` |
| `p_wbe` | output | 16 | protocol pin, core port `p_wbe` |
| `p_rvalid` | input | 1 | protocol pin, core port `p_rvalid` |
| `p_rdata` | input | 128 | protocol pin, core port `p_rdata` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `s_awid` | input | 4 | pin (pass-through) |
| `s_awaddr` | input | 32 | pin (pass-through) |
| `s_awlen` | input | 8 | pin (pass-through) |
| `s_awsize` | input | 3 | pin (pass-through) |
| `s_awburst` | input | 2 | pin (pass-through) |
| `s_awvalid` | input | 1 | pin (pass-through) |
| `s_awready` | output | 1 | pin (pass-through) |
| `s_wdata` | input | 32 | pin (pass-through) |
| `s_wstrb` | input | 4 | pin (pass-through) |
| `s_wlast` | input | 1 | pin (pass-through) |
| `s_wvalid` | input | 1 | pin (pass-through) |
| `s_wready` | output | 1 | pin (pass-through) |
| `s_bid` | output | 4 | pin (pass-through) |
| `s_bresp` | output | 2 | pin (pass-through) |
| `s_bvalid` | output | 1 | pin (pass-through) |
| `s_bready` | input | 1 | pin (pass-through) |
| `s_arid` | input | 4 | pin (pass-through) |
| `s_araddr` | input | 32 | pin (pass-through) |
| `s_arlen` | input | 8 | pin (pass-through) |
| `s_arsize` | input | 3 | pin (pass-through) |
| `s_arburst` | input | 2 | pin (pass-through) |
| `s_arvalid` | input | 1 | pin (pass-through) |
| `s_arready` | output | 1 | pin (pass-through) |
| `s_rid` | output | 4 | pin (pass-through) |
| `s_rdata` | output | 32 | pin (pass-through) |
| `s_rresp` | output | 2 | pin (pass-through) |
| `s_rlast` | output | 1 | pin (pass-through) |
| `s_rvalid` | output | 1 | pin (pass-through) |
| `s_rready` | input | 1 | pin (pass-through) |
| `p_reset_n` | output | 1 | pin (pass-through) |
| `p_cke` | output | 1 | pin (pass-through) |
| `p_odt` | output | 1 | pin (pass-through) |
| `p_cs_n` | output | 1 | pin (pass-through) |
| `p_act_n` | output | 1 | pin (pass-through) |
| `p_ras_n` | output | 1 | pin (pass-through) |
| `p_cas_n` | output | 1 | pin (pass-through) |
| `p_we_n` | output | 1 | pin (pass-through) |
| `p_bg` | output | 2 | pin (pass-through) |
| `p_ba` | output | 2 | pin (pass-through) |
| `p_a` | output | 14 | pin (pass-through) |
| `p_wr` | output | 1 | pin (pass-through) |
| `p_wdata` | output | 128 | pin (pass-through) |
| `p_wbe` | output | 16 | pin (pass-through) |
| `p_rvalid` | input | 1 | pin (pass-through) |
| `p_rdata` | input | 128 | pin (pass-through) |
| `init_done` | output | 1 | STATUS |
| `n_rd` | output | 16 | N_RD[15:0] |
| `n_wr` | output | 16 | N_WR[15:0] |
| `n_err` | output | 16 | N_ERR[15:0] |
| `n_act` | output | 16 | N_ACT[15:0] |
| `n_hit` | output | 16 | N_HIT[15:0] |
| `n_ref` | output | 16 | N_REF[15:0] |
| `err_irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`DDR4_JEDEC_AXI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `s_awid`, `s_awaddr`, `s_awlen`, `s_awsize`, `s_awburst`, `s_awvalid`, `s_awready`, `s_wdata`, `s_wstrb`, `s_wlast`, `s_wvalid`, `s_wready`, `s_bid`, `s_bresp`, `s_bvalid`, `s_bready`, `s_arid`, `s_araddr`, `s_arlen`, `s_arsize`, `s_arburst`, `s_arvalid`, `s_arready`, `s_rid`, `s_rdata`, `s_rresp`, `s_rlast`, `s_rvalid`, `s_rready`, `p_reset_n`, `p_cke`, `p_odt`, `p_cs_n`, `p_act_n`, `p_ras_n`, `p_cas_n`, `p_we_n`, `p_bg`, `p_ba`, `p_a`, `p_wr`, `p_wdata`, `p_wbe`, `p_rvalid`, `p_rdata`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5D4A0001 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Controller state |
| 0x018 | N_RD | RO | core | AXI read bursts completed |
| 0x01C | N_WR | RO | core | AXI write bursts completed (B sent) |
| 0x020 | N_ERR | RO | core | SLVERR responses (AxSIZE above 2, misplaced WLAST) |
| 0x024 | N_ACT | RO | core | ACT commands issued |
| 0x028 | N_HIT | RO | core | RD / WR commands to an already open row (page hits) |
| 0x02C | N_REF | RO | core | REF commands issued |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5D4A | IP code |
| ID | 15:8 | MAJOR | RO | 0x00 | major version |
| ID | 7:0 | MINOR | RO | 0x01 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `init_done` | RO | core | 1: power-up, mode registers and ZQ calibration are done; the AXI port is served |
| N_RD | 15:0 | `n_rd` | RO | core | wraps at 0xFFFF |
| N_WR | 15:0 | `n_wr` | RO | core | wraps at 0xFFFF |
| N_ERR | 15:0 | `n_err` | RO | core | wraps at 0xFFFF |
| N_ACT | 15:0 | `n_act` | RO | core | wraps at 0xFFFF |
| N_HIT | 15:0 | `n_hit` | RO | core | wraps at 0xFFFF |
| N_REF | 15:0 | `n_ref` | RO | core | wraps at 0xFFFF |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | an AXI burst ended with SLVERR |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5D4A0001.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `init_done`; it needs no clearing.
5. Read N_RD (0x018) for the core's live `n_rd`; it needs no clearing.
6. Read N_WR (0x01C) for the core's live `n_wr`; it needs no clearing.
7. Read N_ERR (0x020) for the core's live `n_err`; it needs no clearing.
8. Read N_ACT (0x024) for the core's live `n_act`; it needs no clearing.
9. Read N_HIT (0x028) for the core's live `n_hit`; it needs no clearing.
10. Read N_REF (0x02C) for the core's live `n_ref`; it needs no clearing.
11. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.DDR4_JEDEC_AXI sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.DDR4_JEDEC_AXI syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/DDR4_JEDEC_AXI_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.DDR4_JEDEC_AXI apb` | `TEST PASSED: DDR4_JEDEC_AXI_apb`, then Yosys without `ERROR` | console, `work/DDR4_JEDEC_AXI_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh DDR4_JEDEC_AXI`<br>`bash scripts/cov/run_cov.sh DDR4_JEDEC_AXI_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/DDR4_JEDEC_AXI/score.json`, `work/cov/DDR4_JEDEC_AXI_apb/score.json` |

Expected end of a step 4 run:

```
===== DDR4_JEDEC_AXI =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/DDR4_JEDEC_AXI_tb.sv`): drives `DDR4_JEDEC_AXI_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/DDR4_JEDEC_AXI_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/DDR4_JEDEC_AXI_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/DDR4_JEDEC_AXI_sva.sv`, `tb/cov/DDR4_JEDEC_AXI_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/DDR4_JEDEC_AXI_top.sv` | pass | 150/150 | 4736/4736 (+128 excl.) | 19/19 | 55/55 | 174/174 |
| wrapper `rtl/DDR4_JEDEC_AXI_apb.sv` | pass | 26/26 | 1580/1580 (+20 excl.) | n/a | 7/7 | 37/37 |

Core TB (tb/DDR4_JEDEC_AXI_tb.sv, iverilog by default, SIM=verilator for Verilator 5.x): init (7 MRS), directed INCR / WRAP / FIXED / narrow / 256-beat bursts, data classes, the top row and last column of every bank, the aliased AXI space, AxSIZE 3..7 and WLAST errors, 400 + 400 random concurrent bursts with B / R backpressure checked against a byte reference model, a refresh with every bank closed, and a reset while running. A second device model that assumes tRCD + 4 must flag violations. Every burst prints LAT axi ddr4 R|W <cycles>.
Coverage checker tb/cov/DDR4_JEDEC_AXI_sva.sv: an independent AXI model (walkers, responses, a shadow memory checking every read byte whose write finished before the read), the status counters, and a DDR4 pin model with every JESD79-4 spacing, the power-up order, the mode register values and the refresh interval.
