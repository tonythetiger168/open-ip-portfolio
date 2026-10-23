# USB 1.1 full-speed device: NRZI / bit stuffing / EOP on dp-dm, CRC5 / CRC16, ACK / NAK / STALL, DATA0/1 toggles, EP0 control (GET_DESCRIPTOR, SET_ADDRESS, SET/GET_CONFIGURATION, a vendor preset) and an EP1 interrupt-IN counter

Protocol IP `USB`, version 2.0. Apache-2.0.

## Overview

USB 1.1 Full-Speed device controller (EP0 control + EP1 interrupt IN) Implementation scope: * PHY layer : NRZI decode/encode, bit stuffing (insert 0 after six 1s, also before EOP; remove stuffed 0 on receive), SE0(2 bit) + J(1 bit) EOP, dp/dm tri-state pads with output-enable, bus reset = SE0 held for RST_BITS bit times * Protocol  : SYNC field 8'h80 (KJKJKJKK), PID nibble-complement check, token frame addr[7]+endp[4]+CRC5(poly 0x05), data frame payload+CRC16(poly 0x8005), generated on the fly, handshakes ACK/NAK/STALL, DATA0/DATA1 toggle synchronization (retransmit on lost ACK, discard-but-ACK on duplicated data) * EP0       : standard requests GET_DESCRIPTOR(device, 18 bytes, sent in 8-byte packets, truncated to wLength), SET_ADDRESS (takes effect after the status stage), SET_CONFIGURATION(0/1), GET_CONFIGURATION; vendor request 0x40/0x01 presets the EP1 counter to {wIndex, wValue}; anything else is answered with a protocol STALL until the next SETUP * EP1       : interrupt IN, 4-byte transfer counter (incremented on ACK), NAK while unconfigured * irq       : sticky on a token / data packet with bad CRC or stuffing; cleared by the next good token addressed to the device Line rate is parameterized: BIT_CLKS clk cycles per USB bit time (>= 2).


dp / dm (bidirectional tri-state pads: D+ needs the device pull-up, D- the host pull-down) pass through unchanged. One USB bit time is 4 PCLK clocks.
Enumeration and endpoint traffic run over the USB bus only; the registers report receive errors.

## Files

| File | Content |
|---|---|
| `rtl/USB_top.sv` | protocol core |
| `rtl/USB_apb.sv` | APB4 register wrapper (generated) |
| `tb/USB_tb.sv` | core testbench |
| `tb/USB_apb_tb.sv`, `tb/apb/USB_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/USB_sva.sv`, `tb/cov/USB_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/USB.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.USB sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.USB apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh USB          # core coverage (Verilator)
bash scripts/cov/run_cov.sh USB_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `dp` | inout | 1 | pin (pass-through) |
| `dm` | inout | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.RXERR |

## APB wrapper

`USB_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `dp`, `dm`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55310200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5531 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RXERR | token or data packet with a bad CRC5 / CRC16 or a bit-stuffing error. Held in the core until the next good token addressed to the device, so the bit is set again on every clock until then |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/USB_top.sv` | pass | 234/234 | 910/910 | 47/47 | 4/4 | 31/31 |
| wrapper `rtl/USB_apb.sv` | pass | 19/19 | 396/396 | n/a | 7/7 | 23/23 |
