# I2S audio transceiver: TX and RX at once, master (bclk / wclk generated) or slave, I2S / left-justified / right-justified, 16 / 24 / 32-bit samples in 32-bit slots

Protocol IP `I2S_Audio`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `I2S_Audio_top` (`rtl/I2S_Audio_top.sv`) |
| Register interface | APB4 slave `I2S_Audio_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x49410200 (code 0x4941, version 2.0) |
| Registers | 10 words, 0x000 to 0x024 |
| Interrupts | 5 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 6 pass-through |

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

## Parameters

`I2S_Audio_apb` has the core's parameters and passes them to `I2S_Audio_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |
| `MCLK_DIV` | int | `4` |

## Wrapper pins

Pins of `I2S_Audio_apb`. Widths of the pass-through pins are at the default parameters.

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
| `bclk_out` | output | 1 | protocol pin, core port `bclk_out` |
| `wclk_out` | output | 1 | protocol pin, core port `wclk_out` |
| `bclk_in` | input | 1 | protocol pin, core port `bclk_in` |
| `wclk_in` | input | 1 | protocol pin, core port `wclk_in` |
| `sd_out` | output | 1 | protocol pin, core port `sd_out` |
| `sd_in` | input | 1 | protocol pin, core port `sd_in` |

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

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4941 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 0 | `cfg_master` | RW | 0x1 | 1: master (bclk_out = PCLK / 4, wclk_out = bclk / 64), 0: slave (bclk_in / wclk_in, synchronous to PCLK) |
| CFG | 2:1 | `cfg_fmt` | RW | 0x0 | 0 I2S, 1 left-justified, 2 right-justified |
| CFG | 4:3 | `cfg_depth` | RW | 0x2 | 0 16-bit, 1 24-bit, 2 / 3 32-bit |
| TX0 | 31:0 | `tx_l` | RW | 0x0 | left sample |
| TX1 | 31:0 | `tx_r` | RW | 0x0 | right sample |
| RX0 | 31:0 | `rx_l` | RO (pop) | 0x0 | left sample |
| RX1 | 31:0 | `rx_r` | RO (pop) | 0x0 | right sample |

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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x49410200.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits (RX_AVAIL may be set as soon as reset ends).
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x018) then TX1 (0x01C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x020) then RX1 (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 3) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/I2S_Audio_top.sv` | pass | 68/68 | 710/710 | n/a | 6/6 | 93/93 |
| wrapper `rtl/I2S_Audio_apb.sv` | pass | 37/37 | 984/984 | n/a | 13/13 | 57/57 |
