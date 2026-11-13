<!-- SPDX-License-Identifier: Apache-2.0 -->
# OCP_IP_Open_Core_Protocol: design specification

OCP-IP master (initiator): a CPU-side descriptor port turns single and burst (1 to 8 beats, INCR)
reads, posted writes (MCmd WR) and non-posted writes (MCmd WRNP) into OCP requests. It obeys
SCmdAccept back-pressure with the request held stable, aborts a request after 64 clocks without
SCmdAccept, passes read beats and write completions back to the CPU port, and flags FAIL / ERR
responses, aborts and illegal lengths on a sticky `irq`. Core `OCP_IP_Open_Core_Protocol_top`
(`rtl/OCP_IP_Open_Core_Protocol_top.sv`), testbench `tb/OCP_IP_Open_Core_Protocol_tb.sv` (CPU
driver plus a behavioural OCP slave), checker `tb/cov/OCP_IP_Open_Core_Protocol_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. All outputs except `irq` are combinational from the state and
registers (`resp_*` also pass `SResp` / `SData` through).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock (also the OCP clock) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the state machine, descriptor, counters and `irq` | low | async | - |
| `req_valid` | input | 1 | CPU port: a descriptor (in O_IDLE) or a write data word (in O_WCOL) is taken at an edge with `req_valid` (`req_ready` is 1 in both) | high | `clk` | - |
| `req_ready` | output | 1 | 1 exactly in O_IDLE and O_WCOL | high | comb | 1 |
| `req_rw` | input | 1 | descriptor: 1 write, 0 read | - | `clk` | - |
| `req_posted` | input | 1 | descriptor: for a write, 1 = posted (MCmd WR, no response), 0 = non-posted (MCmd WRNP) | - | `clk` | - |
| `req_addr` | input | `AW` | descriptor: burst address (driven on `MAddr` for every beat) | - | `clk` | - |
| `req_len` | input | 5 | descriptor: burst length; 0 -> 1, 1 to 8 as given, above 8 clamped to 8 (and `irq`) | - | `clk` | - |
| `req_wdata` | input | `DW` | write word: word 0 with the descriptor, words 1..len-1 on later `req_valid` clocks | - | `clk` | - |
| `resp_valid` | output | 1 | CPU port: a response in this clock (§3.4); no back-pressure | high | comb | 0 |
| `resp_rdata` | output | `DW` | read beat data = `SData` in a read response clock, else 0 | - | comb | 0 |
| `resp_err` | output | 1 | the response is an error (FAIL / ERR beat, or accept timeout) | high | comb | 0 |
| `MCmd` | output | 3 | OCP MCmd: 0 IDLE, 1 WR (posted), 2 RD, 5 WRNP; non-IDLE only in O_ISSUE | - | comb | 0 |
| `MAddr` | output | `AW` | OCP MAddr = the descriptor address | - | comb | 0 |
| `MData` | output | `DW` | OCP MData = write word of the current beat | - | comb | - |
| `MByteEn` | output | 4 | constant 4'hF | - | const | F |
| `MBurstLength` | output | 5 | OCP MBurstLength = clamped length (1..8) | - | comb | 1 |
| `MBurstSeq` | output | 3 | constant 000 (INCR) | - | const | 0 |
| `SCmdAccept` | input | 1 | OCP SCmdAccept: the request (or write beat) is accepted at the end of this clock | high | `clk` | - |
| `SResp` | input | 2 | OCP SResp: 0 NULL, 1 DVA, 2 FAIL, 3 ERR; looked at only while a response is awaited | - | `clk` | - |
| `SData` | input | `DW` | OCP SData, read data with SResp | - | `clk` | - |
| `SRespLast` | input | 1 | OCP SRespLast: ends a read burst early when 1 | high | `clk` | - |
| `irq` | output | 1 | sticky error flag (§3.5), cleared only by reset | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 3 | 0 O_IDLE, 1 O_WCOL (collecting write words), 2 O_ISSUE (MCmd driven), 3 O_RDATA, 4 O_WRESP, 5 O_DONE; 6, 7 never occur |
| `to_cnt` | 7 | clocks the current request / beat has waited for SCmdAccept (0 to 63, never above 64) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/OCP_IP_Open_Core_Protocol.md`](../ip/OCP_IP_Open_Core_Protocol.md) (source: `scripts/apb/specs/OCP_IP_Open_Core_Protocol.json`); do not edit by hand.

