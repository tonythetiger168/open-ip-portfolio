# RapidIO logical / transport layer endpoint: NREAD / NWRITE / NWRITE_R / SWRITE / MAINTENANCE / DOORBELL target, doorbell initiator, LP-Serial CRC-16, 1 KB memory

Protocol IP `RAPIDIO`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `RAPIDIO_top` (`rtl/RAPIDIO_top.sv`) |
| Register interface | APB4 slave `RAPIDIO_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x52490100 (code 0x5249, version 1.0) |
| Registers | 23 words, 0x000 to 0x058 |
| Interrupts | 6 sources into one level-high `irq` |
| Data streams | RX_REP (from the core), DOORBELL (from the core), OB_DONE (from the core) |
| Protocol pins | 6 pass-through |

## Overview

RAPIDIO_top v1.0: RapidIO logical / transport layer endpoint (target for NREAD / NWRITE / NWRITE_R / SWRITE / MAINTENANCE / DOORBELL, initiator for DOORBELL) over a packet byte stream with LP-Serial CRC-16

- Packet stream: rx_valid / rx_data / rx_last carry one octet per clock,
the first octet of the packet first; tx_valid / tx_data / tx_last give
the packets this endpoint sends (no back pressure). Packet layout:
{ackID[4:0], rsvd[2:0]}, {prio[1:0], tt[1:0], ftype[3:0]}, transport
(tt 0: dest, src as 8-bit IDs; tt 1: 16-bit IDs), the logical header,
payload, CRC-16. CRC-16 is x^16 + x^12 + x^5 + 1 (0x1021), seed 0xFFFF,
MSB first, with the first 6 bits of the packet taken as 0. A packet
longer than 80 octets carries an early CRC after octet 80 (over octets
0..79); the final CRC covers everything before it, early CRC included.
Packets are padded with 2 zero octets to a multiple of 4 octets.
Sent packets use ackID 0 (the physical layer assigns ackIDs).
- Received packets are buffered (up to 511 octets) and executed after
their CRCs check. While a packet executes or a packet is sent, new
packets are dropped (busy = 1; reported with why 6 the clock after
their last octet).
- Requests (dest ID = this endpoint's base device ID of the packet's tt):
NREAD (ftype 2, ttype 4), NWRITE / NWRITE_R (ftype 5, ttype 4 / 5),
SWRITE (ftype 6) on a 1 KB memory at addresses 0x000..0x3FF; rdsize /
wrsize with wdptr as in the RapidIO size table (sub-double-word lanes,
8 .. 256 octets); a write may carry fewer double-words than its size.
NREAD returns whole double-words. MAINTENANCE (ftype 8, hop count 0)
read / write of one 32-bit word (size 0b1000): 0x00 device identity CAR,
0x04 device information CAR, 0x08 assembly identity CAR, 0x0C assembly
information CAR, 0x10 processing element features CAR (inputs), 0x60
base device ID CSR ([23:16] 8-bit, [15:0] 16-bit ID), 0x68 host base
device ID lock CSR (set when 0xFFFF, cleared by writing the holder),
0x6C component tag CSR; other offsets read 0 and ignore writes.
DOORBELL (ftype 10) is reported on db_*. Responses (ftype 13, or 8 for
maintenance) go to the request's source ID with priority + 1 (at most
3) and status DONE (0) or ERROR (7): ERROR for an address outside the
memory, xamsbs != 0, a size that is reserved for the transaction, or an
unsupported ttype of ftype 2 / 5 / 8. NWRITE / SWRITE send no response.
- Doorbells out: ob_start sends a DOORBELL (ob_tt, ob_dest, ob_tid,
ob_info) when idle; the RESPONSE with that TID ends it: ob_done with
ob_status. ob_busy holds in between.
- Every received packet ends with rx_rep and rx_why: 0 executed,
1 CRC error, 2 not for this endpoint (dest ID, hop count), 3 malformed
(length, tt, structure), 4 unsupported ftype / ttype, 5 request error
(answered with ERROR), 6 dropped (busy), 7 unexpected response.
- Host port: host_rd gives host_rdata the clock after; a host write to
the octet the endpoint writes in the same clock is dropped.
- Not implemented: the physical layer (control symbols, ackID tracking,
retry), message passing, atomics, flow control, request timeouts,
34 / 50 / 66-bit addressing.

Features:

- Target for NREAD, NWRITE, NWRITE_R and SWRITE on a 1 KB memory, with the RapidIO rdsize / wrsize table (sub-double-word lanes, 8 to 256 octets)
- MAINTENANCE read / write of the CARs, base device ID CSR, host base device ID lock and component tag; DOORBELL in and out
- 8-bit and 16-bit device IDs, responses with priority + 1, DONE / ERROR status
- LP-Serial CRC-16 with the early CRC after octet 80 and padding, checked on receive and generated on transmit

rx_valid / rx_data / rx_last carry a packet one octet per PCLK (from the ackID octet to the pad); tx_valid / tx_data / tx_last give the packets the endpoint sends, without back pressure.
Not implemented: the physical layer (control symbols, ackID tracking, retry), message passing, atomics, flow control, request timeouts, 34 / 50 / 66-bit addresses.

## Files

| File | Content |
|---|---|
| `rtl/RAPIDIO_top.sv` | protocol core |
| `rtl/RAPIDIO_apb.sv` | APB4 register wrapper (generated) |
| `tb/RAPIDIO_tb.sv` | core testbench |
| `tb/RAPIDIO_apb_tb.sv`, `tb/apb/RAPIDIO_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/RAPIDIO_sva.sv`, `tb/cov/RAPIDIO_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/RAPIDIO.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `RAPIDIO_apb`. Widths of the pass-through pins are at the default parameters.

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
| `PSLVERR` | output | 1 | error: unmapped or misaligned address |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `rx_valid` | input | 1 | protocol pin, core port `rx_valid` |
| `rx_data` | input | 8 | protocol pin, core port `rx_data` |
| `rx_last` | input | 1 | protocol pin, core port `rx_last` |
| `tx_valid` | output | 1 | protocol pin, core port `tx_valid` |
| `tx_data` | output | 8 | protocol pin, core port `tx_data` |
| `tx_last` | output | 1 | protocol pin, core port `tx_last` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rx_valid` | input | 1 | pin (pass-through) |
| `rx_data` | input | 8 | pin (pass-through) |
| `rx_last` | input | 1 | pin (pass-through) |
| `tx_valid` | output | 1 | pin (pass-through) |
| `tx_data` | output | 8 | pin (pass-through) |
| `tx_last` | output | 1 | pin (pass-through) |
| `cfg_dev_id_car` | input | 32 | DEV_ID_CAR[31:0] |
| `cfg_dev_info_car` | input | 32 | DEV_INFO_CAR[31:0] |
| `cfg_asm_id_car` | input | 32 | ASM_ID_CAR[31:0] |
| `cfg_asm_info_car` | input | 32 | ASM_INFO_CAR[31:0] |
| `cfg_pe_feat_car` | input | 32 | PE_FEAT_CAR[31:0] |
| `cfg_base_id` | input | 24 | BASE_ID_CFG[23:0] |
| `id_load` | input | 1 | CMD[0:0] |
| `base_id` | output | 24 | BASE_ID[23:0] |
| `host_rd` | input | 1 | CMD[2:2] |
| `host_wr` | input | 1 | CMD[1:1] |
| `host_addr` | input | 10 | MEM_ADDR[9:0] |
| `host_wdata` | input | 8 | MEM_WDATA[7:0] |
| `host_rdata` | output | 8 | MEM_RDATA[7:0] |
| `ob_start` | input | 1 | CMD[3:3] |
| `ob_tt` | input | 1 | OB_CTRL[24:24] |
| `ob_dest` | input | 16 | OB_CTRL[15:0] |
| `ob_tid` | input | 8 | OB_CTRL[23:16] |
| `ob_info` | input | 16 | OB_INFO[15:0] |
| `ob_busy` | output | 1 | STATUS[0:0] |
| `ob_done` | output | 1 | OB_DONE capture |
| `ob_status` | output | 4 | OB_DONE[3:0] |
| `db_valid` | output | 1 | DOORBELL capture |
| `db_src` | output | 16 | DOORBELL1[15:0] |
| `db_tid` | output | 8 | DOORBELL0[23:16] |
| `db_info` | output | 16 | DOORBELL0[15:0] |
| `rx_rep` | output | 1 | RX_REP capture |
| `rx_why` | output | 3 | RX_REP[2:0] |
| `rx_ftype` | output | 4 | RX_REP[6:3] |
| `busy` | output | 1 | STATUS[1:1] |

## APB wrapper

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

## Programming sequence

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

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.RAPIDIO sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.RAPIDIO syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/RAPIDIO_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.RAPIDIO apb` | `TEST PASSED: RAPIDIO_apb`, then Yosys without `ERROR` | console, `work/RAPIDIO_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh RAPIDIO`<br>`bash scripts/cov/run_cov.sh RAPIDIO_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/RAPIDIO/score.json`, `work/cov/RAPIDIO_apb/score.json` |

Expected end of a step 4 run:

```
===== RAPIDIO =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/RAPIDIO_tb.sv`): drives `RAPIDIO_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/RAPIDIO_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/RAPIDIO_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/RAPIDIO_sva.sv`, `tb/cov/RAPIDIO_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/RAPIDIO_top.sv` | not run | | | | | |
| wrapper `rtl/RAPIDIO_apb.sv` | not run | | | | | |
