# SHA-3 / SHAKE hash engine (FIPS 202): SHA3-224, SHA3-256, SHA3-384, SHA3-512, SHAKE128 and SHAKE256 on one Keccak-f[1600] core at one round per clock, 64-bit message and digest streams

Protocol IP `SHA3`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SHA3_top` (`rtl/SHA3_top.sv`) |
| Register interface | APB4 slave `SHA3_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53330100 (code 0x5333, version 1.0) |
| Registers | 14 words, 0x000 to 0x034 |
| Interrupts | 5 sources into one level-high `irq` |
| Data streams | MSG (to the core), DIGEST (from the core) |
| Protocol pins | none (register access only) |

## Overview

SHA3_top v1.0: SHA-3 / SHAKE hash engine (FIPS 202): SHA3-224, SHA3-256, SHA3-384, SHA3-512, SHAKE128 and SHAKE256 on one Keccak-f[1600] core

- start with mode (0 SHA3-224, 1 SHA3-256, 2 SHA3-384, 3 SHA3-512,
4 SHAKE128, 5 SHAKE256) clears the state and opens a message; it is
taken in any state, so it also abandons a message or an output stream.
A reserved mode (6, 7) pulses err, clears the state and leaves the core
idle (the way to wipe a SHAKE state without starting a new message).
- Message in: in_valid / in_ready, one 64-bit word (one Keccak lane) per
handshake, little-endian (byte 0 of the message is in_data[7:0]).
in_bytes (0..8) gives the valid bytes of the word, from byte 0 up; only
the in_last word may be short (in_bytes 0 is an empty last word, as
for an empty message). A short word without in_last, or in_bytes > 8,
is dropped with an err pulse. Bytes above in_bytes are ignored.
- Absorbing takes one clock per word; a full rate block (r / 8 words:
18, 17, 13, 9, 21, 17 for the six modes) is then permuted in 24
clocks (one round per clock) with in_ready low. After in_last the
padding (domain bits 01 for SHA3, 1111 for SHAKE, then pad10*1) is
applied and the last block permuted.
- Digest out: out_valid / out_ready, one 64-bit word per handshake,
little-endian. SHA3-d gives ceil(d / 64) words with out_last on the
last (for SHA3-224 its upper 32 bits are zero) and then pulses done;
SHAKE gives an endless stream (a permutation after every r / 8 words,
out_valid low meanwhile) until the next start.
- The state is cleared when a digest has been read, on every start and
on reset; busy is high from start to done.
Not implemented: cSHAKE / KMAC / TupleHash (SP 800-185) framing, which
the host can build on SHAKE by prefixing the encoded strings; more than
one round per clock; masking against power analysis.

Features:

- All six FIPS 202 functions on one Keccak-f[1600] permutation at one round per clock (24 clocks a block).
- 64-bit lane-wide message and digest streams with valid / ready; one clock per message word, so a rate block of SHA3-256 (17 words) takes 17 + 24 clocks: about 3.3 bytes per clock.
- Messages of any length in bytes: the last word carries 0..8 valid bytes; padding (domain bits and pad10*1) is done in hardware, including the case where it needs a block of its own.
- SHAKE128 / SHAKE256 give an endless output stream (any output length), permuting again after every rate block.
- The 1600-bit state is cleared after a digest has been read, on every start and on reset; a start with a reserved mode wipes a SHAKE state without opening a message.

SHA3-224 gives four DIGEST words; the upper 32 bits of the fourth are zero.
cSHAKE, KMAC and TupleHash (SP 800-185) are SHAKE with an encoded prefix: the host can build them by streaming the encoded strings first (cSHAKE also changes the domain bits, which this core does not offer).
Not implemented: more than one round per clock; masking against power analysis.

## Files

