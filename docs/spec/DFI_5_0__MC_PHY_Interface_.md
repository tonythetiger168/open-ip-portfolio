<!-- SPDX-License-Identifier: Apache-2.0 -->
# DFI_5_0__MC_PHY_Interface_: design specification

A PHY-side DFI 5.0 model: it takes DDR-style commands and write / read data beats from a memory
controller with fixed DFI timing parameters, keeps a small DRAM array, and checks the protocol.
Not implemented: frequency ratios other than 1:1 and phase alignment, training (write leveling,
gate training, read / write eye), frequency change, MRS side effects, a real DRAM interface, the
DFI update and phy-master interfaces. Core `DFI_5_0__MC_PHY_Interface__top`
(`rtl/DFI_5_0__MC_PHY_Interface__top.sv`), testbench `tb/DFI_5_0__MC_PHY_Interface__tb.sv` (the TB
is the MC), checker `tb/cov/DFI_5_0__MC_PHY_Interface__sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. "Cycle n" is the clock period whose signals are sampled at edge n;
"k cycles after" counts sampling edges.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | dfi_clk (1:1 ratio) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `dfi_address` | input | 17 | row (ACT, bits 1:0 kept), column (RD / WR, bits 2:0), bit 10 = all banks (PRE) | - | `clk` | - |
| `dfi_bank` | input | 3 | bank | - | `clk` | - |
| `dfi_ras_n` | input | 1 | command bit | low | `clk` | - |
| `dfi_cas_n` | input | 1 | command bit | low | `clk` | - |
| `dfi_we_n` | input | 1 | command bit | low | `clk` | - |
| `dfi_cs_n` | input | 1 | chip select; 1 = deselect | low | `clk` | - |
| `dfi_cke` | input | 1 | clock enable; commands need it high | high | `clk` | - |
| `dfi_odt` | input | 1 | on-die termination (sampled, no effect) | high | `clk` | - |
| `dfi_wrdata_en` | input | 1 | write beat, exactly `T_PHY_WRLAT` after a WR | high | `clk` | - |
| `dfi_wrdata` | input | 32 | write data | - | `clk` | - |
| `dfi_wrdata_mask` | input | 4 | per byte, 1 = not written | high | `clk` | - |
| `dfi_rddata_en` | input | 1 | read beat, exactly `T_RDDATA_EN` after a RD | high | `clk` | - |
| `dfi_rddata_valid` | output | 1 | read data valid | high | `clk` | 0 |
| `dfi_rddata` | output | 32 | read data (0 when not valid) | - | `clk` | 0 |
| `dfi_init_start` | input | 1 | a rising edge starts initialisation | high | `clk` | - |
| `dfi_init_complete` | output | 1 | initialisation done, held while `dfi_init_start` stays high | high | `clk` | 0 |
| `dfi_lp_ctrl` | input | 1 | low-power request | high | `clk` | - |
| `dfi_lp_ctrl_ack` | output | 1 | low-power acknowledge | high | `clk` | 0 |
| `irq` | output | 1 | sticky protocol error (cleared only by reset) | high | `clk` | 0 |

### Internal signals used by the verification

The FSM coverage collector binds these.

| Signal | Width | Meaning |
|---|---|---|
| `init_st` | 2 | initialisation: 0 IDLE, 1 RUN, 2 DONE |
| `lp_st` | 2 | low power: 0 RUN, 1 REQ, 2 SLEEP, 3 EXIT |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/DFI_5_0__MC_PHY_Interface_.md`](../ip/DFI_5_0__MC_PHY_Interface_.md) (source: `scripts/apb/specs/DFI_5_0__MC_PHY_Interface_.json`); do not edit by hand.

