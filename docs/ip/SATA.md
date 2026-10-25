# SATA host: OOB bring-up (COMRESET / COMINIT / COMWAKE, ALIGNp lock), link layer with frame handshakes, CRC-32 and resends, and a built-in DMA command sequencer (IDENTIFY, then WRITE / READ DMA EXT read-verify)

Protocol IP `SATA`, version 2.0. Apache-2.0.

## Overview

SATA protocol Open IP -- SATA host: OOB bring-up, link layer with frame handshakes, and a built-in DMA command sequencer. Open IP design implementation v3.0 Implementation scope (scaled, 1 line bit per clk, no 8b/10b): * Line: tx_p/tx_n differential; electrical idle is tx_p = tx_n = 0. On the receive side a clock carries signal when rx_p != rx_n; data bits are taken from rx_p. Dwords are sent LSB first. * OOB: a pattern is 4 bursts of 16 clk of signal, each preceded by a gap of electrical idle: 48 clk for COMRESET / COMINIT, 16 clk for COMWAKE. The receiver classifies each gap between two bursts of 12..20 clk (40..56 = INIT gap, 12..20 = WAKE gap); three equal gaps in a row detect COMINIT or COMWAKE. * Host PHY init: COMRESET -> wait COMINIT -> COMWAKE -> wait COMWAKE -> send ALIGNp and lock the receiver on the device's ALIGNp stream (two in a row) -> READY. Each wait times out after 1024 clk and restarts with COMRESET. In READY a clock of electrical idle (signal lost, e.g. the device starting COMINIT) is a link loss (irq) and restarts the bring-up; no dword completes on an idle clock. * Link layer (primitives as dword values; ALIGNp is dropped anywhere): transmit X_RDY -> R_RDY -> SOF, FIS dwords, CRC32, EOF -> WTRM until R_OK (done) or R_ERR (resend, at most 2 resends). Receive X_RDY -> send R_RDY, R_IP during the frame, then R_OK / R_ERR (bad CRC, more than 9 FIS dwords) until SYNC. Idle: SYNC (at least one SYNC dword goes out between two transmitted frames). When both sides raise X_RDY the host backs off and receives first. Handshake waits time out after 64 dwords. * CRC32: poly 32'h04C11DB7 reflected (32'hEDB88320), init all-ones, one dword LSB first per step, complemented on the wire. * Command sequencer (the port contract has no command bus): IDENTIFY DEVICE (Register H2D 8'hEC -> Data FIS of 8 dwords, dword 1 [5:0] = max LBA -> Register D2H), then forever: WRITE DMA EXT of one 8-dword sector (Register H2D 8'h35 -> DMA Activate -> Data FIS -> D2H) with xorshift32 data, READ DMA EXT of the same LBA (8'h25 -> Data FIS -> D2H) compared against the written data, next LBA (wraps after max). A D2H with ERR set or a non-zero error byte ends the command early. * irq: 1-clk pulse on link loss, an illegal primitive between frames, a received frame error (CRC / overflow / aborted / handshake timeout), a transmit failure (resends exhausted / timeout), an unexpected or malformed FIS, a status error, read data mismatch, or a command response timeout (4096 clk). * refclk is kept for interface compatibility; the line clock is clk.


tx_p / tx_n, rx_p / rx_n (1 line bit per PCLK, no 8b/10b) and refclk (interface compatibility only) pass through unchanged. The host brings the link up and runs its command sequence on its own after reset.
The registers report the host's error events; commands and data stay on the serial pins.

## Files

| File | Content |
|---|---|
| `rtl/SATA_top.sv` | protocol core |
| `rtl/SATA_apb.sv` | APB4 register wrapper (generated) |
| `tb/SATA_tb.sv` | core testbench |
| `tb/SATA_apb_tb.sv`, `tb/apb/SATA_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SATA_sva.sv`, `tb/cov/SATA_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SATA.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.SATA sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.SATA apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh SATA          # core coverage (Verilator)
bash scripts/cov/run_cov.sh SATA_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_n` | output | 1 | pin (pass-through) |
| `tx_p` | output | 1 | pin (pass-through) |
| `rx_n` | input | 1 | pin (pass-through) |
| `rx_p` | input | 1 | pin (pass-through) |
| `refclk` | input | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`SATA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_n`, `tx_p`, `rx_n`, `rx_p`, `refclk`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5354 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | link loss, illegal primitive, receive frame error (CRC, overflow, abort, handshake timeout), transmit failure (resends exhausted, timeout), unexpected or malformed FIS, error status, read data mismatch, or a command response timeout |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SATA_top.sv` | pass | 228/228 | 1474/1474 | 75/75 | 5/5 | 33/33 |
| wrapper `rtl/SATA_apb.sv` | pass | 19/19 | 402/402 | n/a | 7/7 | 23/23 |
