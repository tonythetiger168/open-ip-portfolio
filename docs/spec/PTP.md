<!-- SPDX-License-Identifier: Apache-2.0 -->
# PTP: design specification

An IEEE 1588-2019 (PTPv2) hardware clock and two-step timestamp unit for one Ethernet port. Not
implemented: one-step timestamping (frames are only observed), general messages, more than one
VLAN tag, IPv6 extension headers, the BMCA and the servo (software). Core `PTP_top`
(`rtl/PTP_top.sv`) with one `PTP_tsu` per direction, testbench `tb/PTP_tb.sv`, checker
`tb/cov/PTP_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Times are {seconds, ns}. Frames are GMII byte streams, one byte per
clock while `*_dv` / `tx_en` is 1.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock (also the GMII byte clock) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_inc_ns` | input | 8 | whole ns added per clock | - | static | - |
| `cfg_inc_frac` | input | 32 | fraction of a ns (2^-32) added per clock | - | `clk` | - |
| `time_set` | input | 1 | load {`set_sec`, `set_ns`} | high | `clk` | - |
| `set_sec` | input | 48 | seconds to load | - | `clk` | - |
| `set_ns` | input | 30 | ns to load (above 999,999,999 loads 999,999,999) | - | `clk` | - |
| `time_step` | input | 1 | add `step_ns` on top of this clock's increment | high | `clk` | - |
| `step_ns` | input | 32 | signed step, \|`step_ns`\| < 10^9 | - | `clk` | - |
| `snap` | input | 1 | copy the time into `snap_sec` / `snap_ns` | high | `clk` | - |
| `t_sec` | output | 48 | clock seconds | - | `clk` | 0 |
| `t_ns` | output | 30 | clock ns, 0..999,999,999 | - | `clk` | 0 |
| `snap_sec` | output | 48 | snapshot seconds | - | `clk` | 0 |
| `snap_ns` | output | 30 | snapshot ns | - | `clk` | 0 |
| `pps_en` | input | 1 | enable `pps` | high | `clk` | - |
| `pps_width_ns` | input | 30 | `pps` high time in ns | - | `clk` | - |
| `pps` | output | 1 | pulse per second: registered `pps_en` and `t_ns` < `pps_width_ns` | high | `clk` | 0 |
| `sec_tick` | output | 1 | one-clock pulse: the increment carried into the seconds | high | `clk` | 0 |
| `target_arm` | input | 1 | arm the target time compare | high | `clk` | - |
| `target_disarm` | input | 1 | cancel it | high | `clk` | - |
| `target_sec` | input | 48 | target seconds | - | `clk` | - |
| `target_ns` | input | 30 | target ns | - | `clk` | - |
| `target_armed` | output | 1 | the compare is armed | high | `clk` | 0 |
| `target_hit` | output | 1 | one-clock pulse: time reached the target | high | `clk` | 0 |
| `ext_evt` | input | 1 | external event pin; three-flop synchronised | high | async | - |
| `evt_valid` | output | 1 | one-clock pulse: a rising edge of `ext_evt` | high | `clk` | 0 |
| `evt_sec` | output | 48 | its time, seconds; holds | - | `clk` | 0 |
| `evt_ns` | output | 30 | its time, ns; holds | - | `clk` | 0 |
| `rx_dv` | input | 1 | receive GMII data valid (observed) | high | `clk` | - |
| `rx_er` | input | 1 | receive byte error | high | `clk` | - |
| `rxd` | input | 8 | receive byte | - | `clk` | - |
| `tx_en` | input | 1 | transmit GMII enable (observed) | high | `clk` | - |
| `tx_er` | input | 1 | transmit byte error | high | `clk` | - |
| `txd` | input | 8 | transmit byte | - | `clk` | - |
| `cfg_rx_lat_ns` | input | 16 | receive latency subtracted from the timestamp | - | static | - |
| `cfg_tx_lat_ns` | input | 16 | transmit latency added to the timestamp | - | static | - |
| `cfg_l2_en` | input | 1 | timestamp layer-2 PTP (EtherType 0x88F7) | high | static | - |
| `cfg_ipv4_en` | input | 1 | timestamp PTP over UDP / IPv4 | high | static | - |
| `cfg_ipv6_en` | input | 1 | timestamp PTP over UDP / IPv6 | high | static | - |
| `rxq_valid` | output | 1 | the receive FIFO is not empty; combinational from flops | high | `clk` | 0 |
| `rxq_pop` | input | 1 | remove the head entry | high | `clk` | - |
| `rxq_type` | output | 4 | head messageType (0 when empty) | - | `clk` | 0 |
| `rxq_domain` | output | 8 | head domainNumber | - | `clk` | 0 |
| `rxq_seq` | output | 16 | head sequenceId | - | `clk` | 0 |
| `rxq_sec` | output | 48 | head timestamp seconds | - | `clk` | 0 |
| `rxq_ns` | output | 30 | head timestamp ns | - | `clk` | 0 |
| `rxq_ovf` | output | 1 | one-clock pulse: an entry was dropped (FIFO full) | high | `clk` | 0 |
| `txq_valid` | output | 1 | the transmit FIFO is not empty | high | `clk` | 0 |
| `txq_pop` | input | 1 | remove the head entry | high | `clk` | - |
| `txq_type` | output | 4 | head messageType | - | `clk` | 0 |
| `txq_domain` | output | 8 | head domainNumber | - | `clk` | 0 |
| `txq_seq` | output | 16 | head sequenceId | - | `clk` | 0 |
| `txq_sec` | output | 48 | head timestamp seconds | - | `clk` | 0 |
| `txq_ns` | output | 30 | head timestamp ns | - | `clk` | 0 |
| `txq_ovf` | output | 1 | one-clock pulse: an entry was dropped | high | `clk` | 0 |

