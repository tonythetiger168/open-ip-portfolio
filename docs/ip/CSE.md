# Crypto & Security Engine: AES-128 (FIPS-197) ECB encrypt and decrypt, key written as four words, one round per clock

Protocol IP `CSE`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `CSE_top` (`rtl/CSE_top.sv`) |
| Register interface | APB4 slave `CSE_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x43450200 (code 0x4345, version 2.0) |
| Registers | 20 words, 0x000 to 0x04C |
| Interrupts | 2 sources into one level-high `irq` |
| Core register port | KEY (4 words) |
| Protocol pins | none (register access only) |

## Overview

CSE -- Crypto & Security Engine: real AES-128 (FIPS-197) ECB core. * Full SubBytes/ShiftRows/MixColumns/AddRoundKey + on-the-fly key expansion; iterative datapath, 1 round/clk, 10 rounds * Parallel command port: 128-bit key written as 4x32 words (key_we/key_widx/key), start/din[127:0]/enc_dec -> busy/done/dout * Command queue depth 1: a new start or key write while busy is a protocol violation -> irq pulse (command ignored)

Wide values are little-endian across words: DIN0 and DOUT0 hold bits [31:0], DIN3 and DOUT3 bits [127:96]. The key is the other way round: KEY0 holds bits [127:96], as the core takes it.
The key words are write only (the core keeps no read path to them) and take whole words: a KEY write with PSTRB != 4'hF gets PSLVERR and is dropped.

## Files

| File | Content |
|---|---|
| `rtl/CSE_top.sv` | protocol core |
| `rtl/CSE_apb.sv` | APB4 register wrapper (generated) |
| `tb/CSE_tb.sv` | core testbench |
| `tb/CSE_apb_tb.sv`, `tb/apb/CSE_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CSE_sva.sv`, `tb/cov/CSE_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CSE.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `CSE_apb`. Widths of the pass-through pins are at the default parameters.

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
| `PSLVERR` | output | 1 | error: unmapped or misaligned address, or partial write to a core register word |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `key_we` | input | 1 | write to a KEY word |
| `key_widx` | input | 2 | KEY word index |
| `key` | input | 32 | KEY write data |
| `start` | input | 1 | CMD |
| `enc_dec` | input | 1 | CTRL |
| `din` | input | 128 | DIN0[31:0], DIN1[31:0], DIN2[31:0], DIN3[31:0] |
| `busy` | output | 1 | STATUS |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `dout` | output | 128 | DOUT0[31:0], DOUT1[31:0], DOUT2[31:0], DOUT3[31:0] |
| `irq` | output | 1 | IRQ_STATUS.PROTOCOL |

## APB wrapper

`CSE_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43450200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | KEY0 | WO (core) | core | key bits [127:96] (write only; reset 0); a write while busy is refused (PROTOCOL) |
| 0x018 | KEY1 | WO (core) | core | key bits [95:64] (write only; reset 0) |
| 0x01C | KEY2 | WO (core) | core | key bits [63:32] (write only; reset 0) |
| 0x020 | KEY3 | WO (core) | core | key bits [31:0] (write only; reset 0) |
| 0x024 | DIN0 | RW | 0x00000000 | Input block |
| 0x028 | DIN1 | RW | 0x00000000 | Input block |
| 0x02C | DIN2 | RW | 0x00000000 | Input block |
| 0x030 | DIN3 | RW | 0x00000000 | Input block |
| 0x034 | CTRL | RW | 0x00000001 | Operation |
| 0x038 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x03C | DOUT0 | RO | core | Result |
| 0x040 | DOUT1 | RO | core | Result |
| 0x044 | DOUT2 | RO | core | Result |
| 0x048 | DOUT3 | RO | core | Result |
| 0x04C | STATUS | RO | core | Engine state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x050 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4345 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| KEY0 | 31:0 | core register | WO (core) | core | written at core register 0 |
| KEY1 | 31:0 | core register | WO (core) | core | written at core register 1 |
| KEY2 | 31:0 | core register | WO (core) | core | written at core register 2 |
| KEY3 | 31:0 | core register | WO (core) | core | written at core register 3 |
| DIN0 | 31:0 | `din[31:0]` | RW | 0x0 | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| DIN1 | 31:0 | `din[63:32]` | RW | 0x0 | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| DIN2 | 31:0 | `din[95:64]` | RW | 0x0 | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| DIN3 | 31:0 | `din[127:96]` | RW | 0x0 | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| CTRL | 0 | `enc_dec` | RW | 0x1 | 1: encrypt, 0: decrypt; taken by START |
| CMD | 0 | `start` | WO (pulse) | 0x0 | write 1: run one block with the current key, DIN and CTRL (21 clocks); refused while busy (PROTOCOL) |
| DOUT0 | 31:0 | `dout[31:0]` | RO | core | the 128-bit result of the last operation, valid from DONE |
| DOUT1 | 31:0 | `dout[63:32]` | RO | core | the 128-bit result of the last operation, valid from DONE |
| DOUT2 | 31:0 | `dout[95:64]` | RO | core | the 128-bit result of the last operation, valid from DONE |
| DOUT3 | 31:0 | `dout[127:96]` | RO | core | the 128-bit result of the last operation, valid from DONE |
| STATUS | 0 | `busy` | RO | core | an operation is running (key expansion, then the rounds) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | an operation finished; DOUT holds the result |
| 1 | PROTOCOL | START or a KEY write while busy (refused) |

### Core register port

The KEY words reach the core's own register port. A write to one pulses `key_we` for one clock with `key_widx` (the core register) and `key` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. 

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43450200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write DIN0 (0x024), DIN1 (0x028), DIN2 (0x02C), DIN3 (0x030), CTRL (0x034). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. Access the core's registers through the KEY words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
6. To issue a command, write 1 to `start` (CMD bit 0) at 0x038; the core sees a one-clock pulse, and the register reads 0.
7. Read DOUT0 (0x03C), DOUT1 (0x040), DOUT2 (0x044), DOUT3 (0x048) for the core's live `dout[31:0]`, `dout[63:32]`, `dout[95:64]`, `dout[127:96]`; it needs no clearing.
8. Read STATUS (0x04C) for the core's live `busy`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.CSE sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.CSE syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/CSE_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.CSE apb` | `TEST PASSED: CSE_apb`, then Yosys without `ERROR` | console, `work/CSE_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh CSE`<br>`bash scripts/cov/run_cov.sh CSE_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/CSE/score.json`, `work/cov/CSE_apb/score.json` |

Expected end of a step 4 run:

```
===== CSE =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/CSE_tb.sv`): drives `CSE_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/CSE_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/CSE_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/CSE_sva.sv`, `tb/cov/CSE_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CSE_top.sv` | pass | 182/182 | 1386/1386 | 8/8 | 5/5 | 41/41 |
| wrapper `rtl/CSE_apb.sv` | pass | 41/41 | 1274/1274 | n/a | 15/15 | 59/59 |
