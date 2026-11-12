<!-- SPDX-License-Identifier: Apache-2.0 -->
# AHB: design specification

AMBA AHB-Lite slave with a 256 x 32-bit register file and three address regions: 0x000-0x3FF
answers with zero wait states, 0x400-0x7FF reaches the same register file with one wait state,
and 0x800-0xFFF is reserved and answered with the two-cycle ERROR response plus an `irq` pulse.
Address and data phases are pipelined: the next address is taken in the cycle the current data
phase completes. Core `AHB_top` (`rtl/AHB_top.sv`), testbench `tb/AHB_tb.sv`, checker
`tb/cov/AHB_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *transfer* is an address phase with `hsel` = 1, `hready` = 1 and
`htrans` NONSEQ or SEQ; its data phase starts in the next cycle and ends in the cycle where
`hreadyout` = 1.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | HCLK | rising edge | - | - |
| `rst_n` | input | 1 | HRESETn: asynchronous reset of the pipeline, the response state and the register file | low | async assert | - |
| `hsel` | input | 1 | slave select | high | `clk` | - |
| `htrans` | input | 2 | 00 IDLE, 01 BUSY, 10 NONSEQ, 11 SEQ; only NONSEQ and SEQ start a transfer | - | `clk` | - |
| `haddr` | input | `AW` | byte address; bits [11:10] select the region, bits [9:2] the word; bits above 11 are ignored | - | `clk` | - |
| `hwrite` | input | 1 | 1 write, 0 read | high | `clk` | - |
| `hsize` | input | 3 | ignored: every transfer is treated as a 32-bit word | - | - | - |
| `hwdata` | input | `DW` | write data, sampled in the last cycle of the write's data phase | - | `clk` | - |
| `hrdata` | output | `DW` | read data of the current data phase (combinational from the register file); 0 outside a read data phase and during ERROR | - | comb. | 0 |
| `hready` | input | 1 | bus HREADY (the previous data phase on the bus is complete); gates the address capture | high | `clk` | - |
| `hreadyout` | output | 1 | this slave's data phase completes in this cycle | high | comb. | 1 |
| `hresp` | output | 1 | 0 OKAY, 1 ERROR | high | comb. | 0 |
| `irq` | output | 1 | one-cycle pulse in the first cycle of every ERROR response | high | comb. | 0 |

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 2 | data-phase state, encoded NORM = 0 (first data cycle), SLOW = 1 (completing cycle of a slow transfer), ERR2 = 2 (second ERROR cycle) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/AHB.md`](../ip/AHB.md) (source: `scripts/apb/specs/AHB.json`); do not edit by hand.

