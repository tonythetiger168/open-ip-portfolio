# SoundWire-style two-wire audio bus interface (manager or peripheral) with control commands and one data port each way

Protocol IP `MIPI_SoundWire`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `MIPI_SoundWire_top` (`rtl/MIPI_SoundWire_top.sv`) |
| Register interface | APB4 slave `MIPI_SoundWire_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x534E0200 (code 0x534E, version 2.0) |
| Registers | 11 words, 0x000 to 0x028 |
| Interrupts | 11 sources into one level-high `irq` |
| Data streams | CMD (to the core), RSP (from the core), TX (to the core), RX (from the core) |
| Protocol pins | 11 pass-through |

## Overview

MIPI_SoundWire_top v2.0: SoundWire-style two-wire audio bus interface (manager or peripheral) with control commands and one data port each way

- CLOCK from the manager, DATA multi-drop, double data rate: every CLOCK
edge ends one bit and starts the next (a bit lasts cfg_div + 1 PCLK on
the manager, cfg_div >= 11). NRZI: a 1 toggles DATA, a 0 keeps it. A
bus keeper holds DATA between drivers. Bits are sampled at the edge
that ends them (a peripheral sees CLOCK through two flops). The
manager drives its bits from mid-bit to the end of the bit; a
peripheral drives from two PCLK after it sees the starting edge to
two PCLK after it sees the ending edge.
- Frame: 48 rows x cfg_cols columns (2, 4, 8, 16) sent row by row.
Column 0 carries the 48-bit control word, MSB in row 0:
[47:45] opcode (000 PING, 010 READ, 011 WRITE), [44:41] device,
[40:25] register address (PING: two status bits per device 1..8,
device 1 in [40:39]), [24:17] data (READ: driven by the device),
[16] parity (even, over [47:25], and [24:17] for a WRITE), [15] ACK
and [14] NAK (driven by the addressed device), [13:6] static sync
8'hB1, [5:2] dynamic sync (PRBS x^4 + x^3 + 1), [1:0] 0.
- Manager: one host command per frame (cmd_*), a PING otherwise;
rsp_* after the ACK / NAK bits of a host command; ping_status after
every PING.
- Peripheral (device number cfg_dev): finds the static sync, locks after
seeing it in two frames in a row, then checks static and dynamic sync
every frame and drops the lock after two bad frames in a row (lost_sync);
the expected dynamic sync steps on over a bad frame.
READ: reg_re with reg_addr, reg_rdata (combinational) sent in the data
bits; WRITE: reg_we once the parity bit checks; ACK, or NAK and
par_err on bad parity. PING: dev_status in its slot (devices 1..8).
- Data port: column cfg_tx_col (rows 0..31) carries tx_data, MSB first,
taken at the column's first bit (tx_underrun and zeros without
tx_valid); column cfg_rx_col is delivered as rx_data after row 31.
A column of 0 or not below the column count is off. The manager's
columns run from the start; a peripheral's while locked.
Not implemented: bank switching and other frame shapes, multiple data
ports and sample intervals, interrupts / alerts beyond PING status,
enumeration, clock stop.

sw_clk_o / sw_clk_oe / sw_clk_i and sw_dat_o / sw_dat_oe / sw_dat_i are the bus pins (CLOCK from the manager; DATA multi-drop with a bus keeper); all pass through unchanged.
reg_we / reg_re / reg_addr / reg_wdata and reg_rdata are the peripheral's register interface; they pass through unchanged (reg_rdata is read combinationally from reg_addr).

## Files

| File | Content |
|---|---|
| `rtl/MIPI_SoundWire_top.sv` | protocol core |
| `rtl/MIPI_SoundWire_apb.sv` | APB4 register wrapper (generated) |
| `tb/MIPI_SoundWire_tb.sv` | core testbench |
| `tb/MIPI_SoundWire_apb_tb.sv`, `tb/apb/MIPI_SoundWire_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/MIPI_SoundWire_sva.sv`, `tb/cov/MIPI_SoundWire_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/MIPI_SoundWire.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.MIPI_SoundWire sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.MIPI_SoundWire apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh MIPI_SoundWire          # core coverage (Verilator)
bash scripts/cov/run_cov.sh MIPI_SoundWire_apb      # wrapper coverage
```

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `MIPI_SoundWire_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sw_clk_o` | output | 1 | protocol pin, core port `sw_clk_o` |
| `sw_clk_oe` | output | 1 | protocol pin, core port `sw_clk_oe` |
| `sw_clk_i` | input | 1 | protocol pin, core port `sw_clk_i` |
| `sw_dat_o` | output | 1 | protocol pin, core port `sw_dat_o` |
| `sw_dat_oe` | output | 1 | protocol pin, core port `sw_dat_oe` |
| `sw_dat_i` | input | 1 | protocol pin, core port `sw_dat_i` |
| `reg_we` | output | 1 | protocol pin, core port `reg_we` |
| `reg_re` | output | 1 | protocol pin, core port `reg_re` |
| `reg_addr` | output | 16 | protocol pin, core port `reg_addr` |
| `reg_wdata` | output | 8 | protocol pin, core port `reg_wdata` |
| `reg_rdata` | input | 8 | protocol pin, core port `reg_rdata` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_manager` | input | 1 | CFG[0:0] |
| `cfg_div` | input | 5 | CFG[5:1] |
| `cfg_cols` | input | 2 | CFG[7:6] |
| `cfg_dev` | input | 4 | CFG[11:8] |
| `cfg_tx_col` | input | 4 | CFG[15:12] |
| `cfg_rx_col` | input | 4 | CFG[19:16] |
| `sw_clk_o` | output | 1 | pin (pass-through) |
| `sw_clk_oe` | output | 1 | pin (pass-through) |
| `sw_clk_i` | input | 1 | pin (pass-through) |
| `sw_dat_o` | output | 1 | pin (pass-through) |
| `sw_dat_oe` | output | 1 | pin (pass-through) |
| `sw_dat_i` | input | 1 | pin (pass-through) |
| `cmd_valid` | input | 1 | CMD commit / FLAGS |
| `cmd_ready` | output | 1 | CMD handshake |
| `cmd_op` | input | 2 | CMD[1:0] |
| `cmd_dev` | input | 4 | CMD[5:2] |
| `cmd_addr` | input | 16 | CMD[21:6] |
| `cmd_wdata` | input | 8 | CMD[29:22] |
| `rsp_valid` | output | 1 | RSP capture |
| `rsp_ack` | output | 1 | RSP[0:0] |
| `rsp_nak` | output | 1 | RSP[1:1] |
| `rsp_rdata` | output | 8 | RSP[9:2] |
| `ping_status` | output | 16 | STATUS[16:1] |
| `dev_status` | input | 2 | CFG[21:20] |
| `reg_we` | output | 1 | pin (pass-through) |
| `reg_re` | output | 1 | pin (pass-through) |
| `reg_addr` | output | 16 | pin (pass-through) |
| `reg_wdata` | output | 8 | pin (pass-through) |
| `reg_rdata` | input | 8 | pin (pass-through) |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 32 | TX[31:0] |
| `tx_underrun` | output | 1 | IRQ_STATUS.TX_UNDERRUN |
| `rx_valid` | output | 1 | RX capture |
| `rx_data` | output | 32 | RX[31:0] |
| `locked` | output | 1 | STATUS[0:0] |
| `lost_sync` | output | 1 | IRQ_STATUS.LOST_SYNC |
| `par_err` | output | 1 | IRQ_STATUS.PAR_ERR |

