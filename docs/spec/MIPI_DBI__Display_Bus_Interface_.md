<!-- SPDX-License-Identifier: Apache-2.0 -->
# MIPI_DBI__Display_Bus_Interface_: design specification

A MIPI DBI-2 host controller: Type A (Motorola 6800), Type B (Intel 8080) and Type C (serial)
options 1 and 3, one command or data transfer per op. Not implemented: Type C option 2 (8-bit
with a 16-bit dummy), the Type A clock-synchronous variant, tearing-effect input handling.
Core `MIPI_DBI__Display_Bus_Interface__top` (`rtl/MIPI_DBI__Display_Bus_Interface__top.sv`),
testbench `tb/MIPI_DBI__Display_Bus_Interface__tb.sv` (a display model decoding the pins of every
type), checker `tb/cov/MIPI_DBI__Display_Bus_Interface__sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; every pin is a register, so
a decision at edge n is on the pins from clock n+1. "ph" is `cfg_tr` for a read op and `cfg_tw`
for a write op; a phase lasts ph + 1 clocks.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock (PCLK) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_type` | input | 2 | 0 Type A (6800), 1 Type B (8080), 2 Type C option 1, 3 Type C option 3; change only while `busy` = 0 | - | static | - |
| `cfg_w16` | input | 1 | Type A / B: 16-bit bus (else 8-bit, D[7:0]) | high | static | - |
| `cfg_tw` | input | 4 | write phase length - 1, in clocks | - | static | - |
| `cfg_tr` | input | 4 | read phase length - 1, in clocks | - | static | - |
| `cfg_dummy` | input | 2 | Type C: dummy clocks before the first read | - | static | - |
| `op_valid` | input | 1 | an op (one transfer) is offered | high | `clk` | - |
| `op_ready` | output | 1 | idle: the op is taken; combinational | high | comb | 1 |
| `op_dc` | input | 1 | 0 command, 1 data / parameter | - | `clk` | - |
| `op_rd` | input | 1 | 1 read, 0 write | high | `clk` | - |
| `op_last` | input | 1 | raise CSX after this op | high | `clk` | - |
| `op_data` | input | 16 | write data (8-bit transfers use bits 7:0) | - | `clk` | - |
| `rd_valid` | output | 1 | one-clock pulse: read data on `rd_data` | high | `clk` | 0 |
| `rd_data` | output | 16 | read data (8-bit reads in bits 7:0, upper bits 0); holds | - | `clk` | 0 |
| `busy` | output | 1 | an op in progress or CSX low; combinational | high | comb | 0 |
| `csx` | output | 1 | CSX chip select | low | `clk` | 1 |
| `dcx` | output | 1 | D/CX: 0 command, 1 data (Type A / B / C option 3) | - | `clk` | 1 |
| `wrx` | output | 1 | Type B WRX strobe (low); Type A R/WX (1 read, 0 write); 1 in Type C | - | `clk` | 1 |
| `rdx` | output | 1 | Type B RDX strobe (low); Type A E (high); 1 in Type C | - | `clk` | 1 |
| `d_o` | output | 16 | Type A / B data out | - | `clk` | 0 |
| `d_oe` | output | 1 | Type A / B data output enable | high | `clk` | 0 |
| `d_i` | input | 16 | Type A / B data in | - | `clk` | - |
| `scl` | output | 1 | Type C SCL (idles low) | - | `clk` | 0 |
| `sda_o` | output | 1 | Type C SDA out | - | `clk` | 0 |
| `sda_oe` | output | 1 | Type C SDA output enable (0 in reads) | high | `clk` | 0 |
| `sda_i` | input | 1 | Type C SDA in | - | `clk` | - |

### Internal signals used by the verification

The FSM coverage collector (`tb/cov/MIPI_DBI__Display_Bus_Interface__fsm_cov.sv`) binds this by
name; a re-implementation must have it.

