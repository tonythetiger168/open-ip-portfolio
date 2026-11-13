<!-- SPDX-License-Identifier: Apache-2.0 -->
# NVMe: design specification

An NVMe controller command engine for one I/O submission / completion queue pair and one small
namespace held in the core, with a host memory master. Not implemented: the PCIe function and
its register file (the controller registers are ports here), the admin queue, more than one I/O
queue, PRP lists and SGLs, fused commands, metadata, protection information, 512-byte blocks
(blocks are `BLKDW` dwords), arbitration bursts, interrupt coalescing, shutdown notification.
Field encodings follow NVMe 1.4 but have not been checked against a compliant host. Core
`NVMe_top` (`rtl/NVMe_top.sv`), testbench `tb/NVMe_tb.sv` (a host model with its own memory),
checker `tb/cov/NVMe_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; registered outputs show a
decision of clock n in clock n+1. All addresses are dword addresses.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset (also clears the namespace) | low | async | - |
| `cc_en` | input | 1 | CC.EN: enable the controller | high | `clk` | - |
| `csts_rdy` | output | 1 | CSTS.RDY: ready (not off, not aborting); combinational | high | comb | 0 |
| `sq_base` | input | 16 | dword address of the submission queue | - | `clk` | - |
| `cq_base` | input | 16 | dword address of the completion queue | - | `clk` | - |
| `sq_db_valid` | input | 1 | SQ tail doorbell write | high | `clk` | - |
| `sq_db` | input | 16 | new SQ tail | - | `clk` | - |
| `cq_db_valid` | input | 1 | CQ head doorbell write | high | `clk` | - |
| `cq_db` | input | 16 | new CQ head | - | `clk` | - |
| `sq_head` | output | `log2(QD)` | SQ head (next entry to fetch) | - | `clk` | 0 |
| `cq_tail` | output | `log2(QD)` | CQ tail (next entry to post) | - | `clk` | 0 |
| `m_req_valid` | output | 1 | host memory request | high | `clk` | 0 |
| `m_req_ready` | input | 1 | the request is taken | high | `clk` | - |
| `m_req_we` | output | 1 | 1 write, 0 read | - | `clk` | 0 |
| `m_req_addr` | output | 16 | dword address (byte address bits 17:2) | - | `clk` | 0 |
| `m_req_wdata` | output | 32 | write data | - | `clk` | 0 |
| `m_rsp_valid` | input | 1 | read response, in request order, no back-pressure | high | `clk` | - |
| `m_rsp_data` | input | 32 | read data | - | `clk` | - |
| `ev_cqe` | output | 1 | one-clock pulse: a completion entry was posted (MSI) | high | `clk` | 0 |
| `ev_err` | output | 1 | with `ev_cqe`: the status is not success | high | `clk` | 0 |
| `ev_db` | output | 1 | one-clock pulse: an invalid doorbell write was ignored | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name (to compare the namespace and to time a disable in each engine state);
the FSM coverage collector binds `st`.

| Signal | Width | Meaning |
|---|---|---|
| `mem` | `NBLK` x `BLKDW` x 32 | the namespace, dword `mem[lba * BLKDW + i]` |
| `st` | 3 | 0 OFF, 1 IDLE, 2 FETCH, 3 DECODE, 4 TRANSFER, 5 COMPLETE, 6 ABORT |
| `ri` | `log2(NBLK*BLKDW)`+1 | memory requests issued in this phase |
| `rr` | `log2(NBLK*BLKDW)`+1 | read responses received in this phase |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/NVMe.md`](../ip/NVMe.md) (source: `scripts/apb/specs/NVMe.json`); do not edit by hand.

