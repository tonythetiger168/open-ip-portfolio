# UniPro: design specification

A teaching slice of the MIPI UniPro 1.x data link layer, with a serial byte line, framing, retransmission and a small CPU port. The core exchanges L2 frames with a peer:
- COF-delimited frames with ESC_DL escaping and a CRC16;
- ACK/NAC with one outstanding data frame and up to 3 resends;
- PACP-style GET/SET of a 16 x 8 attribute file;
- two transmit traffic classes (TC1 strictly before TC0);
- a 32-byte receive message buffer for CPort 0.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset value |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one line bit per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rx_bit` | input | 1 | serial receive line: start(0), 8 data bits LSB first, stop(1); idle 1 | - | `clk` | - |
| `tx_bit` | output | 1 | serial transmit line, same symbol format | - | `clk` | 1 |
| `cpu_we` | input | 1 | CPU write strobe (one clock = one write) | high | `clk` | - |
| `cpu_re` | input | 1 | CPU read strobe; needed only for the side effects of addresses 4 and 6 | high | `clk` | - |
| `cpu_addr` | input | 3 | CPU register address (§2.1) | - | `clk` | - |
| `cpu_wdata` | input | 32 | CPU write data | - | `clk` | - |
| `cpu_rdata` | output | 32 | CPU read data, combinational from `cpu_addr` | - | comb. | 0 (except address 5: status) |
| `irq` | output | 1 | one-clock error pulse (§3.8) | high | `clk` | 0 |

The checker uses ports only.

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/UniPro.md`](../ip/UniPro.md) (source: `scripts/apb/specs/UniPro.json`); do not edit by hand.

`UniPro_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_bit`, `tx_bit`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TC0 | WO (core) | core | push one 32-bit payload onto the TC0 transmit queue (8 entries; a push to a full queue is dropped with ERR) |
| 0x018 | TC1 | WO (core) | core | push one 32-bit payload onto the TC1 transmit queue (strict priority over TC0) |
| 0x01C | PACP_SET | WO (core) | core | PACP SET request to the peer: [15:8] value, [3:0] attribute index |
| 0x020 | PACP_GET | WO (core) | core | PACP GET request to the peer: [3:0] attribute index |
| 0x024 | CPORT | WO (core) | core | [3:0] destination CPort of the following pushes |
| 0x028 | MSG | RO (core) | core | [7:0] next message-buffer byte (CPort 0 payloads, 32 bytes); the read pops it |
| 0x02C | STATUS | RO (core) | core | {pacp_cnf, pacp_rsp_valid, tx busy, PACP request pending, data frame outstanding, resends[1:0], control FIFO count[2:0], rx expected seq[3:0], tx seq[3:0], msg count[5:0], TC1 count[3:0], TC0 count[3:0]} |
| 0x030 | PACP | RO (core) | core | {pacp_cnf, pacp_rsp_valid, GET response value[7:0]}; the read clears both flags |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x034 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5550 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TC0 | 31:0 | core register | WO (core) | core | written at core register 0 |
| TC1 | 31:0 | core register | WO (core) | core | written at core register 1 |
| PACP_SET | 31:0 | core register | WO (core) | core | written at core register 2 |
| PACP_GET | 31:0 | core register | WO (core) | core | written at core register 3 |
| CPORT | 31:0 | core register | WO (core) | core | written at core register 4 |
| MSG | 31:0 | core register | RO (core) | core | read from core register 4 |
| STATUS | 31:0 | core register | RO (core) | core | read from core register 5 |
| PACP | 31:0 | core register | RO (core) | core | read from core register 6 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | received CRC / length error or framing error, message buffer overflow, control FIFO overflow, resend budget exhausted, or a push to a full queue |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `cpu_we` for one clock with `cpu_addr` (the core register) and `cpu_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `cpu_addr` (the core register) and pulses `cpu_re` during the access phase and returns `cpu_rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55500200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

### 2.1 Core CPU map

Writes take effect at the clock edge where `cpu_we` is high. Reads are combinational.

