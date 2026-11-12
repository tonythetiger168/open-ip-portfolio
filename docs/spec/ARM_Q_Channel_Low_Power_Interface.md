<!-- SPDX-License-Identifier: Apache-2.0 -->
# ARM_Q_Channel_Low_Power_Interface: design specification

Device side of an AMBA Q-Channel low-power interface: the controller requests quiescence with
`qreqn` low; the device accepts (`qacceptn` low) when it has been idle, or denies (`qdeny` high)
when it is active. Activity is an `ACT_CYCLES`-clock window restarted by every `dev_event` and
shown on `qactive`. An illegal `qreqn` sequence raises `irq`. Core
`ARM_Q_Channel_Low_Power_Interface_top`, testbench
`tb/ARM_Q_Channel_Low_Power_Interface_tb.sv`, checker
`tb/cov/ARM_Q_Channel_Low_Power_Interface_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; "the clock after edge E"
is the cycle between E and E+1.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | device clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `qreqn` | input | 1 | QREQn from the controller: 0 = request the low-power (quiescent) state, 1 = run | low | clk | - |
| `qacceptn` | output | 1 | QACCEPTn: 0 = the device has entered the low-power state (STOPPED or EXIT); Moore output of the state | low | clk | 1 |
| `qdeny` | output | 1 | QDENY: 1 = the request was refused (state DENIED); Moore | high | clk | 0 |
| `qactive` | output | 1 | QACTIVE: the device is busy (`act_cnt` ≠ 0) | high | clk | 0 |
| `dev_event` | input | 1 | internal activity event (interrupt, DMA, ...): restarts the activity window | high | clk | - |
| `irq` | output | 1 | illegal `qreqn` sequence, combinational: `(state == REQUEST && qreqn) \|\| (state == EXIT && !qreqn)` | high | comb. | 0 |

### Internal signals used by the verification

| Signal | Width | Meaning |
|---|---|---|
| `state` | 3 | FSM state, encoded RUN = 0, REQUEST = 1, STOPPED = 2, EXIT = 3, DENIED = 4 (the TB checks this encoding) |
| `act_cnt` | `$clog2(ACT_CYCLES + 1)` | activity counter; `qactive = (act_cnt != 0)` |

## 2. Registers

The core has no registers of its own; the APB4 wrapper `ARM_Q_Channel_Low_Power_Interface_apb`
maps the pins and `irq` onto the registers below.

<!-- AUTO:registers -->
Generated from [`docs/ip/ARM_Q_Channel_Low_Power_Interface.md`](../ip/ARM_Q_Channel_Low_Power_Interface.md) (source: `scripts/apb/specs/ARM_Q_Channel_Low_Power_Interface.json`); do not edit by hand.

`ARM_Q_Channel_Low_Power_Interface_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `qreqn`, `qacceptn`, `qdeny`, `qactive`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x51430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | EVENT | WO (pulse) | 0x00000000 | Device activity |
| 0x018 | STATUS | RO | core | Q-Channel outputs, as driven on the pins |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x01C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5143 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| EVENT | 0 | `dev_event` | WO (pulse) | 0x0 | write 1: an activity event; qactive stays high for ACT_CYCLES (16) clocks after the last one, and a request while it is high is denied |
| STATUS | 0 | `qacceptn` | RO | core | low: the device accepted the request and is stopped (STOPPED and EXIT) |
| STATUS | 1 | `qdeny` | RO | core | high: the request was denied (DENIED, until qreqn rises) |
| STATUS | 2 | `qactive` | RO | core | high: activity within the last ACT_CYCLES clocks |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ILLEGAL | the controller broke the handshake: qreqn rose before the device answered a request, or fell during the exit |
| 1 | DENIED | a request was denied; set on every clock qdeny is high, so a clear only holds once qreqn has risen |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x51430200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
4. To issue a command, write 1 to `dev_event` (EVENT bit 0) at 0x014; the core sees a one-clock pulse, and the register reads 0.
5. Read STATUS (0x018) for the core's live `qacceptn`, `qdeny`, `qactive`; it needs no clearing.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Activity window

