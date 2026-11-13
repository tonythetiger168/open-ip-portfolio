<!-- SPDX-License-Identifier: Apache-2.0 -->
# IO_LINK: design specification

An IO-Link (IEC 61131-9 / SDCI) master port and device data link layer in one core, selected by
`cfg_master`: UART framing, wake-up request, M-sequences with the IO-Link checksum, a 256-byte
message buffer, master reply handling with timeouts, device message checking, reporting and reply
after the response delay. Not implemented: the physical layer (the C/Q transceiver), the master and
device state machines above the data link layer (startup, preoperate, ISDU handling, events),
M-sequence type selection per state, and the timing of COM rate detection. Core `IO_LINK_top`
(`rtl/IO_LINK_top.sv`), testbench `tb/IO_LINK_tb.sv` (a master and a device on one wired-AND line
plus a UART BFM), checker `tb/cov/IO_LINK_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. B = `cfg_bit` clocks (one bit time). Lengths n_pdo, n_pdi, n_od are
the `cfg_*_len` inputs limited to 32.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_master` | input | 1 | 1 master port, 0 device; a change restarts the link layer | - | `clk` | - |
| `cfg_bit` | input | 16 | clocks per UART bit (at least 4) | - | `clk` | - |
| `cfg_wurq` | input | 16 | wake-up request length in clocks (80 us) | - | `clk` | - |
| `cfg_mtype` | input | 2 | M-sequence type sent in CKT (master) / expected (device) | - | `clk` | - |
| `cfg_pdout_len` | input | 6 | PD out octets, 0..32 (more acts as 32) | - | `clk` | - |
| `cfg_pdin_len` | input | 6 | PD in octets, 0..32 | - | `clk` | - |
| `cfg_od_len` | input | 6 | OD octets per message, 0..32 | - | `clk` | - |
| `txd` | output | 1 | line data to the C/Q transceiver (UART level, 1 idle) | - | `clk` | 1 |
| `tx_en` | output | 1 | drive the line; the receiver is off while it is high | high | `clk` | 0 |
| `rxd` | input | 1 | received line; two synchronising flops | - | async | - |
| `host_rd` | input | 1 | read the message buffer at `host_addr` | high | `clk` | - |
| `host_wr` | input | 1 | write `host_wdata` to the message buffer | high | `clk` | - |
| `host_addr` | input | 8 | message buffer address (section 3.1) | - | `clk` | - |
| `host_wdata` | input | 8 | write data | - | `clk` | - |
| `host_rdata` | output | 8 | read data, the clock after `host_rd` | - | `clk` | 0 |
| `cfg_resp_timeout` | input | 8 | master: bit times of silence before a reply timeout | - | `clk` | - |
| `m_wurq` | input | 1 | master: send a wake-up request (taken when idle) | high | `clk` | - |
| `m_start` | input | 1 | master: send the message for `m_mc` (taken when idle) | high | `clk` | - |
| `m_mc` | input | 8 | master: MC octet {R/W (1 read), channel[1:0], address[4:0]} | - | `clk` | - |
| `m_busy` | output | 1 | master: a request is running | high | `clk` | 0 |
| `m_done` | output | 1 | master: one-clock pulse at the end of every request | high | `clk` | 0 |
| `m_err_timeout` | output | 1 | master: the reply timed out (held until the next `m_start`) | high | `clk` | 0 |
| `m_err_uart` | output | 1 | master: parity or framing error in the reply (held) | high | `clk` | 0 |
| `m_err_cks` | output | 1 | master: reply checksum error (held) | high | `clk` | 0 |
| `m_cks` | output | 8 | master: the CKS octet of the last reply | - | `clk` | 0 |
| `m_cnt` | output | 7 | master: reply octets received in the last request | - | `clk` | 0 |
| `cfg_ta` | input | 4 | device: response delay in bit times (1..15, 0 acts as 1) | - | `clk` | - |
| `cfg_event` | input | 1 | device: CKS event flag | - | `clk` | - |
| `cfg_pd_invalid` | input | 1 | device: CKS PD status (1 invalid) | - | `clk` | - |
| `d_wurq` | output | 1 | device: one-clock pulse: a wake-up request was seen | high | `clk` | 0 |
| `d_msg` | output | 1 | device: one-clock pulse: a message ended (good or bad) | high | `clk` | 0 |
| `d_msg_mc` | output | 8 | device: its MC octet | - | `clk` | 0 |
| `d_msg_why` | output | 3 | device: 0 ok, 1 parity / framing, 2 checksum, 3 M-sequence type, 4 gap | - | `clk` | 0 |

