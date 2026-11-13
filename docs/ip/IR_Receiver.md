# Consumer IR remote receiver: NEC and RC-5 decode, codes to a ring in memory over AXI4

Protocol IP `IR_Receiver`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `IR_Receiver_top` (`rtl/IR_Receiver_top.sv`) |
| Register interface | APB4 slave `IR_Receiver_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C040100 (code 0x7C04, version 1.0) |
| Registers | 15 words, 0x000 to 0x038 |
| Interrupts | 3 sources into one level-high `irq` |
| Protocol pins | 32 pass-through |

## Overview

IR_Receiver: consumer infrared remote decoder of the TV SoC (NEC and RC5) with a code ring DMA (AXI4 manager, APB4 registers) Input ir_in is the demodulated output of the IR receiver module: low while a carrier burst (mark) is present, high otherwise (space). It is synchronised with two flops.

- Time base: one tick every TICK_DIV + 1 clks. Nominal timings in ticks
(one tick = 562.5 us / 16 = 35.16 us for the real protocols):
NEC: unit T = 16 ticks; leader 16T mark + 8T space; repeat 16T mark + 4T
space + 1T mark; bit = 1T mark + 1T space (0) or 3T space (1), 32 bits
LSB first {~cmd, cmd, addr_hi, addr}, then a 1T stop mark.
RC5: half bit H = 25 ticks (889 us); 14 Manchester bits MSB first
{S1 = 1, S2, toggle, addr[4:0], cmd[5:0]}, 1 = space then mark.
Every mark / space must be within +-25 % of its nominal length (H and 2H
for RC5), otherwise the frame is discarded and RX_ERR counts it.
- MODE selects the protocol (0 NEC, 1 RC5).
- Code word: {proto[1:0] (0 NEC, 1 RC5), repeat, toggle, 4'b0, addr_hi[7:0],
addr[7:0], cmd[7:0]}. NEC: addr / addr_hi are bytes 0 / 1 (extended NEC
addresses accepted), cmd byte 2; byte 3 must be ~cmd. A NEC repeat frame
repeats the last code with repeat = 1 (none before a first code: RX_ERR).
RC5: addr = {3'b0, A[4:0]}, cmd = {1'b0, ~S2, C[5:0]} (RC5X command 6).
- Ring DMA: each code is written as one word at RING_BASE + 4 * WR_IDX;
RING_WORDS words (at least 2), software consumes them and writes RD_IDX.
While the ring is full (WR_IDX + 1 = RD_IDX mod RING_WORDS) codes wait in
an 8-entry FIFO; a code that finds that FIFO full is dropped and counted
in OVF_CNT. CODE pulses when a code
is in memory, ERR as well on an AXI error response. LAST holds the last
decoded code.

Features:

- ir_in is the demodulated receiver output, active low. A tick is TICK_DIV + 1 clocks: NEC unit = 16 ticks (562.5 us at a 35.16 us tick), RC-5 half bit = 25 ticks (889 us); pulse widths are accepted within +-25%.
- MODE 0 NEC (address, inverted address or extended address, command, inverted command, repeat codes), MODE 1 RC-5 (toggle, 5-bit address, 6-bit command with field bit).
- Each code is one ring word {proto[1:0], repeat, toggle, 4'b0, addr_hi, addr, cmd}; LAST shows the newest code.
- Ring of RING_WORDS words at RING_BASE (WR_IDX / RD_IDX); 8 codes wait in a FIFO while the ring is full, then OVF_CNT counts the lost ones.

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time.
ir_in is the receiver pin (idle high).
The core testbench prints one `LAT <master> dram R|W <cycles>` line per AXI burst (tb/tv_lat_mon.svh), the regression suite's latency format.

## Files

| File | Content |
|---|---|
| `rtl/IR_Receiver_top.sv` | protocol core |
| `rtl/IR_Receiver_apb.sv` | APB4 register wrapper (generated) |
| `tb/IR_Receiver_tb.sv` | core testbench |
| `tb/IR_Receiver_apb_tb.sv`, `tb/apb/IR_Receiver_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/IR_Receiver_sva.sv`, `tb/cov/IR_Receiver_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/IR_Receiver.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`IR_Receiver_apb` has the core's parameters and passes them to `IR_Receiver_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd5` |

## Wrapper pins

