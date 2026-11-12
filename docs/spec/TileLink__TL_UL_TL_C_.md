<!-- SPDX-License-Identifier: Apache-2.0 -->
# TileLink__TL_UL_TL_C_: design specification

TileLink Uncached Lightweight (TL-UL) slave on the A (request) and D (response) channels, backed
by a 64 x 32-bit register file at addresses 0x00 to 0xFF. It accepts PutFullData (opcode 0),
PutPartialData (1) and Get (4) of exactly 4 bytes, echoes `a_source` and `a_size` in the
response, and answers every illegal request with `d_error` and a sticky `irq`. One request is
outstanding at a time, but a new request is accepted in the same cycle as the previous response
is taken, so the slave sustains one transfer per clock. TL-C (B, C, E channels, caching) is not
implemented despite the IP name. Core `TileLink__TL_UL_TL_C__top` (`rtl/TileLink__TL_UL_TL_C__top.sv`), testbench `tb/TileLink__TL_UL_TL_C__tb.sv`,
checker `tb/cov/TileLink__TL_UL_TL_C__sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. An *A beat* is a cycle with `a_valid && a_ready`, a *D beat* one
with `d_valid && d_ready`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the channel state, the response registers and `irq` (not of the register file) | low | async assert | - |
| `a_valid` | input | 1 | A channel request valid | high | `clk` | - |
| `a_ready` | output | 1 | combinational: 1 when no response is pending, or when `d_ready` takes the pending one in this cycle | high | comb. | 1 |
| `a_opcode` | input | 3 | 0 PutFullData, 1 PutPartialData, 4 Get; any other value is an error | - | `clk` | - |
| `a_param` | input | 3 | reserved in TL-UL; any value other than 0 is an error | - | `clk` | - |
| `a_size` | input | 3 | log2 of the transfer size; only 2 (4 bytes) is legal | - | `clk` | - |
| `a_source` | input | 8 | request id, echoed in `d_source` | - | `clk` | - |
| `a_address` | input | `AW` | byte address; must be 4-byte aligned and below 0x100 | - | `clk` | - |
| `a_mask` | input | 4 | byte lanes: 4'hF for PutFullData and Get, non-zero for PutPartialData | - | `clk` | - |
| `a_data` | input | `DW` | write data | - | `clk` | - |
| `d_valid` | output | 1 | response valid (`state` = RESP) | high | `clk` | 0 |
| `d_ready` | input | 1 | master accepts the response | high | `clk` | - |
| `d_opcode` | output | 3 | 1 AccessAckData for a Get, 0 AccessAck for a Put or any other opcode | - | `clk` | 0 |
| `d_size` | output | 3 | `a_size` of the request, echoed even when it was illegal | - | `clk` | 0 |
| `d_source` | output | 8 | `a_source` of the request | - | `clk` | 0 |
| `d_data` | output | `DW` | read data for a legal Get, 0 otherwise | - | `clk` | 0 |
| `d_error` | output | 1 | the request was illegal (§3.3) and had no effect | high | `clk` | 0 |
| `irq` | output | 1 | sticky: set by the first illegal request, cleared only by `rst_n` | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 1 | IDLE = 0 (no response pending), RESP = 1 (`d_valid`) |
| `d_opcode_q` | 1 | 1 for AccessAckData; `d_opcode` is this bit zero-extended |
| `d_size_q` | 3 | register behind `d_size` |
| `d_source_q` | 8 | register behind `d_source` |
| `d_data_q` | 32 | register behind `d_data` |
| `d_error_q` | 1 | register behind `d_error` |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/TileLink__TL_UL_TL_C_.md`](../ip/TileLink__TL_UL_TL_C_.md) (source: `scripts/apb/specs/TileLink__TL_UL_TL_C_.json`); do not edit by hand.