### Internal signals used by the verification

The bound checker (`.*`) reads the message buffer; fsm_cov binds `st`. The TB also reads the buffer
of each instance (`u.ram`). Keep these names and encodings.

| Signal | Width | Meaning |
|---|---|---|
| `ram` | 8 x 256 | message buffer, unpacked `[0:255]`; not reset |
| `st` | 3 | 0 IDLE, 1 WURQ, 2 SUM (master checksum pass), 3 TX, 4 RX, 5 TA (device response delay), 6 DROP (device, after an error) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/IO_LINK.md`](../ip/IO_LINK.md) (source: `scripts/apb/specs/IO_LINK.json`); do not edit by hand.

`IO_LINK_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `txd`, `tx_en`, `rxd`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x10C90100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000010 | Role, M-sequence type, device reply |
| 0x018 | TIMING | RW | 0x0FA000D9 | Bit time and wake-up length |
| 0x01C | LENGTHS | RW | 0x00401000 | Octet counts and master reply timeout |
| 0x020 | MC | RW | 0x00000000 | Master: M-sequence control octet |
| 0x024 | MEM_ADDR | RW | 0x00000000 | Message buffer address for CMD.host_rd / host_wr |
| 0x028 | MEM_WDATA | RW | 0x00000000 | Message buffer write data |
| 0x02C | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x030 | MEM_RDATA | RO | core | Message buffer read data |
| 0x034 | M_STATUS | RO | core | Master: result of the last request |
| 0x038 | D_MSG | RO (pop) | 0x00000000 | Device: message report; reading it frees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x03C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x10C9 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `cfg_master` | RW | 0x0 | 1 = master port, 0 = device |
| CTRL | 2:1 | `cfg_mtype` | RW | 0x0 | M-sequence type in CKT (the device answers only this type) |
| CTRL | 6:3 | `cfg_ta` | RW | 0x2 | device: reply delay in bit times after the middle of the last stop bit (0 acts as 1) |
| CTRL | 7 | `cfg_event` | RW | 0x0 | device: CKS event flag |
| CTRL | 8 | `cfg_pd_invalid` | RW | 0x0 | device: CKS PD status (1 = invalid) |
| TIMING | 15:0 | `cfg_bit` | RW | 0xD9 | PCLK cycles per bit, >= 4 (217 = COM3 at 50 MHz) |
| TIMING | 31:16 | `cfg_wurq` | RW | 0xFA0 | PCLK cycles of the wake-up request (80 us at 50 MHz); a device accepts +-1/16 |
| LENGTHS | 5:0 | `cfg_pdout_len` | RW | 0x0 | PD octets master to device, 0..32 |
| LENGTHS | 11:6 | `cfg_pdin_len` | RW | 0x0 | PD octets device to master, 0..32 |
| LENGTHS | 17:12 | `cfg_od_len` | RW | 0x1 | OD octets per message, 0..32 |
| LENGTHS | 25:18 | `cfg_resp_timeout` | RW | 0x10 | master: bit times of silence before a timeout |
| MC | 7:0 | `m_mc` | RW | 0x0 | {R/W (1 read), channel (0 process, 1 page, 2 diagnosis, 3 ISDU), address} |
| MEM_ADDR | 7:0 | `host_addr` | RW | 0x0 | 0x00 tx PD, 0x20 tx OD, 0x40 rx PD, 0x60 rx OD, 0x80 device page |
| MEM_WDATA | 7:0 | `host_wdata` | RW | 0x0 | octet written by CMD.host_wr |
| CMD | 0 | `m_start` | WO (pulse) | 0x0 | 1 = master: send the M-sequence for MC (when M_STATUS.m_busy = 0) |
| CMD | 1 | `m_wurq` | WO (pulse) | 0x0 | 1 = master: send a wake-up request |
| CMD | 2 | `host_wr` | WO (pulse) | 0x0 | 1 = write MEM_WDATA at MEM_ADDR |
| CMD | 3 | `host_rd` | WO (pulse) | 0x0 | 1 = read MEM_ADDR into MEM_RDATA |
| MEM_RDATA | 7:0 | `host_rdata` | RO | core | octet read by CMD.host_rd |
| M_STATUS | 0 | `m_busy` | RO | core | a request is under way |
| M_STATUS | 1 | `m_err_timeout` | RO | core | no reply or a gap in it |
| M_STATUS | 2 | `m_err_uart` | RO | core | parity or framing error in the reply |
| M_STATUS | 3 | `m_err_cks` | RO | core | reply checksum error |
| M_STATUS | 11:4 | `m_cks` | RO | core | CKS octet {event, PD invalid, checksum} |
| M_STATUS | 18:12 | `m_cnt` | RO | core | reply octets received |
| D_MSG | 7:0 | `d_msg_mc` | RO (pop) | 0x0 | MC octet |
| D_MSG | 10:8 | `d_msg_why` | RO (pop) | 0x0 | 0 ok (answered), 1 parity / framing, 2 checksum, 3 M-sequence type, 4 gap |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | M_DONE | master: the request or wake-up ended (M_STATUS) |
| 1 | WURQ | device: wake-up request detected |
| 2 | D_MSG_AVAIL | D_MSG captured a beat |
| 3 | D_MSG_OVF | beat dropped, D_MSG was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | D_MSG_AVAIL | D_MSG holds an unread beat |