Pins of `IR_Receiver_apb`. Widths of the pass-through pins are at the default parameters.

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
| `ir_in` | input | 1 | protocol pin, core port `ir_in` |
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
| `ir_in` | input | 1 | pin (pass-through) |
| `enable` | input | 1 | CTRL[0:0] |
| `mode` | input | 1 | CTRL[1:1] |
| `tick_div` | input | 16 | TICK_DIV[15:0] |
| `ring_base` | input | 32 | RING_BASE[31:0] |
| `ring_words` | input | 16 | RING_WORDS[15:0] |
| `rd_idx` | input | 16 | RD_IDX[15:0] |
| `last` | output | 32 | LAST[31:0] |
| `wr_idx` | output | 16 | WR_IDX[15:0] |
| `code_cnt` | output | 16 | COUNTS[15:0] |
| `rx_err_cnt` | output | 16 | COUNTS[31:16] |
| `ovf_cnt` | output | 16 | OVF_CNT[15:0] |
| `err` | output | 1 | STATUS |
| `code` | output | 1 | IRQ_STATUS.CODE |
| `rx_err` | output | 1 | IRQ_STATUS.RX_ERR |
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

`IR_Receiver_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ir_in`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C040100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Enable and protocol |
| 0x018 | TICK_DIV | RW | 0x00000000 | Tick divider |
| 0x01C | RING_BASE | RW | 0x00000000 | Ring address |
| 0x020 | RING_WORDS | RW | 0x00000000 | Ring size |
| 0x024 | RD_IDX | RW | 0x00000000 | Software read index |
| 0x028 | WR_IDX | RO | core | Hardware write index |
| 0x02C | LAST | RO | core | Last code |
| 0x030 | STATUS | RO | core | State |
| 0x034 | COUNTS | RO | core | Counters |
| 0x038 | OVF_CNT | RO | core | Lost codes |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x03C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C04 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `enable` | RW | 0x0 | receiver on; 0 clears WR_IDX |
| CTRL | 1 | `mode` | RW | 0x0 | 0 NEC, 1 RC-5 |
| TICK_DIV | 15:0 | `tick_div` | RW | 0x0 | tick = TICK_DIV + 1 clocks |
| RING_BASE | 31:0 | `ring_base` | RW | 0x0 | word 0, word aligned |
| RING_WORDS | 15:0 | `ring_words` | RW | 0x0 | words |
| RD_IDX | 15:0 | `rd_idx` | RW | 0x0 | next word software reads |
| WR_IDX | 15:0 | `wr_idx` | RO | core | next word the core writes |
| LAST | 31:0 | `last` | RO | core | newest decoded code |
| STATUS | 0 | `err` | RO | core | AXI error response seen |
| COUNTS | 15:0 | `code_cnt` | RO | core | codes decoded |
| COUNTS | 31:16 | `rx_err_cnt` | RO | core | malformed frames |
| OVF_CNT | 15:0 | `ovf_cnt` | RO | core | codes lost to a full ring and FIFO |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CODE | a code was decoded |
| 1 | RX_ERR | a malformed frame |
| 2 | ERR | a job ended that saw an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C040100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), TICK_DIV (0x018), RING_BASE (0x01C), RING_WORDS (0x020), RD_IDX (0x024). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. Read WR_IDX (0x028) for the core's live `wr_idx`; it needs no clearing.
6. Read LAST (0x02C) for the core's live `last`; it needs no clearing.
7. Read STATUS (0x030) for the core's live `err`; it needs no clearing.
8. Read COUNTS (0x034) for the core's live `code_cnt`, `rx_err_cnt`; it needs no clearing.
9. Read OVF_CNT (0x038) for the core's live `ovf_cnt`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write TICK_DIV (clock / 28.44 kHz - 1), RING_BASE, RING_WORDS, RD_IDX = 0.
2. Write CTRL (enable, mode) and IRQ_ENABLE with CODE.
3. On CODE, read LAST or the ring words RD_IDX .. WR_IDX - 1 and write RD_IDX.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.IR_Receiver sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.IR_Receiver syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/IR_Receiver_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.IR_Receiver apb` | `TEST PASSED: IR_Receiver_apb`, then Yosys without `ERROR` | console, `work/IR_Receiver_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh IR_Receiver`<br>`bash scripts/cov/run_cov.sh IR_Receiver_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/IR_Receiver/score.json`, `work/cov/IR_Receiver_apb/score.json` |

Expected end of a step 4 run:

```
===== IR_Receiver =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/IR_Receiver_tb.sv`): drives `IR_Receiver_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/IR_Receiver_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/IR_Receiver_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/IR_Receiver_sva.sv`, `tb/cov/IR_Receiver_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/IR_Receiver_top.sv` | not run | | | | | |
| wrapper `rtl/IR_Receiver_apb.sv` | not run | | | | | |
