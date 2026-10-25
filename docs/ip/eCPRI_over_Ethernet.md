# eCPRI over Ethernet node: 64-byte Ethernet frames with FCS, address and Ethertype filter, eCPRI IQ data into a 32-word buffer with seq_id gap tracking, generic memory transfer against a 64 x 32-bit memory, remote reset, event indication with fault / sync acks, and CPU fault injection

Protocol IP `eCPRI_over_Ethernet`, version 2.0. Apache-2.0.

## Overview

eCPRI over Ethernet -- eCPRI message layer slice (node side)

- Ethernet frame parse/generate: DMAC + SMAC + Ethertype 0xAEFE +
payload + FCS (CRC-32/ISO-HDLC reflected, init/xorout 0xFFFFFFFF,
FCS sent LSB-byte first; rx residue check == 0xDEBB20E3).
Preamble/SFD/IFG are handled by the external MAC (byte stream i/f).
- Every frame is a minimum-size (64 byte) Ethernet frame: an eCPRI
payload is at most 40 bytes, so TX zero-pads to 60 bytes + FCS and RX
requires exactly 64 bytes. tx_en drops for at least one cycle between
frames.
- RX address filter: DMAC must be the node's own MAC (cfg_smac) or
broadcast; other frames and non-0xAEFE frames are dropped silently.
- eCPRI common header {rev[4]=1,rsvd[3],c[1], msgtype[8], payload_size[16]}
- msgtype 0: IQ data -- pc_id[16] + seq_id[16] + IQ bytes (<=32B, must be
a multiple of 4) packed big-endian into a 32x32 IQ buffer (cpu pop);
seq_id gap tracking per link
- msgtype 4: generic memory transfer -- remote_addr[32] + rw[8]
(1=write + data[32], 0=read) against a 64x32 memory (byte address,
word aligned, < 256); read triggers a response frame (rw=2)
- msgtype 5: remote reset -- reset_id[16] + op[8] (1=request, plus
optional vendor bytes); drives reset_op and answers op=2 (response)
- msgtype 6: event indication -- event_id + type + seq + n_elem and
n_elem x 8-byte elements (payload_size == 4 + 8*n_elem, n_elem <= 4).
type 0 (fault) is answered with type 1 (fault ack), type 3 (sync
request) with type 4 (sync ack); type 1 matching the last injected
fault clears ack_wait; types 2/4/5 are recorded only.
- cpu fault injection queues a fault indication frame (one element,
element id 0xFFFF, raise/cease + 12-bit fault number, own seq).
- rx_smac (cpu regs 10/11) holds the source MAC of the last accepted
message.
- errors (sticky irq): bad FCS; bad length / revision / payload shape;
concatenated message (c=1); unsupported msgtype; IQ buffer or TX
queue overflow and injection while one is still pending.

rx_d / rx_dv (received frame bytes), tx_d / tx_en (transmitted frame bytes) and reset_op pass through unchanged. Preamble, SFD and IFG belong to the external MAC.
The core's CPU port is mapped one word per register; a write with PSTRB != 4'hF to a writable word is dropped with PSLVERR.

## Files

