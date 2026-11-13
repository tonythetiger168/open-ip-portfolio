<!-- SPDX-License-Identifier: Apache-2.0 -->
# Bluetooth5: design specification

A Bluetooth LE link-layer peripheral as a simplified baseband model: one air bit per clock, BLE
packet format with whitening and CRC24, ADV_IND advertising on channel 37 with SCAN_REQ /
SCAN_RSP, a simplified CONNECT_REQ, and the connection state with channel hopping, SN / NESN
acknowledgement, peripheral latency and supervision timeout. Not implemented: real RF timing (IFS,
windows, widening), channel maps / CSA#2, encryption, LL control procedures, non-empty transmit
data. Core `Bluetooth5_top` (`rtl/Bluetooth5_top.sv`), testbench `tb/Bluetooth5_tb.sv`, checker
`tb/cov/Bluetooth5_sva.sv` (a pin-level cycle model).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Bytes go LSB first; multi-byte fields little-endian.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one air bit per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rxd` | input | 1 | received air bit (LSB first per byte); ignored while `tx_act` | - | `clk` | - |
| `txd` | output | 1 | transmitted air bit; 0 when not transmitting | - | `clk` | 0 |
| `tx_act` | output | 1 | high exactly while packet bits are on `txd` | high | `clk` | 0 |
| `cfg_we` | input | 1 | host config write strobe | high | `clk` | - |
| `cfg_addr` | input | 5 | 0..15 ADV_IND payload byte, 16 ctrl (bit 0 adv_en), 17 ctrl2 (bit 0 scan_en); others ignored | - | `clk` | - |
| `cfg_wdata` | input | 8 | host config write data | - | `clk` | - |
| `irq` | output | 1 | one-clock error pulse (section 5) | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these to find connection-event boundaries and the link state. Keep the names and
meanings.

| Signal | Width | Meaning |
|---|---|---|
| `ll_state` | 1 | link state: 0 advertising, 1 connection |
| `conn_timer` | 16 | clocks since the last connection event; the event boundary is `conn_timer >= conn_interval` |
| `conn_interval` | 16 | connection interval from CONNECT_REQ (reset 1500) |
| `miss` | 16 | connection events without central traffic in a row |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Bluetooth5.md`](../ip/Bluetooth5.md) (source: `scripts/apb/specs/Bluetooth5.json`); do not edit by hand.

`Bluetooth5_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxd`, `txd`, `tx_act`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x42540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | PAY0 | WO (core) | core | ADV_IND payload byte 0 (write only; reset 0xB0) |
| 0x018 | PAY1 | WO (core) | core | ADV_IND payload byte 1 (write only; reset 0xB1) |
| 0x01C | PAY2 | WO (core) | core | ADV_IND payload byte 2 (write only; reset 0xB2) |
| 0x020 | PAY3 | WO (core) | core | ADV_IND payload byte 3 (write only; reset 0xB3) |
| 0x024 | PAY4 | WO (core) | core | ADV_IND payload byte 4 (write only; reset 0xB4) |
| 0x028 | PAY5 | WO (core) | core | ADV_IND payload byte 5 (write only; reset 0xB5) |
| 0x02C | PAY6 | WO (core) | core | ADV_IND payload byte 6 (write only; reset 0xB6) |
| 0x030 | PAY7 | WO (core) | core | ADV_IND payload byte 7 (write only; reset 0xB7) |
| 0x034 | PAY8 | WO (core) | core | ADV_IND payload byte 8 (write only; reset 0xB8) |
| 0x038 | PAY9 | WO (core) | core | ADV_IND payload byte 9 (write only; reset 0xB9) |
| 0x03C | PAY10 | WO (core) | core | ADV_IND payload byte 10 (write only; reset 0xBA) |
| 0x040 | PAY11 | WO (core) | core | ADV_IND payload byte 11 (write only; reset 0xBB) |
| 0x044 | PAY12 | WO (core) | core | ADV_IND payload byte 12 (write only; reset 0xBC) |
| 0x048 | PAY13 | WO (core) | core | ADV_IND payload byte 13 (write only; reset 0xBD) |
| 0x04C | PAY14 | WO (core) | core | ADV_IND payload byte 14 (write only; reset 0xBE) |
| 0x050 | PAY15 | WO (core) | core | ADV_IND payload byte 15 (write only; reset 0xBF) |
| 0x054 | ADV_CTRL | WO (core) | core | bit 0 adv_en: send ADV_IND every ADV_INTV clocks while advertising (write only; reset 1) |
| 0x058 | SCAN_CTRL | WO (core) | core | bit 0 scan_en: answer SCAN_REQ with SCAN_RSP (write only; reset 1) |
| 0x05C | STATUS | RO | core | Baseband state, as driven on the pin |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x060 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4254 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| PAY0 | 7:0 | core register | WO (core) | core | written at core register 0 |
| PAY1 | 7:0 | core register | WO (core) | core | written at core register 1 |
| PAY2 | 7:0 | core register | WO (core) | core | written at core register 2 |
| PAY3 | 7:0 | core register | WO (core) | core | written at core register 3 |
| PAY4 | 7:0 | core register | WO (core) | core | written at core register 4 |
| PAY5 | 7:0 | core register | WO (core) | core | written at core register 5 |
| PAY6 | 7:0 | core register | WO (core) | core | written at core register 6 |
| PAY7 | 7:0 | core register | WO (core) | core | written at core register 7 |
| PAY8 | 7:0 | core register | WO (core) | core | written at core register 8 |
| PAY9 | 7:0 | core register | WO (core) | core | written at core register 9 |
| PAY10 | 7:0 | core register | WO (core) | core | written at core register 10 |
| PAY11 | 7:0 | core register | WO (core) | core | written at core register 11 |
| PAY12 | 7:0 | core register | WO (core) | core | written at core register 12 |
| PAY13 | 7:0 | core register | WO (core) | core | written at core register 13 |
| PAY14 | 7:0 | core register | WO (core) | core | written at core register 14 |
| PAY15 | 7:0 | core register | WO (core) | core | written at core register 15 |
| ADV_CTRL | 7:0 | core register | WO (core) | core | written at core register 16 |
| SCAN_CTRL | 7:0 | core register | WO (core) | core | written at core register 17 |
| STATUS | 0 | `tx_act` | RO | core | high while a packet is being sent on txd |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERROR | a bad CRC24, an unknown advertising PDU type, a reserved LLID, a length above 16, a CONNECT_REQ of the wrong length, or a supervision timeout (back to advertising) |

