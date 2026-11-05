# CAN XL protocol controller: CAN XL frames up to 2048 bytes (data-phase bit rate, fixed stuffing, PCRC / FCRC) plus classical CAN 2.0A/B frames

Protocol IP `CAN_XL`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `CAN_XL_top` (`rtl/CAN_XL_top.sv`) |
| Register interface | APB4 slave `CAN_XL_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x584C0100 (code 0x584C, version 1.0) |
| Registers | 33 words, 0x000 to 0x080 |
| Interrupts | 13 sources into one level-high `irq` |
| Core register port | BUF (16 words) |
| Protocol pins | 4 pass-through |

## Overview

CAN XL protocol controller (CAN XL frames + classical CAN 2.0A/B frames) Classical frames (CC) work as in CAN_top: base and extended IDs, data and remote frames, DLC 0..15 (at most 8 bytes), dynamic bit stuffing from SOF to the end of the CRC, CRC-15, ACK, EOF, error frames and fault confinement (TEC / REC, error passive, bus-off and its recovery). XL frames (base priority ID, FDF = XLF = 1), de-stuffed bit index from SOF: 0 SOF   1..11 priority ID   12 RRS (0)   13 IDE (0)   14 FDF (1) 15 XLF (1)   16 resXL (0)   17 ADH (1)   18 DH1 (1)   19 DH2 (1) 20 DL1 (0)   21..28 SDT   29 SEC   30..40 DLC (data bytes - 1) 41..43 SBC   44..56 PCRC   57..64 VCID   65..96 AF   97.. data (DLC + 1 bytes, MSB first), FCRC (32), FCP (1100), DAH (1), ACK slot, ACK delimiter, EOF (7)

- Dynamic stuffing (a complement after five equal bits) up to ADH (the
last one can fall before FDF); SBC = the stuff count mod 4, Gray coded, and
its even parity. Fixed stuffing from DL1 to the last FCRC bit: after
every FS bits one stuff bit, the complement of the bit before.
- PCRC (x^13+x^12+x^11+x^8+x^7+x^6+x^5+x^2+x+1) over SOF..SBC with the
dynamic stuff bits; FCRC (x^32+x^31+x^30+x^29+x^28+x^26+x^23+x^21+
x^19+x^18+x^15+x^14+x^13+x^12+x^11+x^9+x^8+x^4+x+1) over SOF..data
(PCRC included) without stuff bits; both start at 0. An SBC or PCRC
mismatch is a CRC error signalled right after the PCRC (the length may
be wrong); an FCRC mismatch is signalled after the ACK delimiter.
- Data phase: DH1 up to the last FCP bit run at the data bit rate
(cfg_d*); tx_fast / rx_fast tell the transceiver (FAST TX / FAST RX
mode). An error in the data phase returns to the nominal rate at the
next bit.
- A frame with FDF set and XLF clear (CAN FD) or an extended frame with
r1 recessive is a protocol exception: the node waits for 11 recessive
bits (pexc pulses), without an error frame.
- Buffers: a TX buffer and a double-buffered RX buffer of MAX_BYTES bytes
(32-bit host port: hb_wen / hb_waddr / hb_wdata write the TX buffer,
hb_raddr reads hb_rdata from the last delivered frame). A frame is
queued with tx_valid; a frame longer than the buffer is refused
(tx_rejected). Received bytes past the buffer are dropped (rx_trunc).
- Bit timing as CAN_top for each rate: tq = brp + 1 clocks, bit = 1 +
(tseg1 + 1) + (tseg2 + 1) tq, sample at the end of TSEG1, SJW = sjw + 1.
The bus input has two synchroniser flops and resynchronisation acts a
clock after the edge: each rate needs (tseg1 + 1) * (brp + 1) >= 3
clocks (a transmitter samples its own bit) and (tseg2 + 1) * (brp + 1)
>= 2 clocks (a receiver samples about 3 clocks behind the bus).
Not implemented: transmitter delay compensation (the data-phase sample
point is the plain one), PWM coding, CAN FD frames, overload frames,
CANsec, and the error-signalling switch-off option. The XL field layout
follows the public CiA 610-1 descriptions; bit-exact conformance with
ISO 11898-1:2024 is not claimed.

Features:

- CAN XL frames (priority ID, SDT, SEC, VCID, AF, 1..2048 data bytes) and classical CAN 2.0A/B frames on one controller
- Separate nominal and data-phase bit timing; tx_fast / rx_fast tell the transceiver when the data phase runs
- Dynamic stuffing in the arbitration field, fixed stuffing (every FS bits) in the data phase, SBC, PCRC-13 and FCRC-32
- Error frames, TEC / REC, error passive, bus-off and recovery; CAN FD frames are protocol exceptions
- TX buffer and double-banked RX buffer of MAX_BYTES bytes behind a 32-bit word port

The wrapper uses the core's default MAX_BYTES = 64 (16 BUF words); a larger buffer adds BUF words.
RX_ID / RX_CTRL / RX_AF and the BUF read side show the last delivered frame and change when the next one is delivered (IRQ RX): read them before then.
Write the TX buffer and header, then CMD.tx_valid; do not change the TX buffer while STATUS.tx_ready is 0.
The XL field layout follows the public CiA 610-1 descriptions; bit-exact conformance with ISO 11898-1:2024 is not claimed. No transmitter delay compensation, PWM coding, CAN FD frames, overload frames or CANsec.

## Files

| File | Content |
|---|---|
| `rtl/CAN_XL_top.sv` | protocol core |
| `rtl/CAN_XL_apb.sv` | APB4 register wrapper (generated) |
| `tb/CAN_XL_tb.sv` | core testbench |
| `tb/CAN_XL_apb_tb.sv`, `tb/apb/CAN_XL_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CAN_XL_sva.sv`, `tb/cov/CAN_XL_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CAN_XL.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`CAN_XL_apb` has the core's parameters and passes them to `CAN_XL_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `MAX_BYTES` | int | `64` |
| `FS` | int | `10` |
| `BW` | int | `$clog2(MAX_BYTES)` |
| `WW` | int | `BW - 2` |

