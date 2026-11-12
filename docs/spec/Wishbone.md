<!-- SPDX-License-Identifier: Apache-2.0 -->
# Wishbone: design specification

Wishbone B4 pipelined slave with a 256 x 32-bit register file: `stall_o` back-pressure, a 2-deep
in-order request queue, one `ack_o` / `err_o` per request, byte selects, a fast window, a slow
window with two wait clocks, a hole that answers without effect, and a reserved window that
answers `err_o` and sets a sticky `irq`. Classic cycles (`cti_i` = 000) are supported through a
re-accept guard. Core `Wishbone_top` (`rtl/Wishbone_top.sv`), testbench `tb/Wishbone_tb.sv` (a
Wishbone master model with an in-order response scoreboard), checker `tb/cov/Wishbone_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A request is "taken" in a clock where `cyc_i`, `stb_i` are 1,
`stall_o` is 0 and the classic guard (§3.3) is clear; it enters the queue at the end of that clock.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | CLK_I | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset (active-low RST_I) of the queue, the service state and `irq` (not the register file) | low | async | - |
| `cyc_i` | input | 1 | CYC_I: bus cycle in progress; a request needs `cyc_i` and `stb_i` | high | `clk` | - |
| `stb_i` | input | 1 | STB_I: request strobe | high | `clk` | - |
| `we_i` | input | 1 | WE_I: 1 write, 0 read | - | `clk` | - |
| `adr_i` | input | `AW` | ADR_I, byte address; word `adr_i[9:2]`, bits 1:0 ignored | - | `clk` | - |
| `dat_i` | input | `DW` | DAT_I, write data | - | `clk` | - |
| `sel_i` | input | 4 | SEL_I: byte lane k written when bit k is 1 | high | `clk` | - |
| `cti_i` | input | 3 | CTI_I: 000 classic cycle (§3.3); any other value is handled as pipelined | - | `clk` | - |
| `dat_o` | output | `DW` | DAT_O: read data of the queue head, valid with `ack_o` (§3.2); combinational | - | comb | 0 |
| `ack_o` | output | 1 | ACK_O: the head request completes normally in this clock | high | comb | 0 |
| `stall_o` | output | 1 | STALL_O: request queue full (2 outstanding); no request is taken | high | comb | 0 |
| `err_o` | output | 1 | ERR_O: the head request (reserved window) completes with an error in this clock | high | comb | 0 |
| `rty_o` | output | 1 | RTY_O: tied to 0 | - | const | 0 |
| `irq` | output | 1 | sticky: set at the end of the first `err_o` clock, cleared only by reset | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 2 | service state of a slow head: 0 S_IDLE, 1 S_WAIT, 2 S_RESP; 3 never occurs |
| `q_count` | 2 | requests in the queue (0 to 2); `stall_o` = (`q_count` == 2) |
| `q_ok` | 2 x 1 | per queue entry: the address is in the register file (< 0x400); entry 0 is the head |
| `q_we` | 2 x 1 | per queue entry: write |
| `q_idx` | 2 x 8 | per queue entry: word index `adr_i[9:2]` |
| `mem` | 256 x `DW` | the register file; `dat_o` = `mem[q_idx[0]]` when `q_ok[0]` and not `q_we[0]`, else 0, at every clock |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Wishbone.md`](../ip/Wishbone.md) (source: `scripts/apb/specs/Wishbone.json`); do not edit by hand.

