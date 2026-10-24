# MIPI DPI transmitter: programmable parallel RGB video timing (front porch, sync, back porch, active in both directions), 1 pixel per clock, 24 or 18-bit colour

Protocol IP `MIPI_DPI__Display_Pixel_Interface_`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `MIPI_DPI__Display_Pixel_Interface__top` (`rtl/MIPI_DPI__Display_Pixel_Interface__top.sv`) |
| Register interface | APB4 slave `MIPI_DPI__Display_Pixel_Interface__apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x44490200 (code 0x4449, version 2.0) |
| Registers | 17 words, 0x000 to 0x040 |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | REGS (12 words) |
| Protocol pins | 7 pass-through |

## Overview

MIPI DPI (Display Pixel Interface) transmitter -- parallel RGB video timing Implementation scope: * Programmable timing generator: horizontal hfp/hsw/hbp/hact and vertical vfp/vsw/vbp/vact in 8 x 16-bit registers (reg 0..7); frame FSM walks front porch -> sync -> back porch -> active in both dimensions, 1 pixel per clk (pclk forwarded 1:1 from clk, all video outputs change on the pclk rising edge) * Outputs: pclk, hsync, vsync (active high), de, rgb[23:0]; pixel source is the pixel[23:0] input, sampled in the active region * Control register (reg 8): bit0 enable, bit1 shutdown (outputs forced low, counters held), bit2 color_mode (18-bit color: 2 LSBs of each channel masked) * Enabling with any timing register == 0, or with a line/frame total that does not fit the 16-bit counters, is rejected and raises irq * Timing registers may be rewritten while running: a counter already past the new total wraps at once * frame_cnt output increments at each vertical wrap; reg readback port

pclk (= PCLK), hsync / vsync (active high), de, rgb[23:0], the pixel[23:0] input (sampled in the active region) and frame_cnt[15:0] pass through unchanged.
Each core register takes bits [15:0] of a whole-word write. Frame order: front porch, sync, back porch, active, horizontally and vertically. Timing registers may change while running; a counter already past a new total wraps at once.

## Files

| File | Content |
|---|---|
| `rtl/MIPI_DPI__Display_Pixel_Interface__top.sv` | protocol core |
| `rtl/MIPI_DPI__Display_Pixel_Interface__apb.sv` | APB4 register wrapper (generated) |
| `tb/MIPI_DPI__Display_Pixel_Interface__tb.sv` | core testbench |
| `tb/MIPI_DPI__Display_Pixel_Interface__apb_tb.sv`, `tb/apb/MIPI_DPI__Display_Pixel_Interface__apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/MIPI_DPI__Display_Pixel_Interface__sva.sv`, `tb/cov/MIPI_DPI__Display_Pixel_Interface__apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/MIPI_DPI__Display_Pixel_Interface_.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.MIPI_DPI__Display_Pixel_Interface_ sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.MIPI_DPI__Display_Pixel_Interface_ apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh MIPI_DPI__Display_Pixel_Interface_          # core coverage (Verilator)
bash scripts/cov/run_cov.sh MIPI_DPI__Display_Pixel_Interface__apb      # wrapper coverage
```

## Parameters

`MIPI_DPI__Display_Pixel_Interface__apb` has the core's parameters and passes them to `MIPI_DPI__Display_Pixel_Interface__top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |

## Wrapper pins

