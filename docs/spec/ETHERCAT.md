<!-- SPDX-License-Identifier: Apache-2.0 -->
# ETHERCAT: design specification

An EtherCAT slave controller (ESC) frame processing unit: datagrams are executed on the fly as the
frame passes from receive to transmit. Not implemented: distributed clocks, SyncManagers, the AL
state machine, EEPROM / SII, mailbox, bit-granular FMMUs, VLAN tags, port forwarding (one
processing direction). Core `ETHERCAT_top` (`rtl/ETHERCAT_top.sv`), testbench `tb/ETHERCAT_tb.sv`
(a frame-level golden model), checker `tb/cov/ETHERCAT_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A frame is the octets while `rx_dv` = 1; the last 4 are its FCS.
All EtherCAT fields are little endian.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one octet per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rx_dv` | input | 1 | frame octet valid (destination MAC to FCS, no preamble) | high | `clk` | - |
| `rx_d` | input | 8 | frame octet | - | `clk` | - |
| `tx_dv` | output | 1 | = `rx_dv` 5 clocks earlier | high | `clk` | 0 |
| `tx_d` | output | 8 | processed octet (5-clock delay) | - | `clk` | 0 |
| `host_rd` | input | 1 | host read | high | `clk` | - |
| `host_wr` | input | 1 | host write (dropped if the frame writes the same octet this clock) | high | `clk` | - |
| `host_addr` | input | 16 | host physical address | - | `clk` | - |
| `host_wdata` | input | 8 | host write data | - | `clk` | - |
| `host_rdata` | output | 8 | host read data, the clock after `host_rd`; holds | - | `clk` | 0 |
| `fr_done` | output | 1 | one-clock pulse: a frame ended | high | `clk` | 0 |
| `fr_fcs_ok` | output | 1 | its received FCS was good (5 or more octets); holds | high | `clk` | 0 |
| `fr_ecat` | output | 1 | it was an EtherCAT datagram frame; holds | high | `clk` | 0 |
| `fr_dgrams` | output | 8 | datagrams processed; holds | - | `clk` | 0 |
| `fr_wkc` | output | 8 | sum of this station's working counter increments, saturating at 255; holds | - | `clk` | 0 |

### Internal signals used by the verification

The TB reads the frame-side memory write port to predict host collisions; the FSM coverage
collector binds `ps`.

