<!-- SPDX-License-Identifier: Apache-2.0 -->
# DigRF: design specification

A DigRF v4-style baseband / RF IC link endpoint, as an educational slice: one transmit and one
receive lane with 8b/10b coding, bursts with sync and filler symbols, and framed logical channels
for data, control register writes and reads with responses, and interrupts. Not implemented: the
M-PHY (gears, line states, clock recovery; the receiver runs on the transmitter's bit clock at any
phase), more lanes, CRC, flow control and retransmission; the header layout is this design's own.
Core `DigRF_top` (`rtl/DigRF_top.sv`), testbench `tb/DigRF_tb.sv` (two endpoints back to back plus
a lane BFM with its own 8b/10b tables), checker `tb/cov/DigRF_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *symbol boundary* is the clock where the transmitter has sent the
last bit of a symbol (or, with the lane stopped, the clock where it starts a burst); the next
symbol is chosen and loaded there.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one line bit per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `tx_p` | output | 1 | transmit lane: symbol bit a first; 0 while the lane is stopped | - | `clk` | 0 |
| `rx_p` | input | 1 | receive lane, any bit phase | - | `clk` | - |
| `cfg_sync` | input | 4 | K28.5 sync symbols at the start of a burst (0 means 1) | - | `clk` | - |
| `cfg_hold` | input | 8 | K28.5 fillers in a row before the burst ends | - | `clk` | - |
| `cfg_timeout` | input | 8 | read response timeout in units of 16 clocks | - | `clk` | - |
| `ctl_valid` | input | 1 | a control request (write or read) is offered | high | `clk` | - |
| `ctl_ready` | output | 1 | no request is waiting to be sent and no read is outstanding; combinational | high | comb | 1 |
| `ctl_rd` | input | 1 | 1 read, 0 write | - | `clk` | - |
| `ctl_addr` | input | 8 | register address | - | `clk` | - |
| `ctl_wdata` | input | 8 | write data | - | `clk` | - |
| `rsp_valid` | output | 1 | one-clock pulse: the outstanding read was answered | high | `clk` | 0 |
| `rsp_data` | output | 8 | read data with `rsp_valid` | - | `clk` | 0 |
| `rsp_timeout` | output | 1 | one-clock pulse: the outstanding read timed out | high | `clk` | 0 |
| `reg_we` | output | 1 | one-clock pulse: a received CTRL_WR writes the local register file | high | `clk` | 0 |
| `reg_re` | output | 1 | one-clock pulse: a received CTRL_RD reads the local register file | high | `clk` | 0 |
| `reg_addr` | output | 8 | register address with `reg_we` / `reg_re` | - | `clk` | 0 |
| `reg_wdata` | output | 8 | write data with `reg_we` | - | `clk` | 0 |
| `reg_rdata` | input | 8 | read data, sampled one clock after `reg_re` | - | `clk` | - |
| `int_valid` | input | 1 | an interrupt vector is offered | high | `clk` | - |
| `int_ready` | output | 1 | no interrupt is waiting to be sent; combinational | high | comb | 1 |
| `int_vec` | input | 5 | interrupt vector | - | `clk` | - |
| `int_rx` | output | 1 | one-clock pulse: an INT frame arrived | high | `clk` | 0 |
| `int_rx_vec` | output | 5 | its vector | - | `clk` | 0 |
| `dtx_valid` | input | 1 | a data frame byte is offered (size and channel with the first byte) | high | `clk` | - |
| `dtx_ready` | output | 1 | the offered byte is taken this clock; combinational | high | comb | 0 |
| `dtx_data` | input | 8 | payload byte | - | `clk` | - |
| `dtx_size` | input | 3 | frame size code: 8 << size bytes; 6 and 7 are sent as 5 | - | `clk` | - |
| `dtx_chan` | input | 2 | logical data channel | - | `clk` | - |
| `drx_valid` | output | 1 | one-clock pulse: a received payload byte (no back-pressure) | high | `clk` | 0 |
| `drx_data` | output | 8 | received byte | - | `clk` | 0 |
| `drx_sof` | output | 1 | first byte of the frame | high | `clk` | 0 |
| `drx_eof` | output | 1 | last byte of the frame | high | `clk` | 0 |
| `drx_chan` | output | 2 | channel of the frame | - | `clk` | 0 |
| `drx_abort` | output | 1 | one-clock pulse: the data frame being received broke off | high | `clk` | 0 |
| `tx_on` | output | 1 | the transmit lane is in a burst; combinational | high | comb | 0 |
| `rx_locked` | output | 1 | the receiver is symbol-aligned | high | `clk` | 0 |
| `err_code` | output | 1 | one-clock pulse: code violation or disparity error | high | `clk` | 0 |
| `err_frame` | output | 1 | one-clock pulse: framing error (section 5) | high | `clk` | 0 |
| `tx_underrun` | output | 1 | one-clock pulse: a data payload byte was not offered and 0 was sent | high | `clk` | 0 |

### Internal signals used by the verification

fsm_cov binds the two state registers; keep their names and encodings.

| Signal | Width | Meaning |
|---|---|---|
| `ts` | 3 | transmitter: 0 OFF, 1 SYNC, 2 GAP (between frames), 3 HDR, 4 PAY, 5 EOB (sending K29.7) |
| `rs` | 2 | receiver: 0 IDLE (between frames), 1 HDR, 2 PAY |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/DigRF.md`](../ip/DigRF.md) (source: `scripts/apb/specs/DigRF.json`); do not edit by hand.

