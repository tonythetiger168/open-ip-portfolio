<!-- SPDX-License-Identifier: Apache-2.0 -->
# UniPro_Mem: design specification

A MIPI UniPro-style data-link endpoint, as an educational slice, with a memory-mapped transaction
service: escaped symbol framing, L2 frames with CRC-16, a 64 x 32 memory on CPort 1, PACP-style
attribute get / set (16 x 8) on CPort 0xF, two traffic classes with strict priority, a read
response timeout, and NAC-driven retransmission. Not implemented: the real UniPro L1.5 / L2 (AFC,
credits, replay timers, sequence number checking on receive), the network and transport layers.
Core `UniPro_Mem_top` (`rtl/UniPro_Mem_top.sv`), testbench `tb/UniPro_Mem_tb.sv`, checker
`tb/cov/UniPro_Mem_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. ESC = 0x9D, COF = 0xC0.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rx_sym` | input | 8 | received symbol (peer to this endpoint) | - | `clk` | - |
| `rx_valid` | input | 1 | `rx_sym` is valid this clock | high | `clk` | - |
| `tx_sym` | output | 8 | transmitted symbol; held until taken | - | `clk` | 0x00 |
| `tx_valid` | output | 1 | `tx_sym` is valid | high | `clk` | 0 |
| `tx_ready` | input | 1 | the peer takes `tx_sym` this clock | high | `clk` | - |
| `irq` | output | 1 | one-clock error pulse (section 5) | high | `clk` | 0 |

### Internal signals used by the verification

The bound checker (`.*`) connects these state, counter and storage names (its inline assertions
A2..A7 and the storage comparison use them); fsm_cov binds `rxs` and `txs`. Keep the names and
meanings.

| Signal | Width | Meaning |
|---|---|---|
| `rxs` | 2 | receiver: 0 IDLE, 1 ESC seen, 2 in a frame, 3 discarding an oversized frame |
| `txs` | 1 | transmitter: 0 IDLE, 1 RUN |
| `q0_timer` | 7 | read-response timeout of the TC0 slot, 100 down to 1 |
| `q1_timer` | 7 | same for TC1 |
| `bcnt` | 5 | received bytes (unescaped) since COF |
| `t_cnt` | 5 | position in the frame being sent: 0 ESC, 1 COF, 2.. header / payload, then CRC hi, CRC lo |
| `rb_retry` | 2 | retransmissions of the last frame so far (0..3) |
| `t_esc` | 1 | an ESC is on the line and the escaped byte follows |
| `mem` | 32 x 64 | memory, unpacked `[0:63]`; reset to 0 |
| `attr` | 8 x 16 | attributes, unpacked `[0:15]`; reset to 0 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/UniPro_Mem.md`](../ip/UniPro_Mem.md) (source: `scripts/apb/specs/UniPro_Mem.json`); do not edit by hand.

`UniPro_Mem_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_sym`, `rx_valid`, `tx_sym`, `tx_valid`, `tx_ready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x554D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x554D | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | received CRC error, out-of-bounds or invalid-length memory request, NAC retransmit budget exhausted, or a response dropped because its traffic-class slot was still occupied |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x554D0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Frame format

On the line: ESC, COF, then the frame bytes, each escaped: a frame byte equal to ESC or COF is sent
as ESC, byte ^ 0x20. Frame bytes: header {3'b0, tc, cport[3:0]}, {4'b0, seq[3:0]}, len (0..16),
len payload bytes, CRC-16 high, low. CRC-16/CCITT-FALSE (0x1021, init 0xFFFF, MSB first) over the
header and payload.

### 3.2 Receive

The receiver handles one symbol per clock with `rx_valid`. ESC then COF starts a frame (ESC ESC
stays waiting for COF; ESC then another byte goes back to idle). Inside a frame ESC marks the next
symbol: COF restarts the frame (the partial frame is lost), anything else is un-escaped (^ 0x20).
A len above 16 discards the frame until the next ESC COF. The frame is complete at its last CRC
byte: a CRC mismatch pulses `irq` and nothing else happens; a good frame is dispatched in that
clock. The received sequence number is not checked.

### 3.3 Requests and responses

| CPort | Payload | Valid when | Response payload |
|---|---|---|---|
| 1 | 0x01 WRITE: {op, 0x00, byte address, length, data} | length 4, 8 or 12, address word aligned, address + length <= 256, frame len = length + 4 | {0x81, 0x00, address, length, 0x00} (WR_ACK) |
| 1 | 0x02 READ: {op, 0x00, byte address, length} | as above, frame len = 4 | {0x82, 0x00, address, length, data words} (RD_RSP), data read at dispatch |
| 0xF | 0x10 GET: {op, index} | index < 16 | {0x90, index, attr[index]} |
| 0xF | 0x11 SET: {op, index, value} | index < 16 | {0x91, index, value}; attr written |
| 0xF | 0x20 NAC: {op, seq} | - | none (section 3.5) |

Memory words are big-endian in the payload (first byte = bits 31:24). Errors:

- out of bounds (memory request failing the checks, attribute index >= 16): `irq` and an ERR frame
  {0xE0, 2};
- any other opcode, a too-short request, or another CPort: an ERR frame {0xE0, 3}, no `irq`.

A response frame carries the request's tc and cport, the transmit sequence counter (counting up
per queued response) and its payload length.

### 3.4 Transmit