| Signal | Width | Meaning |
|---|---|---|
| `st` | 3 | 0 IDLE, 1 SETUP, 2 STROBE, 3 HOLD, 4 SCL low, 5 SCL high, 6 CSX high |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/MIPI_DBI__Display_Bus_Interface_.md`](../ip/MIPI_DBI__Display_Bus_Interface_.md) (source: `scripts/apb/specs/MIPI_DBI__Display_Bus_Interface_.json`); do not edit by hand.

`MIPI_DBI__Display_Bus_Interface__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `csx`, `dcx`, `wrx`, `rdx`, `d_o`, `d_oe`, `d_i`, `scl`, `sda_o`, `sda_oe`, `sda_i`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44420200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000A11 | Interface configuration (change only while STATUS.busy is 0) |
| 0x018 | OP | RW | 0x00000000 | One bus transfer; writing OP commits it |
| 0x01C | RD | RO (pop) | 0x00000000 | Read data; reading RD frees it |
| 0x020 | STATUS | RO | core | Controller state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4442 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 1:0 | `cfg_type` | RW | 0x1 | 0 Type A (6800), 1 Type B (8080), 2 Type C option 1 (3-line, 9-bit), 3 Type C option 3 (4-line, D/CX pin) |
| CFG | 2 | `cfg_w16` | RW | 0x0 | Type A / B 16-bit data bus |
| CFG | 6:3 | `cfg_tw` | RW | 0x2 | write phase length - 1 (PCLK) |
| CFG | 10:7 | `cfg_tr` | RW | 0x4 | read phase length - 1 (PCLK) |
| CFG | 12:11 | `cfg_dummy` | RW | 0x1 | Type C dummy clocks before the first read after a write |
| OP | 15:0 | `op_data` | RW | 0x0 | write data (8-bit transfers use [7:0]) |
| OP | 16 | `op_dc` | RW | 0x0 | 0 command, 1 data / parameter (D/CX) |
| OP | 17 | `op_rd` | RW | 0x0 | 1 read, 0 write |
| OP | 18 | `op_last` | RW | 0x0 | release CSX after this transfer |
| RD | 15:0 | `rd_data` | RO (pop) | 0x0 | read data (8-bit transfers in [7:0]) |
| STATUS | 0 | `busy` | RO | core | a transfer is running or CSX is low |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | OP_DONE | OP beat accepted by the core |
| 1 | OP_OVF | write to OP while full (dropped) |
| 2 | RD_AVAIL | RD captured a beat |
| 3 | RD_OVF | beat dropped, RD was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | OP_FULL | OP holds a beat the core has not taken |
| 1 | RD_AVAIL | RD holds an unread beat |

### Streams

