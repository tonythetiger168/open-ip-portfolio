<!-- SPDX-License-Identifier: Apache-2.0 -->
# PWM: design specification

Single-channel PWM generator: a free-running counter of `period` clocks, an active-high output
that is 1 for the first `duty` counts of each period, its complement, and a one-clock interrupt
at the last count of every period. Core `PWM_top` (`rtl/PWM_top.sv`), testbench
`tb/PWM_tb.sv`, checker `tb/cov/PWM_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Values in a formula are the register values in the current clock
(before the next edge).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock; one count per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of `period_q`, `duty_q`, `counter` | low | async assert | - |
| `wen` | input | 1 | local write strobe | high | clk | - |
| `waddr` | input | 4 | local write address: 0 = period, 1 = duty, others ignored | - | clk | - |
| `wdata` | input | `DW` | local write data | - | clk | - |
| `pwm_out` | output | 1 | PWM output: `period_q != 0 && counter < duty_q` (combinational from flops) | high | clk | 0 |
| `pwm_n_out` | output | 1 | complement: always `~pwm_out` (no dead time) | low | clk | 1 |
| `irq` | output | 1 | `period_q != 0 && counter == period_q - 1`: high during the last count of each period | high | clk | 0 |

Internal state, all `DW` bits and reset to 0: `period_q`, `duty_q`, `counter`. There is no read
port; the APB wrapper keeps its own copies of the written values.

### Internal signals used by the verification

The TB and the bound checker read these core-internal signals by name; a re-implementation
must have them, with these names and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `period_q` | `DW` | period register (§3.1) |
| `duty_q` | `DW` | duty register (§3.2) |
| `counter` | `DW` | period counter (§3.1) |

## 2. Registers

Local write port of the core:

| Local address | Write (`waddr`, `wen`) |
|---|---|
| 0 | `period_q` <= `wdata` (0 = disabled) |
| 1 | `duty_q` <= `wdata` |
| 2..15 | ignored |

<!-- AUTO:registers -->
Generated from [`docs/ip/PWM.md`](../ip/PWM.md) (source: `scripts/apb/specs/PWM.json`); do not edit by hand.

`PWM_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `pwm_out`, `pwm_n_out`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x50570200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | PERIOD | WO (core) | core | Period in clocks (0 stops the output, held low) |
| 0x018 | DUTY | WO (core) | core | Clocks per period the output is high |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x01C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5057 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| PERIOD | 31:0 | core register | WO (core) | core | written at core register 0 |
| DUTY | 31:0 | core register | WO (core) | core | written at core register 1 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PERIOD_END | the last clock of a period |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. 

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x50570200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Counter

At every edge, using the values before the edge:

- `period_q` = 0: `counter <= 0`.
- else, `counter >= period_q - 1`: `counter <= 0` (wrap; also catches a counter above a
  shrunk period).
- else: `counter <= counter + 1`.

With a constant period P ≥ 1 the counter runs 0, 1, ..., P-1, 0, ...: one period is exactly P
clocks.

### 3.2 Outputs

- `pwm_out` = 1 while `counter < duty_q` (and `period_q` ≠ 0). In each period of P clocks it
  is high for min(`duty_q`, P) clocks, starting at count 0: `duty_q` = 0 → always low;
  `duty_q` ≥ P → always high.
- `pwm_n_out = ~pwm_out` in every clock, reset included.
- `irq` is high during the clock where `counter` = P-1, i.e. one clock per period. With P = 1
  the counter stays 0, so `irq` stays high.
- All three are combinational from the flops, so they change only after clock edges (or reset).

### 3.3 Register writes

- A write at edge W updates `period_q` / `duty_q` at W; the outputs use the new value from the
  clock after W. The counter step at W itself still uses the old `period_q`.
- Enable (period 0 → P): the counter is 0 in the clock after W (the old period was 0), then
  counts from there; the first period starts in that clock.
- Disable (write 0 to period): from the clock after W, `pwm_out` = 0, `irq` = 0; at the next
  edge `counter` returns to 0 and stays there.
- Shrinking the period below the running count: at the next edge the counter wraps to 0
  (`counter >= period_q - 1`), so no overlong period.
- Changing the duty mid-period takes effect immediately (compared against the running counter);
  there is no shadow register.

### 3.4 Reset

`rst_n` low clears `period_q`, `duty_q`, `counter` at once: `pwm_out` = 0, `pwm_n_out` = 1,
`irq` = 0 (PWM disabled until the period is written again).

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | 1 .. 32 (the APB wrapper data is 32 bits; the TB uses 32) | width of `wdata`, `period_q`, `duty_q` and `counter`; longest period 2^DW - 1 clocks |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| period = 0 | disabled: outputs low/high, `irq` 0, counter held at 0 |
| period = 1 | counter always 0; `pwm_out` = (`duty_q` ≠ 0); `irq` stays high |
| duty = 0 | `pwm_out` never high |
| duty ≥ period | `pwm_out` always high (no error) |
| write to address 2..15 | ignored; outputs keep running and are never X |
| period shrunk below the count | wrap at the next edge (§3.3) |
| reset while running | §3.4 |

## 6. TB check map

Messages are printed by `tb/PWM_tb.sv` as `ERROR: <message>`; messages starting "CRV" and the
immediate checks A1..A6 are built only for Verilator. Assertions a_* are in `tb/cov/PWM_sva.sv`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "PWM period" (`PWM period=.. duty=.. high_count=..`) | over one period starting at count 0, `pwm_out` is high for exactly `duty` clocks (periods 1 and 10, duties 0, 1, 3, 7) | §3.1, §3.2 |
| "CRV PWM period" | random period 1..200 and duty 0..period+50: high count = min(duty, period) | §3.2 |
| "CRV PWM long period high_count" | period 2^22: the high count matches over the full period | §3.1, §4 |
| "CRV X on pwm_out after illegal write" | writes to address 2..15 leave `pwm_out` defined | §5 |
| "PWM not low when disabled" | the clock after writing period 0, `pwm_out` = 0 | §3.3 |
| "PWM outputs not idle in reset" | in reset `pwm_out` = 0, `pwm_n_out` = 1 | §3.4 |
| "A1 reset: outputs quiescent" | in reset `pwm_out` = 0, `pwm_n_out` = 1, `irq` = 0 | §3.4 |
| "A2 pwm_n == ~pwm_out" | complement in every clock | §3.2 |
| "A3 counter zero when period zero" | counter 0 once the period has been 0 for a clock | §3.1, §3.3 |
| "A4 pwm_out implies nonzero period/duty" | high output needs period ≠ 0 and duty ≠ 0 | §3.2 |
| "A5 pwm_out compare equation" | `pwm_out` = (`period_q` ≠ 0 && `counter` < `duty_q`) | §3.2 |
| "A6 irq only at terminal count" | `irq` only when `counter` = `period_q` - 1 | §3.2 |
| a_reset_low | in reset `pwm_out` = 0, `pwm_n_out` = 1, `irq` = 0 | §3.4 |
| a_complementary | `pwm_n_out` = `~pwm_out` always | §3.2 |
| a_pwm_model | `pwm_out` equals the model's compare | §3.1, §3.2 |
| a_irq_model | `irq` equals the model's terminal count | §3.2 |
| a_disabled_low | period 0: `pwm_out` and `irq` low | §3.3, §5 |
