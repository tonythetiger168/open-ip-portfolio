# MIPI HSI (High-Speed Synchronous Interface) link endpoint, frame mode

Protocol IP `HSI`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `HSI_top` (`rtl/HSI_top.sv`) |
| Register interface | APB4 slave `HSI_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x48530200 (code 0x4853, version 2.0) |
| Registers | 12 words, 0x000 to 0x02C |
| Interrupts | 9 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 8 pass-through |

## Overview

HSI_top v2.0: MIPI HSI (High-Speed Synchronous Interface) link endpoint, frame mode, one transmitter and one receiver

- Signalling: DATA / FLAG (data-strobe): every bit changes exactly one
of the two lines; DATA carries the bit, FLAG toggles when the bit
equals the previous one. A bit lasts cfg_div + 1 clocks (cfg_div >= 3
on both ends).
- Frame: start bit 1, cfg_chbits channel bits (0..4, larger values
count as 4), 32 data bits, each field MSB first.
- Flow control (synchronised data flow): the transmitter starts a frame
only while the peer's READY is high (sampled through two flops). The
receiver drives READY while it is enabled, the peer's WAKE is high and
its 4-frame FIFO has room for one more frame besides the one arriving.
- WAKE: the transmitter raises WAKE while it has a frame to send, is
sending, or cfg_wake forces it.
- Break: tx_brk sends 33 + channel bits zeros (once the transmitter is
idle, without waiting for READY). The receiver counts zeros between
frames: that many is a break (rx_break); fewer before a start bit is
err_stray.
- Receive errors: a frame that ends with the FIFO full is dropped
(err_overflow); both lines changing in one clock is err_ds (taken as
one bit); no bit for 4 bit times inside a frame drops it (err_timeout).
Not implemented: stream mode, pipelined data flow, more than 16
channels, the configuration / "receiver ready" handshake variants of
HSI 1.01 beyond the above.

tx_data / tx_flag / tx_wake and tx_ready_in are the transmit lines (tx_ready_in is the peer's READY); rx_data / rx_flag / rx_wake and rx_ready_out are the receive lines. All pass through unchanged.
The receive lines are synchronised inside the core; the transmit lines are registered.

## Files

| File | Content |
|---|---|
| `rtl/HSI_top.sv` | protocol core |
| `rtl/HSI_apb.sv` | APB4 register wrapper (generated) |
| `tb/HSI_tb.sv` | core testbench |
| `tb/HSI_apb_tb.sv`, `tb/apb/HSI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/HSI_sva.sv`, `tb/cov/HSI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/HSI.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.HSI sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.HSI apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh HSI          # core coverage (Verilator)
bash scripts/cov/run_cov.sh HSI_apb      # wrapper coverage
```

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `HSI_apb`. Widths of the pass-through pins are at the default parameters.

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
| `tx_data` | output | 1 | protocol pin, core port `tx_data` |
| `tx_flag` | output | 1 | protocol pin, core port `tx_flag` |
| `tx_ready_in` | input | 1 | protocol pin, core port `tx_ready_in` |
| `tx_wake` | output | 1 | protocol pin, core port `tx_wake` |
| `rx_data` | input | 1 | protocol pin, core port `rx_data` |
| `rx_flag` | input | 1 | protocol pin, core port `rx_flag` |
| `rx_ready_out` | output | 1 | protocol pin, core port `rx_ready_out` |
| `rx_wake` | input | 1 | protocol pin, core port `rx_wake` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_data` | output | 1 | pin (pass-through) |
| `tx_flag` | output | 1 | pin (pass-through) |
| `tx_ready_in` | input | 1 | pin (pass-through) |
| `tx_wake` | output | 1 | pin (pass-through) |
| `rx_data` | input | 1 | pin (pass-through) |
| `rx_flag` | input | 1 | pin (pass-through) |
| `rx_ready_out` | output | 1 | pin (pass-through) |
| `rx_wake` | input | 1 | pin (pass-through) |
| `cfg_div` | input | 8 | CFG[7:0] |
| `cfg_chbits` | input | 3 | CFG[10:8] |
| `cfg_rx_en` | input | 1 | CFG[11:11] |
| `cfg_wake` | input | 1 | CFG[12:12] |
| `txq_valid` | input | 1 | TX commit / FLAGS |
| `txq_ready` | output | 1 | TX handshake |
| `txq_ch` | input | 4 | TX0[3:0] |
| `txq_data` | input | 32 | TX1[31:0] |
| `tx_brk` | input | 1 | CMD |
| `tx_busy` | output | 1 | STATUS |
| `tx_done` | output | 1 | IRQ_STATUS.TX_SENT |
| `rxq_valid` | output | 1 | RX capture |
| `rxq_ready` | input | 1 | RX handshake |
| `rxq_ch` | output | 4 | RX0[3:0] |
| `rxq_data` | output | 32 | RX1[31:0] |
| `rx_break` | output | 1 | IRQ_STATUS.RX_BREAK |
| `err_overflow` | output | 1 | IRQ_STATUS.ERR_OVERFLOW |
| `err_stray` | output | 1 | IRQ_STATUS.ERR_STRAY |
| `err_ds` | output | 1 | IRQ_STATUS.ERR_DS |
| `err_timeout` | output | 1 | IRQ_STATUS.ERR_TIMEOUT |