| File | Content |
|---|---|
| `rtl/SHA3_top.sv` | protocol core |
| `rtl/SHA3_apb.sv` | APB4 register wrapper (generated) |
| `tb/SHA3_tb.sv` | core testbench |
| `tb/SHA3_apb_tb.sv`, `tb/apb/SHA3_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SHA3_sva.sv`, `tb/cov/SHA3_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SHA3.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `SHA3_apb`. Widths of the pass-through pins are at the default parameters.

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
| `start` | input | 1 | CMD |
| `mode` | input | 3 | CTRL[2:0] |
| `in_valid` | input | 1 | MSG commit / FLAGS |
| `in_data` | input | 64 | MSG0[31:0], MSG1[31:0] |
| `in_bytes` | input | 4 | MSG2[3:0] |
| `in_last` | input | 1 | MSG2[4:4] |
| `in_ready` | output | 1 | MSG handshake |
| `out_valid` | output | 1 | DIGEST capture |
| `out_data` | output | 64 | DIGEST0[31:0], DIGEST1[31:0] |
| `out_last` | output | 1 | DIGEST2 |
| `out_ready` | input | 1 | DIGEST handshake |
| `busy` | output | 1 | STATUS |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `err` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`SHA3_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53330100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000001 | Hash mode |
| 0x018 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x01C | MSG0 | RW | 0x00000000 | Message word: MSG0 = bytes 3..0, MSG1 = bytes 7..4 (little-endian), then MSG2 = {last, bytes}, which commits it |
| 0x020 | MSG1 | RW | 0x00000000 | Message word: MSG0 = bytes 3..0, MSG1 = bytes 7..4 (little-endian), then MSG2 = {last, bytes}, which commits it |
| 0x024 | MSG2 | RW | 0x00000000 | Message word: MSG0 = bytes 3..0, MSG1 = bytes 7..4 (little-endian), then MSG2 = {last, bytes}, which commits it |
| 0x028 | DIGEST0 | RO (pop) | 0x00000000 | Digest / SHAKE output word: DIGEST0 = bytes 3..0, DIGEST1 = bytes 7..4, DIGEST2 = last flag; reading DIGEST2 pops it |
| 0x02C | DIGEST1 | RO (pop) | 0x00000000 | Digest / SHAKE output word: DIGEST0 = bytes 3..0, DIGEST1 = bytes 7..4, DIGEST2 = last flag; reading DIGEST2 pops it |
| 0x030 | DIGEST2 | RO (pop) | 0x00000000 | Digest / SHAKE output word: DIGEST0 = bytes 3..0, DIGEST1 = bytes 7..4, DIGEST2 = last flag; reading DIGEST2 pops it |
| 0x034 | STATUS | RO | core | Engine state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5333 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 2:0 | `mode` | RW | 0x1 | 0 SHA3-224, 1 SHA3-256, 2 SHA3-384, 3 SHA3-512, 4 SHAKE128, 5 SHAKE256 (6 and 7 are refused with ERR and wipe the state) |
| CMD | 0 | `start` | WO (pulse) | 0x0 | clear the state and open a message in CTRL.mode (abandons a running message or output stream) |
| MSG0 | 31:0 | `in_data[31:0]` | RW | 0x0 | message bytes, byte 0 in bits 7:0 |
| MSG1 | 31:0 | `in_data[63:32]` | RW | 0x0 | message bytes, byte 0 in bits 7:0 |
| MSG2 | 3:0 | `in_bytes` | RW | 0x0 | valid bytes, 8 except in the last word (0..8) |
| MSG2 | 4 | `in_last` | RW | 0x0 | last word of the message |
| DIGEST0 | 31:0 | `out_data[31:0]` | RO (pop) | 0x0 | output bytes, byte 0 in bits 7:0 |
| DIGEST1 | 31:0 | `out_data[63:32]` | RO (pop) | 0x0 | output bytes, byte 0 in bits 7:0 |
| DIGEST2 | 0 | `out_last` | RO (pop) | 0x0 | last word of a SHA3 digest (never set for SHAKE) |
| STATUS | 0 | `busy` | RO | core | a message or an output stream is open |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | the last digest word was read |
| 1 | ERR | a message word was refused (short without last, or more than 8 bytes) or start had a reserved mode |
| 2 | MSG_DONE | MSG beat accepted by the core |
| 3 | MSG_OVF | write to MSG while full (dropped) |
| 4 | DIGEST_AVAIL | DIGEST captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | MSG_FULL | MSG holds a beat the core has not taken |
| 1 | DIGEST_AVAIL | DIGEST holds an unread beat |

