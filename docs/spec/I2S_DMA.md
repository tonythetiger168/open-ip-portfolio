<!-- SPDX-License-Identifier: Apache-2.0 -->
# I2S_DMA: design specification

I2S audio port with an AXI4 DMA. The unchanged `I2S_top` core (an I2S slave: BCLK and LRCK come
from the codec, see [I2S.md](I2S.md)) is fed and drained by the shared AXI data mover. A job plays
`xfer_len` stereo frames from memory (TX), records `xfer_len` frames to memory (RX), or both at
once. One 32-bit word holds one frame: left sample in bits [15:0], right in [31:16]. Frames that
memory cannot supply in time are repeated and counted; frames that cannot be written in time are
replaced by the newer one and counted. Core `I2S_DMA_top` (`rtl/I2S_DMA_top.sv`, uses
`rtl/I2S_top.sv` and `rtl/soc_ss_axi_engine.sv`), testbench `tb/I2S_DMA_tb.sv` (with
`tb/soc_ss_axi_mem.svh`). There is no separate core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *frame* runs from one LRCK change to left (a *frame start*) to
the next; its *left-to-right change* is the LRCK change in its middle. Both changes are seen
through the I2S core's 2-flop synchronizer (its `irq`). Frame F is the one running at the start
edge.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; at least 7x BCLK (I2S core requirement) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `bclk` | input | 1 | I2S bit clock from the codec | - | async (2 flops) | - |
| `lrck` | input | 1 | I2S word select from the codec, 0 = left | - | async (2 flops) | - |
| `sdin` | input | 1 | I2S data from the codec (RX) | - | `clk` | - |
| `sdout` | output | 1 | I2S data to the codec (TX); 16-bit samples, Philips timing | - | `clk` | 0 |
| `src_addr` | input | 32 | TX buffer (bits [1:0] ignored); latched at start | - | `clk` | - |
| `dst_addr` | input | 32 | RX buffer; latched at start | - | `clk` | - |
| `xfer_len` | input | 16 | frames in the job (TX and RX alike); latched at start | - | `clk` | - |
| `tx_en` | input | 1 | the job plays frames from `src_addr`; latched at start | high | `clk` | - |
| `rx_en` | input | 1 | the job records frames to `dst_addr`; latched at start | high | `clk` | - |
| `start` | input | 1 | starts a job when `busy` = 0 and `tx_en` or `rx_en` is 1 | high | `clk` | - |
| `busy` | output | 1 | job running | high | `clk` | 0 |
| `err` | output | 1 | an AXI error response was seen in the current / last job | high | `clk` | 0 |
| `frames` | output | 16 | TX words taken (TX or TX + RX job) or RX words queued (RX-only job) | - | `clk` | 0 |
| `tx_underrun` | output | 16 | frames repeated because no TX word was ready | - | `clk` | 0 |
| `rx_overrun` | output | 16 | received frames lost because the previous one was still waiting | - | `clk` | 0 |
| `cycles` | output | 32 | clocks of the current / last job (§3.4) | - | `clk` | 0 |
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

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/I2S_DMA.md`](../ip/I2S_DMA.md) (source: `scripts/apb/specs/I2S_DMA.json`); do not edit by hand.

`I2S_DMA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `bclk`, `lrck`, `sdin`, `sdout`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C210100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | SRC_ADDR | RW | 0x00000000 | TX buffer (byte address, word aligned) |
| 0x018 | DST_ADDR | RW | 0x00000000 | RX buffer (byte address, word aligned) |
| 0x01C | LEN | RW | 0x00000000 | Job length |
| 0x020 | CTRL | RW | 0x00000000 | Job directions |
| 0x024 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x028 | STATUS | RO | core | Job state |
| 0x02C | FRAMES | RO | core | Frames |
| 0x030 | XRUN | RO | core | Underrun / overrun counters (cleared by start) |
| 0x034 | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C21 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| SRC_ADDR | 31:0 | `src_addr` | RW | 0x0 | first word played |
| DST_ADDR | 31:0 | `dst_addr` | RW | 0x0 | first word written |
| LEN | 15:0 | `xfer_len` | RW | 0x0 | frames (32-bit words); 0: the job ends at once |
| CTRL | 0 | `tx_en` | RW | 0x0 | play LEN words from SRC_ADDR |
| CTRL | 1 | `rx_en` | RW | 0x0 | record LEN frames to DST_ADDR |
| CMD | 0 | `start` | WO (pulse) | 0x0 | start a job (TX_EN or RX_EN set); ignored while busy |
| STATUS | 0 | `busy` | RO | core | a job is running |
| STATUS | 1 | `err` | RO | core | the current / last job saw an AXI error response (cleared by start) |
| FRAMES | 15:0 | `frames` | RO | core | frames played / received by the current / last job |
| XRUN | 15:0 | `tx_underrun` | RO | core | TX frames repeated for want of data |
| XRUN | 31:16 | `rx_overrun` | RO | core | RX frames lost (replaced by a newer one) |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C210100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write SRC_ADDR (0x014), DST_ADDR (0x018), LEN (0x01C), CTRL (0x020). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x024; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x028) for the core's live `busy`, `err`; it needs no clearing.
7. Read FRAMES (0x02C) for the core's live `frames`; it needs no clearing.
8. Read XRUN (0x030) for the core's live `tx_underrun`, `rx_overrun`; it needs no clearing.
9. Read CYCLES (0x034) for the core's live `cycles`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write SRC_ADDR / DST_ADDR (word aligned) and LEN (frames).
2. Write CTRL.tx_en / rx_en and IRQ_ENABLE.
3. Write CMD.start = 1.
4. Wait for irq, read FRAMES and XRUN, write 1s to IRQ_STATUS to clear it.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Job start

