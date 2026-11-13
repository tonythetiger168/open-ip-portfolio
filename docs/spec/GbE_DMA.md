<!-- SPDX-License-Identifier: Apache-2.0 -->
# GbE_DMA: design specification

Ethernet MAC with descriptor-ring DMA. The unchanged `Ethernet_top` MAC (byte-wide GMII-style
interface, address filter, PAUSE; see [GMII.md](GMII.md) for the line side) is connected to a TX
and an RX descriptor ring in memory. One shared AXI data mover is time-shared between the two
directions by a scheduler. Core `GbE_DMA_top` (`rtl/GbE_DMA_top.sv`, uses `rtl/Ethernet_top.sv`
and `rtl/soc_ss_axi_engine.sv`), testbench `tb/GbE_DMA_tb.sv` (with `tb/soc_ss_axi_mem.svh`).
There is no separate core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *frame* is DA .. payload, without preamble, padding or FCS.
words(n) = ceil(n / 4).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `cfg_div` | input | 5 | MAC byte time = `cfg_div` + 1 clocks | - | `clk` | - |
| `cfg_mac` | input | 48 | station address for the RX filter | - | `clk` | - |
| `cfg_promisc` | input | 1 | accept every destination address | high | `clk` | - |
| `cfg_pause_en` | input | 1 | honour received PAUSE frames | high | `clk` | - |
| `gtxd` | output | 8 | transmit byte (one per byte time) | - | `clk` | 0 |
| `gtx_en` | output | 1 | transmit enable | high | `clk` | 0 |
| `gtx_er` | output | 1 | transmit error (only on a MAC underrun) | high | `clk` | 0 |
| `grxd` | input | 8 | receive byte, sampled once per byte time | - | `clk` | - |
| `grx_dv` | input | 1 | receive data valid | high | `clk` | - |
| `grx_er` | input | 1 | receive error | high | `clk` | - |
| `tx_en` | input | 1 | the TX ring is processed | high | `clk` | - |
| `rx_en` | input | 1 | received frames are accepted (a frame starting while 0 is dropped) | high | `clk` | - |
| `tx_base` | input | 32 | TX ring base address (8-byte entries) | - | `clk` | - |
| `tx_num` | input | 16 | TX ring entries (at least 1) | - | `clk` | - |
| `tx_tail` | input | 16 | software's TX tail: the next entry it will fill | - | `clk` | - |
| `tx_head` | output | 16 | hardware's TX head: the next entry it will use | - | `clk` | 0 |
| `rx_base` | input | 32 | RX ring base address | - | `clk` | - |
| `rx_num` | input | 16 | RX ring entries (at least 1) | - | `clk` | - |
| `rx_tail` | input | 16 | software's RX tail | - | `clk` | - |
| `rx_head` | output | 16 | hardware's RX head | - | `clk` | 0 |
| `clr_err` | input | 1 | clears `err` (CMD.clr_err) | high | `clk` | - |
| `err` | output | 1 | an AXI error response was seen; sticky until `clr_err` | high | `clk` | 0 |
| `tx_paused` | output | 1 | the MAC transmitter is held by a received PAUSE | high | `clk` | 0 |
| `tx_frames` | output | 16 | TX descriptors completed with a frame sent (wraps) | - | `clk` | 0 |
| `rx_frames` | output | 16 | RX descriptors completed (wraps) | - | `clk` | 0 |
| `rx_drop` | output | 16 | received frames dropped (wraps) | - | `clk` | 0 |
| `tx_irq` | output | 1 | one-clock pulse per completed TX descriptor | high | `clk` | 0 |
| `rx_irq` | output | 1 | one-clock pulse per completed RX descriptor | high | `clk` | 0 |
| `drop_irq` | output | 1 | one-clock pulse per dropped frame | high | `clk` | 0 |
| `err_irq` | output | 1 | one-clock pulse per engine job that ended with an AXI error | high | `clk` | 0 |
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

### Internal signals used by the coverage checker

`tb/cov/GbE_DMA_sva.sv` is bound to `GbE_DMA_top` with `.*`, so a re-implementation must have these
names (width as seen by the checker).

