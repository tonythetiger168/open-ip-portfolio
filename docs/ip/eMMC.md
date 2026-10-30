# eMMC host: RST_n pulse and power-up, CMD0 / CMD1 (busy polling) / CMD2 / CMD3 / CMD7 initialisation, then repeated CMD24 write and CMD17 read-back compare rounds in 1-bit mode, with R1 / R2 / R3 framing, CRC7, card-status, CRC16, CRC status token, busy and timeout checks

Protocol IP `eMMC`, version 3.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `eMMC_top` (`rtl/eMMC_top.sv`) |
| Register interface | APB4 slave `eMMC_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x654D0300 (code 0x654D, version 3.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 4 pass-through |

## Overview

eMMC protocol Open IP -- eMMC host: hardware reset (RST_n), CMD0/CMD1/ CMD2/CMD3/CMD7 init sequence, CMD24/CMD17 single-block read/write in Open IP design implementation v3.0 Bus timing:

- The host drives the device: emmc_clk (CLK) is generated from clk by an
even divider, ID_CLK_DIV during identification (CMD0 .. CMD3, which
JESD84 limits to 400 kHz: the default 128 meets that for clk up to
51.2 MHz) and CLK_DIV from CMD7 on. CMD / DAT0 are sampled on the CLK
rising edge and change on the falling edge.
- emmc_rst_n is the device's RST_n, an output: after rst_n it is held
low RST_LOW clk cycles (tRSTW), then high RST_WAIT clk cycles (tRSCA)
before the host gives the 74 CLK cycles of the power-up sequence and
sends CMD0.
- The response start bit is looked for from N_CR = 2 up to 64 clocks;
the CRC status token within 64 clocks. Read access (data start bit)
and write busy have their own limits, RD_TIMEOUT and BUSY_TIMEOUT
CLK cycles (defaults 100 ms and 250 ms at 26 MHz).
- CMD3 assigns RCA 1; CMD7 then selects the device (stand-by to
transfer state) before any CMD24 / CMD17. CMD7's R1b busy on DAT0 is
waited out in the idle gap (BUSY_TIMEOUT).
Documented simplifications (SPEC section 2.5):
- Block length is 32 bytes (256 bits) instead of the eMMC-native 512 bytes.
- 1-bit bus mode only: host drives/samples dat[0]; dat[7:1] stay high-Z.
- The host autonomously repeats demo rounds: CMD24 write of an internal
pattern block, then CMD17 read of the same block with read-back compare.
Round n uses block address n[1:0]. Status is observable via internal
state (TB hierarchical reference) and irq pulses.
- Response checks: R1 (CMD3/24/17) start + transmission bits, command
index, CRC7, end bit and the card-status error bits (ERR_MASK); R3
framing (start, transmission, reserved 111111 fields, end bit); R2
framing (start, transmission, 111111) and the CID's own CRC7 with
CID[0] = 1. A failed check raises irq: framing / CRC -> err_crc7,
status bits -> err_status.
- Write: after the end bit the card returns the CRC status token
(0, 3 status bits, 1); 010 = accepted, anything else -> err_crc16.
The host then waits for the card to release DAT0 busy.

The core runs on PCLK and drives the device: emmc_clk (CLK) is PCLK / ID_CLK_DIV (128: at most 400 kHz for PCLK up to 51.2 MHz) during identification and PCLK / CLK_DIV (2) from CMD7 on; emmc_rst_n (RST_n) is an output, held low RST_LOW PCLK cycles after PRESETN and then high RST_WAIT cycles (tRSCA) before the 74 power-up clocks and CMD0. cmd and dat[7:0] (bidirectional, need pull-ups; only DAT0 is used) pass through unchanged; CMD / DAT0 change on the CLK falling edge and are sampled on the rising edge. Responses are looked for from N_CR = 2 to 64 clocks; read access and write busy have their own limits, RD_TIMEOUT and BUSY_TIMEOUT CLK cycles (defaults 100 ms and 250 ms at 26 MHz). CMD7 selects the device (RCA 1) before any transfer. The host initialises the device and runs its write / read-back rounds on its own.
Blocks are 32 bytes (the slice's simplification of 512).

## Files

| File | Content |
|---|---|
| `rtl/eMMC_top.sv` | protocol core |
| `rtl/eMMC_apb.sv` | APB4 register wrapper (generated) |
| `tb/eMMC_tb.sv` | core testbench |
| `tb/eMMC_apb_tb.sv`, `tb/apb/eMMC_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/eMMC_sva.sv`, `tb/cov/eMMC_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/eMMC.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`eMMC_apb` has the core's parameters and passes them to `eMMC_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `CLK_DIV` | int | `2` |
| `ID_CLK_DIV` | int | `128` |
| `RST_LOW` | int | `64` |
| `RST_WAIT` | int | `16384` |
| `RD_TIMEOUT` | int | `2600000` |
| `BUSY_TIMEOUT` | int | `6500000` |

## Wrapper pins

Pins of `eMMC_apb`. Widths of the pass-through pins are at the default parameters.

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
| `emmc_clk` | output | 1 | protocol pin, core port `emmc_clk` |
| `cmd` | inout | 1 | protocol pin, core port `cmd` |
| `dat` | inout | 8 | protocol pin, core port `dat` |
| `emmc_rst_n` | output | 1 | protocol pin, core port `emmc_rst_n` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `emmc_clk` | output | 1 | pin (pass-through) |
| `cmd` | inout | 1 | pin (pass-through) |
| `dat` | inout | 8 | pin (pass-through) |
| `emmc_rst_n` | output | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`eMMC_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `emmc_clk`, `cmd`, `dat`, `emmc_rst_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x654D0300 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x654D | IP code |
| ID | 15:8 | MAJOR | RO | 0x03 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a response, CRC status, busy or read phase failed (framing, CRC7, command index, card-status error bits, timeout, negative or missing CRC status, busy timeout, read CRC16 / end bit / compare); the host retries |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x654D0300.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.eMMC sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.eMMC syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/eMMC_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.eMMC apb` | `TEST PASSED: eMMC_apb`, then Yosys without `ERROR` | console, `work/eMMC_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh eMMC`<br>`bash scripts/cov/run_cov.sh eMMC_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/eMMC/score.json`, `work/cov/eMMC_apb/score.json` |

Expected end of a step 4 run:

```
===== eMMC =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/eMMC_tb.sv`): drives `eMMC_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/eMMC_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/eMMC_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/eMMC_sva.sv`, `tb/cov/eMMC_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/eMMC_top.sv` | pass | 120/120 | 1622/1622 | 17/17 | 6/6 | 64/64 |
| wrapper `rtl/eMMC_apb.sv` | pass | 19/19 | 412/412 | n/a | 7/7 | 23/23 |
