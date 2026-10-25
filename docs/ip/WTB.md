# IEEE 802.4-style token-bus station: serial frames with preamble, SD, FC, DA, SA, LEN, payload, CRC-16 and ED; token hold with up to four data frames inside a programmable window, token pass to the next station, claim_token contention, an 8-word TX FIFO and an 8-word RX FIFO

Protocol IP `WTB`, version 2.0. Apache-2.0.

## Overview

WTB protocol -- IEEE 802.4 style token-bus station (educational slice) Frame: preamble(8'h55 x2) + SD(8'hD5) + FC{0=claim,1=token,2=data,3=solicit} + DA + SA + LEN + payload(<=16B) + CRC16(0x1021,init 0xFFFF) + ED(8'hD4) Serial rx/tx at 1 bit/clk (MSB first per byte), idle bus = 1. Station FSM: LISTEN -> token(DA==my_addr) -> HOLD: data frames (4-byte payload) from the 8x32 TX FIFO while fewer than MAX_FR frames were sent and the hold time is below the programmable window -> pass token to NS. claim_token contention after bus-idle timeout with response window: a claim from a lower address wins (we back off), a claim from a higher address is ignored, other traffic ends the attempt. The station hears its own frames on the bus; frames with SA == my_addr are ignored. Data frames for my_addr (or broadcast DA 8'hFF) with a good CRC and ED are delivered to an 8x32 RX FIFO: payload bytes packed big-endian into words, the last word zero-padded; a word that does not fit is dropped with irq. irq (1-clk pulse): bad CRC / bad ED / overlong frame, TX FIFO overflow, RX FIFO overflow, token acquired.


rx_bit (serial in, 1 bit per PCLK, idle 1; the station hears its own frames), tx_bit and tx_en pass through unchanged.
NS, DA and CTRL are write-only in the core and read back as 0. A write with PSTRB != 4'hF to a core word is dropped with PSLVERR.

## Files

| File | Content |
|---|---|
| `rtl/WTB_top.sv` | protocol core |
| `rtl/WTB_apb.sv` | APB4 register wrapper (generated) |
| `tb/WTB_tb.sv` | core testbench |
| `tb/WTB_apb_tb.sv`, `tb/apb/WTB_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/WTB_sva.sv`, `tb/cov/WTB_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/WTB.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.WTB sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.WTB apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh WTB          # core coverage (Verilator)
bash scripts/cov/run_cov.sh WTB_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rx_bit` | input | 1 | pin (pass-through) |
| `tx_bit` | output | 1 | pin (pass-through) |
| `tx_en` | output | 1 | pin (pass-through) |
| `my_addr` | input | 8 | MYADDR[7:0] |
| `cpu_we` | input | 1 | write to a CORE word |
| `cpu_addr` | input | 2 | CORE word index |
| `cpu_wdata` | input | 32 | CORE write data |
| `cpu_re` | input | 1 | read of a CORE word |
| `cpu_rdata` | output | 32 | CORE read data |
| `fifo_count` | output | 4 | STATUS[3:0] |
| `rx_count` | output | 4 | STATUS[7:4] |
| `token_held` | output | 1 | STATUS[8:8] |
| `irq` | output | 1 | IRQ_STATUS.EVT |

## APB wrapper

`WTB_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_bit`, `tx_bit`, `tx_en`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x57540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | MYADDR | RW | 0x00000011 | Station identity |
| 0x018 | STATUS | RO | 0x00000000 | Station state |
| 0x01C | TXF | WO (core) | 0x00000000 | push one 32-bit word (the payload of one 4-byte data frame) onto the TX FIFO; a push to a full FIFO is dropped with EVT |
| 0x020 | NS | WO (core) | 0x00000000 | [7:0] next station: DA of the token pass |
| 0x024 | DA | WO (core) | 0x00000000 | [7:0] DA of the data frames |
| 0x028 | CTRL | WO (core) | 0x00000000 | [16:8] token holding window in clocks, [0] claim_en (claim the token after 300 idle clocks) |
| 0x02C | RXF | RO (core) | 0x00000000 | RX FIFO head: received payload bytes packed big-endian, the last word zero-padded; the read pops it |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5754 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| MYADDR | 7:0 | `my_addr` | this station's bus address (DA of its tokens and data, SA of its frames) |
| STATUS | 3:0 | `fifo_count` | TX FIFO words (0..8) |
| STATUS | 7:4 | `rx_count` | RX FIFO words (0..8) |
| STATUS | 8 | `token_held` | the station holds the token |
| TXF | 31:0 | core register | written at core register 0 |
| NS | 31:0 | core register | written at core register 1 |
| DA | 31:0 | core register | written at core register 2 |
| CTRL | 31:0 | core register | written at core register 3 |
| RXF | 31:0 | core register | read from core register 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | EVT | token acquired, or an error: bad CRC, bad ED or overlong frame received, TX FIFO overflow, RX FIFO overflow |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `cpu_we` for one clock with `cpu_addr` (the core register) and `cpu_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `cpu_addr` (the core register) and pulses `cpu_re` during the access phase and returns `cpu_rdata`.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/WTB_top.sv` | pass | 105/105 | 2140/2140 | 59/59 | 8/8 | 24/24 |
| wrapper `rtl/WTB_apb.sv` | pass | 24/24 | 594/594 | n/a | 12/12 | 38/38 |
