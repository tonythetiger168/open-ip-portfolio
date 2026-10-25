# Toggle-mode NAND flash target: SDR command / address cycles, DDR data in (dqs) and out (re_n echoed on dqs), Read ID, page read / program, block erase, Read Status, reset, a protected block, and protocol-error detection

Protocol IP `Toggle_Mode_NAND`, version 2.0. Apache-2.0.

## Overview

Toggle Mode NAND protocol IP -- NAND flash target Implementation scope (subset of toggle-mode / ONFI NV-DDR style NAND; clk oversamples the bus):

- Commands and addresses are SDR: latched on the rising edge of we_n
while ce_n = 0, with cle = 1 (command) or ale = 1 (address).
- Data is DDR on dq[7:0]:
input : the host drives dqs; every dqs edge (rising and falling)
latches one byte during page-program data input.
output: the host toggles re_n; the target drives dq and echoes
re_n on dqs. The first byte follows the first re_n falling
edge and every further re_n edge presents the next byte;
cle or ale high releases dq / dqs at once.
- Command set:
90h + 1 addr            : Read ID, 5-byte ID
00h + 5 addr + 30h      : Page Read (col[5:0] = byte, row[3:0] = page)
80h + 5 addr + data + 10h: Page Program (1 -> 0 only)
60h + 3 addr + D0h      : Block Erase (4 pages per block)
70h                     : Read Status, accepted at any time, also
while busy: {WP_n=1, RDY, ARDY, 0000, FAIL}
00h (no address)        : after a page read, return from status to
the page data (restarts at the column)
(FAIL reports the last program / erase;
a page read clears it)
FFh                     : Reset, accepted at any time; aborts the
operation in flight, clears irq and FAIL
- Array: 16 pages x 64 bytes; block = 4 pages. Block 3 (pages 12..15)
is protected: program / erase leave it untouched and set FAIL.
- rb_n busy time (clk cycles): read T_R, program T_PROG, erase T_ERASE,
reset T_RST.
- irq (sticky until FFh or rst_n): unknown command, a command out of
sequence, an address cycle outside an address phase, or any command
but 70h / FFh while busy. The offending command is ignored.

ce_n, cle, ale, we_n, re_n (in), dq[7:0] and dqs (bidirectional tri-state) and rb_n (out) are the NAND bus; they pass through unchanged. PCLK oversamples the bus: each strobe phase must last at least two PCLK clocks.
The 16 x 64-byte array is reached over the NAND bus only; the registers report the ready / busy state and protocol errors.

## Files

| File | Content |
|---|---|
| `rtl/Toggle_Mode_NAND_top.sv` | protocol core |
| `rtl/Toggle_Mode_NAND_apb.sv` | APB4 register wrapper (generated) |
| `tb/Toggle_Mode_NAND_tb.sv` | core testbench |
| `tb/Toggle_Mode_NAND_apb_tb.sv`, `tb/apb/Toggle_Mode_NAND_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Toggle_Mode_NAND_sva.sv`, `tb/cov/Toggle_Mode_NAND_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Toggle_Mode_NAND.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.Toggle_Mode_NAND sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.Toggle_Mode_NAND apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh Toggle_Mode_NAND          # core coverage (Verilator)
bash scripts/cov/run_cov.sh Toggle_Mode_NAND_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `ce_n` | input | 1 | pin (pass-through) |
| `cle` | input | 1 | pin (pass-through) |
| `ale` | input | 1 | pin (pass-through) |
| `we_n` | input | 1 | pin (pass-through) |
| `re_n` | input | 1 | pin (pass-through) |
| `dq` | inout | 8 | pin (pass-through) |
| `dqs` | inout | 1 | pin (pass-through) |
| `rb_n` | output | 1 | STATUS |
| `irq` | output | 1 | IRQ_STATUS.PROTO |

## APB wrapper

`Toggle_Mode_NAND_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ce_n`, `cle`, `ale`, `we_n`, `re_n`, `dq`, `dqs`, `rb_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x544E0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | 0x00000000 | Target state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x544E |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| STATUS | 0 | `rb_n` | ready (1) / busy (0); same as the rb_n pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PROTO | unknown command, command out of sequence, address cycle outside an address phase, or a command other than 70h / FFh while busy. Held in the core until FFh, so the bit is set again on every clock until then |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Toggle_Mode_NAND_top.sv` | pass | 98/98 | 246/246 | 31/31 | 7/7 | 22/22 |
| wrapper `rtl/Toggle_Mode_NAND_apb.sv` | pass | 20/20 | 426/426 | n/a | 7/7 | 25/25 |
