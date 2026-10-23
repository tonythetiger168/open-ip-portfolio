# I2S audio transceiver: TX and RX at once, master (bclk / wclk generated) or slave, I2S / left-justified / right-justified, 16 / 24 / 32-bit samples in 32-bit slots

Protocol IP `I2S_Audio`, version 2.0. Apache-2.0.

## Overview

I2S Audio protocol Open IP -- I2S transceiver (TX + RX, master/slave) Three serial formats (I2S standard / left-justified / right-justified) x three sample depths (16/24/32 bit) inside a 32-bclk channel slot; TX and RX operate simultaneously (full-duplex, TB loopback). Documented simplifications:

- clk is the master clock (mclk). In master mode bclk = clk / MCLK_DIV
(default 4 -> 256x fs for 32-bit stereo) and wclk(lrck) = bclk / 64.
- Standard edge use in both modes: the frame position (and with it
sd_out and wclk) advances on the bclk falling edge, sd_in is sampled
on the bclk rising edge. In master mode bclk_out is low for the first
half of each bit, so sd_out/wclk_out are stable around every rise.
- Parallel sample interface carries both channels per frame
(tx_l/tx_r with valid/ready; rx_l/rx_r with rx_valid frame strobe).
Samples are LSB-aligned on the parallel side and left-justified into
the 32-bit wire slot internally.
- Slave mode: bclk_in/wclk_in must be synchronous to clk (TB drives them
from clk), wclk_in changing on bclk_in falling edges; the frame
position re-synchronizes to every wclk edge and a frame-sync error
(irq pulse) is flagged when the bclk/wclk phase is broken (e.g. a
dropped bclk pulse).
- tx_valid/tx_ready: tx_ready is a one-cycle pulse on the cycle that
loads the next frame; a sample pair transfers when both are high.
- TX underrun (no fresh sample at frame start) transmits zeros.
- cfg_fmt/cfg_depth/cfg_master are configuration-register style inputs;
changing them re-synchronizes the frame counters.

bclk_out / wclk_out (master clocks), bclk_in / wclk_in (slave clocks), sd_out and sd_in pass through unchanged. A frame is 64 bclk = 256 PCLK.
A pair arrives every frame, zeros included when nothing was sent, so RX must be read once per frame; a pair arriving with RX full is dropped (RX_OVF).

## Files

| File | Content |
|---|---|
| `rtl/I2S_Audio_top.sv` | protocol core |
| `rtl/I2S_Audio_apb.sv` | APB4 register wrapper (generated) |
| `tb/I2S_Audio_tb.sv` | core testbench |
| `tb/I2S_Audio_apb_tb.sv`, `tb/apb/I2S_Audio_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/I2S_Audio_sva.sv`, `tb/cov/I2S_Audio_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/I2S_Audio.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.I2S_Audio sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.I2S_Audio apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh I2S_Audio          # core coverage (Verilator)
bash scripts/cov/run_cov.sh I2S_Audio_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_master` | input | 1 | CFG[0:0] |
| `cfg_fmt` | input | 2 | CFG[2:1] |
| `cfg_depth` | input | 2 | CFG[4:3] |
| `bclk_out` | output | 1 | pin (pass-through) |
| `wclk_out` | output | 1 | pin (pass-through) |
| `bclk_in` | input | 1 | pin (pass-through) |
| `wclk_in` | input | 1 | pin (pass-through) |
| `tx_l` | input | 32 | TX0[31:0] |
| `tx_r` | input | 32 | TX1[31:0] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `rx_l` | output | 32 | RX0[31:0] |
| `rx_r` | output | 32 | RX1[31:0] |
| `rx_valid` | output | 1 | RX capture |
| `sd_out` | output | 1 | pin (pass-through) |
| `sd_in` | input | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.FSYNC_ERR |

## APB wrapper

`I2S_Audio_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `bclk_out`, `wclk_out`, `bclk_in`, `wclk_in`, `sd_out`, `sd_in`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x49410200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000011 | Configuration; a change re-synchronises the frame counters |
| 0x018 | TX0 | RW | 0x00000000 | Stereo sample pair, LSB-aligned; taken at the start of the next frame (a frame without a pair sends zeros) |
| 0x01C | TX1 | RW | 0x00000000 | Stereo sample pair, LSB-aligned; taken at the start of the next frame (a frame without a pair sends zeros) |
| 0x020 | RX0 | RO (pop) | 0x00000000 | Received stereo pair (LSB-aligned, one per frame); reading the right word frees it |
| 0x024 | RX1 | RO (pop) | 0x00000000 | Received stereo pair (LSB-aligned, one per frame); reading the right word frees it |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4941 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CFG | 0 | `cfg_master` | 1: master (bclk_out = PCLK / 4, wclk_out = bclk / 64), 0: slave (bclk_in / wclk_in, synchronous to PCLK) |
| CFG | 2:1 | `cfg_fmt` | 0 I2S, 1 left-justified, 2 right-justified |
| CFG | 4:3 | `cfg_depth` | 0 16-bit, 1 24-bit, 2 / 3 32-bit |
| TX0 | 31:0 | `tx_l` | left sample |
| TX1 | 31:0 | `tx_r` | right sample |
| RX0 | 31:0 | `rx_l` | left sample |
| RX1 | 31:0 | `rx_r` | right sample |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FSYNC_ERR | slave mode: the bclk / wclk phase broke (e.g. a dropped bclk pulse); the core re-synchronises on the next wclk edge |
| 1 | TX_DONE | TX beat accepted by the core |
| 2 | TX_OVF | write to TX while full (dropped) |
| 3 | RX_AVAIL | RX captured a beat |
| 4 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_l`, `tx_r`/`tx_valid`. Writing TX1 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_l`, `rx_r` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX1 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/I2S_Audio_top.sv` | pass | 68/68 | 710/710 | n/a | 6/6 | 23/23 |
| wrapper `rtl/I2S_Audio_apb.sv` | pass | 37/37 | 984/984 | n/a | 13/13 | 57/57 |
