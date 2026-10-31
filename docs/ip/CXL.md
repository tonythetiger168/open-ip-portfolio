# CXL 3.x-style Type 3 memory device: 256-byte flit link (CRC-64, sequence numbers, credits) carrying CXL.cachemem and CXL.io, CXL.mem M2S Req / RwD and S2M NDR / DRS with a 2-bit meta state, poison and an HDM range decoder, HDM-DB back-invalidation with a snoop filter

Protocol IP `CXL`, version 3.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `CXL_top` (`rtl/CXL_top.sv`) |
| Register interface | APB4 slave `CXL_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x43580300 (code 0x4358, version 3.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 12 sources into one level-high `irq` |
| Data streams | BI (to the core), BIDONE (from the core) |
| Protocol pins | 12 pass-through |

## Overview

CXL_top v3.0: CXL Type 3 device (memory expander) with a 256-byte flit link layer, a CXL.io pass-through path and HDM-DB back-invalidation: CXL.mem M2S Req / RwD / BIRsp in, S2M NDR / DRS / BISnp out, device memory with a 2-bit meta state, poison, a range decoder and a snoop filter

- Link: rx_valid / rx_data (M2S, from the host; no back-pressure) and
tx_valid / tx_ready / tx_data (S2M), 8 bytes per beat, byte 0 in bits
7:0. A flit is 32 beats (256 bytes, beat 0 first):
bytes   0..1    flit header {SEQ[7:0], 6'b0, TYPE[1:0]}; TYPE NOP 0,
CXL.io 1, CXL.cachemem 2 (3 reserved: the flit is
dropped with ev_fmt, its credits too)
bytes   2..15   H slot: bytes 2..7 reserved, bytes 8..15 (beat 1)
one header unit
bytes  16..239  G slots 1..14 (16 bytes each, beats 2..29), each two
units of 8 bytes, or one data slot
bytes 240..241  CRD: credits returned {IO[3:0], CH2[3:0], CH1[3:0],
CH0[3:0]} (M2S: credits for the device's NDR, DRS,
BISnp and CXL.io flits; S2M: for its Req, RwD, BIRsp
and CXL.io flits)
bytes 242..249  CRC-64 (polynomial 0x42F0E1EBA9EA3693, seed all
ones, each beat bit 63 first, no final xor) of bytes
0..241, CRC bit 7:0 in byte 242
bytes 250..255  FEC: sent as zero, not checked (the PHY's job)
SEQ counts the flits a side sends; a received SEQ other than the last
one plus 1 raises ev_seq (the flit is still taken, and the count
follows it). A flit with a bad CRC is dropped whole (ev_crc), a
partly received RwD message is abandoned and SEQ is taken as received.
There is no link-level retry.
- CXL.cachemem flits: units are 8 bytes, format code in bits 3:0. A
header unit carries one message or is empty (0); beat 0 bytes 2..7 are
reserved. Data: after a message with data, the next 4 G slots (8
units, line bytes 0..63 in order) carry its line; they may roll over
into the next CXL.cachemem flit, skipping the H slot, which stays a
header unit.
M2S Req   1: {16'b0, ADDR, TAG, 1'b0, SNP[2:0], MV, MF, OP, 4'd1}
M2S RwD   2: {16'b0, ADDR, TAG, POISON, SNP, MV, MF, OP, 4'd2}, in
the first unit of a G slot; the second unit is the
64-bit byte enable (MemWrPtl). Every RwD opcode but
BIConflict (4) is followed by its 4 data slots. An RwD
header in any other unit is ignored (ev_fmt).
M2S BIRsp 3: {44'b0, BITAG[11:0], OP, 4'd3}
S2M NDR   4: {32'b0, TAG, 4'b0, DEVLOAD, MV, 1'b0, OP[2:0], 4'd4}
S2M DRS   5: {32'b0, TAG, 3'b0, POISON, DEVLOAD, MV, 4'b0, 4'd5}
S2M BISnp 6: {16'b0, ADDR, 12'b0, BITAG, OP, 4'd6}
A received unit with code 4..15 is ignored (ev_fmt). A message that
finds no buffer backed by a credit the host holds (every buffer in use
or owed back as a credit: the host sent it without a credit) is
dropped (ev_ovf); the data units of a dropped RwD are skipped.
The device sends a CXL.cachemem flit when a message or a line's data
is waiting (with credit), a CXL.io flit when the CXL.io side offers one
(with credit; the two alternate), and a NOP flit when only credits are
owed. In a CXL.cachemem flit each header unit takes one message: the
response (NDR or DRS, in the order the core made them) and BISnp
alternate when both wait. A DRS message's data starts in the next G
slot; the unit after a DRS header in the same slot can take an NDR or
BISnp.
Credits: the device's buffers (RQD Req, WQD RwD, 1 BIRsp, IOD CXL.io
flits) are returned in every flit as they free, starting with all of
them after reset. Credits from the host are counted per channel (up to
255) and each message (each CXL.io flit) sent takes one.
- CXL.io: io_rx_* delivers the payload of each CXL.io flit received
(bytes 2..239) as 30 beats of 8 bytes, io_rx_last on the 30th, which
carries bytes 234..239 in its bits 47:0 (bits 63:48 zero); io_tx_*
takes 30 beats per flit the same way (bits 63:48 of the 30th are
ignored). The payload (the TLPs, their framing and flow control) is
not looked at: the CXL.io transaction layer is outside. A CXL.io flit
that finds no buffer backed by a credit is dropped (ev_ovf). A CXL.io flit being sent
waits for each beat of io_tx (tx_valid low meanwhile).
- Address: ADDR is a host line address (byte address bits 21:6). The HDM
decoder maps hdm_base .. hdm_base + LINES - 1 to the device's LINES
lines (DPA = address - hdm_base, modulo 2^16); any other address is out
of range (ev_range): a read returns zeros with poison, a write is
dropped, a completion is still sent.
- M2S Req opcodes: MemInv 0, MemRd 1, MemRdData 2, MemSpecRd 8,
MemInvNT 9, MemClnEvct 10. MemRdFwd 3, MemWrFwd 4 and the reserved
codes are dropped with ev_opcode, no response.
MemRd / MemRdData: S2M DRS with the line, its poison bit and meta
state. MemInv / MemInvNT / MemClnEvct: S2M NDR; for MemInv and
MemInvNT with MetaField Meta0-State the opcode follows MetaValue
(Cmp-S 1 for Shared, Cmp-E 2 for Any, Cmp 0 otherwise), else Cmp.
MemSpecRd: no response (a prefetch hint).
- M2S RwD opcodes: MemWr 1 (the whole line; the poison bit replaces the
line's), MemWrPtl 2 (bytes with their enable set; poison is or-ed in):
S2M NDR Cmp. BIConflict 4 (HDM-DB, bi_en): S2M NDR BIConflictAck 4.
Others (BIConflict without bi_en, reserved) are dropped (ev_opcode).
- Meta state (per line: Invalid 00, Any 10, Shared 11; reset Invalid):
MetaField Meta0-State (00) sets it to MetaValue for MemRd, MemInv,
MemInvNT, MemClnEvct, MemWr and MemWrPtl; No-Op (11) leaves it.
Responses carry the state before the request. A reserved MetaField
(01, 10) or SnpType (1xx) is taken as No-Op with ev_proto.
- HDM-DB (bi_en): the meta state of a line is the host's coherence
state, and the snoop filter holds at most SFE lines that are not
Invalid (sf_cnt counts them). A Req that would take a line from Invalid
to Any or Shared with the filter full waits at the head of the Req
FIFO while the device evicts a victim (the next line not Invalid,
round robin): S2M BISnpInv, then the BIRsp. An RwD that would do so
with the filter full leaves the line Invalid. bi_valid / bi_ready /
bi_op (BISnpCur 0, BISnpData 1, BISnpInv 2; 3 is taken as 2) /
bi_line (DPA) is the device's own back-invalidation request: for a
line already Invalid it completes at once, else a BISnp is sent and
the BIRsp waited for; bi_done pulses with bi_state, the line's new
meta state. One BISnp is outstanding at a time; BITAG steps through a
12-bit LFSR (x^12 + x^11 + x^10 + x^4 + 1) from 1.
BIRsp opcodes: BIRspI 0 (-> Invalid), BIRspS 1 (-> Shared), BIRspE 2
(-> Any); allowed: BISnpInv I; BISnpData I, S; BISnpCur I, S, E. An
illegal one is taken as BIRspI (ev_proto); a BIRsp with another BITAG
or none outstanding is dropped (ev_proto). A Req to the line of the
outstanding BISnp waits at the head of the FIFO; RwD messages do not
(the host's write-back). Without bi_en, bi_ready is low, nothing is
evicted and a BIRsp is dropped (ev_proto).
- Order: Req messages wait in a FIFO of RQD entries, complete RwD
messages in a ring of WQD. A BIRsp is served first; else the Req and
the RwD at the heads are served by round robin when both can go, one
per clock, when the response they need can be held (one NDR, one DRS).
DevLoad in each response grades the requests left waiting in the FIFO
once it is served: none Light (00), 1 Optimal (01), RQD - 1 or more
Severe (11), else Moderate (10). Device memory is zero after reset.
Not implemented: link-level retry, FEC, the 68-byte flit mode, ARB/MUX
link states (L1, ALMP), CXL.cache, HDM-D, the Blk BISnp variants,
several messages per data-free slot beyond two units, IDE, interleaving
and more than one HDM decoder, the extended meta field, traffic classes,
QoS telemetry beyond DevLoad, RAS logging. Field layouts and encodings
are ours, modelled on CXL 3.x as we read it; they have not been checked
against a compliant host.

Features:

- 256-byte flits of 32 beats: header with type and 8-bit sequence number, 14 generic slots of 16 bytes, credit return field, CRC-64 over the first 242 bytes.
- CXL.cachemem units: M2S Req, RwD (header, byte enables, then 64 data bytes rolling over slots and flits), BIRsp in; S2M NDR, DRS (header and 64 data bytes), BISnp out.
- CXL.io flits pass the 240-byte payload through to and from an external transaction layer, with their own credits.
- Per-class credits in both directions (Req, RwD, BIRsp, CXL.io in; NDR, DRS, BISnp, CXL.io out), saturating at 255.
- CXL.mem Type 3 transaction layer as in version 2.0: MemRd, MemRdData, MemInv, MemInvNT, MemClnEvct, MemSpecRd, MemWr, MemWrPtl, meta state, poison, DevLoad.
- HDM-DB: snoop filter of SFE lines, eviction by BISnpInv, device-initiated BISnpCur / BISnpData / BISnpInv, BIRsp legality checks, BIConflict / BIConflictAck.
- Error events for range, opcode, protocol, poison, CRC, sequence, format and overflow.

rx_valid / rx_data and tx_valid / tx_ready / tx_data are the link: one 64-bit beat per PCLK, 32 beats per 256-byte flit. io_rx_* and io_tx_* are the CXL.io payload ports (30 beats of 8 bytes per flit). They all pass through unchanged.
The core parameters LINES (16 cache lines of device memory), RQD (4 Req FIFO entries), WQD (2 RwD buffers), SFE (4 snoop filter entries) and IOD (2 CXL.io receive flits) keep their defaults; device memory is zero after reset.
The flit and message layouts follow CXL 3.x in shape (256-byte flit, 16-byte slots, CRC, credits) but are our own simplified encoding; they have not been checked against a compliant host. Not implemented: CXL.cache, the 68-byte flit, the latency-optimised 256-byte flit, link-layer retry (a bad flit is dropped and reported), FEC correction, IDE, PBR / multi-headed devices, the full CXL.io transaction layer (the payload is handed to an external one), MemSpecRd prefetch hints, extended meta states.

## Files

| File | Content |
|---|---|
| `rtl/CXL_top.sv` | protocol core |
| `rtl/CXL_apb.sv` | APB4 register wrapper (generated) |
| `tb/CXL_tb.sv` | core testbench |
| `tb/CXL_apb_tb.sv`, `tb/apb/CXL_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CXL_sva.sv`, `tb/cov/CXL_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CXL.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`CXL_apb` has the core's parameters and passes them to `CXL_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `LINES` | int | `16` |
| `RQD` | int | `4` |
| `WQD` | int | `2` |
| `SFE` | int | `4` |
| `IOD` | int | `2` |