| Signal | Width | Meaning |
|---|---|---|
| `u_mac` | 1 | instance of the core's sub-module, probed hierarchically |
| `tx_valid` | 1 | core-internal signal read by name by the checker |
| `tx_ready` | 1 | core-internal signal read by name by the checker |
| `tx_last` | 1 | core-internal signal read by name by the checker |
| `rx_valid` | 1 | core-internal signal read by name by the checker |
| `e_start` | 1 | core-internal signal read by name by the checker |
| `e_rd` | 1 | core-internal signal read by name by the checker |
| `e_wr` | 1 | core-internal signal read by name by the checker |
| `e_done` | 1 | core-internal signal read by name by the checker |
| `e_err` | 1 | core-internal signal read by name by the checker |
| `e_src` | [31:0] | core-internal signal read by name by the checker |
| `e_dst` | 1 | core-internal signal read by name by the checker |
| `e_len` | [15:0] | core-internal signal read by name by the checker |
| `rs_valid` | 1 | core-internal signal read by name by the checker |
| `rs_ready` | 1 | core-internal signal read by name by the checker |
| `ws_valid` | 1 | core-internal signal read by name by the checker |
| `ws_ready` | 1 | core-internal signal read by name by the checker |
| `rs_data` | [31:0] | core-internal signal read by name by the checker |
| `ws_data` | 1 | core-internal signal read by name by the checker |
| `tx_done` | 1 | core-internal signal read by name by the checker |
| `tx_underrun` | 1 | core-internal signal read by name by the checker |
| `tx_data` | [7:0] | core-internal signal read by name by the checker |
| `rx_data` | 1 | core-internal signal read by name by the checker |
| `rx_last` | 1 | core-internal signal read by name by the checker |
| `rx_stat` | [3:0] | core-internal signal read by name by the checker |
| `st` | [3:0] | core-internal signal read by name by the checker |
| `txs_pend` | 1 | TX frame sent, status to write |
| `tx_busy` | 1 | a TX descriptor is being processed |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/GbE_DMA.md`](../ip/GbE_DMA.md) (source: `scripts/apb/specs/GbE_DMA.json`); do not edit by hand.

`GbE_DMA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `gtxd`, `gtx_en`, `gtx_er`, `grxd`, `grx_dv`, `grx_er`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C410100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Enables and MAC options |
| 0x018 | MAC0 | RW | 0x00000000 | Station address over two words (MAC1 holds bits 47:32, the first address bytes) |
| 0x01C | MAC1 | RW | 0x00000000 | Station address over two words (MAC1 holds bits 47:32, the first address bytes) |
| 0x020 | TX_BASE | RW | 0x00000000 | TX ring base (byte address, word aligned) |
| 0x024 | TX_NUM | RW | 0x00000000 | TX ring entries |
| 0x028 | TX_TAIL | RW | 0x00000000 | TX tail (software) |
| 0x02C | RX_BASE | RW | 0x00000000 | RX ring base (byte address, word aligned) |
| 0x030 | RX_NUM | RW | 0x00000000 | RX ring entries |
| 0x034 | RX_TAIL | RW | 0x00000000 | RX tail (software) |
| 0x038 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x03C | HEAD | RO | core | Hardware heads |
| 0x040 | STATUS | RO | core | State |
| 0x044 | FRAMES | RO | core | Frame counters |
| 0x048 | RX_DROP | RO | core | Dropped frames |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x04C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C41 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `tx_en` | RW | 0x0 | process TX descriptors |
| CTRL | 1 | `rx_en` | RW | 0x0 | accept frames |
| CTRL | 2 | `cfg_promisc` | RW | 0x0 | accept every destination address |
| CTRL | 3 | `cfg_pause_en` | RW | 0x0 | honour received PAUSE frames |
| CTRL | 8:4 | `cfg_div` | RW | 0x0 | byte time = cfg_div + 1 clocks |
| MAC0 | 31:0 | `cfg_mac[31:0]` | RW | 0x0 | accepted destination address |
| MAC1 | 15:0 | `cfg_mac[47:32]` | RW | 0x0 | accepted destination address |
| TX_BASE | 31:0 | `tx_base` | RW | 0x0 | descriptor 0 |
| TX_NUM | 15:0 | `tx_num` | RW | 0x0 | 1..65535 |
| TX_TAIL | 15:0 | `tx_tail` | RW | 0x0 | next entry software will fill |
| RX_BASE | 31:0 | `rx_base` | RW | 0x0 | descriptor 0 |
| RX_NUM | 15:0 | `rx_num` | RW | 0x0 | 1..65535 |
| RX_TAIL | 15:0 | `rx_tail` | RW | 0x0 | next entry software will post |
| CMD | 0 | `clr_err` | WO (pulse) | 0x0 | clear STATUS.err |
| HEAD | 15:0 | `tx_head` | RO | core | next TX entry the hardware will use |
| HEAD | 31:16 | `rx_head` | RO | core | next RX entry the hardware will use |
| STATUS | 0 | `err` | RO | core | an AXI error response was seen (until CMD.clr_err) |
| STATUS | 1 | `tx_paused` | RO | core | the transmitter is held by a PAUSE |
| FRAMES | 15:0 | `tx_frames` | RO | core | frames sent |
| FRAMES | 31:16 | `rx_frames` | RO | core | frames written to memory |
| RX_DROP | 15:0 | `rx_drop` | RO | core | frames dropped |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX | a TX descriptor was written back |
| 1 | RX | an RX descriptor was written back |
| 2 | DROP | a received frame was dropped |
| 3 | ERR | an AXI error response |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C410100.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), MAC0 (0x018), MAC1 (0x01C), TX_BASE (0x020), TX_NUM (0x024), TX_TAIL (0x028), RX_BASE (0x02C), RX_NUM (0x030), RX_TAIL (0x034). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
5. To issue a command, write 1 to `clr_err` (CMD bit 0) at 0x038; the core sees a one-clock pulse, and the register reads 0.
6. Read HEAD (0x03C) for the core's live `tx_head`, `rx_head`; it needs no clearing.
7. Read STATUS (0x040) for the core's live `err`, `tx_paused`; it needs no clearing.
8. Read FRAMES (0x044) for the core's live `tx_frames`, `rx_frames`; it needs no clearing.
9. Read RX_DROP (0x048) for the core's live `rx_drop`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write MAC, CTRL.cfg_div, TX_BASE / TX_NUM, RX_BASE / RX_NUM, then CTRL.tx_en / rx_en.
2. RX: fill descriptors with buffer address and size, advance RX_TAIL.
3. TX: fill descriptors with buffer address and frame length, advance TX_TAIL.
4. On TX / RX interrupts read HEAD and the written-back descriptors.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Descriptors and rings

