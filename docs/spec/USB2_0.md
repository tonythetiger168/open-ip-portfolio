<!-- SPDX-License-Identifier: Apache-2.0 -->
# USB2_0: design specification

A USB 2.0 full-speed line-level packet engine in echo mode: it receives a frame and sends it back
after a turnaround. Not implemented: device framework (no addresses, endpoints, handshakes or
token / data PID semantics), token CRC5, high-speed chirp and HS signalling, suspend / resume,
low speed. Core `USB2_0_top` (`rtl/USB2_0_top.sv`), testbench `tb/USB2_0_tb.sv` (the TB is the
host, with an FS pull-up on D+), checker `tb/cov/USB2_0_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A bit lasts 2 x `BAUD_DIV` clocks. J = D+ high / D- low, K = the
opposite, SE0 = both low. NRZI: a 0 is a transition, a 1 none. Bytes go LSB first.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `dp` | inout | 1 | D+ (driven while transmitting, else released; the bus pull-up holds J) | - | `clk` | Z |
| `dm` | inout | 1 | D- | - | `clk` | Z |
| `busy` | output | 1 | receiving or transmitting; combinational from flops | high | `clk` | 0 |
| `rx_err` | output | 1 | sticky: a frame was received in error (cleared only by reset) | high | `clk` | 0 |
| `irq` | output | 1 | one-clock pulse: a good frame was received | high | `clk` | 0 |

### Internal signals used by the verification

The checker is bound with `.*` and reads these; the FSM coverage collector binds `rstate` and
`tstate`.

| Signal | Width | Meaning |
|---|---|---|
| `rstate` | 3 | receiver: 0 IDLE, 1 SYNC, 2 PACKET, 3 EOP, 4 WAIT (idle hunt after an error) |
| `tstate` | 3 | transmitter: 0 IDLE, 1 TURNAROUND, 2 PACKET, 3 EOP SE0, 4 EOP J |
| `rsamp` | 1 | receive sample point (mid-bit); combinational |
| `line_j` | 1 | synchronised line is J; combinational |
| `line_k` | 1 | synchronised line is K; combinational |
| `line_se0` | 1 | synchronised line is SE0; combinational |
| `oe_q` | 1 | the engine drives D+ / D- |
| `tedge` | 1 | last clock of a transmit bit; combinational |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/USB2_0.md`](../ip/USB2_0.md) (source: `scripts/apb/specs/USB2_0.json`); do not edit by hand.

`USB2_0_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `dp`, `dm`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55320200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Engine state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5532 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `busy` | RO | core | receiving or echoing a frame |
| STATUS | 1 | `rx_err` | RO | core | a frame was received in error (SYNC, stuffing, PID check, length, alignment, CRC or EOP); held until reset |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ECHO | a good frame was received (its echo follows) |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55320200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `busy`, `rx_err`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Frame

SYNC (KJKJKJKK: seven 0s and a 1), PID (low nibble, then its inverse), 0..`MAXB` payload bytes,
CRC16 (x^16 + x^15 + x^2 + 1, seed 0xFFFF, LSB first, sent inverted) over the payload, then EOP
(SE0 then J). After six 1s in a row, counted from SYNC on, a 0 is stuffed.

### 3.2 Receiver

D+ and D- pass two flops. A bit clock restarts at every line change and samples at mid-bit
(`BAUD_DIV` - 1 clocks after the change, every 2 x `BAUD_DIV` clocks without one).

* IDLE: a K sample (with the transmitter idle) is the first SYNC bit.
* SYNC: further 0s are counted; a 1 after at least five 0s (the first K included) ends SYNC.
  A 1 earlier, or SE0, is an error.
* PACKET: a bit after six 1s must be a 0 and is dropped (a 1 is a stuff error). The first byte
  must have high nibble = ~low nibble. Every bit after the PID goes into the CRC. More than PID +
  `MAXB` + 2 bytes is an error. SE0 ends the packet.
* EOP: at the first J sample the frame is good if it ended on a byte boundary, has at least 3
  bytes (PID and CRC) and the CRC residual is 0xB001: `irq` pulses one clock later. Otherwise, or
  on a K, it is an error.

An error sets `rx_err` (sticky), drops the frame, and the receiver waits for 8 J samples in a row
before it hunts again.

### 3.3 Transmitter (echo)

When a good frame is received, the engine waits 3 bit times (turnaround, counted from the clock
after `irq`), then drives the bus: SYNC, the received PID and payload, the inverted CRC16, with
NRZI and bit stuffing (a stuff bit after the last CRC bit is still sent), then 2 bit times SE0, 1
bit time J, and releases the lines. While the engine transmits the receiver does not start a
frame. D+ and D- are never both high.

### 3.4 Reset

While `rst_n` is low: both sides idle, lines released, `rx_err` 0.

## 4. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `BAUD_DIV` | 20 | clocks per half bit (a bit is 2 x `BAUD_DIV`) |
| `MAXB` | 8 | largest payload, bytes |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| SE0 in SYNC, or SYNC with fewer than five 0s | `rx_err`, no echo |
| stuff error, PID check error, too long, not byte aligned at EOP, CRC wrong, K after the EOP SE0 | `rx_err`, no echo |
| frame of only PID + CRC | echoed with no payload |
| truncated SYNC (five or six 0s) | accepted |
| reset during an echo | lines released at once |

## 6. TB check map

Messages are printed by `tb/USB2_0_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/USB2_0_sva.sv`. The host BFM sends good frames of every length and frames with
each error kind (by mode number); a host decoder checks every echo.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "no echo for pid" | good frames are echoed | §3.3 |
| "turnaround" | echo starts 2..6.5 bits after the EOP | §3.3 |
| "echo SYNC bit" | SYNC sent | §3.1, §3.3 |
| "SE1 on bus" | never both lines high | §3.3 |
| "echo missing stuff bit" | stuffing | §3.1 |
| "echo PID check" | PID with its inverse | §3.1 |
| "echo EOP SE0" | two bits SE0 | §3.3 |
| "echo EOP not J" | then J | §3.3 |
| "echo not byte aligned" | whole bytes | §3.3 |
| "echo CRC16 residual" | CRC | §3.1 |
| "echo pid" | the received PID | §3.3 |
| "echo len" | the received length | §3.3 |
| "echo byte" | the received payload | §3.3 |
| "irq count" | one `irq` per good frame | §3.2 |
| "busy after echo" | idle after the echo | §3.3 |
| "mode" | each error kind sets `rx_err`, no echo, not stuck | §3.2, §5 |
| "reset state" | reset values | §3.4 |
| "rx_err after good frames" | good frames do not set it | §3.2 |
| "short frame rx_err not set" | a frame under 3 bytes is an error | §3.2 |
| "reset during echo" | reset releases the bus | §3.4 |
| "no echo ended with a stuff bit" | coverage: a stuff bit right before the EOP | §3.3 |
| a_reset_idle | reset values | §3.4 |
| a_irq_model | `irq` as the model | §3.2 |
| a_rx_err_model | `rx_err` as the model | §3.2 |
| a_busy_model | `busy` as the model | §3.2, §3.3 |
| a_no_se1 | never both lines high | §3.3 |
| a_tx_sync | SYNC bits | §3.3 |
| a_tx_stuffing | stuffing | §3.1 |
| a_tx_eop | EOP shape | §3.3 |
| a_tx_echo | echoed bits | §3.3 |
| a_no_tx_while_rx | no driving while receiving | §3.3 |
| a_irq_pulse | `irq` lasts one clock | §3.2 |
