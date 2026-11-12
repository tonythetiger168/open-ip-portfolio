<!-- SPDX-License-Identifier: Apache-2.0 -->
# Avalon_MM: design specification

Avalon Memory-Mapped agent (slave) with a 256 x 32-bit register file: `av_waitrequest`
backpressure, pipelined read data on `av_readdatavalid`, read and write bursts of up to 16 beats,
byte enables, a zero-wait "fast" window, a one-wait "slow" window, and out-of-range beats that are
dropped (writes) or return zero (reads) while setting a sticky `irq`. Core `Avalon_MM_top`
(`rtl/Avalon_MM_top.sv`), testbench `tb/Avalon_MM_tb.sv` (an Avalon host model with an in-order
read scoreboard), checker `tb/cov/Avalon_MM_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A command (or a write beat) is taken at a rising edge where it is
presented and `av_waitrequest` is 0.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the state and `irq` (not the register file) | low | async | - |
| `av_address` | input | `AW` | byte address of a command; bits 1:0 ignored (§3.1); held while `av_waitrequest` is 1 | - | `clk` | - |
| `av_read` | input | 1 | read command | high | `clk` | - |
| `av_write` | input | 1 | write command / write data beat | high | `clk` | - |
| `av_writedata` | input | `DW` | write data of the current beat | - | `clk` | - |
| `av_byteenable` | input | 4 | byte lane k of the beat is written when bit k is 1 | high | `clk` | - |
| `av_burstcount` | input | 8 | beats of the burst, sampled with the command: 0 means 1, 1 to 16 as given, above 16 clamped to 16 (and `irq`) | - | `clk` | - |
| `av_readdata` | output | `DW` | read data: the word at the running burst address, 0 when that address is >= 0x400; combinational, meaningful with `av_readdatavalid` | - | comb | word 0 |
| `av_readdatavalid` | output | 1 | one read beat in this clock | high | comb | 0 |
| `av_waitrequest` | output | 1 | command / write beat not taken in this clock (§3.2); combinational | high | comb | 0 |
| `irq` | output | 1 | sticky error flag (§3.5), cleared only by reset | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 2 | 0 IDLE (takes commands), 1 WRB (write burst: takes beats 2..n), 2 RDD (read burst: returns beats); 3 never occurs |
| `beats_left` | 5 | beats still to transfer in WRB / RDD (never above 16) |
| `cur_addr` | 33 | running burst address (bit 32 set once a burst runs past 0xFFFFFFFF) |
| `mem` | 256 x `DW` | the register file; `av_readdata` = `mem[cur_addr[9:2]]` when `cur_addr` < 0x400, else 0, at every clock |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Avalon_MM.md`](../ip/Avalon_MM.md) (source: `scripts/apb/specs/Avalon_MM.json`); do not edit by hand.

