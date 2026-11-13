# MPEG-2 transport stream demultiplexer: 4 PID filters, packets to a ring in memory over AXI4

Protocol IP `TS_Demux`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `TS_Demux_top` (`rtl/TS_Demux_top.sv`) |
| Register interface | APB4 slave `TS_Demux_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C020100 (code 0x7C02, version 1.0) |
| Registers | 15 words, 0x000 to 0x038 |
| Interrupts | 4 sources into one level-high `irq` |
| Protocol pins | 35 pass-through |

## Overview

TS_Demux: MPEG-2 transport stream PID filter and packet DMA of the TV SoC (AXI4 manager, APB4 registers) Input: a parallel TSI port, one byte per clk with ts_valid; ts_sync marks the first byte of each 188-byte packet; ts_err (TEI from the demodulator) marks a corrupted packet.

- A packet starts at ts_valid && ts_sync. It is dropped (DROP_CNT, DROP
interrupt) when the sync byte is not 8'h47, ts_err is seen on any of its
bytes, its transport_error_indicator bit is 1, or the next sync arrives
before 188 bytes. Bytes outside a packet are ignored.
- Four PID filters (PIDn, PID_EN bit n). A good packet whose PID matches
an enabled filter is written to the ring in memory; the others are
discarded silently. The lowest matching filter wins.
- Ring: RING_PKTS slots of 192 bytes from RING_BASE. Slot words 0..46 hold
the 188 bytes (byte i in word i / 4, bits 8 * (i % 4) + 7 : 8 * (i % 4)),
word 47 is the descriptor {cc_err, tei(0), pusi, filter[1:0], 7'b0,
cc[3:0], 3'b0, pid[12:0]}. WR_IDX is the next slot the IP writes; software
consumes slots and writes RD_IDX (RING_PKTS must be at least 2; 0 counts
as 1, a ring that is always full). When the ring is full (WR_IDX + 1 =
RD_IDX modulo RING_PKTS) a matching packet is dropped and counted in
OVF_CNT; so is one that finds both packet buffers still waiting for DMA.
- Continuity counter: per filter, a packet carrying payload whose CC is not
the previous CC + 1 sets cc_err in its descriptor, counts in CC_ERR_CNT
and raises CC_ERR. The first packet after ENABLE has no previous CC.
- PKT pulses for every packet written; ERR when an AXI error response was
seen while writing it (ERR in STATUS is sticky until ENABLE goes low).
- Two packet buffers (ping-pong): one fills while the other is written out
as one 48-word engine job (bursts of up to 16 beats).

Features:

- Byte stream ts_valid / ts_sync / ts_data / ts_err (one 188-byte packet starts with ts_sync and 0x47).
- Up to 4 PID filters (PID_EN, PID0..3); each matching packet takes one 192-byte ring slot: words 0..46 the packet bytes (little-endian), word 47 a descriptor {cc_err, 0, pusi, filter, 0, cc, 0, pid}.
- Packets with a bad sync byte, ts_err, TEI or a short length are dropped (DROP_CNT); continuity counter errors per filter (CC_ERR_CNT).
- Ring of RING_PKTS slots at RING_BASE: the core writes WR_IDX, software returns slots with RD_IDX; a full ring drops packets (OVF_CNT).

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time.
ts_valid / ts_sync / ts_data / ts_err are the transport stream input pins.
The core testbench prints one `LAT <master> dram R|W <cycles>` line per AXI burst (tb/tv_lat_mon.svh), the regression suite's latency format.

## Files

| File | Content |
|---|---|
| `rtl/TS_Demux_top.sv` | protocol core |
| `rtl/TS_Demux_apb.sv` | APB4 register wrapper (generated) |
| `tb/TS_Demux_tb.sv` | core testbench |
| `tb/TS_Demux_apb_tb.sv`, `tb/apb/TS_Demux_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/TS_Demux_sva.sv`, `tb/cov/TS_Demux_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/TS_Demux.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`TS_Demux_apb` has the core's parameters and passes them to `TS_Demux_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd3` |

## Wrapper pins

