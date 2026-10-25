# MIPI RFFE slave (USID 5): register 0 write, register write / read, extended write / read with auto-increment over a 32 x 8 register file, broadcast writes, parity checks

Protocol IP `MIPI_RFFE`, version 2.0. Apache-2.0.

## Overview

MIPI RFFE protocol IP -- RFFE slave controller Implementation scope (subset of MIPI RFFE v2.x, clk oversamples the bus):

- SSC: SDATA rises then falls while SCLK stays low. It is recognised in
any state the slave is not driving, so a new SSC aborts a sequence.
- Master drives SDATA on SCLK rising edges; the slave samples on SCLK
falling edges, and drives read data on rising edges.
- Command frame, 13 bits: SA[3:0] | C[7:0] | P, odd parity per frame.
1DDDDDDD : register 0 write (reg0 <= {0, D[6:0]})
010AAAAA : register write   -> data frame D[7:0]|P, then bus park
011AAAAA : register read    -> bus park, slave drives D[7:0]|P,
slave parks the bus (drives 0 for
the high phase) and releases
0000BBBB : extended write   -> address frame A[7:0]|P, BC+1 data
0010BBBB : extended read    -> address frame, bus park, BC+1 frames
driven by the slave, bus park
- SA = USID addresses this slave; SA = 0 (broadcast) is accepted for
writes only. Other SAs are another slave's traffic and are ignored.
- 32 x 8 register file. Extended accesses auto-increment; addresses
32..255 read as 0 and ignore writes.
- Command/address/data parity errors and unsupported commands abort the
sequence and raise irq, which holds until the next SSC.

sclk (in) and sdata (bidirectional, needs a weak keeper to 0) are the RFFE bus; they pass through unchanged. PCLK oversamples the bus: SCLK phases must last at least four PCLK clocks.
The register file is reached over the RFFE bus only; the registers report its protocol errors.

## Files

| File | Content |
|---|---|
| `rtl/MIPI_RFFE_top.sv` | protocol core |
| `rtl/MIPI_RFFE_apb.sv` | APB4 register wrapper (generated) |
| `tb/MIPI_RFFE_tb.sv` | core testbench |
| `tb/MIPI_RFFE_apb_tb.sv`, `tb/apb/MIPI_RFFE_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/MIPI_RFFE_sva.sv`, `tb/cov/MIPI_RFFE_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/MIPI_RFFE.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.MIPI_RFFE sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.MIPI_RFFE apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh MIPI_RFFE          # core coverage (Verilator)
bash scripts/cov/run_cov.sh MIPI_RFFE_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sclk` | input | 1 | pin (pass-through) |
| `sdata` | inout | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.PROTO |

## APB wrapper

`MIPI_RFFE_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `sdata`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x52660200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5266 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PROTO | a sequence was aborted: command, address or data parity error, or an unsupported command. Held in the core until the next SSC, so the bit is set again on every clock until then |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/MIPI_RFFE_top.sv` | pass | 69/69 (+1 excl.) | 732/732 | 19/19 | 7/7 | 18/18 |
| wrapper `rtl/MIPI_RFFE_apb.sv` | pass | 19/19 | 396/396 | n/a | 7/7 | 23/23 |