### Core register port

The CFG words reach the core's own register port. A write to one pulses `cfg_we` for one clock with `cfg_addr` (the core register) and `cfg_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. 

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x42540200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CFG words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. Read STATUS (0x05C) for the core's live `tx_act`; it needs no clearing.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Packet format

Preamble (0xAA if the access address bit 0 is 0, else 0x55), access address (32 bits), header
byte 0, header byte 1 (length), payload, CRC24, all LSB first. CRC24: serial LFSR, poly 0x00065B,
shift right, init 0x555555 on advertising packets and CRCInit on data packets, over header and
payload; sent register bit 0 first. Whitening (7-bit LFSR, out = l[6], l = {l[5:0], l[6]^l[3]},
seed = channel | 1; advertising 0x25) is applied to header, payload and CRC.

Advertising header byte 0 = {4'b0, type}; data header byte 0 = {3'b0, md, sn, nesn, llid}. Packet
lengths: ADV_IND / SCAN_RSP 8+32+16+128+24 = 208 bits, empty data PDU 80 bits.

### 3.2 Receive

The receiver is off while `tx_act` is high. Otherwise it compares the 32 latest bits (including
the current `rxd`) with the access address of the link state (0x8E89BED6 advertising, the
connection access address connected); the preamble is not checked. Then it de-whitens and reads
the header, the payload (length 0..16) and 24 CRC bits. A length above 16 drops the packet with
`irq`. At the end of the CRC the packet is complete (one clock later it is processed): a CRC
mismatch gives `irq` and nothing else.

### 3.3 Advertising state

Every ADV_INTV + 1 clocks (the advertising timer counts 0..ADV_INTV) an ADV_IND is requested if
adv_en (reset 1); payload = the 16 config bytes (reset 0xB0 + i), read while they are sent. Good
received advertising PDUs:

| Type | Action |
|---|---|
| 3 SCAN_REQ | SCAN_RSP (type 4, 16 bytes 0x53 + i) if scan_en (reset 1); else nothing |
| 5 CONNECT_REQ | length 15: enter the connection state (section 3.4); other length: `irq` |
| 0, 1, 2, 4, 6 | ignored |
| others | `irq` |

The payload is not checked against the advertiser address; any SCAN_REQ / CONNECT_REQ is accepted.

### 3.4 CONNECT_REQ

Payload: AA[4], CRCInit[3], interval[2], latency[2], timeout[2], hop[1] (bits 4:0 used),
channel[1] (bits 5:0, minus 37 if >= 37). Entering the connection state resets SN, NESN, the
event timer and the miss count and cancels pending advertising transmissions.