At the edge where `start && !busy && (tx_en || rx_en)`: the engine starts (§3.4) with reads for
TX and writes for RX, `xfer_len` words each. TX is armed if `tx_en` and `xfer_len` != 0, RX
likewise; `frames`, `tx_underrun`, `rx_overrun` and the internal counters are cleared.

### 3.2 TX

At each left-to-right change while TX is armed:

- a word is ready (the read FIFO is not empty): it is taken; its left half is written to the
  core's TX left register at once and its right half is kept; `frames` increments (TX or TX + RX
  job). After `xfer_len` words TX is disarmed.
- no word is ready: `tx_underrun` increments and nothing is written, so the next frame repeats
  the previous frame's samples.

At the next frame start the kept right half is written to the core's TX right register. Because
the I2S core loads each channel's shifter one BCLK after the LRCK change that starts its slot
(see [I2S.md](I2S.md) §3.2), a word taken in frame F + k plays in frame F + k + 1, left then right.
With a job started early in frame F and memory keeping up, word k plays in frame F + 1 + k. The
last word still plays after `done`; the core keeps sending it until new words are written.

### 3.3 RX

While RX is armed, the first frame start after the job start (the end of frame F) only arms the
capture; every later frame start marks the end of a frame received entirely after the start. At
the first BCLK rise after that frame start the core has stored the frame's right sample (its LSB
arrives then, see [I2S.md](I2S.md) §3.3). The core's RX left and right registers are then read in
the next two clocks and the word {right, left} is offered to the engine's write stream:

- if no word is waiting, it is queued: the RX word count increments, and `frames` increments in
  an RX-only job;
- if the previous word is still waiting (the write FIFO is full), it is replaced by the new one
  and `rx_overrun` increments; the lost frame is not counted.

When `xfer_len` words have been queued RX is disarmed. So RX word k holds frame F + 1 + k when
memory keeps up, and in any case a frame later than word k - 1's.

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

The engine's `busy`, `done`, `err` and `cycles` are this core's outputs.

### 3.5 Reset

`rst_n` low: no job (`busy` = 0), I2S core reset (`sdout` = 0, its registers 0), all counters 0,
all AXI valid / ready outputs 0. A job in progress is abandoned.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd8 | 4'd0 to 4'd15 | value of `m_awid` and `m_arid` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `start` while `busy` | ignored |
| `len` = 0 | no bus traffic, `done` one clock after the start, `cycles` = 1 |
| buffer crossing a 4 KB boundary | the burst is split at the boundary |
| AXI error response (read or write) | `err` set until the next start; the job completes; the affected words are still written |
| unaligned `src` / `dst` | bits [1:0] ignored |
| reset in the middle of a job | `busy` = 0 and every AXI valid / ready output 0 at once; the subordinate must be reset too |
| `start` with `tx_en` = `rx_en` = 0 | ignored |
| TX words not ready in time | frame repeated, `tx_underrun` counted, no word skipped |
| RX words not written in time | the newest frame is kept, `rx_overrun` counts the frames lost; the job still writes `xfer_len` words |
| TX + RX job | `frames` counts TX words; both directions use `xfer_len` |
| slots longer than 16 bits | handled by the I2S core (padding); the frame timing is unchanged |

## 6. TB check map

Messages are printed by `tb/I2S_DMA_tb.sv` through `fail()` as `ERROR: <message>`. The TB is an I2S
master (BCLK = 8 clocks, 16-bit slots) sending a random frame every frame and decoding SDOUT. It
runs TX, RX and TX + RX jobs of 1 to 70 frames against `tb/soc_ss_axi_mem.svh`, each started two
BCLKs into a frame, and holds the AR or AW channel off for 40 frames to force underruns and
overruns.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "job timed out" | every job ends | §3.4 |
| "ERR" | `err` is 1 exactly when an error response was injected | §3.4 |
| "ERR interrupt count" | one `err_irq` per failed job | §3.4 |
| "FRAMES" | `frames` = `xfer_len` after the job | §3.2, §3.3 |
| "TX frame" | frames from F + 1 play word 0, 1, ... in order; any other frame repeats the previous one | §3.2 |
| "TX played" | all `xfer_len` words are played | §3.2 |
| "TX repeated" | `tx_underrun` equals the number of repeated frames; none without a hold | §3.2 |
| "no underrun with AXI reads held off" | holding AR off for 40 frames causes underruns | §3.2 |
| "RX word" | RX word k holds a frame later than word k - 1's, the first at F + 1 or later | §3.3 |
| "RX lost" | `rx_overrun` equals the number of frames skipped; none without a hold | §3.3 |
| "no overrun with AXI writes held off" | holding AW off for 40 frames causes overruns | §3.3 |
| "TX-only job wrote the destination" | a TX-only job never writes | §3.1 |
| "timeout" | the whole test ends within 200 ms | §3.4 |
