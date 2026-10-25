# MIPI DSI host transmitter, packet layer on a 1 bit per clock HS lane: short and long packets with header ECC and CRC-16, DCS writes, video-mode lines, DCS read with bus turn-around and an ECC-checked response

Protocol IP `DSI`, version 2.0. Apache-2.0.

## Overview

MIPI DSI host transmitter (packet layer, command + video mode, BTA) Implementation scope: * Serial HS output model: 1 bit/clk on tx_bit while tx_valid is high, LSB-first per byte; SoT sync byte 8'hB8 per packet (lane/LP states abstracted: tx_oe marks host bus ownership, idle level = 1) * Packet layer: header DI+WC/data[15:0]+ECC (Hamming(30,24) subset, P7=P6=0, single-error correction on receive); long packets append CRC-16/CCITT (reflected poly 0x8408, init 0xFFFF), low byte first * Command ops (cmd_op): 0 OP_SPKT   raw short packet        (DT=cmd_dt, data=cmd_len) 1 OP_DCS_S0 DCS short write 0 param (DT=0x05, data={00,cmd_dcs}) 2 OP_DCS_S1 DCS short write 1 param (DT=0x15, data={ram[0],cmd_dcs}) 3 OP_DCS_L  DCS long write          (DT=0x39, WC=cmd_len, payload RAM) 4 OP_VLINE  video-mode line: HSS(0x21), HSE(0x31), HBP blanking (0x19, WC=cmd_len2, zero payload), HACT RGB888 (0x3E, WC=cmd_len, payload RAM) 5 OP_DCS_RD DCS read (DT=0x06, data={00,cmd_dcs}) + bus turn-around 6, 7        invalid: rejected with irq A command whose RAM payload is longer than the 32-byte RAM, or whose HACT WC is not a whole number of RGB888 pixels (3 bytes), is rejected with irq and nothing is sent. * BTA: after the read-request packet the host sends the BTA trigger byte (8'h84, escape-command abstraction), releases the lane (tx_oe=0) and receives a peripheral short-packet response with ECC checking (single-error corrected; bta_data = {data1, data0, DI}). An Acknowledge-and-Error-Report response (DT 0x02) with any error bit set completes the read and raises irq. A timeout (BTA_TO clocks without a SoT), a bad SoT byte or an uncorrectable header raise irq. * irq is a one-clock pulse. * 32-byte payload RAM written via pl_we/pl_addr.


tx_bit and tx_valid (the HS lane, one bit per PCLK, LSB first, idle 1), tx_oe (the host owns the lane) and rx_bit (driven by the peripheral after the turn-around) pass through unchanged; tx_oe is also readable in STATUS.
PL0..PL31 write the 32-byte payload RAM (write only, whole words: a partial-strobe write gets PSLVERR). The lane states (LP, HS entry) are abstracted to tx_valid.

## Files

