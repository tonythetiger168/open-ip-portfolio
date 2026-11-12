<!-- SPDX-License-Identifier: Apache-2.0 -->
# CAN_XL: design specification

A CAN XL protocol controller that also handles classical CAN 2.0A/B frames: XL frames with the
two-rate data phase, SBC, PCRC, FCRC and fixed stuffing, classical frames exactly as in the CAN IP
([CAN.md](CAN.md)), an acceptance filter, a TX buffer and a double-buffered RX buffer with a 32-bit
host port, error frames and fault confinement. Not implemented: transmitter delay compensation,
PWM coding, CAN FD frames (they are protocol exceptions), overload frames, CANsec, error-signalling
switch-off. The XL layout follows the public CiA 610-1 descriptions; bit-exact ISO 11898-1:2024
conformance is not claimed. Core `CAN_XL_top` (`rtl/CAN_XL_top.sv`), testbench `tb/CAN_XL_tb.sv`,
checker `tb/cov/CAN_XL_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. 0 is dominant. Positions are de-stuffed bit indices from SOF = 0.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rxd` | input | 1 | bus level (wired-AND, 0 dominant); synchronised internally | - | async | - |
| `txd` | output | 1 | bit driven to the transceiver; 1 recessive | - | `clk` | 1 |
| `tx_fast` | output | 1 | transmitting in the data phase (transceiver FAST TX) | high | `clk` | 0 |
| `rx_fast` | output | 1 | receiving in the data phase (transceiver FAST RX) | high | `clk` | 0 |
| `cfg_brp` | input | 6 | nominal rate: tq = `cfg_brp` + 1 clocks | - | `clk` | - |
| `cfg_tseg1` | input | 4 | nominal TSEG1 - 1 (tq) | - | `clk` | - |
| `cfg_tseg2` | input | 3 | nominal TSEG2 - 1 (tq) | - | `clk` | - |
| `cfg_sjw` | input | 2 | nominal SJW - 1 (tq) | - | `clk` | - |
| `cfg_dbrp` | input | 6 | data rate prescaler - 1 | - | `clk` | - |
| `cfg_dtseg1` | input | 4 | data rate TSEG1 - 1 | - | `clk` | - |
| `cfg_dtseg2` | input | 3 | data rate TSEG2 - 1 | - | `clk` | - |
| `cfg_dsjw` | input | 2 | data rate SJW - 1 | - | `clk` | - |
| `acc_code` | input | 29 | acceptance code | - | `clk` | - |
| `acc_mask` | input | 29 | acceptance mask: 1 = bit compared | - | `clk` | - |
| `hb_wen` | input | 1 | write one word of the TX buffer | high | `clk` | - |
| `hb_waddr` | input | WW | TX buffer word address (WW = log2(MAX_BYTES) - 2) | - | `clk` | - |
| `hb_wdata` | input | 32 | TX buffer word; bits 7:0 = byte 4 * addr | - | `clk` | - |
| `hb_raddr` | input | WW | RX buffer word address | - | `clk` | - |
| `hb_rdata` | output | 32 | RX buffer word of the last delivered frame, combinational; bits 7:0 = byte 4 * addr | - | comb | unknown until written |
| `tx_valid` | input | 1 | queue a frame (header on `tx_*`) | high | `clk` | - |
| `tx_ready` | output | 1 | TX buffer empty | high | `clk` | 1 |
| `tx_xl` | input | 1 | 1 XL frame, 0 classical frame | high | `clk` | - |
| `tx_id` | input | 29 | identifier: extended ID[28:0], base / XL priority ID in [10:0] | - | `clk` | - |
| `tx_ide` | input | 1 | extended frame (classical only) | high | `clk` | - |
| `tx_rtr` | input | 1 | remote frame (classical only) | high | `clk` | - |
| `tx_dlc` | input | 11 | classical: DLC in [3:0]; XL: data bytes - 1 | - | `clk` | - |
| `tx_sdt` | input | 8 | XL SDU type | - | `clk` | - |
| `tx_sec` | input | 1 | XL SEC bit | - | `clk` | - |
| `tx_vcid` | input | 8 | XL virtual CAN network ID | - | `clk` | - |
| `tx_af` | input | 32 | XL acceptance field | - | `clk` | - |
| `tx_abort` | input | 1 | drop the queued frame (section 3.4) | high | `clk` | - |
| `tx_done` | output | 1 | one-clock pulse: own frame sent successfully | high | `clk` | 0 |
| `tx_aborted` | output | 1 | one-clock pulse: queued frame dropped | high | `clk` | 0 |
| `tx_rejected` | output | 1 | one-clock pulse: `tx_valid` refused, frame larger than MAX_BYTES | high | `clk` | 0 |
| `rx_valid` | output | 1 | one-clock pulse: frame delivered; `rx_*` and the RX buffer updated | high | `clk` | 0 |
| `rx_xl` | output | 1 | delivered frame is XL | high | `clk` | 0 |
| `rx_id` | output | 29 | delivered identifier (base / priority ID in [10:0]) | - | `clk` | 0 |
| `rx_ide` | output | 1 | delivered frame is extended | high | `clk` | 0 |
| `rx_rtr` | output | 1 | delivered frame is remote | high | `clk` | 0 |
| `rx_dlc` | output | 11 | classical: raw DLC; XL: data bytes - 1 | - | `clk` | 0 |
| `rx_sdt` | output | 8 | XL SDT (0 for classical) | - | `clk` | 0 |
| `rx_sec` | output | 1 | XL SEC (0 for classical) | - | `clk` | 0 |
| `rx_vcid` | output | 8 | XL VCID (0 for classical) | - | `clk` | 0 |
| `rx_af` | output | 32 | XL AF (0 for classical) | - | `clk` | 0 |
| `rx_trunc` | output | 1 | delivered XL frame had more than MAX_BYTES bytes; the rest was dropped | high | `clk` | 0 |
| `arb_lost` | output | 1 | one-clock pulse: arbitration lost | high | `clk` | 0 |
| `err_bit` | output | 1 | one-clock pulse: bit error | high | `clk` | 0 |
| `err_stuff` | output | 1 | one-clock pulse: stuff error | high | `clk` | 0 |
| `err_crc` | output | 1 | one-clock pulse: CRC error (CRC-15, SBC / PCRC or FCRC) | high | `clk` | 0 |
| `err_form` | output | 1 | one-clock pulse: form error | high | `clk` | 0 |
| `err_ack` | output | 1 | one-clock pulse: ACK error | high | `clk` | 0 |
| `pexc` | output | 1 | one-clock pulse: protocol exception (CAN FD frame seen) | high | `clk` | 0 |
| `tec` | output | 9 | transmit error counter | - | `clk` | 0 |
| `rec` | output | 8 | receive error counter | - | `clk` | 0 |
| `err_passive` | output | 1 | not bus-off and (`tec` > 127 or `rec` > 127); combinational | high | comb | 0 |
| `bus_off` | output | 1 | bus-off state; combinational | high | comb | 0 |