## APB wrapper

`MIPI_SoundWire_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sw_clk_o`, `sw_clk_oe`, `sw_clk_i`, `sw_dat_o`, `sw_dat_oe`, `sw_dat_i`, `reg_we`, `reg_re`, `reg_addr`, `reg_wdata`, `reg_rdata`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x534E0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000116 | Role, frame shape, device number, data columns |
| 0x018 | CMD | RW | 0x00000000 | Manager: command for the next frame; writing CMD commits it |
| 0x01C | RSP | RO (pop) | 0x00000000 | Manager: response to a command; reading RSP frees it |
| 0x020 | TX | RW | 0x00000000 | Transmit sample for the data port; writing TX commits it for the next frame |
| 0x024 | RX | RO (pop) | 0x00000000 | Received sample from the data port; reading RX frees it |
| 0x028 | STATUS | RO | core | Lock and PING status |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x534E | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 10:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 10:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 3:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 0 | `cfg_manager` | RW | 0x0 | 1 = manager (drives CLOCK and the control word) |
| CFG | 5:1 | `cfg_div` | RW | 0xB | manager: bit time - 1 in PCLK (11 or more) |
| CFG | 7:6 | `cfg_cols` | RW | 0x0 | columns per row: 0..3 = 2, 4, 8, 16 |
| CFG | 11:8 | `cfg_dev` | RW | 0x1 | peripheral: device number (PING slot for 1..8) |
| CFG | 15:12 | `cfg_tx_col` | RW | 0x0 | transmit column (0 or past the last column = off) |
| CFG | 19:16 | `cfg_rx_col` | RW | 0x0 | receive column (0 or past the last column = off) |
| CFG | 21:20 | `dev_status` | RW | 0x0 | peripheral: status sent in its PING slot |
| CMD | 1:0 | `cmd_op` | RW | 0x0 | 0 PING, 2 READ, 3 WRITE (1 reserved) |
| CMD | 5:2 | `cmd_dev` | RW | 0x0 | device number |
| CMD | 21:6 | `cmd_addr` | RW | 0x0 | register address |
| CMD | 29:22 | `cmd_wdata` | RW | 0x0 | WRITE data |
| RSP | 0 | `rsp_ack` | RO (pop) | 0x0 | ACK bit of the frame |
| RSP | 1 | `rsp_nak` | RO (pop) | 0x0 | NAK bit of the frame |
| RSP | 9:2 | `rsp_rdata` | RO (pop) | 0x0 | data bits of the frame (READ data, WRITE data echoed) |
| TX | 31:0 | `tx_data` | RW | 0x0 | sample, MSB first in rows 0..31 of the column |
| RX | 31:0 | `rx_data` | RO (pop) | 0x0 | sample |
| STATUS | 0 | `locked` | RO | core | frame locked (always 1 on the manager) |
| STATUS | 16:1 | `ping_status` | RO | core | manager: status bits of the last PING, device 1 in [15:14] |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | LOST_SYNC | peripheral: two bad frames in a row, the lock is dropped |
| 1 | PAR_ERR | peripheral: a command to this device failed the parity check (answered with NAK) |
| 2 | TX_UNDERRUN | the transmit column found no sample (zeros sent) |
| 3 | CMD_DONE | CMD beat accepted by the core |
| 4 | CMD_OVF | write to CMD while full (dropped) |
| 5 | RSP_AVAIL | RSP captured a beat |
| 6 | RSP_OVF | beat dropped, RSP was full |
| 7 | TX_DONE | TX beat accepted by the core |
| 8 | TX_OVF | write to TX while full (dropped) |
| 9 | RX_AVAIL | RX captured a beat |
| 10 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CMD_FULL | CMD holds a beat the core has not taken |
| 1 | RSP_AVAIL | RSP holds an unread beat |
| 2 | TX_FULL | TX holds a beat the core has not taken |
| 3 | RX_AVAIL | RX holds an unread beat |

