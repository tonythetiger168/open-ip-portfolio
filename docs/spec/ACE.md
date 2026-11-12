<!-- SPDX-License-Identifier: Apache-2.0 -->
# ACE: design specification

ACE (AXI Coherency Extension) cached agent: the five AXI4 channels (INCR bursts) feed a 64-line
direct-mapped write-back cache of one 32-bit word per line, and the ACE snoop channels (AC / CR /
CD) let the interconnect snoop it: ReadShared and ReadClean return a hit line on CD (passing
dirtiness), CleanInvalid returns dirty data and invalidates, MakeInvalid invalidates. There is no
memory behind the cache: a read miss returns 0. Core `ACE_top` (`rtl/ACE_top.sv`), testbench
`tb/ACE_tb.sv` (an AXI4 manager plus a snoop interconnect model), checker `tb/cov/ACE_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A handshake happens at a rising edge where VALID and READY are both
1. All outputs except `irq` are combinational from the state registers and the cache.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | ACLK | rising edge | - | - |
| `rst_n` | input | 1 | ARESETn: asynchronous reset of all state machines, `irq` and the cache valid / dirty bits (not the tags or data) | low | async | - |
| `awvalid` | input | 1 | AWVALID | high | `clk` | - |
| `awready` | output | 1 | AWREADY: 1 when the write path and the snoop path are both idle | high | comb | 1 |
| `awaddr` | input | `AW` | AWADDR, start byte address | - | `clk` | - |
| `awlen` | input | 8 | AWLEN: beats - 1 | - | `clk` | - |
| `awsize` | input | 3 | AWSIZE: above 2 is an error; the address steps 4 per beat | - | `clk` | - |
| `awburst` | input | 2 | AWBURST: only INCR (01) is legal | - | `clk` | - |
| `awsnoop` | input | 3 | AWSNOOP: accepted and ignored | - | `clk` | - |
| `awdomain` | input | 2 | AWDOMAIN: accepted and ignored | - | `clk` | - |
| `awbar` | input | 2 | AWBAR: accepted and ignored | - | `clk` | - |
| `wvalid` | input | 1 | WVALID | high | `clk` | - |
| `wready` | output | 1 | WREADY: 1 from the AW handshake until the last W beat | high | comb | 0 |
| `wdata` | input | `DW` | WDATA | - | `clk` | - |
| `wstrb` | input | `DW/8` | WSTRB | high | `clk` | - |
| `wlast` | input | 1 | WLAST: ends the burst early when 1 | high | `clk` | - |
| `bvalid` | output | 1 | BVALID | high | comb | 0 |
| `bready` | input | 1 | BREADY | high | `clk` | - |
| `bresp` | output | 2 | BRESP: 00 OKAY, 10 SLVERR | - | comb | 00 |
| `arvalid` | input | 1 | ARVALID | high | `clk` | - |
| `arready` | output | 1 | ARREADY: 1 when the read path is idle (snoops do not block reads) | high | comb | 1 |
| `araddr` | input | `AW` | ARADDR | - | `clk` | - |
| `arlen` | input | 8 | ARLEN | - | `clk` | - |
| `arsize` | input | 3 | ARSIZE: above 2 is an error | - | `clk` | - |
| `arburst` | input | 2 | ARBURST: only INCR legal | - | `clk` | - |
| `arsnoop` | input | 4 | ARSNOOP: accepted and ignored | - | `clk` | - |
| `ardomain` | input | 2 | ARDOMAIN: accepted and ignored | - | `clk` | - |
| `arbar` | input | 2 | ARBAR: accepted and ignored | - | `clk` | - |
| `rvalid` | output | 1 | RVALID | high | comb | 0 |
| `rready` | input | 1 | RREADY | high | `clk` | - |
| `rdata` | output | `DW` | RDATA: the cached word on a hit, 0 on a miss (§3.3); combinational | - | comb | 0 |
| `rresp` | output | 2 | RRESP: 00 OKAY, 10 SLVERR (header error, every beat) | - | comb | 00 |
| `rlast` | output | 1 | RLAST on beat `arlen` | high | comb | 0 |
| `acvalid` | input | 1 | ACVALID: snoop request | high | `clk` | - |
| `acready` | output | 1 | ACREADY: 1 when the snoop path and the write path are both idle | high | comb | 1 |
| `acaddr` | input | `AW` | ACADDR: snooped address | - | `clk` | - |
| `acsnoop` | input | 4 | ACSNOOP: 0001 ReadShared, 0010 ReadClean, 1001 CleanInvalid, 1101 MakeInvalid; others answered with an empty response | - | `clk` | - |
| `crvalid` | output | 1 | CRVALID: snoop response | high | comb | 0 |
| `crready` | input | 1 | CRREADY | high | `clk` | - |
| `crresp` | output | 5 | CRRESP {WasUnique, IsShared, PassDirty, Error = 0, DataTransfer} (§3.4) | - | comb | 0 |
| `cdvalid` | output | 1 | CDVALID: snoop data (one beat), only after a response with DataTransfer | high | comb | 0 |
| `cdready` | input | 1 | CDREADY | high | `clk` | - |
| `cddata` | output | `DW` | CDDATA: the snooped line word | - | comb | - |
| `cdlast` | output | 1 | CDLAST = `cdvalid` (single-beat transfer) | high | comb | 0 |
| `irq` | output | 1 | one-clock pulse after the last beat of a write or read with a header error | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name (FSM coverage); a re-implementation must have them with this encoding.

| Signal | Width | Meaning |
|---|---|---|
| `wstate` | 2 | write path: 0 W_IDLE, 1 W_DATA, 2 W_RESP |
| `rstate` | 1 | read path: 0 R_IDLE, 1 R_DATA |
| `sstate` | 2 | snoop path: 0 S_IDLE (`acready` when writes are idle), 1 S_CR (`crvalid`), 2 S_CD (`cdvalid`) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/ACE.md`](../ip/ACE.md) (source: `scripts/apb/specs/ACE.json`); do not edit by hand.

