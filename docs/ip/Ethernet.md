# IEEE 802.3 MAC (GMII-style byte interface) with address filtering and PAUSE flow control

Protocol IP `Ethernet`, version 2.0. Apache-2.0.

## Overview

Ethernet_top v2.0: IEEE 802.3 MAC (one port, GMII-style byte interface) with address filtering and PAUSE flow control

- Line: one byte per byte time of cfg_div + 1 clocks (gtxd / gtx_en /
gtx_er change once per byte time; grxd / grx_dv / grx_er are sampled
once per byte time, so the far end must use the same byte time).
- Transmit: a frame (DA .. payload) comes from the tx_* stream, one
byte per byte time (tx_ready is high for one clock at the byte time,
tx_last marks the last byte). The MAC sends 7 preamble bytes 0x55 and
the SFD 0xD5, the frame, zero padding up to 60 bytes, the FCS (CRC-32,
least significant byte first) and at least 12 idle byte times. Without
a byte in time it sends one byte with gtx_er, ends the frame and
pulses tx_underrun. tx_done pulses after the FCS. No new frame starts
while a PAUSE is running (tx_paused).
- Receive: any number of 0x55 then 0xD5 starts a frame (another byte
drops it). A frame is accepted when its DA is cfg_mac, broadcast, the
PAUSE address 01-80-C2-00-00-01, or anything with cfg_promisc. Bytes go
out on rx_* six byte times late, without the FCS; the last one has
rx_last and rx_stat = {pause, phy_err, len_err, crc_err}:
crc_err  the FCS does not check
len_err  shorter than 64 bytes, or longer than 1518 (1522 with a
VLAN tag, type 0x8100), FCS included
phy_err  grx_er during the frame
pause    a MAC control PAUSE frame (type 0x8808, opcode 0x0001)
A frame that ends before its sixth byte, or a bad preamble, pulses
rx_frag; a frame that fails the filter is dropped silently.
- PAUSE: an error-free PAUSE frame with cfg_pause_en holds the
transmitter for quanta x 64 byte times (512 bit times each).
Not implemented: half duplex (CSMA/CD), sending PAUSE frames, PFC,
multicast hash filtering, statistics counters, jumbo frames.

gtxd / gtx_en / gtx_er and grxd / grx_dv / grx_er are the GMII-style line pins; they pass through unchanged.

## Files

| File | Content |
|---|---|
| `rtl/Ethernet_top.sv` | protocol core |
| `rtl/Ethernet_apb.sv` | APB4 register wrapper (generated) |
| `tb/Ethernet_tb.sv` | core testbench |
| `tb/Ethernet_apb_tb.sv`, `tb/apb/Ethernet_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Ethernet_sva.sv`, `tb/cov/Ethernet_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Ethernet.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.Ethernet sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.Ethernet apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh Ethernet          # core coverage (Verilator)
bash scripts/cov/run_cov.sh Ethernet_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_div` | input | 5 | CFG[4:0] |
| `cfg_mac` | input | 48 | MAC0[31:0], MAC1[15:0] |
| `cfg_promisc` | input | 1 | CFG[5:5] |
| `cfg_pause_en` | input | 1 | CFG[6:6] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 8 | TX[7:0] |
| `tx_last` | input | 1 | TX[8:8] |
| `tx_done` | output | 1 | IRQ_STATUS.TX_SENT |
| `tx_underrun` | output | 1 | IRQ_STATUS.TX_UNDERRUN |
| `tx_paused` | output | 1 | STATUS |
| `gtxd` | output | 8 | pin (pass-through) |
| `gtx_en` | output | 1 | pin (pass-through) |
| `gtx_er` | output | 1 | pin (pass-through) |
| `grxd` | input | 8 | pin (pass-through) |
| `grx_dv` | input | 1 | pin (pass-through) |
| `grx_er` | input | 1 | pin (pass-through) |
| `rx_valid` | output | 1 | RX capture |
| `rx_data` | output | 8 | RX[7:0] |
| `rx_last` | output | 1 | RX[8:8] |
| `rx_stat` | output | 4 | RX[12:9] |
| `rx_frag` | output | 1 | IRQ_STATUS.RX_FRAG |

## APB wrapper

`Ethernet_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `gtxd`, `gtx_en`, `gtx_er`, `grxd`, `grx_dv`, `grx_er`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x45540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x0000005F | Byte time and receive options |
| 0x018 | MAC0 | RW | 0x00000000 | Station address (MAC0 = bits 31:0, MAC1 = bits 47:32; the first byte on the wire is bits 47:40) |
| 0x01C | MAC1 | RW | 0x00000000 | Station address (MAC0 = bits 31:0, MAC1 = bits 47:32; the first byte on the wire is bits 47:40) |
| 0x020 | TX | RW | 0x00000000 | Transmit byte (DA first; the MAC adds preamble, padding and FCS); a frame starts once its first byte is in TX, and each next byte must arrive within a byte time |
| 0x024 | RX | RO (pop) | 0x00000000 | Received byte (FCS removed); read it within a byte time |
| 0x028 | STATUS | RO | 0x00000000 | Flow control |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4554 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CFG | 4:0 | `cfg_div` | byte time - 1 in PCLK (both ends of the link alike) |
| CFG | 5 | `cfg_promisc` | accept every DA |
| CFG | 6 | `cfg_pause_en` | obey received PAUSE frames |
| MAC0 | 31:0 | `cfg_mac[31:0]` | station address |
| MAC1 | 15:0 | `cfg_mac[47:32]` | station address |
| TX | 7:0 | `tx_data` | byte |
| TX | 8 | `tx_last` | last byte of the frame |
| RX | 7:0 | `rx_data` | byte |
| RX | 8 | `rx_last` | last byte of the frame |
| RX | 12:9 | `rx_stat` | with rx_last: {pause, phy_err, len_err, crc_err} |
| STATUS | 0 | `tx_paused` | a received PAUSE holds the transmitter |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_SENT | a frame was sent (FCS out) |
| 1 | TX_UNDERRUN | a transmit byte was late: the frame was ended with gtx_er |
| 2 | RX_FRAG | a fragment or a bad preamble was received and dropped |
| 3 | TX_DONE | TX beat accepted by the core |
| 4 | TX_OVF | write to TX while full (dropped) |
| 5 | RX_AVAIL | RX captured a beat |
| 6 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_last`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_last`, `rx_stat` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Ethernet_top.sv` | pass | 75/75 | 726/726 | 33/33 | 8/8 | 22/22 |
| wrapper `rtl/Ethernet_apb.sv` | pass | 40/40 | 808/808 | n/a | 15/15 | 67/67 |
