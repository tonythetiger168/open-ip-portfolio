<!-- SPDX-License-Identifier: Apache-2.0 -->
# DMA: design specification

Four-channel system DMA of the phone SoC subsystem. Each channel has its own source, destination,
length and mode (COPY or FILL); a start pulse queues the channel, and queued channels are served
one job at a time in round-robin order by one shared AXI4 data mover. There are no descriptors,
linked lists, peripheral handshakes, 2-D transfers or byte granularity: jobs move whole 32-bit
words. Core `DMA_top` (`rtl/DMA_top.sv`, uses `rtl/soc_ss_axi_engine.sv`), testbench
`tb/DMA_tb.sv` (with `tb/soc_ss_axi_mem.svh`). There is no separate core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *job start* is a clock with `e_start` = 1 (§3.1).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `src0` | input | 32 | channel 0 source (COPY; bits [1:0] ignored); read when the job starts | - | `clk` | - |
| `dst0` | input | 32 | channel 0 destination; read when the job starts | - | `clk` | - |
| `len0` | input | 16 | channel 0 job length in words; read when the job starts | - | `clk` | - |
| `mode0` | input | 1 | channel 0 mode: 0 COPY, 1 FILL; read at the job start and live during it | - | `clk` | - |
| `fill0` | input | 32 | channel 0 FILL word; read live during the job | - | comb. | - |
| `start0` | input | 1 | queues channel 0 (sets `pending[0]`) | high | `clk` | - |
| `src1` | input | 32 | channel 1 source (COPY; bits [1:0] ignored); read when the job starts | - | `clk` | - |
| `dst1` | input | 32 | channel 1 destination; read when the job starts | - | `clk` | - |
| `len1` | input | 16 | channel 1 job length in words; read when the job starts | - | `clk` | - |
| `mode1` | input | 1 | channel 1 mode: 0 COPY, 1 FILL; read at the job start and live during it | - | `clk` | - |
| `fill1` | input | 32 | channel 1 FILL word; read live during the job | - | comb. | - |
| `start1` | input | 1 | queues channel 1 (sets `pending[1]`) | high | `clk` | - |
| `src2` | input | 32 | channel 2 source (COPY; bits [1:0] ignored); read when the job starts | - | `clk` | - |
| `dst2` | input | 32 | channel 2 destination; read when the job starts | - | `clk` | - |
| `len2` | input | 16 | channel 2 job length in words; read when the job starts | - | `clk` | - |
| `mode2` | input | 1 | channel 2 mode: 0 COPY, 1 FILL; read at the job start and live during it | - | `clk` | - |
| `fill2` | input | 32 | channel 2 FILL word; read live during the job | - | comb. | - |
| `start2` | input | 1 | queues channel 2 (sets `pending[2]`) | high | `clk` | - |
| `src3` | input | 32 | channel 3 source (COPY; bits [1:0] ignored); read when the job starts | - | `clk` | - |
| `dst3` | input | 32 | channel 3 destination; read when the job starts | - | `clk` | - |
| `len3` | input | 16 | channel 3 job length in words; read when the job starts | - | `clk` | - |
| `mode3` | input | 1 | channel 3 mode: 0 COPY, 1 FILL; read at the job start and live during it | - | `clk` | - |
| `fill3` | input | 32 | channel 3 FILL word; read live during the job | - | comb. | - |
| `start3` | input | 1 | queues channel 3 (sets `pending[3]`) | high | `clk` | - |
| `done0` | output | 1 | one-clock pulse when a channel 0 job ends | high | comb. | 0 |
| `done1` | output | 1 | one-clock pulse when a channel 1 job ends | high | comb. | 0 |
| `done2` | output | 1 | one-clock pulse when a channel 2 job ends | high | comb. | 0 |
| `done3` | output | 1 | one-clock pulse when a channel 3 job ends | high | comb. | 0 |
| `pending` | output | 4 | queued channels, bit c = channel c | - | `clk` | 0 |
| `busy` | output | 1 | a job is running | high | `clk` | 0 |
| `active_ch` | output | 2 | channel of the running or last job | - | `clk` | 3 |
| `err` | output | 1 | an AXI error response was seen in the running / last job | high | `clk` | 0 |
| `checksum` | output | 32 | sum modulo 2^32 of the words written by the running / last job | - | `clk` | 0 |
| `cycles` | output | 32 | clocks of the running / last job (§3.3) | - | `clk` | 0 |
| `err_irq` | output | 1 | `done` of a job with `err` (any channel) | high | comb. | 0 |
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
| `e_start` | 1 | job start: no job running and a channel is pending (combinational) |
| `nxt` | 2 | the channel the next job start will serve (round-robin choice, combinational) |

