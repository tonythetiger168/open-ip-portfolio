# UFS device link: training handshake, SOF / header / payload / CRC-32 / EOF frames on a serial lane, COMMAND UPIUs (TEST UNIT READY, READ10, WRITE10) answered with RESPONSE and DATA UPIUs from a 256 x 32-bit LUN0 medium

Protocol IP `UFS`, version 2.0. Apache-2.0.

## Overview

UFS protocol Open IP -- UFS host: simplified UniPro frame link + UPIU command transactions (TEST UNIT READY / READ10 / WRITE10 on a serial lane) Open IP design implementation v2.5 Simplifications (per SPEC.md section 2.4): * refclk is kept for interface compatibility only; the lane symbol clock is derived from clk (1 bit per clk, MSB-first within each 32-bit dword). * Frame : SOF(32'h5546_5301) HDR PAYLOAD(len <= 8 dwords) CRC32 EOF(32'h5546_5302) HDR   : {type[7:0], task_tag[7:0], lun[7:0], len[7:0]} CRC32 : poly 32'h04C11DB7 (reflected shift form 32'hEDB8_8320), init all-ones, final XOR all-ones; computed over the on-the-wire bit stream of HDR+PAYLOAD and transmitted as one dword MSB-first. * COMMAND UPIU (type 8'h01): payload[0..3] = 16-byte CDB dword0 = {opcode[7:0], lba[23:0]}, dword1 = {xfer_dwords[7:0], 24'h0} WRITE10 data is carried inline in payload[4..7] (count = len-4 dwords) * RESPONSE UPIU (type 8'h81): payload[0] = {sense[15:0], status[15:0]} READ10 data follows in a DATA UPIU (type 8'h02) * LUN0 medium: internal 256 x 32-bit storage array. * One command at a time: a COMMAND UPIU that completes while the previous response (or its DATA UPIU) is still owed or on the wire is dropped with irq, so a transmitting frame is never overwritten. * LUN0 only: a command for another LUN gets CHECK CONDITION / ILLEGAL REQUEST. WRITE10 needs the CDB transfer length to equal the inline data dword count. * Frames of other UPIU types are ignored. * irq pulses one clk on: CRC mismatch, unknown opcode, len > 8, bad EOF, malformed CDB, bad LUN, out-of-range LBA/transfer length or a command while busy.


tx_p / tx_n (serial out, 1 bit per PCLK), rx_p / rx_n (serial in; only rx_p is sampled) and refclk pass through unchanged. The core trains the link on its own after reset and answers the commands the link partner sends.
The LUN0 medium is reached over the serial link only; the registers report its errors.

## Files

| File | Content |
|---|---|
| `rtl/UFS_top.sv` | protocol core |
| `rtl/UFS_apb.sv` | APB4 register wrapper (generated) |
| `tb/UFS_tb.sv` | core testbench |
| `tb/UFS_apb_tb.sv`, `tb/apb/UFS_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/UFS_sva.sv`, `tb/cov/UFS_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/UFS.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.UFS sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.UFS apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh UFS          # core coverage (Verilator)
bash scripts/cov/run_cov.sh UFS_apb      # wrapper coverage
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

`UFS_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_n`, `tx_p`, `rx_n`, `rx_p`, `refclk`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55460200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5546 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | CRC mismatch, bad EOF, length above 8, malformed CDB, bad LUN, unknown opcode, out-of-range LBA or transfer length, WRITE10 length mismatch, or a command while a response is still owed |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/UFS_top.sv` | pass | 103/103 (+1 excl.) | 1156/1156 | 26/26 | 5/5 | 20/20 |
| wrapper `rtl/UFS_apb.sv` | pass | 19/19 | 402/402 | n/a | 7/7 | 23/23 |
