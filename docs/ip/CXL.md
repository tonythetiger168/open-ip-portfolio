# CXL.mem Type 3 device transaction layer: M2S Req and RwD in, S2M NDR and DRS out, host-managed device memory with a 2-bit meta state, poison and an HDM range decoder

Protocol IP `CXL`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `CXL_top` (`rtl/CXL_top.sv`) |
| Register interface | APB4 slave `CXL_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x43580200 (code 0x4358, version 2.0) |
| Registers | 16 words, 0x000 to 0x03C |
| Interrupts | 10 sources into one level-high `irq` |
| Data streams | REQ (to the core), RWD (to the core), NDR (from the core), DRS (from the core) |
| Protocol pins | none (register access only) |

## Overview

CXL_top v2.0: CXL.mem Type 3 device (memory expander) transaction layer: M2S Req and RwD in, S2M NDR and DRS out, host-managed device memory (HDM-H) with a 2-bit meta state, poison and a range decoder

- Channels: valid / ready, one message per handshake. A cache line is
64 bytes, carried in 8 beats of 64 bits (beat 0 = bytes 7:0). An RwD
message is 8 beats; its header fields are taken from beat 0. A DRS
message is 8 beats, drs_last on the eighth, with its fields steady.
- Address: req_addr / rwd_addr are host line addresses (byte address
bits 21:6). The HDM decoder maps hdm_base .. hdm_base + LINES - 1 to
the device's LINES lines (DPA = address - hdm_base, modulo 2^16); any other
address is out of range (ev_range): a read returns zeros with
drs_poison, a write is dropped, a completion is still sent.
- M2S Req opcodes: MemInv 0, MemRd 1, MemRdData 2, MemSpecRd 8,
MemInvNT 9, MemClnEvct 10. MemRdFwd 3, MemWrFwd 4 (HDM-DB only) and
the reserved codes are dropped with ev_opcode, no response.
MemRd / MemRdData: S2M DRS MemData with the line, its poison bit and
meta state. MemInv / MemInvNT / MemClnEvct: S2M NDR; for MemInv and
MemInvNT with MetaField Meta0-State the opcode follows MetaValue
(Cmp-S for Shared, Cmp-E for Any, Cmp otherwise), else Cmp.
MemSpecRd: no response (a prefetch hint).
- M2S RwD opcodes: MemWr 1 (the whole line; the poison bit replaces the
line's), MemWrPtl 2 (bytes with rwd_be set; poison is or-ed in);
S2M NDR Cmp. Others (BIConflict, reserved) are dropped (ev_opcode).
- Meta state (per line: Invalid 00, Any 10, Shared 11; reset Invalid):
MetaField Meta0-State (00) sets it to MetaValue for MemRd, MemInv,
MemInvNT, MemClnEvct, MemWr and MemWrPtl; No-Op (11) leaves it.
Responses carry the state before the request. A reserved MetaField
(01, 10) or SnpType (1xx) is taken as No-Op with ev_proto.
- Order: requests wait in a FIFO of RQD entries; a complete RwD line
waits in one write buffer. The two are served by round robin when
both wait, one per clock, when the response channel they need can
take a message. DevLoad in each response grades the requests left
waiting in the FIFO once it is served: none Light (00), 1 Optimal (01),
RQD - 1 or more Severe (11), else Moderate (10). Device memory is zero
after reset.
Not implemented: the flit / link layers and ARB/MUX, CXL.io and
CXL.cache, HDM-D / HDM-DB (back-invalidate, snoop filters, forwards),
interleaving and more than one HDM decoder, the extended meta field,
traffic classes, QoS telemetry beyond DevLoad, RAS logging. Field
encodings follow CXL 2.0 as we read them; they have not been checked
against a compliant host.

The core parameters LINES (16 cache lines of device memory) and RQD (4 Req FIFO entries) keep their defaults; device memory is zero after reset.

## Files

| File | Content |
|---|---|
| `rtl/CXL_top.sv` | protocol core |
| `rtl/CXL_apb.sv` | APB4 register wrapper (generated) |
| `tb/CXL_tb.sv` | core testbench |
| `tb/CXL_apb_tb.sv`, `tb/apb/CXL_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CXL_sva.sv`, `tb/cov/CXL_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CXL.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.CXL sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.CXL apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh CXL          # core coverage (Verilator)
bash scripts/cov/run_cov.sh CXL_apb      # wrapper coverage
```

## Parameters

`CXL_apb` has the core's parameters and passes them to `CXL_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `LINES` | int | `16` |
| `RQD` | int | `4` |

