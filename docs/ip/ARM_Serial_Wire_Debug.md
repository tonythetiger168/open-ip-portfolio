# Serial Wire Debug port (ADIv5 SW-DP, DPv1 registers) with a software access port

Protocol IP `ARM_Serial_Wire_Debug`, version 2.0. Apache-2.0.

## Overview

ARM_Serial_Wire_Debug_top v2.0: Serial Wire Debug port (SW-DP, ADIv5 DPv1

register set, SWD only) with a request port towards the access ports
- Pins: SWCLK and SWDIO are synchronised into clk (two flops each); the
target samples SWDIO at each rising SWCLK edge and changes its own
SWDIO output 3 clk after that edge. SWCLK high and low times must be
at least 4 clk. The host drives SWDIO between rising edges and leaves
the line released (pull-up, reads 1) in turnaround cycles. Read data
is taken when the target starts driving the ACK.
- Line reset: 50 or more consecutive 1 samples (target not driving),
then at least 2 idle (0) samples. After a line reset the first packet
must read DPIDR; any other packet, a request parity error or a wrong
stop / park bit is a protocol error: no reply, the port locks out
until the next line reset. The port also starts locked out.
- Packet: request {start 1, APnDP, RnW, A[2], A[3], parity (even over
the 4 bits), stop 0, park 1}, turnaround (DLCR.TURNROUND + 1 cycles),
ACK from the target (3 bits, first bit first: OK 1,0,0; WAIT 0,1,0;
FAULT 0,0,1), then for a read: 32 data bits (bit 0 first) + even
parity from the target and a turnaround; for a write: a turnaround and
32 data bits + parity from the host. WAIT / FAULT end the packet after
the ACK and a turnaround unless CTRL/STAT.ORUNDETECT is set: then the
data phase follows anyway (read data 0, write data ignored) and
STICKYORUN is set.
- DP registers (A[3:2]): read 0 DPIDR, 1 CTRL/STAT (SELECT.DPBANKSEL 0)
or DLCR (bank 1; other banks read 0), 2 RESEND, 3 RDBUFF; write 0
ABORT, 1 CTRL/STAT / DLCR, 2 SELECT, 3 ignored.
CTRL/STAT: [0] ORUNDETECT, [1] STICKYORUN, [5] STICKYERR,
[6] READOK, [7] WDATAERR, [28] CDBGPWRUPREQ, [29] CDBGPWRUPACK,
[30] CSYSPWRUPREQ, [31] CSYSPWRUPACK. Sticky bits are cleared
only through ABORT.
ABORT: [0] DAPABORT (drops the AP access in progress), [2]
STKERRCLR, [3] WDERRCLR, [4] ORUNERRCLR.
DLCR: [9:8] TURNROUND. SELECT: [31:24] APSEL, [7:4] APBANKSEL,
[3:0] DPBANKSEL. RESEND: the data of the last AP or RDBUFF read.
- AP accesses: ap_req pulses for one clock with the request {ap_write,
ap_sel = APSEL, ap_addr (word address) = {APBANKSEL, A[3:2]},
ap_wdata}; ap_busy stays high until ap_done (ap_err: STICKYERR) or
DAPABORT (ap_abort pulse). AP reads are posted: the read returns RDBUFF (the
previous AP read result) and starts a new AP read whose result goes
to RDBUFF. While an AP access is in progress, AP accesses and RDBUFF
reads get WAIT; with STICKYERR, STICKYORUN or WDATAERR set, AP
accesses get FAULT (checked first). A write with a data parity error
sets WDATAERR and is dropped.
Not implemented: JTAG-DP and dormant state (the JTAG-to-SWD sequence
is harmless: it contains line resets), multi-drop (TARGETSEL), DPv2
registers, pushed compare / verify (STICKYCMP reads 0), transaction
counter, debug reset request.

swclk, swdio_in, swdio_out and swdio_oe connect to the SWD pins (swdio_oe = 1: the port drives SWDIO). SWCLK high and low times must be at least 4 PCLK periods.
Software acts as the access ports: on APREQ_AVAIL read APREQ0/APREQ1, perform the access, then write APRESP0 (read data) and APRESP1 (error flag).

## Files

