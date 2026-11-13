<!-- SPDX-License-Identifier: Apache-2.0 -->
# CSI_2: design specification

A MIPI CSI-2 receiver at the packet layer, on a one-bit-per-clock model of a single HS lane:
SoT sync hunt, packet header with ECC (single-error correction, double-error detection),
short packets (Frame Start / End and others), long packets with CRC-16, and a ping-pong line
buffer that always shows the last good line. Not implemented: D-PHY / C-PHY, multiple lanes and
lane merging, virtual channel extension, pixel unpacking, line start / end handling beyond
reporting. Core `CSI_2_top` (`rtl/CSI_2_top.sv`), testbench `tb/CSI_2_tb.sv` (a camera
transmitter with its own ECC and CRC and a scoreboard), checker `tb/cov/CSI_2_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; status outputs change at the
edge that takes the last bit of the deciding byte.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock (one lane bit per clock) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rx_bit` | input | 1 | HS lane bit, LSB of each byte first | - | `clk` | - |
| `rx_valid` | input | 1 | high for one HS burst (SoT .. EoT); `rx_bit` valid | high | `clk` | - |
| `irq` | output | 1 | protocol error (CRC or uncorrectable ECC), held until the next good packet | high | `clk` | 0 |
| `frame_active` | output | 1 | between Frame Start and Frame End | high | `clk` | 0 |
| `frame_cnt` | output | 16 | Frame Start packets received | - | `clk` | 0 |
| `line_cnt` | output | 16 | good long packets since Frame Start | - | `clk` | 0 |
| `last_dt` | output | 8 | DI byte {VC[1:0], DT[5:0]} of the last accepted header | - | `clk` | 0 |
| `last_wc` | output | 16 | WC (long) or data field (short) of the last accepted header | - | `clk` | 0 |
| `err_flags` | output | 4 | [0] CRC, [1] ECC uncorrectable, [2] burst ended inside a packet, [3] ECC corrected; sticky, cleared at Frame Start | - | `clk` | 0 |
| `lb_len` | output | 16 | bytes in the readable line (min(WC, `LINE_BYTES`)) | - | `clk` | 0 |
| `lb_addr` | input | `log2(LINE_BYTES)` | line buffer read address | - | `clk` | - |
| `lb_rdata` | output | 8 | byte `lb_addr` of the last good line; combinational | - | comb | - |

### Internal signals used by the verification

