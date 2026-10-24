# AMBA LTI translation unit: translation requests (LA) answered in order on LR with context tags from a programmed table, completions (LC), link open / close with request credits, invalidation with synchronization

Protocol IP `ARM_Local_Translation_Interface`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `ARM_Local_Translation_Interface_top` (`rtl/ARM_Local_Translation_Interface_top.sv`) |
| Register interface | APB4 slave `ARM_Local_Translation_Interface_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x4C540200 (code 0x4C54, version 2.0) |
| Registers | 10 words, 0x000 to 0x024 |
| Interrupts | 5 sources into one level-high `irq` |
| Data streams | TBL (to the core), INV (to the core) |
| Protocol pins | 20 pass-through |

## Overview

ARM_Local_Translation_Interface_top v2.0: the translation side of an AMBA LTI (Local Translation Interface) link: translation requests (LA), responses (LR) with context tags, completions (LC), link open / close, a small translation table, invalidation with synchronization

- Link: the manager raises lm_open_req; the unit answers lm_open_ack
and then grants RQ request credits (la_credit pulses, one per free
request slot). A request on LA takes a credit. When lm_open_req
falls the unit stops granting, answers what it holds, waits for
every context tag to come back, and drops lm_open_ack; credits the
manager still holds are void from then on.
- LA: la_id, la_va (VA[31:12]), la_sid / la_ssid / la_ssidv (StreamID,
SubstreamID), la_rw (bit 0 read, bit 1 write), la_instr, la_priv.
Requests are answered in order, one per clock at most.
- Translation: NE table entries {sid, ssid (or any substream when
ssidv is clear), VA page, PA page, R / W / X / U permissions, attr},
written on cfg_*; the lowest matching entry is used. A read needs R,
a write W, an instruction fetch X, an unprivileged access U.
- LR: lr_resp 0 OK with lr_pa, lr_attr and a context tag lr_ctag; 1
translation fault (no entry), 2 permission fault (ev_fault on
either; a fault carries no tag). An OK response waits while all NCT
tags are in use.
- LC: the manager returns a tag once the transaction using the
translation is done (lc_valid, lc_ctag).
- Invalidation: inv_valid / inv_ready with inv_all or inv_sid clears
the matching entries at once; inv_done pulses once every tag handed
out before (or with) it has come back, so no transaction still uses
an old translation. inv_ready is low while one waits.
- ev_proto: a request without a credit (dropped), a tag returned that
is not out (ignored).
Not implemented: the LTI virtual channels and their ordering, the full
LA / LR field set (memory attributes in, stage 2, PASID prefixes, ATS,
MPAM, hints), the TBU's walk of real page tables (the table is
programmed directly), LR flow control, the LM channel beyond
open / close. Field widths and encodings are ours; they have not been
checked against an LTI manager.

lm_open_*, la_*, lr_* and lc_* are the LTI link, request, response and completion channels to the manager; they pass through unchanged.
The core parameters NE (8), RQ (4) and NCT (8) keep their defaults.

## Files

| File | Content |
|---|---|
| `rtl/ARM_Local_Translation_Interface_top.sv` | protocol core |
| `rtl/ARM_Local_Translation_Interface_apb.sv` | APB4 register wrapper (generated) |
| `tb/ARM_Local_Translation_Interface_tb.sv` | core testbench |
| `tb/ARM_Local_Translation_Interface_apb_tb.sv`, `tb/apb/ARM_Local_Translation_Interface_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/ARM_Local_Translation_Interface_sva.sv`, `tb/cov/ARM_Local_Translation_Interface_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/ARM_Local_Translation_Interface.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.ARM_Local_Translation_Interface sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.ARM_Local_Translation_Interface apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh ARM_Local_Translation_Interface          # core coverage (Verilator)
bash scripts/cov/run_cov.sh ARM_Local_Translation_Interface_apb      # wrapper coverage
```

## Parameters

`ARM_Local_Translation_Interface_apb` has the core's parameters and passes them to `ARM_Local_Translation_Interface_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NE` | int | `8` |
| `RQ` | int | `4` |
| `NCT` | int | `8` |

## Wrapper pins

Pins of `ARM_Local_Translation_Interface_apb`. Widths of the pass-through pins are at the default parameters.

| Pin | Dir | Width | Description |
|---|---|---|---|
| `PCLK` | input | 1 | APB clock; also the core clock |
| `PRESETN` | input | 1 | APB reset, active low; also the core reset |
| `PSEL` | input | 1 | slave select |
| `PENABLE` | input | 1 | access phase |
| `PWRITE` | input | 1 | 1 = write, 0 = read |
| `PADDR` | input | 12 | byte address; bits [1:0] must be 0 |
| `PWDATA` | input | 32 | write data |
| `PSTRB` | input | 4 | write byte strobes |
| `PRDATA` | output | 32 | read data |
| `PREADY` | output | 1 | always high in the access phase (no wait states) |
| `PSLVERR` | output | 1 | error: unmapped or misaligned address |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `lm_open_req` | input | 1 | protocol pin, core port `lm_open_req` |
| `lm_open_ack` | output | 1 | protocol pin, core port `lm_open_ack` |
| `la_valid` | input | 1 | protocol pin, core port `la_valid` |
| `la_id` | input | 4 | protocol pin, core port `la_id` |
| `la_va` | input | 20 | protocol pin, core port `la_va` |
| `la_sid` | input | 8 | protocol pin, core port `la_sid` |
| `la_ssid` | input | 8 | protocol pin, core port `la_ssid` |
| `la_ssidv` | input | 1 | protocol pin, core port `la_ssidv` |
| `la_rw` | input | 2 | protocol pin, core port `la_rw` |
| `la_instr` | input | 1 | protocol pin, core port `la_instr` |
| `la_priv` | input | 1 | protocol pin, core port `la_priv` |
| `la_credit` | output | 1 | protocol pin, core port `la_credit` |
| `lr_valid` | output | 1 | protocol pin, core port `lr_valid` |
| `lr_id` | output | 4 | protocol pin, core port `lr_id` |
| `lr_resp` | output | 2 | protocol pin, core port `lr_resp` |
| `lr_pa` | output | 20 | protocol pin, core port `lr_pa` |
| `lr_attr` | output | 8 | protocol pin, core port `lr_attr` |
| `lr_ctag` | output | 3 | protocol pin, core port `lr_ctag` |
| `lc_valid` | input | 1 | protocol pin, core port `lc_valid` |
| `lc_ctag` | input | 3 | protocol pin, core port `lc_ctag` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `lm_open_req` | input | 1 | pin (pass-through) |
| `lm_open_ack` | output | 1 | pin (pass-through) |
| `la_valid` | input | 1 | pin (pass-through) |
| `la_id` | input | 4 | pin (pass-through) |
| `la_va` | input | 20 | pin (pass-through) |
| `la_sid` | input | 8 | pin (pass-through) |
| `la_ssid` | input | 8 | pin (pass-through) |
| `la_ssidv` | input | 1 | pin (pass-through) |
| `la_rw` | input | 2 | pin (pass-through) |
| `la_instr` | input | 1 | pin (pass-through) |
| `la_priv` | input | 1 | pin (pass-through) |
| `la_credit` | output | 1 | pin (pass-through) |
| `lr_valid` | output | 1 | pin (pass-through) |
| `lr_id` | output | 4 | pin (pass-through) |
| `lr_resp` | output | 2 | pin (pass-through) |
| `lr_pa` | output | 20 | pin (pass-through) |
| `lr_attr` | output | 8 | pin (pass-through) |
| `lr_ctag` | output | 3 | pin (pass-through) |
| `lc_valid` | input | 1 | pin (pass-through) |
| `lc_ctag` | input | 3 | pin (pass-through) |
| `cfg_we` | input | 1 | TBL commit / FLAGS |
| `cfg_idx` | input | 3 | TBL0[19:17] |
| `cfg_v` | input | 1 | TBL0[20:20] |
| `cfg_sid` | input | 8 | TBL0[7:0] |
| `cfg_ssid` | input | 8 | TBL0[15:8] |
| `cfg_ssidv` | input | 1 | TBL0[16:16] |
| `cfg_va` | input | 20 | TBL1[19:0] |
| `cfg_pa` | input | 20 | TBL2[19:0] |
| `cfg_perm` | input | 4 | TBL0[24:21] |
| `cfg_attr` | input | 8 | TBL1[27:20] |
| `inv_valid` | input | 1 | INV commit / FLAGS |
| `inv_ready` | output | 1 | INV handshake |
| `inv_all` | input | 1 | INV[0:0] |
| `inv_sid` | input | 8 | INV[8:1] |
| `inv_done` | output | 1 | IRQ_STATUS.SYNC |
| `ctags_out` | output | 4 | STATUS[3:0] |
| `ev_fault` | output | 1 | IRQ_STATUS.FAULT |
| `ev_proto` | output | 1 | IRQ_STATUS.PROTO |

## APB wrapper

`ARM_Local_Translation_Interface_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `lm_open_req`, `lm_open_ack`, `la_valid`, `la_id`, `la_va`, `la_sid`, `la_ssid`, `la_ssidv`, `la_rw`, `la_instr`, `la_priv`, `la_credit`, `lr_valid`, `lr_id`, `lr_resp`, `lr_pa`, `lr_attr`, `lr_ctag`, `lc_valid`, `lc_ctag`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4C540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TBL0 | RW | 0x00000000 | Translation table entry; writing TBL2 writes entry cfg_idx |
| 0x018 | TBL1 | RW | 0x00000000 | Translation table entry; writing TBL2 writes entry cfg_idx |
| 0x01C | TBL2 | RW | 0x00000000 | Translation table entry; writing TBL2 writes entry cfg_idx |
| 0x020 | INV | RW | 0x00000000 | Invalidation; writing INV clears every entry (inv_all) or the entries of StreamID inv_sid. The core takes it once the one before has synchronized |
| 0x024 | STATUS | RO | core | Context tags |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4C54 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TBL0 | 7:0 | `cfg_sid` | RW | 0x0 | StreamID |
| TBL0 | 15:8 | `cfg_ssid` | RW | 0x0 | SubstreamID |
| TBL0 | 16 | `cfg_ssidv` | RW | 0x0 | set: the entry is for SubstreamID cfg_ssid only; clear: for any substream |
| TBL0 | 19:17 | `cfg_idx` | RW | 0x0 | entry |
| TBL0 | 20 | `cfg_v` | RW | 0x0 | valid |
| TBL0 | 24:21 | `cfg_perm` | RW | 0x0 | permissions {U, X, W, R} |
| TBL1 | 19:0 | `cfg_va` | RW | 0x0 | VA[31:12] |
| TBL1 | 27:20 | `cfg_attr` | RW | 0x0 | memory attributes returned on LR |
| TBL2 | 19:0 | `cfg_pa` | RW | 0x0 | PA[31:12] |
| INV | 0 | `inv_all` | RW | 0x0 | every entry |
| INV | 8:1 | `inv_sid` | RW | 0x0 | StreamID |
| STATUS | 3:0 | `ctags_out` | RO | core | context tags handed out on LR and not yet returned on LC |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FAULT | a translation or permission fault was returned on LR |
| 1 | PROTO | a request without a credit (dropped) or a context tag returned that was not out |
| 2 | SYNC | an invalidation has synchronized: every tag out when it was taken has come back |
| 3 | INV_DONE | INV beat accepted by the core |
| 4 | INV_OVF | write to INV while full (dropped) |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | INV_FULL | INV holds a beat the core has not taken |

