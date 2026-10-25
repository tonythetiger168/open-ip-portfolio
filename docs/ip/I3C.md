# I3C target (SDR framing on the two-wire base): START / STOP detection, 7-bit address 0x2A, ACK, bytes both ways, an in-band interrupt request after each write

Protocol IP `I3C`, version 2.0. Apache-2.0.

## Overview

I3C slave (SDR-compatible I2C framing) + in-band interrupt request (IBI) Reuses the I2C two-wire base; int_n is asserted after a write transaction (interrupt pending) and released by the next START (master acknowledges IBI).


sda (open drain: the target only pulls it low) and scl are the bus pins; they pass through unchanged. SCL and SDA are sampled on PCLK, so each SCL phase must last at least three PCLK clocks.
The address is the core parameter I3C_ADDR (0x2A). Another address is ignored until the next START or STOP. Dynamic addressing, CCCs, HDR modes and the IBI arbitration on SDA are not implemented.

## Files

| File | Content |
|---|---|
| `rtl/I3C_top.sv` | protocol core |
| `rtl/I3C_apb.sv` | APB4 register wrapper (generated) |
| `tb/I3C_tb.sv` | core testbench |
| `tb/I3C_apb_tb.sv`, `tb/apb/I3C_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/I3C_sva.sv`, `tb/cov/I3C_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/I3C.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.I3C sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.I3C apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh I3C          # core coverage (Verilator)
bash scripts/cov/run_cov.sh I3C_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sda` | inout | 1 | pin (pass-through) |
| `scl` | input | 1 | pin (pass-through) |
| `tx_byte` | input | 8 | TX[7:0] |
| `rx_byte` | output | 8 | RX[7:0] |
| `rx_valid` | output | 1 | RX capture |
| `int_n` | output | 1 | STATUS[1:1] |
| `busy` | output | 1 | STATUS[0:0] |
| `irq` | output | 1 | IRQ_STATUS.BYTE |

## APB wrapper

`I3C_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sda`, `scl`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x49330200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW | 0x00000000 | Byte returned to the controller on reads |
| 0x018 | RX | RO (pop) | 0x00000000 | Bytes written by the controller (acknowledged); reading RX frees it |
| 0x01C | STATUS | RO | 0x00000000 | Target state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4933 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| TX | 7:0 | `tx_byte` | sent MSB first for every byte of a read, until the controller NACKs; read bit by bit as the byte goes out (the MSB at the SCL fall ending the address or the previous ACK), so change it only between a byte's last bit and the ACK clock that follows |
| RX | 7:0 | `rx_byte` | Bytes written by the controller (acknowledged); reading RX frees it |
| STATUS | 0 | `busy` | addressed: between our address and the STOP or the NACK |
| STATUS | 1 | `int_n` | IBI request, active low: set by the STOP that ends a write, released by the next START |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BYTE | a byte was received (the same clock RX captures it) |
| 1 | RX_AVAIL | RX captured a beat |
| 2 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | RX_AVAIL | RX holds an unread beat |

### Streams

* **RX** captures `rx_byte` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/I3C_top.sv` | pass | 47/47 | 114/114 | 17/17 | 22/22 | 23/23 |
| wrapper `rtl/I3C_apb.sv` | pass | 28/28 | 488/488 | n/a | 8/8 | 42/42 |
