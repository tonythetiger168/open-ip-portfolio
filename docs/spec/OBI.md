<!-- SPDX-License-Identifier: Apache-2.0 -->
# OBI: design specification

OBI 1.6 (OpenHW Open Bus Interface) subordinate with a 256 x 32-bit memory: a pipelined A channel
(`req` / `gnt`) with up to `NOUT` transactions outstanding, an in-order R channel (`rvalid` /
`rready`) with id echo, byte-enabled writes, RISC-V atomics (AMOs, LR / SC), decode, protection
and atop errors, and the OBI 1.6 parity (integrity) handshake signals. Core `OBI_top`
(`rtl/OBI_top.sv`), testbench `tb/OBI_tb.sv` (a pipelined OBI manager with a predicting
scoreboard), checker `tb/cov/OBI_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. "Taken" means accepted at an edge with `req && gnt`; "popped" means
a response handed over at an edge with `rvalid && rready`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the response FIFO, the reservation and the irq flops (not the memory) | low | async | - |
| `req` | input | 1 | A-channel request; the manager holds the request until `gnt` | high | `clk` | - |
| `gnt` | output | 1 | grant = `req && (outstanding responses < NOUT)`, combinational; a request is taken at an edge with `req && gnt` | high | comb | 0 |
| `addr` | input | 32 | byte address; word `addr[9:2]`, bits 1:0 ignored; >= 0x400 is a decode error | - | `clk` | - |
| `we` | input | 1 | 1 write, 0 read | - | `clk` | - |
| `be` | input | 4 | byte enables of a plain write (ignored by reads, AMOs and SC) | high | `clk` | - |
| `wdata` | input | 32 | write data / AMO operand / SC data | - | `clk` | - |
| `aid` | input | `IDW` | transaction id, echoed on `rid` | - | `clk` | - |
| `prot` | input | 3 | `prot[2:1]` privilege (11 machine, other user); `prot[0]` data / instruction, ignored | - | `clk` | - |
| `atop` | input | 6 | atomic operation: `atop[5]` = 1 with the RISC-V A encoding in `atop[4:0]` (§3.4); 0 for a plain access | - | `clk` | - |
| `reqpar` | input | 1 | integrity: must be `~req` in every clock (§3.5) | - | `clk` | - |
| `gntpar` | output | 1 | `~gnt` | - | comb | 1 |
| `rvalid` | output | 1 | a response is at the FIFO head (combinational: outstanding count != 0) | high | comb | 0 |
| `rready` | input | 1 | response taken at an edge with `rvalid && rready` | high | `clk` | - |
| `rdata` | output | 32 | response data of the FIFO head (§3.3) | - | comb | 0 |
| `err` | output | 1 | response error flag of the FIFO head | high | comb | 0 |
| `rid` | output | `IDW` | `aid` of the request the head answers | - | comb | 0 |
| `rvalidpar` | output | 1 | `~rvalid` | - | comb | 1 |
| `rreadypar` | input | 1 | integrity: must be `~rready` in every clock | - | `clk` | - |
| `irq_dec` | output | 1 | one-clock pulse in the clock after a request with a decode error was taken | high | `clk` | 0 |
| `irq_prot` | output | 1 | pulse after a request with a protection error (and no decode error) was taken | high | `clk` | 0 |
| `irq_atop` | output | 1 | pulse after a request with an atop error (and neither of the others) was taken | high | `clk` | 0 |
| `irq_par` | output | 1 | high in the clock after any clock with `reqpar == req` or `rreadypar == rready` | high | `clk` | 0 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/OBI.md`](../ip/OBI.md) (source: `scripts/apb/specs/OBI.json`); do not edit by hand.

