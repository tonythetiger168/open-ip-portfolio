<!-- SPDX-License-Identifier: Apache-2.0 -->
# SMBus: design specification

An SMBus 3.x target with a PMBus 1.3 command layer (a voltage-regulator style device): PEC,
clock stretching, SMBALERT# with the Alert Response Address, and the bus timeout. Not implemented:
Quick Command, Receive Byte, Process Call, Block Write, Host Notify, Address Resolution Protocol,
paged and most PMBus commands. Core `SMBus_top` (`rtl/SMBus_top.sv`), testbench `tb/SMBus_tb.sv`
(the TB is the host, with a second ARA responder on the bus), checker `tb/cov/SMBus_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. SCL and SDA are used after a two-flop synchroniser and a spike
filter; "SCL falls" means the filtered level. PEC is CRC-8, x^8 + x^2 + x + 1, seed 0, over every
byte of the transfer including addresses.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `scl` | input | 1 | SCL line level | - | async | - |
| `sda` | input | 1 | SDA line level | - | async | - |
| `scl_o` | output | 1 | 0 pulls SCL low (clock stretching) | low | `clk` | 1 |
| `sda_o` | output | 1 | 0 pulls SDA low | low | `clk` | 1 |
| `smbalert_n` | output | 1 | SMBALERT#; combinational from flops | low | `clk` | 1 |
| `operation` | output | 8 | OPERATION register | - | `clk` | 0x80 |
| `on_off_config` | output | 8 | ON_OFF_CONFIG register | - | `clk` | 0x1E |
| `vout_command` | output | 16 | VOUT_COMMAND register | - | `clk` | 0 |
| `read_vout` | input | 16 | value returned by READ_VOUT (sampled when the read starts) | - | `clk` | - |
| `vout_ov` | input | 1 | VOUT overvoltage fault (latched on a rise) | high | `clk` | - |
| `irq_cml` | output | 1 | one-clock pulse: a STATUS_CML bit was set | high | `clk` | 0 |
| `irq_upd` | output | 1 | one-clock pulse: OPERATION / ON_OFF_CONFIG / VOUT_COMMAND written | high | `clk` | 0 |
| `irq_to` | output | 1 | one-clock pulse: bus timeout | high | `clk` | 0 |

### Internal signals used by the verification

The TB and the checker read these by name (timeouts, fault state, filtered lines).

| Signal | Width | Meaning |
|---|---|---|
| `scl_f` | 1 | filtered SCL |
| `sda_f` | 1 | filtered SDA |
| `fall` | 1 | filtered SCL fell this clock; combinational |
| `active` | 1 | a transfer is in progress (START seen, no STOP / timeout yet) |
| `cml` | 4 | STATUS_CML bits {7, 6, 5, 1} |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SMBus.md`](../ip/SMBus.md) (source: `scripts/apb/specs/SMBus.json`); do not edit by hand.