`DigRF_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_p`, `rx_p`, `reg_we`, `reg_re`, `reg_addr`, `reg_wdata`, `reg_rdata`, `dtx_valid`, `dtx_ready`, `dtx_data`, `dtx_size`, `dtx_chan`, `drx_valid`, `drx_data`, `drx_sof`, `drx_eof`, `drx_chan`, `drx_abort`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44460200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00040102 | Burst and timeout configuration |
| 0x018 | CTL | RW | 0x00000000 | Register access to the peer; writing CTL commits it. A read is answered through RSP (or RSP_TIMEOUT); the next access waits for it |
| 0x01C | RSP | RO (pop) | 0x00000000 | Read data from the peer; reading RSP frees it |
| 0x020 | INT_TX | RW | 0x00000000 | Interrupt message to the peer; writing INT_TX commits it |
| 0x024 | INT_RX | RO (pop) | 0x00000000 | Interrupt message from the peer; reading INT_RX frees it |
| 0x028 | STATUS | RO | core | Lane state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4446 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 11:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 11:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 3:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 3:0 | `cfg_sync` | RW | 0x2 | K28.5 sync symbols at the start of a burst (0 = 1) |
| CFG | 11:4 | `cfg_hold` | RW | 0x10 | K28.5 fillers in a row before the lane stops (K29.7) |
| CFG | 19:12 | `cfg_timeout` | RW | 0x40 | read timeout, x 16 PCLK |
| CTL | 7:0 | `ctl_wdata` | RW | 0x0 | write data |
| CTL | 15:8 | `ctl_addr` | RW | 0x0 | peer register address |
| CTL | 16 | `ctl_rd` | RW | 0x0 | 1 = read, 0 = write |
| RSP | 7:0 | `rsp_data` | RO (pop) | 0x0 | read data |
| INT_TX | 4:0 | `int_vec` | RW | 0x0 | interrupt vector |
| INT_RX | 4:0 | `int_rx_vec` | RO (pop) | 0x0 | interrupt vector |
| STATUS | 0 | `tx_on` | RO | core | a burst is being sent |
| STATUS | 1 | `rx_locked` | RO | core | the receiver is aligned to the incoming burst |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RSP_TIMEOUT | a read got no response within CFG.cfg_timeout |
| 1 | ERR_CODE | 8b/10b code violation or disparity error (the receiver realigns) |
| 2 | ERR_FRAME | bad header or size, unexpected control symbol, data between frames, or a response with no matching read |
| 3 | UNDERRUN | a data payload byte was missing and sent as 0 |
| 4 | CTL_DONE | CTL beat accepted by the core |
| 5 | CTL_OVF | write to CTL while full (dropped) |
| 6 | RSP_AVAIL | RSP captured a beat |
| 7 | RSP_OVF | beat dropped, RSP was full |
| 8 | INT_TX_DONE | INT_TX beat accepted by the core |
| 9 | INT_TX_OVF | write to INT_TX while full (dropped) |
| 10 | INT_RX_AVAIL | INT_RX captured a beat |
| 11 | INT_RX_OVF | beat dropped, INT_RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CTL_FULL | CTL holds a beat the core has not taken |
| 1 | RSP_AVAIL | RSP holds an unread beat |
| 2 | INT_TX_FULL | INT_TX holds a beat the core has not taken |
| 3 | INT_RX_AVAIL | INT_RX holds an unread beat |

### Streams

