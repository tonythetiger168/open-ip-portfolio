<!-- SPDX-License-Identifier: Apache-2.0 -->
# APB: design specification

APB3 completer (slave) with a 256-word register file, a zero-wait-state "fast" window, a
one-wait-state "slow" window onto the same registers, and a reserved window that completes with
PSLVERR and pulses an interrupt. Core `APB_top` (`rtl/APB_top.sv`), testbench `tb/APB_tb.sv`
(an APB3 requester model), checker `tb/cov/APB_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. APB terms: a SETUP cycle has `psel` = 1, `penable` = 0; the
ACCESS cycles that follow have `psel` = `penable` = 1; the transfer completes at the end of the
ACCESS cycle in which `pready` = 1.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | PCLK | rising edge | - | - |
| `rst_n` | input | 1 | PRESETn: asynchronous reset of the state, the captured attributes and the whole register file | low | async assert | - |
| `psel` | input | 1 | PSEL | high | clk | - |
| `penable` | input | 1 | PENABLE | high | clk | - |
| `paddr` | input | `AW` | PADDR, byte address; captured in the SETUP cycle; only bits 11:10 (window) and 9:2 (word) are decoded | - | clk | - |
| `pwrite` | input | 1 | PWRITE, 1 = write; captured in the SETUP cycle | - | clk | - |
| `pwdata` | input | `DW` | PWDATA; written at the completing edge (the value in the last ACCESS cycle is used) | - | clk | - |
| `prdata` | output | `DW` | PRDATA, combinational: register contents during every ACCESS cycle of a read to the fast or slow window, else 0 | - | comb. | 0 |
| `pready` | output | 1 | PREADY, combinational: 1 in an ACCESS cycle with `penable` = 1, except the first ACCESS cycle of a slow-window transfer; 0 outside ACCESS | high | comb. | 0 |
| `pslverr` | output | 1 | PSLVERR, combinational: `pready` = 1 in ACCESS and the transfer is to the reserved window | high | comb. | 0 |
| `irq` | output | 1 | equal to `pslverr`: a one-clock event at each errored completion | high | comb. | 0 |

### Internal signals used by the verification

The TB and the `.*`-bound checker read these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 1 | 0 = IDLE (no transfer, or the SETUP cycle), 1 = ACCESS |
| `setup_cycle` | 1 | `state == 0 && psel && !penable` |
| `access_finish` | 1 | `state == 1 && penable && pready`: the transfer completes at the end of this cycle |
| `write_q` | 1 | `pwrite` captured in the SETUP cycle |
| `addr_q` | `AW` | `paddr` captured in the SETUP cycle |
| `slow_q` | 1 | `paddr[11:10] == 2'b01` captured in the SETUP cycle |
| `err_q` | 1 | `paddr[11]` captured in the SETUP cycle (reserved window) |
| `waited_q` | 1 | the slow transfer's wait cycle has been spent (cleared at SETUP, set at the end of an ACCESS cycle with `pready` = 0) |

## 2. Registers

Address map (byte addresses, `paddr[11:10]`):

| Window | `paddr[11:10]` | Wait states | Register | Response |
|---|---|---|---|---|
| fast | 00 (0x000-0x3FF) | 0 | word `paddr[9:2]` of the 256 x `DW` register file | OKAY |
| slow | 01 (0x400-0x7FF) | 1 | the same word `paddr[9:2]` (alias of the fast window) | OKAY |
| reserved | 1x (0x800-0xFFF) | 0 | none: writes dropped, reads return 0 | PSLVERR, `irq` |

Every register is RW, reset 0x0, no side effects. `paddr` bits 1:0 and above bit 11 are ignored
(the map repeats every 4 KB).

<!-- AUTO:registers -->
Generated from [`docs/ip/APB.md`](../ip/APB.md) (source: `scripts/apb/specs/APB.json`); do not edit by hand.

`APB_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `psel`, `penable`, `paddr`, `pwrite`, `pwdata`, `prdata`, `pready`, `pslverr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4150 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a transfer to the reserved region (paddr[11] set) completed with PSLVERR |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41500200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 State machine

- IDLE → ACCESS at the end of a SETUP cycle (`state` = 0, `psel` = 1, `penable` = 0). At that
  edge `write_q`, `addr_q`, `slow_q`, `err_q` are captured and `waited_q` cleared.
- ACCESS → IDLE at the end of the completing cycle (`access_finish`); otherwise ACCESS holds.
- `penable` = 1 without a preceding SETUP (state IDLE) is ignored: `pready` stays 0, nothing is
  written.
- Back to back: if `psel` stays 1 and `penable` drops to 0 in the cycle after completion, that
  cycle is the next SETUP (no idle cycle needed).

### 3.2 Wait states

- fast and reserved windows: `pready` = 1 in the first ACCESS cycle (zero wait states).
- slow window: `pready` = 0 in the first ACCESS cycle (`waited_q` <= 1 at its end), 1 in the
  second (exactly one wait state). `pslverr` is 0 while `pready` is 0.

### 3.3 Data

- Write: at the completing edge, if `write_q` and not `err_q`, word `addr_q[9:2]` <= `pwdata`.
- Read: `prdata` = word `addr_q[9:2]` during all ACCESS cycles of a read to the fast or slow
  window, so it is valid in the completing cycle and reflects a write that completed in the
  previous transfer. `prdata` = 0 in IDLE / SETUP, during writes and for reserved reads.
- Reserved: `pslverr` = `irq` = 1 in the completing cycle (one clock); nothing is written.

### 3.4 Reset

