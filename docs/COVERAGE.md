# v2.5 Coverage Methodology & Scoreboard

Constrained-random verification with four coverage metrics per DUT:
**line**, **toggle**, **FSM**, **assertion (SVA-subset)**.
Target 100% per metric; provably-unreachable points are listed in
`scripts/verilator_cov/waiver.vc` and counted as closed below.

## Toolchain (validated 2026-09-19/20, Verilator 5.006 + iverilog 11)

| metric | source |
|---|---|
| line | Verilator `--coverage`, `coverage.dat` → `verilator_coverage --write-info` → DA records for the DUT source only |
| toggle | `v_toggle/<DUT>` points in `coverage.dat` (count 0 = un-toggled) |
| FSM | TB-side hierarchical probe of the DUT state register under `` `ifdef VERILATOR ``; per-clock visited-state bitmap; end-of-test prints `FSM_COV: <visited>/<total>` |
| assertion | counted immediate assertions (`sva_check` task) + output invariants, sampled pre-NBA every clock; prints `SVA_CHECKS: <passed>/<total>`. Verilator 5.006 has no SVA coverage engine — this is assertion coverage, not formal SVA coverage. |

Run per protocol:

```sh
bash scripts/verilator_cov/run_cov.sh <PROTO>   # build+run+4-metric summary
make -f Makefile.<PROTO> sim                    # iverilog regression (must stay PASS)
```

## Verilator 5.006 compatibility notes (hard-won, apply to ALL waves)

1. **Timing-scheduler corruption: no long-pending `#delay` events.**
   Root cause verified with minimal repros: with `--timing`, a single
   long-pending delay event (e.g. a `#40_000_000` TB timeout guard)
   sitting in the delay heap while thousands of short-delay resumptions
   interleave eventually corrupts the heap — processes silently lose
   wakeups and the long event fires early (observed deterministically
   after ~4k short suspensions / ~1.3 ms of activity; a no-task,
   no-clock repro fails the same way, and a 100k-iteration run is clean
   once the long event is removed). **Workaround: chunk every long wait**
   (`repeat (40000) #1000;` instead of `#40_000_000;`) so all heap
   entries stay short-lived. Task-based TB structure is fine after
   chunking — no inlining needed.
2. `randomize()` runs but **ignores `constraint` blocks** → all
   constrained randomness uses `$urandom_range` + rejection sampling.
3. Comments starting with the word "Verilator" are parsed as
   `/*verilator ...*/` metacomments → never begin a comment line with it.
4. `tri`/inout open-drain buses (I2C) simulate correctly with TB-side
   pullup modeling (`tri1` + `? 1'b0 : 1'bz` drivers); no workaround
   needed in the pilots.
5. Line-coverage attribution artifact: statements inside `always_ff`
   around unrolled `for`-loop memory writes and multi-line `if`
   conditions get DA counts shifted to neighboring lines (repro:
   executed strobe-memwrite reports DA 0). Such lines are waiver-listed
   only with independent functional proof of execution.
6. `parse_cov.py` page filtering: `v_branch` entries must not bleed
   into the toggle tally (fixed 2026-09-20).

All workarounds are TB-side, `` `ifdef VERILATOR ``-guarded; the iverilog
path is byte-identical (verified: zero baseline lines removed vs the
v2.4 repo TBs) and stays green.

## Scoreboard

### W0 pilots

| Protocol | iverilog sim | Verilator run | LINE | TOGGLE | FSM | SVA_CHECKS | status |
|---|---|---|---|---|---|---|---|
| I2C  | PASS | PASS | 87/88 (98.9%) | 56/57 (98.2%) | 7/7 | 2817981/2817981 | **closed (2 waivers)** |
| AXI4 | PASS | PASS | 142/150 (94.7%) | 345/345 (100%) | 5/5 | 113557/113557 | **closed (8 line waivers)** |

CRV stimulus summary:
- I2C: 200 random txns (75 write + rx_byte read-back compare, 82 read
  vs tx_byte, 43 wrong-address NACK checks; random data covers MSB 0/1).
- AXI4: 220 random txns (111 wr / 109 rd; okay=109 slverr=58 decerr=53
  address classes) with random len (1..16 plus >15 DECERR violations),
  random burst type (INCR/FIXED/WRAP/reserved), random ID, random size,
  5 address classes (in-range/boundary/oob/oob-high-bits/misaligned),
  per-beat random strobes, random W/B/R backpressure; scoreboard memory
  model compare. Plus 2 targeted max-length (len=0xA5) violation bursts
  for deterministic high-bit toggle closure.

### Waivers applied (see scripts/verilator_cov/waiver.vc for full text)

| ID | File:line | Point | Justification |
|---|---|---|---|
| i2c-line-1 | rtl/I2C_top.sv:132 | `if (state == ST_TXACK)` | condition is constant-true inside the `case (state) ST_TXACK:` arm; Verilator const-folds it, coverpoint unhittable. Body lines 133-135 covered (4 hits, multi-byte-read re-entry) |
| i2c-toggle-1 | rtl/I2C_top.sv:41 | `bit_cnt[3]` toggle | bit counter wraps at 4'd7; bit 3 never set by any reachable stimulus |
| axi4-line-1 | rtl/AXI4_top.sv:130-133 | strobe `for`-loop mem write | 5.006 attribution artifact (counts shifted to adjacent lines). Execution proven by 100+ scoreboard read-back compares (incl. partial-strobe bytes) and a minimal repro |
| axi4-line-2 | rtl/AXI4_top.sv:141,143 | early/missing-wlast SLVERR assignment | same artifact family (multi-line `if`; line 142 not instrumented at all). Execution proven by directed check 8: bresp=SLVERR + irq can only come from line 143 |
| axi4-line-3 | rtl/AXI4_top.sv:155 | `default: wstate <= W_IDLE` | dead: `wstate` is 2-bit with all 3 used encodings cased; value 3 unreachable |
| axi4-line-4 | rtl/AXI4_top.sv:210 | `default: rstate <= R_IDLE` | dead: `rstate` is 1-bit; both encodings cased explicitly |

AXI4 toggle: initially 72.2% with misses only in high address bits
[31:15], len/beat-counter bits [7:4], and size bits [0]/[2]; closed to
100% by adding out-of-range high-bit addresses, len>15 DECERR bursts,
and size≠2 transactions to the CRV mix (no waivers needed).

### Wave progress

- [x] W0 infrastructure: `scripts/verilator_cov/` (sim_main template,
      run_cov.sh, parse_cov.py, waiver.vc).
- [x] W0 pilots: I2C and AXI4 closed (4-metric loop + waiver list).
- [ ] W1 AMBA (9) … W7 rest (38): per SPEC_V25_CRV.md wave plan.

## FSM probe details

- **I2C**: `dut.state` (ST_IDLE..ST_IGNORE, 7 states), `fsm_seen` bitmap
  sampled every clock; directed multi-byte reads + CRV mix visit all 7.
- **AXI4**: `dut.wstate` (W_IDLE/W_DATA/W_RESP) + `dut.rstate`
  (R_IDLE/R_DATA), 5 states total, all visited.
