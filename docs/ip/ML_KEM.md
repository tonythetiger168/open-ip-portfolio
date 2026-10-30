# ML-KEM (FIPS 203) key encapsulation engine: KeyGen, Encaps and Decaps with implicit rejection for ML-KEM-512, -768 and -1024, with a Keccak (SHA3 / SHAKE) core, NTT polynomial unit and an 8 KiB key / ciphertext buffer

Protocol IP `ML_KEM`, version 1.1. Apache-2.0.

| Item | Value |
|---|---|
| Core | `ML_KEM_top` (`rtl/ML_KEM_top.sv`) |
| Register interface | APB4 slave `ML_KEM_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x4D4B0101 (code 0x4D4B, version 1.1) |
| Registers | 11 words, 0x000 to 0x028 |
| Interrupts | 5 sources into one level-high `irq` |
| Data streams | DATA_IN (to the core), DATA_OUT (from the core) |
| Protocol pins | none (register access only) |

## Overview

ML_KEM_top v1.1: ML-KEM (FIPS 203) key encapsulation engine for the three parameter sets ML-KEM-512, -768 and -1024: KeyGen, Encaps and Decaps (with implicit rejection), the internal algorithms of FIPS 203 section 6 (the random d, z and m come from the host).

- Host side: a byte buffer of 8 KiB, read and written as 32-bit words
(little-endian) through an auto-incrementing pointer (hp_load /
hp_addr, then hw_* writes and hr_* reads) while the engine is idle.
Buffer map (byte offsets; each field sized for k = 4, the smaller sets
use the start of it):
0x0000 EK  encapsulation key (384k + 32)     KeyGen out, Encaps in
0x0620 DK  decapsulation key (768k + 96)     KeyGen out, Decaps in
0x1280 C   ciphertext (32 (du k + dv))       Encaps out, Decaps in
0x18A0 C'  re-encryption in Decaps (scratch)
0x1EC0 d, 0x1EE0 z (KeyGen in), 0x1F00 m (Encaps in),
0x1F20 K   shared secret (Encaps and Decaps out); 0x1F40.. scratch
- start with op (0 KeyGen, 1 Encaps, 2 Decaps) and pset (0 ML-KEM-512,
1 ML-KEM-768, 2 ML-KEM-1024) runs the operation: busy until the done
pulse. A reserved op or pset pulses err instead.
- Datapath: Keccak-f[1600] at one round per clock for SHA3-256,
SHA3-512, SHAKE128 and SHAKE256 (one byte absorbed or squeezed per
clock); one NTT butterfly, base-case multiplication pair, addition,
sample or packed coefficient per clock on ten 256-coefficient
polynomials, through an 8-stage pipeline (v1.1; the polynomial store
has registered reads); exact constant-divisor reductions mod q = 3329.
- Side channels: the sequence of operations and its length depend only
on the parameter set and the public matrix seed rho (rejection
sampling of A); in Decaps the re-encryption, the comparison and the
key selection always run in full, and whether the ciphertext was
rejected is not visible outside (no flag, same clock count).
Not implemented: the random-number source (d, z and m are inputs), the
input checks of FIPS 203 7.2 / 7.3 (left to the host), masking against
power analysis.

Features:

- FIPS 203 ML-KEM.KeyGen_internal, Encaps_internal and Decaps (Algorithms 16, 17, 18) for all three parameter sets; bit-exact against the NIST ACVP vectors.
- Decaps with implicit rejection: the re-encryption, comparison and selection of K or J(z || c) always run in full; whether the ciphertext was rejected is not visible (no flag, the same number of clocks).
- Keccak-f[1600] at one round per clock for SHA3-256, SHA3-512, SHAKE128 and SHAKE256; one byte absorbed or squeezed per clock.
- Polynomial unit: one NTT / inverse NTT butterfly, base-case multiplication pair, addition, CBD or SampleNTT coefficient, or packed coefficient per clock, through an 8-stage pipeline (registered reads of the polynomial store, products, Barrett quotient and remainder in separate stages); exact reductions mod q = 3329 by constant multiplication. Deepest path 53 gate levels in the repository's PPA flow (scripts/syn/ppa_report.sh).
- 8 KiB byte buffer with an auto-incrementing 32-bit host port; clock counts: KeyGen about 13.8k / 22.6k / 33.6k, Encaps 16.8k / 26.0k / 37.3k, Decaps 24.3k / 36.1k / 50.4k for ML-KEM-512 / 768 / 1024 (Encaps and Decaps vary slightly with rho, through the rejection sampling of A).

Buffer map (byte addresses; word address = byte address / 4): 0x0000 ek (384k + 32 bytes; KeyGen output, Encaps input), 0x0620 dk (768k + 96; KeyGen output, Decaps input), 0x1280 c (32 (du k + dv); Encaps output, Decaps input), 0x1EC0 d and 0x1EE0 z (KeyGen inputs, 32 bytes each), 0x1F00 m (Encaps input, 32), 0x1F20 K (shared secret: Encaps and Decaps output, 32). The rest is the engine's scratch.
The random d, z and m come from the host: the core has no random-number source. The input checks of FIPS 203 7.2 and 7.3 (ek modulus check, dk hash check) are left to the host.
DATA_OUT prefetches: with CTRL.hr_en set, the word at the pointer is fetched as soon as DATA_OUT is empty, so after the last word wanted one more has been fetched. Clear hr_en and read DATA_OUT once more (or check FLAGS) before loading a new pointer.
Not implemented: masking or other power / EM side-channel protection beyond the constant operation sequence; fault-attack countermeasures.

## Files

| File | Content |
|---|---|
| `rtl/ML_KEM_top.sv` | protocol core |
| `rtl/ML_KEM_apb.sv` | APB4 register wrapper (generated) |
| `tb/ML_KEM_tb.sv` | core testbench |
| `tb/ML_KEM_apb_tb.sv`, `tb/apb/ML_KEM_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/ML_KEM_sva.sv`, `tb/cov/ML_KEM_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/ML_KEM.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `ML_KEM_apb`. Widths of the pass-through pins are at the default parameters.

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
| `busy` | output | 1 | STATUS |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `err` | output | 1 | IRQ_STATUS.ERR |
| `hp_load` | input | 1 | CMD[1:1] |
| `hp_addr` | input | 11 | PTR[10:0] |
| `hw_valid` | input | 1 | DATA_IN commit / FLAGS |
| `hw_data` | input | 32 | DATA_IN[31:0] |
| `hw_ready` | output | 1 | DATA_IN handshake |
| `hr_en` | input | 1 | CTRL[4:4] |
| `hr_valid` | output | 1 | DATA_OUT capture |
| `hr_data` | output | 32 | DATA_OUT[31:0] |
| `hr_ready` | input | 1 | DATA_OUT handshake |