There is one response slot per traffic class. A response is queued at dispatch when its slot is
free (or is being loaded into the transmitter that clock); otherwise it is dropped and `irq`
pulses. A queued RD_RSP that has not started 100 clocks after it was queued is replaced by an ERR
frame {0xE0, 1} (read timeout, no `irq`).

When the transmitter is idle it loads, in priority order: a pending retransmission, the TC1 slot,
the TC0 slot. A frame from a slot is also kept as the last frame for retransmission. Loading puts
ESC on `tx_sym` with `tx_valid`; each clock with `tx_ready` moves to the next symbol (COF, then the
escaped frame bytes). After the last CRC symbol is taken `tx_valid` drops and the transmitter is
idle for at least one clock.

### 3.5 NAC and retransmission

A good NAC frame on CPort 0xF whose seq equals the last frame's sequence number requests a
retransmission of that frame (same contents and sequence number) with top priority, up to 3 times;
the 4th such NAC pulses `irq` and forgets the frame. A NAC for another sequence number does
nothing.

### 3.6 Reset

`tx_valid` = 0, `tx_sym` = 0, `irq` = 0, both slots and the retransmission buffer empty, sequence
counter 0, `mem` and `attr` all 0, both state machines idle.

## 4. Parameters

None.

## 5. Errors and corner cases

`irq` is a one-clock pulse for: a CRC error; an out-of-bounds request; the 4th NAC of a frame; a
response dropped because its traffic-class slot is full. Unknown opcodes and CPorts are answered
with ERR but raise no `irq`; oversized frames and broken framing are dropped silently.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "CRV timeout waiting frame count" | responses keep coming in the random phase | §3.4 |
| "DUT frame" | every transmitted frame has correct framing, escaping and CRC | §3.1, §3.4 |
| "timeout waiting for frame count" | each request gets its response | §3.3 |
| "tx_valid not low after reset" | reset values | §3.6 |
| "irq not low after reset" | reset values | §3.6 |
| "frames emitted while tx_ready low" | no symbol advances without `tx_ready` | §3.4 |
| "QoS violated, TC1 did not overtake TC0" | a queued TC1 response goes before a queued TC0 one | §3.4 |
| "no irq on CRC error" | CRC error: `irq` | §5 |
| "response sent for bad-CRC frame" | no response to a bad frame | §3.2 |
| "no irq on out-of-bounds write" | out-of-bounds write: `irq` and ERR | §3.3 |
| "no irq on invalid length" | invalid length: `irq` and ERR | §3.3 |
| "retx" | a NAC retransmits the last frame with the same sequence number | §3.5 |
| "no irq on NAC retransmit exhausted" | the 4th NAC: `irq` | §3.5 |
| "unexpected frame after NAC exhausted" | no frame after the retransmissions are exhausted | §3.5 |
| "CRV irq on clean write" | no `irq` on a good write | §3.3 |
| "CRV irq on clean read" | no `irq` on a good read | §3.3 |
| "CRV irq on PACP" | no `irq` on a good PACP get / set | §3.3 |
| "CRV bad CRC: no irq" | CRC error: `irq` | §5 |
| "CRV bad CRC: response emitted" | no response | §3.2 |
| "CRV NAC unknown seq: irq" | a NAC for another sequence number: no `irq` | §3.5 |
| "CRV NAC unknown seq: response emitted" | ...and no frame | §3.5 |
| "CRV OOB write: no irq" | out of bounds: `irq` | §3.3 |
| "CRV OOB read: no irq" | out of bounds: `irq` | §3.3 |
| "CRV bad-op raised irq" | an unknown opcode / CPort gets ERR without `irq` | §3.3 |
| "CRV PACP OOB: no irq" | attribute index >= 16: `irq` | §3.3 |
| "CRV rx-edge frame produced a response" | oversized length, lone ESC and a mid-frame ESC COF produce nothing | §3.2 |
| "CRV rx-edge: irq" | ...and no `irq` | §3.2 |
| "CRV irq on read timeout" | a read response turned into a timeout error raises no `irq` | §3.4 |
| "irq before the slot overflowed" | no `irq` while the slot can take the response | §3.4 |
| "no irq when a response was dropped" | a response with its slot full is dropped with `irq` | §3.4 |
| "dropped response was sent" | the dropped response is never sent | §3.4 |
| "reset during TX" | a reset in a frame stops the transmitter | §3.6 |
| "A1 reset: outputs quiescent" | reset values | §3.6 |
| "A2 tx_valid mirrors txs" | `tx_valid` exactly while `txs` is RUN | §3.4 |
| "A3 irq is a pulse" | `irq` is never high two clocks in a row | §5 |
| "A4 timers within bound" | `q0_timer`, `q1_timer` <= 100 | §3.4 |
| "A5 counters within bounds" | `bcnt`, `t_cnt` within the frame length | §3.2, §3.4 |
| "A6 rb_retry within budget" | `rb_retry` <= 3 | §3.5 |
| "A7 esc phase carries ESC" | while `t_esc` the symbol on the line is ESC | §3.4 |
| a_reset_state | reset values | §3.6 |
| a_tx_valid | `tx_valid` as the checker's model | §3.4 |
| a_tx_sym | every transmitted symbol as the model | §3.1, §3.4 |
| a_irq | `irq` as the model | §5 |
| a_memory_and_attributes | `mem` and `attr` equal the model | §3.3 |
