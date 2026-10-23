# OCP-IP master: software transactions (single words and INCR bursts of up to 8, posted writes) issued on an OCP master port with SCmdAccept backpressure and a 64-clock accept timeout

Protocol IP `OCP_IP_Open_Core_Protocol`, version 2.0. Apache-2.0.

## Overview




MCmd, MAddr, MData, MByteEn, MBurstLength, MBurstSeq, SCmdAccept, SResp, SData and SRespLast are the OCP master pins; they pass through unchanged.
RESP holds one beat: a read burst's beats are kept only when the slave spaces them at least as far apart as software reads RESP; a beat arriving while RESP is full is dropped (RESP_OVF).

## Files

| File | Content |
|---|---|
| `rtl/OCP_IP_Open_Core_Protocol_top.sv` | protocol core |
| `rtl/OCP_IP_Open_Core_Protocol_apb.sv` | APB4 register wrapper (generated) |
| `tb/OCP_IP_Open_Core_Protocol_tb.sv` | core testbench |
| `tb/OCP_IP_Open_Core_Protocol_apb_tb.sv`, `tb/apb/OCP_IP_Open_Core_Protocol_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/OCP_IP_Open_Core_Protocol_sva.sv`, `tb/cov/OCP_IP_Open_Core_Protocol_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/OCP_IP_Open_Core_Protocol.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.OCP_IP_Open_Core_Protocol sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.OCP_IP_Open_Core_Protocol apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh OCP_IP_Open_Core_Protocol          # core coverage (Verilator)
bash scripts/cov/run_cov.sh OCP_IP_Open_Core_Protocol_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `req_valid` | input | 1 | REQ commit / FLAGS |
| `req_ready` | output | 1 | REQ handshake |
| `req_rw` | input | 1 | REQ2[0:0] |
| `req_posted` | input | 1 | REQ2[1:1] |
| `req_addr` | input | 32 | REQ0[31:0] |
| `req_len` | input | 5 | REQ2[6:2] |
| `req_wdata` | input | 32 | REQ1[31:0] |
| `resp_valid` | output | 1 | RESP capture |
| `resp_rdata` | output | 32 | RESP0[31:0] |
| `resp_err` | output | 1 | RESP1 |
| `MCmd` | output | 3 | pin (pass-through) |
| `MAddr` | output | 32 | pin (pass-through) |
| `MData` | output | 32 | pin (pass-through) |
| `MByteEn` | output | 4 | pin (pass-through) |
| `MBurstLength` | output | 5 | pin (pass-through) |
| `MBurstSeq` | output | 3 | pin (pass-through) |
| `SCmdAccept` | input | 1 | pin (pass-through) |
| `SResp` | input | 2 | pin (pass-through) |
| `SData` | input | 32 | pin (pass-through) |
| `SRespLast` | input | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`OCP_IP_Open_Core_Protocol_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `MCmd`, `MAddr`, `MData`, `MByteEn`, `MBurstLength`, `MBurstSeq`, `SCmdAccept`, `SResp`, `SData`, `SRespLast`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4F500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | REQ0 | RW | 0x00000000 | Transaction descriptor, then the further data words of a write burst; writing REQ2 commits it |
| 0x018 | REQ1 | RW | 0x00000000 | Transaction descriptor, then the further data words of a write burst; writing REQ2 commits it |
| 0x01C | REQ2 | RW | 0x00000000 | Transaction descriptor, then the further data words of a write burst; writing REQ2 commits it |
| 0x020 | RESP0 | RO (pop) | 0x00000000 | One beat per read data beat, per write completion and per posted write or timeout; reading RESP1 frees it |
| 0x024 | RESP1 | RO (pop) | 0x00000000 | One beat per read data beat, per write completion and per posted write or timeout; reading RESP1 frees it |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4F50 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| REQ0 | 31:0 | `req_addr` | byte address (MAddr) |
| REQ1 | 31:0 | `req_wdata` | write data: the first word with the descriptor, then one word per commit |
| REQ2 | 0 | `req_rw` | 1 = write, 0 = read |
| REQ2 | 1 | `req_posted` | 1 = posted write (WRNP, no response from the slave) |
| REQ2 | 6:2 | `req_len` | burst length 1 to 8 (0 is 1; above 8 is clamped to 8 and sets ERR) |
| RESP0 | 31:0 | `resp_rdata` | read data (0 for writes) |
| RESP1 | 0 | `resp_err` | 1 = SResp FAIL / ERR, or no SCmdAccept for 64 clocks |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a burst length above 8, an SResp FAIL / ERR, or an accept timeout; the core holds this until reset, so the bit cannot be cleared before then |
| 1 | REQ_DONE | REQ beat accepted by the core |
| 2 | REQ_OVF | write to REQ while full (dropped) |
| 3 | RESP_AVAIL | RESP captured a beat |
| 4 | RESP_OVF | beat dropped, RESP was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | REQ_FULL | REQ holds a beat the core has not taken |
| 1 | RESP_AVAIL | RESP holds an unread beat |

### Streams

* **REQ** feeds `req_addr`, `req_wdata`, `req_rw`, `req_posted`, `req_len`/`req_valid`. Writing REQ2 commits the beat: FLAGS.REQ_FULL is set and `req_valid` stays high until the core's `req_ready`; then REQ_DONE is set. A write while full is dropped and sets REQ_OVF.
* **RESP** captures `resp_rdata`, `resp_err` when `resp_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RESP_AVAIL. Reading RESP1 pops it. A beat that arrives while the register is full is dropped and sets RESP_OVF.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/OCP_IP_Open_Core_Protocol_top.sv` | pass | 49/49 (+1 excl.) | 1098/1098 (+12 excl.) | 15/15 | 13/13 | 29/29 |
| wrapper `rtl/OCP_IP_Open_Core_Protocol_apb.sv` | pass | 37/37 | 1086/1086 (+12 excl.) | n/a | 13/13 | 57/57 |
