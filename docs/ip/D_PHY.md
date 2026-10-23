# MIPI D-PHY lane pair (clock lane + data lane): HS bursts (SoT, B8 sync, bytes, EoT), escape mode (LPDT, ULPS, trigger), and the same lane decoded on the receive side

Protocol IP `D_PHY`, version 2.0. Apache-2.0.

## Overview

MIPI D-PHY lane-pair (clock lane + data lane) TX with same-lane RX decoder Implementation scope: * LP mode line levels on data lane (lp_p/lp_n): LP-11 STOP, LP-01 HS-Request, LP-00 Sync/Bridge, LP-10 used by escape entry/exit. Simplification: each LP state / line bit lasts exactly 1 clk cycle. * HS mode: SoT sequence LP-11 -> LP-01 -> LP-00 -> HS-0, sync byte 8'hB8 sent LSB-first (wire pattern 00011101), payload bytes LSB-first on differential hs_p/hs_n, EoT = last payload bit inverted for one bit time + one bit of the last level (HS-0/1), then LP-11. * Escape mode: entry LP-10 -> LP-00 -> LP-01 -> LP-00, then 8-bit escape command LSB-first (LP-10 = '1', LP-00 = '0'; the real spaced-one-hot encoding is simplified to 1 bit/clk, see MIPI D-PHY spec 8.4). Commands: LPDT 8'h87 (followed by LPDT data bytes, same 1 bit/clk encoding, LP-01 space marks end of data), ULPS 8'h78 (lines held LP-00 until esc_release), Trigger-Reset 8'h46 (4-clk Mark-1 LP-00 then exit). Exit: [LP-01 space for LPDT] -> LP-10 -> LP-11. * Requests are latched: an hs_req / esc_req pulse that arrives while the lane is busy is served from the next LP-11 STOP (HS first); a second esc_req before that replaces the pending command. * Clock lane follows the data-lane HS entry (LP-01, LP-00) and toggles a differential HS clock during the HS burst (real PHY starts the HS clock earlier; simplified). * RX side decodes the same lane (TB wires TX pads back to RX inputs): HS sync check + payload byte reassembly, escape entry/command/LPDT decode, ULPS detect. Protocol violations (bad HS sync, invalid HS differential level, unknown escape command, illegal LP sequence) raise sticky irq.


d_lp_p / d_lp_n / d_hs_p / d_hs_n / d_hs_en (data lane), c_lp_p / c_lp_n / c_hs_p / c_hs_n / c_hs_en (clock lane) and r_lp_p / r_lp_n / r_hs_p / r_hs_n / r_hs_en (the receive lane) pass through unchanged. Each LP state and each HS or LPDT bit lasts one PCLK.
A byte takes eight clocks on the lane: HS_TX and LPDT must be written, and RX read, at that rate (one holding register each; a byte arriving with RX full is dropped, RX_OVF). The escape command encoding is simplified to one bit per clock (LP-10 one, LP-00 zero).

## Files