`DFI_5_0__MC_PHY_Interface__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `dfi_address`, `dfi_bank`, `dfi_ras_n`, `dfi_cas_n`, `dfi_we_n`, `dfi_cs_n`, `dfi_cke`, `dfi_odt`, `dfi_wrdata_en`, `dfi_wrdata`, `dfi_wrdata_mask`, `dfi_rddata_en`, `dfi_rddata_valid`, `dfi_rddata`, `dfi_init_start`, `dfi_init_complete`, `dfi_lp_ctrl`, `dfi_lp_ctrl_ack`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44350200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Handshake state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4435 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `dfi_init_complete` | RO | core | initialisation done (held while dfi_init_start stays high); same as the pin |
| STATUS | 1 | `dfi_lp_ctrl_ack` | RO | core | low-power request acknowledged; same as the pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a command before init, in low power or with cke low; ACT to an open bank; RD / WR to a closed bank; REF / MRS with a bank open; a missing or unexpected dfi_wrdata_en / dfi_rddata_en beat. Sticky in the core until PRESETN, so the bit is set again on every clock |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44350200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `dfi_init_complete`, `dfi_lp_ctrl_ack`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Commands

With `dfi_cs_n` = 0, {`dfi_ras_n`, `dfi_cas_n`, `dfi_we_n`}: 011 ACT, 101 RD, 100 WR, 010 PRE,
001 REF, 000 MRS, 111 NOP. A command (anything but NOP or deselect) is carried out only when the
PHY is up: initialised, not in low power (REQ or SLEEP) and `dfi_cke` = 1.

* ACT to a closed bank opens it with row = `dfi_address`[1:0].
* PRE closes the bank (all banks with `dfi_address`[10]).
* RD / WR to an open bank address word {bank, row, `dfi_address`[2:0]}.
* REF / MRS need all banks closed (no other effect).

Any other command (ACT to an open bank, RD / WR to a closed bank, REF / MRS with a bank open, or
any command while not up) is ignored and sets `irq`.

### 3.2 Data beats

* Write: `dfi_wrdata_en` must be high exactly `T_PHY_WRLAT` cycles after each carried-out WR and
  at no other time. The unmasked bytes of `dfi_wrdata` are written.
* Read: `dfi_rddata_en` must be high exactly `T_RDDATA_EN` cycles after each carried-out RD and at
  no other time. The word is read in that cycle (a write to the same word in the same cycle is not
  seen), and `dfi_rddata_valid` is high with the data `T_PHY_RDLAT` + 1 cycles after the
  `dfi_rddata_en` cycle (the output register adds one).

A missing or extra beat sets `irq` and is dropped (no write, no read data). Beats may be back to
back.

### 3.3 Initialisation

A rising edge of `dfi_init_start` while idle clears the initialised state, closes all banks and
runs the sequence; `dfi_init_complete` is high `INIT_CYCLES` + 1 cycles after the first cycle with
`dfi_init_start` high, and the PHY is initialised from then on. `dfi_init_complete` stays high while
`dfi_init_start` is high and falls one cycle after it drops; if `dfi_init_start` already dropped
during the sequence, `dfi_init_complete` is high for one cycle. The initialised state persists
after the handshake. An edge while running is ignored.

### 3.4 Low power

`dfi_lp_ctrl` first high in RUN: `dfi_lp_ctrl_ack` is high 3 cycles later (REQ, then SLEEP). First
low in SLEEP: the ack is low 3 cycles later (EXIT, then RUN). Commands are refused in REQ and SLEEP
(accepted again in EXIT).

### 3.5 Reset

While `rst_n` is low: not initialised, RUN, banks closed, pipelines empty, outputs 0. The array is
not cleared.

## 4. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `T_PHY_WRLAT` | 4 | WR command to `dfi_wrdata_en`, cycles (2 or more) |
| `T_RDDATA_EN` | 3 | RD command to `dfi_rddata_en`, cycles (2 or more) |
| `T_PHY_RDLAT` | 5 | `dfi_rddata_en` to the read data register (2 or more); valid appears one cycle after |
| `INIT_CYCLES` | 32 | initialisation length, cycles (1..32) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| command before initialisation, in low power or with `dfi_cke` low | ignored, `irq` |
| ACT to an open bank, RD / WR to a closed bank, REF / MRS with a bank open | ignored, `irq` |
| missing or unexpected `dfi_wrdata_en` / `dfi_rddata_en` | beat dropped, `irq` |
| read and write of the same word in the same cycle | read returns the old data |
| new `dfi_init_start` edge | banks closed, PHY down until it completes |
| `irq` | sticky until reset |

## 6. TB check map

Messages are printed by `tb/DFI_5_0__MC_PHY_Interface__tb.sv` as `ERROR: <message>`. Assertions
`a_*` are in the bound checker `tb/cov/DFI_5_0__MC_PHY_Interface__sva.sv`, which predicts every
output each clock. The TB is the MC with a beat schedule and a shadow array, and injects every
fault kind (each followed by a reset).

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "unexpected read beat" | no read data without a read | §3.2 |
| "read" | read data as the shadow array | §3.2 |
| "rddata not gated" | data 0 when not valid | §3.2 |
| "init took" | initialisation length | §3.3 |
| "init_complete dropped while init_start held" | handshake | §3.3 |
| "init_complete held after release" | handshake release | §3.3 |
| "lp ack early" | no ack in the first 2 cycles | §3.4 |
| "lp ack" | ack rises | §3.4 |
| "lp ack dropped early" | ack held for 2 cycles after release | §3.4 |
| "lp ack release" | ack falls | §3.4 |
| "reset state" | reset values | §3.5 |
| "short init_start: init_complete high" | one-cycle complete after a short start | §3.3 |
| a_reset_outputs | reset values | §3.5 |
| a_init_complete | `dfi_init_complete` as the model | §3.3 |
| a_lp_ack | `dfi_lp_ctrl_ack` as the model | §3.4 |
| a_rddata_valid | `dfi_rddata_valid` as the model | §3.2 |
| a_rddata | `dfi_rddata` as the model | §3.2 |
| a_irq | `irq` as the model | §3.1, §3.2 |
| a_irq_sticky | `irq` never falls | §5 |
