<!-- SPDX-License-Identifier: Apache-2.0 -->
# DisplayPort2: design specification

A DisplayPort source (TX) educational slice: one main-link lane with 8b/10b encoding, link
training (clock recovery with D10.2, then TPS1), a simplified video line with an MSA packet, an
AUX channel with Manchester-II coding for native DPCD access and I2C-over-AUX EDID reads, and HPD
handling. Simplified: one lane at one bit per clock, a 4-register DPCD window, AUX CRC replaced
by the STOP chips, len fields carry the byte count, fixed video timing. Not implemented: DP 2.x
128b/132b, multiple lanes / rates, voltage swing / pre-emphasis adjustment, MST, DSC, HDCP, real
video input. Core `DisplayPort2_top` (`rtl/DisplayPort2_top.sv`), testbench
`tb/DisplayPort2_tb.sv` (the TB is the sink), checker `tb/cov/DisplayPort2_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. "HPD low" means `sink_present` = 0.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one main-link bit or one AUX chip per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `lane_p` | output | 1 | main-link serial bit (8b/10b, bit a first) | - | `clk` | 0 |
| `lane_valid` | output | 1 | the lane is up and `lane_p` carries symbols | high | `clk` | 0 |
| `link_trained` | output | 1 | training complete, video streaming; combinational from the state | high | comb | 0 |
| `train_fail` | output | 1 | training failed after all retries; sticky until reset or HPD low | high | `clk` | 0 |
| `aux_tx_p` | output | 1 | AUX Manchester chip driven by the source | - | `clk` | 1 |
| `aux_tx_en` | output | 1 | the source drives the AUX pair | high | `clk` | 0 |
| `aux_rx_p` | input | 1 | AUX line as seen by the source (idle 1) | - | `clk` | - |
| `sink_present` | input | 1 | HPD, already debounced | high | `clk` | - |
| `edid` | output | 64 | first 8 EDID bytes, byte i in bits 8i+7:8i | - | `clk` | 0 |
| `edid_valid` | output | 1 | `edid` read successfully | high | `clk` | 0 |
| `irq` | output | 1 | = `train_fail` | high | `clk` | 0 |

### Internal signals used by the verification

fsm_cov binds these three state machines; keep the names and encodings.

| Signal | Width | Meaning |
|---|---|---|
| `lt_state` | 4 | link training: 0 IDLE, 1 CFG_RATE, 2 CFG_LANE, 3 CR_SET, 4 CR_WAIT, 5 CR_POLL, 6 TPS_SET, 7 TPS_WAIT, 8 TPS_POLL, 9 EDID_W, 10 EDID_R, 11 TRAIN_OFF, 12 VIDEO, 13 FAIL |
| `pat` | 2 | main-link pattern: 0 FILL, 1 CR, 2 TPS1, 3 VIDEO |
| `aux_state` | 4 | AUX: 0 IDLE, 1 SYNC0, 2 SYNC1, 3 START0, 4 START1, 5 C0, 6 C1, 7 STOP0, 8 STOP1, 9 RX_W0, 10 RX_C0, 11 RX_C1, 12 RX_STOP0, 13 RX_STOP1 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/DisplayPort2.md`](../ip/DisplayPort2.md) (source: `scripts/apb/specs/DisplayPort2.json`); do not edit by hand.

