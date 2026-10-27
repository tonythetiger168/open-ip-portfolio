# USB3 SuperSpeed device link and protocol layer: LFPS training to U0, warm reset, DPH / DPP / TP framing with CRC5 / CRC32, sequence numbers with retry, NRDY and LBAD, IN retransmission, and bulk OUT / IN over a 4-block buffer

Protocol IP `USB3`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `USB3_top` (`rtl/USB3_top.sv`) |
| Register interface | APB4 slave `USB3_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55530200 (code 0x5553, version 2.0) |
| Registers | 6 words, 0x000 to 0x014 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 5 pass-through |

## Overview

USB3 protocol IP -- SuperSpeed link + protocol layer (simplified) * Symbol-parallel serial link: 1 symbol/clk, 8-bit symbol, on the tx_p/tx_n and rx_p/rx_n differential pairs (_n carries the complement) * Symbol decode: a received symbol is valid only when rx_n == ~rx_p; an invalid symbol inside a packet aborts it (irq), and is never counted as LFPS or taken as a packet start. * LFPS out-of-band handshake: RXDET (32 clk) -> Polling.LFPS: the device sends 16-symbol LFPS bursts + 16 idle; U0 (link_up) once it has sent two bursts and received two bursts of >= 8 symbols. LFPS burst = repeated 8'hAA symbols, idle = 8'h00. * Warm reset: in U0, 32 consecutive LFPS symbols between packets drop the link back to RXDET and clear the sequence numbers and any transfer in progress (buffer contents, block flags and irq are kept). * Ordered-set framing: DPH : SOF(8'hBC) + {route,type} + {seq,blk} + CRC5 DPP : START(8'h5A) + fixed 16-dword payload + CRC32 + END(8'h3C) TP  : SOF(8'h4B) + {route,type} + {seq,retry,blk,in_req} + CRC5 + END Transaction packet types: ACK(4'hA) / NRDY(4'h5) / LBAD(4'hB) * Sequence-number retransmission management: bad DPP CRC32 -> LBAD -> host resends; duplicate seq -> ACK with retry flag; out-of-order seq -> NRDY; device IN data retransmitted on LBAD / ACK timeout. * Function unit: bulk OUT writes / bulk IN reads a 64x32 buffer (4 blocks x 16 dwords, one DPP carries exactly one block).

rx_p / rx_n (one 8-bit symbol per PCLK, rx_n = ~rx_p), tx_p / tx_n and link_up pass through unchanged. The device trains on its own after reset.
The bulk buffer is reached over the link only; the registers report the link state and errors.

## Files

| File | Content |
|---|---|
| `rtl/USB3_top.sv` | protocol core |
| `rtl/USB3_apb.sv` | APB4 register wrapper (generated) |
| `tb/USB3_tb.sv` | core testbench |
| `tb/USB3_apb_tb.sv`, `tb/apb/USB3_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/USB3_sva.sv`, `tb/cov/USB3_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/USB3.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `USB3_apb`. Widths of the pass-through pins are at the default parameters.

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
| `rx_p` | input | 8 | protocol pin, core port `rx_p` |
| `rx_n` | input | 8 | protocol pin, core port `rx_n` |
| `tx_p` | output | 8 | protocol pin, core port `tx_p` |
| `tx_n` | output | 8 | protocol pin, core port `tx_n` |
| `link_up` | output | 1 | protocol pin, core port `link_up` (also read in a register) |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rx_p` | input | 8 | pin (pass-through) |
| `rx_n` | input | 8 | pin (pass-through) |
| `tx_p` | output | 8 | pin (pass-through) |
| `tx_n` | output | 8 | pin (pass-through) |
| `link_up` | output | 1 | STATUS |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`USB3_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_p`, `rx_n`, `tx_p`, `tx_n`, `link_up`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Link state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5553 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `link_up` | RO | core | U0 reached (cleared by a warm reset); same as the link_up pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | bad DPP CRC32, bad DPH / TP CRC5, bad END, missing DPP, symbol decode error inside a packet, or an IN transfer given up after four attempts. Sticky in the core until PRESETN, so the bit is set again on every clock |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55530200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `link_up`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.USB3 sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.USB3 syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/USB3_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.USB3 apb` | `TEST PASSED: USB3_apb`, then Yosys without `ERROR` | console, `work/USB3_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh USB3`<br>`bash scripts/cov/run_cov.sh USB3_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/USB3/score.json`, `work/cov/USB3_apb/score.json` |

Expected end of a step 4 run:

```
===== USB3 =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/USB3_tb.sv`): drives `USB3_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/USB3_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/USB3_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/USB3_sva.sv`, `tb/cov/USB3_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/USB3_top.sv` | pass | 137/137 | 720/720 | 80/80 | 8/8 | 100/100 |
| wrapper `rtl/USB3_apb.sv` | pass | 20/20 | 462/462 | n/a | 7/7 | 25/25 |
