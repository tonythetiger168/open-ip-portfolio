<!-- SPDX-License-Identifier: Apache-2.0 -->
# XGMII: design specification

XGMII-style 32-bit column datapath without framing: host bytes are packed into 4-lane columns
(lane 0 first), queued in a 4-entry asynchronous FIFO and sent one column per `tx_clk` rise on
`txd`/`txc`, with unused lanes and empty cycles filled with the Idle control character 0x07
(`txc` = 1). On receive, every data lane (`rxc` = 0) of each column is stored, in lane order, in a
16-entry byte ring that the host reads by index. There is no Start (0xFB), Terminate (0xFD),
preamble, FCS or lane alignment, and columns are single data rate (§5). Core `XGMII_top`
(`rtl/XGMII_top.sv`), testbench `tb/XGMII_tb.sv`, checker `tb/cov/XGMII_sva.sv`.

Conventions on this page: the host side and the RX capture run on the rising edge of `clk`, the
TX FIFO read on the rising edge of `tx_clk`; every flop in both domains is reset asynchronously
by `rst_n` low. `rx_clk` is not used as a clock: it is oversampled by `clk` (§3.4). Lane *l* is
bits [8l+7:8l] of `txd`/`rxd` with control bit `txc[l]`/`rxc[l]`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | host clock; also oversamples `rx_clk` and must be at least 4x faster than it | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of both domains (packer, FIFO pointers, TX column, RX pointer) | low | async assert | - |
| `tx_clk` | input | 1 | transmit clock, one column per rising edge | rising edge | - | - |
| `txd` | output | 32 | transmit column; data lanes from lane 0 up, 0x07 in every control lane | - | `tx_clk` | 0x07070707 |
| `txc` | output | 4 | per-lane control flag: 0 = data, 1 = control (Idle); 4'hF for an idle column | - | `tx_clk` | 4'hF |
| `rx_clk` | input | 1 | receive clock; only its rising edges matter, detected by sampling with `clk` | rising edge | async (2 flops) | - |
| `rxd` | input | 32 | receive column, sampled by `clk` together with `rx_clk` | - | `clk` (1 flop) | - |
| `rxc` | input | 4 | receive control flags; lanes with `rxc` = 0 are stored, others skipped | - | `clk` (1 flop) | - |
| `wen` | input | 1 | host write strobe, one `clk` per write | high | `clk` | - |
| `waddr` | input | 4 | 0: data byte into the packer; 1: end of frame (push a partial column); others ignored | - | `clk` | - |
| `wdata` | input | 8 | data byte for `waddr` = 0 | - | `clk` | - |
| `ren` | input | 1 | host read strobe; has no side effect, only gates `irq` | high | `clk` | - |
| `raddr` | input | 4 | RX ring entry to read | - | comb. | - |
| `rdata` | output | 8 | `rxq[raddr]`, combinational; the ring is not reset | - | comb. | X |
| `count` | output | 5 | number of bytes received, modulo 32 (`rx_wr`); the next byte goes to entry `count[3:0]` | - | `clk` | 0 |
| `irq` | output | 1 | `count != 0 && ren`, combinational | high | comb. | 0 |

### Internal signals used by the verification

