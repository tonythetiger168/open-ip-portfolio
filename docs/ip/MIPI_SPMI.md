# MIPI SPMI slave (USID 5): register 0 write, register and extended (short and long address) write / read over a 32 x 8 register file, write ACK, reset / sleep / shutdown / wakeup, parity checks

Protocol IP `MIPI_SPMI`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `MIPI_SPMI_top` (`rtl/MIPI_SPMI_top.sv`) |
| Register interface | APB4 slave `MIPI_SPMI_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53700200 (code 0x5370, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 2 pass-through |

## Overview

MIPI SPMI protocol IP -- SPMI slave controller Implementation scope (subset of MIPI SPMI v2.0, clk oversamples the bus):

- SSC: SDATA rises then falls while SCLK stays low. It is recognised in
any state the slave is not driving, so a new SSC aborts a sequence.
Bus arbitration is left to the masters; this slave never requests.
- Master drives SDATA on SCLK rising edges; the slave samples on SCLK
falling edges, and drives read data / ACK on rising edges.
- Command frame, 13 bits: SA[3:0] | C[7:0] | P, odd parity per frame.
0000BBBB : extended register write  -> A[7:0]|P, BC+1 data frames
00010000 : reset     (clears the register file)
00010001 : sleep     \
00010010 : shutdown   > accepted, no power modes in this slave
00010011 : wakeup    /
0010BBBB : extended register read   -> A[7:0]|P, bus park,
BC+1 frames from the slave
00110BBB : ext. register write long -> A[15:8]|P, A[7:0]|P, BC+1
00111BBB : ext. register read long  -> A[15:8]|P, A[7:0]|P, bus
park, BC+1 slave frames
010AAAAA : register write           -> D[7:0]|P
011AAAAA : register read            -> bus park, D[7:0]|P
1DDDDDDD : register 0 write          (reg0 <= {0, D[6:0]})
- Write response: after a write addressed to USID whose frames all had
good parity, the slave drives ACK (1) for one SCLK cycle, then parks
the bus (drives 0 for the high phase) and releases it. A sequence with
a parity error is abandoned without a response, so the master reads
the bus keeper's 0 as NACK. Broadcast writes get no response.
- Every read ends with the slave's bus park and release.
- SA = USID addresses this slave; SA = 0 (broadcast) is accepted for
writes, reset, sleep, shutdown and wakeup. Other SAs are another
slave's traffic and are ignored.
- 32 x 8 register file; extended accesses auto-increment (the 16-bit
address wraps from 0xFFFF to 0); addresses 32..65535 read as 0
and ignore writes.
- Command/address/data parity errors and unsupported commands (master
read/write, authenticate, bus ownership transfer, DDB, ...) abort the
sequence and raise irq, which holds until the next SSC.

sclk (in) and sdata (bidirectional, needs a weak keeper to 0) are the SPMI bus; they pass through unchanged. PCLK oversamples the bus: SCLK phases must last at least four PCLK clocks.
The register file is reached over the SPMI bus only; the registers report its protocol errors.

## Files

| File | Content |
|---|---|
| `rtl/MIPI_SPMI_top.sv` | protocol core |
| `rtl/MIPI_SPMI_apb.sv` | APB4 register wrapper (generated) |
| `tb/MIPI_SPMI_tb.sv` | core testbench |
| `tb/MIPI_SPMI_apb_tb.sv`, `tb/apb/MIPI_SPMI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/MIPI_SPMI_sva.sv`, `tb/cov/MIPI_SPMI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/MIPI_SPMI.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.MIPI_SPMI sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.MIPI_SPMI apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh MIPI_SPMI          # core coverage (Verilator)
bash scripts/cov/run_cov.sh MIPI_SPMI_apb      # wrapper coverage
```

## Parameters

`MIPI_SPMI_apb` has the core's parameters and passes them to `MIPI_SPMI_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `USID` | logic [3:0] | `4'h5` |

## Wrapper pins

Pins of `MIPI_SPMI_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sclk` | input | 1 | protocol pin, core port `sclk` |
| `sdata` | inout | 1 | protocol pin, core port `sdata` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sclk` | input | 1 | pin (pass-through) |
| `sdata` | inout | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.PROTO |

## APB wrapper

`MIPI_SPMI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `sdata`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53700200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5370 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PROTO | a sequence was aborted: command, address or data parity error, or an unsupported command. Held in the core until the next SSC, so the bit is set again on every clock until then |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53700200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/MIPI_SPMI_top.sv` | pass | 86/86 | 756/756 | 23/23 | 7/7 | 98/98 |
| wrapper `rtl/MIPI_SPMI_apb.sv` | pass | 19/19 | 396/396 | n/a | 7/7 | 23/23 |
