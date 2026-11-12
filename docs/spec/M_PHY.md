<!-- SPDX-License-Identifier: Apache-2.0 -->
# M_PHY: design specification

A MIPI M-PHY-style lane, as an educational slice: a full 8b/10b codec (256 D-codes and 12 K-codes)
with running disparity, two gears modelled as NRZ bit-rate division, the DIF-N / DIF-P / DIF-Z line
states, HIBERN8 with a wake burst, and a receiver that hunts for the comma, frames 10-bit words and
flags code and disparity errors. Not implemented: real PWM signalling at LS gears, HS gears, the
line-state handshakes (PREPARE, SYNC) and clock recovery. Core `M_PHY_top` (`rtl/M_PHY_top.sv`),
testbench `tb/M_PHY_tb.sv` (TX looped back to RX, plus an injector), checker
`tb/cov/M_PHY_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *bit time* is 1 clock in G1 and 2 clocks in G2.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `irq` | output | 1 | sticky protocol error flag (TX or RX); combinational OR of two flags | high | `clk` | 0 |
| `irq_clear` | input | 1 | clear both error flags (a new error in the same clock wins) | high | `clk` | - |
| `gear` | input | 1 | 0 G1: one bit per clock, 1 G2: one bit per 2 clocks; change only while idle | - | `clk` | - |
| `hibern8_req` | input | 1 | pulse: enter HIBERN8 (taken while the TX is idle with an empty buffer) | high | `clk` | - |
| `wake_req` | input | 1 | pulse: leave HIBERN8 | high | `clk` | - |
| `hibern8` | output | 1 | the TX is in HIBERN8 (SAVE); combinational from the state | high | `clk` | 0 |
| `tx_data` | input | 8 | byte to send | - | `clk` | - |
| `tx_k` | input | 1 | 1 control code (K28.5 = 0xBC is the comma) | - | `clk` | - |
| `tx_valid` | input | 1 | a byte is offered | high | `clk` | - |
| `tx_ready` | output | 1 | the 1-deep buffer is empty and the TX is idle or shifting; combinational | high | comb | 1 |
| `tx_dif_p` | output | 1 | line +: DIF-N (0,1) idle, (bit, ~bit) in a burst, DIF-Z (0,0) in HIBERN8 | - | comb | 0 |
| `tx_dif_n` | output | 1 | line - | - | comb | 1 |
| `rx_dif_p` | input | 1 | receive line + (carries the data bits) | - | `clk` | - |
| `rx_dif_n` | input | 1 | receive line - (only used to see DIF-Z) | - | `clk` | - |
| `rx_locked` | output | 1 | the RX found a comma and frames words; combinational from the state | high | `clk` | 0 |
| `rx_hibern` | output | 1 | the RX sees the line in DIF-Z; combinational from the state | high | `clk` | 0 |
| `rx_data` | output | 8 | decoded byte with `rx_valid` | - | `clk` | 0 |
| `rx_k` | output | 1 | the decoded word was a K-code | high | `clk` | 0 |
| `rx_valid` | output | 1 | one-clock pulse: a decoded word (including the comma) | high | `clk` | 0 |

### Internal signals used by the verification

The TB polls `tstate`, `buf_valid` and `gap_cnt` to wait for the TX to go quiet; fsm_cov binds
`tstate` and `rstate`. Keep these names and encodings.

| Signal | Width | Meaning |
|---|---|---|
| `tstate` | 2 | TX: 0 IDLE, 1 SHIFT (burst), 2 SAVE (HIBERN8), 3 WAKE |
| `buf_valid` | 1 | the 1-deep TX buffer holds a byte |
| `gap_cnt` | 5 | inter-burst idle clocks still owed |
| `rstate` | 2 | RX: 0 HUNT, 1 LOCK, 2 HIB |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/M_PHY.md`](../ip/M_PHY.md) (source: `scripts/apb/specs/M_PHY.json`); do not edit by hand.

