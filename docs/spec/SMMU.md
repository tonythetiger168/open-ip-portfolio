<!-- SPDX-License-Identifier: Apache-2.0 -->
# SMMU: design specification

A system MMU of the phone SoC: AXI4 subordinate in, AXI4 manager out, translating the address of
each burst through a single-level page table with 4 KB pages and a 4-entry TLB. Not implemented:
the Arm SMMUv3 architecture (stream tables, context descriptors, multi-level tables, queues),
more than one outstanding burst, stage 2. Core `SMMU_top` (`rtl/SMMU_top.sv`), testbench
`tb/SMMU_tb.sv` (an upstream master BFM, and a behavioural AXI4 memory holding the page table and
the data). There is no SVA checker for this core.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Many outputs are combinational from the state and the other port.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `enable` | input | 1 | 0: bypass (PA = VA) | high | static | - |
| `pt_base` | input | 32 | page table base address | - | static | - |
| `tlb_inv` | input | 1 | empty the TLB (CMD.tlb_inv) | high | `clk` | - |
| `fault_addr` | output | 32 | virtual address of the last fault | - | `clk` | 0 |
| `fault_info` | output | 4 | {walk_err, write, not_writable, not_valid} of the last fault | - | `clk` | 0 |
| `hits` | output | 16 | TLB hits, saturating | - | `clk` | 0 |
| `misses` | output | 16 | TLB misses, saturating | - | `clk` | 0 |
| `busy` | output | 1 | a burst is being handled; combinational from flops | high | `clk` | 0 |
| `fault` | output | 1 | one-clock pulse: a fault is recorded (FAULT interrupt) | high | `clk` | 0 |
| `s_awid` | input | 4 | upstream write address channel | - | `clk` | - |
| `s_awaddr` | input | 32 | upstream write address channel | - | `clk` | - |
| `s_awlen` | input | 8 | upstream write address channel | - | `clk` | - |
| `s_awsize` | input | 3 | upstream write address channel | - | `clk` | - |
| `s_awburst` | input | 2 | upstream write address channel | - | `clk` | - |
| `s_awprot` | input | 3 | upstream write address channel | - | `clk` | - |
| `s_awvalid` | input | 1 | upstream write address channel | - | `clk` | - |
| `s_awready` | output | 1 | write address taken (idle and the write is picked); combinational | high | comb | 0 |
| `s_wdata` | input | 32 | upstream write data | - | `clk` | - |
| `s_wstrb` | input | 4 | upstream write data | - | `clk` | - |
| `s_wlast` | input | 1 | upstream write data | - | `clk` | - |
| `s_wvalid` | input | 1 | upstream write data | - | `clk` | - |
| `s_wready` | output | 1 | write beat taken; combinational | high | comb | 0 |
| `s_bid` | output | 4 | write response ID (downstream, or the burst ID on a fault) | - | comb | 0 |
| `s_bresp` | output | 2 | write response (SLVERR on a fault) | - | comb | 0 |
| `s_bvalid` | output | 1 | write response valid | high | comb | 0 |
| `s_bready` | input | 1 | upstream takes the response | high | `clk` | - |
| `s_arid` | input | 4 | upstream read address channel | - | `clk` | - |
| `s_araddr` | input | 32 | upstream read address channel | - | `clk` | - |
| `s_arlen` | input | 8 | upstream read address channel | - | `clk` | - |
| `s_arsize` | input | 3 | upstream read address channel | - | `clk` | - |
| `s_arburst` | input | 2 | upstream read address channel | - | `clk` | - |
| `s_arprot` | input | 3 | upstream read address channel | - | `clk` | - |
| `s_arvalid` | input | 1 | upstream read address channel | - | `clk` | - |
| `s_arready` | output | 1 | read address taken; combinational | high | comb | 0 |
| `s_rid` | output | 4 | read data ID | - | comb | 0 |
| `s_rdata` | output | 32 | read data (0 on a fault) | - | comb | 0 |
| `s_rresp` | output | 2 | read response (SLVERR on a fault) | - | comb | 0 |
| `s_rlast` | output | 1 | last read beat | high | comb | 0 |
| `s_rvalid` | output | 1 | read data valid | high | comb | 0 |
| `s_rready` | input | 1 | upstream takes the beat | high | `clk` | - |
| `m_awid` | output | 4 | downstream write address (translated) | - | comb | 0 |
| `m_awaddr` | output | 32 | downstream write address (translated) | - | comb | 0 |
| `m_awlen` | output | 8 | downstream write address (translated) | - | comb | 0 |
| `m_awsize` | output | 3 | downstream write address (translated) | - | comb | 0 |
| `m_awburst` | output | 2 | downstream write address (translated) | - | comb | 0 |
| `m_awprot` | output | 3 | downstream write address (translated) | - | comb | 0 |
| `m_awvalid` | output | 1 | downstream write address valid | high | comb | 0 |
| `m_awready` | input | 1 | downstream takes it | high | `clk` | - |
| `m_wdata` | output | 32 | downstream write data (= upstream) | - | comb | - |
| `m_wstrb` | output | 4 | downstream write data (= upstream) | - | comb | - |
| `m_wlast` | output | 1 | downstream write data (= upstream) | - | comb | - |
| `m_wvalid` | output | 1 | downstream write beat valid | high | comb | 0 |
| `m_wready` | input | 1 | downstream takes it | high | `clk` | - |
| `m_bid` | input | 4 | downstream write response | - | `clk` | - |
| `m_bresp` | input | 2 | downstream write response | - | `clk` | - |
| `m_bvalid` | input | 1 | downstream write response | - | `clk` | - |
| `m_bready` | output | 1 | = `s_bready` while waiting for the response | high | comb | 0 |
| `m_arid` | output | 4 | downstream read address (translated burst or a walk) | - | comb | - |
| `m_araddr` | output | 32 | downstream read address (translated burst or a walk) | - | comb | - |
| `m_arlen` | output | 8 | downstream read address (translated burst or a walk) | - | comb | - |
| `m_arsize` | output | 3 | downstream read address (translated burst or a walk) | - | comb | - |
| `m_arburst` | output | 2 | downstream read address (translated burst or a walk) | - | comb | - |
| `m_arprot` | output | 3 | downstream read address (translated burst or a walk) | - | comb | - |
| `m_arvalid` | output | 1 | downstream read address valid | high | comb | 0 |
| `m_arready` | input | 1 | downstream takes it | high | `clk` | - |
| `m_rid` | input | 4 | downstream read data | - | `clk` | - |
| `m_rdata` | input | 32 | downstream read data | - | `clk` | - |
| `m_rresp` | input | 2 | downstream read data | - | `clk` | - |
| `m_rlast` | input | 1 | downstream read data | - | `clk` | - |
| `m_rvalid` | input | 1 | downstream read data | - | `clk` | - |
| `m_rready` | output | 1 | 1 during a walk; `s_rready` while passing read data | high | comb | 0 |

