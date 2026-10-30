# True random number generator: ring-oscillator noise source, SP 800-90B repetition count and adaptive proportion health tests with start-up test, and SHA-256 conditioning into 256-bit full-entropy seeds

Protocol IP `TRNG`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `TRNG_top` (`rtl/TRNG_top.sv`) |
| Register interface | APB4 slave `TRNG_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x54520100 (code 0x5452, version 1.0) |
| Registers | 12 words, 0x000 to 0x02C |
| Interrupts | 3 sources into one level-high `irq` |
| Data streams | ENT (from the core) |
| Protocol pins | 6 pass-through |

## Overview

TRNG_top v1.0: true random number generator in the structure of NIST SP 800-90B: a noise source, health tests on every raw sample, and a vetted conditioning function that turns the raw bits into full-entropy seeds.

- Noise source: NRO free-running ring oscillators outside the core
(ro_in, asynchronous to clk). Their XOR passes a two-flop synchronizer
and is sampled once every smp_div + 1 clocks: one raw bit per sample.
src_sel = 1 replaces it by a 32-bit Galois LFSR loaded with lfsr_seed
(bring-up and test only: deterministic, no entropy, never marked FIPS).
Every raw sample is also driven on raw_valid / raw_bit, for the offline
entropy assessment of SP 800-90B (and for an external health monitor).
- Health tests (SP 800-90B 4.4) on every raw sample while enabled:
repetition count test: a run of rct_cutoff identical samples fails;
adaptive proportion test: in each window of 2^APT_WL samples (1024),
apt_cutoff occurrences of the window's first sample value fail.
With alpha = 2^-20 and a claimed min-entropy H per bit, the cutoffs are
1 + ceil(20 / H) and 1 + CRITBINOM(1024, 2^-H, 1 - alpha): H = 0.5 gives
41 and 793 (the reset values in the APB wrapper), H = 1 gives 21 and 589.
A cutoff of 0 or 1 fails on the first sample (a forced-failure test).
- Start-up: after en rises the first window (1024 samples) is tested and
discarded; only when it passes does the core collect. A failure at any
time stops the core (state FAIL): alert pulses, alert_rct / alert_apt
stay set, the buffers are cleared and nothing more is output until en is
dropped and raised again (which reruns the start-up test).
- Conditioning (SP 800-90B 3.1.5.1.1, a vetted function): the raw bits,
first bit as the MSB of the first byte, are collected in 512-bit blocks
and hashed with SHA-256 (64 rounds, one per clock), cond_blks + 1 blocks
per seed; the 256-bit digest of those 512 * (cond_blks + 1) bits is the
seed, output as eight 32-bit words (digest word 0 first). The default of
two blocks gives 1024 raw bits, at H = 0.5 512 bits of entropy for a
256-bit output (90B full entropy needs 256 + 64). Each seed is hashed
from fresh samples; samples taken while hashing or while the seed waits
to be read are health-tested and discarded.
- cond_bypass = 1: raw bits are output unconditioned, 32 per word (first
bit at bit 31), for characterization; never marked FIPS.
- src_sel, cond_bypass and cond_blks are taken when en rises; smp_div and
the cutoffs apply at once.
- Output: ent_valid / ent_ready / ent_data, with ent_fips set on words of a
conditioned seed from the ring oscillators. seed_rdy pulses when a seed
(or bypass word) becomes available. es_fips: running (start-up passed)
in the FIPS configuration (ring oscillators, conditioned).
- Monitors: rct_fails / apt_fails count failures since reset (saturating);
rct_hw / apt_hw hold the longest run and the highest window count seen
since en rose.

Features:

- Noise source: the XOR of NRO free-running ring oscillators (asynchronous inputs ro_in, placed outside the core) through a two-flop synchronizer, sampled every smp_div + 1 clocks. Every raw sample is also on raw_valid / raw_bit (pass-through pins) for the SP 800-90B entropy assessment and an external monitor.
- SP 800-90B health tests on every raw sample: the repetition count test and the adaptive proportion test (1024-sample window), with programmable cutoffs. A start-up test runs one full window before anything is collected; a failure at any time stops the core, raises ALERT and clears the buffers until en is cleared and set again.
- Conditioning with SHA-256, a vetted function: 512 x (cond_blks + 1) raw bits per 256-bit seed (1024 by default), each seed from fresh samples. Output as eight words through ENT, with the core held off (no loss) while ENT is full.
- Test LFSR source and raw bypass for bring-up and characterization; output from either is never flagged FIPS (STATUS.es_fips, core port ent_fips).
- Monitors: failure counters per test since reset and high-water marks (longest run, highest window count) since the last start.

The health test reset values assume 0.5 bit of min-entropy per raw sample. Measure the real source (raw_valid / raw_bit, or bypass words through ENT) with the SP 800-90B tools and set HEALTH, CTRL.smp_div and CTRL.cond_blks from the assessed entropy: 256 + 64 bits of entropy must go into each seed for full entropy.
The ring oscillators are not part of the core: a production design places NRO oscillators of different lengths in the analog / custom area, with their enables; ro_in is their output. In simulation the testbench drives them from a noise model.
Not implemented: an SP 800-90A DRBG on top (the seeds feed one, or the Root_of_Trust UDS / key generation); oscillator enables and frequency monitors; side-channel and fault-injection hardening beyond the state register check.

## Files

| File | Content |
|---|---|
| `rtl/TRNG_top.sv` | protocol core |
| `rtl/TRNG_apb.sv` | APB4 register wrapper (generated) |
| `tb/TRNG_tb.sv` | core testbench |
| `tb/TRNG_apb_tb.sv`, `tb/apb/TRNG_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/TRNG_sva.sv`, `tb/cov/TRNG_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/TRNG.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`TRNG_apb` has the core's parameters and passes them to `TRNG_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NRO` | int | `4` |
| `APT_WL` | int | `10` |

