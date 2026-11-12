<!-- SPDX-License-Identifier: Apache-2.0 -->
# CXL: design specification

A CXL 3.x Type 3 device (memory expander) with a 256-byte flit link layer, a CXL.io pass-through,
and HDM-DB back-invalidation: CXL.mem M2S Req / RwD / BIRsp in, S2M NDR / DRS / BISnp out, device
memory with a 2-bit meta state per line, poison, an HDM range decoder and a snoop filter. Not
implemented: link-level retry, FEC, 68-byte flits, ARB/MUX states and ALMPs, CXL.cache, HDM-D,
Blk BISnp variants, IDE, interleaving and several HDM decoders, extended meta field, traffic
classes, QoS beyond DevLoad, RAS logging. Field layouts and encodings are this IP's own, modelled
on CXL 3.x; they have not been checked against a compliant host. Core `CXL_top`
(`rtl/CXL_top.sv`), testbench `tb/CXL_tb.sv`, checker `tb/cov/CXL_sva.sv` (an independent
reference model compared every clock).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A "line" is 64 bytes; a "unit" is 8 bytes (one beat).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `hdm_base` | input | 16 | first host line address mapped to the device (HDM decoder) | - | `clk` | - |
| `bi_en` | input | 1 | HDM-DB mode: snoop filter and back-invalidation | high | `clk` | - |
| `rx_valid` | input | 1 | M2S flit beat valid (no back-pressure) | high | `clk` | - |
| `rx_data` | input | 64 | M2S flit beat, byte 0 in bits 7:0 | - | `clk` | - |
| `tx_valid` | output | 1 | S2M flit beat valid | high | `clk` | 0 |
| `tx_ready` | input | 1 | the link takes the S2M beat | high | `clk` | - |
| `tx_data` | output | 64 | S2M flit beat; held while `tx_valid` && !`tx_ready` | - | `clk` | 0 |
| `io_rx_valid` | output | 1 | a received CXL.io payload beat is available | high | `clk` | 0 |
| `io_rx_ready` | input | 1 | the CXL.io side takes the beat | high | `clk` | - |
| `io_rx_data` | output | 64 | CXL.io payload beat (section 3.6) | - | `clk` | - |
| `io_rx_last` | output | 1 | 30th beat of a payload | high | `clk` | 0 |
| `io_tx_valid` | input | 1 | a CXL.io payload beat to send | high | `clk` | - |
| `io_tx_ready` | output | 1 | the device takes `io_tx_data` this clock; combinational | high | comb | 0 |
| `io_tx_data` | input | 64 | CXL.io payload beat to send | - | `clk` | - |
| `bi_valid` | input | 1 | device back-invalidation request | high | `clk` | - |
| `bi_ready` | output | 1 | bi_en, BISnp engine idle and no eviction starting; combinational | high | comb | 0 |
| `bi_op` | input | 2 | 0 BISnpCur, 1 BISnpData, 2 BISnpInv (3 taken as 2) | - | `clk` | - |
| `bi_line` | input | log2(LINES) | device line (DPA) to back-invalidate | - | `clk` | - |
| `bi_done` | output | 1 | one-clock pulse: the device request completed | high | `clk` | 0 |
| `bi_state` | output | 2 | meta state of the line after the request, with `bi_done` | - | `clk` | 0 |
| `sf_cnt` | output | log2(LINES)+1 | lines whose meta state is not Invalid | - | `clk` | 0 |
| `ev_range` | output | 1 | one-clock pulse: address outside the HDM range | high | `clk` | 0 |
| `ev_opcode` | output | 1 | one-clock pulse: unsupported opcode, dropped | high | `clk` | 0 |
| `ev_proto` | output | 1 | one-clock pulse: reserved MetaField / SnpType, bad BIRsp | high | `clk` | 0 |
| `ev_poison` | output | 1 | one-clock pulse: read of a poisoned line | high | `clk` | 0 |
| `ev_crc` | output | 1 | one-clock pulse: flit with a bad CRC dropped | high | `clk` | 0 |
| `ev_seq` | output | 1 | one-clock pulse: flit out of sequence | high | `clk` | 0 |
| `ev_fmt` | output | 1 | one-clock pulse: reserved flit type / unit code, misplaced RwD | high | `clk` | 0 |
| `ev_ovf` | output | 1 | one-clock pulse: message or CXL.io flit without a buffer, dropped | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads the receive beat index to time a stress window in the middle of flits.

