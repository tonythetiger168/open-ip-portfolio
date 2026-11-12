<!-- SPDX-License-Identifier: Apache-2.0 -->
# CHI: design specification

AMBA CHI subordinate node (SN-F) in front of a small memory. It handles ReadNoSnp, WriteNoSnpPtl
and WriteNoSnpFull over the CHI link-layer channels RXREQ, RXDAT (in) and TXRSP, TXDAT (out) with
L-Credit flow control, serves requests in order, keeps up to two writes waiting for data, and
answers bad addresses with DERR and unsupported requests with NDERR. Flit fields follow CHI Issue B,
narrowed (16-bit address, 7-bit node IDs). Not implemented: snoops and coherence, other opcodes,
retry / protocol credits, DMT / DWT, CompAck, link activation, QoS, poison, data check. Core
`CHI_top` (`rtl/CHI_top.sv`), testbench `tb/CHI_tb.sv` (a home-node model), checker
`tb/cov/CHI_sva.sv` (a cycle-exact model of every output).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Every output is registered: what the core decides from the inputs
and its state in clock n appears on the outputs in clock n+1. A flit or credit is a one-clock
pulse of its valid.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of everything, including the memory (cleared to 0) | low | async | - |
| `rxreqflitv` | input | 1 | RXREQ flit valid: one clock per flit; needs an L-Credit held by the sender (§3.1) | high | `clk` | - |
| `rxreqflit` | input | 41 | REQ flit {SrcID[6:0], TxnID[7:0], Opcode[5:0], Order, Size[2:0], Addr[15:0]} (bits 40:0) | - | `clk` | - |
| `rxreqlcrdv` | output | 1 | RXREQ L-Credit: each clock it is 1 grants the sender one request credit | high | `clk` | 0 |
| `rxdatflitv` | input | 1 | RXDAT flit valid (write data) | high | `clk` | - |
| `rxdatflit` | input | 158 | DAT flit {TxnID[7:0], Opcode[3:0], DataID[1:0], BE[15:0], Data[127:0]}; TxnID carries the DBID | - | `clk` | - |
| `rxdatlcrdv` | output | 1 | RXDAT L-Credit: one data credit per clock it is 1 | high | `clk` | 0 |
| `txrspflitv` | output | 1 | TXRSP flit valid, one clock per flit | high | `clk` | 0 |
| `txrspflit` | output | 29 | RSP flit {TgtID[6:0], TxnID[7:0], Opcode[3:0], RespErr[1:0], DBID[7:0]} | - | `clk` | 0 |
| `txrsplcrdv` | input | 1 | TXRSP L-Credit from the receiver: one per clock it is 1 | high | `clk` | - |
| `txdatflitv` | output | 1 | TXDAT flit valid (CompData) | high | `clk` | 0 |
| `txdatflit` | output | 147 | DAT flit {TgtID[6:0], TxnID[7:0], RespErr[1:0], DataID[1:0], Data[127:0]}; always CompData with Resp UC (not on the port) | - | `clk` | 0 |
| `txdatlcrdv` | input | 1 | TXDAT L-Credit from the receiver | high | `clk` | - |
| `ev_err` | output | 1 | one-clock pulse with the first response of a request answered DERR or NDERR (§3.6) | high | `clk` | 0 |
| `ev_proto` | output | 1 | one-clock pulse in the clock after a flit was dropped (no credit, or unexpected data) | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name to steer its stimulus; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `rqw` | `log2(RQ)`+1 | request queue write pointer (with wrap bit) |
| `rqr` | `log2(RQ)`+1 | request queue read pointer; `rqw - rqr` = requests held |
| `rq_g` | `log2(RQ)`+1 | request credits the sender holds (granted, not yet used) |
| `w_v` | 2 | write buffer b is allocated (between its DBID response and its completion) |
| `w_comp` | 2 | write buffer b owes a Comp (all its data is in) |
| `c_rsp` | 4 | TXRSP credits held |
| `beat` | 2 | CompData beats already sent for the head read |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/CHI.md`](../ip/CHI.md) (source: `scripts/apb/specs/CHI.json`); do not edit by hand.

`CHI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxreqflitv`, `rxreqflit`, `rxreqlcrdv`, `rxdatflitv`, `rxdatflit`, `rxdatlcrdv`, `txrspflitv`, `txrspflit`, `txrsplcrdv`, `txdatflitv`, `txdatflit`, `txdatlcrdv`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43480200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4348 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a request got an error response: DERR (address beyond the memory) or NDERR (opcode or size not supported) |
| 1 | PROTO | a flit was dropped: it came without an L-Credit, or it was write data not expected (opcode, DBID or DataID) |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43480200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Link-layer credits

* RXREQ: the core pulses `rxreqlcrdv` (at most one per clock) while the credits the sender holds,
  plus the requests in the queue, plus a request arriving this clock, are fewer than `RQ`. So the
  sender never holds more credits than free slots. A request flit consumes one credit; a request
  flit while the sender holds none is dropped and pulses `ev_proto`.
* RXDAT: the core pulses `rxdatlcrdv` (at most one per clock) until the sender holds `NDC`
  credits; each data flit uses one (if the sender holds any). Data is written as it arrives, so
  data credits never wait on the memory.
* TXRSP / TXDAT: each `txrsplcrdv` / `txdatlcrdv` pulse adds one credit (counters of 4 bits; the
  receiver gives at most 15). A credit received in clock n can be used from clock n+1. Each
  TXRSP / TXDAT flit uses one credit; with no credit the flit waits.
* After reset the core starts granting credits in the first clock out of reset; it holds no TX
  credits.

### 3.2 Address, size and data beats

The memory has `LINES` 64-byte lines at byte addresses 0 .. `LINES` x 64 - 1; a line is 4 beats of
16 bytes, beat DataID = `Addr[5:4]`. An address is in range when `Addr[15:6]` < `LINES`.

| Size | Beats (DataID) |
|---|---|
| 0 .. 4 | one beat: `Addr[5:4]` |
| 5 | two beats: `{Addr[5], 0}` and the next |
| 6 | four beats: 0 .. 3 |
| 7 | illegal (NDERR, §3.6) |

### 3.3 Request queue and the head

Requests enter an `RQ`-slot FIFO and are served strictly in order; the oldest is the head. In each
clock at most one TXRSP flit and at most one TXDAT flit go out. TXRSP priority: a Comp owed by a
write buffer first (buffer 0 before 1), else the head's response.

| Head request | TXRSP | TXDAT | Head leaves the queue |
|---|---|---|---|
| ReadNoSnp (opcode 04h), Order = 1 | ReadReceipt (8h), RespErr 00, DBID 0, first | then CompData beats | after its last CompData |
| ReadNoSnp, Order = 0 | - | CompData beats, one per clock with a TXDAT credit | after its last CompData |
| WriteNoSnpPtl (1Ch), Size != 7 | DBIDResp (6h) when a write buffer is free | - | with the DBIDResp |
| WriteNoSnpFull (1Dh), Size = 6 | CompDBIDResp (5h) when a write buffer is free | - | with the CompDBIDResp |
| anything else | Comp (4h) RespErr NDERR | - | with the Comp |

* Every response carries TgtID = the request's SrcID and the request's TxnID. CompData beats go
  in DataID order from the first beat of §3.2; CompData starts no earlier than the clock after the
  ReadReceipt. ReadReceipt and CompData of different requests never mix: the head must finish
  first.
* Reads take their data from the memory when each beat is sent, so a read sees every write whose
  data arrived before.

### 3.4 Writes

* The DBID response allocates write buffer b (b = 0 if free, else 1): DBID = `{b, TxnID[6:0]}`,
  RespErr DERR if the address is out of range. It records which beats the Size needs. With both
  buffers allocated a write head waits.
* RXDAT flits are matched by TxnID (= DBID): bit 7 selects the buffer. A flit is taken when its
  opcode is NonCopyBackWrData (3h), `TxnID[6:0]` equals the buffer's TxnID, and its DataID is one
  the buffer needs and has not received yet. Its bytes with BE[k] = 1 are written to the memory at
  once (unless the write is out of range). Beats may come in any DataID order and interleaved
  between the two buffers.
* When the last needed beat arrives: WriteNoSnpPtl owes a Comp (4h, RespErr DERR if out of range,
  DBID 0), sent with the next TXRSP credit ahead of any head response, which frees the buffer;
  WriteNoSnpFull frees the buffer at once (its CompDBIDResp was the completion).
* Any other RXDAT flit (wrong opcode, a DBID not waiting, a DataID not needed or already received)
  is dropped and pulses `ev_proto`.

### 3.5 Throughput

With credits available: one request can be taken per clock; a head read sends one CompData per
clock; a head write is answered in one clock; a Comp and a CompData can go out in the same clock.

### 3.6 Errors and events

| Case | Response | `ev_err` |
|---|---|---|
| ReadNoSnp out of range | every CompData beat RespErr DERR (10), data 0 | with the first CompData |
| ReadNoSnp Size 7 | one CompData beat (DataID `Addr[5:4]`), RespErr NDERR (11), data 0 | with it |
| WriteNoSnpPtl / Full out of range | DBIDResp / CompDBIDResp RespErr DERR; data accepted and dropped; Ptl's Comp also DERR | with the DBID response |
| WriteNoSnpPtl Size 7, WriteNoSnpFull Size != 6, other opcode | Comp RespErr NDERR | with the Comp |

`ev_proto` pulses in the clock after a dropped RXREQ or RXDAT flit (one pulse if both in a clock).

### 3.7 Reset

While `rst_n` is low: every output 0, queue and buffers empty, all credit counters 0, memory 0.
Traffic in flight is lost; the sender must also forget its credits.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `LINES` | 16 | power of 2, 1 to 1024 | memory size in 64-byte lines |
| `RQ` | 4 | power of 2, 2 or more | request slots (and maximum request credits) |
| `NDC` | 2 | 1 to 7 | RXDAT credits granted |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| request without a credit | dropped, `ev_proto` |
| data flit for a DBID not waiting, wrong opcode, or a repeated / unneeded DataID | dropped, `ev_proto` |
| data flit sent without a data credit to a waiting buffer | still taken (the credit count stays at 0); the sender must not do this |
| both write buffers allocated | the next write head waits; reads behind it wait too (in order) |
| two Comps owed | buffer 0's first |
| no TXRSP / TXDAT credits | flits wait; with request slots full the RXREQ credits stop |
| BE all zero | beat counted as received, nothing written |
| reset with traffic in flight | everything cleared, memory too |

## 6. TB check map

Messages are printed by `tb/CHI_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/CHI_sva.sv`, which computes the exact expected value of every output in every
clock. The TB is a home node: it sends ReadNoSnp (with and without Order), WriteNoSnpPtl and Full
of every Size, other opcodes, addresses in and out of range, random SrcIDs and unique TxnIDs;
write data in random DataID order, interleaved, with random byte enables; error flits (no credit,
wrong opcode, unknown DBID, unexpected or repeated DataID); it starves the node of TX credits,
gives it the full 15, and resets with traffic in flight. A reference memory predicts every
CompData.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "RSP for TxnID" | every RSP answers an outstanding transaction | §3.3 |
| "RSP TgtID" | RSP TgtID = the request's SrcID | §3.3 |
| "TxnID" | per transaction: the right RSP opcode / RespErr in order (no RSP for an unordered read, DBIDResp then Comp after the data, CompDBIDResp, Comp NDERR), CompData only after ReadReceipt, DAT RespErr, DataID order, data | §3.3, §3.4, §3.6 |
| "DAT for TxnID" | every CompData answers an outstanding read | §3.3 |
| "DAT TgtID" | CompData TgtID = SrcID | §3.3 |
| "the request slots never filled" | with TX credits starved, the queue fills to `RQ` and request credits stop | §3.1 |
| "two Comps never owed at once" | both buffers can owe a Comp at once | §3.4 |
| a_credits | `rxreqlcrdv` / `rxdatlcrdv` exactly as the credit model | §3.1 |
| a_rsp | `txrspflitv` and `txrspflit` exactly as the model | §3.3, §3.4 |
| a_dat | `txdatflitv` and `txdatflit` exactly as the model | §3.3 |
| a_events | `ev_err` / `ev_proto` exactly as the model | §3.6 |
| a_reset | in reset every output 0 | §3.7 |
