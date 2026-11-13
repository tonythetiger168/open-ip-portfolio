<!-- SPDX-License-Identifier: Apache-2.0 -->
# JTAG: design specification

IEEE 1149.1 test access port with the standard 16-state TAP controller, a 4-bit instruction
register and three data registers: IDCODE (32 bits, selected after reset), an 8-bit USER register
that the debugger can write and read back, and the 1-bit BYPASS register used for opcode 1111 and
every unused opcode. Each Update-DR of USER raises a one-cycle `irq` in the `clk` domain. There is
no boundary scan, EXTEST or SAMPLE/PRELOAD. Core `JTAG_top` (`rtl/JTAG_top.sv`), testbench
`tb/JTAG_tb.sv`, checker `tb/cov/JTAG_sva.sv`.

Conventions on this page: the TAP, IR and DRs change on the rising edge of TCK, TDO on the falling
edge; all of them are reset asynchronously by `trst_n` low. Only the `irq` synchronizer runs on
`clk` and is reset by `rst_n`. Scan data is shifted LSB first.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | system clock for the `irq` synchronizer only | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the `irq` synchronizer | low | async assert | - |
| `tck` | input | 1 | test clock | both edges | - | - |
| `tms` | input | 1 | test mode select, sampled at the TCK rise | - | `tck` rise | - |
| `tdi` | input | 1 | test data in, sampled at the TCK rise in Shift-IR / Shift-DR | - | `tck` rise | - |
| `trst_n` | input | 1 | asynchronous test reset: TAP to Test-Logic-Reset, IR = IDCODE, all DRs and TDO to 0 | low | async assert | - |
| `tdo` | output | 1 | test data out, changes at the TCK fall; LSB of the selected shift register in Shift-IR / Shift-DR, 0 in all other states (it is never tri-stated) | - | `tck` fall | 0 |
| `irq` | output | 1 | one-`clk` pulse 2 to 3 `clk` after each Update-DR with USER selected | high | `clk` | 0 |

### Internal signals used by the verification

