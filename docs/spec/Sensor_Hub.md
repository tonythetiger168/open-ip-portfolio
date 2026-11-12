<!-- SPDX-License-Identifier: Apache-2.0 -->
# Sensor_Hub: design specification

Always-on sensor hub of the phone SoC subsystem, reduced to a sample decimator and batching
writer. It takes 16-bit samples from a sensor interface (for example an I2C / I3C or SPI
controller reading an accelerometer), averages each group of 2^`avg_log2` samples, packs two
averages per 32-bit word and writes a batch of `xfer_len` words to memory over an AXI4 manager
port, so the application processor can sleep until the batch is complete. A wake interrupt fires
when an average exceeds a threshold. There is no sensor protocol, FIFO watermark logic or
timestamping. Core `Sensor_Hub_top` (`rtl/Sensor_Hub_top.sv`, uses `rtl/soc_ss_axi_engine.sv`),
testbench `tb/Sensor_Hub_tb.sv` (with `tb/soc_ss_axi_mem.svh`). There is no separate core
checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A sample is *taken* in a clock where `sns_valid` = 1, a job is
running and the batch still needs words.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `dst_addr` | input | 32 | batch buffer (bits [1:0] ignored); latched at start | - | `clk` | - |
| `xfer_len` | input | 16 | words in the batch (two averages each); latched at start | - | `clk` | - |
| `avg_log2` | input | 3 | log2 of the samples per average (0..7); latched at start | - | `clk` | - |
| `threshold` | input | 16 | wake threshold, unsigned; read live | - | comb. | - |
| `wake_en` | input | 1 | enables `wake`; read live | high | comb. | - |
| `start` | input | 1 | starts a batch when `busy` = 0 | high | `clk` | - |
| `busy` | output | 1 | batch in progress (collecting or still writing) | high | `clk` | 0 |
| `err` | output | 1 | an AXI write error response was seen in the current / last batch | high | `clk` | 0 |
| `last_avg` | output | 16 | the most recent average (kept across batches) | - | `clk` | 0 |
| `drops` | output | 16 | packed words lost because the write FIFO was full, in the current / last batch (saturates at 0xFFFF) | - | `clk` | 0 |
| `cycles` | output | 32 | clocks of the current / last batch (§3.3) | - | `clk` | 0 |
| `done` | output | 1 | one-clock pulse when the batch is written | high | `clk` | 0 |
| `err_irq` | output | 1 | `done && err` | high | `clk` | 0 |
| `wake` | output | 1 | one-clock pulse, at most once per batch: an average > `threshold` with `wake_en` = 1 | high | comb. | 0 |
| `sns_valid` | input | 1 | a sample is present in this clock (no back-pressure: an untaken sample is lost) | high | `clk` | - |
| `sns_data` | input | 16 | the sample, unsigned | - | `clk` | - |
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
| `nwords` | 16 | words queued for writing in this batch (dropped words not counted); the TB counts a sample as taken while `busy && sns_valid && nwords != len_q` |
| `len_q` | 16 | `xfer_len` latched at the start |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Sensor_Hub.md`](../ip/Sensor_Hub.md) (source: `scripts/apb/specs/Sensor_Hub.json`); do not edit by hand.

`Sensor_Hub_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sns_valid`, `sns_data`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C080100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | DST_ADDR | RW | 0x00000000 | Destination address (byte address, word aligned) |
| 0x018 | LEN | RW | 0x00000000 | Job length |
| 0x01C | CTRL | RW | 0x00000000 | Averaging and wake-up |
| 0x020 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x024 | STATUS | RO | core | Job state |
| 0x028 | SAMPLE | RO | core | Latest result |
| 0x02C | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C08 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| DST_ADDR | 31:0 | `dst_addr` | RW | 0x0 | first word written by the job |
| LEN | 15:0 | `xfer_len` | RW | 0x0 | 32-bit words (0: the job ends at once) |
| CTRL | 2:0 | `avg_log2` | RW | 0x0 | average 2^AVG_LOG2 samples |
| CTRL | 3 | `wake_en` | RW | 0x0 | 1: WAKE enabled |
| CTRL | 19:4 | `threshold` | RW | 0x0 | WAKE threshold |
| CMD | 0 | `start` | WO (pulse) | 0x0 | start a job with the current registers; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a job is running |
| STATUS | 1 | `err` | RO | core | the current / last job saw an AXI error response (cleared by start) |
| SAMPLE | 15:0 | `last_avg` | RO | core | latest average |
| SAMPLE | 31:16 | `drops` | RO | core | words dropped |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |
| 2 | WAKE | an average crossed THRESHOLD |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C080100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write DST_ADDR (0x014), LEN (0x018), CTRL (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x020; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x024) for the core's live `busy`, `err`; it needs no clearing.
7. Read SAMPLE (0x028) for the core's live `last_avg`, `drops`; it needs no clearing.
8. Read CYCLES (0x02C) for the core's live `cycles`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write SRC_ADDR, DST_ADDR (word aligned) and LEN (32-bit words).
2. Write CTRL with the job's options and IRQ_ENABLE with DONE (and ERR).
3. Write CMD.start = 1 (ignored while STATUS.busy is 1).
4. Wait for irq (or poll STATUS.busy = 0), read the result registers, write 1s to IRQ_STATUS to clear it.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Batch start

At the edge where `start && !busy`: the engine starts a write-only job (§3.3) of `xfer_len` words
at `dst_addr`; `avg_log2` (k) and `xfer_len` are latched, the accumulator, sample count, half-word
flag, wake flag, `drops` and the queued-word count are cleared.

### 3.2 Averaging and packing

A sample is taken in a clock where `busy`, `sns_valid` and fewer than `xfer_len` words have been
queued. At each taken sample:

- if it is not the last of its group of 2^k: accumulator += sample, count += 1;
- if it is the last: average = (accumulator + sample) >> k (unsigned, truncating), the
  accumulator and count restart, `last_avg` <= average. The first average of a pair is kept as
  the low half; the second forms the word {average, low half}, which is offered to the write
  side in that same clock. If the write FIFO can take it the word is queued, otherwise it is
  dropped and `drops` increments (the pair is lost either way, the next average starts a new
  pair).

`wake` is 1 in the clock of an average > `threshold` when `wake_en` = 1 and no wake has fired in
this batch. When `xfer_len` words are queued no more samples are taken; `busy` stays 1 until the
engine has written them all. With samples arriving no faster than the engine can write (the
FIFO holds 32 words) nothing is dropped.

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

`done` = the engine's done pulse; `err_irq` = `done && err`; `wake` as in §3.2. All are one
clock long.

### 3.5 Reset

`rst_n` low: no batch (`busy` = 0), accumulator, `last_avg`, `drops`, `err`, `cycles` = 0, all AXI
valid / ready outputs 0. A batch in progress is abandoned.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd9 | 4'd0 to 4'd15 | value of `m_awid` (and `m_arid`, which is never used) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `start` while `busy` | ignored |
| `len` = 0 | no bus traffic, `done` one clock after the start, `cycles` = 1 |
| buffer crossing a 4 KB boundary | the burst is split at the boundary |
| AXI error response (read or write) | `err` set until the next start; the job completes; the affected words are still written |
| unaligned `src` / `dst` | bits [1:0] ignored |
| reset in the middle of a job | `busy` = 0 and every AXI valid / ready output 0 at once; the subordinate must be reset too |
| write-only core | the read channel stays idle; `m_arvalid` and `m_rready` are always 0 |
| samples while no batch runs, or after the batch is complete | ignored (not taken) |
| write FIFO full when a word completes | word dropped, `drops` counted; the batch takes more samples to fill `xfer_len` words |
| `avg_log2` = 0 | every sample is an average |
| several averages above the threshold | one `wake` per batch |
| `threshold` or `wake_en` changed during a batch | later averages use the new values |

## 6. TB check map

Messages are printed by `tb/Sensor_Hub_tb.sv` through `fail()` as `ERROR: <message>`. The TB runs random
batches of 0 to 600 words with random averaging, threshold and sample spacing against
`tb/soc_ss_axi_mem.svh` (bursts checked, random stalls and error responses), plus a flood test
with one sample per clock and a stalling memory.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "batch of" | every batch ends within the time-out | §3.3 |
| "DONE pulses" | exactly one `done` per batch | §3.3, §3.4 |
| "ERR" | `err` is 1 exactly when an error response was injected | §3.3 |
| "ERR interrupt count" | one `err_irq` per failed batch | §3.4 |
| "no DROPS with one sample per clock and a stalling memory" | flood: words are dropped when the FIFO is full | §3.2 |
| "flood: too few samples taken" | flood: dropped words are replaced by taking more samples | §3.2 |
| "flood: word" | flood: every word of the batch is written | §3.2, §3.3 |
| "samples taken after the batch was complete" | no sample is taken once `xfer_len` words are queued | §3.2 |
| "DROPS" | no drops at normal sample rates | §3.2 |
| "LAST_AVG" | `last_avg` is the last average of the batch | §3.2 |
| "word" | every batch word equals the model's packed averages | §3.2, §3.3 |
| "not idle in reset" | reset mid-batch: `busy`, `m_awvalid`, `m_wvalid` all 0 | §3.5 |