* **CTL** feeds `ctl_wdata`, `ctl_addr`, `ctl_rd`/`ctl_valid`. Writing CTL commits the beat: FLAGS.CTL_FULL is set and `ctl_valid` stays high until the core's `ctl_ready`; then CTL_DONE is set. A write while full is dropped and sets CTL_OVF.
* **RSP** captures `rsp_data` when `rsp_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RSP_AVAIL. Reading RSP pops it. A beat that arrives while the register is full is dropped and sets RSP_OVF.
* **INT_TX** feeds `int_vec`/`int_valid`. Writing INT_TX commits the beat: FLAGS.INT_TX_FULL is set and `int_valid` stays high until the core's `int_ready`; then INT_TX_DONE is set. A write while full is dropped and sets INT_TX_OVF.
* **INT_RX** captures `int_rx_vec` when `int_rx` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ INT_RX_AVAIL. Reading INT_RX pops it. A beat that arrives while the register is full is dropped and sets INT_RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44460200.
2. Write 0xFFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xFFF enables all).
5. To send on CTL: wait until FLAGS.CTL_FULL (bit 0) is 0, or for IRQ CTL_DONE, then write CTL (0x018). The last write commits the beat. CTL_OVF means a write came while the register was full and was dropped.
6. To receive on RSP: wait for IRQ RSP_AVAIL or FLAGS.RSP_AVAIL (bit 1), then read RSP (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RSP_AVAIL (bit 6) to clear it. Read each beat before the next arrives, or it is dropped and RSP_OVF is set.
7. To send on INT_TX: wait until FLAGS.INT_TX_FULL (bit 2) is 0, or for IRQ INT_TX_DONE, then write INT_TX (0x020). The last write commits the beat. INT_TX_OVF means a write came while the register was full and was dropped.
8. To receive on INT_RX: wait for IRQ INT_RX_AVAIL or FLAGS.INT_RX_AVAIL (bit 3), then read INT_RX (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.INT_RX_AVAIL (bit 10) to clear it. Read each beat before the next arrives, or it is dropped and INT_RX_OVF is set.
9. Read STATUS (0x028) for the core's live `tx_on`, `rx_locked`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Line coding

8b/10b per IEEE 802.3 clause 36, symbol bits abcdei fghj with a sent first, with running disparity.
Control symbols used: K28.5 (sync and filler), K28.1 (start of frame), K29.7 (end of burst). The
transmitter starts every burst at RD-. A symbol takes 10 clocks.

### 3.2 Bursts

While no burst is running `tx_p` = 0 and `tx_on` = 0. A burst starts in the first clock in which
anything is waiting to be sent (a read response, an interrupt, a control request or `dtx_valid`):
the first sync symbol is loaded at that edge and its bit a is on `tx_p` from then on. Symbol order:

1. max(`cfg_sync`, 1) x K28.5;
2. frames, back to back when more are waiting, otherwise K28.5 fillers;
3. at a symbol boundary between frames with nothing waiting, after `cfg_hold` fillers in a row
   (immediately when `cfg_hold` = 0): K29.7; after it the lane stops.

Anything that becomes ready while K29.7 is on the line waits, and starts a new burst after the
lane stopped.

### 3.3 Frames

Frame = K28.1, header byte {LCT[2:0], F[4:0]}, payload bytes:

| LCT | Name | F | Payload |
|---|---|---|---|
| 0 | DATA | {chan[1:0], size[2:0]} | 8 << size bytes (size 0..5) |
| 1 | CTRL_WR | tag | {addr, data} |
| 2 | CTRL_RD | tag | {addr} |
| 3 | CTRL_RSP | tag of the read | {data} |
| 4 | INT | vector | none |

At a symbol boundary between frames, the frame to send is chosen by priority: read response,
interrupt, control request, data. The source is taken when the K28.1 is loaded: the response and
interrupt slots are freed (`int_ready` rises), the control request leaves its slot.

### 3.4 Data transmit

A DATA frame is chosen when `dtx_valid` is high at the boundary; `dtx_size` (6 and 7 become 5) and
`dtx_chan` are sampled then. Each payload byte is taken at its own symbol boundary: `dtx_ready` =
1 in that clock when `dtx_valid` is high (combinational), and `dtx_data` is coded. With `dtx_valid`
low at a payload boundary, 0x00 is sent and `tx_underrun` pulses in the next clock; the frame
always has its full length.

### 3.5 Control master

`ctl_ready` = no request waiting and no read outstanding. A handshake stores the request. When it
is sent (K28.1 loaded) it carries the current tag, and the tag counter (5 bits, from 0 after
reset) counts up. A read becomes outstanding with a timer of `cfg_timeout` x 16 clocks; each clock
it is decremented, and when it is 0 `rsp_timeout` pulses and the read is no longer outstanding. A
CTRL_RSP with the outstanding tag gives `rsp_valid` with its data and ends the read; a CTRL_RSP
with another tag, or with no read outstanding (also a response that comes after the timeout), is
a framing error.

### 3.6 Receive alignment

`rx_p` is registered, then shifted into a 10-bit window. Unlocked, the receiver looks for K28.5
(either disparity form) at every bit offset; a match locks it, sets the running disparity after
that comma, and from then on a symbol is decoded every 10 clocks. A locked receiver does not
re-align on commas. A symbol that is not a valid code for the current running disparity pulses
`err_code` and unlocks; a K29.7 unlocks without error.

### 3.7 Receive frames

At each decoded symbol:

- control symbol: K28.1 starts a frame (header next); K28.5 and K29.7 return to IDLE. Any control
  symbol inside a frame (header or payload), or one other than these three, pulses `err_frame`; a
  data frame cut this way pulses `drx_abort`.
- data symbol between frames: `err_frame`.
- header: DATA with size above 5, or LCT 5..7: `err_frame`, frame dropped. INT: `int_rx` with the
  vector, frame done.
- payload: DATA bytes go out at once on `drx_*` (`drx_sof` on the first, `drx_eof` on the last,
  `drx_chan` from F). CTRL_WR: after the second byte `reg_we` pulses with `reg_addr` = first byte,
  `reg_wdata` = second. CTRL_RD: `reg_re` pulses with `reg_addr`; `reg_rdata` is sampled in the
  next clock and a CTRL_RSP with the read's tag is queued (sent with top priority). CTRL_RSP: see 3.5.

A code error inside a frame drops it (`drx_abort` for a data frame).

### 3.8 Reset

`tx_p` = 0, lane stopped, nothing pending (`ctl_ready` = `int_ready` = 1), tag 0, receiver unlocked
and idle, all pulses and data outputs 0.

## 4. Parameters

None. `cfg_*` should be stable while a burst is running.

## 5. Errors and corner cases

| Pulse | Cause |
|---|---|
| `err_code` | invalid code or wrong running disparity while locked (unlocks) |
| `err_frame` | data symbol between frames; control symbol inside a frame or unknown control symbol; bad LCT; DATA size above 5; CTRL_RSP with no matching outstanding read |
| `drx_abort` | a DATA frame broken off by a control symbol or a code error |
| `tx_underrun` | a DATA payload byte not offered in time |
| `rsp_timeout` | no matching response within `cfg_timeout` x 16 clocks |

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "lane" | a stopped lane is 0; every symbol in a burst is a valid 8b/10b code for the running disparity | §3.1, §3.2 |
| "byte taken with tx_underrun" | no `dtx_ready` together with an underrun | §3.4 |
| "side" | per side: no unexpected errors or aborts; data bytes, SOF / EOF, channel, interrupts and read responses (or timeouts) as sent by the peer; nothing missing | §3.3..§3.7 |
| "link did not go quiet" | both lanes stop after the traffic | §3.2 |
| "late response not flagged" | a response after the timeout is a framing error | §3.5, §5 |
| "only" | every injected receive error is flagged | §5 |
| a_tx_bit | each `tx_p` bit equals the checker's transmit model | §3.1..§3.4 |
| a_tx_on | `tx_on` during a burst | §3.2 |
| a_tx_off | `tx_p` = 0 when the lane is stopped | §3.2 |
| a_dtx_ready | `dtx_ready` as the model | §3.4 |
| a_underrun | `tx_underrun` as the model | §3.4 |
| a_ctl_ready | `ctl_ready` | §3.5 |
| a_int_ready | `int_ready` | §3.3 |
| a_timeout | `rsp_timeout` | §3.5 |
| a_locked | `rx_locked` | §3.6 |
| a_err | `err_code` and `err_frame` | §5 |
| a_reg | `reg_we` / `reg_re` | §3.7 |
| a_reg_data | `reg_addr` / `reg_wdata` | §3.7 |
| a_rsp | `rsp_valid` | §3.5 |
| a_rsp_data | `rsp_data` | §3.5 |
| a_int | `int_rx` | §3.7 |
| a_int_vec | `int_rx_vec` | §3.7 |
| a_drx | `drx_valid` / `drx_abort` | §3.7 |
| a_drx_data | `drx_data`, `drx_sof`, `drx_eof`, `drx_chan` | §3.7 |
| a_rst | reset values | §3.8 |
