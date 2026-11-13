<!-- SPDX-License-Identifier: Apache-2.0 -->
# MIPI_SoundWire: design specification

A SoundWire-style two-wire audio bus interface (manager or peripheral) with control commands and
one data port each way. Not implemented: bank switching and other frame shapes, multiple data
ports and sample intervals, interrupts and alerts beyond PING status, enumeration, clock stop.
Core `MIPI_SoundWire_top` (`rtl/MIPI_SoundWire_top.sv`), testbench `tb/MIPI_SoundWire_tb.sv` (a
manager and two peripherals on one bus with a keeper), checker `tb/cov/MIPI_SoundWire_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` (PCLK) and reset
asynchronously by `rst_n` low. Double data rate: every CLOCK edge ends one bit and starts the
next. NRZI: a 1 toggles DATA, a 0 keeps it. A frame is 48 rows x C columns, sent row by row.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | PCLK | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_manager` | input | 1 | 1: manager (drives CLOCK), 0: peripheral | high | static | - |
| `cfg_div` | input | 5 | manager: a bit lasts `cfg_div` + 1 PCLK (11 or more) | - | static | - |
| `cfg_cols` | input | 2 | columns per row: 0 = 2, 1 = 4, 2 = 8, 3 = 16 | - | static | - |
| `cfg_dev` | input | 4 | peripheral device number | - | static | - |
| `cfg_tx_col` | input | 4 | transmit data column (0 or beyond the last column = off) | - | static | - |
| `cfg_rx_col` | input | 4 | receive data column (0 or beyond = off) | - | static | - |
| `sw_clk_o` | output | 1 | CLOCK driven (manager) | - | `clk` | 0 |
| `sw_clk_oe` | output | 1 | = `cfg_manager` | high | comb | - |
| `sw_clk_i` | input | 1 | CLOCK on the bus (peripheral: two-flop synchronised) | - | async | - |
| `sw_dat_o` | output | 1 | DATA driven (NRZI level) | - | `clk` | 0 |
| `sw_dat_oe` | output | 1 | this endpoint drives DATA | high | `clk` | 0 |
| `sw_dat_i` | input | 1 | DATA on the bus | - | `clk` | - |
| `cmd_valid` | input | 1 | manager: a host command is offered | high | `clk` | - |
| `cmd_ready` | output | 1 | the holding register is free; combinational from flops | high | `clk` | 1 |
| `cmd_op` | input | 2 | 0 PING, 2 READ, 3 WRITE (1 reserved) | - | `clk` | - |
| `cmd_dev` | input | 4 | device | - | `clk` | - |
| `cmd_addr` | input | 16 | register address | - | `clk` | - |
| `cmd_wdata` | input | 8 | WRITE data | - | `clk` | - |
| `rsp_valid` | output | 1 | one-clock pulse: response of a host command | high | `clk` | 0 |
| `rsp_ack` | output | 1 | its ACK bit; holds | high | `clk` | 0 |
| `rsp_nak` | output | 1 | its NAK bit; holds | high | `clk` | 0 |
| `rsp_rdata` | output | 8 | its data bits; holds | - | `clk` | 0 |
| `ping_status` | output | 16 | status bits of the last PING, device 1 in bits 15:14; holds | - | `clk` | 0 |
| `dev_status` | input | 2 | peripheral: status sent in PING | - | `clk` | - |
| `reg_we` | output | 1 | one-clock pulse: WRITE to this device with good parity | high | `clk` | 0 |
| `reg_re` | output | 1 | one-clock pulse: READ of this device (address complete) | high | `clk` | 0 |
| `reg_addr` | output | 16 | register address; holds | - | `clk` | 0 |
| `reg_wdata` | output | 8 | write data; holds | - | `clk` | 0 |
| `reg_rdata` | input | 8 | read data (used combinationally as bits are sent) | - | `clk` | - |
| `tx_valid` | input | 1 | a data sample is offered | high | `clk` | - |
| `tx_ready` | output | 1 | one-clock pulse: the sample was taken for this frame | high | `clk` | 0 |
| `tx_data` | input | 32 | data sample, MSB first | - | `clk` | - |
| `tx_underrun` | output | 1 | one-clock pulse: no sample, zeros sent | high | `clk` | 0 |
| `rx_valid` | output | 1 | one-clock pulse: a received sample | high | `clk` | 0 |
| `rx_data` | output | 32 | received sample; holds | - | `clk` | 0 |
| `locked` | output | 1 | frame lock (always 1 on the manager); combinational from flops | high | `clk` | 0 |
| `lost_sync` | output | 1 | one-clock pulse: lock lost | high | `clk` | 0 |
| `par_err` | output | 1 | one-clock pulse: bad parity in a command to this device | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these in the manager instance (`g_ep[0].u`) to follow the frame; the FSM coverage
collector binds `ys`.

| Signal | Width | Meaning |
|---|---|---|
| `row` | 6 | row of the bit on the bus (reset 47) |
| `col` | 4 | column of the bit on the bus |
| `lastc_hi` | 3 | last column is {`lastc_hi`, 1}; combinational |
| `edge_now` | 1 | a bit ends this clock; combinational |
| `m_edge` | 1 | manager: CLOCK toggles this clock; combinational |
| `m_mid` | 1 | manager: mid-bit (drive point); combinational |
| `cw` | 31 | manager: control word bits 46:16 of this frame |
| `rw` | 33 | control word bits 47:15 received so far this frame |
| `dyn_m` | 4 | manager: dynamic sync of the current frame |
| `ys` | 2 | sync: 0 HUNT, 1 CHECK, 2 LOCK |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/MIPI_SoundWire.md`](../ip/MIPI_SoundWire.md) (source: `scripts/apb/specs/MIPI_SoundWire.json`); do not edit by hand.

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