`TileLink__TL_UL_TL_C__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `a_valid`, `a_ready`, `a_opcode`, `a_param`, `a_size`, `a_source`, `a_address`, `a_mask`, `a_data`, `d_valid`, `d_ready`, `d_opcode`, `d_size`, `d_source`, `d_data`, `d_error`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x544C0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x544C | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a request was answered with d_error: an opcode other than PutFullData / PutPartialData / Get, a size other than 4 bytes, a misaligned or out-of-range address (0x100 and up), a mask not matching the opcode, or a non-zero param; the core holds this until reset, so the bit cannot be cleared before then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x544C0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Handshake

`a_ready` = (`state` = IDLE) or `d_ready`. At each `clk` edge:

- A beat: the request is executed (§3.2) and its response registered; `state` <= RESP, so
  `d_valid` is 1 from the next cycle. Latency from A beat to `d_valid` is 1 cycle.
- No A beat but a D beat: `state` <= IDLE.
- Otherwise `state` holds.

While `d_valid` = 1 and `d_ready` = 0 the slave stalls the A channel (`a_ready` = 0) and holds
every D field stable. With `a_valid` and `d_ready` both held high, one request is accepted and
one response delivered every cycle, in order.

### 3.2 Request execution

At the A beat, for a legal request:

- PutFullData / PutPartialData: byte *b* of word `a_address[7:2]` <= `a_data[8b+7:8b]` for every
  set `a_mask[b]`. The response is AccessAck with `d_data` = 0.
- Get: `d_data` <= word `a_address[7:2]` as it is before this edge, so a Get sees every Put
  accepted in an earlier cycle. The response is AccessAckData.

`d_source` <= `a_source`, `d_size` <= `a_size` and `d_error` <= 0 in both cases.

### 3.3 Illegal requests

A request is illegal if any of these holds: opcode not 0, 1 or 4; `a_param` != 0; `a_size` != 2;
`a_address[1:0]` != 0; `a_address` >= 0x100; Get or PutFullData with `a_mask` != 4'hF;
PutPartialData with `a_mask` = 0. It is still accepted and answered in the normal timing, with
`d_error` = 1, `d_data` = 0, `d_opcode` = AccessAckData for a Get and AccessAck otherwise, the
size and source echoed, and no change to the register file. `irq` <= 1 and stays 1.

### 3.4 Reset

`rst_n` low: `state` = IDLE (`d_valid` = 0, `a_ready` = 1), all D registers 0, `irq` = 0. A
pending response is dropped. The register file is not reset: its content after power-up is
undefined, and a reset keeps the old values.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | 32 | data width; the mask is 4 bits and the response data register 32 bits, so only 32 works |
| `AW` | 32 | 8 to 32 | address width; the decode uses bits [7:2] and compares the whole address with 0x100 |
| `DEPTH` | 64 | 64 | register-file depth in words; the index is `a_address[7:2]` and the valid range is fixed at 0x100, so only 64 is consistent |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| illegal request (§3.3) | answered with `d_error` = 1, no side effect, sticky `irq` |
| `irq` set | stays until `rst_n`; there is no clear |
| `d_ready` low with a response pending | `d_valid` and all D fields hold, `a_ready` = 0 |
| new request in the cycle the response is taken | accepted (pipelined, one per clock) |
| Get right after a Put to the same word | returns the new data |
| reset with a response pending | response dropped, `irq` cleared, register file kept |
| `a_opcode` 2 (Intent) or 6 / 7 (TL-C) | illegal, error response |

## 6. TB check map

Messages are printed by the TB as `ERROR: <message>` (A1..A6 as `SVA_FAIL:`); "CRV" messages and
A1..A6 are built only for Verilator. Assertions a_* are in the checker. The TB is a TL-UL master
model with a 50-cycle timeout on every handshake.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "a_ready timeout op" | every request is accepted | §3.1 |
| "d_valid timeout op" | every request gets a response | §3.1 |
| "d_error" | `d_error` matches the expected legality | §3.3 |
| "source echo exp" | `d_source` = `a_source` | §3.2 |
| "size echo exp" | `d_size` = `a_size` | §3.2 |
| "Get d_opcode exp AccessAckData got" | Get answered with opcode 1 | §3.2 |
| "Get data" | Get returns the register-file word (PutFull, PutPartial merge; error requests leave it intact) | §3.2, §3.3 |
| "Put d_opcode exp AccessAck got" | Put answered with opcode 0 | §3.2 |
| "bad reset state d_valid" | after reset `d_valid` = 0 and `irq` = 0 | §3.4 |
| "a_ready must be high when idle" | `a_ready` = 1 with no response pending | §3.1 |
| "d_valid timeout (backpressure test)" | response appears while `d_ready` is low | §3.1 |
| "backpressure data exp DEAD_BEEF got" | the held response carries the right data | §3.1, §3.2 |
| "d_valid dropped under backpressure" | `d_valid` stays 1 until taken | §3.1 |
| "d_data changed while d_ready low" | D fields stable while stalled | §3.1 |
| "irq not set after illegal requests" | seven illegal kinds (opcode, size, alignment, Get mask, zero PutPartial mask, PutFull partial mask, range) set `irq` | §3.3 |
| "b2b a_ready timeout" | four requests with `a_valid` held are accepted on consecutive cycles | §3.1 |
| "b2b got" | all four responses arrive | §3.1 |
| "b2b resp" | in order, with the right opcode and source, no error | §3.1, §3.2 |
| "a_param!=0 not rejected" | `a_param` = 1 gives `d_error` | §3.3 |
| "a_ready while D stalled" | `a_ready` = 0 while the response is stalled | §3.1 |
| "TL reset state d_valid" | reset with a pending response: `d_valid` = 0, `irq` = 0, `a_ready` = 1 | §3.4 |
| "CRV irq not sticky after error injections" | `irq` stays 1 through random traffic after errors | §3.3 |
| "A1 reset: idle, ready, no irq" | reset state | §3.4 |
| "A2 d_valid == S_RESP" | `d_valid` is the RESP state | §3.1 |
| "A3 a_ready rule" | `a_ready` = IDLE or `d_ready` | §3.1 |
| "A4 D outputs mirror regs" | D outputs are the `d_*_q` registers | §1 |
| "A5 state legal" | `state` is 0 or 1 | §1 |
| "A6 legal response opcode" | `d_opcode` is 0 or 1 | §3.2 |
| a_reset_quiet | in reset `d_valid` = 0, `irq` = 0, `a_ready` = 1 | §3.4 |
| a_dvalid_model | `d_valid` equals the model's pending flag | §3.1 |
| a_aready_model | `a_ready` = !pending or `d_ready` | §3.1 |
| a_resp_fields | opcode, size, source and error equal the model | §3.2, §3.3 |
| a_resp_data | `d_data` equals the model register file | §3.2 |
| a_d_stable | D fields stable while `d_valid && !d_ready` | §3.1 |
| a_irq_model | `irq` equals the sticky model | §3.3 |
