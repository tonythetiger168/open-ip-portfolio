<!-- SPDX-License-Identifier: Apache-2.0 -->
# ARM_Local_Translation_Interface: design specification

The translation side of an AMBA LTI (Local Translation Interface) link: translation requests on
LA, responses with context tags on LR, tag returns on LC, link open / close, a small directly
programmed translation table, and invalidation with synchronization against tags still in use.
Not implemented: LTI virtual channels and their ordering, the full LA / LR field set, a page-table
walk (the table is programmed directly), LR flow control, the LM channel beyond open / close.
Field widths and encodings are this design's own. Core `ARM_Local_Translation_Interface_top`
(`rtl/ARM_Local_Translation_Interface_top.sv`), testbench `tb/ARM_Local_Translation_Interface_tb.sv`
(a TB manager and a TB host), checker `tb/cov/ARM_Local_Translation_Interface_sva.sv` (a
cycle-exact model of every output).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; registered outputs show a
decision of clock n in clock n+1. Valids, credits and events are one-clock pulses.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of everything, including the table | low | async | - |
| `lm_open_req` | input | 1 | manager asks for the link to be open (level) | high | `clk` | - |
| `lm_open_ack` | output | 1 | link open or closing (§3.1); combinational from the link state | high | comb | 0 |
| `la_valid` | input | 1 | translation request (one clock per request); needs a credit | high | `clk` | - |
| `la_id` | input | 4 | request id, returned on `lr_id` | - | `clk` | - |
| `la_va` | input | 20 | virtual page VA[31:12] | - | `clk` | - |
| `la_sid` | input | 8 | StreamID | - | `clk` | - |
| `la_ssid` | input | 8 | SubstreamID | - | `clk` | - |
| `la_ssidv` | input | 1 | `la_ssid` valid | - | `clk` | - |
| `la_rw` | input | 2 | bit 0 read, bit 1 write (both may be set) | - | `clk` | - |
| `la_instr` | input | 1 | instruction fetch | - | `clk` | - |
| `la_priv` | input | 1 | privileged access (0 = unprivileged, needs U) | - | `clk` | - |
| `la_credit` | output | 1 | request credit: one per clock it is 1 | high | `clk` | 0 |
| `lr_valid` | output | 1 | translation response (one clock) | high | `clk` | 0 |
| `lr_id` | output | 4 | `la_id` of the request answered | - | `clk` | 0 |
| `lr_resp` | output | 2 | 0 OK, 1 translation fault, 2 permission fault | - | `clk` | 0 |
| `lr_pa` | output | 20 | physical page PA[31:12] (OK), else 0 | - | `clk` | 0 |
| `lr_attr` | output | 8 | entry attributes (OK), else 0 | - | `clk` | 0 |
| `lr_ctag` | output | `log2(NCT)` | context tag handed out with an OK response, else 0 | - | `clk` | 0 |
| `lc_valid` | input | 1 | completion: the manager returns a context tag | high | `clk` | - |
| `lc_ctag` | input | `log2(NCT)` | tag returned | - | `clk` | - |
| `cfg_we` | input | 1 | write table entry `cfg_idx` at this edge | high | `clk` | - |
| `cfg_idx` | input | `log2(NE)` | entry index | - | `clk` | - |
| `cfg_v` | input | 1 | entry valid | - | `clk` | - |
| `cfg_sid` | input | 8 | entry StreamID | - | `clk` | - |
| `cfg_ssid` | input | 8 | entry SubstreamID | - | `clk` | - |
| `cfg_ssidv` | input | 1 | 1: match only this SubstreamID; 0: any substream | - | `clk` | - |
| `cfg_va` | input | 20 | entry virtual page | - | `clk` | - |
| `cfg_pa` | input | 20 | entry physical page | - | `clk` | - |
| `cfg_perm` | input | 4 | permissions {U, X, W, R} | - | `clk` | - |
| `cfg_attr` | input | 8 | entry attributes | - | `clk` | - |
| `inv_valid` | input | 1 | invalidation request; taken with `inv_ready` | high | `clk` | - |
| `inv_ready` | output | 1 | no invalidation waiting for its sync (combinational) | high | comb | 1 |
| `inv_all` | input | 1 | invalidate every entry | high | `clk` | - |
| `inv_sid` | input | 8 | invalidate the entries of this StreamID (when `inv_all` is 0) | - | `clk` | - |
| `inv_done` | output | 1 | one-clock pulse: the invalidation is complete (§3.5) | high | `clk` | 0 |
| `ctags_out` | output | `log2(NCT)`+1 | number of context tags out (combinational) | - | comb | 0 |
| `ev_fault` | output | 1 | one-clock pulse with every fault response | high | `clk` | 0 |
| `ev_proto` | output | 1 | pulse in the clock after a request without a credit or a return of a tag that is not out | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads this by name to time a scenario; a re-implementation must have it.