| Signal | Width | Meaning |
|---|---|---|
| `m_we` | 1 | the passing octet writes memory this clock; combinational |
| `m_wa` | 16 | its physical address; combinational |
| `ps` | 3 | parser: 0 Ethernet header, 1 EtherCAT header, 2 datagram header, 3 datagram data, 4 working counter, 5 pass (no more processing) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/ETHERCAT.md`](../ip/ETHERCAT.md) (source: `scripts/apb/specs/ETHERCAT.json`); do not edit by hand.

`ETHERCAT_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_dv`, `rx_d`, `tx_dv`, `tx_d`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0xEC470100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | MEM_ADDR | RW | 0x00000000 | ESC address for CMD.host_rd / host_wr |
| 0x018 | MEM_WDATA | RW | 0x00000000 | ESC write data |
| 0x01C | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x020 | MEM_RDATA | RO | core | ESC read data |
| 0x024 | FRAME | RO (pop) | 0x00000000 | Frame report, one per forwarded frame; reading it frees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0xEC47 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| MEM_ADDR | 15:0 | `host_addr` | RW | 0x0 | 0x0010..0x0011 station address, 0x0600..0x061F FMMU 0 / 1, 0x1000..0x13FF process RAM |
| MEM_WDATA | 7:0 | `host_wdata` | RW | 0x0 | octet written by CMD.host_wr |
| CMD | 0 | `host_wr` | WO (pulse) | 0x0 | 1 = write MEM_WDATA at MEM_ADDR (dropped if a frame writes the same octet in that clock) |
| CMD | 1 | `host_rd` | WO (pulse) | 0x0 | 1 = read MEM_ADDR into MEM_RDATA |
| MEM_RDATA | 7:0 | `host_rdata` | RO | core | octet read by CMD.host_rd |
| FRAME | 0 | `fr_fcs_ok` | RO (pop) | 0x0 | received FCS correct |
| FRAME | 1 | `fr_ecat` | RO (pop) | 0x0 | EtherCAT datagram frame |
| FRAME | 9:2 | `fr_dgrams` | RO (pop) | 0x0 | datagrams processed (modulo 256) |
| FRAME | 17:10 | `fr_wkc` | RO (pop) | 0x0 | this station's working counter increments, saturating at 255 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FRAME_AVAIL | FRAME captured a beat |
| 1 | FRAME_OVF | beat dropped, FRAME was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | FRAME_AVAIL | FRAME holds an unread beat |

### Streams

* **FRAME** captures `fr_fcs_ok`, `fr_ecat`, `fr_dgrams`, `fr_wkc` when `fr_done` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ FRAME_AVAIL. Reading FRAME pops it. A beat that arrives while the register is full is dropped and sets FRAME_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0xEC470100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write MEM_ADDR (0x014), MEM_WDATA (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `host_wr` (CMD bit 0), `host_rd` (CMD bit 1) at 0x01C; the core sees a one-clock pulse, and the register reads 0.
6. Read MEM_RDATA (0x020) for the core's live `host_rdata`; it needs no clearing.
7. To receive on FRAME: wait for IRQ FRAME_AVAIL or FLAGS.FRAME_AVAIL (bit 0), then read FRAME (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.FRAME_AVAIL (bit 0) to clear it. Read each beat before the next arrives, or it is dropped and FRAME_OVF is set.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write the station address (0x0010..0x0011) and FMMUs (0x0600..) through MEM_ADDR / MEM_WDATA / CMD.host_wr, preload the process RAM the same way.
2. On IRQ FRAME_AVAIL read FRAME for each frame; read process data with CMD.host_rd and MEM_RDATA.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Frame path

`tx_dv` / `tx_d` are `rx_dv` / the processed octet 5 clocks later. The FCS is recomputed over the
processed octets (CRC-32) and replaces the last 4 octets; if the received FCS was wrong, the new
FCS is inverted so the next station sees the error too. A frame of fewer than 5 octets passes
unchanged. `fr_done` pulses in the clock after `rx_dv` falls, with the `fr_*` results.

### 3.2 Parsing

* Octets 12..13 = 0x88A4, then a 2-octet EtherCAT header with type (bits 15:12) = 1: datagrams.
  Anything else passes unchanged.
* Datagram: cmd, idx, address (ADP 2 octets + ADO 2 octets, or a 32-bit logical address), length
  (len[10:0], bit 15 = more datagrams follow), IRQ (2), len data octets, WKC (2).

| cmd | Command | Addressed when | ADP + 1 |
|---|---|---|---|
| 1..3 | APRD / APWR / APRW | ADP = 0 | yes |
| 4..6 | FPRD / FPWR / FPRW | ADP = station address | no |
| 7..9 | BRD / BWR / BRW | always (BRD / BRW read data OR memory) | yes |
| 10..12 | LRD / LWR / LRW | per octet through the FMMUs | no |
| 13 | ARMW | ADP = 0 reads, others write | yes |
| 14 | FRMW | ADP = station address reads, others write | no |
| others | NOP | - | no |

ADP + 1 and WKC + n are written into the passing octets with carry into the high octet.

### 3.3 Memory access

As each data octet passes it reads (replacing the octet) or writes memory at ADO + i (physical),
or at the FMMU-mapped address (logical). Writes take effect as the octets pass; they are not
undone by a bad FCS.

Physical memory: 0x0010..0x0011 station address; 0x0600..0x061F FMMU 0 / 1 (16 octets each:
logical start 0..3, length 4..5, physical start 8..9, type 0x0B bit 0 read / bit 1 write, activate
0x0C bit 0; other octets stored only); 0x1000..0x13FF process RAM; other addresses read 0 and
ignore writes. A logical octet maps through the first active FMMU whose range holds it.

### 3.4 Working counter

Read + 1, write + 1, read / write + 3 (ARMW / FRMW + 1). A physical datagram counts when addressed;
a logical one counts read and write once each when at least one of its octets maps with that
permission (LRW: read + 1, write + 2).

### 3.5 Host port

`host_rd` gives `host_rdata` the next clock. A host write to the octet a frame writes in the same
clock is dropped.

### 3.6 Reset

While `rst_n` is low: no frame, outputs 0, station address and FMMUs 0 (the RAM keeps its
contents).

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| bad received FCS | processed anyway; the sent FCS is wrong |
| frame under 5 octets | unchanged, `fr_fcs_ok` = 0 |
| non-EtherCAT frame | unchanged |
| unknown command | as NOP |
| unmapped address | reads 0, writes ignored |
| overlapping FMMUs | FMMU 0 wins |
| working counter sum over 255 | `fr_wkc` = 255 |

## 6. TB check map

Messages are printed by `tb/ETHERCAT_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the
bound checker `tb/cov/ETHERCAT_sva.sv`, which predicts every output octet. The TB builds frames
from datagram lists and checks them against a golden model with its own memory image.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "host read" | host reads | §3.5 |
| "host read in a frame write" | host write dropped on a collision | §3.5 |
| "outputs in reset" | reset | §3.6 |
| "frame result for the frame cut by reset" | reset drops the frame | §3.6 |
| a_tx_dv | `tx_dv` delay | §3.1 |
| a_tx_d | each output octet as the model | §3.1..§3.4 |
| a_done | `fr_done` | §3.1 |
| a_done_fcs | `fr_fcs_ok` | §3.1 |
| a_done_ecat | `fr_ecat` | §3.2 |
| a_done_dgrams | `fr_dgrams` | §3.2 |
| a_done_wkc | `fr_wkc` | §3.4 |
| a_host_rdata | host read data | §3.5 |
| a_rst_outputs | reset | §3.6 |