### Internal signals used by the verification

The TB reads `walk` to tell walk reads from forwarded reads.

| Signal | Width | Meaning |
|---|---|---|
| `walk` | 1 | the downstream read channel carries a page walk; combinational |

### Internal signals used by the coverage checker

`tb/cov/SMMU_sva.sv` is bound to `SMMU_top` with `.*`, so a re-implementation must have these
names (width as seen by the checker).

| Signal | Width | Meaning |
|---|---|---|
| `st` | 1 | core-internal signal read by name by the checker |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SMMU.md`](../ip/SMMU.md) (source: `scripts/apb/specs/SMMU.json`); do not edit by hand.

`SMMU_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `s_awid`, `s_awaddr`, `s_awlen`, `s_awsize`, `s_awburst`, `s_awprot`, `s_awvalid`, `s_awready`, `s_wdata`, `s_wstrb`, `s_wlast`, `s_wvalid`, `s_wready`, `s_bid`, `s_bresp`, `s_bvalid`, `s_bready`, `s_arid`, `s_araddr`, `s_arlen`, `s_arsize`, `s_arburst`, `s_arprot`, `s_arvalid`, `s_arready`, `s_rid`, `s_rdata`, `s_rresp`, `s_rlast`, `s_rvalid`, `s_rready`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C0A0100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Translation control |
| 0x018 | PT_BASE | RW | 0x00000000 | Page table base |
| 0x01C | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x020 | STATUS | RO | core | State |
| 0x024 | FAULT_ADDR | RO | core | Last fault |
| 0x028 | FAULT_INFO | RO | core | Last fault cause |
| 0x02C | TLB_STATS | RO | core | TLB counters (saturating) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C0A | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `enable` | RW | 0x0 | 1: translate, 0: bypass |
| PT_BASE | 31:0 | `pt_base` | RW | 0x0 | byte address of the PTE of page 0 |
| CMD | 0 | `tlb_inv` | WO (pulse) | 0x0 | invalidate every TLB entry |
| STATUS | 0 | `busy` | RO | core | a burst is in progress |
| FAULT_ADDR | 31:0 | `fault_addr` | RO | core | virtual address of the last faulting burst |
| FAULT_INFO | 3:0 | `fault_info` | RO | core | {walk_err, write, not_writable, not_valid} |
| TLB_STATS | 15:0 | `hits` | RO | core | lookups that hit |
| TLB_STATS | 31:16 | `misses` | RO | core | lookups that walked |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FAULT | a burst faulted |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C0A0100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), PT_BASE (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. To issue a command, write 1 to `tlb_inv` (CMD bit 0) at 0x01C; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x020) for the core's live `busy`; it needs no clearing.
7. Read FAULT_ADDR (0x024) for the core's live `fault_addr`; it needs no clearing.
8. Read FAULT_INFO (0x028) for the core's live `fault_info`; it needs no clearing.
9. Read TLB_STATS (0x02C) for the core's live `hits`, `misses`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Build the page table in memory, write PT_BASE, write CMD.tlb_inv = 1.
2. Write IRQ_ENABLE.FAULT = 1 and CTRL.enable = 1.
3. On a FAULT interrupt read FAULT_ADDR and FAULT_INFO, fix the table, write CMD.tlb_inv and clear IRQ_STATUS.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Page table

