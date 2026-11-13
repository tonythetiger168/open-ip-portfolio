<!-- SPDX-License-Identifier: Apache-2.0 -->
# Smartcard_7816: design specification

ISO/IEC 7816-3 smartcard interface (conditional-access card reader) with DMA: received characters
go to an RX ring in memory, transmitted characters come from a TX buffer. Card activation and
deactivation, direct and inverse convention, T=0 character-level error signalling and repetition,
T=1 parity flags, the waiting time. Core `Smartcard_7816_top` (`rtl/Smartcard_7816_top.sv`, uses
`rtl/soc_ss_axi_engine.sv` twice and `rtl/tv_fifo.sv`), testbench `tb/Smartcard_7816_tb.sv`
(with a card model and `tb/soc_ss_axi_mem.svh`). There is no separate core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *card clock* is one `sc_clk` period; the bit timing counts card
clocks (one clock enable per `sc_clk` rising edge). E = `etu`, or 1 when `etu` = 0. Times in a
character are in ETU from the start bit's falling edge: bit k (0 start, 1 to 8 data, 9 parity)
spans k to k + 1 ETU.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `sc_vcc_en` | output | 1 | card power (VCC) on | high | `clk` | 0 |
| `sc_rst_n` | output | 1 | card RST | low | `clk` | 0 |
| `sc_clk` | output | 1 | card CLK; period 2 x (`clk_div` + 1) clocks while running, else 0 | - | `clk` | 0 |
| `sc_io_in` | input | 1 | I/O line level | - | async (2 flops) | - |
| `sc_io_oe_low` | output | 1 | pull the open-drain I/O line low | high | `clk` | 0 |
| `sc_det` | input | 1 | card present | high | async (2 flops) | - |
| `enable` | input | 1 | interface enabled; 0 deactivates the card | high | `clk` | - |
| `inverse` | input | 1 | inverse convention (MSB first, low = 1) | high | `clk` | - |
| `t1` | input | 1 | protocol T=1 (no character-level error signalling); 0 = T=0 | high | `clk` | - |
| `clk_div` | input | 8 | `sc_clk` half period - 1, in clocks | - | `clk` | - |
| `etu` | input | 16 | elementary time unit in card clocks (F / D; 372 after reset); 0 counts as 1 | - | `clk` | - |
| `guard` | input | 8 | extra guard time in ETU: characters are sent 12 + `guard` ETU start to start | - | `clk` | - |
| `wt` | input | 16 | waiting time in ETU; 0 = off | - | `clk` | - |
| `rst_clks` | input | 16 | RST low time after power-up, in card clocks | - | `clk` | - |
| `ring_base` | input | 32 | RX ring base address | - | `clk` | - |
| `ring_words` | input | 16 | RX ring size in words (at least 2) | - | `clk` | - |
| `rd_idx` | input | 16 | software's RX ring read index | - | `clk` | - |
| `tx_addr` | input | 32 | TX buffer address | - | `clk` | - |
| `tx_len` | input | 16 | TX bytes | - | `clk` | - |
| `activate` | input | 1 | command: activate the card | high | `clk` | - |
| `deactivate` | input | 1 | command: deactivate the card | high | `clk` | - |
| `tx_start` | input | 1 | command: send `tx_len` bytes | high | `clk` | - |
| `active` | output | 1 | activation complete (RST high), card not being deactivated | high | `clk` | 0 |
| `powered` | output | 1 | = `sc_vcc_en` | high | `clk` | 0 |
| `tx_busy` | output | 1 | a TX is running | high | `clk` | 0 |
| `tx_fail` | output | 1 | the last TX failed (4 repetitions) or was cut by deactivation | high | `clk` | 0 |
| `err` | output | 1 | an AXI error response was seen; cleared by `activate` | high | `clk` | 0 |
| `present` | output | 1 | synchronised `sc_det` | high | `clk` | 0 |
| `wr_idx` | output | 16 | hardware's RX ring write index | - | `clk` | 0 |
| `rx_cnt` | output | 16 | characters written to the ring (saturates) | - | `clk` | 0 |
| `perr_cnt` | output | 16 | received characters with a parity error (saturates) | - | `clk` | 0 |
| `retx_cnt` | output | 16 | TX characters repeated after an error signal (saturates) | - | `clk` | 0 |
| `ovf_cnt` | output | 16 | received characters dropped, FIFO full (saturates) | - | `clk` | 0 |
| `rx` | output | 1 | pulse: a character was written to the ring | high | `clk` | 0 |
| `tx_done` | output | 1 | pulse: a TX ended (sent, failed or cut) | high | `clk` | 0 |
| `perr` | output | 1 | pulse: a received parity error, or a TX failed after 4 repetitions | high | `clk` | 0 |
| `det` | output | 1 | pulse: the synchronised `sc_det` changed | high | `clk` | 0 |
| `timeout` | output | 1 | pulse: the waiting time expired | high | `clk` | 0 |
| `err_irq` | output | 1 | pulse: with `rx` or `tx_done` when that access saw an AXI error | high | `clk` | 0 |
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
| `re_busy` | 1 | the RX ring engine is writing a word |
| `f_empty` | 1 | the 8-word RX FIFO is empty (the TB waits for it and `re_busy` before checking the ring) |
| `clk_run` | 1 | the card clock runs; falls when CLK is stopped in the deactivation (§3.2) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Smartcard_7816.md`](../ip/Smartcard_7816.md) (source: `scripts/apb/specs/Smartcard_7816.json`); do not edit by hand.

`Smartcard_7816_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sc_vcc_en`, `sc_rst_n`, `sc_clk`, `sc_io_in`, `sc_io_oe_low`, `sc_det`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C0A0100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Interface control |
| 0x018 | TIMING | RW | 0x00000000 | Character timing |
| 0x01C | WAITS | RW | 0x00000000 | Reset and waiting times |
| 0x020 | RING_BASE | RW | 0x00000000 | RX ring address |
| 0x024 | RING_WORDS | RW | 0x00000000 | RX ring size |
| 0x028 | RD_IDX | RW | 0x00000000 | Software read index |
| 0x02C | TX_ADDR | RW | 0x00000000 | TX buffer address |
| 0x030 | TX_LEN | RW | 0x00000000 | TX length |
| 0x034 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x038 | STATUS | RO | core | State |
| 0x03C | WR_IDX | RO | core | Hardware write index |
| 0x040 | RX_COUNTS | RO | core | RX counters |
| 0x044 | TX_COUNTS | RO | core | TX and overflow counters |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x048 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C0A | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 5:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 5:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `enable` | RW | 0x0 | interface on; 0 deactivates the card and clears WR_IDX |
| CTRL | 1 | `inverse` | RW | 0x0 | inverse convention (MSB first, low = 1) |
| CTRL | 2 | `t1` | RW | 0x0 | protocol T=1 (no parity error signalling) |
| CTRL | 10:3 | `clk_div` | RW | 0x0 | CLK toggles every CLK_DIV + 1 clocks |
| TIMING | 15:0 | `etu` | RW | 0x0 | card clocks per ETU (F / D; 0 counts as 1) |
| TIMING | 23:16 | `guard` | RW | 0x0 | extra guard time N in ETU |
| WAITS | 15:0 | `wt` | RW | 0x0 | waiting time in ETU (0: off) |
| WAITS | 31:16 | `rst_clks` | RW | 0x0 | card clocks of RST low at activation |
| RING_BASE | 31:0 | `ring_base` | RW | 0x0 | word 0, word aligned |
| RING_WORDS | 15:0 | `ring_words` | RW | 0x0 | words (at least 2); move or resize the ring only while WR_IDX is below the new size, or with ENABLE 0 (which clears WR_IDX) |
| RD_IDX | 15:0 | `rd_idx` | RW | 0x0 | next ring word software reads |
| TX_ADDR | 31:0 | `tx_addr` | RW | 0x0 | byte 0, word aligned |
| TX_LEN | 15:0 | `tx_len` | RW | 0x0 | bytes to send |
| CMD | 0 | `activate` | WO (pulse) | 0x0 | power the card and reset it (card present, ENABLE) |
| CMD | 1 | `deactivate` | WO (pulse) | 0x0 | deactivate the card |
| CMD | 2 | `tx_start` | WO (pulse) | 0x0 | send TX_LEN bytes; ignored while a TX runs |
| STATUS | 0 | `active` | RO | core | the card is powered and out of reset |
| STATUS | 1 | `powered` | RO | core | VCC is on |
| STATUS | 2 | `tx_busy` | RO | core | a TX is running |
| STATUS | 3 | `tx_fail` | RO | core | the last TX failed (repetitions exhausted or deactivation) |
| STATUS | 4 | `err` | RO | core | an AXI error response since the activation |
| STATUS | 5 | `present` | RO | core | card detect (sc_det) |
| WR_IDX | 15:0 | `wr_idx` | RO | core | next ring word the core writes |
| RX_COUNTS | 15:0 | `rx_cnt` | RO | core | characters stored |
| RX_COUNTS | 31:16 | `perr_cnt` | RO | core | characters received with a parity error |
| TX_COUNTS | 15:0 | `retx_cnt` | RO | core | characters sent again |
| TX_COUNTS | 31:16 | `ovf_cnt` | RO | core | characters dropped (FIFO full) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RX | a character is in the ring |
| 1 | TX_DONE | a TX ended |
| 2 | PERR | an RX parity error, or a TX that failed after 4 repetitions |
| 3 | DET | card inserted or removed |
| 4 | TIMEOUT | the waiting time passed without a character |
| 5 | ERR | an RX ring write or a TX buffer read saw an AXI error response |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C0A0100.
2. Write 0x3F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), TIMING (0x018), WAITS (0x01C), RING_BASE (0x020), RING_WORDS (0x024), RD_IDX (0x028), TX_ADDR (0x02C), TX_LEN (0x030). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3F enables all).
5. To issue a command, write 1 to `activate` (CMD bit 0), `deactivate` (CMD bit 1), `tx_start` (CMD bit 2) at 0x034; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x038) for the core's live `active`, `powered`, `tx_busy`, `tx_fail`, `err`, `present`; it needs no clearing.
7. Read WR_IDX (0x03C) for the core's live `wr_idx`; it needs no clearing.
8. Read RX_COUNTS (0x040) for the core's live `rx_cnt`, `perr_cnt`; it needs no clearing.
9. Read TX_COUNTS (0x044) for the core's live `retx_cnt`, `ovf_cnt`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL (enable, clk_div), TIMING (ETU 372 at first), WAITS, RING_BASE, RING_WORDS, RD_IDX = 0 and IRQ_ENABLE.
2. On DET with STATUS.present = 1 write CMD.activate = 1; read the ATR from the ring on RX (set CTRL.inverse if TS is 0x3F).
3. Put a command in the TX buffer, write TX_ADDR, TX_LEN and CMD.tx_start = 1; on TX_DONE check STATUS.tx_fail, then read the card's answer from the ring.
4. Write CMD.deactivate = 1 to power the card down.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Synchronisers, detect, card clock

`sc_io_in` and `sc_det` go through two flops. `present` = synchronised `sc_det`; `det` pulses for
one clock when it changes. While the card clock runs, `sc_clk` toggles every `clk_div` + 1 clocks
(starting low); when stopped it is 0.

### 3.2 Activation and deactivation

- Off: `activate` with `present` and `enable`: `sc_vcc_en` <= 1, the card clock starts,
  `sc_rst_n` = 0. Also `err` <= 0.
- RST stays low for `rst_clks` card clocks, then `sc_rst_n` <= 1 and `active` = 1. The card
  answers with its ATR, received like any character.
- Deactivation, by `deactivate`, `present` = 0 or `enable` = 0 while activating or active:
  `sc_rst_n` <= 0 at once (`active` = 0); at the second card clock rising edge after that the
  card clock stops (`clk_run` = 0, `sc_clk` low); 16 clocks later `sc_vcc_en` <= 0. Order: RST,
  then CLK, then VCC.

### 3.3 Character format

Start bit (low), 8 data bits, the parity bit (even parity over the data), then the guard time.
Direct convention (`inverse` = 0): LSB first, high = 1. Inverse convention: MSB first, low = 1,
the parity bit inverted too. Bits are sampled at the middle of the bit: card clock E / 2 (integer
division) of each ETU.

### 3.4 Receive

Receiving is enabled while `active` and no TX is running. A falling edge of the synchronised I/O
line starts a character; if the line is high again at 0.5 ETU it was a glitch and is ignored. The
character is complete at its parity sample (9.5 ETU); the receiver is busy until 10 ETU.

- Good parity: the character is stored.
- Parity error, T=0: `perr` pulses, `perr_cnt` + 1, the character is not stored, and the core
  signals the error by pulling I/O low from 10.5 to 12 ETU (the card repeats the character).
- Parity error, T=1: `perr` pulses, `perr_cnt` + 1, the character is stored with its error flag;
  no signal.

A stored character enters an 8-word FIFO as {23'b0, parity_err, data[7:0]}; if the FIFO is full
it is dropped and `ovf_cnt` + 1.

### 3.5 RX ring

When the FIFO is not empty, `enable` = 1, no ring write is running and the ring is not full
(next(`wr_idx`) != `rd_idx`, next = + 1 wrapping at `ring_words`), the FIFO head is written as one
word to `ring_base` + 4 x `wr_idx`. When that write completes: the word leaves the FIFO,
`wr_idx` advances, `rx_cnt` + 1, `rx` pulses (with `err_irq` and `err` <= 1 on an error
response; the ring still advances). While the ring is full, characters wait in the FIFO. With
`enable` = 0 and nothing waiting, `wr_idx` <= 0.

### 3.6 Transmit

`tx_start` is taken when no TX runs, `active`, `tx_len` != 0 and the receiver is idle; `tx_busy`
<= 1, `tx_fail` <= 0, and a read of ceil(`tx_len` / 4) words from `tx_addr` starts. Byte i is
bits 8 x (i mod 4) + 7 : 8 x (i mod 4) of word i / 4. Each byte is sent as soon as its word is
available, characters 12 + `guard` ETU start to start (each ETU E card clocks); the line is
pulled low for the 0 bits and released otherwise.

T=0: at 11.25 ETU (card clock E / 4 of ETU 11) the line is sampled; low means the card signals a
parity error. The same byte is then sent again with its start 14 + `guard` ETU after the previous
start, and `retx_cnt` + 1. After the fourth repetition is also refused the TX fails: `tx_fail`
<= 1, `perr` pulses, the rest is not sent. T=1: no sampling.

At the end (last byte's frame complete, failure, or deactivation, which also sets `tx_fail`) the
words not used are drained from the read job; then `tx_busy` <= 0 and `tx_done` pulses for one
clock (with `err_irq`, and `err` <= 1, if the read saw an error response; the bytes read with an
error are still sent).

### 3.7 Waiting time

With `wt` != 0 a counter of ETU ticks runs while `active`, the receiver is idle and no TX runs.
The ETU tick is free running (every E card clocks), so the waiting time is WT - 1 to WT ETU. It
restarts when RST goes high, at each received character's parity sample (then held at 0 until the
receiver is idle again), and at `tx_done`. When it reaches `wt`, `timeout` pulses once; there is
no further pulse until it restarts.

### 3.8 AXI data mover

The core moves data with `rtl/soc_ss_axi_engine.sv` (instances `u_rx_eng` and `u_tx_eng`, FIFO depth 32
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

`u_rx_eng` drives only AW / W / B (one-word ring writes), `u_tx_eng` only AR / R (the TX buffer);
both use ID `AXI_ID`.

### 3.9 Reset

`rst_n` low: card off (`sc_vcc_en` = 0, `sc_rst_n` = 0, `sc_clk` = 0), I/O released, FIFO empty,
`wr_idx` and all counters 0, every AXI valid / ready output 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd10 | 4'd0 to 4'd15 | value of `m_awid` and `m_arid` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `activate` without a card or with `enable` = 0 | ignored |
| `tx_start` while not active, during a TX or a reception, or with `tx_len` = 0 | ignored |
| T=0 received parity error | signalled 10.5 to 12 ETU, not stored, counted |
| T=1 received parity error | stored with the flag, counted, not signalled |
| card refuses a TX character 5 times | `tx_fail`, `perr`, `tx_done`; the rest is not sent |
| ring full | characters wait in the FIFO; the ninth is dropped (`ovf_cnt`) |
| AXI error response | the access completes; `err` (sticky until `activate`) and `err_irq` |
| card removed or `enable` off | deactivation order RST, CLK, VCC; a TX ends with `tx_fail` |
| glitch on I/O shorter than 0.5 ETU | not a start bit |
| counters at 0xFFFF | they stay there |

## 6. TB check map

Messages are printed by `tb/Smartcard_7816_tb.sv` through `fail()` as `ERROR: <message>`. The card model
checks the activation, sends ATRs and characters, checks the TX character spacing, and can refuse
characters (T=0) a chosen number of times. Messages built from a step name (e.g. "ATR: RST low for
...", "TX: card got ...", "RX: ... characters never reached the ring") have no fixed prefix; they
check §3.2, §3.4 to §3.6 step by step.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "RX without an expected character" | an `rx` pulse only for a character the card sent and that should be stored | §3.4, §3.5 |
| "ring word" | each ring word is {flag, data} of the next expected character | §3.4, §3.5 |
| "powered without a card" | `activate` without a card does nothing | §3.2 |
| "DET / present on insertion" | one `det` and `present` = 1 on insertion | §3.1 |
| "RX_CNT" | `rx_cnt` = 6 after a 6-byte ATR | §3.5 |
| "RETX_CNT" | two refused characters are repeated | §3.6 |
| "no PERR for a failed TX" | a TX refused five times pulses `perr` | §3.6 |
| "PERR_CNT" | received parity errors counted in T=0 and in T=1 | §3.4 |
| "TIMEOUT before WT after a character" | no `timeout` before WT ETU after a character | §3.7 |
| "no TIMEOUT WT after a character" | one `timeout` after WT ETU | §3.7 |
| "OVF_CNT" | with the ring full the FIFO fills and the next character is dropped | §3.4, §3.5 |
| "ERR after an RX write error" | a ring write error gives `err` and `err_irq` with `rx` | §3.5 |
| "TX read error: DEADBEEF bytes not sent" | the bytes of a word read with an error are still sent | §3.6 |
| "ERR after a TX read error" | `err_irq` with `tx_done` | §3.6 |
| "deactivation order RST" | RST falls before CLK stops (internal `clk_run`), CLK before VCC | §3.2 |
| "not deactivated" | `active` = 0 and `sc_clk` = 0 after deactivation | §3.2 |
| "TX not ended by the card removal" | removal during a TX: `tx_fail` = 1, `tx_busy` = 0 | §3.6 |
| "no DET on removal" | one `det` on removal | §3.1 |
| "not idle in reset" | in reset: no power, RST low, I/O released, no AXI request | §3.9 |

The TB also prints `LAT` lines (performance report, not a check).

### Coverage-closure assertions

From `tb/cov/Smartcard_7816_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_reset_idle | while `!rst_n` (reset): `!sc_vcc_en && !sc_rst_n && !sc_clk && !sc_io_oe_low && !tx_busy && !m_awvalid && !m_arvalid && wr_idx == 0 && rx_cnt == 0 && perr_cnt == 0 && ovf_cnt == 0 && !err` | §3 |
| a_power_up | whenever `!powered && activate && present && enable`, on the next clock: `powered && !sc_rst_n` | §3 |
| a_status | always holds: `active == sc_rst_n && powered == sc_vcc_en && present == det_s[1] && det == (present != pres_q)` | §3 |
| a_rst_needs_power | always holds: `!sc_rst_n \|\| sc_vcc_en` | §3 |
| a_clk_needs_power | always holds: `!sc_clk \|\| sc_vcc_en` | §3 |
| a_rst_low_time | whenever `sc_rst_n && !$past(sc_rst_n)`: `nce == rst_n_clks && $past(rstl)` | §3 |
| a_deactivate | whenever `active && go_off`, on the next clock: `!sc_rst_n` | §3 |
| a_vcc_off_last | whenever `!sc_vcc_en && $past(sc_vcc_en)`: `!sc_rst_n && !sc_clk && quiet >= 13` | §3 |
| a_clk_half_period | whenever `sc_clk != sck_q && seen_edge && !div_chg && sc_rst_n && $past(sc_rst_n)`: `hc == 16'(cd_q)` | §3 |
| a_tx_line_idle | whenever `sc_io_oe_low`: `(tx_busy && active) \|\| r_sig` | §3 |
| a_tx_guard_released | whenever `d_run && d_k >= 10`: `!sc_io_oe_low` | §3 |
| a_tx_char | whenever `d_end`: `d_par_ok && tq.size() != 0 && d_byte == tq[0]` | §3 |
| a_tx_retx_cnt | always holds: `retx_cnt == m_retx` | §3 |
| a_tx_done | whenever `tx_done`: `tx_fail == t_fail_m && (t_fail_m \|\| t_left == 0) && !d_on` | §3 |
| a_tx_read_addr | whenever `m_arvalid && m_arready`: `m_araddr[31:2] >= tx_addr[31:2] && m_araddr[31:2] - tx_addr[31:2] + 32'(m_arlen) + 1 <= (32'(tx_len) + 3) / 4` | §3 |
| a_rx_signal | whenever `!tx_busy && active`: `sc_io_oe_low == r_sig` | §3 |
| a_rx_perr | always holds: `perr == ((r_done && r_bad) \|\| t_failp_m)` | §3 |
| a_ring_word | whenever `m_wvalid && m_wready`: `rq.size() != 0 && m_wdata == rq[0]` | §3 |
| a_ring_addr | whenever `m_awvalid`: `m_awaddr == ring_base + {14'd0, wr_idx, 2'b00} && m_wr_next != rd_idx` | §3 |
| a_wr_idx | whenever `rx`, on the next clock: `wr_idx == $past(m_wr_next) \|\| !enable` | §3 |
| a_rx_counters | always holds: `rx_cnt == m_rxc && perr_cnt == m_perr && ovf_cnt == m_ovf` | §3 |
| a_timeout | always holds: `timeout == w_fire` | §3 |
| a_err_irq | always holds: `err_irq == ((rx && b_err_now) \|\| (tx_done && t_err_m))` | §3 |
| a_err_sticky | whenever `err_irq`: `##1 err` | §3 |

