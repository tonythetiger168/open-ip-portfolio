<!-- SPDX-License-Identifier: Apache-2.0 -->
# TRNG: design specification

A true random number generator in the structure of NIST SP 800-90B: a ring oscillator noise
source, the two approved health tests on every raw sample, and SHA-256 as the vetted
conditioning function turning raw bits into 256-bit seeds. Not implemented: a DRBG
(SP 800-90A) after the conditioner, other conditioning functions, the ring oscillators
themselves (they are outside the core), and the entropy assessment (done offline on the raw
samples). Core `TRNG_top` (`rtl/TRNG_top.sv`), testbench `tb/TRNG_tb.sv` (a noise model and a
reference model of the health tests and SHA-256, checked against `hashlib` vectors in
`tb/TRNG_vec.svh`), checker `tb/cov/TRNG_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; registered outputs show a
decision of clock n in clock n+1.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `ro_in` | input | `NRO` | free-running ring oscillator outputs (asynchronous to `clk`) | - | async | - |
| `en` | input | 1 | run; a rising edge starts (start-up test), 0 stops and clears (§3.1) | high | `clk` | - |
| `src_sel` | input | 1 | 0 ring oscillators, 1 test LFSR (taken when `en` rises) | - | `clk` | - |
| `cond_bypass` | input | 1 | 1: output raw bits, 32 per word, unconditioned (taken when `en` rises) | high | `clk` | - |
| `cond_blks` | input | 2 | 512-bit blocks per seed, minus 1 (taken when `en` rises) | - | `clk` | - |
| `smp_div` | input | 8 | a sample every `smp_div` + 1 clocks (applies at once) | - | `clk` | - |
| `rct_cutoff` | input | 8 | repetition count test cutoff (applies at once) | - | `clk` | - |
| `apt_cutoff` | input | 11 | adaptive proportion test cutoff (applies at once) | - | `clk` | - |
| `lfsr_seed` | input | 32 | test LFSR value loaded when `en` rises | - | `clk` | - |
| `ent_valid` | output | 1 | an output word is available (state OUT); combinational | high | comb | 0 |
| `ent_ready` | input | 1 | the host takes the word | high | `clk` | - |
| `ent_data` | output | 32 | output word (0 when `ent_valid` is 0); combinational | - | comb | 0 |
| `ent_fips` | output | 1 | `ent_valid` and the FIPS configuration (§3.6); combinational | high | comb | 0 |
| `seed_rdy` | output | 1 | one-clock pulse when a seed (or bypass word) becomes available | high | `clk` | 0 |
| `raw_valid` | output | 1 | one-clock pulse: a raw sample on `raw_bit` | high | `clk` | 0 |
| `raw_bit` | output | 1 | the raw sample; holds | - | `clk` | 0 |
| `state` | output | 3 | 0 IDLE, 1 START, 2 RUN, 3 HASH, 4 OUT, 5 FAIL | - | `clk` | 0 |
| `es_ok` | output | 1 | start-up passed and running: RUN, HASH or OUT; combinational | high | comb | 0 |
| `es_fips` | output | 1 | `es_ok` in the FIPS configuration; combinational | high | comb | 0 |
| `alert` | output | 1 | one-clock pulse on a health test failure | high | `clk` | 0 |
| `alert_rct` | output | 1 | sticky: the repetition count test failed (cleared when `en` rises) | high | `clk` | 0 |
| `alert_apt` | output | 1 | sticky: the adaptive proportion test failed (cleared when `en` rises) | high | `clk` | 0 |
| `rct_fails` | output | 8 | RCT failures since reset, saturating at 255 | - | `clk` | 0 |
| `apt_fails` | output | 8 | APT failures since reset, saturating at 255 | - | `clk` | 0 |
| `rct_hw` | output | 8 | longest run seen since `en` rose | - | `clk` | 0 |
| `apt_hw` | output | 11 | highest APT window count seen since `en` rose | - | `clk` | 0 |

### Internal signals used by the verification

The TB and the bound checker read these by name (they must hold no sample data unless the core is
collecting or hashing); the FSM coverage collector (`tb/cov/TRNG_fsm_cov.sv`) binds `st`.

| Signal | Width | Meaning |
|---|---|---|
| `blk` | 512 | collection register (raw bits shift in at bit 0); during a compression the SHA-256 schedule window, W[t] at the top. 0 outside RUN and HASH |
| `hh` | 256 | SHA-256 chaining value, word 0 at the top; 0 from the clock after leaving RUN / HASH |
| `dig` | 256 | the seed being output, the current word at the top; shifts in zeros as words are read |
| `st` | 3 | control state, the value on `state` |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/TRNG.md`](../ip/TRNG.md) (source: `scripts/apb/specs/TRNG.json`); do not edit by hand.

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