| Signal | Width | Meaning |
|---|---|---|
| `rq_n` | `log2(RQ)`+1 | requests held in the request slots (taken, not yet answered) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/ARM_Local_Translation_Interface.md`](../ip/ARM_Local_Translation_Interface.md) (source: `scripts/apb/specs/ARM_Local_Translation_Interface.json`); do not edit by hand.

`ARM_Local_Translation_Interface_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `lm_open_req`, `lm_open_ack`, `la_valid`, `la_id`, `la_va`, `la_sid`, `la_ssid`, `la_ssidv`, `la_rw`, `la_instr`, `la_priv`, `la_credit`, `lr_valid`, `lr_id`, `lr_resp`, `lr_pa`, `lr_attr`, `lr_ctag`, `lc_valid`, `lc_ctag`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4C540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TBL0 | RW | 0x00000000 | Translation table entry; writing TBL2 writes entry cfg_idx |
| 0x018 | TBL1 | RW | 0x00000000 | Translation table entry; writing TBL2 writes entry cfg_idx |
| 0x01C | TBL2 | RW | 0x00000000 | Translation table entry; writing TBL2 writes entry cfg_idx |
| 0x020 | INV | RW | 0x00000000 | Invalidation; writing INV clears every entry (inv_all) or the entries of StreamID inv_sid. The core takes it once the one before has synchronized |
| 0x024 | STATUS | RO | core | Context tags |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4C54 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TBL0 | 7:0 | `cfg_sid` | RW | 0x0 | StreamID |
| TBL0 | 15:8 | `cfg_ssid` | RW | 0x0 | SubstreamID |
| TBL0 | 16 | `cfg_ssidv` | RW | 0x0 | set: the entry is for SubstreamID cfg_ssid only; clear: for any substream |
| TBL0 | 19:17 | `cfg_idx` | RW | 0x0 | entry |
| TBL0 | 20 | `cfg_v` | RW | 0x0 | valid |
| TBL0 | 24:21 | `cfg_perm` | RW | 0x0 | permissions {U, X, W, R} |
| TBL1 | 19:0 | `cfg_va` | RW | 0x0 | VA[31:12] |
| TBL1 | 27:20 | `cfg_attr` | RW | 0x0 | memory attributes returned on LR |
| TBL2 | 19:0 | `cfg_pa` | RW | 0x0 | PA[31:12] |
| INV | 0 | `inv_all` | RW | 0x0 | every entry |
| INV | 8:1 | `inv_sid` | RW | 0x0 | StreamID |
| STATUS | 3:0 | `ctags_out` | RO | core | context tags handed out on LR and not yet returned on LC |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FAULT | a translation or permission fault was returned on LR |
| 1 | PROTO | a request without a credit (dropped) or a context tag returned that was not out |
| 2 | SYNC | an invalidation has synchronized: every tag out when it was taken has come back |
| 3 | INV_DONE | INV beat accepted by the core |
| 4 | INV_OVF | write to INV while full (dropped) |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | INV_FULL | INV holds a beat the core has not taken |

### Streams

* **TBL** feeds `cfg_sid`, `cfg_ssid`, `cfg_ssidv`, `cfg_idx`, `cfg_v`, `cfg_perm`, `cfg_va`, `cfg_attr`, `cfg_pa`; writing TBL2 pulses `cfg_we` for one clock.
* **INV** feeds `inv_all`, `inv_sid`/`inv_valid`. Writing INV commits the beat: FLAGS.INV_FULL is set and `inv_valid` stays high until the core's `inv_ready`; then INV_DONE is set. A write while full is dropped and sets INV_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4C540200.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
4. To send on TBL: write TBL0 (0x014) then TBL1 (0x018) then TBL2 (0x01C). The last write pulses `cfg_we` for one clock; there is no back-pressure.
5. To send on INV: wait until FLAGS.INV_FULL (bit 0) is 0, or for IRQ INV_DONE, then write INV (0x020). The last write commits the beat. INV_OVF means a write came while the register was full and was dropped.
6. Read STATUS (0x024) for the core's live `ctags_out`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Link and credits

| State | `lm_open_ack` | Moves on |
|---|---|---|
| CLOSED | 0 | `lm_open_req` = 1 -> OPEN |
| OPEN | 1 | `lm_open_req` = 0 -> CLOSING |
| CLOSING | 1 | no request held or arriving and no tag out -> CLOSED; credits the manager holds become void |