### Internal signals used by the verification

The FSM coverage collector binds these in each `PTP_tsu` instance (`u_rx`, `u_tx`).

| Signal | Width | Meaning |
|---|---|---|
| `st` | 2 | parser: 0 IDLE, 1 PREAMBLE, 2 DATA (after the SFD), 3 SKIP (not a frame start) |
| `kind` | 2 | frame kind: 0 none, 1 layer 2, 2 IPv4, 3 IPv6 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/PTP.md`](../ip/PTP.md) (source: `scripts/apb/specs/PTP.json`); do not edit by hand.

`PTP_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `t_sec`, `t_ns`, `pps`, `target_hit`, `ext_evt`, `rx_dv`, `rx_er`, `rxd`, `tx_en`, `tx_er`, `txd`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x50540100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | INC | RW | 0x00000008 | Clock increment per PCLK (the rate) |
| 0x018 | INC_FRAC | RW | 0x00000000 | Fractional increment, 2^-32 ns per clock (the servo's trim) |
| 0x01C | SET0 | RW | 0x00000000 | Time loaded by CMD.time_set (SET0 / SET1: seconds, SET2: ns) |
| 0x020 | SET1 | RW | 0x00000000 | Time loaded by CMD.time_set (SET0 / SET1: seconds, SET2: ns) |
| 0x024 | SET2 | RW | 0x00000000 | Time loaded by CMD.time_set (SET0 / SET1: seconds, SET2: ns) |
| 0x028 | STEP | RW | 0x00000000 | Signed step added by CMD.time_step |
| 0x02C | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x030 | SNAP0 | RO | core | Time captured by CMD.snap (SNAP0 / SNAP1: seconds, SNAP2: ns) |
| 0x034 | SNAP1 | RO | core | Time captured by CMD.snap (SNAP0 / SNAP1: seconds, SNAP2: ns) |
| 0x038 | SNAP2 | RO | core | Time captured by CMD.snap (SNAP0 / SNAP1: seconds, SNAP2: ns) |
| 0x03C | PPS | RW | 0x00000000 | Pulse per second |
| 0x040 | TARGET0 | RW | 0x00000000 | Target time (TARGET0 / TARGET1: seconds, TARGET2: ns) |
| 0x044 | TARGET1 | RW | 0x00000000 | Target time (TARGET0 / TARGET1: seconds, TARGET2: ns) |
| 0x048 | TARGET2 | RW | 0x00000000 | Target time (TARGET0 / TARGET1: seconds, TARGET2: ns) |
| 0x04C | EVT0 | RO | core | Time of the last ext_evt rising edge (EVT0 / EVT1: seconds, EVT2: ns) |
| 0x050 | EVT1 | RO | core | Time of the last ext_evt rising edge (EVT0 / EVT1: seconds, EVT2: ns) |
| 0x054 | EVT2 | RO | core | Time of the last ext_evt rising edge (EVT0 / EVT1: seconds, EVT2: ns) |
| 0x058 | TSU_CFG | RW | 0x00000007 | Timestamp units: transports |
| 0x05C | LAT | RW | 0x00000000 | PHY latencies to the timestamp point on the line |
| 0x060 | STATUS | RO | core | Status |
| 0x064 | RXTS0 | RO (pop) | 0x00000000 | Receive timestamp; reading RXTS3 frees it |
| 0x068 | RXTS1 | RO (pop) | 0x00000000 | Receive timestamp; reading RXTS3 frees it |
| 0x06C | RXTS2 | RO (pop) | 0x00000000 | Receive timestamp; reading RXTS3 frees it |
| 0x070 | RXTS3 | RO (pop) | 0x00000000 | Receive timestamp; reading RXTS3 frees it |
| 0x074 | TXTS0 | RO (pop) | 0x00000000 | Transmit timestamp; reading TXTS3 frees it |
| 0x078 | TXTS1 | RO (pop) | 0x00000000 | Transmit timestamp; reading TXTS3 frees it |
| 0x07C | TXTS2 | RO (pop) | 0x00000000 | Transmit timestamp; reading TXTS3 frees it |
| 0x080 | TXTS3 | RO (pop) | 0x00000000 | Transmit timestamp; reading TXTS3 frees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x084 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5054 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 6:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 6:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| INC | 7:0 | `cfg_inc_ns` | RW | 0x8 | whole ns added every clock (8 at 125 MHz) |
| INC_FRAC | 31:0 | `cfg_inc_frac` | RW | 0x0 | fraction of a ns added every clock |
| SET0 | 31:0 | `set_sec[31:0]` | RW | 0x0 | seconds |
| SET1 | 15:0 | `set_sec[47:32]` | RW | 0x0 | seconds |
| SET2 | 29:0 | `set_ns` | RW | 0x0 | nanoseconds (above 999,999,999 loads 999,999,999) |
| STEP | 31:0 | `step_ns` | RW | 0x0 | ns, two's complement, |step| < 10^9 |
| CMD | 0 | `time_set` | WO (pulse) | 0x0 | 1 = load SET (the fraction is cleared) |
| CMD | 1 | `time_step` | WO (pulse) | 0x0 | 1 = add STEP on top of this clock's increment |
| CMD | 2 | `snap` | WO (pulse) | 0x0 | 1 = copy the time into SNAP |
| CMD | 3 | `target_arm` | WO (pulse) | 0x0 | 1 = arm the TARGET compare |
| CMD | 4 | `target_disarm` | WO (pulse) | 0x0 | 1 = cancel the TARGET compare (arm wins when both are set) |
| SNAP0 | 31:0 | `snap_sec[31:0]` | RO | core | seconds |
| SNAP1 | 15:0 | `snap_sec[47:32]` | RO | core | seconds |
| SNAP2 | 29:0 | `snap_ns` | RO | core | nanoseconds |
| PPS | 0 | `pps_en` | RW | 0x0 | 1 = pps is high while ns < width |
| PPS | 30:1 | `pps_width_ns` | RW | 0x0 | pulse width in ns |
| TARGET0 | 31:0 | `target_sec[31:0]` | RW | 0x0 | seconds |
| TARGET1 | 15:0 | `target_sec[47:32]` | RW | 0x0 | seconds |
| TARGET2 | 29:0 | `target_ns` | RW | 0x0 | nanoseconds |
| EVT0 | 31:0 | `evt_sec[31:0]` | RO | core | seconds |
| EVT1 | 15:0 | `evt_sec[47:32]` | RO | core | seconds |
| EVT2 | 29:0 | `evt_ns` | RO | core | nanoseconds |
| TSU_CFG | 0 | `cfg_l2_en` | RW | 0x1 | timestamp layer-2 PTP (EtherType 0x88F7) |
| TSU_CFG | 1 | `cfg_ipv4_en` | RW | 0x1 | timestamp PTP over UDP / IPv4 |
| TSU_CFG | 2 | `cfg_ipv6_en` | RW | 0x1 | timestamp PTP over UDP / IPv6 |
| LAT | 15:0 | `cfg_rx_lat_ns` | RW | 0x0 | ns subtracted from receive timestamps |
| LAT | 31:16 | `cfg_tx_lat_ns` | RW | 0x0 | ns added to transmit timestamps |
| STATUS | 0 | `target_armed` | RO | core | the TARGET compare is armed |
| RXTS0 | 3:0 | `rxq_type` | RO (pop) | 0x0 | messageType (0 Sync, 1 Delay_Req, 2 Pdelay_Req, 3 Pdelay_Resp) |
| RXTS0 | 11:4 | `rxq_domain` | RO (pop) | 0x0 | domainNumber |
| RXTS0 | 27:12 | `rxq_seq` | RO (pop) | 0x0 | sequenceId |
| RXTS1 | 31:0 | `rxq_sec[31:0]` | RO (pop) | 0x0 | seconds |
| RXTS2 | 15:0 | `rxq_sec[47:32]` | RO (pop) | 0x0 | seconds |
| RXTS3 | 29:0 | `rxq_ns` | RO (pop) | 0x0 | nanoseconds |
| TXTS0 | 3:0 | `txq_type` | RO (pop) | 0x0 | messageType |
| TXTS0 | 11:4 | `txq_domain` | RO (pop) | 0x0 | domainNumber |
| TXTS0 | 27:12 | `txq_seq` | RO (pop) | 0x0 | sequenceId |
| TXTS1 | 31:0 | `txq_sec[31:0]` | RO (pop) | 0x0 | seconds |
| TXTS2 | 15:0 | `txq_sec[47:32]` | RO (pop) | 0x0 | seconds |
| TXTS3 | 29:0 | `txq_ns` | RO (pop) | 0x0 | nanoseconds |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | SEC_TICK | the clock entered a new second |
| 1 | TARGET | the TARGET time was reached (the compare disarms) |
| 2 | EVENT | ext_evt rose; EVT holds its time |
| 3 | RX_OVF | a receive timestamp was dropped (the core FIFO was full) |
| 4 | TX_OVF | a transmit timestamp was dropped (the core FIFO was full) |
| 5 | RXTS_AVAIL | RXTS captured a beat |
| 6 | TXTS_AVAIL | TXTS captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | RXTS_AVAIL | RXTS holds an unread beat |
| 1 | TXTS_AVAIL | TXTS holds an unread beat |

### Streams

* **RXTS** takes `rxq_type`, `rxq_domain`, `rxq_seq`, `rxq_sec`, `rxq_ns` from the core with `rxq_valid` / `rxq_pop`: `rxq_pop` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RXTS_AVAIL. Reading RXTS3 pops it. Nothing is dropped: the core holds its data until the register is free.
* **TXTS** takes `txq_type`, `txq_domain`, `txq_seq`, `txq_sec`, `txq_ns` from the core with `txq_valid` / `txq_pop`: `txq_pop` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ TXTS_AVAIL. Reading TXTS3 pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x50540100.
2. Write 0x7F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write INC (0x014), INC_FRAC (0x018), SET0 (0x01C), SET1 (0x020), SET2 (0x024), STEP (0x028), PPS (0x03C), TARGET0 (0x040), TARGET1 (0x044), TARGET2 (0x048), TSU_CFG (0x058), LAT (0x05C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7F enables all).
5. To issue a command, write 1 to `time_set` (CMD bit 0), `time_step` (CMD bit 1), `snap` (CMD bit 2), `target_arm` (CMD bit 3), `target_disarm` (CMD bit 4) at 0x02C; the core sees a one-clock pulse, and the register reads 0.
6. Read SNAP0 (0x030), SNAP1 (0x034), SNAP2 (0x038) for the core's live `snap_sec[31:0]`, `snap_sec[47:32]`, `snap_ns`; it needs no clearing.
7. Read EVT0 (0x04C), EVT1 (0x050), EVT2 (0x054) for the core's live `evt_sec[31:0]`, `evt_sec[47:32]`, `evt_ns`; it needs no clearing.
8. Read STATUS (0x060) for the core's live `target_armed`; it needs no clearing.
9. To receive on RXTS: wait for IRQ RXTS_AVAIL or FLAGS.RXTS_AVAIL (bit 0), then read RXTS0 (0x064) then RXTS1 (0x068) then RXTS2 (0x06C) then RXTS3 (0x070). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RXTS_AVAIL (bit 5) to clear it.
10. To receive on TXTS: wait for IRQ TXTS_AVAIL or FLAGS.TXTS_AVAIL (bit 1), then read TXTS0 (0x074) then TXTS1 (0x078) then TXTS2 (0x07C) then TXTS3 (0x080). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.TXTS_AVAIL (bit 6) to clear it.
11. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Set INC (and INC_FRAC), then SET0..SET2 and CMD.time_set; LAT, TSU_CFG and IRQ_ENABLE.
2. On IRQ RXTS_AVAIL / TXTS_AVAIL read RXTS0..RXTS3 / TXTS0..TXTS3; match them to the messages by type, domain and sequenceId.
3. Servo: CMD.snap and read SNAP, or compare timestamps with the master; trim INC_FRAC and correct offsets with STEP + CMD.time_step.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Hardware clock

Each clock the time advances by `cfg_inc_ns` ns plus `cfg_inc_frac` x 2^-32 ns (a 32-bit
fraction accumulator carries into ns); ns wraps at 10^9 into the seconds and `sec_tick` pulses
one clock later. `time_set` loads the time (ns clamped to 999,999,999, fraction 0) instead of
advancing. `time_step` adds `step_ns` to the advanced time, borrowing or carrying one second
(`sec_tick` does not pulse in that clock). `time_set` has priority. `snap` copies the current
`t_sec` / `t_ns` in one clock.

### 3.2 PPS and target time

`pps` is the registered value of `pps_en` && `t_ns` < `pps_width_ns`. `target_arm` arms (priority
over `target_disarm`, which disarms). While armed, in the first clock where the time >= the
target, `target_armed` clears and `target_hit` pulses one clock later; a target in the past hits
right after arming.

### 3.3 External event

`ext_evt` passes three flops. `evt_valid` is 1 after the third rising edge of `clk` that sees the
pin high (2 to 3 clock periods after the pin edge), and `evt_sec` / `evt_ns` hold `t_sec` / `t_ns`
as they were just before that edge. A later event overwrites them.

### 3.4 Frame parsing (each direction)

* Optional 0x55 preamble bytes, then the SFD 0xD5: the time in the SFD clock is the frame's
  time. A frame starting with another byte is skipped to the end of `dv`.
* Bytes are then counted from the destination address (index 0). A TPID 0x8100 at index 12..13
  moves the EtherType to 16..17.
* EtherType 0x88F7: layer 2, PTP header right after it.
* 0x0800: IPv4 if version 4, IHL >= 5, MF = 0, fragment offset 0, protocol 17; the UDP header
  follows the IHL x 4 header. 0x86DD: IPv6 if version 6 and next header 17; UDP after 40 bytes.
  UDP destination port 319: the PTP header follows the 8-byte UDP header.
* From the PTP header: byte 0 [3:0] messageType, byte 1 [3:0] versionPTP, byte 4 domainNumber,
  bytes 30..31 sequenceId.

When `dv` falls, an entry is pushed if: a PTP header was located, its kind is enabled, no byte
had `er`, the FCS is good, the frame is at least 64 bytes and at least header start + 38 bytes
(34-byte header + FCS), messageType <= 3 and versionPTP = 2.

### 3.5 Timestamp FIFOs

Entry = {type, domain, sequence, timestamp}; timestamp = frame time - `cfg_rx_lat_ns` (receive)
or + `cfg_tx_lat_ns` (transmit), wrapping across the second. The head is shown on the `*q_*`
outputs while `*q_valid` (all 0 when empty); `*q_pop` removes it (ignored when empty). A push to a
full FIFO is dropped with a `*q_ovf` pulse one clock later, unless the head is popped in the same
clock.

### 3.6 Reset

While `rst_n` is low: time 0, FIFOs empty, parser idle, all outputs 0.

## 4. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `FIFO_DEPTH` | 4 | entries per FIFO (power of 2, at least 2) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| general message (type 8..15), version not 2, port 320, other EtherType, non-UDP, IP fragment, IPv6 with extension header | no entry |
| `er` byte, bad FCS, frame under 64 bytes or cut in the PTP header | no entry |
| kind disabled by `cfg_*_en` | no entry |
| FIFO full | entry dropped, `*q_ovf` |
| negative step across a second | seconds - 1 |
| two VLAN tags | not parsed (no entry) |
| preamble cut short | the SFD alone starts the frame |

## 6. TB check map

Messages are printed by `tb/PTP_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/PTP_sva.sv`. The TB keeps its own clock model compared every clock, drives events
between clock edges, and builds frames byte by byte (layer 2, IPv4 with every IHL, IPv6, with and
without VLAN) with every reason not to timestamp, plus FIFO overflow.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "time" | time as the model every clock | §3.1 |
| "sec_tick" | carry pulse | §3.1 |
| "pps" | `pps` | §3.2 |
| "snap" | snapshot | §3.1 |
| "target not armed" | arming | §3.2 |
| "event time" | event time | §3.3 |
| "event latency" | event pulse timing | §3.3 |
| "stream" | entries as the parser model | §3.4, §3.5 |
| "reset values" | reset values | §3.6 |
| "pps / sec_tick not seen" | pulses happen | §3.1, §3.2 |
| "target hit in the same second" | compare | §3.2 |
| "target hit in the next second" | compare | §3.2 |
| "past target" | a past target hits at once | §3.2 |
| "disarm" | disarm | §3.2 |
| "disarmed target hit" | no hit after disarm | §3.2 |
| "arm with disarm" | arm wins | §3.2 |
| "target at equal seconds" | compare on ns | §3.2 |
| "timestamps" | timestamps with latency | §3.5 |
| "pop on an empty FIFO" | ignored | §3.5 |
| "overflow count" | `*q_ovf` | §3.5 |
| "after reset" | reset clears the FIFOs | §3.6 |
| "corner" | corner frames | §3.4 |
| "jumbo frames" | long frames | §3.4 |
| "cut preamble" | short preamble | §3.4 |
| a_fifo_valid_model | `*q_valid` as the model | §3.5 |
| a_fifo_head_model | head entry as the model | §3.5 |
| a_fifo_empty_zero | outputs 0 when empty | §3.5 |
| a_ovf_model | overflow pulses | §3.5 |
| a_fifo_bound | never more than `FIFO_DEPTH` entries | §3.5 |
| a_ts_ns_range | timestamp ns below 10^9 | §3.5 |
| a_reset_values | reset values | §3.6 |
| a_clock_model | time as the model | §3.1 |
| a_ns_range | `t_ns` below 10^9 | §3.1 |
| a_snap_model | snapshot | §3.1 |
| a_pps_model | `pps` | §3.2 |
| a_target_model | target compare | §3.2 |
| a_event_model | event capture | §3.3 |
| a_tick_once_per_second | one `sec_tick` per second | §3.1 |