### Programming sequence

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
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 States

| State | Moves on |
|---|---|
| IDLE (0) | a rising edge of `en` (`en` = 1 and 0 in the previous clock; also `en` high out of reset): -> START. `src_sel`, `cond_bypass`, `cond_blks` are taken; the LFSR is loaded with `lfsr_seed`; health tests, high-water marks and `alert_rct` / `alert_apt` are cleared |
| START (1) | the 2^`APT_WL`-th sample of the first window passes: -> RUN. Start-up samples are discarded |
| RUN (2) | collecting raw bits (§3.4) |
| HASH (3) | SHA-256 compression (§3.5) |
| OUT (4) | seed words on `ent_*` (§3.6) |
| FAIL (5) | stays until `en` = 0 |

In every state but IDLE, `en` = 0 moves to IDLE and clears `blk`, `dig` and `raw_valid`. Otherwise
a health test failure moves to FAIL (§3.3). An illegal state encoding moves to FAIL with `alert`.

### 3.2 Sampling

`^ro_in` passes two synchronizer flops. In START, RUN, HASH and OUT a divider counts clocks: when
it reaches `smp_div` (counter >= `smp_div`) it restarts and a sample is taken: `raw_bit` = the
synchronizer output (or `lfsr[0]` with the LFSR source) and `raw_valid` pulses in the next clock.
So with `smp_div` = 0 a sample comes every clock. The LFSR is a 32-bit Galois LFSR shifting right
with taps 0x80200003 (x^32 + x^22 + x^2 + x + 1), stepped with every sample. No samples are taken
in IDLE or FAIL.

### 3.3 Health tests

Each sample on `raw_valid` (in START, RUN, HASH or OUT) is tested at the next edge:

* Repetition count: the run length (1 for a new value) reaching `rct_cutoff` fails.
* Adaptive proportion: windows of 2^`APT_WL` samples; the first sample of a window sets the
  reference value with count 1, each later sample equal to it counts one; the count reaching
  `apt_cutoff` fails.

The run continues across windows. `rct_hw` / `apt_hw` keep the maxima of run length and window
count. A cutoff of 0 or 1 fails on the first sample. A failure: `alert` pulses, `alert_rct` and /
or `alert_apt` set, the matching failure counter + 1 (saturating), FAIL, `blk` / `dig` cleared,
no `raw_valid` in the next clock. With alpha = 2^-20 and min-entropy H per bit, the cutoffs are
1 + ceil(20 / H) and 1 + CRITBINOM(1024, 2^-H, 1 - alpha): H = 0.5 gives 41 and 793, H = 1 gives
21 and 589.

### 3.4 Collection

In RUN each sample is shifted into `blk` at bit 0 (the first bit of a block ends at bit 511, the
MSB of the first message byte).

* Bypass: every 32 samples the word (first bit at bit 31) goes to OUT as one output word,
  `seed_rdy` pulses.
* Conditioned: after 512 samples a compression starts (HASH); the first block of a seed starts
  from the SHA-256 IV, later ones from the chaining value.

Samples taken in HASH and OUT are health-tested and discarded; each seed is hashed from fresh
samples.

### 3.5 Conditioning

SHA-256, 64 rounds at one per clock, the message schedule computed in `blk`. After a data block,
if fewer than `cond_blks` + 1 data blocks were hashed the core returns to RUN for the next block;
else the padding block {0x80000000, 0..., 64-bit length = 512 x (`cond_blks` + 1)} is hashed. The
digest of the padding block is the seed: OUT with 8 words, `seed_rdy` pulses. A compression takes
about 66 clocks (start, 64 rounds, the chaining-value add).

### 3.6 Output

In OUT `ent_valid` = 1 and `ent_data` = the current word (digest word 0 first). Each `ent_ready`
takes a word; after the last (8, or 1 in bypass) the core goes to RUN and starts a fresh seed.
`ent_fips` = `ent_valid` and FIPS configuration, where FIPS = ring oscillators and conditioned
(`src_sel` = 0 and `cond_bypass` = 0 when `en` rose). `es_fips` = `es_ok` and FIPS.

### 3.7 Reset

While `rst_n` is low: IDLE, all outputs 0, counters and marks 0, `blk` / `hh` / `dig` 0, 2 blocks
per seed.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `NRO` | 4 | 1 or more | ring oscillator inputs, XORed |
| `APT_WL` | 10 | 1..10 (the 11-bit counts) | adaptive proportion window = 2^`APT_WL` samples (also the start-up length) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| stuck source | RCT fails after `rct_cutoff` samples: FAIL |
| biased source | APT fails within a window: FAIL |
| both tests fail on one sample | both flags and both counters |
| failure in START, RUN, HASH or OUT | FAIL; buffers cleared; no output until `en` falls and rises |
| `en` dropped in any state | IDLE, buffers cleared; flags kept until the next rise |
| `en` high out of reset | counts as a rising edge |
| LFSR or bypass | output never marked FIPS |
| failure counters at 255 | stay at 255 |
| reset mid-output | everything cleared |