### Further TB checks

| Check (TB message) | What it requires | Spec |
|---|---|---|
| "not in the RST low time" | fails when `sc_rst_n \|\| !sc_vcc_en` (`tb/Smartcard_7816_tb.sv` line 344) | §3 |
| "deactivation during the RST low time" | fails when `powered \|\| active` (`tb/Smartcard_7816_tb.sv` line 347) | §3 |
| "glitch taken as a character" | fails when `rx_cnt != r0 \|\| perr_cnt != p0 \|\| dut.re_busy` (`tb/Smartcard_7816_tb.sv` line 359) | §3 |
| "no TIMEOUT with WT 65535" | fails when `n_to == t0` (`tb/Smartcard_7816_tb.sv` line 373) | §3 |
| "TX not waiting for its word" | fails when `!tx_busy` (`tb/Smartcard_7816_tb.sv` line 407) | §3 |
| "TX not ended by a deactivation while loading" | fails when `tx_busy \|\| !tx_fail` (`tb/Smartcard_7816_tb.sv` line 416) | §3 |
| "RING_WORDS 0" | see `tb/Smartcard_7816_tb.sv` (`tb/Smartcard_7816_tb.sv` line 421) | §3 |
| "the 65535-byte TX sent nothing" | fails when `c_rxq.size() == 0` (`tb/Smartcard_7816_tb.sv` line 437) | §3 |
| "long TX not ended by the deactivation" | fails when `!tx_fail` (`tb/Smartcard_7816_tb.sv` line 440) | §3 |
| "ERR_IRQ after DECERR" | fails when `n_err_irq != e0 + 2` (`tb/Smartcard_7816_tb.sv` line 459) | §3 |
