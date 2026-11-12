<!-- SPDX-License-Identifier: Apache-2.0 -->
# HDMI_2_1: design specification

An HDMI source in TMDS mode, as an educational slice: TMDS 8b/10b video coding, control and data
island periods with TERC4, AVI and SPD InfoFrames, and a built-in 640x480 at 60 Hz timing and
test-pattern generator. Not implemented: FRL (HDMI 2.1 fixed rate link) and 16b/18b, real 10x
serialisation, audio, HDCP, SCDC / DDC, deep colour and other formats. Core `HDMI_2_1_top`
(`rtl/HDMI_2_1_top.sv`), testbench `tb/HDMI_2_1_tb.sv` (a TMDS sink decoder), checker
`tb/cov/HDMI_2_1_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A pixel period is 10 clocks; each channel sends one 10-bit code per
pixel, bit 0 first, all channels in step.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one serial bit per clock, a pixel every 10 | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `hpd` | input | 1 | hot plug detect; low stops the link | high | `clk` | - |
| `tmds_clk` | output | 1 | TMDS clock channel: 1111100000 repeated, LSB first | - | `clk` | 0 |
| `tmds_d` | output | 3 | TMDS data channels 2..0, bit 0 of each code first | - | `clk` | 0 |
| `hsync` | output | 1 | horizontal sync of the current pixel (VIC 1: active low) | low | `clk` | 1 |
| `vsync` | output | 1 | vertical sync (active low) | low | `clk` | 1 |
| `de` | output | 1 | active video pixel | high | `clk` | 0 |
| `irq` | output | 1 | level: the link was running and `hpd` is now low; combinational | high | comb | 0 |

### Internal signals used by the verification

The TB's sink model and inline checks read these.

| Signal | Width | Meaning |
|---|---|---|
| `x` | 10 | pixel column of the current pixel, 0..799 |
| `y` | 10 | line, 0..524 |
| `bit_cnt` | 4 | bit within the pixel, 0..9 |
| `mode` | 3 | period of the next pixel: 0 control, 1 video, 2 video preamble, 3 video guard band, 4 island preamble, 5 island guard band, 6 island data; combinational |
| `ever_hpd` | 1 | the link has run since reset |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/HDMI_2_1.md`](../ip/HDMI_2_1.md) (source: `scripts/apb/specs/HDMI_2_1.json`); do not edit by hand.

