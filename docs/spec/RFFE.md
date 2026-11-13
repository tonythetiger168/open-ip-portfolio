<!-- SPDX-License-Identifier: Apache-2.0 -->
# RFFE: design specification

A MIPI RFFE-style bus master: it drives SCLK and runs one command sequence per host command
(register 0 write, register write / read, extended write / read, extended long write / read) with
odd-parity frames and bus park cycles. Not implemented: half-speed reads, masked writes,
interrupt and master-ownership-handover sequences. Core `RFFE_top` (`rtl/RFFE_top.sv`),
testbench `tb/RFFE_tb.sv` (two `MIPI_RFFE_top` slaves and a TB slave model), checker `tb/cov/RFFE_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge. A half period H is
`cfg_div` + 1 clocks; the master acts at "ticks", the last clock of each half period. Frames are
MSB first with an odd parity bit P (the frame including P has an odd number of ones).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock (PCLK) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_div` | input | 4 | SCLK half period - 1, in clocks (7 or more with `MIPI_RFFE_top` slaves) | - | static | - |
| `sclk` | output | 1 | RFFE SCLK | - | `clk` | 0 |
| `sdata_o` | output | 1 | SDATA driven value | - | `clk` | 0 |
| `sdata_oe` | output | 1 | the master drives SDATA | high | `clk` | 0 |
| `sdata_i` | input | 1 | SDATA seen on the bus (two-flop synchronised) | - | async | - |
| `cmd_valid` | input | 1 | a command sequence is requested | high | `clk` | - |
| `cmd_ready` | output | 1 | idle: the command is taken; combinational | high | comb | 1 |
| `cmd_type` | input | 3 | 0 reg 0 write, 1 reg write, 2 reg read, 3 ext write, 4 ext read, 5 ext long write, 6 ext long read, 7 reserved | - | `clk` | - |
| `cmd_sa` | input | 4 | slave address | - | `clk` | - |
| `cmd_addr` | input | 16 | register address (type 0: the 7-bit data in [6:0]; types 1, 2: [4:0]; 3, 4: [7:0]) | - | `clk` | - |
| `cmd_bc` | input | 4 | byte count - 1 (types 3, 4; types 5, 6 use [2:0]) | - | `clk` | - |
| `wr_valid` | input | 1 | a write data byte is available | high | `clk` | - |
| `wr_ready` | output | 1 | one-clock pulse: the byte on `wr_data` was taken at the previous edge | high | `clk` | 0 |
| `wr_data` | input | 8 | write data byte | - | `clk` | - |
| `rd_valid` | output | 1 | one-clock pulse: a read frame on `rd_data` | high | `clk` | 0 |
| `rd_data` | output | 8 | read byte; holds | - | `clk` | 0 |
| `rd_perr` | output | 1 | with `rd_valid`: the frame's parity failed | high | `clk` | 0 |
| `done` | output | 1 | one-clock pulse: the sequence ended | high | `clk` | 0 |
| `done_perr` | output | 1 | with `done`: a read frame of the sequence failed parity; holds | high | `clk` | 0 |
| `busy` | output | 1 | a sequence is running; combinational | high | comb | 0 |

### Internal signals used by the verification

The TB reads `st` by name (and compares it with the state constant `S_WAIT`); the FSM coverage
collector binds it too.