### Streams

* **D_MSG** captures `d_msg_mc`, `d_msg_why` when `d_msg` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ D_MSG_AVAIL. Reading D_MSG pops it. A beat that arrives while the register is full is dropped and sets D_MSG_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x10C90100.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), TIMING (0x018), LENGTHS (0x01C), MC (0x020), MEM_ADDR (0x024), MEM_WDATA (0x028). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
5. To issue a command, write 1 to `m_start` (CMD bit 0), `m_wurq` (CMD bit 1), `host_wr` (CMD bit 2), `host_rd` (CMD bit 3) at 0x02C; the core sees a one-clock pulse, and the register reads 0.
6. Read MEM_RDATA (0x030) for the core's live `host_rdata`; it needs no clearing.
7. Read M_STATUS (0x034) for the core's live `m_busy`, `m_err_timeout`, `m_err_uart`, `m_err_cks`, `m_cks`, `m_cnt`; it needs no clearing.
8. To receive on D_MSG: wait for IRQ D_MSG_AVAIL or FLAGS.D_MSG_AVAIL (bit 0), then read D_MSG (0x038). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.D_MSG_AVAIL (bit 2) to clear it. Read each beat before the next arrives, or it is dropped and D_MSG_OVF is set.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Master: CTRL.cfg_master = 1, TIMING, LENGTHS; CMD.m_wurq, then for each cycle write the PD out / OD octets, MC, CMD.m_start; on IRQ M_DONE read M_STATUS and the reply at 0x40 / 0x60.
2. Device: CTRL, TIMING, LENGTHS; keep PD in at 0x00, OD at 0x20 and the page at 0x80; on IRQ D_MSG_AVAIL read D_MSG and the received octets at 0x40 / 0x60.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Message buffer

| Address | Master | Device |
|---|---|---|
| 0x00..0x1F | PD out to send | PD in to send |
| 0x20..0x3F | OD to send (writes) | OD to send (reads of channels other than page) |
| 0x40..0x5F | PD in received | PD out received |
| 0x60..0x7F | OD received (reads) | OD received (writes) |
| 0x80..0x9F | - | parameter page: a page-channel read returns 0x80 + ((address + i) mod 32) |
| 0xA0..0xFF | free | free |

`host_rdata` is registered: the clock after `host_rd` it holds the buffer content before any write
in that clock. A host write to the address the core writes in the same clock is dropped. The buffer
is not reset.

### 3.2 UART

