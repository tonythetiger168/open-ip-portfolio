<!-- SPDX-License-Identifier: Apache-2.0 -->
# ACE_Lite: design specification

ACE-Lite (I/O-coherent) subordinate with a 256 x 32-bit memory: the five AXI4 channels with INCR
bursts of up to 256 beats, byte strobes, and the ACE-Lite AxSNOOP / AxDOMAIN / AxBAR fields
accepted and ignored. There are no snoop channels; one write burst and one read burst can be in
flight at a time, on independent paths, and every transaction completes in order, which meets
barrier ordering. Core `ACE_Lite_top` (`rtl/ACE_Lite_top.sv`), testbench `tb/ACE_Lite_tb.sv` (an
AXI4 manager with ACE-Lite fields and a scoreboard), checker `tb/cov/ACE_Lite_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A handshake happens at a rising edge where VALID and READY are
both 1. All outputs except `irq` are combinational decodes of the state registers.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | ACLK | rising edge | - | - |
| `rst_n` | input | 1 | ARESETn: asynchronous reset of both state machines and `irq` (not the memory) | low | async | - |
| `awvalid` | input | 1 | AWVALID | high | `clk` | - |
| `awready` | output | 1 | AWREADY: 1 exactly when the write path is idle | high | comb | 1 |
| `awaddr` | input | `AW` | AWADDR, start byte address; bits 1:0 are ignored (§3.3) | - | `clk` | - |
| `awlen` | input | 8 | AWLEN: beats - 1 (1 to 256 beats) | - | `clk` | - |
| `awsize` | input | 3 | AWSIZE: 0 to 2 legal; above 2 (more than 4 bytes) is an error (§3.3). The address always steps 4 per beat | - | `clk` | - |
| `awburst` | input | 2 | AWBURST: only 01 INCR is legal; FIXED / WRAP / reserved are errors | - | `clk` | - |
| `awsnoop` | input | 3 | AWSNOOP (WriteNoSnoop, WriteUnique, WriteLineUnique, ...): accepted and ignored | - | `clk` | - |
| `awdomain` | input | 2 | AWDOMAIN: accepted and ignored | - | `clk` | - |
| `awbar` | input | 2 | AWBAR: accepted and ignored; barriers are met by in-order completion (§3.4) | - | `clk` | - |
| `wvalid` | input | 1 | WVALID | high | `clk` | - |
| `wready` | output | 1 | WREADY: 1 from the AW handshake until the last W beat | high | comb | 0 |
| `wdata` | input | `DW` | WDATA | - | `clk` | - |
| `wstrb` | input | `DW/8` | WSTRB: byte lane k written when bit k is 1 | high | `clk` | - |
| `wlast` | input | 1 | WLAST: ends the burst early when 1 (§3.1) | high | `clk` | - |
| `bvalid` | output | 1 | BVALID: 1 from the clock after the last W beat until the B handshake | high | comb | 0 |
| `bready` | input | 1 | BREADY | high | `clk` | - |
| `bresp` | output | 2 | BRESP: 00 OKAY, 10 SLVERR (§3.3); valid with `bvalid` | - | comb | 00 |
| `arvalid` | input | 1 | ARVALID | high | `clk` | - |
| `arready` | output | 1 | ARREADY: 1 exactly when the read path is idle | high | comb | 1 |
| `araddr` | input | `AW` | ARADDR, start byte address; bits 1:0 ignored | - | `clk` | - |
| `arlen` | input | 8 | ARLEN: beats - 1 | - | `clk` | - |
| `arsize` | input | 3 | ARSIZE: above 2 is an error | - | `clk` | - |
| `arburst` | input | 2 | ARBURST: only 01 INCR is legal | - | `clk` | - |
| `arsnoop` | input | 4 | ARSNOOP (ReadNoSnoop, ReadOnce, CleanShared, CleanInvalid, MakeInvalid, ...): accepted and ignored | - | `clk` | - |
| `ardomain` | input | 2 | ARDOMAIN: accepted and ignored | - | `clk` | - |
| `arbar` | input | 2 | ARBAR: accepted and ignored | - | `clk` | - |
| `rvalid` | output | 1 | RVALID: 1 from the clock after the AR handshake until the R handshake of the last beat | high | comb | 0 |
| `rready` | input | 1 | RREADY | high | `clk` | - |
| `rdata` | output | `DW` | RDATA: the word of the current beat, 0 on an errored beat (§3.3) | - | comb | word 0 |
| `rresp` | output | 2 | RRESP per beat: 00 OKAY, 10 SLVERR | - | comb | 00 |
| `rlast` | output | 1 | RLAST: 1 on the beat number `arlen` | high | comb | 0 |
| `irq` | output | 1 | one-clock pulse in the clock after the last W beat of an errored write or the last R beat of an errored read | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name (FSM coverage); a re-implementation must have them with this encoding.

| Signal | Width | Meaning |
|---|---|---|
| `wstate` | 2 | write path: 0 W_IDLE (`awready`), 1 W_DATA (`wready`), 2 W_RESP (`bvalid`) |
| `rstate` | 1 | read path: 0 R_IDLE (`arready`), 1 R_DATA (`rvalid`) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/ACE_Lite.md`](../ip/ACE_Lite.md) (source: `scripts/apb/specs/ACE_Lite.json`); do not edit by hand.

