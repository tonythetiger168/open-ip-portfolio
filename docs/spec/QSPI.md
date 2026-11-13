<!-- SPDX-License-Identifier: Apache-2.0 -->
# QSPI: design specification

SPI target (slave), mode 0, 8-bit frames, in standard (1-bit: IO0 = MOSI, IO1 = MISO) or quad
(4-bit, IO[3:0], high nibble first) mode. In quad mode a direction bit selects whether the
target drives IO[3:0] (quad read) or releases them (quad write). The SPI pins are oversampled by
`clk`. A local port loads the TX byte, the mode and the direction, and reads the RX byte. Core
`QSPI_top` (`rtl/QSPI_top.sv`), testbench `tb/QSPI_tb.sv`, checker `tb/cov/QSPI_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. "Sampled at edge E" means the value just before E.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | system clock; samples SCLK, CSn and IO | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of every flop | low | async assert | - |
| `sclk` | input | 1 | SPI clock, idles low (mode 0) | - | sampled by clk (no sync) | - |
| `csn` | input | 1 | chip select; high clears the bit / nibble counters and the output phase | low | sampled by clk | - |
| `io` | inout | 4 | std: `io[0]` = MOSI (input), `io[1]` = MISO (driven); quad: IO[3:0], driven by the target when `dir` = 0, released when `dir` = 1. Driving does **not** depend on `csn` (§3.4) | - | drive comb.; sampled by clk | std: `io[1]` = 0, others Z |
| `wen` | input | 1 | local write strobe | high | clk | - |
| `waddr` | input | 4 | 0 = TX byte, 2 = mode (`wdata[1:0]`, 0 = std, any other value = quad), 3 = direction (`wdata[0]`); others ignored | - | clk | - |
| `wdata` | input | 8 | local write data | - | clk | - |
| `ren` | input | 1 | unused (reads have no side effect) | high | - | - |
| `raddr` | input | 4 | 0 = RX byte, 1 = TX byte, others read 0 | - | comb. | - |
| `rdata` | output | 8 | local read data, combinational | - | comb. | 0x00 |
| `irq` | output | 1 | one-clock pulse after each complete byte (8 std bits or 2 quad nibbles) | high | clk | 0 |

### Internal signals used by the verification

| Signal | Width | Meaning |
|---|---|---|
| `tx_q` | 8 | TX byte register |
| `mode` | 2 | mode register; std when 0 |
| `bit_cnt` | 3 | std bits captured in the current byte |
| `qcnt` | 1 | quad nibbles captured in the current byte (0 or 1) |
| `io_oe` | 4 | per-pin output enable: std `4'b0010`; quad with `dir` = 0 `4'b1111`; quad with `dir` = 1 `4'b0000` |

Other state: `rx_q`, `dir`, `sclk_d`, `started` (a falling SCLK edge has occurred in this frame),
`io_out` (registered output bits), `byte_done`.

## 2. Registers

| Local address | Read (`raddr`) | Write (`waddr`) |
|---|---|---|
| 0 | `rx_q` (live shift register) | `tx_q` |
| 1 | `tx_q` | ignored |
| 2 | 0x00 | `mode` <= `wdata[1:0]` |
| 3 | 0x00 | `dir` <= `wdata[0]` |
| 4..15 | 0x00 | ignored |

All reset to 0 (std mode, `dir` = 0). The APB4 wrapper `QSPI_apb` maps these below.

<!-- AUTO:registers -->
Generated from [`docs/ip/QSPI.md`](../ip/QSPI.md) (source: `scripts/apb/specs/QSPI.json`); do not edit by hand.