`OBI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `req`, `gnt`, `addr`, `we`, `be`, `wdata`, `aid`, `prot`, `atop`, `reqpar`, `gntpar`, `rvalid`, `rready`, `rdata`, `err`, `rid`, `rvalidpar`, `rreadypar`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4F420100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4F42 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DEC | a request at or above byte 0x400 got an error response (write dropped, rdata 0) |
| 1 | PROT | a request below machine level (prot[2:1] != 2'b11) to the window from PROT_BASE (0x300) up got an error response |
| 2 | ATOP | a request with an unsupported atop (atop[5] = 0 with atop != 0, an undefined AMO, LR with we = 1, SC or an AMO with we = 0) got an error response |
| 3 | PAR | reqpar was not the inverse of req, or rreadypar not the inverse of rready, in a clock |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4F420100.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 A channel

* `gnt` = `req` while fewer than `NOUT` responses are outstanding (taken but not popped), else 0.
  A pop in the same clock does not free a slot for that clock. `gnt` is never 1 without `req`.
* The request is decoded and executed at the edge it is taken: the memory write (if any), the
  reservation update and the response are all done at that edge. Requests can be taken on
  consecutive edges (one per clock).

### 3.2 R channel

* Every taken request gets exactly one response, in request order, through an `NOUT`-entry FIFO.
  The response of a request taken at edge e is at the FIFO head no earlier than the clock after e
  (`rvalid` = 1 from then while the FIFO is not empty).
* `rdata`, `err`, `rid` show the head; they hold while `rready` is 0. A pop at an edge moves to the
  next entry.

### 3.3 Decode and response data

Errors, in precedence order (the first that applies names the irq; all give `err` = 1, `rdata` =
0, no memory write, no reservation change):

| Error | Condition | irq |
|---|---|---|
| decode | `addr[31:10]` != 0 | `irq_dec` |
| protection | `addr[9:0]` >= `PROT_BASE` and `prot[2:1]` != 11 (user access to the machine-only window) | `irq_prot` |
| atop | `atop[5]` = 0 with `atop[4:0]` != 0; or `atop[5]` = 1 and not one of: LR with `we` = 0, SC or a defined AMO with `we` = 1 | `irq_atop` |

Without an error (`err` = 0):

| Request | Memory | `rdata` |
|---|---|---|
| plain read (`we` 0, `atop` 0) | - | the word |
| plain write (`we` 1, `atop` 0) | bytes with `be[k]` = 1 replaced | 0 |
| AMO (`we` 1) | the word replaced by the AMO result (all 4 bytes, `be` ignored) | the old word |
| LR.W (`we` 0) | - (sets the reservation on this word) | the word |
| SC.W (`we` 1) | `wdata` written (all bytes) only if the reservation is valid for this word | 0 on success, 1 on failure |

### 3.4 Atomics

`atop[4:0]` codes (with `atop[5]` = 1): 00001 AMOSWAP (result `wdata`), 00000 AMOADD
(old + `wdata`), 00100 AMOXOR, 01100 AMOAND, 01000 AMOOR, 10000 AMOMIN (signed), 10100 AMOMAX
(signed), 11000 AMOMINU, 11100 AMOMAXU, 00010 LR, 00011 SC. Others are atop errors.

Reservation (one, for the whole memory): LR sets it to its word. Every SC clears it (success or
failure). A plain write or an AMO to the reserved word clears it (also with `be` = 0). Reads and
accesses to other words keep it; errored requests do not touch it. Reset clears it.

### 3.5 Integrity

`gntpar` = `~gnt` and `rvalidpar` = `~rvalid` at all times. In every clock out of reset the
manager must drive `reqpar` = `~req` and `rreadypar` = `~rready`; any clock where either equals its
partner makes `irq_par` 1 in the next clock (no other effect).

### 3.6 Reset

While `rst_n` is low: FIFO empty (`rvalid` 0), `gnt` = 0 is not guaranteed by the core when `req`
is 1 (it is `req` && count < NOUT), `irq_*` 0, reservation cleared. Outstanding responses are lost.
The memory keeps its contents (it is zeroed once at time 0 in simulation).

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `NOUT` | 4 | 1 or more | response FIFO depth = maximum outstanding transactions |
| `IDW` | 4 | 1 or more | `aid` / `rid` width |
| `PROT_BASE` | 10'h300 | 0 to 10'h3FF | start (byte offset) of the machine-only window, up to 0x3FF |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| FIFO full (`NOUT` outstanding) | `gnt` 0; the request waits |
| decode and protection both | decode error, only `irq_dec` |
| error response | `err` 1, `rdata` 0, nothing written, reservation unchanged |
| LR with `we` = 1, SC / AMO with `we` = 0 | atop error |
| SC without a reservation, or to another word | returns 1, nothing written |
| write with `be` = 0 to the reserved word | nothing written, reservation cleared |
| parity fault | `irq_par` pulse only; the transfer is still handled |
| reset with responses outstanding | dropped |

## 6. TB check map

Messages are printed by `tb/OBI_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/OBI_sva.sv`, which keeps a shadow memory, reservation and response queue. The TB
drives pipelined traffic with random gaps and `rready` back-pressure, fills the FIFO with `rready`
low, sends 64 back-to-back writes, every AMO, LR / SC pairs (successful and broken), every error
class, parity faults, and a reset with responses outstanding.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "response without a granted request" | no pop with nothing outstanding | §3.2 |
| "response rdata" | each response's `rdata`, `err`, `rid` as predicted | §3.2, §3.3 |
| "gnt without req" | `gnt` only with `req` | §3.1 |
| "gntpar / rvalidpar" | parity outputs are the inverses | §3.5 |
| "more than NOUT responses outstanding" | at most `NOUT` outstanding | §3.1 |
| "rvalid does not match the outstanding count" | `rvalid` = outstanding != 0 | §3.2 |
| "gnt with free FIFO space" | `gnt` = `req` && outstanding < `NOUT` | §3.1 |
| "response changed while rready was low" | head stable under back-pressure | §3.2 |
| "X on a subordinate output" | no X on the outputs | §1 |
| "irq_dec/prot/atop" | error pulses as predicted, with precedence | §3.3 |
| "responses never drained" | all responses arrive within 2000 clocks | §3.2 |
| "idle in reset" | in reset `gnt` (with `req` 0), `rvalid`, `irq_par` 0 | §3.6 |
| "irq_par pulsed" | one `irq_par` pulse per parity-fault clock | §3.5 |
| "reset clears the response FIFO" | after reset `rvalid` 0 | §3.6 |
| "irq counts dec" | pulse counts per error class match the scoreboard | §3.3 |
| "thin traffic: sc ok" | the random run exercised SC success / failure, AMOs and errors | §3.4 |
| a_gnt | `gnt` = `req` && outstanding < `NOUT` | §3.1 |
| a_rvalid | `rvalid` = outstanding != 0 | §3.2 |
| a_rsp | head `rdata` / `err` / `rid` = model queue head | §3.2, §3.3 |
| a_hold | head stable while `rready` is 0 | §3.2 |
| a_par_out | `gntpar` = `~gnt`, `rvalidpar` = `~rvalid` | §3.5 |
| a_irq | the four irq outputs equal the model's pulses | §3.3, §3.5 |
| a_no_x | no X on handshake and irq outputs | §1 |
| a_rst | in reset: `gnt`, `rvalid`, all irqs 0 (with `req` low) | §3.6 |
