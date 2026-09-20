# gem5 Co-Verification for the DDR Family

The parametric controller (DDR4/DDR5/DDR6/HBM/GDDR6/LPDDR4/5/5X/6) exposes a
gem5 DRAMCtrl-style trace port: `trace_valid`, `trace_cmd` (1=ACT, 2=RD, 3=WR),
`trace_addr`. Capture it in TB via `$display("%0d 0x%04h", trace_cmd, trace_addr[15:0])`
into `rtl_trace.txt`.

## Flow
1. Build gem5 with DRAM trace support:
   `scons build/X86/gem5.opt --trace-flags=DRAM`
2. Run the same access sequence through gem5 (`ddr_gem5.py`), generating
   `m5out/dramctrl.trace`.
3. Compare: `python3 gem5/compare_trace.py rtl_trace.txt m5out/dramctrl.trace`

## Semantics
Single-bank RTL vs full bank-group gem5 timing WILL differ; the check compares
activate/rd/wr ADDRESS SETS, which must match for identical access streams.
gem5 mainline has no DDR6/LPDDR6/HBM-per-pseudo-channel device; use the closest
(DDR4_2400_8x8 / LPDDR4) with matching geometry, or add a custom DRAMSim-style
device in gem5's DRAMCtrl.py.