A descriptor is two words at ring base + 8 x i (entry i, 0 to num - 1): word 0 the buffer address
(word aligned; bits [1:0] ignored), word 1 the length. Entries head .. tail - 1 (modulo num) belong
to the hardware; head = tail means the ring is empty. The hardware advances its head by one entry
(wrapping from num - 1 to 0) after it has written the entry's status back to word 1. Software must
not write an entry it has handed over until the head has passed it, and must never make tail run
into head from behind (at most num - 1 entries handed over).

TX word 1, from software: frame length in bytes. Written back:

| Bits | Field |
|---|---|
| 31 | done = 1 |
| 30 | 0 |
| 29 | underrun: the MAC underran on this frame |
| 28 | bad_len: length 0 or above `TXF_BYTES`; the frame was not sent |
| 27:16 | 0 |
| 15:0 | length, as posted |

RX word 1, from software: buffer size in bytes. Written back:

| Bits | Field |
|---|---|
| 31 | done = 1 |
| 30 | trunc: the frame was longer than the buffer |
| 29:20 | 0 |
| 19:16 | the MAC's `rx_stat` {pause, phy_err, len_err, crc_err} |
| 15:0 | frame length in bytes (without FCS), even when truncated |

### 3.2 Scheduler

The engine runs one job at a time. When idle the scheduler picks, in this order:

