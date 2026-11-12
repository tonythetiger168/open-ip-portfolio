<!-- SPDX-License-Identifier: Apache-2.0 -->
# MIPI_RFFE: design specification

A MIPI RFFE slave (subset of RFFE v2.x): sequence start condition, register 0 write, register
write and read, extended register write and read (1..16 bytes), broadcast writes, odd parity on
every frame, and a 32 x 8 register file. Not implemented: extended long accesses, masked write,
interrupt / trigger registers, USID programming, half-speed reads, group slave IDs. Core
`MIPI_RFFE_top` (`rtl/MIPI_RFFE_top.sv`), testbench `tb/MIPI_RFFE_tb.sv` (an RFFE master with a
shadow register file), checker `tb/cov/MIPI_RFFE_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. SCLK and SDATA pass three flops; SCLK edges are seen two to three
clocks late, and the SDATA bit used at a falling SCLK edge is the value one flop newer. SCLK must be
slow compared with `clk` (the TB uses 10 clocks per half period). Frames are MSB first with an odd
parity bit (the frame including P has an odd number of ones).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; oversamples the bus | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset (also clears the register file) | low | async | - |
| `sclk` | input | 1 | RFFE SCLK from the master (asynchronous, three-flop synchronised) | - | async | - |
| `sdata` | inout | 1 | RFFE SDATA; the slave drives it only for read data and its bus park | - | async | - |
| `irq` | output | 1 | protocol error (parity or unsupported command), held until the next SSC | high | `clk` | 0 |

### Internal signals used by the verification

The TB and the bound checker read these by name; the FSM coverage collector binds `state`.

| Signal | Width | Meaning |
|---|---|---|
| `drv_en` | 1 | the slave drives SDATA |
| `mem` | 32 x 8 | register file, register k = `mem[k]` |
| `state` | 3 | 0 IDLE, 1 COMMAND, 2 ADDRESS, 3 WRITE DATA, 4 BUS PARK, 5 READ DATA, 6 SLAVE PARK |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/MIPI_RFFE.md`](../ip/MIPI_RFFE.md) (source: `scripts/apb/specs/MIPI_RFFE.json`); do not edit by hand.

`MIPI_RFFE_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `sdata`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x52660200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5266 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PROTO | a sequence was aborted: command, address or data parity error, or an unsupported command. Held in the core until the next SSC, so the bit is set again on every clock until then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x52660200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Sequence start condition (SSC)

An SSC is SDATA rising and then falling while SCLK stays low (seen low at both synchronised
samples throughout). It is recognised in every state in which the slave is not driving (not READ
DATA or SLAVE PARK), so an SSC aborts any sequence. An SSC clears `irq` and starts a command
frame. An SDATA pulse with SCLK high is not an SSC.

### 3.2 Command frame

13 bits sampled at SCLK falling edges: SA[3:0], C[7:0], P. On the 13th:

* parity wrong: `irq`, IDLE;
* SA = `USID`, or SA = 0 (broadcast) for writes:

| C | Command | Next |
|---|---|---|
| 1DDDDDDD | register 0 write: register 0 = {0, D[6:0]} | IDLE |
| 010AAAAA | register write to A | one data frame |
| 011AAAAA | register read of A (own SA only) | bus park, one read frame |
| 0000BBBB | extended write, BC = B | address frame, BC + 1 data frames |
| 0010BBBB | extended read (own SA only) | address frame, bus park, BC + 1 read frames |
| other | unsupported | `irq`, IDLE |

* other SA, or a broadcast read: ignored silently (IDLE).

### 3.3 Address and write data frames

9 bits (8 data + P) at falling edges. A parity error sets `irq` and ends the sequence (frames
before it stay written). Address frame: sets the register address. Data frame: writes the
register (addresses 32..255 are ignored), the address + 1; after the last frame IDLE (the
master's bus park that follows is ignored).

### 3.4 Read

After the command (or address) frame the next SCLK rising edge is the master's bus park. From the
following rising edge the slave drives SDATA, one bit per rising edge: D7..D0 of the register
(0 for addresses 32..255), then the odd parity bit; the address + 1. For an extended read the next
byte's D7 follows at the next rising edge, until BC + 1 frames are sent. Then the slave drives 0
for one rising edge (slave bus park) and releases SDATA at the next falling edge.

### 3.5 Reset

While `rst_n` is low: IDLE, SDATA released, `irq` 0, every register 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `USID` | 4'h5 | 1..15 | unique slave ID this slave answers |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| command, address or data parity error | `irq`, sequence ended |
| unsupported command | `irq` |
| other slave's traffic | ignored, no `irq` |
| broadcast read | ignored, no `irq`, SDATA not driven |
| address past the 32 registers | reads 0, writes ignored; extended accesses go on incrementing |
| SSC in the middle of a sequence | aborts it, new command |
| SDATA pulse with SCLK high | not an SSC |
| reset while the slave drives | released at once |

## 6. TB check map

Messages are printed by `tb/MIPI_RFFE_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the
bound checker `tb/cov/MIPI_RFFE_sva.sv`. An RFFE master (SCLK half period 10 clocks, a bus keeper
to 0) runs register 0 writes, register writes and reads, extended writes and reads of 1..16 bytes
across the end of the register file, broadcast writes, other slaves' traffic, every parity error,
unsupported commands, an aborting SSC, back-to-back sequences and a reset while the slave drives.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "read frame" | read frames carry odd parity | §3.4 |
| "slave bus park not driven low" | the slave drives 0 for its bus park | §3.4 |
| "slave did not release SDATA" | released after the bus park | §3.4 |
| "read reg" | register read returns the register | §3.2, §3.4 |
| "other-SA read answered" | no answer to other SAs | §3.2 |
| "ext read" | extended read returns consecutive registers (0 past the end) | §3.4 |
| "irq" | `irq` after each case as expected | §3.2, §3.3 |
| "reg" | register file as the shadow model | §3.2, §3.3 |
| "reset state" | `irq` 0, released | §3.5 |
| "SDATA pulse with SCLK high taken as SSC" | not an SSC | §3.1 |
| "drive kept through reset" | reset releases SDATA | §3.5 |
| a_reset_released | in reset: released, no `irq` | §3.5 |
| a_irq_model | `irq` exactly as the checker's model | §3.2, §3.3 |
| a_drive_enable_model | `drv_en` as the model | §3.4 |
| a_drive_value_model | driven SDATA value as the model | §3.4 |
| a_regs_model | `mem` as the model | §3.2, §3.3 |
| a_ssc_clears_irq | `irq` 0 after an SSC | §3.1 |
| a_drive_only_in_read | the slave drives only in read data or its bus park | §3.4 |
