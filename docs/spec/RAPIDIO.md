<!-- SPDX-License-Identifier: Apache-2.0 -->
# RAPIDIO: design specification

A RapidIO logical / transport layer endpoint over a packet octet stream with LP-Serial CRC-16:
target for NREAD, NWRITE, NWRITE_R, SWRITE (a 1 KB memory), MAINTENANCE (CARs and CSRs) and
DOORBELL, initiator for DOORBELL. Not implemented: the physical layer (control symbols, ackID
tracking, retry), message passing, atomics, flow control, request timeouts, 34 / 50 / 66-bit
addressing. Core `RAPIDIO_top` (`rtl/RAPIDIO_top.sv`), testbench `tb/RAPIDIO_tb.sv` (a packet
builder and a golden model of the endpoint), checker `tb/cov/RAPIDIO_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Octet numbers count from 0 at the first octet of a packet.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rx_valid` | input | 1 | a received packet octet | high | `clk` | - |
| `rx_data` | input | 8 | packet octet, the first octet of the packet first | - | `clk` | - |
| `rx_last` | input | 1 | last octet of the packet | high | `clk` | - |
| `tx_valid` | output | 1 | a transmitted packet octet (no back-pressure); combinational from the state | high | comb | 0 |
| `tx_data` | output | 8 | transmitted octet | - | comb | 0 |
| `tx_last` | output | 1 | last octet of the transmitted packet | high | comb | 0 |
| `cfg_dev_id_car` | input | 32 | device identity CAR (maintenance offset 0x00) | - | `clk` | - |
| `cfg_dev_info_car` | input | 32 | device information CAR (0x04) | - | `clk` | - |
| `cfg_asm_id_car` | input | 32 | assembly identity CAR (0x08) | - | `clk` | - |
| `cfg_asm_info_car` | input | 32 | assembly information CAR (0x0C) | - | `clk` | - |
| `cfg_pe_feat_car` | input | 32 | processing element features CAR (0x10) | - | `clk` | - |
| `cfg_base_id` | input | 24 | base device ID to load: [23:16] 8-bit ID, [15:0] 16-bit ID | - | `clk` | - |
| `id_load` | input | 1 | load `cfg_base_id` into the base device ID CSR | high | `clk` | - |
| `base_id` | output | 24 | base device ID CSR | - | `clk` | 0 |
| `host_rd` | input | 1 | read the 1 KB memory at `host_addr` | high | `clk` | - |
| `host_wr` | input | 1 | write `host_wdata` | high | `clk` | - |
| `host_addr` | input | 10 | memory octet address | - | `clk` | - |
| `host_wdata` | input | 8 | write data | - | `clk` | - |
| `host_rdata` | output | 8 | read data, the clock after `host_rd` | - | `clk` | 0 |
| `ob_start` | input | 1 | send a DOORBELL (taken when idle and not receiving) | high | `clk` | - |
| `ob_tt` | input | 1 | its transport size: 0 8-bit IDs, 1 16-bit IDs | - | `clk` | - |
| `ob_dest` | input | 16 | its destination ID | - | `clk` | - |
| `ob_tid` | input | 8 | its transaction ID | - | `clk` | - |
| `ob_info` | input | 16 | its info field | - | `clk` | - |
| `ob_busy` | output | 1 | our doorbell is waiting for its response | high | `clk` | 0 |
| `ob_done` | output | 1 | one-clock pulse: the response arrived | high | `clk` | 0 |
| `ob_status` | output | 4 | status of that response | - | `clk` | 0 |
| `db_valid` | output | 1 | one-clock pulse: a DOORBELL was received | high | `clk` | 0 |
| `db_src` | output | 16 | its source ID | - | `clk` | 0 |
| `db_tid` | output | 8 | its TID | - | `clk` | 0 |
| `db_info` | output | 16 | its info | - | `clk` | 0 |
| `rx_rep` | output | 1 | one-clock pulse: a received packet ended | high | `clk` | 0 |
| `rx_why` | output | 3 | its outcome (section 5) | - | `clk` | 0 |
| `rx_ftype` | output | 4 | its ftype (0 for a dropped packet) | - | `clk` | 0 |
| `busy` | output | 1 | executing a packet or sending one; packets arriving now are dropped; combinational | high | comb | 0 |

### Internal signals used by the verification

The bound checker (`.*`) connects the engine's memory write port to model host-write collisions;
fsm_cov binds the engine state. Keep these names and encodings.

