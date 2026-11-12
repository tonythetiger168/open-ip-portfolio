<!-- SPDX-License-Identifier: Apache-2.0 -->
# GMII: design specification

GMII MAC byte datapath without framing: a host writes bytes into an 8-entry asynchronous FIFO
that is drained one byte per `tx_clk` onto `txd`/`tx_en`, and bytes arriving on `rxd` while
`rx_dv` is high are captured, one per `rx_clk` rising edge, into a 16-entry ring that the host
reads by index. There is no preamble, SFD, FCS or inter-frame gap handling; `tx_er` is tied low
and `rx_er` is ignored. Core `GMII_top` (`rtl/GMII_top.sv`), testbench `tb/GMII_tb.sv`, checker
`tb/cov/GMII_sva.sv`.

Conventions on this page: the host side and the RX capture run on the rising edge of `clk`, the
TX drain on the rising edge of `tx_clk`; every flop in both domains is reset asynchronously by
`rst_n` low. `rx_clk` is not used as a clock: it is oversampled by `clk` (§3.3).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | host clock; also oversamples `rx_clk` and must be at least 4x faster than it | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of both domains (TX FIFO pointers, `txd`, `tx_en`, RX ring pointer) | low | async assert | - |
| `tx_clk` | input | 1 | GMII transmit clock (125 MHz in a real PHY); drains the TX FIFO | rising edge | - | - |
| `txd` | output | 8 | transmit byte, registered; valid while `tx_en` = 1, holds the last byte otherwise | - | `tx_clk` | 0x00 |
| `tx_en` | output | 1 | transmit enable: 1 for every `tx_clk` cycle that carries a byte from the FIFO | high | `tx_clk` | 0 |
| `tx_er` | output | 1 | transmit error, constant 0 | high | - | 0 |
| `rx_clk` | input | 1 | receive clock; only its rising edges matter, detected by sampling with `clk` | rising edge | async (2 flops) | - |
| `rxd` | input | 8 | receive byte, sampled by `clk` together with `rx_clk` (§3.3) | - | `clk` (1 flop) | - |
| `rx_dv` | input | 1 | receive data valid: a byte is captured on an `rx_clk` rising edge only while it is 1 | high | `clk` (1 flop) | - |
| `rx_er` | input | 1 | receive error; accepted and ignored (the byte is still captured) | high | - | - |
| `wen` | input | 1 | host write strobe, one `clk` per write | high | `clk` | - |
| `waddr` | input | 4 | host write address; only 0 (TX FIFO) does anything, other addresses are ignored | - | `clk` | - |
| `wdata` | input | 8 | byte pushed into the TX FIFO when `wen` and `waddr` = 0 and the FIFO is not full | - | `clk` | - |
| `ren` | input | 1 | host read strobe; has no side effect, only gates `irq` | high | `clk` | - |
| `raddr` | input | 4 | RX ring entry to read | - | comb. | - |
| `rdata` | output | 8 | `rxq[raddr]`, combinational; the ring is not reset, so an entry never written reads X | - | comb. | X |
| `count` | output | 5 | number of bytes captured, modulo 32 (`rx_wr`); the next byte goes to entry `count[3:0]` | - | `clk` | 0 |
| `irq` | output | 1 | `count != 0 && ren`, combinational | high | comb. | 0 |

### Internal signals used by the verification