## APB wrapper

`HSI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_data`, `tx_flag`, `tx_ready_in`, `tx_wake`, `rx_data`, `rx_flag`, `rx_ready_out`, `rx_wake`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x48530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000C07 | Link configuration |
| 0x018 | TX0 | RW | 0x00000000 | Frame to send; writing TX_DATA commits it. The core sends it once the peer's READY is high |
| 0x01C | TX1 | RW | 0x00000000 | Frame to send; writing TX_DATA commits it. The core sends it once the peer's READY is high |
| 0x020 | RX0 | RO (pop) | 0x00000000 | Received frame (head of the core's 4-frame FIFO); reading RX_DATA pops it |
| 0x024 | RX1 | RO (pop) | 0x00000000 | Received frame (head of the core's 4-frame FIFO); reading RX_DATA pops it |
| 0x028 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x02C | STATUS | RO | core | Transmitter state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4853 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 8:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 8:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 7:0 | `cfg_div` | RW | 0x7 | bit time - 1 in PCLK (3 or more on both ends) |
| CFG | 10:8 | `cfg_chbits` | RW | 0x4 | channel bits per frame (0..4; larger values count as 4) |
| CFG | 11 | `cfg_rx_en` | RW | 0x1 | receiver enabled (drives READY) |
| CFG | 12 | `cfg_wake` | RW | 0x0 | hold WAKE high while idle |
| TX0 | 3:0 | `txq_ch` | RW | 0x0 | channel |
| TX1 | 31:0 | `txq_data` | RW | 0x0 | frame data |
| RX0 | 3:0 | `rxq_ch` | RO (pop) | 0x0 | channel (upper bits 0 when fewer channel bits are used) |
| RX1 | 31:0 | `rxq_data` | RO (pop) | 0x0 | frame data |
| CMD | 0 | `tx_brk` | WO (pulse) | 0x0 | send a break (once the transmitter is idle; does not wait for READY) |
| STATUS | 0 | `tx_busy` | RO | core | a frame or break is being sent, or a break is pending |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_SENT | a frame was sent (TX_DONE is set earlier, when the core takes the frame) |
| 1 | RX_BREAK | a break was received |
| 2 | ERR_OVERFLOW | a frame arrived with the receive FIFO full and was dropped |
| 3 | ERR_STRAY | a start bit followed fewer zeros than a break |
| 4 | ERR_DS | DATA and FLAG changed in the same clock |
| 5 | ERR_TIMEOUT | no bit for 4 bit times inside a frame (frame dropped) |
| 6 | TX_DONE | TX beat accepted by the core |
| 7 | TX_OVF | write to TX while full (dropped) |
| 8 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `txq_ch`, `txq_data`/`txq_valid`. Writing TX1 commits the beat: FLAGS.TX_FULL is set and `txq_valid` stays high until the core's `txq_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rxq_ch`, `rxq_data` from the core with `rxq_valid` / `rxq_ready`: `rxq_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX1 pops it. Nothing is dropped: the core holds its data until the register is free.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x48530200.
2. Write 0x1FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x018) then TX1 (0x01C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x020) then RX1 (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 8) to clear it.
7. To issue a command, write 1 to `tx_brk` (CMD bit 0) at 0x028; the core sees a one-clock pulse, and the register reads 0.
8. Read STATUS (0x02C) for the core's live `tx_busy`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/HSI_top.sv` | pass | 51/51 | 920/920 | 11/11 | 15/15 | 33/33 |
| wrapper `rtl/HSI_apb.sv` | pass | 40/40 | 842/842 | n/a | 16/16 | 78/78 |
