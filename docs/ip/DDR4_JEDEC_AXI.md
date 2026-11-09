# DDR4 controller on JEDEC pins with an AXI4 subordinate port

Protocol IP `DDR4_JEDEC_AXI`, version 0.1. Apache-2.0.

`DDR4_AXI` keeps its storage inside a small core and has only placeholder DRAM pins. `DDR4_JEDEC_AXI` is different: it drives real JESD79-4 DDR4 command pins. The storage is a DDR4 device on those pins, so a vendor simulation model such as Micron's `ddr4_model` can sit behind it. The portfolio's own `tb/ddr4_dev_model` is the stand-in and does the same timing checks.

| Item | Value |
|---|---|
| Core | `DDR4_JEDEC_AXI_top` (`rtl/DDR4_JEDEC_AXI_top.sv`): AXI4 front end + `ddr4_jedec_ctrl` (`rtl/ddr4_jedec_ctrl.sv`) |
| Simulation PHY | `tb/ddr4_phy_beh.sv`, behavioural: DQS, DQ, DM_n, CL / CWL |
| Device stand-in | `tb/ddr4_dev_model.sv`, x16, with JEDEC timing and state checks |
| Clock | `clk` = CK (1:1). Timings are parameters in nCK |
| Defaults | DDR4-3200AA (CL 22, CWL 16, 22-22-22), 8 Gb x16 (2 BG x 4 BA, 64K rows, 1K columns), `NDEV` x16 devices side by side |

## Controller

- Init per JESD79-4: RESET_n low, then CKE low, then CKE high. After tXPR it writes MRS MR3, MR6, MR5, MR4, MR2, MR1, MR0, waiting tMRD between them and tMOD after MR0. Then ZQCL and tZQinit, and `init_done` rises.
  - MR0 sets BL8, CL, WR and DLL reset.
  - MR2 sets CWL.
  - MR5 A10 enables DM_n.
  - MR6 sets tCCD_L.
- Open-page policy. The controller enforces per-bank tRCD, tRP, tRAS, tRC, tRTP and tWR. Across bank groups it enforces tRRD_S/L, tCCD_S/L and tWTR_S/L. It also enforces tFAW and the read-to-write turnaround.
- Refresh: all-bank REF every tREFI, with PREA first when a bank is open, then tRFC.
- Address map, from the bottom bit: byte in the BL8 burst, column[9:3], BG, BA, row. Bank groups sit next to the column bits, so a linear stream alternates groups and gets tCCD_S.

## AXI4 front end

- 32-bit data and `IDW`-bit ID. INCR, FIXED and WRAP bursts of 1 to 256 beats, AxSIZE 0 to 2.
- One write burst and one read burst are in service at a time.
- Beats are gathered into DRAM bursts of 16*NDEV bytes. WSTRB becomes DM_n, so there is no read-modify-write. Up to 4 DRAM read bursts can be in flight.
- SLVERR on AxSIZE > 2 (the DRAM is not accessed) and on a WLAST on the wrong beat.
- Status outputs: `n_rd`, `n_wr`, `n_err`, `n_act`, `n_hit` (page hits), `n_ref`, `err_irq`.

## Verification

`make -f Makefile.DDR4_JEDEC_AXI sim` needs Verilator 5 with `--timing`, because the PHY and device model use timed DQS. It runs `tb/DDR4_JEDEC_AXI_tb.sv`:

- **Init:** checks that the 7 MRS writes arrive and that `init_done` rises.
- **Directed bursts:** aligned and unaligned INCR; narrow transfers with sparse strobes; WRAP 4, 8 and 16; FIXED; a 256-beat INCR; row misses.
- **Random traffic:** 400 writes and 400 reads on concurrent AW and AR threads, over a few rows per bank. Results are checked against a byte reference model. Unwritten bytes are predicted from `ddr4_dev_model.init_word`.
- **Negative checks:** AxSIZE 3 on read and write, and a misplaced WLAST, must each give SLVERR. A second device model that assumes tRCD + 4 must flag violations.
- **Refresh during traffic:** tREFI is set to 3000 so refreshes happen while traffic runs.
- **Latency:** each burst prints `LAT axi ddr4 R|W <cycles>`, the SoC TB's latency format.

Mutation check: lowering T_RCD, T_RP, T_RFC or T_WTR_L in the controller below the device's value makes the test fail.

## Limits (v0.1)

- One request is in service at a time, in order. There is no lookahead ACT or reordering, so bank-level parallelism and tFAW pressure are low, and latency under load is pessimistic.
- No auto-precharge, BC4, write leveling, read training, CRC, parity, DBI, gear-down or power-down.
- The PHY is behavioural and simulation only. In silicon the controller would sit behind a DFI PHY.

## Micron model

`ddr4_dev_model` has the same pins as Micron's DDR4 model, by signal name. The SoC testbench wrapper (SoC-tb-regress-builder `vip/micron/`) connects the Micron model instead when the model files are present. Micron's license does not allow the model in this repository.