### Streams

* **TBL** feeds `cfg_sid`, `cfg_ssid`, `cfg_ssidv`, `cfg_idx`, `cfg_v`, `cfg_perm`, `cfg_va`, `cfg_attr`, `cfg_pa`; writing TBL2 pulses `cfg_we` for one clock.
* **INV** feeds `inv_all`, `inv_sid`/`inv_valid`. Writing INV commits the beat: FLAGS.INV_FULL is set and `inv_valid` stays high until the core's `inv_ready`; then INV_DONE is set. A write while full is dropped and sets INV_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4C540200.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
4. To send on TBL: write TBL0 (0x014) then TBL1 (0x018) then TBL2 (0x01C). The last write pulses `cfg_we` for one clock; there is no back-pressure.
5. To send on INV: wait until FLAGS.INV_FULL (bit 0) is 0, or for IRQ INV_DONE, then write INV (0x020). The last write commits the beat. INV_OVF means a write came while the register was full and was dropped.
6. Read STATUS (0x024) for the core's live `ctags_out`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ARM_Local_Translation_Interface_top.sv` | pass | 51/51 | 2122/2122 | 6/6 | 5/5 | 93/93 |
| wrapper `rtl/ARM_Local_Translation_Interface_apb.sv` | pass | 36/36 | 960/960 | n/a | 20/20 | 53/53 |
