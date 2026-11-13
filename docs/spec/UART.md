<!-- SPDX-License-Identifier: Apache-2.0 -->
# UART: design specification

8N1 UART transceiver: one start bit, 8 data bits LSB first, one stop bit, no parity, no FIFO.
TX takes a byte through a valid/ready handshake; RX oversamples the line 16 times per bit and
delivers each byte as a one-clock `rx_valid` pulse. Core `UART_top` (`rtl/UART_top.sv`),
testbench `tb/UART_tb.sv`, checker `tb/cov/UART_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. "Edge *n*" means a rising edge of `clk`; a register "set at
edge *n*" has its new value from edge *n* until the next edge. "Sampled at edge *n*" means
the value an input had just before edge *n*.

## 1. Interface

All ports are in the `clk` domain except `rxd`, which is asynchronous and goes through a
2-flop synchroniser.

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock, frequency `CLK_FREQ` | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of every flop | low | async assert; release synchronous to `clk` | - |
| `rxd` | input | 1 | serial receive line; idle level 1 | - | async (synchronised) | - |
| `txd` | output | 1 | serial transmit line; idle level 1; driven from a flop | - | clk | 1 |
| `tx_data` | input | 8 | byte to transmit; captured only at the accept edge (§3.2) | - | clk | - |
| `tx_valid` | input | 1 | `tx_data` is valid; may be held high while `tx_ready` is low | high | clk | - |
| `tx_ready` | output | 1 | transmitter idle, a byte can be accepted; combinational from the TX state (`state == TX_IDLE`), does not depend on `tx_valid` | high | clk | 1 |
| `rx_data` | output | 8 | last byte received without framing error; holds its value until the next good byte | - | clk | 0x00 |
| `rx_valid` | output | 1 | one-clock pulse: `rx_data` was updated at the same edge | high | clk | 0 |
| `irq` | output | 1 | `rx_valid` OR framing-error pulse (combinational OR of two flops) | high | clk | 0 |

There is no RX buffer and no overrun flag: a byte that is not consumed in the clock of its
`rx_valid` pulse stays readable on `rx_data` until the next good byte overwrites it.

### Internal signals used by the verification

The TB and the bound checker read these core-internal signals by name; a re-implementation
must have them, with these names and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `frame_err` | 1 | framing-error pulse flop: 1 for the one clock after a stop sample that read 0 (§3.3); `irq = rx_valid \| frame_err` |

## 2. Registers

The core has no registers of its own. The generated APB4 wrapper `UART_apb` maps the core's
ports onto the registers below (TXDATA drives `tx_data`/`tx_valid`, RXDATA captures
`rx_data` on `rx_valid`, IRQ_STATUS.CORE latches the core `irq`).

<!-- AUTO:registers -->
Generated from [`docs/ip/UART.md`](../ip/UART.md) (source: `scripts/apb/specs/UART.json`); do not edit by hand.

`UART_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxd`, `txd`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55410200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TXDATA | RW | 0x00000000 | Byte to transmit |
| 0x018 | RXDATA | RO (pop) | 0x00000000 | Received byte |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x01C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5541 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TXDATA | 7:0 | `tx_data` | RW | 0x0 | Byte to transmit |
| RXDATA | 7:0 | `rx_data` | RO (pop) | 0x0 | Received byte |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CORE | core irq: a byte was received or a framing error occurred |
| 1 | TXDATA_DONE | TXDATA beat accepted by the core |
| 2 | TXDATA_OVF | write to TXDATA while full (dropped) |
| 3 | RXDATA_AVAIL | RXDATA captured a beat |
| 4 | RXDATA_OVF | beat dropped, RXDATA was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TXDATA_FULL | TXDATA holds a beat the core has not taken |
| 1 | RXDATA_AVAIL | RXDATA holds an unread beat |

### Streams

* **TXDATA** feeds `tx_data`/`tx_valid`. Writing TXDATA commits the beat: FLAGS.TXDATA_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TXDATA_DONE is set. A write while full is dropped and sets TXDATA_OVF.
* **RXDATA** captures `rx_data` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RXDATA_AVAIL. Reading RXDATA pops it. A beat that arrives while the register is full is dropped and sets RXDATA_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55410200.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
4. To send on TXDATA: wait until FLAGS.TXDATA_FULL (bit 0) is 0, or for IRQ TXDATA_DONE, then write TXDATA (0x014). The last write commits the beat. TXDATA_OVF means a write came while the register was full and was dropped.
5. To receive on RXDATA: wait for IRQ RXDATA_AVAIL or FLAGS.RXDATA_AVAIL (bit 1), then read RXDATA (0x018). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RXDATA_AVAIL (bit 3) to clear it. Read each beat before the next arrives, or it is dropped and RXDATA_OVF is set.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Baud tick

`DIV16 = (CLK_FREQ / BAUD) / 16` (integer divisions, truncating). A counter `div_cnt`
runs 0, 1, ..., DIV16-1, 0, ... from reset and is never restarted by TX or RX. The strobe
`tick16` is a flop: it is set to 1 at the edge where `div_cnt` wraps from DIV16-1 to 0 and to
0 at every other edge. So, counting edges after reset release from 1, `tick16` is high
during the clock after edges DIV16, 2·DIV16, 3·DIV16, ..., and a state machine that tests
`tick16` sees it at edges DIV16+1, 2·DIV16+1, ... ("tick edges"). One bit lasts exactly 16
tick periods = 16·DIV16 clocks (with the TB's 50 MHz / 1 MBd: DIV16 = 3, 48 clocks per bit;
the truncation makes the real baud rate slightly higher than `BAUD`).

Both TX and RX count tick edges *after* the edge that started them; a tick at the starting
edge itself is not counted. Because the tick is free-running, the first count of a frame
comes 1 to DIV16 clocks after the start, so the first bit (start bit) may be up to DIV16-1
clocks shorter than 16·DIV16; all later bits are exactly 16·DIV16 clocks.

### 3.2 Transmitter

States TX_IDLE, TX_START, TX_DATA, TX_STOP; `tx_ready = (state == TX_IDLE)`.

| Event | Edge | Effect at that edge |
|---|---|---|
| accept | edge A where `tx_valid` = 1 and state = TX_IDLE | `tx_data` captured into the shift register; `txd` <= 0 (start bit); state <= TX_START, so `tx_ready` is 0 from edge A on |
| data bit k (k = 0..7) | 16·(k+1)-th tick edge after A | `txd` <= bit k of the captured byte |
| stop bit | 144th tick edge after A | `txd` <= 1; state <= TX_STOP |
| done | 160th tick edge after A | state <= TX_IDLE, `tx_ready` = 1 |

- `tx_ready` is low from edge A until the 160th tick edge; while it is low, `tx_valid` and
  `tx_data` are ignored (the byte is not taken; a held `tx_valid` is simply waited on).
- Back to back: if `tx_valid` is high when `tx_ready` returns, the next byte is accepted at the
  next edge, and its start bit begins there. The stop bit therefore lasts 16 tick periods
  plus at least one clock.
- `txd` changes only at the edges listed above; it is never X and is 1 whenever idle.

### 3.3 Receiver

Synchroniser: at every edge `rxd_s <= rxd` and `rxd_d <= rxd_s` (both reset to 1). A start
edge is `rxd_d == 1 && rxd_s == 0` (the synchronised line just fell); it is looked for only
in RX_IDLE. All RX samples use `rxd_s`, i.e. `rxd` as sampled one edge earlier.

| Event | Edge (tick edges counted after the start-detect edge S) | Effect |
|---|---|---|
| start detect | edge S: state RX_IDLE and start edge seen | state <= RX_START |
| start re-check | 8th tick edge | `rxd_s` = 1: glitch, state <= RX_IDLE, nothing is output. `rxd_s` = 0: state <= RX_DATA |
| data bit i (i = 0..7) | tick edge 24 + 16·i | `rxd_s` shifted in as bit i (LSB first) |
| stop sample | tick edge 152 | state <= RX_IDLE. `rxd_s` = 1: `rx_data` <= byte and `rx_valid` <= 1. `rxd_s` = 0: framing-error pulse <= 1, `rx_data` unchanged |

- `rx_valid` and the framing-error flop are 1 for exactly the one clock after the stop-sample
  edge and 0 otherwise; `irq` is their OR, so it is a one-clock pulse for each good byte and for
  each framing error. A framing error never raises `rx_valid`.
- A low pulse on `rxd` that is high again at the start re-check (shorter than about half a
  bit) is a glitch: no byte, no `irq`.
- The receiver hunts for the next start edge from the stop-sample edge on (the middle of the
  stop bit), so a following frame may start right after a full stop bit. A falling edge that
  happens while the receiver is not in RX_IDLE is ignored.
- TX and RX are independent and may run at the same time (full duplex). With `rxd` tied to
  `txd`, every transmitted byte comes back on `rx_data`.

### 3.4 Reset

`rst_n` low resets, immediately: `txd` = 1, `tx_ready` = 1 (TX_IDLE), `rx_valid` = 0,
`irq` = 0, `rx_data` = 0x00, synchroniser flops = 1, tick counter = 0. A frame in progress
in either direction is abandoned; after release the TX starts with a fresh handshake and the RX
waits for a new start edge (the tail of a frame cut by reset may look like a start edge and
produce a byte or a framing error; the TB ignores RX output for 12 bit times after such a
reset).

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `CLK_FREQ` | 50_000_000 | > 0, with `CLK_FREQ / BAUD >= 16` | clock frequency in Hz; only used through DIV16 |
| `BAUD` | 115_200 | > 0, with `CLK_FREQ / BAUD >= 16` | bit rate; bit time = 16·DIV16 clocks with DIV16 = (`CLK_FREQ` / `BAUD`) / 16 (truncated) |

The width of the tick counter is `$clog2(max(DIV16, 2))`. DIV16 = 1 is legal (a tick every
clock). DIV16 = 0 (`CLK_FREQ / BAUD < 16`) is not supported.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| stop bit samples 0 (framing error) | byte dropped, `rx_data` keeps its old value, `irq` pulses one clock without `rx_valid` |
| break (line held low for many bit times) | exactly one framing error (data 0x00, stop 0); no further output until the line has gone high and falls again |
| start-bit glitch (low shorter than half a bit) | ignored, no output |
| `tx_valid` while busy | not accepted; the byte is taken only when `tx_ready` is high again |
| `tx_data` changes after accept | no effect on the frame being sent |
| consumer does not take `rx_data` | no flag; next good byte overwrites it |
| reset in the middle of a frame | see §3.4 |
| bit-time jitter on `rxd` | tolerated as long as every sample point (start + 8, 24 + 16·i, 152 ticks) still falls inside its bit; the TB jitters each bit by ±2 clocks of 48 |

## 6. TB check map

Messages are printed by `tb/UART_tb.sv` as `ERROR: <message>`; assertions are in
`tb/cov/UART_sva.sv`, which models the core independently as tick counters over a whole frame.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "reset values" | during and right after reset: `txd` = 1, `tx_ready` = 1, `rx_valid` = 0, `irq` = 0, `rx_data` = 0 | §1, §3.4 |
| "txd start bit" | half a bit after a falling edge on `txd`, `txd` is still 0 | §3.2 |
| "txd byte" | the 8 bits sampled at bit middles equal the accepted byte, LSB first | §3.2 |
| "txd stop bit" | the 10th bit is 1 | §3.2 |
| "byte on txd that was not accepted" | a frame appears on `txd` only for a byte taken with `tx_valid` & `tx_ready` | §3.2 |
| "not drained: tx" | every accepted byte is sent and every sent good frame received within the time allowed (no lost handshake, no stuck FSM) | §3.2, §3.3 |
| "unexpected rx byte" | `rx_valid` only for a frame that was sent with a good stop bit (not for glitches, breaks, framing errors) | §3.3, §5 |
| "rx byte" | `rx_data` at `rx_valid` equals the sent byte, in order | §3.3 |
| "irq" | `irq` equals `rx_valid` OR the framing-error pulse in every clock | §1, §3.3 |
| "framing errors not reported" | two frames with stop bit 0 give two `irq` pulses without `rx_valid` | §5 |
| "break not reported once" | a 20-bit low gives exactly one framing error | §5 |
| "rx bytes after glitches" | low pulses of 2 to 17 clocks (bit = 48) produce no byte | §3.3, §5 |
| a_reset_idle | in reset: `txd`, `tx_ready` high, `rx_valid`, `irq` low, `rx_data` = 0 | §3.4 |
| a_txd_model | `txd` equals the model every clock: 0 for ticks 0..15 after accept, data bit k for ticks 16(k+1)..16(k+1)+15, 1 for ticks 144..159 and when idle | §3.1, §3.2 |
| a_tx_ready_model | `tx_ready` low from the accept edge until the 160th tick edge | §3.2 |
| a_accept_starts_frame | the clock after `tx_valid` & `tx_ready`: `txd` = 0 and `tx_ready` = 0 | §3.2 |
| a_rx_valid_model | `rx_valid` pulses exactly when the model's stop sample (tick 152 after start detect) reads 1 | §3.3 |
| a_rx_data_model | `rx_data` equals the model's last good byte every clock | §3.3 |
| a_irq_model | `irq` = model `rx_valid` OR model framing error | §3.3 |
| a_frame_error_drops_byte | on a framing error `irq` is high and `rx_valid` low | §3.3, §5 |
