<!-- SPDX-License-Identifier: Apache-2.0 -->
# Ethernet_PCS: design specification

The 400GBASE-R PCS data path around the RS(544,514) FEC (IEEE 802.3 clause 119), transmit and
receive: 256B/257B transcoding, the 1 + x^39 + x^58 scrambler, alignment marker groups, pre-FEC
distribution onto two codewords (A and B), RS encoding / decoding with two
[Ethernet_RS_FEC](Ethernet_RS_FEC.md) instances, symbol distribution, marker lock, descrambling and
reverse transcoding. Not implemented: 64B/66B encoding, idle deletion / insertion, per-lane marker
lock, deskew and lane reordering, BIP counters, the FEC_degraded_SER detector, the 200GBASE-R
variant, test patterns, EEE. Core `Ethernet_PCS_top` (`rtl/Ethernet_PCS_top.sv`), testbench
`tb/Ethernet_PCS_tb.sv` (reference-model vectors plus a loopback, `AMP` = 3), checker
`tb/cov/Ethernet_PCS_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Bit 0 of every vector is the first bit sent. A *block* on the line
is 257 bits; a *pair* is 40 blocks (10280 bits) = two 514-symbol FEC messages.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_bypass_corr` | input | 1 | FEC correction bypass (both decoders) | high | `clk` | - |
| `cfg_bypass_ind` | input | 1 | FEC error indication bypass (both decoders) | high | `clk` | - |
| `tx_am_sf` | input | 3 | status bits carried in every transmitted alignment marker group | - | `clk` | - |
| `tx_in_valid` | input | 1 | a group of four 66-bit blocks is offered | high | `clk` | - |
| `tx_in_data` | input | 264 | group: block j at [66j +: 66], sync header in [1:0] (data 10, control 01), payload [65:2] | - | `clk` | - |
| `tx_in_ready` | output | 1 | the group is taken; low during the 8 marker block times; combinational | high | comb | 1 |
| `tx_out_valid` | output | 1 | a 64-symbol beat of the interleaved codeword pair | high | `clk` | 0 |
| `tx_out_first` | output | 1 | beat 0 of a pair (17 beats a pair) | high | `clk` | 0 |
| `tx_out_data` | output | 640 | 64 symbols, symbol n at [10n +: 10]; symbol n goes to PCS lane n mod 16 | - | `clk` | 0 |
| `tx_out_ready` | input | 1 | downstream takes the beat | high | `clk` | - |
| `rx_in_valid` | input | 1 | a received beat (de-skewed, re-ordered lanes, same layout) | high | `clk` | - |
| `rx_in_first` | input | 1 | beat 0 of a pair | high | `clk` | - |
| `rx_in_data` | input | 640 | received symbols | - | `clk` | - |
| `rx_in_ready` | output | 1 | the receive FEC takes the beat; combinational | high | comb | 1 |
| `rx_out_valid` | output | 1 | a received group is on `rx_out_data` (held until taken) | high | `clk` | 0 |
| `rx_out_data` | output | 264 | received group, same layout as `tx_in_data`; invalid blocks have sync header 11 | - | `clk` | 0 |
| `rx_out_ready` | input | 1 | downstream takes the group | high | `clk` | - |
| `rx_am_lock` | output | 1 | alignment marker lock; combinational from the lock state | high | comb | 0 |
| `rx_am_sf` | output | 3 | status bits of the last marker group found | - | `clk` | 0 |
| `ev_am_err` | output | 1 | one-clock pulse: marker group missing, or found off its period | high | `clk` | 0 |
| `ev_itb` | output | 1 | one-clock pulse: an invalid transcoded block (not caused by an uncorrectable codeword) | high | `clk` | 0 |
| `ev_corr_a` | output | 1 | codeword A corrected (from FEC A) | high | `clk` | 0 |
| `ev_corr_b` | output | 1 | codeword B corrected | high | `clk` | 0 |
| `ev_uncorr_a` | output | 1 | codeword A uncorrectable | high | `clk` | 0 |
| `ev_uncorr_b` | output | 1 | codeword B uncorrectable | high | `clk` | 0 |
| `ev_resync` | output | 1 | `rx_in_first` in the middle of a pair (FEC A realigned) | high | `clk` | 0 |
| `st_nsym_a` | output | 4 | symbols corrected in the last A codeword | - | `clk` | 0 |
| `st_nsym_b` | output | 4 | symbols corrected in the last B codeword | - | `clk` | 0 |