### Internal signals used by the coverage checker

`tb/cov/DMA_sva.sv` is bound to `DMA_top` with `.*`, so a re-implementation must have these
names (width as seen by the checker).

| Signal | Width | Meaning |
|---|---|---|
| `e_done` | 1 | core-internal signal read by name by the checker |
| `rs_valid` | 1 | core-internal signal read by name by the checker |
| `rs_ready` | 1 | core-internal signal read by name by the checker |
| `ws_valid` | 1 | core-internal signal read by name by the checker |
| `ws_ready` | 1 | core-internal signal read by name by the checker |
| `rs_data` | [31:0] | core-internal signal read by name by the checker |
| `ws_data` | 1 | core-internal signal read by name by the checker |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/DMA.md`](../ip/DMA.md) (source: `scripts/apb/specs/DMA.json`); do not edit by hand.

`DMA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C090100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | SRC0 | RW | 0x00000000 | Channel 0 source address |
| 0x018 | DST0 | RW | 0x00000000 | Channel 0 destination address |
| 0x01C | LEN0 | RW | 0x00000000 | Channel 0 length |
| 0x020 | FILL0 | RW | 0x00000000 | Channel 0 fill word |
| 0x024 | SRC1 | RW | 0x00000000 | Channel 1 source address |
| 0x028 | DST1 | RW | 0x00000000 | Channel 1 destination address |
| 0x02C | LEN1 | RW | 0x00000000 | Channel 1 length |
| 0x030 | FILL1 | RW | 0x00000000 | Channel 1 fill word |
| 0x034 | SRC2 | RW | 0x00000000 | Channel 2 source address |
| 0x038 | DST2 | RW | 0x00000000 | Channel 2 destination address |
| 0x03C | LEN2 | RW | 0x00000000 | Channel 2 length |
| 0x040 | FILL2 | RW | 0x00000000 | Channel 2 fill word |
| 0x044 | SRC3 | RW | 0x00000000 | Channel 3 source address |
| 0x048 | DST3 | RW | 0x00000000 | Channel 3 destination address |
| 0x04C | LEN3 | RW | 0x00000000 | Channel 3 length |
| 0x050 | FILL3 | RW | 0x00000000 | Channel 3 fill word |
| 0x054 | MODE | RW | 0x00000000 | Channel modes |
| 0x058 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x05C | STATUS | RO | core | Scheduler state |
| 0x060 | CHECKSUM | RO | core | Data checksum |
| 0x064 | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x068 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C09 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| SRC0 | 31:0 | `src0` | RW | 0x0 | byte address, word aligned |
| DST0 | 31:0 | `dst0` | RW | 0x0 | byte address, word aligned |
| LEN0 | 15:0 | `len0` | RW | 0x0 | 32-bit words |
| FILL0 | 31:0 | `fill0` | RW | 0x0 | FILL mode data |
| SRC1 | 31:0 | `src1` | RW | 0x0 | byte address, word aligned |
| DST1 | 31:0 | `dst1` | RW | 0x0 | byte address, word aligned |
| LEN1 | 15:0 | `len1` | RW | 0x0 | 32-bit words |
| FILL1 | 31:0 | `fill1` | RW | 0x0 | FILL mode data |
| SRC2 | 31:0 | `src2` | RW | 0x0 | byte address, word aligned |
| DST2 | 31:0 | `dst2` | RW | 0x0 | byte address, word aligned |
| LEN2 | 15:0 | `len2` | RW | 0x0 | 32-bit words |
| FILL2 | 31:0 | `fill2` | RW | 0x0 | FILL mode data |
| SRC3 | 31:0 | `src3` | RW | 0x0 | byte address, word aligned |
| DST3 | 31:0 | `dst3` | RW | 0x0 | byte address, word aligned |
| LEN3 | 15:0 | `len3` | RW | 0x0 | 32-bit words |
| FILL3 | 31:0 | `fill3` | RW | 0x0 | FILL mode data |
| MODE | 0 | `mode0` | RW | 0x0 | channel 0: 0 COPY, 1 FILL |
| MODE | 1 | `mode1` | RW | 0x0 | channel 1: 0 COPY, 1 FILL |
| MODE | 2 | `mode2` | RW | 0x0 | channel 2: 0 COPY, 1 FILL |
| MODE | 3 | `mode3` | RW | 0x0 | channel 3: 0 COPY, 1 FILL |
| CMD | 0 | `start0` | WO (pulse) | 0x0 | queue channel 0 |
| CMD | 1 | `start1` | WO (pulse) | 0x0 | queue channel 1 |
| CMD | 2 | `start2` | WO (pulse) | 0x0 | queue channel 2 |
| CMD | 3 | `start3` | WO (pulse) | 0x0 | queue channel 3 |
| STATUS | 3:0 | `pending` | RO | core | queued channels |
| STATUS | 4 | `busy` | RO | core | a job is running |
| STATUS | 6:5 | `active_ch` | RO | core | channel of the current / last job |
| STATUS | 7 | `err` | RO | core | the current / last job saw an AXI error response |
| CHECKSUM | 31:0 | `checksum` | RO | core | sum of the words written by the current / last job |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE0 | a channel 0 job ended |
| 1 | DONE1 | a channel 1 job ended |
| 2 | DONE2 | a channel 2 job ended |
| 3 | DONE3 | a channel 3 job ended |
| 4 | ERR | a job ended that saw an AXI error response |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C090100.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write SRC0 (0x014), DST0 (0x018), LEN0 (0x01C), FILL0 (0x020), SRC1 (0x024), DST1 (0x028), LEN1 (0x02C), FILL1 (0x030), SRC2 (0x034), DST2 (0x038), LEN2 (0x03C), FILL2 (0x040), SRC3 (0x044), DST3 (0x048), LEN3 (0x04C), FILL3 (0x050), MODE (0x054). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `start0` (CMD bit 0), `start1` (CMD bit 1), `start2` (CMD bit 2), `start3` (CMD bit 3) at 0x058; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x05C) for the core's live `pending`, `busy`, `active_ch`, `err`; it needs no clearing.
7. Read CHECKSUM (0x060) for the core's live `checksum`; it needs no clearing.
8. Read CYCLES (0x064) for the core's live `cycles`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write SRCn, DSTn, LENn (and FILLn), MODE and IRQ_ENABLE.
2. Write CMD with startn = 1 for each channel to run; channels may be queued while one runs.
3. On irq read IRQ_STATUS to see which DONEn are set, then write them back to clear.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Queue and arbitration

