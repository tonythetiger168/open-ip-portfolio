<!-- SPDX-License-Identifier: Apache-2.0 -->
# MDIO: design specification

IEEE 802.3 Clause 22 management slave (PHY side) with 32 16-bit registers: frames of
ST(01) + OP(2) + PHYAD(5) + REGAD(5) + TA(2) + DATA(16), MSB first, clocked by the station's
MDC. Writes (OP 01) to this PHY's address update a register; reads (OP 10) drive the second
turnaround bit low and then the register contents on the open-drain MDIO line. MDC and MDIO are
oversampled by `clk`. Core `MDIO_top` (`rtl/MDIO_top.sv`), testbench `tb/MDIO_tb.sv`, checker
`tb/cov/MDIO_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *bit* is one detected rising edge of MDC (§3.1); "bit value"
is MDIO as sampled for that bit.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock, much faster than MDC | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the frame engine and of all 32 registers | low | async assert | - |
| `mdio` | inout | 1 | MDIO, open drain: the core only drives 0 (`drive_low`), else high-Z; needs a pull-up | - | sampled by one flop; drive comb. | released |
| `mdc` | input | 1 | MDC from the station; bits are taken at its rising edges | rising edge | async (2 flops) | - |
| `irq` | output | 1 | `frame_act && cnt == 29`: high while the last data bit of any frame is pending (from the bit that set `cnt` = 29 until the bit that completes the frame) | high | comb. | 0 |

### Internal signals used by the verification

The TB and the checker read these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `frame_act` | 1 | a frame is being received (set by ST, cleared by the last bit) |
| `cnt` | 5 | frame bits received after ST: 0..29 |
| `read_frame` | 1 | OP = 10 (read) was received (set at the bit with `cnt` = 1) |
| `read_match` | 1 | read frame and PHYAD = `PHY_ADDR` (set at the bit with `cnt` = 6); cleared at frame end |
| `drive_low` | 1 | the core pulls MDIO low: `read_match && cnt >= 13 && (cnt == 13 \|\| reg bit (29 - cnt) == 0)` |
| `regs` | 32 x 16 | the register file, `regs[n]` = register n |

## 2. Registers

Clause 22 registers, reached only over MDIO (no other port):

| REGAD | Reset | Access |
|---|---|---|
| 0 | 0x1140 (PHY ID preset) | RW |
| 1..31 | 0x0000 | RW |

All 16 bits of every register are plain read/write storage with no side effects. The APB4
wrapper `MDIO_apb` (below) only passes the pins through and latches `irq`.

<!-- AUTO:registers -->
Generated from [`docs/ip/MDIO.md`](../ip/MDIO.md) (source: `scripts/apb/specs/MDIO.json`); do not edit by hand.

`MDIO_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `mdio`, `mdc`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4D440200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4D44 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FRAME | a management frame (to any PHY address) has been fully received |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4D440200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Sampling

At every `clk` edge: `mdc_s <= mdc`, `mdc_d <= mdc_s`, `mdio_s <= mdio` (reset values 0, 0, 1).
A bit is processed at a `clk` edge where `mdc_s && !mdc_d`, with value `mdio_s`, i.e. MDIO as
it was one `clk` before that edge, the same sample time as the MDC high that was detected. The
station must hold MDIO stable across its MDC rising edge for at least 2 `clk` periods, and each
MDC level must last at least 2 `clk` periods (the TB uses 10 ns `clk`, MDC 300 ns high and
600 ns low).

### 3.2 Start of frame

While no frame is active, two flags track the line (`pre_ok`: the last bit was an idle 1;
`st0`: the last bit was a 0 that came right after a 1):

| Bit value | Action |
|---|---|
| 1 | if `st0`: ST = 01 complete, `frame_act` <= 1, `cnt` <= 0. Then `pre_ok` <= !`st0`, `st0` <= 0 |
| 0 | `st0` <= `pre_ok`, `pre_ok` <= 0 |

So a frame starts on the pattern 1, 0, 1 (at least one preamble 1, then ST). A 0 that does not
follow a 1 (for example 0, 0, 1) does not start a frame; the tail of a frame that ends in 0
cannot start a new one. Preamble suppression down to a single 1 is accepted.

### 3.3 Frame bits

With `frame_act` = 1, each bit with `cnt` < 29 is shifted into a 29-bit register (MSB first) and
`cnt` increments. Frame bit positions by `cnt` at the time the bit is processed:

| `cnt` | Field |
|---|---|
| 0, 1 | OP[1], OP[0] |
| 2..6 | PHYAD[4..0] |
| 7..11 | REGAD[4..0] |
| 12, 13 | TA[1], TA[0] |
| 14..28 | DATA[15..1] |
| 29 | DATA[0]: frame complete |

