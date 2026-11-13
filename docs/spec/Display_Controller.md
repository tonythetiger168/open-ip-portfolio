<!-- SPDX-License-Identifier: Apache-2.0 -->
# Display_Controller: design specification

Display processor (DPU) scan-out of the phone SoC subsystem. A job fetches a frame of
`xfer_len` RGBA8888 pixels (one per 32-bit word) at `src_addr` with streaming AXI4 reads and sends
it to the panel interface (for example a DSI or DPI transmitter) as a valid / ready pixel stream
with line and frame markers, while computing the frame's CRC-32 signature and counting underrun
clocks. There is no composition, scaling, colour conversion or video timing generation: the
panel side paces the stream with `pix_ready`. Core `Display_Controller_top`
(`rtl/Display_Controller_top.sv`, uses `rtl/soc_ss_axi_engine.sv`), testbench
`tb/Display_Controller_tb.sv` (with `tb/soc_ss_axi_mem.svh`). There is no separate core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *pixel beat* is a clock with `pix_valid && pix_ready`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `src_addr` | input | 32 | frame buffer (bits [1:0] ignored); latched at start | - | `clk` | - |
| `xfer_len` | input | 16 | pixels in the frame; latched at start | - | `clk` | - |
| `line_words` | input | 16 | pixels per line for `pix_hsync` (0: every pixel ends a line); read live, hold it during the frame | - | comb. | - |
| `start` | input | 1 | starts a frame when `busy` = 0 | high | `clk` | - |
| `busy` | output | 1 | frame in progress | high | `clk` | 0 |
| `err` | output | 1 | an AXI read error response was seen in the current / last frame | high | `clk` | 0 |
| `frame_crc` | output | 32 | CRC-32 (IEEE 802.3, reflected, init and final XOR 0xFFFFFFFF) of the pixels sent so far, bytes of each pixel in little-endian order | - | `clk` | 0x00000000 |
| `underruns` | output | 16 | clocks of the current / last frame in which the panel was ready but no pixel was available (saturates at 0xFFFF) | - | `clk` | 0 |
| `cycles` | output | 32 | clocks of the current / last frame (§3.3) | - | `clk` | 0 |
| `done` | output | 1 | one-clock pulse at the end of every frame | high | `clk` | 0 |
| `err_irq` | output | 1 | `done && err` | high | `clk` | 0 |
| `pix_valid` | output | 1 | a pixel is available (the read FIFO is not empty) | high | `clk` | 0 |
| `pix_data` | output | 32 | the pixel, in frame order | - | `clk` | - |
| `pix_hsync` | output | 1 | with `pix_valid`: this pixel is the last of a line or of the frame | high | comb. | 0 |
| `pix_vsync` | output | 1 | with `pix_valid`: this pixel is the last of the frame | high | comb. | 0 |
| `pix_ready` | input | 1 | the panel takes the pixel | high | `clk` | - |
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

`tb/cov/Display_Controller_sva.sv` is bound to `Display_Controller_top` with `.*`, so a re-implementation must have these
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
Generated from [`docs/ip/Display_Controller.md`](../ip/Display_Controller.md) (source: `scripts/apb/specs/Display_Controller.json`); do not edit by hand.

