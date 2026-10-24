# MIPI D-PHY lane pair (clock lane + data lane): HS bursts (SoT, B8 sync, bytes, EoT), escape mode (LPDT, ULPS, trigger), and the same lane decoded on the receive side

Protocol IP `D_PHY`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `D_PHY_top` (`rtl/D_PHY_top.sv`) |
| Register interface | APB4 slave `D_PHY_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x44500200 (code 0x4450, version 2.0) |
| Registers | 12 words, 0x000 to 0x02C |
| Interrupts | 11 sources into one level-high `irq` |
| Data streams | HS_TX (to the core), LPDT (to the core), RX (from the core), RX_ESC (from the core) |
| Protocol pins | 15 pass-through |

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

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `D_PHY_apb`. Widths of the pass-through pins are at the default parameters.

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
| `d_lp_p` | output | 1 | protocol pin, core port `d_lp_p` |
| `d_lp_n` | output | 1 | protocol pin, core port `d_lp_n` |
| `d_hs_p` | output | 1 | protocol pin, core port `d_hs_p` |
| `d_hs_n` | output | 1 | protocol pin, core port `d_hs_n` |
| `d_hs_en` | output | 1 | protocol pin, core port `d_hs_en` |
| `c_lp_p` | output | 1 | protocol pin, core port `c_lp_p` |
| `c_lp_n` | output | 1 | protocol pin, core port `c_lp_n` |
| `c_hs_p` | output | 1 | protocol pin, core port `c_hs_p` |
| `c_hs_n` | output | 1 | protocol pin, core port `c_hs_n` |
| `c_hs_en` | output | 1 | protocol pin, core port `c_hs_en` |
| `r_lp_p` | input | 1 | protocol pin, core port `r_lp_p` |
| `r_lp_n` | input | 1 | protocol pin, core port `r_lp_n` |
| `r_hs_p` | input | 1 | protocol pin, core port `r_hs_p` |
| `r_hs_n` | input | 1 | protocol pin, core port `r_hs_n` |
| `r_hs_en` | input | 1 | protocol pin, core port `r_hs_en` |

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
| 0x02C | STATUS | RO | core | Receiver state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4450 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 10:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 10:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 3:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD | 0 | `hs_req` | WO (pulse) | 0x0 | write 1: request an HS burst; its bytes come from HS_TX |
| CMD | 1 | `esc_req` | WO (pulse) | 0x0 | write 1: request escape mode with ESC.esc_cmd (a second request before it is served replaces the command) |
| CMD | 2 | `esc_release` | WO (pulse) | 0x0 | write 1: leave ULPS |
| CMD | 3 | `irq_clear` | WO (pulse) | 0x0 | write 1: clear the receiver's sticky error |
| ESC | 7:0 | `esc_cmd` | RW | 0x0 | 0x87 LPDT (bytes from LPDT), 0x78 ULPS, 0x46 trigger reset; taken by CMD.esc_req |
| HS_TX | 7:0 | `hs_tx_data` | RW | 0x0 | HS payload byte; one byte every eight clocks, and the burst ends (EoT) when the next byte is not there in time |
| LPDT | 7:0 | `lpdt_data` | RW | 0x0 | LPDT payload byte |
| LPDT | 8 | `lpdt_last` | RW | 0x0 | last byte |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | Byte decoded from the receive lane (HS payload or LPDT); reading RX frees it |
| RX_ESC | 7:0 | `rx_esc_cmd` | RO (pop) | 0x0 | Escape command decoded from the receive lane; reading RX_ESC frees it |
| STATUS | 0 | `rx_hs_active` | RO | core | an HS burst is being decoded |
| STATUS | 1 | `rx_ulps` | RO | core | the receive lane is in ULPS |

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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44500200.
2. Write 0x7FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write ESC (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7FF enables all).
5. To issue a command, write 1 to `hs_req` (CMD bit 0), `esc_req` (CMD bit 1), `esc_release` (CMD bit 2), `irq_clear` (CMD bit 3) at 0x014; the core sees a one-clock pulse, and the register reads 0.
6. To send on HS_TX: wait until FLAGS.HS_TX_FULL (bit 0) is 0, or for IRQ HS_TX_DONE, then write HS_TX (0x01C). The last write commits the beat. HS_TX_OVF means a write came while the register was full and was dropped.
7. To send on LPDT: wait until FLAGS.LPDT_FULL (bit 1) is 0, or for IRQ LPDT_DONE, then write LPDT (0x020). The last write commits the beat. LPDT_OVF means a write came while the register was full and was dropped.
8. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 2), then read RX (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 7) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
9. To receive on RX_ESC: wait for IRQ RX_ESC_AVAIL or FLAGS.RX_ESC_AVAIL (bit 3), then read RX_ESC (0x028). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_ESC_AVAIL (bit 9) to clear it. Read each beat before the next arrives, or it is dropped and RX_ESC_OVF is set.
10. Read STATUS (0x02C) for the core's live `rx_hs_active`, `rx_ulps`; it needs no clearing.
11. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/D_PHY_top.sv` | pass | 157/157 | 282/282 | 89/89 | 15/15 | 38/38 |
| wrapper `rtl/D_PHY_apb.sv` | pass | 46/46 | 712/712 | n/a | 17/17 | 97/97 |
