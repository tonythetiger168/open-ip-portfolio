<!-- SPDX-License-Identifier: Apache-2.0 -->
# UALink: design specification

UALink completer on the UPLI (UALink Protocol Level Interface): READ, WRITE and the atomics
FETCH_ADD, SWAP and CAS to a local memory of `MW` 64-bit words, over four credited channels (request,
originator data, read response, write response). Requests are executed in order, one at a time.
Not implemented: virtual channels and their ordering rules, multiple outstanding requests,
out-of-order completion, the full request field set, the layers below UPLI. Field widths and
encodings are this design's own. Core `UALink_top` (`rtl/UALink_top.sv`), testbench
`tb/UALink_tb.sv` (a TB originator with a reference memory), checker `tb/cov/UALink_sva.sv` (a
cycle-exact model of every output).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Every output is registered. Inputs are sampled at the rising edge;
a decision taken in clock n shows on the outputs in clock n+1. Valids and credits are one-clock
pulses.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of everything, including the memory (cleared to 0) | low | async | - |
| `req_valid` | input | 1 | request beat (one clock per request); needs a request credit | high | `clk` | - |
| `req_cmd` | input | 3 | 0 READ, 1 WRITE, 2 FETCH_ADD, 3 SWAP, 4 CAS; 5..7 invalid | - | `clk` | - |
| `req_tag` | input | 8 | request tag, returned with the response | - | `clk` | - |
| `req_addr` | input | 16 | byte address; must be 8-byte aligned; word = `req_addr[log2(MW)+2:3]` | - | `clk` | - |
| `req_len` | input | 3 | beats - 1 (READ / WRITE: 1 to 8 beats of 8 bytes); must be 0 for atomics | - | `clk` | - |
| `req_crd` | output | 1 | request credit: one per clock it is 1 | high | `clk` | 0 |
| `od_valid` | input | 1 | originator data beat; needs a data credit | high | `clk` | - |
| `od_data` | input | 64 | data beat: WRITE data, atomic operand, CAS compare then swap value | - | `clk` | - |
| `od_be` | input | 8 | byte enables of a WRITE beat (ignored for atomics) | high | `clk` | - |
| `od_last` | input | 1 | marks the last data beat of a request (checked, §3.3) | high | `clk` | - |
| `od_crd` | output | 1 | data credit: one per clock it is 1 | high | `clk` | 0 |
| `rd_valid` | output | 1 | read response beat (one clock per beat) | high | `clk` | 0 |
| `rd_tag` | output | 8 | tag of the request answered | - | `clk` | 0 |
| `rd_data` | output | 64 | READ data / atomic old value; 0 on a failed status | - | `clk` | 0 |
| `rd_last` | output | 1 | last beat of the response | high | `clk` | 0 |
| `rd_status` | output | 2 | 0 OK, 1 UR, 2 BAD (§3.4) | - | `clk` | 0 |
| `rd_crd` | input | 1 | read response credit from the originator: one per clock it is 1 | high | `clk` | - |
| `wr_valid` | output | 1 | write response (one clock) | high | `clk` | 0 |
| `wr_tag` | output | 8 | tag of the request answered | - | `clk` | 0 |
| `wr_status` | output | 2 | 0 OK, 1 UR, 2 BAD | - | `clk` | 0 |
| `wr_crd` | input | 1 | write response credit from the originator | high | `clk` | - |
| `ev_err` | output | 1 | one-clock pulse with every response that has a non-OK status | high | `clk` | 0 |
| `ev_proto` | output | 1 | one-clock pulse in the clock after a protocol fault (§3.5) | high | `clk` | 0 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/UALink.md`](../ip/UALink.md) (source: `scripts/apb/specs/UALink.json`); do not edit by hand.

`UALink_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `req_valid`, `req_cmd`, `req_tag`, `req_addr`, `req_len`, `req_crd`, `od_valid`, `od_data`, `od_be`, `od_last`, `od_crd`, `rd_valid`, `rd_tag`, `rd_data`, `rd_last`, `rd_status`, `rd_crd`, `wr_valid`, `wr_tag`, `wr_status`, `wr_crd`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x554C0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x554C | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a response with a non-OK status: UR (the access runs past the memory) or BAD (invalid command, misaligned address, atomic with len != 0) |
| 1 | PROTO | a request or data beat without a credit (dropped), an od_last not matching the beat count, or a response credit past 15 |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x554C0200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Credits

