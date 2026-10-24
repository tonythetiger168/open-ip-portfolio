# eMMC host: CMD0 / CMD1 (busy polling) / CMD2 / CMD3 initialisation, then repeated CMD24 write and CMD17 read-back compare rounds in 1-bit mode, with R1 / R2 / R3 framing, CRC7, card-status, CRC16, CRC status token, busy and timeout checks

Protocol IP `eMMC`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `eMMC_top` (`rtl/eMMC_top.sv`) |
| Register interface | APB4 slave `eMMC_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x654D0200 (code 0x654D, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 3 pass-through |

## Overview

eMMC protocol Open IP -- eMMC host: CMD0/CMD1/CMD2/CMD3 init sequence, CMD24/CMD17 single-block read/write in 1-bit DAT mode, CRC7/CRC16 checking Open IP design implementation v2.4 Documented simplifications (SPEC section 2.5):

- Block length is 32 bytes (256 bits) instead of the eMMC-native 512 bytes.
- 1-bit bus mode only: host drives/samples dat[0]; dat[7:1] stay high-Z.
- All host logic runs in the emmc_clk (bus clock) domain; clk is the
system clock and is reserved/unused internally (single-clock design).
- rst_n and emmc_rst_n are combined into one asynchronous reset (srst_n).
- Response wait timeout is 64 emmc_clk cycles (SPEC: N <= 64).
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

The core runs on PCLK as its eMMC bus clock (1 bit per PCLK); its unused system clock input is tied off. cmd and dat[7:0] (bidirectional, need pull-ups; only DAT0 is used) and emmc_rst_n (device reset, combined with PRESETN) pass through unchanged. The host initialises the device and runs its write / read-back rounds on its own.
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

```
make -f Makefile.eMMC sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.eMMC apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh eMMC          # core coverage (Verilator)
bash scripts/cov/run_cov.sh eMMC_apb      # wrapper coverage
```

## Parameters

`eMMC_apb` has the core's parameters and passes them to `eMMC_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `BIT_CLKS` | int | `1` |

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
| `cmd` | inout | 1 | protocol pin, core port `cmd` |
| `dat` | inout | 8 | protocol pin, core port `dat` |
| `emmc_rst_n` | input | 1 | protocol pin, core port `emmc_rst_n` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | tied to 1'b0 |
| `rst_n` | input | 1 | PRESETN |
| `emmc_clk` | input | 1 | PCLK |
| `cmd` | inout | 1 | pin (pass-through) |
| `dat` | inout | 8 | pin (pass-through) |
| `emmc_rst_n` | input | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`eMMC_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `cmd`, `dat`, `emmc_rst_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x654D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x654D | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
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

1. Release PRESETN. Read ID (0x000) and check it is 0x654D0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/eMMC_top.sv` | pass | 120/120 | 1622/1622 | 17/17 | 6/6 | 64/64 |
| wrapper `rtl/eMMC_apb.sv` | pass | 19/19 | 412/412 | n/a | 7/7 | 23/23 |
