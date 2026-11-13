<!-- SPDX-License-Identifier: Apache-2.0 -->
# OCP: design specification

OCP-IP 3.0 slave, basic data-handshake subset, with a 256 x 32-bit register file: posted writes
(WR, no response), reads (RD) and non-posted writes (WRNP) answered DVA or ERR two clocks after
the accept, a configurable command-accept latency, byte enables, thread-id echo, and ERR plus an
`irq` pulse for bad addresses and unsupported commands. One request is handled at a time. Core
`OCP_top` (`rtl/OCP_top.sv`), testbench `tb/OCP_tb.sv` (two OCP master models: one per accept
latency), checker `tb/cov/OCP_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A request is "accepted" in a clock where `scmdaccept` = 1 and
`mcmd` != IDLE; it takes effect at the edge that ends that clock.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | OCP clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the state machine and captured response (not the register file) | low | async | - |
| `mcmd` | input | 3 | MCmd: 0 IDLE, 1 WR (posted write), 2 RD, 5 WRNP (non-posted write); 3, 4, 6, 7 unsupported (answered ERR). Held, with the other request fields, until `scmdaccept` | - | `clk` | - |
| `maddr` | input | `AW` | MAddr, byte address | - | `clk` | - |
| `mdata` | input | `DW` | MData, write data | - | `clk` | - |
| `mbyteen` | input | `DW/8` | MByteEn: byte lane k written when bit k is 1 | high | `clk` | - |
| `mthreadid` | input | 2 | MThreadID, echoed on `sthreadid` with the response | - | `clk` | - |
| `scmdaccept` | output | 1 | SCmdAccept: the request is taken at the end of this clock (§3.1); combinational | high | comb | 0 |
| `sdata` | output | `DW` | SData: the word read at the accepting edge (valid with a DVA response to RD) | - | comb | 0 |
| `sresp` | output | 2 | SResp: 0 NULL, 1 DVA, 3 ERR; non-NULL for exactly one clock (§3.2) | - | comb | 0 |
| `sthreadid` | output | 2 | SThreadID: `mthreadid` of the request being answered | - | comb | 0 |
| `irq` | output | 1 | one-clock pulse in the clock after a bad request was accepted (§3.3) | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 2 | 0 S_IDLE, 1 S_ACCEPT (`scmdaccept` = 1 when `ACCEPT_DLY` = 1), 2 S_LAT, 3 S_RESP (`sresp` != NULL) |
| `rdata_q` | `DW` | word captured at the accept; drives `sdata` |
| `thread_q` | 2 | `mthreadid` captured at the accept; drives `sthreadid` |
| `err_q` | 1 | the accepted request was bad; `sresp` = ERR in S_RESP |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/OCP.md`](../ip/OCP.md) (source: `scripts/apb/specs/OCP.json`); do not edit by hand.