The TB and the checker read these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `tx_full` | 1 | TX FIFO full as seen from the `clk` domain (§3.1) |
| `pk_n` | 2 | number of bytes held in the packer (0..3) |
| `rxq` | 8 x `DEPTH` | the RX ring, entry *i* is what `rdata` returns for `raddr` = *i* |
| `rx_wr` | 5 | RX write pointer and byte count; `count` is this flop |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/XGMII.md`](../ip/XGMII.md) (source: `scripts/apb/specs/XGMII.json`); do not edit by hand.

`XGMII_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_clk`, `txd`, `txc`, `rx_clk`, `rxd`, `rxc`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x58470200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | RX capture count |
| 0x018 | TX | WO (core) | core | Byte to send, packed lane 0 first; the fourth byte pushes the column (dropped while the 4-column FIFO is full) (write-only) |
| 0x01C | EOF | WO (core) | core | End of frame: pushes a partly filled column, idle (0x07, txc set) in the unused lanes; nothing when no byte is held or while the FIFO is full (write-only, data ignored) |
| 0x020 | RX0 | RO (core) | core | RX capture ring entry 0 |
| 0x024 | RX1 | RO (core) | core | RX capture ring entry 1 |
| 0x028 | RX2 | RO (core) | core | RX capture ring entry 2 |
| 0x02C | RX3 | RO (core) | core | RX capture ring entry 3 |
| 0x030 | RX4 | RO (core) | core | RX capture ring entry 4 |
| 0x034 | RX5 | RO (core) | core | RX capture ring entry 5 |
| 0x038 | RX6 | RO (core) | core | RX capture ring entry 6 |
| 0x03C | RX7 | RO (core) | core | RX capture ring entry 7 |
| 0x040 | RX8 | RO (core) | core | RX capture ring entry 8 |
| 0x044 | RX9 | RO (core) | core | RX capture ring entry 9 |
| 0x048 | RX10 | RO (core) | core | RX capture ring entry 10 |
| 0x04C | RX11 | RO (core) | core | RX capture ring entry 11 |
| 0x050 | RX12 | RO (core) | core | RX capture ring entry 12 |
| 0x054 | RX13 | RO (core) | core | RX capture ring entry 13 |
| 0x058 | RX14 | RO (core) | core | RX capture ring entry 14 |
| 0x05C | RX15 | RO (core) | core | RX capture ring entry 15 |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x060 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5847 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 4:0 | `count` | RO | core | data lanes captured (wraps at 32); entry count mod 16 is written next |
| TX | 7:0 | core register | WO (core) | core | written at core register 0 |
| EOF | 7:0 | core register | WO (core) | core | written at core register 1 |
| RX0 | 7:0 | core register | RO (core) | core | read from core register 0 |
| RX1 | 7:0 | core register | RO (core) | core | read from core register 1 |
| RX2 | 7:0 | core register | RO (core) | core | read from core register 2 |
| RX3 | 7:0 | core register | RO (core) | core | read from core register 3 |
| RX4 | 7:0 | core register | RO (core) | core | read from core register 4 |
| RX5 | 7:0 | core register | RO (core) | core | read from core register 5 |
| RX6 | 7:0 | core register | RO (core) | core | read from core register 6 |
| RX7 | 7:0 | core register | RO (core) | core | read from core register 7 |
| RX8 | 7:0 | core register | RO (core) | core | read from core register 8 |
| RX9 | 7:0 | core register | RO (core) | core | read from core register 9 |
| RX10 | 7:0 | core register | RO (core) | core | read from core register 10 |
| RX11 | 7:0 | core register | RO (core) | core | read from core register 11 |
| RX12 | 7:0 | core register | RO (core) | core | read from core register 12 |
| RX13 | 7:0 | core register | RO (core) | core | read from core register 13 |
| RX14 | 7:0 | core register | RO (core) | core | read from core register 14 |
| RX15 | 7:0 | core register | RO (core) | core | read from core register 15 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | READ | a ring entry was read after at least one byte was captured |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x58470200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `count`; it needs no clearing.
5. Access the core's registers through the CORE words (0x018 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Packing and the TX FIFO

The packer holds up to 3 bytes (`pk_n`). At a `clk` edge:

- data byte (`wen`, `waddr` = 0) with `pk_n` < 3: stored in lane `pk_n`, `pk_n` increments;
- data byte with `pk_n` = 3 and `tx_full` = 0: a full column {byte, packer} is pushed and the
  packer empties; with `tx_full` = 1 the byte is dropped and the packer keeps its 3 bytes;
- end of frame (`wen`, `waddr` = 1) with `pk_n` != 0 and `tx_full` = 0: the partial column is
  pushed with its byte count and the packer empties; with `pk_n` = 0 it does nothing; with
  `tx_full` = 1 it is ignored and the packer keeps its bytes (a later end of frame flushes them).

The FIFO has 4 entries, each a 32-bit column plus its byte count, with 3-bit binary and Gray
pointers and a 2-flop synchronizer each way. `tx_full` is pessimistic by up to 2 `clk` (it uses
the synchronized read pointer). Bytes are never sent before the column is complete or the frame
ended, so a frame of *n* bytes needs ceil(*n*/4) columns and the host must end it with a write
to `waddr` 1 unless *n* is a multiple of 4.

### 3.2 Transmit

At each `tx_clk` rise, if the FIFO (seen through the synchronized write pointer) is not empty,
the oldest entry is sent: lane 0 always carries data; lanes 1..3 carry data up to the entry's byte
count and Idle (0x07, `txc` = 1) above it. So `txc` is 4'b0000, 4'b1000, 4'b1100 or 4'b1110. If it
is empty, an idle column (0x07070707, `txc` = 4'hF) is sent. A column pushed at a `clk` edge
reaches the outputs at the third `tx_clk` rise after it (two synchronizer stages and the output
register), give or take one. Columns go out in push order, one per `tx_clk`, none repeated
(checker `a_tx_column`).

### 3.3 Idle lanes

Every lane whose `txc` bit is 1 carries 0x07 (checker `a_idle_lanes`); in particular after reset
and whenever the FIFO is empty.

### 3.4 Receive

At every `clk` edge `rxclk_s <= rx_clk`, `rxclk_d <= rxclk_s`, `rxd_s <= rxd`, `rxc_s <= rxc`. At
a `clk` edge where `rxclk_s && !rxclk_d` (an `rx_clk` rise), the lanes with `rxc_s` = 0 are
stored in lane order at consecutive ring entries starting at `rx_wr[3:0]` (wrapping at 16), and
`rx_wr` advances by their number (0 to 4, 5 bits, wraps at 32). Control lanes are skipped
wherever they sit in the column, so a column such as `rxc` = 4'b0101 stores lanes 1 and 3 in two
consecutive entries. The column used is the one present at the first `clk` edge that sees
`rx_clk` high, so the source must hold `rxd`/`rxc` stable across that edge; each `rx_clk` level
must last at least 2 `clk` periods (TB: 10 ns `clk`, 80 ns `tx_clk`).

### 3.5 Host read

`rdata = rxq[raddr]` and `irq = (rx_wr != 0) && ren` are combinational. Reading does not
consume anything; `count` steps by up to 4 per `clk`.

### 3.6 Reset

`rst_n` low, in both domains at once: packer and FIFO pointers to 0 (queued bytes are discarded
and never sent), TX column idle (0x07070707, `txc` = 4'hF), RX synchronizers to idle
(`rxc_s` = 4'hF) and `rx_wr` = 0. The FIFO and ring storage are not reset.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DEPTH` | 16 | 16 | size of the RX ring `rxq`. Indexes are `rx_wr[3:0]` plus a lane offset and `raddr[3:0]`, so only 16 is consistent |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| byte completing a column while the FIFO is full | dropped; the packer keeps the first 3 bytes |
| end of frame while the FIFO is full | ignored, packer kept; repeat it to flush |
| end of frame with an empty packer | no-op |
| `waddr` other than 0 or 1 | ignored |
| received column with control lanes between data lanes | data lanes stored compacted in lane order |
| received column with `rxc` = 4'hF | nothing stored |
| more than 16 bytes received without reading | ring wraps and overwrites the oldest entries |
| reset with columns queued | discarded; TX stays idle after reset |
| data rate | one column per `tx_clk` rise (SDR). IEEE 802.3 XGMII transfers a column on each edge of a 156.25 MHz clock; this core needs a clock at the column rate |
| framing characters | none: a PHY expecting Start / Terminate would not recognise these columns as a frame |

