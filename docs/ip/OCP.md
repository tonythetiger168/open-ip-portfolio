# OCP-IP 3.0 slave: a 256-word memory behind MCmd / SCmdAccept / SResp, WR, RD and posted WRNP with byte enables and thread IDs

Protocol IP `OCP`, version 2.0. Apache-2.0.

## Overview

OCP protocol -- OCP-IP 3.0 slave (MCmd/MAddr/MData -> SCmdAccept/SData/SResp) Scope: basic data-handshake subset of OCP-IP:

- MCmd: IDLE=0 / WR=1 / RD=2 / WRNP=5 (posted write, no response)
- configurable command-accept latency (ACCEPT_DLY = 0 or 1)
- fixed 2-cycle DVA response latency for WR/RD, SData valid with DVA
- MByteEn partial-write merge, MThreadID echoed on SThreadID
- 256x32 register file (1 KiB, word aligned); accesses outside
0x000..0x3FC or misaligned -> SResp=ERR + irq pulse
- other MCmd encodings (RDEX/RDL/WRC/BCST) are not supported: accepted
and answered with SResp=ERR + irq pulse, no register-file effect

mcmd, maddr, mdata, mbyteen, mthreadid, scmdaccept, sdata, sresp and sthreadid are the OCP slave pins; they pass through unchanged. The registers report the slave's error events.
A command is accepted the clock after it is presented (ACCEPT_DLY 1, the default). WR and RD are answered DVA (or ERR) two clocks after acceptance with the thread ID echoed; SData carries the word as it was when the request was accepted. WRNP is not answered. MCmd values other than WR, RD and WRNP are answered ERR and do nothing.

## Files

| File | Content |
|---|---|
| `rtl/OCP_top.sv` | protocol core |
| `rtl/OCP_apb.sv` | APB4 register wrapper (generated) |
| `tb/OCP_tb.sv` | core testbench |
| `tb/OCP_apb_tb.sv`, `tb/apb/OCP_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/OCP_sva.sv`, `tb/cov/OCP_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/OCP.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.OCP sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.OCP apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh OCP          # core coverage (Verilator)
bash scripts/cov/run_cov.sh OCP_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `mcmd` | input | 3 | pin (pass-through) |
| `maddr` | input | 32 | pin (pass-through) |
| `mdata` | input | 32 | pin (pass-through) |
| `mbyteen` | input | 4 | pin (pass-through) |
| `mthreadid` | input | 2 | pin (pass-through) |
| `scmdaccept` | output | 1 | pin (pass-through) |
| `sdata` | output | 32 | pin (pass-through) |
| `sresp` | output | 2 | pin (pass-through) |
| `sthreadid` | output | 2 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`OCP_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `mcmd`, `maddr`, `mdata`, `mbyteen`, `mthreadid`, `scmdaccept`, `sdata`, `sresp`, `sthreadid`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4F430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4F43 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a request was answered ERR (an address outside 0x000 to 0x3FC or misaligned, or an unsupported MCmd), or a posted write went to such an address |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/OCP_top.sv` | pass | 31/31 | 308/308 | 11/11 | 11/11 | 32/32 |
| wrapper `rtl/OCP_apb.sv` | pass | 19/19 | 612/612 | n/a | 7/7 | 23/23 |