| Addr | Write | Read |
|---|---|---|
| 0 | push `{tx_cport, wdata}` to the TC0 queue | 0 |
| 1 | push `{tx_cport, wdata}` to the TC1 queue | 0 |
| 2 | PACP SET request: idx = wdata[3:0], value = wdata[15:8] | 0 |
| 3 | PACP GET request: idx = wdata[3:0] | 0 |
| 4 | `tx_cport` = wdata[3:0] (used by later pushes) | `{24'd0, mbuf[oldest]}`; with `cpu_re` and a non-empty buffer the byte is popped. When empty it returns the stale byte at the read pointer and pops nothing. |
| 5 | - | status |
| 6 | - | `{22'd0, pacp_cnf, pacp_rsp_valid, pacp_rsp_val}`; with `cpu_re` both flags clear |
| 7 | - | 0 |

The status word (address 5) packs these fields:

| Bits | Field |
|---|---|
| 31 | `pacp_cnf` |
| 30 | `pacp_rsp_valid` |
| 29 | transmitter busy (frame FSM not idle) |
| 28 | CPU PACP request pending |
| 27 | data frame outstanding |
| 26:25 | resends of the outstanding frame |
| 24:22 | control FIFO count (0-4) |
| 21:18 | expected receive sequence |
| 17:14 | transmit sequence |
| 13:8 | message buffer count (0-32) |
| 7:4 | TC1 queue count (0-8) |
| 3:0 | TC0 queue count (0-8) |

## 3. Timing

### 3.1 Symbol line

The line idles at 1 and carries one bit per clock.

**Receive.** A 0 seen while idle is the start bit. The next 8 clocks sample data bits 0..7, and the clock after them is the stop bit. If the stop bit is 1, the byte is delivered. If it is 0, `irq` pulses (framing error), the byte is lost, and the receiver goes back to idle. Sampling is plain one sample per bit, with no oversampling or mid-bit sampling.

**Transmit.** Each symbol is a start bit 0, then data bits LSB first, then a stop bit 1. When bytes go back to back the line stays 1 for one more clock before the next start bit, so each byte takes 11 clocks.

### 3.2 Frames

A frame is COF (8'h7E), the content bytes, then COF. Inside a frame, a content byte equal to 8'h7E or 8'h9D is sent as ESC_DL (8'h9D) followed by byte ^ 8'h20. No other byte is escaped. Nothing is sent between frames.

Content bytes, before escaping:

| # | Byte |
|---|---|
| 0 | `{tc, 3'b000, cport[3:0]}` |
| 1 | `{4'b0, seq[3:0]}` |
| 2 | len: payload byte count (0-16; the DUT sends 4 for data and 3 for control) |
| 3.. | payload (DUT data frames: the 32-bit word, bits 31:24 first) |
| last 2 | CRC16 high byte, then low byte |

The CRC16 uses polynomial 0x1021 and initial value 8'hFFFF, with no final XOR. It covers the unescaped header and payload bytes.

Control frames use CPort 15, TC 0, seq 0 and len 3. Their payload is `{cmd, arg1, arg2}`, with these commands:

| cmd | Name | arg1 | arg2 |
|---|---|---|---|
| 0 | GET | idx | 0 |
| 1 | SET | idx | value |
| 2 | GET response | idx | `attr[idx]` |
| 3 | SET confirm | idx | 0 |
| 4 | ACK | seq | 0 |
| 5 | NAC | expected seq | 0 |

Unknown commands are ignored.

### 3.3 Receive frame checks

The de-framer removes escapes and resets at every COF. A COF with no bytes since the previous one is ignored. A frame longer than 32 decoded bytes is dropped silently. At the closing COF the frame is processed one clock later. The frame is dropped, with a one-clock `irq` pulse, if any of these holds:
- the CRC residue over all bytes is not 0;
- the frame has fewer than 5 bytes;
- len != bytes - 5;
- len > 16;
- it is a control frame with len != 3.