## Wrapper pins

Pins of `TRNG_apb`. Widths of the pass-through pins are at the default parameters.

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
| `ro_in` | input | 4 | protocol pin, core port `ro_in` |
| `ent_fips` | output | 1 | protocol pin, core port `ent_fips` |
| `raw_valid` | output | 1 | protocol pin, core port `raw_valid` |
| `raw_bit` | output | 1 | protocol pin, core port `raw_bit` |
| `es_ok` | output | 1 | protocol pin, core port `es_ok` (also read in a register) |
| `alert` | output | 1 | protocol pin, core port `alert` (also read in a register) |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `ro_in` | input | 4 | pin (pass-through) |
| `en` | input | 1 | CTRL[0:0] |
| `src_sel` | input | 1 | CTRL[1:1] |
| `cond_bypass` | input | 1 | CTRL[2:2] |
| `cond_blks` | input | 2 | CTRL[4:3] |
| `smp_div` | input | 8 | CTRL[12:5] |
| `rct_cutoff` | input | 8 | HEALTH[7:0] |
| `apt_cutoff` | input | 11 | HEALTH[18:8] |
| `lfsr_seed` | input | 32 | LFSR_SEED[31:0] |
| `ent_valid` | output | 1 | ENT capture |
| `ent_ready` | input | 1 | ENT handshake |
| `ent_data` | output | 32 | ENT[31:0] |
| `ent_fips` | output | 1 | pin (pass-through) |
| `seed_rdy` | output | 1 | IRQ_STATUS.SEED |
| `raw_valid` | output | 1 | pin (pass-through) |
| `raw_bit` | output | 1 | pin (pass-through) |
| `state` | output | 3 | STATUS[2:0] |
| `es_ok` | output | 1 | STATUS[3:3] |
| `es_fips` | output | 1 | STATUS[4:4] |
| `alert` | output | 1 | IRQ_STATUS.ALERT |
| `alert_rct` | output | 1 | STATUS[5:5] |
| `alert_apt` | output | 1 | STATUS[6:6] |
| `rct_fails` | output | 8 | FAILS[7:0] |
| `apt_fails` | output | 8 | FAILS[15:8] |
| `rct_hw` | output | 8 | WATERMARK[7:0] |
| `apt_hw` | output | 11 | WATERMARK[18:8] |

## APB wrapper

