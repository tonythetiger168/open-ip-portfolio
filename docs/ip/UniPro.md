# MIPI UniPro data link layer: 8-bit serial symbols, COF / ESC_DL framing, CRC-16, data frames with ACK / NAC, resend on timeout, TC0 / TC1 priority queues, PACP GET / SET of 16 attributes, a CPort 0 message buffer

Protocol IP `UniPro`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `UniPro_top` (`rtl/UniPro_top.sv`) |
| Register interface | APB4 slave `UniPro_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55500200 (code 0x5550, version 2.0) |
| Registers | 13 words, 0x000 to 0x030 |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CORE (8 words) |
| Protocol pins | 2 pass-through |

## Overview

UniPro protocol -- MIPI UniPro 1.x data link layer (educational slice)

- 8-bit symbol serial tx/rx (start + 8 data LSB-first + stop, idle=1,
1 bit/clk); a missing stop bit is a framing error
- ESC_DL escape (8'h9D, next byte XOR 0x20) + COF (8'h7E) frame delimiting;
a frame over 32 bytes is dropped silently
- L2 frame: hdr{tc[1],cport[4],seq[4],len[8]} + payload(<=16B) + CRC16
(poly 0x1021, init 0xFFFF, appended hi/lo, rx residue == 0).  A bad
residue, len != bytes - 5, len > 16 or a control frame with len != 3 is
dropped with an error.
- Control frames (CPort 15): GET/SET of 16x8 attributes, GET response,
SET confirm, ACK{seq}, NAC{expected seq}; unknown commands are ignored
- Data frames: one outstanding frame awaiting ACK; NAC or ACK timeout
resends it (<=3 resends), then it is dropped with an error.  ACK, NAC
and PACP frames still go out while a data frame is outstanding.
- Receive side: in-sequence data is ACKed (CPort0 payload goes to a
32x8 message buffer; no room -> NAC + error), the previous sequence
number is re-ACKed (duplicate), anything else is NACed
- TC0/TC1 transmit queues (8 entries), strict priority (TC1 first)
CPU map: wr 0=push TC0, 1=push TC1, 2=PACP SET{val[15:8],idx[3:0]},
3=PACP GET{idx[3:0]}, 4=tx_cport
rd 4=message buffer pop, 5=status (below),
6={pacp_cnf,pacp_rsp_valid,pacp_rsp_val} (read clears flags)
status = {pacp_cnf, pacp_rsp_valid, tx busy, PACP request pending,
data frame outstanding, resends[1:0], control FIFO
count[2:0], rx expected seq[3:0], tx seq[3:0],
msg count[5:0], TC1 count[3:0], TC0 count[3:0]}
irq: 1-clk pulse on CRC/length error, framing error, message buffer
overflow, control FIFO overflow, resend budget exhausted, queue overflow

rx_bit / tx_bit (start + 8 data bits LSB first + stop, idle 1, one bit per PCLK) pass through unchanged.
The core's CPU port is mapped one word per register; a write with PSTRB != 4'hF to a writable word is dropped with PSLVERR.

## Files

| File | Content |
|---|---|
| `rtl/UniPro_top.sv` | protocol core |
| `rtl/UniPro_apb.sv` | APB4 register wrapper (generated) |
| `tb/UniPro_tb.sv` | core testbench |
| `tb/UniPro_apb_tb.sv`, `tb/apb/UniPro_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/UniPro_sva.sv`, `tb/cov/UniPro_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/UniPro.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.UniPro sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.UniPro apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh UniPro          # core coverage (Verilator)
bash scripts/cov/run_cov.sh UniPro_apb      # wrapper coverage
```

## Parameters

`UniPro_apb` has the core's parameters and passes them to `UniPro_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `ACK_WAIT` | int | `600` |

## Wrapper pins

Pins of `UniPro_apb`. Widths of the pass-through pins are at the default parameters.

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
| `PSLVERR` | output | 1 | error: unmapped or misaligned address, or partial write to a core register word |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `rx_bit` | input | 1 | protocol pin, core port `rx_bit` |
| `tx_bit` | output | 1 | protocol pin, core port `tx_bit` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rx_bit` | input | 1 | pin (pass-through) |
| `tx_bit` | output | 1 | pin (pass-through) |
| `cpu_we` | input | 1 | write to a CORE word |
| `cpu_re` | input | 1 | read of a CORE word |
| `cpu_addr` | input | 3 | CORE word index |
| `cpu_wdata` | input | 32 | CORE write data |
| `cpu_rdata` | output | 32 | CORE read data |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`UniPro_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_bit`, `tx_bit`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TC0 | WO (core) | core | push one 32-bit payload onto the TC0 transmit queue (8 entries; a push to a full queue is dropped with ERR) |
| 0x018 | TC1 | WO (core) | core | push one 32-bit payload onto the TC1 transmit queue (strict priority over TC0) |
| 0x01C | PACP_SET | WO (core) | core | PACP SET request to the peer: [15:8] value, [3:0] attribute index |
| 0x020 | PACP_GET | WO (core) | core | PACP GET request to the peer: [3:0] attribute index |
| 0x024 | CPORT | WO (core) | core | [3:0] destination CPort of the following pushes |
| 0x028 | MSG | RO (core) | core | [7:0] next message-buffer byte (CPort 0 payloads, 32 bytes); the read pops it |
| 0x02C | STATUS | RO (core) | core | {pacp_cnf, pacp_rsp_valid, tx busy, PACP request pending, data frame outstanding, resends[1:0], control FIFO count[2:0], rx expected seq[3:0], tx seq[3:0], msg count[5:0], TC1 count[3:0], TC0 count[3:0]} |
| 0x030 | PACP | RO (core) | core | {pacp_cnf, pacp_rsp_valid, GET response value[7:0]}; the read clears both flags |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x034 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5550 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TC0 | 31:0 | core register | WO (core) | core | written at core register 0 |
| TC1 | 31:0 | core register | WO (core) | core | written at core register 1 |
| PACP_SET | 31:0 | core register | WO (core) | core | written at core register 2 |
| PACP_GET | 31:0 | core register | WO (core) | core | written at core register 3 |
| CPORT | 31:0 | core register | WO (core) | core | written at core register 4 |
| MSG | 31:0 | core register | RO (core) | core | read from core register 4 |
| STATUS | 31:0 | core register | RO (core) | core | read from core register 5 |
| PACP | 31:0 | core register | RO (core) | core | read from core register 6 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | received CRC / length error or framing error, message buffer overflow, control FIFO overflow, resend budget exhausted, or a push to a full queue |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `cpu_we` for one clock with `cpu_addr` (the core register) and `cpu_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `cpu_addr` (the core register) and pulses `cpu_re` during the access phase and returns `cpu_rdata`.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55500200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/UniPro_top.sv` | pass | 169/169 | 2144/2144 | 24/24 | 5/5 | 39/39 |
| wrapper `rtl/UniPro_apb.sv` | pass | 22/22 | 544/544 | n/a | 11/11 | 40/40 |
