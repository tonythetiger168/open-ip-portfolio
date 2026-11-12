# eCPRI_over_Ethernet: design specification

The node side of an eCPRI message layer carried directly in Ethernet frames (Ethertype 0xAEFE). Frames arrive and leave as byte streams; the external MAC adds the preamble, SFD and IFG. The core handles four message types:
- **IQ data (type 0):** payload goes into a 32-word buffer that the CPU pops.
- **Generic memory transfer (type 4):** reads and writes a 64-word memory.
- **Remote reset (type 5):** drives `reset_op`.
- **Event indication (type 6):** acknowledges faults and sync requests.

It answers with its own frames, and the CPU can inject fault indications. Every frame is a minimum-size 64-byte Ethernet frame.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset value |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one byte per clock on both streams | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rx_d` | input | 8 | received frame byte (DMAC first, FCS last; no preamble/SFD) | - | `clk` | - |
| `rx_dv` | input | 1 | `rx_d` valid; one contiguous high run is one frame | high | `clk` | - |
| `tx_d` | output | 8 | transmitted frame byte (valid while `tx_en`) | - | `clk` | 0 |
| `tx_en` | output | 1 | transmit frame in progress (64 clocks per frame, low for at least one clock between frames) | high | `clk` | 0 |
| `reset_op` | output | 16 | reset_id of the last accepted remote-reset request; cleared by CPU | - | `clk` | 0 |
| `cpu_we` | input | 1 | CPU write strobe | high | `clk` | - |
| `cpu_re` | input | 1 | CPU read strobe; pops the IQ buffer at address 4 | high | `clk` | - |
| `cpu_addr` | input | 4 | CPU register address (§2.1) | - | `clk` | - |
| `cpu_wdata` | input | 32 | CPU write data | - | `clk` | - |
| `cpu_rdata` | output | 32 | CPU read data, combinational | - | comb. | see §2.1 |
| `irq` | output | 1 | OR of five sticky error bits (write-1-to-clear at address 8) | high | `clk` | 0 |

The checker uses ports only.

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/eCPRI_over_Ethernet.md`](../ip/eCPRI_over_Ethernet.md) (source: `scripts/apb/specs/eCPRI_over_Ethernet.json`); do not edit by hand.

