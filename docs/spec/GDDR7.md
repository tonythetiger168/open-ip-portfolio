<!-- SPDX-License-Identifier: Apache-2.0 -->
# GDDR7: design specification

Graphics memory controller with PAM3 read signalling: the DRAM returns read data on the channel's `dq` lanes as 12 ternary symbols over two beats (the clock before `hdone` and the `hdone` clock), and the controller decodes them. Writes stay NRZ. Otherwise the open-page engine of DDR4 with 4 banks per channel and all-bank refresh. The core holds no data: write words go out on `dq` and read words come back on `dq` from the DRAM device, which the testbenches model (`tb/mem_dev.svh`). Core `GDDR7_top` (`rtl/GDDR7_top.sv`), testbench `tb/GDDR7_tb.sv` (shared body
`tb/mem_tb_common.svh`), checker `tb/cov/GDDR7_sva.sv` (shared model `tb/cov/mem_chk.svh`). The host
contract and the checker are shared by the whole memory-controller family; [DDR4.md](DDR4.md) is
the baseline the others are described against. Line commands (RDL / WRL: one 128-bit line in a BL8 PAM2 or a BL6 PAM3 burst) and an MR file with
programmable CL / CWL and the PAM3 mode are described in §3.10.

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
| `hcmd` | input | 3 | host command: 1 ACT, 2 RD, 3 WR, 4 PRE, 5 RDL, 6 WRL, 7 MR access (§3.10); 0 is a no-op | - | `clk` | - |
| `haddr` | input | 32 | host address (§3.2) | - | `clk` | - |
| `hwdata` | input | 16 | write word (WR), MRW value (bits 7:0), or a WRL data beat (§3.10) | - | `clk` | - |
| `hrdata` | output | 16 | read word, valid from the clock after `hdone` until the next read; an RDL passes its beats through it (§3.10), an MRR returns {8'h00, MR} | - | `clk` | 0 |
| `rdline` | output | 128 | the line of the last RDL (word k = column {haddr[7:3], k} in bits 16k+15:16k), from the clock after its `hdone` until the next RDL | - | `clk` | 0 |
| `hdone` | output | 1 | one-clock pulse per RD (CL clocks after its RD pin command), per RDL (with its last beat) and per MRR (the clock after it is taken) | high | `clk` | 0 |
| `ck_t` | output | 1 | DRAM clock = `clk` | - | `clk` | - |
| `ck_c` | output | 1 | DRAM clock complement = not `clk` | - | `clk` | - |
| `addr` | output | 17 | pin address: ACT row in [13:0], RD / WR column in [7:0], PRE all-banks flag in [10] | - | `clk` | 0 |
| `cs_n` | output | 1 | chip select: 0 in the clock of each pin command, 1 (deselect) otherwise | low | `clk` | 1 |
| `act_n` | output | 1 | 0 on an ACT (then `ras_n` / `cas_n` / `we_n` = 0 carry row bits A16..A14), 1 otherwise | low | `clk` | 1 |
| `ba` | output | 3 | bank entry {channel, bank} of the pin command (0 for PREA / REF) | - | `clk` | 0 |
| `pam3` | output | 1 | = MR2[0]: 1 PAM3 line bursts and word reads, 0 PAM2 (§3.10) | high | `clk` | 1 |
| `dqx` | inout | NCH x 16 | upper level bit of each `dq` pin in a PAM3 line beat (§3.10); else high-Z | - | `clk` | high-Z |
| `ras_n` | output | 1 | command pin RAS# | low | `clk` | 1 |
| `cas_n` | output | 1 | command pin CAS# | low | `clk` | 1 |
| `we_n` | output | 1 | command pin WE# | low | `clk` | 1 |
| `dq` | inout | NCH x 16 | data; the core drives it only with write data (§3.7), else high-Z; the DRAM drives PAM3 read beats | - | `clk` | high-Z |
| `dqs` | inout | 2 | data strobe: the core drives {~s, s}, s toggling every beat, with the beats of a line write (§3.10), else high-Z; the DRAM drives it with line read beats | - | `clk` | high-Z |
| `cke` | output | 1 | clock enable = `rst_n` | high | `clk` | 0 |
| `trace_valid` | output | 1 | a pin command ACT / RD / WR comes in the next clock | high | `clk` | 0 |
| `trace_cmd` | output | 3 | 1 ACT, 2 RD, 3 WR (valid with `trace_valid`) | - | `clk` | - |
| `trace_addr` | output | 32 | host address of the command being served | - | `clk` | - |

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `ref_cnt` | 14 | refresh down-counter: clocks until the next refresh is due; loaded with TREFI at reset and when a refresh starts, decremented every clock, `hready` = 0 while it is 0. The TB waits for exact values of it to make a refresh fall due during a command |
| `cl_now`, `cwl_now` | 5 each | CL and CWL in use, from the MR file (§3.10). The TB's DRAM device follows them for its read latency and line write capture, as a real device follows its own mode registers |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/GDDR7.md`](../ip/GDDR7.md) (source: `scripts/apb/specs/GDDR7.json`); do not edit by hand.

`GDDR7_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `pam3`, `ck_t`, `ck_c`, `addr`, `cs_n`, `act_n`, `ba`, `ras_n`, `cas_n`, `we_n`, `dq`, `dqx`, `dqs`, `cke`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D080300 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD0 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command (the core takes it when it is idle and no refresh is due), or one of the 8 data beats that follow a WRL |
| 0x018 | CMD1 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command (the core takes it when it is idle and no refresh is due), or one of the 8 data beats that follow a WRL |
| 0x01C | CMD2 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command (the core takes it when it is idle and no refresh is due), or one of the 8 data beats that follow a WRL |
| 0x020 | RDATA | RO | core | Read data |
| 0x024 | RLINE0 | RO | core | Line of the last RDL (RLINE0 = bits 31:0) |
| 0x028 | RLINE1 | RO | core | Line of the last RDL (RLINE0 = bits 31:0) |
| 0x02C | RLINE2 | RO | core | Line of the last RDL (RLINE0 = bits 31:0) |
| 0x030 | RLINE3 | RO | core | Line of the last RDL (RLINE0 = bits 31:0) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x034 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6D08 | IP code |
| ID | 15:8 | MAJOR | RO | 0x03 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD0 | 2:0 | `hcmd` | RW | 0x0 | 1 ACT, 2 RD, 3 WR, 4 PRE, 5 RDL, 6 WRL (then 8 data beats), 7 MR access; 0 is a no-op; ignored on a data beat |
| CMD1 | 31:0 | `haddr` | RW | 0x0 | host address (bank, row and column fields below); MR access: [3] 1 MRR / 0 MRW, [2:0] MR index |
| CMD2 | 15:0 | `hwdata` | RW | 0x0 | word to write (WR), MRW value (bits 7:0), or a WRL data beat (beat 0 = column {haddr[7:3], 0}) |
| RDATA | 15:0 | `hrdata` | RO | core | word of the last RD (or word 7 of an RDL, {8'h0, MR} of an MRR), valid once DONE is set |
| RLINE0 | 31:0 | `rdline[31:0]` | RO | core | the 8 words of the last RDL (word k = column {haddr[7:3], k} in bits 16k+15:16k), held until the next RDL |
| RLINE1 | 31:0 | `rdline[63:32]` | RO | core | the 8 words of the last RDL (word k = column {haddr[7:3], k} in bits 16k+15:16k), held until the next RDL |
| RLINE2 | 31:0 | `rdline[95:64]` | RO | core | the 8 words of the last RDL (word k = column {haddr[7:3], k} in bits 16k+15:16k), held until the next RDL |
| RLINE3 | 31:0 | `rdline[127:96]` | RO | core | the 8 words of the last RDL (word k = column {haddr[7:3], k} in bits 16k+15:16k), held until the next RDL |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a RD, RDL or MRR finished; RDATA (and RLINE for an RDL) holds its data |
| 1 | CMD_DONE | CMD beat accepted by the core |
| 2 | CMD_OVF | write to CMD while full (dropped) |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CMD_FULL | CMD holds a beat the core has not taken |

### Streams

* **CMD** feeds `hcmd`, `haddr`, `hwdata`/`hvalid`. Writing CMD2 commits the beat: FLAGS.CMD_FULL is set and `hvalid` stays high until the core's `hready`; then CMD_DONE is set. A write while full is dropped and sets CMD_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x6D080300.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
4. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD0 (0x014) then CMD1 (0x018) then CMD2 (0x01C). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
5. Read RDATA (0x020) for the core's live `hrdata`; it needs no clearing.
6. Read RLINE0 (0x024), RLINE1 (0x028), RLINE2 (0x02C), RLINE3 (0x030) for the core's live `rdline[31:0]`, `rdline[63:32]`, `rdline[95:64]`, `rdline[127:96]`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
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

A RD returns the word the device drives on `dq` for it (§3.7). With the TB's device that is the
word last written to the storage cell the address maps to (§3.2), or 0 if that cell was never
written (the device array starts zeroed and keeps its data through `rst_n`).

### 3.2 Address map and storage

| Field | Bits | Meaning |
|---|---|---|
| row | `haddr[31:18]` | 14-bit row |
| bank | `haddr[10:9]` | 4 banks per channel |
| channel | `haddr[8]` | 2 channels (NCH = 2) |
| column | `haddr[7:0]` | 256 columns |

Bank entry = {channel, bank} (8 entries). The core holds no data; the TB's device (`tb/mem_dev.svh`) stores 256 16-bit words per channel indexed by the
column (cell = {channel, column}); banks and rows alias onto it.

### 3.3 Pin commands

One command per clock at most; `cs_n` = 1 (deselect) between commands. Commands last one clock.
`line` = `addr[12]` = 1 on the RD / WR of a line, 0 for a word.

| Command | `cs_n` `act_n` | `ras_n` `cas_n` `we_n` | `addr` | `ba` |
|---|---|---|---|---|
| ACT | 0 0 | 0 0 0 (row bits A16..A14) | {3'b000, row} | bank |
| RD | 0 1 | 1 0 1 | {4'b0, line, 4'b0, column} | bank |
| WR | 0 1 | 1 0 0 | {4'b0, line, 4'b0, column} | bank |
| PRE (one bank) | 0 1 | 0 1 0 | `addr[10]` = 0 (other bits don't care) | bank |
| PREA (all banks) | 0 1 | 0 1 0 | `addr[10]` = 1 | 0 |
| REF | 0 1 | 0 0 1 | don't care | 0 |
| deselect | 1 1 | don't care | don't care | don't care |

`ba` carries the bank entry {channel, bank} of the command (0 for PREA and REF). `ck_t` = `clk`,
`ck_c` = not `clk`, `cke` = `rst_n`; the core drives `dqs` only with line write beats (§3.10).

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
| CL | 18 | read latency at reset: RD pin command to `hdone` (then 5 + MR0[3:0], §3.10) |
| TRCD | 15 | ACT to RD / WR of that bank |
| TRP | 15 | PRE to ACT (or REF) of that bank |
| TRC | 46 | ACT to ACT of the same bank |
| TRAS | 32 | ACT to PRE of the same bank |
| TRFC | 150 | REF to the next pin command |
| TREFI | 3900 | refresh interval (down-counter reload) |

Each spacing is a minimum count of clocks between the two pin commands (a command in clock t and
the next in clock t + T or later). Derived bounds used by the checker: REF_MIN = 3849, REF_MAX = 4143, BUSY_MAX = 393 clocks (formulas in `tb/cov/GDDR7_sva.sv`).

### 3.6 Refresh

`ref_cnt` counts down from TREFI every clock. When it reaches 0, `hready` drops. If the engine is
idle, the refresh starts at once; if a command is running, the refresh starts when that command's
work is done, before `hready` returns. Refresh: every bank is marked closed; PREA when every
bank's tRAS has passed; REF when every bank's tRP has passed; then tRFC; then idle. `ref_cnt` is
reloaded with TREFI when the refresh starts. Rows open before a refresh must be activated again.
REF-to-REF spacing stays within REF_MIN .. REF_MAX.

### 3.7 Data

Write: the write word is driven on `dq[16 x ch +: 16]` of the command's channel in the clock
before the WR pin command (the clock of its trace announcement), where the device stores it; `dq` is
high-Z in every other clock (the other channels' lanes too).

Read: the RD pin command is on the pins in clock t; the device drives the word as two PAM3 beats
on `dq[16 x ch +: 12]` in clocks t + CL - 1 and t + CL (`hdone` = 1), and the core takes the first beat
at the end of clock t + CL - 1 and the second at the end of clock t + CL, then decodes them:
`hrdata` holds the word from clock t + CL + 1 until the next read completes.

PAM3 read beats: the word w being read is split into 4 nibbles; nibble n (w[4n+3:4n], value v =
0 to 15) is sent as 3 ternary symbols t0, t1, t2 with v = 9 x t0 + 3 x t1 + t2. A symbol is a
2-bit level code on a pin pair: 00, 01, 10 = levels 0, 1, 2 (11 never appears). On the channel's
lanes `dq[16 x ch +: 12]`:

| Clock | `dq` bits [1:0] [3:2] [5:4] | bits [7:6] [9:8] [11:10] |
|---|---|---|
| t + CL - 1 (before `hdone`) | t0 t1 t2 of nibble 0 | t0 t1 t2 of nibble 1 |
| t + CL (`hdone`) | t0 t1 t2 of nibble 2 | t0 t1 t2 of nibble 3 |

`dq[16 x ch + 15 : 16 x ch + 12]` stay high-Z in both beats; the other channel's lanes too. Decode:
v = 9 x t0 + 3 x t1 + t2 per nibble, low 4 bits kept. The core drives `dq` only with write data.

### 3.8 Trace port

In the clock before each ACT, RD or WR pin command, `trace_valid` = 1, `trace_cmd` = 1 / 2 / 3 and
`trace_addr` = the host address of the command being served. It is 0 in every other clock (it
does not announce PRE, PREA or REF).

### 3.9 Reset

`rst_n` low: idle, every bank closed and every timer 0, `ref_cnt` = TREFI, `hready` = 1, command
pins NOP, `addr` = 0, `hrdata` = 0, `hdone` = 0, `trace_valid` = 0, `cke` = 0, `dq` released. The DRAM device keeps its array.

### 3.10 Line commands and the MR file

On top of the word commands the core takes line commands and has a mode-register file.

| `hcmd` | Command | Taken | Complete when |
|---|---|---|---|
| 5 | RDL: read line | as a RD (same bank, page and refresh rules, §3.4) | `hdone` has pulsed with the last beat |
| 6 | WRL: write line | `hready` stays 1 for its 8 data beats: beat k = `hwdata` at the k-th following edge with `hvalid` = 1 (gaps allowed) | the last data beat is on the pins |
| 7 | MR access | in one clock, no pin command: `haddr[3]` = 0 MRW (MR `haddr[2:0]` = `hwdata[7:0]`), 1 MRR (`hdone` in the next clock, `hrdata` = {8'h00, MR} from the clock after) | at once |

A line is the 8 columns {`haddr[7:3]`, k}, k = 0..7, of the addressed bank and row (`haddr[2:0]`
are ignored). It moves in one burst: the RD / WR pin command of a line has `addr[12]` = 1; a word RD / WR
has it 0. The column field of the pin command is {`haddr[7:3]`, 3'b000} for a line.

Write: the WR pin command of a WRL is issued in clock t (after its ACT, as for a WR); beat k is on the
channel's `dq` lanes in clock t + CWL + k, k = 0..7, with `dqs` = {~s, s}, s toggling every beat
(the first beat's s is the opposite of the previous line write's last). The WRL is complete after
beat 7. Read: the RD pin command of an RDL is in clock t; the DRAM drives beat k in clock t + CL + k;
the core passes beat k to `hrdata` in the clock after it, pulses `hdone` with beat 7 (clock
t + CL + 7) and holds the line on `rdline` from the clock after. PAM2: a line is BL8 as above. PAM3: a line is BL6. Its 32 nibbles are 96 ternary symbols (nibble
k = symbols 3k..3k+2, v = 9 x t0 + 3 x t1 + t2) and beat b, b = 0..5, carries symbols 16b..16b+15,
symbol 16b + p on pin p of the channel as the level code {`dqx[p]`, `dq[p]`} (00 / 01 / 10). A PAM3
WRL drives beats 0..5 in clocks t + CWL .. t + CWL + 5; a PAM3 RDL takes beats 0..5 in clocks
t + CL .. t + CL + 5, pulses `hdone` with beat 5 and decodes the line with it: `hrdata` = word 7
and `rdline` = the line from the clock after (no per-beat words on `hrdata`).

MR file: MR0..MR7, 8 bits each, reset 0 except MR0 = 13, MR1 = 2 (CL 18, CWL 7) and MR2 = 1 (PAM3). CL = 5 + MR0[3:0], CWL = 5 + MR1[3:0]; every RD / WR
(word or line) uses the values in force when it is taken. MR0 bit 7 is self-clearing (reads 0). MR2[0] selects the signaling (pin `pam3`): 1 = PAM3, 0 = PAM2. In PAM2 a word read comes NRZ
on the channel's 16 `dq` lanes in the second beat (clock t + CL).
The MR file is controller-side: no MRW goes to the DRAM, whose own mode registers are set to match
outside this model.

Write recovery and the write-to-read turnaround count from the WR pin command: a PRE of the bank
waits CWL + burst + TWR clocks, any RD CWL + burst + TWTR clocks (burst = the clocks the write
data holds the bus: 8 for a line, the word burst for a word).

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `NCH` | 2 | 2 | two channels; `dq` is 32 bits, `haddr[8]` selects the channel |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `hcmd` 0 | taken, no effect, `hready` stays 1 |
| WRL data beat gaps | `hready` stays 1 until all 8 beats are taken; the burst starts after the last |
| MRW of MR0 bit 7 | taken, reads back 0 (self-clearing) |
| `hvalid` while `hready` = 0 | ignored |
| ACT to the row already open | no pin command |
| PRE of a closed bank | no pin command; `hready` returns once that bank's tRP (from an earlier PRE) has passed |
| refresh due during a command | the command finishes first; the refresh follows before `hready` |
| a stream of no-op commands | cannot hold off a refresh (`hready` drops when it is due) |
| two addresses with the same storage cell | the same cell of the TB's device (aliasing, §3.2) |
| reset with a command in flight | the command is lost; a WR may or may not have reached the device |

## 6. TB check map

Messages are printed by `tb/GDDR7_tb.sv` (the shared body `tb/mem_tb_common.svh`) as `ERROR: <message>`;
assertions are in the bound checker `tb/cov/GDDR7_sva.sv` with the shared model `tb/cov/mem_chk.svh`,
which rebuilds a per-bank page and timing model from the pins and checks every pin command
independently of the RTL. The TB opens, writes, reads, re-opens and precharges every bank entry,
writes all-zero / all-one / alternating patterns, sends unknown codes and commands while busy,
600 random commands, and lets a refresh fall due during each kind of command and while idle;
finally it resets with a read in flight. The TB's `dq driven while idle` check still holds: the PAM3 beats are part of a read.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| a_cmd_belongs_to_host_op | every ACT / RD / WR / PRE pin command serves the host command in flight (or a refresh); a RD / WR at most once | §3.4 |
| a_rw_to_open_page | RD / WR only to the open row of the addressed bank | §3.4 |
| a_page_hit_needs_no_pre_act | a RD / WR page hit goes straight to the burst (no PRE / ACT) | §3.4 |
| a_act_to_closed_bank | ACT only to a closed bank | §3.4 |
| a_trcd | tRCD between ACT and RD / WR of a bank | §3.5 |
| a_trp | tRP between PRE and ACT / REF of a bank | §3.5 |
| a_trc | tRC between ACTs of a bank | §3.5 |
| a_tras | tRAS between ACT and PRE of a bank | §3.5 |
| a_trfc | no pin command within tRFC after REF | §3.5 |
| a_ref_all_closed | REF only with the refreshed bank(s) closed | §3.6 |
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
| a_pam3_read_word | the two PAM3 beats decode to the expected read word | §3.7 |
| a_pam3_legal_symbols | no level code 11 and no nibble value above 15 | §3.7 |
| a_ck_differential | `ck_c` = not `ck_t` | §3.3 |
| "RD" | every RD gets `hdone` within 4000 clocks and returns the scoreboard's word for its cell | §3.1, §3.7 |
| "dq driven while idle" | after 40 idle clocks `dq` floats (Icarus only) | §3.7 |
| a_burst_length_matches_command | a RD / WR pin command carries the line flag exactly when it serves an RDL / WRL | §3.10 |
| a_line_write_beats_on_dq | WRL beat k is on the channel's lanes in clock WR + CWL + k | §3.10 |
| a_line_write_dqs_toggles | `dqs` = {~s, s} with s toggling on every line write beat | §3.10 |
| a_line_read_beats_on_hrdata | each RDL beat reaches `hrdata`, `hdone` with the last | §3.10 |
| a_rdline_holds_line | `rdline` = the 8 words of the line after an RDL | §3.10 |
| a_mrr_value | MRR returns {8'h00, MR} of the model's MR file | §3.10 |
| "RDL" / "WRL" | every RDL gets `hdone`, `rdline` and the last `hrdata` beat equal to the scoreboard's line; WRL data beats are taken with `hready` = 1 | §3.10 |
| "MRR" | every MRR gets `hdone` and returns the value last written | §3.10 |
| a_bank_pins | `ba` = the entry of every ACT / RD / WR / PRE, 0 for PREA / REF | §3.3 |
| a_pam3_pin_is_mr2 | `pam3` = MR2[0] of the model's MR file | §3.10 |
| a_reset_cs | in reset: `cs_n` = 1, `act_n` = 1, `ba` = 0, `rdline` = 0 | §3.9 |
