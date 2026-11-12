<!-- SPDX-License-Identifier: Apache-2.0 -->
# I2S_Audio: design specification

A full-duplex I2S transceiver (master or slave) with three serial formats and three sample depths
in a 32-bit channel slot. Not implemented: TDM / more than two channels, slot widths other than 32,
an asynchronous slave clock domain, sample FIFOs. Core `I2S_Audio_top`
(`rtl/I2S_Audio_top.sv`), testbench `tb/I2S_Audio_tb.sv` (loopback `sd_out` -> `sd_in`), checker
`tb/cov/I2S_Audio_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` (mclk) and reset
asynchronously by `rst_n` low. A frame is 64 bit periods: positions 0..31 are the left slot
(`wclk` = 0), 32..63 the right slot.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | master clock (mclk) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_master` | input | 1 | 1: master (generates `bclk_out` / `wclk_out`), 0: slave | high | static | - |
| `cfg_fmt` | input | 2 | 0: I2S, 1: left-justified, 2: right-justified (3 behaves as I2S) | - | static | - |
| `cfg_depth` | input | 2 | sample depth 0: 16, 1: 24, 2/3: 32 bits | - | static | - |
| `bclk_out` | output | 1 | master bit clock: low for the first half of each bit | - | `clk` | 0 |
| `wclk_out` | output | 1 | master word clock (0 = left); 0 in slave mode | - | comb | 0 |
| `bclk_in` | input | 1 | slave bit clock (synchronous to `clk`) | - | `clk` | - |
| `wclk_in` | input | 1 | slave word clock, changes on `bclk_in` falling edges | - | `clk` | - |
| `tx_l` | input | DW | left transmit sample, LSB-aligned | - | `clk` | - |
| `tx_r` | input | DW | right transmit sample, LSB-aligned | - | `clk` | - |
| `tx_valid` | input | 1 | a sample pair is offered | high | `clk` | - |
| `tx_ready` | output | 1 | one-clock pulse: the pair is taken for the next frame; combinational | high | comb | 0 |
| `rx_l` | output | DW | received left sample, LSB-aligned; holds | - | `clk` | 0 |
| `rx_r` | output | DW | received right sample, LSB-aligned; holds | - | `clk` | 0 |
| `rx_valid` | output | 1 | one-clock pulse: a received pair | high | `clk` | 0 |
| `sd_out` | output | 1 | serial transmit data; combinational from the frame position | - | comb | 0 |
| `sd_in` | input | 1 | serial receive data | - | `clk` | - |
| `irq` | output | 1 | one-clock pulse: slave frame-sync error | high | `clk` | 0 |

### Internal signals used by the verification

The TB's inline checks read these by name.

| Signal | Width | Meaning |
|---|---|---|
| `frame_pos` | 6 | bit position in the frame, 0..63; bit 5 is the channel |
| `div_cnt` | $clog2(`MCLK_DIV`) | master divider, 0..`MCLK_DIV` - 1 |
| `fall` | 1 | bit-clock falling edge this clock (master: `div_cnt` = `MCLK_DIV` - 1; slave: `bclk_in` 1 -> 0); combinational |
| `cfg_chg` | 1 | {`cfg_master`, `cfg_fmt`, `cfg_depth`} differs from the copy registered last clock; combinational |
| `tx_word_l` | 32 | left word of the frame being sent, left-justified |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/I2S_Audio.md`](../ip/I2S_Audio.md) (source: `scripts/apb/specs/I2S_Audio.json`); do not edit by hand.

