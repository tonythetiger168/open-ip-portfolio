# NVMe controller command engine: one I/O submission / completion queue pair, Write, Read and Flush on a small namespace, completions with phase tag and status, a host memory master

Protocol IP `NVMe`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `NVMe_top` (`rtl/NVMe_top.sv`) |
| Register interface | APB4 slave `NVMe_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x4E560200 (code 0x4E56, version 2.0) |
| Registers | 10 words, 0x000 to 0x024 |
| Interrupts | 3 sources into one level-high `irq` |
| Data streams | SQ_DB (to the core), CQ_DB (to the core) |
| Protocol pins | 7 pass-through |

## Overview

NVMe_top v2.0: NVMe controller command engine for one I/O submission / completion queue pair and one small namespace, with a host memory master

- Host memory: a 32-bit request channel (valid / ready; m_req_we, a
dword address, write data) and an in-order read response (m_rsp_valid,
no ready). Writes have no response. All addresses here are dword
addresses (byte address bits 17:2).
- Controller enable: while cc_en is low the controller is off
(csts_rdy low) and its queue pointers are zero. Raising cc_en makes it
ready. Dropping cc_en while a command runs aborts it: no new memory
request is made, a request already on the channel stays until it is
taken, the read responses still owed are waited for, then csts_rdy
falls. sq_base, cq_base and the namespace keep their values.
- Queues: QD entries each, at sq_base (64-byte entries) and cq_base
(16-byte entries). The host writes the SQ tail doorbell (sq_db_valid,
sq_db) and the CQ head doorbell (cq_db_valid, cq_db). A doorbell
value of QD or more, or a doorbell written while the controller is not
ready, is ignored with ev_db (NVMe's invalid doorbell write).
- Commands are taken one at a time, in order. The engine reads dwords
0, 1, 6, 7, 10, 11 and 12 of the entry (CDW0, NSID, PRP1, CDW10 to
CDW12), moves the SQ head past it and checks it, in this order:
opcode not Flush 00h, Write 01h or Read 02h: Invalid Opcode (01h);
FUSE or PSDT not zero: Invalid Field (02h); NSID not 1 (Flush also
takes FFFFFFFFh): Invalid Namespace (0Bh); Read and Write only: PRP1
bits 1:0 not zero: PRP Offset Invalid (13h); SLBA + NLB beyond the
namespace: LBA Out of Range (80h); PRP1 beyond the 256 KiB host
window (bits 63:18 not zero): Data Transfer Error (04h). All are
generic status (SCT 0); an error sets DNR.
- Write moves (NLB + 1) * BLKDW dwords from host memory at PRP1 into
the namespace at SLBA, Read the other way; Flush moves nothing. The
buffer is contiguous (PRP2 and page boundaries are not used); its
dword addresses wrap within the window.
- Completion: 4 dwords at the CQ tail: DW0 and DW1 zero, DW2 the SQ head
and SQ identifier 1, DW3 the command identifier, phase tag (1 on the
first pass, inverted on each wrap), status code and DNR. The engine
waits while the CQ is full (tail + 1 = head). ev_cqe pulses as the
entry is posted (an MSI); ev_err with it when the status is not
success.
Not implemented: the PCIe function and its register file (the
controller registers are ports here), the admin queue and its commands,
more than one I/O queue, PRP lists and SGLs, fused commands, metadata,
protection information, the 512-byte minimum LBA size (blocks are
BLKDW dwords), arbitration bursts, interrupt coalescing, shutdown
notification. Field encodings follow NVMe 1.4 as we read them; they have
not been checked against a compliant host.

m_req_* and m_rsp_* are the host memory master (dword addresses); they pass through unchanged.
The core parameters QD (8 entries per queue), NBLK (8 blocks) and BLKDW (4 dwords per block) keep their defaults; the namespace is zero after reset.

## Files

| File | Content |
|---|---|
| `rtl/NVMe_top.sv` | protocol core |
| `rtl/NVMe_apb.sv` | APB4 register wrapper (generated) |
| `tb/NVMe_tb.sv` | core testbench |
| `tb/NVMe_apb_tb.sv`, `tb/apb/NVMe_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/NVMe_sva.sv`, `tb/cov/NVMe_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/NVMe.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.NVMe sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.NVMe apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh NVMe          # core coverage (Verilator)
bash scripts/cov/run_cov.sh NVMe_apb      # wrapper coverage
```

## Parameters

`NVMe_apb` has the core's parameters and passes them to `NVMe_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `QD` | int | `8` |
| `NBLK` | int | `8` |
| `BLKDW` | int | `4` |

## Wrapper pins

Pins of `NVMe_apb`. Widths of the pass-through pins are at the default parameters.

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
| `m_req_valid` | output | 1 | protocol pin, core port `m_req_valid` |
| `m_req_ready` | input | 1 | protocol pin, core port `m_req_ready` |
| `m_req_we` | output | 1 | protocol pin, core port `m_req_we` |
| `m_req_addr` | output | 16 | protocol pin, core port `m_req_addr` |
| `m_req_wdata` | output | 32 | protocol pin, core port `m_req_wdata` |
| `m_rsp_valid` | input | 1 | protocol pin, core port `m_rsp_valid` |
| `m_rsp_data` | input | 32 | protocol pin, core port `m_rsp_data` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cc_en` | input | 1 | CC |
| `csts_rdy` | output | 1 | CSTS[0:0] |
| `sq_base` | input | 16 | QBASE[15:0] |
| `cq_base` | input | 16 | QBASE[31:16] |
| `sq_db_valid` | input | 1 | SQ_DB commit / FLAGS |
| `sq_db` | input | 16 | SQ_DB[15:0] |
| `cq_db_valid` | input | 1 | CQ_DB commit / FLAGS |
| `cq_db` | input | 16 | CQ_DB[15:0] |
| `sq_head` | output | 3 | CSTS[3:1] |
| `cq_tail` | output | 3 | CSTS[6:4] |
| `m_req_valid` | output | 1 | pin (pass-through) |
| `m_req_ready` | input | 1 | pin (pass-through) |
| `m_req_we` | output | 1 | pin (pass-through) |
| `m_req_addr` | output | 16 | pin (pass-through) |
| `m_req_wdata` | output | 32 | pin (pass-through) |
| `m_rsp_valid` | input | 1 | pin (pass-through) |
| `m_rsp_data` | input | 32 | pin (pass-through) |
| `ev_cqe` | output | 1 | IRQ_STATUS.CQE |
| `ev_err` | output | 1 | IRQ_STATUS.ERR_CMD |
| `ev_db` | output | 1 | IRQ_STATUS.ERR_DB |

## APB wrapper

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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4E560200.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CC (0x014), QBASE (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To send on SQ_DB: write SQ_DB (0x01C). The last write pulses `sq_db_valid` for one clock; there is no back-pressure.
6. To send on CQ_DB: write CQ_DB (0x020). The last write pulses `cq_db_valid` for one clock; there is no back-pressure.
7. Read CSTS (0x024) for the core's live `csts_rdy`, `sq_head`, `cq_tail`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/NVMe_top.sv` | pass | 68/68 | 602/602 | 17/17 | 5/5 | 119/119 |
| wrapper `rtl/NVMe_apb.sv` | pass | 32/32 | 868/868 | n/a | 14/14 | 43/43 |
