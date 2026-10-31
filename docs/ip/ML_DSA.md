# ML-DSA (FIPS 204) signature engine: KeyGen, Sign (deterministic or hedged, with external mu) and Verify for ML-DSA-44, -65 and -87, with a SHAKE128 / SHAKE256 Keccak core, NTT polynomial unit and a 32 KiB key / signature / message buffer

Protocol IP `ML_DSA`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `ML_DSA_top` (`rtl/ML_DSA_top.sv`) |
| Register interface | APB4 slave `ML_DSA_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x4D640100 (code 0x4D64, version 1.0) |
| Registers | 12 words, 0x000 to 0x02C |
| Interrupts | 5 sources into one level-high `irq` |
| Data streams | DATA_IN (to the core), DATA_OUT (from the core) |
| Protocol pins | none (register access only) |

## Overview

ML_DSA_top v1.0: ML-DSA (FIPS 204) signature engine for the three parameter sets ML-DSA-44, -65 and -87: KeyGen, Sign and Verify, the internal algorithms of FIPS 204 section 6 (ML-DSA.KeyGen_internal, Sign_internal, Verify_internal; the seed xi and the signing randomness rnd come from the host, and the host formats M').

- Host side: a byte buffer of 32 KiB, read and written as 32-bit words
(little-endian) through an auto-incrementing pointer (hp_load /
hp_addr, then hw_* writes and hr_* reads) while the engine is idle.
Buffer map (byte offsets; each field sized for ML-DSA-87, the smaller
sets use the start of it):
0x0000 PK   public key (32 + 320 k)          KeyGen out, Verify in
0x0A20 SK   private key                      KeyGen out, Sign in
0x1D40 SIG  signature                        Sign out, Verify in
0x2F60 XI   seed xi (32)                     KeyGen in
0x2FA0 RND  signing randomness (32; zero for the deterministic variant)
0x2FC0 MU   message representative mu (64)  in with ext_mu, else scratch
0x3000..0x3FFF scratch
0x4000 MSG  M' (mlen bytes, at most 16384)   Sign and Verify in
- start with op (0 KeyGen, 1 Sign, 2 Verify) and pset (0 ML-DSA-44,
1 ML-DSA-65, 2 ML-DSA-87) runs the operation: busy until the done
pulse; fail (Verify: the signature is rejected) and tries (Sign: the
number of attempts of the rejection loop) hold from done to the next
start. ext_mu: Sign and Verify take mu from the buffer and skip
mu = H(tr || M'). A reserved op or pset, or mlen > 16384 without ext_mu,
pulses err instead.
- Datapath: Keccak-f[1600] at one round per clock for SHAKE128 and
SHAKE256 (one byte absorbed per clock; up to three bytes squeezed per
clock into the samplers); one NTT butterfly, pointwise product, sample,
or packed coefficient per clock on 43 polynomials of 256 coefficients,
through a 6-stage pipeline; reduction mod q = 2^23 - 2^13 + 1 by three
folds of 2^23 = 2^13 - 1; the matrix A is sampled on the fly into a
multiply-accumulate and never stored.
Not implemented: the random-number source (xi and rnd are inputs), the
message formatting of ML-DSA.Sign / Verify and HashML-DSA (M' is an
input), masking against power analysis, fault countermeasures.

Features:

- FIPS 204 ML-DSA.KeyGen_internal, Sign_internal and Verify_internal (Algorithms 6, 7, 8) for all three parameter sets; bit-exact against the NIST ACVP vectors. Sign is deterministic (rnd = 0) or hedged (rnd from the host); Sign and Verify take M' from the buffer or an external mu.
- Verify checks everything FIPS 204 does: ||z|| < gamma1 - beta, the hint encoding (HintBitUnpack's ordering, row-end and zero-padding rules) and c~ = c~'. STATUS.fail holds the result.
- Keccak-f[1600] at one round per clock for SHAKE128 and SHAKE256; one byte absorbed per clock, up to three bytes per clock squeezed into the samplers.
- Polynomial unit: one NTT / inverse NTT butterfly, pointwise product, sample or packed coefficient per clock on 43 polynomial slots, through a 6-stage pipeline; mod q = 2^23 - 2^13 + 1 by three folds of 2^23 = 2^13 - 1 (adders only). The matrix A is sampled on the fly (RejNTTPoly) straight into a multiply-accumulate and never stored.
- Clock counts: KeyGen about 26k / 41k / 61k, Verify about 32k / 47k / 70k, Sign about 63k / 91k / 128k per attempt of the rejection loop for ML-DSA-44 / 65 / 87 (FIPS 204 expects 4.25 / 5.1 / 3.85 attempts on average), plus about one clock per byte of M'.

Buffer map (byte addresses; word address = byte address / 4): 0x0000 pk (32 + 320 k bytes; KeyGen output, Verify input), 0x0A20 sk (KeyGen output, Sign input), 0x1D40 sig (Sign output, Verify input), 0x2F60 xi (KeyGen input, 32), 0x2FA0 rnd (Sign input, 32; zero for the deterministic variant), 0x2FC0 mu (input with CTRL.ext_mu, 64), 0x4000 M' (MLEN bytes, at most 16384). 0x2F80 and 0x3000-0x3FFF are the engine's scratch.
The host formats M' (FIPS 204 Algorithms 2-5: 0 || |ctx| || ctx || M for ML-DSA, 1 || |ctx| || ctx || OID || PH(M) for HashML-DSA) and supplies xi and rnd: the core has no random-number source.
Sign's run time depends on the number of attempts of the rejection loop (STATUS.tries), as in FIPS 204; the attempts themselves run the same sequence of steps whatever the secret values.
DATA_OUT prefetches: with CTRL.hr_en set, the word at the pointer is fetched as soon as DATA_OUT is empty, so after the last word wanted one more has been fetched. Clear hr_en and read DATA_OUT once more (or check FLAGS) before loading a new pointer.
Not implemented: masking or other power / EM side-channel protection; fault-attack countermeasures; a bound on the number of Sign attempts.

## Files

| File | Content |
|---|---|
| `rtl/ML_DSA_top.sv` | protocol core |
| `rtl/ML_DSA_apb.sv` | APB4 register wrapper (generated) |
| `tb/ML_DSA_tb.sv` | core testbench |
| `tb/ML_DSA_apb_tb.sv`, `tb/apb/ML_DSA_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/ML_DSA_sva.sv`, `tb/cov/ML_DSA_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/ML_DSA.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `ML_DSA_apb`. Widths of the pass-through pins are at the default parameters.

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

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `start` | input | 1 | CMD[0:0] |
| `op` | input | 2 | CTRL[1:0] |
| `pset` | input | 2 | CTRL[3:2] |
| `ext_mu` | input | 1 | CTRL[5:5] |
| `mlen` | input | 15 | MLEN[14:0] |
| `busy` | output | 1 | STATUS[0:0] |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `err` | output | 1 | IRQ_STATUS.ERR |
| `fail` | output | 1 | STATUS[1:1] |
| `tries` | output | 16 | STATUS[17:2] |
| `hp_load` | input | 1 | CMD[1:1] |
| `hp_addr` | input | 13 | PTR[12:0] |
| `hw_valid` | input | 1 | DATA_IN commit / FLAGS |
| `hw_data` | input | 32 | DATA_IN[31:0] |
| `hw_ready` | output | 1 | DATA_IN handshake |
| `hr_en` | input | 1 | CTRL[4:4] |
| `hr_valid` | output | 1 | DATA_OUT capture |
| `hr_data` | output | 32 | DATA_OUT[31:0] |
| `hr_ready` | input | 1 | DATA_OUT handshake |

