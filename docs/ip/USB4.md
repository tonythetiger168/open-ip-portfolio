# USB4-style transport layer adapter: transport layer packets with HEC-protected headers, HEC delineation with single-bit correction, two tunneled paths with HopID routing, credit-based flow control per path

Protocol IP `USB4`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `USB4_top` (`rtl/USB4_top.sv`) |
| Register interface | APB4 slave `USB4_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55340200 (code 0x5534, version 2.0) |
| Registers | 11 words, 0x000 to 0x028 |
| Interrupts | 9 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 2 pass-through |

## Overview

USB4_top v2.0: USB4-style transport layer adapter, one link (transport layer packets with HEC-protected headers, HEC delineation, two tunneled paths with HopID routing, credit-based flow control per path)

- Line: one byte per clk each way, most significant byte of each field
first, while link_up (the logical layer: lane bonding, 64b/66b /
128b/132b, RS-FEC and the LTSSM belong below). Packets go back to back
with no gaps; with nothing to send the transmitter sends Idle packets.
- Transport layer packet (TLP): a 4-byte header, then Length payload
bytes padded with zeros to a multiple of 4. Header = {PDF[3:0],
SuppID, HopID[10:0], Length[7:0], HEC[7:0]}; HEC = CRC-8 (x^8+x^2+x+1,
initial value 0, bit 31 first) of header bits 31:8, XOR 55h. SuppID
is sent 0 and ignored.
Idle: HopID 0, PDF 0, Length 0.
Credit grant: HopID 0, PDF 1, Length 4; payload {5'b0, HopID[10:0],
8'h00, count[7:0]}: the receiver's cumulative credit count for its
path with that (ingress) HopID.
Data: HopID of a path, Length 1..MAXL (PDF sent 0, ignored).
- Delineation (HEC, as in ATM cell delineation): HUNT checks the HEC of
every 4-byte window; a good one moves to PRESYNC at that alignment,
where packets are followed by their length but not delivered; DELTA
good headers in a row reach SYNC, a bad one returns to HUNT. In SYNC a
header with a single-bit error is corrected (ev_hec_fix); any other
HEC error returns to HUNT (ev_hec_bad). The link going down returns to
HUNT. After link_up the transmitter sends 2 x DELTA Idle packets first.
- Paths: two, each enabled by path_en[p], with an egress HopID (hop_txN,
put in its data packets) and an ingress HopID (hop_rxN, accepted from
the partner). Packets are written through tx_* with tx_path, one
buffer of MAXL bytes per path (a longer write is cut into packets).
Received packets are handed out through rx_* with rx_path, in arrival
order, from RXB buffers per path.
- Credits: one credit is one receive buffer. While its receiver is in
SYNC an adapter sends each enabled path's credit grant at once after
link up, again when one of the path's buffers is read out, and every
REFRESH clocks; a lost grant is made good by the next (counts are
cumulative). A path sends (path_up) once a grant for its egress HopID
arrived and while count - sent != 0; a grant with count - sent over
RXB, for no enabled path or with reserved bits set is ignored
(ev_proto). Credit counts restart at link up; a packet is kept until
its last byte went out with the link up, so one cut by the link going
down is sent again (the receiver drops the part it got).
- Receive errors (the packet is skipped by its length): HopID 0 with any
other PDF / Length (ev_proto), a HopID of no enabled path (ev_hop),
Length 0 or over MAXL on a path (ev_len), a packet for a path whose
buffers are all full (ev_overflow).
Not implemented: the logical layer, lane bonding, control packets and
the router configuration space, link management packets other than the
credit grant, path setup over the configuration space (the HopIDs are
pins here), more than two paths, Path Credits Sync and shared buffering,
the protocol adapters (DisplayPort, PCIe, USB3 tunnels). Field layouts
follow the USB4 transport layer as we read it; they have not been
checked against a compliant router.

tx_sym and rx_sym are the transport layer byte streams (one byte per clock each way while link_up); they pass through unchanged.
The core parameters MAXL (32), RXB (2 buffers per path), DELTA (4) and REFRESH (128) keep their defaults.

## Files

| File | Content |
|---|---|
| `rtl/USB4_top.sv` | protocol core |
| `rtl/USB4_apb.sv` | APB4 register wrapper (generated) |
| `tb/USB4_tb.sv` | core testbench |
| `tb/USB4_apb_tb.sv`, `tb/apb/USB4_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/USB4_sva.sv`, `tb/cov/USB4_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/USB4.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.USB4 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.USB4 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh USB4          # core coverage (Verilator)
bash scripts/cov/run_cov.sh USB4_apb      # wrapper coverage
```

## Parameters

`USB4_apb` has the core's parameters and passes them to `USB4_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `MAXL` | int | `32` |
| `RXB` | int | `2` |
| `DELTA` | int | `4` |
| `REFRESH` | int | `128` |

## Wrapper pins