`DisplayPort2_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `lane_p`, `lane_valid`, `link_trained`, `train_fail`, `aux_tx_p`, `aux_tx_en`, `aux_rx_p`, `sink_present`, `edid_valid`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44320200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Link state, as driven on the pins |
| 0x018 | EDID0 | RO | core | EDID bytes 0 to 7 |
| 0x01C | EDID1 | RO | core | EDID bytes 0 to 7 |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x020 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4432 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `lane_valid` | RO | core | the main lane is up (training patterns, video or fill) |
| STATUS | 1 | `link_trained` | RO | core | training completed; video lines are being sent |
| STATUS | 2 | `train_fail` | RO | core | training failed after all retries (until HPD low or reset) |
| STATUS | 3 | `edid_valid` | RO | core | EDID holds the first 8 EDID bytes |
| EDID0 | 31:0 | `edid[31:0]` | RO | core | byte i in bits [8i+7:8i] (EDID0 holds bytes 0 to 3), valid with STATUS.edid_valid |
| EDID1 | 31:0 | `edid[63:32]` | RO | core | byte i in bits [8i+7:8i] (EDID0 holds bytes 0 to 3), valid with STATUS.edid_valid |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TRAINED | the link is trained; set on every clock it stays trained, so clear it once and mask it |
| 1 | TRAIN_FAIL | training failed; the core holds it until HPD low or reset, so the bit is set again on every clock until then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44320200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
4. Read STATUS (0x014) for the core's live `lane_valid`, `link_trained`, `train_fail`, `edid_valid`; it needs no clearing.
5. Read EDID0 (0x018), EDID1 (0x01C) for the core's live `edid[31:0]`, `edid[63:32]`; it needs no clearing.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Main link

While the lane is up the serializer sends one 10-bit code per 10 clocks, gap free, code bit a
(`code[9]`) first; `lane_valid` rises with the first bit. Encoding: ANSI 8b/10b (full D table,
K28.5, K23.7, K27.7, K29.7, K30.7; D.x.A7 where required), running disparity starting at RD-
each time the lane comes up. When the lane goes down `lane_valid` = `lane_p` = 0.

Patterns (a pattern change takes effect at the next symbol, which is position 0 of the new
pattern):

| Pattern | Symbols |
|---|---|
| FILL | K23.7 repeated (lane up, nothing else to send) |
| CR | D10.2 repeated |
| TPS1 | K28.5, D10.2, D10.2, D10.2 repeated |
| VIDEO | 40-symbol line, section 3.2 |

### 3.2 Video line

| Position | Symbol |
|---|---|
| 0 | BS K27.7 |
| 1..16 | pixel i-1 = (line count + i - 1) mod 256 (D) |
| 17 | BE K28.5 |
| 18 | SS K29.7 |
| 19..34 | MSA bytes: 01, line count, 00, 00, 56, 34, 12, 00, 40, 01, 00, 00, F0, 00, 00, 00 |
| 35 | SE K30.7 |
| 36 | FS K23.7 |
| 37..39 | D0.0 |

The line count (8 bits) increments after each line; it is cleared only by reset.

### 3.3 AUX request

The source drives the pair (`aux_tx_en` = 1) with one Manchester chip per clock, each bit as
(bit, !bit): SYNC = 16 zero bits, a start bit 1, then the request bytes MSB first, then one chip
1, after which the pair is released (`aux_tx_en` = 0; `aux_tx_p` stays 1), so the
line's idle level 1 forms the second STOP chip.

| Byte | Native write | Native read | I2C write | I2C read |
|---|---|---|---|---|
| 0 {cmd, addr[19:16]} | 0x80 | 0x90 | 0x00 | 0x10 |
| 1 addr[15:8] | 0x00 | 0x00 | 0x50 (EDID device) | 0x50 |
| 2 addr[7:0] | DPCD address | DPCD address | 0x00 (offset) | 0x00 |
| 3 {4'h0, len} | 1 | 1 | 0 | 8 |
| 4 | data | - | - | - |

### 3.4 AUX reply

From the clock after release the source waits up to 200 clocks for `aux_rx_p` = 0 (the first
SYNC chip). Then it takes chip pairs: each must have chip 1 = !chip 0, the first 16 bits must be
0 and the 17th (start) 1. Then the header byte (MSB first); its bits 7:4 are the reply code. A
code other than 0 (ACK) is a failed attempt and must be followed directly by the STOP; an ACK is
followed by the expected data bytes (1 for a poll, 8 for the EDID read, 0 for writes), then the
STOP. STOP = two chips of 1. The attempt fails on a timeout, a Manchester violation, a bad SYNC
or start bit, a non-1 STOP chip, or a non-ACK code.

### 3.5 Link training

After reset with HPD high, or when HPD rises, the lane comes up with FILL and the source runs
these AUX operations in order:

1. native write DPCD 0 (LINK_RATE) = 0x14
2. native write DPCD 1 (LANE_COUNT) = 0x01
3. native write DPCD 2 (TRAINING_PATTERN_SET) = 0x21, then the CR pattern
4. after at least 32 CR symbols: native read DPCD 3 (LANE0_STATUS); bit 0 CR_DONE required
5. native write DPCD 2 = 0x22, then the TPS1 pattern
6. after at least 32 TPS1 symbols: native read DPCD 3; bit 1 EQ_DONE required
7. I2C write to 0x50, len 0 (EDID offset 0)
8. I2C read from 0x50, len 8: `edid` = the 8 bytes, `edid_valid` = 1
9. native write DPCD 2 = 0x00, then VIDEO and `link_trained`

A failed attempt is retried at once, up to 3 retries per step; a poll that fails or reads the bit
clear restarts its pattern and polls again after another 32 symbols (counting toward the same 3
retries). The retry count restarts at each new step.

### 3.6 Failure

When a step runs out of retries the lane switches to FILL and `train_fail` (= `irq`) rises one
clock later; it stays until reset or HPD low. The lane stays up.

### 3.7 HPD

HPD low (checked every clock): training state to IDLE, the lane goes down (from the next symbol
clock), any AUX transfer is aborted (`aux_tx_en` = 0 next clock), `edid_valid` and `train_fail`
clear; `edid` keeps its value. HPD high again starts a new training from step 1.

### 3.8 Reset

`lane_valid` = `lane_p` = 0, `aux_tx_en` = 0, `aux_tx_p` = 1, `train_fail` = 0, `edid` = 0,
`edid_valid` = 0, training IDLE, line count 0.

## 4. Parameters

None. The AUX reply timeout (200 clocks) and the retry limit (3) are fixed.

## 5. Errors and corner cases

- `irq` only reports training failure; individual AUX faults are retried silently.
- More than 16 SYNC zeros in a reply is a framing error (the 17th bit must be the start bit).
- An ACK reply with fewer data bytes than expected fails at the STOP check.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "anchor K28.5 RD" | (TB self-check of its own 8b/10b reference against standard code words) | §3.1 |
| "anchor K28.5 RD+" | as above | §3.1 |
| "anchor D10.2" | as above | §3.1 |
| "anchor K23.7 RD" | as above | §3.1 |
| "fill expected after training failure" | after a failure the lane sends K23.7 | §3.6 |
| "video line pos" | each video-line symbol at its position | §3.2 |
| "8b/10b code" | every symbol is a valid code group with correct running disparity | §3.1 |
| "request SYNC" | AUX request: 16 SYNC zeros | §3.3 |
| "request start bit" | then the start bit 1 | §3.3 |
| "request header chips" | Manchester chips of the header bytes | §3.3 |
| "request len byte high nibble" | len byte bits 7:4 = 0 | §3.3 |
| "request data chips" | chips of the write byte | §3.3 |
| "request STOP" | STOP after the last byte | §3.3 |
| "source still drives the AUX pair after STOP" | the pair is released after STOP | §3.3 |
| "request" | each request is the expected training op | §3.5 |
| "outputs after HPD low" | HPD low drops the lane and AUX and clears flags | §3.7 |
| "training did not complete" | training completes with a good sink | §3.5 |
| "DPCD" | DPCD writes leave rate 0x14, lane count 1, pattern off | §3.5 |
| "EDID" | `edid` = the sink's first 8 bytes | §3.5 |
| "irq after successful training" | no `irq` when training succeeds | §3.6 |
| "ops after training" | exactly 9 AUX ops in a clean training | §3.5 |
| "training did not fail" | `train_fail` after exhausted retries | §3.6 |
| "train_fail not sticky" | `train_fail` stays until reset / HPD low | §3.6 |
| "reset values" | reset values | §3.8 |
| "video lines" | video lines keep coming | §3.2 |
| "reset state" | reset values | §3.8 |
| "activity without HPD" | no lane / AUX activity while HPD is low | §3.7 |
| "fault kind" | (TB coverage: every reply fault kind was injected) | §3.4 |
| a_reset_outputs | reset values | §3.8 |
| a_aux_tx_en | `aux_tx_en` equals the checker's model | §3.3 |
| a_aux_tx_p | `aux_tx_p` as the model while driving | §3.3 |
| a_lane_valid | `lane_valid` as the model | §3.1 |
| a_lane_p | `lane_p` as the model | §3.1, §3.2 |
| a_link_trained | `link_trained` as the model | §3.5 |
| a_train_fail | `train_fail` as the model | §3.6 |
| a_irq | `irq` = `train_fail` | §3.6 |
| a_edid_valid | `edid_valid` as the model | §3.5 |
| a_edid | `edid` as the model | §3.5 |
| a_hpd_low_drops_link | HPD low: lane and AUX released | §3.7 |
