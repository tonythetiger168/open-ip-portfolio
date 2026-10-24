# SLIMbus-style TDM bus interface (framer or device) with one transmit and one receive data channel

Protocol IP `MIPI_SLIMbus`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `MIPI_SLIMbus_top` (`rtl/MIPI_SLIMbus_top.sv`) |
| Register interface | APB4 slave `MIPI_SLIMbus_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x534C0200 (code 0x534C, version 2.0) |
| Registers | 11 words, 0x000 to 0x028 |
| Interrupts | 8 sources into one level-high `irq` |
| Data streams | SFSET (to the core), TX (to the core), RX (from the core) |
| Protocol pins | 6 pass-through |

## Overview

MIPI_SLIMbus_top v2.0: SLIMbus-style TDM bus interface (framer or device) with one transmit and one receive data channel

- Two-wire multi-drop bus: CLK from the framer, DATA NRZI coded (a 1
toggles the line, a 0 keeps it). A cell (one bit) per CLK period:
drivers change DATA after CLK rises, everyone samples as CLK falls.
A driver releases DATA once a cell is sampled (its CLK falling edge);
a bus keeper holds the level until the next driver.
- Frame: 192 slots of 4 cells, MSB first. Slot 0 carries the frame sync
1011, slot 96 four bits of the framing information (FI). Eight frames
make a superframe whose 32 FI bits are {8'h96 superframe sync,
cfg_fi, 16-bit superframe count}; sf_set loads the count sent in the
next superframe.
- Framer (cfg_framer = 1): drives CLK (a half period is cfg_div + 1
clocks), the frame sync and the FI. Device: samples CLK through two
flops (cfg_div >= 3 on the framer), hunts for the frame sync, locks
after seeing it in three frames in a row and loses lock after two
misses in a row, or after 16 frames without finding the superframe
(lost_sync); finds the superframe from the FI sync (sf_locked) and
reports every complete FI (fi_valid, fi_info, sf_count). The data
channels run only while sf_locked; an underrun sends zeros.
- Data channels (pushed protocol, once per frame): a
segment of 1 + 2 * len slots from slot cfg_*_slot: a TAG slot
{present, 000} and len bytes (1..4, MSB first). The transmitter takes
tx_data (the low len bytes) at the segment start when tx_valid, else
sends present = 0 and pulses tx_underrun. The receiver delivers
rx_data (the low len bytes) after a present segment; a TAG with
reserved bits set is rx_err. A segment must lie inside slots 1..95 or
97..191; otherwise the channel is off and cfg_err is high.
Not implemented: the message protocol (control space, arbitration,
enumeration, reconfiguration), clock gears and other transport
protocols, more than one channel per direction.

slim_clk_o / slim_clk_oe / slim_clk_i and slim_dat_o / slim_dat_oe / slim_dat_i are the bus pins (open drivers onto CLK and DATA; DATA needs a bus keeper); all pass through unchanged.

## Files

| File | Content |
|---|---|
| `rtl/MIPI_SLIMbus_top.sv` | protocol core |
| `rtl/MIPI_SLIMbus_apb.sv` | APB4 register wrapper (generated) |
| `tb/MIPI_SLIMbus_tb.sv` | core testbench |
| `tb/MIPI_SLIMbus_apb_tb.sv`, `tb/apb/MIPI_SLIMbus_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/MIPI_SLIMbus_sva.sv`, `tb/cov/MIPI_SLIMbus_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/MIPI_SLIMbus.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.MIPI_SLIMbus sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.MIPI_SLIMbus apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh MIPI_SLIMbus          # core coverage (Verilator)
bash scripts/cov/run_cov.sh MIPI_SLIMbus_apb      # wrapper coverage
```

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `MIPI_SLIMbus_apb`. Widths of the pass-through pins are at the default parameters.

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
| `slim_clk_o` | output | 1 | protocol pin, core port `slim_clk_o` |
| `slim_clk_oe` | output | 1 | protocol pin, core port `slim_clk_oe` |
| `slim_clk_i` | input | 1 | protocol pin, core port `slim_clk_i` |
| `slim_dat_o` | output | 1 | protocol pin, core port `slim_dat_o` |
| `slim_dat_oe` | output | 1 | protocol pin, core port `slim_dat_oe` |
| `slim_dat_i` | input | 1 | protocol pin, core port `slim_dat_i` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_framer` | input | 1 | CFG[0:0] |
| `cfg_div` | input | 4 | CFG[4:1] |
| `cfg_fi` | input | 8 | CFG[12:5] |
| `sf_set` | input | 1 | SFSET commit / FLAGS |
| `sf_set_val` | input | 16 | SFSET[15:0] |
| `cfg_tx_slot` | input | 8 | CHAN[7:0] |
| `cfg_tx_len` | input | 3 | CHAN[10:8] |
| `cfg_rx_slot` | input | 8 | CHAN[18:11] |
| `cfg_rx_len` | input | 3 | CHAN[21:19] |
| `cfg_err` | output | 1 | STATUS[2:2] |
| `slim_clk_o` | output | 1 | pin (pass-through) |
| `slim_clk_oe` | output | 1 | pin (pass-through) |
| `slim_clk_i` | input | 1 | pin (pass-through) |
| `slim_dat_o` | output | 1 | pin (pass-through) |
| `slim_dat_oe` | output | 1 | pin (pass-through) |
| `slim_dat_i` | input | 1 | pin (pass-through) |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 32 | TX[31:0] |
| `tx_underrun` | output | 1 | IRQ_STATUS.TX_UNDERRUN |
| `rx_valid` | output | 1 | RX capture |
| `rx_data` | output | 32 | RX[31:0] |
| `rx_err` | output | 1 | IRQ_STATUS.RX_ERR |
| `locked` | output | 1 | STATUS[0:0] |
| `sf_locked` | output | 1 | STATUS[1:1] |
| `lost_sync` | output | 1 | IRQ_STATUS.LOST_SYNC |
| `fi_valid` | output | 1 | IRQ_STATUS.FI |
| `fi_info` | output | 8 | STATUS[10:3] |
| `sf_count` | output | 16 | STATUS[26:11] |

