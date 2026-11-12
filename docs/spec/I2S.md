<!-- SPDX-License-Identifier: Apache-2.0 -->
# I2S: design specification

I2S (Philips format) slave transceiver for two channels of `DW`-bit samples. The bus master
drives BCLK and LRCK; the core sends the host's left/right words on SDOUT and captures the
master's words from SDIN, each word MSB first and starting one BCLK after the LRCK transition
that selects its channel. Slots longer than `DW` bits are padded (TX sends 0, RX ignores the
extra bits). BCLK, LRCK and SDIN are oversampled by `clk`. Core `I2S_top` (`rtl/I2S_top.sv`),
testbench `tb/I2S_tb.sv`, checker `tb/cov/I2S_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *rise* or *fall* is a BCLK edge as detected by the core
(§3.1), an *LRCK change* likewise. LRCK = 0 selects the left channel, 1 the right.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock; must be at least 7x BCLK, 8x or more recommended (§3.1) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the synchronizers, shift registers and all four data registers | low | async assert | - |
| `bclk` | input | 1 | I2S bit clock from the master; SDOUT changes after its falls, SDIN is taken at its rises | - | async (2 flops) | - |
| `lrck` | input | 1 | word select from the master, changes on a BCLK fall; 0 = left, 1 = right | - | async (2 flops) | - |
| `sdin` | input | 1 | serial data from the master, MSB first | - | `clk` (1 flop) | - |
| `sdout` | output | 1 | serial data to the master: `tx_shift[DW-1]`, MSB first, 0 in padding bits | - | `clk` | 0 |
| `wen` | input | 1 | host write strobe | high | `clk` | - |
| `waddr` | input | 4 | 0 writes `tx_left`, 1 writes `tx_right`; other addresses are ignored | - | `clk` | - |
| `wdata` | input | `DW` | word written to the selected TX register | - | `clk` | - |
| `ren` | input | 1 | host read strobe; unused (reads have no side effect) | high | - | - |
| `raddr` | input | 4 | 0 reads `rx_left`, 1 reads `rx_right`, any other value reads 0 | - | comb. | - |
| `rdata` | output | `DW` | selected RX register, combinational | - | comb. | 0 |
| `irq` | output | 1 | frame sync: 1 for one `clk` at every detected LRCK change (`lrck_s ^ lrck_d`) | high | `clk` | 0 |

### Internal signals used by the verification

The checker reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `tx_left` | `DW` | left word to send, written by the host at `waddr` = 0 |
| `tx_right` | `DW` | right word to send, written at `waddr` = 1 |
| `rx_left` | `DW` | last complete left word received (`rdata` for `raddr` = 0) |
| `rx_right` | `DW` | last complete right word received (`rdata` for `raddr` = 1) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/I2S.md`](../ip/I2S.md) (source: `scripts/apb/specs/I2S.json`); do not edit by hand.