`AHB_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `hsel`, `htrans`, `haddr`, `hwrite`, `hsize`, `hwdata`, `hrdata`, `hready`, `hreadyout`, `hresp`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41480200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4148 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a transfer to the reserved region (HADDR[11] set) got the two-cycle ERROR response |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41480200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Address phase

At a `clk` edge where `hreadyout` = 1 (the current data phase, if any, completes):

- `hsel && hready && htrans[1]`: the transfer is captured (direction, address, region = slow if
  `haddr[11:10]` = 01, reserved if `haddr[11]` = 1) and occupies the data phase from the next
  cycle.
- otherwise (IDLE, BUSY, not selected): the next cycle has no data phase.

While `hreadyout` = 0 nothing is captured; the master holds the next address, as AHB requires.
BUSY inside a burst therefore just gives a cycle without a data phase.

### 3.2 Data phase

| Region | Cycle 1 | Cycle 2 |
|---|---|---|
| fast (0x000-0x3FF) | `hreadyout` = 1, `hresp` = OKAY: completes | - |
| slow (0x400-0x7FF) | `hreadyout` = 0, `hresp` = OKAY (wait) | `hreadyout` = 1, OKAY: completes |
| reserved (0x800-0xFFF) | `hreadyout` = 0, `hresp` = ERROR, `irq` = 1 | `hreadyout` = 1, `hresp` = ERROR |
| no transfer | `hreadyout` = 1, OKAY | - |

- Write: at the edge that ends the completing cycle, word `addr[9:2]` <= `hwdata`. The slow region
  writes the same word as the fast region (0x408 and 0x008 are the same register).
- Read: `hrdata` = word `addr[9:2]` for every cycle of the data phase (also the wait cycle), so a
  read right after a write to the same word returns the new value.
- ERROR: the register file is not touched and `hrdata` = 0. In the second ERROR cycle
  `hreadyout` = 1, so the next address is captured then (the master may also change it to IDLE,
  as AHB-Lite allows).

Back-to-back fast transfers complete one per cycle; a slow transfer costs one extra cycle; an
ERROR costs two cycles.

### 3.3 Reset

`rst_n` low: no data phase, `state` = NORM, so `hreadyout` = 1, `hresp` = OKAY, `irq` = 0,
`hrdata` = 0; every register-file word is cleared to 0. A transfer waiting in its slow cycle is
dropped without writing.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | 32 | data width; the word index is `haddr[9:2]`, i.e. 4-byte words |
| `AW` | 32 | 12 to 32 | address width; only bits [11:2] are decoded, higher bits are ignored (the 4 KB map repeats) |
| `DEPTH` | 256 | 256 | register-file depth; the index is 8 bits (`haddr[9:2]`), so only 256 is consistent |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| address 0x800-0xFFF | two-cycle ERROR, `irq` pulse in cycle 1, no write, `hrdata` = 0 |
| address >= 0x1000 | aliases into 0x000-0xFFF (bits above 11 ignored) |
| `hsize` other than word | ignored: full-word write and read |
| unaligned address | bits [1:0] ignored |
| IDLE or BUSY, or `hsel` = 0 | no data phase, stays ready and OKAY |
| next transfer presented during a slow wait or ERROR cycle 1 | held by the master, captured in the completing cycle |
| reset during a wait cycle | outputs quiet at once, register file cleared |

## 6. TB check map

Messages are printed by `tb/AHB_tb.sv` through `chk()` as `ERROR: <message>` (A1..A6 as
`SVA_FAIL:`); "crv" messages and A1..A6 are built only for Verilator. Assertions a_* are in
`tb/cov/AHB_sva.sv`. The TB is an AHB-Lite master with `hready` tied to `hreadyout`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "TIMEOUT guard fired" | the test finishes (no hang in a wait state) | §3.2 |
| "pipe_w: idle cycle must be ready" | ready before a burst | §3.2 |
| "pipe_w: beat0 not single-cycle OKAY" | pipelined fast write burst: beat 0 completes in one cycle | §3.1, §3.2 |
| "pipe_w: beat1 not single-cycle OKAY" | beat 1 | §3.2 |
| "pipe_w: beat2 not single-cycle OKAY" | beat 2 | §3.2 |
| "pipe_w: beat3 not single-cycle OKAY" | beat 3 | §3.2 |
| "pipe_r: beat0 not single-cycle" | pipelined fast read burst completes one per cycle | §3.2 |
| "pipe_r: beat0 data mismatch" | read data beat 0 | §3.2 |
| "pipe_r: beat1 data mismatch" | beat 1 | §3.2 |
| "pipe_r: beat2 data mismatch" | beat 2 | §3.2 |
| "pipe_r: beat3 data mismatch" | beat 3 | §3.2 |
| "pipe_pair: A read data" | random pairs of overlapped transfers in any regions: first read data | §3.1, §3.2 |
| "pipe_pair: A response" | first response OKAY / ERROR by region | §3.2 |
| "pipe_pair: B read data" | second read data | §3.2 |
| "pipe_pair: B response" | second response | §3.2 |
| "A1 reset: outputs quiescent" | in reset ready, OKAY, no `irq`, `hrdata` = 0 | §3.3 |
| "A2 irq implies hresp ERROR" | `irq` only with ERROR | §3.2 |
| "A3 two-cycle ERROR response" | ERROR with `hreadyout` = 0 is followed by ERROR with `hreadyout` = 1 | §3.2 |
| "A4 state encoding legal" | `state` <= 2 | §1 |
| "A5 hrdata zero on ERROR" | `hrdata` = 0 during ERROR | §3.2 |
| "A6 irq single-cycle pulse" | `irq` never two cycles in a row | §3.2 |
| "crv: idle cycle must be ready" | random single transfers: ready when idle | §3.2 |
| "crv fast: single-cycle OKAY" | fast region zero wait | §3.2 |
| "crv fast: read data mismatch" | fast read data | §3.2 |
| "crv slow: wait cycle must be OKAY" | slow region: one wait cycle, OKAY | §3.2 |
| "crv slow: second cycle must complete" | slow completes in cycle 2 | §3.2 |
| "crv slow: read data mismatch" | slow read data (aliased word) | §3.2 |
| "crv err: cycle1 ERROR/stall" | reserved: ERROR cycle 1 | §3.2 |
| "crv err: irq event expected" | `irq` in cycle 1 | §3.2 |
| "crv err: cycle2 ERROR/complete" | ERROR cycle 2 | §3.2 |
| "crv err: must recover to OKAY/ready" | ready and OKAY after the ERROR | §3.2 |
| "reset: hreadyout must be 1" | reset state | §3.3 |
| "reset: hresp must be OKAY" | reset state | §3.3 |
| "reset: hrdata must be 0" | reset state | §3.3 |
| "reset: irq must be 0" | reset state | §3.3 |
| "busy: BUSY must not stall slave" | BUSY inside a burst: no data phase, ready | §3.1 |
| "busy: recovery after BUSY" | burst continues after BUSY | §3.1 |
| "busy: beat after BUSY must complete" | the SEQ beat after BUSY completes | §3.1, §3.2 |
| "slow: first data cycle must insert wait" | slow write: cycle 1 `hreadyout` = 0 | §3.2 |
| "slow: wait cycle must be OKAY" | wait cycle OKAY | §3.2 |
| "slow: second data cycle must complete" | completes in cycle 2 | §3.2 |
| "slow rd: wait cycle expected" | slow read: wait cycle | §3.2 |
| "slow rd: data mismatch" | slow read returns the aliased fast word | §3.2 |
| "error: cycle1 resp=ERROR readyout=0" | reserved address: cycle 1 | §3.2 |
| "error: irq event expected on ERROR response" | `irq` in cycle 1 | §3.2 |
| "error: cycle2 resp=ERROR readyout=1" | cycle 2 | §3.2 |
| "error: must recover to OKAY/ready" | back to OKAY | §3.2 |
| "idle/unsel: slave must stay ready" | selected IDLE and unselected NONSEQ start nothing | §3.1 |
| "idle/unsel: no data phase" | ... and write nothing | §3.1 |
| "slow+pipe: wait cycle expected" | next address held through the slow wait | §3.1, §3.2 |
| "slow+pipe: completion" | slow write completes and the next read is captured | §3.1 |
| "slow+pipe: read after slow write" | the read returns the right word | §3.2 |
| "err+pipe: cycle1" | ERROR cycle 1 with the next address presented | §3.2 |
| "err+pipe: cycle2" | ERROR cycle 2 captures the next address | §3.2 |
| "err+pipe: read after ERROR" | that read returns the aliased slow write | §3.2 |
| "reset-in-wait: wait cycle expected" | slow write in its wait cycle | §3.2 |
| "reset-in-wait: outputs quiescent" | reset then: outputs quiet, register file cleared | §3.3 |
| a_reset_quiet | in reset ready, OKAY, no `irq`, `hrdata` = 0 | §3.3 |
| a_idle_okay | no data phase: ready and OKAY | §3.2 |
| a_fast_zero_wait | fast transfer: ready and OKAY | §3.2 |
| a_slow_wait | slow transfer cycle 1: wait, OKAY | §3.2 |
| a_slow_done | slow transfer cycle 2: complete, OKAY | §3.2 |
| a_err_cycle1 | reserved cycle 1: ERROR, wait, `irq` | §3.2 |
| a_err_cycle2 | ERROR cycle 1 is followed by ERROR with ready | §3.2 |
| a_hresp_only_err | ERROR only for reserved transfers | §3.2 |
| a_irq_only_err1 | `irq` only in ERROR cycle 1 | §3.2 |
| a_wait_bounded | at most one wait cycle per data phase | §3.2 |
| a_rdata_model | read data equals a shadow register file | §3.2 |
| a_rdata_zero | `hrdata` = 0 outside read data phases | §1 |