- At `cnt` = 1: `read_frame <= (OP == 10)`. At `cnt` = 6: `read_match <= read_frame && PHYAD == PHY_ADDR`.
  At `cnt` = 11: the REGAD is latched.
- At the bit with `cnt` = 29: `frame_act`, `read_frame`, `read_match` <= 0; if OP = 01 and
  PHYAD = `PHY_ADDR`, register REGAD <= {DATA[15:1], this bit}. `cnt` stays 29 until the next
  frame starts (it is reset to 0 by the next ST).
- OP 00 and 11, and any frame to another PHYAD, change nothing and never drive MDIO.

### 3.4 Read data drive

For a matching read, `drive_low` depends on `cnt` (combinational): while `cnt` = 13 the core
drives TA[0] = 0; while `cnt` = 14 + i (i = 0..15) it drives 0 if register bit 15 - i is 0 and
releases the line for a 1. Since `cnt` advances at the bit edge (2 to 3 `clk` after the MDC rise),
each value is on the line from just after one MDC rise until just after the next, and the station
samples it at that next rising edge: TA[0] at the rise that ends `cnt` = 13, DATA[15] at the rise
that ends `cnt` = 14, ..., DATA[0] at the rise that completes the frame, after which the line is
released. In TA[1] (`cnt` = 12) the line is released (the station releases it too).

### 3.5 Reset

`rst_n` low: engine idle (`frame_act` = 0, `cnt` = 0, `read_match` = 0, flags cleared), MDIO
released at once, `irq` = 0, registers back to their reset values (reg 0 = 0x1140, others 0).

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `PHY_ADDR` | 5'h0C | 0x00 .. 0x1F | PHYAD this slave answers to |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| frame to another PHYAD | ignored: no write, read leaves MDIO released (station reads all ones, TA[0] = 1) |
| OP 00 or 11 | ignored |
| preamble of a single 1 between frames | accepted |
| 0, 0, 1 after the preamble | not a start; following bits are ignored until a 1, 0, 1 pattern |
| reset in a read data phase | MDIO released immediately |
| station writes TA as 10 | not checked (TA bits are received but not validated) |

## 6. TB check map

Messages are printed by `tb/MDIO_tb.sv` as `ERROR: <message>`; "CRV" messages and A1..A6 are
built only for Verilator. Assertions a_* are in `tb/cov/MDIO_sva.sv`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "MDIO rw" | write 0xBEEF to reg 3, read it back | §3.3, §3.4 |
| "MDIO read TA2 not driven low" | in a read the core drives TA[0] = 0 | §3.4 |
| "MDIO reg0" | reg 0 reads 0x1140 after reset | §2 |
| "MDIO reg5" | after a 1-bit preamble a frame is still received | §3.2 |
| "MDIO back-to-back reg6" | a frame ending in 0 followed by a 1-bit preamble: the next frame is received | §3.2 |
| "MDIO wrong-PHY read drove the bus" | read to PHYAD 0x0D: TA and data stay released | §5 |
| "MDIO invalid-OP frame wrote reg7" | OP 00 / 11 frames do not write | §3.3, §5 |
| "MDIO 001 taken as ST" | 0, 0, 1 after preamble does not start a frame | §3.2 |
| "MDIO still driving in reset" | reset during read data releases MDIO at once | §3.5 |
| "MDIO reg0 after reset" | reset restores reg 0 = 0x1140 | §3.5 |
| "MDIO reg" | all 32 registers write and read back | §2, §3.3 |
| "MDIO reg 9 changed by op" | OP 00 / 11 frames to another PHY leave reg 9 | §5 |
| "CRV rd reg" | random reads return the last written value | §3.4 |
| "CRV rw reg" | random write / read pairs | §3.3 |
| "CRV wrong-phy wr leaked: reg" | random writes to other PHYADs are ignored | §5 |
| "CRV wrong-phy rd" | random reads to other PHYADs read all ones | §5 |
| "A1 reset: engine quiescent" | in reset `frame_act` = 0, `read_match` = 0, `cnt` = 0 | §3.5 |
| "A2 cnt bounded in frame" | `cnt` ≤ 29 during a frame | §3.3 |
| "A3 slave drive only in read window" | `drive_low` only with `read_match` and `cnt` 13..29 | §3.4 |
| "A4 irq definition" | `irq` = `frame_act && cnt == 29` | §1 |
| "A5 cnt steps <=1" | `cnt` increments by 1 or restarts at 0 | §3.3 |
| "A6 read_match needs read_frame" | `read_match` implies `read_frame` | §3.3 |
| a_reset_released | MDIO released in reset | §3.5 |
| a_drive_model | the core's MDIO drive equals the model's | §3.4 |
| a_regs_model | every register equals the model's | §3.3 |
| a_irq_model | `irq` equals the model's | §1 |
| a_no_drive_outside_read | no drive outside a matching read's window | §3.4 |
