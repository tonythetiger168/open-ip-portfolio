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
- ONFI: iverilog PASS, Verilator TEST PASSED (RISK-1 CLOSED, see below):
  FSM 5/5, SVA_CHECKS 8561532/8561532 all-pass, LINE 123/138 (89.1%,
  15 structural waivers), TOGGLE 444/495 (89.7%, 51 structural waivers).
- Toggle_Mode_NAND: iverilog PASS, FSM 10/10, SVA all-pass. Verilator sim
  cannot model the DUT (tool bug): see BLOCKER-1 — CLOSED by
  tool-limitation waiver; line/toggle N/A (tool bug).

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
  v2.5.1 FIXED: muxes now index via `sel_c = (sel < NCH) ? sel : '0`
  (clamp into `[0:NCH-1]`); all 20 memory wrappers iverilog PASS.
- BUG-ONFI-1: rtl/ONFI_top.sv:196-197 — echo-copy loop
  `for (i=2; i<HB+MAXB+6; i++) tx_mem[i-2] <= buf_mem[i]` writes tx_mem[0..19]
  into tx_mem[0:15]; Verilator masks indices, clobbering tx_mem[0..3] with
  buf_mem[18..21] (CRC bytes when plen=8, stale bytes otherwise) -> echo
  header bytes 0-3 corrupted. Same template family as W2/W5 findings.
  TB predicts actual echo with a shadow model (exp_txm/sh_buf in ONFI_tb).
  Repro: send any plen=8 frame; echo hdr[0..3] == sent CRC bytes.
  v2.5.1 FIXED: loop bound corrected to `HB + MAXB + 2`; exp_txm shadow
  simplified to exact copy. iverilog + Verilator run_cov PASS, 4 metrics
  unchanged; mutant (revert bound) FAILs.

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