## 6. TB check map

Messages are printed by `tb/TRNG_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/TRNG_sva.sv`. A noise model drives `ro_in` (random, stuck, runs); the output is
read with random back-pressure. A TB model runs the health tests on every raw sample and predicts
failures, flags, counters and marks; it collects the samples into seeds, hashes them with its own
SHA-256 (checked first against `hashlib` vectors) and compares every word and its FIPS flag. Then
failures in every state, forced-failure cutoffs, counter saturation, `en` dropped in every state
and a reset mid-output.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "raw sample is not the synchronized ring oscillator XOR" | two synchronizer flops and the sample register | §3.2 |
| "outputs in reset" | reset values | §3.7 |
| "health test failure not flagged" | a predicted failure gives FAIL and `alert` | §3.3 |
| "unexpected health test failure" | no failure the model does not predict | §3.3 |
| "high-water marks" | `rct_hw` / `apt_hw` as the model | §3.3 |
| "failure counters" | `rct_fails` / `apt_fails` as the model | §3.3 |
| "sticky alert flags" | `alert_rct` / `alert_apt` as the model | §3.3 |
| "raw sample while stopped" | no samples in IDLE / FAIL | §3.2 |
| "es_ok" | `es_ok` in RUN / HASH / OUT | §3.1 |
| "es_fips" | `es_fips` = `es_ok` and FIPS | §3.6 |
| "ent_valid" | `ent_valid` exactly in OUT | §3.6 |
| "output with no seed expected" | output only after a full seed | §3.4, §3.5 |
| "output data while not valid" | `ent_data` 0 when not valid | §3.6 |
| "seed_rdy" | `seed_rdy` once per seed | §3.5 |
| "output word" | every word as the model's SHA-256 of the samples | §3.4, §3.5 |
| "timeout waiting for state" | the state is reached in time | §3.1 |
| "timeout waiting for" | the expected event happens in time | §3.1 |
| "SHA-256 vector" | the TB's own SHA-256 matches `hashlib` | §3.5 |
| "reset values" | reset values | §3.7 |
| "LFSR seed marked FIPS" | LFSR output not FIPS | §3.6 |
| "ring oscillator seed not marked FIPS" | conditioned ring oscillator output is FIPS | §3.6 |
| "start-up RCT failure flags" | RCT failure during START | §3.1, §3.3 |
| "output after a failure" | no output in FAIL | §3.3 |
| "APT failure flags" | APT failure flags | §3.3 |
| "APT failure in a running state" | APT failure in RUN / HASH / OUT | §3.3 |
| "high-water marks after long runs" | marks after long runs | §3.3 |
| "RCT failure counter does not saturate" | saturation at 255 | §3.3 |
| "APT failure counter does not saturate" | saturation at 255 | §3.3 |
| "both tests failing together" | both flags and counters | §3.3 |
| "alert flags not cleared on restart" | flags cleared when `en` rises | §3.1 |
| "en dropped in START" | `en` = 0 -> IDLE from START | §3.1 |
| "buffers not cleared after en dropped" | `dig` / `blk` cleared | §3.1 |
| "not started with en high out of reset" | `en` high out of reset starts | §3.1 |
| "state after a reset mid-output" | reset clears state, counters, `dig` | §3.7 |
| a_state | `state` exactly as the model | §3.1 |
| a_raw_sample | `raw_valid` / `raw_bit` exactly as the model | §3.2 |
| a_health_alert | `alert`, `alert_rct`, `alert_apt` exactly as the model | §3.3 |
| a_fail_counters | failure counters exactly as the model | §3.3 |
| a_high_water | high-water marks exactly as the model | §3.3 |
| a_output_word | `ent_data` / `ent_fips` exactly as the model | §3.5, §3.6 |
| a_output_valid | `ent_valid` and `seed_rdy` exactly as the model | §3.6 |
| a_output_quiet | `ent_data` 0 and `ent_fips` 0 when not valid | §3.6 |
| a_es_ok | `es_ok` / `es_fips` | §3.1, §3.6 |
| a_no_output_after_fail | with an alert flag set, no output and no `es_ok` | §3.3 |
| a_clear_when_stopped | `blk` = 0 outside RUN / HASH | §3.4 |
| a_chain_cleared | `hh` = 0 from the clock after leaving RUN / HASH | §3.5 |
| a_reset | in reset: IDLE, outputs, counters, `blk`, `hh` 0 | §3.7 |
