# UALink completer on the UPLI: READ, WRITE, FETCH_ADD, SWAP and CAS to a small memory over the request, originator data, read response and write response channels, each credited

Protocol IP `UALink`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `UALink_top` (`rtl/UALink_top.sv`) |
| Register interface | APB4 slave `UALink_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x554C0200 (code 0x554C, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | 21 pass-through |

## Overview

UALink_top v2.0: a UALink completer on the UPLI (UALink Protocol Level Interface): reads, writes and atomics to a local memory over the four UPLI channels, each credited

- Request channel (req_*): cmd 0 READ, 1 WRITE, 2 FETCH_ADD, 3 SWAP,
4 CAS (5..7 invalid), an 8-bit tag, a byte address and len (beats - 1,
beats of 8 bytes; atomics are one 64-bit beat, len 0). The completer
grants RQ request credits (req_crd pulses, one per free slot).
- Originator data channel (od_*): the data of WRITE (len + 1 beats with
byte enables), FETCH_ADD / SWAP (one beat: the operand) and CAS (two
beats: compare, then swap value), in request order; od_last marks
each request's last beat. DQ data credits (od_crd).
- Read response channel (rd_*): READ data (len + 1 beats, rd_last on
the last) and the old value of an atomic (one beat), with a status;
the originator grants a credit per beat (rd_crd).
- Write response channel (wr_*): WRITE and invalid commands, one
response with a status; credited by the originator (wr_crd).
- Status: 0 OK; 1 UR, the access runs past the MW-word memory; 2 BAD,
an invalid command, an address not 8-byte aligned or an atomic with
len != 0. A failed access has no effect; a failed read answers one
beat (data 0). Its data beats are still taken.
- Requests are executed in order, one at a time: a clock to take the
request, a clock per data beat, a clock per response beat (waiting
for a credit). An atomic updates memory as its response goes out.
- ev_err: a response with a non-OK status. ev_proto: a request or data
beat without a credit (dropped), an od_last that does not match the
beat count (the beat count wins), a response credit past 15
(ignored).
Not implemented: the UPLI virtual channels and their ordering rules,
multiple outstanding requests and out-of-order completion, the full
request field set (address width, size and byte-granular reads,
metadata, the atomic set beyond these three, poison), the UALink
transaction, data link and physical layers below UPLI. Field widths
and encodings are ours; they have not been checked against a UALink
originator.

req_*, od_*, rd_* and wr_* are the UPLI request, originator data, read response and write response channels to the originator; they pass through unchanged. The registers report the completer's error events.
The core parameters MW (16), RQ (4) and DQ (8) keep their defaults.

## Files

| File | Content |
|---|---|
| `rtl/UALink_top.sv` | protocol core |
| `rtl/UALink_apb.sv` | APB4 register wrapper (generated) |
| `tb/UALink_tb.sv` | core testbench |
| `tb/UALink_apb_tb.sv`, `tb/apb/UALink_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/UALink_sva.sv`, `tb/cov/UALink_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/UALink.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.UALink sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.UALink apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh UALink          # core coverage (Verilator)
bash scripts/cov/run_cov.sh UALink_apb      # wrapper coverage
```

## Parameters

`UALink_apb` has the core's parameters and passes them to `UALink_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `MW` | int | `16` |
| `RQ` | int | `4` |
| `DQ` | int | `8` |

## Wrapper pins

Pins of `UALink_apb`. Widths of the pass-through pins are at the default parameters.

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
| `req_valid` | input | 1 | protocol pin, core port `req_valid` |
| `req_cmd` | input | 3 | protocol pin, core port `req_cmd` |
| `req_tag` | input | 8 | protocol pin, core port `req_tag` |
| `req_addr` | input | 16 | protocol pin, core port `req_addr` |
| `req_len` | input | 3 | protocol pin, core port `req_len` |
| `req_crd` | output | 1 | protocol pin, core port `req_crd` |
| `od_valid` | input | 1 | protocol pin, core port `od_valid` |
| `od_data` | input | 64 | protocol pin, core port `od_data` |
| `od_be` | input | 8 | protocol pin, core port `od_be` |
| `od_last` | input | 1 | protocol pin, core port `od_last` |
| `od_crd` | output | 1 | protocol pin, core port `od_crd` |
| `rd_valid` | output | 1 | protocol pin, core port `rd_valid` |
| `rd_tag` | output | 8 | protocol pin, core port `rd_tag` |
| `rd_data` | output | 64 | protocol pin, core port `rd_data` |
| `rd_last` | output | 1 | protocol pin, core port `rd_last` |
| `rd_status` | output | 2 | protocol pin, core port `rd_status` |
| `rd_crd` | input | 1 | protocol pin, core port `rd_crd` |
| `wr_valid` | output | 1 | protocol pin, core port `wr_valid` |
| `wr_tag` | output | 8 | protocol pin, core port `wr_tag` |
| `wr_status` | output | 2 | protocol pin, core port `wr_status` |
| `wr_crd` | input | 1 | protocol pin, core port `wr_crd` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `req_valid` | input | 1 | pin (pass-through) |
| `req_cmd` | input | 3 | pin (pass-through) |
| `req_tag` | input | 8 | pin (pass-through) |
| `req_addr` | input | 16 | pin (pass-through) |
| `req_len` | input | 3 | pin (pass-through) |
| `req_crd` | output | 1 | pin (pass-through) |
| `od_valid` | input | 1 | pin (pass-through) |
| `od_data` | input | 64 | pin (pass-through) |
| `od_be` | input | 8 | pin (pass-through) |
| `od_last` | input | 1 | pin (pass-through) |
| `od_crd` | output | 1 | pin (pass-through) |
| `rd_valid` | output | 1 | pin (pass-through) |
| `rd_tag` | output | 8 | pin (pass-through) |
| `rd_data` | output | 64 | pin (pass-through) |
| `rd_last` | output | 1 | pin (pass-through) |
| `rd_status` | output | 2 | pin (pass-through) |
| `rd_crd` | input | 1 | pin (pass-through) |
| `wr_valid` | output | 1 | pin (pass-through) |
| `wr_tag` | output | 8 | pin (pass-through) |
| `wr_status` | output | 2 | pin (pass-through) |
| `wr_crd` | input | 1 | pin (pass-through) |
| `ev_err` | output | 1 | IRQ_STATUS.ERR |
| `ev_proto` | output | 1 | IRQ_STATUS.PROTO |

## APB wrapper

`UALink_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `req_valid`, `req_cmd`, `req_tag`, `req_addr`, `req_len`, `req_crd`, `od_valid`, `od_data`, `od_be`, `od_last`, `od_crd`, `rd_valid`, `rd_tag`, `rd_data`, `rd_last`, `rd_status`, `rd_crd`, `wr_valid`, `wr_tag`, `wr_status`, `wr_crd`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x554C0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x554C | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a response with a non-OK status: UR (the access runs past the memory) or BAD (invalid command, misaligned address, atomic with len != 0) |
| 1 | PROTO | a request or data beat without a credit (dropped), an od_last not matching the beat count, or a response credit past 15 |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x554C0200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/UALink_top.sv` | pass | 70/70 | 1722/1722 | 8/8 | 5/5 | 42/42 |
| wrapper `rtl/UALink_apb.sv` | pass | 19/19 | 792/792 | n/a | 7/7 | 27/27 |