At every edge `pending` <= (`pending` | {`start3`..`start0`}) with the bit of the channel being
started cleared. `e_start` = no job running and `pending` != 0. `nxt` is the first pending channel
after the last one served, in the order `active_ch` + 1, + 2, + 3, then `active_ch` itself. At an
`e_start` edge: `active_ch` <= `nxt`, `busy` <= 1, `checksum` <= 0, and the engine starts with
channel `nxt`'s `src`, `dst`, `len`, reads enabled for COPY only, writes always.

A start for a channel that is already pending has no effect; a start for the channel that is
running queues it again; but a start for the channel in the very clock its job starts is lost
(its pending bit is cleared at that edge). After reset `active_ch` = 3, so channel 0 has the
highest priority for the first job.

### 3.2 Datapath

- COPY: the read stream passes to the write stream, one word per clock.
- FILL: the write stream offers `fill` of the active channel whenever `busy`; nothing is read.

The mode and FILL word of the active channel are used live. At each edge where a word enters the
write side, `checksum` += that word.

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

After the engine's done pulse, `busy` falls at the next edge, and the next pending channel starts
one clock later (two idle clocks between jobs).

### 3.4 Interrupts

`done`c = engine done pulse and `active_ch` = c; `err_irq` = engine done pulse and `err`. All one
clock long. `checksum` and `cycles` are valid in the clock of the done pulse and stay until the
next job start.

