# AVSBus voltage-control slave at address 0x55: START, address, command, 16-bit data, CRC4 and ACK over sclk / sdat, SET and GET of a 12-bit DAC code ramped at 10 codes per clock

Protocol IP `AVSBus__Adaptive_Voltage_Scaling_`, version 2.0. Apache-2.0.

## Overview

AVSBus (Adaptive Voltage Scaling, PMBus-style) -- synthesizable slave Scope: serial sclk/sdat (open-drain) frame interface: START + addr[6:0] + cmd[7:0] + data[15:0] + CRC4 + ACK/NACK slot, GET reads back {4'h0, vdac} + CRC4; set/get voltage commands with an internal 12-bit DAC code register and a voltage ramp FSM (10 mV/clk, 1 code = 1 mV). NACK on illegal address / bad CRC / unknown command / a SET code that does not fit the 12-bit DAC (data[15:12] != 0). A frame abandoned by the master (no sclk rise for TIMEOUT clk cycles) is dropped, so the next START is decoded from bit 0.


sclk and sdat (open drain: the slave only pulls it low, for the ACK and the GET readback) are the bus pins; they pass through unchanged. Both are sampled on PCLK, so each sclk phase must last at least three PCLK clocks. vdac and busy drive the regulator and are also readable in STATUS.
The voltage is set and read only over AVSBus (SET 0x01, GET 0x02); the APB side observes it. A frame with no sclk rise for TIMEOUT (1024) clocks is dropped. A frame to another address is not acknowledged and raises no interrupt.

## Files

| File | Content |
|---|---|
| `rtl/AVSBus__Adaptive_Voltage_Scaling__top.sv` | protocol core |
| `rtl/AVSBus__Adaptive_Voltage_Scaling__apb.sv` | APB4 register wrapper (generated) |
| `tb/AVSBus__Adaptive_Voltage_Scaling__tb.sv` | core testbench |
| `tb/AVSBus__Adaptive_Voltage_Scaling__apb_tb.sv`, `tb/apb/AVSBus__Adaptive_Voltage_Scaling__apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/AVSBus__Adaptive_Voltage_Scaling__sva.sv`, `tb/cov/AVSBus__Adaptive_Voltage_Scaling__apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/AVSBus__Adaptive_Voltage_Scaling_.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.AVSBus__Adaptive_Voltage_Scaling_ sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.AVSBus__Adaptive_Voltage_Scaling_ apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh AVSBus__Adaptive_Voltage_Scaling_          # core coverage (Verilator)
bash scripts/cov/run_cov.sh AVSBus__Adaptive_Voltage_Scaling__apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sclk` | input | 1 | pin (pass-through) |
| `sdat` | inout | 1 | pin (pass-through) |
| `vdac` | output | 12 | STATUS[11:0] |
| `busy` | output | 1 | STATUS[12:12] |
| `irq` | output | 1 | IRQ_STATUS.ERROR |

## APB wrapper

`AVSBus__Adaptive_Voltage_Scaling__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `sdat`, `vdac`, `busy`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41560200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | 0x00000000 | Voltage state, as driven on the pins |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4156 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| STATUS | 11:0 | `vdac` | current DAC code (1 code = 1 mV), moving 10 codes per clock toward the last target SET |
| STATUS | 12 | `busy` | high while vdac has not reached the target |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERROR | a frame to our address was NACKed for a bad CRC or a bad command (unknown command, or a SET code above 0xFFF) |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/AVSBus__Adaptive_Voltage_Scaling__top.sv` | pass | 51/51 (+1 excl.) | 352/352 | 12/12 | 5/5 | 11/11 |
| wrapper `rtl/AVSBus__Adaptive_Voltage_Scaling__apb.sv` | pass | 20/20 | 450/450 | n/a | 7/7 | 25/25 |