### Internal signals used by the verification

The bound checker (`.*`) connects these to check the gearboxes and the receive path at block
level; fsm_cov binds `rlk`. Keep the names and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `tload` | 1 | the transmit block register can take a block this clock |
| `tam` | 1 | the current transmit block slot is a marker slot (pair 0 of the period, blocks 0..7) |
| `rblk` | 1 | the receive gearbox hands one 257-bit block on this clock |
| `rtake` | 1 | the receive gearbox takes the decoders' beat (their `d_out_ready`) |
| `a_d_out_valid` | 1 | FEC A decoder output valid |
| `a_d_out_first` | 1 | FEC A decoder output beat 0 |
| `a_d_out_bad` | 1 | FEC A codeword uncorrectable |
| `b_d_out_bad` | 1 | FEC B codeword uncorrectable |
| `a_d_out_data` | 320 | FEC A decoded beat |
| `b_d_out_data` | 320 | FEC B decoded beat |
| `rlk` | 2 | marker lock: 0 HUNT, 1 LOCK, 2 one group missing, 3 two missing |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Ethernet_PCS.md`](../ip/Ethernet_PCS.md) (source: `scripts/apb/specs/Ethernet_PCS.json`); do not edit by hand.

`Ethernet_PCS_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x45500100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Configuration |
| 0x018 | TX_IN0 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x01C | TX_IN1 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x020 | TX_IN2 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x024 | TX_IN3 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x028 | TX_IN4 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x02C | TX_IN5 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x030 | TX_IN6 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x034 | TX_IN7 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x038 | TX_IN8 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x03C | TX_OUT0 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x040 | TX_OUT1 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x044 | TX_OUT2 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x048 | TX_OUT3 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x04C | TX_OUT4 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x050 | TX_OUT5 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x054 | TX_OUT6 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x058 | TX_OUT7 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x05C | TX_OUT8 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x060 | TX_OUT9 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x064 | TX_OUT10 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x068 | TX_OUT11 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x06C | TX_OUT12 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x070 | TX_OUT13 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x074 | TX_OUT14 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x078 | TX_OUT15 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x07C | TX_OUT16 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x080 | TX_OUT17 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x084 | TX_OUT18 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x088 | TX_OUT19 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x08C | TX_OUT20 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x090 | RX_IN0 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x094 | RX_IN1 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x098 | RX_IN2 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x09C | RX_IN3 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0A0 | RX_IN4 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0A4 | RX_IN5 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0A8 | RX_IN6 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0AC | RX_IN7 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0B0 | RX_IN8 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0B4 | RX_IN9 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0B8 | RX_IN10 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0BC | RX_IN11 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0C0 | RX_IN12 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0C4 | RX_IN13 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0C8 | RX_IN14 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0CC | RX_IN15 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0D0 | RX_IN16 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0D4 | RX_IN17 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0D8 | RX_IN18 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0DC | RX_IN19 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0E0 | RX_IN20 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0E4 | RX_OUT0 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0E8 | RX_OUT1 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0EC | RX_OUT2 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0F0 | RX_OUT3 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0F4 | RX_OUT4 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0F8 | RX_OUT5 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0FC | RX_OUT6 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x100 | RX_OUT7 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x104 | RX_OUT8 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x108 | STATUS | RO | core | Receive state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x10C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4550 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 12:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 12:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 3:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `cfg_bypass_corr` | RW | 0x0 | FEC correction off: data passes as received, codewords with errors are reported uncorrectable |
| CTRL | 1 | `cfg_bypass_ind` | RW | 0x0 | FEC error indication off: uncorrectable codewords do not corrupt the sync headers |
| CTRL | 4:2 | `tx_am_sf` | RW | 0x0 | the 3 status bits sent in every alignment marker group ({FEC_degraded_SER, 0, 0} in clause 119) |
| TX_IN0 | 31:0 | `tx_in_data[31:0]` | RW | 0x0 | four 66-bit blocks |
| TX_IN1 | 31:0 | `tx_in_data[63:32]` | RW | 0x0 | four 66-bit blocks |
| TX_IN2 | 31:0 | `tx_in_data[95:64]` | RW | 0x0 | four 66-bit blocks |
| TX_IN3 | 31:0 | `tx_in_data[127:96]` | RW | 0x0 | four 66-bit blocks |
| TX_IN4 | 31:0 | `tx_in_data[159:128]` | RW | 0x0 | four 66-bit blocks |
| TX_IN5 | 31:0 | `tx_in_data[191:160]` | RW | 0x0 | four 66-bit blocks |
| TX_IN6 | 31:0 | `tx_in_data[223:192]` | RW | 0x0 | four 66-bit blocks |
| TX_IN7 | 31:0 | `tx_in_data[255:224]` | RW | 0x0 | four 66-bit blocks |
| TX_IN8 | 7:0 | `tx_in_data[263:256]` | RW | 0x0 | four 66-bit blocks |
| TX_OUT0 | 31:0 | `tx_out_data[31:0]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT1 | 31:0 | `tx_out_data[63:32]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT2 | 31:0 | `tx_out_data[95:64]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT3 | 31:0 | `tx_out_data[127:96]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT4 | 31:0 | `tx_out_data[159:128]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT5 | 31:0 | `tx_out_data[191:160]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT6 | 31:0 | `tx_out_data[223:192]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT7 | 31:0 | `tx_out_data[255:224]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT8 | 31:0 | `tx_out_data[287:256]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT9 | 31:0 | `tx_out_data[319:288]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT10 | 31:0 | `tx_out_data[351:320]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT11 | 31:0 | `tx_out_data[383:352]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT12 | 31:0 | `tx_out_data[415:384]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT13 | 31:0 | `tx_out_data[447:416]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT14 | 31:0 | `tx_out_data[479:448]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT15 | 31:0 | `tx_out_data[511:480]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT16 | 31:0 | `tx_out_data[543:512]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT17 | 31:0 | `tx_out_data[575:544]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT18 | 31:0 | `tx_out_data[607:576]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT19 | 31:0 | `tx_out_data[639:608]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT20 | 0 | `tx_out_first` | RO (pop) | 0x0 | first beat of a pair |
| RX_IN0 | 31:0 | `rx_in_data[31:0]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN1 | 31:0 | `rx_in_data[63:32]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN2 | 31:0 | `rx_in_data[95:64]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN3 | 31:0 | `rx_in_data[127:96]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN4 | 31:0 | `rx_in_data[159:128]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN5 | 31:0 | `rx_in_data[191:160]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN6 | 31:0 | `rx_in_data[223:192]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN7 | 31:0 | `rx_in_data[255:224]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN8 | 31:0 | `rx_in_data[287:256]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN9 | 31:0 | `rx_in_data[319:288]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN10 | 31:0 | `rx_in_data[351:320]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN11 | 31:0 | `rx_in_data[383:352]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN12 | 31:0 | `rx_in_data[415:384]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN13 | 31:0 | `rx_in_data[447:416]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN14 | 31:0 | `rx_in_data[479:448]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN15 | 31:0 | `rx_in_data[511:480]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN16 | 31:0 | `rx_in_data[543:512]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN17 | 31:0 | `rx_in_data[575:544]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN18 | 31:0 | `rx_in_data[607:576]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN19 | 31:0 | `rx_in_data[639:608]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN20 | 0 | `rx_in_first` | RW | 0x0 | first beat of a pair |
| RX_OUT0 | 31:0 | `rx_out_data[31:0]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT1 | 31:0 | `rx_out_data[63:32]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT2 | 31:0 | `rx_out_data[95:64]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT3 | 31:0 | `rx_out_data[127:96]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT4 | 31:0 | `rx_out_data[159:128]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT5 | 31:0 | `rx_out_data[191:160]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT6 | 31:0 | `rx_out_data[223:192]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT7 | 31:0 | `rx_out_data[255:224]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT8 | 7:0 | `rx_out_data[263:256]` | RO (pop) | 0x0 | four 66-bit blocks |
| STATUS | 0 | `rx_am_lock` | RO | core | alignment marker lock |
| STATUS | 3:1 | `rx_am_sf` | RO | core | status bits of the last marker group received |
| STATUS | 7:4 | `st_nsym_a` | RO | core | symbols corrected in the last codeword A |
| STATUS | 11:8 | `st_nsym_b` | RO | core | symbols corrected in the last codeword B |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | AM_ERR | a marker group missing (correctable pair) or off its period |
| 1 | ITB | an invalid transcoded block (its four blocks come out with sync header 11) |
| 2 | CORR_A | codeword A corrected |
| 3 | CORR_B | codeword B corrected |
| 4 | UNCORR_A | codeword A uncorrectable |
| 5 | UNCORR_B | codeword B uncorrectable |
| 6 | RESYNC | RX_IN first beat in the middle of a pair: the pair was dropped |
| 7 | TX_IN_DONE | TX_IN beat accepted by the core |
| 8 | TX_IN_OVF | write to TX_IN while full (dropped) |
| 9 | TX_OUT_AVAIL | TX_OUT captured a beat |
| 10 | RX_IN_DONE | RX_IN beat accepted by the core |
| 11 | RX_IN_OVF | write to RX_IN while full (dropped) |
| 12 | RX_OUT_AVAIL | RX_OUT captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_IN_FULL | TX_IN holds a beat the core has not taken |
| 1 | TX_OUT_AVAIL | TX_OUT holds an unread beat |
| 2 | RX_IN_FULL | RX_IN holds a beat the core has not taken |
| 3 | RX_OUT_AVAIL | RX_OUT holds an unread beat |

