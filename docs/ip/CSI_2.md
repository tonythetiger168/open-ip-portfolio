# MIPI CSI-2 receiver, packet layer on a 1 bit per clock HS lane: SoT sync, header ECC (single-bit correction), short packets (frame start / end), long packets with CRC-16 into a ping-pong line buffer

Protocol IP `CSI_2`, version 2.0. Apache-2.0.

## Overview

MIPI CSI-2 receiver (camera side link, packet layer) Implementation scope: * Serial HS input model: 1 bit/clk on rx_bit while rx_valid is high, LSB-first per byte. rx_valid high = one HS burst (SoT .. EoT). * SoT: the 8'hB8 sync byte is hunted bit by bit from the start of a burst (any number of leading HS-zero bits). After a packet, a further sync byte on the same byte alignment starts another packet in the same burst; anything else is EoT trailer and is ignored to burst end. * Packet header DI/VC + WC/data[15:0] + ECC byte (CSI-2 Hamming code, 6 parity bits, SEC-DED):

- syndrome == 0             -> clean header
- syndrome of a data bit    -> single error corrected in place
- one-hot syndrome          -> error inside the ECC byte, data ok
- otherwise                 -> uncorrectable, packet dropped + irq
* Short packets (DT 6'h00..6'h0F): FS=0x00 opens a frame (frame_cnt++,
line_cnt and err_flags cleared), FE=0x01 closes it; the 16-bit data
field of every short packet is reported in last_wc.
* Long packets (DT >= 6'h10): WC payload bytes, then CRC-16/CCITT
(poly 0x1021, init 0xFFFF, LSB-first on the wire). The payload goes
into the back half of a ping-pong line buffer; a good CRC swaps the
halves and bumps line_cnt, so the read port always shows the last
good line. Bytes beyond LINE_BYTES are checked but not stored.
* irq: protocol error, held until the next good packet.
err_flags: [0] CRC  [1] ECC uncorrectable  [2] burst ended inside a
packet  [3] ECC corrected; they accumulate and clear at Frame Start.

rx_bit and rx_valid are the lane pins (rx_valid high for one HS burst, one bit per PCLK, LSB first); they pass through unchanged.
The line buffer is double-buffered: a long packet fills the back half and a good CRC swaps the halves, so LB_DATA always reads the last good line. Bytes beyond 512 are checked but not stored.

## Files

| File | Content |
|---|---|
| `rtl/CSI_2_top.sv` | protocol core |
| `rtl/CSI_2_apb.sv` | APB4 register wrapper (generated) |
| `tb/CSI_2_tb.sv` | core testbench |
| `tb/CSI_2_apb_tb.sv`, `tb/apb/CSI_2_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CSI_2_sva.sv`, `tb/cov/CSI_2_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CSI_2.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.CSI_2 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.CSI_2 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh CSI_2          # core coverage (Verilator)
bash scripts/cov/run_cov.sh CSI_2_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rx_bit` | input | 1 | pin (pass-through) |
| `rx_valid` | input | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERROR |
| `frame_active` | output | 1 | STATUS[0:0] |
| `frame_cnt` | output | 16 | COUNTS[15:0] |
| `line_cnt` | output | 16 | COUNTS[31:16] |
| `last_dt` | output | 8 | LAST[7:0] |
| `last_wc` | output | 16 | LAST[23:8] |
| `err_flags` | output | 4 | STATUS[4:1] |
| `lb_len` | output | 16 | STATUS[20:5] |
| `lb_addr` | input | 9 | LB_ADDR[8:0] |
| `lb_rdata` | output | 8 | LB_DATA[7:0] |

## APB wrapper

`CSI_2_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_bit`, `rx_valid`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43320200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | 0x00000000 | Receiver state |
| 0x018 | COUNTS | RO | 0x00000000 | Counters |
| 0x01C | LAST | RO | 0x00000000 | Last accepted header |
| 0x020 | LB_ADDR | RW | 0x00000000 | Line buffer read address |
| 0x024 | LB_DATA | RO | 0x00000000 | Line buffer data |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4332 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| STATUS | 0 | `frame_active` | between a Frame Start and a Frame End |
| STATUS | 4:1 | `err_flags` | [0] CRC error, [1] uncorrectable header, [2] burst ended inside a packet, [3] header corrected; they accumulate and clear at Frame Start |
| STATUS | 20:5 | `lb_len` | bytes in the readable line (the last long packet with a good CRC, at most 512) |
| COUNTS | 15:0 | `frame_cnt` | Frame Starts received (wraps) |
| COUNTS | 31:16 | `line_cnt` | good long packets since the last Frame Start |
| LAST | 7:0 | `last_dt` | {VC[1:0], DT[5:0]} |
| LAST | 23:8 | `last_wc` | word count (long packet) or data field (short packet) |
| LB_ADDR | 8:0 | `lb_addr` | byte of the readable line shown in LB_DATA |
| LB_DATA | 7:0 | `lb_rdata` | byte LB_ADDR of the last good line |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERROR | a CRC error or an uncorrectable header; the core holds it until the next good packet, so the bit is set again on every clock until then |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CSI_2_top.sv` | pass | 53/53 | 520/520 (+12 excl.) | 23/23 | 8/8 | 27/27 |
| wrapper `rtl/CSI_2_apb.sv` | pass | 26/26 | 612/612 (+12 excl.) | n/a | 8/8 | 33/33 |