`M_PHY_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_dif_p`, `tx_dif_n`, `rx_dif_p`, `rx_dif_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4D500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x018 | CFG | RW | 0x00000000 | Gear |
| 0x01C | TX | RW | 0x00000000 | Byte to send; start each burst with the comma K28.5 (0xBC with K). A byte every 10 bit times keeps the burst going; a gap ends it |
| 0x020 | RX | RO (pop) | 0x00000000 | Byte decoded by the receiver (the comma included); reading RX frees it |
| 0x024 | STATUS | RO | core | Lane state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4D50 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD | 0 | `hibern8_req` | WO (pulse) | 0x0 | write 1: enter HIBERN8 (SAVE state, lines DIF-Z) once the lane is idle; a buffered byte goes first |
| CMD | 1 | `wake_req` | WO (pulse) | 0x0 | write 1: leave HIBERN8 (8-clock DIF-N wake burst) |
| CMD | 2 | `irq_clear` | WO (pulse) | 0x0 | write 1: clear the sticky receive / transmit error (an error in the same clock wins) |
| CFG | 0 | `gear` | RW | 0x0 | 0: G1 (1 bit per clock), 1: G2 (1 bit per 2 clocks); change only while the lane is idle (a change while locked makes the receiver re-hunt) |
| TX | 7:0 | `tx_data` | RW | 0x0 | byte |
| TX | 8 | `tx_k` | RW | 0x0 | 1: control code (K28.0-7, K23.7, K27.7, K29.7, K30.7; other K-codes are dropped with ERROR) |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | byte |
| RX | 8 | `rx_k` | RO (pop) | 0x0 | control code |
| STATUS | 0 | `hibern8` | RO | core | the transmitter is in HIBERN8 |
| STATUS | 1 | `rx_locked` | RO | core | the receiver found the comma and frames 10-bit words |
| STATUS | 2 | `rx_hibern` | RO | core | the receive line is in DIF-Z (hibernated) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERROR | an unsupported K-code was dropped, or the receiver saw an invalid code or a disparity error; sticky in the core, so the bit is set again on every clock until CMD.irq_clear |
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

* **TX** feeds `tx_data`, `tx_k`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_k` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4D500200.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `hibern8_req` (CMD bit 0), `wake_req` (CMD bit 1), `irq_clear` (CMD bit 2) at 0x014; the core sees a one-clock pulse, and the register reads 0.
6. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x01C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
7. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x020). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 3) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
8. Read STATUS (0x024) for the core's live `hibern8`, `rx_locked`, `rx_hibern`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Coding

IEEE 802.3 clause 36 8b/10b, word bits abcdei fghj, bit a sent first, with the D.x.A7 and K28 rules
and running disparity (RD). Allowed K-codes: K28.0..K28.7, K23.7, K27.7, K29.7, K30.7. The TX
running disparity starts at RD- after reset and carries over between bursts.

### 3.2 Transmit

`tx_ready` = buffer empty and TX in IDLE or SHIFT. A handshake loads the buffer. The user starts
each burst with K28.5 (`tx_k` = 1, 0xBC) so the far receiver can align.

- IDLE: the inter-burst counter counts down one per clock. With a byte buffered, the counter at 0
  and a codable byte, the TX loads the word (buffer emptied) and enters SHIFT; the first bit is on
  the line from that edge (one idle clock after the buffer was loaded). A byte that is a K-code
  outside the allowed set is dropped and sets the TX error flag.
- SHIFT: one bit per bit time, bit a first. At the end of the 10th bit, a buffered codable byte is
  loaded at once (back-to-back words); otherwise (or after dropping an uncodable byte with the TX
  error flag) the burst ends: IDLE with the counter at 10 (G1) or 20 (G2) clocks, so the line is
  DIF-N for at least 10 bit times plus one clock before the next burst.

### 3.3 Line states

| TX state | (`tx_dif_p`, `tx_dif_n`) |
|---|---|
| IDLE, WAKE | DIF-N (0, 1) |
| SHIFT | (bit, ~bit) |
| SAVE | DIF-Z (0, 0) |

The line outputs are combinational from the state and the word register.

### 3.4 HIBERN8

`hibern8_req` while IDLE with an empty buffer: SAVE (`hibern8` = 1, DIF-Z, `tx_ready` = 0). In SAVE,
`wake_req` starts WAKE: 8 clocks of DIF-N, then IDLE. `hibern8_req` in other states is ignored.