`OCP_IP_Open_Core_Protocol_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `MCmd`, `MAddr`, `MData`, `MByteEn`, `MBurstLength`, `MBurstSeq`, `SCmdAccept`, `SResp`, `SData`, `SRespLast`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4F500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | REQ0 | RW | 0x00000000 | Transaction descriptor, then the further data words of a write burst; writing REQ2 commits it |
| 0x018 | REQ1 | RW | 0x00000000 | Transaction descriptor, then the further data words of a write burst; writing REQ2 commits it |
| 0x01C | REQ2 | RW | 0x00000000 | Transaction descriptor, then the further data words of a write burst; writing REQ2 commits it |
| 0x020 | RESP0 | RO (pop) | 0x00000000 | One beat per read data beat, per write completion and per posted write or timeout; reading RESP1 frees it |
| 0x024 | RESP1 | RO (pop) | 0x00000000 | One beat per read data beat, per write completion and per posted write or timeout; reading RESP1 frees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4F50 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| REQ0 | 31:0 | `req_addr` | RW | 0x0 | byte address (MAddr) |
| REQ1 | 31:0 | `req_wdata` | RW | 0x0 | write data: the first word with the descriptor, then one word per commit |
| REQ2 | 0 | `req_rw` | RW | 0x0 | 1 = write, 0 = read |
| REQ2 | 1 | `req_posted` | RW | 0x0 | 1 = posted write (MCmd WR, no response from the slave); 0 = non-posted write (MCmd WRNP) |
| REQ2 | 6:2 | `req_len` | RW | 0x0 | burst length 1 to 8 (0 is 1; above 8 is clamped to 8 and sets ERR) |
| RESP0 | 31:0 | `resp_rdata` | RO (pop) | 0x0 | read data (0 for writes) |
| RESP1 | 0 | `resp_err` | RO (pop) | 0x0 | 1 = SResp FAIL / ERR, or no SCmdAccept for 64 clocks |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a burst length above 8, an SResp FAIL / ERR, or an accept timeout; the core holds this until reset, so the bit cannot be cleared before then |
| 1 | REQ_DONE | REQ beat accepted by the core |
| 2 | REQ_OVF | write to REQ while full (dropped) |
| 3 | RESP_AVAIL | RESP captured a beat |
| 4 | RESP_OVF | beat dropped, RESP was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | REQ_FULL | REQ holds a beat the core has not taken |
| 1 | RESP_AVAIL | RESP holds an unread beat |

### Streams

* **REQ** feeds `req_addr`, `req_wdata`, `req_rw`, `req_posted`, `req_len`/`req_valid`. Writing REQ2 commits the beat: FLAGS.REQ_FULL is set and `req_valid` stays high until the core's `req_ready`; then REQ_DONE is set. A write while full is dropped and sets REQ_OVF.
* **RESP** captures `resp_rdata`, `resp_err` when `resp_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RESP_AVAIL. Reading RESP1 pops it. A beat that arrives while the register is full is dropped and sets RESP_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4F500200.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
4. To send on REQ: wait until FLAGS.REQ_FULL (bit 0) is 0, or for IRQ REQ_DONE, then write REQ0 (0x014) then REQ1 (0x018) then REQ2 (0x01C). The last write commits the beat. REQ_OVF means a write came while the register was full and was dropped.
5. To receive on RESP: wait for IRQ RESP_AVAIL or FLAGS.RESP_AVAIL (bit 1), then read RESP0 (0x020) then RESP1 (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RESP_AVAIL (bit 3) to clear it. Read each beat before the next arrives, or it is dropped and RESP_OVF is set.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Descriptor and write data

* In O_IDLE a clock with `req_valid` takes the descriptor (`req_rw`, `req_posted`, `req_addr`,
  `req_len` clamped). For a write, `req_wdata` of that clock is word 0.
* A read, or a write of length 1, goes to O_ISSUE. A longer write goes to O_WCOL and takes word k
  (k = 1 .. len-1) from `req_wdata` on each later clock with `req_valid`; clocks without
  `req_valid` are gaps. After the last word it goes to O_ISSUE.
* `req_len` > 8 sets `irq` when the descriptor is taken; the burst still runs with 8 beats.

### 3.2 Request phase (O_ISSUE)

* `MCmd` = RD for a read, WR for a posted write, WRNP for a non-posted write; `MAddr` = the
  descriptor address, `MBurstLength` = the clamped length, `MBurstSeq` = INCR, `MByteEn` = F.
* Read: the request is one command; at the edge it is accepted (SCmdAccept = 1) the core goes to
  O_RDATA.
* Write: every beat is one command with `MData` = word `beat`. At each accept the beat counter
  advances (`MAddr` stays the descriptor address); at the accept of the last beat a posted write
  goes to O_DONE and a non-posted one to O_WRESP.
* While SCmdAccept is 0 every request output is held stable. `to_cnt` counts the waiting clocks
  and restarts at each accept; if a request waits 64 consecutive clocks (the 64th clock without
  SCmdAccept) it is aborted: the core goes to O_DONE with an error and sets `irq`. `MCmd` is IDLE
  from the next clock.

### 3.3 Response phase

* O_RDATA: every clock with `SResp` != NULL is one read beat, passed to the CPU port in the same
  clock. The burst ends on the beat with `SRespLast` = 1 or on beat len-1, whichever comes first,
  and the core returns to O_IDLE. FAIL / ERR beats set `irq` but do not end the burst early (the
  remaining beats are still consumed).
* O_WRESP: the first clock with `SResp` != NULL completes the non-posted write; the core returns
  to O_IDLE. FAIL / ERR set `irq`.
* `SResp` is ignored outside O_RDATA / O_WRESP; a slave must answer after the accept. There is no
  timeout on the response phase.

### 3.4 CPU response port

| Clock | `resp_valid` | `resp_rdata` | `resp_err` |
|---|---|---|---|
| O_RDATA with `SResp` != NULL | 1 | `SData` | `SResp` is FAIL or ERR |
| O_WRESP with `SResp` != NULL | 1 | 0 | `SResp` is FAIL or ERR |
| O_DONE after a posted write | 1 | 0 | 0 |
| O_DONE after an accept timeout | 1 | 0 | 1 |
| otherwise | 0 | 0 | 0 |

O_DONE lasts one clock and then the core is in O_IDLE; the next descriptor can be taken in the
clock after the last response.

### 3.5 irq

Set at the end of the clock of: a descriptor with `req_len` > 8; a FAIL or ERR read beat or write
response; an accept timeout. It stays 1 until reset.

### 3.6 Reset

While `rst_n` is low: O_IDLE, `MCmd` IDLE, `req_ready` 1, `resp_valid` 0, `irq` 0, `MBurstLength`
1, counters 0. A transaction in progress is dropped.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | 32 | data width (`MByteEn` is 4 bits) |
| `AW` | 32 | 32 | address width (the descriptor register is 32 bits) |

The accept timeout is a fixed 64 clocks.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `req_len` = 0 | one beat, no error |
| `req_len` > 8 | 8 beats, `irq` |
| no SCmdAccept for 64 clocks | abort: `resp_valid` + `resp_err` in O_DONE, `irq`, MCmd IDLE; a write's remaining beats are not sent |
| FAIL / ERR on a read beat | that beat reported with `resp_err`, `irq`; the burst continues |
| FAIL / ERR on a write response | `resp_err`, `irq` |
| `SRespLast` before beat len-1 | read burst ends there |
| slave never answers a read / non-posted write | the core waits forever (no response timeout) |
| gaps between write words | allowed |
| reset mid transaction | dropped; `irq` cleared |

## 6. TB check map

Messages are printed by `tb/OCP_IP_Open_Core_Protocol_tb.sv` as `ERROR: <message>`; its immediate
checks print `SVA_FAIL: <name>`. Assertions `a_*` are in the bound checker
`tb/cov/OCP_IP_Open_Core_Protocol_sva.sv`, which models the descriptor, beat and wait counters.
The TB's slave has a configurable SCmdAccept delay, 2-clock response latency, a 64-word memory,
ERR / FAIL regions, a dead region that never accepts, and an optional ERR on one read beat. It
checks reset, single / burst / posted writes and reads, back-pressure and request stability,
ERR / FAIL with `irq`, a read burst with an error beat, write-word gaps, length clamps, the
timeout abort and recovery, back-to-back transactions, a mid-run reset, and (Verilator) random
traffic.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "request not held stable under backpressure" | MCmd / MAddr / MData / MBurstLength held while SCmdAccept is 0 | §3.2 |
| "desc accept timeout" | a write descriptor is taken | §3.1 |
| "wdata accept timeout beat" | each write word is taken | §3.1 |
| "write resp timeout" | the write completes on the CPU port | §3.4 |
| "write resp_err" | `resp_err` of a write as expected | §3.4 |
| "rd desc accept timeout" | a read descriptor is taken | §3.1 |
| "err read resp timeout" | an errored read still returns its beats | §3.3 |
| "expected resp_err" | FAIL / ERR beats give `resp_err` | §3.4 |
| "read beat" | read beats arrive | §3.3 |
| "unexpected resp_err on read beat" | DVA beats have no `resp_err` | §3.4 |
| "read data beat" | `resp_rdata` = slave data | §3.4 |
| "bad reset state MCmd" | out of reset: MCmd IDLE, `req_ready` 1, `resp_valid` 0, `irq` 0 | §3.6 |
| "SCmdAccept backpressure never observed" | the run stalled a request | §3.2 |
| "irq not set after SResp=ERR" | ERR sets `irq` | §3.5 |
| "timeout abort never signalled" | a dead-region request is aborted | §3.2 |
| "timeout abort missing resp_err" | the abort response has `resp_err` | §3.4 |
| "MCmd not IDLE after timeout abort" | MCmd IDLE after the abort | §3.2 |
| "irq not set after timeout" | the abort sets `irq` | §3.5 |
| "len 0 not clamped to 1" | `req_len` 0 runs one beat | §3.1 |
| "err-drain beat" | a read burst with an ERR beat delivers every beat | §3.3 |
| "not idle after err drain" | O_IDLE after that burst | §3.3 |
| "mid-run reset did not clear irq/MCmd" | reset clears `irq` and MCmd | §3.6 |
| "CRV read beat timeout t" | random reads return all beats | §3.3 |
| "CRV read t" | random read data / errors as the slave model | §3.3, §3.4 |
| "CRV clamp write resp timeout t" | clamped random writes complete | §3.1 |
| "CRV timeout abort never signalled t" | random dead-region requests abort | §3.2 |
| "CRV timeout abort missing resp_err t" | with `resp_err` | §3.4 |
| "CRV MCmd not IDLE after abort t" | MCmd IDLE after the abort | §3.2 |
| "CRV irq not sticky after error classes" | `irq` stays 1 | §3.5 |
| "CRV verify w" | data written by random writes reads back | §3.2, §3.3 |
| "A1 reset: outputs quiescent" | in reset: MCmd IDLE, `req_ready` 1, `resp_valid` 0, `irq` 0 | §3.6 |
| "A2 req_ready rule" | `req_ready` = state is O_IDLE or O_WCOL | §3.1 |
| "A3 MCmd only in O_ISSUE" | MCmd IDLE outside O_ISSUE | §3.2 |
| "A4 resp_valid rule" | `resp_valid` as in §3.4 | §3.4 |
| "A5 to_cnt <= 64 (63+abort-cycle overshoot)" | `to_cnt` bounded | §3.2 |
| "A6 state legal" | `state` <= 5 | §1 |
| a_reset_quiet | in reset: MCmd IDLE, `req_ready`, no `resp_valid`, no `irq` | §3.6 |
| a_req_ready | `req_ready` exactly while idle or collecting | §3.1 |
| a_mcmd | MCmd = RD / WR / WRNP while issuing, IDLE otherwise | §3.2 |
| a_maddr | MAddr = descriptor address while issuing | §3.2 |
| a_burst_len | MBurstLength = clamped length while issuing | §3.2 |
| a_wdata_beat | MData = word of the current beat | §3.2 |
| a_byteen_incr | MByteEn = F, MBurstSeq = INCR | §1 |
| a_resp_valid | `resp_valid` = response beat or O_DONE | §3.4 |
| a_resp_err | `resp_err` = bad beat or failed O_DONE | §3.4 |
| a_resp_rdata | read beat `resp_rdata` = `SData` | §3.4 |
| a_irq | `irq` = model's sticky flag | §3.5 |
| a_req_held | request outputs stable while waiting for SCmdAccept | §3.2 |
| a_timeout_abort | after 64 clocks without accept: `resp_valid`, `resp_err`, MCmd IDLE | §3.2 |