`Wishbone_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `cyc_i`, `stb_i`, `we_i`, `adr_i`, `dat_i`, `sel_i`, `cti_i`, `dat_o`, `ack_o`, `stall_o`, `err_o`, `rty_o`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x57420200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5742 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a request to the reserved region (address 0x800 and up) was answered with ERR; the core holds this until reset, so the bit cannot be cleared before then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x57420200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Address map

| Byte address | Window | Response |
|---|---|---|
| 0x000 - 0x1FF | fast | `ack_o` in the first clock the request is at the queue head |
| 0x200 - 0x3FF | slow | `ack_o` in the third clock the request is at the queue head (two wait clocks) |
| 0x400 - 0x7FF | hole | `ack_o` like the fast window; reads return 0, writes are dropped; no error |
| 0x800 and up | reserved | `err_o` like the fast window; nothing written; `irq` set |

Word `adr_i[9:2]`; address bits 1:0 are ignored. The register file is not reset; it keeps its
contents through `rst_n` and is undefined until written (a 2-state simulator shows 0; the
checker's shadow starts at 0).

### 3.2 Queue and responses

* Up to 2 requests are outstanding. `stall_o` = 1 exactly when 2 are queued; a response and a new
  request can happen in the same clock (the slot is reused from the next clock).
* A request taken in clock a is at the head from clock a+1 if the queue was empty (or the head
  responds in clock a). Responses are strictly in order, one per clock at most: a fast head
  answers in its first clock at the head, so pipelined fast requests are answered back to back,
  one clock after each was taken. A slow head moves S_IDLE -> S_WAIT -> S_RESP and answers in
  S_RESP; requests behind it wait.
* The response clock is when the request takes effect: a write lands in the register file (bytes
  with `sel_i[k]` = 1) at the end of its `ack_o` clock; a read's `dat_o` is the word read in its
  `ack_o` clock, so it sees every earlier write. `dat_o` is 0 for writes, the hole and the
  reserved window.
* `ack_o` and `err_o` are never 1 together. `cyc_i` is not checked after a request is taken:
  requests in the queue are answered even if the master drops `cyc_i`.

### 3.3 Classic cycles

A classic master (`cti_i` = 000) holds `stb_i` until it sees `ack_o`. So after a classic request is
taken, no further request is taken until `stb_i` goes low or the last outstanding request
responds; in the clock after that response a held strobe (the next beat of a classic block cycle,
with its new address) is taken. Pipelined requests (`cti_i` != 000) are taken in every clock
`stall_o` is 0.

### 3.4 irq

`irq` is set at the end of every `err_o` clock and stays 1 until reset.

### 3.5 Reset

While `rst_n` is low: queue empty, S_IDLE, `ack_o` = `err_o` = `stall_o` = `irq` = 0, classic guard
clear. Queued requests are dropped (queued writes never land).

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | 32 | data width; four byte selects |
| `AW` | 32 | 32 | address width; the window decode compares 32-bit constants |
| `DEPTH` | 256 | 256 | register-file words; the decode always uses `adr_i[9:2]` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| address >= 0x800 | `err_o` (fast timing), nothing written, `dat_o` 0, `irq` sticky |
| address 0x400 - 0x7FF | `ack_o`, read 0, write dropped, no `irq` |
| queue full | `stall_o`; the strobe must be held |
| fast request behind a slow one | waits for the slow response (in order) |
| read behind a queued write to the same word | sees the new data (writes land at their response) |
| classic strobe held after its ack | taken once as the next request, not re-taken before |
| `cyc_i` dropped with requests queued | they are still answered |
| reset with requests queued | dropped |

## 6. TB check map

Messages are printed by `tb/Wishbone_tb.sv` as `ERROR: <message>`; its immediate checks print
`SVA_FAIL: <name>`. Assertions `a_*` are in the bound checker `tb/cov/Wishbone_sva.sv`, which keeps
an independent 2-deep request model and a shadow register file. The TB checks reset, single
reads / writes in every window, byte selects, pipelined bursts that fill the queue, the reserved
window with `irq`, a classic block cycle, reset with requests queued, data classes, and
(Verilator) random traffic.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "unexpected response ack" | no response without a queued request | §3.2 |
| "expected err_o, got ack_o" | reserved window answers `err_o` | §3.1 |
| "expected ack_o, got err_o" | other windows answer `ack_o` | §3.1 |
| "read data mismatch resp" | read data in order equals the scoreboard (0 for the hole) | §3.2 |
| "stall timeout" | `stall_o` releases within 100 clocks | §3.2 |
| "write ack timeout" | a write is answered | §3.2 |
| "read ack timeout" | a read is answered | §3.2 |
| "reserved access acked" | no `ack_o` for the reserved window | §3.1 |
| "err timeout" | a reserved access gets `err_o` | §3.1 |
| "bad reset state ack" | out of reset: `ack_o`, `err_o`, `stall_o`, `rty_o` 0 | §3.5 |
| "irq high after reset" | `irq` 0 after reset | §3.5 |
| "stall_o never asserted (backpressure not real)" | a pipelined burst fills the queue and stalls | §3.2 |
| "irq not set after reserved access" | `err_o` sets `irq` | §3.4 |
| "classic block cycle: second beat never acked" | the held classic strobe is taken as the next beat | §3.3 |
| "outputs not quiescent in reset" | in reset outputs idle | §3.5 |
| "rty_o must be tied 0" | `rty_o` = 0 | §1 |
| "CRV err_o timeout" | random reserved access gets `err_o` | §3.1 |
| "CRV" | random traffic: no response missing | §3.2 |
| "CRV irq not sticky after reserved accesses" | `irq` stays 1 | §3.4 |
| "data-class responses missing" | every data-class access answered | §3.2 |
| "A1 reset: outputs quiescent" | in reset: `ack_o`, `err_o`, `irq`, `stall_o` 0 | §3.5 |
| "A2 stall == queue full" | `stall_o` = (`q_count` == 2) | §3.2 |
| "A3 ack/err exclusive" | never both | §3.2 |
| "A4 rty tied off" | `rty_o` 0 | §1 |
| "A5 state legal" | `state` <= 2 | §1 |
| "A6 dat_o mux" | `dat_o` = head word when a read in range, else 0 | §3.2 |
| a_reset_quiet | in reset: `ack_o`, `err_o`, `stall_o`, `irq` 0 | §3.5 |
| a_rty_tied_off | `rty_o` 0 | §1 |
| a_stall_when_full | `stall_o` = 2 queued | §3.2 |
| a_resp_timing | a response exactly when the model's head is due (fast age 0, slow age 2) | §3.1, §3.2 |
| a_err_reserved | `err_o` iff the head is reserved, else `ack_o` | §3.1 |
| a_read_data | read `dat_o` = shadow word (0 outside the register file) | §3.2 |
| a_irq_sticky | `irq` stays 1 | §3.4 |
| a_irq_on_err | `err_o` sets `irq` next clock | §3.4 |
| a_irq_cause | `irq` rises only after `err_o` | §3.4 |
