<!-- SPDX-License-Identifier: Apache-2.0 -->
# USB_Type_C_Port_Controller: design specification

A USB Type-C port controller's attach / detach logic for a dual-role port acting as source:
debounced sink attach on CC1 or CC2 with orientation, debounced detach, VBUS enable, CC fault
detection, and an 8 x 8-bit register file. Not implemented: the TCPCI register map and I2C, sink
and DRP toggling state machines, Rp current advertisement, VCONN, USB PD messaging, analog CC
comparators (the CC levels arrive already encoded). Core `USB_Type_C_Port_Controller_top`
(`rtl/USB_Type_C_Port_Controller_top.sv`), testbench `tb/USB_Type_C_Port_Controller_tb.sv` (the
port partner driving CC levels), checker `tb/cov/USB_Type_C_Port_Controller_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cc1` | input | 2 | CC1 level: 00 open, 01 Rd, 10 Ra, 11 abnormal (fault) | - | `clk` | - |
| `cc2` | input | 2 | CC2 level, same encoding | - | `clk` | - |
| `attached` | output | 1 | a sink is attached (state ATTACHED); combinational from the state | high | comb | 0 |
| `orientation` | output | 1 | 0: CC1 is the wired CC, 1: CC2 (set when debouncing starts, kept after detach) | - | `clk` | 0 |
| `vbus_en` | output | 1 | VBUS source enable: attached and source role; combinational | high | comb | 0 |
| `reg_addr` | input | 3 | register address (§3.4) | - | `clk` | - |
| `reg_wdata` | input | 8 | register write data | - | `clk` | - |
| `reg_rdata` | output | 8 | register read data for `reg_addr`; combinational | - | comb | - |
| `reg_rd` | input | 1 | read strobe (no side effect; unused) | high | `clk` | - |
| `reg_wr` | input | 1 | register write at this edge | high | `clk` | - |
| `irq` | output | 1 | abnormal CC level now, or any INT_STAT bit set; combinational | high | comb | 0 |

### Internal signals used by the verification

The TB reads these by name (its in-TB assertions A2..A6); the FSM coverage collector binds `state`.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 2 | 0 UNATTACHED, 1 ATTACHWAIT, 2 ATTACHED (3 unused, goes to 0) |
| `role_src_q` | 1 | ROLE_CTRL bit 0: 1 source |
| `int_sticky` | 3 | INT_STAT {fault, detach, attach} |
| `deb_cnt` | 7 | attach debounce counter, 0..99 |
| `rel_cnt` | 4 | detach debounce counter, 0..9 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/USB_Type_C_Port_Controller.md`](../ip/USB_Type_C_Port_Controller.md) (source: `scripts/apb/specs/USB_Type_C_Port_Controller.json`); do not edit by hand.

`USB_Type_C_Port_Controller_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `cc1`, `cc2`, `attached`, `orientation`, `vbus_en`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x54430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CC_STATUS | RO (core) | core | {attached, orientation, fsm[1:0], cc2[1:0], cc1[1:0]} (fsm: 0 unattached, 1 attach wait, 2 attached) |
| 0x018 | ROLE_CTRL | RW (core) | core | bit 0: 1 = source / DFP (reset), 0 = sink / UFP; vbus_en needs the source role |
| 0x01C | FAULT_STAT | RW (core) | core | bit 0: abnormal CC level seen (sticky, write 1 to clear; a fault in the same clock wins) |
| 0x020 | INT_STAT | RW (core) | core | bit 0 attach, bit 1 detach, bit 2 fault (sticky, write 1 to clear; a new event in the same clock wins) |
| 0x024 | DEBOUNCE | RO (core) | core | attach debounce in clocks (100) |
| 0x028 | ORIENT | RO (core) | core | bit 0: orientation (1 = CC2 is the wired CC) |
| 0x02C | VBUS_STAT | RO (core) | core | bit 0: vbus_en |
| 0x030 | DEVICE_ID | RO (core) | core | device ID 0xC7 |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x034 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5443 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CC_STATUS | 7:0 | core register | RO (core) | core | read from core register 0 |
| ROLE_CTRL | 7:0 | core register | RW (core) | core | written at core register 1 and read from core register 1 |
| FAULT_STAT | 7:0 | core register | RW (core) | core | written at core register 2 and read from core register 2 |
| INT_STAT | 7:0 | core register | RW (core) | core | written at core register 3 and read from core register 3 |
| DEBOUNCE | 7:0 | core register | RO (core) | core | read from core register 4 |
| ORIENT | 7:0 | core register | RO (core) | core | read from core register 5 |
| VBUS_STAT | 7:0 | core register | RO (core) | core | read from core register 6 |
| DEVICE_ID | 7:0 | core register | RO (core) | core | read from core register 7 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | EVENT | an abnormal CC level is present or an INT_STAT bit is set; held while either lasts, so the bit is set again on every clock until INT_STAT is cleared and the fault is gone |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `reg_wr` for one clock with `reg_addr` (the core register) and `reg_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `reg_addr` (the core register) and pulses `reg_rd` during the access phase and returns `reg_rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x54430200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Attach