### Programming sequence

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
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Bus

The manager toggles CLOCK every `cfg_div` + 1 PCLK. A bit is sampled at the edge that ends it (a
peripheral sees CLOCK through two flops, one more clock to detect the edge). The manager drives
its bits from mid-bit to the end of the bit; a peripheral drives from two PCLK after it sees the
starting edge until the ending edge. A bus
keeper holds DATA between drivers. Each driver drives the level = previous sampled level XOR bit.

### 3.2 Control word

Column 0, row r carries control bit 47 - r:

| Bits | Field |
|---|---|
| 47:45 | opcode: 000 PING, 010 READ, 011 WRITE |
| 44:41 | device |
| 40:25 | register address; PING: two status bits per device 1..8, device 1 in 40:39 |
| 24:17 | data (READ: driven by the device) |
| 16 | even parity over 47:25 (and 24:17 for a WRITE) |
| 15, 14 | ACK, NAK (driven by the addressed device) |
| 13:6 | static sync 0xB1 |
| 5:2 | dynamic sync, PRBS x^4 + x^3 + 1 stepping each frame |
| 1:0 | 0 |

### 3.3 Manager

A host command is held (`cmd_ready` = 0) until the next frame start, which sends it; without one
the frame carries a PING. The manager leaves to the devices: READ data bits, ACK / NAK, and the
PING status bits. `rsp_valid` pulses after the NAK bit of a host command's frame with ACK, NAK and
data; `ping_status` is updated after the PING address bits.

### 3.4 Peripheral

* Sync: in HUNT, the static sync is looked for at a stride of the column count; found -> CHECK,
  aligned so the ended bit was control bit 6. At each frame's dynamic sync position, CHECK goes
  to LOCK when the static sync was good in two frames in a row (else HUNT). In LOCK a frame is
  bad if the static sync or the expected dynamic sync is wrong; two bad frames in a row ->
  HUNT and `lost_sync`. The expected dynamic sync steps on over a bad frame.
* Commands (locked, device = `cfg_dev`): READ pulses `reg_re` once the address is in and sends
  `reg_rdata` in the data bits; at the parity bit of a READ or WRITE, good parity sends ACK (and a
  WRITE pulses `reg_we`), bad parity sends NAK and pulses `par_err`. PING: `dev_status` in its slot
  (devices 1..8).

### 3.5 Data port

Column `cfg_tx_col`, rows 0..31 carries a 32-bit sample, MSB first; it is taken at row 0 (with
`tx_valid`: `tx_ready` pulses; without: zeros and `tx_underrun`). Column `cfg_rx_col` rows 0..31
are delivered as `rx_data` with `rx_valid` after row 31. The manager's columns run from the start,
a peripheral's while locked.

### 3.6 Reset

While `rst_n` is low: HUNT, position row 47 column 0, no drive, outputs 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| bad parity in a command to this device | NAK, `par_err`, no write |
| command to an absent device | no ACK / NAK (both 0) |
| reserved opcode 1 | not answered |
| one bad frame | lock kept |
| two bad frames in a row | `lost_sync`, HUNT |
| data column 0 or beyond the last | off |
| a command while one is held | waits (`cmd_ready` = 0) |

## 6. TB check map

Messages are printed by `tb/MIPI_SoundWire_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in
the bound checker `tb/cov/MIPI_SoundWire_sva.sv`. The TB has its own line decoder and checks every
frame's syncs and parity, every response and register bank against a model, and the data ports.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "static sync" | 0xB1 every frame | §3.2 |
| "dynamic sync" | PRBS | §3.2 |
| "reserved control bits" | bits 1:0 = 0 | §3.2 |
| "parity" | parity | §3.2 |
| "DATA driven by" | one driver at a time | §3.1 |
| "response with no command" | responses only for host commands | §3.3 |
| "response" | ACK / NAK / data | §3.3, §3.4 |
| "PING status" | PING slots | §3.4 |
| "no lock" | peripherals lock | §3.4 |
| "bad parity: writes or par_err" | NAK, no write | §3.4 |
| "one bad frame lost the lock" | one bad frame tolerated | §3.4 |
| "two bad frames kept the lock" | two bad frames lose lock | §3.4 |
| a_clk_oe | `sw_clk_oe` | §3.1 |
| a_clk | manager CLOCK | §3.1 |
| a_dat_oe | DATA drive windows | §3.1 |
| a_dat | DATA values | §3.1, §3.2 |
| a_cmd_ready | holding register | §3.3 |
| a_rsp_valid | response pulse | §3.3 |
| a_rsp | response fields | §3.3 |
| a_ping | `ping_status` | §3.3 |
| a_reg_re | `reg_re` | §3.4 |
| a_reg | `reg_we` / address / data | §3.4 |
| a_tx | data port transmit | §3.5 |
| a_rx_valid | data port receive pulse | §3.5 |
| a_rx_data | data port receive data | §3.5 |
| a_locked | `locked` | §3.4 |
| a_errs | `lost_sync` / `par_err` | §3.4 |
| a_reset | reset values | §3.6 |