### Internal signals used by the verification

fsm_cov binds the protocol state; keep its name and encoding.

| Signal | Width | Meaning |
|---|---|---|
| `mode` | 4 | 0 IDLE, 1 SUSPEND, 2 FRAME, 3 EFLAG, 4 EWAIT, 5 EDELIM, 6 INTERM, 7 BUSOFF, 8 PEXC (protocol exception) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/CAN_XL.md`](../ip/CAN_XL.md) (source: `scripts/apb/specs/CAN_XL.json`); do not edit by hand.

`CAN_XL_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxd`, `txd`, `tx_fast`, `rx_fast`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x584C0100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | NBTR | RW | 0x00002941 | Nominal bit timing (static while the bus is in use) |
| 0x018 | DBTR | RW | 0x000004C0 | Data-phase bit timing of XL frames (static while the bus is in use) |
| 0x01C | ACC_CODE | RW | 0x00000000 | Acceptance code |
| 0x020 | ACC_MASK | RW | 0x00000000 | Acceptance mask |
| 0x024 | TX_ID | RW | 0x00000000 | Header of the frame to queue |
| 0x028 | TX_CTRL | RW | 0x00000000 | XL control fields / length of the frame to queue |
| 0x02C | TX_AF | RW | 0x00000000 | XL acceptance field of the frame to queue |
| 0x030 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x034 | BUF0 | RW (core) | core | write: TX buffer bytes 0..3 (byte 0 in bits 7:0, sent first); read: bytes 0..3 of the last delivered frame |
| 0x038 | BUF1 | RW (core) | core | TX / RX buffer bytes 4..7 |
| 0x03C | BUF2 | RW (core) | core | TX / RX buffer bytes 8..11 |
| 0x040 | BUF3 | RW (core) | core | TX / RX buffer bytes 12..15 |
| 0x044 | BUF4 | RW (core) | core | TX / RX buffer bytes 16..19 |
| 0x048 | BUF5 | RW (core) | core | TX / RX buffer bytes 20..23 |
| 0x04C | BUF6 | RW (core) | core | TX / RX buffer bytes 24..27 |
| 0x050 | BUF7 | RW (core) | core | TX / RX buffer bytes 28..31 |
| 0x054 | BUF8 | RW (core) | core | TX / RX buffer bytes 32..35 |
| 0x058 | BUF9 | RW (core) | core | TX / RX buffer bytes 36..39 |
| 0x05C | BUF10 | RW (core) | core | TX / RX buffer bytes 40..43 |
| 0x060 | BUF11 | RW (core) | core | TX / RX buffer bytes 44..47 |
| 0x064 | BUF12 | RW (core) | core | TX / RX buffer bytes 48..51 |
| 0x068 | BUF13 | RW (core) | core | TX / RX buffer bytes 52..55 |
| 0x06C | BUF14 | RW (core) | core | TX / RX buffer bytes 56..59 |
| 0x070 | BUF15 | RW (core) | core | TX / RX buffer bytes 60..63 |
| 0x074 | RX_ID | RO | core | Header of the last delivered frame (until the next one) |
| 0x078 | RX_CTRL | RO | core | XL control fields / length of the last delivered frame |
| 0x07C | RX_AF | RO | core | XL acceptance field of the last delivered frame |
| 0x080 | STATUS | RO | core | Transmitter and fault confinement |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x084 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x584C | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 12:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 12:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| NBTR | 5:0 | `cfg_brp` | RW | 0x1 | time quantum = BRP+1 clocks |
| NBTR | 9:6 | `cfg_tseg1` | RW | 0x5 | TSEG1 = TSEG1+1 tq (propagation + phase 1) |
| NBTR | 12:10 | `cfg_tseg2` | RW | 0x2 | TSEG2 = TSEG2+1 tq (phase 2) |
| NBTR | 14:13 | `cfg_sjw` | RW | 0x1 | resynchronisation jump width = SJW+1 tq |
| DBTR | 5:0 | `cfg_dbrp` | RW | 0x0 | data-phase time quantum = DBRP+1 clocks |
| DBTR | 9:6 | `cfg_dtseg1` | RW | 0x3 | data-phase TSEG1 = DTSEG1+1 tq |
| DBTR | 12:10 | `cfg_dtseg2` | RW | 0x1 | data-phase TSEG2 = DTSEG2+1 tq |
| DBTR | 14:13 | `cfg_dsjw` | RW | 0x0 | data-phase SJW = DSJW+1 tq |
| ACC_CODE | 28:0 | `acc_code` | RW | 0x0 | ID to match (base and XL priority IDs in bits 10:0) |
| ACC_MASK | 28:0 | `acc_mask` | RW | 0x0 | 1 = the ID bit must equal ACC_CODE; 0 accepts every frame |
| TX_ID | 28:0 | `tx_id` | RW | 0x0 | identifier (base and XL frames: bits 10:0) |
| TX_ID | 29 | `tx_ide` | RW | 0x0 | 1 = extended CC frame |
| TX_ID | 30 | `tx_rtr` | RW | 0x0 | 1 = CC remote frame |
| TX_ID | 31 | `tx_xl` | RW | 0x0 | 1 = XL frame |
| TX_CTRL | 10:0 | `tx_dlc` | RW | 0x0 | CC: DLC in bits 3:0; XL: data bytes - 1 |
| TX_CTRL | 18:11 | `tx_sdt` | RW | 0x0 | XL SDU type |
| TX_CTRL | 19 | `tx_sec` | RW | 0x0 | XL SEC bit |
| TX_CTRL | 27:20 | `tx_vcid` | RW | 0x0 | XL virtual CAN network ID |
| TX_AF | 31:0 | `tx_af` | RW | 0x0 | XL acceptance field |
| CMD | 0 | `tx_valid` | WO (pulse) | 0x0 | 1 = queue TX_ID / TX_CTRL / TX_AF with the TX buffer (ignored while STATUS.tx_ready is 0; IRQ REFUSED when longer than the buffer) |
| CMD | 1 | `tx_abort` | WO (pulse) | 0x0 | 1 = drop the queued frame when it is not being sent (IRQ ABORTED) |
| BUF0 | 31:0 | core register | RW (core) | core | written at core register 0 and read from core register 0 |
| BUF1 | 31:0 | core register | RW (core) | core | written at core register 1 and read from core register 1 |
| BUF2 | 31:0 | core register | RW (core) | core | written at core register 2 and read from core register 2 |
| BUF3 | 31:0 | core register | RW (core) | core | written at core register 3 and read from core register 3 |
| BUF4 | 31:0 | core register | RW (core) | core | written at core register 4 and read from core register 4 |
| BUF5 | 31:0 | core register | RW (core) | core | written at core register 5 and read from core register 5 |
| BUF6 | 31:0 | core register | RW (core) | core | written at core register 6 and read from core register 6 |
| BUF7 | 31:0 | core register | RW (core) | core | written at core register 7 and read from core register 7 |
| BUF8 | 31:0 | core register | RW (core) | core | written at core register 8 and read from core register 8 |
| BUF9 | 31:0 | core register | RW (core) | core | written at core register 9 and read from core register 9 |
| BUF10 | 31:0 | core register | RW (core) | core | written at core register 10 and read from core register 10 |
| BUF11 | 31:0 | core register | RW (core) | core | written at core register 11 and read from core register 11 |
| BUF12 | 31:0 | core register | RW (core) | core | written at core register 12 and read from core register 12 |
| BUF13 | 31:0 | core register | RW (core) | core | written at core register 13 and read from core register 13 |
| BUF14 | 31:0 | core register | RW (core) | core | written at core register 14 and read from core register 14 |
| BUF15 | 31:0 | core register | RW (core) | core | written at core register 15 and read from core register 15 |
| RX_ID | 28:0 | `rx_id` | RO | core | identifier |
| RX_ID | 29 | `rx_ide` | RO | core | extended CC frame |
| RX_ID | 30 | `rx_rtr` | RO | core | CC remote frame |
| RX_ID | 31 | `rx_xl` | RO | core | XL frame |
| RX_CTRL | 10:0 | `rx_dlc` | RO | core | CC: DLC; XL: data bytes - 1 |
| RX_CTRL | 18:11 | `rx_sdt` | RO | core | XL SDU type |
| RX_CTRL | 19 | `rx_sec` | RO | core | XL SEC bit |
| RX_CTRL | 27:20 | `rx_vcid` | RO | core | XL virtual CAN network ID |
| RX_CTRL | 28 | `rx_trunc` | RO | core | XL frame longer than the buffer: the bytes past it were dropped |
| RX_AF | 31:0 | `rx_af` | RO | core | XL acceptance field |
| STATUS | 0 | `tx_ready` | RO | core | no frame queued (CMD.tx_valid is taken) |
| STATUS | 9:1 | `tec` | RO | core | transmit error counter |
| STATUS | 17:10 | `rec` | RO | core | receive error counter |
| STATUS | 18 | `err_passive` | RO | core | error passive |
| STATUS | 19 | `bus_off` | RO | core | bus-off |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | SENT | a queued frame was sent |
| 1 | ABORTED | a queued frame was dropped by CMD.tx_abort |
| 2 | REFUSED | CMD.tx_valid with a frame longer than the buffer |
| 3 | RX | a frame was delivered (RX_* and BUF hold it until the next one) |
| 4 | ARB_LOST | arbitration lost (the frame is retried) |
| 5 | ERR_BIT | bit error |
| 6 | ERR_STUFF | stuff error (dynamic or fixed stuff bit) |
| 7 | ERR_CRC | CRC error (CC CRC, SBC / PCRC, or FCRC) |
| 8 | ERR_FORM | form error |
| 9 | ERR_ACK | acknowledgement error |
| 10 | PEXC | protocol exception (a CAN FD frame): the node waited for 11 recessive bits |
| 11 | ERR_PASSIVE | node is error passive (level) |
| 12 | BUS_OFF | node is bus-off (level) |

### Core register port

The BUF words reach the core's own register port. A write to one pulses `hb_wen` for one clock with `hb_waddr` (the core register) and `hb_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `hb_raddr` (the core register) during the access phase and returns `hb_rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x584C0100.
2. Write 0x1FFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write NBTR (0x014), DBTR (0x018), ACC_CODE (0x01C), ACC_MASK (0x020), TX_ID (0x024), TX_CTRL (0x028), TX_AF (0x02C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FFF enables all).
5. To issue a command, write 1 to `tx_valid` (CMD bit 0), `tx_abort` (CMD bit 1) at 0x030; the core sees a one-clock pulse, and the register reads 0.
6. Access the core's registers through the BUF words (0x034 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
7. Read RX_ID (0x074) for the core's live `rx_id`, `rx_ide`, `rx_rtr`, `rx_xl`; it needs no clearing.
8. Read RX_CTRL (0x078) for the core's live `rx_dlc`, `rx_sdt`, `rx_sec`, `rx_vcid`, `rx_trunc`; it needs no clearing.
9. Read RX_AF (0x07C) for the core's live `rx_af`; it needs no clearing.
10. Read STATUS (0x080) for the core's live `tx_ready`, `tec`, `rec`, `err_passive`, `bus_off`; it needs no clearing.
11. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Set NBTR and DBTR (or keep the reset values: 20-clock nominal and 7-clock data bits), ACC_CODE / ACC_MASK, IRQ_ENABLE.
2. Transmit: write BUF0.. with the data bytes, TX_ID, TX_CTRL, TX_AF, then CMD = 1. IRQ SENT (or REFUSED, ARB_LOST, ERR_*) follows.
3. Receive: on IRQ RX read RX_ID, RX_CTRL, RX_AF and BUF0.. (bytes past the length read stale data).
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Bit timing and the two rates

Bit timing, hard synchronisation and resynchronisation are as in CAN.md section 3.1, with one set
of `cfg_*` for the nominal rate and one (`cfg_d*`) for the data rate. The rate of each bit is
chosen at its bit start: the data rate from XL position 18 (DH1) through the last FCP bit
(including stuff bits in that range), the nominal rate elsewhere. An error in the data phase
returns to the nominal rate at the next bit (the error flag). `tx_fast` = data rate and
transmitting, `rx_fast` = data rate and not transmitting.

The bus input has two synchroniser flops and resynchronisation acts a clock after the edge, so
each rate needs (tseg1 + 1) * (brp + 1) >= 3 clocks and (tseg2 + 1) * (brp + 1) >= 2 clocks.
There is no transmitter delay compensation: the data-phase sample point is the plain one.

### 3.2 Classical frames

As CAN.md section 3.2 (base and extended, data and remote, DLC 0..15 with at most 8 bytes, CRC-15,
dynamic stuffing through the last CRC bit). An extended frame with r1 (position 33) recessive is a
protocol exception (section 3.6).

### 3.3 XL frames

| Position | Field |
|---|---|
| 0 | SOF |
| 1..11 | priority ID[10:0] |
| 12 | RRS (0) |
| 13 | IDE (0) |
| 14, 15 | FDF (1), XLF (1) |
| 16 | resXL (0) |
| 17, 18, 19 | ADH, DH1, DH2 (1) |
| 20 | DL1 (0) |
| 21..28 | SDT |
| 29 | SEC |
| 30..40 | DLC = data bytes - 1 |
| 41..43 | SBC: Gray code of (dynamic stuff count mod 4), then its even parity |
| 44..56 | PCRC |
| 57..64 | VCID |
| 65..96 | AF |
| 97.. | data, DLC + 1 bytes, byte 0 first, MSB first |
| next 32 | FCRC |
| next 4 | FCP 1100 |
| then | DAH (1), ACK slot, ACK delimiter, EOF (7) |

All fields MSB first. Stuffing:

- dynamic (a complement after five equal bits) from SOF up to the bit before ADH (position 17);
- fixed from DL1: one stuff bit (the complement of the bit before) before every FS-th de-stuffed
  bit counted from DL1 (before positions 20 + FS, 20 + 2 FS, ...), up to the last FCRC bit; none
  after it.

PCRC: x^13+x^12+x^11+x^8+x^7+x^6+x^5+x^2+x+1 (0x19E7), init 0, over SOF..SBC including the dynamic
stuff bits. FCRC: polynomial 0xF4ACFB13, init 0, over SOF..last data bit including the PCRC field
and without stuff bits. A wrong fixed stuff bit is a stuff error. Wrong resXL / ADH / DH1 / DH2 /
DL1 / FCP / DAH values are form errors. An SBC or PCRC mismatch is a CRC error at the last PCRC bit
(the length may be wrong); an FCRC mismatch is a CRC error at the ACK delimiter.

### 3.4 Buffers and the host side

`tx_ready` = no queued frame. `tx_valid` with `tx_ready` queues the header (`tx_ide` and `tx_rtr`
forced 0 for XL) if the frame's data fits in MAX_BYTES (XL: DLC + 1 bytes); otherwise
`tx_rejected` pulses and nothing is queued. The frame data is read from the TX buffer while it is
sent, so the host must not change it until `tx_done` / `tx_aborted`. `tx_abort` with a queued
frame requests a drop: the frame is dropped (`tx_aborted`) when the node is not transmitting it,
at once when idle or after the current attempt ends; a frame that completes first gives `tx_done`.
No new attempt starts while a drop is requested.

Received data bytes are written into the hidden bank of the RX buffer as they arrive; bytes past
MAX_BYTES are dropped and flagged. On delivery the banks swap, so `hb_rdata` shows the delivered
frame until the next delivery.

### 3.5 Transmission and arbitration

As CAN.md sections 3.4 and 3.5. Arbitration covers positions 1..12 (base and XL) or 1..32
(extended). `tx_done` pulses at the 7th EOF bit sampled recessive; `tec` then drops by 1.

### 3.6 Reception

Every node that is not transmitting checks the frame and drives the ACK slot dominant when its
CRC (CRC-15 or FCRC) matched. At the 6th EOF bit the frame is valid: `rec` drops as in CAN, and
when ((ID ^ `acc_code`) & `acc_mask`) == 0 (XL: ID = priority ID) `rx_valid` pulses with the
header, `rx_trunc` and the banks swapped. Own frames are never delivered.

Protocol exception: FDF = 1 with XLF = 0 (a CAN FD frame), or an extended frame with r1 recessive:
`pexc` pulses, the node stops transmitting / receiving without an error frame and waits for 11
consecutive recessive samples, then IDLE. A queued own frame stays queued.

### 3.7 Errors, intermission, fault confinement

Error detection, error frames, intermission / suspend and fault confinement are as in CAN.md
sections 3.5, 3.7 and 3.8, extended by the XL errors of section 3.3. Bus-off when `tec` would
exceed 255; recovery after 128 runs of 11 recessive samples.

### 3.8 Fault confinement summary

Transmit error: `tec` += 8 (not for a stuff error on an own recessive stuff bit in arbitration,
not for an ACK error while error passive). Receive error: `rec` += 1 (saturating). Own success:
`tec` -= 1. Received valid frame: `rec` -= 1, or `rec` = 120 when it was above 127.

### 3.9 Reset

`txd` = 1, `tx_ready` = 1, all pulses and `rx_*` 0, `tec` = `rec` = 0, IDLE at the nominal rate.
The RX and TX buffer memories are not reset.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `MAX_BYTES` | 64 | multiple of 4, 8..2048 | TX buffer and each RX bank size in bytes; larger XL frames are refused on transmit and truncated on receive |
| `FS` | 10 | 1..15 (CiA 610-1 uses 10; all nodes must agree) | fixed stuff period in the XL data phase |

## 5. Errors and corner cases

- A CAN FD frame on the bus is a protocol exception (`pexc`), not an error.
- An XL frame and a classical base data frame with the same ID cannot be arbitrated apart: they differ first at
  position 14, outside arbitration, which is a bit error for the recessive sender.
- Received XL data beyond MAX_BYTES still counts in the FCRC; the frame is delivered with
  `rx_trunc`.
- The ACK is given by every error-free receiver regardless of the filter.
- Overload frames are not generated.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "BFM frame not seen by the monitor" | every frame the BFM sends is a valid frame on the bus | §3.2, §3.3 |
| "bus never idle" | the bus returns to idle after each scenario | §3.6 |
| "A sent a frame without tx_done" | `tx_done` exactly for each valid own frame | §3.5 |
| "A sent" | the frame on the bus is the queued header and buffer | §3.2, §3.3 |
| "B sent a frame without tx_done" | as above for B | §3.5 |
| "B sent" | as above for B | §3.2, §3.3 |
| "A did not deliver" | a valid frame matching the filter is delivered | §3.6 |
| "A rx_trunc" | `rx_trunc` iff the frame had more than MAX_BYTES bytes | §3.6 |
| "A delivered a frame it should not" | no delivery when the filter does not match or the frame is its own | §3.6 |
| "B did not deliver" | as above for B | §3.6 |
| "B rx_trunc" | as above for B | §3.6 |
| "B delivered a frame it should not" | as above for B | §3.6 |
| "transmit never completed" | a queued frame is eventually sent | §3.5 |
| "reset values" | reset values of the outputs and counters | §3.9 |
| "reset values of the pulses and the received header" | pulses and `rx_*` are 0 after reset | §3.9 |
| "A TEC" | `tec` follows the fault-confinement rules | §3.8 |
| "A REC" | `rec` follows the rules | §3.8 |
| "B TEC" | as above for B | §3.8 |
| "B REC" | as above for B | §3.8 |
| "oversized frame not refused" | an XL frame larger than MAX_BYTES gets `tx_rejected` and is not queued | §3.4 |
| "BFM XL frame not acknowledged" | receivers ACK a good XL frame | §3.6 |
| "BFM should have lost arbitration" | the lower priority ID wins arbitration | §3.5 |
| "BFM frame at the 3rd intermission bit" | a SOF in the 3rd intermission bit is received; a node with a frame joins from ID bit 1 | §3.7 |
| "A did not join the BFM's SOF" | a node with a queued frame hard-synchronised to a SOF transmits along | §3.5 |
| "monitor saw" | FD formats are protocol exceptions without an error frame | §3.6, §5 |
| "stuff error in arbitration: no TEC" | a stuff error on an own recessive stuff bit in arbitration does not raise `tec` | §3.8 |
| "transmitter stuff error after arbitration" | a transmitter stuff error after arbitration: `tec` + 8 | §3.8 |
| "TEC count-down" | each successful own frame: `tec` - 1 | §3.8 |
| "A never became error passive" | `tec` > 127: error passive | §3.8 |
| "TEC moved on passive ACK errors" | ACK errors while error passive leave `tec` | §3.8 |
| "A should still be error passive" | as above | §3.8 |
| "A never went bus-off" | `tec` above 255: bus-off | §3.8 |
| "no bus-off recovery" | recovery after 128 x 11 recessive bits | §3.8 |
| "bus-off recovery before 128 x 11 recessive bits" | ...not earlier | §3.8 |
| "receivers not error passive" | `rec` > 127: error passive | §3.8 |
| "abort while receiving: no tx_aborted" | `tx_abort` while the node receives drops the frame | §3.4 |
| "tx_aborted for a frame that completed" | a frame that completes gives `tx_done`, not `tx_aborted` | §3.4 |
| "abort between retransmissions: no tx_aborted" | an abort during a failed attempt drops the frame after it | §3.4 |
| a_reset_values | reset values | §3.9 |
| a_txd_model | `txd` equals the checker's bit-level model | §3 |
| a_rate_model | `tx_fast` / `rx_fast` as the model | §3.1, §3.3 |
| a_tx_ready_model | `tx_ready` as the model | §3.4 |
| a_tx_done_model | `tx_done` / `tx_aborted` / `tx_rejected` as the model | §3.4, §3.5 |
| a_rx_valid_model | `rx_valid` as the model | §3.6 |
| a_rx_frame_model | delivered header as the model | §3.6 |
| a_rx_bytes_model | RX buffer contents as the model | §3.6 |
| a_arb_lost_model | `arb_lost` as the model | §3.5 |
| a_error_pulses_model | the `err_*` pulses as the model | §3.7 |
| a_pexc_model | `pexc` as the model | §3.6 |
| a_counters_model | `tec`, `rec` as the model | §3.8 |
| a_state_model | `err_passive`, `bus_off` as the model | §3.8 |
| a_bus_off_recessive | `txd` = 1 while bus-off | §3.8 |
