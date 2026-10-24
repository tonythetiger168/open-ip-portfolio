# SAS initiator: OOB (COMRESET / COMINIT) bring-up, then an SSP-style frame link (SOF, header, payload, CRC-32, EOF, ALIGN idle) with a built-in write / read-verify sequencer over a 16 x 32-bit register file

Protocol IP `SAS`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SAS_top` (`rtl/SAS_top.sv`) |
| Register interface | APB4 slave `SAS_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53410200 (code 0x5341, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 5 pass-through |

## Overview

SAS protocol Open IP -- SAS initiator (OOB + SSP frame link layer) Open IP design implementation v2.5 Implementation scope:

- OOB FSM: COMRESET-style burst/idle pattern (106 symbol burst + 318 symbol
idle), COMINIT exchange detection, then PHY READY. A burst is detected
when at least 64 consecutive '1's end.
- Link layer: ALIGN idle primitive (32'h7B4A4ABC) inserted between frames,
1 bit per bit time, MSB-first per 32-bit dword, tx_n = ~tx_p.
- The receiver hunts SOF bit by bit (dword alignment) and then takes
whole dwords until EOF.
- SSP frame: SOF(32'hA5A50001) + HDR{len[31:24],type[23:16],dst[15:8],
src[7:0]} + PAYLOAD(len x 32-bit, len<=16) + CRC32 + EOF(32'hA5A50002).
- CRC32: poly 32'h04C11DB7 (reflected form 32'hEDB88320), init all-ones,
input/output reflected, final XOR all-ones (Ethernet FCS style),
processed one 32-bit dword per step over HDR + PAYLOAD.
- Functional unit: 16x32-bit register file. type 8'h01 = write,
8'h02 = read request, 8'h83 = read response (payload[0] = reg value).
Only payload dword 0 is used; further dwords are CRC-checked only.
- Built-in initiator sequencer (SAS address 8'h01) issues write /
read-verify transactions with pseudo-random data (xorshift32) so the
IP exercises itself over the loopback link; a read response must come
from the register just written and carry the written value.
- irq: 1-clk pulse on CRC error or protocol violation (oversize len,
bad EOF, unknown frame type, bad register address, missing payload,
link timeout).
NOTE: refclk is kept for interface compatibility; this simplified model
uses clk as the line bit clock and does not use refclk. rx_n is the
inverted companion of rx_p and is not used by the simplified receiver
(single-ended sampling on rx_p).

tx_p / tx_n (serial out, 1 bit per PCLK), rx_p / rx_n (serial in; only rx_p is sampled) and refclk (unused by the simplified model) pass through unchanged. The initiator runs on its own after reset and verifies its own traffic over the link.
The registers report the link's error events; frame contents stay on the serial pins.

## Files

| File | Content |
|---|---|
| `rtl/SAS_top.sv` | protocol core |
| `rtl/SAS_apb.sv` | APB4 register wrapper (generated) |
| `tb/SAS_tb.sv` | core testbench |
| `tb/SAS_apb_tb.sv`, `tb/apb/SAS_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SAS_sva.sv`, `tb/cov/SAS_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SAS.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.SAS sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.SAS apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh SAS          # core coverage (Verilator)
bash scripts/cov/run_cov.sh SAS_apb      # wrapper coverage
```

## Parameters

`SAS_apb` has the core's parameters and passes them to `SAS_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `BIT_CLKS` | int | `1` |

## Wrapper pins

Pins of `SAS_apb`. Widths of the pass-through pins are at the default parameters.

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

`SAS_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_n`, `tx_p`, `rx_n`, `rx_p`, `refclk`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53410200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5341 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a received frame failed (CRC error, bad EOF, oversize length, unknown type, bad register address, missing payload) or a transaction timed out |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53410200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SAS_top.sv` | pass | 142/142 | 1050/1050 | 50/50 | 6/6 | 21/21 |
| wrapper `rtl/SAS_apb.sv` | pass | 19/19 | 402/402 | n/a | 7/7 | 23/23 |