## BLOCKER-1 (CLOSED — tool-limitation waiver): Toggle_Mode_NAND under
## Verilator 5.006 --timing
ROOT CAUSE PROVEN at codegen level (2026-09-20 follow-up): the two
constant-value NBA-to-array loop fills are a documented UNSUPPORTED
construct — `%Error-BLKLOOPINIT: Unsupported: Delayed assignment to array
inside for loops (non-delayed is ok)` at rtl/Toggle_Mode_NAND_top.sv:169
(reset fill `for i<1024: mem[i] <= 8'hFF`) and :383 (erase fill
`for i<256: mem[{blk_q,i[7:0]}] <= 8'hFF`). The global `-Wno-BLKLOOPINIT`
wrapper only suppresses the error; it does NOT fix the codegen. Generated
C++ (obj/*__1.cpp) shows both loops collapse to a SINGLE delayed slot
(__Vdlyv*__mem__v65 / __v64): the while-loop overwrites one slot's
dim each iteration and the NBA commit applies exactly one element —
mem[1023] after reset, mem[{blk_q,255}] after erase; the other 1023/255
bytes keep their power-up value (read back as 00). The non-constant
program merge (line 374, `mem <= mem & pbuf`) is NOT flagged and unrolls
correctly into 64 slots (v0..v63) — which is why program/read paths work
and all 380 Verilator errors are exclusively erased-state (FF-expected)
miscompares. Not the timeout coroutine (removal tested, no change); not
--coverage (no-coverage build fails identically, 380 errors); no -fno-*
stage can add support for an intentionally-unsupported construct.

FINAL DISPOSITION — tool-limitation waiver (recorded in master
methodology, docs/COVERAGE.md):
- Functional evidence: iverilog `make sim` PASS (bit-exact reference
  semantics; RTL is IEEE-legal — no RTL/TB defect); Verilator FSM 10/10;
  Verilator SVA 348856/348856 all-pass; Verilator program/read/read-ID/
  status/protected-block/bad-command checks all pass (only constant-fill
  paths miscompare).
- line/toggle: N/A (tool bug) — metrics are collectible (LINE 223/258,
  TOGGLE 103/110 on the failing build) but the DUT's memory-array
  behavior under Verilator does not model the design, so the numbers are
  not a valid coverage statement. Protocol counts as CLOSED by waiver.

## RISK-1 (CLOSED 2026-09-20, TEST PASSED): ONFI timing under Verilator
Symptom at handoff: run hit the (20→200 ms) chunked timeout with 0 errors
and ~1000x sim-time inflation of the TB's #delay schedule. Two distinct
defects were found and fixed (both TB-side, `ifdef VERILATOR`-guarded,
iverilog path byte-identical):

1. Scheduler pathology (stall): per-#delay-resumption LAG WITH JITTER
   skewed host bit cells off the DUT's clk-exact sampling grid
   (BAUD_DIV=20) until a frame was corrupted on the wire -> rx_err, no
   echo, TB parked in recv_tlp. FIX: all host/recv timing converted to
   clock-aligned waits via `BDLY(ns)` (runtime-bound task waiting on clk
   edges under Verilator, #(ns) otherwise); recv_tlp's wait() became a
   bounded clk poll (200k clk) that reports DUT state instead of parking.
   The constant-bound repeat form explodes codegen (9.4 MB TU), so BDLY
   calls a runtime-bound task (no unrolling). bdly waits on the NEGATIVE
   edge: posedge resumptions contend with the DUT always_ff wakeups and
   intermittently land a clock late; negedge is scheduler-quiet and also
   places host drives/TB samples half a cycle off the DUT sampling grid.
2. Echo-drain race (173 deterministic errors after the stall fix — the
   true root cause of the remaining failures, proven with temporary
   probes): recv_tlp's fixed post-echo tail (BIT*40) is not cycle-exact
   against the DUT TX grid (extra T_END cell + free-running tick phase),
   so the next host frame could begin while tstate != T_IDLE; its start
   edge then fails the `rstate==R_IDLE && start_edge && tstate==T_IDLE`
   guard (rtl/ONFI_top.sv:133) and is never armed — mid-frame edges arm a
   garbage frame instead -> rx_err + no echo (13 clean frames lost this
   way; the remaining 160 errors were BUG-ONFI-1 shadow-model cascade
   from those corrupted receptions). Deterministic: identical errors across
   posedge/negedge drive variants. FIX: recv_tlp now waits for
   `dut.tstate == T_IDLE` (bounded, negedge-polled) after the echo tail —
   no host frame ever starts against a busy TX FSM.

FINAL (run_cov.sh ONFI, Verilator 5.006): TEST PASSED — directed frame +
110 CRV frames (95 ok / 15 error-injection: bad CRC/STP/END, all flagged
rx_err, none echoed) + reset recovery, all echo bytes matching the
BUG-ONFI-1 shadow prediction. FSM_COV 5/5. SVA_CHECKS 8561532/8561532
(lower than the interim 24.8M only because the 13x200k-clk no-echo
timeouts are gone). iverilog `make -f Makefile.ONFI sim` PASS
re-verified after the changes (Verilator-only edits).

Coverage gaps -> structural waivers (details in waiver_w4.vc):
- LINE 123/138: 15 uncovered = 3 dead enum default arms (tstate/rstate/
  tfld encodings fully covered by case arms) + 12 lines of the RX
  CRC-verify/rx_done block that Verilator 5.006 coverage mis-attributes
  (constant-unrolled CRC loop): the block provably executes — 96 echoes
  carried DUT-computed content matching the shadow, and rx_err was
  observed set by every injected CRC/STP/END error.
- TOGGLE 444/495: 51 zero-hit points, all structural constant bits /
  dead storage: tmr[15:5] & rtmr[15:5] (baud counters only count 0..19),
  rstate[1] (2-state enum in logic[1:0]), tlen[5] (LEN<=16), tbit[5]
  (tbit<=31), ta_cnt[3] (ta_cnt=6), ridx[5] (ridx<=22), buf_mem[0] (RX
  storage starts at index 1; [0] only reset-cleared), buf_mem[22..23]
  (array margin beyond max write index 21).
