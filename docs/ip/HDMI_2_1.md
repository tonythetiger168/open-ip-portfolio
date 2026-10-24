# HDMI source, TMDS mode (educational slice): 640x480@60 timing, TMDS 8b/10b video, control periods with preambles, TERC4 data islands carrying the AVI and SPD InfoFrames, serialised 1 bit per clock

Protocol IP `HDMI_2_1`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `HDMI_2_1_top` (`rtl/HDMI_2_1_top.sv`) |
| Register interface | APB4 slave `HDMI_2_1_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x484D0200 (code 0x484D, version 2.0) |
| Registers | 6 words, 0x000 to 0x014 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 6 pass-through |

## Overview

HDMI_2_1 protocol Open IP -- HDMI source (TMDS mode) educational slice: full TMDS 8b/10b encode algorithm (transition minimisation with XOR/XNOR selection + disparity tracking + DC-balance bits 8/9), 3 data channels + TMDS clock channel (serial 1 bit/clk simplification), control period with 8-pixel video/data-island preambles and CTL0-3 codes (4 fixed 10-bit codes), video period RGB888 active pixels on 3 channels, data island period with TERC4 4b/10b encoding and packet structure (24-bit header + 4 subpackets x 56 bit, BCH ECC simplified to XOR parity - see comments), AVI InfoFrame (type 0x82) sent once per frame, built-in 640x480@60 timing generator (hact=640 hfp=16 hsw=96 hbp=48 / vact=480 vfp=10 vsw=2 vbp=33). Documented simplifications (educational slice of the HDMI physical layer):

- Serialisation is 1 bit/clk per channel (real TMDS runs 10x pixel clk);
pixel period = 10 clk, all 3 channels + clock channel in lock-step,
TMDS bit0 transmitted first. TMDS clock channel = 10'b1111100000
repeated (LSB first).
- Pixel source is an internal demo generator: R=x[7:0], G=y[7:0],
B=x[7:0]^y[7:0]. HSYNC/VSYNC are active low as VIC 1 specifies; the
sync levels are carried on channel 0 (D0=HSYNC, D1=VSYNC) in control
and data island periods, CTL1:0 on channel 1, CTL3:2 on channel 2.
- The TMDS disparity counter is cleared in every non-video period.
- Video preamble (CTL0=1) and leading guard band precede every active
line, including line 0 after vertical blanking.
- Data islands: AVI InfoFrame on line VACT+1, SPD InfoFrame on line
490 (inside vsync), both at x=636..679 so they span the hsync edge:
8 px preamble (CTL0=CTL2=1), 2 px leading guard band, 32 px packet,
2 px trailing guard band. Packet header HB0..HB2 + BCH(32,24) ECC and
4 subpackets of 7 bytes + BCH(64,56) ECC, generator x^8+x^7+x^6+1
(precomputed: both packets are constant).
Per packet pixel i (0..31), TERC4 inputs:
ch0 = {i != 0, header[i], VSYNC, HSYNC}
ch1 = {sp3[2i],   sp2[2i],   sp1[2i],   sp0[2i]}
ch2 = {sp3[2i+1], sp2[2i+1], sp1[2i+1], sp0[2i+1]}
guard bands: ch0 = TERC4({1,1,VSYNC,HSYNC}), ch1 = ch2 = 0100110011.
- AVI InfoFrame: type=0x82 ver=0x02 len=0x0D, PB1=0x10 (RGB, active
format present), PB2=0x18 (4:3, active format = picture), PB4=VIC 1,
checksum = two's complement of the byte sum.
- hpd=0: TMDS outputs stop (all zero), timing restarts at (0,0) on
hpd return; irq = level "link was running and hpd was lost".

The link runs on its own from the internal demo pattern while hpd is high; hpd low stops the TMDS outputs and restarts the timing at pixel (0,0) on return.
hpd (in) and tmds_clk / tmds_d[2:0] (TMDS clock and data channels, 1 bit per clock, pixel period 10 clocks) pass through unchanged; hsync / vsync / de also stay pins.

## Files

| File | Content |
|---|---|
| `rtl/HDMI_2_1_top.sv` | protocol core |
| `rtl/HDMI_2_1_apb.sv` | APB4 register wrapper (generated) |
| `tb/HDMI_2_1_tb.sv` | core testbench |
| `tb/HDMI_2_1_apb_tb.sv`, `tb/apb/HDMI_2_1_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/HDMI_2_1_sva.sv`, `tb/cov/HDMI_2_1_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/HDMI_2_1.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.HDMI_2_1 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.HDMI_2_1 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh HDMI_2_1          # core coverage (Verilator)
bash scripts/cov/run_cov.sh HDMI_2_1_apb      # wrapper coverage
```

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `HDMI_2_1_apb`. Widths of the pass-through pins are at the default parameters.

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
| `hpd` | input | 1 | protocol pin, core port `hpd` |
| `tmds_clk` | output | 1 | protocol pin, core port `tmds_clk` |
| `tmds_d` | output | 3 | protocol pin, core port `tmds_d` |
| `hsync` | output | 1 | protocol pin, core port `hsync` (also read in a register) |
| `vsync` | output | 1 | protocol pin, core port `vsync` (also read in a register) |
| `de` | output | 1 | protocol pin, core port `de` (also read in a register) |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `hpd` | input | 1 | pin (pass-through) |
| `tmds_clk` | output | 1 | pin (pass-through) |
| `tmds_d` | output | 3 | pin (pass-through) |
| `hsync` | output | 1 | STATUS[0:0] |
| `vsync` | output | 1 | STATUS[1:1] |
| `de` | output | 1 | STATUS[2:2] |
| `irq` | output | 1 | IRQ_STATUS.HPD_LOST |

## APB wrapper

`HDMI_2_1_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `hpd`, `tmds_clk`, `tmds_d`, `hsync`, `vsync`, `de`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x484D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Video timing (the same levels as the hsync / vsync / de pins) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x484D | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `hsync` | RO | core | horizontal sync, active low (VIC 1) |
| STATUS | 1 | `vsync` | RO | core | vertical sync, active low (VIC 1) |
| STATUS | 2 | `de` | RO | core | active video pixel |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | HPD_LOST | hpd went low after the link had run; level in the core, so the bit is set again on every clock until hpd returns |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x484D0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `hsync`, `vsync`, `de`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/HDMI_2_1_top.sv` | pass | 75/75 | 466/466 | n/a | 8/8 | 16/16 |
| wrapper `rtl/HDMI_2_1_apb.sv` | pass | 20/20 | 416/416 | n/a | 7/7 | 25/25 |