| File | Content |
|---|---|
| `rtl/ARM_Serial_Wire_Debug_top.sv` | protocol core |
| `rtl/ARM_Serial_Wire_Debug_apb.sv` | APB4 register wrapper (generated) |
| `tb/ARM_Serial_Wire_Debug_tb.sv` | core testbench |
| `tb/ARM_Serial_Wire_Debug_apb_tb.sv`, `tb/apb/ARM_Serial_Wire_Debug_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/ARM_Serial_Wire_Debug_sva.sv`, `tb/cov/ARM_Serial_Wire_Debug_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/ARM_Serial_Wire_Debug.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.ARM_Serial_Wire_Debug sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.ARM_Serial_Wire_Debug apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh ARM_Serial_Wire_Debug          # core coverage (Verilator)
bash scripts/cov/run_cov.sh ARM_Serial_Wire_Debug_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `swclk` | input | 1 | pin (pass-through) |
| `swdio_in` | input | 1 | pin (pass-through) |
| `swdio_out` | output | 1 | pin (pass-through) |
| `swdio_oe` | output | 1 | pin (pass-through) |
| `cdbgpwrupreq` | output | 1 | STATUS[2:2] |
| `cdbgpwrupack` | input | 1 | PWR[0:0] |
| `csyspwrupreq` | output | 1 | STATUS[3:3] |
| `csyspwrupack` | input | 1 | PWR[1:1] |
| `ap_req` | output | 1 | APREQ capture |
| `ap_busy` | output | 1 | STATUS[0:0] |
| `ap_write` | output | 1 | APREQ1[0:0] |
| `ap_sel` | output | 8 | APREQ1[8:1] |
| `ap_addr` | output | 6 | APREQ1[14:9] |
| `ap_wdata` | output | 32 | APREQ0[31:0] |
| `ap_done` | input | 1 | APRESP commit / FLAGS |
| `ap_rdata` | input | 32 | APRESP0[31:0] |
| `ap_err` | input | 1 | APRESP1 |
| `ap_abort` | output | 1 | IRQ_STATUS.ABORT |
| `lockout` | output | 1 | STATUS[1:1] |
| `line_reset` | output | 1 | IRQ_STATUS.LINE_RESET |
| `proto_err` | output | 1 | IRQ_STATUS.PROTO_ERR |
| `ack_wait` | output | 1 | IRQ_STATUS.WAIT |
| `ack_fault` | output | 1 | IRQ_STATUS.FAULT |

## APB wrapper

`ARM_Serial_Wire_Debug_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `swclk`, `swdio_in`, `swdio_out`, `swdio_oe`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53570200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | PWR | RW | 0x00000000 | Power controller acknowledges (driven by software) |
| 0x018 | APREQ0 | RO (pop) | 0x00000000 | AP access requested by the debugger; reading APREQ1 frees it. Answer every request through APRESP |
| 0x01C | APREQ1 | RO (pop) | 0x00000000 | AP access requested by the debugger; reading APREQ1 frees it. Answer every request through APRESP |
| 0x020 | APRESP0 | RW | 0x00000000 | Completes the AP access in progress; writing APRESP1 commits it (ignored when no access is in progress) |
| 0x024 | APRESP1 | RW | 0x00000000 | Completes the AP access in progress; writing APRESP1 commits it (ignored when no access is in progress) |
| 0x028 | STATUS | RO | 0x00000000 | Port state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5357 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| PWR | 0 | `cdbgpwrupack` | debug power-up acknowledge (CTRL/STAT.CDBGPWRUPACK) |
| PWR | 1 | `csyspwrupack` | system power-up acknowledge (CTRL/STAT.CSYSPWRUPACK) |
| APREQ0 | 31:0 | `ap_wdata` | write data |
| APREQ1 | 0 | `ap_write` | 1 = write, 0 = read |
| APREQ1 | 8:1 | `ap_sel` | SELECT.APSEL |
| APREQ1 | 14:9 | `ap_addr` | AP register word address {SELECT.APBANKSEL, A[3:2]} |
| APRESP0 | 31:0 | `ap_rdata` | read data (reads only) |
| APRESP1 | 0 | `ap_err` | 1 = the access failed (sets CTRL/STAT.STICKYERR) |
| STATUS | 0 | `ap_busy` | an AP access is in progress (the debugger gets WAIT) |
| STATUS | 1 | `lockout` | waiting for a line reset |
| STATUS | 2 | `cdbgpwrupreq` | debug power-up requested |
| STATUS | 3 | `csyspwrupreq` | system power-up requested |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | LINE_RESET | a line reset was seen |
| 1 | PROTO_ERR | protocol error: request parity, stop or park bit, or a first packet other than a DPIDR read |
| 2 | WAIT | a packet was answered with WAIT |
| 3 | FAULT | a packet was answered with FAULT |
| 4 | ABORT | the debugger aborted the AP access in progress (DAPABORT) |
| 5 | APREQ_AVAIL | APREQ captured a beat |
| 6 | APREQ_OVF | beat dropped, APREQ was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | APREQ_AVAIL | APREQ holds an unread beat |

### Streams

* **APREQ** captures `ap_wdata`, `ap_write`, `ap_sel`, `ap_addr` when `ap_req` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ APREQ_AVAIL. Reading APREQ1 pops it. A beat that arrives while the register is full is dropped and sets APREQ_OVF.
* **APRESP** feeds `ap_rdata`, `ap_err`; writing APRESP1 pulses `ap_done` for one clock.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ARM_Serial_Wire_Debug_top.sv` | pass | 95/95 | 552/552 | 23/23 | 6/6 | 42/42 |
| wrapper `rtl/ARM_Serial_Wire_Debug_apb.sv` | pass | 35/35 | 802/802 | n/a | 12/12 | 65/65 |
