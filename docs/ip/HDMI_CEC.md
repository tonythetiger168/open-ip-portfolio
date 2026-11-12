# HDMI CEC controller: bit timing, arbitration and ACK, messages in memory over AXI4

Protocol IP `HDMI_CEC`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `HDMI_CEC_top` (`rtl/HDMI_CEC_top.sv`) |
| Register interface | APB4 slave `HDMI_CEC_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C060100 (code 0x7C06, version 1.0) |
| Registers | 15 words, 0x000 to 0x038 |
| Interrupts | 4 sources into one level-high `irq` |
| Protocol pins | 33 pass-through |

## Overview

HDMI_CEC: HDMI Consumer Electronics Control controller of the TV SoC (initiator and follower) with message DMA (AXI4 manager, APB4 registers) The CEC line is open drain: cec_in is the bus level, cec_oe_low = 1 pulls it low. One tick is TICK_DIV + 1 clks; the nominal 0.05 ms tick gives the CEC timings in ticks: start bit 74 low / 90 period, data bit '0' 30 low, '1' 12 low, 48 period, sample point 21. Receiver (follower): accepts a start bit with 70..78 low and 86..94 period, data bits with 8..34 low ('1' when shorter than 21) and 41..55 period; anything else ends the message with RX_ERR (counted). A message is blocks of 10 bits: 8 data bits MSB first, EOM, ACK. When the header's destination (bits 3:0) is LA (not 15), the IP acknowledges every block by pulling the ACK bit low for 30 ticks. Messages to LA, broadcasts (15), or all messages with PROMISC, of 1..16 bytes, are written to the RX ring.

- RX ring: RX_SLOTS slots of 32 bytes from RX_BASE; word 0 = {16'b0, 5'b0,
broadcast, acked, 1'b0, 3'b0, len[4:0]}, words 1..4 the bytes (byte i in
word 1 + i / 4, bits 8 * (i % 4) + 7 : 8 * (i % 4)), words 5..7 zero.
RX_WR is the next slot, software consumes and writes RX_RD; a message
that finds the ring full or the previous message not yet written is
dropped (RX_OVF_CNT). RX pulses when a message is in memory.
Transmitter (initiator): TX_START reads 5 words from TX_ADDR (word 0 bits
4:0 = length 1..16, words 1..4 the bytes as above), waits until the bus
has been high for SFT ticks (and no message is being received), then
sends the start bit and the blocks (EOM on the last, ACK sent as '1').
- At the sample point of every '1' bit it sends, the bus must be high:
otherwise, in the initiator address (first 4 bits), arbitration is lost;
elsewhere it is a bit error. Both stop the message at once.
- ACK: a directed message needs ACK low on every block, a broadcast needs
it high; otherwise the message stops with NACK. No retransmission (the
driver retries). TX_DONE pulses at the end with TX_STATUS {err, arb_lost,
nack, ok}. Messages the IP sends itself are not received.
- ERR pulses with RX / TX_DONE when the AXI access saw an error response.

Features:

- Open-drain line: cec_in samples it, cec_oe_low pulls it low. Tick = TICK_DIV + 1 clocks, nominally 0.05 ms: start bit 3.7 ms low / 4.5 ms, bit 0 1.5 ms low, bit 1 0.6 ms low, 2.4 ms period, sample at 1.05 ms.
- Receive: messages to logical address LA (or all with PROMISC) and broadcasts; directed blocks are ACKed. Each message takes one 32-byte RX slot: word 0 {flags (bcast, acked), len}, words 1..4 the bytes.
- Transmit: CMD.tx_start fetches 5 words at TX_ADDR (word 0 = length, words 1..4 bytes), waits SFT bit periods of free line, sends with arbitration (lost in the first 4 bits: TX_STATUS.arb_lost) and checks ACK (TX_STATUS.nack).
- RX ring of RX_SLOTS slots at RX_BASE (RX_WR / RX_RD).

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time.
cec_in / cec_oe_low are the line pins (open drain: the pad pulls low when cec_oe_low is 1).
The core testbench prints one `LAT <master> dram R|W <cycles>` line per AXI burst (tb/tv_lat_mon.svh), the regression suite's latency format.

## Files

| File | Content |
|---|---|
| `rtl/HDMI_CEC_top.sv` | protocol core |
| `rtl/HDMI_CEC_apb.sv` | APB4 register wrapper (generated) |
| `tb/HDMI_CEC_tb.sv` | core testbench |
| `tb/HDMI_CEC_apb_tb.sv`, `tb/apb/HDMI_CEC_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/HDMI_CEC_sva.sv`, `tb/cov/HDMI_CEC_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/HDMI_CEC.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`HDMI_CEC_apb` has the core's parameters and passes them to `HDMI_CEC_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd7` |

## Wrapper pins