In OPEN (including the clock `lm_open_req` falls) the unit pulses `la_credit` (at most one per
clock) while the credits out plus the requests held (after this clock's arrival and answer) are
fewer than `RQ`. A request uses one credit; a request while the manager holds none is dropped
with `ev_proto`. In CLOSING no credits are granted but requests sent with held credits are still
answered.

### 3.2 Requests and responses

Requests are answered in order, at most one per clock. A request on LA in clock n can be answered
in clock n+1, so `lr_valid` comes 2 clocks after `la_valid` at the earliest. The head is looked up
in the table as it stands in its answer clock (a `cfg_we` or an invalidation in that clock takes
effect only after it).

* Lookup: the lowest-numbered valid entry with `sid` = request StreamID, `va` = request VA page,
  and either `ssidv` = 0 (any substream) or the request has `la_ssidv` = 1 and the same
  SubstreamID.
* No entry: `lr_resp` 1 (translation fault), `lr_pa` / `lr_attr` / `lr_ctag` 0, `ev_fault` with it.
* Entry found, permission check: a read (`la_rw[0]`) needs R, a write (`la_rw[1]`) needs W, an
  instruction fetch needs X, an unprivileged access (`la_priv` = 0) needs U. A failure gives
  `lr_resp` 2 (permission fault), the rest 0, `ev_fault`.
* Otherwise `lr_resp` 0 with the entry's `pa` and `attr` and the lowest free context tag on
  `lr_ctag`, which is then out. If all `NCT` tags are out, an OK answer waits (and so do the
  requests behind it); faults never wait.

### 3.3 Completions

`lc_valid` with `lc_ctag` returns a tag; it is free for a new response from the next clock (a tag
returned in a clock is not handed out again in the same clock). Returning a tag that is not out is
ignored with `ev_proto`. `ctags_out` counts the tags out.

### 3.4 Table writes

`cfg_we` writes every field of entry `cfg_idx` at the edge. An invalidation in the same clock that
matches that entry wins (the entry ends up invalid).

### 3.5 Invalidation

An invalidation is taken at an edge with `inv_valid` and `inv_ready`. At that edge every entry
with `inv_all` = 1, or with `sid` = `inv_sid`, becomes invalid (the SubstreamID is not looked at).
The tags out at that edge (including one handed out in that clock and excluding one returned in
it) must all come back:

* none out: `inv_done` pulses in the next clock, `inv_ready` stays 1;
* otherwise `inv_ready` falls; when the last of those tags returns, `inv_done` pulses in the next
  clock and `inv_ready` rises. Tags handed out later do not delay it.

### 3.6 Reset

While `rst_n` is low: link CLOSED, every output 0 except `inv_ready` 1, table empty, no tags out,
no credits.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `NE` | 8 | 2 or more | translation table entries |
| `RQ` | 4 | power of 2, 2 or more | request slots / credits |
| `NCT` | 8 | power of 2, 2 or more | context tags |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| request without a credit | dropped, `ev_proto` |
| tag returned that is not out | ignored, `ev_proto` |
| all tags out | OK answers wait; fault answers still go |
| several entries match | the lowest index wins |
| entry rewritten while requests wait | each request uses the table of its answer clock |
| invalidation while one is waiting | not taken (`inv_ready` 0) |
| link closed with tags out | CLOSING until every tag is back, then CLOSED |
| reset with traffic in flight | everything cleared, the table too |

## 6. TB check map

Messages are printed by `tb/ARM_Local_Translation_Interface_tb.sv` as `ERROR: <message>`.
Assertions `a_*` are in the bound checker `tb/cov/ARM_Local_Translation_Interface_sva.sv`, which
computes the exact value of every output in every clock. The TB manager opens the link, counts
credits, sends hits, misses, every permission case, substream and any-substream entries, returns
tags after a random delay or holds them all; the TB host rewrites entries and invalidates (all, by
StreamID) under traffic; the link is closed and opened with tags out; error cases and a reset with
traffic in flight are included.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "response with no request" | no LR without a request | §3.2 |
| "LR id" | each LR: id, resp, pa, attr as the reference table predicts, in order | §3.2 |
| "tag" | a tag is free when handed out | §3.2, §3.3 |
| "inv_done with no invalidation" | `inv_done` only for a taken invalidation | §3.5 |
| "inv_done with tag" | `inv_done` only after every tag out at the invalidation came back | §3.5 |
| "invalidation done with the tag handed out with it still out" | the tag handed out in the invalidation clock is waited for | §3.5 |
| "tags not all out" | with tags held, all `NCT` go out and OK answers wait | §3.2 |
| "link closed with tags out" | `lm_open_ack` stays 1 in CLOSING until the tags are back | §3.1 |
| a_lr | LR outputs exactly as the model | §3.2 |
| a_link | `lm_open_ack` and `la_credit` exactly as the model | §3.1 |
| a_inv | `inv_ready`, `inv_done`, `ctags_out` exactly as the model | §3.3, §3.5 |
| a_events | `ev_fault` / `ev_proto` exactly as the model | §3.2, §3.3 |
| a_reset | in reset: outputs 0, `inv_ready` 1 | §3.6 |
