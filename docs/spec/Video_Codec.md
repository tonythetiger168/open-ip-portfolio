<!-- SPDX-License-Identifier: Apache-2.0 -->
# Video_Codec: design specification

Video codec of the phone SoC subsystem, reduced to a lossless DPCM intra coder. A job reads
`xfer_len` words of 8-bit samples (four per word, byte 0 first) over an AXI4 manager port and
writes the same number of words: ENCODE replaces every sample by its difference to the previous
sample, DECODE undoes it. The predictor restarts at 128 at the start of the job and of each line.
It also reports how many residuals were zero and a checksum of the reconstructed frame. There is
no entropy coding, motion compensation, transform or bitstream format. Core `Video_Codec_top`
(`rtl/Video_Codec_top.sv`, uses `rtl/soc_ss_axi_engine.sv`), testbench `tb/Video_Codec_tb.sv`
(with `tb/soc_ss_axi_mem.svh`). There is no separate core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Sample arithmetic is modulo 256; the checksum is modulo 2^32.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `src_addr` | input | 32 | input words (bits [1:0] ignored); latched at start | - | `clk` | - |
| `dst_addr` | input | 32 | output words; latched at start | - | `clk` | - |
| `xfer_len` | input | 16 | words in the job; latched at start | - | `clk` | - |
| `mode` | input | 1 | 0 ENCODE, 1 DECODE; latched at start | - | `clk` | - |
| `line_words` | input | 16 | words per line: the predictor resets to 128 at every line start (0: only at the job start); read live, hold during the job | - | comb. | - |
| `start` | input | 1 | starts a job when `busy` = 0 | high | `clk` | - |
| `busy` | output | 1 | job running | high | `clk` | 0 |
| `err` | output | 1 | an AXI error response was seen in the current / last job | high | `clk` | 0 |
| `zeros` | output | 16 | zero residuals in the current / last job (saturating count) | - | `clk` | 0 |
| `checksum` | output | 32 | sum modulo 2^32 of the reconstructed words (ENCODE: the input words, DECODE: the output words) | - | `clk` | 0 |
| `cycles` | output | 32 | clocks of the current / last job (§3.3) | - | `clk` | 0 |
| `done` | output | 1 | one-clock pulse at the end of every job | high | `clk` | 0 |
| `err_irq` | output | 1 | `done && err` | high | `clk` | 0 |
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

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Video_Codec.md`](../ip/Video_Codec.md) (source: `scripts/apb/specs/Video_Codec.json`); do not edit by hand.

`Video_Codec_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C040100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | SRC_ADDR | RW | 0x00000000 | Source address (byte address, word aligned) |
| 0x018 | DST_ADDR | RW | 0x00000000 | Destination address (byte address, word aligned) |
| 0x01C | LEN | RW | 0x00000000 | Job length |
| 0x020 | CTRL | RW | 0x00000000 | Job options |
| 0x024 | LINE | RW | 0x00000000 | Frame geometry |
| 0x028 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x02C | STATUS | RO | core | Job state |
| 0x030 | ZEROS | RO | core | Zero residuals |
| 0x034 | CHECKSUM | RO | core | Frame checksum |
| 0x038 | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x03C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C04 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| SRC_ADDR | 31:0 | `src_addr` | RW | 0x0 | first word read by the job |
| DST_ADDR | 31:0 | `dst_addr` | RW | 0x0 | first word written by the job |
| LEN | 15:0 | `xfer_len` | RW | 0x0 | 32-bit words (0: the job ends at once) |
| CTRL | 0 | `mode` | RW | 0x0 | 0 ENCODE, 1 DECODE |
| LINE | 15:0 | `line_words` | RW | 0x0 | words per line, 0: one line |
| CMD | 0 | `start` | WO (pulse) | 0x0 | start a job with the current registers; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a job is running |
| STATUS | 1 | `err` | RO | core | the current / last job saw an AXI error response (cleared by start) |
| ZEROS | 15:0 | `zeros` | RO | core | zero residuals of the current / last job |
| CHECKSUM | 31:0 | `checksum` | RO | core | sum of the frame words |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C040100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write SRC_ADDR (0x014), DST_ADDR (0x018), LEN (0x01C), CTRL (0x020), LINE (0x024). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x028; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x02C) for the core's live `busy`, `err`; it needs no clearing.
7. Read ZEROS (0x030) for the core's live `zeros`; it needs no clearing.
8. Read CHECKSUM (0x034) for the core's live `checksum`; it needs no clearing.
9. Read CYCLES (0x038) for the core's live `cycles`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write SRC_ADDR, DST_ADDR (word aligned) and LEN (32-bit words).
2. Write CTRL with the job's options and IRQ_ENABLE with DONE (and ERR).
3. Write CMD.start = 1 (ignored while STATUS.busy is 1).
4. Wait for irq (or poll STATUS.busy = 0), read the result registers, write 1s to IRQ_STATUS to clear it.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Job start