## 6. TB check map

Messages are printed by `tb/XGMII_tb.sv` as `ERROR: <message>` (A1..A6 as `SVA_FAIL:`); "CRV"
messages and A1..A6 are built only for Verilator. Assertions a_* are in `tb/cov/XGMII_sva.sv`.
All TB checks run in loopback (`rx_clk` = `tx_clk`, `rxd` = `txd`, `rxc` = `txc` unless the TB
forces lanes to control).

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "XGMII rxq[" | 8 bytes (two full columns) looped back into ring entries 0..7 | §3.1 to §3.4 |
| "CRV burst" | random bursts with end of frame, stray writes, forced control lanes; random-order read back | §3.1, §3.4, §5 |
| "XGMII" | frames of 1..7 bytes plus a second end of frame: exactly *n* bytes arrive | §3.1, §3.2 |
| "XGMII frame byte" | ... with the right values | §3.2, §3.4 |
| "XGMII sparse" | received columns with control lanes in any position: data lanes stored compacted, `count` advances by their number | §3.4 |
| "XGMII overflow" | 40 back-to-back bytes into the 4-column FIFO, with an end of frame while full: some bytes arrive | §3.1, §5 |
| "XGMII not idle in reset" | during reset `count` = 0 and `txc` = 4'hF | §3.6 |
| "XGMII sent queued bytes after reset" | columns queued before reset are never sent | §3.6 |
| "XGMII class byte" | 00, FF, 55, AA pass end to end | §3.2, §3.4 |
| "A1 reset: count cleared" | `count` = 0 in reset | §3.6 |
| "A2 control lanes idle" | every control lane carries 0x07 | §3.3 |
| "A3 count steps <=4" | `count` advances by 0..4 per `clk` | §3.4 |
| "A4 irq implies ren & data" | `irq` only with `ren` and `count` != 0 | §3.5 |
| "A5 rdata is rxq[raddr]" | combinational ring read | §3.5 |
| "A6 count is rx_wr" | `count` is the ring write pointer | §3.4 |
| a_reset_idle | in reset `count` = 0 and `txc` = 4'hF | §3.6 |
| a_idle_lanes | control lanes carry 0x07 | §3.3 |
| a_tx_column | every non-idle column is the next pushed column, data and `txc` | §3.1, §3.2 |
| a_full_means_backlog | `tx_full` only while at least 2 pushed columns are unsent | §3.1 |
| a_rx_count_model | `count` equals an independent model of §3.4 | §3.4 |
| a_rx_read_model | `rdata` matches the model ring | §3.4, §3.5 |
| a_irq_model | `irq` = (model count != 0) && `ren` | §3.5 |