`ACE_Lite_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `awvalid`, `awready`, `awaddr`, `awlen`, `awsize`, `awburst`, `awsnoop`, `awdomain`, `awbar`, `wvalid`, `wready`, `wdata`, `wstrb`, `wlast`, `bvalid`, `bready`, `bresp`, `arvalid`, `arready`, `araddr`, `arlen`, `arsize`, `arburst`, `arsnoop`, `ardomain`, `arbar`, `rvalid`, `rready`, `rdata`, `rresp`, `rlast`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41450200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4145 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a burst ended with SLVERR: a burst type other than INCR, a size above 4 bytes, a start above 0x3FF, or beats running past 0x3FF |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41450200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Write path

| State | Outputs | Leaves at the edge with | To |
|---|---|---|---|
| W_IDLE | `awready` = 1 | AW handshake: address, `awlen` captured; beat count 0; error flag = header error (§3.3) | W_DATA |
| W_DATA | `wready` = 1 | W handshake of the last beat (below) | W_RESP |
| W_RESP | `bvalid` = 1, `bresp` | B handshake | W_IDLE |

* Each W handshake in W_DATA writes one beat (§3.3), adds 4 to the address and 1 to the beat
  count. The beat is the last when `wlast` = 1 or the beat count equals `awlen`, whichever comes
  first: an early `wlast` ends the burst, and a missing `wlast` does not extend it. Neither is
  an error.
* W is only taken after the AW handshake (`wready` is 0 in W_IDLE). One write is outstanding;
  the next AW is taken in the clock after the B handshake. `bvalid` / `bresp` hold until `bready`.

### 3.2 Read path

| State | Outputs | Leaves at the edge with | To |
|---|---|---|---|
| R_IDLE | `arready` = 1 | AR handshake: address, `arlen` captured; beat 0; error flag | R_DATA |
| R_DATA | `rvalid` = 1, `rdata`, `rresp`, `rlast` | R handshake of beat `arlen` | R_IDLE |

* Each R handshake moves to the next beat (address + 4). `rlast` is 1 on beat `arlen`. The beat
  payload holds while `rready` is 0.
* The read path is independent of the write path: AW and AR can be taken at the same edge.

### 3.3 Address decode, errors and data

* Header error: AxBURST != INCR, or AxSIZE > 2, or the start address >= 0x400 (any of bits
  `AW-1:10` set). The low address bits 1:0 are ignored (no alignment check) and the address steps
  4 bytes per beat whatever AxSIZE says.
* Beat range: a beat whose current address is >= 0x400 is out of range. A burst that runs past
  0x3FC never wraps to word 0.
* Write beat: written only if there was no header error and the beat is in range; then byte lane
  k of word `addr[9:2]` takes `wdata[8k+7:8k]` where `wstrb[k]` = 1. An out-of-range beat also
  makes the rest of the burst an error. `bresp` = SLVERR if the header was in error or any beat was
  out of range; the in-range beats before the crossing have landed.
* Read beat: `rdata` = word `addr[9:2]` read combinationally from the memory, `rresp` OKAY; with a
  header error or an out-of-range beat `rdata` = 0 and `rresp` = SLVERR for that beat. So a read
  that crosses 0x3FC returns OKAY beats up to the end and SLVERR beats after.
* The memory is not reset: it keeps its contents through `rst_n` and is undefined until written
  (a 2-state simulator shows 0; the checker's shadow starts at 0).

### 3.4 Ordering and ACE-Lite fields

AxSNOOP, AxDOMAIN and AxBAR do not change anything: every transaction type (WriteNoSnoop,
WriteUnique, WriteLineUnique, ReadNoSnoop, ReadOnce, CleanShared, CleanInvalid, MakeInvalid, and
barriers) is a plain memory access. A write's data is in the memory at its last W handshake,
before its B response, so any read whose AR is taken after a B handshake sees that write.

### 3.5 irq

`irq` is 1 for exactly one clock: the clock after the last W handshake of a write that ends with
SLVERR, or the clock after the last R handshake of a read whose last beat is SLVERR. A write and a
read ending in errors on consecutive edges give two consecutive clocks of `irq`.

### 3.6 Reset

While `rst_n` is low both paths are idle: `awready` = `arready` = 1, `wready` = `bvalid` =
`rvalid` = `rlast` = 0, `bresp` = `rresp` = OKAY, `irq` = 0. Bursts in flight are abandoned; the
beats already written stay in the memory.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | 32 | data width; the memory has 4-byte words and the address steps 4 per beat |
| `AW` | 32 | 11 to 64 | address width; bits `AW-1:10` must be 0 for an in-range beat |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| start address >= 0x400 | write: all beats taken and dropped, `bresp` SLVERR; read: every beat 0 / SLVERR; `irq` pulse at the end |
| FIXED, WRAP or reserved AxBURST | same as out of range (whole burst) |
| AxSIZE > 2 | same as out of range |
| INCR burst crossing 0x3FC | beats up to 0x3FC land / read OKAY, beats past it are dropped / read 0 with SLVERR, no wrap; write `bresp` SLVERR |
| misaligned start address | not an error: bits 1:0 are ignored |
| AxSIZE 0 or 1 | accepted; still one 32-bit word per beat, address + 4 |
| early `wlast` | burst ends there, OKAY |
| no `wlast` on beat `awlen` | burst ends by count, OKAY |
| `bready` / `rready` low | response / beat payload held |
| write to a word that a stalled R beat is returning | `rdata` is read live from the memory, so it changes under the stall (an AXI stability violation); the TB never overlaps them |
| reset mid-burst on both paths | both abandoned; written beats remain |

## 6. TB check map

Messages are printed by `tb/ACE_Lite_tb.sv` as `ERROR: <message>`; its immediate checks print
`SVA_FAIL: <name>`. Assertions `a_*` are in the bound checker `tb/cov/ACE_Lite_sva.sv`, which
keeps an independent shadow of the memory and of each burst. The TB checks the reset state,
burst writes / reads of 1, 4 and 16 beats, byte-strobe merges, barrier ordering, out-of-range and
unsupported-burst errors with `irq`, back-to-back bursts, bursts crossing 0x3FC both ways, early
and missing `wlast`, concurrent write + read, reset with both paths mid-burst, every ACE-Lite
transaction type in and out of range, sizes and byte lanes, and (Verilator) random bursts.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "CRV ACE_Lite write" | random burst: BRESP as the model predicts | §3.3 |
| "CRV ACE_Lite read" | random burst: per-beat data, `rlast`, RRESP as the scoreboard predicts | §3.2, §3.3 |
| "ACE_Lite write" | directed burst BRESP | §3.3 |
| "ACE_Lite read" | directed burst: per-beat data, `rlast`, RRESP | §3.2, §3.3 |
| "ACE_Lite reset state bvalid" | `bvalid`, `rvalid`, `irq` 0 after reset | §3.6 |
| "ACE_Lite irq not asserted on SLVERR protocol error" | an out-of-range write / read pulses `irq` | §3.5 |
| "ACE_Lite 1KB-cross read beat" | read crossing 0x3FC: OKAY beats then 0 / SLVERR | §3.3 |
| "ACE_Lite early wlast bresp" | early `wlast` ends the burst with OKAY | §3.1 |
| "ACE_Lite missing wlast bresp" | the beat count ends the burst with OKAY | §3.1 |
| "ACE_Lite outputs not quiescent in reset" | reset mid-burst: `bvalid`, `rvalid`, `wready`, `irq` 0 | §3.6 |
| "A1 reset: b/rvalid low" | no `bvalid` / `rvalid` in or leaving reset | §3.6 |
| "A2 bvalid/bresp held until bready" | B payload stable under backpressure | §3.1 |
| "A3 rvalid/rdata/rresp held until rready" | R payload (with `rlast`) stable under backpressure | §3.2 |
| "A4 rlast implies rvalid" | `rlast` only with `rvalid` | §3.2 |
| "A5 b/rresp legal" | responses only OKAY / SLVERR | §3.3 |
| "A6 one write phase hot" | exactly one of `awready`, `wready`, `bvalid` | §3.1 |
| "A7 irq single-cycle pulse" | `irq` never two clocks in a row (in the TB's traffic) | §3.5 |
| a_reset_quiet | in reset: `bvalid`, `rvalid`, `wready`, `irq` 0 | §3.6 |
| a_b_stable | `bvalid` / `bresp` held while `bready` is 0 | §3.1 |
| a_r_stable | R payload held while `rready` is 0 | §3.2 |
| a_aw_only_idle | `awready` only with no write in flight | §3.1 |
| a_ar_only_idle | `arready` only with no read in flight | §3.2 |
| a_wready_in_burst | `wready` only between AW and the last W beat | §3.1 |
| a_bvalid_model | `bvalid` only after the last W beat | §3.1 |
| a_one_write_phase | one-hot write phase outputs | §3.1 |
| a_bresp_model | `bresp` = SLVERR iff header error or a beat out of range | §3.3 |
| a_rvalid_model | `rvalid` only while a read burst is in flight | §3.2 |
| a_rresp_model | per-beat `rresp` and `rlast` as the model | §3.2, §3.3 |
| a_rdata_model | `rdata` = shadow word, 0 on an errored beat | §3.3 |
| a_irq_on_werr | errored write's last W beat pulses `irq` next clock | §3.5 |
| a_irq_on_rerr | errored read's last beat pulses `irq` next clock | §3.5 |
| a_irq_cause | `irq` only after such a last beat | §3.5 |
