<!-- SPDX-License-Identifier: Apache-2.0 -->
# GPIO: design specification

8-bit bidirectional GPIO bank: an output register driven onto the pins whose output enable is
set, an input register that samples all 8 pins every clock, and a level interrupt that is high
while any sampled pin is 1. Core `GPIO_top` (`rtl/GPIO_top.sv`), testbench `tb/GPIO_tb.sv`,
checker `tb/cov/GPIO_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. "Sampled at edge *n*" means the value an input had just before
rising edge *n*.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of `out_q` and `in_q` | low | async assert | - |
| `wen` | input | 1 | local write strobe | high | clk | - |
| `waddr` | input | 4 | local write address: 0 = output register; others ignored | - | clk | - |
| `wdata` | input | 8 | local write data | - | clk | - |
| `ren` | input | 1 | local read strobe; unused (reads have no side effect, `rdata` is valid regardless of `ren`) | high | - | - |
| `raddr` | input | 4 | local read address: 0 = input register, 1 = output register, others read 0 | - | comb. | - |
| `rdata` | output | 8 | local read data, combinational from `raddr` | - | comb. | 0x00 |
| `gpio` | inout | 8 | the pins (tri-state); bit *i* is driven with `out_q[i]` when `gpio_oe[i]` = 1, else high-Z | - | driven: comb. from flops; sampled by clk | driven pins 0 |
| `gpio_oe` | input | 8 | per-pin output enable, 1 = drive the pin (combinational, takes effect at once) | high | comb. | - |
| `irq` | output | 1 | level interrupt: OR of the 8 bits of the input register `in_q` | high | clk | 0 |

Internal state: `out_q` (output register) and `in_q` (input register), 8 bits each, reset 0.
The pins are sampled by a single flop (no 2-flop synchroniser); asynchronous inputs need an
external synchroniser if metastability matters.

### Internal signals used by the verification

The TB and the bound checker read these core-internal signals by name; a re-implementation
must have them, with these names and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `out_q` | 8 | output register (§3) |

## 2. Registers

Local port of the core (the generated APB4 wrapper `GPIO_apb` maps these onto its own
registers and latches `irq`):

| Local address | Read (`raddr`) | Write (`waddr`, `wen`) |
|---|---|---|
| 0 | `in_q`: pins as sampled at the last edge | `out_q` <= `wdata` |
| 1 | `out_q` | ignored |
| 2..15 | 0x00 | ignored |

<!-- AUTO:registers -->
Generated from [`docs/ip/GPIO.md`](../ip/GPIO.md) (source: `scripts/apb/specs/GPIO.json`); do not edit by hand.

`GPIO_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `gpio`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x47500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | OE | RW | 0x00000000 | Output enables |
| 0x018 | OUT | RW (core) | core | Output values (driven on pins whose OE bit is set) |
| 0x01C | IN | RO (core) | core | Pin levels, sampled one clock earlier |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x020 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4750 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| OE | 7:0 | `gpio_oe` | RW | 0x0 | 1: pin driven from OUT; 0: pin is an input |
| OUT | 7:0 | core register | RW (core) | core | written at core register 0 and read from core register 1 |
| IN | 7:0 | core register | RO (core) | core | read from core register 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | HIGH | a pin was sampled high |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x47500200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write OE (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. Access the core's registers through the CORE words (0x018 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

- **Write**: at an edge with `wen` = 1 and `waddr` = 0, `out_q <= wdata`. Pins with
  `gpio_oe` = 1 show the new value right after that edge (combinational from `out_q`).
  Other `waddr` values change nothing.
- **Output enable**: `gpio[i] = gpio_oe[i] ? out_q[i] : 1'bz`, combinational: changing
  `gpio_oe` drives or releases the pin at once. `out_q` keeps its value while a pin is an input.
- **Input sampling**: at every edge `in_q <= gpio` (all 8 pins, outputs included). So a pin
  value is visible on `rdata` (`raddr` = 0) and on `irq` one edge after it appears on the pin;
  an output written at edge W reads back at `raddr` 0 from edge W+1 on (loopback).
- **Read**: `rdata` is combinational: `raddr` = 0 → `in_q`, 1 → `out_q`, else 0x00. No side
  effect.
- **Interrupt**: `irq = |in_q`. It is a level, not a pulse or a latched event: it is high
  for as long as any sampled pin is 1 and falls one edge after the last pin goes to 0. Pins
  driven as outputs count too.
- **Reset**: `out_q` and `in_q` clear at once: every enabled pin drives 0, `rdata` = 0 for every
  `raddr`, `irq` = 0. After release `in_q` follows the pins again from the first edge.

## 4. Parameters

The core has no parameters.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| write to address 1..15 | ignored, `out_q` unchanged |
| read from address 2..15 | returns 0x00 |
| mixed directions (`gpio_oe` partly set) | enabled pins show `out_q`; `in_q` holds `out_q` on those bits and the external value on the others |
| external driver fights an enabled pin | not handled (bus contention outside the core) |
| floating input pin (`gpio_oe` = 0, nothing drives it) | samples Z/X into `in_q`; the system must pull pins to a level |
| reset with the output register set | pins and both registers go to 0 immediately |

## 6. TB check map

Messages are printed by `tb/GPIO_tb.sv` as `ERROR: <message>`; messages starting "CRV" and the
immediate checks A1..A6 are built only for Verilator. Assertions a_* are in
`tb/cov/GPIO_sva.sv`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "GPIO output" | with `gpio_oe` = FF, a write of A5 appears on the pins | §3 Write, Output enable |
| "GPIO loopback" | an output value reads back at `raddr` 0 one edge later | §3 Input sampling |
| "GPIO input" | an externally driven value (3C) reads at `raddr` 0 | §3 Input sampling |
| "GPIO out_reg" | `raddr` 1 reads `out_q`, also while the pins are inputs | §3 Read |
| "GPIO mixed-direction pins" | `gpio_oe` = 0F: low nibble driven from `out_q`, high nibble external | §3 Output enable, §5 |
| "GPIO mixed-direction input" | `in_q` holds both halves | §5 |
| "GPIO pin" | each pin alone, as an input, raises `irq` | §3 Interrupt |
| "GPIO walking-one pin" | `in_q` is exactly the one driven pin | §3 Input sampling |
| "GPIO irq stuck with all inputs low" | `irq` = 0 once all sampled pins are 0 | §3 Interrupt |
| "GPIO pins not cleared by reset" | reset makes the enabled pins 0 at once | §3 Reset |
| "GPIO out_q not cleared by reset" | `out_q` = 0 after reset | §3 Reset |
| "GPIO out_q" | FF, 55, AA write and read back through address 1 | §3 Write, Read |
| "CRV GPIO out" | random writes appear on enabled pins | §3 Write |
| "CRV loopback" | random outputs read back at address 0 | §3 Input sampling |
| "CRV input" | random external inputs read at address 0 | §3 Input sampling |
| "CRV illegal write to" | writes to address 1..15 leave `out_q` unchanged | §5 |
| "CRV out_reg" | address 1 reads the model of `out_q` | §3 Read |
| "CRV illegal addr" | reads at address 2..15 return 0 | §5 |
| "A1 reset: rdata zero" | `rdata` = 0 in reset | §3 Reset |
| "A2 rdata never X/Z" | `rdata` defined out of reset | §3 Read |
| "A3 raddr1 reads out_q" | address 1 reads `out_q` | §3 Read |
| "A4 hi-Z when OE clear" | a pin with `gpio_oe` = 0 is not driven by the core | §3 Output enable |
| "A5 driven value == out_q" | a pin with `gpio_oe` = 1 shows `out_q` | §3 Output enable |
| "A6 illegal addr reads 0" | `raddr` > 1 reads 0 | §3 Read |
| a_reset_clear | in reset `rdata` = 0 and `irq` = 0 | §3 Reset |
| a_pins_driven | enabled pins equal the model's `out_q` | §3 Write, Output enable |
| a_read_mux | `rdata` = `in_q` / `out_q` / 0 by `raddr` | §3 Read |
| a_irq_level | `irq` = OR of the model's `in_q` | §3 Interrupt |