* **OP** feeds `op_data`, `op_dc`, `op_rd`, `op_last`/`op_valid`. Writing OP commits the beat: FLAGS.OP_FULL is set and `op_valid` stays high until the core's `op_ready`; then OP_DONE is set. A write while full is dropped and sets OP_OVF.
* **RD** captures `rd_data` when `rd_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RD_AVAIL. Reading RD pops it. A beat that arrives while the register is full is dropped and sets RD_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44420200.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
5. To send on OP: wait until FLAGS.OP_FULL (bit 0) is 0, or for IRQ OP_DONE, then write OP (0x018). The last write commits the beat. OP_OVF means a write came while the register was full and was dropped.
6. To receive on RD: wait for IRQ RD_AVAIL or FLAGS.RD_AVAIL (bit 1), then read RD (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RD_AVAIL (bit 2) to clear it. Read each beat before the next arrives, or it is dropped and RD_OVF is set.
7. Read STATUS (0x020) for the core's live `busy`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Ops and CSX

An op is taken at an edge with `op_valid` in IDLE (`op_ready` = 1). CSX goes low at that edge
(if not already low) and stays low across ops until an op with `op_last` ends: then CSX goes high
and a CSX-high phase of ph + 1 clocks follows before the next op can be taken. After an op without
`op_last` the controller returns to IDLE with CSX low; `busy` = not IDLE or CSX low. In IDLE the
strobe pins are driven to the idle level of the current `cfg_type` each clock (Type A: E low,
R/WX high; Type B and C: WRX and RDX high), so a configuration change shows one clock later.

### 3.2 Type A and Type B

At the op's edge: D/CX = `op_dc`; a write drives `d_o` = `op_data` (8-bit: upper byte 0) with
`d_oe` = 1, a read sets `d_oe` = 0; Type A sets R/WX = `op_rd`. Then three phases of ph + 1
clocks:

| Phase | Type A | Type B |
|---|---|---|
| SETUP | E low | WRX / RDX high |
| STROBE | E high | WRX low (write) or RDX low (read) |
| HOLD | E low | WRX / RDX high |

Read data is taken from `d_i` at the edge that ends STROBE (16 bits, or bits 7:0 with the upper
byte 0) and `rd_valid` pulses in the next clock. At the end of HOLD `d_oe` = 0, Type A R/WX = 1.
D/CX, R/WX and the bus are stable through all three phases.

### 3.3 Type C

SCL idles low; each bit is an SCL-low phase and an SCL-high phase of ph + 1 clocks, the display
samples on the rising edge. Bits go MSB first.

* Option 1 (`cfg_type` 2) write: 9 bits, the D/CX bit (`op_dc`) then `op_data[7:0]`.
* Option 3 (`cfg_type` 3): 8 bits; the `dcx` pin carries `op_dc`.
* Write: `sda_oe` = 1, the first bit on `sda_o` from the op's edge, each next bit at the edge
  that ends an SCL-high phase.
* Read: 8 bits (no D/CX bit in either option), `sda_oe` = 0. When the previous Type C op was not
  a read, or CSX was high, `cfg_dummy` dummy clocks come first. `sda_i` is sampled at each edge
  that raises SCL; the last 8 samples are `rd_data[7:0]`, `rd_valid` after the last SCL-high
  phase.

After the last bit: `sda_oe` = 0, and CSX high (with `op_last`) or IDLE.

### 3.4 Reset

While `rst_n` is low: IDLE, CSX / D/CX / WRX / RDX high, SCL, SDA and bus outputs 0, not driven.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `cfg_tw` / `cfg_tr` 0 | 1-clock phases |
| configuration changed while busy | not allowed (undefined) |
| first read after a write in Type C | `cfg_dummy` dummy clocks first |
| reads back to back in Type C with CSX low | no dummy clocks |
| 8-bit read on a 16-bit capable bus | `rd_data[15:8]` 0 |
| reset in the middle of a transfer | pins return to idle levels |

## 6. TB check map

Messages are printed by `tb/MIPI_DBI__Display_Bus_Interface__tb.sv` as `ERROR: <message>`.
Assertions `a_*` are in the bound checker `tb/cov/MIPI_DBI__Display_Bus_Interface__sva.sv`, a
cycle model of every pin. A display model decodes every type from the pins (Type A latch on E
falling, Type B on WRX rising, Type C on SCL rising) and drives read data; random transactions run
on every type, width, phase length and dummy count, with a configuration change between
transactions and a reset mid-transfer.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "read data with no read" | `rd_valid` only for read ops | §3.2, §3.3 |
| "read data" | read data as the display drove it | §3.2, §3.3 |
| "transfer with no op" | one transfer per op | §3.1 |
| "transfer rd" | direction and D/CX as the op | §3.2, §3.3 |
| "write" | write data and width as the op | §3.2, §3.3 |
| "CSX fell twice" | CSX low once per transaction | §3.1 |
| "CSX rose before op_last" | CSX stays low until `op_last` | §3.1 |
| "CSX low after op_last" | CSX high after `op_last` | §3.1 |
| "bus driven by both or neither" | Type A: `d_oe` = not R/WX | §3.2 |
| "R/WX, D/CX or data changed while E high" | Type A stable while E high | §3.2 |
| "WRX and RDX low together" | one Type B strobe at a time | §3.2 |
| "strobe with CSX high" | strobes only with CSX low | §3.2 |
| "bus direction wrong for the strobe" | Type B `d_oe` with WRX, off with RDX | §3.2 |
| "D/CX or data changed during the strobe" | stable during the strobe | §3.2 |
| "parallel pins active in Type C" | WRX / RDX high, `d_oe` 0 in Type C | §3.1, §3.3 |
| "SCL with CSX high" | SCL only with CSX low | §3.3 |
| "host drives SDA in a read" | `sda_oe` 0 in reads | §3.3 |
| "SDA not driven in a write" | `sda_oe` 1 in writes | §3.3 |
| "did not drain" | every op completes | §3.1 |
| a_op_ready | `op_ready` exactly in IDLE | §3.1 |
| a_busy | `busy` = op running or CSX low | §3.1 |
| a_csx | CSX as the model | §3.1 |
| a_dcx | D/CX as the model | §3.2, §3.3 |
| a_wrx | WRX / R/WX as the model | §3.2 |
| a_rdx | RDX / E as the model | §3.2 |
| a_d_oe | `d_oe` in Type A / B writes | §3.2 |
| a_d_o | `d_o` as the model | §3.2 |
| a_scl | SCL phases as the model | §3.3 |
| a_sda_oe | `sda_oe` in Type C writes | §3.3 |
| a_sda_o | `sda_o` bits as the model | §3.3 |
| a_rd_valid | `rd_valid` exactly as the model | §3.2, §3.3 |
| a_rd_data | `rd_data` as the model | §3.2, §3.3 |
| a_strobe_csx | any strobe or SCL high only with CSX low | §3.2, §3.3 |
| a_reset | in reset: CSX high, outputs idle | §3.4 |