The receiver ignores the TC bit.

### 3.4 Receive actions

**Control frames (CPort 15):**

| Command | Action |
|---|---|
| GET | queues a GET response with the current `attr[idx]` |
| SET | writes `attr[idx]` = value and queues a SET confirm |
| GET response | sets `pacp_rsp_valid` and `pacp_rsp_val` |
| SET confirm | sets `pacp_cnf` |
| ACK | signals the sender (§3.6) |
| NAC | signals the sender (§3.6) |

**Data frames (any other CPort):**
- **In sequence (seq == expected):**
  - Normally the frame is ACKed with its seq and the expected seq increments.
  - For CPort 0 the len payload bytes are also appended to the 32-byte message buffer.
  - If CPort 0 has no room (count + len > 32), the frame is NACed with the expected seq, `irq` pulses, and the expected seq does not advance.
- **Duplicate (seq == expected - 1):** ACKed again with that seq.
- **Anything else:** NACed with the expected seq.

ACK, NAC, GET responses and SET confirms produced by the receiver go to a 4-entry control FIFO. If the FIFO is full the response is lost and `irq` pulses. The data-frame state above still updates.

### 3.5 PACP requests from the CPU

Writing address 2 or 3 fills a single request slot. A later write before the request is launched replaces it. The request is launched as a GET or SET control frame when the transmitter is idle, no resend is waiting, and the control FIFO is empty. If a new request is written in the very clock the old one launches, both are sent. Responses update the flags in §2.1, and so do unsolicited ones. A read of address 6 clears the flags. A read in the same clock as an incoming response wins, and the flag stays clear.

### 3.6 Data frame retransmission

At most one data frame is outstanding.
- **ACK:** an ACK whose seq equals the outstanding frame's seq releases it. The transmit seq increments and the queue entry is popped. Any other ACK is ignored.
- **NAC or timeout:** these count only while the frame is outstanding, no resend is already waiting, and no data frame is on the wire.
  - A NAC (whatever its seq) triggers a resend.
  - So does a timeout: `ACK_WAIT` clocks counted under the same conditions.
  - A NAC that arrives while a data frame is being sent is ignored.
- **Resend budget:** up to 3 resends. On the 4th trigger the frame is dropped: `irq` pulses, the transmit seq increments and the queue entry is popped.

The transmit seq wraps mod 16.

### 3.7 Transmit scheduling

When the frame FSM is idle, it starts the first of these that applies:
1. a resend of the outstanding frame;
2. a control FIFO entry (ACK, NAC, GET response, SET confirm);
3. the CPU PACP request;
4. a new data frame from TC1, then TC0, only when nothing is outstanding.

Each queue holds 8 entries of `{cport, payload}`. An entry stays queued until its frame is ACKed or dropped. A push to a full queue is dropped and pulses `irq`, unless an entry is popped in the same clock.

### 3.8 irq

`irq` is the OR of registered one-clock pulses:
- CRC/length error;
- framing error;
- message buffer overflow;
- control FIFO overflow;
- resend budget exhausted;
- transmit queue overflow.

It is not sticky.

### 3.9 Reset

`rst_n` low clears all state:
- `tx_bit` = 1 and `irq` = 0;
- the queues, the control FIFO and the message buffer are emptied;
- `attr` = 0, the flags are cleared, both sequence numbers = 0 and `tx_cport` = 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `ACK_WAIT` | 600 | 1-1024 (10-bit timer) | ACK timeout in clocks, counted while a data frame is outstanding and not on the wire |

## 5. Errors and corner cases