### 3.5 Receive

HUNT: each clock the newest `rx_dif_p` bits are compared with K28.5 in either RD form, as 10 bits
(G1) or 20 bits with every bit doubled (G2). A match (on the clock of the comma's last bit) gives
LOCK, outputs the comma as a word (`rx_data` = 0xBC, `rx_k` = 1, `rx_valid`), and sets the RD after
the comma (RD+ after the RD- form, RD- after the RD+ form).

LOCK: one bit per bit time (G2: on the second clock of each bit). Every 10 bits:

- all 10 bits 0 (an idle DIF-N word): the burst is over, back to HUNT;
- a word that re-encodes exactly as a D-code, or as an allowed K-code, with the current RD:
  `rx_valid` with the byte and `rx_k`, RD updated;
- anything else (code or disparity violation): the RX error flag is set, no output; RD follows
  the word's unbalanced sub-blocks.

A change of `gear` while locked returns to HUNT.

### 3.6 RX hibernation

In any RX state, both receive lines low for a third consecutive clock gives HIB (`rx_hibern`).
In HIB, either line going high returns to HUNT with the hunt register cleared.

### 3.7 Reset

Line DIF-N, `tx_ready` = 1, buffer empty, `hibern8` = 0, `irq` = 0, RX in HUNT, `rx_valid` = 0, both
running disparities RD-.

## 4. Parameters

None.

## 5. Errors and corner cases

`irq` = TX error flag \|\| RX error flag. The TX flag is set by an uncodable K-code (dropped), the
RX flag by a code or disparity violation in LOCK. Both are sticky until `irq_clear`. Gear changes
during a burst are outside the contract (the RX re-hunts).

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "burst" | every word sent comes back in the loopback | §3.2, §3.5 |
| "word" | each received word equals the one sent (byte and K flag) | §3.5 |
| "irq after a clean burst" | no `irq` for valid traffic | §5 |
| "reset state" | reset values | §3.7 |
| "burst queued in the gap" | a burst offered during the inter-burst gap waits and arrives whole | §3.2 |
| "unsupported K-code raises irq" | a K-code outside the 12 allowed ones is dropped with `irq` | §3.1, §5 |
| "irq_clear" | `irq_clear` clears `irq` | §5 |
| "unsupported K-code at idle raises irq" | also when the TX is idle | §3.2 |
| "HIBERN8 entered" | `hibern8`, DIF-Z on the line, `rx_hibern` at the far end | §3.4, §3.6 |
| "tx_ready low in HIBERN8" | no bytes taken in HIBERN8 | §3.4 |
| "woke up" | after `wake_req` the line returns to DIF-N | §3.4 |
| "invalid code raises irq" | a word not in the code tables sets `irq` | §3.5 |
| "disparity error raises irq" | a word with the wrong running disparity sets `irq` | §3.5 |
| "RD+ comma then a matching code" | after an RD+ comma the RX expects RD- words | §3.5 |
| "gear change while locked re-hunts" | a gear change drops the lock | §3.5 |
| "DIF-Z seen as hibernation" | 3 clocks of DIF-Z give `rx_hibern` | §3.6 |
| "wake re-hunts" | leaving DIF-Z returns to hunting | §3.6 |
| "reset mid-burst" | a reset in a burst returns the lane to DIF-N, unlocked, `irq` = 0 | §3.7 |
| a_reset_idle | in reset: DIF-N, `hibern8` = 0, `irq` = 0, RX unlocked, no `rx_valid` | §3.7 |
| a_tx_line | line state equals the checker's TX model, clock for clock | §3.2..§3.4 |
| a_tx_ready | `tx_ready` as the model | §3.2 |
| a_hibern8 | `hibern8` exactly in SAVE | §3.4 |
| a_irq | `irq` = model TX error \|\| RX error | §5 |
| a_rx_state | `rx_locked` / `rx_hibern` as the model | §3.5, §3.6 |
| a_rx_valid | `rx_valid` as the model | §3.5 |
| a_rx_word | `rx_data` / `rx_k` with `rx_valid` | §3.5 |
