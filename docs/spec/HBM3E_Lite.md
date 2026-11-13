<!-- SPDX-License-Identifier: Apache-2.0 -->
# HBM3E_Lite: design specification

An HBM3E-flavoured fork of [DDR4_Lite](DDR4_Lite.md): the same host contract, engine and
timing, with 8 pseudo-channels x 4 banks = 32 bank entries, the pseudo-channel carried on
`addr[13:11]`, and per-entry refresh in rotation instead of all-bank refresh. Everything not
stated here is as in DDR4_Lite; this page is complete on its own. Core `HBM3E_Lite_top` (`rtl/HBM3E_Lite_top.sv`), testbench `tb/HBM3E_Lite_tb.sv` (shared body
`tb/lite_tb_common.svh`), checker `tb/cov/HBM3E_Lite_sva.sv` (shared line-controller model
`tb/cov/lite_chk.svh`).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. "Clock n" is the clock period that starts at rising edge n; a
value "in clock n" is the value registered at edge n and held until edge n+1. Pin commands are
one-clock pulses: every pin output is registered, and the command bus is deselected (`cs_n`
high) in every clock that carries no command.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock; also drives `ck_t` / `ck_c` | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset; also drives `cke` | low | async | - |
| `hvalid` | input | 1 | host command valid; with `hready` high a command (or a write data beat) is taken at the rising edge (§3.1) | high | `clk` | - |
| `hready` | output | 1 | core can take a command or a write data beat: high exactly when no READ / WRITE / REFRESH is in flight, or while a WRITE is collecting its 8 data beats (combinational from the front-end state) | high | `clk` | 1 |
| `hcmd` | input | 3 | host command: 0 NOP, 1 READ line, 2 WRITE line, 3 MRW, 4 MRR, 5 REFRESH; 6 and 7 are illegal: rejected (see §3.1); ignored on a write data beat | - | `clk` | - |
| `haddr` | input | 32 | host byte address for READ / WRITE (map in §3.2; bits [31:21] must be 0); MR index in bits 2:0 for MRW / MRR; ignored for NOP / REFRESH and on a write data beat | - | `clk` | - |
| `hwdata` | input | 16 | MRW value in bits 7:0; on each of the 8 data beats of a WRITE, one 16-bit word of the line (beat 0 = line bits 15:0) | - | `clk` | - |
| `hrdata` | output | 16 | read data: word k of the line in clock k of the 8 clocks that end with the READ `hdone`; `{8'h00, MR}` in the `hdone` clock of an MRR; holds its last value otherwise | - | `clk` | 0 |
| `rdline` | output | 128 | the line of the last READ (word k in bits 16k+15:16k), updated in the clock of the last read beat on `dq` and held until the next READ burst ends | - | `clk` | 0 |
| `hdone` | output | 1 | one-clock pulse when a host command completes (§3.1) | high | `clk` | 0 |
| `irq` | output | 1 | sticky error: set two clocks after a rejected command or one clock after a refresh overrun; cleared only by reset (§5) | high | `clk` | 0 |
| `pc_act` | output | 3 | pseudo-channel of the entry the engine works on (`entry[4:2]`); equals the pseudo-channel of every ACT / RD / WR / PRE / per-entry REF in its clock (debug) | - | `clk` | 0 |
| `ck_t` | output | 1 | DRAM clock = `clk` | - | comb | - |
| `ck_c` | output | 1 | DRAM clock complement = `~clk` | - | comb | - |
| `cke` | output | 1 | clock enable = `rst_n` (no power-down) | high | comb | 0 |
| `cs_n` | output | 1 | chip select: low in a command clock (§3.3) | low | `clk` | 1 |
| `act_n` | output | 1 | low with `cs_n` low = ACT | low | `clk` | 1 |
| `ras_n` | output | 1 | command bit (§3.3) | low | `clk` | 1 |
| `cas_n` | output | 1 | command bit (§3.3) | low | `clk` | 1 |
| `we_n` | output | 1 | command bit (§3.3) | low | `clk` | 1 |
| `ba` | output | 2 | bank (within the pseudo-channel) of ACT / RD / WR / PRE / per-entry REF; 0 for PREA and the all-entry REF; holds its value between commands | - | `clk` | 0 |
| `addr` | output | 14 | ### 3.2 Address map and storage

