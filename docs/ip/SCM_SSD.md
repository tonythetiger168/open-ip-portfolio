# SCM dual-mode SSD controller slice: NVMe 2.1-style multi-queue block mode with Flexible Data Placement, plus a CXL.mem-style byte port onto the SCM region

Protocol IP `SCM_SSD`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SCM_SSD_top` (`rtl/SCM_SSD_top.sv`) |
| Register interface | none yet: the controller registers are ports (no APB wrapper in v1.0) |
| Clock, reset | clk (rising edge), rst_n (active low, asynchronous) |
| Queues | NQ = 4 I/O submission / completion queue pairs, QD = 8 entries each, round robin |
| Namespaces | 1: SCM region (NBS = 8 blocks), 2: NAND region (NBN = 16 blocks), BLKDW = 4 dwords per block |
| FDP | NRUH = 4 reclaim unit handles, RUB = 4 blocks per reclaim unit |
| Media latency | TSCM = 2, TRD = 12, TPROG = 24 clocks |
| Byte port | tagged load / store, dword granularity, SCM region only |

## Why this IP

The Helios KV-cache chip plan puts an SCM dual-mode SSD below DRAM as the
KV capacity tier: hot, small KV pages in the SCM region (byte-addressable
over CXL.mem, or 512-byte NVMe reads on an XL-FLASH-class drive), cold pages
in the NAND region, written through FDP placement handles so pages with the
same lifetime share reclaim units and garbage collection does not multiply
SSD writes. This core is a cycle-level slice of that device for the Helios
testbench and FPGA work: the KV tiering engine can be verified against it
before real drives are attached. `NVMe_top` (one queue pair, no FDP) is left
unchanged; this is a separate IP so its ports stay stable.

## Overview

SCM_SSD_top v1.0: dual-mode SCM SSD controller slice. One device, two
media regions and two host views:
  - block mode: an NVMe 2.1-style I/O command engine with NQ submission /
    completion queue pairs (round-robin arbitration), Write, Read and
    Flush, and Flexible Data Placement (FDP) on the NAND namespace
  - byte mode: a CXL.mem-style load / store port (tagged requests and
    responses) straight onto the SCM region, the same cells namespace 1
    reads and writes
Modelled on an SCM-class (low-latency flash) plus TLC NAND drive behind
PCIe 6.0 / CXL 3.x; the PCIe and CXL link layers are separate IPs
(PCIe_top, CXL_top) and are not part of this core.
 - Host memory master: as NVMe_top (32-bit request channel, valid /
   ready; in-order read responses, no ready; dword addresses, a 256 KiB
   window).
 - Controller enable: while cc_en is low the controller is off
   (csts_rdy low) and every queue pointer is zero. Raising cc_en makes it
   ready. Dropping cc_en while a command runs aborts it as NVMe_top does
   (no new request, the request on the channel and the reads owed are
   waited for, then csts_rdy falls). The media keep their contents.
 - Queues: NQ pairs, QD entries each; pair q (queue identifier q + 1)
   has its SQ at sq_base[16q +: 16] (64-byte entries) and its CQ at
   cq_base[16q +: 16] (16-byte entries). Doorbells carry the pair index
   (sq_db_qid, cq_db_qid). A value of QD or more, or a write while not
   ready, is ignored with ev_db.
 - Arbitration: round robin over the pairs whose SQ is not empty,
   starting after the pair served last; one command at a time.
 - Commands: the engine reads dwords 0, 1, 6, 7, 10, 11, 12 and 13 of the
   entry (CDW0, NSID, PRP1, CDW10 to CDW13), moves that SQ's head past it
   and checks, in this order: opcode not Flush 00h, Write 01h or Read
   02h: Invalid Opcode (01h); FUSE or PSDT not zero: Invalid Field (02h);
   NSID not 1 or 2 (Flush also takes FFFFFFFFh): Invalid Namespace (0Bh);
   Write only, CDW12 DTYPE (bits 23:20) not 0 or 2, DTYPE 2 on namespace
   1, or DTYPE 2 with a placement handle (CDW13 DSPEC, bits 31:16) of
   NRUH or more: Invalid Field (02h); Read and Write: PRP1 bits 1:0 not
   zero: PRP Offset Invalid (13h); SLBA + NLB beyond the namespace: LBA
   Out of Range (80h); PRP1 beyond the window: Data Transfer Error (04h).
   All generic status (SCT 0); an error sets DNR.
 - Namespaces: 1 = SCM region (NBS blocks), 2 = NAND region (NBN
   blocks), BLKDW dwords per block. Media latency, in clocks: a Read waits
   TSCM (namespace 1) or TRD (namespace 2) before its data moves; a
   Write waits TSCM or TPROG after its data has moved, before the
   completion. A NAND block never written reads as zero.
 - FDP: NRUH reclaim unit handles, each with a reclaim unit of RUB
   blocks. A Write to namespace 2 goes to the handle in DSPEC when DTYPE
   is 2, else to handle 0. When it completes, its NLB + 1 blocks are
   added to the handle's fill count; when that reaches RUB the unit is
   full, a new one opens (the count keeps the remainder) and ev_ru pulses
   with ev_ru_h = the handle. ru_fill shows each handle's count;
   nand_blks and scm_blks count the blocks written to each region.
 - Completion: 4 dwords at the CQ tail of the command's pair: DW0, DW1
   zero, DW2 {SQ identifier q + 1, SQ head}, DW3 {DNR, 6'b0, status
   code, phase tag, command identifier}. The engine waits while that CQ
   is full. ev_cqe pulses with ev_cqe_qid = q (an MSI-X vector per pair);
   ev_err with it when the status is not success.
 - Byte port: b_req_valid / b_req_ready, b_req_we, b_req_tag, b_req_addr
   (dword index into the SCM region), b_req_wdata. One request at a time:
   TSCM clocks after it is taken the port answers with b_rsp_valid (one
   clock, no ready), b_rsp_tag, b_rsp_data (the dword for a read, zero
   for a write) and b_rsp_err when the address is beyond the region
   (nothing is written). Byte-port stores and namespace 1 Writes hit the
   same cells; if both write one dword in the same clock, the byte port's
   value lands. The byte port works while the controller is disabled.
 Not implemented: the admin queue (no Identify, Get Log Page or FDP
 event log; the FDP configuration is fixed by parameters), PRP lists and
 SGLs, metadata and protection information, the 512-byte minimum LBA
 size, weighted round robin and urgent queues, wear levelling, garbage
 collection, reclaim-unit erase, power-loss protection. Field encodings
 follow NVMe 2.1 as we read them; they have not been checked against a
 compliant host.
## Files

| File | Content |
|---|---|
| `rtl/SCM_SSD_top.sv` | core |
| `tb/SCM_SSD_tb.sv` | self-checking testbench (host model, reference namespaces and FDP fill counts, byte-port master) |
| `syn/SCM_SSD_yosys.ys`, `syn/SCM_SSD_dc.tcl`, `syn/SCM_SSD.sdc` | synthesis |
| `sim/filelist_SCM_SSD.f` | file list |

## Running and verifying

```
make -f Makefile.SCM_SSD sim     # iverilog: ends with TEST PASSED: SCM_SSD
make -f Makefile.SCM_SSD syn     # yosys 0.33
python3 scripts/lint/strict_elab.py SCM_SSD
```

The testbench runs about 500 commands over the four pairs (valid traffic,
malformed commands of every status code, CQs left full, invalid doorbells,
round robin with every SQ loaded, FDP writes across reclaim units including
invalid placement handles and FDP on the SCM namespace), 2000 byte-port
accesses on the upper half of the SCM region while block traffic uses the
lower half, a dual-mode phase where block writes are read through the byte
port and byte stores are read back as blocks, exact media latency checks,
and a disable / re-enable. It was checked against mutants of the round
robin, FDP fill and wrap, DTYPE / DSPEC checks, SQ identifier, phase tag,
CQ-full wait, media and byte-port latency, byte-port errors and namespace
routing; each is caught.

## Open items

- APB register wrapper and spec (`scripts/apb/specs/SCM_SSD.json`) and the
  coverage checker `tb/cov/SCM_SSD_sva.sv` for the five-metric flow.
- Admin queue with Identify, Get Log Page (FDP configurations, reclaim
  unit handle usage, FDP events) and Set Features; 512-byte LBAs.
