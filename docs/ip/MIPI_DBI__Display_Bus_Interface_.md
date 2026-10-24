# MIPI DBI-2 display bus host controller (Type A, Type B, Type C options 1 / 3)

Protocol IP `MIPI_DBI__Display_Bus_Interface_`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `MIPI_DBI__Display_Bus_Interface__top` (`rtl/MIPI_DBI__Display_Bus_Interface__top.sv`) |
| Register interface | APB4 slave `MIPI_DBI__Display_Bus_Interface__apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x44420200 (code 0x4442, version 2.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 4 sources into one level-high `irq` |
| Data streams | OP (to the core), RD (from the core) |
| Protocol pins | 11 pass-through |

## Overview

MIPI_DBI__Display_Bus_Interface__top v2.0: MIPI DBI-2 host controller (Type A, Type B and Type C options 1 / 3)

- The host issues one transfer per op: a command or data (op_dc = 0 /
1), a write or a read (op_rd), 8 or 16 bits. CSX goes low with the
first op and high after an op with op_last, for at least one phase.
- Type A (Motorola 6800, cfg_type 0): R/WX on wrx, E on rdx. Type B
(Intel 8080, cfg_type 1): WRX / RDX low strobes. Both: setup, strobe
and hold phases of cfg_tw + 1 PCLK (cfg_tr + 1 for reads); D/CX and
the bus (8 or 16 bits, cfg_w16) are valid through all three; read
data is taken at the end of the strobe phase.
- Type C (serial, SCL idles low, the display samples on the rising
edge): option 1 (cfg_type 2) sends the D/CX bit before the 8 data
bits, option 3 (cfg_type 3) drives the D/CX pin. Each bit is an SCL
low and an SCL high phase of cfg_tw + 1 (cfg_tr + 1 while reading)
PCLK. A read clocks in 8 bits (no D/CX bit) on SDA, which the host
releases; the first read after a write (or after CSX goes low)
first sends cfg_dummy dummy clocks. Read data is sampled as SCL rises.
- Read data: rd_valid for one clock with rd_data (8-bit transfers in
rd_data[7:0], upper bits 0).
Change the configuration only while idle (busy low); the strobe pins
take the new type's idle level one clock later.
Not implemented: DBI Type C option 2 (8-bit with 16-bit dummy), the
Type A clock-synchronous variant, tearing-effect input handling.

csx, dcx, wrx (Type B WRX / Type A R/WX), rdx (Type B RDX / Type A E), d_o / d_oe / d_i (data bus, 16 bits, Type A / B) and scl, sda_o / sda_oe / sda_i (Type C) are the display pins; all pass through unchanged.

## Files

| File | Content |
|---|---|
| `rtl/MIPI_DBI__Display_Bus_Interface__top.sv` | protocol core |
| `rtl/MIPI_DBI__Display_Bus_Interface__apb.sv` | APB4 register wrapper (generated) |
| `tb/MIPI_DBI__Display_Bus_Interface__tb.sv` | core testbench |
| `tb/MIPI_DBI__Display_Bus_Interface__apb_tb.sv`, `tb/apb/MIPI_DBI__Display_Bus_Interface__apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/MIPI_DBI__Display_Bus_Interface__sva.sv`, `tb/cov/MIPI_DBI__Display_Bus_Interface__apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/MIPI_DBI__Display_Bus_Interface_.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.MIPI_DBI__Display_Bus_Interface_ sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.MIPI_DBI__Display_Bus_Interface_ apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh MIPI_DBI__Display_Bus_Interface_          # core coverage (Verilator)
bash scripts/cov/run_cov.sh MIPI_DBI__Display_Bus_Interface__apb      # wrapper coverage
```

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `MIPI_DBI__Display_Bus_Interface__apb`. Widths of the pass-through pins are at the default parameters.

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
| `csx` | output | 1 | protocol pin, core port `csx` |
| `dcx` | output | 1 | protocol pin, core port `dcx` |
| `wrx` | output | 1 | protocol pin, core port `wrx` |
| `rdx` | output | 1 | protocol pin, core port `rdx` |
| `d_o` | output | 16 | protocol pin, core port `d_o` |
| `d_oe` | output | 1 | protocol pin, core port `d_oe` |
| `d_i` | input | 16 | protocol pin, core port `d_i` |
| `scl` | output | 1 | protocol pin, core port `scl` |
| `sda_o` | output | 1 | protocol pin, core port `sda_o` |
| `sda_oe` | output | 1 | protocol pin, core port `sda_oe` |
| `sda_i` | input | 1 | protocol pin, core port `sda_i` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_type` | input | 2 | CFG[1:0] |
| `cfg_w16` | input | 1 | CFG[2:2] |
| `cfg_tw` | input | 4 | CFG[6:3] |
| `cfg_tr` | input | 4 | CFG[10:7] |
| `cfg_dummy` | input | 2 | CFG[12:11] |
| `op_valid` | input | 1 | OP commit / FLAGS |
| `op_ready` | output | 1 | OP handshake |
| `op_dc` | input | 1 | OP[16:16] |
| `op_rd` | input | 1 | OP[17:17] |
| `op_last` | input | 1 | OP[18:18] |
| `op_data` | input | 16 | OP[15:0] |
| `rd_valid` | output | 1 | RD capture |
| `rd_data` | output | 16 | RD[15:0] |
| `busy` | output | 1 | STATUS |
| `csx` | output | 1 | pin (pass-through) |
| `dcx` | output | 1 | pin (pass-through) |
| `wrx` | output | 1 | pin (pass-through) |
| `rdx` | output | 1 | pin (pass-through) |
| `d_o` | output | 16 | pin (pass-through) |
| `d_oe` | output | 1 | pin (pass-through) |
| `d_i` | input | 16 | pin (pass-through) |
| `scl` | output | 1 | pin (pass-through) |
| `sda_o` | output | 1 | pin (pass-through) |
| `sda_oe` | output | 1 | pin (pass-through) |
| `sda_i` | input | 1 | pin (pass-through) |