`ACE_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `awvalid`, `awready`, `awaddr`, `awlen`, `awsize`, `awburst`, `awsnoop`, `awdomain`, `awbar`, `wvalid`, `wready`, `wdata`, `wstrb`, `wlast`, `bvalid`, `bready`, `bresp`, `arvalid`, `arready`, `araddr`, `arlen`, `arsize`, `arburst`, `arsnoop`, `ardomain`, `arbar`, `rvalid`, `rready`, `rdata`, `rresp`, `rlast`, `acvalid`, `acready`, `acaddr`, `acsnoop`, `crvalid`, `crready`, `crresp`, `cdvalid`, `cdready`, `cddata`, `cdlast`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4143 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a read or write burst ended with SLVERR: a burst type other than INCR, a size above 4 bytes, or a start at or above 64 KB |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41430200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Cache organisation

64 lines, direct mapped, one `DW` word per line: index = `addr[7:2]`, tag = `addr[AW-1:8]`, plus
a valid and a dirty bit per line. A line hits for an address when it is valid and its tag equals
the address tag. Reset clears every valid and dirty bit; tags and data keep their values.

### 3.2 Write path

| State | Outputs | Leaves at the edge with | To |
|---|---|---|---|
| W_IDLE | `awready` = 1 if the snoop path is idle | AW handshake: address, length captured; error = burst != INCR, or size > 2, or `awaddr[AW-1:16]` != 0 | W_DATA |
| W_DATA | `wready` = 1 | W handshake of the last beat (`wlast` = 1 or beat count = `awlen`, whichever first) | W_RESP |
| W_RESP | `bvalid`, `bresp` (SLVERR iff error) | B handshake | W_IDLE |

Each W beat without a header error allocates line `addr[7:2]`: valid = 1, dirty = 1, tag =
`addr[AW-1:8]`, and the bytes with `wstrb[k]` = 1 replace those of the line word (the other bytes
keep the old line word, whatever address it held). A line holding another (possibly dirty)
address is replaced without write-back. The address adds 4 per beat. With a header error nothing
is written; `irq` pulses in the clock after the last W beat.

### 3.3 Read path

| State | Outputs | Leaves at the edge with | To |
|---|---|---|---|
| R_IDLE | `arready` = 1 | AR handshake: address, length, error flag (same rule as AW) | R_DATA |
| R_DATA | `rvalid`, `rdata`, `rresp`, `rlast` | R handshake of beat `arlen` | R_IDLE |

`rdata` = the line word when the beat address hits, else 0 (read combinationally); `rresp` =
SLVERR on every beat of a burst with a header error (data still from the cache), OKAY otherwise.
A read does not change the cache. Reads run independently of writes and snoops. `irq` pulses in
the clock after the last R beat of an errored burst.

### 3.4 Snoop path

| State | Outputs | Leaves at the edge with | To |
|---|---|---|---|
| S_IDLE | `acready` = 1 if the write path is idle | AC handshake: address, response computed, cache updated (table below) | S_CR |
| S_CR | `crvalid`, `crresp` | CR handshake | S_CD if DataTransfer, else S_IDLE |
| S_CD | `cdvalid`, `cdlast`, `cddata` = line word of `acaddr[7:2]` | CD handshake | S_IDLE |

At the AC handshake (line = `acaddr[7:2]`, hit as in §3.1):

| ACSNOOP | Hit, dirty | Hit, clean | Miss |
|---|---|---|---|
| ReadShared / ReadClean | CRRESP 11101 (WasUnique, IsShared, PassDirty, DataTransfer); line stays valid, dirty cleared | 01001 (IsShared, DataTransfer); line unchanged | 00000 |
| CleanInvalid | 10101 (WasUnique, PassDirty, DataTransfer); line invalidated | 00000; line invalidated | 00000 |
| MakeInvalid | 00000; line invalidated | 00000; line invalidated | 00000; the indexed line is invalidated anyway (no tag check) |
| other | 00000 | 00000 | 00000 |

CRRESP Error is always 0 and WasUnique always equals PassDirty (a dirty line is UniqueDirty in this
model). Snoops and writes exclude each other: AW is not taken while a snoop is in progress, and AC
is not taken while a write burst is in progress (W_DATA or W_RESP).

### 3.5 Reset

While `rst_n` is low: all paths idle (`awready`, `arready`, `acready` 1; `wready`, `bvalid`,
`rvalid`, `crvalid`, `cdvalid` 0), `irq` 0, every line invalid and clean.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | 32 | data width; one word per cache line, address step 4 |
| `AW` | 32 | 17 to 32 | address width; bits `AW-1:16` must be 0 for a legal burst, `AW-1:8` is the tag |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| burst != INCR, size > 2, or start address >= 0x10000 | SLVERR for the whole burst, nothing written, `irq` pulse at the last beat |
| read miss | `rdata` 0, OKAY (no backing memory) |
| write to a line holding another address | replaced without write-back; unstrobed bytes keep the old word |
| MakeInvalid to an index holding another address | that line is invalidated too |
| snoop while a write burst runs | `acready` 0 until the write's B handshake |
| write while a snoop runs | `awready` 0 until the snoop's last handshake |
| snoop or write changing a line a stalled R beat returns | `rdata` is read live, so it changes under the stall (an AXI stability violation); the TB never overlaps them |
| early `wlast` / missing `wlast` | the burst ends at the first of the two; no error |
| errored write and read ending on consecutive edges | `irq` high for two clocks |

## 6. TB check map

Messages are printed by `tb/ACE_tb.sv` as `ERROR: <message>`; its immediate checks print
`SVA_FAIL: <name>`. Assertions `a_*` are in the bound checker `tb/cov/ACE_sva.sv`, which keeps its
own copy of the cache and of each path. The TB checks reset, burst writes and reads, snoop dirty
hits with CD data, snoop misses, every snoop type on dirty, clean and empty lines, MakeInvalid,
SLVERR with `irq`, back-to-back snoops, snoops after writes and after reset, reset mid
transaction, and (Verilator) random writes, reads and snoops.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "CRV ACE write" | random write BRESP | §3.2 |
| "CRV ACE read" | random read data / RRESP / RLAST against the cache model | §3.3 |
| "CRV ACE snoop" | random snoop CRRESP | §3.4 |
| "CRV ACE snoop CD" | random snoop CD data | §3.4 |
| "ACE write" | directed write BRESP | §3.2 |
| "ACE read" | directed read data / RRESP / RLAST | §3.3 |
| "ACE snoop" | directed snoop completes | §3.4 |
| "ACE reset state bvalid" | out of reset: `bvalid`, `rvalid`, `crvalid`, `cdvalid`, `irq` 0 | §3.5 |
| "ACE snoop dirty hit crresp" | dirty hit ReadShared: DataTransfer, PassDirty, IsShared, WasUnique | §3.4 |
| "ACE snoop CD data" | CD carries the written word | §3.4 |
| "ACE snoop miss crresp" | miss: 00000 | §3.4 |
| "ACE MakeInvalid crresp" | MakeInvalid: 00000 | §3.4 |
| "ACE post-MakeInvalid snoop crresp" | the line misses after MakeInvalid | §3.4 |
| "ACE irq not asserted on SLVERR protocol error" | errored burst pulses `irq` | §3.2, §3.3 |
| "ACE back-to-back snoop resp" | consecutive snoops answered | §3.4 |
| "ACE dirty ReadShared crresp" | dirty ReadShared response | §3.4 |
| "ACE clean ReadShared crresp" | clean ReadShared: IsShared + DataTransfer | §3.4 |
| "ACE clean ReadClean crresp" | clean ReadClean: IsShared + DataTransfer | §3.4 |
| "ACE clean CleanInvalid crresp" | clean CleanInvalid: 00000 | §3.4 |
| "ACE snoop-after-write crresp" | a written line snoops dirty | §3.2, §3.4 |
| "ACE outputs not quiescent in reset" | in reset the valid outputs are 0 | §3.5 |
| "ACE snoop after reset crresp" | after reset every line misses | §3.5 |
| "ACE CleanInvalid dirty hit resp" | dirty CleanInvalid: 10101 and CD data | §3.4 |
| "ACE ReadClean on empty line resp" | empty line: 00000 | §3.4 |
| "ACE MakeInvalid on empty line resp" | empty line: 00000 | §3.4 |
| "ACE CleanInvalid on empty line resp" | empty line: 00000 | §3.4 |
| "A1 reset: response channels low" | in reset no response valid | §3.5 |
| "A2 bvalid/bresp held until bready" | B stable | §3.2 |
| "A3 rvalid/rdata/rresp held until rready" | R stable | §3.3 |
| "A4 crvalid/crresp held until crready" | CR stable | §3.4 |
| "A5 cdvalid/cddata held until cdready" | CD stable | §3.4 |
| "A6 last implies valid" | `rlast` / `cdlast` only with their valid | §3.3, §3.4 |
| "A7 b/rresp legal" | only OKAY / SLVERR | §3.2, §3.3 |
| "A8 crresp Error=0, WasUnique=PassDirty" | CRRESP shape | §3.4 |
| "A9 write phases mutually exclusive" | at most one of `awready`, `wready`, `bvalid` (`awready` may be 0 in W_IDLE during a snoop) | §3.2 |
| "A10 irq single-cycle pulse" | `irq` pulses (no two in a row in the TB's traffic) | §5 |
| a_reset_quiet | in reset: no `bvalid`, `rvalid`, `crvalid`, `cdvalid`, `irq` | §3.5 |
| a_b_stable | B payload held | §3.2 |
| a_r_stable | R payload held | §3.3 |
| a_cr_stable | CR payload held | §3.4 |
| a_cd_stable | CD payload held | §3.4 |
| a_ac_blocked_by_write | `acready` only with writes and snoops idle | §3.4 |
| a_aw_blocked_by_snoop | `awready` only with snoops and writes idle | §3.2 |
| a_bresp_model | `bresp` from the header check | §3.2 |
| a_rresp_model | `rresp` / `rlast` as the model | §3.3 |
| a_rdata_model | `rdata` = model line on a hit, 0 on a miss | §3.3 |
| a_crresp_model | `crresp` as the snoop table | §3.4 |
| a_cd_only_on_transfer | `cdvalid` only after DataTransfer, with `cdlast` | §3.4 |
| a_cddata_model | `cddata` = model line word | §3.4 |
| a_irq_on_werr | errored write's last beat pulses `irq` | §3.2 |
| a_irq_on_rerr | errored read's last beat pulses `irq` | §3.3 |
| a_irq_pulse | `irq` behaves as a pulse | §5 |