### Streams

* **TX_IN** feeds `tx_in_data`/`tx_in_valid`. Writing TX_IN8 commits the beat: FLAGS.TX_IN_FULL is set and `tx_in_valid` stays high until the core's `tx_in_ready`; then TX_IN_DONE is set. A write while full is dropped and sets TX_IN_OVF.
* **TX_OUT** takes `tx_out_data`, `tx_out_first` from the core with `tx_out_valid` / `tx_out_ready`: `tx_out_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ TX_OUT_AVAIL. Reading TX_OUT20 pops it. Nothing is dropped: the core holds its data until the register is free.
* **RX_IN** feeds `rx_in_data`, `rx_in_first`/`rx_in_valid`. Writing RX_IN20 commits the beat: FLAGS.RX_IN_FULL is set and `rx_in_valid` stays high until the core's `rx_in_ready`; then RX_IN_DONE is set. A write while full is dropped and sets RX_IN_OVF.
* **RX_OUT** takes `rx_out_data` from the core with `rx_out_valid` / `rx_out_ready`: `rx_out_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_OUT_AVAIL. Reading RX_OUT8 pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x45500100.
2. Write 0x1FFF to IRQ_STATUS (0x004) to clear any stale bits (TX_OUT_AVAIL may be set as soon as reset ends).
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FFF enables all).
5. To send on TX_IN: wait until FLAGS.TX_IN_FULL (bit 0) is 0, or for IRQ TX_IN_DONE, then write TX_IN0 (0x018) then TX_IN1 (0x01C) then TX_IN2 (0x020) then TX_IN3 (0x024) then TX_IN4 (0x028) then TX_IN5 (0x02C) then TX_IN6 (0x030) then TX_IN7 (0x034) then TX_IN8 (0x038). The last write commits the beat. TX_IN_OVF means a write came while the register was full and was dropped.
6. To receive on TX_OUT: wait for IRQ TX_OUT_AVAIL or FLAGS.TX_OUT_AVAIL (bit 1), then read TX_OUT0 (0x03C) then TX_OUT1 (0x040) then TX_OUT2 (0x044) then TX_OUT3 (0x048) then TX_OUT4 (0x04C) then TX_OUT5 (0x050) then TX_OUT6 (0x054) then TX_OUT7 (0x058) then TX_OUT8 (0x05C) then TX_OUT9 (0x060) then TX_OUT10 (0x064) then TX_OUT11 (0x068) then TX_OUT12 (0x06C) then TX_OUT13 (0x070) then TX_OUT14 (0x074) then TX_OUT15 (0x078) then TX_OUT16 (0x07C) then TX_OUT17 (0x080) then TX_OUT18 (0x084) then TX_OUT19 (0x088) then TX_OUT20 (0x08C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.TX_OUT_AVAIL (bit 9) to clear it.
7. To send on RX_IN: wait until FLAGS.RX_IN_FULL (bit 2) is 0, or for IRQ RX_IN_DONE, then write RX_IN0 (0x090) then RX_IN1 (0x094) then RX_IN2 (0x098) then RX_IN3 (0x09C) then RX_IN4 (0x0A0) then RX_IN5 (0x0A4) then RX_IN6 (0x0A8) then RX_IN7 (0x0AC) then RX_IN8 (0x0B0) then RX_IN9 (0x0B4) then RX_IN10 (0x0B8) then RX_IN11 (0x0BC) then RX_IN12 (0x0C0) then RX_IN13 (0x0C4) then RX_IN14 (0x0C8) then RX_IN15 (0x0CC) then RX_IN16 (0x0D0) then RX_IN17 (0x0D4) then RX_IN18 (0x0D8) then RX_IN19 (0x0DC) then RX_IN20 (0x0E0). The last write commits the beat. RX_IN_OVF means a write came while the register was full and was dropped.
8. To receive on RX_OUT: wait for IRQ RX_OUT_AVAIL or FLAGS.RX_OUT_AVAIL (bit 3), then read RX_OUT0 (0x0E4) then RX_OUT1 (0x0E8) then RX_OUT2 (0x0EC) then RX_OUT3 (0x0F0) then RX_OUT4 (0x0F4) then RX_OUT5 (0x0F8) then RX_OUT6 (0x0FC) then RX_OUT7 (0x100) then RX_OUT8 (0x104). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_OUT_AVAIL (bit 12) to clear it.
9. Read STATUS (0x108) for the core's live `rx_am_lock`, `rx_am_sf`, `st_nsym_a`, `st_nsym_b`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL; for each group write TX_IN0..TX_IN8 (TX_IN8 commits), and read beats from TX_OUT0..TX_OUT20 (TX_OUT20 pops) when FLAGS says one is available.
2. Receive: write each beat to RX_IN0..RX_IN20 (RX_IN20 commits, bit 0 = first beat of a pair); STATUS.rx_am_lock comes up at the first marker group; read groups from RX_OUT0..RX_OUT8.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 256B/257B transcoding

For each group: when all four sync headers are valid and all four blocks are data, the 257-bit block
is {payloads, 1} (header bit 0 = 1). Otherwise header bit 0 = 0, bits 4:1 are a flag per block
(1 data, block 0 in bit 1), followed by the four payloads with the high nibble (second sent) of the
first control block's type field removed. A group with any invalid sync header (00 or 11) is sent
with all flags 1 (the receiver sees it as invalid).

### 3.2 Scrambling and transmit flow

Data blocks are scrambled with the self-synchronising 1 + x^39 + x^58 scrambler over all 257 bits
(history all ones after reset). `tx_in_ready` = the block register can take a block and the slot is
not a marker slot; the group is transcoded, scrambled and enters the gearbox.

### 3.3 Alignment marker group

The first 8 block slots of every `AMP`-th pair (the first pair after reset included) carry the
marker group instead of data, not scrambled (the scrambler history is not advanced): the 16 lane
markers of Table 119-2 in 10-bit interleaved form (1920 bits), then 133 pad bits from a
free-running PRBS9 (x^9 + x^5 + 1, all ones after reset, advanced 133 bits per group), then the 3
status bits `tx_am_sf` (bits 256:254 of block 7). `tx_in_ready` is low for those 8 slots; the MAC
side must make room (idle deletion is not done here).

### 3.4 Pre-FEC and symbol distribution

The 10280 bits of a pair form 1028 ten-bit symbols; even symbols go to codeword A, odd ones to
codeword B (514 each), 32 per FEC beat (beat 16 carries the last 2). Each FEC appends its 30 parity
symbols. `tx_out_data` carries 64 symbols a beat, 17 beats a pair: in beat group k = 0..3 of 16
symbols, symbol 16k + 2j is A's symbol 8k + j for even k and B's for odd k, and symbol 16k + 2j + 1
is the other codeword's. `tx_out_first` marks beat 0; `tx_out_ready` low holds the encoders (and,
through the gearbox, `tx_in_ready`).