1. a pending TX status write-back (§3.3);
2. an RX job: `rx_en` = 1, a received frame is waiting in the RX FIFO and `rx_head` != `rx_tail`;
3. a TX job: `tx_en` = 1, no TX descriptor is in progress and `tx_head` != `tx_tail`.

Only one TX descriptor is in progress at a time (from its fetch until its status is written), so
frames are sent strictly in ring order. RX and TX jobs interleave while a TX frame is on the wire.

### 3.3 TX

1. Fetch: a 2-word read of the descriptor at `tx_base` + 8 x `tx_head`.
2. If the length is 0 or above `TXF_BYTES`: status {done, bad_len, length} is queued (step 5); no
   frame is sent and `tx_frames` does not count it.
3. Else the buffer is read whole: words(length) words from word 0 into the TX FIFO (store and
   forward). After the read's engine `done` the frame is offered to the MAC, byte b of the frame
   being byte b mod 4 of FIFO word b / 4 (address order, bits [7:0] first).
4. The MAC sends preamble, frame, zero padding to 60 bytes and FCS. At its `tx_done` the status
   {done, underrun, length} is queued; underrun is set if the MAC pulsed `tx_underrun` (never
   expected: the whole frame is buffered).
5. Status write-back: a 1-word write to word 1 of the descriptor (the highest scheduler priority).
   At its engine `done`: `tx_head` advances, `tx_frames` increments unless bad_len, and `tx_irq`
   pulses for one clock. Then the next TX descriptor may be fetched.

### 3.4 RX

Receive path: the MAC delivers accepted frames (address filter: `cfg_mac`, broadcast, the PAUSE
address, or anything with `cfg_promisc`) without FCS, with `rx_stat` on the last byte. Bytes are
packed into words in address order (byte 0 in bits [7:0]; the unused bytes of the last word are 0)
and pushed into the RX FIFO (`RXF_BYTES`). A record {rx_stat, length} is kept per waiting frame,
at most 4.

A frame is dropped (`rx_drop` + 1, `drop_irq` for one clock, its words forgotten) when, at its
first byte, `rx_en` = 0 or 4 records are already waiting, or when the RX FIFO fills during it. The
drop is counted at the frame's last byte. With no free descriptor, frames wait in the FIFO.

RX job for the oldest waiting frame, with take = min(length, buffer size):

1. Fetch: a 2-word read of the descriptor at `rx_base` + 8 x `rx_head`.
2. Copy: if take != 0, a write of words(take) words from the RX FIFO to the buffer address. When
   take is not a multiple of 4 the last word is written whole, so up to 3 bytes past the buffer
   size are written (frame bytes when truncated, 0 otherwise).
3. Drain: words(length) - words(take) FIFO words of a truncated frame are discarded (one per
   clock).
4. Status write-back: a 1-word write of {done, trunc, rx_stat, length} to word 1. At its engine
   `done`: the frame's record is freed, `rx_head` advances, `rx_frames` increments, `rx_irq`
   pulses for one clock.

### 3.5 AXI data mover

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

Every job above is one engine job with this core's constant ID.

### 3.6 Errors

When an engine job ends with an AXI error response, `err` <= 1 and `err_irq` pulses for one clock.
`err` stays 1 until `clr_err` (a new error in the same clock wins). The job's data is used as
received: a descriptor fetched with an error response is processed with whatever words the
subordinate returned, and the ring still advances (for example a TX descriptor read as length 0
completes as bad_len).

### 3.7 Reset