`eCPRI_over_Ethernet_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_d`, `rx_dv`, `tx_d`, `tx_en`, `reset_op`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x65430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | DMAC_LO | RW (core) | core | peer MAC [31:0] (DMAC of transmitted frames); reset 0xCCDDEEFF |
| 0x018 | DMAC_HI | RW (core) | core | [15:0] peer MAC [47:32]; reset 0xAABB |
| 0x01C | SMAC_LO | RW (core) | core | own MAC [31:0] (SMAC of transmitted frames, RX address filter); reset 0x33445566 |
| 0x020 | SMAC_HI | RW (core) | core | [15:0] own MAC [47:32]; reset 0x1122 |
| 0x024 | IQ | RO (core) | core | IQ buffer head (32 x 32-bit, big-endian packed IQ bytes); the read pops it |
| 0x028 | COUNTS | RO (core) | core | {rx error count[7:0], rx ok count[7:0], seq_id gap count[7:0], 2'b0, IQ words[5:0]} |
| 0x02C | IQ_LAST | RO (core) | core | {pc_id[15:0], seq_id[15:0]} of the last IQ message |
| 0x030 | EVENT | RW (core) | core | write: inject a fault indication {raise[20], fault number[19:8], event_id[7:0]}; read: last recorded event {8'h0, seq[7:0], 5'h0, type[2:0], event_id[7:0]} |
| 0x034 | ERRORS | RW (core) | core | {concat, overflow, malformed, msgtype, fcs} error flags (sticky, write 1 to clear; a new error in the same clock wins) |
| 0x038 | RESET_OP | RW (core) | core | [15:0] reset_id of the last remote reset request (also the reset_op pin); write bit 0 = 1 to clear |
| 0x03C | RX_SMAC_LO | RO (core) | core | source MAC [31:0] of the last accepted message |
| 0x040 | RX_SMAC_HI | RO (core) | core | [15:0] source MAC [47:32] of the last accepted message |
| 0x044 | TX_STATUS | RO (core) | core | {14'h0, ack_wait, injection pending, tx seq[7:0], 5'h0, TX queue count[2:0]} |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x048 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6543 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| DMAC_LO | 31:0 | core register | RW (core) | core | written at core register 0 and read from core register 0 |
| DMAC_HI | 31:0 | core register | RW (core) | core | written at core register 1 and read from core register 1 |
| SMAC_LO | 31:0 | core register | RW (core) | core | written at core register 2 and read from core register 2 |
| SMAC_HI | 31:0 | core register | RW (core) | core | written at core register 3 and read from core register 3 |
| IQ | 31:0 | core register | RO (core) | core | read from core register 4 |
| COUNTS | 31:0 | core register | RO (core) | core | read from core register 5 |
| IQ_LAST | 31:0 | core register | RO (core) | core | read from core register 6 |
| EVENT | 31:0 | core register | RW (core) | core | written at core register 7 and read from core register 7 |
| ERRORS | 31:0 | core register | RW (core) | core | written at core register 8 and read from core register 8 |
| RESET_OP | 31:0 | core register | RW (core) | core | written at core register 9 and read from core register 9 |
| RX_SMAC_LO | 31:0 | core register | RO (core) | core | read from core register 10 |
| RX_SMAC_HI | 31:0 | core register | RO (core) | core | read from core register 11 |
| TX_STATUS | 31:0 | core register | RO (core) | core | read from core register 12 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | any ERRORS flag is set (FCS, msgtype, malformed message, IQ buffer / TX queue overflow, concatenation); held until ERRORS is cleared, so the bit is set again on every clock until then |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `cpu_we` for one clock with `cpu_addr` (the core register) and `cpu_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `cpu_addr` (the core register) and pulses `cpu_re` during the access phase and returns `cpu_rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x65430200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

### 2.1 Core CPU map

Writes take effect at the clock edge. Reads are combinational.

| Addr | Write | Read | Reset |
|---|---|---|---|
| 0 | peer DMAC[31:0] (destination of sent frames) | same | DMAC = AA:BB:CC:DD:EE:FF |
| 1 | peer DMAC[47:32] = wdata[15:0] | `{16'h0, DMAC[47:32]}` | |
| 2 | own MAC[31:0] (SMAC of sent frames and the receive filter) | same | own MAC = 11:22:33:44:55:66 |
| 3 | own MAC[47:32] = wdata[15:0] | `{16'h0, MAC[47:32]}` | |
| 4 | - | IQ buffer head word; `cpu_re` pops it if the buffer is not empty. When empty it returns the stale entry at the read pointer. | empty |
| 5 | - | `{rx_err_cnt[7:0], rx_ok_cnt[7:0], seq_gap_cnt[7:0], 2'b00, iq_cnt[5:0]}` | 0 |
| 6 | - | `{last_pc_id[15:0], last_seq_id[15:0]}` (IQ) | 0 |
| 7 | fault injection: wdata[7:0] event id, wdata[19:8] fault number, wdata[20] cease | `{8'h0, last_event_seq, 5'h0, last_event_type[2:0], last_event_id}` | 0 |
| 8 | write 1 to clear irq bits | `{27'h0, concat, ovf, malf, type, fcs}` | 0 |
| 9 | wdata[0] = 1 clears `reset_op` | `{16'h0, reset_op}` | 0 |
| 10 | - | source MAC of the last accepted message, [31:0] | 0 |
| 11 | - | `{16'h0, src MAC[47:32]}` | 0 |
| 12 | - | `{14'h0, ack_wait, inj_pend, tx_seq[7:0], 5'h0, tq_cnt[2:0]}` | 0 |
| 13-15 | - | 0 | |

The MAC registers hold the first byte on the wire in bits 47:40.

### 2.1 Core CPU map

Writes take effect at the clock edge. Reads are combinational.

| Addr | Write | Read | Reset |
|---|---|---|---|
| 0 | peer DMAC[31:0] (destination of sent frames) | same | DMAC = AA:BB:CC:DD:EE:FF |
| 1 | peer DMAC[47:32] = wdata[15:0] | `{16'h0, DMAC[47:32]}` | |
| 2 | own MAC[31:0] (SMAC of sent frames and the receive filter) | same | own MAC = 11:22:33:44:55:66 |
| 3 | own MAC[47:32] = wdata[15:0] | `{16'h0, MAC[47:32]}` | |
| 4 | - | IQ buffer head word; `cpu_re` pops it if the buffer is not empty. When empty it returns the stale entry at the read pointer. | empty |
| 5 | - | `{rx_err_cnt[7:0], rx_ok_cnt[7:0], seq_gap_cnt[7:0], 2'b00, iq_cnt[5:0]}` | 0 |
| 6 | - | `{last_pc_id[15:0], last_seq_id[15:0]}` (IQ) | 0 |
| 7 | fault injection: wdata[7:0] event id, wdata[19:8] fault number, wdata[20] cease | `{8'h0, last_event_seq, 5'h0, last_event_type[2:0], last_event_id}` | 0 |
| 8 | write 1 to clear irq bits | `{27'h0, concat, ovf, malf, type, fcs}` | 0 |
| 9 | wdata[0] = 1 clears `reset_op` | `{16'h0, reset_op}` | 0 |
| 10 | - | source MAC of the last accepted message, [31:0] | 0 |
| 11 | - | `{16'h0, src MAC[47:32]}` | 0 |
| 12 | - | `{14'h0, ack_wait, inj_pend, tx_seq[7:0], 5'h0, tq_cnt[2:0]}` | 0 |
| 13-15 | - | 0 | |

The MAC registers hold the first byte on the wire in bits 47:40.

## 3. Timing

### 3.1 Byte streams

A receive frame is one contiguous run of `rx_dv` = 1, one byte per clock. It ends on the clock where `rx_dv` falls, and is checked and dispatched at that clock edge.

### 3.2 Frame layout (both directions)

| Bytes | Field |
|---|---|
| 0-5 | DMAC |
| 6-11 | SMAC |
| 12-13 | Ethertype 8'hAE, 8'hFE |
| 14 | eCPRI byte 0: `{rev[3:0], rsvd[2:0], c}`; sent as 8'h10 (rev 1, c 0) |
| 15 | message type |
| 16-17 | payload_size, big-endian |
| 18.. | payload (at most 40 bytes), then zero padding up to byte 59 |
| 60-63 | FCS, LSB byte first |

The FCS is CRC-32/ISO-HDLC: reflected poly 0xEDB88320, init and xorout 8'hFFFFFFFF, over bytes 0-59. On receive, the CRC over all 64 bytes must leave the residue 0xDEBB20E3.

On transmit, `tx_en` and the first DMAC byte appear the clock after a descriptor is popped. A frame is exactly 64 clocks long. `tx_en` then goes low for at least one clock before the next frame.

### 3.3 Receive filter and checks

A frame is the node's only if both hold:
- its DMAC equals the own MAC (registers 2/3) or FF:FF:FF:FF:FF:FF;
- its Ethertype is 0xAEFE.

Any other frame, including a runt that ends before byte 14, is ignored silently: no irq, no counters.

For the node's frames, the first failing check below sets one irq bit and the frame is discarded:

| Order | Check | irq bit |
|---|---|---|
| 1 | FCS residue wrong | fcs (0) |
| 2 | frame length != 64 bytes, payload_size > 40, or rev != 1 (rsvd bits are ignored) | malf (2) |
| 3 | c = 1 (concatenated messages are unsupported) | concat (4) |
| 4 | message type not 0, 4, 5 or 6 | type (1) |
| 5 | payload shape wrong for the type (table below) | malf (2) |

Payload shapes accepted per type:

| Type | Accepted payload |
|---|---|
| 0 IQ | payload_size 4-36, a multiple of 4: pc_id[16], seq_id[16], then up to 32 IQ bytes |
| 4 memory | rw = 0 (read) with payload_size 5, or rw = 1 (write) with payload_size 9; remote_addr (32-bit, big-endian) < 256 and word aligned |
| 5 reset | payload_size >= 3 and op byte (payload[2]) = 1; extra vendor bytes are allowed |
| 6 event | n_elem (payload[3]) <= 4, type (payload[1]) <= 5, payload_size = 4 + 8 * n_elem |

Every one of the node's frames counts in `rx_ok_cnt` (accepted) or `rx_err_cnt` (discarded); both counters wrap. An accepted message stores its SMAC in registers 10/11.

### 3.4 IQ data (type 0)

The IQ bytes are packed big-endian, four per word, into the 32-word IQ buffer at the frame-end edge. If fewer free words remain than the message carries (counting a CPU pop in the same clock), only the words that fit are stored and the ovf bit is set.

Sequence tracking:
- If a previous IQ message exists, has the same pc_id, and the new seq_id != previous + 1, `seq_gap_cnt` increments.
- A change of pc_id is not a gap.
- `last_pc_id` and `last_seq_id` always update.

### 3.5 Memory and remote reset (types 4, 5)

**Memory write:** stores the 4 data bytes, big-endian, to word remote_addr / 4.

**Memory read:** queues a read response. Its data is the memory word at the moment the request is accepted.

**Remote reset request:**
- Sets `reset_op` = reset_id at the frame-end edge.
- Queues a reset response.
- A CPU clear (address 9) in the same clock loses to the new request.
- A malformed request does not touch `reset_op`.

### 3.6 Transmit messages

Responses and injections go through a 4-entry descriptor queue that the serializer drains in order. The node sends four kinds of frame:

| Kind | Type | payload_size | Payload bytes |
|---|---|---|---|
| read response | 4 | 9 | 00 00 00 `{word addr, 2'b00}`, 8'h02, data[31:24] .. data[7:0] |
| reset response | 5 | 3 | reset_id hi, reset_id lo, 8'h02 |
| event ack | 6 | 4 | event id, 1 (fault ack) or 4 (sync ack), the received seq, 0 |
| fault indication | 6 | 12 | event id, 0, `tx_seq`, 1, FF, FF, `{3'b000, cease, fault[11:8]}`, fault[7:0], 00 00 00 00 |

Which received events produce what:
- An event of type 0 (fault) is answered with type 1; type 3 (sync request) is answered with type 4.
- Types 1, 2, 4 and 5 are only recorded in register 7.
- A type 1 whose event id and seq match the last sent fault indication clears `ack_wait`.

Fault injection (CPU write to address 7):
- The injection waits in one pending slot (`inj_pend`) and enters the queue only in a clock with no receive push.
- When a fault indication starts transmission it takes `tx_seq`, `tx_seq` increments (mod 256), and `ack_wait` is set.
- A second injection while one is still pending, and not entering the queue that clock, is dropped and sets ovf.

A receive response that meets a full queue is lost and sets ovf.

### 3.7 irq

There are five sticky bits: fcs, type, malf, ovf, concat. Each stays set until the CPU writes 1 to it at address 8. `irq` is their OR.

### 3.8 Reset

`rst_n` low resets the core:
- `tx_en` = 0, `tx_d` = 0, `irq` = 0, `reset_op` = 0;
- the queues and counters are cleared and the memory is zeroed;
- the MAC registers return to their reset values.

The IQ buffer contents are not reset; its pointers are.

## 4. Parameters

None.

## 5. Errors and corner cases

- **One irq bit per frame:** a frame with several faults sets only the first bit in the check order.
- **Fixed frame size:** any frame that is not exactly 64 bytes is malformed, even if its payload would fit.
- **Truncated IQ data:** an IQ overflow stores a partial message. The CPU cannot tell which words were lost.
- **Stale read data:** read responses carry the memory value at the time of the request, not at the time of transmission.
- **Memory not CPU-visible:** the 64-word memory is only reachable through eCPRI messages.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "tx frame length" | every transmitted frame is 64 bytes | §3.2 |
| "tx frame FCS" | the transmitted FCS is CRC-32 of bytes 0-59, LSB byte first | §3.2 |
| "outputs after reset" | reset values | §3.8 |
| "iq word" | IQ bytes are packed big-endian, 4 per word, in order | §3.4 |
| "reset_op" | a remote-reset request drives `reset_op` = reset_id | §3.5 |
| "reset_op vendor" | vendor bytes after op do not matter | §3.5 |
| "reset_op clear collision" | a request in the same clock as the CPU clear wins | §3.5 |
| "reset_op after malformed" | malformed reset messages do not change `reset_op` | §3.3 |
| "broadcast frame" | broadcast DMAC frames are accepted | §3.3 |
| "filtered frames acted on" | other DMACs, other ethertypes and runts are silently ignored | §3.3 |
| "irq after clear" | `irq` falls after all five bits are cleared | §3.7 |
| "IQ pattern word" | IQ data patterns pass unchanged | §3.4 |
| a_reset_outputs | in reset: `tx_en` = 0, `irq` = 0, `reset_op` = 0 | §3.8 |
| a_tx_en | `tx_en` equals the checker's model | §3.2 |
| a_tx_d | while `tx_en`, `tx_d` equals the modelled frame byte | §3.2, §3.6 |
| a_irq | `irq` = OR of the modelled sticky bits | §3.7 |
| a_reset_op | `reset_op` equals the model | §3.5 |
| a_cpu_rdata | `cpu_rdata` equals the model, except address 4 with an empty IQ buffer | §2.1 |