## Wrapper pins

Pins of `CXL_apb`. Widths of the pass-through pins are at the default parameters.

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

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `hdm_base` | input | 16 | CTRL[15:0] |
| `req_valid` | input | 1 | REQ commit / FLAGS |
| `req_ready` | output | 1 | REQ handshake |
| `req_opcode` | input | 4 | REQ1[3:0] |
| `req_meta_field` | input | 2 | REQ1[5:4] |
| `req_meta_value` | input | 2 | REQ1[7:6] |
| `req_snp_type` | input | 3 | REQ1[10:8] |
| `req_tag` | input | 16 | REQ0[31:16] |
| `req_addr` | input | 16 | REQ0[15:0] |
| `rwd_valid` | input | 1 | RWD commit / FLAGS |
| `rwd_ready` | output | 1 | RWD handshake |
| `rwd_opcode` | input | 4 | RWD3[11:8] |
| `rwd_meta_field` | input | 2 | RWD3[13:12] |
| `rwd_meta_value` | input | 2 | RWD3[15:14] |
| `rwd_snp_type` | input | 3 | RWD3[18:16] |
| `rwd_tag` | input | 16 | RWD0[31:16] |
| `rwd_addr` | input | 16 | RWD0[15:0] |
| `rwd_poison` | input | 1 | RWD3[19:19] |
| `rwd_data` | input | 64 | RWD1[31:0], RWD2[31:0] |
| `rwd_be` | input | 8 | RWD3[7:0] |
| `ndr_valid` | output | 1 | NDR capture |
| `ndr_ready` | input | 1 | NDR handshake |
| `ndr_opcode` | output | 2 | NDR[17:16] |
| `ndr_tag` | output | 16 | NDR[15:0] |
| `ndr_meta_value` | output | 2 | NDR[19:18] |
| `ndr_devload` | output | 2 | NDR[21:20] |
| `drs_valid` | output | 1 | DRS capture |
| `drs_ready` | input | 1 | DRS handshake |
| `drs_tag` | output | 16 | DRS2[15:0] |
| `drs_meta_value` | output | 2 | DRS2[17:16] |
| `drs_devload` | output | 2 | DRS2[19:18] |
| `drs_poison` | output | 1 | DRS2[20:20] |
| `drs_data` | output | 64 | DRS0[31:0], DRS1[31:0] |
| `drs_last` | output | 1 | DRS2[21:21] |
| `ev_range` | output | 1 | IRQ_STATUS.ERR_RANGE |
| `ev_opcode` | output | 1 | IRQ_STATUS.ERR_OPCODE |
| `ev_proto` | output | 1 | IRQ_STATUS.ERR_PROTO |
| `ev_poison` | output | 1 | IRQ_STATUS.POISON_RD |

## APB wrapper

