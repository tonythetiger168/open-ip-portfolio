<!-- SPDX-License-Identifier: Apache-2.0 -->
# CPRI_v8_0__eCPRI_over_CPR_: design specification

A CPRI master (REC) link-layer slice as an educational model: full 8b/10b encode / decode with
running disparity on both directions, one byte-wide word per symbol, a simplified hyperframe of 64
basic frames x 16 words, the HUNT / ALIGN / SYNC state machine with loss-of-sync detection, an L1
inband slow stream for protocol-version and rate negotiation, a vendor byte, and a 32-word buffer
of received IQ data. Not implemented: the real 256-frame hyperframe and 150-hyperframe radio
frame, line rates / word widths above one byte, C&M channels (HDLC / Ethernet), eCPRI messages,
a real downlink IQ source (a fixed pattern is sent). Core `CPRI_v8_0__eCPRI_over_CPR__top`, testbench
`tb/CPRI_v8_0__eCPRI_over_CPR__tb.sv`, checker `tb/cov/CPRI_v8_0__eCPRI_over_CPR__sva.sv` (a
pin-level cycle model).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. "Position" counts symbols in a hyperframe, 0..1023 = basic frame
* 16 + word.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one line symbol per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rx_sym` | input | 10 | received 8b/10b symbol {a,b,c,d,e,i,f,g,h,j}, a = bit 9 (sent first) | - | `clk` | - |
| `tx_sym` | output | 10 | transmitted 8b/10b symbol, same bit order | - | `clk` | D0.0 at RD- (0x274) |
| `cpu_we` | input | 1 | register write strobe | high | `clk` | - |
| `cpu_re` | input | 1 | register read strobe (only address 10 has a side effect: pop) | high | `clk` | - |
| `cpu_addr` | input | 4 | register address (section 3.5) | - | `clk` | - |
| `cpu_wdata` | input | 32 | write data; only bits 7:0 are used | - | `clk` | - |
| `cpu_rdata` | output | 32 | read data, combinational from `cpu_addr` | - | comb | - |
| `irq` | output | 1 | level: loss-of-sync flag OR code-violation flag | high | `clk` | 0 |

### Internal signals used by the verification

fsm_cov binds the sync state; keep its name and encoding.

| Signal | Width | Meaning |
|---|---|---|
| `sync_st` | 2 | 0 HUNT, 1 ALIGN, 2 SYNC (also STATUS bits 1:0) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/CPRI_v8_0__eCPRI_over_CPR_.md`](../ip/CPRI_v8_0__eCPRI_over_CPR_.md) (source: `scripts/apb/specs/CPRI_v8_0__eCPRI_over_CPR_.json`); do not edit by hand.

