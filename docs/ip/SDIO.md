# SDIO card (function 1, 4-bit bus): CMD52 IO_RW_DIRECT and CMD53 IO_RW_EXTENDED (byte mode, incrementing or fixed address) over a 128 x 8 register file, R5 responses with error flags, CRC7, CRC16 data blocks and CRC status tokens

Protocol IP `SDIO`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SDIO_top` (`rtl/SDIO_top.sv`) |
| Register interface | APB4 slave `SDIO_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53490200 (code 0x5349, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 3 pass-through |

## Overview

SDIO protocol Open IP -- SDIO card/slave (CMD52/CMD53, R5, CRC7/CRC16) Open IP design implementation v2.5 Scope: card-side SDIO subset, function 1 only, 4-bit bus. * CMD line: host drives a command (card Hi-Z), the card drives R5. Everything is sampled / driven on sd_clk rising edges. * Frame: start(0) + tx(1 host / 0 card) + cmdidx[6] + arg[32] + CRC7[7] + end(1), 48 bits, MSB first. CRC7 poly x^7+x^3+1. * CMD52 IO_RW_DIRECT: arg[31] r/w, [30:28] function, [27] RAW, [25:9] register address, [7:0] write data. The R5 data field is the register value (after the write for a write; with RAW = 0 this is the written value as well, the register file has no side effects). * CMD53 IO_RW_EXTENDED: arg[31] r/w, [30:28] function, [27] block mode (not supported: ILLEGAL_COMMAND), [26] OP code (1 = incrementing address), [25:9] address, [8:0] byte count (0 = 512). * Function 1 register file: 128 x 8 bit, addresses 0..127. * R5: start, tx = 0, index, 16 stuff bits, flags[7:0], data[7:0], CRC7, end. Flags: [7] COM_CRC_ERROR and [6] ILLEGAL_COMMAND report an error of the previous command (that command got no response) and clear once reported; [5:4] IO_CURRENT_STATE = 01 (CMD); [1] FUNCTION_NUMBER for a function other than 1; [0] OUT_OF_RANGE for an address above 127, a CMD53 count above 32 (the transfer buffer) or an incrementing transfer that runs past address 127. A command with [1] or [0] set is answered but not executed, and has no data phase. * Data phase on DAT[3:0], 4-bit mode, both directions: start 0000, 2 nibbles per byte (high nibble first), one CRC16-CCITT per line (16 clocks), end 1111. write: after the end bits and 2 clocks the card drives the CRC status token on DAT0: 0 + 010 (accepted) or 101 (CRC error) + 1. The block is committed only when accepted. read : the card sends the block 2 clocks after its R5. * Bad CRC7, bad framing or an unsupported command index: no response, flag for the next R5, irq pulse. Bad data CRC16 / end bits, or no write block start within 64 clocks: irq pulse, block discarded. Note: `clk` is the reserved system clock; the card runs on sd_clk.

sd_clk (in), cmd and dat[3:0] (bidirectional, need pull-ups) are the SDIO bus; they pass through unchanged. The card runs on sd_clk; sd_clk must be synchronous to PCLK and at most PCLK / 2 so that every error pulse is seen.
The register file is reached over the SDIO bus only; the registers report the card's error events.

## Files

| File | Content |
|---|---|
| `rtl/SDIO_top.sv` | protocol core |
| `rtl/SDIO_apb.sv` | APB4 register wrapper (generated) |
| `tb/SDIO_tb.sv` | core testbench |
| `tb/SDIO_apb_tb.sv`, `tb/apb/SDIO_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SDIO_sva.sv`, `tb/cov/SDIO_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SDIO.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.SDIO sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.SDIO apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh SDIO          # core coverage (Verilator)
bash scripts/cov/run_cov.sh SDIO_apb      # wrapper coverage
```

## Parameters

`SDIO_apb` has the core's parameters and passes them to `SDIO_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `BIT_CLKS` | int | `1` |

## Wrapper pins

Pins of `SDIO_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sd_clk` | input | 1 | protocol pin, core port `sd_clk` |
| `cmd` | inout | 1 | protocol pin, core port `cmd` |
| `dat` | inout | 4 | protocol pin, core port `dat` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sd_clk` | input | 1 | pin (pass-through) |
| `cmd` | inout | 1 | pin (pass-through) |
| `dat` | inout | 4 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`SDIO_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sd_clk`, `cmd`, `dat`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53490200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5349 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a command was dropped (bad CRC7, bad framing, unsupported index or block mode) or a data block was discarded (bad CRC16 or end bits, no write block within 64 clocks) |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53490200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SDIO_top.sv` | pass | 93/93 (+1 excl.) | 1342/1342 | 30/30 | 5/5 | 67/67 |
| wrapper `rtl/SDIO_apb.sv` | pass | 19/19 | 404/404 | n/a | 7/7 | 23/23 |