A sink candidate is Rd on exactly one CC pin (Ra-only, Rd on both, or open is not a candidate),
with no abnormal level (11) on either pin.

* UNATTACHED: at an edge with a candidate -> ATTACHWAIT, debounce counter 0, orientation = 1 if
  the Rd is on CC2.
* ATTACHWAIT: at each edge, if the candidate is gone, the Rd moved to the other pin, or an
  abnormal level is present -> UNATTACHED; else at counter 99 -> ATTACHED (INT_STAT attach set),
  else the counter + 1.

So Rd must be seen at 101 consecutive edges; `attached` rises after the 101st.

### 3.2 Detach

In ATTACHED, at each edge where the wired CC pin (by orientation) is open the release counter
+ 1; at counter 9 with the pin open -> UNATTACHED (INT_STAT detach set). Any edge with the pin not
open resets the counter. So 10 consecutive open edges detach. Levels on the other pin are not
looked at.

### 3.3 Fault, interrupts and VBUS

* An abnormal level on either pin sets FAULT_STAT and INT_STAT bit 2 at every edge it is present,
  and drives `irq` directly while present.
* INT_STAT bits are set by hardware events and cleared by writing 1 (RW1C); a set in the same
  clock as a clear wins.
* `irq` = abnormal level now OR INT_STAT != 0.
* `vbus_en` = ATTACHED and ROLE_CTRL bit 0; a role change shows from the clock after the write.

### 3.4 Registers

| Address | Register | Access | Value |
|---|---|---|---|
| 0 | CC_STATUS | RO | {attached, orientation, state[1:0], cc2, cc1} (live CC levels) |
| 1 | ROLE_CTRL | RW | bit 0: 1 source (reset), 0 sink |
| 2 | FAULT_STAT | RW1C | bit 0: abnormal level seen |
| 3 | INT_STAT | RW1C | bit 0 attach, bit 1 detach, bit 2 fault |
| 4 | DEBOUNCE | RO | 100 |
| 5 | ORIENT | RO | bit 0 orientation |
| 6 | VBUS_STAT | RO | bit 0 `vbus_en` |
| 7 | DEVICE_ID | RO | 0xC7 |

`reg_rdata` follows `reg_addr` combinationally. Writes to read-only registers are ignored; unused
bits read 0.

### 3.5 Reset

While `rst_n` is low: UNATTACHED, counters 0, orientation 0, source role, status bits 0; so
`attached`, `vbus_en` 0 and `irq` = abnormal level only (0 in the TB).

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | any | unused (kept for the framework) |
| `AW` | 32 | any | unused (kept for the framework) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| Rd shorter than the debounce | no attach, no event |
| Rd moves to the other pin while debouncing | restarts from UNATTACHED |
| abnormal level while debouncing | restarts; FAULT and INT bit 2 set |
| Ra on one pin and Rd on the other (powered cable) | attaches on the Rd pin |
| Ra only, or Rd on both pins | no attach |
| active pin open for fewer than 10 clocks | stays attached |
| role changed while attached | `vbus_en` follows the role |
| reset while attached | UNATTACHED, no detach event |

## 6. TB check map

