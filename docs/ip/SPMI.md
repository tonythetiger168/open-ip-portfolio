# SPMI-style target: sequence start, a header of slave address 5 and command, a register address, then a register write (acknowledged) or read

Protocol IP `SPMI`, version 2.0. Apache-2.0.

## Overview

MIPI SPMI slave: SSC + SA[3:0] + CMD[3:0] + AD[7:0] + DATA[7:0] Simplified command set: CMD 0x0 = register write, 0x1 = register read. Two-wire open-drain style, OpenCores spmi/pmic bus pattern.


sdata (open drain: the target only pulls it low for the ACK and read data) and sclk are the bus pins; they pass through unchanged. Each SCLK phase must last at least three PCLK clocks.
Frame: SSC (SDATA falling while SCLK is high), header {SA[3:0], CMD[3:0]} then the register address, MSB first, sampled on SCLK rising. CMD 0: a data byte follows and the target ACKs it by holding SDATA low for the next bit; CMD 1: the target sends TX on the next 8 bits, each driven from an SCLK fall. Other commands and slave addresses are ignored. This is a simplified SPMI framing: no parity bits, bus park or arbitration.

## Files

| File | Content |
|---|---|
| `rtl/SPMI_top.sv` | protocol core |
| `rtl/SPMI_apb.sv` | APB4 register wrapper (generated) |
| `tb/SPMI_tb.sv` | core testbench |
| `tb/SPMI_apb_tb.sv`, `tb/apb/SPMI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SPMI_sva.sv`, `tb/cov/SPMI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SPMI.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.SPMI sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.SPMI apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh SPMI          # core coverage (Verilator)
bash scripts/cov/run_cov.sh SPMI_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sdata` | inout | 1 | pin (pass-through) |
| `sclk` | input | 1 | pin (pass-through) |
| `rx_byte` | output | 8 | RX[7:0] |
| `rx_addr` | output | 8 | RX[15:8] |
| `rx_valid` | output | 1 | RX capture |
| `tx_byte` | input | 8 | TX[7:0] |
| `busy` | output | 1 | STATUS |
| `irq` | output | 1 | IRQ_STATUS.WRITE |

## APB wrapper

`SPMI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sdata`, `sclk`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x534D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW | 0x00000000 | Byte returned for a register read |
| 0x018 | RX | RO (pop) | 0x00000000 | Register writes received (data and register address); reading RX frees it |
| 0x01C | STATUS | RO | 0x00000000 | Target state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x534D |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| TX | 7:0 | `tx_byte` | taken when the register address of a read is complete, sent MSB first |
| RX | 7:0 | `rx_byte` | data written |
| RX | 15:8 | `rx_addr` | register address |
| STATUS | 0 | `busy` | in a command addressed to us |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | WRITE | a register write was received (the same clock RX captures it) |
| 1 | RX_AVAIL | RX captured a beat |
| 2 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | RX_AVAIL | RX holds an unread beat |

### Streams

* **RX** captures `rx_byte`, `rx_addr` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SPMI_top.sv` | pass | 44/44 | 162/162 | 12/12 | 6/6 | 11/11 |
| wrapper `rtl/SPMI_apb.sv` | pass | 28/28 | 518/518 | n/a | 8/8 | 42/42 |