| Signal | Width | Meaning |
|---|---|---|
| `e_we` | 1 | the engine writes the memory this clock (state WR) |
| `e_wa` | 10 | the octet address it writes |
| `es` | 3 | 0 IDLE, 1 RX (receiving), 2 CHK (checking / deciding), 3 WR (writing memory), 4 TX (sending) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/RAPIDIO.md`](../ip/RAPIDIO.md) (source: `scripts/apb/specs/RAPIDIO.json`); do not edit by hand.

`RAPIDIO_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_valid`, `rx_data`, `rx_last`, `tx_valid`, `tx_data`, `tx_last`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x52490100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | DEV_ID_CAR | RW | 0x00000000 | Device identity CAR (maintenance offset 0x00) |
| 0x018 | DEV_INFO_CAR | RW | 0x00000000 | Device information CAR (0x04) |
| 0x01C | ASM_ID_CAR | RW | 0x00000000 | Assembly identity CAR (0x08) |
| 0x020 | ASM_INFO_CAR | RW | 0x00000000 | Assembly information CAR (0x0C) |
| 0x024 | PE_FEAT_CAR | RW | 0x00000000 | Processing element features CAR (0x10) |
| 0x028 | BASE_ID_CFG | RW | 0x00000000 | Base device ID loaded by CMD.id_load |
| 0x02C | MEM_ADDR | RW | 0x00000000 | Memory address for CMD.host_rd / host_wr |
| 0x030 | MEM_WDATA | RW | 0x00000000 | Memory write data |
| 0x034 | OB_CTRL | RW | 0x00000000 | Outbound doorbell header |
| 0x038 | OB_INFO | RW | 0x00000000 | Outbound doorbell information |
| 0x03C | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x040 | MEM_RDATA | RO | core | Memory read data |
| 0x044 | BASE_ID | RO | core | Base device ID CSR (maintenance offset 0x60) |
| 0x048 | STATUS | RO | core | Endpoint state |
| 0x04C | RX_REP | RO (pop) | 0x00000000 | Received packet report, one per packet; reading it frees it |
| 0x050 | DOORBELL0 | RO (pop) | 0x00000000 | Received doorbell; reading the last word frees it |
| 0x054 | DOORBELL1 | RO (pop) | 0x00000000 | Received doorbell; reading the last word frees it |
| 0x058 | OB_DONE | RO (pop) | 0x00000000 | Our doorbell's response; reading it frees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x05C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5249 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 5:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 5:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 2:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| DEV_ID_CAR | 31:0 | `cfg_dev_id_car` | RW | 0x0 | {device ID, vendor ID} |
| DEV_INFO_CAR | 31:0 | `cfg_dev_info_car` | RW | 0x0 | device revision |
| ASM_ID_CAR | 31:0 | `cfg_asm_id_car` | RW | 0x0 | {assembly ID, assembly vendor ID} |
| ASM_INFO_CAR | 31:0 | `cfg_asm_info_car` | RW | 0x0 | {assembly revision, extended features pointer} |
| PE_FEAT_CAR | 31:0 | `cfg_pe_feat_car` | RW | 0x0 | processing element features |
| BASE_ID_CFG | 23:0 | `cfg_base_id` | RW | 0x0 | {8-bit device ID, 16-bit device ID} |
| MEM_ADDR | 9:0 | `host_addr` | RW | 0x0 | octet address 0x000..0x3FF |
| MEM_WDATA | 7:0 | `host_wdata` | RW | 0x0 | octet written by CMD.host_wr |
| OB_CTRL | 15:0 | `ob_dest` | RW | 0x0 | destination ID (tt 0: [7:0]) |
| OB_CTRL | 23:16 | `ob_tid` | RW | 0x0 | transaction ID |
| OB_CTRL | 24 | `ob_tt` | RW | 0x0 | 0 = 8-bit IDs, 1 = 16-bit IDs |
| OB_INFO | 15:0 | `ob_info` | RW | 0x0 | 16-bit doorbell information |
| CMD | 0 | `id_load` | WO (pulse) | 0x0 | 1 = base device ID CSR <= BASE_ID_CFG |
| CMD | 1 | `host_wr` | WO (pulse) | 0x0 | 1 = write MEM_WDATA at MEM_ADDR (dropped if a packet writes the same octet in that clock) |
| CMD | 2 | `host_rd` | WO (pulse) | 0x0 | 1 = read MEM_ADDR into MEM_RDATA |
| CMD | 3 | `ob_start` | WO (pulse) | 0x0 | 1 = send the doorbell (when STATUS.ob_busy = 0 and the endpoint is idle) |
| MEM_RDATA | 7:0 | `host_rdata` | RO | core | octet read by CMD.host_rd |
| BASE_ID | 23:0 | `base_id` | RO | core | {8-bit device ID, 16-bit device ID} |
| STATUS | 0 | `ob_busy` | RO | core | our doorbell is waiting for its response |
| STATUS | 1 | `busy` | RO | core | a packet is being executed or sent (new packets are dropped) |
| RX_REP | 2:0 | `rx_why` | RO (pop) | 0x0 | 0 executed, 1 CRC error, 2 not for this endpoint, 3 malformed, 4 unsupported, 5 request error (ERROR response), 6 dropped (busy), 7 unexpected response |
| RX_REP | 6:3 | `rx_ftype` | RO (pop) | 0x0 | ftype of the packet (0 when dropped) |
| DOORBELL0 | 15:0 | `db_info` | RO (pop) | 0x0 | doorbell information |
| DOORBELL0 | 23:16 | `db_tid` | RO (pop) | 0x0 | transaction ID |
| DOORBELL1 | 15:0 | `db_src` | RO (pop) | 0x0 | source ID |
| OB_DONE | 3:0 | `ob_status` | RO (pop) | 0x0 | response status (0 DONE, 7 ERROR, others as received) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RX_REP_AVAIL | RX_REP captured a beat |
| 1 | RX_REP_OVF | beat dropped, RX_REP was full |
| 2 | DOORBELL_AVAIL | DOORBELL captured a beat |
| 3 | DOORBELL_OVF | beat dropped, DOORBELL was full |
| 4 | OB_DONE_AVAIL | OB_DONE captured a beat |
| 5 | OB_DONE_OVF | beat dropped, OB_DONE was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | RX_REP_AVAIL | RX_REP holds an unread beat |
| 1 | DOORBELL_AVAIL | DOORBELL holds an unread beat |
| 2 | OB_DONE_AVAIL | OB_DONE holds an unread beat |

### Streams

* **RX_REP** captures `rx_why`, `rx_ftype` when `rx_rep` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_REP_AVAIL. Reading RX_REP pops it. A beat that arrives while the register is full is dropped and sets RX_REP_OVF.
* **DOORBELL** captures `db_info`, `db_tid`, `db_src` when `db_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ DOORBELL_AVAIL. Reading DOORBELL1 pops it. A beat that arrives while the register is full is dropped and sets DOORBELL_OVF.
* **OB_DONE** captures `ob_status` when `ob_done` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ OB_DONE_AVAIL. Reading OB_DONE pops it. A beat that arrives while the register is full is dropped and sets OB_DONE_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x52490100.
2. Write 0x3F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write DEV_ID_CAR (0x014), DEV_INFO_CAR (0x018), ASM_ID_CAR (0x01C), ASM_INFO_CAR (0x020), PE_FEAT_CAR (0x024), BASE_ID_CFG (0x028), MEM_ADDR (0x02C), MEM_WDATA (0x030), OB_CTRL (0x034), OB_INFO (0x038). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3F enables all).
5. To issue a command, write 1 to `id_load` (CMD bit 0), `host_wr` (CMD bit 1), `host_rd` (CMD bit 2), `ob_start` (CMD bit 3) at 0x03C; the core sees a one-clock pulse, and the register reads 0.
6. Read MEM_RDATA (0x040) for the core's live `host_rdata`; it needs no clearing.
7. Read BASE_ID (0x044) for the core's live `base_id`; it needs no clearing.
8. Read STATUS (0x048) for the core's live `ob_busy`, `busy`; it needs no clearing.
9. To receive on RX_REP: wait for IRQ RX_REP_AVAIL or FLAGS.RX_REP_AVAIL (bit 0), then read RX_REP (0x04C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_REP_AVAIL (bit 0) to clear it. Read each beat before the next arrives, or it is dropped and RX_REP_OVF is set.
10. To receive on DOORBELL: wait for IRQ DOORBELL_AVAIL or FLAGS.DOORBELL_AVAIL (bit 1), then read DOORBELL0 (0x050) then DOORBELL1 (0x054). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.DOORBELL_AVAIL (bit 2) to clear it. Read each beat before the next arrives, or it is dropped and DOORBELL_OVF is set.
11. To receive on OB_DONE: wait for IRQ OB_DONE_AVAIL or FLAGS.OB_DONE_AVAIL (bit 2), then read OB_DONE (0x058). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.OB_DONE_AVAIL (bit 4) to clear it. Read each beat before the next arrives, or it is dropped and OB_DONE_OVF is set.
12. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Set the CARs, write BASE_ID_CFG and pulse CMD.id_load; preload memory with MEM_ADDR / MEM_WDATA / CMD.host_wr.
2. Read RX_REP for each received packet and DOORBELL for each doorbell; send a doorbell with OB_CTRL / OB_INFO / CMD.ob_start and read OB_DONE for its response.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Packet flow

Octets are taken while IDLE or RX into a 511-octet buffer. The clock after the last octet the
engine is in CHK: it checks and decodes the packet, pulses `rx_rep` with `rx_why` / `rx_ftype` (and
`db_*` / `ob_done` when they apply) and goes to TX (a response), WR (a write) or IDLE. `busy` = CHK,
WR or TX. A packet whose octets arrive while busy is dropped to its last octet and reported with
why 6 (and `rx_ftype` 0) in the clock after that last octet.

### 3.2 Packet format and CRC

Octet 0 {ackID[4:0], rsvd[2:0]}, octet 1 {prio[1:0], tt[1:0], ftype[3:0]}, transport (tt 0:
dest, src as 8-bit IDs; tt 1: 16-bit IDs), logical header, payload, CRC-16, pad. CRC-16:
x^16 + x^12 + x^5 + 1 (0x1021), seed 0xFFFF, MSB first, with the first 6 bits of the packet taken as
0. A packet whose content (everything before the CRCs) is longer than 80 octets carries an early
CRC after octet 79 (over octets 0..79); the final CRC covers everything before it, early CRC
included. The packet is padded with two zero octets when needed to a multiple of 4 octets.

Receive: the total length must be a multiple of 4 (more than 511 octets fails this), tt must be 0
or 1, and 84 octets is not a legal length. The receiver accepts the packet with or without the 2
pad octets, whichever gives a good CRC and a legal structure.

Transmit: one octet per clock from the clock TX is entered, `tx_valid` high throughout, ackID 0,
content then early CRC (when the content passes 80 octets), final CRC, pad; `tx_last` on the last
octet.

### 3.3 Requests

A request is for this endpoint when its dest ID equals the base ID of its size (tt 0:
`base_id[23:16]`, tt 1: `base_id[15:0]`) and, for MAINTENANCE, the hop count is 0.

| ftype / ttype | Request | Response |
|---|---|---|
| 2 / 4 | NREAD | ftype 13, ttype 8 (with data), whole double-words |
| 5 / 4 | NWRITE | none |
| 5 / 5 | NWRITE_R | ftype 13, ttype 0 |
| 6 | SWRITE | none |
| 8 / 0, 1 | MAINTENANCE read / write of one 32-bit word (size 0b1000) | ftype 8, ttype 2 / 3, read data in the wdptr lane of 8 octets |
| 10 | DOORBELL | ftype 13, ttype 0, DONE; `db_*` pulse |

Responses go to the request's source ID from this endpoint's ID, same tt, priority prio + 1
(capped at 3), with the request's TID; status DONE (0) or ERROR (7). The maintenance response
header carries hop count 0xFF and a zero offset.

Memory requests: 1 KB at addresses 0x000..0x3FF. NREAD / NWRITE: double-word address {29 bits,
wdptr, xamsbs[1:0]}; rdsize / wrsize with wdptr per the RapidIO size table (sizes 0..10 select
octet lanes inside one double-word, 11..15 multiples up to 256 octets; some sizes are reserved for
writes). A write may carry fewer double-words than its size (sub-double-word sizes need exactly 8
payload octets). SWRITE: address {29 bits, reserved, xamsbs}, payload of whole double-words.
ERROR: address outside the memory, xamsbs != 0, a reserved size, an over-long write payload, or an
unsupported ttype of ftype 2 / 5 / 8.

### 3.4 Writes

A write copies the payload octets (or the selected lanes) into the memory one octet per clock in WR,
skipping a received early CRC; NWRITE_R then sends its response.

### 3.5 Doorbells in

A DOORBELL for this endpoint pulses `db_valid` with `db_src`, `db_tid`, `db_info` in the CHK clock's
report and is answered DONE.

### 3.6 CSRs (maintenance)

| Offset | Register | Write |
|---|---|---|
| 0x00 .. 0x10 | the five CAR inputs | ignored |
| 0x60 | base device ID CSR {8'b0, `base_id`} | loads `base_id` |
| 0x68 | host base device ID lock CSR | when 0xFFFF it takes the written ID; writing the holder's ID clears it to 0xFFFF |
| 0x6C | component tag CSR | written |
| other | 0 | ignored |

`id_load` loads `cfg_base_id`; a maintenance write of 0x60 in the same clock wins.

### 3.7 Doorbells out

`ob_start` in IDLE with `ob_busy` low and no `rx_valid` that clock sends a DOORBELL (priority 0,
`ob_tt`, `ob_dest`, source `base_id` of that size, TID `ob_tid`, info `ob_info`) and sets `ob_busy`.
A RESPONSE (ftype 13, ttype 0) for this endpoint with the same tt, TID and source = our destination
ends it: why 0, `ob_done` with `ob_status` = its status, `ob_busy` low. Any other response is why 7.
There is no timeout.

### 3.8 Host port

`host_rdata` is registered: the memory octet at `host_addr` the clock after `host_rd`. A host write
to the octet the engine writes in the same clock is dropped. The memory is not reset.

### 3.9 Reset

`busy` = 0, `tx_valid` = 0, all pulses 0, `base_id` = 0, lock CSR 0xFFFF, tag 0, `ob_busy` = 0. A
packet in progress is lost.

## 4. Parameters

None.

## 5. Errors and corner cases

| `rx_why` | Meaning | Response |
|---|---|---|
| 0 | executed | as section 3.3 |
| 1 | CRC error (final or early) | none |
| 2 | not for this endpoint (dest ID, hop count) | none |
| 3 | malformed (length, tt, structure) | none |
| 4 | unsupported ftype / ttype | ERROR for ftype 2, 5, 8 |
| 5 | request error | ERROR for NREAD, NWRITE_R, MAINTENANCE |
| 6 | dropped (busy) | none |
| 7 | unexpected response | none |

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "host read" | `host_rdata` = memory, the clock after `host_rd` | §3.8 |
| "tx_last without tx_valid" | `tx_last` only with `tx_valid` | §3.2 |
| "ob_busy not set" | `ob_busy` after a doorbell goes out | §3.7 |
| "base ID after reset" | `base_id` = 0 after reset | §3.9 |
| "id_load" | `id_load` loads `cfg_base_id` | §3.6 |
| "the CSR write loses to id_load" | a maintenance write of the base ID CSR wins over `id_load` in the same clock | §3.6 |
| "base_id output" | `base_id` shows the CSR | §3.6 |
| "ob_busy dropped" | `ob_busy` holds until the matching response | §3.7 |
| "outbound doorbell completion" | matching response: `ob_done`, `ob_status` | §3.7 |
| "second doorbell sent" | `ob_start` while busy sends nothing | §3.7 |
| "outbound doorbell completion 2" | as above | §3.7 |
| "outbound doorbell completion 3" | as above | §3.7 |
| "outbound doorbell completion 4" | as above | §3.7 |
| "one-octet packet" | a one-octet packet is malformed (why 3) | §5 |
| "packet while busy" | a packet arriving while busy is dropped, why 6 | §3.1 |
| "long packet while busy" | also a long one | §3.1 |
| "one-octet packet after a request" | also a one-octet one | §3.1 |
| "packet while our doorbell goes out" | dropped while our doorbell is sent | §3.1 |
| "reset values" | reset values | §3.9 |
| "reset values in a packet" | a reset inside a packet | §3.9 |
| a_tx_valid | `tx_valid` as the checker's model | §3.2 |
| a_tx_data | every transmitted octet as the model | §3.2..§3.7 |
| a_tx_last | `tx_last` on the last octet | §3.2 |
| a_busy | `busy` as the model | §3.1 |
| a_rx_rep | `rx_rep` once per packet | §3.1 |
| a_rx_why | `rx_why` / `rx_ftype` | §5 |
| a_db_valid | `db_valid` | §3.5 |
| a_db_fields | `db_src`, `db_tid`, `db_info` | §3.5 |
| a_ob_done | `ob_done` | §3.7 |
| a_ob_status | `ob_status` | §3.7 |
| a_ob_busy | `ob_busy` | §3.7 |
| a_base_id | `base_id` | §3.6 |
| a_host_rdata | `host_rdata` | §3.8 |
| a_rst_outputs | reset values | §3.9 |