### 3.5 Connection state

A connection event happens when `conn_timer >= conn_interval` (an interval of N clocks gives an
event every N + 1 clocks; 0 gives one every clock). At each event the data channel advances to
(channel + hop) mod 37, and:

- central traffic seen since the last event: the miss count is cleared;
- otherwise, if timeout != 0 and miss + 1 >= timeout: back to advertising with `irq` (a pending
  keepalive is dropped);
- otherwise miss increments, and if the old miss >= latency an empty PDU is requested
  (keepalive).

A good data PDU (CRC ok) marks central traffic. LLID 0 gives `irq` and no answer. Otherwise: if its
SN equals our NESN, NESN toggles (new packet); if its NESN differs from our SN, SN toggles (acked);
an empty PDU (LLID 1, length 0, with the current SN / NESN) is requested.

### 3.6 Transmit and reset

Requests are served when the transmitter is idle, priority: data, SCAN_RSP, ADV_IND. The clock
after the grant the first bit is on `txd` with `tx_act` high; one bit per clock; `tx_act` falls
the clock after the last CRC bit. `txd` = 0 while `tx_act` is low.

Reset: `txd` = `tx_act` = `irq` = 0, advertising state, adv_en = scan_en = 1, payload 0xB0 + i,
interval 1500.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `ADV_INTV` | 1200 | >= 1 (below about 210 the packets run back to back and the receiver is mostly off) | advertising period is ADV_INTV + 1 clocks |

## 5. Errors and corner cases

`irq` is a one-clock pulse two clocks after the end of the offending packet for: bad CRC24,
unknown advertising PDU type, CONNECT_REQ of the wrong length, reserved LLID 0; and for a length
above 16 (two clocks after the length byte); and the clock after a supervision timeout event. A
SCAN_REQ with scan_en off raises no `irq`.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "ADV_IND expected" | an ADV_IND every ADV_INTV + 1 clocks while advertising | §3.3 |
| "ADV_IND format" | good CRC, header type 0, length 16 | §3.1, §3.3 |
| "ADV_IND payload" | the payload is the 16 config bytes | §3.3 |
| "connected" | a 15-byte CONNECT_REQ enters the connection state | §3.4 |
| "no answer to a bad PDU" | a data PDU with reserved LLID gets no answer | §3.5 |
| "irq on a bad data PDU" | ...and one `irq` | §5 |
| "data PDU acknowledged" | a good central data PDU gets an empty PDU | §3.5 |
| "keepalive" | more than `latency` missed events: empty PDU each event | §3.5 |
| "no keepalive within latency" | no transmission while missed events <= latency | §3.5 |
| "reset outputs" | reset values | §3.6 |
| "adv_en off" | adv_en = 0 stops ADV_IND | §3.3 |
| "SCAN_RSP" | SCAN_REQ with scan_en gets a SCAN_RSP | §3.3 |
| "SCAN_RSP format" | SCAN_RSP header type 4, length 16, good CRC | §3.3 |
| "SCAN_RSP payload" | SCAN_RSP payload byte i = 0x53 + i | §3.3 |
| "scan_en off" | scan_en = 0: no SCAN_RSP | §3.3 |
| "no irq for a disabled SCAN_REQ" | ...and no `irq` | §3.3 |
| "no answer to an advertising PDU" | known advertising PDU types are ignored | §3.3 |
| "no SCAN_RSP for a bad CRC" | bad CRC: dropped | §3.2 |
| "still advertising" | a CONNECT_REQ of another length does not connect | §3.4 |
| "keepalives while the central is silent" | keepalives on the connection access address | §3.5 |
| "no advertising while connected" | no ADV_IND in the connection state | §3.3 |
| "oversize PDU not acknowledged" | length > 16 is dropped | §3.2 |
| "timeout -> advertising" | `timeout` missed events drop the connection | §3.5 |
| "answer at interval 0" | interval 0: an event every clock, packets still answered | §3.5 |
| "miss counter cleared" | an event with central traffic clears the miss count | §3.5 |
| "reset mid-TX" | reset stops a transmission at once | §3.6 |
| a_reset_outputs | reset values | §3.6 |
| a_txd | `txd` equals the checker's pin-level model every clock | §3 |
| a_tx_act | `tx_act` equals the model | §3 |
| a_irq | `irq` equals the model | §5 |
| a_txd_low_when_idle | `txd` = 0 while `tx_act` = 0 | §3.1 |
| a_irq_on_timeout | `irq` after a supervision timeout | §5 |
| a_irq_on_bad_crc | `irq` after a bad CRC | §5 |
