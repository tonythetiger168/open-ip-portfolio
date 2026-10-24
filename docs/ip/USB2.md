# USB 2.0 high-speed capable device: chirp speed detection, SOF frame / microframe tracking, NRZI / bit stuffing / EOP on dp-dm, CRC5 / CRC16, ACK / NAK / STALL, DATA0/1 toggles, EP0 control (device and device_qualifier descriptors, SET_ADDRESS, SET/GET_CONFIGURATION, a vendor preset) and an EP1 interrupt-IN counter

Protocol IP `USB2`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `USB2_top` (`rtl/USB2_top.sv`) |
| Register interface | APB4 slave `USB2_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55480200 (code 0x5548, version 2.0) |
| Registers | 7 words, 0x000 to 0x018 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 2 pass-through |

## Overview

USB 2.0 High-Speed capable device controller (EP0 control + EP1 interrupt IN) Implementation scope: * Speed detection (scaled digital model of the chirp handshake): after a bus reset (SE0 >= RST_BITS bit times) the device drives chirp K for CHIRP_K clocks once the host releases SE0, then listens; three host K-J chirp pairs (each chirp >= CHIRP_MIN clocks) within CHIRP_WAIT clocks switch the device to hs_mode, otherwise it stays full speed. hs_mode is cleared by the next bus reset. The packet layer keeps the same NRZI line coding in both speeds (signalling levels not modelled). * SOF tracking: frame_no holds the last frame number, uframe counts the SOFs that repeat it (microframes 0..7 of a frame in high speed). * PHY layer : NRZI decode/encode, bit stuffing (insert 0 after six 1s, also before EOP; remove stuffed 0 on receive), SE0(2 bit) + J(1 bit) EOP, dp/dm tri-state pads with output-enable * Protocol  : SYNC field 8'h80 (KJKJKJKK), PID nibble-complement check, token frame addr[7]+endp[4]+CRC5(poly 0x05), data frame payload+CRC16(poly 0x8005), generated on the fly, handshakes ACK/NAK/STALL, DATA0/DATA1 toggle synchronization (retransmit on lost ACK, discard-but-ACK on duplicated data) * EP0       : max packet 8 (full speed) / 64 (high speed); GET_DESCRIPTOR device (18 bytes, bMaxPacketSize0 follows the speed) and device_qualifier (10 bytes), truncated to wLength; SET_ADDRESS (after the status stage), SET_CONFIGURATION(0/1), GET_CONFIGURATION; vendor request 0x40/0x01 presets the EP1 counter to {wIndex, wValue}; anything else is answered with a protocol STALL * EP1       : interrupt IN, 4-byte transfer counter (incremented on ACK), NAK while unconfigured * irq       : sticky on a token / data packet with bad CRC or stuffing; cleared by the next good token addressed to the device Line rate is parameterized: BIT_CLKS clk cycles per USB bit time (>= 2).

dp / dm (bidirectional tri-state pads: D+ needs the device pull-up, D- the host pull-down) pass through unchanged. One USB bit time is 4 PCLK clocks; the chirp handshake is a scaled digital model (device chirp K 64 PCLK, host chirps of at least 16 PCLK within 512 PCLK).
Enumeration and endpoint traffic run over the USB bus only; the registers report the speed, SOF tracking and receive errors.

## Files

| File | Content |
|---|---|
| `rtl/USB2_top.sv` | protocol core |
| `rtl/USB2_apb.sv` | APB4 register wrapper (generated) |
| `tb/USB2_tb.sv` | core testbench |
| `tb/USB2_apb_tb.sv`, `tb/apb/USB2_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/USB2_sva.sv`, `tb/cov/USB2_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/USB2.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.USB2 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.USB2 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh USB2          # core coverage (Verilator)
bash scripts/cov/run_cov.sh USB2_apb      # wrapper coverage
```

## Parameters

`USB2_apb` has the core's parameters and passes them to `USB2_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `BIT_CLKS` | int | `4` |
| `CHIRP_K` | int | `64` |
| `CHIRP_MIN` | int | `16` |
| `CHIRP_WAIT` | int | `512` |

## Wrapper pins

Pins of `USB2_apb`. Widths of the pass-through pins are at the default parameters.

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
| `dp` | inout | 1 | protocol pin, core port `dp` |
| `dm` | inout | 1 | protocol pin, core port `dm` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `dp` | inout | 1 | pin (pass-through) |
| `dm` | inout | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.RXERR |
| `hs_mode` | output | 1 | STATUS |
| `frame_no` | output | 11 | FRAME[10:0] |
| `uframe` | output | 3 | FRAME[13:11] |

## APB wrapper

`USB2_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `dp`, `dm`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55480200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Link speed |
| 0x018 | FRAME | RO | core | SOF tracking |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x01C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5548 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `hs_mode` | RO | core | high speed: set by a successful chirp handshake, cleared by the next bus reset |
| FRAME | 10:0 | `frame_no` | RO | core | frame number of the last good SOF |
| FRAME | 13:11 | `uframe` | RO | core | SOFs seen with this frame number, minus 1 (the microframe in high speed) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RXERR | token or data packet with a bad CRC5 / CRC16 or a bit-stuffing error. Held in the core until the next good token addressed to the device, so the bit is set again on every clock until then |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55480200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `hs_mode`; it needs no clearing.
5. Read FRAME (0x018) for the core's live `frame_no`, `uframe`; it needs no clearing.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/USB2_top.sv` | pass | 272/272 | 998/998 | 57/57 | 8/8 | 81/81 |
| wrapper `rtl/USB2_apb.sv` | pass | 21/21 | 430/430 | n/a | 7/7 | 27/27 |