| Signal | Width | Meaning |
|---|---|---|
| `st` | 3 | 0 IDLE, 1 SSC, 2 TRANSMIT, 3 WAIT (for write data), 4 BUS PARK, 5 RECEIVE, 6 SLAVE PARK |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/RFFE.md`](../ip/RFFE.md) (source: `scripts/apb/specs/RFFE.json`); do not edit by hand.

`RFFE_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `sdata_o`, `sdata_oe`, `sdata_i`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x52460200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000007 | Bus speed |
| 0x018 | CMD | RW | 0x00000000 | Command sequence; writing CMD commits it, the core takes it when idle |
| 0x01C | WR | RW | 0x00000000 | Write data byte for the next data frame (SCLK waits while WR is empty) |
| 0x020 | RD | RO (pop) | 0x00000000 | Read data byte; reading RD frees it |
| 0x024 | STATUS | RO | core | Sequence state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5246 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 6:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 6:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 2:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 3:0 | `cfg_div` | RW | 0x7 | SCLK half period - 1 in PCLK (7 or more for reads from MIPI_RFFE_top) |
| CMD | 2:0 | `cmd_type` | RW | 0x0 | 0 register 0 write, 1 register write, 2 register read, 3 extended write, 4 extended read, 5 extended long write, 6 extended long read, 7 reserved (no bus activity) |
| CMD | 6:3 | `cmd_sa` | RW | 0x0 | slave address (0 = broadcast) |
| CMD | 22:7 | `cmd_addr` | RW | 0x0 | register address (type 0: data in [6:0]) |
| CMD | 26:23 | `cmd_bc` | RW | 0x0 | byte count - 1 (extended; long uses [2:0]) |
| WR | 7:0 | `wr_data` | RW | 0x0 | data byte |
| RD | 7:0 | `rd_data` | RO (pop) | 0x0 | data byte |
| RD | 8 | `rd_perr` | RO (pop) | 0x0 | the frame's parity failed |
| STATUS | 0 | `busy` | RO | core | a sequence is running |
| STATUS | 1 | `done_perr` | RO | core | a read frame of the last finished sequence failed its parity |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | SEQ_DONE | a sequence finished (STATUS.done_perr updated) |
| 1 | CMD_DONE | CMD beat accepted by the core |
| 2 | CMD_OVF | write to CMD while full (dropped) |
| 3 | WR_DONE | WR beat accepted by the core |
| 4 | WR_OVF | write to WR while full (dropped) |
| 5 | RD_AVAIL | RD captured a beat |
| 6 | RD_OVF | beat dropped, RD was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CMD_FULL | CMD holds a beat the core has not taken |
| 1 | WR_FULL | WR holds a beat the core has not taken |
| 2 | RD_AVAIL | RD holds an unread beat |

### Streams