| File | Content |
|---|---|
| `rtl/D_PHY_top.sv` | protocol core |
| `rtl/D_PHY_apb.sv` | APB4 register wrapper (generated) |
| `tb/D_PHY_tb.sv` | core testbench |
| `tb/D_PHY_apb_tb.sv`, `tb/apb/D_PHY_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/D_PHY_sva.sv`, `tb/cov/D_PHY_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/D_PHY.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.D_PHY sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.D_PHY apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh D_PHY          # core coverage (Verilator)
bash scripts/cov/run_cov.sh D_PHY_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `irq` | output | 1 | IRQ_STATUS.ERROR |
| `irq_clear` | input | 1 | CMD[3:3] |
| `hs_req` | input | 1 | CMD[0:0] |
| `hs_tx_data` | input | 8 | HS_TX[7:0] |
| `hs_tx_valid` | input | 1 | HS_TX commit / FLAGS |
| `hs_tx_ready` | output | 1 | HS_TX handshake |
| `hs_tx_done` | output | 1 | IRQ_STATUS.HS_SENT |
| `esc_req` | input | 1 | CMD[1:1] |
| `esc_cmd` | input | 8 | ESC[7:0] |
| `esc_release` | input | 1 | CMD[2:2] |
| `lpdt_data` | input | 8 | LPDT[7:0] |
| `lpdt_valid` | input | 1 | LPDT commit / FLAGS |
| `lpdt_last` | input | 1 | LPDT[8:8] |
| `lpdt_ready` | output | 1 | LPDT handshake |
| `esc_done` | output | 1 | IRQ_STATUS.ESC_DONE |
| `d_lp_p` | output | 1 | pin (pass-through) |
| `d_lp_n` | output | 1 | pin (pass-through) |
| `d_hs_p` | output | 1 | pin (pass-through) |
| `d_hs_n` | output | 1 | pin (pass-through) |
| `d_hs_en` | output | 1 | pin (pass-through) |
| `c_lp_p` | output | 1 | pin (pass-through) |
| `c_lp_n` | output | 1 | pin (pass-through) |
| `c_hs_p` | output | 1 | pin (pass-through) |
| `c_hs_n` | output | 1 | pin (pass-through) |
| `c_hs_en` | output | 1 | pin (pass-through) |
| `r_lp_p` | input | 1 | pin (pass-through) |
| `r_lp_n` | input | 1 | pin (pass-through) |
| `r_hs_p` | input | 1 | pin (pass-through) |
| `r_hs_n` | input | 1 | pin (pass-through) |
| `r_hs_en` | input | 1 | pin (pass-through) |
| `rx_hs_active` | output | 1 | STATUS[0:0] |
| `rx_data` | output | 8 | RX[7:0] |
| `rx_data_valid` | output | 1 | RX capture |
| `rx_esc_cmd` | output | 8 | RX_ESC[7:0] |
| `rx_esc_valid` | output | 1 | RX_ESC capture |
| `rx_ulps` | output | 1 | STATUS[1:1] |

## APB wrapper

`D_PHY_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `d_lp_p`, `d_lp_n`, `d_hs_p`, `d_hs_n`, `d_hs_en`, `c_lp_p`, `c_lp_n`, `c_hs_p`, `c_hs_n`, `c_hs_en`, `r_lp_p`, `r_lp_n`, `r_hs_p`, `r_hs_n`, `r_hs_en`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD | WO (pulse) | 0x00000000 | Lane requests (latched by the core and served from the next LP-11 stop, HS first) |
| 0x018 | ESC | RW | 0x00000000 | Escape command |
| 0x01C | HS_TX | RW | 0x00000000 | HS payload byte; one byte every eight clocks, and the burst ends (EoT) when the next byte is not there in time |
| 0x020 | LPDT | RW | 0x00000000 | LPDT byte; the escape ends after a byte with last set, or when the next byte is not there in time |
| 0x024 | RX | RO (pop) | 0x00000000 | Byte decoded from the receive lane (HS payload or LPDT); reading RX frees it |
| 0x028 | RX_ESC | RO (pop) | 0x00000000 | Escape command decoded from the receive lane; reading RX_ESC frees it |
| 0x02C | STATUS | RO | 0x00000000 | Receiver state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4450 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CMD | 0 | `hs_req` | write 1: request an HS burst; its bytes come from HS_TX |
| CMD | 1 | `esc_req` | write 1: request escape mode with ESC.esc_cmd (a second request before it is served replaces the command) |
| CMD | 2 | `esc_release` | write 1: leave ULPS |
| CMD | 3 | `irq_clear` | write 1: clear the receiver's sticky error |
| ESC | 7:0 | `esc_cmd` | 0x87 LPDT (bytes from LPDT), 0x78 ULPS, 0x46 trigger reset; taken by CMD.esc_req |
| HS_TX | 7:0 | `hs_tx_data` | HS payload byte; one byte every eight clocks, and the burst ends (EoT) when the next byte is not there in time |
| LPDT | 7:0 | `lpdt_data` | LPDT payload byte |
| LPDT | 8 | `lpdt_last` | last byte |
| RX | 7:0 | `rx_data` | Byte decoded from the receive lane (HS payload or LPDT); reading RX frees it |
| RX_ESC | 7:0 | `rx_esc_cmd` | Escape command decoded from the receive lane; reading RX_ESC frees it |
| STATUS | 0 | `rx_hs_active` | an HS burst is being decoded |
| STATUS | 1 | `rx_ulps` | the receive lane is in ULPS |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | HS_SENT | an HS burst finished and the lane is back in LP-11 |
| 1 | ESC_DONE | an escape sequence finished (LP-11) |
| 2 | ERROR | the receiver saw a protocol violation (bad HS sync, invalid HS level, unknown escape command, illegal LP sequence); sticky in the core, so the bit is set again on every clock until CMD.irq_clear |
| 3 | HS_TX_DONE | HS_TX beat accepted by the core |
| 4 | HS_TX_OVF | write to HS_TX while full (dropped) |
| 5 | LPDT_DONE | LPDT beat accepted by the core |
| 6 | LPDT_OVF | write to LPDT while full (dropped) |
| 7 | RX_AVAIL | RX captured a beat |
| 8 | RX_OVF | beat dropped, RX was full |
| 9 | RX_ESC_AVAIL | RX_ESC captured a beat |
| 10 | RX_ESC_OVF | beat dropped, RX_ESC was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | HS_TX_FULL | HS_TX holds a beat the core has not taken |
| 1 | LPDT_FULL | LPDT holds a beat the core has not taken |
| 2 | RX_AVAIL | RX holds an unread beat |
| 3 | RX_ESC_AVAIL | RX_ESC holds an unread beat |

### Streams

* **HS_TX** feeds `hs_tx_data`/`hs_tx_valid`. Writing HS_TX commits the beat: FLAGS.HS_TX_FULL is set and `hs_tx_valid` stays high until the core's `hs_tx_ready`; then HS_TX_DONE is set. A write while full is dropped and sets HS_TX_OVF.
* **LPDT** feeds `lpdt_data`, `lpdt_last`/`lpdt_valid`. Writing LPDT commits the beat: FLAGS.LPDT_FULL is set and `lpdt_valid` stays high until the core's `lpdt_ready`; then LPDT_DONE is set. A write while full is dropped and sets LPDT_OVF.
* **RX** captures `rx_data` when `rx_data_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.
* **RX_ESC** captures `rx_esc_cmd` when `rx_esc_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_ESC_AVAIL. Reading RX_ESC pops it. A beat that arrives while the register is full is dropped and sets RX_ESC_OVF.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/D_PHY_top.sv` | pass | 157/157 | 282/282 | 89/89 | 15/15 | 38/38 |
| wrapper `rtl/D_PHY_apb.sv` | pass | 46/46 | 712/712 | n/a | 17/17 | 97/97 |