| `haddr` bits | Field |
|---|---|
| 31:21 | must be 0 |
| 20:12 | row (512) |
| 11:9 | pseudo-channel (8) |
| 8:7 | bank (4) |
| 6:4 | line within the row segment (8) |
| 3:0 | byte within the line, ignored |

The entry number is `haddr[11:7]` = `{pc, bank}` (0 to 31). One array line (128 bits) per
{entry, row, line}. On the pins the entry of a command is `{addr[13:11], ba}`.
 | - | `clk` | 0 |
| `dq` | inout | 16 | data: driven by the core for each beat of a read or write burst (SDR, one 16-bit beat per clock), Hi-Z otherwise | - | `clk` | Hi-Z |
| `dqs` | inout | 2 | strobe `{~s, s}`: driven with the burst, `s` toggles every beat; Hi-Z otherwise | - | `clk` | Hi-Z |
| `trace_valid` | output | 1 | high in the clock of every ACT, RD, WR, single-bank PRE and REF on the pins (§3.8) | high | `clk` | 0 |
| `trace_cmd` | output | 4 | 0 ACT, 1 RD, 2 WR, 3 PRE, 5 per-entry REF, 6 all-entry REF | - | `clk` | 0 |
| `trace_addr` | output | 32 | §3.8: row of the operation (ACT / RD / WR), row closed (PRE), entry (per-entry REF), 0 (all-entry REF) | - | `clk` | 0 |

### Internal signals used by the verification

The checker is bound to the core with `.*`, so these internal nets must exist under these names.

