# MIPI I3C target: legacy I2C register access on static address 0x3C (16 x 8-bit registers), ENTDAA dynamic address assignment with arbitration, RSTDAA, GETPID, and in-band interrupts

Protocol IP `MIPI_I3C`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `MIPI_I3C_top` (`rtl/MIPI_I3C_top.sv`) |
| Register interface | APB4 slave `MIPI_I3C_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x4D330200 (code 0x4D33, version 2.0) |
| Registers | 8 words, 0x000 to 0x01C |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 2 pass-through |

## Overview

MIPI I3C protocol IP -- I3C slave controller Implementation scope:

- Legacy I2C write/read on a 7-bit static address (16x8 register file);
the first written byte is the register pointer (0..15, larger -> NACK)
- Broadcast CCCs (7E/W + code): ENTDAA (0x07), RSTDAA (0x06), and the
direct CCC GETPID (0x8C): after Sr + own address / R the slave returns
its 6 PID bytes. Unknown codes are NACKed and raise irq.
- ENTDAA dynamic address assignment: a slave without a dynamic address
answers 7E/R with 48-bit PID + BCR + DCR (open-drain, with arbitration:
a slave that loses drops out and retries on the next 7E/R), then takes
the 7-bit dynamic address if its odd parity bit is right (else NACK +
irq). 7E/R inside ENTDAA with nothing left to do is NACKed silently;
7E/R outside ENTDAA is NACKed with irq.
- IBI (in-band interrupt, only with a dynamic address): slave pulls SDA
while bus idle, arbitrates its dynamic address, then pushes one IBI
data byte. Losing the arbitration raises irq; a NACK keeps the
request for a retry.
- irq is held until the next START (or rst_n)
- Data bytes are ACKed like I2C (the I3C T-bit is not modelled)
- Open-drain vs push-pull phase switching (address/arbitration phases are
open-drain, data transmit phases are push-pull -- simplified, the pad is
a shared clk-domain model so both are driven from the same enable logic)

scl (in) and sda (open drain, needs a pull-up) are the I3C bus; they pass through unchanged. SCL phases must last at least three PCLK clocks.
PID 0x0123456789AB, BCR 0x06, DCR 0x5A (core parameter defaults). The 16 registers are reached over the bus only (first written byte = pointer).

## Files

| File | Content |
|---|---|
| `rtl/MIPI_I3C_top.sv` | protocol core |
| `rtl/MIPI_I3C_apb.sv` | APB4 register wrapper (generated) |
| `tb/MIPI_I3C_tb.sv` | core testbench |
| `tb/MIPI_I3C_apb_tb.sv`, `tb/apb/MIPI_I3C_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/MIPI_I3C_sva.sv`, `tb/cov/MIPI_I3C_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/MIPI_I3C.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.MIPI_I3C sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.MIPI_I3C apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh MIPI_I3C          # core coverage (Verilator)
bash scripts/cov/run_cov.sh MIPI_I3C_apb      # wrapper coverage
```

## Parameters

`MIPI_I3C_apb` has the core's parameters and passes them to `MIPI_I3C_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `STATIC_ADDR` | logic [6:0] | `7'h3C` |
| `PID` | logic [47:0] | `48'h0123_4567_89AB` |
| `BCR` | logic [7:0] | `8'h06` |
| `DCR` | logic [7:0] | `8'h5A` |

## Wrapper pins

Pins of `MIPI_I3C_apb`. Widths of the pass-through pins are at the default parameters.

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
| `scl` | input | 1 | protocol pin, core port `scl` |
| `sda` | inout | 1 | protocol pin, core port `sda` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `scl` | input | 1 | pin (pass-through) |
| `sda` | inout | 1 | pin (pass-through) |
| `ibi_req` | input | 1 | CMD |
| `ibi_data` | input | 8 | IBI[7:0] |
| `dyn_addr` | output | 7 | STATUS[6:0] |
| `dyn_addr_valid` | output | 1 | STATUS[7:7] |
| `irq` | output | 1 | IRQ_STATUS.PROTO |

## APB wrapper

`MIPI_I3C_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `scl`, `sda`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4D330200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x018 | IBI | RW | 0x00000000 | In-band interrupt payload |
| 0x01C | STATUS | RO | core | Dynamic address |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x020 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4D33 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD | 0 | `ibi_req` | WO (pulse) | 0x0 | write 1: request an in-band interrupt carrying IBI.ibi_data; held until a dynamic address is assigned and the bus is idle, kept after a NACK, dropped after a lost arbitration |
| IBI | 7:0 | `ibi_data` | RW | 0x0 | the IBI data byte (read when the IBI goes out) |
| STATUS | 6:0 | `dyn_addr` | RO | core | dynamic address assigned by ENTDAA |
| STATUS | 7 | `dyn_addr_valid` | RO | core | a dynamic address is assigned (cleared by RSTDAA) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PROTO | protocol error or IBI arbitration lost: register pointer out of range, unknown CCC, 7E/R outside ENTDAA, ENTDAA parity error, lost IBI. Held in the core until the next START, so the bit is set again on every clock until then |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4D330200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write IBI (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. To issue a command, write 1 to `ibi_req` (CMD bit 0) at 0x014; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x01C) for the core's live `dyn_addr`, `dyn_addr_valid`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/MIPI_I3C_top.sv` | pass | 123/123 (+1 excl.) | 500/500 | 39/39 | 7/7 | 20/20 |
| wrapper `rtl/MIPI_I3C_apb.sv` | pass | 25/25 | 454/454 | n/a | 9/9 | 30/30 |