Start bit (0), 8 data bits LSB first, even parity, one stop bit (1); B clocks per bit. Transmit: the
start bit begins at the edge that loads the octet; after the stop bit the transmitter is idle for
two more clocks before the next octet's start bit, so octets of one message follow with almost no
gap. Receive (only while `tx_en` is low, after the two-flop synchroniser): a falling edge starts an
octet; the start bit is sampled after B/2 clocks (a high sample there is a glitch and is ignored),
then each bit every B clocks, the octet completes in the middle of the stop bit. Parity error: odd
parity over data and parity bit. Framing error: stop bit sampled 0. A break octet is 0x00 with a
framing error and good parity.

### 3.3 Wake-up request

Master: `m_wurq` while idle drives `tx_en` = 1, `txd` = 0 for `cfg_wurq` clocks (at least 1), then
releases the line with `m_done` and no error flag (the flags of the last request are kept).

Device: counts the clocks the synchronised line is low while it is not transmitting (saturating at
65535). When the line goes high again after L low clocks with L != 0 and
`cfg_wurq` - floor(`cfg_wurq`/16) <= L <= `cfg_wurq` + floor(`cfg_wurq`/16), `d_wurq` pulses and the
device returns to IDLE (abandoning a message, a response delay or a reply in progress). This check
runs in every device state. The break octet the low pulse causes is dropped without a report.

### 3.4 Master request

`m_start` while idle (and not `m_wurq`): `m_busy`, the result flags, `m_cks` and `m_cnt` clear, and
the message is built for MC = `m_mc`:

1. SUM: one clock per payload octet reading the buffer (n_pdo PD octets from 0x00, then on a write
   n_od OD octets from 0x20) into the checksum; then CKT = {`cfg_mtype`, checksum} (3.6).
2. TX (`tx_en` = 1): MC, CKT, the payload, back to back.
3. RX (`tx_en` = 0): expected reply = n_od OD octets (reads only), n_pdi PD octets, CKS. Each
   octet counts in `m_cnt`; OD goes to 0x60 + i, PD to 0x40 + j. A parity or framing error ends the
   request with `m_err_uart` (no more octets read). The CKS octet ends it: `m_cks` = CKS,
   `m_err_cks` when its checksum fails. Silence of `cfg_resp_timeout` bit times (counted from the
   own last stop bit or the last received octet, with no octet in progress) ends it with
   `m_err_timeout`.

Every request ends with `m_done` (one clock) and `m_busy` low in the same clock. `m_start` and
`m_wurq` while busy are ignored.

### 3.5 Device message

Octet 0 is MC, octet 1 CKT, then n_pdo PD out octets (to 0x40 + k) and, for a write, n_od OD octets
(to 0x60 + j), stored as they arrive. When the last octet arrives the device pulses `d_msg` with
`d_msg_mc` = MC and:

- `d_msg_why` = 3 if CKT[7:6] != `cfg_mtype`;
- else 2 if the checksum fails;
- else 0, and the reply follows (3.6).

Errors during the message: a parity or framing error pulses `d_msg` with why 1 (MC = that octet if
it was the first) and the device enters DROP, ignoring the line until 16 bit times without an octet;
16 bit times without an octet inside a message pulse why 4 and drop the message (15 do not). A
break octet abandons the message silently.

### 3.6 Device reply and checksum

The reply starts when max(`cfg_ta`, 1) bit times passed since the last octet of the message
(counted from the middle of its stop bit): `tx_en` rises, then OD (reads only: n_od octets from the
page for channel 1, else from 0x20), n_pdi PD octets from 0x00, and CKS = {`cfg_event`,
`cfg_pd_invalid`, checksum}. `tx_en` falls after the CKS stop bit.

Checksum: XOR of 0x52 and every octet of the message, the CKT / CKS octet taken with its 6 checksum
bits as 0, compressed to 6 bits: c5 = x7^x5^x3^x1, c4 = x6^x4^x2^x0, c3 = x7^x6, c2 = x5^x4,
c1 = x3^x2, c0 = x1^x0.

### 3.7 Reset and role change