`QSPI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `csn`, `io`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x51530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW (core) | core | Byte shifted out (MISO in standard mode, io[3:0] in a quad read) |
| 0x018 | RX | RO (core) | core | Last byte shifted in |
| 0x01C | MODE | WO (core) | core | Bits 1:0: 0 standard, otherwise quad (write-only) |
| 0x020 | DIR | WO (core) | core | Bit 0, quad mode: 0 the slave drives io[3:0] (read), 1 it releases them (write) (write-only) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5153 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX | 7:0 | core register | RW (core) | core | written at core register 0 and read from core register 1 |
| RX | 7:0 | core register | RO (core) | core | read from core register 0 |
| MODE | 7:0 | core register | WO (core) | core | written at core register 2 |
| DIR | 7:0 | core register | WO (core) | core | written at core register 3 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BYTE | a byte was received (eight standard or two quad SCLK rising edges) |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x51530200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Edges

At every edge `sclk_d <= sclk`. A rising edge is detected at clock edge E when `sclk` sampled at E
is 1, `sclk_d` is 0 and `csn` sampled at E is 0; a falling edge when `sclk_d` = 1, `sclk` = 0 and
`csn` = 0. `csn` = 1 at an edge clears `bit_cnt`, `qcnt` and `started` (wins over an increment).
SCLK must stay high and low for at least 2 clocks each (the TB uses 4).

### 3.2 Capture (rising edges)

- std: `rx_q <= {rx_q[6:0], io[0]}`; `bit_cnt` +1, and after the 8th bit `bit_cnt` <= 0 with
  `irq` the next clock.
- quad: `rx_q <= {rx_q[3:0], io[3:0]}` (high nibble first); `qcnt` toggles, and after the second
  nibble `irq` the next clock. The capture happens in both quad directions (in quad read the
  target captures its own drive).

### 3.3 Output (falling edges)

The value on the driven pins is `pin_out = started ? io_out : first_out`:

- Before the first falling SCLK edge of a frame (`started` = 0), `first_out` is combinational:
  std `io[1] = tx_q[7]`; quad `io[3:0] = tx_q[7:4]`. So a TX write just before CSn falls is
  presented at once.
- At each falling edge, `started` <= 1 and `io_out` <=: std `tx_q[7 - bit_cnt]` (`bit_cnt` was
  already advanced by the rising edge, so this is the next bit); quad `qcnt ? tx_q[3:0] : tx_q[7:4]`.
  The pins change one clock after the falling SCLK edge is detected, and are stable at the next
  rising edge, where the master samples them.
- `tx_q` is not consumed: each byte or frame sends it again; a write to it takes effect at the next
  falling edge (or at once while `started` = 0).

### 3.4 Pin direction

`io_oe` is a function of `mode` and `dir` only: std drives only IO1, quad read drives IO[3:0],
quad write drives nothing. The drive does not depend on `csn`: in std mode IO1 is always driven,
and in quad read mode IO[3:0] are always driven (with `first_out` while not started).

### 3.5 Reset

`rst_n` low: all flops 0, so std mode with IO1 driven (= `tx_q[7]` = 0), IO0/2/3 released,
`irq` = 0, `rdata` = 0.

## 4. Parameters

The core has no parameters.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| CSn high in the middle of a byte (abort) | counters and output phase cleared; the next frame is clean (both modes) |
| two bytes under one CSn (quad read) | `tx_q` sent twice |
| write to address 1 or 4..15 | ignored |
| read of address 2..15 | 0x00 |
| mode switched std ↔ quad | `tx_q` is kept; pin direction changes at once |
| `tx_q[4]` = 1 in std mode | does not drive IO0 (only IO1 is enabled; regression of a fixed bug) |

## 6. TB check map

Messages are printed by `tb/QSPI_tb.sv` as `ERROR: <message>`; "CRV" messages and A1..A7 are
built only for Verilator. Assertions a_* are in `tb/cov/QSPI_sva.sv`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "QSPI std MISO" | std frame returns `tx_q` (0x3C) on IO1 | §3.3 |
| "QSPI std MOSI (tx_q[4]=1)" | std MOSI byte captured while `tx_q[4]` = 1 (IO0 not driven by the target) | §3.4, §5 |
| "QSPI std MISO (tx_q[4]=1)" | and MISO returns 0x10 | §3.3 |
| "QSPI quad read" | quad read returns `tx_q` (0xA7), high nibble first | §3.3 |
| "QSPI quad write" | quad write (target released) captures 0x5A | §3.2, §3.4 |
| "QSPI 2-byte quad read" | two bytes under one CSn: 0xC4C4 | §3.3, §5 |
| "QSPI post-abort frame miso" | after an aborted std frame the next frame is clean | §5 |
| "QSPI std sweep miso" | std data classes both ways | §3.2, §3.3 |
| "QSPI quad-read sweep" | quad read data classes | §3.3 |
| "QSPI quad-write sweep" | quad write data classes | §3.2 |
| "QSPI abort" | std abort after 1..7 bits, then a clean frame | §3.1, §5 |
| "QSPI quad-read after abort" | quad read after a 1-nibble abort | §5 |
| "QSPI quad-write after abort" | quad write after a 1-nibble abort | §5 |
| "QSPI not idle in reset" | in reset `irq` = 0 and `io_oe` = 0010 | §3.5 |
| "CRV illegal addr" | unmapped reads return 0 | §2 |
| "CRV illegal write disturbed tx_q" | unmapped writes leave `tx_q` | §2 |
| "CRV std MISO" | random std MISO | §3.3 |
| "CRV std MOSI" | random std MOSI | §3.2 |
| "CRV quad read" | random quad reads | §3.3 |
| "CRV quad write" | random quad writes | §3.2 |
| "CRV std MOSI with tx_q[4]=1" | std MOSI with `tx_q[4]` = 1 | §3.4 |
| "CRV std MISO with tx_q[4]=1" | std MISO with `tx_q[4]` = 1 | §3.3 |
| "A1 reset: outputs quiescent" | in reset `irq` = 0, std pin enables | §3.5 |
| "A2 rdata never X/Z" | `rdata` defined | §2 |
| "A3 raddr1 reads tx_q" | address 1 reads `tx_q` | §2 |
| "A4 irq single-cycle pulse" | `irq` one clock | §3.2 |
| "A5 counters clear under csn" | the clock after CSn high: `bit_cnt` = `qcnt` = 0 | §3.1 |
| "A6 illegal addr reads 0" | `raddr` > 1 reads 0 | §2 |
| "A7 std mode drives MISO only" | std: `io_oe` = 0010 | §3.4 |
| a_reset_idle | in reset `irq` = 0, `io_oe` = 0010 | §3.5 |
| a_std_miso_bit | at a std rising edge IO1 = model `tx[7 - bit]` | §3.3 |
| a_quad_read_nibble | at a quad-read rising edge IO[3:0] = model nibble | §3.3 |
| a_quad_write_released | quad write: `io_oe` = 0000 | §3.4 |
| a_irq_byte_done | `irq` equals the model's byte-done | §3.2 |
| a_read_mux | `rdata` by `raddr` | §2 |