## Wrapper pins

Pins of `CXL_apb`. Widths of the pass-through pins are at the default parameters.

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
| `rx_data` | input | 64 | protocol pin, core port `rx_data` |
| `tx_valid` | output | 1 | protocol pin, core port `tx_valid` |
| `tx_ready` | input | 1 | protocol pin, core port `tx_ready` |
| `tx_data` | output | 64 | protocol pin, core port `tx_data` |
| `io_rx_valid` | output | 1 | protocol pin, core port `io_rx_valid` |
| `io_rx_ready` | input | 1 | protocol pin, core port `io_rx_ready` |
| `io_rx_data` | output | 64 | protocol pin, core port `io_rx_data` |
| `io_rx_last` | output | 1 | protocol pin, core port `io_rx_last` |
| `io_tx_valid` | input | 1 | protocol pin, core port `io_tx_valid` |
| `io_tx_ready` | output | 1 | protocol pin, core port `io_tx_ready` |
| `io_tx_data` | input | 64 | protocol pin, core port `io_tx_data` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `hdm_base` | input | 16 | CTRL[15:0] |
| `bi_en` | input | 1 | CTRL[16:16] |
| `rx_valid` | input | 1 | pin (pass-through) |
| `rx_data` | input | 64 | pin (pass-through) |
| `tx_valid` | output | 1 | pin (pass-through) |
| `tx_ready` | input | 1 | pin (pass-through) |
| `tx_data` | output | 64 | pin (pass-through) |
| `io_rx_valid` | output | 1 | pin (pass-through) |
| `io_rx_ready` | input | 1 | pin (pass-through) |
| `io_rx_data` | output | 64 | pin (pass-through) |
| `io_rx_last` | output | 1 | pin (pass-through) |
| `io_tx_valid` | input | 1 | pin (pass-through) |
| `io_tx_ready` | output | 1 | pin (pass-through) |
| `io_tx_data` | input | 64 | pin (pass-through) |
| `bi_valid` | input | 1 | BI commit / FLAGS |
| `bi_ready` | output | 1 | BI handshake |
| `bi_op` | input | 2 | BI[5:4] |
| `bi_line` | input | 4 | BI[3:0] |
| `bi_done` | output | 1 | BIDONE capture |
| `bi_state` | output | 2 | BIDONE[1:0] |
| `sf_cnt` | output | 5 | STATUS[4:0] |
| `ev_range` | output | 1 | IRQ_STATUS.ERR_RANGE |
| `ev_opcode` | output | 1 | IRQ_STATUS.ERR_OPCODE |
| `ev_proto` | output | 1 | IRQ_STATUS.ERR_PROTO |
| `ev_poison` | output | 1 | IRQ_STATUS.POISON_RD |
| `ev_crc` | output | 1 | IRQ_STATUS.ERR_CRC |
| `ev_seq` | output | 1 | IRQ_STATUS.ERR_SEQ |
| `ev_fmt` | output | 1 | IRQ_STATUS.ERR_FMT |
| `ev_ovf` | output | 1 | IRQ_STATUS.OVERFLOW |

