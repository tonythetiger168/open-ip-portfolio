# UART (8N1)

Protocol IP `UART`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `UART_top` (`rtl/UART_top.sv`) |
| Register interface | APB4 slave `UART_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55410200 (code 0x5541, version 2.0) |
| Registers | 7 words, 0x000 to 0x018 |
| Interrupts | 5 sources into one level-high `irq` |
| Data streams | TXDATA (to the core), RXDATA (from the core) |
| Protocol pins | 2 pass-through |

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

## Parameters

`UART_apb` has the core's parameters and passes them to `UART_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `CLK_FREQ` | int | `50_000_000` |
| `BAUD` | int | `115_200` |

## Wrapper pins

Pins of `UART_apb`. Widths of the pass-through pins are at the default parameters.

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
| `rxd` | input | 1 | protocol pin, core port `rxd` |
| `txd` | output | 1 | protocol pin, core port `txd` |

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

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x01C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5541 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TXDATA | 7:0 | `tx_data` | RW | 0x0 | Byte to transmit |
| RXDATA | 7:0 | `rx_data` | RO (pop) | 0x0 | Received byte |

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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55410200.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
4. To send on TXDATA: wait until FLAGS.TXDATA_FULL (bit 0) is 0, or for IRQ TXDATA_DONE, then write TXDATA (0x014). The last write commits the beat. TXDATA_OVF means a write came while the register was full and was dropped.
5. To receive on RXDATA: wait for IRQ RXDATA_AVAIL or FLAGS.RXDATA_AVAIL (bit 1), then read RXDATA (0x018). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RXDATA_AVAIL (bit 3) to clear it. Read each beat before the next arrives, or it is dropped and RXDATA_OVF is set.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/UART_top.sv` | pass | 59/59 | 130/130 | 17/17 | 8/8 | 526/526 |
| wrapper `rtl/UART_apb.sv` | pass | 30/30 | 502/502 | n/a | 9/9 | 51/51 |
