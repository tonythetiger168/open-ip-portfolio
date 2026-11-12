<!-- SPDX-License-Identifier: Apache-2.0 -->
# MIPI_DPI__Display_Pixel_Interface_: design specification

A MIPI DPI (Display Pixel Interface) transmitter: a programmable parallel RGB video timing
generator, one pixel per clock, with a 16 x 16-bit register interface. Not implemented: sync
polarity selection, pixel formats other than 24 / 18 bits on 24 pins, pixel clock division,
the DPI shutdown / color mode pins as inputs (they are register bits here). Core
`MIPI_DPI__Display_Pixel_Interface__top` (`rtl/MIPI_DPI__Display_Pixel_Interface__top.sv`),
testbench `tb/MIPI_DPI__Display_Pixel_Interface__tb.sv` (a shadow timing model compared every
clock), checker `tb/cov/MIPI_DPI__Display_Pixel_Interface__sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; video outputs for counter
position (x, y) in clock n appear in clock n+1.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock = pixel clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `irq` | output | 1 | an enable was rejected (§3.1); cleared by an accepted control write | high | `clk` | 0 |
| `pclk` | output | 1 | pixel clock forwarded: `clk` itself | - | - | - |
| `hsync` | output | 1 | horizontal sync | high | `clk` | 0 |
| `vsync` | output | 1 | vertical sync | high | `clk` | 0 |
| `de` | output | 1 | data enable: active pixel | high | `clk` | 0 |
| `rgb` | output | 24 | pixel out (0 outside active video) | - | `clk` | 0 |
| `pixel` | input | 24 | pixel source, sampled in the active region | - | `clk` | - |
| `reg_wr` | input | 1 | register write at this edge | high | `clk` | - |
| `reg_addr` | input | 4 | core register address (§3.1) | - | `clk` | - |
| `reg_wdata` | input | 16 | register write data | - | `clk` | - |
| `reg_rdata` | output | 16 | register read data for `reg_addr`; combinational | - | comb | 0 |
| `frame_cnt` | output | 16 | frames completed (wraps) | - | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `ctrl` | 3 | control register: bit 0 enable, bit 1 shutdown, bit 2 18-bit colour mode |
| `hcnt` | 16 | horizontal position counter |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/MIPI_DPI__Display_Pixel_Interface_.md`](../ip/MIPI_DPI__Display_Pixel_Interface_.md) (source: `scripts/apb/specs/MIPI_DPI__Display_Pixel_Interface_.json`); do not edit by hand.