Reset: `txd` = 1, `tx_en` = 0, all pulses, flags and counters 0, `host_rdata` = 0, state IDLE. A
change of `cfg_master` returns to IDLE with `tx_en` = 0 and `m_busy` = 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Error | Master | Device |
|---|---|---|
| parity / framing | `m_err_uart`, request ends | `d_msg` why 1, DROP |
| checksum | `m_err_cks` | why 2, no reply |
| M-sequence type | - | why 3, no reply |
| silence | `m_err_timeout` after `cfg_resp_timeout` bit times | why 4 after 16 bit times inside a message |

Lengths above 32 act as 32. The line is never received while `tx_en` is high, so the own
transmission is not seen.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "M: no m_done" | every master request ends with `m_done` | §3.4 |
| "M: busy with m_done" | `m_busy` falls with `m_done` | §3.4 |
| "start while busy: page octet" | `m_start` while busy is ignored | §3.4 |
| "WURQ: m_done flags" | a wake-up request ends with `m_done` and no error | §3.3 |
| "WURQ not detected" | the device sees the master's wake-up request | §3.3 |
| "WURQ: the break octet was reported" | the break octet it causes is not reported | §3.3 |
| "WURQ: 374 clocks accepted" | with `cfg_wurq` = 400, a 374-clock low pulse is rejected | §3.3 |
| "WURQ: 375 clocks not accepted" | 375 clocks is accepted | §3.3 |
| "WURQ: 425 clocks not accepted" | 425 clocks is accepted | §3.3 |
| "WURQ: 426 clocks accepted" | 426 clocks is rejected | §3.3 |
| "WURQ with cfg_wurq 0" | `cfg_wurq` = 0 never detects | §3.3 |
| "WURQ of 65535 clocks" | the counter covers 65535 clocks | §3.3 |
| "WURQ: saturated counter" | the low-time counter saturates at 65535 | §3.3 |
| "WURQ in tA not detected" | a wake-up request is seen while waiting to answer | §3.3 |
| "WURQ in a message: reported" | a wake-up request inside a message is seen | §3.3 |
| "BFM message not taken" | a well-formed message is reported with why 0 | §3.5 |
| "BFM message stored" | its PD out / OD land in the buffer | §3.5 |
| "checksum error not reported" | why 2 | §3.5 |
| "M-sequence type error not reported" | why 3 | §3.5 |
| "parity error not reported" | why 1 | §3.5 |
| "framing error not reported" | why 1 | §3.5 |
| "gap not reported" | 16 bit times between octets: why 4 | §3.5 |
| "15-bit gap reported" | 15 bit times is no gap | §3.5 |
| "message with gaps: checksum" | short gaps keep the message | §3.5 |
| "octets after an error not dropped" | after an error the device ignores octets until 16 idle bit times | §3.5 |
| "message after the drop time not taken" | the next message after the drop time is taken | §3.5 |
| "message after a start-bit glitch" | a start-bit glitch is ignored | §3.2 |
| "break octet reported" | a break octet is dropped without a report | §3.3 |
| "BFM read not taken" | the master takes a reply from the BFM | §3.4 |
| "BFM reply stored" | the reply lands in the master's buffer | §3.4 |
| "CKS flags" | the CKS event and PD flags | §3.6 |
| "host read" | `host_rdata` the clock after `host_rd` | §3.1 |
| "collision: host write won" | a host write colliding with a received octet is dropped | §3.1 |
| "host read after collision" | the buffer holds the received octet | §3.1 |
| "M host read" | host reads of the master's buffer | §3.1 |
| "outputs in reset" | reset values | §3.7 |
| "first message after reset started" | a request after reset starts within 3 bit times | §3.4 |
| a_tx_en | `tx_en` as the checker's model | §3.3..§3.6 |
| a_txd | `txd` while driving | §3.2..§3.6 |
| a_m_busy | `m_busy` (master) | §3.4 |
| a_m_done | `m_done` | §3.4 |
| a_m_result | `m_err_*` and `m_cnt` with `m_done` | §3.4 |
| a_d_wurq | `d_wurq` | §3.3 |
| a_d_msg | `d_msg` | §3.5 |
| a_d_report | `d_msg_mc` / `d_msg_why` | §3.5 |
| a_core_write | each received octet is stored at its address | §3.4, §3.5 |
| a_host_write | host writes land unless they collide | §3.1 |
| a_host_read | `host_rdata` | §3.1 |