`rst_n` low: scheduler idle, both heads 0, all counters 0, FIFOs empty, the MAC reset (`gtx_en`
= 0), every AXI valid / ready output 0. Jobs and frames in progress are abandoned.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd10 | 4'd0 to 4'd15 | value of `m_awid` and `m_arid` |
| `TXF_BYTES` | 2048 | power of 2, 64 to 32768 | TX FIFO size; the longest frame that can be sent |
| `RXF_BYTES` | 4096 | power of 2, at least 64 | RX FIFO size, shared by up to 4 waiting frames |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| TX length 0 or above `TXF_BYTES` | not sent; written back with bad_len; `tx_irq` but no `tx_frames` count |
| TX frame shorter than 60 bytes | the MAC pads with zeros to 60 bytes |
| RX frame longer than the buffer | the first take bytes (rounded up to a word) are written, the rest discarded; trunc = 1, the full length reported |
| RX buffer size 0 | nothing is written; status only, trunc = 1 |
| RX frame with a MAC error (CRC, length, PHY) | delivered and written back with its `rx_stat`; not dropped |
| RX frame failing the address filter | dropped silently by the MAC; not counted in `rx_drop` |
| fifth waiting frame, or `rx_en` = 0 at its start | dropped, `rx_drop` and `drop_irq` |
| RX FIFO full during a frame | the frame is dropped |
| `tx_en` = 0 | no new TX descriptor is fetched; a frame in progress completes |
| `rx_en` = 0 | no new RX job starts; frames starting are dropped; waiting frames stay |
| AXI error response | `err` (sticky) and `err_irq`; the descriptor is still completed |
| unaligned buffer addresses | bits [1:0] ignored |
| reset while busy | everything idle at once; the subordinate must be reset too |

## 6. TB check map

Messages are printed by `tb/GbE_DMA_tb.sv` through `fail()` as `ERROR: <message>`. The link partner
is a second `Ethernet_top` (`cfg_div` = 1, promiscuous) wired back to back. The TB posts random
TX frames of 1 to 1514 bytes into a ring of 8 and RX buffers into a ring of 6 (random sizes, some
smaller than the frame) against `tb/soc_ss_axi_mem.svh` (bursts checked, random stalls, error
responses in a chosen region), with TX and RX at the same time.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "partner received a frame nobody sent" | no frame is sent that was not posted | §3.3 |
| "partner rx_stat" | every sent frame arrives with a good FCS and length | §3.3 |
| "TX frame" | every posted frame arrives in ring order with its bytes, zero padded to 60 bytes | §3.3 |
| "TX descriptor" | each TX write-back is {done, 0, length} | §3.1, §3.3 |
| "TX:" | all posted frames are sent within the time limit | §3.3 |
| "RX descriptor" | each RX write-back is {done, trunc, stat 0, length} | §3.1, §3.4 |
| "RX frame" | the first take bytes in the buffer are the frame's; nothing written past take rounded up to a word | §3.4 |
| "RX descriptor completed with no frame sent" | no RX descriptor completes without a frame | §3.4 |
| "only" | all expected RX frames arrive within the time limit | §3.4 |
| "TX_HEAD did not reach TX_TAIL" | the TX head reaches the tail after the frames are sent | §3.3 |
| "TX_FRAMES" | `tx_frames` counts the frames sent; one `tx_irq` per frame | §3.3 |
| "RX_DROP" | with no free descriptor 4 frames wait and the fifth is dropped; they are delivered once buffers are posted | §3.4 |
| "a frame was not dropped with RX_EN off" | a frame received with `rx_en` = 0 is dropped; one `drop_irq` per drop | §3.4 |
| "RX_FRAMES" | `rx_frames` counts the completed RX descriptors; one `rx_irq` per frame | §3.4 |
| "ERR low after an SLVERR descriptor read" | an error response on a descriptor fetch sets `err` | §3.6 |
| "no ERR interrupt" | and pulses `err_irq` | §3.6 |
| "the bad TX descriptor was not consumed" | the descriptor fetched with an error is still completed | §3.6 |
| "CMD.clr_err did not clear ERR" | `clr_err` clears `err` | §3.6 |
| "TX frames left over" | every posted TX frame was received | §3.3 |
| "RX frames left over" | every accepted RX frame was delivered | §3.4 |
| "timeout" | the whole test ends within 100 ms | §3.2 |

The TB also prints `LAT GbE_DMA axi R|W <clocks>` for every burst (performance report, not a
check).

### Coverage-closure assertions