`Avalon_MM_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `av_address`, `av_read`, `av_write`, `av_writedata`, `av_byteenable`, `av_burstcount`, `av_readdata`, `av_readdatavalid`, `av_waitrequest`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x414D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x414D | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | an access outside the memory, a burstcount above 16, or read and write asserted together; the core holds this until reset, so the bit cannot be cleared before then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x414D0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Address map and storage

| Byte address | Window | Wait |
|---|---|---|
| 0x000 - 0x1FF | fast | none |
| 0x200 - 0x3FF | slow | one wait state per command / write beat; one bubble before each read beat |
| 0x400 and up | out of range | as fast; write beats dropped, read beats return 0; `irq` |

Word `addr[9:2]` of the 256-word register file; address bits 1:0 are ignored (a misaligned
address is not an error). Each burst beat adds 4 to the address, as a 33-bit value, so a burst
that runs past 0xFFFFFFFF stays out of range and never wraps into the register file. The window
is decided per beat. The register file is not reset; it keeps its contents through `rst_n` and is
undefined until written (a 2-state simulator shows 0; the checker's shadow starts at 0).

### 3.2 Waitrequest

| State | `av_waitrequest` |
|---|---|
| IDLE, no command | 0 |
| IDLE, command to the fast window or out of range | 0 (taken at once) |
| IDLE, command to the slow window | 1 in the first clock it is presented, 0 in the next (exactly one wait state) |
| WRB, no `av_write` | 0 |
| WRB, beat to the fast window or out of range | 0 |
| WRB, beat to the slow window | 1 in the first clock, 0 in the next |
| RDD | 1 in every clock: no new command is taken until every read beat has been returned |

The host must hold a command (or a beat) with its address, data and byte enables while
`av_waitrequest` is 1.

### 3.3 Write

* The command clock carries beat 1: when a write command is taken, its data is written at once
  (byte lanes per `av_byteenable`) if the address is < 0x400; beats = `av_burstcount` clamped
  (0 -> 1, > 16 -> 16). With one beat the core stays in IDLE.
* With more beats the core enters WRB at address + 4; each later clock with `av_write` = 1 and
  `av_waitrequest` = 0 takes one beat at the running address (+ 4 per beat). Clocks with
  `av_write` = 0 are gaps. After the last beat it returns to IDLE.
* A beat to an address >= 0x400 is dropped and sets `irq`.
* `av_read` is ignored in WRB: a read presented during a write burst is not taken, although
  `av_waitrequest` can be 0 (§5).
* If `av_read` and `av_write` are both 1 on a command, it is a write and `irq` is set.

### 3.4 Read

* A read command taken at edge e enters RDD with the address and the clamped beat count. The
  first beat can be returned in the clock after e.
* In RDD each clock returns one beat (`av_readdatavalid` = 1, `av_readdata` = word at the running
  address), except that a beat in the slow window is preceded by one bubble clock
  (`av_readdatavalid` = 0). After a beat the address steps + 4. After the last beat the core is in
  IDLE again, so a new command can be taken in the clock after it.
* Every requested beat is returned, also when the burst starts or runs out of range: those beats
  carry 0 and each sets `irq`. The host never waits for data that does not come.
* `av_readdata` is read live from the register file (combinational).

### 3.5 irq

`irq` is set at the edge after any of these and stays 1 until reset:

* a command taken with `av_read` and `av_write` both 1;
* a command taken with `av_burstcount` > 16;
* a write beat (command or later) to an address >= 0x400;
* a read beat returned from an address >= 0x400.

### 3.6 Reset

While `rst_n` is low: IDLE, `av_waitrequest` 0 (with no slow command presented),
`av_readdatavalid` 0, `irq` 0, `beats_left` 0, `cur_addr` 0. A burst in progress is abandoned;
beats already written stay.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | 32 | data width; four byte lanes (`av_byteenable` is 4 bits) |
| `AW` | 32 | 32 | address width; the address decode is written for 32 bits |
| `DEPTH` | 256 | 256 | register-file words; the decode always uses `addr[9:2]` and the 0x400 limit |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `av_burstcount` = 0 | one beat, no error |
| `av_burstcount` > 16 | 16 beats, `irq` |
| `av_read` and `av_write` together | write, `irq` |
| write beat at >= 0x400 | dropped, `irq`; the burst continues |
| read burst starting or running out of range | all beats returned, those out of range carry 0, `irq` |
| burst past 0xFFFFFFFF | stays out of range (33-bit address), never aliases to 0x0 |
| misaligned address | bits 1:0 ignored |
| command presented during RDD | held off by `av_waitrequest` until the burst has drained |
| read presented during a write burst | ignored (not taken) while `av_waitrequest` may be 0; the host must not issue it there |
| gaps between write beats | allowed |
| reset mid write burst | abandoned; earlier beats remain written |

## 6. TB check map

Messages are printed by `tb/Avalon_MM_tb.sv` as `ERROR: <message>`; its immediate checks print
`SVA_FAIL: <name>`. Assertions `a_*` are in the bound checker `tb/cov/Avalon_MM_sva.sv`, which
keeps its own state machine and shadow register file. The TB checks reset, single and burst
reads / writes in both windows, byte-enable merges, wait states, out-of-range bursts and single
accesses, bursts wrapping past 4 GB, a command held while read data drains, reset mid burst,
and (Verilator) random traffic over every error class.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "unexpected readdatavalid data" | no read beat that the scoreboard does not expect | §3.4 |
| "readdata mismatch beat" | each read beat equals the expected word (0 out of range) | §3.4 |
| "write timeout" | a single write is taken within 100 clocks | §3.2 |
| "write burst timeout beat" | each write burst beat is taken within 100 clocks | §3.2 |
| "read cmd timeout" | a read command is taken within 100 clocks | §3.2 |
| "readdatavalid never arrived" | a single read returns its beat | §3.4 |
| "read burst cmd timeout" | a read burst command is taken | §3.2 |
| "read burst" | a read burst returns all its beats | §3.4 |
| "bad reset state wr" | out of reset: `av_waitrequest`, `av_readdatavalid`, `irq` 0 | §3.6 |
| "waitrequest never asserted on slow window" | a slow-window command gets a wait state | §3.2 |
| "waitrequest never asserted in slow burst" | slow-window write beats get wait states | §3.2 |
| "irq not set after out-of-range write burst" | dropped write beats set `irq` | §3.5 |
| "out-of-range read burst beats" | an out-of-range read burst returns all 8 beats | §3.4 |
| "irq not set after out-of-range read burst" | zero read beats set `irq` | §3.5 |
| "out-of-range read returned" | a single out-of-range read returns exactly 1 beat | §3.4 |
| "irq not set after out-of-range single access" | single out-of-range access sets `irq` | §3.5 |
| "held command" | a command presented during RDD is held, then served (5 beats in all) | §3.2 |
| "outputs not quiescent in reset" | reset mid burst: `av_readdatavalid`, `irq` 0 | §3.6 |
| "waitrequest after reset" | `av_waitrequest` 0 after reset with no command | §3.6 |
| "CRV read burst t" | random read burst returns the clamped beat count | §3.4 |
| "CRV" | random traffic: no expected beat missing | §3.4 |
| "CRV irq not sticky after error classes" | `irq` still 1 after the random error classes | §3.5 |
| "A1 reset: outputs quiescent" | in reset: `av_readdatavalid`, `irq` 0 | §3.6 |
| "A2 rdv only in AV_RDD" | read beats only in RDD | §3.4 |
| "A3 AV_RDD => waitrequest" | `av_waitrequest` in every RDD clock | §3.2 |
| "A4 beats_left <= 16" | `beats_left` never above 16 | §1 |
| "A5 state legal" | `state` <= 2 | §1 |
| "A6 readdata == mem[cur] (zero out of range)" | `av_readdata` = `mem[cur_addr[9:2]]`, 0 at >= 0x400 | §3.4 |
| a_reset_quiet | in reset: `av_readdatavalid`, `irq` 0 | §3.6 |
| a_rdd_blocks | `av_waitrequest` in RDD | §3.2 |
| a_fast_cmd_no_wait | fast / out-of-range command: no wait | §3.2 |
| a_slow_cmd_waits | slow command: wait in its first clock | §3.2 |
| a_slow_cmd_one_wait | slow command: taken in its second clock | §3.2 |
| a_fast_beat_no_wait | fast write beat: no wait | §3.2 |
| a_slow_beat_waits | slow write beat: wait in its first clock | §3.2 |
| a_slow_beat_one_wait | slow write beat: taken in its second clock | §3.2 |
| a_wrb_idle_no_wait | WRB without `av_write`: no wait | §3.2 |
| a_idle_no_wait | IDLE without a command: no wait | §3.2 |
| a_rdv_model | `av_readdatavalid` exactly on the model's read-beat clocks (slow bubbles) | §3.4 |
| a_rdata_model | read beat data = shadow word, 0 out of range | §3.4 |
| a_irq_sticky | `irq` stays 1 | §3.5 |
| a_irq_on_error | each error event sets `irq` by the next clock | §3.5 |
| a_irq_cause | `irq` rises only after an error event | §3.5 |