`rst_n` low: `state` = IDLE, captured attributes 0, every register-file word 0 (at once), so
`pready` = `pslverr` = `irq` = 0 and `prdata` = 0. A transfer in its wait state is abandoned and
its write does not land.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | ≥ 1 | data width of `pwdata`, `prdata` and the registers |
| `AW` | 32 | ≥ 12 (bits 11:2 are decoded) | width of `paddr` |
| `DEPTH` | 256 | 256 (the word index is `paddr[9:2]`) | register-file words |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| access to 0x800-0xFFF | PSLVERR + `irq` in the completing cycle, zero wait; write dropped, read data 0 |
| write to the reserved window whose low bits alias a used word | the word is not changed |
| `penable` without `psel` / SETUP | ignored |
| `pwdata` changing between SETUP and completion | the value in the completing cycle is written |
| reset during a wait state | outputs quiescent at once; the write does not land; registers cleared |
| read right after a write to the same word | returns the new value |

## 6. TB check map

Messages are printed by `tb/APB_tb.sv` as `ERROR: <message>`; the "CRV" messages and A1..A6
are built only for Verilator. Assertions a_* are in `tb/cov/APB_sva.sv`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "reset: pready must be 0 outside ACCESS" | in reset `pready` = 0 | §3.4 |
| "reset: pslverr must be 0" | in reset `pslverr` = 0 | §3.4 |
| "reset: prdata must be 0" | in reset `prdata` = 0 | §3.4 |
| "reset: irq must be 0" | in reset `irq` = 0 | §3.4 |
| "apb: pslverr must be low while pready=0" | no PSLVERR in a wait cycle | §3.2 |
| "apb_write: pslverr mismatch" | PSLVERR at write completion exactly for the reserved window | §3.3, §5 |
| "apb_write: irq expected on pslverr" | `irq` with PSLVERR | §3.3 |
| "apb_read: pslverr mismatch" | PSLVERR at read completion exactly for the reserved window | §3.3 |
| "apb_read: data mismatch" | read data = last value written to the word (via either window) | §2, §3.3 |
| "apb_read: irq expected on pslverr" | `irq` with PSLVERR | §3.3 |
| "fast write: no wait state expected" | fast write completes in the first ACCESS cycle | §3.2 |
| "fast read: no wait state expected" | fast read completes in the first ACCESS cycle | §3.2 |
| "slow write: exactly one wait state expected" | slow write: one wait cycle | §3.2 |
| "slow read: exactly one wait state expected" | slow read: one wait cycle | §3.2 |
| "penable w/o psel must be ignored" | `pready` = `pslverr` = 0 for `penable` without a transfer | §3.1 |
| "b2b: write0 pslverr" | back-to-back write without idle: no error | §3.1 |
| "b2b: write1 pslverr" | second back-to-back write: no error | §3.1 |
| "b2b: read0 data mismatch" | back-to-back read returns the first write | §3.1, §3.3 |
| "b2b: read1 data mismatch" | back-to-back read returns the second write | §3.1, §3.3 |
| "mid-access reset: expected wait state" | first ACCESS cycle of a slow write has `pready` = 0 | §3.2 |
| "mid-access reset: outputs must be quiescent" | reset in the wait state: outputs 0 at once | §3.4 |
| "pairs: read-back mismatch" | wr→rd pairs with psel held return the data | §3.1, §3.3 |
| "pairs: inverted read-back mismatch" | second word of a wr→wr pair reads back | §3.3 |
| "pairs: rd-rd read-back mismatch" | rd→rd pairs return the data | §3.3 |
| "pairs: reserved access without pslverr" | ok→reserved back to back: PSLVERR | §3.3 |
| "pairs: read after error" | reserved→ok back to back: correct data, no error | §3.1, §3.3 |
| "CRV: reserved transfer must pslverr" | random reserved transfers error | §5 |
| "CRV: reserved transfer must raise irq" | and raise `irq` | §5 |
| "CRV: reserved read returns 0" | and read 0 | §5 |
| "A1 reset: outputs quiescent" | in reset `pready`, `pslverr`, `irq` = 0 | §3.4 |
| "A2 pslverr only at completion" | PSLVERR only with `psel`, `penable`, `pready` | §3.3 |
| "A3 irq implies pslverr" | `irq` only with PSLVERR | §1 |
| "A4 pready implies penable" | `pready` only with `penable` | §1, §3.2 |
| "A5 pready implies psel" | `pready` only with `psel` | §3.1 |
| "A6 prdata zero on pslverr" | errored completion returns 0 | §3.3 |
| "TIMEOUT guard fired" | the test finishes (no stuck transfer) | §3.1 |
| a_reset_quiet | in reset: outputs 0, IDLE | §3.4 |
| a_pslverr_at_completion | PSLVERR only in a completing ACCESS cycle | §3.3 |
| a_irq_is_pslverr | `irq` = `pslverr` | §1 |
| a_pready_in_access | `pready` only in ACCESS with `psel`, `penable` | §3.2 |
| a_setup_to_access | SETUP → ACCESS next cycle | §3.1 |
| a_completion_to_idle | completion → IDLE next cycle | §3.1 |
| a_slow_one_wait | slow window: `pready` 0 then 1 | §3.2 |
| a_fast_zero_wait | fast / reserved: `pready` in the first ACCESS cycle | §3.2 |
| a_err_on_reserved | reserved → PSLVERR at completion | §3.3 |
| a_no_err_on_valid | fast / slow → no PSLVERR | §3.3 |
| a_read_data | read data equals the shadow register file | §3.3 |
| a_err_read_zero | PSLVERR → `prdata` = 0 | §3.3 |
| a_prdata_zero_outside_read | `prdata` = 0 in IDLE and in writes | §3.3 |
| a_attrs_stable_in_access | captured address and direction do not change during ACCESS | §3.1 |
