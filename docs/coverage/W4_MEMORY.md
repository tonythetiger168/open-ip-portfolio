# W4 Memory Family — v2.5 CRV Coverage Notes

Scope: DDR, DDR4-DDR7, DFI_5_0__MC_PHY_Interface_, GDDR5-GDDR7, HBM/HBM2-HBM5,
LPDDR/LPDDR4-LPDDR7, ONFI, Toggle_Mode_NAND (23 protocols).

## FSM probe paths
- MEMCH wrappers (20 protocols): `<P>_top` has no state register; the command
  FSM is MEMCORE_top.dstate (7 states D_IDLE..D_PRE), probed as
  `dut.core.g_ch[0].g_drv.core.dstate` (MEMCH channel-0 generate scope).
- DFI: `dut.init_st` (3) + `dut.lp_st` (4). ONFI: `dut.tstate` (3) + `dut.rstate` (2).
  Toggle_Mode_NAND: `dut.state` (10).

## Results (make -f Makefile.<P> sim = iverilog; run_cov.sh = Verilator)
- 20 MEMCH protocols: iverilog PASS, Verilator PASS, FSM 7/7, SVA all-pass.
  Waivers below. (DDR e.g. LINE 17/18 TOGGLE 141/149; DDR5 17/18 159/165;
  HBM4 17/18 383/389; LPDDR6 19/20 166/174.)
- DFI_5_0: PASS/PASS, FSM 7/7, SVA all-pass, LINE 6 + TOGGLE 5 waivers.
  run_cov.sh needs `VERILATOR_TEST_FLAGS="--prefix VDFI_5_0__MC_PHY_Interface__tb"`
  (Verilator mangles `__` to `_05F`, breaking the generated sim_main include).
- ONFI: iverilog PASS. Verilator: see RISK-1.
- Toggle_Mode_NAND: iverilog PASS, FSM 10/10, SVA all-pass. Verilator sim FAILS:
  see BLOCKER-1.

## Waivers (all MEMCH protocols, structural)
1. `addr[16:14]` / `addr_full[16:14]`: ROWW=14 < AW=17, upper bits tied 0.
2. `dqs[1:0]` (toggle + the dqs inout port line): tied Hi-Z in the
   educational MEMCORE model.
3. `trace_cmd[2]`: only command codes 1..3 exist.
4. NCH=1 only (DDR/DDR4/GDDR5/LPDDR): `haddr[8]`, `trace_addr[8]` — channel
   select must be 0 (see BUG-MEMCH-1), so the bit cannot toggle legally.
5. LPDDR5/5X `ca[6]`, LPDDR6/7 `ca[7:6]`: constant-0 padding in CA encoding.
DFI line waivers: 159/162/163 (if-attribution artifact, both branches proven
executed), 166/201 (dead default arms), 240 (constant `unused` wire);
toggle: `init_cnt[7:5]` (cnt only 0..31), `lp_cnt[1]` (cnt only 0..1), `unused`.

## Suspected RTL bugs (recorded, NOT fixed)
- BUG-MEMCH-1 (v2.5.1 candidate): rtl/MEMCH_top.sv:77-82 — output muxes
  (hready/hdone/hrdata/trace_*) index per-channel arrays with haddr[8+:CHW]
  even when NCH==1; driving haddr[8]=1 is an out-of-bounds read (sim hang
  under Verilator; potential X-propagation at gate level). Legal
  single-channel traffic keeps the bit 0, so it never triggers in practice.
- BUG-ONFI-1: rtl/ONFI_top.sv:196-197 — echo-copy loop
  `for (i=2; i<HB+MAXB+6; i++) tx_mem[i-2] <= buf_mem[i]` writes tx_mem[0..19]
  into tx_mem[0:15]; Verilator masks indices, clobbering tx_mem[0..3] with
  buf_mem[18..21] (CRC bytes when plen=8, stale bytes otherwise) -> echo
  header bytes 0-3 corrupted. Same template family as W2/W5 findings.
  TB predicts actual echo with a shadow model (exp_txm/sh_buf in ONFI_tb).
  Repro: send any plen=8 frame; echo hdr[0..3] == sent CRC bytes.

## Tool workarounds
- BLKLOOPINIT (NBA-to-array in for-loops, MEMCORE/NAND reset loops):
  `VERILATOR_TEST_FLAGS="-Wno-BLKLOOPINIT"` (env injection; infra untouched).
- Double-underscore protocol name: `--prefix` flag (above).
- Oversized 16-bit literals in 15 directed TBs (e.g. 16'h111101): iverilog
  silently truncated, Verilator rejects; replaced with the explicit truncated
  values — behavior identical (both write and compare used the same literal).
- Reset SVA sampling race: rst_n dropping mid-timestep at a posedge samples
  pre-async-clear values; reset checks are gated with rst_cyc>=1 (generic
  pattern, recommended for COVERAGE.md methodology).
- Toggle_NAND/ONFI read sampling: level-synced (drive_en wait) sampling is
  skew-immune vs Verilator resume lag.

## BLOCKER-1: Toggle_Mode_NAND under Verilator 5.006 --timing
Sim hits a scheduler-corruption region from t=0: NBA-to-array loop writes
(reset FF fill, program &=merge, erase fill, pbuf load) are silently DROPPED
(mem reads back 00 right after reset; probe: dut.mem[0]==8'h00 @80ns).
Scalar NBA/FSM logic unaffected (FSM 10/10, SVA 349k/349k pass). Region
"heals" later (CRV-phase array writes work; only 1/300 read compares fail).
iverilog run is fully clean; isolated repros of the same constructs pass ->
contextual Verilator 5.006 bug (failure-mode-1/3 family), not an RTL/TB
defect. Trigger is NOT the timeout coroutine (removal tested, no change).

## RISK-1: ONFI Verilator run status
iverilog PASS; Verilator build clean; run hit the 20 ms chunked timeout
with 0 errors and sim-time inflation (same pathology family). Timeout raised
to 200 ms (10 us chunks); a confirming run was still pending at handoff.
