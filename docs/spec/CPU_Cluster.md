<!-- SPDX-License-Identifier: Apache-2.0 -->
# CPU_Cluster: design specification

Memory-traffic model of the application CPU cluster's L3 port in the phone SoC subsystem. A job
moves `xfer_len` 32-bit words over an AXI4 manager port in bursts of up to 16 beats (one 64-byte
cache line), in one of three modes: WRITE a known pattern (like cache-line write-backs), CHECK
that a buffer holds that pattern (counting and locating mismatches), or COPY a buffer. There is
no instruction execution or cache; the core exists to load and verify the memory system in SoC
tests. Core `CPU_Cluster_top` (`rtl/CPU_Cluster_top.sv`, uses `rtl/soc_ss_axi_engine.sv`),
testbench `tb/CPU_Cluster_tb.sv` (with `tb/soc_ss_axi_mem.svh`). There is no separate core
checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. pattern(i) = `seed` ^ {~i[15:0], i[15:0]} for word index i of
the job, so every word of a job differs.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `src_addr` | input | 32 | source buffer for CHECK and COPY (bits [1:0] ignored); latched at start | - | `clk` | - |
| `dst_addr` | input | 32 | destination buffer for WRITE and COPY; latched at start | - | `clk` | - |
| `xfer_len` | input | 16 | words in the job; latched at start | - | `clk` | - |
| `mode` | input | 2 | 0 WRITE, 1 CHECK, 2 and 3 COPY; latched at start | - | `clk` | - |
| `seed` | input | 32 | pattern seed; read live for every word, so hold it during the job | - | comb. | - |
| `start` | input | 1 | starts a job when `busy` = 0 | high | `clk` | - |
| `busy` | output | 1 | job running | high | `clk` | 0 |
| `err` | output | 1 | an AXI error response was seen in the current / last job | high | `clk` | 0 |
| `mismatches` | output | 16 | CHECK: words that differed from the pattern (saturates at 0xFFFF); 0 in other modes | - | `clk` | 0 |
| `first_fail` | output | 16 | CHECK: index of the first differing word (valid when `mismatches` != 0) | - | `clk` | 0 |
| `cycles` | output | 32 | clocks of the current / last job (§3.3) | - | `clk` | 0 |
| `done` | output | 1 | one-clock pulse at the end of every job | high | `clk` | 0 |
| `err_irq` | output | 1 | `done && err` | high | `clk` | 0 |
| `mis_irq` | output | 1 | `done` of a CHECK job with `mismatches` != 0 | high | `clk` | 0 |
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

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `u_eng` | - | the `soc_ss_axi_engine` instance; the TB prints its `rstate` (read side: 0 idle, 1 AR, 2 data) and `wstate` (write side: 0 idle, 1 AW, 2 data, 3 response) when a job times out |

### Internal signals used by the coverage checker

`tb/cov/CPU_Cluster_sva.sv` is bound to `CPU_Cluster_top` with `.*`, so a re-implementation must have these
names (width as seen by the checker).

| Signal | Width | Meaning |
|---|---|---|
| `rs_valid` | 1 | core-internal signal read by name by the checker |
| `rs_ready` | 1 | core-internal signal read by name by the checker |
| `ws_valid` | 1 | core-internal signal read by name by the checker |
| `ws_ready` | 1 | core-internal signal read by name by the checker |
| `rs_data` | [31:0] | core-internal signal read by name by the checker |
| `ws_data` | 1 | core-internal signal read by name by the checker |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/CPU_Cluster.md`](../ip/CPU_Cluster.md) (source: `scripts/apb/specs/CPU_Cluster.json`); do not edit by hand.

`CPU_Cluster_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C000100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | SRC_ADDR | RW | 0x00000000 | Source address (byte address, word aligned) |
| 0x018 | DST_ADDR | RW | 0x00000000 | Destination address (byte address, word aligned) |
| 0x01C | LEN | RW | 0x00000000 | Job length |
| 0x020 | CTRL | RW | 0x00000000 | Job options |
| 0x024 | SEED | RW | 0x00000000 | Pattern seed |
| 0x028 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x02C | STATUS | RO | core | Job state |
| 0x030 | RESULT | RO | core | CHECK result |
| 0x034 | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C00 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| SRC_ADDR | 31:0 | `src_addr` | RW | 0x0 | first word read by the job |
| DST_ADDR | 31:0 | `dst_addr` | RW | 0x0 | first word written by the job |
| LEN | 15:0 | `xfer_len` | RW | 0x0 | 32-bit words (0: the job ends at once) |
| CTRL | 1:0 | `mode` | RW | 0x0 | 0 WRITE, 1 CHECK, 2 COPY |
| SEED | 31:0 | `seed` | RW | 0x0 | XORed into every pattern word |
| CMD | 0 | `start` | WO (pulse) | 0x0 | start a job with the current registers; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a job is running |
| STATUS | 1 | `err` | RO | core | the current / last job saw an AXI error response (cleared by start) |
| RESULT | 15:0 | `mismatches` | RO | core | words that differed |
| RESULT | 31:16 | `first_fail` | RO | core | index of the first word that differed |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |
| 2 | MISMATCH | a CHECK job ended with MISMATCHES != 0 |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C000100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write SRC_ADDR (0x014), DST_ADDR (0x018), LEN (0x01C), CTRL (0x020), SEED (0x024). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x028; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x02C) for the core's live `busy`, `err`; it needs no clearing.
7. Read RESULT (0x030) for the core's live `mismatches`, `first_fail`; it needs no clearing.
8. Read CYCLES (0x034) for the core's live `cycles`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write SRC_ADDR, DST_ADDR (word aligned) and LEN (32-bit words).
2. Write CTRL with the job's options and IRQ_ENABLE with DONE (and ERR).
3. Write CMD.start = 1 (ignored while STATUS.busy is 1).
4. Wait for irq (or poll STATUS.busy = 0), read the result registers, write 1s to IRQ_STATUS to clear it.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Job start

