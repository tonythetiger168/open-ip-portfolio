# WTB: design specification

A teaching slice of an IEEE 802.4-style token-bus station on a 1-bit serial bus. While the station holds the token, it sends data frames from an 8-word TX FIFO, then passes the token to the next station. After the bus has been idle for `IDLE_TO` clocks it contends with claim_token frames. It delivers data frames addressed to it, or broadcast, into an 8-word RX FIFO.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset value |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one bus bit per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rx_bit` | input | 1 | serial bus receive (idle 1, MSB first); the station also hears its own frames here | - | `clk` | - |
| `tx_bit` | output | 1 | serial bus transmit (1 when idle) | - | `clk` | 1 |
| `tx_en` | output | 1 | station drives the bus (whole frame, preamble to ED) | high | `clk` | 0 |
| `my_addr` | input | 8 | station address (SA of sent frames, DA match on receive) | - | static | - |
| `cpu_we` | input | 1 | CPU write strobe | high | `clk` | - |
| `cpu_addr` | input | 2 | CPU write address (§2.1) | - | `clk` | - |
| `cpu_wdata` | input | 32 | CPU write data | - | `clk` | - |
| `cpu_re` | input | 1 | pop the RX FIFO head (ignored when empty) | high | `clk` | - |
| `cpu_rdata` | output | 32 | RX FIFO head word, combinational | - | comb. | undefined (FIFO storage is not reset) |
| `fifo_count` | output | 4 | TX FIFO occupancy 0-8 | - | `clk` | 0 |
| `rx_count` | output | 4 | RX FIFO occupancy 0-8 | - | `clk` | 0 |
| `token_held` | output | 1 | station is in HOLD or PASS (owns the token) | high | `clk` | 0 |
| `irq` | output | 1 | one-clock event pulse (§3.7) | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these through `dut.`. A re-implementation must keep these names, timings and encodings.

| Signal | Width | Meaning |
|---|---|---|
| `sstate` | 3 | station FSM: 0 ST_LISTEN, 1 ST_HOLD, 2 ST_CLAIM_TX, 3 ST_CLAIM_WAIT, 4 ST_PASS |
| `rx_done` | 1 | one-clock pulse the clock after a frame's ED: good CRC, good ED and SA != `my_addr` |
| `fifo_pop` | 1 | one-clock pulse, the clock after a data frame was started: the TX FIFO head is popped at this edge |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/WTB.md`](../ip/WTB.md) (source: `scripts/apb/specs/WTB.json`); do not edit by hand.