### 3.5 Receive FEC

The inverse symbol distribution feeds both decoders; `rx_in_ready` = FEC A's `d_in_ready` (the two
run in lockstep). `ev_corr_*`, `ev_uncorr_*`, `st_nsym_*` come from the decoders, `ev_resync` from
FEC A. The decoded symbols are re-interleaved into the pair bit stream and cut into 257-bit blocks;
each pair carries a bad flag (A or B uncorrectable).

### 3.6 Marker lock

The receiver counts blocks of each pair (0..39) and pairs of the period. At block 7 of a pair it
checks whether blocks 0..7 hold the marker group (all 1920 marker bits; pad and status ignored):

| State | Pair | Group found | Not found |
|---|---|---|---|
| HUNT | any | LOCK; this pair is pair 0 of the period; `rx_am_sf` = its status bits | stay |
| locked | pair 0 | LOCK (miss count cleared), `rx_am_sf` updated | if the pair is not bad: `ev_am_err` and one more miss; the third miss in a row: HUNT |
| locked | other pairs | `ev_am_err` (if the pair is not bad) | - |

`rx_am_lock` = not HUNT.

### 3.7 Receive output

While unlocked nothing comes out (the descrambler still runs on blocks 8..39 so it is synchronised
at lock). Locked, marker slots (blocks 0..7 of pair 0) are removed and every other block is
descrambled and reverse-transcoded into a group on `rx_out_*` (registered, held until
`rx_out_ready`):

