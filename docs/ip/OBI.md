# OBI 1.6 subordinate: a 256 x 32-bit memory behind the req / gnt A channel and the rvalid / rready R channel, up to 4 outstanding transactions, byte enables, error responses, atomics (AMOs, LR / SC), protection window, parity handshake

Protocol IP `OBI`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `OBI_top` (`rtl/OBI_top.sv`) |
| Register interface | APB4 slave `OBI_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x4F420100 (code 0x4F42, version 1.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 4 sources into one level-high `irq` |
| Protocol pins | 18 pass-through |

## Overview

OBI 1.6 subordinate (OpenHW Open Bus Interface): a 256 x 32-bit memory behind a pipelined A channel (req / gnt) and an in-order R channel (rvalid / rready) with up to NOUT transactions outstanding. * A phase: a request is taken on req && gnt; gnt is only given to a request (gnt implies req) and drops while NOUT responses wait. * R phase: one response per granted request, in order, held stable while rvalid && !rready; rid echoes the request's aid. * Byte enables on writes; reads return the whole word. * Errors (err = 1, write dropped, rdata 0): an address at or above 0x400 (decode), a user-mode access (prot[2:1] != 2'b11) to the machine-only window from PROT_BASE up (protection), and an atop code with atop[5] = 0 or an undefined AMO (unsupported). * Atomics (atop[5] = 1, RISC-V A extension encoding in atop[4:0]): AMOSWAP / ADD / XOR / AND / OR / MIN / MAX / MINU / MAXU read the old word (returned in rdata) and write the result in the same cycle; LR.W (we = 0) sets the reservation, SC.W (we = 1) writes only if it holds and returns 0 on success, 1 on failure. Any other write to the reserved word, and every SC, clears the reservation. * Integrity handshake (OBI 1.6 parity signals): gntpar = ~gnt and rvalidpar = ~rvalid; reqpar must be ~req and rreadypar ~rready, a mismatch pulses irq_par. irq_dec / irq_prot / irq_atop pulse with the err response of the failing request (a decode error takes precedence). The memory is not cleared by reset (sim zeroes it once).

Features:

- OBI 1.6 subordinate (OpenHW Group): A channel req / gnt with addr, we, be, wdata, aid, prot and atop; R channel rvalid / rready with rdata, err and rid.
- Pipelined: up to NOUT (default 4) granted requests outstanding; gnt is given only to a request and drops while NOUT responses wait. One transfer per clock with rready high.
- Responses in order, held stable while rvalid is high and rready low; rid echoes aid.
- Atomics in the RISC-V A encoding (atop[5] = 1, atop[4:0] = funct5): AMOSWAP, AMOADD, AMOXOR, AMOAND, AMOOR, AMOMIN, AMOMAX, AMOMINU, AMOMAXU return the old word and write the result; LR.W / SC.W with one reservation (SC returns 0 on success, 1 on failure).
- Integrity handshake signals: gntpar = ~gnt, rvalidpar = ~rvalid, reqpar and rreadypar checked against req and rready.

req, gnt, addr, we, be, wdata, aid, prot, atop, reqpar, gntpar, rvalid, rready, rdata, err, rid, rvalidpar and rreadypar are the OBI pins; they pass through unchanged. The registers report the subordinate's error events.
Not implemented: the OBI 1.6 achk / rchk signal-group checksums, auser / wuser / ruser, memtype and dbg (an access answers the same whatever their value), and exclusive access per manager (one reservation for the whole memory). prot[0] (data / instruction) does not change the answer.

## Files

| File | Content |
|---|---|
| `rtl/OBI_top.sv` | protocol core |
| `rtl/OBI_apb.sv` | APB4 register wrapper (generated) |
| `tb/OBI_tb.sv` | core testbench |
| `tb/OBI_apb_tb.sv`, `tb/apb/OBI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/OBI_sva.sv`, `tb/cov/OBI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/OBI.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`OBI_apb` has the core's parameters and passes them to `OBI_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NOUT` | int | `4` |
| `IDW` | int | `4` |
| `PROT_BASE` | logic [9:0] | `10'h300` |

## Wrapper pins