At the edge where `start && !busy`: the engine starts (§3.3) with reads enabled for CHECK and
COPY and writes enabled for WRITE and COPY; `mode` is latched and the word indexes, `mismatches`
and `first_fail` are cleared.

### 3.2 Datapath

| Mode | Reads | Writes | Per word |
|---|---|---|---|
| 0 WRITE | no | pattern(i) to `dst` + 4i | the write stream is valid whenever `busy` |
| 1 CHECK | `src` + 4i | none | every read word is consumed at once and compared with pattern(i) |
| 2, 3 COPY | `src` + 4i | the same word to `dst` + 4i | one word per clock from the read stream to the write stream |

In CHECK, at each read word that differs from pattern(i): if `mismatches` = 0, `first_fail` <= i;
`mismatches` increments unless it is 0xFFFF. Words read with an error response are still
compared.

### 3.3 AXI data mover

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

### 3.4 Interrupts

`done` = the engine's done pulse; `err_irq` = `done && err`; `mis_irq` = `done` of a CHECK job
with `mismatches` != 0. All are one clock long, in the same clock.

### 3.5 Reset

`rst_n` low: no job (`busy` = 0), `err`, `cycles`, `mismatches`, `first_fail` = 0, latched mode
WRITE, all AXI valid / ready outputs 0. A job in progress is abandoned.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd0 | 4'd0 to 4'd15 | value of `m_awid` and `m_arid` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `start` while `busy` | ignored |
| `len` = 0 | no bus traffic, `done` one clock after the start, `cycles` = 1 |
| buffer crossing a 4 KB boundary | the burst is split at the boundary |
| AXI error response (read or write) | `err` set until the next start; the job completes; the affected words are still written |
| unaligned `src` / `dst` | bits [1:0] ignored |
| reset in the middle of a job | `busy` = 0 and every AXI valid / ready output 0 at once; the subordinate must be reset too |
| more than 65535 mismatches | `mismatches` saturates at 0xFFFF |
| `seed` changed during a job | later words use the new seed |
| MODE 3 | same as COPY |

## 6. TB check map

Messages are printed by `tb/CPU_Cluster_tb.sv` through `fail()` as `ERROR: <message>`. The TB runs
random jobs of 0 to 600 words in random modes (CHECK sources hold the pattern with about one word in eight corrupted) against `tb/soc_ss_axi_mem.svh`, which itself checks every burst (size, INCR, WLAST, 4 KB,
at most 16 beats) and injects random stalls and error responses at one word of a job.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "busy low after start" | `busy` = 1 in the clock after an accepted start (non-zero length) | §3.3 |
| "job of" | every job ends within 100000 clocks, also with `start` pulsed again while busy | §3.3 |
| "ERR" | `err` is 1 exactly when an error response was injected | §3.3 |
| "ERR interrupt count" | one `err_irq` pulse per failed job, none otherwise | §3.4 |
| "CYCLES = 0" | `cycles` non-zero after a non-empty job | §3.3 |
| "word" | every destination word equals the TB's reference model | §3.2, §3.3 |
| "read-only job wrote the destination" | a CHECK job leaves the destination untouched | §3.1 |
| "MISMATCHES" | CHECK: `mismatches` equals the number of corrupted words | §3.2 |
| "FIRST_FAIL" | CHECK: `first_fail` is the index of the first corrupted word | §3.2 |
| "MISMATCH interrupt count" | one `mis_irq` per CHECK job with mismatches, none otherwise | §3.4 |
| "not idle in reset" | reset mid-job: `busy`, `m_awvalid`, `m_arvalid`, `m_wvalid` all 0 | §3.5 |

### Coverage-closure assertions

From `tb/cov/CPU_Cluster_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_reset_idle | while `!rst_n` (reset): `mismatches == 0 && first_fail == 0 && !mis_irq && !err_irq` | §3 |
| a_ws_valid | always holds: `ws_valid == (m_mode == 2'd0 ? busy : m_mode == 2'd1 ? 1'b0 : rs_valid)` | §3 |
| a_ws_data | whenever `ws_valid`: `ws_data == (m_mode == 2'd0 ? m_pat_w : rs_data)` | §3 |
| a_rs_ready | always holds: `rs_ready == (m_mode == 2'd1 ? 1'b1 : ws_ready)` | §3 |
| a_mismatches | always holds: `mismatches == m_mis && first_fail == m_ff` | §3 |
| a_mis_irq | always holds: `mis_irq == (done && m_mode == 2'd1 && m_mis != 0)` | §3 |
