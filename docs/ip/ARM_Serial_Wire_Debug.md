# Serial Wire Debug port (ADIv5 SW-DP, DPv1 registers) with a software access port

Protocol IP `ARM_Serial_Wire_Debug`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `ARM_Serial_Wire_Debug_top` (`rtl/ARM_Serial_Wire_Debug_top.sv`) |
| Register interface | APB4 slave `ARM_Serial_Wire_Debug_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53570200 (code 0x5357, version 2.0) |
| Registers | 11 words, 0x000 to 0x028 |
| Interrupts | 7 sources into one level-high `irq` |
| Data streams | APREQ (from the core), APRESP (to the core) |
| Protocol pins | 4 pass-through |

## Overview

ARM_Serial_Wire_Debug_top v2.0: Serial Wire Debug port (SW-DP, ADIv5 DPv1 register set, SWD only) with a request port towards the access ports

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

## Parameters

`ARM_Serial_Wire_Debug_apb` has the core's parameters and passes them to `ARM_Serial_Wire_Debug_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DPIDR` | logic [31:0] | `32'h0010_1001` |

## Wrapper pins

Pins of `ARM_Serial_Wire_Debug_apb`. Widths of the pass-through pins are at the default parameters.

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
| `swclk` | input | 1 | protocol pin, core port `swclk` |
| `swdio_in` | input | 1 | protocol pin, core port `swdio_in` |
| `swdio_out` | output | 1 | protocol pin, core port `swdio_out` |
| `swdio_oe` | output | 1 | protocol pin, core port `swdio_oe` |

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
| 0x028 | STATUS | RO | core | Port state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5357 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 6:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 6:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| PWR | 0 | `cdbgpwrupack` | RW | 0x0 | debug power-up acknowledge (CTRL/STAT.CDBGPWRUPACK) |
| PWR | 1 | `csyspwrupack` | RW | 0x0 | system power-up acknowledge (CTRL/STAT.CSYSPWRUPACK) |
| APREQ0 | 31:0 | `ap_wdata` | RO (pop) | 0x0 | write data |
| APREQ1 | 0 | `ap_write` | RO (pop) | 0x0 | 1 = write, 0 = read |
| APREQ1 | 8:1 | `ap_sel` | RO (pop) | 0x0 | SELECT.APSEL |
| APREQ1 | 14:9 | `ap_addr` | RO (pop) | 0x0 | AP register word address {SELECT.APBANKSEL, A[3:2]} |
| APRESP0 | 31:0 | `ap_rdata` | RW | 0x0 | read data (reads only) |
| APRESP1 | 0 | `ap_err` | RW | 0x0 | 1 = the access failed (sets CTRL/STAT.STICKYERR) |
| STATUS | 0 | `ap_busy` | RO | core | an AP access is in progress (the debugger gets WAIT) |
| STATUS | 1 | `lockout` | RO | core | waiting for a line reset |
| STATUS | 2 | `cdbgpwrupreq` | RO | core | debug power-up requested |
| STATUS | 3 | `csyspwrupreq` | RO | core | system power-up requested |

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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53570200.
2. Write 0x7F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write PWR (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7F enables all).
5. To receive on APREQ: wait for IRQ APREQ_AVAIL or FLAGS.APREQ_AVAIL (bit 0), then read APREQ0 (0x018) then APREQ1 (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.APREQ_AVAIL (bit 5) to clear it. Read each beat before the next arrives, or it is dropped and APREQ_OVF is set.
6. To send on APRESP: write APRESP0 (0x020) then APRESP1 (0x024). The last write pulses `ap_done` for one clock; there is no back-pressure.
7. Read STATUS (0x028) for the core's live `ap_busy`, `lockout`, `cdbgpwrupreq`, `csyspwrupreq`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ARM_Serial_Wire_Debug_top.sv` | pass | 95/95 | 552/552 | 23/23 | 6/6 | 97/97 |
| wrapper `rtl/ARM_Serial_Wire_Debug_apb.sv` | pass | 35/35 | 802/802 | n/a | 12/12 | 65/65 |