## APB wrapper

`MIPI_DBI__Display_Bus_Interface__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `csx`, `dcx`, `wrx`, `rdx`, `d_o`, `d_oe`, `d_i`, `scl`, `sda_o`, `sda_oe`, `sda_i`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44420200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000A11 | Interface configuration (change only while STATUS.busy is 0) |
| 0x018 | OP | RW | 0x00000000 | One bus transfer; writing OP commits it |
| 0x01C | RD | RO (pop) | 0x00000000 | Read data; reading RD frees it |
| 0x020 | STATUS | RO | core | Controller state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4442 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 1:0 | `cfg_type` | RW | 0x1 | 0 Type A (6800), 1 Type B (8080), 2 Type C option 1 (3-line, 9-bit), 3 Type C option 3 (4-line, D/CX pin) |
| CFG | 2 | `cfg_w16` | RW | 0x0 | Type A / B 16-bit data bus |
| CFG | 6:3 | `cfg_tw` | RW | 0x2 | write phase length - 1 (PCLK) |
| CFG | 10:7 | `cfg_tr` | RW | 0x4 | read phase length - 1 (PCLK) |
| CFG | 12:11 | `cfg_dummy` | RW | 0x1 | Type C dummy clocks before the first read after a write |
| OP | 15:0 | `op_data` | RW | 0x0 | write data (8-bit transfers use [7:0]) |
| OP | 16 | `op_dc` | RW | 0x0 | 0 command, 1 data / parameter (D/CX) |
| OP | 17 | `op_rd` | RW | 0x0 | 1 read, 0 write |
| OP | 18 | `op_last` | RW | 0x0 | release CSX after this transfer |
| RD | 15:0 | `rd_data` | RO (pop) | 0x0 | read data (8-bit transfers in [7:0]) |
| STATUS | 0 | `busy` | RO | core | a transfer is running or CSX is low |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | OP_DONE | OP beat accepted by the core |
| 1 | OP_OVF | write to OP while full (dropped) |
| 2 | RD_AVAIL | RD captured a beat |
| 3 | RD_OVF | beat dropped, RD was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | OP_FULL | OP holds a beat the core has not taken |
| 1 | RD_AVAIL | RD holds an unread beat |

### Streams

* **OP** feeds `op_data`, `op_dc`, `op_rd`, `op_last`/`op_valid`. Writing OP commits the beat: FLAGS.OP_FULL is set and `op_valid` stays high until the core's `op_ready`; then OP_DONE is set. A write while full is dropped and sets OP_OVF.
* **RD** captures `rd_data` when `rd_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RD_AVAIL. Reading RD pops it. A beat that arrives while the register is full is dropped and sets RD_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44420200.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
5. To send on OP: wait until FLAGS.OP_FULL (bit 0) is 0, or for IRQ OP_DONE, then write OP (0x018). The last write commits the beat. OP_OVF means a write came while the register was full and was dropped.
6. To receive on RD: wait for IRQ RD_AVAIL or FLAGS.RD_AVAIL (bit 1), then read RD (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RD_AVAIL (bit 2) to clear it. Read each beat before the next arrives, or it is dropped and RD_OVF is set.
7. Read STATUS (0x020) for the core's live `busy`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/MIPI_DBI__Display_Bus_Interface__top.sv` | pass | 68/68 | 264/264 | 18/18 | 15/15 | 27/27 |
| wrapper `rtl/MIPI_DBI__Display_Bus_Interface__apb.sv` | pass | 34/34 | 706/706 | n/a | 17/17 | 51/51 |