The entry of a page is the 32-bit word at `pt_base` + 4 x VA[31:12]: bit 0 VALID, bit 1 WRITABLE,
bits 31:12 the physical page number. PA = {PTE[31:12], VA[11:0]}. Bursts must not cross 4 KB, so
one translation covers the whole burst.

### 3.2 Burst flow

One burst at a time:

1. Idle: `s_arready` / `s_awready` = 1 for the picked request. A read is picked if `s_arvalid`
   and (no `s_awvalid` or the last burst was a write), else a write; so they alternate when both
   wait. The address and attributes are captured.
2. Lookup (one clock): with `enable` = 0, PA = VA. Else on a TLB hit (and no `tlb_inv` this
   clock) `hits` + 1 (not when the hit follows its own walk); a write to a non-writable page
   faults; otherwise PA is set. On a miss `misses` + 1 and a walk starts.
3. Walk: a single-beat read on m_AR (address `pt_base` + 4 x VPN, len 0, size 2, INCR, prot 010,
   ID `PTW_ID`), `m_rready` = 1. An error response or VALID = 0 faults. Otherwise the entry fills
   the next TLB slot in round-robin order and lookup runs again.
4. Issue: m_AR or m_AW with the translated address and the burst's own ID, length, size, burst
   and prot.
5. Data: read beats pass through (`s_rvalid` = `m_rvalid`, `m_rready` = `s_rready`, data, ID,
   response and last unchanged) until the last beat; write beats pass through (W only after the
   AW handshake) until the beat with `s_wlast`; then the write response passes through.

### 3.3 Faults