`WTB_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_bit`, `tx_bit`, `tx_en`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x57540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | MYADDR | RW | 0x00000011 | Station identity |
| 0x018 | STATUS | RO | core | Station state |
| 0x01C | TXF | WO (core) | core | push one 32-bit word (the payload of one 4-byte data frame) onto the TX FIFO; a push to a full FIFO is dropped with EVT |
| 0x020 | NS | WO (core) | core | [7:0] next station: DA of the token pass |
| 0x024 | DA | WO (core) | core | [7:0] DA of the data frames |
| 0x028 | CTRL | WO (core) | core | [16:8] token holding window in clocks, [0] claim_en (claim the token after 300 idle clocks) |
| 0x02C | RXF | RO (core) | core | RX FIFO head: received payload bytes packed big-endian, the last word zero-padded; the read pops it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5754 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| MYADDR | 7:0 | `my_addr` | RW | 0x11 | this station's bus address (DA of its tokens and data, SA of its frames) |
| STATUS | 3:0 | `fifo_count` | RO | core | TX FIFO words (0..8) |
| STATUS | 7:4 | `rx_count` | RO | core | RX FIFO words (0..8) |
| STATUS | 8 | `token_held` | RO | core | the station holds the token |
| TXF | 31:0 | core register | WO (core) | core | written at core register 0 |
| NS | 31:0 | core register | WO (core) | core | written at core register 1 |
| DA | 31:0 | core register | WO (core) | core | written at core register 2 |
| CTRL | 31:0 | core register | WO (core) | core | written at core register 3 |
| RXF | 31:0 | core register | RO (core) | core | read from core register 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | EVT | token acquired, or an error: bad CRC, bad ED or overlong frame received, TX FIFO overflow, RX FIFO overflow |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `cpu_we` for one clock with `cpu_addr` (the core register) and `cpu_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `cpu_addr` (the core register) and pulses `cpu_re` during the access phase and returns `cpu_rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x57540200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write MYADDR (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. Read STATUS (0x018) for the core's live `fifo_count`, `rx_count`, `token_held`; it needs no clearing.
6. Access the core's registers through the CORE words (0x01C onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

### 2.1 Core CPU port

Every register is write-only; the only readable data is the RX FIFO head on `cpu_rdata`.

| `cpu_addr` | Write effect | Reset |
|---|---|---|
| 0 | push `cpu_wdata` to the TX FIFO (8 x 32) | empty |
| 1 | NS (next-station address) = wdata[7:0] | 8'h02 |
| 2 | DA for data frames = wdata[7:0] | 8'hFF (broadcast) |
| 3 | `claim_en` = wdata[0]; hold window = wdata[8 +: HW], HW = clog2(`HOLD_WIN` + 1) | 0, `HOLD_WIN` |

A push and a station pop may happen in the same clock. A push to a full FIFO with no pop in that clock is dropped and pulses `irq` one clock later.

### 2.1 Core CPU port

Every register is write-only; the only readable data is the RX FIFO head on `cpu_rdata`.

| `cpu_addr` | Write effect | Reset |
|---|---|---|
| 0 | push `cpu_wdata` to the TX FIFO (8 x 32) | empty |
| 1 | NS (next-station address) = wdata[7:0] | 8'h02 |
| 2 | DA for data frames = wdata[7:0] | 8'hFF (broadcast) |
| 3 | `claim_en` = wdata[0]; hold window = wdata[8 +: HW], HW = clog2(`HOLD_WIN` + 1) | 0, `HOLD_WIN` |

A push and a station pop may happen in the same clock. A push to a full FIFO with no pop in that clock is dropped and pulses `irq` one clock later.

## 3. Timing

### 3.1 Bus

The bus carries one bit per clock, MSB first within each byte, and idles at 1.

### 3.2 Frame format

| Byte | Value |
|---|---|
| 0-1 | preamble 8'h55, 8'h55 |
| 2 | SD 8'hD5 |
| 3 | FC: 0 claim_token, 1 token, 2 data, 3 solicit (the station sends 0, 1 and 2) |
| 4 | DA |
| 5 | SA (`my_addr` on sent frames) |
| 6 | LEN (payload bytes; received frames allow 0-16) |
| 7.. | payload |
| +2 | CRC16 high byte, then low byte: poly 0x1021, init 8'hFFFF, over FC, DA, SA, LEN and payload |
| last | ED 8'hD4 |

The station sends three kinds of frame:

| Frame | DA | LEN | Payload | Length |
|---|---|---|---|---|
| Data | DA register | 4 | the FIFO word, bits 31:24 first | 14 bytes, 112 clocks |
| Token | NS | 0 | none | 10 bytes, 80 clocks |
| Claim | 8'hFF | 0 | none | 10 bytes, 80 clocks |

Transmit timing:
- A frame starts the clock after the station FSM requests it.
- `tx_en` rises with the first preamble bit and stays high through the last ED bit.
- The transmitter's internal `tx_done` pulse coincides with the last ED bit.
- On the next clock `tx_en` = 0 and `tx_bit` = 1.

### 3.3 Receive

The receiver hunts bit by bit for the 16-bit pattern 8'h55, 8'hD5. It does not need the first preamble byte. Once synced, it takes byte-aligned fields and does not re-hunt until the frame ends.

Errors:
- **LEN > 16:** an `irq` pulse at the LEN byte, and the receiver returns to hunting.
- **CRC mismatch:** an `irq` pulse at the CRC low byte.
- **ED other than 8'hD4:** an `irq` pulse at the ED byte.

A frame with both a CRC and an ED error gives two pulses.

`rx_done` pulses the clock after the ED byte if the CRC and ED are good and SA != `my_addr`. The station ignores its own frames, but their errors still pulse `irq`.

### 3.4 Delivery to the RX FIFO

Delivery happens on `rx_done` when FC = 2 and DA = `my_addr` or 8'hFF:
- The payload is packed big-endian into ceil(LEN/4) words. The first byte goes in bits 31:24, and the last word is zero-padded.
- One word is pushed per clock, starting the clock after `rx_done`. A LEN = 0 frame delivers nothing.
- A word that meets a full FIFO, with no pop in that clock, is dropped and pulses `irq`. Each dropped word gives one pulse.

`cpu_rdata` always shows the head entry. `cpu_re` pops it when the FIFO is not empty.

### 3.5 Station FSM and token holding

`token_held` = (`sstate` == ST_HOLD or ST_PASS).

- **ST_LISTEN:** a good token frame (FC = 1, DA = `my_addr`) moves the station to ST_HOLD with an `irq` pulse, and the hold counters reset. Tokens for other stations, solicit frames and the station's own token echo are ignored.
- **ST_HOLD:** the hold counter counts clocks and stops at the hold window. Whenever the transmitter is idle, the station decides:
  - if fewer than `MAX_FR` data frames were sent in this hold, the hold counter is below the window, and the TX FIFO is not empty, it sends a data frame with the FIFO head word. `fifo_pop` pulses on the next clock and pops it.
  - otherwise it sends a token to NS and moves to ST_PASS.

  The window is checked only when a frame starts, so a frame started inside the window always completes.
- **ST_PASS:** on `tx_done` the station returns to ST_LISTEN, and `token_held` falls one clock after the last ED bit.

### 3.6 Claim contention

`idle_cnt` counts consecutive clocks with `rx_bit` = 1 and saturates at `IDLE_TO`. It clears on any 0.
1. **Start:** in ST_LISTEN, with `claim_en` = 1 and `idle_cnt` = `IDLE_TO`, the station sends a claim frame and enters ST_CLAIM_TX.
2. **Wait:** after the claim frame it enters ST_CLAIM_WAIT with a counter at 0.
3. **Outcome:**
   - **Win:** a token for `my_addr`, or reaching `CLAIM_WIN` clocks with no `rx_done` in that clock, moves the station to ST_HOLD with an `irq` pulse.
   - **Ignore:** a claim from a higher SA is ignored.
   - **Back off:** any other good frame (a claim from a lower SA, or other traffic) returns the station to ST_LISTEN.

### 3.7 irq

`irq` is the combinational OR of four registered one-clock pulses:
- bad frame (CRC, ED or LEN);
- TX FIFO overflow;
- RX FIFO overflow;
- token acquired.

Pulses in the same clock merge.

### 3.8 Reset

`rst_n` low resets the station:
- `tx_en` = 0 and `tx_bit` = 1;
- both FIFOs are emptied;
- `token_held` = 0 and `irq` = 0;
- the station returns to ST_LISTEN, and the registers take their reset values from §2.1.

A reset during a hold drops the token without passing it on.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `IDLE_TO` | 300 | >= 1 | consecutive idle (1) bus clocks before a claim |
| `CLAIM_WIN` | 150 | >= 1 | claim response window in clocks |
| `HOLD_WIN` | 400 | 1 to 2^24 - 1 | reset value of the hold window; it also sets the width HW of the programmable window (wdata[8 +: HW]) |
| `MAX_FR` | 4 | >= 1 | maximum data frames per token hold |

## 5. Errors and corner cases

- **Overrun claim window:** if the claim window ends in the same clock as an `rx_done` for a higher-address claim, neither branch fires. The CW-bit counter then wraps, and the claim completes about 2^CW clocks later.
- **Late frames still start:** once the hold window is over, the station passes the token. It does not pass early if the FIFO empties, so a data frame started at the end of the window still runs to completion.
- **Hold window 0:** a programmed hold window of 0 passes the token at once, without sending data.
- **Solicit frames:** solicit frames (FC = 3) are received and checked but cause no action.
- **Own-frame errors:** bad frames whose SA = `my_addr` still pulse `irq`.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "idle tx_bit is 1" | `tx_bit` = 1 whenever `tx_en` = 0 | §3.2 |
| "whole bytes" | frames are whole bytes | §3.2 |
| "preamble and SD" | frames start 55 55 D5 | §3.2 |
| "length and ED" | byte count = 10 + LEN and the last byte is D4 | §3.2 |
| "SA is my_addr" | SA = `my_addr` | §3.2 |
| "frame CRC" | CRC16 over FC..payload | §3.2 |
| "rx word available" | a delivered frame fills the RX FIFO | §3.4 |
| "rx word data" | payload packed big-endian, last word zero-padded | §3.4 |
| "reset outputs" | reset values | §3.8 |
| "token acquired irq" | an `irq` pulse when the token is taken | §3.5 |
| "fifo_count 3" | TX FIFO count after pushes | §2.1 |
| "fifo drained" | each data frame pops one word | §3.5 |
| "fifo full" | 8 words fill the TX FIFO | §2.1 |
| "tx overflow irq" | a push to a full TX FIFO is dropped with `irq` | §2.1 |
| "4 left" | at most `MAX_FR` data frames per hold | §3.5 |
| "fifo 5 after push+pop" | push and pop in the same clock | §2.1 |
| "fifo empty" | TX FIFO empty | §2.1 |
| "rx empty" | RX FIFO empty | §3.4 |
| "bad CRC irq" | a CRC error pulses `irq` | §3.3 |
| "bad ED irq" | a bad ED pulses `irq` | §3.3 |
| "bad CRC+ED irq" | both errors pulse `irq` | §3.3 |
| "overlong irq" | LEN > 16 pulses `irq` | §3.3 |
| "overlong irq 2" | LEN = 255 pulses `irq` | §3.3 |
| "only the good frame delivered" | bad frames are not delivered | §3.4 |
| "no token taken" | tokens for others, solicit frames and the station's own token echo are ignored | §3.5 |
| "rx fifo full" | RX FIFO holds 8 words | §3.4 |
| "rx overflow irq" | a word that does not fit is dropped with `irq` | §3.4 |
| "rx full again" | pops free room for later frames | §3.4 |
| "backed off" | a claim from a lower address makes the station return to LISTEN | §3.6 |
| "traffic ends claim" | any other good frame ends the claim | §3.6 |
| "no claim when disabled" | claim_en = 0: no claim frames | §3.6 |
| "holding" | the station holds the token | §3.5 |
| "reset drops token" | `rst_n` clears `token_held` | §3.8 |
| a_reset_outputs | in reset: `tx_en` = 0, `tx_bit` = 1, `irq` = 0, `token_held` = 0, counts 0 | §3.8 |
| a_tx_en | `tx_en` equals the checker's model | §3.2, §3.5 |
| a_tx_bit | `tx_bit` equals the checker's model | §3.2, §3.5 |
| a_fifo_count | `fifo_count` equals the model | §2.1 |
| a_rx_count | `rx_count` equals the model | §3.4 |
| a_cpu_rdata | when `rx_count` != 0, `cpu_rdata` is the oldest RX word | §3.4 |
| a_token_held | `token_held` equals the model's HOLD or PASS | §3.5 |
| a_irq | `irq` = bad frame \| TX overflow \| RX overflow \| token acquired | §3.7 |