The TB and the checker read these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `txen_q` | 1 | the flop that drives `tx_en` (the TB's two-state "TX FSM": idle / sending) |
| `tx_full` | 1 | TX FIFO full as seen from the `clk` domain (§3.1); host writes are dropped while it is 1 |
| `rxq` | 8 x `DEPTH` | the RX capture ring, entry *i* is what `rdata` returns for `raddr` = *i* |
| `rx_wr` | 5 | RX write pointer and capture count; `count` is this flop |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/GMII.md`](../ip/GMII.md) (source: `scripts/apb/specs/GMII.json`); do not edit by hand.

`GMII_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_clk`, `txd`, `tx_en`, `tx_er`, `rx_clk`, `rxd`, `rx_dv`, `rx_er`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x474D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | RX capture count |
| 0x018 | TX | WO (core) | core | Byte to send (dropped while the 8-entry TX FIFO is full) (write-only) |
| 0x01C | RX0 | RO (core) | core | RX capture ring entry 0 |
| 0x020 | RX1 | RO (core) | core | RX capture ring entry 1 |
| 0x024 | RX2 | RO (core) | core | RX capture ring entry 2 |
| 0x028 | RX3 | RO (core) | core | RX capture ring entry 3 |
| 0x02C | RX4 | RO (core) | core | RX capture ring entry 4 |
| 0x030 | RX5 | RO (core) | core | RX capture ring entry 5 |
| 0x034 | RX6 | RO (core) | core | RX capture ring entry 6 |
| 0x038 | RX7 | RO (core) | core | RX capture ring entry 7 |
| 0x03C | RX8 | RO (core) | core | RX capture ring entry 8 |
| 0x040 | RX9 | RO (core) | core | RX capture ring entry 9 |
| 0x044 | RX10 | RO (core) | core | RX capture ring entry 10 |
| 0x048 | RX11 | RO (core) | core | RX capture ring entry 11 |
| 0x04C | RX12 | RO (core) | core | RX capture ring entry 12 |
| 0x050 | RX13 | RO (core) | core | RX capture ring entry 13 |
| 0x054 | RX14 | RO (core) | core | RX capture ring entry 14 |
| 0x058 | RX15 | RO (core) | core | RX capture ring entry 15 |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x05C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x474D | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 4:0 | `count` | RO | core | bytes captured (wraps at 32); entry count mod 16 is written next |
| TX | 7:0 | core register | WO (core) | core | written at core register 0 |
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

1. Release PRESETN. Read ID (0x000) and check it is 0x474D0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `count`; it needs no clearing.
5. Access the core's registers through the CORE words (0x018 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Host write into the TX FIFO

The TX FIFO has 8 entries with 4-bit binary and Gray pointers (one wrap bit); each domain sees
the other's Gray pointer through a 2-flop synchronizer.

- At a `clk` edge with `wen` = 1, `waddr` = 0 and `tx_full` = 0: the byte `wdata` is stored at
  entry `tw_bin[2:0]` and the write pointer advances. With `tx_full` = 1 the write is dropped
  silently (nothing is stored and no flag records it). `wen` with any other `waddr` is ignored.
- `tx_full` compares the write pointer with the read pointer as synchronized into `clk`, so it
  is pessimistic: it can stay 1 for up to 2 `clk` cycles after the TX side has already freed an
  entry, but it is never 0 while the FIFO really holds 8 bytes.
- Back-to-back writes, one per `clk`, are allowed; the 9th byte written before any has been
  drained is dropped. Because `tx_clk` is usually slower than `clk`, a burst of more than 8
  writes loses bytes; software paces by writing at most 8 bytes per drain.

### 3.2 Transmit

At each `tx_clk` edge the TX side compares its read pointer with the write pointer as
synchronized into `tx_clk` (2 flops):

- FIFO not empty: `txd` <= the oldest byte, `tx_en` <= 1, read pointer advances.
- FIFO empty: `tx_en` <= 0; `txd` keeps its last value.

So a byte written at a `clk` edge reaches `txd`/`tx_en` at the third `tx_clk` edge after the
write (two synchronizer stages, then the output flop), give or take one `tx_clk` for the
sampling of the asynchronous pointer. Bytes written while the FIFO is non-empty are sent on
consecutive `tx_clk` cycles with `tx_en` held high; a byte that arrives after the FIFO has run
dry is sent after a gap of one or more `tx_clk` cycles with `tx_en` low. Bytes are sent in
write order and none is sent twice or skipped (checker `a_tx_byte_order`).

### 3.3 Receive capture

At every `clk` edge: `rxclk_s <= rx_clk`, `rxclk_d <= rxclk_s`, `rxdv_s <= rx_dv`,
`rxd_s <= rxd`. An `rx_clk` rising edge is detected at a `clk` edge where `rxclk_s && !rxclk_d`;
at that edge, if `rxdv_s` = 1, `rxq[rx_wr[3:0]] <= rxd_s` and `rx_wr` increments (5 bits,
wraps at 32).

`rxd` and `rx_dv` are sampled at the same `clk` edge as the first synchronizer stage of
`rx_clk`, so the byte captured for a rising edge is the value present at the first `clk` edge
at which `rx_clk` reads high. The source must hold `rxd`/`rx_dv` stable across that edge; in
the TB loopback (`rx_clk` = `tx_clk`, `rxd` = `txd`, `rx_dv` = `tx_en`) that is the byte
launched by the same `tx_clk` rising edge. Each `rx_clk` level must last at least 2 `clk`
periods to be seen (the TB uses a 10 ns `clk` and an 80 ns `tx_clk`).

`count` is `rx_wr` and changes by at most 1 per `clk`. The ring is written at
`rx_wr[3:0]`, so after 16 bytes the oldest entries are overwritten; there is no overrun flag.

### 3.4 Host read

`rdata = rxq[raddr]` and `irq = (rx_wr != 0) && ren` are combinational. Reading does not
consume or clear anything; software tracks which entries are new from `count`.

### 3.5 Reset

`rst_n` low, in both domains at once: both TX pointers and their synchronizers to 0 (any byte
still in the FIFO is discarded and never sent), `txd` = 0x00, `tx_en` = 0, RX synchronizers and
`rx_wr` to 0, so `count` = 0 and `irq` = 0. The FIFO and ring storage are not reset.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DEPTH` | 16 | 16 | size of the RX ring `rxq`. The write index is `rx_wr[3:0]` and the read index `raddr[3:0]`, so only 16 is consistent: smaller values index past the array, larger ones leave entries that are never used |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| host write while the TX FIFO is full | dropped silently; bytes already queued are sent intact (§3.1) |
| host write to `waddr` != 0 | ignored |
| `rx_er` = 1 during reception | ignored; the byte is captured as usual |
| more than 16 bytes received without reading | ring wraps and overwrites the oldest entries; `count` keeps counting mod 32 |
| `rx_dv` = 0 at an `rx_clk` rising edge | nothing is captured |
| reset with bytes still queued for transmit | the bytes are discarded; `tx_en` stays low after reset (§3.5) |
| `rx_clk` level shorter than 2 `clk` periods | the edge may be missed: no capture for that byte |

## 6. TB check map

Messages are printed by `tb/GMII_tb.sv` as `ERROR: <message>` (A1..A6 as `SVA_FAIL:`); "CRV"
messages and A1..A6 are built only for Verilator. Assertions a_* are in `tb/cov/GMII_sva.sv`.
All TB checks run in loopback (`rx_clk` = `tx_clk`, `rxd` = `txd`, `rx_dv` = `tx_en`).

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "GMII rxq[" | 8 bytes written, looped back, captured in order in ring entries 0..7 | §3.1, §3.2, §3.3 |
| "CRV burst" | 120 random bursts of 1..8 bytes (00/FF corners, stray writes to other addresses, `rx_er` pulses) read back in random order from `rxq[(base+i) % 16]` | §3.3, §5 |
| "GMII overflow" | 12 back-to-back writes: some but not all 12 bytes are sent (FIFO fills, later writes dropped) | §3.1 |
| "GMII overflow byte" | the first 8 of those bytes arrive intact and in order | §3.1, §3.2 |
| "GMII not idle in reset" | during reset `count` = 0 and `tx_en` = 0 | §3.5 |
| "GMII sent queued bytes after reset" | bytes queued before reset are never sent | §3.5 |
| "GMII class byte" | 00, FF, 55, AA pass end to end | §3.2, §3.3 |
| "A1 reset: count cleared" | `count` = 0 in reset | §3.5 |
| "A2 tx_er tied low" | `tx_er` = 0 always | §1 |
| "A3 count steps <=1" | `count` advances by 0 or 1 per `clk` | §3.3 |
| "A4 irq implies ren & data" | `irq` only with `ren` and `count` != 0 | §3.4 |
| "A5 rdata is rxq[raddr]" | combinational ring read | §3.4 |
| "A6 count is rx_wr" | `count` is the ring write pointer | §3.3 |
| a_reset_idle | in reset `count` = 0 and `tx_en` = 0 | §3.5 |
| a_tx_er_low | `tx_er` = 0 always | §1 |
| a_tx_byte_order | every `tx_en` cycle carries the next accepted host byte, in order, none sent from an empty FIFO | §3.1, §3.2 |
| a_full_means_backlog | `tx_full` only while at least 4 accepted bytes have not yet appeared on `txd` (bounds the pessimism of the synchronized full flag) | §3.1 |
| a_rx_count_model | `count` equals an independent oversampling model of §3.3 | §3.3 |
| a_rx_read_model | for a written entry, `rdata` matches the model ring | §3.3, §3.4 |
| a_irq_model | `irq` = (model count != 0) && `ren` | §3.4 |