On a fault, for one clock `fault` = 1 and `fault_addr` / `fault_info` are written: {1, write, 0,
0} walk error, {0, write, 0, 1} not valid, {0, 1, 1, 0} write to a non-writable page. Nothing is
forwarded. A read then returns `s_arlen` + 1 beats of data 0, SLVERR, with its ID and RLAST on the
last. A write takes every W beat up to `s_wlast` (`s_wready` = 1), then returns SLVERR with its
ID.

### 3.4 TLB invalidate and reset

`tlb_inv` clears all four entries in any clock. While `rst_n` is low: idle, TLB empty, counters
and fault registers 0.

## 4. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `PTW_ID` | 0xF | AXI ID of page walk reads |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| page not VALID | fault, SLVERR upstream |
| walk read error response | fault, SLVERR upstream |
| write to a non-writable page | fault, SLVERR upstream |
| downstream SLVERR / DECERR | passed upstream unchanged |
| `enable` = 0 | no walks, no faults, counters unchanged |
| table changed without `tlb_inv` | stale translations used |
| counters at 65535 | stay |

## 6. TB check map

Messages are printed by `tb/SMMU_tb.sv` as `ERROR: <message>`. The TB checks against a reference
page table: random read and write bursts of 1 to 16 beats land at the translated address only,
with data, responses and IDs unchanged; walks; TLB hits, misses and invalidation; each fault kind;
bypass; reads and writes waiting together; reset in the middle of a burst.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "walk read: ID or length" | walk read format | §3.2 |
| "BID" | write ID passed back | §3.2 |
| "RID" | read ID passed back | §3.2 |
| "RLAST" | RLAST on the last beat | §3.2, §3.3 |
| "write" | write data lands at the PA | §3.1, §3.2 |
| "write VA" | write response | §3.2 |
| "write reached the untranslated address" | translated address only | §3.1 |
| "read" | read data from the PA | §3.2 |
| "read VA" | read response | §3.2 |
| "fault" | fault responses | §3.3 |
| "FAULT interrupt count" | one pulse per fault | §3.3 |
| "faulting burst was forwarded" | nothing forwarded | §3.3 |
| "FAULT_ADDR" | fault address | §3.3 |
| "FAULT_INFO" | fault cause | §3.3 |
| "fault read data not 0" | fault data is 0 | §3.3 |
| "walks in bypass" | no walks in bypass | §3.2 |
| "miss / hit" | counters | §3.2 |
| "walks with the working set in the TLB" | 4 entries, round robin | §3.2 |
| "no walk after CMD.tlb_inv" | invalidate empties the TLB | §3.4 |
| "downstream SLVERR not passed on a read" | read response passed | §3.2 |
| "downstream SLVERR not passed on a write" | write response passed | §3.2 |
| "not idle in reset" | reset | §3.4 |
| "counters not reset" | reset | §3.4 |

### Coverage-closure assertions