| File | Content |
|---|---|
| `rtl/eCPRI_over_Ethernet_top.sv` | protocol core |
| `rtl/eCPRI_over_Ethernet_apb.sv` | APB4 register wrapper (generated) |
| `tb/eCPRI_over_Ethernet_tb.sv` | core testbench |
| `tb/eCPRI_over_Ethernet_apb_tb.sv`, `tb/apb/eCPRI_over_Ethernet_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/eCPRI_over_Ethernet_sva.sv`, `tb/cov/eCPRI_over_Ethernet_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/eCPRI_over_Ethernet.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.eCPRI_over_Ethernet sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.eCPRI_over_Ethernet apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh eCPRI_over_Ethernet          # core coverage (Verilator)
bash scripts/cov/run_cov.sh eCPRI_over_Ethernet_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rx_d` | input | 8 | pin (pass-through) |
| `rx_dv` | input | 1 | pin (pass-through) |
| `tx_d` | output | 8 | pin (pass-through) |
| `tx_en` | output | 1 | pin (pass-through) |
| `reset_op` | output | 16 | pin (pass-through) |
| `cpu_we` | input | 1 | write to a CORE word |
| `cpu_re` | input | 1 | read of a CORE word |
| `cpu_addr` | input | 4 | CORE word index |
| `cpu_wdata` | input | 32 | CORE write data |
| `cpu_rdata` | output | 32 | CORE read data |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`eCPRI_over_Ethernet_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_d`, `rx_dv`, `tx_d`, `tx_en`, `reset_op`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x65430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | DMAC_LO | RW (core) | 0x00000000 | peer MAC [31:0] (DMAC of transmitted frames); reset 0xCCDDEEFF |
| 0x018 | DMAC_HI | RW (core) | 0x00000000 | [15:0] peer MAC [47:32]; reset 0xAABB |
| 0x01C | SMAC_LO | RW (core) | 0x00000000 | own MAC [31:0] (SMAC of transmitted frames, RX address filter); reset 0x33445566 |
| 0x020 | SMAC_HI | RW (core) | 0x00000000 | [15:0] own MAC [47:32]; reset 0x1122 |
| 0x024 | IQ | RO (core) | 0x00000000 | IQ buffer head (32 x 32-bit, big-endian packed IQ bytes); the read pops it |
| 0x028 | COUNTS | RO (core) | 0x00000000 | {rx error count[7:0], rx ok count[7:0], seq_id gap count[7:0], 2'b0, IQ words[5:0]} |
| 0x02C | IQ_LAST | RO (core) | 0x00000000 | {pc_id[15:0], seq_id[15:0]} of the last IQ message |
| 0x030 | EVENT | RW (core) | 0x00000000 | write: inject a fault indication {raise[20], fault number[19:8], event_id[7:0]}; read: last recorded event {8'h0, seq[7:0], 5'h0, type[2:0], event_id[7:0]} |
| 0x034 | ERRORS | RW (core) | 0x00000000 | {concat, overflow, malformed, msgtype, fcs} error flags (sticky, write 1 to clear; a new error in the same clock wins) |
| 0x038 | RESET_OP | RW (core) | 0x00000000 | [15:0] reset_id of the last remote reset request (also the reset_op pin); write bit 0 = 1 to clear |
| 0x03C | RX_SMAC_LO | RO (core) | 0x00000000 | source MAC [31:0] of the last accepted message |
| 0x040 | RX_SMAC_HI | RO (core) | 0x00000000 | [15:0] source MAC [47:32] of the last accepted message |
| 0x044 | TX_STATUS | RO (core) | 0x00000000 | {14'h0, ack_wait, injection pending, tx seq[7:0], 5'h0, TX queue count[2:0]} |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x6543 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| DMAC_LO | 31:0 | core register | written at core register 0 and read from core register 0 |
| DMAC_HI | 31:0 | core register | written at core register 1 and read from core register 1 |
| SMAC_LO | 31:0 | core register | written at core register 2 and read from core register 2 |
| SMAC_HI | 31:0 | core register | written at core register 3 and read from core register 3 |
| IQ | 31:0 | core register | read from core register 4 |
| COUNTS | 31:0 | core register | read from core register 5 |
| IQ_LAST | 31:0 | core register | read from core register 6 |
| EVENT | 31:0 | core register | written at core register 7 and read from core register 7 |
| ERRORS | 31:0 | core register | written at core register 8 and read from core register 8 |
| RESET_OP | 31:0 | core register | written at core register 9 and read from core register 9 |
| RX_SMAC_LO | 31:0 | core register | read from core register 10 |
| RX_SMAC_HI | 31:0 | core register | read from core register 11 |
| TX_STATUS | 31:0 | core register | read from core register 12 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | any ERRORS flag is set (FCS, msgtype, malformed message, IQ buffer / TX queue overflow, concatenation); held until ERRORS is cleared, so the bit is set again on every clock until then |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `cpu_we` for one clock with `cpu_addr` (the core register) and `cpu_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `cpu_addr` (the core register) and pulses `cpu_re` during the access phase and returns `cpu_rdata`.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/eCPRI_over_Ethernet_top.sv` | pass | 217/217 | 1986/1986 | 8/8 | 6/6 | 43/43 |
| wrapper `rtl/eCPRI_over_Ethernet_apb.sv` | pass | 32/32 | 618/618 | n/a | 11/11 | 50/50 |
