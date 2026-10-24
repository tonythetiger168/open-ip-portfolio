# USB Power Delivery sink (UFP): BMC on CC, SOP / HardReset ordered sets, CRC-32, GoodCRC, Source_Capabilities -> Request -> Accept -> PS_RDY negotiation picking the 9 V PDO, Reject, renegotiation, MessageIDCounter with GoodCRC timeout and retries

Protocol IP `USB_PD`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `USB_PD_top` (`rtl/USB_PD_top.sv`) |
| Register interface | APB4 slave `USB_PD_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x50440200 (code 0x5044, version 2.0) |
| Registers | 6 words, 0x000 to 0x014 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 4 pass-through |

## Overview

USB-PD (USB Power Delivery) UFP / sink-side controller Implementation scope: * CC-line BMC (biphase-mark coding) encoder/decoder, simplified to 1 bit/clk symbol rate: '1' = toggle line level at UI boundary, '0' = hold level (bi-phase-space). Decoder = toggle detect. * Ordered sets (5-bit K-codes, sent MSB first): K_SYNC1 = 5'b11000 (Sync-1), K_SYNC2 = 5'b10001 (Sync-2) K_RST1  = 5'b00111 (RST-1),  K_RST2  = 5'b11001 (RST-2) K_EOP   = 5'b01101 (EOP) SOP       = {SYNC1,SYNC1,SYNC1,SYNC2}  (packed 20'hC6311, annotated as 28'h00C_6311 when zero-extended to 28 bits) HardReset = {RST1,RST1,RST1,RST2}      (SOP'-class reset ordered set) * Message frame: preamble(16 alt bits) + SOP + 16-bit header {ext[15], numobj[14:12], msgid[11:9], powerrole[8], specrev[7:6], datarole[5], msgtype[4:0]} + up to 2 x 32-bit data objects + CRC-32 (poly 0x04C11DB7 reflected -> 32'hEDB8_8320, init/xorout all-ones, good-frame residue 32'hDEBB_20E3) + EOP. * Policy engine (UFP): Source_Capabilities (fixed-supply PDOs; the 9 V PDO is chosen when offered as object 2, else 5 V object 1) -> GoodCRC -> Request -> GoodCRC -> Accept -> GoodCRC -> PS_RDY -> GoodCRC -> vbus_ok=1. Reject returns to waiting for capabilities; a new Source_Capabilities in the contract renegotiates. * The Request carries the MessageIDCounter, which advances when its GoodCRC arrives. Without that GoodCRC within GCRC_TO clocks the Request is retried N_RETRY times, then the engine gives up (irq) and waits for capabilities again. A GoodCRC with another id sets irq. * Every valid received non-GoodCRC message is answered with GoodCRC (echoing rx msgid). Bad CRC / framing / numobj>2 -> no GoodCRC + irq. * irq is a level: set by an error, cleared by the next good message. * HardReset ordered set detected any time receiver is hunting sync: policy engine + TX abort back to initial state, vbus_ok cleared, MessageIDCounter reset.

cc_rxd (CC line level in), cc_txd / cc_tx_en (BMC drive and its enable) and vbus_ok pass through unchanged. One BMC unit interval is one PCLK.
Messages travel on the CC wire only; the registers report the contract state and protocol errors.

## Files

| File | Content |
|---|---|
| `rtl/USB_PD_top.sv` | protocol core |
| `rtl/USB_PD_apb.sv` | APB4 register wrapper (generated) |
| `tb/USB_PD_tb.sv` | core testbench |
| `tb/USB_PD_apb_tb.sv`, `tb/apb/USB_PD_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/USB_PD_sva.sv`, `tb/cov/USB_PD_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/USB_PD.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.USB_PD sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.USB_PD apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh USB_PD          # core coverage (Verilator)
bash scripts/cov/run_cov.sh USB_PD_apb      # wrapper coverage
```

## Parameters

`USB_PD_apb` has the core's parameters and passes them to `USB_PD_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `GCRC_TO` | int | `200` |
| `N_RETRY` | int | `2` |

## Wrapper pins

Pins of `USB_PD_apb`. Widths of the pass-through pins are at the default parameters.

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
| `cc_rxd` | input | 1 | protocol pin, core port `cc_rxd` |
| `cc_txd` | output | 1 | protocol pin, core port `cc_txd` |
| `cc_tx_en` | output | 1 | protocol pin, core port `cc_tx_en` |
| `vbus_ok` | output | 1 | protocol pin, core port `vbus_ok` (also read in a register) |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cc_rxd` | input | 1 | pin (pass-through) |
| `cc_txd` | output | 1 | pin (pass-through) |
| `cc_tx_en` | output | 1 | pin (pass-through) |
| `vbus_ok` | output | 1 | STATUS |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`USB_PD_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `cc_rxd`, `cc_txd`, `cc_tx_en`, `vbus_ok`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x50440200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Contract state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5044 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `vbus_ok` | RO | core | explicit contract established (PS_RDY received); same as the vbus_ok pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | bad CRC, bad EOP or more than two objects (no GoodCRC sent), a GoodCRC with the wrong MessageID, or a Request given up after its retries. Held in the core until the next good message or a HardReset, so the bit is set again on every clock until then |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x50440200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `vbus_ok`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/USB_PD_top.sv` | pass | 119/119 | 650/650 | 42/42 | 5/5 | 67/67 |
| wrapper `rtl/USB_PD_apb.sv` | pass | 20/20 | 404/404 | n/a | 7/7 | 25/25 |