Pins of `USB4_apb`. Widths of the pass-through pins are at the default parameters.

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
| `tx_sym` | output | 8 | protocol pin, core port `tx_sym` |
| `rx_sym` | input | 8 | protocol pin, core port `rx_sym` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `link_up` | input | 1 | CTRL[0:0] |
| `tx_sym` | output | 8 | pin (pass-through) |
| `rx_sym` | input | 8 | pin (pass-through) |
| `path_en` | input | 2 | CTRL[2:1] |
| `hop_tx0` | input | 11 | HOP0[10:0] |
| `hop_tx1` | input | 11 | HOP1[10:0] |
| `hop_rx0` | input | 11 | HOP0[21:11] |
| `hop_rx1` | input | 11 | HOP1[21:11] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 8 | TX[7:0] |
| `tx_last` | input | 1 | TX[8:8] |
| `tx_path` | input | 1 | TX[9:9] |
| `rx_valid` | output | 1 | RX capture |
| `rx_ready` | input | 1 | RX handshake |
| `rx_data` | output | 8 | RX[7:0] |
| `rx_last` | output | 1 | RX[8:8] |
| `rx_path` | output | 1 | RX[9:9] |
| `sync` | output | 1 | STATUS[0:0] |
| `path_up` | output | 2 | STATUS[2:1] |
| `ev_hec_fix` | output | 1 | IRQ_STATUS.HEC_FIX |
| `ev_hec_bad` | output | 1 | IRQ_STATUS.ERR_HEC |
| `ev_proto` | output | 1 | IRQ_STATUS.ERR_PROTO |
| `ev_hop` | output | 1 | IRQ_STATUS.ERR_HOP |
| `ev_len` | output | 1 | IRQ_STATUS.ERR_LEN |
| `ev_overflow` | output | 1 | IRQ_STATUS.ERR_OVERFLOW |

## APB wrapper

`USB4_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_sym`, `rx_sym`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55340200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Link and path control |
| 0x018 | HOP0 | RW | 0x00000000 | Path 0 HopIDs (change them only while the path is disabled) |
| 0x01C | HOP1 | RW | 0x00000000 | Path 1 HopIDs (change them only while the path is disabled) |
| 0x020 | TX | RW | 0x00000000 | Packet byte to send on a path; one write per byte, LAST on the final byte (a packet is cut after MAXL = 32 bytes). Each path has one packet buffer: bytes are taken while the PATH's buffer is free, and the buffer frees once the packet went out (the partner must have granted credit). The two paths' bytes may be interleaved |
| 0x024 | RX | RO (pop) | 0x00000000 | Received packet byte (head of the core's receive buffers, packets in arrival order); reading it pops it. A credit grant is sent once a packet is read out |
| 0x028 | STATUS | RO | core | Link state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5534 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 8:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 8:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `link_up` | RW | 0x0 | the logical layer is up: Idle packets, then credit grants; clearing it returns delineation to HUNT and restarts credit counts (a packet cut by it is sent again) |
| CTRL | 2:1 | `path_en` | RW | 0x0 | paths enabled (bit p: path p sends, accepts its ingress HopID and grants credit) |
| HOP0 | 10:0 | `hop_tx0` | RW | 0x0 | egress HopID: put in path 0's packets, and matched against credit grants |
| HOP0 | 21:11 | `hop_rx0` | RW | 0x0 | ingress HopID: packets with it go to path 0 |
| HOP1 | 10:0 | `hop_tx1` | RW | 0x0 | egress HopID of path 1 |
| HOP1 | 21:11 | `hop_rx1` | RW | 0x0 | ingress HopID of path 1 |
| TX | 7:0 | `tx_data` | RW | 0x0 | byte |
| TX | 8 | `tx_last` | RW | 0x0 | last byte of the packet |
| TX | 9 | `tx_path` | RW | 0x0 | path |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | byte |
| RX | 8 | `rx_last` | RO (pop) | 0x0 | last byte of the packet |
| RX | 9 | `rx_path` | RO (pop) | 0x0 | the path it came in on |
| STATUS | 0 | `sync` | RO | core | receive delineation in SYNC |
| STATUS | 2:1 | `path_up` | RO | core | bit p: a credit grant arrived for path p |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | HEC_FIX | a header with a single-bit error was corrected |
| 1 | ERR_HEC | a header HEC error in SYNC that could not be corrected: delineation back to HUNT |
| 2 | ERR_PROTO | a HopID 0 packet with an unknown PDF or length, or a credit grant with reserved bits set, for no enabled path or over RXB credits ahead |
| 3 | ERR_HOP | a packet for a HopID of no enabled path: skipped |
| 4 | ERR_LEN | a data packet with length 0 or over MAXL: skipped |
| 5 | ERR_OVERFLOW | a data packet for a path whose RXB buffers are full: dropped |
| 6 | TX_DONE | TX beat accepted by the core |
| 7 | TX_OVF | write to TX while full (dropped) |
| 8 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_last`, `tx_path`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rx_data`, `rx_last`, `rx_path` from the core with `rx_valid` / `rx_ready`: `rx_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. Nothing is dropped: the core holds its data until the register is free.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55340200.
2. Write 0x1FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), HOP0 (0x018), HOP1 (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x020). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 8) to clear it.
7. Read STATUS (0x028) for the core's live `sync`, `path_up`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/USB4_top.sv` | pass | 98/98 | 820/820 | 13/13 | 7/7 | 45/45 |
| wrapper `rtl/USB4_apb.sv` | pass | 40/40 | 784/784 | n/a | 18/18 | 75/75 |