`MIPI_DPI__Display_Pixel_Interface__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `pclk`, `hsync`, `vsync`, `de`, `rgb`, `pixel`, `frame_cnt`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44490200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | HFP | RW (core) | core | [15:0] horizontal front porch, pixels (reset 0) |
| 0x018 | HSW | RW (core) | core | [15:0] hsync width, pixels |
| 0x01C | HBP | RW (core) | core | [15:0] horizontal back porch, pixels |
| 0x020 | HACT | RW (core) | core | [15:0] active pixels per line |
| 0x024 | VFP | RW (core) | core | [15:0] vertical front porch, lines |
| 0x028 | VSW | RW (core) | core | [15:0] vsync width, lines |
| 0x02C | VBP | RW (core) | core | [15:0] vertical back porch, lines |
| 0x030 | VACT | RW (core) | core | [15:0] active lines |
| 0x034 | CTRL | RW (core) | core | [0] enable, [1] shutdown (outputs low, position held), [2] 18-bit colour (2 LSBs of each channel cleared). Enabling with a timing register at 0 or a total above 65536 is refused (CFG_ERR) |
| 0x038 | FRAME | RO (core) | core | [15:0] frames sent (wraps; also on the frame_cnt pins) |
| 0x03C | HCNT | RO (core) | core | [15:0] current pixel in the line (0 while disabled) |
| 0x040 | VCNT | RO (core) | core | [15:0] current line in the frame |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x044 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4449 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| HFP | 15:0 | core register | RW (core) | core | written at core register 0 and read from core register 0 |
| HSW | 15:0 | core register | RW (core) | core | written at core register 1 and read from core register 1 |
| HBP | 15:0 | core register | RW (core) | core | written at core register 2 and read from core register 2 |
| HACT | 15:0 | core register | RW (core) | core | written at core register 3 and read from core register 3 |
| VFP | 15:0 | core register | RW (core) | core | written at core register 4 and read from core register 4 |
| VSW | 15:0 | core register | RW (core) | core | written at core register 5 and read from core register 5 |
| VBP | 15:0 | core register | RW (core) | core | written at core register 6 and read from core register 6 |
| VACT | 15:0 | core register | RW (core) | core | written at core register 7 and read from core register 7 |
| CTRL | 15:0 | core register | RW (core) | core | written at core register 8 and read from core register 8 |
| FRAME | 15:0 | core register | RO (core) | core | read from core register 9 |
| HCNT | 15:0 | core register | RO (core) | core | read from core register 10 |
| VCNT | 15:0 | core register | RO (core) | core | read from core register 11 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CFG_ERR | an enable was refused (invalid timing); level in the core until the next accepted CTRL write, so the bit is set again on every clock until then |

### Core register port

The REGS words reach the core's own register port. A write to one pulses `reg_wr` for one clock with `reg_addr` (the core register) and `reg_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `reg_addr` (the core register) during the access phase and returns `reg_rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44490200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the REGS words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Registers and enable

| Address | Register | Access |
|---|---|---|
| 0..3 | HFP, HSW, HBP, HACT (pixels) | RW |
| 4..7 | VFP, VSW, VBP, VACT (lines) | RW |
| 8 | CTRL {13'b0, colour mode, shutdown, enable} | RW |
| 9 | frame count | RO |
| 10 | `hcnt` | RO |
| 11 | `vcnt` | RO |
| 12..15 | 0 | RO |

Writes take effect at the edge. A CTRL write with bit 0 = 1 when the configuration is invalid
(any timing register 0, or HFP + HSW + HBP + HACT or VFP + VSW + VBP + VACT above 65536) is
rejected: CTRL is unchanged and `irq` = 1. Any other CTRL write is stored and clears `irq`.
Writes to addresses 9..15 are ignored. `reg_rdata` follows `reg_addr` combinationally.

### 3.2 Timing generator

While enable = 0, `hcnt` = `vcnt` = 0 and every video output is 0. While enabled and not shut down,
each clock the outputs take the values for the current position and the counters advance:

* `hsync` = HFP <= x < HFP + HSW; `vsync` = VFP <= y < VFP + VSW (front porch, sync, back porch,
  active in that order in both dimensions);
* `de` = x >= HFP + HSW + HBP and y >= VFP + VSW + VBP (and inside the totals);
* `rgb` = `pixel` (with colour mode: `pixel` AND 0xFCFCFC) when `de`, else 0.

x runs 0 .. HTOTAL - 1, then 0 with y + 1; after the last line y wraps to 0 and `frame_cnt` + 1.
A total shrunk below the current position wraps at the next clock (the comparison is >=).
Timing registers may be rewritten while running. After enabling, the first clock shows position
(0, 0).

### 3.3 Shutdown

With shutdown = 1 (and enable = 1) every video output is 0 and the counters hold their position;
clearing shutdown resumes from that position. The effect is seen one clock after the CTRL write
(the write's edge still runs one normal step).

### 3.4 Reset

While `rst_n` is low: every register and output 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | any | unused (kept for the framework) |
| `AW` | 32 | any | unused (kept for the framework) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| enable with a zero timing register | rejected, `irq` |
| line or frame total above 65536 | rejected, `irq`; exactly 65536 is accepted |
| timing registers made invalid while running, then an enable write | rejected with `irq` while still running (CTRL keeps enable 1) |
| total shrunk below the current position | the counter wraps at once |
| `frame_cnt` at 0xFFFF | wraps to 0 |
| reset while active | all outputs and registers 0 |

## 6. TB check map

Messages are printed by `tb/MIPI_DPI__Display_Pixel_Interface__tb.sv` as `ERROR: <message>`
(TB checks) or `SVA_FAIL: <name>` (the in-TB assertions A1..A8). Assertions `a_*` are in the bound
checker `tb/cov/MIPI_DPI__Display_Pixel_Interface__sva.sv`. A shadow timing model predicts
`hsync` / `vsync` / `de` / `rgb` at every position over full frames; random configurations
(valid and invalid) run one frame each; shutdown / resume, reconfiguration, colour mode,
overflowing totals and a reset while active are covered.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "CRV invalid config not rejected" | invalid enable sets `irq` | §3.1 |
| "CRV rejected config not blank" | outputs stay 0 after a rejected enable | §3.1, §3.2 |
| "CRV valid config raised irq" | valid enable clears `irq` | §3.1 |
| "A1 reset: outputs quiescent" | outputs 0 in reset | §3.4 |
| "A2 disabled blank" | outputs 0 one clock after enable clears | §3.2 |
| "A3 shutdown blank" | outputs 0 one clock after shutdown sets | §3.3 |
| "A4 rgb pipeline" | `rgb` = previous clock's `pixel` (masked) when `de` | §3.2 |
| "A5 irq implies rejected enable" | `irq` only with CTRL 0 (in the TB's use) | §3.1 |
| "A6 frame_cnt monotone" | `frame_cnt` only counts up (wrap allowed) | §3.2 |
| "A7 de excludes syncs" | `de` never with a sync | §3.2 |
| "A8 region encoding legal" | never two of `hsync` / `vsync` / `de` with `de` | §3.2 |
| "reset state" | outputs and registers 0 after reset | §3.4 |
| "invalid config raises irq" | zero timing register rejected | §3.1 |
| "rejected enable stays blank" | no video after rejection | §3.1 |
| "valid enable clears irq" | `irq` cleared | §3.1 |
| "disabled blank" | outputs 0 when disabled | §3.2 |
| "cc: no irq during closure sweeps" | valid writes leave `irq` 0 | §3.1 |
| "16-bit overflow config raises irq" | line total above 65536 rejected | §3.1 |
| "vertical overflow config raises irq" | frame total above 65536 rejected | §3.1 |
| "vtotal of 65536 accepted" | 65536 is legal | §3.1 |
| "counter past new total wrapped" | shrunk total wraps at once | §3.2 |
| "reset while active" | reset clears a running generator | §3.4 |
| "constant pixel through the colour mask" | colour mode masks 2 LSBs per channel | §3.2 |
| "shutdown in 18-bit mode blanks" | shutdown blanks in colour mode | §3.3 |
| "shutdown blank" | outputs 0 and position held | §3.3 |
| "resume.req blank" | still blank before the resume write | §3.3 |
| "resume hold" | blank on the resume write's clock, then resumes | §3.3 |
| a_reset_blank | in reset: outputs, `irq`, `frame_cnt` 0 | §3.4 |
| a_video_model | `hsync` / `vsync` / `de` / `rgb` exactly as the checker's model | §3.2, §3.3 |
| a_frame_cnt_model | `frame_cnt` as the model | §3.2 |
| a_irq_model | `irq` as the model | §3.1 |
| a_readback_model | `reg_rdata` as the model | §3.1 |
| a_de_inside_frame | `de` only with both syncs low | §3.2 |