## APB wrapper

`CXL_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_valid`, `rx_data`, `tx_valid`, `tx_ready`, `tx_data`, `io_rx_valid`, `io_rx_ready`, `io_rx_data`, `io_rx_last`, `io_tx_valid`, `io_tx_ready`, `io_tx_data`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43580300 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | HDM decoder and coherence mode |
| 0x018 | BI | RW | 0x00000000 | device-initiated back-invalidation of one line (HDM-DB only); writing BI sends it. The core takes it when no BISnp is outstanding |
| 0x01C | BIDONE | RO (pop) | 0x00000000 | completion of a BI request: the line's new meta state; reading it pops it |
| 0x020 | STATUS | RO | core | snoop filter |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4358 | IP code |
| ID | 15:8 | MAJOR | RO | 0x03 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 11:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 11:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 15:0 | `hdm_base` | RW | 0x0 | first host line address (byte address bits 21:6) of the device's LINES = 16 lines; change it only while no message is in flight |
| CTRL | 16 | `bi_en` | RW | 0x0 | HDM-DB: device-managed coherence with back-invalidation (BISnp / BIRsp) and a snoop filter of SFE = 4 lines; 0 is HDM-H (host-only coherent). Change it only while the link is idle |
| BI | 3:0 | `bi_line` | RW | 0x0 | device line 0..15 |
| BI | 5:4 | `bi_op` | RW | 0x0 | BISnpCur 0, BISnpData 1, BISnpInv 2 (3 is taken as 2) |
| BIDONE | 1:0 | `bi_state` | RO (pop) | 0x0 | meta state after the BIRsp: Invalid 00, Any 10, Shared 11 (a line already Invalid completes at once) |
| STATUS | 4:0 | `sf_cnt` | RO | core | lines not Invalid (the snoop filter occupancy; at most SFE with HDM-DB) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR_RANGE | a request or write outside the HDM range (reads return poisoned zeros, writes are dropped; both complete) |
| 1 | ERR_OPCODE | an unsupported opcode: the message was dropped without a response |
| 2 | ERR_PROTO | a reserved MetaField or SnpType (taken as No-Op), an illegal BIRsp (taken as BIRspI), or a BIRsp with a stale tag or none outstanding (dropped) |
| 3 | POISON_RD | a read returned a poisoned line |
| 4 | ERR_CRC | a flit failed its CRC-64 and was dropped whole |
| 5 | ERR_SEQ | a flit's sequence number skipped (taken, and the count resynchronised) |
| 6 | ERR_FMT | a reserved flit type, unit code or misplaced RwD header: the unit or flit was dropped |
| 7 | OVERFLOW | a message or CXL.io flit arrived without a free buffer (the host sent without credit): dropped |
| 8 | BI_DONE | BI beat accepted by the core |
| 9 | BI_OVF | write to BI while full (dropped) |
| 10 | BIDONE_AVAIL | BIDONE captured a beat |
| 11 | BIDONE_OVF | beat dropped, BIDONE was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | BI_FULL | BI holds a beat the core has not taken |
| 1 | BIDONE_AVAIL | BIDONE holds an unread beat |