## Wrapper pins

Pins of `CAN_XL_apb`. Widths of the pass-through pins are at the default parameters.

| Pin | Dir | Width | Description |
|---|---|---|---|
| `PCLK` | input | 1 | APB clock; also the core clock |
| `PRESETN` | input | 1 | APB reset, active low; also the core reset |
| `PSEL` | input | 1 | slave select |
| `PENABLE` | input | 1 | access phase |
| `PWRITE` | input | 1 | 1 = write, 0 = read |
| `PADDR` | input | 12 | byte address; bits [1:0] must be 0 |
| `PWDATA` | input | 32 | write data |
| `PSTRB` | input | 4 | write byte strobes |
| `PRDATA` | output | 32 | read data |
| `PREADY` | output | 1 | always high in the access phase (no wait states) |
| `PSLVERR` | output | 1 | error: unmapped or misaligned address, or partial write to a core register word |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `rxd` | input | 1 | protocol pin, core port `rxd` |
| `txd` | output | 1 | protocol pin, core port `txd` |
| `tx_fast` | output | 1 | protocol pin, core port `tx_fast` |
| `rx_fast` | output | 1 | protocol pin, core port `rx_fast` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rxd` | input | 1 | pin (pass-through) |
| `txd` | output | 1 | pin (pass-through) |
| `tx_fast` | output | 1 | pin (pass-through) |
| `rx_fast` | output | 1 | pin (pass-through) |
| `cfg_brp` | input | 6 | NBTR[5:0] |
| `cfg_tseg1` | input | 4 | NBTR[9:6] |
| `cfg_tseg2` | input | 3 | NBTR[12:10] |
| `cfg_sjw` | input | 2 | NBTR[14:13] |
| `cfg_dbrp` | input | 6 | DBTR[5:0] |
| `cfg_dtseg1` | input | 4 | DBTR[9:6] |
| `cfg_dtseg2` | input | 3 | DBTR[12:10] |
| `cfg_dsjw` | input | 2 | DBTR[14:13] |
| `acc_code` | input | 29 | ACC_CODE[28:0] |
| `acc_mask` | input | 29 | ACC_MASK[28:0] |
| `hb_wen` | input | 1 | write to a BUF word |
| `hb_waddr` | input | 4 | BUF word index |
| `hb_wdata` | input | 32 | BUF write data |
| `hb_raddr` | input | 4 | BUF word index |
| `hb_rdata` | output | 32 | BUF read data |
| `tx_valid` | input | 1 | CMD[0:0] |
| `tx_ready` | output | 1 | STATUS[0:0] |
| `tx_xl` | input | 1 | TX_ID[31:31] |
| `tx_id` | input | 29 | TX_ID[28:0] |
| `tx_ide` | input | 1 | TX_ID[29:29] |
| `tx_rtr` | input | 1 | TX_ID[30:30] |
| `tx_dlc` | input | 11 | TX_CTRL[10:0] |
| `tx_sdt` | input | 8 | TX_CTRL[18:11] |
| `tx_sec` | input | 1 | TX_CTRL[19:19] |
| `tx_vcid` | input | 8 | TX_CTRL[27:20] |
| `tx_af` | input | 32 | TX_AF[31:0] |
| `tx_abort` | input | 1 | CMD[1:1] |
| `tx_done` | output | 1 | IRQ_STATUS.SENT |
| `tx_aborted` | output | 1 | IRQ_STATUS.ABORTED |
| `tx_rejected` | output | 1 | IRQ_STATUS.REFUSED |
| `rx_valid` | output | 1 | IRQ_STATUS.RX |
| `rx_xl` | output | 1 | RX_ID[31:31] |
| `rx_id` | output | 29 | RX_ID[28:0] |
| `rx_ide` | output | 1 | RX_ID[29:29] |
| `rx_rtr` | output | 1 | RX_ID[30:30] |
| `rx_dlc` | output | 11 | RX_CTRL[10:0] |
| `rx_sdt` | output | 8 | RX_CTRL[18:11] |
| `rx_sec` | output | 1 | RX_CTRL[19:19] |
| `rx_vcid` | output | 8 | RX_CTRL[27:20] |
| `rx_af` | output | 32 | RX_AF[31:0] |
| `rx_trunc` | output | 1 | RX_CTRL[28:28] |
| `arb_lost` | output | 1 | IRQ_STATUS.ARB_LOST |
| `err_bit` | output | 1 | IRQ_STATUS.ERR_BIT |
| `err_stuff` | output | 1 | IRQ_STATUS.ERR_STUFF |
| `err_crc` | output | 1 | IRQ_STATUS.ERR_CRC |
| `err_form` | output | 1 | IRQ_STATUS.ERR_FORM |
| `err_ack` | output | 1 | IRQ_STATUS.ERR_ACK |
| `pexc` | output | 1 | IRQ_STATUS.PEXC |
| `tec` | output | 9 | STATUS[9:1] |
| `rec` | output | 8 | STATUS[17:10] |
| `err_passive` | output | 1 | STATUS[18:18], IRQ_STATUS.ERR_PASSIVE |
| `bus_off` | output | 1 | STATUS[19:19], IRQ_STATUS.BUS_OFF |

## APB wrapper

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

## Programming sequence

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

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.CAN_XL sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.CAN_XL syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/CAN_XL_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.CAN_XL apb` | `TEST PASSED: CAN_XL_apb`, then Yosys without `ERROR` | console, `work/CAN_XL_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh CAN_XL`<br>`bash scripts/cov/run_cov.sh CAN_XL_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/CAN_XL/score.json`, `work/cov/CAN_XL_apb/score.json` |

Expected end of a step 4 run:

```
===== CAN_XL =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/CAN_XL_tb.sv`): drives `CAN_XL_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/CAN_XL_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/CAN_XL_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/CAN_XL_sva.sv`, `tb/cov/CAN_XL_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CAN_XL_top.sv` | not run | | | | | |
| wrapper `rtl/CAN_XL_apb.sv` | not run | | | | | |