| File | Content |
|---|---|
| `rtl/DSI_top.sv` | protocol core |
| `rtl/DSI_apb.sv` | APB4 register wrapper (generated) |
| `tb/DSI_tb.sv` | core testbench |
| `tb/DSI_apb_tb.sv`, `tb/apb/DSI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/DSI_sva.sv`, `tb/cov/DSI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/DSI.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.DSI sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.DSI apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh DSI          # core coverage (Verilator)
bash scripts/cov/run_cov.sh DSI_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `irq` | output | 1 | IRQ_STATUS.ERROR |
| `tx_bit` | output | 1 | pin (pass-through) |
| `tx_valid` | output | 1 | pin (pass-through) |
| `tx_oe` | output | 1 | STATUS[1:1] |
| `rx_bit` | input | 1 | pin (pass-through) |
| `cmd_valid` | input | 1 | GO |
| `cmd_op` | input | 3 | CMD[2:0] |
| `cmd_dt` | input | 6 | CMD[8:3] |
| `cmd_dcs` | input | 8 | CMD[16:9] |
| `cmd_len` | input | 16 | LEN[15:0] |
| `cmd_len2` | input | 16 | LEN[31:16] |
| `cmd_busy` | output | 1 | STATUS[0:0] |
| `pl_we` | input | 1 | write to a PAYLOAD word |
| `pl_addr` | input | 5 | PAYLOAD word index |
| `pl_wdata` | input | 8 | PAYLOAD write data |
| `bta_done` | output | 1 | IRQ_STATUS.BTA_DONE |
| `bta_data` | output | 24 | BTA[23:0] |
| `pkt_cnt` | output | 16 | STATUS[17:2] |

## APB wrapper

`DSI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_bit`, `tx_valid`, `tx_oe`, `rx_bit`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD | RW | 0x00000000 | Command |
| 0x018 | LEN | RW | 0x00000000 | Lengths |
| 0x01C | GO | WO (pulse) | 0x00000000 | Start |
| 0x020 | PL0 | WO (core) | 0x00000000 | payload RAM byte 0 (write only) |
| 0x024 | PL1 | WO (core) | 0x00000000 | payload RAM byte 1 (write only) |
| 0x028 | PL2 | WO (core) | 0x00000000 | payload RAM byte 2 (write only) |
| 0x02C | PL3 | WO (core) | 0x00000000 | payload RAM byte 3 (write only) |
| 0x030 | PL4 | WO (core) | 0x00000000 | payload RAM byte 4 (write only) |
| 0x034 | PL5 | WO (core) | 0x00000000 | payload RAM byte 5 (write only) |
| 0x038 | PL6 | WO (core) | 0x00000000 | payload RAM byte 6 (write only) |
| 0x03C | PL7 | WO (core) | 0x00000000 | payload RAM byte 7 (write only) |
| 0x040 | PL8 | WO (core) | 0x00000000 | payload RAM byte 8 (write only) |
| 0x044 | PL9 | WO (core) | 0x00000000 | payload RAM byte 9 (write only) |
| 0x048 | PL10 | WO (core) | 0x00000000 | payload RAM byte 10 (write only) |
| 0x04C | PL11 | WO (core) | 0x00000000 | payload RAM byte 11 (write only) |
| 0x050 | PL12 | WO (core) | 0x00000000 | payload RAM byte 12 (write only) |
| 0x054 | PL13 | WO (core) | 0x00000000 | payload RAM byte 13 (write only) |
| 0x058 | PL14 | WO (core) | 0x00000000 | payload RAM byte 14 (write only) |
| 0x05C | PL15 | WO (core) | 0x00000000 | payload RAM byte 15 (write only) |
| 0x060 | PL16 | WO (core) | 0x00000000 | payload RAM byte 16 (write only) |
| 0x064 | PL17 | WO (core) | 0x00000000 | payload RAM byte 17 (write only) |
| 0x068 | PL18 | WO (core) | 0x00000000 | payload RAM byte 18 (write only) |
| 0x06C | PL19 | WO (core) | 0x00000000 | payload RAM byte 19 (write only) |
| 0x070 | PL20 | WO (core) | 0x00000000 | payload RAM byte 20 (write only) |
| 0x074 | PL21 | WO (core) | 0x00000000 | payload RAM byte 21 (write only) |
| 0x078 | PL22 | WO (core) | 0x00000000 | payload RAM byte 22 (write only) |
| 0x07C | PL23 | WO (core) | 0x00000000 | payload RAM byte 23 (write only) |
| 0x080 | PL24 | WO (core) | 0x00000000 | payload RAM byte 24 (write only) |
| 0x084 | PL25 | WO (core) | 0x00000000 | payload RAM byte 25 (write only) |
| 0x088 | PL26 | WO (core) | 0x00000000 | payload RAM byte 26 (write only) |
| 0x08C | PL27 | WO (core) | 0x00000000 | payload RAM byte 27 (write only) |
| 0x090 | PL28 | WO (core) | 0x00000000 | payload RAM byte 28 (write only) |
| 0x094 | PL29 | WO (core) | 0x00000000 | payload RAM byte 29 (write only) |
| 0x098 | PL30 | WO (core) | 0x00000000 | payload RAM byte 30 (write only) |
| 0x09C | PL31 | WO (core) | 0x00000000 | payload RAM byte 31 (write only) |
| 0x0A0 | STATUS | RO | 0x00000000 | Host state |
| 0x0A4 | BTA | RO | 0x00000000 | Read response |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4453 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CMD | 2:0 | `cmd_op` | 0 raw short packet (DT cmd_dt, data LEN), 1 DCS short write without parameter, 2 DCS short write with PL0 as parameter, 3 DCS long write of LEN payload bytes, 4 video line (HSS, HSE, HBP of LEN2 zero bytes, HACT of LEN bytes), 5 DCS read and bus turn-around; 6 and 7 are rejected (ERROR) |
| CMD | 8:3 | `cmd_dt` | data type of a raw short packet |
| CMD | 16:9 | `cmd_dcs` | DCS command byte |
| LEN | 15:0 | `cmd_len` | raw short packet data, long-write length or HACT length (a payload above 32 bytes, or HACT not a multiple of 3, is rejected: ERROR) |
| LEN | 31:16 | `cmd_len2` | HBP blanking length of a video line |
| GO | 0 | `cmd_valid` | write 1: run CMD with LEN (ignored while STATUS.busy) |
| PL0 | 7:0 | core register | written at core register 0 |
| PL1 | 7:0 | core register | written at core register 1 |
| PL2 | 7:0 | core register | written at core register 2 |
| PL3 | 7:0 | core register | written at core register 3 |
| PL4 | 7:0 | core register | written at core register 4 |
| PL5 | 7:0 | core register | written at core register 5 |
| PL6 | 7:0 | core register | written at core register 6 |
| PL7 | 7:0 | core register | written at core register 7 |
| PL8 | 7:0 | core register | written at core register 8 |
| PL9 | 7:0 | core register | written at core register 9 |
| PL10 | 7:0 | core register | written at core register 10 |
| PL11 | 7:0 | core register | written at core register 11 |
| PL12 | 7:0 | core register | written at core register 12 |
| PL13 | 7:0 | core register | written at core register 13 |
| PL14 | 7:0 | core register | written at core register 14 |
| PL15 | 7:0 | core register | written at core register 15 |
| PL16 | 7:0 | core register | written at core register 16 |
| PL17 | 7:0 | core register | written at core register 17 |
| PL18 | 7:0 | core register | written at core register 18 |
| PL19 | 7:0 | core register | written at core register 19 |
| PL20 | 7:0 | core register | written at core register 20 |
| PL21 | 7:0 | core register | written at core register 21 |
| PL22 | 7:0 | core register | written at core register 22 |
| PL23 | 7:0 | core register | written at core register 23 |
| PL24 | 7:0 | core register | written at core register 24 |
| PL25 | 7:0 | core register | written at core register 25 |
| PL26 | 7:0 | core register | written at core register 26 |
| PL27 | 7:0 | core register | written at core register 27 |
| PL28 | 7:0 | core register | written at core register 28 |
| PL29 | 7:0 | core register | written at core register 29 |
| PL30 | 7:0 | core register | written at core register 30 |
| PL31 | 7:0 | core register | written at core register 31 |
| STATUS | 0 | `cmd_busy` | a command is running (sending, or waiting for the BTA response) |
| STATUS | 1 | `tx_oe` | the host owns the lane (low during the bus turn-around) |
| STATUS | 17:2 | `pkt_cnt` | packets sent (wraps) |
| BTA | 23:0 | `bta_data` | {data1, data0, DI} of the last accepted response, single-bit errors corrected |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BTA_DONE | a read response was accepted (BTA holds it) |
| 1 | ERROR | a command rejected, an Acknowledge-and-Error-Report response with error bits, no response within BTA_TO (512) clocks, a bad SoT byte or an uncorrectable response header |

### Core register port

The PAYLOAD words reach the core's own register port. A write to one pulses `pl_we` for one clock with `pl_addr` (the core register) and `pl_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. 

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/DSI_top.sv` | pass | 145/145 (+1 excl.) | 1218/1218 | 41/41 | 11/11 | 24/24 |
| wrapper `rtl/DSI_apb.sv` | pass | 29/29 | 784/784 | n/a | 15/15 | 103/103 |