* **CMD** feeds `cmd_type`, `cmd_sa`, `cmd_addr`, `cmd_bc`/`cmd_valid`. Writing CMD commits the beat: FLAGS.CMD_FULL is set and `cmd_valid` stays high until the core's `cmd_ready`; then CMD_DONE is set. A write while full is dropped and sets CMD_OVF.
* **WR** feeds `wr_data`/`wr_valid`. Writing WR commits the beat: FLAGS.WR_FULL is set and `wr_valid` stays high until the core's `wr_ready`; then WR_DONE is set. A write while full is dropped and sets WR_OVF.
* **RD** captures `rd_data`, `rd_perr` when `rd_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RD_AVAIL. Reading RD pops it. A beat that arrives while the register is full is dropped and sets RD_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x52460200.
2. Write 0x7F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7F enables all).
5. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD (0x018). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
6. To send on WR: wait until FLAGS.WR_FULL (bit 1) is 0, or for IRQ WR_DONE, then write WR (0x01C). The last write commits the beat. WR_OVF means a write came while the register was full and was dropped.
7. To receive on RD: wait for IRQ RD_AVAIL or FLAGS.RD_AVAIL (bit 2), then read RD (0x020). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RD_AVAIL (bit 5) to clear it. Read each beat before the next arrives, or it is dropped and RD_OVF is set.
8. Read STATUS (0x024) for the core's live `busy`, `done_perr`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Command and SSC

In IDLE (`cmd_ready` = 1) a command is taken at an edge with `cmd_valid`. Type 7 does nothing on
the bus: `done` pulses in the next clock (`done_perr` 0). Otherwise `sdata_oe` = 1 and SDATA = 1
from that edge (the SSC); SDATA goes low two ticks later (high for one SCLK period), and after two
more ticks the frames start; the first SCLK rise is at the next tick, so SDATA is low for three
half periods before it.

### 3.2 Frames

Each bit: at a tick with SCLK low, SCLK rises and SDATA takes the bit; at the next tick SCLK falls
(the slaves sample there). Frames in order:

| Type | Command C | Then |
|---|---|---|
| 0 | 1 D[6:0] (D = `cmd_addr[6:0]`) | bus park |
| 1 | 010 A[4:0] | one data frame, bus park |
| 2 | 011 A[4:0] | bus park, one read frame, slave park |
| 3 | 0000 BC | A[7:0], BC + 1 data frames, bus park |
| 4 | 0010 BC | A[7:0], bus park, BC + 1 read frames, slave park |
| 5 | 00110 BC[2:0] | A[15:8], A[7:0], BC[2:0] + 1 data frames, bus park |
| 6 | 00111 BC[2:0] | A[15:8], A[7:0], bus park, BC[2:0] + 1 read frames, slave park |

The command frame is {SA, C, P}; address and data frames are {D[7:0], P}.

### 3.3 Write data

Each data frame takes a byte at the falling tick that ends the previous frame: if `wr_valid` = 1
the byte is taken at that edge and `wr_ready` pulses in the next clock; otherwise the master
waits (WAIT) with SCLK low and SDATA held, and takes the byte at the first edge with `wr_valid`
(`wr_ready` in the next clock); the next SCLK rise follows one half period later.

### 3.4 Bus park and reads

Bus park: at a tick SCLK rises with SDATA 0 driven; at the next tick SCLK falls and `sdata_oe`
= 0. A write sequence then ends (`done`). A read continues: for each bit SCLK rises at a tick and
falls at the next, and the bit is the synchronised `sdata_i` (through two flops) at the falling
tick. After 9 bits `rd_valid` pulses with `rd_data` = D[7:0] and `rd_perr` = parity failed. After
the last frame the slave's park cycle (SCLK high for a half period, then low), then one more half
period, then `done` with `done_perr` = any read frame failed.

### 3.5 Reset

While `rst_n` is low: IDLE, SCLK 0, SDATA released, all pulses 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| no write byte ready | SCLK held low until `wr_valid` |
| read frame with bad parity | `rd_perr`, and `done_perr` at the end |
| no slave answers a read | the bus holder keeps SDATA low: reads 0x00 with a parity error |
| reserved command type 7 | `done` at once, no bus activity |
| `cfg_div` too small for the slave's delay | read bits sampled too early (not checked) |
| reset mid-sequence | bus released, SCLK low |

## 6. TB check map

Messages are printed by `tb/RFFE_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/RFFE_sva.sv`. Two `MIPI_RFFE_top` slaves (USID 5 and 2, 32 registers, no long
commands) and a TB slave model (USID 9, 256 registers, long commands, can corrupt a read parity
bit) share the bus with a pull-down; a line monitor checks the SSC shape, every frame's parity,
bus park cycles and half periods. Every command type goes to every slave, plus broadcast writes,
an absent slave, the reserved type, held-back write bytes, read parity errors, every `cfg_div`
and resets mid-sequence.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "SDATA driven by two" | the master never drives while a slave does | §3.4 |
| "SCLK high for" | SCLK high exactly one half period | §3.2 |
| "read byte" | each read byte as the slave's register | §3.4 |
| "read" | read count and parity flags as expected | §3.4 |
| "done with no command" | one `done` per command | §3.1, §3.4 |
| "done_perr" | `done_perr` = any read parity error | §3.4 |
| "sequence did not finish" | every sequence ends | §3.2 |
| "slave 5 register" | writes land in slave 5's registers | §3.2, §3.3 |
| "slave 2 register" | writes land in slave 2's registers | §3.2, §3.3 |
| "slave 9 register" | writes land in slave 9's registers | §3.2, §3.3 |
| "a slave saw an error" | every frame well-formed for the slaves | §3.1, §3.2 |
| "the slave model saw a parity error" | odd parity on every frame | §3.2 |
| a_ready | `cmd_ready` / `busy` as the checker's model | §3.1 |
| a_sclk | SCLK exactly as the model | §3.1..§3.4 |
| a_oe | `sdata_oe` as the model | §3.1, §3.4 |
| a_sdata | driven SDATA value as the model | §3.1, §3.2 |
| a_wr_ready | `wr_ready` as the model | §3.3 |
| a_rd_valid | `rd_valid` as the model | §3.4 |
| a_rd | `rd_data` / `rd_perr` as the model | §3.4 |
| a_done | `done` as the model | §3.1, §3.4 |
| a_done_perr | `done_perr` with `done` | §3.4 |
| a_reset | in reset: SCLK 0, released, idle | §3.5 |