## APB wrapper

`MIPI_SLIMbus_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `slim_clk_o`, `slim_clk_oe`, `slim_clk_i`, `slim_dat_o`, `slim_dat_oe`, `slim_dat_i`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x534C0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000006 | Role and framing |
| 0x018 | CHAN | RW | 0x00000801 | Data channel segments (TAG slot + 2 slots per byte, inside slots 1..95 or 97..191) |
| 0x01C | SFSET | RW | 0x00000000 | Framer: writing SFSET loads the superframe count sent in the next superframe |
| 0x020 | TX | RW | 0x00000000 | Transmit sample (the low CHAN.cfg_tx_len bytes); writing TX commits it for the next segment |
| 0x024 | RX | RO (pop) | 0x00000000 | Received sample; reading RX frees it |
| 0x028 | STATUS | RO | core | Lock and framing information |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x534C | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 7:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 7:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 0 | `cfg_framer` | RW | 0x0 | 1 = framer (drives CLK, frame sync and FI) |
| CFG | 4:1 | `cfg_div` | RW | 0x3 | framer: CLK half period - 1 (PCLK); 3 or more |
| CFG | 12:5 | `cfg_fi` | RW | 0x0 | framer: FI information byte |
| CHAN | 7:0 | `cfg_tx_slot` | RW | 0x1 | transmit segment first slot |
| CHAN | 10:8 | `cfg_tx_len` | RW | 0x0 | transmit bytes per frame (1..4, 0 = off) |
| CHAN | 18:11 | `cfg_rx_slot` | RW | 0x1 | receive segment first slot |
| CHAN | 21:19 | `cfg_rx_len` | RW | 0x0 | receive bytes per frame (1..4, 0 = off) |
| SFSET | 15:0 | `sf_set_val` | RW | 0x0 | superframe count |
| TX | 31:0 | `tx_data` | RW | 0x0 | sample |
| RX | 31:0 | `rx_data` | RO (pop) | 0x0 | sample (the low CHAN.cfg_rx_len bytes) |
| STATUS | 0 | `locked` | RO | core | frame sync locked |
| STATUS | 1 | `sf_locked` | RO | core | superframe found; the data channels run |
| STATUS | 2 | `cfg_err` | RO | core | a channel segment is invalid (that channel is off) |
| STATUS | 10:3 | `fi_info` | RO | core | FI information byte of the last superframe |
| STATUS | 26:11 | `sf_count` | RO | core | superframe count of the last superframe |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FI | a complete FI was received (STATUS.fi_info / sf_count updated) |
| 1 | LOST_SYNC | frame sync lost (two misses, or no superframe within 16 frames) |
| 2 | TX_UNDERRUN | a transmit segment found no sample (sent as not present) |
| 3 | RX_ERR | a receive segment TAG had reserved bits set |
| 4 | TX_DONE | TX beat accepted by the core |
| 5 | TX_OVF | write to TX while full (dropped) |
| 6 | RX_AVAIL | RX captured a beat |
| 7 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **SFSET** feeds `sf_set_val`; writing SFSET pulses `sf_set` for one clock.
* **TX** feeds `tx_data`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x534C0200.
2. Write 0xFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014), CHAN (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xFF enables all).
5. To send on SFSET: write SFSET (0x01C). The last write pulses `sf_set` for one clock; there is no back-pressure.
6. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x020). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
7. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 6) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
8. Read STATUS (0x028) for the core's live `locked`, `sf_locked`, `cfg_err`, `fi_info`, `sf_count`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/MIPI_SLIMbus_top.sv` | pass | 74/74 | 748/748 | 8/8 | 16/16 | 83/83 |
| wrapper `rtl/MIPI_SLIMbus_apb.sv` | pass | 40/40 | 996/996 | n/a | 18/18 | 72/72 |
