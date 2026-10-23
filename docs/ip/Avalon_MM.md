# Avalon-MM agent: a 256-word memory with a wait-state window, read and write bursts of up to 16 beats with byte enables, pipelined read data

Protocol IP `Avalon_MM`, version 2.0. Apache-2.0.

## Overview




av_address, av_read, av_write, av_writedata, av_byteenable, av_burstcount, av_readdata, av_readdatavalid and av_waitrequest are the Avalon-MM agent pins; they pass through unchanged. The registers report the agent's error event.
Bytes 0x000 to 0x1FF answer without wait states; 0x200 to 0x3FF cost one wait state per command or write beat and one idle cycle before each read beat. Beats above 0x3FF are dropped (writes) or return 0 (reads). A burstcount of 0 is one beat, above 16 is clamped to 16. waitrequest stays high while read data is returned.

## Files

| File | Content |
|---|---|
| `rtl/Avalon_MM_top.sv` | protocol core |
| `rtl/Avalon_MM_apb.sv` | APB4 register wrapper (generated) |
| `tb/Avalon_MM_tb.sv` | core testbench |
| `tb/Avalon_MM_apb_tb.sv`, `tb/apb/Avalon_MM_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Avalon_MM_sva.sv`, `tb/cov/Avalon_MM_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Avalon_MM.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.Avalon_MM sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.Avalon_MM apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh Avalon_MM          # core coverage (Verilator)
bash scripts/cov/run_cov.sh Avalon_MM_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `av_address` | input | 32 | pin (pass-through) |
| `av_read` | input | 1 | pin (pass-through) |
| `av_write` | input | 1 | pin (pass-through) |
| `av_writedata` | input | 32 | pin (pass-through) |
| `av_byteenable` | input | 4 | pin (pass-through) |
| `av_burstcount` | input | 8 | pin (pass-through) |
| `av_readdata` | output | 32 | pin (pass-through) |
| `av_readdatavalid` | output | 1 | pin (pass-through) |
| `av_waitrequest` | output | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`Avalon_MM_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `av_address`, `av_read`, `av_write`, `av_writedata`, `av_byteenable`, `av_burstcount`, `av_readdata`, `av_readdatavalid`, `av_waitrequest`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x414D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x414D |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | an access outside the memory, a burstcount above 16, or read and write asserted together; the core holds this until reset, so the bit cannot be cleared before then |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Avalon_MM_top.sv` | pass | 51/51 (+1 excl.) | 338/338 | 7/7 | 15/15 | 31/31 |
| wrapper `rtl/Avalon_MM_apb.sv` | pass | 19/19 | 616/616 | n/a | 7/7 | 23/23 |
