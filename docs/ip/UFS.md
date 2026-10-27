# UFS device link: training handshake, SOF / header / payload / CRC-32 / EOF frames on a serial lane, COMMAND UPIUs (TEST UNIT READY, READ10, WRITE10) answered with RESPONSE and DATA UPIUs from a 256 x 32-bit LUN0 medium

Protocol IP `UFS`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `UFS_top` (`rtl/UFS_top.sv`) |
| Register interface | APB4 slave `UFS_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55460200 (code 0x5546, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 5 pass-through |

## Overview

UFS protocol Open IP -- UFS host: simplified UniPro frame link + UPIU command transactions (TEST UNIT READY / READ10 / WRITE10 on a serial lane) Open IP design implementation v2.5 Simplifications (per SPEC.md section 2.4): * refclk is kept for interface compatibility only; the lane symbol clock is derived from clk (1 bit per clk, MSB-first within each 32-bit dword). * Frame : SOF(32'h5546_5301) HDR PAYLOAD(len <= 8 dwords) CRC32 EOF(32'h5546_5302) HDR   : {type[7:0], task_tag[7:0], lun[7:0], len[7:0]} CRC32 : poly 32'h04C11DB7 (reflected shift form 32'hEDB8_8320), init all-ones, final XOR all-ones; computed over the on-the-wire bit stream of HDR+PAYLOAD and transmitted as one dword MSB-first. * COMMAND UPIU (type 8'h01): payload[0..3] = 16-byte CDB dword0 = {opcode[7:0], lba[23:0]}, dword1 = {xfer_dwords[7:0], 24'h0} WRITE10 data is carried inline in payload[4..7] (count = len-4 dwords) * RESPONSE UPIU (type 8'h81): payload[0] = {sense[15:0], status[15:0]} READ10 data follows in a DATA UPIU (type 8'h02) * LUN0 medium: internal 256 x 32-bit storage array. * One command at a time: a COMMAND UPIU that completes while the previous response (or its DATA UPIU) is still owed or on the wire is dropped with irq, so a transmitting frame is never overwritten. * LUN0 only: a command for another LUN gets CHECK CONDITION / ILLEGAL REQUEST. WRITE10 needs the CDB transfer length to equal the inline data dword count. * Frames of other UPIU types are ignored. * irq pulses one clk on: CRC mismatch, unknown opcode, len > 8, bad EOF, malformed CDB, bad LUN, out-of-range LBA/transfer length or a command while busy.

tx_p / tx_n (serial out, 1 bit per PCLK), rx_p / rx_n (serial in; only rx_p is sampled) and refclk pass through unchanged. The core trains the link on its own after reset and answers the commands the link partner sends.
The LUN0 medium is reached over the serial link only; the registers report its errors.

## Files

| File | Content |
|---|---|
| `rtl/UFS_top.sv` | protocol core |
| `rtl/UFS_apb.sv` | APB4 register wrapper (generated) |
| `tb/UFS_tb.sv` | core testbench |
| `tb/UFS_apb_tb.sv`, `tb/apb/UFS_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/UFS_sva.sv`, `tb/cov/UFS_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/UFS.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`UFS_apb` has the core's parameters and passes them to `UFS_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `BIT_CLKS` | int | `1` |

## Wrapper pins

Pins of `UFS_apb`. Widths of the pass-through pins are at the default parameters.

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
| `tx_n` | output | 1 | protocol pin, core port `tx_n` |
| `tx_p` | output | 1 | protocol pin, core port `tx_p` |
| `rx_n` | input | 1 | protocol pin, core port `rx_n` |
| `rx_p` | input | 1 | protocol pin, core port `rx_p` |
| `refclk` | input | 1 | protocol pin, core port `refclk` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_n` | output | 1 | pin (pass-through) |
| `tx_p` | output | 1 | pin (pass-through) |
| `rx_n` | input | 1 | pin (pass-through) |
| `rx_p` | input | 1 | pin (pass-through) |
| `refclk` | input | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`UFS_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_n`, `tx_p`, `rx_n`, `rx_p`, `refclk`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55460200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5546 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | CRC mismatch, bad EOF, length above 8, malformed CDB, bad LUN, unknown opcode, out-of-range LBA or transfer length, WRITE10 length mismatch, or a command while a response is still owed |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55460200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.UFS sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.UFS syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/UFS_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.UFS apb` | `TEST PASSED: UFS_apb`, then Yosys without `ERROR` | console, `work/UFS_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh UFS`<br>`bash scripts/cov/run_cov.sh UFS_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/UFS/score.json`, `work/cov/UFS_apb/score.json` |

Expected end of a step 4 run:

```
===== UFS =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/UFS_tb.sv`): drives `UFS_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/UFS_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/UFS_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/UFS_sva.sv`, `tb/cov/UFS_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/UFS_top.sv` | pass | 103/103 (+1 excl.) | 1156/1156 | 26/26 | 5/5 | 56/56 |
| wrapper `rtl/UFS_apb.sv` | pass | 19/19 | 402/402 | n/a | 7/7 | 23/23 |