`CPRI_v8_0__eCPRI_over_CPR__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_sym`, `tx_sym`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG0 | RW (core) | core | {pointer p[7:4], line rate[3:0]} sent in the L1 inband stream; the rate is negotiated against the peer's (reset 0x2A) |
| 0x018 | CFG1 | RW (core) | core | bits [3:0]: local protocol version, sent in the L1 inband stream and negotiated (reset 0x04) |
| 0x01C | CFG2 | RW (core) | core | vendor byte, sent in control word #4 of each hyperframe (reset 0xC9) |
| 0x020 | CFG3 | RW (core) | core | spare configuration byte, no effect on the link (reset 0) |
| 0x024 | CFG4 | RW (core) | core | spare configuration byte, no effect on the link (reset 0) |
| 0x028 | CFG5 | RW (core) | core | spare configuration byte, no effect on the link (reset 0) |
| 0x02C | CFG6 | RW (core) | core | spare configuration byte, no effect on the link (reset 0) |
| 0x030 | CFG7 | RW (core) | core | spare configuration byte, no effect on the link (reset 0) |
| 0x034 | LINK | RO (core) | core | [1:0] sync state (0 HUNT, 1 ALIGN, 2 SYNC), [2] L1 inband negotiation received, [4:3] hyperframes missed in a row, [11:6] IQ words buffered, [15:12] peer protocol version, [23:16] IQ words dropped with the buffer full (saturates at 255) |
| 0x038 | NEG | RO (core) | core | [3:0] negotiated protocol version, [7:4] negotiated line rate (the smaller of ours and the peer's) |
| 0x03C | IQ | RO (core) | core | oldest buffered IQ word {I[15:0], Q[15:0]}; reading it pops the word when one is buffered |
| 0x040 | IQ_COUNT | RO (core) | core | IQ words buffered (0..32) |
| 0x044 | VENDOR | RO (core) | core | vendor byte received from the peer |
| 0x048 | EVENTS | RW (core) | core | [0] loss of sync, [1] code violation; sticky, write 1 to clear (a violation in the same clock wins) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x04C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4350 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG0 | 31:0 | core register | RW (core) | core | written at core register 0 and read from core register 0 |
| CFG1 | 31:0 | core register | RW (core) | core | written at core register 1 and read from core register 1 |
| CFG2 | 31:0 | core register | RW (core) | core | written at core register 2 and read from core register 2 |
| CFG3 | 31:0 | core register | RW (core) | core | written at core register 3 and read from core register 3 |
| CFG4 | 31:0 | core register | RW (core) | core | written at core register 4 and read from core register 4 |
| CFG5 | 31:0 | core register | RW (core) | core | written at core register 5 and read from core register 5 |
| CFG6 | 31:0 | core register | RW (core) | core | written at core register 6 and read from core register 6 |
| CFG7 | 31:0 | core register | RW (core) | core | written at core register 7 and read from core register 7 |
| LINK | 31:0 | core register | RO (core) | core | read from core register 8 |
| NEG | 31:0 | core register | RO (core) | core | read from core register 9 |
| IQ | 31:0 | core register | RO (core) | core | read from core register 10 |
| IQ_COUNT | 31:0 | core register | RO (core) | core | read from core register 11 |
| VENDOR | 31:0 | core register | RO (core) | core | read from core register 12 |
| EVENTS | 31:0 | core register | RW (core) | core | written at core register 13 and read from core register 13 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | LINK_EVENT | EVENTS has a bit set (loss of sync or a code violation); set on every clock until EVENTS is cleared, so clear EVENTS first |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `cpu_we` for one clock with `cpu_addr` (the core register) and `cpu_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `cpu_addr` (the core register) and pulses `cpu_re` during the access phase and returns `cpu_rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43500200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Transmit hyperframe

The master is the timing source: from reset it sends hyperframes back to back, one symbol per
clock, position 0 in the first clock after reset. Byte at each position (basic frame f, word w):

| Position | Byte |
|---|---|
| f 0, w 0 | K28.5 |
| f 0, w 1..2 | 0x50 |
| f 1, w 0 | L1 slow-stream byte for this hyperframe (below) |
| f 4, w 0 | config register 2 (vendor byte) |
| other w 0 | 0x00 |
| other | {f[3:0], w} (IQ placeholder pattern) |

L1 slow stream, by hyperframe number mod 16: 0 = 0x5A (start mark), 1 = {4'h0, cfg1[3:0]}
(protocol version), 2 = cfg0 ({pointer p, rate}), 15 = cfg0 ^ {4'h0, cfg1[3:0]} ^ 0xA5 (check),
others 0x00. Config changes take effect at the next symbol that uses them.

Every byte is 8b/10b encoded (standard tables, D.x.A7 alternate where required) with running
disparity starting at RD-; `tx_sym` is registered, so it shows the encoding of position n one
clock after the counters reach n.

### 3.2 Receive synchronisation

Received symbols are decoded combinationally; a symbol is valid when it is a code group with the
right disparity for the receive running disparity (which starts at RD- and is updated by every
symbol, valid or not). The receive hyperframe position runs from the peer's commas,
independent of the transmit side.

- HUNT: a valid K28.5 enters ALIGN; that symbol is position 0.
- ALIGN: a valid K28.5 at position 0 (1024 symbols after the last one) counts; the second such
  comma enters SYNC. A K28.5 elsewhere becomes the new position 0 (count restarts). No comma at
  position 0: HUNT.
- SYNC: at position 0 a valid K28.5 clears the miss count; otherwise the miss count increments,
  and the 4th miss in a row goes to HUNT and sets the LOS flag (also clearing L1 done). Commas
  elsewhere are ignored.

So SYNC is entered at the third comma of three spaced 1024 symbols apart.

### 3.3 L1 slow stream, vendor byte (SYNC only)

At position 16 (basic frame 1, word 0), a valid data byte: 0x5A (re)starts the sequence; with a
sequence running, the next byte is the peer version, the one after the peer rate, and the 15th
byte after the start mark is the check. If check = version ^ rate ^ 0xA5 (8 bits), L1 done is set
and peer version / rate take bits 3:0 of those bytes; otherwise they keep their old values. K
symbols or invalid symbols at position 16 do not advance the sequence. Register 9 is the
negotiated pair min(cfg0[3:0], peer rate), min(cfg1[3:0], peer version).

At position 64 (basic frame 4, word 0) a valid data byte is stored as the peer vendor byte.

### 3.4 IQ buffer (SYNC only)

IQ positions are every word other than w 0, except positions 1 and 2. Valid data bytes at IQ
positions are packed four at a time (counter cleared on entering SYNC and on loss of sync) into
{b0, b1, b2, b3} = {I[15:0], Q[15:0]}; K or invalid symbols are skipped. A complete word is
written to the 32-entry buffer if it holds fewer than 32 words or a pop happens in the same clock;
otherwise it is dropped and the overflow count increments (saturating at 255, no `irq`). A read of
address 10 with `cpu_re` and a non-empty buffer pops the head (the read data is the head before
the pop).

### 3.5 Registers

| Addr | Access | Content |
|---|---|---|
| 0..7 | RW, 8 bits | config: 0 = {pointer p, rate} (reset 0x2A), 1 = protocol version (0x04), 2 = vendor (0xC9), 3..7 spare (0) |
| 8 | RO | {8'h0, overflow count, peer version, IQ count[5:0], 1'b0, miss count[1:0], L1 done, sync state[1:0]} |
| 9 | RO | {24'h0, negotiated rate, negotiated version} |
| 10 | RO, pop | IQ buffer head |
| 11 | RO | IQ count |
| 12 | RO | peer vendor byte |
| 13 | W1C | {30'h0, CV flag, LOS flag}; write bit 0 clears LOS, bit 1 clears CV |
| 14, 15 | - | read 0, writes ignored |

### 3.6 Interrupt

`irq` = LOS flag OR CV flag. The CV flag is set by any invalid received symbol (in every sync
state); the LOS flag by loss of sync. A flag set in the same clock as its clear stays set.

### 3.7 Reset

HUNT, flags 0, IQ buffer empty, counters 0, peer values 0, config defaults as in 3.5, transmit at
position 0 with RD-.

## 4. Parameters

None.

## 5. Errors and corner cases

- A received symbol at the wrong disparity is a code violation even if it is a code group; the
  receive disparity still follows it.
- In SYNC a K28.5 away from position 0 is not an error and does not realign.
- Overflow does not raise `irq`.
- L1 negotiation only compares 4-bit fields; the upper bits of version / rate bytes are covered by
  the check byte only.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "TX symbol" | every transmitted symbol equals the expected hyperframe content and disparity | §3.1, §3.2 |
| "IQ word" | IQ words read back in order, packed {b0,b1,b2,b3} | §3.4 |
| "reset irq" | `irq` = 0 after reset | §3.7 |
| "cfg write ones" | config registers hold 8 written bits | §3.5 |
| "cfg write zeros" | ...and zeros | §3.5 |
| "unmapped read" | addresses 14, 15 read 0 | §3.5 |
| "unmapped read 15" | as above | §3.5 |
| "IQ buffer empty" | count 0 after reset | §3.4 |
| "pop on empty" | a pop of an empty buffer does nothing | §3.4 |
| "IQ buffer full" | the buffer holds 32 words | §3.4 |
| "overflow counted" | words arriving while full are dropped and counted | §3.4 |
| "buffer still full after pop + push" | a pop and a push in the same clock keep the count | §3.4 |
| "L1 done, peer version" | a complete L1 sequence with a good check byte sets L1 done and the peer version | §3.3 |
| "negotiated rate / version" | register 9 = min of local and peer | §3.3 |
| "local lower" | ...also when the local value is lower | §3.3 |
| "peer vendor byte" | register 12 = byte in the control word of basic frame 4 | §3.3 |
| "peer version F" | 4-bit fields up to F | §3.3 |
| "negotiated F / F" | as above | §3.3 |
| "peer vendor A3" | vendor byte updates every hyperframe | §3.3 |
| "bad check byte ignored" | a wrong check byte leaves the peer values | §3.3 |
| "check byte bit 7 wrong: ignored" | all 8 check bits compared | §3.3 |
| "restarted sequence not complete" | 0x5A mid-sequence restarts it | §3.3 |
| "peer version 0" | the restarted sequence completes 15 hyperframes later | §3.3 |
| "no irq yet" | no `irq` on a clean link | §3.6 |
| "code violation irq" | a symbol that is not a code group sets the CV flag | §3.6 |
| "cv flag" | register 13 bit 1 | §3.6 |
| "clearing los leaves cv" | write-1-to-clear per bit | §3.6 |
| "cv cleared" | as above | §3.6 |
| "disparity error irq" | a code group at the wrong running disparity sets CV | §3.6 |
| "cv cleared after a disparity error" | the receive disparity recovers | §3.6 |
| "violation set wins over clear" | a violation in the clearing clock keeps the flag | §3.6 |
| "cleared" | clear works afterwards | §3.6 |
| "no loss of sync" | 3 missed commas in a row are tolerated | §3.2 |
| "loss of sync irq" | the 4th missed comma: HUNT and the LOS flag | §3.2 |
| "los flag" | register 13 bit 0 | §3.6 |
| "los cleared" | as above | §3.6 |
| "reset clears irq" | reset values | §3.7 |
| "buffer empty after reset" | reset values | §3.7 |
| a_reset_state | reset values | §3.7 |
| a_tx_sym | `tx_sym` equals the checker's model | §3.1 |
| a_irq | `irq` equals the model | §3.6 |
| a_cpu_rdata | `cpu_rdata` equals the model | §3.5 |
| a_tx_symbol_is_code_group | every `tx_sym` is a valid code group | §3.1 |
| a_los_irq | loss of sync raises `irq` | §3.2 |