`TRNG_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ro_in`, `ent_fips`, `raw_valid`, `raw_bit`, `es_ok`, `alert`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x54520100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000008 | Enable and configuration (src_sel, cond_bypass and cond_blks are taken when en rises) |
| 0x018 | HEALTH | RW | 0x00031929 | Health test cutoffs (apply at once); the reset values are those of a claimed min-entropy of 0.5 bit per sample at alpha = 2^-20 |
| 0x01C | LFSR_SEED | RW | 0x00000001 | Test LFSR |
| 0x020 | ENT | RO (pop) | 0x00000000 | Entropy output: a seed is eight words, digest word 0 first (one word per raw-bit word in bypass); reading ENT pops the word |
| 0x024 | STATUS | RO | core | State and health |
| 0x028 | FAILS | RO | core | Health test failures since reset (saturating at 255) |
| 0x02C | WATERMARK | RO | core | High-water marks since en rose, for tuning the cutoffs |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5452 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `en` | RW | 0x0 | 1 runs the start-up test, then collection; 0 stops and clears the buffers (and is how a failure is cleared) |
| CTRL | 1 | `src_sel` | RW | 0x0 | noise source: 0 the ring oscillators, 1 the test LFSR (bring-up only: deterministic, no entropy) |
| CTRL | 2 | `cond_bypass` | RW | 0x0 | 1 outputs the raw bits unconditioned, 32 per word, for characterization |
| CTRL | 4:3 | `cond_blks` | RW | 0x1 | 512-bit blocks of raw bits hashed per seed, minus 1 (default 1: two blocks, 1024 raw bits per 256-bit seed) |
| CTRL | 12:5 | `smp_div` | RW | 0x0 | one raw sample every smp_div + 1 clocks |
| HEALTH | 7:0 | `rct_cutoff` | RW | 0x29 | repetition count test: a run of this many equal samples fails (1 + ceil(20 / H)) |
| HEALTH | 18:8 | `apt_cutoff` | RW | 0x319 | adaptive proportion test: this many occurrences of the first value in a 1024-sample window fail (1 + CRITBINOM(1024, 2^-H, 1 - 2^-20)) |
| LFSR_SEED | 31:0 | `lfsr_seed` | RW | 0x1 | loaded into the test LFSR when en rises (0 is a stuck source: the repetition count test fails) |
| ENT | 31:0 | `ent_data` | RO (pop) | 0x0 | seed word |
| STATUS | 2:0 | `state` | RO | core | 0 IDLE, 1 START (start-up test), 2 RUN (collecting), 3 HASH, 4 OUT (seed waiting to be read), 5 FAIL |
| STATUS | 3 | `es_ok` | RO | core | the start-up test passed and no test has failed since |
| STATUS | 4 | `es_fips` | RO | core | es_ok in the FIPS configuration (ring oscillators, conditioned) |
| STATUS | 5 | `alert_rct` | RO | core | the repetition count test failed (cleared when en rises again) |
| STATUS | 6 | `alert_apt` | RO | core | the adaptive proportion test failed (cleared when en rises again) |
| FAILS | 7:0 | `rct_fails` | RO | core | repetition count test failures |
| FAILS | 15:8 | `apt_fails` | RO | core | adaptive proportion test failures |
| WATERMARK | 7:0 | `rct_hw` | RO | core | longest run of equal samples |
| WATERMARK | 18:8 | `apt_hw` | RO | core | highest count of a window's first value |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | SEED | a seed (or raw word) is ready in ENT |
| 1 | ALERT | a health test failed: the core stopped (STATUS.alert_rct / alert_apt give the test) |
| 2 | ENT_AVAIL | ENT captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | ENT_AVAIL | ENT holds an unread beat |

### Streams

* **ENT** takes `ent_data` from the core with `ent_valid` / `ent_ready`: `ent_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ ENT_AVAIL. Reading ENT pops it. Nothing is dropped: the core holds its data until the register is free.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x54520100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), HEALTH (0x018), LFSR_SEED (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To receive on ENT: wait for IRQ ENT_AVAIL or FLAGS.ENT_AVAIL (bit 0), then read ENT (0x020). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.ENT_AVAIL (bit 2) to clear it.
6. Read STATUS (0x024) for the core's live `state`, `es_ok`, `es_fips`, `alert_rct`, `alert_apt`; it needs no clearing.
7. Read FAILS (0x028) for the core's live `rct_fails`, `apt_fails`; it needs no clearing.
8. Read WATERMARK (0x02C) for the core's live `rct_hw`, `apt_hw`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Configure: HEALTH = rct_cutoff | apt_cutoff << 8 (or keep the reset values), CTRL = cond_blks << 3 | smp_div << 5 with en = 0.
2. Start: set CTRL.en; STATUS.state goes 1 (START) then 2 (RUN) once 1024 samples have passed.
3. Read a seed: wait for IRQ_STATUS.SEED (or FLAGS ENT available), then read ENT eight times (digest word 0 first).
4. On IRQ_STATUS.ALERT: read STATUS (alert_rct / alert_apt) and FAILS, clear CTRL.en, then set it again to rerun the start-up test.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.TRNG sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.TRNG syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/TRNG_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.TRNG apb` | `TEST PASSED: TRNG_apb`, then Yosys without `ERROR` | console, `work/TRNG_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh TRNG`<br>`bash scripts/cov/run_cov.sh TRNG_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/TRNG/score.json`, `work/cov/TRNG_apb/score.json` |

Expected end of a step 4 run:

```
===== TRNG =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/TRNG_tb.sv`): drives `TRNG_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/TRNG_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/TRNG_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/TRNG_sva.sv`, `tb/cov/TRNG_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/TRNG_top.sv` | pass | 74/74 (+1 excl.) | 3526/3526 (+6 excl.) | 15/15 | 13/13 | 38/38 |
| wrapper `rtl/TRNG_apb.sv` | pass | 36/36 | 914/914 (+2 excl.) | n/a | 16/16 | 50/50 |

Core: tb/TRNG_tb.sv drives the ring oscillator inputs from a noise model (random, stuck, runs of ones and zeros) and reads with random back-pressure. Its own model runs both health tests on every raw sample and predicts each failure, flag, counter and high-water mark; it hashes the samples each seed is made of with its own SHA-256 (first checked against hashlib vectors from scripts/trng/gen_vec.py) and compares every output word. Cases: every block count, both sources, bypass, sampling every clock to every 256 clocks, each test failing in START, RUN, HASH and OUT, cutoffs of 0 and 1, both tests at once, counter saturation, en dropped in every state, reset mid-output.
The core checker is a separate cycle model from the ports (synchronizer, LFSR, divider, health tests, control timing) with its own SHA-256 (constants from the primes); it checks every raw sample, state, flag, counter and output word, and that no sample data is left in the buffers when the core is not collecting.
