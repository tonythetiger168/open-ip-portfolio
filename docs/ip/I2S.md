# I2S slave transmitter and receiver: 16-bit samples, left and right channels, Philips timing (MSB one BCLK after LRCK)

Protocol IP `I2S`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `I2S_top` (`rtl/I2S_top.sv`) |
| Register interface | APB4 slave `I2S_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x49320200 (code 0x4932, version 2.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CORE (4 words) |
| Protocol pins | 4 pass-through |

## Overview

I2S slave transmitter/receiver, 16-bit samples, 2 channels Samples SDIN on BCLK rise, shifts SDOUT on BCLK fall, with the I2S standard one-BCLK data delay after each LRCK transition. Clock ratio: BCLK is oversampled, so SDOUT changes up to two clk periods after a BCLK falling edge (synchroniser + edge detect). The I2S transmitter limit (data valid 0.8 T after the previous rising edge, so 0.3 T after the fall, leaving the receiver its 0.2 T setup) then needs 2 * Tclk + t_co(sdout pad) <= 0.3 * T_BCLK: clk >= 7 x BCLK, with 8 x or more recommended so the pad delay fits. SDIN is taken in the clk cycle after the BCLK rise, so the master must hold it one clk past the rise (a master that changes SDIN on the falling edge holds it T / 2).

Features:

- I2S (Philips) slave: BCLK and LRCK come from the master; LRCK = 0 is the left channel.
- `DW`-bit (default 16) samples, MSB first, one BCLK after each LRCK transition; slots longer than `DW` bits are padded (TX sends 0, RX ignores the extra bits).
- Separate sample registers TX_LEFT, TX_RIGHT, RX_LEFT and RX_RIGHT; SDOUT shifts on BCLK falling edges and SDIN is sampled on rising edges.
- BCLK, LRCK and SDIN are synchronised to the system clock.
- Interrupt FRAME on every LRCK transition (frame sync, twice per stereo frame).

bclk, lrck, sdin and sdout are the I2S pins; they pass through unchanged. BCLK and LRCK are sampled on clk, so PCLK must run at 7 x BCLK or more (8 x recommended): SDOUT changes up to two PCLK periods after a BCLK falling edge, and the I2S transmitter limit (valid 0.8 T after the previous rising edge) leaves 0.3 T for that and the pad delay. SDIN is sampled in the PCLK cycle after the BCLK rise, so the master must hold it one PCLK past the rise (any master that changes SDIN on the falling edge does).

## Files

| File | Content |
|---|---|
| `rtl/I2S_top.sv` | protocol core |
| `rtl/I2S_apb.sv` | APB4 register wrapper (generated) |
| `tb/I2S_tb.sv` | core testbench |
| `tb/I2S_apb_tb.sv`, `tb/apb/I2S_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/I2S_sva.sv`, `tb/cov/I2S_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/I2S.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`I2S_apb` has the core's parameters and passes them to `I2S_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `16` |

## Wrapper pins

Pins of `I2S_apb`. Widths of the pass-through pins are at the default parameters.

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
| `bclk` | input | 1 | protocol pin, core port `bclk` |
| `lrck` | input | 1 | protocol pin, core port `lrck` |
| `sdin` | input | 1 | protocol pin, core port `sdin` |
| `sdout` | output | 1 | protocol pin, core port `sdout` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `bclk` | input | 1 | pin (pass-through) |
| `lrck` | input | 1 | pin (pass-through) |
| `sdin` | input | 1 | pin (pass-through) |
| `sdout` | output | 1 | pin (pass-through) |
| `wen` | input | 1 | write to a CORE word |
| `waddr` | input | 4 | CORE word index |
| `wdata` | input | 16 | CORE write data |
| `ren` | input | 1 | read of a CORE word |
| `raddr` | input | 4 | CORE word index |
| `rdata` | output | 16 | CORE read data |
| `irq` | output | 1 | IRQ_STATUS.FRAME |

## APB wrapper

`I2S_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `bclk`, `lrck`, `sdin`, `sdout`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x49320200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX_LEFT | WO (core) | core | Left sample sent in each left slot (write-only) |
| 0x018 | TX_RIGHT | WO (core) | core | Right sample sent in each right slot (write-only) |
| 0x01C | RX_LEFT | RO (core) | core | Last left sample received |
| 0x020 | RX_RIGHT | RO (core) | core | Last right sample received |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4932 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX_LEFT | 15:0 | core register | WO (core) | core | written at core register 0 |
| TX_RIGHT | 15:0 | core register | WO (core) | core | written at core register 1 |
| RX_LEFT | 15:0 | core register | RO (core) | core | read from core register 0 |
| RX_RIGHT | 15:0 | core register | RO (core) | core | read from core register 1 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FRAME | LRCK changed (a channel slot started) |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x49320200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.I2S sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.I2S syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/I2S_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.I2S apb` | `TEST PASSED: I2S_apb`, then Yosys without `ERROR` | console, `work/I2S_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh I2S`<br>`bash scripts/cov/run_cov.sh I2S_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/I2S/score.json`, `work/cov/I2S_apb/score.json` |

Expected end of a step 4 run:

```
===== I2S =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/I2S_tb.sv`): drives `I2S_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/I2S_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/I2S_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/I2S_sva.sv`, `tb/cov/I2S_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/I2S_top.sv` | pass | 37/37 | 356/356 | n/a | 4/4 | 52/52 |
| wrapper `rtl/I2S_apb.sv` | pass | 21/21 | 476/476 | n/a | 11/11 | 32/32 |