`OCP_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `mcmd`, `maddr`, `mdata`, `mbyteen`, `mthreadid`, `scmdaccept`, `sdata`, `sresp`, `sthreadid`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4F430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4F43 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a request was answered ERR (an address outside 0x000 to 0x3FC or misaligned, or an unsupported MCmd), or a posted write went to such an address |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4F430200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Request phase

| `ACCEPT_DLY` | `scmdaccept` | First accept |
|---|---|---|
| 0 | = 1 in S_IDLE whenever `mcmd` != IDLE | in the clock the request is first presented |
| 1 | = 1 exactly in S_ACCEPT | the clock after the request is first presented in S_IDLE (one wait clock) |

At the accepting edge the core captures `mthreadid`, the error flag (§3.3) and the word
`mem[maddr[9:2]]` (before any write at that edge), and a WR / WRNP to a good address writes the
bytes with `mbyteen[k]` = 1. Then:

* WR (posted): back to S_IDLE; no response. With `ACCEPT_DLY` 0 the next request can be accepted
  in the next clock; with 1 it is accepted one clock later (S_IDLE, then S_ACCEPT).
* RD, WRNP and every unsupported command: S_LAT for one clock, then S_RESP for one clock, then
  S_IDLE. `scmdaccept` is 0 from the accepting edge until S_IDLE (the next request waits).

### 3.2 Response phase

* `sresp` = DVA (or ERR for a bad request) in exactly one clock: the second clock after the
  accepting clock (accept in clock a, S_LAT in a+1, S_RESP in a+2). There is no MRespAccept: the
  master must take the response in that clock.
* `sthreadid` = the captured thread id; `sdata` = the captured word. For a DVA read it is the word
  at the address; for WRNP it is the word before the write; for ERR it is whatever
  `mem[maddr[9:2]]` held (not zeroed, §5).
* `sresp` = NULL in every other clock. `sdata` / `sthreadid` hold the last captured values.

### 3.3 Errors

A request is bad when the address is outside 0x000..0x3FC or not word aligned
(`maddr[AW-1:10]` != 0 or `maddr[1:0]` != 0), or `mcmd` is not WR / RD / WRNP. A bad request writes
nothing and pulses `irq` in the clock after the accepting clock. A bad RD / WRNP / unsupported
command is answered ERR; a bad posted WR has no response, only the `irq` pulse.

### 3.4 Reset

While `rst_n` is low: S_IDLE, `sresp` NULL, `scmdaccept` 0 (with `mcmd` IDLE), `irq` 0,
captured fields 0. A pending response is dropped. The register file keeps its contents and is
undefined until written (a 2-state simulator shows 0; the checker's shadow starts at 0).

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | 32 | data width (4-byte words) |
| `AW` | 32 | 11 to 64 | address width; bits `AW-1:10` must be 0 |
| `DEPTH` | 256 | 256 | register-file words; the decode always uses `maddr[9:2]` |
| `ACCEPT_DLY` | 1 | 0 or 1 | command-accept latency (§3.1) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| address >= 0x400 or misaligned | ERR (RD / WRNP) or no response (WR); nothing written; `irq` pulse |
| unsupported MCmd (3, 4, 6, 7) | accepted, ERR, `irq`, no effect |
| `sdata` of an ERR response | the word at `maddr[9:2]` (aliased for a high address), not 0; only meaningful with DVA |
| request presented while busy | not accepted; it must stay on the bus |
| `mcmd` withdrawn in S_ACCEPT (`ACCEPT_DLY` 1) | not allowed by OCP; the core still leaves S_ACCEPT and answers ERR with an `irq` pulse |
| RD right after a posted WR to the same word | returns the written data |
| reset with a response pending | dropped; `sresp` NULL after reset |

## 6. TB check map

Messages are printed by `tb/OCP_tb.sv` as `ERROR: <message>`; its immediate checks (on the
`ACCEPT_DLY` 1 instance `dut`) print `SVA_FAIL: <name>`. Assertions `a_*` are in the bound checker
`tb/cov/OCP_sva.sv` (bound to both instances), which models the accept / response pipeline and a
shadow register file. Instance `dut0` (`ACCEPT_DLY` 0) has its own master. The TB checks reset,
WR / WRNP / RD with read-back, byte-enable merges, latency 2, thread-id echo, posted writes
without response, back-to-back requests, reserved and misaligned addresses, every unsupported
MCmd, reset mid transaction, and (Verilator) random traffic.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "OCP dut0 no same-cycle accept" | `ACCEPT_DLY` 0: `scmdaccept` in the first clock | §3.1 |
| "OCP dut0 posted WR responded" | no response to a posted WR | §3.1 |
| "OCP dut0 no accept after posted WR" | `ACCEPT_DLY` 0: next request accepted right after a posted WR | §3.1 |
| "OCP dut0 read behind posted WR resp" | the read behind it returns DVA and the written data | §3.2 |
| "OCP dut0 early response" | no response in the latency clock | §3.2 |
| "OCP dut0 cmd" | response value, thread id and data on `dut0` | §3.2 |
| "OCP dut0 accepted while busy" | no accept while a response is pending | §3.1 |
| "OCP response timeout" | a response arrives | §3.2 |
| "OCP WRNP" | WRNP: DVA / ERR, latency 2, thread id | §3.2, §3.3 |
| "OCP RD" | RD: response, data, latency 2, thread id | §3.2 |
| "OCP posted WR" | posted WR gets no SResp | §3.1 |
| "OCP reset state sresp" | out of reset: `sresp` NULL, `scmdaccept` 0, `irq` 0 | §3.4 |
| "OCP back-to-back" | two back-to-back non-posted requests give two DVA | §3.1 |
| "OCP reserved RD: no irq pulse" | bad read pulses `irq` | §3.3 |
| "OCP reserved WR: no irq pulse" | bad write pulses `irq` | §3.3 |
| "OCP MCmd" | unsupported MCmd answered ERR | §3.3 |
| "OCP outputs not quiescent in reset" | in reset: `sresp` NULL, `scmdaccept`, `irq` 0 | §3.4 |
| "OCP stale response after reset" | no response from before the reset | §3.4 |
| "CRV irq never pulsed on error classes" | random error classes pulse `irq` | §3.3 |
| "A1 reset: outputs quiescent" | in reset outputs idle | §3.4 |
| "A2 sresp NULL unless S_RESP" | `sresp` != NULL only in S_RESP | §3.2 |
| "A3 S outputs mirror regs" | `sdata` = `rdata_q`, `sthreadid` = `thread_q` | §3.2 |
| "A4 scmdaccept == S_ACCEPT" | `ACCEPT_DLY` 1: `scmdaccept` exactly in S_ACCEPT | §3.1 |
| "A5 ERR implies err_q" | ERR only with `err_q` | §3.3 |
| "A6 state legal" | `state` within 0..3 | §1 |
| a_reset_quiet | in reset: `sresp` NULL, `scmdaccept` 0, `irq` 0 | §3.4 |
| a_no_accept_when_busy | no accept while a response is in the pipeline | §3.1 |
| a_accept_same_cycle | `ACCEPT_DLY` 0: accept in the first clock | §3.1 |
| a_accept_wait_one | `ACCEPT_DLY` 1: no accept in the first clock | §3.1 |
| a_accept_next_cycle | `ACCEPT_DLY` 1: accept in the second clock | §3.1 |
| a_accept_needs_cmd | `scmdaccept` only with a command | §3.1 |
| a_resp_timing | `sresp` != NULL exactly 2 clocks after a non-posted accept | §3.2 |
| a_resp_value | `sresp` and `sthreadid` as the model | §3.2, §3.3 |
| a_read_data | DVA read `sdata` = shadow word | §3.2 |
| a_irq_on_bad | bad accepted request pulses `irq` next clock | §3.3 |
| a_irq_cause | `irq` only after a bad accept | §3.3 |