## APB wrapper

`ML_KEM_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4D4B0101 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Operation and buffer read control |
| 0x018 | PTR | RW | 0x00000000 | Buffer word address for LOAD |
| 0x01C | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x020 | DATA_IN | RW | 0x00000000 | Buffer write: the word goes to the pointer (little-endian bytes) and the pointer advances; taken while the engine is idle |
| 0x024 | DATA_OUT | RO (pop) | 0x00000000 | Buffer read: the word fetched while CTRL.hr_en is set; reading it fetches the next |
| 0x028 | STATUS | RO | core | Engine state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4D4B | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x01 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 1:0 | `op` | RW | 0x0 | operation: 0 KeyGen, 1 Encaps, 2 Decaps (3 is reserved: START sets ERR) |
| CTRL | 3:2 | `pset` | RW | 0x0 | parameter set: 0 ML-KEM-512, 1 ML-KEM-768, 2 ML-KEM-1024 (3 is reserved: START sets ERR) |
| CTRL | 4 | `hr_en` | RW | 0x0 | buffer read: while set and the engine is idle, the word at the pointer is fetched into DATA_OUT and the pointer advances |
| PTR | 10:0 | `hp_addr` | RW | 0x0 | word address (byte address / 4) in the 8 KiB buffer |
| CMD | 0 | `start` | WO (pulse) | 0x0 | run CTRL.op on CTRL.pset; ignored while busy |
| CMD | 1 | `hp_load` | WO (pulse) | 0x0 | load the buffer pointer from PTR |
| DATA_IN | 31:0 | `hw_data` | RW | 0x0 | word |
| DATA_OUT | 31:0 | `hr_data` | RO (pop) | 0x0 | word |
| STATUS | 0 | `busy` | RO | core | an operation is running (the buffer port is closed) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | the operation finished: results are in the buffer |
| 1 | ERR | START with a reserved op or parameter set: nothing was run |
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

1. Release PRESETN. Read ID (0x000) and check it is 0x4D4B0101.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), PTR (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `start` (CMD bit 0), `hp_load` (CMD bit 1) at 0x01C; the core sees a one-clock pulse, and the register reads 0.
6. To send on DATA_IN: wait until FLAGS.DATA_IN_FULL (bit 0) is 0, or for IRQ DATA_IN_DONE, then write DATA_IN (0x020). The last write commits the beat. DATA_IN_OVF means a write came while the register was full and was dropped.
7. To receive on DATA_OUT: wait for IRQ DATA_OUT_AVAIL or FLAGS.DATA_OUT_AVAIL (bit 1), then read DATA_OUT (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.DATA_OUT_AVAIL (bit 4) to clear it.
8. Read STATUS (0x028) for the core's live `busy`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write the inputs: PTR = word address, CMD.hp_load = 1, then the words to DATA_IN (for KeyGen d and z; Encaps ek and m; Decaps dk and c).
2. CTRL = op | pset << 2, CMD.start = 1; wait for IRQ_STATUS.DONE (or STATUS.busy = 0).
3. Read the outputs: PTR = word address, CMD.hp_load = 1, CTRL.hr_en = 1, then read DATA_OUT once per word; clear CTRL.hr_en and read DATA_OUT once more to drop the prefetched word.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.ML_KEM sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.ML_KEM syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/ML_KEM_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.ML_KEM apb` | `TEST PASSED: ML_KEM_apb`, then Yosys without `ERROR` | console, `work/ML_KEM_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh ML_KEM`<br>`bash scripts/cov/run_cov.sh ML_KEM_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/ML_KEM/score.json`, `work/cov/ML_KEM_apb/score.json` |

