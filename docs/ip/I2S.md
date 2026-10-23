# I2S slave transmitter and receiver: 16-bit samples, left and right channels, Philips timing (MSB one BCLK after LRCK)

Protocol IP `I2S`, version 2.0. Apache-2.0.

## Overview

I2S slave transmitter/receiver, 16-bit samples, 2 channels Samples SDIN on BCLK rise, shifts SDOUT on BCLK fall, with the I2S standard one-BCLK data delay after each LRCK transition.


bclk, lrck, sdin and sdout are the I2S pins; they pass through unchanged. BCLK and LRCK are sampled on clk: each BCLK phase must last at least two clocks.

## Files

| File | Content |
|---|---|
| `rtl/I2S_top.sv` | protocol core |
| `rtl/I2S_apb.sv` | APB4 register wrapper (generated) |
| `tb/I2S_tb.sv` | core testbench |
| `tb/I2S_apb_tb.sv`, `tb/apb/I2S_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/I2S_sva.sv`, `tb/cov/I2S_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/I2S.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.I2S sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.I2S apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh I2S          # core coverage (Verilator)
bash scripts/cov/run_cov.sh I2S_apb      # wrapper coverage
```

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
| 0x014 | TX_LEFT | WO (core) | 0x00000000 | Left sample sent in each left slot (write-only) |
| 0x018 | TX_RIGHT | WO (core) | 0x00000000 | Right sample sent in each right slot (write-only) |
| 0x01C | RX_LEFT | RO (core) | 0x00000000 | Last left sample received |
| 0x020 | RX_RIGHT | RO (core) | 0x00000000 | Last right sample received |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4932 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| TX_LEFT | 15:0 | core register | written at core register 0 |
| TX_RIGHT | 15:0 | core register | written at core register 1 |
| RX_LEFT | 15:0 | core register | read from core register 0 |
| RX_RIGHT | 15:0 | core register | read from core register 1 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FRAME | LRCK changed (a channel slot started) |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/I2S_top.sv` | pass | 37/37 | 356/356 | n/a | 4/4 | 10/10 |
| wrapper `rtl/I2S_apb.sv` | not run | | | | | |
