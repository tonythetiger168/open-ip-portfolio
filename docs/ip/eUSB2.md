# eUSB2 repeater: eD+ / eD- retimed onto USB2 dp / dm, control packets (PID C3, NRZI, bit stuffing, CRC8) writing and reading an 8 x 8 register file with read responses sent on dp / dm, and squelch detection on long SE0

Protocol IP `eUSB2`, version 2.0. Apache-2.0.

## Overview

eUSB2 protocol IP -- eUSB2 device/repeater (simplified) * eD+/eD- single-ended 1.2V signalling, simplified to lvcmos logic levels (J = 10, K = 01, SE0 = 00, SE1 = 11 illegal), 1 bit cell/clk * USB2 packet-layer retimer: the received eUSB2 NRZI bit stream is re-registered and driven onto the standard dp/dm output port * Control messages (control packets, PID 8'hC3): register write/read of an 8x8 register file (reg0 = squelch threshold, reg1 = term config, reg2..7 scratch); read responses are transmitted as a USB2-style frame on dp/dm * Squelch detection: SE0 longer than the programmed threshold forces the retimed outputs silent and resets the packet parser * NRZI decode + bit unstuffing on receive; NRZI encode + bit stuffing on transmit; CRC8 (poly 0x07, init 0xFF) protects control packets * irq (sticky until rst_n): SE1 on the line, bit-stuff error, a truncated or over-long control packet, or a CRC8 mismatch


edp / edm (eUSB2 line in, one bit cell per PCLK), dp / dm (retimed USB2 line out) and squelch pass through unchanged.
The 8 x 8 register file (squelch threshold, termination, scratch) is reached through control packets on the line only.

## Files

| File | Content |
|---|---|
| `rtl/eUSB2_top.sv` | protocol core |
| `rtl/eUSB2_apb.sv` | APB4 register wrapper (generated) |
| `tb/eUSB2_tb.sv` | core testbench |
| `tb/eUSB2_apb_tb.sv`, `tb/apb/eUSB2_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/eUSB2_sva.sv`, `tb/cov/eUSB2_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/eUSB2.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.eUSB2 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.eUSB2 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh eUSB2          # core coverage (Verilator)
bash scripts/cov/run_cov.sh eUSB2_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `edp` | input | 1 | pin (pass-through) |
| `edm` | input | 1 | pin (pass-through) |
| `dp` | output | 1 | pin (pass-through) |
| `dm` | output | 1 | pin (pass-through) |
| `squelch` | output | 1 | STATUS |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`eUSB2_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `edp`, `edm`, `dp`, `dm`, `squelch`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x65550200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | 0x00000000 | Line state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x6555 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| STATUS | 0 | `squelch` | signal loss: SE0 longer than the squelch threshold (cleared by J); same as the squelch pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | SE1 on the line, bit-stuff error, truncated or over-long control packet, or CRC8 mismatch. Sticky in the core until PRESETN, so the bit is set again on every clock |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/eUSB2_top.sv` | pass | 108/108 (+1 excl.) | 394/394 | 16/16 | 6/6 | 34/34 |
| wrapper `rtl/eUSB2_apb.sv` | pass | 20/20 | 406/406 | n/a | 7/7 | 25/25 |