`I2S_Audio_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `bclk_out`, `wclk_out`, `bclk_in`, `wclk_in`, `sd_out`, `sd_in`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x49410200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000011 | Configuration; a change re-synchronises the frame counters |
| 0x018 | TX0 | RW | 0x00000000 | Stereo sample pair, LSB-aligned; taken at the start of the next frame (a frame without a pair sends zeros) |
| 0x01C | TX1 | RW | 0x00000000 | Stereo sample pair, LSB-aligned; taken at the start of the next frame (a frame without a pair sends zeros) |
| 0x020 | RX0 | RO (pop) | 0x00000000 | Received stereo pair (LSB-aligned, one per frame); reading the right word frees it |
| 0x024 | RX1 | RO (pop) | 0x00000000 | Received stereo pair (LSB-aligned, one per frame); reading the right word frees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4941 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 0 | `cfg_master` | RW | 0x1 | 1: master (bclk_out = PCLK / 4, wclk_out = bclk / 64), 0: slave (bclk_in / wclk_in, synchronous to PCLK) |
| CFG | 2:1 | `cfg_fmt` | RW | 0x0 | 0 I2S, 1 left-justified, 2 right-justified |
| CFG | 4:3 | `cfg_depth` | RW | 0x2 | 0 16-bit, 1 24-bit, 2 / 3 32-bit |
| TX0 | 31:0 | `tx_l` | RW | 0x0 | left sample |
| TX1 | 31:0 | `tx_r` | RW | 0x0 | right sample |
| RX0 | 31:0 | `rx_l` | RO (pop) | 0x0 | left sample |
| RX1 | 31:0 | `rx_r` | RO (pop) | 0x0 | right sample |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FSYNC_ERR | slave mode: the bclk / wclk phase broke (e.g. a dropped bclk pulse); the core re-synchronises on the next wclk edge |
| 1 | TX_DONE | TX beat accepted by the core |
| 2 | TX_OVF | write to TX while full (dropped) |
| 3 | RX_AVAIL | RX captured a beat |
| 4 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_l`, `tx_r`/`tx_valid`. Writing TX1 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_l`, `rx_r` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX1 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x49410200.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits (RX_AVAIL may be set as soon as reset ends).
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x018) then TX1 (0x01C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x020) then RX1 (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 3) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Bit clock

Master: `div_cnt` counts 0..`MCLK_DIV` - 1; a rise is at `MCLK_DIV`/2 - 1 (`bclk_out` goes 1 next
clock) and a fall at `MCLK_DIV` - 1 (`bclk_out` goes 0). Slave: a rise / fall is a 0 -> 1 / 1 -> 0
change of `bclk_in` between the previous clock and this one. On each fall the frame position
advances; `sd_out` and `wclk_out` follow it, so they are stable around every rise. `sd_in` is
sampled on each rise.

### 3.2 Serial formats

A sample of depth D is left-justified into the 32-bit slot (D = 16, 24 or 32). At slot position p:

| `cfg_fmt` | `sd_out` |
|---|---|
| 1 left-justified | slot bit 31 - p |
| 2 right-justified | 0 while p < 32 - D, then sample bit 31 - p (the LSB is at p = 31) |
| 0 I2S | at p = 0 the previous slot's LSB; then slot bit 32 - p (one bit delay) |

The receiver mirrors this: each rise stores `sd_in` in the slot bit of the current position (I2S:
p = 0 stores the previous channel's LSB). The received words are shifted back to LSB-aligned.

### 3.3 Sample interfaces

At the fall that ends position 63, `tx_ready` = 1 (combinational, not in a clock where the
configuration changed). With `tx_valid` the pair is taken for the next frame; without it the
next frame sends zeros (underrun). The previous right word's LSB is kept for I2S position 0.

`rx_valid` pulses one clock after the fall that ends the frame's last sampled bit: position 63
for left / right-justified, position 0 of the next frame for I2S. `rx_l` / `rx_r` then hold.

### 3.4 Slave frame sync

On a slave fall the position after the advance must have bit 5 = `wclk_in`. If not, the position
is set to {`wclk_in`, 00000} (re-aligned to the word clock edge). The first such re-alignment, or a
full frame, sets an internal synced flag; a later mismatch also pulses `irq` (for example a dropped
`bclk_in` pulse).

### 3.5 Configuration change and reset

When {`cfg_master`, `cfg_fmt`, `cfg_depth`} changes, for that clock everything is re-synchronised:
divider, `bclk_out`, position 0, synced cleared, `rx_valid` / `irq` 0. Sample words are kept.
While `rst_n` is low all flops are 0.

## 4. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `DW` | 32 | sample interface width (fixed 32) |
| `AW` | 32 | reserved |
| `MCLK_DIV` | 4 | `clk` cycles per bit (even, at least 2) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| no pair at frame start | zeros sent, no flag |
| dropped / extra slave `bclk_in` pulse | `irq` pulse, re-aligned at the next `wclk_in` edge |
| `cfg_fmt` = 3 | as I2S |
| configuration change mid-frame | frame restarts at position 0 |

## 6. TB check map

The TB prints `ERROR: <message>`, and the inline assertions print `SVA_FAIL: <name>`. Assertions
`a_*` are in the bound checker `tb/cov/I2S_Audio_sva.sv`, which decodes the line independently. The
TB loops back every format and depth in master mode, then slave mode with TB-generated clocks,
then injects dropped `bclk_in` pulses and underruns, with a random phase.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "wclk phase mismatch wclk" | `wclk_out` = position bit 5 at each rise | §3.1 |
| "A1 reset: regs cleared" | reset clears the position, words and pulses | §3.5 |
| "A2 tx_ready load cycle" | `tx_ready` exactly at the position-63 fall | §3.3 |
| "A3 wclk_out source" | `wclk_out` = position bit 5 (master), 0 (slave) | §3.1 |
| "A4 irq pulse width" | `irq` lasts one clock | §3.4 |
| "A5 div_cnt < MCLK_DIV" | divider bounded | §3.1 |
| "send_frame: tx_ready timeout" | a pair is taken every frame | §3.3 |
| "recv_check: rx_valid timeout" | a pair is received every frame | §3.3 |
| "bclk_out not 0 after reset" | reset value | §3.5 |
| "wclk_out not 0 after reset (left channel)" | reset value | §3.5 |
| "sd_out not 0 after reset" | reset value | §3.5 |
| "rx_valid not 0 after reset" | reset value | §3.5 |
| "tx_ready not 0 after reset" | reset value | §3.5 |
| "irq not 0 after reset" | reset value | §3.5 |
| "wclk phase monitor did not run" | the bit clock runs | §3.1 |
| "no irq on dropped bclk pulse (frame sync loss)" | dropped pulse flagged | §3.4 |
| "CRV: no irq on dropped bclk" | same, random phase | §3.4 |
| "outputs not idle in reset" | reset values | §3.5 |
| a_reset_quiet | in reset all outputs 0 | §3.5 |
| a_tx_bit_model | every transmitted bit as the format model | §3.2, §3.3 |
| a_master_stable_at_rise | `sd_out` / `wclk_out` do not change where `bclk_out` rises | §3.1 |
| a_rx_model | `rx_l` / `rx_r` as decoded from `sd_in` | §3.2, §3.3 |
| a_irq_slave_only | no `irq` in master mode | §3.4 |
| a_ready_once_per_frame | one `tx_ready` per frame | §3.3 |
