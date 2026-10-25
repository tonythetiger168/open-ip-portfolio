# SD memory card host: CMD0 / CMD8 / ACMD41 / CMD2 / CMD3 / CMD7 initialisation, then repeated CMD24 write, CMD17 read-back compare and CMD13 status rounds in 4-bit mode, with R1 / R2 / R3 / R6 / R7 checks, CRC7 and CRC16

Protocol IP `SD`, version 2.0. Apache-2.0.

## Overview

SD protocol Open IP -- SD memory card host: CMD0/CMD8/ACMD41/CMD2/CMD3/CMD7 init sequence, CMD24/CMD17 single-block read/write in 4-bit DAT mode, CMD13 status poll, R1/R2/R3/R6/R7 response checking, CRC7/CRC16 Documented simplifications (educational slice of the SD physical layer):

- Block length is 32 bytes (256 bits) instead of the SD-native 512 bytes.
- 4-bit bus mode from the start (bus-width switch via ACMD6 is skipped;
the host is born in 4-bit mode, documented deviation).
- sd_clk is generated from clk by an even divider (parameter SD_CLK_DIV);
all host logic runs in the clk domain and advances one bus bit per
sd_clk period (internal "tick" aligned with the sd_clk rising edge).
- CMD7's R1b busy on DAT0 is simplified to plain R1 (no busy wait).
- Response / data-start / CRC-status / busy timeout is 64 sd_clk cycles.
- The host autonomously repeats demo rounds: CMD24 write of an internal
pattern block, CMD17 read-back compare, CMD13 status poll. Round n
uses block n[1:0]: the argument is the block number for a high
capacity card (OCR CCS = 1) and its byte address (n[1:0] * 32)
otherwise. Status is observable via internal state (TB hierarchical
reference) and irq pulses.
- Response checks: R1 (CMD55/7/24/17/13) start + transmission bits,
command index, CRC7, end bit and the card-status error bits
(ERR_MASK); R6 (CMD3) the same with its 16 status bits; R7 (CMD8)
framing plus the echoed voltage (1) and check pattern (0xAA); R3
framing (start, transmission, reserved 111111 fields, end bit); R2
framing (start, transmission, 111111) and the CID's own CRC7 with
CID[0] = 1. A failed check raises irq: framing / CRC -> err_crc7,
status bits -> err_status, R7 contents -> err_r7.
- Write: after the end bits the card returns the CRC status token on
DAT0 (0, 3 status bits, 1); 010 = accepted, anything else ->
err_crc16. The host then waits for the card to release DAT0 busy.
- Errors during init restart it with CMD0; errors in a round return to
the idle gap, which restarts the round.

sd_clk (PCLK / 4), cmd and dat[3:0] (bidirectional, need pull-ups) are the SD bus; they pass through unchanged. The host initialises the card and runs its write / read-back rounds on its own after reset.
Blocks are 32 bytes (the slice's simplification of 512).

## Files

| File | Content |
|---|---|
| `rtl/SD_top.sv` | protocol core |
| `rtl/SD_apb.sv` | APB4 register wrapper (generated) |
| `tb/SD_tb.sv` | core testbench |
| `tb/SD_apb_tb.sv`, `tb/apb/SD_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SD_sva.sv`, `tb/cov/SD_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SD.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.SD sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.SD apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh SD          # core coverage (Verilator)
bash scripts/cov/run_cov.sh SD_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sd_clk` | output | 1 | pin (pass-through) |
| `cmd` | inout | 1 | pin (pass-through) |
| `dat` | inout | 4 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`SD_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sd_clk`, `cmd`, `dat`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53440200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5344 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a response, CRC status, read block or busy phase failed (framing, CRC7, index, card-status error bits, R7 contents, negative CRC status, CRC16, end bit, read compare, timeout); the host retries |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SD_top.sv` | pass | 137/137 | 1850/1850 | 18/18 | 7/7 | 32/32 |
| wrapper `rtl/SD_apb.sv` | pass | 19/19 | 404/404 | n/a | 7/7 | 23/23 |
