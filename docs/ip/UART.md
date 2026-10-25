# UART (8N1)

Protocol IP `UART`, version 2.0. Apache-2.0.

## Overview

UART 8N1 transceiver with 16x oversampled RX

- Baud tick: tick16 every CLK_FREQ/BAUD/16 clocks (free-running).
- TX: tx_valid/tx_ready handshake; start bit, 8 data bits LSB first,
one stop bit, 16 ticks per bit. tx_ready is high only while idle.
- RX: 2-flop synchroniser, falling-edge start detection, start bit
re-checked at its middle (a shorter low pulse is a glitch and is
ignored), data and stop bits sampled at their middles. A frame whose
stop bit samples 0 is a framing error: it is dropped and pulses irq.
Hunting for the next start bit begins at the middle of the stop bit.
- irq: one-clock pulse per received byte (with rx_valid) or framing error.

A framing error sets IRQ_STATUS.CORE without RXDATA_AVAIL; a received byte sets both.

## Files

| File | Content |
|---|---|
| `rtl/UART_top.sv` | protocol core |
| `rtl/UART_apb.sv` | APB4 register wrapper (generated) |
| `tb/UART_tb.sv` | core testbench |
| `tb/UART_apb_tb.sv`, `tb/apb/UART_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/UART_sva.sv`, `tb/cov/UART_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/UART.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.UART sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.UART apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh UART          # core coverage (Verilator)
bash scripts/cov/run_cov.sh UART_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rxd` | input | 1 | pin (pass-through) |
| `txd` | output | 1 | pin (pass-through) |
| `tx_data` | input | 8 | TXDATA[7:0] |
| `tx_valid` | input | 1 | TXDATA commit / FLAGS |
| `tx_ready` | output | 1 | TXDATA handshake |
| `rx_data` | output | 8 | RXDATA[7:0] |
| `rx_valid` | output | 1 | RXDATA capture |
| `irq` | output | 1 | IRQ_STATUS.CORE |

## APB wrapper

`UART_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxd`, `txd`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55410200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TXDATA | RW | 0x00000000 | Byte to transmit |
| 0x018 | RXDATA | RO (pop) | 0x00000000 | Received byte |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5541 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| TXDATA | 7:0 | `tx_data` | Byte to transmit |
| RXDATA | 7:0 | `rx_data` | Received byte |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CORE | core irq: a byte was received or a framing error occurred |
| 1 | TXDATA_DONE | TXDATA beat accepted by the core |
| 2 | TXDATA_OVF | write to TXDATA while full (dropped) |
| 3 | RXDATA_AVAIL | RXDATA captured a beat |
| 4 | RXDATA_OVF | beat dropped, RXDATA was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TXDATA_FULL | TXDATA holds a beat the core has not taken |
| 1 | RXDATA_AVAIL | RXDATA holds an unread beat |

### Streams

* **TXDATA** feeds `tx_data`/`tx_valid`. Writing TXDATA commits the beat: FLAGS.TXDATA_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TXDATA_DONE is set. A write while full is dropped and sets TXDATA_OVF.
* **RXDATA** captures `rx_data` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RXDATA_AVAIL. Reading RXDATA pops it. A beat that arrives while the register is full is dropped and sets RXDATA_OVF.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/UART_top.sv` | pass | 59/59 | 130/130 | 17/17 | 8/8 | 140/140 |
| wrapper `rtl/UART_apb.sv` | pass | 30/30 | 502/502 | n/a | 9/9 | 51/51 |
