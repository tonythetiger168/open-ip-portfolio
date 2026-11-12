<!-- SPDX-License-Identifier: Apache-2.0 -->
# ARM_Serial_Wire_Debug: design specification

A Serial Wire Debug port (SW-DP, ADIv5 DPv1 register set, SWD only) with a request port towards
the access ports. Not implemented: JTAG-DP and the dormant state (the JTAG-to-SWD sequence is
harmless: it contains line resets), multi-drop (TARGETSEL), DPv2 registers, pushed compare /
verify (STICKYCMP reads 0), the transaction counter, debug reset request. Core
`ARM_Serial_Wire_Debug_top` (`rtl/ARM_Serial_Wire_Debug_top.sv`), testbench
`tb/ARM_Serial_Wire_Debug_tb.sv` (a host BFM, an AP model and a power controller), checker
`tb/cov/ARM_Serial_Wire_Debug_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. SWCLK and SWDIO pass two flops; "a rise" is a rising SWCLK edge
seen there, acted on in that clock, so `swdio_out` / `swdio_oe` change at the third `clk` edge
after the pin edge. The target samples SWDIO at each rise. Data goes bit 0 first; parity is even.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock (at least 8 x SWCLK) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `swclk` | input | 1 | SWCLK; high and low at least 4 clocks each; two-flop synchronised | - | async | - |
| `swdio_in` | input | 1 | SWDIO line (pull-up: reads 1 when nobody drives); two-flop synchronised | - | async | - |
| `swdio_out` | output | 1 | SWDIO driven by the target | - | `clk` | 0 |
| `swdio_oe` | output | 1 | the target drives SWDIO | high | `clk` | 0 |
| `cdbgpwrupreq` | output | 1 | CTRL/STAT.CDBGPWRUPREQ | high | `clk` | 0 |
| `cdbgpwrupack` | input | 1 | debug power-up acknowledge (read in CTRL/STAT) | high | `clk` | - |
| `csyspwrupreq` | output | 1 | CTRL/STAT.CSYSPWRUPREQ | high | `clk` | 0 |
| `csyspwrupack` | input | 1 | system power-up acknowledge | high | `clk` | - |
| `ap_req` | output | 1 | one-clock pulse: a new AP access (fields held until done) | high | `clk` | 0 |
| `ap_busy` | output | 1 | an AP access is in progress | high | `clk` | 0 |
| `ap_write` | output | 1 | the access is a write | high | `clk` | 0 |
| `ap_sel` | output | 8 | SELECT.APSEL | - | `clk` | 0 |
| `ap_addr` | output | 6 | word address {APBANKSEL, A[3:2]} | - | `clk` | 0 |
| `ap_wdata` | output | 32 | write data | - | `clk` | 0 |
| `ap_done` | input | 1 | the AP access finished (ignored when not busy) | high | `clk` | - |
| `ap_rdata` | input | 32 | AP read data with `ap_done` | - | `clk` | - |
| `ap_err` | input | 1 | the AP access failed (with `ap_done`) | high | `clk` | - |
| `ap_abort` | output | 1 | one-clock pulse: DAPABORT dropped the access | high | `clk` | 0 |
| `lockout` | output | 1 | waiting for a line reset; combinational from flops | high | `clk` | 1 |
| `line_reset` | output | 1 | one-clock pulse: line reset seen | high | `clk` | 0 |
| `proto_err` | output | 1 | one-clock pulse: protocol error (port locks out) | high | `clk` | 0 |
| `ack_wait` | output | 1 | one-clock pulse: WAIT sent | high | `clk` | 0 |
| `ack_fault` | output | 1 | one-clock pulse: FAULT sent | high | `clk` | 0 |

### Internal signals used by the verification

The FSM coverage collector binds `st`.

| Signal | Width | Meaning |
|---|---|---|
| `st` | 4 | 0 LOCKOUT, 1 after line reset, 2 IDLE, 3 REQUEST, 4 turnaround before ACK, 5 ACK, 6 read data, 7 turnaround before write data, 8 write data, 9 turnaround after read data |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/ARM_Serial_Wire_Debug.md`](../ip/ARM_Serial_Wire_Debug.md) (source: `scripts/apb/specs/ARM_Serial_Wire_Debug.json`); do not edit by hand.

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

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53570200.
2. Write 0x7F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write PWR (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7F enables all).
5. To receive on APREQ: wait for IRQ APREQ_AVAIL or FLAGS.APREQ_AVAIL (bit 0), then read APREQ0 (0x018) then APREQ1 (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.APREQ_AVAIL (bit 5) to clear it. Read each beat before the next arrives, or it is dropped and APREQ_OVF is set.
6. To send on APRESP: write APRESP0 (0x020) then APRESP1 (0x024). The last write pulses `ap_done` for one clock; there is no back-pressure.
7. Read STATUS (0x028) for the core's live `ap_busy`, `lockout`, `cdbgpwrupreq`, `csyspwrupreq`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Line reset and lockout

At each rise with the target not driving: SWDIO = 1 counts, 0 restarts the count. The 50th 1 in
a row, in any state, pulses `line_reset` (the target stops driving); further 1s do nothing. Then
two 0 samples in a row go to IDLE, and the first packet must be a DPIDR read. The port starts
locked out after reset (`lockout` = 1) and locks out on a protocol error (`proto_err` pulse): a
request parity error, stop bit not 0, park bit not 1, or a first packet other than a DPIDR read.
A locked-out port does not reply until the next line reset.

### 3.2 Packet

In IDLE a 1 sample is the start bit; the next 7 samples are APnDP, RnW, A[2], A[3], parity (of
those four), stop, park. At the park sample the ACK is decided:

| Condition, in order | ACK |
|---|---|
| AP access with STICKYERR, STICKYORUN or WDATAERR set | FAULT 001 |
| AP access, or RDBUFF read, while an AP access is in progress | WAIT 010 |
| otherwise | OK 100 |

Then the turnaround: DLCR.TURNROUND + 1 rises. At the rise ending it the target drives the first
ACK bit (`ack_wait` / `ack_fault` pulse there), then the second and third at the next rises.

* Read with OK: at the next rise the target drives data bit 0, then one bit per rise, 32 bits
  and the parity; at the rise after the parity it releases the line, then TURNROUND + 1 rises of
  turnaround, IDLE.
* Write with OK, or WAIT / FAULT: at the rise after the third ACK bit the target releases the
  line; TURNROUND + 1 rises of turnaround; for a write the host's 32 data bits and parity are
  sampled at the next 33 rises; IDLE.
* WAIT / FAULT with CTRL/STAT.ORUNDETECT set: STICKYORUN is set and the data phase still follows
  (read data 0, write data ignored).

### 3.3 DP registers

| A[3:2] | Read | Write |
|---|---|---|
| 0 | DPIDR (`DPIDR`) | ABORT: [0] DAPABORT, [2] STKERRCLR, [3] WDERRCLR, [4] ORUNERRCLR |
| 1 | CTRL/STAT (DPBANKSEL 0), DLCR (1), else 0 | CTRL/STAT: [0] ORUNDETECT, [28] CDBGPWRUPREQ, [30] CSYSPWRUPREQ; DLCR [9:8] TURNROUND |
| 2 | RESEND: data of the last AP or RDBUFF read | SELECT: [31:24] APSEL, [7:4] APBANKSEL, [3:0] DPBANKSEL |
| 3 | RDBUFF | ignored |

CTRL/STAT reads [0] ORUNDETECT, [1] STICKYORUN, [5] STICKYERR, [6] READOK, [7] WDATAERR,
[28..31] CDBGPWRUPREQ, `cdbgpwrupack`, CSYSPWRUPREQ, `csyspwrupack`. Sticky bits clear only
through ABORT. Write values take effect at the parity sample; a write with a data parity error sets
WDATAERR and is dropped.

### 3.4 AP accesses

* AP read (OK): returns RDBUFF (the previous AP read's result) and, in the clock of the last
  turnaround rise, starts a new AP read (`ap_req` pulse, `ap_write` = 0).
* AP write (OK): at the parity sample `ap_req` pulses with `ap_write` = 1 and the data.
* `ap_busy` stays high until `ap_done`: `ap_err` sets STICKYERR; a read writes `ap_rdata` to RDBUFF
  and READOK = !`ap_err`.
* ABORT.DAPABORT while busy clears `ap_busy` and pulses `ap_abort`; a later `ap_done` is ignored.

### 3.5 Reset

While `rst_n` is low: locked out, line released, registers and outputs 0.

## 4. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `DPIDR` | 0x00101001 | DPIDR value (part 0x01, DPv1, RAO) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| request parity / stop / park error, or first packet not a DPIDR read | no reply, lockout, `proto_err` |
| AP access with a sticky error | FAULT |
| AP access or RDBUFF read while busy | WAIT |
| WAIT / FAULT with ORUNDETECT | data phase follows, STICKYORUN |
| write data parity error | WDATAERR, dropped |
| AP error | STICKYERR (READOK = 0 for reads) |
| JTAG-to-SWD sequence | treated as line resets |

## 6. TB check map

Messages are printed by `tb/ARM_Serial_Wire_Debug_tb.sv` as `ERROR: <message>`. Assertions `a_*`
are in the bound checker `tb/cov/ARM_Serial_Wire_Debug_sva.sv`. The host BFM uses random SWCLK
timing, retries on WAIT and checks ACK, data and parity; the TB models the DP registers and checks
every AP request.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "AP request while one is in progress" | one AP access at a time | §3.4 |
| "unexpected AP request" | requests only from AP accesses | §3.4 |
| "AP request w" | request fields | §3.4 |
| "read data parity" | read parity | §3.2 |
| "ACK" | ACK rules | §3.2 |
| "AP request never completed" | `ap_busy` ends | §3.4 |
| "AP write: no request" | write request | §3.4 |
| "AP write: ACK" | write ACK | §3.2 |
| "AP read: posted data" | posted read data | §3.4 |
| "AP read: no request" | read request | §3.4 |
| "AP read: ACK" | read ACK | §3.2 |
| "RDBUFF" | RDBUFF | §3.3, §3.4 |
| "not locked out after reset" | lockout at reset | §3.1 |
| "locked out after line reset" | line reset leaves lockout | §3.1 |
| "no lockout after a protocol error" | protocol error locks out | §3.1 |
| "power-up not acknowledged" | power-up handshake | §3.3 |
| "AP readback" | AP data | §3.4 |
| "slow AP: read back" | WAIT while busy | §3.2 |
| "no WAIT seen" | WAIT happens | §3.2 |
| "AP write with a parity error was not dropped" | WDATAERR drop | §3.3 |
| "read data after WAIT in overrun mode" | data 0 in overrun mode | §3.2 |
| "DAPABORT did not drop the AP access" | abort | §3.4 |
| "readback with a longer turnaround" | TURNROUND | §3.2 |
| "RDBUFF 0xFFFF8000" | RDBUFF data | §3.4 |
| "fast SWCLK readback" | 4-clock SWCLK phases | conventions |
| "slow SWCLK readback" | slow SWCLK | conventions |
| "pattern readback" | data patterns | §3.4 |
| a_reset_values | reset values | §3.5 |
| a_swdio_model | `swdio_out` / `swdio_oe` as the model | §3.2 |
| a_ap_req_model | `ap_req` / `ap_busy` / `ap_abort` as the model | §3.4 |
| a_ap_fields_model | AP request fields | §3.4 |
| a_status_model | status pulses and `lockout` | §3.1, §3.2 |
| a_power_model | power-up requests | §3.3 |
