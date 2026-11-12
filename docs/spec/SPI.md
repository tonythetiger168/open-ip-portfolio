<!-- SPDX-License-Identifier: Apache-2.0 -->
# SPI: design specification

SPI target (slave), mode 0 (CPOL = 0, CPHA = 0), MSB first, 8-bit frames, oversampled: the
SPI pins are sampled by the system clock `clk`, so `sclk` must be much slower than `clk`.
A small local port (`wen`/`waddr`/`wdata`, `raddr`/`rdata`) loads the byte to send and reads
the byte received. Core `SPI_top` (`rtl/SPI_top.sv`), testbench `tb/SPI_tb.sv`, checker
`tb/cov/SPI_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. "Sampled at edge *n*" means the value an input had just before
rising edge *n* of `clk`.

## 1. Interface

`sclk`, `mosi` and `csn` are sampled directly by `clk` (no synchroniser flops); the master must
keep them stable around `clk` edges as a synchronous input would (in the TB they change between
edges). `miso` is combinational.

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | system clock; samples the SPI pins | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of every flop | low | async assert | - |
| `sclk` | input | 1 | SPI clock from the master; idles low (CPOL = 0) | rising edge = capture | sampled by clk | - |
| `mosi` | input | 1 | data from the master, MSB first; captured at each detected `sclk` rising edge | - | sampled by clk | - |
| `miso` | output | 1 | data to the master: `csn` = 1 → high-Z; `csn` = 0 → `tx_q[7 - bit_cnt]` (combinational) | - | comb. | Z if `csn` = 1, else 0 |
| `csn` | input | 1 | chip select; low selects this target, high aborts a byte and resets the bit counter | low | sampled by clk (also gates `miso` directly) | - |
| `wen` | input | 1 | local write strobe, one write per clock | high | clk | - |
| `waddr` | input | 4 | local write address: only 0 (TX byte) is writable; others are ignored | - | clk | - |
| `wdata` | input | 8 | local write data | - | clk | - |
| `ren` | input | 1 | local read strobe; unused (reads have no side effect, `rdata` is valid regardless of `ren`) | high | - | - |
| `raddr` | input | 4 | local read address: 0 = RX shift register, 1 = TX byte, others read 0 | - | comb. | - |
| `rdata` | output | 8 | local read data, combinational from `raddr` | - | comb. | 0x00 |
| `irq` | output | 1 | one-clock pulse after every 8th captured bit (byte done) | high | clk | 0 |

Internal state: `tx_q` (8 bits, TX byte), `rx_q` (8 bits, RX shift register), `bit_cnt`
(3 bits), `sclk_d` (previous `sclk` sample), `byte_done` (drives `irq`). All reset to 0.

### Internal signals used by the verification

The TB and the bound checker read these core-internal signals by name; a re-implementation
must have them, with these names and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `tx_q` | 8 | TX byte register (§3.2) |
| `bit_cnt` | 3 | bits captured in the current byte, 0..7 (§3.1) |

## 2. Registers

The core's own local port has two locations (table below). The generated APB4 wrapper
`SPI_apb` maps them as TX (0x014) and RX (0x018) and latches `irq` into IRQ_STATUS.

| Local address | Read (`raddr`) | Write (`waddr`, `wen`) |
|---|---|---|
| 0 | `rx_q`: the RX shift register, live (holds the complete byte once `irq` pulsed) | `tx_q` <= `wdata` |
| 1 | `tx_q` | ignored |
| 2..15 | 0x00 | ignored |

<!-- AUTO:registers -->
Generated from [`docs/ip/SPI.md`](../ip/SPI.md) (source: `scripts/apb/specs/SPI.json`); do not edit by hand.

`SPI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `mosi`, `miso`, `csn`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW (core) | core | Byte shifted out on MISO in the next transfer |
| 0x018 | RX | RO (core) | core | Last byte shifted in on MOSI |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x01C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5350 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX | 7:0 | core register | RW (core) | core | written at core register 0 and read from core register 1 |
| RX | 7:0 | core register | RO (core) | core | read from core register 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BYTE | a byte was received (eighth SCLK rising edge) |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53500200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Edge detection and capture

At every `clk` edge: `sclk_d <= sclk`. A *rising edge* is detected at `clk` edge E when `sclk`
sampled at E is 1, `sclk_d` is 0 (it was 0 at edge E-1) and `csn` sampled at E is 0. At that
edge E:

- `rx_q <= {rx_q[6:0], mosi}` (`mosi` sampled at E; first bit ends up in bit 7 after 8 bits);
- if `bit_cnt` = 7: `bit_cnt <= 0` and `byte_done <= 1`; else `bit_cnt <= bit_cnt + 1`.

`byte_done` is 0 at every other edge, so `irq` is high for exactly the one clock after the edge
that captured the 8th bit. Falling `sclk` edges do nothing.

`sclk` must be high for at least one `clk` sample and low for at least one sample between
rising edges (two or more clocks each is recommended; the TB uses 4 clocks high and 4 low).

### 3.2 MISO

`miso = csn ? 1'bz : tx_q[7 - bit_cnt]`. Consequences:

- When `csn` falls, `miso` immediately shows `tx_q[7]` (bit_cnt is 0 between frames).
- After the edge that captures bit *k* (counting from 0), `bit_cnt` = k+1 and `miso` shows
  `tx_q[6 - k]`, i.e. MISO moves to the next bit one `clk` after the detected rising `sclk` edge,
  long before the next rising edge. A mode-0 master that samples `miso` at its rising `sclk`
  edge (before the target's `clk` has detected it) gets bits 7, 6, ..., 0 of `tx_q`.
- `tx_q` is not shifted or consumed: the same byte is sent again in every following byte and
  frame until it is rewritten.
- A write to `tx_q` in the middle of a byte changes `miso` from the clock after the write
  edge: the remaining bits come from the new value at the current `bit_cnt` position.

### 3.3 Frames and CSn

- If `csn` is sampled 1 at an edge, `bit_cnt <= 0` (this wins over an increment) and rising
  `sclk` edges are not captured. `rx_q` keeps its contents.
- Several bytes may be sent under one `csn` low: `bit_cnt` wraps 7 → 0 and `irq` pulses after
  every byte.
- `csn` going high after 1..7 bits aborts the byte: no `irq`; the partial bits stay shifted
  into `rx_q` (they are pushed out by the next full byte); the next frame starts with
  `tx_q[7]`.
- `sclk` toggling while `csn` is high has no effect (only `sclk_d` follows it).

### 3.4 Local port

- Write: at an edge with `wen` = 1 and `waddr` = 0, `tx_q <= wdata`. `ren` is ignored.
- Read: `rdata` is combinational: `raddr` = 0 → `rx_q`, 1 → `tx_q`, else 0x00. Reading has no
  side effect; `rx_q` is the live shift register, so it is a complete byte only between a byte's
  `irq` and the next captured bit.

### 3.5 Reset

`rst_n` low clears `tx_q`, `rx_q`, `bit_cnt`, `sclk_d` and `byte_done` at once: `irq` = 0,
`rdata` = 0 for every `raddr`, `miso` = 0 if selected (Z otherwise). A byte in progress is lost.
Because `sclk_d` resets to 0, an `sclk` that is high with `csn` low at reset release is
detected as a rising edge at the first edge.

## 4. Parameters

The core has no parameters.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `csn` high mid-byte (abort) | `bit_cnt` cleared at the next edge, no `irq`, partial bits remain in `rx_q`; the next frame is clean |
| write or read at an unmapped local address | write ignored (no effect on `tx_q`), read returns 0x00 |
| `tx_q` written during a transfer | new value appears on `miso` from the current bit position on (§3.2) |
| host does not read `rx_q` | no overrun flag; the register keeps shifting |
| `sclk` while deselected | ignored |
| reset mid-byte | §3.5 |

## 6. TB check map

Messages are printed by `tb/SPI_tb.sv` as `ERROR: <message>`; messages starting "CRV" and the
immediate checks A1..A7 are built only for Verilator (`ifdef VERILATOR`). Assertions a_* are in
`tb/cov/SPI_sva.sv`, an independent shift model of the core.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "SPI MISO xfer1" | the byte written to TX before a frame (0x3C) comes out on `miso`, MSB first | §3.2 |
| "SPI MISO xfer2" | `tx_q` is not consumed: the next frame sends 0x3C again | §3.2 |
| "SPI MOSI" | after a frame, `rdata` at `raddr` 0 is the byte sent on `mosi` | §3.1, §3.4 |
| "SPI irq pulses" | one `irq` pulse per 8-bit frame | §3.1 |
| "SPI sweep MISO" | every TX byte class (00, FF, AA, 3C) with every RX class goes out unchanged | §3.2 |
| "SPI sweep MOSI" | every RX byte class lands in `rx_q` unchanged | §3.1 |
| "SPI abort" | after a `csn` abort at bit 1..7, the next frame sends `tx_q` from bit 7 and receives a clean byte | §3.3 |
| "SPI 2-byte frame rx" | 16 bits under one `csn`: `rx_q` holds the last 8 bits | §3.3 |
| "SPI deselected SCLK shifted rx" | `sclk` pulses with `csn` high do not shift `rx_q` | §3.3 |
| "SPI not idle in reset" | in reset `irq` = 0 and `rdata` = 0 | §3.5 |
| "CRV MISO" | random TX byte comes out on `miso` | §3.2 |
| "CRV MOSI" | random MOSI byte lands in `rx_q` | §3.1 |
| "CRV post-abort MISO" | after a random abort, the next frame sends the full TX byte | §3.3 |
| "CRV post-abort MOSI" | after a random abort, the next frame's byte is received clean | §3.3 |
| "CRV illegal addr" | read at address 2..15 returns 0 | §3.4, §5 |
| "CRV illegal write clobbered tx_q" | a write at address 2..15 does not change `tx_q` | §3.4, §5 |
| "A1 reset: irq low" | `irq` = 0 in reset | §3.5 |
| "A2 rdata never X/Z" | `rdata` is never X/Z out of reset | §3.4 |
| "A3 raddr1 reads tx_q" | `raddr` = 1 reads `tx_q` | §3.4 |
| "A4 irq single-cycle pulse" | `irq` is never high two clocks in a row | §3.1 |
| "A5 bit_cnt clear under csn" | the clock after `csn` was high, `bit_cnt` = 0 | §3.3 |
| "A6 miso bit select / high-Z" | `miso` = `tx_q[7 - bit_cnt]` when selected, Z otherwise | §3.2 |
| "A7 illegal addr reads 0" | `raddr` > 1 reads 0 | §3.4 |
| a_reset_idle | in reset: `irq` = 0, `rdata` = 0, `miso` = 0 or deselected | §3.5 |
| a_miso_model | while selected, `miso` = model `tx[7 - bit]` | §3.2 |
| a_read_mux | `rdata` = `rx_q` / `tx_q` / 0 by `raddr` | §3.4 |
| a_irq_byte_done | `irq` is high exactly the clock after the 8th captured bit | §3.1 |
| a_csn_resets_count | the clock after `csn` high, a selected `miso` shows `tx_q[7]` | §3.3 |
