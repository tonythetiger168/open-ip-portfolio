<!-- SPDX-License-Identifier: Apache-2.0 -->
# Interrupt_Controller: design specification

32-source interrupt controller of the phone SoC subsystem with an in-memory event log. It masks
the level interrupts of the subsystems and peripherals plus 32 software interrupt bits, drives
one CPU interrupt, reports the highest-priority pending source for a claim, and, when enabled,
writes a timestamped record for every source that becomes pending into a ring buffer in memory
over an AXI4 manager port. There is no per-source priority register, no nesting, no edge-triggered
input mode and no multi-CPU routing. Core `Interrupt_Controller_top`
(`rtl/Interrupt_Controller_top.sv`, uses `rtl/soc_ss_axi_engine.sv`), testbench
`tb/Interrupt_Controller_tb.sv` (with `tb/soc_ss_axi_mem.svh`). There is no separate core
checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A source *becomes pending* at an edge where its `pending` bit is 1
and was 0 at the previous edge.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `irq_src` | input | 32 | level interrupt inputs, bit i = source i; must be synchronous to `clk` | high | `clk` | - |
| `enable` | input | 32 | per-source enable | high | comb. | - |
| `sw_set` | input | 32 | software interrupt bits, ORed with `irq_src` | high | comb. | - |
| `log_en` | input | 1 | enables the event log; 0 also discards records not yet written | high | `clk` | - |
| `log_base` | input | 32 | ring buffer base address (bits [1:0] ignored); read when each record starts | - | `clk` | - |
| `log_words` | input | 16 | ring size in records; 0 stops logging | - | `clk` | - |
| `pending` | output | 32 | (`irq_src` \| `sw_set`) & `enable` | high | comb. | 0 when inputs 0 |
| `claim` | output | 32 | {valid (bit 31), 26'b0, id (bits 4:0)} of the lowest-numbered pending source; 0 when none | - | comb. | - |
| `log_wp` | output | 16 | records written since reset (wraps at 65536) | - | `clk` | 0 |
| `cpu_irq` | output | 1 | `pending` != 0 | high | comb. | - |
| `log_err` | output | 1 | one-clock pulse when a record write got an AXI error response | high | comb. | 0 |
| `m_awid` | output | 4 | write ID, constant `AXI_ID` | - | - | - |
| `m_awaddr` | output | 32 | burst start address (word aligned) | - | `clk` | 0 |
| `m_awlen` | output | 8 | beats - 1 (0 to 15) | - | `clk` | - |
| `m_awsize` | output | 3 | constant 2 (4 bytes) | - | - | 2 |
| `m_awburst` | output | 2 | constant 01 (INCR) | - | - | 01 |
| `m_awprot` | output | 3 | constant 3'b000 | - | - | 3'b000 |
| `m_awvalid` | output | 1 | write address valid; held until `m_awready` | high | `clk` | 0 |
| `m_awready` | input | 1 | write address ready | high | `clk` | - |
| `m_wdata` | output | 32 | write data, from the write FIFO | - | `clk` | - |
| `m_wstrb` | output | 4 | constant 4'hF | - | - | 4'hF |
| `m_wlast` | output | 1 | last beat of the burst | high | `clk` | 0 |
| `m_wvalid` | output | 1 | write data valid; never low inside a burst once AW is accepted | high | `clk` | 0 |
| `m_wready` | input | 1 | write data ready | high | `clk` | - |
| `m_bid` | input | 4 | write response ID; ignored (one write outstanding) | - | - | - |
| `m_bresp` | input | 2 | write response; anything but OKAY sets `err` | - | `clk` | - |
| `m_bvalid` | input | 1 | write response valid | high | `clk` | - |
| `m_bready` | output | 1 | 1 while waiting for the burst's response | high | `clk` | 0 |
| `m_arid` | output | 4 | read ID, constant `AXI_ID` | - | - | - |
| `m_araddr` | output | 32 | burst start address (word aligned) | - | `clk` | 0 |
| `m_arlen` | output | 8 | beats - 1 (0 to 15) | - | `clk` | - |
| `m_arsize` | output | 3 | constant 2 (4 bytes) | - | - | 2 |
| `m_arburst` | output | 2 | constant 01 (INCR) | - | - | 01 |
| `m_arprot` | output | 3 | constant 3'b000 | - | - | 3'b000 |
| `m_arvalid` | output | 1 | read address valid; held until `m_arready` | high | `clk` | 0 |
| `m_arready` | input | 1 | read address ready | high | `clk` | - |
| `m_rid` | input | 4 | read ID; ignored (one read outstanding) | - | - | - |
| `m_rdata` | input | 32 | read data | - | `clk` | - |
| `m_rresp` | input | 2 | read response; anything but OKAY sets `err` (the data is still used) | - | `clk` | - |
| `m_rlast` | input | 1 | last read beat; ends the burst (the beat count is not checked) | high | `clk` | - |
| `m_rvalid` | input | 1 | read data valid | high | `clk` | - |
| `m_rready` | output | 1 | 1 for the whole read data phase of a burst (never back-pressures) | high | `clk` | 0 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Interrupt_Controller.md`](../ip/Interrupt_Controller.md) (source: `scripts/apb/specs/Interrupt_Controller.json`); do not edit by hand.

`Interrupt_Controller_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `irq_src`, `cpu_irq`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C0B0100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | ENABLE | RW | 0x00000000 | Source enables |
| 0x018 | SW_SET | RW | 0x00000000 | Software interrupts |
| 0x01C | LOG_CTRL | RW | 0x00000000 | Event log |
| 0x020 | LOG_BASE | RW | 0x00000000 | Event log base |
| 0x024 | PENDING | RO | core | Pending sources |
| 0x028 | CLAIM | RO | core | Highest-priority pending source |
| 0x02C | STATE | RO | core | Output and log state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C0B | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| ENABLE | 31:0 | `enable` | RW | 0x0 | 1: source can be pending |
| SW_SET | 31:0 | `sw_set` | RW | 0x0 | ORed into irq_src |
| LOG_CTRL | 0 | `log_en` | RW | 0x0 | 1: log records |
| LOG_CTRL | 16:1 | `log_words` | RW | 0x0 | ring size in words (0: no log) |
| LOG_BASE | 31:0 | `log_base` | RW | 0x0 | byte address of record 0 |
| PENDING | 31:0 | `pending` | RO | core | (irq_src | SW_SET) & ENABLE |
| CLAIM | 31:0 | `claim` | RO | core | {valid, 26'b0, id} |
| STATE | 15:0 | `log_wp` | RO | core | records written |
| STATE | 16 | `cpu_irq` | RO | core | the CPU interrupt |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CPU | cpu_irq was high (level: sets again while a source is pending) |
| 1 | LOG_ERR | a log write got an AXI error response |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C0B0100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write ENABLE (0x014), SW_SET (0x018), LOG_CTRL (0x01C), LOG_BASE (0x020). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. Read PENDING (0x024) for the core's live `pending`; it needs no clearing.
6. Read CLAIM (0x028) for the core's live `claim`; it needs no clearing.
7. Read STATE (0x02C) for the core's live `log_wp`, `cpu_irq`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write LOG_BASE and LOG_CTRL (optional), then ENABLE.
2. On cpu_irq read CLAIM, service source id at its device, repeat until CLAIM.valid = 0.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Routing and claim

`pending`, `claim` and `cpu_irq` are combinational from `irq_src`, `sw_set` and `enable`. The
lowest-numbered pending source has the highest priority. A source is acknowledged at the device
(its level falls) or, for software bits, by clearing its `sw_set` bit; the controller holds no
state for routing.

### 3.2 Event log queue

At every edge: the previous `pending` is stored; with `log_en` = 1 each source that becomes
pending sets its bit in a 32-bit to-log set; with `log_en` = 0 the set is cleared. A source that
becomes pending again while its bit is still set is merged into one record. A record start
(`go`) happens in a clock where `log_en` = 1, the set is non-empty, `log_words` != 0, and no
record write is running or finishing (the engine is neither busy nor in its done clock). At a
`go` edge the lowest-numbered source in the set is taken out of it and becomes the record's id,
and a one-word write job starts at `log_base` + 4 x slot, where slot is the next ring slot, or 0
if `log_words` has been lowered to or below it.

### 3.3 Record write

The record is {ts[23:0], 3'b000, id[4:0]}, where ts is a free-running 24-bit counter of `clk`
cycles since reset; it is taken when the record enters the write buffer, one clock after the
`go` edge, so timestamps of successive records strictly increase (until ts wraps). The write is
one single-beat INCR burst (AWLEN 0, AWSIZE 2, WSTRB 4'hF, WLAST 1), issued after the word is
buffered, by the shared data mover of §3.4.

### 3.4 AXI data mover

The core moves data with `rtl/soc_ss_axi_engine.sv` (instance `u_eng`, FIFO depth 32
words per direction). One job reads `len` 32-bit words from `src` into the read stream (if the job
reads) and writes `len` words taken from the write stream to `dst` (if it writes). Bits [1:0] of
both addresses are ignored.

- Start: at the edge where `start` is accepted (not busy), `busy` <= 1, `err` <= 0,
  `cycles` <= 0 and the job parameters are latched. `start` while `busy` is ignored.
- Bursts: INCR, AxSIZE 2, WSTRB 4'hF, length min(16, words left, words to the next 4 KB
  boundary), so no burst crosses 4 KB. One read and one write burst may be outstanding at the same
  time, never two of the same kind. All IDs are the core's constant ID.
- Read side: a read burst is requested (ARVALID from the clock after the start edge at the
  earliest) only when the read FIFO has room for 16 more words, so `m_rready` is 1 for the whole
  data phase. Every RVALID beat goes into the FIFO; RLAST ends the burst.
- Write side: a write burst is requested only when the write FIFO already holds all of its beats,
  so once AW is accepted WVALID stays high until WLAST; then BREADY waits for the response.
- Error: any RRESP or BRESP other than OKAY sets `err` until the next start; the job still runs to
  the end with the data it got.
- Done: at the edge where both sides have finished every burst (all responses received) and the
  read FIFO is empty, `busy` <= 0 and `done` is 1 for one clock. `cycles` counts every edge while
  `busy` is 1, so it holds the number of clocks from the start edge to the done edge and keeps it
  until the next start. A job with `len` = 0 finishes at the edge after the start (`cycles` = 1).

In this core the engine's `busy`, `done`, `err` and `cycles` are internal and every job is one
word. At the engine's done pulse `log_wp` increments and slot <= next slot (0 after `log_words` - 1).
So record n lands at `log_base` + 4 x (n mod `log_words`) while `log_words` is constant. Records
are written one at a time; the read channel is never used.

### 3.5 Interrupts

`cpu_irq` = any pending source (level). `log_err` = done pulse of a record write with an error
response (one clock); the record still counts in `log_wp`.

### 3.6 Reset

`rst_n` low: to-log set, stored pending, ts, slot, `log_wp` = 0, all AXI valid / ready outputs 0.
A record write in progress is abandoned.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd10 | 4'd0 to 4'd15 | value of `m_awid` (and `m_arid`, never used) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| several sources become pending together | one record each, lowest id first |
| a source re-rises before its record is written | merged: one record |
| masked source (`enable` bit 0) | never pending, never logged |
| `sw_set` bit set | pending and logged like a hardware source |
| `log_en` = 0 | no records; waiting records are discarded |
| `log_words` = 0 | no record starts |
| `log_words` lowered below the next slot | the next record goes to slot 0 |
| AXI error response on a record | `log_err` pulse; the record is counted |
| write-only engine use | `m_arvalid` and `m_rready` always 0 |
| reset during a record write | AXI outputs idle at once, `log_wp` = 0 |

## 6. TB check map

Messages are printed by `tb/Interrupt_Controller_tb.sv` through `fail()` as `ERROR: <message>`. The TB drives
random sources, enables and software bits, then exercises the log against
`tb/soc_ss_axi_mem.svh` (bursts checked, random stalls, an injected error response).

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "PENDING" | `pending` = (`irq_src` \| `sw_set`) & `enable` for 400 random settings | §3.1 |
| "CLAIM" | `claim` gives the lowest pending id with bit 31 set, 0 when none | §3.1 |
| "cpu_irq" | `cpu_irq` = any pending | §3.1 |
| "LOG_WP" | `log_wp` counts every record written | §3.4 |
| "records written with LOG_EN 0" | no records while `log_en` = 0 | §3.2 |
| "record" | each record holds the source id with bits [7:5] = 0, in ring slot n mod 5 | §3.3, §3.4 |
| "timestamps not rising" | successive records have increasing timestamps | §3.3 |
| "several sources: order" | sources 4, 10, 16, 31 together are logged in that order | §3.2 |
| "merged edge logged twice" | a source re-rising while waiting gives one record | §3.2 |
| "SW_SET record" | a software bit is logged | §3.2 |
| "masked source logged" | a disabled source is not logged | §3.1, §3.2 |
| "LOG_ERR" | an error response on a record write pulses `log_err` once | §3.5 |
| "records with LOG_EN 0" | edges while `log_en` = 0 give no records | §3.2 |
| "not idle in reset" | reset during a record write: `m_awvalid`, `m_wvalid` 0 and `log_wp` = 0 | §3.6 |
| "record after reset" | logging works after reset, starting at slot 0 | §3.2, §3.6 |
| "record after lowering LOG_WORDS at slot 0" | after shrinking the ring below the next slot the record goes to slot 0 | §3.2 |
| "record outside the shrunk ring" | ... and nothing is written outside the new ring | §3.2 |