`I2S_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `bclk`, `lrck`, `sdin`, `sdout`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x49320200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX_LEFT | WO (core) | core | Left sample sent in each left slot (write-only) |
| 0x018 | TX_RIGHT | WO (core) | core | Right sample sent in each right slot (write-only) |
| 0x01C | RX_LEFT | RO (core) | core | Last left sample received |
| 0x020 | RX_RIGHT | RO (core) | core | Last right sample received |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4932 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX_LEFT | 15:0 | core register | WO (core) | core | written at core register 0 |
| TX_RIGHT | 15:0 | core register | WO (core) | core | written at core register 1 |
| RX_LEFT | 15:0 | core register | RO (core) | core | read from core register 0 |
| RX_RIGHT | 15:0 | core register | RO (core) | core | read from core register 1 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FRAME | LRCK changed (a channel slot started) |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x49320200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Sampling and clock ratio

At every `clk` edge: `bclk_s <= bclk`, `bclk_d <= bclk_s`, `lrck_s <= lrck`, `lrck_d <= lrck_s`,
`sdin_s <= sdin`. A rise is a `clk` edge where `bclk_s && !bclk_d`, a fall one where
`!bclk_s && bclk_d`, an LRCK change one where `lrck_s != lrck_d`. Because LRCK changes on a BCLK
fall, the LRCK change is normally detected at the same `clk` edge as that fall.

- SDOUT changes 1 to 2 `clk` periods after the BCLK fall (synchronizer and edge detect). The I2S
  transmitter rule (data valid at most 0.8 T after the previous rise, i.e. 0.3 T after the fall,
  leaving the receiver 0.2 T setup) needs 2 x T(clk) + t_co(pad) <= 0.3 x T(BCLK): `clk` at least
  7x BCLK, 8x or more so the pad delay fits.
- SDIN is sampled by `sdin_s` at the same `clk` edge as `bclk_s`, so the bit taken for a rise is
  SDIN at the first `clk` edge that sees BCLK high. The master must hold SDIN at least one `clk`
  period past its BCLK rise (a master that changes SDIN on the fall holds it T/2).

### 3.2 Transmit

- The host may write `tx_left` / `tx_right` at any time; a word is copied into the shifter only
  when its slot starts, so a write takes effect for the next slot of that channel that starts
  after it.
- At an LRCK change: `tx_pend` <= 1, `tx_ch` <= new LRCK.
- At each fall: if `tx_pend`, `tx_shift` <= (`tx_ch` ? `tx_right` : `tx_left`) and `tx_pend` <= 0;
  otherwise `tx_shift` shifts left by one with a 0 in.
- When the LRCK change is detected at the same edge as its fall, that fall still shifts (it puts
  the old word's next bit, the LSB for an exactly `DW`-bit slot, on the line) and the load
  happens at the following fall. So the new word's MSB is on SDOUT from one BCLK after the LRCK
  change and is sampled by the master at the second rise after it; bit *k* (1 = MSB) at rise
  *k* + 1.
- After the LSB the shifter outputs 0 for every further bit of a longer slot.

### 3.3 Receive

`rx_cnt` counts the bits of the current word (value `DW` = idle, nothing being assembled).

- At an LRCK change: `rx_pend` <= 1, `rx_ch_n` <= new LRCK.
- At each rise, first: if `rx_cnt` != `DW`, `rx_shift` takes `{rx_shift, sdin_s}` and `rx_cnt`
  increments; when `rx_cnt` was `DW`-1 this bit is the LSB and `{rx_shift, sdin_s}` is stored in
  `rx_left` (`rx_ch` = 0) or `rx_right` (`rx_ch` = 1).
- Then, at the same rise, if `rx_pend`: `rx_cnt` <= 0, `rx_ch` <= `rx_ch_n`, `rx_pend` <= 0.

So the first rise after an LRCK change still belongs to the previous word (it carries its LSB
when the slot is exactly `DW` bits) and the new word's MSB is taken at the second rise. A word is
stored at the rise of its LSB: rise `DW` + 1 after its LRCK change when the slot is longer, or the
first rise after the next LRCK change for an exact slot. Bits after the LSB are ignored. A slot
shorter than `DW` bits never reaches `rx_cnt` = `DW`-1, so its word is dropped and the register
keeps its previous value.

### 3.4 Host read and frame sync

`rdata` is `rx_left` for `raddr` = 0, `rx_right` for 1 and 0 for any other address,
combinational. `irq` = `lrck_s ^ lrck_d`: a one-`clk` pulse per LRCK change, 2 `clk` periods
(plus synchronizer uncertainty) after the LRCK edge; software uses it as a per-channel frame
sync.

### 3.5 Reset

`rst_n` low: synchronizers to 0, `tx_shift` = 0 (SDOUT = 0 at once), `tx_pend` = 0, all four data
registers 0, `rx_cnt` = `DW` (idle), `rx_pend` = 0. After reset SDOUT stays 0 and nothing is
received until the next LRCK change starts a slot.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 16 | even, >= 2 | sample width in bits, also the width of `wdata`, `rdata` and the four data registers. The checker's data classes assume an even width; the TB and the APB wrapper use 16 |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| slot longer than `DW` bits | TX sends 0 after the LSB; RX ignores the extra bits |
| slot exactly `DW` bits | the LSB is sent and received at the LRCK-change edge (§3.2, §3.3) |
| slot shorter than `DW` bits | TX word truncated; RX word is not stored, the register keeps the previous word |
| host write in the middle of a slot | does not affect the word being sent; used from the next slot of that channel |
| `waddr` other than 0 or 1 | write ignored |
| `raddr` other than 0 or 1 | reads 0 |
| reset in the middle of a word | SDOUT 0 at once, RX registers 0; the next run after an LRCK change is normal |
| `clk` slower than 7x BCLK | SDOUT may miss the 0.8 T transmitter limit; edges closer than 2 `clk` may be missed |

## 6. TB check map

Messages are printed by `tb/I2S_tb.sv` as `ERROR: <message>`. The TB is the I2S master
(BCLK half period 50 ns, later 36 ns, with a 10 ns `clk`). Assertions a_* are in
`tb/cov/I2S_sva.sv`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "I2S sdout changed" | SDOUT changes only while BCLK is low, within 2 `clk` of the fall and within 0.8 T of the previous rise | §3.1, §3.2 |
| "I2S slot" | for 16-bit, 32-bit and random 16..32-bit slots: every word on SDOUT matches `tx_left`/`tx_right`, and `rx_left`/`rx_right` hold the master's last words; also data classes, a run with 12-bit slots (not stored) | §3.2, §3.3, §5 |
| "I2S raddr 2" | `raddr` = 2 reads 0 | §3.4 |
| "I2S raddr 15" | `raddr` = 15 reads 0 | §3.4 |
| "I2S sdout not 0 in reset" | reset mid-word drives SDOUT to 0 | §3.5 |
| "I2S worst-case SDOUT delay not reached" | at 7.2 `clk` per BCLK the TB really saw a delay above 1.5 `clk` (the timing check above was exercised at its limit) | §3.1 |
| a_reset_quiet | in reset SDOUT = 0 and both RX registers 0 | §3.5 |
| a_sdout_model | at every rise SDOUT equals a pin-level model of the Philips framing | §3.2 |
| a_rx_model | `rx_left`/`rx_right` always equal the model's received words | §3.3 |
| a_irq_frame_sync | `irq` is exactly the detected LRCK change | §3.4 |