Pins of `MIPI_DPI__Display_Pixel_Interface__apb`. Widths of the pass-through pins are at the default parameters.

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
| `PSLVERR` | output | 1 | error: unmapped or misaligned address, or partial write to a core register word |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `pclk` | output | 1 | protocol pin, core port `pclk` |
| `hsync` | output | 1 | protocol pin, core port `hsync` |
| `vsync` | output | 1 | protocol pin, core port `vsync` |
| `de` | output | 1 | protocol pin, core port `de` |
| `rgb` | output | 24 | protocol pin, core port `rgb` |
| `pixel` | input | 24 | protocol pin, core port `pixel` |
| `frame_cnt` | output | 16 | protocol pin, core port `frame_cnt` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `irq` | output | 1 | IRQ_STATUS.CFG_ERR |
| `pclk` | output | 1 | pin (pass-through) |
| `hsync` | output | 1 | pin (pass-through) |
| `vsync` | output | 1 | pin (pass-through) |
| `de` | output | 1 | pin (pass-through) |
| `rgb` | output | 24 | pin (pass-through) |
| `pixel` | input | 24 | pin (pass-through) |
| `reg_wr` | input | 1 | write to a REGS word |
| `reg_addr` | input | 4 | REGS word index |
| `reg_wdata` | input | 16 | REGS write data |
| `reg_rdata` | output | 16 | REGS read data |
| `frame_cnt` | output | 16 | pin (pass-through) |

## APB wrapper

`MIPI_DPI__Display_Pixel_Interface__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `pclk`, `hsync`, `vsync`, `de`, `rgb`, `pixel`, `frame_cnt`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44490200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | HFP | RW (core) | core | [15:0] horizontal front porch, pixels (reset 0) |
| 0x018 | HSW | RW (core) | core | [15:0] hsync width, pixels |
| 0x01C | HBP | RW (core) | core | [15:0] horizontal back porch, pixels |
| 0x020 | HACT | RW (core) | core | [15:0] active pixels per line |
| 0x024 | VFP | RW (core) | core | [15:0] vertical front porch, lines |
| 0x028 | VSW | RW (core) | core | [15:0] vsync width, lines |
| 0x02C | VBP | RW (core) | core | [15:0] vertical back porch, lines |
| 0x030 | VACT | RW (core) | core | [15:0] active lines |
| 0x034 | CTRL | RW (core) | core | [0] enable, [1] shutdown (outputs low, position held), [2] 18-bit colour (2 LSBs of each channel cleared). Enabling with a timing register at 0 or a total above 65536 is refused (CFG_ERR) |
| 0x038 | FRAME | RO (core) | core | [15:0] frames sent (wraps; also on the frame_cnt pins) |
| 0x03C | HCNT | RO (core) | core | [15:0] current pixel in the line (0 while disabled) |
| 0x040 | VCNT | RO (core) | core | [15:0] current line in the frame |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x044 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4449 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| HFP | 15:0 | core register | RW (core) | core | written at core register 0 and read from core register 0 |
| HSW | 15:0 | core register | RW (core) | core | written at core register 1 and read from core register 1 |
| HBP | 15:0 | core register | RW (core) | core | written at core register 2 and read from core register 2 |
| HACT | 15:0 | core register | RW (core) | core | written at core register 3 and read from core register 3 |
| VFP | 15:0 | core register | RW (core) | core | written at core register 4 and read from core register 4 |
| VSW | 15:0 | core register | RW (core) | core | written at core register 5 and read from core register 5 |
| VBP | 15:0 | core register | RW (core) | core | written at core register 6 and read from core register 6 |
| VACT | 15:0 | core register | RW (core) | core | written at core register 7 and read from core register 7 |
| CTRL | 15:0 | core register | RW (core) | core | written at core register 8 and read from core register 8 |
| FRAME | 15:0 | core register | RO (core) | core | read from core register 9 |
| HCNT | 15:0 | core register | RO (core) | core | read from core register 10 |
| VCNT | 15:0 | core register | RO (core) | core | read from core register 11 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CFG_ERR | an enable was refused (invalid timing); level in the core until the next accepted CTRL write, so the bit is set again on every clock until then |

### Core register port

The REGS words reach the core's own register port. A write to one pulses `reg_wr` for one clock with `reg_addr` (the core register) and `reg_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `reg_addr` (the core register) during the access phase and returns `reg_rdata`.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44490200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the REGS words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/MIPI_DPI__Display_Pixel_Interface__top.sv` | pass | 30/30 | 1070/1070 | n/a | 6/6 | 10/10 |
| wrapper `rtl/MIPI_DPI__Display_Pixel_Interface__apb.sv` | pass | 31/31 | 618/618 | n/a | 10/10 | 48/48 |
