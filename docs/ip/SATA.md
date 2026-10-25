# SATA host: OOB bring-up (COMRESET / COMINIT / COMWAKE, ALIGNp lock), link layer with frame handshakes, CRC-32 and resends, and a built-in DMA command sequencer (IDENTIFY, then WRITE / READ DMA EXT read-verify)

Protocol IP `SATA`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SATA_top` (`rtl/SATA_top.sv`) |
| Register interface | APB4 slave `SATA_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53540200 (code 0x5354, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 5 pass-through |

## Overview

SATA protocol Open IP -- SATA host: OOB bring-up, link layer with frame handshakes, and a built-in DMA command sequencer. Open IP design implementation v3.0 Implementation scope (scaled, 1 line bit per clk, no 8b/10b): * Line: tx_p/tx_n differential; electrical idle is tx_p = tx_n = 0. On the receive side a clock carries signal when rx_p != rx_n; data bits are taken from rx_p. Dwords are sent LSB first. * OOB: a pattern is 4 bursts of 16 clk of signal, each preceded by a gap of electrical idle: 48 clk for COMRESET / COMINIT, 16 clk for COMWAKE. The receiver classifies each gap between two bursts of 12..20 clk (40..56 = INIT gap, 12..20 = WAKE gap); three equal gaps in a row detect COMINIT or COMWAKE. * Host PHY init: COMRESET -> wait COMINIT -> COMWAKE -> wait COMWAKE -> send ALIGNp and lock the receiver on the device's ALIGNp stream (two in a row) -> READY. Each wait times out after 1024 clk and restarts with COMRESET. In READY a clock of electrical idle (signal lost, e.g. the device starting COMINIT) is a link loss (irq) and restarts the bring-up; no dword completes on an idle clock. * Link layer (primitives as dword values; ALIGNp is dropped anywhere): transmit X_RDY -> R_RDY -> SOF, FIS dwords, CRC32, EOF -> WTRM until R_OK (done) or R_ERR (resend, at most 2 resends). Receive X_RDY -> send R_RDY, R_IP during the frame, then R_OK / R_ERR (bad CRC, more than 9 FIS dwords) until SYNC. Idle: SYNC (at least one SYNC dword goes out between two transmitted frames). When both sides raise X_RDY the host backs off and receives first. Handshake waits time out after 64 dwords. * CRC32: poly 32'h04C11DB7 reflected (32'hEDB88320), init all-ones, one dword LSB first per step, complemented on the wire. * Command sequencer (the port contract has no command bus): IDENTIFY DEVICE (Register H2D 8'hEC -> Data FIS of 8 dwords, dword 1 [5:0] = max LBA -> Register D2H), then forever: WRITE DMA EXT of one 8-dword sector (Register H2D 8'h35 -> DMA Activate -> Data FIS -> D2H) with xorshift32 data, READ DMA EXT of the same LBA (8'h25 -> Data FIS -> D2H) compared against the written data, next LBA (wraps after max). A D2H with ERR set or a non-zero error byte ends the command early. * irq: 1-clk pulse on link loss, an illegal primitive between frames, a received frame error (CRC / overflow / aborted / handshake timeout), a transmit failure (resends exhausted / timeout), an unexpected or malformed FIS, a status error, read data mismatch, or a command response timeout (4096 clk). * refclk is kept for interface compatibility; the line clock is clk.

tx_p / tx_n, rx_p / rx_n (1 line bit per PCLK, no 8b/10b) and refclk (interface compatibility only) pass through unchanged. The host brings the link up and runs its command sequence on its own after reset.
The registers report the host's error events; commands and data stay on the serial pins.

## Files

| File | Content |
|---|---|
| `rtl/SATA_top.sv` | protocol core |
| `rtl/SATA_apb.sv` | APB4 register wrapper (generated) |
| `tb/SATA_tb.sv` | core testbench |
| `tb/SATA_apb_tb.sv`, `tb/apb/SATA_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SATA_sva.sv`, `tb/cov/SATA_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SATA.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `SATA_apb`. Widths of the pass-through pins are at the default parameters.

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
| `tx_n` | output | 1 | protocol pin, core port `tx_n` |
| `tx_p` | output | 1 | protocol pin, core port `tx_p` |
| `rx_n` | input | 1 | protocol pin, core port `rx_n` |
| `rx_p` | input | 1 | protocol pin, core port `rx_p` |
| `refclk` | input | 1 | protocol pin, core port `refclk` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_n` | output | 1 | pin (pass-through) |
| `tx_p` | output | 1 | pin (pass-through) |
| `rx_n` | input | 1 | pin (pass-through) |
| `rx_p` | input | 1 | pin (pass-through) |
| `refclk` | input | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`SATA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_n`, `tx_p`, `rx_n`, `rx_p`, `refclk`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5354 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | link loss, illegal primitive, receive frame error (CRC, overflow, abort, handshake timeout), transmit failure (resends exhausted, timeout), unexpected or malformed FIS, error status, read data mismatch, or a command response timeout |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53540200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SATA sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SATA syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SATA_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SATA apb` | `TEST PASSED: SATA_apb`, then Yosys without `ERROR` | console, `work/SATA_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SATA`<br>`bash scripts/cov/run_cov.sh SATA_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SATA/score.json`, `work/cov/SATA_apb/score.json` |

Expected end of a step 4 run:

```
===== SATA =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SATA_tb.sv`): drives `SATA_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SATA_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SATA_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SATA_sva.sv`, `tb/cov/SATA_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SATA_top.sv` | pass | 228/228 | 1474/1474 | 75/75 | 5/5 | 64/64 |
| wrapper `rtl/SATA_apb.sv` | pass | 19/19 | 402/402 | n/a | 7/7 | 23/23 |