`CXL_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43580200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | HDM decoder |
| 0x018 | REQ0 | RW | 0x00000000 | M2S Req message; writing REQ1 sends it (the core holds up to RQD = 4 requests) |
| 0x01C | REQ1 | RW | 0x00000000 | M2S Req message; writing REQ1 sends it (the core holds up to RQD = 4 requests) |
| 0x020 | RWD0 | RW | 0x00000000 | One beat of an M2S RwD message (8 beats of 8 bytes, beat 0 first); writing RWD3 sends the beat. The header fields are taken from beat 0; RWD0 need not be written again for beats 1..7 |
| 0x024 | RWD1 | RW | 0x00000000 | One beat of an M2S RwD message (8 beats of 8 bytes, beat 0 first); writing RWD3 sends the beat. The header fields are taken from beat 0; RWD0 need not be written again for beats 1..7 |
| 0x028 | RWD2 | RW | 0x00000000 | One beat of an M2S RwD message (8 beats of 8 bytes, beat 0 first); writing RWD3 sends the beat. The header fields are taken from beat 0; RWD0 need not be written again for beats 1..7 |
| 0x02C | RWD3 | RW | 0x00000000 | One beat of an M2S RwD message (8 beats of 8 bytes, beat 0 first); writing RWD3 sends the beat. The header fields are taken from beat 0; RWD0 need not be written again for beats 1..7 |
| 0x030 | NDR | RO (pop) | 0x00000000 | S2M NDR message (completion of MemInv, MemInvNT, MemClnEvct, MemWr, MemWrPtl); reading it pops it |
| 0x034 | DRS0 | RO (pop) | 0x00000000 | One beat of an S2M DRS MemData message (8 beats per line); reading DRS2 pops it |
| 0x038 | DRS1 | RO (pop) | 0x00000000 | One beat of an S2M DRS MemData message (8 beats per line); reading DRS2 pops it |
| 0x03C | DRS2 | RO (pop) | 0x00000000 | One beat of an S2M DRS MemData message (8 beats per line); reading DRS2 pops it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x040 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4358 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 9:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 9:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 3:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 15:0 | `hdm_base` | RW | 0x0 | first host line address (byte address bits 21:6) of the device's LINES = 16 lines; change it only while no message is in flight |
| REQ0 | 15:0 | `req_addr` | RW | 0x0 | host line address |
| REQ0 | 31:16 | `req_tag` | RW | 0x0 | tag, returned in the response |
| REQ1 | 3:0 | `req_opcode` | RW | 0x0 | MemInv 0, MemRd 1, MemRdData 2, MemSpecRd 8, MemInvNT 9, MemClnEvct 10 (others are dropped: ERR_OPCODE) |
| REQ1 | 5:4 | `req_meta_field` | RW | 0x0 | Meta0-State 00, No-Op 11 (01, 10: ERR_PROTO, taken as No-Op) |
| REQ1 | 7:6 | `req_meta_value` | RW | 0x0 | new meta state for Meta0-State: Invalid 00, Any 10, Shared 11 |
| REQ1 | 10:8 | `req_snp_type` | RW | 0x0 | SnpType (1xx: ERR_PROTO) |
| RWD0 | 15:0 | `rwd_addr` | RW | 0x0 | host line address |
| RWD0 | 31:16 | `rwd_tag` | RW | 0x0 | tag, returned in the NDR |
| RWD1 | 31:0 | `rwd_data[31:0]` | RW | 0x0 | 8 data bytes |
| RWD2 | 31:0 | `rwd_data[63:32]` | RW | 0x0 | 8 data bytes |
| RWD3 | 7:0 | `rwd_be` | RW | 0x0 | byte enables (MemWrPtl) |
| RWD3 | 11:8 | `rwd_opcode` | RW | 0x0 | MemWr 1, MemWrPtl 2 (others are dropped: ERR_OPCODE) |
| RWD3 | 13:12 | `rwd_meta_field` | RW | 0x0 | Meta0-State 00, No-Op 11 |
| RWD3 | 15:14 | `rwd_meta_value` | RW | 0x0 | new meta state |
| RWD3 | 18:16 | `rwd_snp_type` | RW | 0x0 | SnpType |
| RWD3 | 19 | `rwd_poison` | RW | 0x0 | the data is poisoned |
| NDR | 15:0 | `ndr_tag` | RO (pop) | 0x0 | the request's tag |
| NDR | 17:16 | `ndr_opcode` | RO (pop) | 0x0 | Cmp 0, Cmp-S 1, Cmp-E 2 |
| NDR | 19:18 | `ndr_meta_value` | RO (pop) | 0x0 | the line's meta state before the request |
| NDR | 21:20 | `ndr_devload` | RO (pop) | 0x0 | DevLoad: Light 0, Optimal 1, Moderate 2, Severe 3 |
| DRS0 | 31:0 | `drs_data[31:0]` | RO (pop) | 0x0 | 8 data bytes |
| DRS1 | 31:0 | `drs_data[63:32]` | RO (pop) | 0x0 | 8 data bytes |
| DRS2 | 15:0 | `drs_tag` | RO (pop) | 0x0 | the request's tag |
| DRS2 | 17:16 | `drs_meta_value` | RO (pop) | 0x0 | the line's meta state before the request |
| DRS2 | 19:18 | `drs_devload` | RO (pop) | 0x0 | DevLoad |
| DRS2 | 20 | `drs_poison` | RO (pop) | 0x0 | the line is poisoned (or the address was out of range) |
| DRS2 | 21 | `drs_last` | RO (pop) | 0x0 | the eighth beat |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR_RANGE | a request or write outside the HDM range (reads return poisoned zeros, writes are dropped; both complete) |
| 1 | ERR_OPCODE | an unsupported opcode: the message was dropped without a response |
| 2 | ERR_PROTO | a reserved MetaField or SnpType (taken as No-Op) |
| 3 | POISON_RD | a read returned a poisoned line |
| 4 | REQ_DONE | REQ beat accepted by the core |
| 5 | REQ_OVF | write to REQ while full (dropped) |
| 6 | RWD_DONE | RWD beat accepted by the core |
| 7 | RWD_OVF | write to RWD while full (dropped) |
| 8 | NDR_AVAIL | NDR captured a beat |
| 9 | DRS_AVAIL | DRS captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | REQ_FULL | REQ holds a beat the core has not taken |
| 1 | RWD_FULL | RWD holds a beat the core has not taken |
| 2 | NDR_AVAIL | NDR holds an unread beat |
| 3 | DRS_AVAIL | DRS holds an unread beat |

### Streams

* **REQ** feeds `req_addr`, `req_tag`, `req_opcode`, `req_meta_field`, `req_meta_value`, `req_snp_type`/`req_valid`. Writing REQ1 commits the beat: FLAGS.REQ_FULL is set and `req_valid` stays high until the core's `req_ready`; then REQ_DONE is set. A write while full is dropped and sets REQ_OVF.
* **RWD** feeds `rwd_addr`, `rwd_tag`, `rwd_data`, `rwd_be`, `rwd_opcode`, `rwd_meta_field`, `rwd_meta_value`, `rwd_snp_type`, `rwd_poison`/`rwd_valid`. Writing RWD3 commits the beat: FLAGS.RWD_FULL is set and `rwd_valid` stays high until the core's `rwd_ready`; then RWD_DONE is set. A write while full is dropped and sets RWD_OVF.
* **NDR** takes `ndr_tag`, `ndr_opcode`, `ndr_meta_value`, `ndr_devload` from the core with `ndr_valid` / `ndr_ready`: `ndr_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ NDR_AVAIL. Reading NDR pops it. Nothing is dropped: the core holds its data until the register is free.
* **DRS** takes `drs_data`, `drs_tag`, `drs_meta_value`, `drs_devload`, `drs_poison`, `drs_last` from the core with `drs_valid` / `drs_ready`: `drs_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ DRS_AVAIL. Reading DRS2 pops it. Nothing is dropped: the core holds its data until the register is free.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43580200.
2. Write 0x3FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3FF enables all).
5. To send on REQ: wait until FLAGS.REQ_FULL (bit 0) is 0, or for IRQ REQ_DONE, then write REQ0 (0x018) then REQ1 (0x01C). The last write commits the beat. REQ_OVF means a write came while the register was full and was dropped.
6. To send on RWD: wait until FLAGS.RWD_FULL (bit 1) is 0, or for IRQ RWD_DONE, then write RWD0 (0x020) then RWD1 (0x024) then RWD2 (0x028) then RWD3 (0x02C). The last write commits the beat. RWD_OVF means a write came while the register was full and was dropped.
7. To receive on NDR: wait for IRQ NDR_AVAIL or FLAGS.NDR_AVAIL (bit 2), then read NDR (0x030). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.NDR_AVAIL (bit 8) to clear it.
8. To receive on DRS: wait for IRQ DRS_AVAIL or FLAGS.DRS_AVAIL (bit 3), then read DRS0 (0x034) then DRS1 (0x038) then DRS2 (0x03C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.DRS_AVAIL (bit 9) to clear it.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CXL_top.sv` | pass | 64/64 | 1416/1416 | n/a | 6/6 | 138/138 |
| wrapper `rtl/CXL_apb.sv` | pass | 57/57 | 1638/1638 | n/a | 28/28 | 97/97 |