`Display_Controller_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `pix_valid`, `pix_data`, `pix_hsync`, `pix_vsync`, `pix_ready`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C050100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | SRC_ADDR | RW | 0x00000000 | Source address (byte address, word aligned) |
| 0x018 | LEN | RW | 0x00000000 | Job length |
| 0x01C | LINE | RW | 0x00000000 | Panel geometry |
| 0x020 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x024 | STATUS | RO | core | Job state |
| 0x028 | FRAME_CRC | RO | core | Frame signature |
| 0x02C | UNDERRUNS | RO | core | Starved clocks |
| 0x030 | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x034 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C05 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| SRC_ADDR | 31:0 | `src_addr` | RW | 0x0 | first word read by the job |
| LEN | 15:0 | `xfer_len` | RW | 0x0 | 32-bit words (0: the job ends at once) |
| LINE | 15:0 | `line_words` | RW | 0x0 | pixels per line |
| CMD | 0 | `start` | WO (pulse) | 0x0 | start a job with the current registers; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a job is running |
| STATUS | 1 | `err` | RO | core | the current / last job saw an AXI error response (cleared by start) |
| FRAME_CRC | 31:0 | `frame_crc` | RO | core | CRC-32 of the pixels sent |
| UNDERRUNS | 15:0 | `underruns` | RO | core | clocks the panel waited for a pixel |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C050100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write SRC_ADDR (0x014), LEN (0x018), LINE (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x020; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x024) for the core's live `busy`, `err`; it needs no clearing.
7. Read FRAME_CRC (0x028) for the core's live `frame_crc`; it needs no clearing.
8. Read UNDERRUNS (0x02C) for the core's live `underruns`; it needs no clearing.
9. Read CYCLES (0x030) for the core's live `cycles`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write SRC_ADDR, DST_ADDR (word aligned) and LEN (32-bit words).
2. Write CTRL with the job's options and IRQ_ENABLE with DONE (and ERR).
3. Write CMD.start = 1 (ignored while STATUS.busy is 1).
4. Wait for irq (or poll STATUS.busy = 0), read the result registers, write 1s to IRQ_STATUS to clear it.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Frame start

At the edge where `start && !busy`: the engine starts a read-only job (§3.3) of `xfer_len` words
at `src_addr`; the CRC register is set to 0xFFFFFFFF (so `frame_crc` reads 0 until the first
pixel), the line position and `underruns` are cleared, and the pixels-left counter <= `xfer_len`.

### 3.2 Pixel stream

`pix_valid` and `pix_data` are the read FIFO's head; the panel's `pix_ready` pops it. At every
pixel beat: CRC <= CRC-32 update with the pixel's 4 bytes, byte 0 (bits [7:0]) first, bit 0 of
each byte first; pixels left decrements; the line position advances and wraps to 0 after
`line_words` pixels. `frame_crc` = ~CRC, so after the last pixel it is the standard CRC-32 of the
frame bytes (CRC-32 of the ASCII bytes "12345678" is 0x9AE0DAAF).

- `pix_hsync` = `pix_valid` and (`line_words` = 0, or this is pixel `line_words` - 1 of its line,
  or the last pixel of the frame).
- `pix_vsync` = `pix_valid` and this is the last pixel of the frame.

Underrun: at each edge with `busy`, `pix_ready`, no pixel available and pixels still to send,
`underruns` increments (up to 0xFFFF). This includes the clocks after the start before the first
read data arrives, so a frame always shows some underruns when the panel is ready from the start.

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

The frame ends (`done`) when all pixels have been fetched and the panel has taken the last one.

### 3.4 Interrupts

`done` = the engine's done pulse; `err_irq` = `done && err`. Both are one clock long.

### 3.5 Reset

`rst_n` low: no frame (`busy` = 0, `pix_valid` = 0), CRC register 0xFFFFFFFF, `underruns`,
`err`, `cycles` = 0, all AXI valid / ready outputs 0. A frame in progress is abandoned.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd4 | 4'd0 to 4'd15 | value of `m_arid` (and `m_awid`, which is never used) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `start` while `busy` | ignored |
| `len` = 0 | no bus traffic, `done` one clock after the start, `cycles` = 1 |
| buffer crossing a 4 KB boundary | the burst is split at the boundary |
| AXI error response (read or write) | `err` set until the next start; the job completes; the affected words are still written |
| unaligned `src` / `dst` | bits [1:0] ignored |
| reset in the middle of a job | `busy` = 0 and every AXI valid / ready output 0 at once; the subordinate must be reset too |
| read-only core | the write channel stays idle; `m_awvalid`, `m_wvalid`, `m_bready` are always 0 |
| panel stalls (`pix_ready` = 0) | pixels wait in the FIFO; reads stop when the FIFO cannot take another 16 words |
| `line_words` = 0 | every pixel carries `pix_hsync` |
| frame length not a multiple of `line_words` | the last, short line ends with `pix_hsync` on the frame's last pixel |
| `line_words` changed during a frame | the line position wraps against the new value |

## 6. TB check map

Messages are printed by `tb/Display_Controller_tb.sv` through `fail()` as `ERROR: <message>`. The TB runs
random frames of 0 to 600 pixels with a panel that is ready with a random probability against `tb/soc_ss_axi_mem.svh`, which itself checks every burst (size, INCR, WLAST, 4 KB,
at most 16 beats) and injects random stalls and error responses at one word of a job.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "vsync" | `pix_vsync` exactly on the last pixel of the frame | §3.2 |
| "hsync" | `pix_hsync` exactly at every line end and on the last pixel | §3.2 |
| "busy low after start" | `busy` = 1 in the clock after an accepted start (non-zero length) | §3.3 |
| "job of" | every job ends within 100000 clocks, also with `start` pulsed again while busy | §3.3 |
| "ERR" | `err` is 1 exactly when an error response was injected | §3.3 |
| "ERR interrupt count" | one `err_irq` pulse per failed job, none otherwise | §3.4 |
| "CYCLES = 0" | `cycles` non-zero after a non-empty job | §3.3 |
| "word" | every destination word equals the TB's reference model | §3.2, §3.3 |
| "read-only job wrote the destination" | a scan-out never writes memory | §3.1 |
| "pixel" | the pixel stream equals the frame buffer, in order | §3.2 |
| "FRAME_CRC" | `frame_crc` equals the CRC-32 of the frame | §3.2 |
| "UNDERRUNS" | `underruns` equals the TB's count of ready clocks without a pixel | §3.2 |
| "CRC-32 check value" | a frame of the ASCII bytes 12345678 gives 0x9AE0DAAF | §3.2 |
| "not idle in reset" | reset mid-job: `busy`, `m_awvalid`, `m_arvalid`, `m_wvalid` all 0 | §3.5 |

### Coverage-closure assertions

From `tb/cov/Display_Controller_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_reset_idle | while `!rst_n` (reset): `!pix_valid && !pix_hsync && !pix_vsync && underruns == 0 && frame_crc == 0` | §3 |
| a_pix_stream | always holds: `pix_valid == rs_valid && pix_data == rs_data && rs_ready == pix_ready` | §3 |
| a_hsync | always holds: `pix_hsync == (pix_valid && (m_eol \|\| m_left == 1))` | §3 |
| a_vsync | always holds: `pix_vsync == (pix_valid && m_left == 1)` | §3 |
| a_crc | always holds: `frame_crc == ~m_crc` | §3 |
| a_underruns | always holds: `underruns == m_und` | §3 |
| a_no_write_stream | always holds: `!ws_valid` | §3 |
| a_pixels_in_frame | whenever `pix_valid`: `m_left != 0` | §3 |