Expected end of a step 4 run:

```
===== ML_KEM =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/ML_KEM_tb.sv`): drives `ML_KEM_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/ML_KEM_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/ML_KEM_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/ML_KEM_sva.sv`, `tb/cov/ML_KEM_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ML_KEM_top.sv` | pass | 556/556 (+3 excl.) | 7448/7448 (+134 excl.) | 31/31 | 23/23 | 54/54 |
| wrapper `rtl/ML_KEM_apb.sv` | pass | 39/39 | 776/776 | n/a | 16/16 | 61/61 |

Test vectors (tb/ML_KEM_vec.hex, `make -f Makefile.ML_KEM vec` rebuilds them): 24 random cases from the FIPS 203 model scripts/mlkem/mlkem_ref.py (KeyGen, Encaps, Decaps and Decaps of a modified ciphertext for each parameter set, twice) and 18 NIST ACVP cases (the first two of each KeyGen, Encaps and Decaps group). The model itself passes all 240 vectors of the NIST ACVP ML-KEM keyGen and encapDecap files.
Implicit rejection: each Decaps of a modified ciphertext must give J(z || c) and take exactly as many clocks as the valid Decaps with the same key.
The core checker computes every step the engine takes on its own: the Keccak sponge (its own Keccak-f[1600] from the FIPS 202 rotation and round-constant rules) for every byte absorbed and squeezed, and NTT, inverse NTT, base-case multiplication, addition, subtraction, CBD, SampleNTT, encode, decode, copy, compare and select from a copy of their inputs, as FIPS 203 writes them; plus the host port and control rules.
Exhaustive checks (python3 scripts/formal/exhaust_ml_kem.py): the modular reduction for every input below 2^25, addq and subq for every pair below q, Compress and Decompress for every input and d, the zeta and gamma tables and the Keccak round constants against their definitions.
