# AMBA CHI subordinate node (SN-F) for a small memory: ReadNoSnp, WriteNoSnpPtl and WriteNoSnpFull over the RXREQ, RXDAT, TXRSP and TXDAT link channels with L-Credit flow control

Protocol IP `CHI`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `CHI_top` (`rtl/CHI_top.sv`) |
| Register interface | APB4 slave `CHI_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x43480200 (code 0x4348, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | 12 pass-through |

## Overview

CHI_top v2.0: AMBA CHI subordinate node (SN-F) for a small memory: ReadNoSnp, WriteNoSnpPtl and WriteNoSnpFull over CHI link-layer channels with L-Credit flow control

- Channels: RXREQ and RXDAT in, TXRSP and TXDAT out. A flit is a one
clock pulse of its flitv; a sender needs one L-Credit per flit, and
a credit is one clock pulse of the receiver's lcrdv. This node grants
RQ request credits (one per free request slot) and NDC data credits
(data is written as it arrives), and counts the credits it is given
for TXRSP and TXDAT (at most 15 each). A flit that arrives without a
credit is dropped with ev_proto.
- Flits (fields from CHI Issue B, narrowed): REQ {SrcID[6:0],
TxnID[7:0], Opcode[5:0], Order, Size[2:0], Addr[15:0]}; RXDAT
{TxnID[7:0], Opcode[3:0], DataID[1:0], BE[15:0], Data[127:0]}; RSP
{TgtID[6:0], TxnID[7:0], Opcode[3:0], RespErr[1:0], DBID[7:0]};
TXDAT {TgtID[6:0], TxnID[7:0], RespErr[1:0], DataID[1:0],
Data[127:0]}, always CompData with Resp UC (the opcode and Resp
fields are left out of the port).
- Memory: LINES 64-byte lines at byte addresses 0 .. LINES * 64 - 1,
16 bytes per data beat (DataID = address bits 5:4). Size 0..4 moves
the beat holding the address, 5 two beats, 6 the line.
- Requests are served in order. ReadNoSnp: ReadReceipt (RSP 8h) first
when Order is set, then CompData beats. WriteNoSnpPtl: DBIDResp (6h),
then Comp (4h) once its data beats are in; WriteNoSnpFull (Size 6
only): CompDBIDResp (5h). DBID = {write buffer, TxnID[6:0]}; NDB = 2
writes can wait for data. NonCopyBackWrData (3h) beats are written
with their byte enables; a beat with another opcode, a DBID not
waiting, or a DataID not expected (or already in) is dropped with
ev_proto.
- Errors: an address beyond the memory gets RespErr DERR (10)
(read data zero, write data dropped); another opcode, Size 7, or
WriteNoSnpFull with Size other than 6 gets Comp (or, for ReadNoSnp
with Size 7, one CompData beat of zeros) with RespErr NDERR (11).
ev_err pulses once per such request, with its first response.
- TXRSP: a Comp for completed write data goes before the request
being served. Memory is zero after reset.
Not implemented: snoops and the home node's coherence (the node is
only a memory target), the other request opcodes (atomics, CMOs,
exclusive, ReadOnce and friends), retry and protocol credits
(RetryAck, PCrdGrant), DMT / DWT, CompAck, link activation and
deactivation (TXLINKACTIVE*), the SACTIVE signals, QoS, poison,
data check, MPAM, full-width addresses and node IDs. Encodings follow
CHI Issue B as we read them; they have not been checked against a
compliant home node.

rxreqflitv, rxreqflit, rxreqlcrdv, rxdatflitv, rxdatflit, rxdatlcrdv, txrspflitv, txrspflit, txrsplcrdv, txdatflitv, txdatflit and txdatlcrdv are the CHI link channels to the home node; they pass through unchanged. The registers report the node's error events.
The core parameters LINES (16), RQ (4) and NDC (2) keep their defaults.

## Files

| File | Content |
|---|---|
| `rtl/CHI_top.sv` | protocol core |
| `rtl/CHI_apb.sv` | APB4 register wrapper (generated) |
| `tb/CHI_tb.sv` | core testbench |
| `tb/CHI_apb_tb.sv`, `tb/apb/CHI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CHI_sva.sv`, `tb/cov/CHI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CHI.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.CHI sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.CHI apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh CHI          # core coverage (Verilator)
bash scripts/cov/run_cov.sh CHI_apb      # wrapper coverage
```

## Parameters

`CHI_apb` has the core's parameters and passes them to `CHI_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `LINES` | int | `16` |
| `RQ` | int | `4` |
| `NDC` | int | `2` |

## Wrapper pins

Pins of `CHI_apb`. Widths of the pass-through pins are at the default parameters.

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
| `rxreqflitv` | input | 1 | protocol pin, core port `rxreqflitv` |
| `rxreqflit` | input | 41 | protocol pin, core port `rxreqflit` |
| `rxreqlcrdv` | output | 1 | protocol pin, core port `rxreqlcrdv` |
| `rxdatflitv` | input | 1 | protocol pin, core port `rxdatflitv` |
| `rxdatflit` | input | 158 | protocol pin, core port `rxdatflit` |
| `rxdatlcrdv` | output | 1 | protocol pin, core port `rxdatlcrdv` |
| `txrspflitv` | output | 1 | protocol pin, core port `txrspflitv` |
| `txrspflit` | output | 29 | protocol pin, core port `txrspflit` |
| `txrsplcrdv` | input | 1 | protocol pin, core port `txrsplcrdv` |
| `txdatflitv` | output | 1 | protocol pin, core port `txdatflitv` |
| `txdatflit` | output | 147 | protocol pin, core port `txdatflit` |
| `txdatlcrdv` | input | 1 | protocol pin, core port `txdatlcrdv` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rxreqflitv` | input | 1 | pin (pass-through) |
| `rxreqflit` | input | 41 | pin (pass-through) |
| `rxreqlcrdv` | output | 1 | pin (pass-through) |
| `rxdatflitv` | input | 1 | pin (pass-through) |
| `rxdatflit` | input | 158 | pin (pass-through) |
| `rxdatlcrdv` | output | 1 | pin (pass-through) |
| `txrspflitv` | output | 1 | pin (pass-through) |
| `txrspflit` | output | 29 | pin (pass-through) |
| `txrsplcrdv` | input | 1 | pin (pass-through) |
| `txdatflitv` | output | 1 | pin (pass-through) |
| `txdatflit` | output | 147 | pin (pass-through) |
| `txdatlcrdv` | input | 1 | pin (pass-through) |
| `ev_err` | output | 1 | IRQ_STATUS.ERR |
| `ev_proto` | output | 1 | IRQ_STATUS.PROTO |

## APB wrapper

`CHI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxreqflitv`, `rxreqflit`, `rxreqlcrdv`, `rxdatflitv`, `rxdatflit`, `rxdatlcrdv`, `txrspflitv`, `txrspflit`, `txrsplcrdv`, `txdatflitv`, `txdatflit`, `txdatlcrdv`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43480200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4348 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a request got an error response: DERR (address beyond the memory) or NDERR (opcode or size not supported) |
| 1 | PROTO | a flit was dropped: it came without an L-Credit, or it was write data not expected (opcode, DBID or DataID) |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43480200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CHI_top.sv` | pass | 53/53 | 1492/1492 | n/a | 5/5 | 93/93 |
| wrapper `rtl/CHI_apb.sv` | pass | 19/19 | 1166/1166 | n/a | 7/7 | 27/27 |
