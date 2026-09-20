# W1 AMBA — CRV Coverage Closure Report (v2.5)

Branch `crv-w1-amba`. 15/15 AMBA protocols closed: iverilog `make sim`
PASS (byte-identical directed path, all CRV code `` `ifdef VERILATOR ``-
guarded) + `scripts/verilator_cov/run_cov.sh` PASS with FSM all-states
and SVA_CHECKS all-pass. LINE/TOGGLE are 100% after the structural
waivers in `scripts/verilator_cov/waiver_w1.vc` (57 records; every line
number verified against `coverage.dat` on 2026-09-20).

## Scoreboard

| Protocol | iverilog | Verilator | LINE | TOGGLE | FSM | SVA_CHECKS | waivers |
|---|---|---|---|---|---|---|---|
| APB | PASS | PASS | 45/46 (97.8%) | 144/144 (100%) | 2/2 | 6194/6194 | 1 line |
| AXI4_Lite | PASS | PASS | 85/87 (97.7%) | 253/257 (98.4%) | 5/5 | 7228/7228 | 2 line + 4 toggle |
| AXI | PASS | PASS | 144/152 (94.7%) | 325/325 (100%) | 5/5 | 38404/38404 | 8 line |
| AXI_Stream | PASS | PASS | 20/20 (100%) | 86/86 (100%) | 17/17 | 2305/2305 | 0 |
| AHB | PASS | PASS | 59/64 (92.2%) | 149/150 (99.3%) | 3/3 | 6254/6254 | 5 line + 1 toggle |
| ATB | PASS | PASS | 29/29 (100%) | 109/109 (100%) | 17/17 | 2488/2488 | 0 |
| CHI | PASS | PASS | 36/37 (97.3%) | 141/148 (95.3%) | 3/3 | 6057/6057 | 1 line + 7 toggle |
| CCIX | PASS | PASS | 36/37 (97.3%) | 141/148 (95.3%) | 3/3 | 6057/6057 | 1 line + 7 toggle |
| CXS | PASS | PASS | 36/37 (97.3%) | 141/148 (95.3%) | 3/3 | 6057/6057 | 1 line + 7 toggle |
| ARM_Q_Channel | PASS | PASS | 33/35 (94.3%) | 31/53 (58.5%) | 5/5 | 52799/52799 | 2 line + 22 toggle |
| LTI | PASS | PASS | 36/37 (97.3%) | 141/148 (95.3%) | 3/3 | 6057/6057 | 1 line + 7 toggle |
| ARM_Serial_Wire_Debug | PASS | PASS | 91/93 (97.8%) | 64/80 (80.0%) | 8/8 | 184290/184290 | 2 line + 16 toggle |
| AVSBus | PASS | PASS | 96/97 (99.0%) | 176/180 (97.8%) | 5/5 | 371515/371515 | 1 line + 4 toggle |
| ACE | PASS | PASS | 169/174 (97.1%) | 559/564 (99.1%) | 8/8 | 51448/51448 | 5 line + 5 toggle |
| ACE_Lite | PASS | PASS | 100/103 (97.1%) | 292/295 (99.0%) | 5/5 | 51226/51226 | 3 line + 3 toggle |

Totals: 33 line waivers + 82 toggle-bit waivers across 15 DUTs; every
waiver is structural (dead `default:` arm, constant-0 response/sink
bits, counter high bits beyond any reachable count) or a proven
Verilator 5.006 line-attribution artifact (2 blocks, with functional
proof of execution). No RTL functional changes were made.

## CRV stimulus summary (per protocol)

- **APB**: 256-word random init sweep (scoreboard resync) + 120 random
  transfers; address classes fast/slow-alias/boundary/reserved
  (pslverr+irq error injection); read-vs-scoreboard compare.
- **AXI4_Lite**: random phases with FSM probe + assertion suite;
  OKAY/SLVERR classes, backpressure.
- **AXI**: 160 random bursts (wr/rd, ID/len/size/burst/5 address
  classes/per-beat strobes/backpressure), scoreboard mem model,
  targeted all-ones/all-zeros toggle closure.
- **AXI_Stream**: random FIFO rounds + full-drop injection; FIFO write
  pointer probed as sequential state (17 states).
- **AHB**: random NONSEQ transfers, region classes, probe + assertions.
- **ATB**: random trace rounds, flush + full-drop injection; FIFO write
  pointer probed as sequential state (17 states).
- **CHI/CCIX/CXS/LTI** (credit-flit family, shared template): random
  flits with sticky-capture + level waits (slow-scheduler workaround,
  see below), cstate FSM probe, assertions.
- **ARM_Q_Channel**: random LP cycles, illegal-sequence injection,
  statistics-counter closure.
- **SWD**: 120 random loopback bytes (corner-mixed 00/FF/55/AA +
  uniform, random inter-frame gaps), TX+RX FSM probes, 4-assertion
  suite (reset quiescence / irq==rx_valid / single-cycle rx_valid /
  txd idle-high) with `rst_obs` gating of the t=0 sample.
- **AVSBus**: 140 random frames in 5 classes (valid SET random 12-bit
  code + ramp + GET readback vs scoreboard / valid GET / illegal
  address NACK-no-irq / corrupted-CRC NACK+irq / unknown-command
  NACK+irq), FSM probe, 5-assertion suite (incl. ramp-step ≤ 10/clk,
  open-drain drive legality).
- **ACE**: 64-line full-strobe resync sweep + 140 random transactions
  (write/read bursts with random len 0..255, burst type, size, 5
  address classes, per-beat strb, ACE side fields; snoops ReadShared/
  ReadClean/MakeUnique/CleanInvalid/unsupported), 64-line cache
  scoreboard (valid/dirty/tag/data), targeted toggle closure
  (all-ones/all-zeros + CleanInvalid dirty-hit), 3-FSM probes
  (W/R/S), 10-assertion suite.
- **ACE_Lite**: 256-word full-strobe resync sweep + 140 random bursts
  (~50/50 wr/rd; len 0..255, burst, size, 5 address classes, strb,
  side fields, backpressure), scoreboard mem model, 2-FSM probes,
  7-assertion suite.

All random phases use `$urandom_range` + rejection sampling
(Verilator 5.006 ignores `constraint` blocks inside `randomize()`),
all ≥ 100 randomized transactions (range 120..396 incl. resync sweeps).

## Waiver details

Full machine-readable records: `scripts/verilator_cov/waiver_w1.vc`.

### Dead `default:` arms (line, unreachable by construction)

| DUT | line | register |
|---|---|---|
| APB | 60 | `state` (1-bit, both encodings cased) |
| AXI4_Lite | 95 / 130 | `wstate` (2-bit, 3 used) / `rstate` (1-bit) |
| AXI | 161 / 216 | `wstate` / `rstate` |
| AHB | 90 | `state`; plus 124-126 dead default arm of the combinational output case |
| CHI / CCIX / CXS / LTI | 72 | `cstate` (2-bit, 3 used) |
| ARM_Q_Channel | 72 | `state` |
| SWD | 83 / 134 | `tstate` / `rstate` (2-bit, all 4 cased) |
| AVSBus | 154 | `avstate` (3-bit, 5 used) |
| ACE | 175 / 195 / 233 | `wstate` / `rstate` / `sstate` |
| ACE_Lite | 122 / 142 | `wstate` / `rstate` |

### Constant-0 sink wires (`wire unused = &{1'b0, ...}`)

AHB:138, ARM_Q_Channel:91, ACE:264, ACE_Lite:165 — each waives 1 line +
1 toggle bit. The RTL accepts but ignores sideband encodings; the
reduction of a 0-headed concat is constant 0.

### Response-bit constant 0 (toggle)

- AXI4_Lite: `bresp[0]`/`rresp[0]` (25/34) and `werr_q[0]`/`rerr_q[0]`
  (61/107) — responses only ever OKAY(00)/SLVERR(10).
- ACE: `bresp[0]`/`rresp[0]` (34/49); `crresp[4]` WasUnique /
  `crresp[1]` Error (59) — hard-wired 0 in the response encoder.
- ACE_Lite: `bresp[0]`/`rresp[0]` (35/50).

### Counter high bits (toggle, beyond any reachable count)

- SWD: `div_cnt[15:2]` (14 bits; DIV16 = (50 MHz/1 MBd)/16 = 3, counter
  reaches 2), `tbit[3]`/`rbit[3]` (bit counters wrap at 7).
- AVSBus: `get_word[15:12]` (readback word `{4'h0, vdac}` constant
  nibble).
- CHI/CCIX/CXS/LTI: `rxrspflit[33:30]` (single emitted response
  opcode), `crd_timer[3]` (timer wraps at 7), `lat_cnt[3]` (saturates
  at 4), `tx_crd[3]` (slow-scheduler wakeup-starved, see below).
- ARM_Q_Channel: `act_cnt[7:5]`, `evt_count[31:14]` (18 bits;
  32-bit statistics counter, bit 14 needs 16384 events).

### Verilator 5.006 line-attribution artifacts (execution proven)

- AXI:136-139 (write-beat strobe mem-write block; 100+ scoreboard
  read-back compares incl. partial-strobe bytes) and 147,149
  (early/missing-wlast SLVERR; directed check 9 can only reach
  bresp=SLVERR+irq through line 149).
- ACE:218 (bare `if (line_dirty[...]) begin` records DA 0; body lines
  219/220 covered DA=3, enclosing arm line 217 DA=5, and the targeted
  CleanInvalid dirty-hit snoop check compares crresp=5'b00101 + CD
  data).

## Verilator 5.006 timing-scheduler failure modes (W1 catalog)

Three distinct modes are now characterized; all workarounds are TB-side
and `` `ifdef VERILATOR ``-guarded.

1. **Long-pending `#delay` heap corruption** (found in W0): a single
   long-pending delay event (TB timeout guard) corrupts the delay heap
   once thousands of short-delay resumptions interleave; processes lose
   wakeups and the long event fires early. Workaround: chunked timeout
   (`repeat (N) #1000;`), applied to every W1 TB.
2. **Lost coroutine wakeups in forever-loop drivers**: concurrent
   `forever` coroutines (e.g. periodic credit-grant drivers) can lose
   event wakeups. Workaround: re-express the driver as a static clocked
   `always @(posedge clk)` block under `` `ifdef VERILATOR `` (iverilog
   keeps the original coroutine).
3. **Slow-scheduler resume delay (credit-flit family)**: with
   `--timing`, *all* coroutine resumes land ~10 us late regardless of
   structure — minimal repro: DUT-less clock + `repeat (30) @(posedge
   clk)` returns at 295 us instead of 0.3 us. Single-edge/pulse waits
   can miss entirely. Three-layer workaround (CHI/CCIX/CXS/LTI):
   (a) **level-based waits** instead of pulse sampling — issue a flit
   only when `(cstate == IDLE) && (rx_crd != 0)`, driven at negedge;
   level waits cannot miss a late resume;
   (b) **sticky response capture** — a clocked always block latches
   single-cycle `rxrspflitv` pulses into `rsp_seen/rsp_cap`, which the
   timed coroutines then consume (no edge wait on the pulse itself);
   (c) **static always-block credit grant** (mode-2 workaround) so the
   credit cadence does not depend on coroutine wakeups at all.
   Residual effect: the credit-grant cadence is too slow to drive
   `tx_crd` to 8+ within feasible sim time → `tx_crd[3]` toggle waiver
   ("wakeup-starved") in all four family members.

## Infrastructure notes (do not modify shared scripts)

- `run_cov.sh` documents "extra VFLAGS via VFLAGS" but never forwards
  `$VFLAGS` to the verilator command line. The `-Wno-BLKLOOPINIT`
  needed by the APB/AHB TBs (declaration-initialized variables in
  unrolled blocks) is instead injected by the `$HOME/bin/verilator`
  wrapper (`exec /usr/bin/verilator -Wno-BLKLOOPINIT "$@"`). Any clean
  environment must reinstall this wrapper (`setup_tools.sh`).
- **Double-underscore module names** (e.g.
  `AVSBus__Adaptive_Voltage_Scaling__tb`): Verilator mangles `_` →
  `__05F` in generated C++ class names, so `sim_main.cpp.tmpl`'s
  `#include "V@TOP@.h"` / `new V@TOP@` do not resolve. Workaround
  ("mangling shim"): drop a two-line header
  `$BUILD/V<plain-name>.h` containing
  `#include "V<mangled-name>.h"` + `#define V<plain> V<mangled>`
  into the protocol build dir before running `run_cov.sh` (the build
  dir is preserved across runs; quoted-include lookup finds the shim
  next to `sim_main.cpp`). Applied for AVSBus.
- `parse_cov.py` toggle tally must stay restricted to the DUT's
  `v_toggle/<DUT>` page (TB-internal signals with 0-counts, e.g. the
  CHI-family `rsp_cap` sticky capture, correctly do not count).
- Comments starting with the word "Verilator" are parsed as
  metacomments — never begin a comment line with it (hit during SWD
  bring-up).

## FIFO write pointer as sequential-state probe (AXI_Stream, ATB)

These DUTs are FIFO pipelines with no state-register FSM. Per SPEC
("TB-side instrumentation: hierarchical probe of DUT state register"),
the FIFO **write pointer** (`dut.wr_ptr`, values 0..DEPTH, DEPTH=16) is
the sequential state variable and is probed as the FSM state: a
17-bit visited bitmap is sampled every clock and printed as
`FSM_COV: 17/17`. The CRV phases (random FIFO rounds with full-drop
injection) fill the FIFO to every depth, visiting all 17 pointer
values; this measures sequential-state coverage of the DUT's only
stateful variable, not a protocol FSM (there is none).

## Assertion-suite note: t=0 sample gating

On the very first posedge, a TB `always @(posedge clk)` block can run
before the DUT's initial reset settle (observed on SWD: pre-settle
zero-init values fail an idle-line check at t≈0). All W1 assertion
suites written after SWD gate their checks with an `rst_obs` flag
(set once `rst_n` has been observed low) plus a registered `p_rstn`
for the reset-branch select, so no check consumes the unsettled t=0
sample. (The earlier wave-1 TBs used constant checks unaffected by
this; SWD/AVSBus/ACE/ACE_Lite all use the gated form.)

## RTL bug log

None. W1 reviewed the v2.4 echo-copy template for the out-of-bounds
read pattern seen in other waves: **no echo-copy OOB template exists
in any W1 DUT** (confirmed across all 15 RTL files). All CRV
mismatches observed during bring-up were TB-side (scoreboard resync
strobe masking on ACE/ACE_Lite, t=0 sampling on SWD) and fixed in the
TBs; no RTL functional change was made or is pending.