`HDMI_2_1_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `hpd`, `tmds_clk`, `tmds_d`, `hsync`, `vsync`, `de`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x484D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Video timing (the same levels as the hsync / vsync / de pins) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x484D | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `hsync` | RO | core | horizontal sync, active low (VIC 1) |
| STATUS | 1 | `vsync` | RO | core | vertical sync, active low (VIC 1) |
| STATUS | 2 | `de` | RO | core | active video pixel |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | HPD_LOST | hpd went low after the link had run; level in the core, so the bit is set again on every clock until hpd returns |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x484D0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `hsync`, `vsync`, `de`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Serialisation

Every 10th clock (bit 9 of a pixel) the next pixel's three codes are loaded; each clock one bit
of each code goes out (`tmds_d` is registered, so a code's bit 0 appears the clock after loading).
`tmds_clk` sends 1111100000, LSB first, continuously while `hpd` is high.

### 3.2 Raster

640x480 at 60 Hz, VIC 1: 800 x 525 total; hsync columns 656..751, vsync lines 490..491 (both
active low); `de` on columns 0..639 of lines 0..479. `hsync`, `vsync`, `de` change with each
pixel load. After reset or `hpd` return the first pixel is (0, 0).

### 3.3 Video

Pixel (x, y): R = x[7:0], G = y[7:0], B = x[7:0] ^ y[7:0] on channels 2, 1, 0, TMDS 8b/10b coded
(the DVI 1.0 algorithm: XOR / XNOR transition minimisation, DC balance with a running disparity
per channel). The disparity runs over video pixels only and restarts at 0 in every other period.

### 3.4 Control periods

Channel 0 carries {VSYNC, HSYNC}, channel 1 CTL1:0, channel 2 CTL3:2, as the four control codes.
Before every active line (including line 0): an 8-pixel video preamble (CTL0 = 1) at columns
790..797, then a 2-pixel video guard band (1011001100 on channels 0 and 2, 0100110011 on channel 1).

### 3.5 Data islands

On line 481 (AVI) and line 490 (SPD), starting at column 636: an 8-pixel preamble (CTL0 = CTL2 =
1), a 2-pixel leading guard band (channel 0 TERC4 {1, 1, VSYNC, HSYNC}; channels 1 and 2
0100110011), 32 packet pixels, a 2-pixel trailing guard band. Packet pixel i: channel 0 =
TERC4({i != 0, header bit i, VSYNC, HSYNC}); channel 1 = TERC4 of bit 2i of subpackets 3..0;
channel 2 = TERC4 of bit 2i + 1 of subpackets 3..0.

### 3.6 InfoFrames

Constant packets with BCH(32,24) / BCH(64,56) ECC (generator x^8 + x^7 + x^6 + 1):

* AVI (type 0x82, version 2, length 13): PB1 = 0x10, PB2 = 0x18, PB4 = VIC 1, checksum so the
  bytes sum to 0; subpackets 1..3 are 0.
* SPD (type 0x83, version 1, length 25): vendor "OpenIP", product "HDMI 2.1 TX Core", source
  information 0.

### 3.7 Hot plug and reset

While `hpd` is low the TMDS outputs are 0, `hsync` / `vsync` 1, `de` 0, and timing restarts at
(0, 0) when it returns. `irq` = the link has run since reset and `hpd` is low. While `rst_n` is
low: the same parked state, and the running flag clears.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `hpd` low | link stopped, `irq` if it had run |
| `hpd` returns | restart at pixel (0, 0) |
| reset with `hpd` low | `irq` = 0 |
| islands across the hsync edge | sync bits follow the raster inside the island |

## 6. TB check map

The TB prints `ERROR: <message>` for most checks and `SVA_FAIL: <name>` for its inline assertions
(A1..A6). Assertions `a_*` are in the bound checker `tb/cov/HDMI_2_1_sva.sv`. The TB decodes a
whole frame pixel by pixel, checks every period boundary, extracts both InfoFrames, tracks the DC
balance and injects `hpd` loss.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "tmds_clk pattern bit" | clock channel pattern | §3.1 |
| "flags px" | hsync / vsync / de per pixel | §3.2 |
| "pixel px" | decoded video pixels | §3.3 |
| "disparity ch" | DC balance | §3.3 |
| "video guard px" | video guard band | §3.4 |
| "video preamble px" | video preamble | §3.4 |
| "island preamble px" | data island preamble | §3.5 |
| "island guard(px<10) px" | leading island guard band | §3.5 |
| "TERC4 invalid px" | TERC4 codes | §3.5 |
| "island ch0 sync/first bits px" | channel 0 island bits | §3.5 |
| "island guard(px<44) px" | trailing island guard band | §3.5 |
| "control px" | control codes | §3.4 |
| "AVI header" | AVI header | §3.6 |
| "AVI header BCH" | header ECC | §3.6 |
| "AVI checksum sum" | checksum | §3.6 |
| "AVI PB1/PB2/VIC" | AVI fields | §3.6 |
| "AVI sp0 BCH" | subpacket ECC | §3.6 |
| "AVI sp1/2/3 nonzero" | unused subpackets 0 | §3.6 |
| "SPD header" | SPD header | §3.6 |
| "SPD header BCH" | SPD header ECC | §3.6 |
| "SPD subpacket" | SPD subpackets | §3.6 |
| "SPD checksum" | SPD checksum | §3.6 |
| "SPD vendor/product strings" | SPD strings | §3.6 |
| "reset state tmds_d" | reset | §3.7 |
| "TMDS active before hpd" | no TMDS without `hpd` | §3.7 |
| "pixels checked" | a whole frame was checked | §3.3 |
| "TMDS not stopped after hpd loss d" | `hpd` low stops TMDS | §3.7 |
| "irq not asserted on hpd loss" | `irq` on loss | §3.7 |
| "irq not cleared after hpd restore" | `irq` clears | §3.7 |
| "data islands observed" | islands present | §3.5 |
| "irq not set before reset" | `irq` | §3.7 |
| "reset while unplugged" | reset | §3.7 |
| "irq after reset with hpd low" | reset clears the running flag | §3.7 |
| "CRV" | random plug / unplug phase | §3.7 |
| "no SPD InfoFrame seen" | SPD sent | §3.6 |
| "TIMEOUT" | the run finishes | §3 |
| "A1 reset: idle" | reset | §3.7 |
| "A2 irq level identity" | `irq` = running and `hpd` low | §3.7 |
| "A3 hpd loss: outputs parked" | outputs parked | §3.7 |
| "A4 de implies hpd" | no video without `hpd` | §3.7 |
| "A5 counters bounded" | raster counters bounded | §3.2 |
| "A6 bit_cnt <= 9" | 10 bits per pixel | §3.1 |
| a_reset_parked | reset values | §3.7 |
| a_word_ch0 | channel 0 codes as the model | §3.3..§3.5 |
| a_word_ch1 | channel 1 codes | §3.3..§3.5 |
| a_word_ch2 | channel 2 codes | §3.3..§3.5 |
| a_raster_flags | hsync / vsync / de | §3.2 |
| a_clock_channel | clock channel | §3.1 |
| a_unplug_parks | unplug parks the outputs | §3.7 |
| a_irq | `irq` | §3.7 |