Pins of `OBI_apb`. Widths of the pass-through pins are at the default parameters.

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
| `req` | input | 1 | protocol pin, core port `req` |
| `gnt` | output | 1 | protocol pin, core port `gnt` |
| `addr` | input | 32 | protocol pin, core port `addr` |
| `we` | input | 1 | protocol pin, core port `we` |
| `be` | input | 4 | protocol pin, core port `be` |
| `wdata` | input | 32 | protocol pin, core port `wdata` |
| `aid` | input | 4 | protocol pin, core port `aid` |
| `prot` | input | 3 | protocol pin, core port `prot` |
| `atop` | input | 6 | protocol pin, core port `atop` |
| `reqpar` | input | 1 | protocol pin, core port `reqpar` |
| `gntpar` | output | 1 | protocol pin, core port `gntpar` |
| `rvalid` | output | 1 | protocol pin, core port `rvalid` |
| `rready` | input | 1 | protocol pin, core port `rready` |
| `rdata` | output | 32 | protocol pin, core port `rdata` |
| `err` | output | 1 | protocol pin, core port `err` |
| `rid` | output | 4 | protocol pin, core port `rid` |
| `rvalidpar` | output | 1 | protocol pin, core port `rvalidpar` |
| `rreadypar` | input | 1 | protocol pin, core port `rreadypar` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `req` | input | 1 | pin (pass-through) |
| `gnt` | output | 1 | pin (pass-through) |
| `addr` | input | 32 | pin (pass-through) |
| `we` | input | 1 | pin (pass-through) |
| `be` | input | 4 | pin (pass-through) |
| `wdata` | input | 32 | pin (pass-through) |
| `aid` | input | 4 | pin (pass-through) |
| `prot` | input | 3 | pin (pass-through) |
| `atop` | input | 6 | pin (pass-through) |
| `reqpar` | input | 1 | pin (pass-through) |
| `gntpar` | output | 1 | pin (pass-through) |
| `rvalid` | output | 1 | pin (pass-through) |
| `rready` | input | 1 | pin (pass-through) |
| `rdata` | output | 32 | pin (pass-through) |
| `err` | output | 1 | pin (pass-through) |
| `rid` | output | 4 | pin (pass-through) |
| `rvalidpar` | output | 1 | pin (pass-through) |
| `rreadypar` | input | 1 | pin (pass-through) |
| `irq_dec` | output | 1 | IRQ_STATUS.DEC |
| `irq_prot` | output | 1 | IRQ_STATUS.PROT |
| `irq_atop` | output | 1 | IRQ_STATUS.ATOP |
| `irq_par` | output | 1 | IRQ_STATUS.PAR |

## APB wrapper

`OBI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `req`, `gnt`, `addr`, `we`, `be`, `wdata`, `aid`, `prot`, `atop`, `reqpar`, `gntpar`, `rvalid`, `rready`, `rdata`, `err`, `rid`, `rvalidpar`, `rreadypar`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4F420100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4F42 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DEC | a request at or above byte 0x400 got an error response (write dropped, rdata 0) |
| 1 | PROT | a request below machine level (prot[2:1] != 2'b11) to the window from PROT_BASE (0x300) up got an error response |
| 2 | ATOP | a request with an unsupported atop (atop[5] = 0 with atop != 0, an undefined AMO, LR with we = 1, SC or an AMO with we = 0) got an error response |
| 3 | PAR | reqpar was not the inverse of req, or rreadypar not the inverse of rready, in a clock |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4F420100.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.OBI sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.OBI syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/OBI_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.OBI apb` | `TEST PASSED: OBI_apb`, then Yosys without `ERROR` | console, `work/OBI_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh OBI`<br>`bash scripts/cov/run_cov.sh OBI_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/OBI/score.json`, `work/cov/OBI_apb/score.json` |

Expected end of a step 4 run:

```
===== OBI =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/OBI_tb.sv`): drives `OBI_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/OBI_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/OBI_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/OBI_sva.sv`, `tb/cov/OBI_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/OBI_top.sv` | not run | | | | | |
| wrapper `rtl/OBI_apb.sv` | not run | | | | | |