### Streams

* **BI** feeds `bi_line`, `bi_op`/`bi_valid`. Writing BI commits the beat: FLAGS.BI_FULL is set and `bi_valid` stays high until the core's `bi_ready`; then BI_DONE is set. A write while full is dropped and sets BI_OVF.
* **BIDONE** captures `bi_state` when `bi_done` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ BIDONE_AVAIL. Reading BIDONE pops it. A beat that arrives while the register is full is dropped and sets BIDONE_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43580300.
2. Write 0xFFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xFFF enables all).
5. To send on BI: wait until FLAGS.BI_FULL (bit 0) is 0, or for IRQ BI_DONE, then write BI (0x018). The last write commits the beat. BI_OVF means a write came while the register was full and was dropped.
6. To receive on BIDONE: wait for IRQ BIDONE_AVAIL or FLAGS.BIDONE_AVAIL (bit 1), then read BIDONE (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.BIDONE_AVAIL (bit 10) to clear it. Read each beat before the next arrives, or it is dropped and BIDONE_OVF is set.
7. Read STATUS (0x020) for the core's live `sf_cnt`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL with hdm_base (and bi_en for HDM-DB) while the link is idle, then bring the link up; the host's credits arrive in its first flits.
2. Device-initiated back-invalidation: write BI with the line and op; on BIDONE_AVAIL read BIDONE for the line's new state.
3. Enable the error interrupts of interest in IRQ_ENABLE; on an interrupt read IRQ_STATUS and clear it by writing the bits back.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.CXL sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.CXL syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/CXL_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.CXL apb` | `TEST PASSED: CXL_apb`, then Yosys without `ERROR` | console, `work/CXL_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh CXL`<br>`bash scripts/cov/run_cov.sh CXL_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/CXL/score.json`, `work/cov/CXL_apb/score.json` |

Expected end of a step 4 run:

```
===== CXL =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/CXL_tb.sv`): drives `CXL_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/CXL_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/CXL_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/CXL_sva.sv`, `tb/cov/CXL_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CXL_top.sv` | pass | 194/194 | 3134/3134 | 6/6 | 8/8 | 472/472 |
| wrapper `rtl/CXL_apb.sv` | pass | 34/34 | 1132/1132 | n/a | 12/12 | 83/83 |

Core: tb/CXL_tb.sv drives the link with a host model (tb/CXL_host.svh) that packs Req, RwD and BIRsp messages into flits unit by unit within the device's credits, mixes in CXL.io and NOP flits, checks and parses every S2M flit (CRC, sequence, FEC and reserved bits, credits) and predicts every response from a reference memory. Phases: six back-pressure and gap modes with a moving HDM base, poison, range edges, conflicts, stalls, credits held and saturated, overflow of every buffer, every error flit, BIRsps in every unit, HDM-DB with evictions, device BI requests, write-backs, BIConflict and illegal or stale BIRsps, the first arbitration ties after reset, a reset mid-flit in both directions.
The core checker (tb/cov/CXL_sva.sv) is an independent cycle model fed only by the inputs: it computes the CRC-64 of each transmitted flit itself and predicts every output beat, ready, BI result, snoop-filter count and event on every clock.
Sign-off (docs/SIGNOFF.md): Verilator -Wall lint clean, mutation testing with the checker (scripts/mut/run_mut.py CXL --flow cov), a bounded formal proof of 10 properties to depth 36 (formal/CXL_props.svh), which found and led to the fix of a credit-counter wrap when a host sends without credit, and the area / depth report.
