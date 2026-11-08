# Gigabit Ethernet MAC with TX and RX descriptor-ring DMA over AXI4 (store-and-forward TX, 4 KB RX FIFO)

Protocol IP `GbE_DMA`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `GbE_DMA_top` (`rtl/GbE_DMA_top.sv`) |
| Register interface | APB4 slave `GbE_DMA_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C410100 (code 0x5C41, version 1.0) |
| Registers | 19 words, 0x000 to 0x048 |
| Interrupts | 4 sources into one level-high `irq` |
| Protocol pins | 37 pass-through |

## Overview

GbE_DMA: Ethernet MAC with descriptor-ring DMA (AXI4 manager, APB4 regs) The unchanged Ethernet_top MAC (GMII-style byte interface, address filter, PAUSE) with a TX and an RX descriptor ring in memory, moved by one soc_ss_axi_engine that a scheduler shares between the two directions.

- Descriptor (8 bytes, word aligned): word 0 buffer address (word
aligned), word 1 length. Ring entry i is at BASE + 8 * i, NUM entries.
Software owns TAIL (the next entry it will fill), the hardware HEAD (the
next entry it will use); entries HEAD .. TAIL - 1 belong to the hardware.
- TX: word 1 = frame length in bytes (DA .. payload, 1..TXF_BYTES). The
frame is fetched whole into the TX FIFO, then sent (store and forward,
so the MAC never underruns). After the MAC's tx_done the hardware writes
word 1 = {1 done, 1'b0, underrun, bad_len, 12'd0, len} and advances
TX_HEAD. A length of 0 or above TXF_BYTES is not sent (bad_len).
- RX: word 1 = buffer size in bytes. Received frames (without FCS) wait in
the RX FIFO (RXF_BYTES, up to 4 frames). Each one takes the descriptor
at RX_HEAD: its first min(len, size) bytes are written to the buffer,
(rounded up to a word, so up to 3 bytes past SIZE when it is not a
multiple of 4), then word 1 = {1 done, trunc, 10'd0, stat[3:0], len} with the MAC's
rx_stat {pause, phy_err, len_err, crc_err} and trunc when the frame was
longer than the buffer. A frame that does not fit in the RX FIFO, or
arrives with 4 frames waiting or with RX_EN off, is dropped (RX_DROP).
With no descriptor free the frames wait in the FIFO.
- Interrupts: TX (a TX descriptor completed), RX (an RX descriptor
completed), DROP (a frame dropped), ERR (an AXI error response; ERR
stays set in STATUS until CMD.clr_err).
- AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.

Features:

- The unchanged Ethernet_top MAC (GMII-style byte interface, address filter, PAUSE).
- Descriptors of 8 bytes: word 0 buffer address, word 1 length (TX) or buffer size (RX); entry i at BASE + 8 i.
- Software owns TAIL, the hardware HEAD; entries HEAD .. TAIL - 1 belong to the hardware.
- TX write-back: word 1 = {1 done, 0, underrun, bad_len, 12'd0, len}; frames of 1..2048 bytes, sent store-and-forward.
- RX write-back: word 1 = {1 done, trunc, 10'd0, rx_stat {pause, phy_err, len_err, crc_err}, len}; frames wait in a 4 KB FIFO (4 frames) when no descriptor is free.
- A frame that does not fit in the RX FIFO, arrives with 4 frames waiting, or arrives with RX_EN off is dropped (RX_DROP).

gtxd / gtx_en / gtx_er and grxd / grx_dv / grx_er are the GMII pins; they pass through unchanged.
m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time. A read burst is issued only when its data has room, a write burst only when all its data is ready.

## Files

| File | Content |
|---|---|
| `rtl/GbE_DMA_top.sv` | protocol core |
| `rtl/GbE_DMA_apb.sv` | APB4 register wrapper (generated) |
| `tb/GbE_DMA_tb.sv` | core testbench |
| `tb/GbE_DMA_apb_tb.sv`, `tb/apb/GbE_DMA_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/GbE_DMA_sva.sv`, `tb/cov/GbE_DMA_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/GbE_DMA.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`GbE_DMA_apb` has the core's parameters and passes them to `GbE_DMA_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd10` |
| `TXF_BYTES` | int | `2048` |
| `RXF_BYTES` | int | `4096` |

## Wrapper pins

Pins of `GbE_DMA_apb`. Widths of the pass-through pins are at the default parameters.

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
| `gtxd` | output | 8 | protocol pin, core port `gtxd` |
| `gtx_en` | output | 1 | protocol pin, core port `gtx_en` |
| `gtx_er` | output | 1 | protocol pin, core port `gtx_er` |
| `grxd` | input | 8 | protocol pin, core port `grxd` |
| `grx_dv` | input | 1 | protocol pin, core port `grx_dv` |
| `grx_er` | input | 1 | protocol pin, core port `grx_er` |
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
| `cfg_div` | input | 5 | CTRL[8:4] |
| `cfg_mac` | input | 48 | MAC0[31:0], MAC1[15:0] |
| `cfg_promisc` | input | 1 | CTRL[2:2] |
| `cfg_pause_en` | input | 1 | CTRL[3:3] |
| `gtxd` | output | 8 | pin (pass-through) |
| `gtx_en` | output | 1 | pin (pass-through) |
| `gtx_er` | output | 1 | pin (pass-through) |
| `grxd` | input | 8 | pin (pass-through) |
| `grx_dv` | input | 1 | pin (pass-through) |
| `grx_er` | input | 1 | pin (pass-through) |
| `tx_en` | input | 1 | CTRL[0:0] |
| `rx_en` | input | 1 | CTRL[1:1] |
| `tx_base` | input | 32 | TX_BASE[31:0] |
| `tx_num` | input | 16 | TX_NUM[15:0] |
| `tx_tail` | input | 16 | TX_TAIL[15:0] |
| `tx_head` | output | 16 | HEAD[15:0] |
| `rx_base` | input | 32 | RX_BASE[31:0] |
| `rx_num` | input | 16 | RX_NUM[15:0] |
| `rx_tail` | input | 16 | RX_TAIL[15:0] |
| `rx_head` | output | 16 | HEAD[31:16] |
| `clr_err` | input | 1 | CMD |
| `err` | output | 1 | STATUS[0:0] |
| `tx_paused` | output | 1 | STATUS[1:1] |
| `tx_frames` | output | 16 | FRAMES[15:0] |
| `rx_frames` | output | 16 | FRAMES[31:16] |
| `rx_drop` | output | 16 | RX_DROP[15:0] |
| `tx_irq` | output | 1 | IRQ_STATUS.TX |
| `rx_irq` | output | 1 | IRQ_STATUS.RX |
| `drop_irq` | output | 1 | IRQ_STATUS.DROP |
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

## Programming sequence

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

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.GbE_DMA sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.GbE_DMA syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/GbE_DMA_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.GbE_DMA apb` | `TEST PASSED: GbE_DMA_apb`, then Yosys without `ERROR` | console, `work/GbE_DMA_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh GbE_DMA`<br>`bash scripts/cov/run_cov.sh GbE_DMA_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/GbE_DMA/score.json`, `work/cov/GbE_DMA_apb/score.json` |

Expected end of a step 4 run:

```
===== GbE_DMA =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/GbE_DMA_tb.sv`): drives `GbE_DMA_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/GbE_DMA_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/GbE_DMA_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/GbE_DMA_sva.sv`, `tb/cov/GbE_DMA_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/GbE_DMA_top.sv` | not run | | | | | |
| wrapper `rtl/GbE_DMA_apb.sv` | not run | | | | | |