- header bit 1: four data blocks;
- header 0 with all flags 1, or a first control block whose low type nibble is not one of the 11
  clause 82 types: all four sync headers 11, `ev_itb`;
- otherwise the high type nibble is restored from the low one and each block gets 10 (data) or
  01 (control).

Every block of a bad pair is output with sync headers 11 (no `ev_itb`).

### 3.8 Reset

All outputs 0, `tx_in_ready` low only in marker slots (the first pair starts with the marker
group), scrambler histories and PRBS all ones, marker lock HUNT, both FECs reset.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AMP` | 4096 | 1 and up | pairs of codewords per alignment marker period (4096 = 163840 blocks) |

## 5. Errors and corner cases

| Event | Cause |
|---|---|
| `ev_am_err` | locked: no marker group at pair 0 of a correctable pair, or a marker group at another pair |
| `ev_itb` | invalid transcoded block in a correctable pair |
| `ev_uncorr_a` / `ev_uncorr_b` | uncorrectable codeword; its pair's blocks come out invalid |
| `ev_resync` | `rx_in_first` in the middle of a pair |

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "loopback: transmitter stalled" | the transmitter keeps taking groups | §3.2 |
| "loopback" | every group sent comes out of the receiver, in order, unchanged (with up to 15 symbol errors a codeword) | §3 |
| "loopback group" | each group equals the one sent | §3 |
| "loopback: no lock" | the receiver locks on the transmitter's markers | §3.6 |
| "loopback: events" | no marker, transcoding or uncorrectable events on a clean loopback | §5 |
| "TX beat" | every transmit beat (and `tx_out_first`) equals the reference model | §3.1..§3.4 |
| "RX group" | every received group equals the reference model | §3.5..§3.7 |
| "RX events: am_err" | `ev_am_err` and `ev_itb` counts as the reference | §3.6, §3.7 |
| "RX lock / status" | `rx_am_lock` and `rx_am_sf` at the end | §3.6 |
| "RX: uncorrectable codewords not reported" | FEC uncorrectable events come out | §3.5 |
| "loopback: status bits" | `tx_am_sf` arrives on `rx_am_sf` | §3.3, §3.6 |
| "no resync event" | `rx_in_first` mid-pair pulses `ev_resync` | §3.5 |
| a_tx_beat | each transmit beat equals the checker's model | §3.1..§3.4 |
| a_tx_first | `tx_out_first` every 17 beats | §3.4 |
| a_tx_not_ahead | no beat is emitted before its data is in | §3.4 |
| a_tx_am_slot | marker blocks fill the first 8 slots of every `AMP`-th pair | §3.3 |
| a_tx_no_input_in_am_slot | `tx_in_ready` low in the marker slots | §3.3 |
| a_tx_out_held | a stalled `tx_out` holds | §3.4 |
| a_rx_block_available | a block is only formed when 257 bits are in | §3.5 |
| a_rx_out | each output group equals the model | §3.7 |
| a_rx_no_out | no output while unlocked or in a marker slot | §3.6 |
| a_rx_out_held | a stalled `rx_out` holds | §3.7 |
| a_rx_events | `ev_am_err` / `ev_itb` as the model | §3.6, §3.7 |
| a_rx_lock | `rx_am_lock` as the model | §3.6 |
| a_rx_sf | `rx_am_sf` as the model | §3.6 |
| a_reset_outputs | reset values | §3.8 |