| Signal | Width | Meaning |
|---|---|---|
| `rj` | 5 | index of the next M2S beat of the flit being received, 0..31 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/CXL.md`](../ip/CXL.md) (source: `scripts/apb/specs/CXL.json`); do not edit by hand.

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

### Programming sequence

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
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Flit format

A flit is 32 beats of 8 bytes (256 bytes), beat 0 first:

| Bytes | Content |
|---|---|
| 0..1 | header: byte 0 bits 1:0 TYPE (0 NOP, 1 CXL.io, 2 CXL.cachemem, 3 reserved), byte 1 SEQ |
| 2..15 | H slot: bytes 2..7 reserved (CXL.io: payload), bytes 8..15 (beat 1) one header unit |
| 16..239 | G slots 1..14, beats 2..29: two units each, or one 16-byte piece of a data line |
| 240..241 | CRD: {IO[3:0], CH2[3:0], CH1[3:0], CH0[3:0]} credits returned |
| 242..249 | CRC-64 (poly 0x42F0E1EBA9EA3693, seed all ones, each beat MSB (bit 63) first, no final xor) over bytes 0..241; CRC bits 7:0 in byte 242 |
| 250..255 | FEC: sent 0, not checked |

M2S CRD returns credits for the device's NDR (CH0), DRS (CH1), BISnp (CH2) and CXL.io flits; S2M
CRD returns credits for the host's Req, RwD, BIRsp and CXL.io flits.

### 3.2 Units (CXL.cachemem flits)

Format code in bits 3:0; a header unit holds one message or is empty (code 0).

| Code | Message | Layout (bits 63..0) |
|---|---|---|
| 1 | M2S Req | {16'b0, ADDR, TAG, 1'b0, SNP[2:0], MV[1:0], MF[1:0], OP[3:0], 4'd1} |
| 2 | M2S RwD | same with bit 15 = POISON; only in the first unit of a G slot; the second unit is the 64-bit byte enable |
| 3 | M2S BIRsp | {44'b0, BITAG[11:0], OP[3:0], 4'd3} |
| 4 | S2M NDR | {32'b0, TAG, 4'b0, DEVLOAD[1:0], MV[1:0], 1'b0, OP[2:0], 4'd4} |
| 5 | S2M DRS | {32'b0, TAG, 3'b0, POISON, DEVLOAD, MV, 4'b0, 4'd5} |
| 6 | S2M BISnp | {16'b0, ADDR, 12'b0, BITAG, OP[3:0], 4'd6} |

Data: after an RwD (every opcode but BIConflict 4) or a DRS, the next 4 G slots (8 units, line
bytes 0..63 in order) carry the line; they may roll over into the next CXL.cachemem flit
(skipping its H slot, which stays a header unit). ADDR is a host line address (byte address bits
21:6).

### 3.3 Link receive

Beats are taken whenever `rx_valid` is high. At beat 31 the CRC is checked:

- bad CRC: the flit is dropped whole (`ev_crc`), a partly received RwD is abandoned, the expected
  SEQ advances by one;
- good CRC: a SEQ other than the expected one gives `ev_seq` (the flit is still taken and the
  expected SEQ becomes SEQ + 1); the CRD credits are added (saturating at 255); TYPE 3 is dropped
  with `ev_fmt` (its credits too); TYPE 0 carries only credits.

From the clock after beat 31 the flit is unpacked one unit per clock (units of beats 1..29). A
CXL.cachemem unit with code 4..15, or an RwD header in a second unit, gives `ev_fmt` and is
ignored. A message that finds no buffer backed by a credit the host holds (every buffer in use
or owed back) is dropped with `ev_ovf`; the data units of a dropped RwD are skipped. A received
CXL.io flit is stored the same way (section 3.6). There is no link-level retry.

### 3.4 Link transmit

When no flit is being sent and the output can advance, the device starts a flit if it has
something to send, in this order of choice:

- a CXL.cachemem flit when a response, a BISnp (with credit) or DRS data is waiting;
- a CXL.io flit when `io_tx_valid` and a CXL.io credit (CXL.cachemem and CXL.io alternate when
  both want to go);
- a NOP flit when only credits are owed.

`tx_valid` / `tx_data` are registered and advance on `!tx_valid || tx_ready`; a CXL.io flit also
waits for each `io_tx_valid` beat (no beat is produced meanwhile). SEQ counts the flits sent
(the first flit after reset has SEQ 0). In a CXL.cachemem flit each header unit takes one message; responses (NDR / DRS
in the order the core made them) and BISnp alternate when both wait; DRS data starts at the next
G slot and the unit after a DRS header in the same slot can carry an NDR or BISnp. Each message
uses one host credit of its channel. Beat 30 carries the credits owed (then cleared) and CRC bits
47:0; beat 31 CRC bits 63:48.

### 3.5 Credits

The device's buffers (RQD Req, WQD RwD, one BIRsp, IOD CXL.io flits) are all owed to the host
after reset and are returned in the CRD of the next flit sent; each buffer is owed again when it
frees (a Req or RwD served, a BIRsp taken, a CXL.io flit fully read on `io_rx_*`).

### 3.6 CXL.io pass-through

Received CXL.io flit payload (bytes 2..239) is delivered as 30 beats on `io_rx_*` (beat k = bytes
2 + 8k .. 9 + 8k; the 30th carries bytes 234..239 in bits 47:0 with bits 63:48 zero), with
`io_rx_last` on the 30th; flits are buffered (IOD deep). For sending, `io_tx_ready` takes 30 beats
per flit the same way; bits 63:48 of the 30th are ignored. The payload is not looked at.

### 3.7 Service order and responses

Req messages wait in a FIFO of RQD entries, complete RwD messages in a ring of WQD. Per clock at
most one is served: a BIRsp first; else the Req and RwD heads by round robin when both can go. A
Req can go when its response can be held (one NDR, one DRS slot), it is not blocked by the
outstanding BISnp line, and it does not need a snoop-filter eviction (section 3.9). DevLoad in each
response grades the Reqs left waiting: 0 Light (00), 1 Optimal (01), RQD - 1 or more Severe (11),
else Moderate (10).

| Request | Response | Effect |
|---|---|---|
| Req MemRd 1 / MemRdData 2 | DRS with the line, its poison, the old meta state | MemRd with MF Meta0-State sets meta = MV |
| Req MemInv 0 / MemInvNT 9 | NDR: with MF Meta0-State Cmp-S 1 (MV Shared), Cmp-E 2 (MV Any), Cmp 0 otherwise | MF Meta0-State sets meta = MV |
| Req MemClnEvct 10 | NDR Cmp | as above |
| Req MemSpecRd 8 | none | - |
| Req others (MemRdFwd 3, MemWrFwd 4, reserved) | none | `ev_opcode` |
| RwD MemWr 1 | NDR Cmp | the whole line; poison = POISON |
| RwD MemWrPtl 2 | NDR Cmp | bytes with their enable; poison \|= POISON |
| RwD BIConflict 4 (bi_en) | NDR BIConflictAck 4 | - |
| RwD others | none | `ev_opcode` |

Meta state per line: Invalid 00, Any 10, Shared 11 (reset Invalid). MF 00 (Meta0-State) sets it,
MF 11 (No-Op) leaves it; a reserved MF (01, 10) or SnpType (1xx) is taken as No-Op with
`ev_proto`. Responses carry the state before the request. Out-of-range address (outside hdm_base
.. hdm_base + LINES - 1, modulo 2^16): `ev_range`, a read returns zeros with poison, a write is
dropped, the completion is still sent. A read of a poisoned line gives `ev_poison`.

### 3.8 BIRsp

BIRspI 0 -> Invalid, BIRspS 1 -> Shared, BIRspE 2 -> Any; legal for BISnpInv: I; BISnpData: I, S;
BISnpCur: I, S, E. An illegal opcode is taken as BIRspI with `ev_proto`; a BIRsp with another
BITAG, with none outstanding, or without bi_en is dropped with `ev_proto`.

### 3.9 HDM-DB (bi_en)

The snoop filter holds at most SFE lines that are not Invalid (`sf_cnt`). A Req that would take
a line from Invalid to Any or Shared with the filter full waits at the FIFO head while the device
evicts a victim (the next line not Invalid from a round-robin pointer): BISnpInv, then the
BIRsp. An RwD that would do so with the filter full leaves the line Invalid. Device request:
`bi_valid` && `bi_ready`; a line already Invalid completes at once (`bi_done`, state 0), else a
BISnp is sent and the BIRsp awaited, then `bi_done` with the new state. One BISnp is
outstanding at a time; BITAG steps through a 12-bit LFSR (x^12 + x^11 + x^10 + x^4 + 1) from 1,
advancing per BISnp. A Req to the line of the outstanding BISnp waits; RwD messages do not.
Without bi_en `bi_ready` is low and nothing is evicted.

### 3.10 Memory

LINES lines of 64 bytes, zero after reset, with a poison bit and meta state per line. DPA =
ADDR - hdm_base (modulo 2^16).

### 3.11 Reset

All buffers empty, all credits owed to the host, host credits 0, SEQ counters 0, memory / poison /
meta 0, `tx_valid` 0, BITAG 1, all pulses 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `LINES` | 16 | power of 2, 2..256 | device memory in lines |
| `RQD` | 4 | power of 2, 4..8 | Req FIFO entries (Req credits) |
| `WQD` | 2 | power of 2, 2..8 | RwD buffers (RwD credits) |
| `SFE` | 4 | 1..LINES | snoop filter capacity |
| `IOD` | 2 | power of 2, 2..8 | CXL.io receive flit buffers (CXL.io credits) |

## 5. Errors and corner cases

Events are one-clock pulses in the clock the problem is handled: `ev_crc` / `ev_seq` / `ev_fmt`
(TYPE 3) at the clock after the last beat; `ev_fmt` (unit), `ev_ovf` at the unit; `ev_range`,
`ev_opcode`, `ev_proto`, `ev_poison` when the request is served (BIRsp: when taken).

- A host that sends without credit loses the message (`ev_ovf`), never another buffer.
- SEQ errors are reported but the flit is used (no retry).
- An RwD MemWrPtl with all enables 0 still completes and still ORs in POISON.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| a_tx | `tx_valid` / `tx_data` equal the checker's flit model every clock | §3.2, §3.4 |
| a_io_tx_ready | `io_tx_ready` as the model | §3.6 |
| a_io_rx | `io_rx_valid` / `io_rx_data` / `io_rx_last` as the model | §3.6 |
| a_bi_ready | `bi_ready` as the model | §3.9 |
| a_bi_done | `bi_done` / `bi_state` as the model | §3.9 |
| a_sf_cnt | `sf_cnt` as the model | §3.9 |
| a_events | every `ev_*` pulse as the model | §5 |
| a_reset | reset values | §3.11 |