### 3.5 Reset

`rst_n` low: `pending` = 0, no job (`busy` = 0), `active_ch` = 3, `checksum`, `err`, `cycles` = 0,
all AXI valid / ready outputs 0. A job in progress and all queued channels are abandoned.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd7 | 4'd0 to 4'd15 | value of `m_awid` and `m_arid` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `start` while `busy` | ignored |
| `len` = 0 | no bus traffic, `done` one clock after the start, `cycles` = 1 |
| buffer crossing a 4 KB boundary | the burst is split at the boundary |
| AXI error response (read or write) | `err` set until the next start; the job completes; the affected words are still written |
| unaligned `src` / `dst` | bits [1:0] ignored |
| reset in the middle of a job | `busy` = 0 and every AXI valid / ready output 0 at once; the subordinate must be reset too |
| start for the channel whose job starts in the same clock | lost (§3.1) |
| channel registers changed while queued | the values at the job start are used |
| `mode` / `fill` of the active channel changed during its job | later words follow the new values |
| all four channels queued at once | served 0, 1, 2, 3 (after reset) or in round-robin order from the last one served |

## 6. TB check map

Messages are printed by `tb/DMA_tb.sv` through `fail()` as `ERROR: <message>`. The TB queues random
channel sets (all at once or staggered) with random COPY / FILL jobs against
`tb/soc_ss_axi_mem.svh` (bursts checked, random stalls, injected error responses).

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "DMA did not go idle" | every round of jobs ends with `busy` = 0 and nothing pending | §3.1, §3.3 |
| "channel served twice" | channels queued together are each served once, in round-robin order | §3.1 |
| "CHECKSUM of ch" | `checksum` at each done pulse is the sum of that channel's written words | §3.2, §3.4 |
| "not idle after reset" | after reset `pending` = 0 and `busy` = 0 | §3.5 |
| "round-robin order wrong" | after serving channel 1, channels 2, 3, 0 follow in that order | §3.1 |
| "read error: ERR / interrupt" | an error response on a COPY read sets `err` and pulses `err_irq` | §3.3, §3.4 |
| "write error: ERR / interrupt" | an error response on a FILL write sets `err` and pulses `err_irq` | §3.3, §3.4 |
| "ERR not cleared by the next job" | `err` is cleared at the next job start | §3.3 |
| "not idle in reset" | reset mid-job: `busy`, `pending`, `m_awvalid`, `m_arvalid`, `m_wvalid` all 0 | §3.5 |

### Coverage-closure assertions

From `tb/cov/DMA_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_reset_idle | while `!rst_n` (reset): `pending == 0 && !busy && active_ch == 2'd3 && checksum == 0 && dn == 0` | §3 |
| a_queue | always holds: `pending == m_pend && busy == m_run && active_ch == m_ch && checksum == m_sum` | §3 |
| a_engine_start | always holds: `e_start == m_go` | §3 |
| a_engine_job | whenever `m_go`: `u_eng.src == sv[m_nxt] && u_eng.dst == dv[m_nxt] && u_eng.len == lv[m_nxt] && u_eng.rd_en == !md[m_nxt] && u_eng.wr_en` | §3 |
| a_ws_valid | always holds: `ws_valid == (md[m_ch] ? m_run : rs_valid)` | §3 |
| a_ws_data | whenever `ws_valid`: `ws_data == (md[m_ch] ? fv[m_ch] : rs_data)` | §3 |
| a_rs_ready | always holds: `rs_ready == ws_ready` | §3 |
| a_done | always holds: `dn == (e_done ? 4'b1 << m_ch : 4'b0) && err_irq == (e_done && err)` | §3 |

### Further TB checks

| Check (TB message) | What it requires | Spec |
|---|---|---|
| "error code: ERR" | fails when `!err` (`tb/DMA_tb.sv` line 164) | §3 |