Messages are printed by `tb/USB_Type_C_Port_Controller_tb.sv` as `ERROR: <message>` (TB checks)
or `SVA_FAIL: <name>` (the in-TB assertions A1..A7). Assertions `a_*` are in the bound checker
`tb/cov/USB_Type_C_Port_Controller_sva.sv`. The TB drives attach / detach on either pin,
flipped plugs, glitches, pin swaps and faults during debounce, short releases, role changes,
powered cables and random scenarios, and reads the registers.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "reg read" | register read value | §3.4 |
| "A1 reset: outputs quiescent" | outputs 0 in reset | §3.5 |
| "A2 state encoding legal" | `state` <= 2 | §3.1 |
| "A3 vbus_en == attached&&src" | `vbus_en` = attached and source role | §3.3 |
| "A4 attached == ST_ATTACHED" | `attached` = state ATTACHED | §3.1 |
| "A5 irq composition" | `irq` = abnormal level or INT_STAT | §3.3 |
| "A6 debounce ranges" | counters within 0..99 / 0..9 | §3.1, §3.2 |
| "A7 unattached => vbus off" | no VBUS when UNATTACHED | §3.3 |
| "CRV attach after full debounce" | attach after 101 edges of Rd | §3.1 |
| "CRV orientation matches wired CC pin" | orientation from the Rd pin | §3.1 |
| "CRV irq after attach event" | attach sets INT_STAT bit 0 | §3.3 |
| "CRV irq cleared after attach W1C" | RW1C clears it | §3.3 |
| "CRV detach after release debounce" | detach after 10 open edges | §3.2 |
| "CRV irq after detach event" | detach sets INT_STAT bit 1 | §3.3 |
| "CRV glitch must not attach" | short Rd does not attach | §3.1 |
| "CRV still unattached after glitch" | UNATTACHED after a glitch | §3.1 |
| "CRV irq on CC fault" | abnormal level raises `irq` | §3.3 |
| "CRV irq sticky after fault removed" | INT bit 2 keeps `irq` | §3.3 |
| "CRV irq cleared after fault W1C" | RW1C clears it | §3.3 |
| "CRV Ra-only/both-Rd must not attach" | not a sink candidate | §3.1 |
| "CRV no events for non-sink levels" | no INT bits for them | §3.1 |
| "CRV detach-glitch: attached first" | attached before the release glitch | §3.1 |
| "CRV short release must not detach" | fewer than 10 open edges keep ATTACHED | §3.2 |
| "CRV no detach event after short release" | no INT bit 1 | §3.2 |
| "CRV detach-glitch: final detach" | a full release detaches | §3.2 |
| "CRV role: attached" | attached before the role test | §3.1 |
| "CRV vbus_en follows role while attached" | `vbus_en` follows ROLE_CTRL | §3.3 |
| "reset state outputs" | reset values | §3.5 |
| "attached before debounce done" | not attached early | §3.1 |
| "attached after debounce" | attached after the debounce | §3.1 |
| "orientation=0 for cc1 attach" | orientation 0 | §3.1 |
| "vbus_en on (source role)" | `vbus_en` in source role | §3.3 |
| "irq after attach event" | attach event | §3.3 |
| "irq cleared by W1C" | RW1C | §3.3 |
| "still attached during detach debounce" | attached during the release count | §3.2 |
| "detached after release debounce" | detach after 10 open edges | §3.2 |
| "vbus_en off after detach" | no VBUS after detach | §3.3 |
| "irq after detach event" | detach event | §3.3 |
| "attached cc2" | attach on CC2 | §3.1 |
| "orientation=1 for cc2 attach" | orientation 1 | §3.1 |
| "vbus_en on cc2 attach" | `vbus_en` on a CC2 attach | §3.3 |
| "vbus_en off in sink role" | sink role: no VBUS | §3.3 |
| "still attached in sink role" | role does not change `attached` | §3.3 |
| "vbus_en back in source role" | source role again | §3.3 |
| "irq on CC fault" | abnormal level | §3.3 |
| "irq sticky after fault removed" | INT bit 2 | §3.3 |
| "irq cleared after fault W1C" | RW1C | §3.3 |
| "glitch attach rejected" | short Rd | §3.1 |
| "cycle-3 attach" | repeated attach | §3.1 |
| "cycle-3 detach" | repeated detach | §3.2 |
| "pin swap during debounce must restart it" | Rd moving restarts | §3.1 |
| "attached on cc2 after full debounce" | a full debounce on the new pin | §3.1 |
| "detach after pin-swap attach" | detach on CC2 | §3.2 |
| "fault during debounce must restart it" | abnormal level restarts | §3.1 |
| "attached after fault-free debounce" | then a clean debounce attaches | §3.1 |
| "reset while attached" | reset clears the attach | §3.5 |
| "no attach without Rd" | open / Ra only | §3.1 |
| "powered cable attaches on the Rd pin" | Ra + Rd attaches on the Rd pin | §3.1 |
| "read-only writes ignored" | RO registers unchanged by writes | §3.4 |
| "powered cable detach" | detach on the Rd pin | §3.2 |
| a_reset_state | in reset: outputs 0, read data as the model | §3.5 |
| a_attach_model | `attached` / orientation as the checker's model | §3.1, §3.2 |
| a_vbus_model | `vbus_en` as the model | §3.3 |
| a_irq_model | `irq` as the model | §3.3 |
| a_readback_model | `reg_rdata` as the model | §3.4 |
