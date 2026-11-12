# ISO/IEC 7816-3 smartcard interface (conditional-access card reader): T=0 / T=1 characters, RX ring and TX buffer over AXI4

Protocol IP `Smartcard_7816`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Smartcard_7816_top` (`rtl/Smartcard_7816_top.sv`) |
| Register interface | APB4 slave `Smartcard_7816_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C0A0100 (code 0x7C0A, version 1.0) |
| Registers | 18 words, 0x000 to 0x044 |
| Interrupts | 6 sources into one level-high `irq` |
| Protocol pins | 37 pass-through |

## Overview

Smartcard_7816: ISO/IEC 7816-3 smartcard interface of the STB SoC (conditional-access card reader) with an RX ring and TX buffer DMA (AXI4 manager, APB4 registers) Card pins: sc_vcc_en (card power), sc_rst_n (RST), sc_clk (CLK), the open-drain I/O line (sc_io_in is the line level, sc_io_oe_low = 1 pulls it low) and sc_det (card present, high). sc_io_in and sc_det are synchronised with two flops.

- Clock: CLK toggles every CLK_DIV + 1 clocks while the card is powered
(card clock = clk / (2 * (CLK_DIV + 1))). One ETU is ETU card clocks (F / D,
372 after reset of the card; 0 counts as 1). Bits are sampled in the
middle of the ETU.
- Activation (CMD.activate, card present, ENABLE): VCC on, CLK running,
RST low for RST_CLKS card clocks, then RST high: STATUS.active. The card
answers with its ATR, received like any other character.
- Deactivation (CMD.deactivate, card removed, or ENABLE off): RST low, CLK
stopped low two card clocks later, VCC off 16 clocks after that. A TX in
progress ends (STATUS.tx_fail, TX_DONE).
- Character: start bit (low), 8 data bits, even parity, then the guard
time. Direct convention (CTRL.inverse 0): LSB first, high = 1. Inverse
convention: MSB first, low = 1 (the parity bit too).
- RX (while no TX is running): a character is complete at its parity
sample. T=0 (CTRL.t1 0): a parity error is signalled to the card by
pulling I/O low from 10.5 to 12 ETU, the character is counted
(PERR_CNT) and not stored (the card repeats it). T=1: no error signal;
the character is stored with its parity error flag. Stored characters
go through an 8-word FIFO to the RX ring, one word each,
{23'b0, parity_err, data[7:0]}, at RING_BASE + 4 * WR_IDX; RING_WORDS
words (at least 2); software consumes them and writes RD_IDX. While the
ring is full (WR_IDX + 1 = RD_IDX mod RING_WORDS) characters wait in the
FIFO; one that finds the FIFO full is dropped (OVF_CNT).
- TX (CMD.tx_start, active, TX_LEN > 0): TX_LEN bytes are read from
TX_ADDR (byte i in word i / 4, bits 8 * (i % 4) + 7 : 8 * (i % 4)) and
sent start to start every 12 + GUARD ETU. T=0: the I/O line is sampled at
11.25 ETU; low means the card signalled a parity error and the character
is sent again 2 ETU later than usual (RETX_CNT), up to 4 times, then the TX stops with
STATUS.tx_fail (PERR interrupt). TX_DONE pulses at the end.
- Waiting time: with WT != 0, WT ETUs after RST goes high, after the last
character received or after a TX without a new start bit raise TIMEOUT
(once until the next character).
- Interrupts: RX (a character is in memory), TX_DONE, PERR (an RX parity
error, or a TX that failed after 4 repetitions), DET (sc_det changed), TIMEOUT, ERR (with RX or
TX_DONE when the AXI access saw an error response).

Features:

- Card pins: sc_vcc_en, sc_rst_n, sc_clk (clk / (2 * (CLK_DIV + 1))), open-drain I/O (sc_io_in, sc_io_oe_low), sc_det (card present).
- Activation (CMD.activate): VCC on, CLK running, RST low for RST_CLKS card clocks, then RST high (STATUS.active); deactivation (CMD.deactivate, card removal or ENABLE off): RST low, CLK stopped, VCC off.
- Characters: start bit, 8 data bits, even parity; one ETU is ETU card clocks (F / D); direct or inverse convention (CTRL.inverse).
- T=0: parity errors are signalled to the card (I/O low 10.5..12 ETU) and the character is not stored; a character the card rejects is sent again 2 ETU later, up to 4 times, then the TX fails (STATUS.tx_fail, PERR). T=1: no signalling, the parity flag is stored.
- RX: every character goes as one word {23'b0, parity_err, data} through an 8-word FIFO to the ring at RING_BASE (RING_WORDS words, WR_IDX / RD_IDX); a full FIFO drops characters (OVF_CNT).
- TX: CMD.tx_start sends TX_LEN bytes read from TX_ADDR (byte i in word i / 4, little-endian), start to start every 12 + GUARD ETU.
- Waiting time: WT ETUs without a start bit after RST, the last character or a TX raise TIMEOUT.

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time.
RX ring writes use the write channel and TX buffer reads the read channel (two engines, one ID).
sc_vcc_en, sc_rst_n, sc_clk, sc_io_oe_low (out) and sc_io_in, sc_det (in) are the card pins; the I/O pad is open drain with a pull-up.
The core testbench prints one `LAT <master> dram R|W <cycles>` line per AXI burst (tb/tv_lat_mon.svh), the regression suite's latency format.

## Files

| File | Content |
|---|---|
| `rtl/Smartcard_7816_top.sv` | protocol core |
| `rtl/Smartcard_7816_apb.sv` | APB4 register wrapper (generated) |
| `tb/Smartcard_7816_tb.sv` | core testbench |
| `tb/Smartcard_7816_apb_tb.sv`, `tb/apb/Smartcard_7816_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Smartcard_7816_sva.sv`, `tb/cov/Smartcard_7816_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Smartcard_7816.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`Smartcard_7816_apb` has the core's parameters and passes them to `Smartcard_7816_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd10` |

## Wrapper pins

Pins of `Smartcard_7816_apb`. Widths of the pass-through pins are at the default parameters.

| Pin | Dir | Width | Description |
|---|---|---|---|
| `PCLK` | input | 1 | APB clock; also the core clock |
| `PRESETN` | input | 1 | APB reset, active low; also the core reset |
| `PSEL` | input | 1 | slave select |
| `PENABLE` | input | 1 | access phase |
| `PWRITE` | input | 1 | 1 = write, 0 = read |
| `PADDR` | input | 12 | byte address; bits [1:0] must be 0 |
| `PWDATA` | input | 32 | write data |
| `PSTRB` | input | 4 | write byte strobes |
| `PRDATA` | output | 32 | read data |
| `PREADY` | output | 1 | always high in the access phase (no wait states) |
| `PSLVERR` | output | 1 | error: unmapped or misaligned address |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `sc_vcc_en` | output | 1 | protocol pin, core port `sc_vcc_en` |
| `sc_rst_n` | output | 1 | protocol pin, core port `sc_rst_n` |
| `sc_clk` | output | 1 | protocol pin, core port `sc_clk` |
| `sc_io_in` | input | 1 | protocol pin, core port `sc_io_in` |
| `sc_io_oe_low` | output | 1 | protocol pin, core port `sc_io_oe_low` |
| `sc_det` | input | 1 | protocol pin, core port `sc_det` |
| `m_awid` | output | 4 | protocol pin, core port `m_awid` |
| `m_awaddr` | output | 32 | protocol pin, core port `m_awaddr` |
| `m_awlen` | output | 8 | protocol pin, core port `m_awlen` |
| `m_awsize` | output | 3 | protocol pin, core port `m_awsize` |
| `m_awburst` | output | 2 | protocol pin, core port `m_awburst` |
| `m_awprot` | output | 3 | protocol pin, core port `m_awprot` |
| `m_awvalid` | output | 1 | protocol pin, core port `m_awvalid` |
| `m_awready` | input | 1 | protocol pin, core port `m_awready` |
| `m_wdata` | output | 32 | protocol pin, core port `m_wdata` |
| `m_wstrb` | output | 4 | protocol pin, core port `m_wstrb` |
| `m_wlast` | output | 1 | protocol pin, core port `m_wlast` |
| `m_wvalid` | output | 1 | protocol pin, core port `m_wvalid` |
| `m_wready` | input | 1 | protocol pin, core port `m_wready` |
| `m_bid` | input | 4 | protocol pin, core port `m_bid` |
| `m_bresp` | input | 2 | protocol pin, core port `m_bresp` |
| `m_bvalid` | input | 1 | protocol pin, core port `m_bvalid` |
| `m_bready` | output | 1 | protocol pin, core port `m_bready` |
| `m_arid` | output | 4 | protocol pin, core port `m_arid` |
| `m_araddr` | output | 32 | protocol pin, core port `m_araddr` |
| `m_arlen` | output | 8 | protocol pin, core port `m_arlen` |
| `m_arsize` | output | 3 | protocol pin, core port `m_arsize` |
| `m_arburst` | output | 2 | protocol pin, core port `m_arburst` |
| `m_arprot` | output | 3 | protocol pin, core port `m_arprot` |
| `m_arvalid` | output | 1 | protocol pin, core port `m_arvalid` |
| `m_arready` | input | 1 | protocol pin, core port `m_arready` |
| `m_rid` | input | 4 | protocol pin, core port `m_rid` |
| `m_rdata` | input | 32 | protocol pin, core port `m_rdata` |
| `m_rresp` | input | 2 | protocol pin, core port `m_rresp` |
| `m_rlast` | input | 1 | protocol pin, core port `m_rlast` |
| `m_rvalid` | input | 1 | protocol pin, core port `m_rvalid` |
| `m_rready` | output | 1 | protocol pin, core port `m_rready` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sc_vcc_en` | output | 1 | pin (pass-through) |
| `sc_rst_n` | output | 1 | pin (pass-through) |
| `sc_clk` | output | 1 | pin (pass-through) |
| `sc_io_in` | input | 1 | pin (pass-through) |
| `sc_io_oe_low` | output | 1 | pin (pass-through) |
| `sc_det` | input | 1 | pin (pass-through) |
| `enable` | input | 1 | CTRL[0:0] |
| `inverse` | input | 1 | CTRL[1:1] |
| `t1` | input | 1 | CTRL[2:2] |
| `clk_div` | input | 8 | CTRL[10:3] |
| `etu` | input | 16 | TIMING[15:0] |
| `guard` | input | 8 | TIMING[23:16] |
| `wt` | input | 16 | WAITS[15:0] |
| `rst_clks` | input | 16 | WAITS[31:16] |
| `ring_base` | input | 32 | RING_BASE[31:0] |
| `ring_words` | input | 16 | RING_WORDS[15:0] |
| `rd_idx` | input | 16 | RD_IDX[15:0] |
| `tx_addr` | input | 32 | TX_ADDR[31:0] |
| `tx_len` | input | 16 | TX_LEN[15:0] |
| `activate` | input | 1 | CMD[0:0] |
| `deactivate` | input | 1 | CMD[1:1] |
| `tx_start` | input | 1 | CMD[2:2] |
| `active` | output | 1 | STATUS[0:0] |
| `powered` | output | 1 | STATUS[1:1] |
| `tx_busy` | output | 1 | STATUS[2:2] |
| `tx_fail` | output | 1 | STATUS[3:3] |
| `err` | output | 1 | STATUS[4:4] |
| `present` | output | 1 | STATUS[5:5] |
| `wr_idx` | output | 16 | WR_IDX[15:0] |
| `rx_cnt` | output | 16 | RX_COUNTS[15:0] |
| `perr_cnt` | output | 16 | RX_COUNTS[31:16] |
| `retx_cnt` | output | 16 | TX_COUNTS[15:0] |
| `ovf_cnt` | output | 16 | TX_COUNTS[31:16] |
| `rx` | output | 1 | IRQ_STATUS.RX |
| `tx_done` | output | 1 | IRQ_STATUS.TX_DONE |
| `perr` | output | 1 | IRQ_STATUS.PERR |
| `det` | output | 1 | IRQ_STATUS.DET |
| `timeout` | output | 1 | IRQ_STATUS.TIMEOUT |
| `err_irq` | output | 1 | IRQ_STATUS.ERR |
| `m_awid` | output | 4 | pin (pass-through) |
| `m_awaddr` | output | 32 | pin (pass-through) |
| `m_awlen` | output | 8 | pin (pass-through) |
| `m_awsize` | output | 3 | pin (pass-through) |
| `m_awburst` | output | 2 | pin (pass-through) |
| `m_awprot` | output | 3 | pin (pass-through) |
| `m_awvalid` | output | 1 | pin (pass-through) |
| `m_awready` | input | 1 | pin (pass-through) |
| `m_wdata` | output | 32 | pin (pass-through) |
| `m_wstrb` | output | 4 | pin (pass-through) |
| `m_wlast` | output | 1 | pin (pass-through) |
| `m_wvalid` | output | 1 | pin (pass-through) |
| `m_wready` | input | 1 | pin (pass-through) |
| `m_bid` | input | 4 | pin (pass-through) |
| `m_bresp` | input | 2 | pin (pass-through) |
| `m_bvalid` | input | 1 | pin (pass-through) |
| `m_bready` | output | 1 | pin (pass-through) |
| `m_arid` | output | 4 | pin (pass-through) |
| `m_araddr` | output | 32 | pin (pass-through) |
| `m_arlen` | output | 8 | pin (pass-through) |
| `m_arsize` | output | 3 | pin (pass-through) |
| `m_arburst` | output | 2 | pin (pass-through) |
| `m_arprot` | output | 3 | pin (pass-through) |
| `m_arvalid` | output | 1 | pin (pass-through) |
| `m_arready` | input | 1 | pin (pass-through) |
| `m_rid` | input | 4 | pin (pass-through) |
| `m_rdata` | input | 32 | pin (pass-through) |
| `m_rresp` | input | 2 | pin (pass-through) |
| `m_rlast` | input | 1 | pin (pass-through) |
| `m_rvalid` | input | 1 | pin (pass-through) |
| `m_rready` | output | 1 | pin (pass-through) |

## APB wrapper

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

## Programming sequence

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

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Smartcard_7816 sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Smartcard_7816 syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Smartcard_7816_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Smartcard_7816 apb` | `TEST PASSED: Smartcard_7816_apb`, then Yosys without `ERROR` | console, `work/Smartcard_7816_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Smartcard_7816`<br>`bash scripts/cov/run_cov.sh Smartcard_7816_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Smartcard_7816/score.json`, `work/cov/Smartcard_7816_apb/score.json` |

Expected end of a step 4 run:

```
===== Smartcard_7816 =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Smartcard_7816_tb.sv`): drives `Smartcard_7816_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Smartcard_7816_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Smartcard_7816_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Smartcard_7816_sva.sv`, `tb/cov/Smartcard_7816_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Smartcard_7816_top.sv` | not run | | | | | |
| wrapper `rtl/Smartcard_7816_apb.sv` | not run | | | | | |