From `tb/cov/GbE_DMA_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_reset_idle | while `!rst_n` (reset): `tx_head == 0 && rx_head == 0 && tx_frames == 0 && rx_frames == 0 && rx_drop == 0 && !err && !tx_valid && !e_start` | §3 |
| a_heads | always holds: `tx_head == t_head && rx_head == r_head` | §3 |
| a_counters | always holds: `tx_frames == t_frames && rx_frames == r_frames && rx_drop == m_drop` | §3 |
| a_err | always holds: `err == m_err` | §3 |
| a_err_irq | whenever `e_done && e_err`, on the next clock: `err_irq` | §3 |
| a_irqs | always holds: `tx_irq == $past(st == S_TXS && e_done && !e_start) && rx_irq == $past(st == S_RXS && e_done && !e_start) && drop_irq == $past(rx_valid && rx_last && f_drop_now)` | §3 |
| a_sched | whenever `st == S_IDLE`: `##1 st == sched_q` | §3 |
| a_job_rx_desc | whenever `st == S_RXD && e_start`: `e_src == rx_base + {13'd0, r_head, 3'b000} && e_len == 2 && e_rd && !e_wr && w_info.size() != 0` | §3 |
| a_job_tx_desc | whenever `st == S_TXD && e_start`: `e_src == tx_base + {13'd0, t_head, 3'b000} && e_len == 2 && e_rd && !e_wr` | §3 |
| a_job_tx_status | whenever `st == S_TXS && e_start`: `e_dst == tx_base + {13'd0, t_head, 3'b100} && e_len == 1 && !e_rd && e_wr` | §3 |
| a_job_tx_buf | whenever `st == S_TXB && e_start`: `e_src == d_w0 && e_len == wds(t_len) && e_rd && !e_wr && !t_bad` | §3 |
| a_job_rx_buf | whenever `st == S_RXB && e_start`: `e_dst == d_w0 && e_len == r_take && !e_rd && e_wr && r_take != 0` | §3 |
| a_job_rx_status | whenever `st == S_RXS && e_start`: `e_dst == rx_base + {13'd0, r_head, 3'b100} && e_len == 1 && !e_rd && e_wr` | §3 |
| a_job_only_on_entry | always holds: `e_start -> $past(st) != st` | §3 |
| a_tx_store_fwd | whenever `tx_valid`: `st != S_TXB && t_words.size() == int'(wds(t_len)) - int'(t_bi / 4)` | §3 |
| a_tx_byte | whenever `tx_valid`: `tx_data == tx_byte() && tx_last == (t_bi + 1 == t_len)` | §3 |
| a_tx_status | whenever `st == S_TXS && ws_valid`: `ws_data == {1'b1, 1'b0, t_ur && !t_bad, t_bad, 12'd0, t_len}` | §3 |
| a_rx_word | whenever `st == S_RXB && ws_valid && ws_ready`: `ws_data == rx_word(int'(r_left)) && r_left < r_take` | §3 |
| a_rx_status | whenever `st == S_RXS && ws_valid`: `ws_data == {1'b1, w_len > d_w1[15:0], 10'd0, w_stat, w_len}` | §3 |
| a_no_underrun | always holds: `!tx_underrun` | §3 |

### Further TB checks

| Check (TB message) | What it requires | Spec |
|---|---|---|
| "bad-length TX descriptor write-back" | fails when `w !== {1'b1, 1'b0, 1'b0, 1'b1, 12'd0, 16'(len)}` (`tb/GbE_DMA_tb.sv` line 241) | §3 |
| "FIFO full: RX_DROP" | fails when `rx_drop != d0 + 1` (`tb/GbE_DMA_tb.sv` line 433) | §3 |
| "40000-byte frame: RX_DROP" | fails when `rx_drop != d0 + 1` (`tb/GbE_DMA_tb.sv` line 479) | §3 |
| "drop run: RX_DROP" | fails when `rx_drop != 16'(n0 + 65540)` (`tb/GbE_DMA_tb.sv` line 546) | §3 |
| "long runs: rings not drained" | fails when `tx_head != tx_tail \|\| rx_head != rx_tail` (`tb/GbE_DMA_tb.sv` line 547) | §3 |
| "TX not idle in reset" | fails when `dut.tx_valid \|\| tx_head != 0` (`tb/GbE_DMA_tb.sv` line 571) | §3 |