### Streams

* **MSG** feeds `in_data`, `in_bytes`, `in_last`/`in_valid`. Writing MSG2 commits the beat: FLAGS.MSG_FULL is set and `in_valid` stays high until the core's `in_ready`; then MSG_DONE is set. A write while full is dropped and sets MSG_OVF.
* **DIGEST** takes `out_data`, `out_last` from the core with `out_valid` / `out_ready`: `out_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ DIGEST_AVAIL. Reading DIGEST2 pops it. Nothing is dropped: the core holds its data until the register is free.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53330100.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x018; the core sees a one-clock pulse, and the register reads 0.
6. To send on MSG: wait until FLAGS.MSG_FULL (bit 0) is 0, or for IRQ MSG_DONE, then write MSG0 (0x01C) then MSG1 (0x020) then MSG2 (0x024). The last write commits the beat. MSG_OVF means a write came while the register was full and was dropped.
7. To receive on DIGEST: wait for IRQ DIGEST_AVAIL or FLAGS.DIGEST_AVAIL (bit 1), then read DIGEST0 (0x028) then DIGEST1 (0x02C) then DIGEST2 (0x030). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.DIGEST_AVAIL (bit 4) to clear it.
8. Read STATUS (0x034) for the core's live `busy`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. CTRL.mode = function, CMD.start = 1.
2. For each message word: wait for FLAGS.MSG_FULL = 0, write MSG0, MSG1, then MSG2 = bytes | last << 4 (bytes = 8 except in the last word; an empty message is one word with bytes 0 and last).
3. Read the output: wait for FLAGS.DIGEST_AVAIL, read DIGEST0, DIGEST1, DIGEST2 (DIGEST2 pops the word); for SHA3, IRQ_STATUS.DONE follows the word with last set. For SHAKE read as many words as needed, then start the next message (or CMD.start with a reserved mode to wipe the state).

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SHA3 sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SHA3 syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SHA3_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SHA3 apb` | `TEST PASSED: SHA3_apb`, then Yosys without `ERROR` | console, `work/SHA3_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SHA3`<br>`bash scripts/cov/run_cov.sh SHA3_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SHA3/score.json`, `work/cov/SHA3_apb/score.json` |

Expected end of a step 4 run:

```
===== SHA3 =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SHA3_tb.sv`): drives `SHA3_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SHA3_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SHA3_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SHA3_sva.sv`, `tb/cov/SHA3_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SHA3_top.sv` | pass | 66/66 | 6882/6882 (+10 excl.) | 19/19 | 11/11 | 87/87 |
| wrapper `rtl/SHA3_apb.sv` | pass | 44/44 | 1006/1006 | n/a | 15/15 | 66/66 |

Core: tb/SHA3_tb.sv runs 214 cases from scripts/sha3/gen_vec.py (Python hashlib: every message length class around the rate of each function, both encodings of a message that fills its last word, SHAKE streams over several blocks) three times with different input gaps and output back-pressure, junk above the valid bytes, refused words in the middle of a message, start in every state, reserved modes and resets in the middle of a hash.
The core checker has its own Keccak-f[1600] built from FIPS 202 (round constants from the rc(t) LFSR, rho offsets from the (x, y) walk) and predicts every output word, the ready / valid timing, busy, done and err on every clock, and that the state is clear whenever the core is idle.