### Streams

* **CMD** feeds `cmd_op`, `cmd_dev`, `cmd_addr`, `cmd_wdata`/`cmd_valid`. Writing CMD commits the beat: FLAGS.CMD_FULL is set and `cmd_valid` stays high until the core's `cmd_ready`; then CMD_DONE is set. A write while full is dropped and sets CMD_OVF.
* **RSP** captures `rsp_ack`, `rsp_nak`, `rsp_rdata` when `rsp_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RSP_AVAIL. Reading RSP pops it. A beat that arrives while the register is full is dropped and sets RSP_OVF.
* **TX** feeds `tx_data`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x534E0200.
2. Write 0x7FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7FF enables all).
5. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD (0x018). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
6. To receive on RSP: wait for IRQ RSP_AVAIL or FLAGS.RSP_AVAIL (bit 1), then read RSP (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RSP_AVAIL (bit 5) to clear it. Read each beat before the next arrives, or it is dropped and RSP_OVF is set.
7. To send on TX: wait until FLAGS.TX_FULL (bit 2) is 0, or for IRQ TX_DONE, then write TX (0x020). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
8. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 3), then read RX (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 9) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
9. Read STATUS (0x028) for the core's live `locked`, `ping_status`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/MIPI_SoundWire_top.sv` | pass | 102/102 | 1024/1024 | 8/8 | 16/16 | 30/30 |
| wrapper `rtl/MIPI_SoundWire_apb.sv` | pass | 44/44 | 1114/1114 | n/a | 21/21 | 91/91 |