From `tb/cov/SMMU_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_reset_idle | while `!rst_n` (reset): `!busy && !fault && hits == 0 && misses == 0 && !m_arvalid && !m_awvalid && !m_wvalid && !s_rvalid && !s_bvalid && !s_arready && !s_awready` | §3 |
| a_busy | always holds: `busy == (ph != P_IDLE) && fault == (ph == P_FAULT)` | §3 |
| a_accept | always holds: `s_arready == (ph == P_IDLE && s_arvalid && (!s_awvalid \|\| m_last_wr)) && s_awready == (ph == P_IDLE && s_awvalid && !(s_arvalid && (!s_awvalid \|\| m_last_wr)))` | §3 |
| a_counters | always holds: `hits == m_hits && misses == m_misses` | §3 |
| a_ar_valid | always holds: `m_arvalid == (ph == P_WALK_AR \|\| (ph == P_FWD && !r_wr))` | §3 |
| a_aw_valid | always holds: `m_awvalid == (ph == P_FWD && r_wr)` | §3 |
| a_walk_req | whenever `ph == P_WALK_AR`: `m_araddr == walk_addr && m_arlen == 0 && m_arid == PTW_ID && m_arsize == 3'd2 && m_arburst == 2'b01 && m_arprot == 3'b010` | §3 |
| a_fwd_ar | whenever `ph == P_FWD && !r_wr`: `m_araddr == r_pa && m_arlen == r_len && m_arid == r_id && m_arsize == r_size && m_arburst == r_burst && m_arprot == r_prot` | §3 |
| a_fwd_aw | whenever `ph == P_FWD && r_wr`: `m_awaddr == r_pa && m_awlen == r_len && m_awid == r_id && m_awsize == r_size && m_awburst == r_burst && m_awprot == r_prot` | §3 |
| a_bypass_pa | whenever `ph == P_LK && lk_byp`: `##1 r_pa == r_va` | §3 |
| a_walk_rready | always holds: `(ph == P_WALK_R) -> m_rready` | §3 |
| a_r_pass | always holds: `fwd_r == (fwd_r && s_rvalid == m_rvalid && m_rready == s_rready && s_rdata == m_rdata && s_rresp == m_rresp && s_rlast == m_rlast && s_rid == m_rid)` | §3 |
| a_r_idle | always holds: `(ph != P_FWD_R && ph != P_WALK_R) -> !m_rready` | §3 |
| a_w_pass | always holds: `fwd_w == (fwd_w && m_wvalid == s_wvalid && s_wready == m_wready && m_wdata == s_wdata && m_wstrb == s_wstrb && m_wlast == s_wlast)` | §3 |
| a_w_idle | always holds: `!fwd_w -> (!m_wvalid && s_wready == (ph == P_FAULT_W))` | §3 |
| a_b_pass | always holds: `fwd_b == (fwd_b && s_bvalid == m_bvalid && m_bready == s_bready && s_bresp == m_bresp && s_bid == m_bid)` | §3 |
| a_b_idle | always holds: `!fwd_b -> (!m_bready && s_bvalid == (ph == P_FAULT_B))` | §3 |
| a_r_upstream | always holds: `(ph != P_FWD_R) -> (s_rvalid == (ph == P_FAULT_R))` | §3 |
| a_fault_regs | whenever `ph == P_FAULT`, on the next clock: `fault_addr == r_va && fault_info == r_info` | §3 |
| a_fault_r | whenever `ph == P_FAULT_R`: `s_rdata == 0 && s_rresp == 2'b10 && s_rid == r_id && s_rlast == (r_beat == r_len)` | §3 |
| a_fault_b | whenever `ph == P_FAULT_B`: `s_bresp == 2'b10 && s_bid == r_id` | §3 |
| a_fault_regs_hold | whenever `ph != P_FAULT && $past(ph) != P_FAULT && !$past(!rst_n)`: `$stable(fault_addr) && $stable(fault_info)` | §3 |

### Further TB checks

| Check (TB message) | What it requires | Spec |
|---|---|---|
| "attribute burst" | fails when `resp !== 0` (`tb/SMMU_tb.sv` line 273) | §3 |
| "downstream RRESP" | fails when `resp !== 2'(c)` (`tb/SMMU_tb.sv` line 289) | §3 |
| "downstream BRESP" | fails when `resp !== 2'(c)` (`tb/SMMU_tb.sv` line 291) | §3 |
| "unaligned write fault" | fails when `resp !== 2'b10 \|\| fault_addr !== ({vp[5], 12'h100} \| 32'(k))` (`tb/SMMU_tb.sv` line 305) | §3 |
| "no walk after CMD.tlb_inv in the lookup clock" | fails when `n_walks != w0 + 1` (`tb/SMMU_tb.sv` line 314) | §3 |
| "entry filled with CMD.tlb_inv lost" | fails when `n_walks != w0` (`tb/SMMU_tb.sv` line 321) | §3 |
| "HITS" | fails when `hits !== 16'hFFFF \|\| misses !== 16'hFFFF` (`tb/SMMU_tb.sv` line 340) | §3 |
