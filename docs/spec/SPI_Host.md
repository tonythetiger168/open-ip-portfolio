<!-- SPDX-License-Identifier: Apache-2.0 -->
# SPI_Host: design specification

SPI controller (master): one 8-bit full-duplex frame per `start`, MSB first, SPI modes 0..3
(CPOL, CPHA), SCLK half period of `div` + 1 clocks, `NCS` software-controlled chip selects.
Core `SPI_Host_top` (`rtl/SPI_Host_top.sv`), testbench `tb/SPI_Host_tb.sv` (targets: the
portfolio's `SPI_top` and a mode-table model); no core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Edge S is the edge that accepts `start`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of every flop | low | async assert | - |
| `sclk` | output | 1 | SPI clock, from a flop; idles at `cpol` | - | clk | 0 |
| `mosi` | output | 1 | data to the target, from a flop; holds its last value between frames | - | clk | 0 |
| `miso` | input | 1 | data from the target; sampled by `clk` at the sampling edges (§3.3) | - | clk | - |
| `csn` | output | `NCS` | chip selects, active low: `csn = ~cs` (combinational, no timing of its own) | low | comb. | `~cs` |
| `div` | input | 16 | half SCLK period minus one, in clocks; read at every reload (§3.2) | - | clk | - |
| `cpol` | input | 1 | SCLK idle level | - | clk | - |
| `cpha` | input | 1 | 0: sample on the leading edge, change on the trailing edge (first bit before the first edge); 1: change on the leading edge, sample on the trailing edge. Captured at `start` | - | clk | - |
| `cs` | input | `NCS` | chip-select request, bit i high selects target i; software keeps it set across the frames of one transaction | high | - | - |
| `tx_data` | input | 8 | byte to send; captured at `start` | - | clk | - |
| `start` | input | 1 | start a frame; ignored while `busy` | high | clk | - |
| `rx_data` | output | 8 | byte received by the last frame; updated at the end of a frame | - | clk | 0x00 |
| `busy` | output | 1 | a frame is in progress (from edge S to the edge that sets `done`) | high | clk | 0 |
| `done` | output | 1 | one-clock pulse at the end of each frame, with `rx_data` updated at the same edge | high | clk | 0 |

## 2. Registers

The core has no registers of its own; the APB4 wrapper `SPI_Host_apb` holds `div`, `cpol`,
`cpha`, `cs` and `tx_data` in CFG / DIV / TX_DATA, makes `start` from CMD, and reads `rx_data`
and `busy`.

<!-- AUTO:registers -->
Generated from [`docs/ip/SPI_Host.md`](../ip/SPI_Host.md) (source: `scripts/apb/specs/SPI_Host.json`); do not edit by hand.

`SPI_Host_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `mosi`, `miso`, `csn`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C520100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000000 | Mode and chip selects |
| 0x018 | DIV | RW | 0x00000009 | SCLK timing |
| 0x01C | TX_DATA | RW | 0x00000000 | Byte sent by the next frame |
| 0x020 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x024 | RX_DATA | RO | core | Byte received by the last frame |
| 0x028 | STATUS | RO | core | State |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C52 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 0 | `cpol` | RW | 0x0 | SCLK idle level |
| CFG | 1 | `cpha` | RW | 0x0 | 0 sample on the leading edge, 1 on the trailing edge |
| CFG | 3:2 | `cs` | RW | 0x0 | csn[i] = !cs[i] |
| DIV | 15:0 | `div` | RW | 0x9 | half SCLK period - 1, in clocks |
| TX_DATA | 7:0 | `tx_data` | RW | 0x0 | MSB first |
| CMD | 0 | `start` | WO (pulse) | 0x0 | send one frame; ignored while busy |
| RX_DATA | 7:0 | `rx_data` | RO | core | MSB first |
| STATUS | 0 | `busy` | RO | core | a frame is running |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a frame ended |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C520100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014), DIV (0x018), TX_DATA (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x020; the core sees a one-clock pulse, and the register reads 0.
6. Read RX_DATA (0x024) for the core's live `rx_data`; it needs no clearing.
7. Read STATUS (0x028) for the core's live `busy`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write DIV and CFG (mode, then CS to select the target).
2. For each byte: TX_DATA, CMD.start, wait for DONE, read RX_DATA.
3. Write CFG.cs = 0 to end the transaction.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Idle and start

While `busy` = 0, at every edge `sclk <= cpol` (so a change of `cpol` reaches `sclk` one clock
later). At edge S (`start` = 1 and `busy` = 0): `busy <= 1`, the half-period counter is loaded
with `div`, the edge count is cleared, `tx_data` goes into the shift register, `cpha` is
captured, and with `cpha` = 0 `mosi <= tx_data[7]`. `start` while `busy` = 1 has no effect.

### 3.2 SCLK

Let H = `div` + 1. While busy the counter counts down to 0; at the edge where it is 0 it
reloads `div` and SCLK toggles. So the 16 SCLK edges of a frame are at edges S + k·H,
k = 1..16, and every SCLK level lasts exactly H clocks, including the idle level before the
first edge. Edges k = 1, 3, ..., 15 are *leading* edges (away from `cpol`), k = 2, 4, ..., 16
*trailing* edges (back to `cpol`). At edge S + 17·H: `busy <= 0`, `done <= 1`,
`rx_data <= ` the received byte. The frame takes 17·H clocks from S to the `done` edge.
`div` is re-read at every reload, so changing it during a frame changes the following half
periods.

### 3.3 Data

At SCLK edge k (clock edge S + k·H), the action depends on `cpha` (as captured):

| `cpha` | leading edges (k odd) | trailing edges (k even) |
|---|---|---|
| 0 | sample: shift in `miso` | k = 2..14: `mosi <=` next bit; k = 16: nothing (MOSI keeps bit 0) |
| 1 | `mosi <=` next bit (bit 7 at k = 1) | sample: shift in `miso` |

"Sample" takes the value `miso` has just before that clock edge, i.e. before the target can
react to the SCLK edge made at the same clock edge. Bits go out and come in MSB first; after 8
samples the received byte is complete. With `cpha` = 0 bit 7 is on `mosi` from edge S, H clocks
before the first SCLK edge.

### 3.4 Chip select

`csn = ~cs`, combinational, independent of `busy`; software asserts it before `start` and
releases it after `done`. Several frames may run under one chip select.

### 3.5 Reset

`rst_n` low: `sclk` = 0, `mosi` = 0, `busy` = 0, `done` = 0, `rx_data` = 0; a frame in progress
is abandoned. After release `sclk` follows `cpol` from the first edge.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `NCS` | 2 | ≥ 1 | number of chip selects (width of `cs` and `csn`) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `start` while busy | ignored; exactly one `done` per accepted frame |
| `div` = 0 | H = 1 clock per SCLK level (SCLK = `clk` / 2) |
| target that samples SCLK on its own clock (`SPI_top`) | needs H ≥ 3 |
| `cpol` / `cpha` changed during a frame | `cpha` captured at start; `sclk` keeps toggling from its level, `cpol` only matters when idle |
| no `cs` bit set | the frame runs on the pins without a selected target |

## 6. TB check map

Messages are printed by `tb/SPI_Host_tb.sv` as `ERROR: <message>`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "SCLK half period" | while busy, no SCLK level is shorter than `div` + 1 clocks | §3.2 |
| "SCLK not at CPOL while idle" | idle and not in the `done` clock: `sclk` = `cpol` (one clock after `cpol` changes) | §3.1 |
| "busy low after start" | `busy` = 1 the clock after `start` | §3.1 |
| "mode" (`mode CP: RX_DATA .., expected ..`) | after `done`, `rx_data` is the target's byte, in all four modes | §3.2, §3.3 |
| "mode" (`mode CP: target got .., sent ..`) | the model target received `tx_data` | §3.3 |
| "mode" (`mode CP: target saw N sampling edges`) | exactly 8 sampling edges per frame for the mode's target | §3.2, §3.3 |
| `N DONE pulses for one frame` | one `done` per frame, also when `start` is pulsed again while busy | §3.1, §5 |
| "SPI_top got" | the `SPI_top` target (mode 0, H = 3..9) receives each byte, several frames per chip select | §3.3, §3.4, §5 |
| "timeout" | the test ends within 20 ms (no hung frame) | §3.2 |