At each edge: if `dev_event` = 1, `act_cnt <= ACT_CYCLES`; else if `act_cnt` ≠ 0,
`act_cnt <= act_cnt - 1`. So after the last edge that sampled `dev_event` = 1, `qactive` is high
for exactly `ACT_CYCLES` clocks. Activity does not change the state by itself (a device that
becomes active while STOPPED stays STOPPED; the controller must raise `qreqn`).

### 3.2 Handshake FSM

Transitions at each edge, from the state and the sampled `qreqn`:

| State | `qreqn` = 1 | `qreqn` = 0 | `qacceptn` | `qdeny` |
|---|---|---|---|---|
| RUN | RUN | REQUEST | 1 | 0 |
| REQUEST | RUN (illegal: `irq` in this clock) | DENIED if `qactive` in this clock, else STOPPED | 1 | 0 |
| DENIED | RUN | DENIED | 1 | 1 |
| STOPPED | EXIT | STOPPED | 0 | 0 |
| EXIT | RUN | STOPPED (illegal: `irq` in this clock) | 0 | 0 |

Timeline of a request: the edge that first samples `qreqn` = 0 moves RUN → REQUEST; the next
edge decides, so `qacceptn` falls (or `qdeny` rises) in the second clock after `qreqn` is seen
low. The activity is judged in the REQUEST clock: an event sampled at the same edge as the
`qreqn` fall makes the device active in that clock and it denies; a request whose REQUEST
clock is the last active clock is denied; one clock later it is accepted. Exit: `qreqn` = 1
seen in STOPPED → EXIT (one clock, `qacceptn` still 0), then RUN (`qacceptn` = 1). Leaving
DENIED takes one edge after `qreqn` rises.

`irq` is combinational and lasts only the one clock in REQUEST or EXIT; the FSM moves on at the
next edge (to RUN or STOPPED), so it never repeats.

### 3.3 Reset

`rst_n` low: state RUN, `act_cnt` = 0, so `qacceptn` = 1, `qdeny` = 0, `qactive` = 0, `irq` = 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | any | unused (interface conformity) |
| `AW` | 32 | any | unused (interface conformity) |
| `ACT_CYCLES` | 16 | ≥ 1 | length of the activity window in clocks (§3.1) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `qreqn` rises again before the device answers (REQUEST) | `irq` for one clock, back to RUN |
| `qreqn` falls again during EXIT | `irq` for one clock, back to STOPPED |
| request while active | DENIED until `qreqn` rises; the window may expire meanwhile, still denied |
| `dev_event` while STOPPED | `qactive` rises, state stays STOPPED |
| `qdeny` and `qacceptn` low together | never happens |

## 6. TB check map