Pins of `HDMI_CEC_apb`. Widths of the pass-through pins are at the default parameters.

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
| `cec_in` | input | 1 | protocol pin, core port `cec_in` |
| `cec_oe_low` | output | 1 | protocol pin, core port `cec_oe_low` |
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
| `cec_in` | input | 1 | pin (pass-through) |
| `cec_oe_low` | output | 1 | pin (pass-through) |
| `enable` | input | 1 | CTRL[0:0] |
| `tick_div` | input | 16 | TIMING[15:0] |
| `la` | input | 4 | CTRL[4:1] |
| `promisc` | input | 1 | CTRL[5:5] |
| `sft` | input | 10 | TIMING[25:16] |
| `rx_base` | input | 32 | RX_BASE[31:0] |
| `rx_slots` | input | 8 | RX_RING[7:0] |
| `rx_rd` | input | 8 | RX_RING[15:8] |
| `tx_addr` | input | 32 | TX_ADDR[31:0] |
| `tx_start` | input | 1 | CMD |
| `rx_wr` | output | 8 | RX_WR[7:0] |
| `rx_cnt` | output | 16 | RX_CNT[15:0] |
| `rx_err_cnt` | output | 16 | RX_CNT[31:16] |
| `rx_ovf_cnt` | output | 16 | RX_OVF[15:0] |
| `tx_status` | output | 4 | TX[3:0] |
| `tx_busy` | output | 1 | TX[4:4] |
| `rx` | output | 1 | IRQ_STATUS.RX |
| `rx_err` | output | 1 | IRQ_STATUS.RX_ERR |
| `tx_done` | output | 1 | IRQ_STATUS.TX_DONE |
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

`HDMI_CEC_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `cec_in`, `cec_oe_low`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C060100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Enable and address |
| 0x018 | TIMING | RW | 0x00000000 | Timing |
| 0x01C | RX_BASE | RW | 0x00000000 | RX ring address |
| 0x020 | RX_RING | RW | 0x00000000 | RX ring control |
| 0x024 | TX_ADDR | RW | 0x00000000 | TX message address |
| 0x028 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x02C | RX_WR | RO | core | RX write index |
| 0x030 | TX | RO | core | Transmit state |
| 0x034 | RX_CNT | RO | core | RX counters |
| 0x038 | RX_OVF | RO | core | Lost messages |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x03C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C06 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `enable` | RW | 0x0 | controller on |
| CTRL | 4:1 | `la` | RW | 0x0 | logical address |
| CTRL | 5 | `promisc` | RW | 0x0 | receive every message |
| TIMING | 15:0 | `tick_div` | RW | 0x0 | tick = TICK_DIV + 1 clocks |
| TIMING | 25:16 | `sft` | RW | 0x0 | signal free time in ticks |
| RX_BASE | 31:0 | `rx_base` | RW | 0x0 | slot 0, 32-byte aligned |
| RX_RING | 7:0 | `rx_slots` | RW | 0x0 | slots |
| RX_RING | 15:8 | `rx_rd` | RW | 0x0 | next slot software reads |
| TX_ADDR | 31:0 | `tx_addr` | RW | 0x0 | 5 words |
| CMD | 0 | `tx_start` | WO (pulse) | 0x0 | send the message at TX_ADDR; ignored while tx_busy |
| RX_WR | 7:0 | `rx_wr` | RO | core | next slot the core writes |
| TX | 3:0 | `tx_status` | RO | core | {err, arb_lost, nack, ok} of the last message |
| TX | 4 | `tx_busy` | RO | core | a message is being sent |
| RX_CNT | 15:0 | `rx_cnt` | RO | core | messages stored |
| RX_CNT | 31:16 | `rx_err_cnt` | RO | core | bit timing errors |
| RX_OVF | 15:0 | `rx_ovf_cnt` | RO | core | messages lost to a full ring |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RX | a message was stored |
| 1 | RX_ERR | a bit timing error |
| 2 | TX_DONE | a transmit ended (see TX) |
| 3 | ERR | a job ended that saw an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C060100.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), TIMING (0x018), RX_BASE (0x01C), RX_RING (0x020), TX_ADDR (0x024). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
5. To issue a command, write 1 to `tx_start` (CMD bit 0) at 0x028; the core sees a one-clock pulse, and the register reads 0.
6. Read RX_WR (0x02C) for the core's live `rx_wr`; it needs no clearing.
7. Read TX (0x030) for the core's live `tx_status`, `tx_busy`; it needs no clearing.
8. Read RX_CNT (0x034) for the core's live `rx_cnt`, `rx_err_cnt`; it needs no clearing.
9. Read RX_OVF (0x038) for the core's live `rx_ovf_cnt`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write TIMING (TICK_DIV = clock x 50 us - 1, SFT), RX_BASE, RX_RING, CTRL with enable and LA.
2. Receive: on RX read slots RX_RD .. RX_WR - 1 and write RX_RD.
3. Transmit: write the message to memory, TX_ADDR, CMD.tx_start; on TX_DONE read TX.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.HDMI_CEC sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.HDMI_CEC syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/HDMI_CEC_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.HDMI_CEC apb` | `TEST PASSED: HDMI_CEC_apb`, then Yosys without `ERROR` | console, `work/HDMI_CEC_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh HDMI_CEC`<br>`bash scripts/cov/run_cov.sh HDMI_CEC_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/HDMI_CEC/score.json`, `work/cov/HDMI_CEC_apb/score.json` |

Expected end of a step 4 run:

```
===== HDMI_CEC =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/HDMI_CEC_tb.sv`): drives `HDMI_CEC_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/HDMI_CEC_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/HDMI_CEC_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/HDMI_CEC_sva.sv`, `tb/cov/HDMI_CEC_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/HDMI_CEC_top.sv` | not run | | | | | |
| wrapper `rtl/HDMI_CEC_apb.sv` | not run | | | | | |