`SMBus_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `scl`, `sda`, `scl_o`, `sda_o`, `smbalert_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53420100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | VOUT | RO | core | Output-voltage set point commanded over PMBus |
| 0x018 | CTRL | RO | core | On / off control commanded over PMBus |
| 0x01C | TELEMETRY | RW | 0x00000000 | Measured output voltage, returned by READ_VOUT (8Bh) |
| 0x020 | FAULT | WO (pulse) | 0x00000000 | Power-stage faults |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5342 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| VOUT | 15:0 | `vout_command` | RO | core | VOUT_COMMAND (21h), linear 16-bit mantissa, exponent from VOUT_MODE (-9) |
| CTRL | 7:0 | `operation` | RO | core | OPERATION (01h); bit 7 = on |
| CTRL | 15:8 | `on_off_config` | RO | core | ON_OFF_CONFIG (02h) |
| TELEMETRY | 15:0 | `read_vout` | RW | 0x0 | READ_VOUT value |
| FAULT | 0 | `vout_ov` | WO (pulse) | 0x0 | write 1: a VOUT overvoltage fault; latched into STATUS_BYTE / STATUS_WORD and SMBALERT# until CLEAR_FAULTS |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CML | a STATUS_CML bit was set (unsupported command, invalid data, PEC failure, bus timeout) |
| 1 | UPD | the host wrote OPERATION, ON_OFF_CONFIG or VOUT_COMMAND |
| 2 | TO | SCL was held low for TIMEOUT clocks in a transfer; the target released the bus |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53420100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write TELEMETRY (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. Read VOUT (0x014) for the core's live `vout_command`; it needs no clearing.
6. Read CTRL (0x018) for the core's live `operation`, `on_off_config`; it needs no clearing.
7. To issue a command, write 1 to `vout_ov` (FAULT bit 0) at 0x020; the core sees a one-clock pulse, and the register reads 0.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Bus

The filtered level follows the synchronised input once it has differed for `FILT` clocks. START
is SDA 1 -> 0 and STOP SDA 0 -> 1 with SCL high in both clocks. The target samples SDA when SCL
rises and changes SDA `HOLD` clocks after SCL falls. The first SCL fall after a START belongs to
the START; bits are counted from there, 8 bits then the ACK bit.

After it ACKs an address (the first address byte, or the read address after a repeated START),
at the end of the ACK bit the target holds SCL low for `STRETCH` clocks.

### 3.2 Commands

| Code | Command | Write bytes | Read bytes |
|---|---|---|---|
| 01 | OPERATION | 1 | 1 |
| 02 | ON_OFF_CONFIG | 1 | 1 |
| 03 | CLEAR_FAULTS | 0 (Send Byte) | - |
| 10 | WRITE_PROTECT (00 / 20 / 40 / 80) | 1 | 1: {WP bits, 00000} |
| 19 | CAPABILITY | - | 1: 0xB0 |
| 20 | VOUT_MODE | - | 1: 0x17 |
| 21 | VOUT_COMMAND | 2, low byte first | 2 |
| 78 | STATUS_BYTE: [6] OFF = !OPERATION[7], [5] VOUT_OV, [1] CML | - | 1 |
| 79 | STATUS_WORD: low byte as STATUS_BYTE, [15] VOUT | - | 2 |
| 7E | STATUS_CML: [7] command, [6] data, [5] PEC, [1] other | - | 1 |
| 8B | READ_VOUT | - | 2 |
| 98 | PMBUS_REVISION | - | 1: 0x33 |
| 99 | MFR_ID (block) | - | 5: 04, "OIPF" |

WRITE_PROTECT 0x80: only WRITE_PROTECT is writable; 0x40: also OPERATION; 0x20 and 0x00: all.
CLEAR_FAULTS is always accepted.

### 3.3 Write transfers

START, {`ADDR`, 0}, command, data bytes, optional PEC, STOP.

* Address: ACKed if it is {`ADDR`, 0}, or the ARA 0x19 while SMBALERT# is low (§3.5). Otherwise
  NACK and the transfer is ignored to STOP.
* Command: ACKed if writable or readable; else NACK and STATUS_CML[7].
* Each data byte, before the expected count: ACKed. The byte after the data is the PEC: ACKed if
  correct, else NACK and STATUS_CML[5]. NACK and STATUS_CML[6]: a data byte for a command that is
  not writable, a byte beyond the PEC, a first data byte for a protected command, or a
  WRITE_PROTECT value other than 00 / 20 / 40 / 80.
* At STOP, a write that carried all its data (with or without its PEC) and was not NACKed takes
  effect; `irq_upd` pulses for OPERATION, ON_OFF_CONFIG and VOUT_COMMAND. CLEAR_FAULTS clears
  STATUS_CML and re-latches the overvoltage from `vout_ov`. A write with too few data bytes sets
  STATUS_CML[6].

After any NACK the transfer is ignored until STOP.

### 3.4 Read transfers

START, {`ADDR`, 0}, command, repeated START, {`ADDR`, 1}, then data from the target. The read
address is ACKed only right after the command byte and only for a readable command (a
write-only command: NACK and STATUS_CML[7]). The value is sampled at that ACK. The target sends
the data bytes, then the PEC while the host keeps ACKing, then 0xFF; a host NACK ends sending. A
1 sent while SDA reads 0 (lost arbitration) stops sending.

### 3.5 Faults and SMBALERT#

Any STATUS_CML bit, or the overvoltage latch (set when `vout_ov` is 1 and not latched), pulls
SMBALERT# low. A host read of the ARA (0x19) is ACKed while SMBALERT# is low; the target then
sends {`ADDR`, 0}, the PEC (of 0x19 and that byte) and 0xFF. If the whole address byte is sent
(arbitration won), SMBALERT# is released until a new fault or CLEAR_FAULTS. `irq_cml` pulses one
clock after any STATUS_CML bit is set.

### 3.6 Timeout and reset

With a transfer active, SCL low for `TIMEOUT` consecutive clocks ends the transfer, releases both
lines, sets STATUS_CML[1] and pulses `irq_to` one clock later. While `rst_n` is low the lines are
released and the registers take their reset values.

## 4. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR` | 0x5A | 7-bit target address |
| `FILT` | 3 | spike filter, clocks (at least 1) |
| `HOLD` | 4 | SDA hold after SCL falls, clocks (at least 1) |
| `STRETCH` | 8 | SCL stretch after an address ACK, clocks (0: none) |
| `TIMEOUT` | 2500000 | tTIMEOUT, clocks |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| unknown command | NACK, STATUS_CML[7] |
| read of a write-only command | read address NACK, STATUS_CML[7] |
| too many / too few data bytes, protected command, bad WP value | NACK or no effect, STATUS_CML[6] |
| wrong PEC | NACK, STATUS_CML[5], no effect |
| SCL low too long | STATUS_CML[1], `irq_to` |
| read address right after START (Receive Byte) | NACK |
| transfer for another address | ignored, no fault |
| ARA arbitration lost | SMBALERT# stays low |
| spike shorter than `FILT` | ignored |

## 6. TB check map

Messages are printed by `tb/SMBus_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/SMBus_sva.sv`. The TB is an open-drain host with a transaction model of the
target that predicts every ACK, byte, fault and SMBALERT#; monitors check SDA timing and stretch
length.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "write" | ACK / NACK of each written byte | §3.3 |
| "read: address NACKed" | read address ACK rules | §3.4 |
| "read" | read bytes, PEC and 0xFF | §3.4 |
| "SDA driven after the host NACK" | sending stops at a NACK | §3.4 |
| "ARA ack" | ARA ACKed only with SMBALERT# low | §3.5 |
| "ARA returned" | the address returned | §3.5 |
| "ARA PEC" | its PEC | §3.5 |
| "outputs op" | registers as the model | §3.3 |
| "STATUS_CML" | fault bits | §3.3, §3.5 |
| "SMBALERT#" | SMBALERT# as the model | §3.5 |
| "target changed SDA while SCL high" | SDA moves only with SCL low | §3.1 |
| "SDA hold" | `HOLD` clocks after SCL falls | §3.1 |
| "stretch of" | stretch lasts `STRETCH` | §3.1 |
| "bus released in reset" | reset | §3.6 |
| "long write: address" | ACKs in an over-long write | §3.3 |
| "long write: command" | same | §3.3 |
| "long write: PEC" | same | §3.3 |
| "long write: extra byte ACKed" | a byte after the PEC is NACKed | §3.3 |
| "SMBALERT# without a fault" | no stray alert | §3.5 |
| "faults from transfers for other targets" | other addresses ignored | §3.3 |
| "SMBALERT# released after a lost arbitration" | released only if the address was sent | §3.5 |
| "byte with spikes NACKed" | spikes filtered | §3.1 |
| "no timeout" | timeout fires | §3.6 |
| "reset values" | reset values | §3.6 |
| "irq_upd" | update pulse | §3.3 |
| "irq_to" | timeout pulse | §3.6 |
| "irq_cml only" | fault pulse only with a fault | §3.5 |
| a_filter | filtered lines as the model | §3.1 |
| a_ack | ACK / NACK as the model | §3.3, §3.4 |
| a_tx_bit | each sent bit | §3.4, §3.5 |
| a_release | SDA released otherwise | §3.1 |
| a_regs | registers as the model | §3.3 |
| a_alert | SMBALERT# as the model | §3.5 |
| a_sda_hold | SDA changes `HOLD` clocks after SCL falls | §3.1 |
| a_stretch_len | stretch length | §3.1 |
| a_stretch_end | stretch release | §3.1 |
| a_stretch_start | stretch start | §3.1 |
| a_stretch_when | stretch only after an address ACK | §3.1 |
| a_stretch_due | stretch after every address ACK | §3.1 |
| a_timeout | timeout behaviour | §3.6 |
| a_rst | reset values | §3.6 |
