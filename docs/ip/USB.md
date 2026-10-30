# USB 1.1 full-speed device: NRZI / bit stuffing / EOP on dp-dm, CRC5 / CRC16, ACK / NAK / STALL, DATA0/1 toggles, EP0 control (GET_DESCRIPTOR of the device and of configuration 0 with its interface and endpoint, GET_STATUS, SET_ADDRESS, SET/GET_CONFIGURATION, a vendor preset) and an EP1 interrupt-IN counter

Protocol IP `USB`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `USB_top` (`rtl/USB_top.sv`) |
| Register interface | APB4 slave `USB_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55310200 (code 0x5531, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 2 pass-through |

## Overview

USB 1.1 Full-Speed device controller (EP0 control + EP1 interrupt IN) Implementation scope: * PHY layer : NRZI decode/encode, bit stuffing (insert 0 after six 1s, also before EOP; remove stuffed 0 on receive), SE0(2 bit) + J(1 bit) EOP, dp/dm tri-state pads with output-enable, bus reset = SE0 held for RST_BITS bit times * Protocol  : SYNC field 8'h80 (KJKJKJKK), PID nibble-complement check, token frame addr[7]+endp[4]+CRC5(poly 0x05), data frame payload+CRC16(poly 0x8005), generated on the fly, handshakes ACK/NAK/STALL, DATA0/DATA1 toggle synchronization (retransmit on lost ACK, discard-but-ACK on duplicated data) * EP0       : standard requests GET_DESCRIPTOR(device, 18 bytes, or configuration 0: configuration + interface + EP1 IN endpoint descriptors, 25 bytes; sent in 8-byte packets, truncated to wLength), GET_STATUS (device; interface 0 and EP1 IN once configured; EP0: two zero bytes, as the device is bus powered without remote wakeup or halt), SET_ADDRESS (takes effect after the status stage), SET_CONFIGURATION (0/1), GET_CONFIGURATION; vendor request 0x40/0x01 presets the EP1 counter to {wIndex, wValue}; anything else is answered with a protocol STALL until the next SETUP * EP1       : interrupt IN, 4-byte transfer counter (incremented on ACK), NAK while unconfigured * irq       : sticky on a token / data packet with bad CRC or stuffing; cleared by the next good token addressed to the device Line rate is parameterized: BIT_CLKS clk cycles per USB bit time (>= 2).

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

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`USB_apb` has the core's parameters and passes them to `USB_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `BIT_CLKS` | int | `4` |

## Wrapper pins

Pins of `USB_apb`. Widths of the pass-through pins are at the default parameters.

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

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5531 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RXERR | token or data packet with a bad CRC5 / CRC16 or a bit-stuffing error. Held in the core until the next good token addressed to the device, so the bit is set again on every clock until then |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55310200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.USB sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.USB syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/USB_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.USB apb` | `TEST PASSED: USB_apb`, then Yosys without `ERROR` | console, `work/USB_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh USB`<br>`bash scripts/cov/run_cov.sh USB_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/USB/score.json`, `work/cov/USB_apb/score.json` |

Expected end of a step 4 run:

```
===== USB =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/USB_tb.sv`): drives `USB_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/USB_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/USB_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/USB_sva.sv`, `tb/cov/USB_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/USB_top.sv` | pass | 234/234 | 910/910 | 47/47 | 4/4 | 56/56 |
| wrapper `rtl/USB_apb.sv` | pass | 19/19 | 396/396 | n/a | 7/7 | 23/23 |