Pins of `TS_Demux_apb`. Widths of the pass-through pins are at the default parameters.

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
| `ts_valid` | input | 1 | protocol pin, core port `ts_valid` |
| `ts_sync` | input | 1 | protocol pin, core port `ts_sync` |
| `ts_data` | input | 8 | protocol pin, core port `ts_data` |
| `ts_err` | input | 1 | protocol pin, core port `ts_err` |
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
| `ts_valid` | input | 1 | pin (pass-through) |
| `ts_sync` | input | 1 | pin (pass-through) |
| `ts_data` | input | 8 | pin (pass-through) |
| `ts_err` | input | 1 | pin (pass-through) |
| `enable` | input | 1 | CTRL[0:0] |
| `pid_en` | input | 4 | CTRL[4:1] |
| `pid0` | input | 13 | PID01[12:0] |
| `pid1` | input | 13 | PID01[25:13] |
| `pid2` | input | 13 | PID23[12:0] |
| `pid3` | input | 13 | PID23[25:13] |
| `ring_base` | input | 32 | RING_BASE[31:0] |
| `ring_pkts` | input | 16 | RING_PKTS[15:0] |
| `rd_idx` | input | 16 | RD_IDX[15:0] |
| `wr_idx` | output | 16 | WR_IDX[15:0] |
| `pkt_cnt` | output | 16 | PKTS[15:0] |
| `drop_cnt` | output | 16 | PKTS[31:16] |
| `cc_err_cnt` | output | 16 | ERRS[15:0] |
| `ovf_cnt` | output | 16 | ERRS[31:16] |
| `busy` | output | 1 | STATUS[0:0] |
| `err` | output | 1 | STATUS[1:1] |
| `pkt` | output | 1 | IRQ_STATUS.PKT |
| `drop` | output | 1 | IRQ_STATUS.DROP |
| `cc_err` | output | 1 | IRQ_STATUS.CC_ERR |
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

`TS_Demux_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ts_valid`, `ts_sync`, `ts_data`, `ts_err`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C020100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Enable and filters |
| 0x018 | PID01 | RW | 0x00000000 | Filters 0 and 1 |
| 0x01C | PID23 | RW | 0x00000000 | Filters 2 and 3 |
| 0x020 | RING_BASE | RW | 0x00000000 | Ring address |
| 0x024 | RING_PKTS | RW | 0x00000000 | Ring size |
| 0x028 | RD_IDX | RW | 0x00000000 | Software read index |
| 0x02C | WR_IDX | RO | core | Hardware write index |
| 0x030 | STATUS | RO | core | State |
| 0x034 | PKTS | RO | core | Packet counters |
| 0x038 | ERRS | RO | core | Error counters |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x03C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C02 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `enable` | RW | 0x0 | demux on; 0 clears WR_IDX and ERR |
| CTRL | 4:1 | `pid_en` | RW | 0x0 | filter enables |
| PID01 | 12:0 | `pid0` | RW | 0x0 | PID of filter 0 |
| PID01 | 25:13 | `pid1` | RW | 0x0 | PID of filter 1 |
| PID23 | 12:0 | `pid2` | RW | 0x0 | PID of filter 2 |
| PID23 | 25:13 | `pid3` | RW | 0x0 | PID of filter 3 |
| RING_BASE | 31:0 | `ring_base` | RW | 0x0 | slot 0, word aligned |
| RING_PKTS | 15:0 | `ring_pkts` | RW | 0x0 | slots of 192 bytes |
| RD_IDX | 15:0 | `rd_idx` | RW | 0x0 | next slot software reads |
| WR_IDX | 15:0 | `wr_idx` | RO | core | next slot the core writes |
| STATUS | 0 | `busy` | RO | core | a packet is being written |
| STATUS | 1 | `err` | RO | core | AXI error response seen |
| PKTS | 15:0 | `pkt_cnt` | RO | core | packets written |
| PKTS | 31:16 | `drop_cnt` | RO | core | packets dropped |
| ERRS | 15:0 | `cc_err_cnt` | RO | core | continuity errors |
| ERRS | 31:16 | `ovf_cnt` | RO | core | packets lost to a full ring |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PKT | a packet was written to the ring |
| 1 | DROP | a packet was dropped |
| 2 | CC_ERR | continuity counter error |
| 3 | ERR | a job ended that saw an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C020100.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), PID01 (0x018), PID23 (0x01C), RING_BASE (0x020), RING_PKTS (0x024), RD_IDX (0x028). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
5. Read WR_IDX (0x02C) for the core's live `wr_idx`; it needs no clearing.
6. Read STATUS (0x030) for the core's live `busy`, `err`; it needs no clearing.
7. Read PKTS (0x034) for the core's live `pkt_cnt`, `drop_cnt`; it needs no clearing.
8. Read ERRS (0x038) for the core's live `cc_err_cnt`, `ovf_cnt`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write RING_BASE, RING_PKTS, RD_IDX = 0, PID01 / PID23.
2. Write CTRL with enable = 1 and the filter enables; IRQ_ENABLE with PKT.
3. On PKT, read slots RD_IDX .. WR_IDX - 1, then write RD_IDX = WR_IDX.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.TS_Demux sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.TS_Demux syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/TS_Demux_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.TS_Demux apb` | `TEST PASSED: TS_Demux_apb`, then Yosys without `ERROR` | console, `work/TS_Demux_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh TS_Demux`<br>`bash scripts/cov/run_cov.sh TS_Demux_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/TS_Demux/score.json`, `work/cov/TS_Demux_apb/score.json` |

Expected end of a step 4 run:

```
===== TS_Demux =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/TS_Demux_tb.sv`): drives `TS_Demux_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/TS_Demux_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/TS_Demux_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/TS_Demux_sva.sv`, `tb/cov/TS_Demux_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/TS_Demux_top.sv` | not run | | | | | |
| wrapper `rtl/TS_Demux_apb.sv` | not run | | | | | |