At the edge where `start && !busy`: the engine starts (§3.3) with reads and writes enabled;
`mode` is latched, the predictor <= 128, the word position in the line <= 0, `zeros` and
`checksum` <= 0.

### 3.2 DPCM datapath

Each word passes from the read stream to the write stream in one clock (combinational). The
predictor p of byte 0 is 128 if the word starts a line (position 0), else the last reconstructed
sample of the previous word; the predictor of byte b > 0 is reconstructed sample b - 1 of the
same word. For each byte b with input v:

| Mode | Output byte | Reconstructed sample r | Zero residual when |
|---|---|---|---|
| ENCODE | v - p | v | output = 0 |
| DECODE | v + p | the output | v = 0 |

So DECODE of an ENCODE output with the same `line_words` gives the input back exactly, and both
jobs report the same `checksum` and `zeros`. At the edge where the word is taken: predictor <= r
of byte 3; `zeros` <= `zeros` + the word's zero residuals (0..4), saturating (once above 0xFFFB
it becomes 0xFFFF at the next word); `checksum` <= `checksum` + {r3, r2, r1, r0}; position <=
0 if `line_words` != 0 and position + 1 >= `line_words`, else position + 1.

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

`done` = the engine's done pulse; `err_irq` = `done && err`. Both are one clock long.

### 3.5 Reset

`rst_n` low: no job (`busy` = 0), mode ENCODE, predictor 128, `zeros`, `checksum`, `err`,
`cycles` = 0, all AXI valid / ready outputs 0. A job in progress is abandoned.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd5 | 4'd0 to 4'd15 | value of `m_awid` and `m_arid` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `start` while `busy` | ignored |
| `len` = 0 | no bus traffic, `done` one clock after the start, `cycles` = 1 |
| buffer crossing a 4 KB boundary | the burst is split at the boundary |
| AXI error response (read or write) | `err` set until the next start; the job completes; the affected words are still written |
| unaligned `src` / `dst` | bits [1:0] ignored |
| reset in the middle of a job | `busy` = 0 and every AXI valid / ready output 0 at once; the subordinate must be reset too |
| sample differences beyond -128..127 | wrap modulo 256; DECODE still restores the input exactly |
| `line_words` = 0 | one prediction chain over the whole job |
| `line_words` changed during a job | the line position wraps against the new value |

## 6. TB check map

Messages are printed by `tb/Video_Codec_tb.sv` through `fail()` as `ERROR: <message>`. The TB runs
random ENCODE and DECODE jobs of 0 to 600 words with random line lengths against `tb/soc_ss_axi_mem.svh`, which itself checks every burst (size, INCR, WLAST, 4 KB,
at most 16 beats) and injects random stalls and error responses at one word of a job.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "busy low after start" | `busy` = 1 in the clock after an accepted start (non-zero length) | §3.3 |
| "job of" | every job ends within 100000 clocks, also with `start` pulsed again while busy | §3.3 |
| "ERR" | `err` is 1 exactly when an error response was injected | §3.3 |
| "ERR interrupt count" | one `err_irq` pulse per failed job, none otherwise | §3.4 |
| "CYCLES = 0" | `cycles` non-zero after a non-empty job | §3.3 |
| "word" | every destination word equals the TB's reference model | §3.2, §3.3 |
| "read-only job wrote the destination" | (the TB's shared shape; Video_Codec jobs always write) | §3.1 |
| "ZEROS" | `zeros` equals the model's zero-residual count | §3.2 |
| "CHECKSUM" | `checksum` equals the sum of the model's reconstructed words | §3.2 |
| "not idle in reset" | reset mid-job: `busy`, `m_awvalid`, `m_arvalid`, `m_wvalid` all 0 | §3.5 |
