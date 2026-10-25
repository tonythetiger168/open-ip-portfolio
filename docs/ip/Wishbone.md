# Wishbone B4 pipelined subordinate: a 256-word memory with a wait-state window, two requests outstanding with in-order acknowledges, classic cycles, ERR for the reserved region

Protocol IP `Wishbone`, version 2.0. Apache-2.0.

## Overview




cyc_i, stb_i, we_i, adr_i, dat_i, sel_i, cti_i, dat_o, ack_o, stall_o, err_o and rty_o are the Wishbone B4 subordinate pins; they pass through unchanged. The registers report the subordinate's error event.
Bytes 0x000 to 0x1FF answer in the next clock, 0x200 to 0x3FF two clocks later; 0x400 to 0x7FF acknowledge with reads 0 and writes dropped; 0x800 and up answer ERR. Up to two requests are accepted ahead of their acknowledges (stall_o when two are waiting). A classic cycle (cti_i 000) holds its strobe until the acknowledge and is taken once. rty_o is never set (waived).

## Files

| File | Content |
|---|---|
| `rtl/Wishbone_top.sv` | protocol core |
| `rtl/Wishbone_apb.sv` | APB4 register wrapper (generated) |
| `tb/Wishbone_tb.sv` | core testbench |
| `tb/Wishbone_apb_tb.sv`, `tb/apb/Wishbone_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Wishbone_sva.sv`, `tb/cov/Wishbone_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Wishbone.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.Wishbone sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.Wishbone apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh Wishbone          # core coverage (Verilator)
bash scripts/cov/run_cov.sh Wishbone_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cyc_i` | input | 1 | pin (pass-through) |
| `stb_i` | input | 1 | pin (pass-through) |
| `we_i` | input | 1 | pin (pass-through) |
| `adr_i` | input | 32 | pin (pass-through) |
| `dat_i` | input | 32 | pin (pass-through) |
| `sel_i` | input | 4 | pin (pass-through) |
| `cti_i` | input | 3 | pin (pass-through) |
| `dat_o` | output | 32 | pin (pass-through) |
| `ack_o` | output | 1 | pin (pass-through) |
| `stall_o` | output | 1 | pin (pass-through) |
| `err_o` | output | 1 | pin (pass-through) |
| `rty_o` | output | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`Wishbone_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `cyc_i`, `stb_i`, `we_i`, `adr_i`, `dat_i`, `sel_i`, `cti_i`, `dat_o`, `ack_o`, `stall_o`, `err_o`, `rty_o`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x57420200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5742 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a request to the reserved region (address 0x800 and up) was answered with ERR; the core holds this until reset, so the bit cannot be cleared before then |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Wishbone_top.sv` | pass | 27/27 (+1 excl.) | 440/440 (+2 excl.) | 6/6 | 9/9 | 29/29 |
| wrapper `rtl/Wishbone_apb.sv` | pass | 19/19 | 612/612 (+2 excl.) | n/a | 7/7 | 23/23 |
