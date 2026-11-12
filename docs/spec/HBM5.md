<!-- SPDX-License-Identifier: Apache-2.0 -->
# HBM5: design specification

Projected HBM5 controller, refresh-centric: fine-granularity refresh slices the refresh interval 8 ways, each slice refreshing one entry, so a refresh costs tRFC_PB = 40 clocks every 195 clocks instead of a long all-bank refresh every 1560: refresh-induced latency is short and frequent, and at most one entry is ever closed by it. 128 page entries ({channel, pc}); the refresh pointer rotates over all 128 and precharges an entry only if it is open. Open page. Core `HBM5_top` (`rtl/HBM5_top.sv`), testbench `tb/HBM5_tb.sv` (shared body
`tb/mem_tb_common.svh`), checker `tb/cov/HBM5_sva.sv` (shared model `tb/cov/mem_chk.svh`). The host
contract and the checker are shared by the whole memory-controller family; [DDR4.md](DDR4.md) is
the baseline the others are described against.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. *Clock t* is the clock period after edge t. A pin command is
*on the pins* in the clock where its registered pin values show it. Timing parameters are in
`clk` clocks (§3.5).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | controller clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `hvalid` | input | 1 | host command valid; taken at an edge where `hready` = 1 | high | `clk` | - |
| `hready` | output | 1 | the controller can take a host command | high | `clk` | 1 |
| `hcmd` | input | 3 | host command: 1 ACT, 2 RD, 3 WR, 4 PRE; other codes are no-ops | - | `clk` | - |
| `haddr` | input | 32 | host address (§3.2) | - | `clk` | - |
| `hwdata` | input | 16 | write word (WR) | - | `clk` | - |
| `hrdata` | output | 16 | read word, valid from the clock after `hdone` until the next read | - | `clk` | 0 |
| `hdone` | output | 1 | one-clock pulse per RD, CL clocks after its RD pin command | high | `clk` | 0 |
| `ck_t` | output | 1 | DRAM clock = `clk` | - | `clk` | - |
| `ck_c` | output | 1 | DRAM clock complement = not `clk` | - | `clk` | - |
| `addr` | output | 17 | pin address: ACT row in [13:0], RD / WR column in [7:0], PRE all-banks flag in [10] | - | `clk` | 0 |
| `ras_n` | output | 1 | command pin RAS# | low | `clk` | 1 |
| `cas_n` | output | 1 | command pin CAS# | low | `clk` | 1 |
| `we_n` | output | 1 | command pin WE# | low | `clk` | 1 |
| `dq` | inout | NCH x 16 | data; driven only with write data (§3.7), else high-Z | - | `clk` | high-Z |
| `dqs` | inout | 2 | data strobe; never driven (high-Z) | - | `clk` | high-Z |
| `cke` | output | 1 | clock enable = `rst_n` | high | `clk` | 0 |
| `trace_valid` | output | 1 | a pin command ACT / RD / WR comes in the next clock | high | `clk` | 0 |
| `trace_cmd` | output | 3 | 1 ACT, 2 RD, 3 WR (valid with `trace_valid`) | - | `clk` | - |
| `trace_addr` | output | 32 | host address of the command being served | - | `clk` | - |

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `ref_cnt` | 14 | refresh down-counter: clocks until the next refresh is due; loaded with TREFI at reset and when a refresh starts, decremented every clock, `hready` = 0 while it is 0. The TB waits for exact values of it to make a refresh fall due during a command |
| `ref_bank` | 7 | entry the next per-entry refresh targets (0 to 127, entry numbering of §3.2); the TB opens that entry just before a refresh falls due, so the refresh PRE must wait out its tRAS |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/HBM5.md`](../ip/HBM5.md) (source: `scripts/apb/specs/HBM5.json`); do not edit by hand.

`HBM5_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ck_t`, `ck_c`, `addr`, `ras_n`, `cas_n`, `we_n`, `dq`, `dqs`, `cke`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D0E0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD0 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x018 | CMD1 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x01C | CMD2 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x020 | RDATA | RO | core | Read data |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6D0E | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD0 | 2:0 | `hcmd` | RW | 0x0 | 1 ACT, 2 RD, 3 WR, 4 PRE; other codes are no-ops |
| CMD1 | 31:0 | `haddr` | RW | 0x0 | host address (bank, row and column fields below) |
| CMD2 | 15:0 | `hwdata` | RW | 0x0 | word to write (WR) |
| RDATA | 15:0 | `hrdata` | RO | core | word of the last RD, valid once RD_DONE is set |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RD_DONE | a RD finished; RDATA holds its word |
| 1 | CMD_DONE | CMD beat accepted by the core |
| 2 | CMD_OVF | write to CMD while full (dropped) |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CMD_FULL | CMD holds a beat the core has not taken |

### Streams

* **CMD** feeds `hcmd`, `haddr`, `hwdata`/`hvalid`. Writing CMD2 commits the beat: FLAGS.CMD_FULL is set and `hvalid` stays high until the core's `hready`; then CMD_DONE is set. A write while full is dropped and sets CMD_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x6D0E0200.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
4. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD0 (0x014) then CMD1 (0x018) then CMD2 (0x01C). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
5. Read RDATA (0x020) for the core's live `hrdata`; it needs no clearing.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Host interface

A command is taken at an edge where `hvalid` = 1 and `hready` = 1; `hcmd`, `haddr` and `hwdata`
are read at that edge only. `hvalid` while `hready` = 0 is ignored (not queued). Codes 0, 5, 6, 7
are taken and do nothing. `hready` drops at the edge after a real command is taken and returns
only when that command's work is complete on the pins (an engine may wait longer, see §3.4):

| Command | Complete when |
|---|---|
| ACT | the row is open in the bank (ACT issued, or it was already open) |
| RD | `hdone` has pulsed (the read word is in `hrdata` from the next clock) |
| WR | the WR pin command has been issued with the write word on `dq` |
| PRE | the bank is closed (PRE issued, or it was already closed) |

`hready` is also 0 while a refresh is due or running (§3.6), so a refresh never drops a host
command. `hready` is never low for more than BUSY_MAX clocks in a row (§3.5).

A RD returns the word last written to the storage cell its address maps to (§3.2), or 0 if that
cell was never written (the array is zeroed once at time 0 and is not cleared by `rst_n`).

### 3.2 Address map and storage

| Field | Bits | Meaning |
|---|---|---|
| row | `haddr[31:18]` | 14-bit row |
| pc | `haddr[14:12]` | pc within the channel |
| channel | `haddr[11:8]` | 16 channels |
| column | `haddr[7:0]` | 256 columns |

Page entry = {channel, pc} (128 entries, numbered channel x 8 + pc),
each with its own open row and timers. Storage is 256 16-bit words per channel indexed by the
column (cell = {channel, column}); pcs and rows alias onto it.

### 3.3 Pin commands

One command per clock at most; between commands all three command pins are 1 (NOP). Commands
last one clock.

| Command | `ras_n` `cas_n` `we_n` | `addr` |
|---|---|---|
| ACT | 0 1 1 | {3'b000, row} |
| RD | 1 0 1 | {9'b0, column} |
| WR | 1 0 0 | {9'b0, column} |
| PRE (one bank) | 0 1 0 | `addr[10]` = 0 (other bits don't care) |
| PREA (all banks) | 0 1 0 | `addr[10]` = 1 |
| REF | 0 0 1 | don't care |

There are no bank or channel pins: the entry of a pin command is that of the host command it serves.
`ck_t` = `clk`, `ck_c` = not `clk`, `cke` = `rst_n`; `dqs` is never driven.

### 3.4 Command sequences

Per host command, with *hit* = the bank is open on the command's row, *conflict* = open on
another row, *closed* = not open:

| Host command | hit | conflict | closed |
|---|---|---|---|
| ACT | nothing | PRE, ACT | ACT |
| RD | RD | PRE, ACT, RD | ACT, RD |
| WR | WR | PRE, ACT, WR | ACT, WR |
| PRE | PRE | PRE | nothing |

Each pin command is issued at the first clock its spacing rules (§3.5) allow. After an ACT the
engine waits tRCD (before the RD / WR, or before `hready` for a host ACT). After a RD or WR it
waits CL clocks (`hdone` at the end for a RD) before returning to idle. After a host PRE it waits
tRP. Rows stay open after RD / WR (open page) until a conflict, a host PRE or a refresh closes
them.

### 3.5 Timing parameters

| Name | Clocks | Meaning |
|---|---|---|
| CL | 16 | read latency: RD pin command to `hdone` |
| TRCD | 12 | ACT to RD / WR of that bank |
| TRP | 12 | PRE to ACT (or REF) of that bank |
| TRC | 42 | ACT to ACT of the same bank |
| TRAS | 26 | ACT to PRE of the same bank |
| TRFC | 40 | REF to the next pin command |
| TREFI | 195 | refresh interval (down-counter reload) |

Each spacing is a minimum count of clocks between the two pin commands (a command in clock t and
the next in clock t + T or later). Derived bounds used by the checker: REF_MIN = 153, REF_MAX = 405, BUSY_MAX = 250 clocks (formulas in `tb/cov/HBM5_sva.sv`).

### 3.6 Refresh

Per-entry refresh. `ref_cnt` counts down from TREFI every clock; when it reaches 0, `hready`
drops and (once the current command's work is done, or at once when idle) one entry is
refreshed: the entry the refresh pointer `ref_bank` points at, which then advances by one, wrapping
over all 128 entries, so the k-th REF since reset refreshes entry k mod 128. If that entry is
open it is closed with a single-bank PRE (`addr[10]` = 0) once its tRAS has passed; the REF
follows once its tRP has passed; then tRFC; then idle. `ref_cnt` is reloaded when the refresh
starts. Every other entry keeps its open page across the refresh; only the refreshed entry must
be activated again. REF-to-REF spacing stays within REF_MIN .. REF_MAX. Here TREFI is the slice interval (195 clocks) and TRFC the per-entry refresh time tRFC_PB (40 clocks).

### 3.7 Data

Write: the write word is driven on `dq[16 x ch +: 16]` of the command's channel in the clock
before the WR pin command (the clock of its trace announcement) and the cell is written; `dq` is
high-Z in every other clock (the other channels' lanes too).

Read: the RD pin command is on the pins in clock t; `hdone` = 1 in clock t + CL; `hrdata` holds
the cell's word from clock t + CL + 1 until the next read completes.

### 3.8 Trace port

In the clock before each ACT, RD or WR pin command, `trace_valid` = 1, `trace_cmd` = 1 / 2 / 3 and
`trace_addr` = the host address of the command being served. It is 0 in every other clock (it
does not announce PRE, PREA or REF).

### 3.9 Reset

`rst_n` low: idle, every bank closed and every timer 0, `ref_cnt` = TREFI, `hready` = 1, command
pins NOP, `addr` = 0, `hrdata` = 0, `hdone` = 0, `trace_valid` = 0, `cke` = 0, `dq` released. The
storage array keeps its contents. `ref_bank` = 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `NCH` | 16 | 16 | channels; `dq` is 256 bits, `haddr[11:8]` selects the channel |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| unknown `hcmd` (0, 5 to 7) | taken, no effect, `hready` stays 1 |
| `hvalid` while `hready` = 0 | ignored |
| ACT to the row already open | no pin command |
| PRE of a closed bank | no pin command; `hready` returns once that bank's tRP (from an earlier PRE) has passed |
| refresh due during a command | the command finishes first; the refresh follows before `hready` |
| a stream of no-op commands | cannot hold off a refresh (`hready` drops when it is due) |
| two addresses with the same storage cell | aliasing (§3.2) |
| reset with a command in flight | the command is lost; a WR may or may not have reached the array |
| refresh | closes only the entry it refreshes (if open); other pages stay open |

## 6. TB check map

Messages are printed by `tb/HBM5_tb.sv` (the shared body `tb/mem_tb_common.svh`) as `ERROR: <message>`;
assertions are in the bound checker `tb/cov/HBM5_sva.sv` with the shared model `tb/cov/mem_chk.svh`,
which rebuilds a per-bank page and timing model from the pins and checks every pin command
independently of the RTL. The TB opens, writes, reads, re-opens and precharges every bank entry,
writes all-zero / all-one / alternating patterns, sends unknown codes and commands while busy,
600 random commands, and lets a refresh fall due during each kind of command and while idle;
finally it resets with a read in flight.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| a_cmd_belongs_to_host_op | every pin command serves the host command in flight or the refresh (whose PRE closes the refreshed entry) | §3.4 |
| a_rw_to_open_page | RD / WR only to the open row of the addressed bank | §3.4 |
| a_page_hit_needs_no_pre_act | a RD / WR page hit goes straight to the burst (no PRE / ACT) | §3.4 |
| a_act_to_closed_bank | ACT only to a closed bank | §3.4 |
| a_trcd | tRCD between ACT and RD / WR of a bank | §3.5 |
| a_trp | tRP between PRE and ACT / REF of a bank | §3.5 |
| a_trc | tRC between ACTs of a bank | §3.5 |
| a_tras | tRAS between ACT and PRE of a bank | §3.5 |
| a_trfc | no pin command within tRFC after REF | §3.5 |
| a_ref_all_closed | REF only with the refreshed entry (k mod N for the k-th REF) closed and its tRP past; other entries may stay open | §3.6 |
| a_pin_address | ACT carries the host row, RD / WR the host column | §3.3 |
| a_write_data_on_dq | the write word is on the channel's `dq` lanes in the clock before the WR command | §3.7 |
| a_trace_announces_cmd | the trace port announces every ACT / RD / WR one clock ahead with the host address | §3.8 |
| a_hdone_once_per_read | `hdone` exactly once per RD and only for a RD | §3.7 |
| a_read_latency_cl | `hdone` exactly CL clocks after the RD pin command | §3.7 |
| a_read_data | `hrdata` (clock after `hdone`) = the word last written to that cell | §3.2, §3.7 |
| a_hready_after_completion | `hready` returns only when the command is complete | §3.1 |
| a_no_stall | `hready` is not low for more than BUSY_MAX clocks | §3.5 |
| a_refresh_not_starved | REF-to-REF at most REF_MAX clocks | §3.6 |
| a_refresh_not_early | REF-to-REF at least REF_MIN clocks | §3.6 |
| a_legal_pin_code | only legal pin command codes | §3.3 |
| a_cke_out_of_reset | `cke` = 1 out of reset | §3.9 |
| a_reset_pins | in reset: `cke` = 0, no `hdone`, no trace, no pin command | §3.9 |
| a_ck_differential | `ck_c` = not `ck_t` | §3.3 |
| "RD" | every RD gets `hdone` within 4000 clocks and returns the scoreboard's word for its cell | §3.1, §3.7 |
| "dq driven while idle" | after 40 idle clocks `dq` floats (Icarus only) | §3.7 |