| Signal | Width | Meaning |
|---|---|---|
| `dq_oe` | 1 | `dq` output enable: high exactly in the clocks that carry a burst beat (§3.7) |
| `dqs_oe` | 1 | `dqs` output enable: the same clocks as `dq_oe` |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/HBM3E_Lite.md`](../ip/HBM3E_Lite.md) (source: `scripts/apb/specs/HBM3E_Lite.json`); do not edit by hand.

`HBM3E_Lite_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `pc_act`, `ck_t`, `ck_c`, `cke`, `cs_n`, `act_n`, `ras_n`, `cas_n`, `we_n`, `ba`, `addr`, `dq`, `dqs`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D230200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD0 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command, or one of the 8 data beats that follow a WRITE |
| 0x018 | CMD1 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command, or one of the 8 data beats that follow a WRITE |
| 0x01C | CMD2 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command, or one of the 8 data beats that follow a WRITE |
| 0x020 | RDATA | RO | core | MRR result |
| 0x024 | RLINE0 | RO | core | Line of the last READ (RLINE0 = bits 31:0) |
| 0x028 | RLINE1 | RO | core | Line of the last READ (RLINE0 = bits 31:0) |
| 0x02C | RLINE2 | RO | core | Line of the last READ (RLINE0 = bits 31:0) |
| 0x030 | RLINE3 | RO | core | Line of the last READ (RLINE0 = bits 31:0) |
| 0x034 | STATUS | RO | core | Core state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6D23 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD0 | 2:0 | `hcmd` | RW | 0x0 | command (see the notes); ignored on a data beat |
| CMD1 | 31:0 | `haddr` | RW | 0x0 | host address (see the notes); ignored on a data beat |
| CMD2 | 15:0 | `hwdata` | RW | 0x0 | MRW value (bits 7:0), or the data beat of a WRITE (beat 0 = line bits 15:0) |
| RDATA | 15:0 | `hrdata` | RO | core | {8'h0, MR value} after an MRR (also carries read beats while a READ drains) |
| RLINE0 | 31:0 | `rdline[31:0]` | RO | core | the 128-bit line of the last READ, held until the next READ completes |
| RLINE1 | 31:0 | `rdline[63:32]` | RO | core | the 128-bit line of the last READ, held until the next READ completes |
| RLINE2 | 31:0 | `rdline[95:64]` | RO | core | the 128-bit line of the last READ, held until the next READ completes |
| RLINE3 | 31:0 | `rdline[127:96]` | RO | core | the 128-bit line of the last READ, held until the next READ completes |
| STATUS | 2:0 | `pc_act` | RO | core | pseudo-channel of the entry the engine works on; same as the pc_act pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a command finished (READ: RLINE holds the line; MRR: RDATA holds the value) |
| 1 | ERR | a command was rejected (out-of-range address, illegal code) or a refresh overran; the core holds this until reset, so the bit cannot be cleared before then |
| 2 | CMD_DONE | CMD beat accepted by the core |
| 3 | CMD_OVF | write to CMD while full (dropped) |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CMD_FULL | CMD holds a beat the core has not taken |

### Streams

* **CMD** feeds `hcmd`, `haddr`, `hwdata`/`hvalid`. Writing CMD2 commits the beat: FLAGS.CMD_FULL is set and `hvalid` stays high until the core's `hready`; then CMD_DONE is set. A write while full is dropped and sets CMD_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x6D230200.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
4. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD0 (0x014) then CMD1 (0x018) then CMD2 (0x01C). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
5. Read RDATA (0x020) for the core's live `hrdata`; it needs no clearing.
6. Read RLINE0 (0x024), RLINE1 (0x028), RLINE2 (0x02C), RLINE3 (0x030) for the core's live `rdline[31:0]`, `rdline[63:32]`, `rdline[95:64]`, `rdline[127:96]`; it needs no clearing.
7. Read STATUS (0x034) for the core's live `pc_act`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Host interface

One host command is handled at a time. A command is taken at a rising edge with `hvalid` and
`hready` both high; `hcmd`, `haddr` and `hwdata` are sampled at that edge.

| `hcmd` | Command | Effect | Completion |
|---|---|---|---|
| 0 | NOP | nothing | `hdone` in the next clock |
| 1 | READ | reads the line at `haddr` (§3.4) | `hdone` after the 8 read words were put on `hrdata` |
| 2 | WRITE | takes 8 data beats, then writes the line at `haddr` | `hdone` after the write burst |
| 3 | MRW | `MR[haddr[2:0]] <= hwdata[7:0]`; every bit is stored as written (no DLL, so MR0 bit 7 is an ordinary bit) | `hdone` in the next clock |
| 4 | MRR | `hrdata <= {8'h00, MR[haddr[2:0]]}` | `hdone` in the next clock, with the value |
| 5 | REFRESH | all-bank refresh (§3.6) | `hdone` tRFC after the REF |
| 6, 7 | illegal | rejected, sets `irq` | `hdone` in the next clock |

* `hready` is high when the front end is idle, and stays high while a WRITE collects its data:
  after the WRITE command, each later rising edge with `hvalid` high takes one data beat from
  `hwdata` (beat 0 first); `hcmd` and `haddr` are ignored on data beats, and clocks with
  `hvalid` low are gaps that take nothing. After the 8th beat `hready` falls.
* From a READ, REFRESH (or the 8th WRITE beat) until its `hdone`, `hready` is low and `hvalid` is
  ignored. In the clock of `hdone` the front end is idle again, so the next command can be
  presented and is taken at the edge that ends the `hdone` clock (back to back).
* READ / WRITE with `haddr[31:21]` not 0 are rejected: no pin activity, no data beats are taken,
  `hdone` in the next clock, and `irq` set (§5).
* READ data: the 8 words of the line are on `hrdata` in the 8 consecutive clocks that end with the
  `hdone` clock (word 0 first). The words come from the read burst, so they are what the array
  held when the RD was issued.
* MRW, MRR, NOP and rejected commands never wait for the engine: `hdone` is in the clock after the
  command was taken.

### 3.2 Address map and storage

| `haddr` bits | Field |
|---|---|
| 31:21 | must be 0 |
| 20:12 | row (512) |
| 11:9 | pseudo-channel (8) |
| 8:7 | bank (4) |
| 6:4 | line within the row segment (8) |
| 3:0 | byte within the line, ignored |

The entry number is `haddr[11:7]` = `{pc, bank}` (0 to 31). One array line (128 bits) per
{entry, row, line}. On the pins the entry of a command is `{addr[13:11], ba}`.

### 3.3 Pin commands

A command is one clock with `cs_n` low. Decoding (`cs_n` = 0):

| `act_n` | `ras_n` `cas_n` `we_n` | `addr` | `ba` | Command |
|---|---|---|---|---|
| 0 | 1 1 1 | `{pc, 2'b00, row}` | bank | ACT |
| 1 | 1 0 1 | `{pc, 4'b0000, line, 4'h0}` (A10 = 0; A13..A11 carry the pseudo-channel, so there is no BC_n bit) | bank | RD |
| 1 | 1 0 0 | same as RD | bank | WR |
| 1 | 0 1 0 | `{pc, 11'h000}` (A10 = 0) | bank | PRE (one bank) |
| 1 | 0 1 0 | `14'h0400` (A10 = 1) | 0 | PREA (all banks) |
| 1 | 0 0 1 | `{pc, 11'h000}` (A10 = 0) | bank | REF one entry (per-entry refresh) |
| 1 | 0 0 1 | `14'h0400` (A10 = 1) | 0 | REF all entries (host REFRESH) |

No other combination is ever driven. Between commands `cs_n`, `act_n`, `ras_n`, `cas_n`,
`we_n` are 1 and `ba` / `addr` keep their last value.

### 3.4 Command sequences (open-page policy)

Each bank entry keeps its row open after an access. A READ / WRITE to bank b and row r:

| Bank b state | Pin sequence |
|---|---|
| row r open (hit) | RD / WR only |
| closed | ACT r, then RD / WR |
| another row open (conflict) | PRE b, ACT r, then RD / WR |

Every command is issued at the earliest clock its timing (§3.5) allows, and exactly one RD or WR
is issued per host READ / WRITE. On a hit the RD / WR is on the pins 3 clocks after the command
(or the 8th write beat) was taken, later only if tWTR still runs or a refresh is due. The engine is a single in-order
state machine, so nothing of the next host command reaches the pins before the current one
completes.

### 3.5 Timing parameters

All in `clk` clocks, counted between the clocks of the two pin commands (a write-recovery time
from the clock of the last write beat on `dq`). The checker enforces each as a minimum.

| Parameter | Rule |
|---|---|
| `T_RCD` | ACT to RD / WR of the same bank entry |
| `T_RP` | PRE to ACT of the same bank entry; PRE / PREA to REF (of that entry for a per-entry REF, of every entry for the all-entry REF) |
| `T_RC` | ACT to ACT of the same bank entry |
| `T_RAS` | ACT to PRE (or the PREA) of the same bank entry |
| `T_RRD` | ACT to ACT of any two banks |
| `T_WR` | last write beat on `dq` to PRE / PREA of that bank |
| `T_WTR` | last write beat on `dq` (any bank) to the next RD |
| `T_RFC` | all-entry REF to any next pin command |
| `T_RFC_PB` | per-entry REF to the next ACT or REF of that entry (the engine in fact issues nothing for `T_RFC_PB` clocks) |
| CL | RD to the first read beat on `dq`: exactly `5 + MR0[3:0]` clocks |
| CWL | WR to the first write beat on `dq`: exactly `5 + MR1[3:0]` clocks |

CL and CWL are read from the MR file when the RD / WR is issued; an MRW takes effect for the
next RD / WR. The MR file issues no MRS on the pins: the device's own mode registers are assumed
to be set to match outside this core.

### 3.6 Refresh

* Per-entry refresh: a tREFI counter loads `T_REFI` at reset and counts down every clock; when it
  is 0 it reloads and the next entry of a rotation 0, 1, ..., 31, 0, ... falls due. A full
  rotation therefore takes 32 x (`T_REFI` + 1) clocks.
* Due entrys are served only when the engine is idle (between host operations). When the engine is
  idle it serves, in this order: a host REFRESH, the lowest-numbered due entry, then a
  waiting READ / WRITE. So a due refresh delays a READ / WRITE that was taken but has not reached
  the pins.
* Per-entry service of entry e: wait until e is past tRAS and tWR; if e is open, PRE e, then tRP;
  REF with A10 = 0 addressed to e (§3.3); then nothing on the pins for `T_RFC_PB` clocks. The
  other entrys keep their open rows.
* Host REFRESH (all entrys): wait until every entry is past tRAS and tWR; if any entry is open,
  PREA, then tRP; REF with A10 = 1; nothing for `T_RFC`; then `hdone`. It does not serve a
  entry that is due: that entry still gets its own per-entry REF.
* Overrun: a entry falling due while its previous refresh is still unserved (and not served in
  that clock) sets `irq` one clock later. It only happens when `T_REFI` is shorter than one engine
  operation divided by 32, so it is a misconfiguration alarm.
* The checker requires every due entry to get its REF within REF_LAT clocks of falling due (§6).

### 3.7 Data

* Bursts are SDR BL8: 8 beats on 8 consecutive clocks, one 16-bit word per beat, word 0 (line
  bits 15:0) first. A read burst starts exactly CL clocks after the RD, a write burst exactly CWL
  clocks after the WR.
* `dq` and `dqs` are driven exactly in the burst clocks (`dq_oe` / `dqs_oe` high) and are Hi-Z in
  every other clock. `dqs` is `{~s, s}` and `s` toggles every beat.
* WRITE: the burst carries the 8 host beats in the order they were taken. The array line is
  written after the last beat, so a READ issued after the WRITE completes returns it.
* READ: the burst carries the array line. When the last beat is on `dq`, `rdline` takes the line
  in the same clock; the front end then puts its words on `hrdata` (§3.1).
* The array is 32 entries x 512 rows x 8 lines x 128 bits. It is zeroed once at time 0 in simulation and
  keeps its contents through `rst_n` (a DRAM does too).

### 3.8 Trace port

`trace_valid` is high in the same clock as each ACT, RD, WR, single-entry PRE and REF on the pins
(not with PREA). `trace_cmd`: 0 ACT, 1 RD, 2 WR, 3 PRE, 5 per-entry REF, 6 all-entry REF.
`trace_addr`: `{11'h0, row, 12'h0}` with the row of the host operation for ACT / RD / WR; for a PRE
the row that PRE closes (the old row on a conflict, the open row for a refresh PRE); the entry
number for a per-entry REF; 0 for an all-entry REF. In other clocks `trace_valid` is 0 and
`trace_cmd` / `trace_addr` are don't-care.

### 3.9 Mode registers

MR0..MR7, 8 bits each. Reset: MR0 = `CL - 5`, MR1 = `CWL - 5`, the others 0. MR0[3:0] sets CL,
MR1[3:0] sets CWL (5 to 20 clocks); every other bit is stored as written and has no effect (HBM has
no DLL, so there is no self-clearing DLL-reset bit).

### 3.10 Reset

While `rst_n` is low: `hready` 1, `hdone` 0, `irq` 0, `cs_n` / `act_n` / `ras_n` / `cas_n` /
`we_n` 1, `ba` / `addr` 0, `dq` / `dqs` Hi-Z, `trace_valid` 0, every bank closed, every timer 0,
tREFI reloaded, MR file at its reset values, the refresh rotation back at entry 0, `pc_act` 0. A READ in flight is dropped (no `hdone`). The
array is not cleared.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `T_RCD` | 6 | 1 to 31 | §3.5 |
| `T_RP` | 6 | 1 or more | §3.5 |
| `T_RC` | 24 | 1 or more | §3.5 |
| `T_RAS` | 16 | 1 or more | §3.5 |
| `T_RRD` | 3 | 1 or more | §3.5 |
| `T_WR` | 8 | 1 or more | §3.5 |
| `T_WTR` | 4 | 1 or more | §3.5 |
| `T_RFC` | 40 | 1 or more | §3.5 |
| `T_RFC_PB` | 20 | 1 or more | per-entry refresh time, §3.5 |
| `T_REFI` | 1560 | 1 or more; below one engine operation / 32 it overruns (§5) | per-entry refresh interval (one entry falls due every `T_REFI` + 1 clocks), §3.6 |
| `CL` | 11 | 5 to 20 | reset value of the read latency (MR0[3:0] = `CL - 5`) |
| `CWL` | 8 | 5 to 20 | reset value of the write latency (MR1[3:0] = `CWL - 5`) |

Each timer is as wide as its own parameter. The TB runs with `T_RC` 40, `T_WTR` 8 and `T_REFI` 150 (a full rotation every 4832 clocks); a second instance with `T_REFI` 1 checks the overrun; the performance run (`MEM_PERF`) uses the defaults.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| READ / WRITE with `haddr[31:21]` not 0 | rejected: `hdone` next clock, no pins, a WRITE takes no data beats, `irq` set two clocks after the command was taken |
| `hcmd` 6 or 7 | rejected the same way |
| NOP | `hdone` next clock, no `irq` |
| refresh overrun | `irq` set (sticky); the late refresh is still served |
| `irq` | sticky until reset; nothing else clears it |
| command while busy | not taken (`hready` low); it stays on the bus until taken |
| write beats with gaps | allowed: only clocks with `hvalid` high take a beat |
| due refresh while a READ / WRITE waits | the refresh goes first (§3.6) |
| host REFRESH with banks open | PREA first; with all banks closed REF goes out directly |
| RD after a WR | waits tWTR from the last write beat, also on a page hit |
| PRE after a WR | waits tWR from the last write beat |
| MRW to MR0 / MR1 | CL / CWL change for the next RD / WR; no pin command |
| reset with a READ in flight | dropped; open rows are forgotten (the next access opens the bank again) |
| a due entry that the operation in flight also needs | the operation finishes first; the refresh PRE then closes the row the operation opened |
| all-entry REFRESH while entries are due | the due entries are still refreshed one by one afterwards |

## 6. TB check map

Messages are printed by `tb/HBM3E_Lite_tb.sv` through the shared body `tb/lite_tb_common.svh` as
`ERROR: <message>`. Assertions are in the bound checker `tb/cov/HBM3E_Lite_sva.sv` with the shared
model `tb/cov/lite_chk.svh`, which rebuilds the bank, timing, refresh and array state from the
pins at every clock. The TB rejects each error class after its own reset, writes and reads every entry (closed, hit,
conflict, with and without beat gaps), programs CL / CWL both ways, writes every MR bit both
ways, sends host refreshes with entries open and closed, rejected commands, a command while
busy, back-to-back commands, tWTR / tWR / tRC corner cases in all 32 entries, the far rows, a
full refresh rotation with every entry open, zero / one / alternating lines, 400 random
operations with idle gaps, and a reset with a READ in flight. A second instance with `T_REFI` 1
checks the overrun `irq`.

The checker's bounds (TB timing): REF_LAT = 144 clocks, BUSY_MAX = 328 clocks (REF_LAT =
`2 * (T_RAS + T_RP + T_RCD + 20 + 8 + T_WR) + 16`, BUSY_MAX = REF_LAT + `T_RFC` + the same term).

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| irq set before rejection | no `irq` before the first rejected command after reset | §5 |
| irq not set by rejection | each rejection class (high address bit, lowest out-of-range bit, and an illegal code where one exists) sets `irq` on its own | §5 |
| irq set by a NOP | a NOP does not set `irq` | §5 |
| no hdone | every command completes within 2000 clocks | §3.1 |
| RD | the 8 `hrdata` words of a READ equal the last data written to that line (or 0) | §3.1, §3.7 |
| MRR | MRR returns the MR value (MR0 bit 7 reads 0) | §3.9 |
| irq set with no rejected command since reset | no `irq` from refresh after reset, also over a full refresh rotation of idle time | §3.6 |
| overrun irq set in reset | the overrun instance (`T_REFI` 1, no traffic) has `irq` low right after reset | §3.6 |
| no irq on a refresh overrun | the overrun instance sets `irq` within 1280 clocks | §3.6, §5 |
| a_cmd_belongs_to_op_or_refresh | every ACT / PRE / RD / WR serves the host READ / WRITE in flight (its bank, PRE only on a conflict, at most one ACT and one PRE); PREA / REF only for a due or host refresh | §3.4, §3.6 |
| a_act_to_closed_bank | ACT only to a closed bank | §3.4 |
| a_rw_to_open_row | RD / WR only to the open row of the operation's bank | §3.4 |
| a_one_rw_per_op | one RD / WR per operation, not while a burst is pending | §3.4 |
| a_trcd | tRCD | §3.5 |
| a_trp | tRP before ACT and REF | §3.5 |
| a_trc | tRC | §3.5 |
| a_tras | tRAS before PRE / PREA | §3.5 |
| a_trrd | tRRD | §3.5 |
| a_twr | tWR from the last write beat to PRE / PREA | §3.5 |
| a_twtr | tWTR from the last write beat to RD | §3.5 |
| a_trfc | no pin command within tRFC of an all-entry REF; no ACT / REF to an entry within tRFC_PB of its per-entry REF | §3.5 |
| a_ref_all_closed | per-entry REF only to a closed, due entry past tRP; all-entry REF only with every entry closed and past tRP | §3.6 |
| a_ref_only_when_due | REF only for a due refresh or a host REFRESH | §3.6 |
| a_refresh_not_starved | a due refresh reaches the pins within REF_LAT clocks | §3.6 |
| a_pin_address | `ba` / `addr` of every command as in §3.3 | §3.3 |
| a_write_data_on_dq | write beats on `dq` exactly CWL clocks after the WR, host words in order | §3.7 |
| a_read_data_on_dq | read beats on `dq` exactly CL clocks after the RD, the array line | §3.7 |
| a_dqs_toggles | `dqs` differential and toggling every beat | §3.7 |
| a_read_data_to_host | `hrdata` in the 8 clocks ending with `hdone` = the burst line | §3.1 |
| a_hdone_once_per_op | one `hdone` per command, after the burst / tRFC; next clock for MRW / MRR / NOP / rejected | §3.1 |
| a_mrr_value | MRR value on `hrdata` in its `hdone` clock | §3.9 |
| a_hready_idle_or_fill | `hready` exactly when idle or collecting write beats | §3.1 |
| a_op_completes | an operation completes within BUSY_MAX clocks | §3.6 |
| a_irq_on_reject | `irq` rises two clocks after the first rejected command and stays | §5 |
| a_trace_with_cmd | trace exactly with ACT / RD / WR / PRE / REF, code and address | §3.8 |
| a_no_bad_pin_cmd | no undefined command on the pins | §3.3 |
| a_dq_driven_only_in_burst | `dq_oe` / `dqs_oe` high exactly in the burst clocks | §3.7 |
| a_rdline_holds_last_read | `rdline` = line of the last READ from its last beat on | §3.7 |
| a_ck_differential | `ck_c` = `~ck_t` | §1 |
| a_cke_high | `cke` high out of reset | §1 |
| a_pc_act | `pc_act` = the pseudo-channel of every ACT / RD / WR / PRE / per-entry REF in its clock | §1 |