`NVMe_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `m_req_valid`, `m_req_ready`, `m_req_we`, `m_req_addr`, `m_req_wdata`, `m_rsp_valid`, `m_rsp_data`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4E560200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CC | RW | 0x00000000 | Controller configuration |
| 0x018 | QBASE | RW | 0x00000000 | Queue bases, dword addresses in host memory (change them only while CC.cc_en and CSTS.csts_rdy are 0) |
| 0x01C | SQ_DB | RW | 0x00000000 | Submission queue tail doorbell: writing it gives the new tail (0..7); a value of 8 or more, or a write while not ready, is ignored with ERR_DB |
| 0x020 | CQ_DB | RW | 0x00000000 | Completion queue head doorbell: writing it gives the new head (0..7); a value of 8 or more, or a write while not ready, is ignored with ERR_DB |
| 0x024 | CSTS | RO | core | Controller status |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4E56 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CC | 0 | `cc_en` | RW | 0x0 | enable; clearing it aborts the command in progress and zeroes the queue pointers once the memory reads owed have returned |
| QBASE | 15:0 | `sq_base` | RW | 0x0 | submission queue (QD = 8 entries of 64 bytes) |
| QBASE | 31:16 | `cq_base` | RW | 0x0 | completion queue (QD = 8 entries of 16 bytes) |
| SQ_DB | 15:0 | `sq_db` | RW | 0x0 | new SQ tail |
| CQ_DB | 15:0 | `cq_db` | RW | 0x0 | new CQ head |
| CSTS | 0 | `csts_rdy` | RO | core | ready: enabled and not aborting |
| CSTS | 3:1 | `sq_head` | RO | core | SQ head: the next entry the controller fetches |
| CSTS | 6:4 | `cq_tail` | RO | core | CQ tail: where the next completion goes |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CQE | a completion entry was posted |
| 1 | ERR_CMD | a completion with an error status was posted |
| 2 | ERR_DB | an invalid doorbell write was ignored |

### Streams

* **SQ_DB** feeds `sq_db`; writing SQ_DB pulses `sq_db_valid` for one clock.
* **CQ_DB** feeds `cq_db`; writing CQ_DB pulses `cq_db_valid` for one clock.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4E560200.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CC (0x014), QBASE (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To send on SQ_DB: write SQ_DB (0x01C). The last write pulses `sq_db_valid` for one clock; there is no back-pressure.
6. To send on CQ_DB: write CQ_DB (0x020). The last write pulses `cq_db_valid` for one clock; there is no back-pressure.
7. Read CSTS (0x024) for the core's live `csts_rdy`, `sq_head`, `cq_tail`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Enable and doorbells

| State | Moves on |
|---|---|
| OFF | queue pointers and the phase are reset every clock; `cc_en` = 1 -> IDLE |
| IDLE | `cc_en` = 0 -> OFF; SQ head != SQ tail -> FETCH |
| FETCH, DECODE, TRANSFER, COMPLETE | `cc_en` = 0 -> ABORT |
| ABORT | no request on the channel and (the last request was a write, or every read was answered) -> OFF |

`csts_rdy` = not OFF and not ABORT. A doorbell write with a value >= `QD`, or while not ready, is
ignored with `ev_db`; otherwise it sets the SQ tail / CQ head at the edge. `sq_base`, `cq_base`
and the namespace keep their values across a disable.

### 3.2 Memory channel

A request is held on `m_req_*` until `m_req_ready`; the next one may be loaded at the same edge.
Requests are made only with `cc_en` = 1 in FETCH, TRANSFER, and COMPLETE (with the CQ not full).
Read responses come in order on `m_rsp_*`, one per clock at most.

### 3.3 Fetch and decode

FETCH reads dwords 0, 1, 6, 7, 10, 11, 12 of the SQ entry at `sq_base` + 16 x head (CDW0, NSID,
PRP1 low / high, CDW10..12). At the 7th response the SQ head + 1 and DECODE (one clock) checks, in
order (generic status, SCT 0; an error sets DNR):

| Status | SC | Condition |
|---|---|---|
| Invalid Opcode | 01h | opcode (CDW0[7:0]) not 00h Flush, 01h Write, 02h Read |
| Invalid Field | 02h | FUSE (CDW0[9:8]) or PSDT (CDW0[15:14]) not 0 |
| Invalid Namespace | 0Bh | NSID not 1 (Flush also takes FFFFFFFFh) |
| PRP Offset Invalid | 13h | Read / Write: PRP1 bits 1:0 not 0 |
| LBA Out of Range | 80h | Read / Write: SLBA (CDW11:CDW10) + NLB (CDW12[15:0]) beyond `NBLK` |
| Data Transfer Error | 04h | Read / Write: PRP1 bits 63:18 not 0 (outside the 256 KiB window) |

An error or a Flush goes to COMPLETE; a good Read / Write to TRANSFER.

### 3.4 Transfer

(NLB + 1) x `BLKDW` dwords at host address PRP1[17:2] + i (wrapping in 16 bits) and namespace
dword SLBA x `BLKDW` + i. Write command: host reads, each response written to the namespace;
done at the last response. Read command: host writes of namespace data; done when the last
request is accepted.

### 3.5 Completion

Waits while the CQ is full (tail + 1 = head). Writes 4 dwords at `cq_base` + 4 x tail: DW0 = 0,
DW1 = 0, DW2 = {SQ identifier 1, SQ head}, DW3 = {DNR = error, 6'b0, SC, phase, CID}. When the
4th write is accepted: CQ tail + 1 (the phase inverts on the wrap; it is 1 on the first pass),
`ev_cqe` pulses with `ev_err` = status not success, IDLE.

### 3.6 Reset

While `rst_n` is low: OFF, pointers 0, phase 1, namespace 0, no request, no events.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `QD` | 8 | power of 2, 4..16 | entries per queue |
| `NBLK` | 8 | power of 2, 2 or more | namespace size in blocks |
| `BLKDW` | 4 | power of 2, 2 or more | block size in dwords |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| doorbell value >= `QD` | ignored, `ev_db` |
| doorbell while off or aborting | ignored, `ev_db` |
| CQ full | the completion waits for a CQ head doorbell |
| `cc_en` dropped mid-command | ABORT: the request on the channel and owed reads finish, then OFF; no completion |
| several errors in one command | the first in the table order |
| host buffer crossing the window end | wraps within the 64 Ki-dword window |
| reset with traffic | everything cleared, namespace included |

## 6. TB check map

Messages are printed by `tb/NVMe_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/NVMe_sva.sv`. A host model builds Write, Read, Flush and malformed commands, rings
doorbells singly or in batches, polls the CQ by phase and rings the CQ head doorbell late (so the
CQ fills); its memory takes requests with random back-pressure and answers after random latency.
The controller is disabled in each engine state, re-enabled with new queue bases, given invalid
doorbells, and reset with traffic in flight.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "write to" | writes only to Read buffers in flight and to the CQ | §3.4, §3.5 |
| "completion with none expected" | one completion per command | §3.5 |
| "CQE DW0/DW1 not zero" | DW0 / DW1 = 0 | §3.5 |
| "CQE DW2" | SQ head and SQ identifier | §3.5 |
| "CQE CID" | CID, then status and DNR | §3.3, §3.5 |
| "Read CID" | Read data in the host buffer | §3.4 |
| "abort: state" | the disable lands in the intended engine state | §3.1 |
| "doorbell while off not flagged" | `ev_db` for doorbells while off | §3.1 |
| "status" | every status code is produced | §3.3 |
| "no free host memory" | the host model found buffer space (TB-internal) | - |
| a_req | memory requests exactly as the checker's model | §3.2..§3.5 |
| a_rdy | `csts_rdy` = not OFF / ABORT | §3.1 |
| a_ptrs | `sq_head` / `cq_tail` as the model | §3.1, §3.3, §3.5 |
| a_events | `ev_cqe` / `ev_err` / `ev_db` as the model | §3.1, §3.5 |
| a_reset | in reset: no request, not ready, pointers 0, no events | §3.6 |