## APB wrapper

`ML_DSA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4D640100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Operation and buffer read control |
| 0x018 | MLEN | RW | 0x00000000 | Length of M' in bytes |
| 0x01C | PTR | RW | 0x00000000 | Buffer word address for LOAD |
| 0x020 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x024 | DATA_IN | RW | 0x00000000 | Buffer write: the word goes to the pointer (little-endian bytes) and the pointer advances; taken while the engine is idle |
| 0x028 | DATA_OUT | RO (pop) | 0x00000000 | Buffer read: the word fetched while CTRL.hr_en is set; reading it fetches the next |
| 0x02C | STATUS | RO | core | Engine state and the last operation's result |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4D64 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 1:0 | `op` | RW | 0x0 | operation: 0 KeyGen, 1 Sign, 2 Verify (3 is reserved: START sets ERR) |
| CTRL | 3:2 | `pset` | RW | 0x0 | parameter set: 0 ML-DSA-44, 1 ML-DSA-65, 2 ML-DSA-87 (3 is reserved: START sets ERR) |
| CTRL | 4 | `hr_en` | RW | 0x0 | buffer read: while set and the engine is idle, the word at the pointer is fetched into DATA_OUT and the pointer advances |
| CTRL | 5 | `ext_mu` | RW | 0x0 | Sign and Verify take mu (64 bytes at 0x2FC0) from the buffer instead of computing H(tr || M') |
| MLEN | 14:0 | `mlen` | RW | 0x0 | bytes of M' at 0x4000 (Sign and Verify without ext_mu); above 16384 START sets ERR |
| PTR | 12:0 | `hp_addr` | RW | 0x0 | word address (byte address / 4) in the 32 KiB buffer |
| CMD | 0 | `start` | WO (pulse) | 0x0 | run CTRL.op on CTRL.pset; ignored while busy |
| CMD | 1 | `hp_load` | WO (pulse) | 0x0 | load the buffer pointer from PTR |
| DATA_IN | 31:0 | `hw_data` | RW | 0x0 | word |
| DATA_OUT | 31:0 | `hr_data` | RO (pop) | 0x0 | word |
| STATUS | 0 | `busy` | RO | core | an operation is running (the buffer port is closed) |
| STATUS | 1 | `fail` | RO | core | Verify: the signature was rejected (held from DONE to the next START) |
| STATUS | 17:2 | `tries` | RO | core | Sign: attempts of the rejection loop (held from DONE to the next START) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | the operation finished: results are in the buffer, STATUS.fail / tries are valid |
| 1 | ERR | START with a reserved op or parameter set, or MLEN above 16384 without ext_mu: nothing was run |
| 2 | DATA_IN_DONE | DATA_IN beat accepted by the core |
| 3 | DATA_IN_OVF | write to DATA_IN while full (dropped) |
| 4 | DATA_OUT_AVAIL | DATA_OUT captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | DATA_IN_FULL | DATA_IN holds a beat the core has not taken |
| 1 | DATA_OUT_AVAIL | DATA_OUT holds an unread beat |

### Streams

* **DATA_IN** feeds `hw_data`/`hw_valid`. Writing DATA_IN commits the beat: FLAGS.DATA_IN_FULL is set and `hw_valid` stays high until the core's `hw_ready`; then DATA_IN_DONE is set. A write while full is dropped and sets DATA_IN_OVF.
* **DATA_OUT** takes `hr_data` from the core with `hr_valid` / `hr_ready`: `hr_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ DATA_OUT_AVAIL. Reading DATA_OUT pops it. Nothing is dropped: the core holds its data until the register is free.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4D640100.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), MLEN (0x018), PTR (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `start` (CMD bit 0), `hp_load` (CMD bit 1) at 0x020; the core sees a one-clock pulse, and the register reads 0.
6. To send on DATA_IN: wait until FLAGS.DATA_IN_FULL (bit 0) is 0, or for IRQ DATA_IN_DONE, then write DATA_IN (0x024). The last write commits the beat. DATA_IN_OVF means a write came while the register was full and was dropped.
7. To receive on DATA_OUT: wait for IRQ DATA_OUT_AVAIL or FLAGS.DATA_OUT_AVAIL (bit 1), then read DATA_OUT (0x028). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.DATA_OUT_AVAIL (bit 4) to clear it.
8. Read STATUS (0x02C) for the core's live `busy`, `fail`, `tries`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write the inputs: PTR = word address, CMD.hp_load = 1, then the words to DATA_IN (KeyGen: xi; Sign: sk, rnd and M' or mu; Verify: pk, sig and M' or mu). Write MLEN.
2. CTRL = op | pset << 2 | ext_mu << 5, CMD.start = 1; wait for IRQ_STATUS.DONE (or STATUS.busy = 0). Verify: STATUS.fail = 0 accepts the signature.
3. Read the outputs: PTR = word address, CMD.hp_load = 1, CTRL.hr_en = 1, then read DATA_OUT once per word; clear CTRL.hr_en and read DATA_OUT once more to drop the prefetched word.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.ML_DSA sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.ML_DSA syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/ML_DSA_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.ML_DSA apb` | `TEST PASSED: ML_DSA_apb`, then Yosys without `ERROR` | console, `work/ML_DSA_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh ML_DSA`<br>`bash scripts/cov/run_cov.sh ML_DSA_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/ML_DSA/score.json`, `work/cov/ML_DSA_apb/score.json` |

Expected end of a step 4 run:

```
===== ML_DSA =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/ML_DSA_tb.sv`): drives `ML_DSA_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/ML_DSA_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/ML_DSA_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/ML_DSA_sva.sv`, `tb/cov/ML_DSA_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ML_DSA_top.sv` | pass | 655/655 (+4 excl.) | 10202/10202 (+615 excl.) | 43/43 | 36/36 | 78/78 |
| wrapper `rtl/ML_DSA_apb.sv` | pass | 42/42 | 884/884 (+26 excl.) | n/a | 18/18 | 63/63 |

Test vectors (tb/ML_DSA_vec.hex, `make -f Makefile.ML_DSA vec ACVP=...` rebuilds them): random cases from the FIPS 204 model scripts/mldsa/mldsa_ref.py (per parameter set a KeyGen, a deterministic and a hedged Sign, external mu, Verify of valid signatures and of ones with a modified c~, z, hint encoding or message; for ML-DSA-44 Sign cases picked for the rare rejections: too many hints, exactly omega hints, ||c t0|| above and exactly at gamma2, an empty and the longest M') and NIST ACVP cases (one per internal-interface group of the keyGen, sigGen and sigVer files). The model itself passes all 615 vectors of those NIST ACVP files.
The core checker computes every step the engine takes on its own: the Keccak sponge (its own Keccak-f[1600] from the FIPS 202 rotation and round-constant rules) for every byte absorbed and squeezed, and NTT, inverse NTT, pointwise products, RejNTTPoly, RejBoundedPoly, ExpandMask, SampleInBall, BitPack / SimpleBitPack, Power2Round, Decompose, MakeHint, UseHint and HintBitPack / HintBitUnpack (with every reject condition) from a copy of their inputs, as FIPS 204 writes them; plus the Sign loop, the Verify result, the host port and control rules.
Exhaustive checks (python3 scripts/formal/exhaust_ml_dsa.py): the three reduction folds for every high part, the last for every input, Decompose, UseHint and Power2Round for every r < q (both gamma2), addq / subq for every a, CoeffFromHalfByte, the zeta table and the Keccak round constants against their definitions.