- **NAC while sending:** a NAC received while the outstanding data frame (or its resend) is still on the wire is lost. Recovery then waits for the timeout.
- **Lost ACK:** when the control FIFO overflows, the receive side has already advanced its expected seq. The peer then resends, and the duplicate is ACKed.
- **Non-zero CPorts:** data frames to CPorts other than 0 and 15 are ACKed, but their payload is discarded.
- **Silent long frames:** frames longer than 32 bytes are dropped without `irq`.
- **No sticky errors:** `irq` is a pulse only, so software must count pulses.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "frame seq" | an outstanding data frame is either ACKed or sent 4 times (1 + 3 resends) before the next one | §3.6 |
| "DUT frame CRC" | every DUT frame has a correct CRC16 | §3.2 |
| "DUT control frame header" | control frame header: TC 0, CPort 15, seq 0, len 3 | §3.2 |
| "DUT PACP request fields" | PACP GET/SET frames carry the CPU's index and value | §3.5 |
| "DUT control command" | control command codes 0-5 only | §3.2 |
| "DUT data frame header" | data frame header: TC, CPort, len 4 | §3.2 |
| "resend content" | a resend repeats the frame exactly | §3.6 |
| "DUT seq" | data frames use consecutive sequence numbers (mod 16) | §3.6 |
| "TC1 frame" | TC1 frames go out in push order with their CPort and payload | §3.7 |
| "TC0 frame" | TC0 frames go out in push order with their CPort and payload | §3.7 |
| "DUT stop bit" | every DUT symbol has a stop bit | §3.1 |
| "escape before COF" | an escape is never followed by COF | §3.2 |
| "DUT byte outside a frame" | no bytes between frames | §3.2 |
| "needless escape" | only 8'h7E and 8'h9D are escaped | §3.2 |
| "outstanding frame neither ACKed nor dropped" | a frame without ACK is dropped after 3 resends | §3.6 |
| "queues did not drain" | all queued frames are eventually sent | §3.7 |
| "data frame not ACKed" | an in-sequence data frame is ACKed with its sequence number | §3.4 |
| "duplicate not re-ACKed" | the previous sequence number is ACKed again | §3.4 |
| "data frame not NACed" | an out-of-sequence frame, or one with no buffer room, is NACed with the expected sequence number | §3.4 |
| "mbuf read empty" | reading address 4 with an empty buffer returns 0 in bits 31:8 | §2.1 |
| "mbuf byte" | CPort 0 payload bytes are popped in order | §3.4 |
| "status msg count" | status[13:8] = message buffer count | §2.1 |
| "status rx seq" | status[21:18] = expected receive sequence | §2.1 |
| "reset state" | reset values | §3.9 |
| "irq during clean traffic" | no `irq` without an error | §3.8 |
| "queue counts" | status[7:0] = 8'h88 when both queues are full | §3.7 |
| "resend budget: no irq" | exactly one `irq` pulse when a frame is dropped | §3.6 |
| "PACP request behind a resend lost" | a PACP request waits behind a resend and is still sent | §3.5 |
| "SET confirm flags" | a SET confirm sets flag bit 9 only | §3.5 |
| "GET" | a GET response sets flag bit 8 and the value | §3.5 |
| "PACP flags without a response" | no flags without a peer response | §3.5 |
| "SET 0x9D" | a SET value of 8'h9D is escaped and arrives intact | §3.2 |
| "replaced PACP request" | a second request written before the first is sent replaces it | §3.5 |
| "peer PACP responses missing" | peer GET/SET requests are answered | §3.5 |
| "unsolicited PACP flags" | unsolicited GET responses and SET confirms still set the flags; ACK/NAC with nothing outstanding are ignored | §3.5 |
| "buffer overflow: no irq" | a CPort 0 frame without buffer room pulses `irq` | §3.4 |
| "control FIFO overflow: no irq" | a control response with the FIFO full is dropped and pulses `irq` | §3.4 |
| a_reset_outputs | in reset `tx_bit` = 1 and `irq` = 0 | §3.9 |
| a_tx_bit | `tx_bit` equals the checker's transmitter model | §3.1-§3.7 |
| a_irq | `irq` equals the modelled error pulses | §3.8 |
| a_cpu_rdata | `cpu_rdata` equals the model, except address 4 with an empty buffer | §2.1 |
| a_mbuf_data | address 4 with a non-empty buffer returns the oldest byte | §3.4 |
