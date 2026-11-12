<!-- SPDX-License-Identifier: Apache-2.0 -->
# DSI: design specification

A MIPI DSI host transmitter at the packet layer: short and long packets with ECC and CRC-16, DCS
short / long writes, a video-mode line (HSS, HSE, HBP blanking, RGB888 HACT), and a DCS read with
bus turn-around and a peripheral short-packet response. The lane is abstracted to one serial bit
per clock with an ownership flag; LP states, escape mode, multiple lanes and virtual channels
other than 0 are not modelled. Core `DSI_top` (`rtl/DSI_top.sv`), testbench `tb/DSI_tb.sv`,
checker `tb/cov/DSI_sva.sv` (a pin-level cycle model).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Bytes go LSB first; one bit per clock.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one lane bit per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `irq` | output | 1 | one-clock error pulse (section 5) | high | `clk` | 0 |
| `tx_bit` | output | 1 | serial lane bit, LSB first per byte; 1 when idle | - | `clk` | 1 |
| `tx_valid` | output | 1 | `tx_bit` carries a packet or trigger bit | high | `clk` | 0 |
| `tx_oe` | output | 1 | 1 = the host owns the lane; 0 during BTA | high | `clk` | 1 |
| `rx_bit` | input | 1 | peripheral lane bit while `tx_oe` = 0; idle level 1 | - | `clk` | - |
| `cmd_valid` | input | 1 | start a command (taken only when idle) | high | `clk` | - |
| `cmd_op` | input | 3 | command (section 3.2) | - | `clk` | - |
| `cmd_dt` | input | 6 | data type for OP_SPKT | - | `clk` | - |
| `cmd_dcs` | input | 8 | DCS command byte | - | `clk` | - |
| `cmd_len` | input | 16 | OP_SPKT data field; long packet WC (DCS long write, HACT) | - | `clk` | - |
| `cmd_len2` | input | 16 | HBP blanking WC (video line) | - | `clk` | - |
| `cmd_busy` | output | 1 | a command is running | high | `clk` | 0 |
| `pl_we` | input | 1 | payload RAM write | high | `clk` | - |
| `pl_addr` | input | 5 | payload RAM byte address | - | `clk` | - |
| `pl_wdata` | input | 8 | payload RAM byte | - | `clk` | - |
| `bta_done` | output | 1 | one-clock pulse: a BTA response header was received (clean or corrected) | high | `clk` | 0 |
| `bta_data` | output | 24 | response header {data1, data0, DI}, after ECC correction | - | `clk` | 0 |
| `pkt_cnt` | output | 16 | packets sent (wraps) | - | `clk` | 0 |

### Internal signals used by the verification

