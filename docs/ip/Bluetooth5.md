# Bluetooth 5 (BLE) link-layer peripheral on a 1 bit per clock baseband: ADV_IND from a host payload, SCAN_REQ / SCAN_RSP, CONNECT_REQ, connection events with SN / NESN acknowledgement, peripheral latency and supervision timeout

Protocol IP `Bluetooth5`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Bluetooth5_top` (`rtl/Bluetooth5_top.sv`) |
| Register interface | APB4 slave `Bluetooth5_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x42540200 (code 0x4254, version 2.0) |
| Registers | 24 words, 0x000 to 0x05C |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CFG (18 words) |
| Protocol pins | 3 pass-through |

## Overview

Bluetooth 5 (BLE) link layer peripheral -- synthesizable baseband model Implementation scope (simplified, NOT the full BLE LL specification):

- Air interface: 1 bit/clk, LSB-first per byte (BLE over-the-air order).
Preamble: 8'hAA when the access address LSB is 0, else 8'h55.
- Advertising channel 37: preamble + AccessAddress 32'h8E89BED6 +
PDU header {rfu[3:0],type[3:0]}{len[7:0]} + payload + CRC24 (serial
LFSR, poly 24'h00065B, init 24'h555555, sent register bit 0 first).
- Data whitening: LFSR poly x^7+x^4+1 (out = l[6], l <<= l[6]^l[3]),
seed = channel index | 1 (adv ch37 -> 7'h25); applied to everything
after the access address (header + payload + CRC).
- ADV_IND every ADV_INTV clks while advertising and adv_en (payload =
16x8 host-writable register file, read while it is sent).
SCAN_REQ (scan_en) -> SCAN_RSP (payload[i] = 8'h53+i).
- CONNECT_REQ with the simplified 15-byte LLData (AA[4], CRCInit[3],
interval[2], latency[2], timeout[2], hop[1], chan[1]) -> CONNECTION
state on the new access address. Another length -> irq, ignored.
- Connection events every `interval` clks. Channel selection (CSA#1
without channel-map remapping): the first event uses chan mod 37,
each later event (channel + hop) mod 37.
- Data channel PDU: header {rfu[2:0],md,sn,nesn,llid[1:0]}{len[7:0]}
+ payload (<= 16 B) + CRC24 (init = CRCInit). SN / NESN as in the
spec; every valid central PDU gets an empty-PDU response (ack).
An event without central traffic counts as missed; after more than
`latency` missed events in a row the peripheral sends an empty PDU
each event; `timeout` (events, 0 = off) missed events in a row drop
the connection (back to advertising, irq).
- irq (1-clk pulse): bad CRC24, unknown advertising PDU type, reserved
LLID, length > 16, CONNECT_REQ of the wrong length, supervision
timeout.

rxd and txd are the baseband pins (1 bit per PCLK, LSB first); they pass through unchanged. tx_act also drives a pin.
The core's configuration port has no read side, so PAY0..PAY15, ADV_CTRL and SCAN_CTRL are write only and read as 0. A write must set all four byte strobes (the low 8 bits are used); a partial-strobe write gets PSLVERR and is dropped. The payload is read while ADV_IND is sent, so a write during a packet can change it mid-way.
Simplified link layer (see rtl/Bluetooth5_top.sv): advertising channel 37 only, the 15-byte CONNECT_REQ, channel selection algorithm #1 without a channel map.

## Files

| File | Content |
|---|---|
| `rtl/Bluetooth5_top.sv` | protocol core |
| `rtl/Bluetooth5_apb.sv` | APB4 register wrapper (generated) |
| `tb/Bluetooth5_tb.sv` | core testbench |
| `tb/Bluetooth5_apb_tb.sv`, `tb/apb/Bluetooth5_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Bluetooth5_sva.sv`, `tb/cov/Bluetooth5_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Bluetooth5.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.Bluetooth5 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.Bluetooth5 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh Bluetooth5          # core coverage (Verilator)
bash scripts/cov/run_cov.sh Bluetooth5_apb      # wrapper coverage
```

## Parameters

`Bluetooth5_apb` has the core's parameters and passes them to `Bluetooth5_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `ADV_INTV` | int | `1200` |

## Wrapper pins

Pins of `Bluetooth5_apb`. Widths of the pass-through pins are at the default parameters.

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
| `rxd` | input | 1 | protocol pin, core port `rxd` |
| `txd` | output | 1 | protocol pin, core port `txd` |
| `tx_act` | output | 1 | protocol pin, core port `tx_act` (also read in a register) |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rxd` | input | 1 | pin (pass-through) |
| `txd` | output | 1 | pin (pass-through) |
| `tx_act` | output | 1 | STATUS |
| `cfg_we` | input | 1 | write to a CFG word |
| `cfg_addr` | input | 5 | CFG word index |
| `cfg_wdata` | input | 8 | CFG write data |
| `irq` | output | 1 | IRQ_STATUS.ERROR |

## APB wrapper

`Bluetooth5_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxd`, `txd`, `tx_act`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x42540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | PAY0 | WO (core) | core | ADV_IND payload byte 0 (write only; reset 0xB0) |
| 0x018 | PAY1 | WO (core) | core | ADV_IND payload byte 1 (write only; reset 0xB1) |
| 0x01C | PAY2 | WO (core) | core | ADV_IND payload byte 2 (write only; reset 0xB2) |
| 0x020 | PAY3 | WO (core) | core | ADV_IND payload byte 3 (write only; reset 0xB3) |
| 0x024 | PAY4 | WO (core) | core | ADV_IND payload byte 4 (write only; reset 0xB4) |
| 0x028 | PAY5 | WO (core) | core | ADV_IND payload byte 5 (write only; reset 0xB5) |
| 0x02C | PAY6 | WO (core) | core | ADV_IND payload byte 6 (write only; reset 0xB6) |
| 0x030 | PAY7 | WO (core) | core | ADV_IND payload byte 7 (write only; reset 0xB7) |
| 0x034 | PAY8 | WO (core) | core | ADV_IND payload byte 8 (write only; reset 0xB8) |
| 0x038 | PAY9 | WO (core) | core | ADV_IND payload byte 9 (write only; reset 0xB9) |
| 0x03C | PAY10 | WO (core) | core | ADV_IND payload byte 10 (write only; reset 0xBA) |
| 0x040 | PAY11 | WO (core) | core | ADV_IND payload byte 11 (write only; reset 0xBB) |
| 0x044 | PAY12 | WO (core) | core | ADV_IND payload byte 12 (write only; reset 0xBC) |
| 0x048 | PAY13 | WO (core) | core | ADV_IND payload byte 13 (write only; reset 0xBD) |
| 0x04C | PAY14 | WO (core) | core | ADV_IND payload byte 14 (write only; reset 0xBE) |
| 0x050 | PAY15 | WO (core) | core | ADV_IND payload byte 15 (write only; reset 0xBF) |
| 0x054 | ADV_CTRL | WO (core) | core | bit 0 adv_en: send ADV_IND every ADV_INTV clocks while advertising (write only; reset 1) |
| 0x058 | SCAN_CTRL | WO (core) | core | bit 0 scan_en: answer SCAN_REQ with SCAN_RSP (write only; reset 1) |
| 0x05C | STATUS | RO | core | Baseband state, as driven on the pin |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x060 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4254 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| PAY0 | 7:0 | core register | WO (core) | core | written at core register 0 |
| PAY1 | 7:0 | core register | WO (core) | core | written at core register 1 |
| PAY2 | 7:0 | core register | WO (core) | core | written at core register 2 |
| PAY3 | 7:0 | core register | WO (core) | core | written at core register 3 |
| PAY4 | 7:0 | core register | WO (core) | core | written at core register 4 |
| PAY5 | 7:0 | core register | WO (core) | core | written at core register 5 |
| PAY6 | 7:0 | core register | WO (core) | core | written at core register 6 |
| PAY7 | 7:0 | core register | WO (core) | core | written at core register 7 |
| PAY8 | 7:0 | core register | WO (core) | core | written at core register 8 |
| PAY9 | 7:0 | core register | WO (core) | core | written at core register 9 |
| PAY10 | 7:0 | core register | WO (core) | core | written at core register 10 |
| PAY11 | 7:0 | core register | WO (core) | core | written at core register 11 |
| PAY12 | 7:0 | core register | WO (core) | core | written at core register 12 |
| PAY13 | 7:0 | core register | WO (core) | core | written at core register 13 |
| PAY14 | 7:0 | core register | WO (core) | core | written at core register 14 |
| PAY15 | 7:0 | core register | WO (core) | core | written at core register 15 |
| ADV_CTRL | 7:0 | core register | WO (core) | core | written at core register 16 |
| SCAN_CTRL | 7:0 | core register | WO (core) | core | written at core register 17 |
| STATUS | 0 | `tx_act` | RO | core | high while a packet is being sent on txd |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERROR | a bad CRC24, an unknown advertising PDU type, a reserved LLID, a length above 16, a CONNECT_REQ of the wrong length, or a supervision timeout (back to advertising) |

### Core register port

The CFG words reach the core's own register port. A write to one pulses `cfg_we` for one clock with `cfg_addr` (the core register) and `cfg_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. 

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x42540200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CFG words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. Read STATUS (0x05C) for the core's live `tx_act`; it needs no clearing.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Bluetooth5_top.sv` | pass | 140/140 | 1316/1316 | 24/24 | 7/7 | 24/24 |
| wrapper `rtl/Bluetooth5_apb.sv` | pass | 20/20 | 456/456 | n/a | 9/9 | 62/62 |