The FSM coverage collector (`tb/cov/CSI_2_fsm_cov.sv`) binds this by name; a re-implementation
must have it.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 4 | 0 HUNT, 1..3 header bytes, 4 ECC, 5 payload, 6 / 7 CRC bytes, 8 next sync, 9 EoT trailer |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/CSI_2.md`](../ip/CSI_2.md) (source: `scripts/apb/specs/CSI_2.json`); do not edit by hand.

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
| 0x014 | STATUS | RO | core | Receiver state |
| 0x018 | COUNTS | RO | core | Counters |
| 0x01C | LAST | RO | core | Last accepted header |
| 0x020 | LB_ADDR | RW | 0x00000000 | Line buffer read address |
| 0x024 | LB_DATA | RO | core | Line buffer data |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4332 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `frame_active` | RO | core | between a Frame Start and a Frame End |
| STATUS | 4:1 | `err_flags` | RO | core | [0] CRC error, [1] uncorrectable header, [2] burst ended inside a packet, [3] header corrected; they accumulate and clear at Frame Start |
| STATUS | 20:5 | `lb_len` | RO | core | bytes in the readable line (the last long packet with a good CRC, at most 512) |
| COUNTS | 15:0 | `frame_cnt` | RO | core | Frame Starts received (wraps) |
| COUNTS | 31:16 | `line_cnt` | RO | core | good long packets since the last Frame Start |
| LAST | 7:0 | `last_dt` | RO | core | {VC[1:0], DT[5:0]} |
| LAST | 23:8 | `last_wc` | RO | core | word count (long packet) or data field (short packet) |
| LB_ADDR | 8:0 | `lb_addr` | RW | 0x0 | byte of the readable line shown in LB_DATA |
| LB_DATA | 7:0 | `lb_rdata` | RO | core | byte LB_ADDR of the last good line |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERROR | a CRC error or an uncorrectable header; the core holds it until the next good packet, so the bit is set again on every clock until then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43320200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write LB_ADDR (0x020). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. Read STATUS (0x014) for the core's live `frame_active`, `err_flags`, `lb_len`; it needs no clearing.
6. Read COUNTS (0x018) for the core's live `frame_cnt`, `line_cnt`; it needs no clearing.
7. Read LAST (0x01C) for the core's live `last_dt`, `last_wc`; it needs no clearing.
8. Read LB_DATA (0x024) for the core's live `lb_rdata`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Bursts and sync

`rx_valid` high is one HS burst. In HUNT the receiver compares, at every bit, the last 8 bits
received (newest as the MSB) with the sync byte 0xB8; a match starts the packet header with the
next bit as bit 0 of byte 0. Any number of leading bits may precede the sync. After a packet the
next byte on the same alignment is checked: 0xB8 starts another packet in the same burst, anything
else is the EoT trailer, ignored to the end of the burst. `rx_valid` low returns to HUNT; if a
packet was in progress (header, payload or CRC) `err_flags[2]` is set (no `irq`).

### 3.2 Packet header and ECC

Header bytes: DI {VC[1:0], DT[5:0]}, WC[7:0], WC[15:8], ECC. With d = {WC[15:8], WC[7:0], DI},
the six parity bits are the CSI-2 Hamming equations (P0..P5; ECC bits 7:6 are ignored). The
syndrome s = received ECC[5:0] XOR computed:

| Syndrome | Result |
|---|---|
| 0 | clean |
| equal to the parity of a single data bit | that bit corrected, `err_flags[3]` |
| one-hot (error in the ECC byte) | data used as is, `err_flags[3]` |
| anything else | uncorrectable: packet dropped, `irq` = 1, `err_flags[1]`; next byte checked for sync |

An accepted header updates `last_dt` and `last_wc` with the corrected values.

### 3.3 Short packets (DT 0x00..0x0F)

* Frame Start (0x00): `frame_active` = 1, `frame_cnt` + 1, `line_cnt` = 0, `err_flags` = 0 (bit 3
  set if this header was corrected).
* Frame End (0x01): `frame_active` = 0.
* Every short packet clears `irq`; other DTs only update `last_dt` / `last_wc`.

### 3.4 Long packets (DT 0x10..0x3F)

WC payload bytes follow, then the CRC-16 (polynomial 0x1021 reflected, init 0xFFFF, no final XOR,
over the payload), low byte first. Payload byte i (i < `LINE_BYTES`) is written to the hidden half
of the line buffer; bytes beyond are checked but not stored. WC = 0 goes straight to the CRC
bytes (CRC of nothing = 0xFFFF). At the second CRC byte:

* good: `irq` = 0, `line_cnt` + 1, the buffer halves swap (the read port now shows this line),
  `lb_len` = min(WC, `LINE_BYTES`);
* bad: `irq` = 1, `err_flags[0]`; the read port keeps the previous line.

### 3.5 Reset

While `rst_n` is low: HUNT, all outputs 0 (the line buffer contents are not cleared).

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `LINE_BYTES` | 512 | power of 2, 2 or more | bytes stored per line (each half of the buffer) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| single-bit header error | corrected, `err_flags[3]` |
| ECC byte error | data kept, `err_flags[3]` |
| double error | packet dropped, `irq`, `err_flags[1]` |
| bad CRC | `irq`, `err_flags[0]`, previous line kept |
| burst ends inside a packet | `err_flags[2]`, back to HUNT |
| long packet longer than `LINE_BYTES` | checked; first `LINE_BYTES` bytes stored |
| bits from the end of a previous burst | the 7-bit history is not cleared between bursts, so the sync hunt may match across the burst boundary |
| reset mid-packet | HUNT, status cleared |

## 6. TB check map

The TB `tb/CSI_2_tb.sv` compares every status output and the readable line with its scoreboard
after each step and prints `ERROR: <step> ...`, where the step names vary (FS, RAW8 lines, header
bit k corrected, abort after n bits, ...); there are no fixed message prefixes. Assertions `a_*`
are in the bound checker `tb/cov/CSI_2_sva.sv`. Covered: FS / FE / generic shorts, long packets of
WC 0..520, every single-bit header and ECC-byte error, double errors, CRC errors, bursts ending in
every stage, several packets per burst, trailers, sync at any bit offset, reset mid-packet.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| a_reset_clear | in reset: status outputs 0 | §3.5 |
| a_irq | `irq` exactly as the checker's model | §3.2, §3.4 |
| a_frame | `frame_active` / `frame_cnt` as the model | §3.3 |
| a_line_cnt | `line_cnt` as the model | §3.3, §3.4 |
| a_last_hdr | `last_dt` / `last_wc` as the model | §3.2 |
| a_err_flags | `err_flags` as the model | §3.1..§3.4 |
| a_lb_len | `lb_len` as the model | §3.4 |
| a_line_data | each byte below `lb_len` as the last good line | §3.4 |