fsm_cov binds both state machines; keep the names and encodings.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 4 | 0 IDLE, 1 SOT, 2 H0, 3 H1, 4 H2, 5 HE (ECC), 6 PAY, 7 C0, 8 C1, 9 GAP, 10 BTA (trigger), 11 B_WAIT, 12 B_RBIT |
| `rbst` | 3 | BTA response byte: 0 SOT, 1 H0, 2 H1, 3 H2, 4 HE |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/DSI.md`](../ip/DSI.md) (source: `scripts/apb/specs/DSI.json`); do not edit by hand.

`DSI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_bit`, `tx_valid`, `tx_oe`, `rx_bit`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD | RW | 0x00000000 | Command |
| 0x018 | LEN | RW | 0x00000000 | Lengths |
| 0x01C | GO | WO (pulse) | 0x00000000 | Start |
| 0x020 | PL0 | WO (core) | core | payload RAM byte 0 (write only) |
| 0x024 | PL1 | WO (core) | core | payload RAM byte 1 (write only) |
| 0x028 | PL2 | WO (core) | core | payload RAM byte 2 (write only) |
| 0x02C | PL3 | WO (core) | core | payload RAM byte 3 (write only) |
| 0x030 | PL4 | WO (core) | core | payload RAM byte 4 (write only) |
| 0x034 | PL5 | WO (core) | core | payload RAM byte 5 (write only) |
| 0x038 | PL6 | WO (core) | core | payload RAM byte 6 (write only) |
| 0x03C | PL7 | WO (core) | core | payload RAM byte 7 (write only) |
| 0x040 | PL8 | WO (core) | core | payload RAM byte 8 (write only) |
| 0x044 | PL9 | WO (core) | core | payload RAM byte 9 (write only) |
| 0x048 | PL10 | WO (core) | core | payload RAM byte 10 (write only) |
| 0x04C | PL11 | WO (core) | core | payload RAM byte 11 (write only) |
| 0x050 | PL12 | WO (core) | core | payload RAM byte 12 (write only) |
| 0x054 | PL13 | WO (core) | core | payload RAM byte 13 (write only) |
| 0x058 | PL14 | WO (core) | core | payload RAM byte 14 (write only) |
| 0x05C | PL15 | WO (core) | core | payload RAM byte 15 (write only) |
| 0x060 | PL16 | WO (core) | core | payload RAM byte 16 (write only) |
| 0x064 | PL17 | WO (core) | core | payload RAM byte 17 (write only) |
| 0x068 | PL18 | WO (core) | core | payload RAM byte 18 (write only) |
| 0x06C | PL19 | WO (core) | core | payload RAM byte 19 (write only) |
| 0x070 | PL20 | WO (core) | core | payload RAM byte 20 (write only) |
| 0x074 | PL21 | WO (core) | core | payload RAM byte 21 (write only) |
| 0x078 | PL22 | WO (core) | core | payload RAM byte 22 (write only) |
| 0x07C | PL23 | WO (core) | core | payload RAM byte 23 (write only) |
| 0x080 | PL24 | WO (core) | core | payload RAM byte 24 (write only) |
| 0x084 | PL25 | WO (core) | core | payload RAM byte 25 (write only) |
| 0x088 | PL26 | WO (core) | core | payload RAM byte 26 (write only) |
| 0x08C | PL27 | WO (core) | core | payload RAM byte 27 (write only) |
| 0x090 | PL28 | WO (core) | core | payload RAM byte 28 (write only) |
| 0x094 | PL29 | WO (core) | core | payload RAM byte 29 (write only) |
| 0x098 | PL30 | WO (core) | core | payload RAM byte 30 (write only) |
| 0x09C | PL31 | WO (core) | core | payload RAM byte 31 (write only) |
| 0x0A0 | STATUS | RO | core | Host state |
| 0x0A4 | BTA | RO | core | Read response |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x0A8 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4453 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD | 2:0 | `cmd_op` | RW | 0x0 | 0 raw short packet (DT cmd_dt, data LEN), 1 DCS short write without parameter, 2 DCS short write with PL0 as parameter, 3 DCS long write of LEN payload bytes, 4 video line (HSS, HSE, HBP of LEN2 zero bytes, HACT of LEN bytes), 5 DCS read and bus turn-around; 6 and 7 are rejected (ERROR) |
| CMD | 8:3 | `cmd_dt` | RW | 0x0 | data type of a raw short packet |
| CMD | 16:9 | `cmd_dcs` | RW | 0x0 | DCS command byte |
| LEN | 15:0 | `cmd_len` | RW | 0x0 | raw short packet data, long-write length or HACT length (a payload above 32 bytes, or HACT not a multiple of 3, is rejected: ERROR) |
| LEN | 31:16 | `cmd_len2` | RW | 0x0 | HBP blanking length of a video line |
| GO | 0 | `cmd_valid` | WO (pulse) | 0x0 | write 1: run CMD with LEN (ignored while STATUS.busy) |
| PL0 | 7:0 | core register | WO (core) | core | written at core register 0 |
| PL1 | 7:0 | core register | WO (core) | core | written at core register 1 |
| PL2 | 7:0 | core register | WO (core) | core | written at core register 2 |
| PL3 | 7:0 | core register | WO (core) | core | written at core register 3 |
| PL4 | 7:0 | core register | WO (core) | core | written at core register 4 |
| PL5 | 7:0 | core register | WO (core) | core | written at core register 5 |
| PL6 | 7:0 | core register | WO (core) | core | written at core register 6 |
| PL7 | 7:0 | core register | WO (core) | core | written at core register 7 |
| PL8 | 7:0 | core register | WO (core) | core | written at core register 8 |
| PL9 | 7:0 | core register | WO (core) | core | written at core register 9 |
| PL10 | 7:0 | core register | WO (core) | core | written at core register 10 |
| PL11 | 7:0 | core register | WO (core) | core | written at core register 11 |
| PL12 | 7:0 | core register | WO (core) | core | written at core register 12 |
| PL13 | 7:0 | core register | WO (core) | core | written at core register 13 |
| PL14 | 7:0 | core register | WO (core) | core | written at core register 14 |
| PL15 | 7:0 | core register | WO (core) | core | written at core register 15 |
| PL16 | 7:0 | core register | WO (core) | core | written at core register 16 |
| PL17 | 7:0 | core register | WO (core) | core | written at core register 17 |
| PL18 | 7:0 | core register | WO (core) | core | written at core register 18 |
| PL19 | 7:0 | core register | WO (core) | core | written at core register 19 |
| PL20 | 7:0 | core register | WO (core) | core | written at core register 20 |
| PL21 | 7:0 | core register | WO (core) | core | written at core register 21 |
| PL22 | 7:0 | core register | WO (core) | core | written at core register 22 |
| PL23 | 7:0 | core register | WO (core) | core | written at core register 23 |
| PL24 | 7:0 | core register | WO (core) | core | written at core register 24 |
| PL25 | 7:0 | core register | WO (core) | core | written at core register 25 |
| PL26 | 7:0 | core register | WO (core) | core | written at core register 26 |
| PL27 | 7:0 | core register | WO (core) | core | written at core register 27 |
| PL28 | 7:0 | core register | WO (core) | core | written at core register 28 |
| PL29 | 7:0 | core register | WO (core) | core | written at core register 29 |
| PL30 | 7:0 | core register | WO (core) | core | written at core register 30 |
| PL31 | 7:0 | core register | WO (core) | core | written at core register 31 |
| STATUS | 0 | `cmd_busy` | RO | core | a command is running (sending, or waiting for the BTA response) |
| STATUS | 1 | `tx_oe` | RO | core | the host owns the lane (low during the bus turn-around) |
| STATUS | 17:2 | `pkt_cnt` | RO | core | packets sent (wraps) |
| BTA | 23:0 | `bta_data` | RO | core | {data1, data0, DI} of the last accepted response, single-bit errors corrected |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BTA_DONE | a read response was accepted (BTA holds it) |
| 1 | ERROR | a command rejected, an Acknowledge-and-Error-Report response with error bits, no response within BTA_TO (512) clocks, a bad SoT byte or an uncorrectable response header |

### Core register port

The PAYLOAD words reach the core's own register port. A write to one pulses `pl_we` for one clock with `pl_addr` (the core register) and `pl_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. 

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44530200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CMD (0x014), LEN (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `cmd_valid` (GO bit 0) at 0x01C; the core sees a one-clock pulse, and the register reads 0.
6. Access the core's registers through the PAYLOAD words (0x020 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
7. Read STATUS (0x0A0) for the core's live `cmd_busy`, `tx_oe`, `pkt_cnt`; it needs no clearing.
8. Read BTA (0x0A4) for the core's live `bta_data`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Packets

Each packet is: SoT sync byte 0xB8, DI = {2'b00 (VC 0), DT}, data0 / WC low, data1 / WC high, ECC
byte {2'b00, ECC[5:0]}, then for long packets the WC payload bytes and CRC-16 (low byte first).
ECC: the MIPI Hamming code over {data1, data0, DI} (P7 = P6 = 0). CRC-16: reflected polynomial
0x8408, init 0xFFFF, over the payload (an empty payload gives 0xFFFF). Each byte takes 8 clocks
with `tx_valid` high; bytes of a packet are back to back.

### 3.2 Commands

| `cmd_op` | Packets |
|---|---|
| 0 OP_SPKT | short packet DT = `cmd_dt`, data = `cmd_len` (always sent as a short packet) |
| 1 OP_DCS_S0 | short 0x05, data = {0x00, `cmd_dcs`} |
| 2 OP_DCS_S1 | short 0x15, data = {RAM[0], `cmd_dcs`} (RAM[0] taken at acceptance) |
| 3 OP_DCS_L | long 0x39, WC = `cmd_len`, payload RAM[0..WC-1] |
| 4 OP_VLINE | HSS 0x21 (data 0), HSE 0x31 (data 0), HBP 0x19 long with WC = `cmd_len2` zero bytes, HACT 0x3E long with WC = `cmd_len` RAM bytes |
| 5 OP_DCS_RD | short 0x06, data = {0x00, `cmd_dcs`}, then BTA (section 3.3) |
| 6, 7 | rejected |

A command is rejected (one `irq` pulse, nothing sent, `cmd_busy` stays low) when the op is 6 or 7,
an OP_DCS_L has `cmd_len` > 32, or an OP_VLINE has `cmd_len` > 32 or not a multiple of 3. The
long-packet payload is read from the RAM while it is sent.

### 3.3 Bus turn-around

After the read request the host sends the trigger byte 0x84 (8 bits, like a packet byte, without
SoT), then releases the lane: from the clock after the trigger's last bit `tx_valid` = 0 and
`tx_oe` = 0, and `rx_bit` is sampled every clock. The first 0 sampled is bit 0 of the
peripheral's SoT; the next 7 bits complete it, and it must be 0xB8, else `irq` and the command
ends. Then 3 header bytes and an ECC byte (bits 5:0 used). Syndrome 0 or a single-bit error (data
or parity): `bta_data` = the corrected header, `bta_done` pulses, and if DI = 0x02
(acknowledge-and-error-report) with a non-zero error field also `irq`. Any other syndrome: `irq`
only. If `rx_bit` stays 1 for BTA_TO + 1 sampled clocks: `irq` (timeout). In all cases `tx_oe`
returns to 1 and the command ends.

### 3.4 Command flow

In IDLE, `cmd_valid` is checked every clock; an accepted command raises `cmd_busy` in the next
clock and the first SoT bit appears on `tx_bit` one clock later. `cmd_valid` while busy is
ignored. `pkt_cnt` increments as each packet's last bit is sent (16-bit wrap). After a packet
`tx_valid` is low for 2 clocks before the next packet (or the trigger) starts. After the last
packet of a command `cmd_busy` is low from the second of these clocks (after a BTA, from the clock
after it ends).

### 3.5 Reset

IDLE, `tx_bit` = 1, `tx_valid` = 0, `tx_oe` = 1, `cmd_busy` = 0, `pkt_cnt` = 0, `bta_data` = 0,
pulses 0. The payload RAM is not reset.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `BTA_TO` | 512 | >= 1 | BTA response timeout in clocks |

## 5. Errors and corner cases

`irq` (one clock) for: a rejected command, a BTA timeout, a bad response SoT byte, an
uncorrectable response header, and an error report with error bits set. Not checked: the
response data type other than 0x02, the VC field of the response.

- An HBP WC is not limited (zeros are generated).
- A long packet with WC 0 sends its header and CRC 0xFFFF.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "DCS long write header" | DT 0x39, WC, ECC | §3.1, §3.2 |
| "DCS long write payload" | RAM bytes then CRC-16 | §3.1 |
| "HSS header" | video line packet 1: HSS short packet | §3.2 |
| "HSE header" | packet 2: HSE | §3.2 |
| "HBP header" | packet 3: HBP long, WC = `cmd_len2` | §3.2 |
| "HBP blanking payload" | zero payload and its CRC | §3.2 |
| "HACT header" | packet 4: HACT 0x3E, WC = `cmd_len` | §3.2 |
| "HACT payload" | RAM payload and CRC | §3.2 |
| "DCS read header" | DT 0x06 with the DCS byte | §3.2 |
| "BTA trigger byte" | 0x84 after the read request | §3.3 |
| "lane released for BTA" | `tx_oe` = 0 after the trigger | §3.3 |
| "BTA response accepted" | a good response gives `bta_done` | §3.3 |
| "BTA response data" | `bta_data` is the (corrected) header | §3.3 |
| "BTA irq only for an error report" | `irq` only for ACK-and-error-report with error bits | §3.3 |
| "uncorrectable BTA response -> irq" | two-bit errors: `irq`, no `bta_done` | §3.3 |
| "lane back to the host" | `tx_oe` = 1 after the response | §3.3 |
| "reset state" | reset values | §3.5 |
| "S1 used ram[0] before the write" | DCS short write 1 takes RAM byte 0 at acceptance | §3.2 |
| "rejected commands send nothing" | invalid op / payload too long / HACT not whole pixels: `irq`, nothing sent | §3.2 |
| "first command sent" | a command accepted when idle | §3.4 |
| "second command dropped while busy" | `cmd_valid` while busy is ignored | §3.4 |
| "bad BTA SoT -> irq" | response sync byte != 0xB8 | §3.3 |
| "bad BTA SoT bit 7 -> irq" | all 8 sync bits compared | §3.3 |
| "still waiting for the response" | no timeout before BTA_TO | §3.3 |
| "BTA timeout -> irq" | no SoT within BTA_TO + 1 clocks | §3.3 |
| "pkt_cnt wrapped" | 16-bit wrap | §3.4 |
| "reset mid-packet" | reset stops a packet at once | §3.5 |
| "reset mid-BTA" | reset during BTA returns the lane | §3.5 |
| a_reset_outputs | reset values | §3.5 |
| a_tx_bit | `tx_bit` equals the checker's model | §3.1 |
| a_tx_valid | `tx_valid` as the model | §3.4 |
| a_tx_oe | `tx_oe` as the model | §3.3 |
| a_cmd_busy | `cmd_busy` as the model | §3.4 |
| a_irq | `irq` as the model | §5 |
| a_bta_done | `bta_done` as the model | §3.3 |
| a_bta_data | `bta_data` as the model | §3.3 |
| a_pkt_cnt | `pkt_cnt` as the model | §3.4 |
| a_valid_only_when_owned | `tx_valid` only while `tx_oe` | §3.3 |
| a_rejected_command_stays_idle | a rejected command leaves `cmd_busy` low | §3.2 |