* Request and data channels: the completer has `RQ` request slots and `DQ` data-beat slots. It
  pulses `req_crd` (at most one per clock) while the credits the originator holds plus the
  requests held (after this clock's arrival and removal) are fewer than `RQ`; `od_crd` the same
  against `DQ`. Each request / data beat uses one credit; one sent while the originator holds none
  is dropped with `ev_proto`.
* Response channels: each `rd_crd` / `wr_crd` pulse gives the completer one response credit (it
  holds at most 15; a credit past 15 is ignored with `ev_proto`). A credit received in clock n is
  usable from clock n+1. Every read response beat uses a read credit, every write response a write
  credit; without one the response waits.

### 3.2 Execution

The engine works on the oldest request, one at a time:

| Step | Takes | Needs |
|---|---|---|
| take the request | 1 clock | a request in a slot (a request that arrived in clock n can be taken in clock n+1) |
| data beats | 1 clock per beat | a beat in a data slot: WRITE `len`+1 beats, FETCH_ADD / SWAP 1, CAS 2, READ and invalid commands 0 |
| READ response | 1 clock per beat | a read credit per beat |
| other response | 1 clock | a write credit (WRITE, invalid command) or a read credit (atomic) |

The status is decided when the request is taken (§3.4). Data beats are taken in order, so they
must be sent in request order.

* WRITE: each beat writes the bytes with `od_be[k]` = 1 of word `addr/8 + i` (beat i) as it is
  taken (only with status OK). Then one write response with the status.
* READ: beat i returns word `addr/8 + i`, read when that beat is sent; `rd_last` on beat `len`.
  A failed READ answers one beat with data 0 and `rd_last` = 1.
* FETCH_ADD (new = old + operand), SWAP (new = operand), CAS (new = swap value if old = compare,
  else old): one read response beat with the old value; the memory takes the new value in the
  same clock the response is sent. With a failed status nothing changes and the data is 0.
* Each response clock with a non-OK status pulses `ev_err` together with the response.

### 3.3 Data beat checks

A data beat whose `od_last` does not equal "this is the request's last beat" pulses `ev_proto`; the
beat count decides where the request ends.

### 3.4 Status

| Status | Condition | Effect |
|---|---|---|
| 2 BAD | command 5..7, or `addr[2:0]` != 0, or an atomic with `len` != 0 | no memory effect; data beats (as many as the command would take) still consumed |
| 1 UR | otherwise, if `addr/8 + len` >= `MW` (the access runs past the memory) | the same |
| 0 OK | otherwise | as §3.2 |

Invalid commands are answered on the write response channel.

### 3.5 ev_proto

Pulses in the clock after any of: a request or data beat without a credit (dropped); an `od_last`
mismatch; a response credit past 15 (ignored). Several in one clock give one pulse.

### 3.6 Reset

While `rst_n` is low every output is 0, the slots are empty, all credit counts are 0 and the memory
is cleared. After reset the completer grants `RQ` request and `DQ` data credits, one of each per
clock.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `MW` | 16 | power of 2, 2 to 8192 | memory size in 64-bit words |
| `RQ` | 4 | power of 2, 2 or more | request slots / credits |
| `DQ` | 8 | power of 2, 2 or more | data-beat slots / credits |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| request or data beat without a credit | dropped, `ev_proto` |
| `od_last` on the wrong beat | `ev_proto`; the beat count wins |
| response credit past 15 | ignored, `ev_proto` |
| failed READ | one beat, data 0, `rd_last` 1, status UR / BAD, `ev_err` |
| failed WRITE / atomic | data beats consumed, no effect, status, `ev_err` |
| CAS without a match | memory unchanged, old value returned, OK |
| no response credits | the engine waits; requests and data keep queuing up to the slots |
| reset with traffic in flight | everything cleared, memory too; credits restart |

## 6. TB check map

Messages are printed by `tb/UALink_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/UALink_sva.sv`, which computes the exact value of every output in every clock. The
TB originator counts its credits, sends reads and writes of 1 to 8 beats, FETCH_ADD, SWAP and CAS
(match and no match) with data on its own schedule, grants response credits at a variable rate, and
sends error requests, a wrong `od_last`, a request and a data beat without a credit, a response
credit past 15, and a reset with traffic in flight. A reference memory predicts every response.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "read response with none expected" | no read response beyond the expected ones | §3.2 |
| "RD tag" | each read response beat: tag, data, last, status as predicted, in order | §3.2, §3.4 |
| "write response with none expected" | no write response beyond the expected ones | §3.2 |
| "WR tag" | each write response: tag and status as predicted | §3.2, §3.4 |
| a_rd | read response outputs exactly as the model | §3.2 |
| a_wr | write response outputs exactly as the model | §3.2 |
| a_credits | `req_crd` / `od_crd` exactly as the model | §3.1 |
| a_events | `ev_err` / `ev_proto` exactly as the model | §3.2, §3.5 |
| a_reset | in reset every output 0 | §3.6 |