Messages are printed by `tb/ARM_Q_Channel_Low_Power_Interface_tb.sv` as `ERROR: <message>`;
"crv:" messages and A1..A6 are built only for Verilator. Assertions a_* are in the checker.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "reset: qacceptn must be 1 (Q_RUN)" | reset → RUN | §3.3 |
| "reset: qdeny must be 0" | reset → no deny | §3.3 |
| "reset: qactive must be 0" | reset → idle | §3.3 |
| "reset: irq must be 0" | reset → no `irq` | §3.3 |
| "q_request: accept expected" | idle device answers a request with `qacceptn` = 0 within 10 clocks | §3.2 |
| "q_request: deny expected" | active device answers with `qdeny` = 1, `qacceptn` = 1 | §3.2 |
| "q_restore: must reach Q_RUN" | after `qreqn` rises, RUN within 6 clocks | §3.2 |
| "stopped: outputs stable" | STOPPED holds `qacceptn` 0, `qdeny` 0 | §3.2 |
| "stopped: no irq" | no `irq` while stopped with `qreqn` low | §3.2 |
| "deny: qactive must rise after dev_event" | `qactive` the clock after an event | §3.1 |
| "deny: legal deny must not raise irq" | a deny is not an error | §3.2 |
| "denied: outputs stable" | DENIED holds while `qreqn` low | §3.2 |
| "deny: qdeny must clear on qreqn high" | DENIED → RUN | §3.2 |
| "wake: activity must expire" | `qactive` falls after the window | §3.1 |
| "wake: qactive must rise in stopped state" | events still counted while STOPPED | §3.1, §5 |
| "wake: still stopped until qreqn rises" | activity does not leave STOPPED | §3.1, §5 |
| "illegal: irq expected on premature qreqn rise" | `qreqn` 0 for one clock: `irq` in the REQUEST clock | §3.2, §5 |
| "illegal: irq must clear next cycle" | `irq` lasts one clock | §3.2 |
| "illegal: must return to Q_RUN" | back to RUN | §3.2 |
| "repeat: activity must have expired" | window over after 20 clocks | §3.1 |
| "exit-drop: irq expected" | `qreqn` falls during EXIT: `irq` | §3.2, §5 |
| "exit-drop: device must stay stopped" | and back to STOPPED | §3.2 |
| "reset: Q_RUN expected" | reset while STOPPED and active: at once `qacceptn` 1, `qdeny` 0, `qactive` 0 | §3.3 |
| "event in the request cycle denies" | event sampled with the `qreqn` fall → deny | §3.2 |
| "deny in the window's last cycle" | REQUEST in the last active clock → deny, window then expires while denied | §3.2 |
| "accept right after the window" | REQUEST one clock later → accept | §3.2 |
| "qreqn drop during exit returns to stopped" | EXIT with `qreqn` 0 → STOPPED | §3.2 |
| "crv: stopped outputs stable" | random dwell in STOPPED | §3.2 |
| "crv: legal deny must not raise irq" | random denies | §3.2 |
| "crv: illegal sequence must raise irq" | random premature `qreqn` rises | §5 |
| "crv: irq must clear next cycle" | one-clock `irq` | §3.2 |
| "crv: must return to Q_RUN after illegal sequence" | back to RUN | §3.2 |
| "crv: wake must raise qactive" | events while stopped | §3.1 |
| "crv: still stopped until qreqn rises" | activity does not wake by itself | §3.1 |
| "A1 reset: outputs quiescent" | reset outputs | §3.3 |
| "A2 state encoding legal" | `state` ≤ 4 | §1 |
| "A3 qdeny == Q_DENIED" | `qdeny` = (state 4) | §3.2 |
| "A4 qacceptn Moore decode" | `qacceptn` = state not 2 or 3 | §3.2 |
| "A5 irq illegal-sequence decode" | `irq` = (state 1 && `qreqn`) or (state 3 && !`qreqn`) | §1, §3.2 |
| "A6 qactive == act_cnt!=0" | `qactive` = (`act_cnt` ≠ 0) | §3.1 |
| "TIMEOUT guard fired" | the test finishes | §3.2 |
| a_reset_run | in reset: `qacceptn` 1, no deny, not active, no `irq` | §3.3 |
| a_accept_deny_exclusive | never `qdeny` with `qacceptn` low | §5 |
| a_qacceptn_model | `qacceptn` equals the model | §3.2 |
| a_qdeny_model | `qdeny` equals the model | §3.2 |
| a_qactive_model | `qactive` equals the model window | §3.1 |
| a_idle_request_accepted | REQUEST, `qreqn` low, idle → accept next clock | §3.2 |
| a_busy_request_denied | REQUEST, `qreqn` low, active → deny next clock | §3.2 |
| a_exit_restores_run | EXIT with `qreqn` high → RUN next clock | §3.2 |
| a_irq_on_violation | `irq` = model's illegal-sequence decode | §3.2 |