The TB and the checker read these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `tap_q` | 4 | TAP state, encoded TLR = 0, RTI = 1, SEL_DR = 2, CAP_DR = 3, SH_DR = 4, EX1_DR = 5, PAUSE_DR = 6, EX2_DR = 7, UPD_DR = 8, SEL_IR = 9, CAP_IR = 10, SH_IR = 11, EX1_IR = 12, PAUSE_IR = 13, EX2_IR = 14, UPD_IR = 15 |
| `ir_q` | 4 | current instruction (IDCODE = 0001 after reset) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/JTAG.md`](../ip/JTAG.md) (source: `scripts/apb/specs/JTAG.json`); do not edit by hand.

`JTAG_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tck`, `tms`, `tdi`, `trst_n`, `tdo`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4A540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4A54 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | USER_UPDATE | the debugger wrote the USER register (Update-DR with IR = USER), seen three PCLK edges later through the TCK-to-PCLK synchroniser |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4A540200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 TAP controller

At each TCK rise the TAP moves along the IEEE 1149.1 state diagram with `tms`:

| State | TMS = 0 | TMS = 1 |
|---|---|---|
| Test-Logic-Reset | Run-Test/Idle | Test-Logic-Reset |
| Run-Test/Idle | Run-Test/Idle | Select-DR |
| Select-DR | Capture-DR | Select-IR |
| Capture-DR | Shift-DR | Exit1-DR |
| Shift-DR | Shift-DR | Exit1-DR |
| Exit1-DR | Pause-DR | Update-DR |
| Pause-DR | Pause-DR | Exit2-DR |
| Exit2-DR | Shift-DR | Update-DR |
| Update-DR | Run-Test/Idle | Select-DR |
| Select-IR | Capture-IR | Test-Logic-Reset |
| Capture-IR | Shift-IR | Exit1-IR |
| Shift-IR | Shift-IR | Exit1-IR |
| Exit1-IR | Pause-IR | Update-IR |
| Pause-IR | Pause-IR | Exit2-IR |
| Exit2-IR | Shift-IR | Update-IR |
| Update-IR | Run-Test/Idle | Select-DR |

Five TCK cycles with TMS = 1 reach Test-Logic-Reset from any state. `trst_n` low forces it at once.

### 3.2 Instruction register

The actions below happen at the TCK rise *while* the TAP is in the named state (that is, the rise
that leaves it):

- Test-Logic-Reset: `ir_q` <= 0001 (IDCODE).
- Capture-IR: the IR shift register <= 0101 (LSBs 01 as 1149.1 requires).
- Shift-IR: the IR shift register shifts right, `tdi` into bit 3.
- Update-IR: `ir_q` <= the IR shift register.

Opcodes: 0001 IDCODE, 0010 USER, 1111 BYPASS; every other opcode selects BYPASS as well.

### 3.3 Data registers

| `ir_q` | DR | Length | Capture-DR loads | Update-DR |
|---|---|---|---|---|
| 0001 | IDCODE | 32 | `IDCODE` | nothing |
| 0010 | USER | 8 | the current USER value | USER <= shift register, `irq` request (§3.5) |
| other | BYPASS | 1 | 0 | nothing |

In Shift-DR the selected register shifts right with `tdi` into its MSB (BYPASS: the bit becomes
`tdi`). The other registers hold. So a BYPASS scan returns the captured 0 followed by the TDI
bits delayed by one TCK, and an IDCODE scan longer than 32 bits returns IDCODE then the first
TDI bits shifted in.

### 3.4 TDO

At each TCK fall: in Shift-IR, `tdo` <= bit 0 of the IR shift register; in Shift-DR, `tdo` <=
bit 0 of the selected DR; in every other state `tdo` <= 0. The first bit appears at the fall
after the Capture-to-Shift rise and is sampled by the debugger at the next rise, the standard
half-cycle TDO timing. The last bit is shifted at the rise that leaves Shift with TMS = 1. A
Pause in the middle of a scan holds the register and TDO returns to 0 until Shift resumes.

### 3.5 USER update interrupt

Each Update-DR with USER selected toggles a TCK-domain bit. In the `clk` domain the toggle passes
through three flops, and `irq` = stage 3 XOR stage 2: a single-`clk` pulse 2 to 3 `clk` after the
TCK rise. Two updates must be at least 2 `clk` apart to give two pulses (at a normal TCK much
slower than `clk` they always are). `rst_n` resets the synchronizer; an update during `rst_n` low
gives no pulse.

### 3.6 Reset

`trst_n` low: TAP = Test-Logic-Reset, `ir_q` = IDCODE, IR shift register, all DRs, USER, the
update toggle and `tdo` = 0. Leaving Test-Logic-Reset through TMS (no `trst_n`) also selects
IDCODE but keeps USER. `rst_n` resets only the `irq` synchronizer.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `IDCODE` | 32'h1CAF_0001 | any 32-bit value with bit 0 = 1 (1149.1 requires the LSB to be 1) | value captured into the IDCODE DR |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| unused IR opcode | DR is BYPASS (1 bit, captures 0) |
| DR scan shorter than the register | only the bits shifted in change; for USER the update loads the partly shifted value |
| DR scan longer than the register | extra TDO bits are the earliest TDI bits; extra TDI bits push out the first ones |
| Pause-DR / Pause-IR in a scan | registers hold; scan continues after Exit2 |
| `trst_n` in the middle of a scan | TAP, IR, DRs and USER reset at once |
| TMS walk through Test-Logic-Reset | IDCODE selected again; USER keeps its value |
| `tdo` outside Shift states | driven 0, not high-Z (a board needs no TDO enable) |

## 6. TB check map

Messages are printed by `tb/JTAG_tb.sv` as `ERROR: <message>` (A1..A6 as `SVA_FAIL:`); "CRV"
messages and A1..A6 are built only for Verilator. Assertions a_* are in `tb/cov/JTAG_sva.sv`.
The TB drives TMS / TDI while TCK is low and samples TDO just before the rise.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "JTAG IDCODE" | after reset a 32-bit DR scan returns 0x1CAF0001 | §3.3, §3.6 |
| "JTAG irq before any USER update" | no `irq` before the first USER update | §3.5 |
| "JTAG irq pulses after one USER update" | exactly one `irq` pulse per USER Update-DR | §3.5 |
| "JTAG USER" | USER write 0xA5 reads back | §3.3 |
| "JTAG BYPASS" | BYPASS scan returns the captured 0 then TDI delayed by one bit | §3.3 |
| "CRV IDCODE" | random IDCODE scans | §3.3 |
| "CRV USER" | random USER write and read back | §3.3 |
| "CRV BYPASS" | random BYPASS scans | §3.3 |
| "CRV reserved-IR BYPASS" | every unused opcode behaves as BYPASS | §3.2, §5 |
| "CRV IDCODE after mid-scan TRST" | `trst_n` in a scan, then IDCODE scan | §3.6 |
| "JTAG TLR did not select IDCODE" | five TMS = 1 cycles select IDCODE again | §3.1, §3.2 |
| "JTAG IR capture" | Shift-IR returns the capture pattern 0101 (LSB first: 1, 0, 1, 0) | §3.2, §3.4 |
| "JTAG paused USER scan" | a USER scan through Exit1, Pause, Exit2 completes correctly | §3.4 |
| "JTAG paused IR -> BYPASS" | an IR scan with a pause loads BYPASS | §3.2 |
| "JTAG USER FF readback" | USER value class 0xFF | §3.3 |
| "JTAG USER 55 readback" | USER value class 0x55 | §3.3 |
| "JTAG USER AA readback" | USER value class 0xAA | §3.3 |
| "JTAG long scan bit" | a 40-bit IDCODE scan: bits 32..39 are the first TDI bits (all 1) | §3.3 |
| "JTAG long IDCODE scan" | ... and bits 0..31 are IDCODE | §3.3 |
| "A1 trst: TAP in TLR" | `trst_n` low: `tap_q` = TLR | §3.6 |
| "A2 TAP transition legal" | `tap_q` follows the state diagram | §3.1 |
| "A4 tdo never X" | `tdo` is 0 or 1 at every TCK | §3.4 |
| "A6 ir_q updates only at UPD_IR / TLR" | `ir_q` changes only after Update-IR or in Test-Logic-Reset | §3.2 |
| a_irq_quiet_in_reset | `irq` = 0 in `rst_n` | §3.5 |
| a_tap_state | `tap_q` equals the model TAP | §3.1 |
| a_ir_model | `ir_q` equals the model IR | §3.2 |
| a_tdo_model | `tdo` equals the model's TCK-fall output | §3.3, §3.4 |
| a_irq_matches_updates | `irq` pulses = USER updates (at most one pending) | §3.5 |
| a_irq_pulse | `irq` is one `clk` | §3.5 |
