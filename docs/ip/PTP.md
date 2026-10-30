# IEEE 1588-2019 (PTPv2) hardware clock and timestamp unit for one Ethernet port: PTP clock with rate trim, set / step, pps, target time, external event capture, and RX / TX event-message timestamps (layer 2, UDP over IPv4 and IPv6)

Protocol IP `PTP`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `PTP_top` (`rtl/PTP_top.sv`) |
| Register interface | APB4 slave `PTP_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x50540100 (code 0x5054, version 1.0) |
| Registers | 33 words, 0x000 to 0x080 |
| Interrupts | 7 sources into one level-high `irq` |
| Data streams | RXTS (from the core), TXTS (from the core) |
| Protocol pins | 11 pass-through |

## Overview

PTP_top v1.0: IEEE 1588-2019 (PTPv2) hardware clock and timestamp unit for one Ethernet port

- PTP hardware clock: {t_sec (48 bits), t_ns (0..999,999,999), a 32-bit
fraction of a ns} advances by {cfg_inc_ns, cfg_inc_frac} every clk
(the rate: 8 ns per clk at 125 MHz is inc_ns = 8, inc_frac = 0; a
servo trims inc_frac). time_set loads {set_sec, set_ns} with a zero
fraction (set_ns above 999,999,999 loads 999,999,999); time_step adds
the signed step_ns (|step_ns| < 10^9) on top of that clock's
increment. snap copies the time into snap_sec / snap_ns (a consistent
read of both halves).
- pps is high while pps_en and t_ns < pps_width_ns (one pulse at the
start of every second). sec_tick pulses when the increment carries
into the seconds.
- Target time: target_arm arms a compare; target_hit pulses in the
first clock with time >= {target_sec, target_ns} and disarms (an
armed time in the past hits in the next clock). target_disarm cancels.
- External event: ext_evt (asynchronous) goes through two flops; on a
rising edge evt_valid pulses and evt_sec / evt_ns hold the time of the
clock the synchronised edge is seen (2 to 3 clocks after the pin
edge; a later event overwrites them).
- Timestamp units for the receive and the transmit GMII byte streams
(one byte per clk with rx_dv / tx_en, er marks an errored byte; the
streams are only observed). A frame starts with optional preamble
bytes 0x55 and the SFD 0xD5; the time of the SFD clock is the frame's
timestamp, minus cfg_rx_lat_ns (receive) or plus cfg_tx_lat_ns
(transmit), the PHY latencies to the timestamp point on the line.
The frame is parsed for a PTP event message (messageType 0..3: Sync,
Delay_Req, Pdelay_Req, Pdelay_Resp; versionPTP 2):
* Ethernet II with an optional 802.1Q tag (TPID 0x8100);
* EtherType 0x88F7 (layer 2, cfg_l2_en);
* IPv4 (0x0800, cfg_ipv4_en): version 4, IHL >= 5, not a fragment,
protocol 17 (UDP), destination port 319;
* IPv6 (0x86DD, cfg_ipv6_en): next header 17 (no extension
headers), destination port 319.
A frame without er bytes, with a good FCS, at least 64 bytes long
and long enough for the whole 34-byte PTP header pushes {messageType,
domainNumber, sequenceId, timestamp} into that direction's FIFO
(FIFO_DEPTH entries); a full FIFO drops it (rxq_ovf / txq_ovf)
unless the head is popped in the same clock.
The head entry is shown while *q_valid; *q_pop removes it.
Not implemented: one-step timestamping (no frame is changed), PTP
general messages (no timestamp needed), more than one VLAN tag, IPv6
extension headers, the BMCA and the servo (software).

Features:

- PTP hardware clock: 48-bit seconds, ns, 32-bit fraction; rate set by INC / INC_FRAC, set, signed step, consistent snapshot
- pps output with a programmable width, a target-time compare (TARGET irq and target_hit pin), external event time capture
- RX and TX GMII stream observers: SFD timestamp -/+ PHY latency for PTP event messages over layer 2 and UDP / IPv4 / IPv6, with or without one 802.1Q tag
- FCS, length, version and fragment checks; a FIFO of {messageType, domainNumber, sequenceId, seconds, ns} per direction

TIME is not readable as registers: CMD.snap copies the time into SNAP, which reads both halves consistently.
The wrapper takes a timestamp from the core FIFO whenever RXTS / TXTS is empty, so up to FIFO_DEPTH + 1 timestamps wait per direction; a frame that finds both full is counted in RX_OVF / TX_OVF.
Not implemented: one-step timestamping, general messages (they need no timestamp), more than one VLAN tag, IPv6 extension headers; the BMCA and the servo are software.

## Files

| File | Content |
|---|---|
| `rtl/PTP_top.sv` | protocol core |
| `rtl/PTP_apb.sv` | APB4 register wrapper (generated) |
| `tb/PTP_tb.sv` | core testbench |
| `tb/PTP_apb_tb.sv`, `tb/apb/PTP_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/PTP_sva.sv`, `tb/cov/PTP_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/PTP.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`PTP_apb` has the core's parameters and passes them to `PTP_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `FIFO_DEPTH` | int | `4` |

## Wrapper pins

Pins of `PTP_apb`. Widths of the pass-through pins are at the default parameters.

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
| `t_sec` | output | 48 | protocol pin, core port `t_sec` |
| `t_ns` | output | 30 | protocol pin, core port `t_ns` |
| `pps` | output | 1 | protocol pin, core port `pps` |
| `target_hit` | output | 1 | protocol pin, core port `target_hit` (also read in a register) |
| `ext_evt` | input | 1 | protocol pin, core port `ext_evt` |
| `rx_dv` | input | 1 | protocol pin, core port `rx_dv` |
| `rx_er` | input | 1 | protocol pin, core port `rx_er` |
| `rxd` | input | 8 | protocol pin, core port `rxd` |
| `tx_en` | input | 1 | protocol pin, core port `tx_en` |
| `tx_er` | input | 1 | protocol pin, core port `tx_er` |
| `txd` | input | 8 | protocol pin, core port `txd` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_inc_ns` | input | 8 | INC[7:0] |
| `cfg_inc_frac` | input | 32 | INC_FRAC[31:0] |
| `time_set` | input | 1 | CMD[0:0] |
| `set_sec` | input | 48 | SET0[31:0], SET1[15:0] |
| `set_ns` | input | 30 | SET2[29:0] |
| `time_step` | input | 1 | CMD[1:1] |
| `step_ns` | input | 32 | STEP[31:0] |
| `snap` | input | 1 | CMD[2:2] |
| `t_sec` | output | 48 | pin (pass-through) |
| `t_ns` | output | 30 | pin (pass-through) |
| `snap_sec` | output | 48 | SNAP0[31:0], SNAP1[15:0] |
| `snap_ns` | output | 30 | SNAP2[29:0] |
| `pps_en` | input | 1 | PPS[0:0] |
| `pps_width_ns` | input | 30 | PPS[30:1] |
| `pps` | output | 1 | pin (pass-through) |
| `sec_tick` | output | 1 | IRQ_STATUS.SEC_TICK |
| `target_arm` | input | 1 | CMD[3:3] |
| `target_disarm` | input | 1 | CMD[4:4] |
| `target_sec` | input | 48 | TARGET0[31:0], TARGET1[15:0] |
| `target_ns` | input | 30 | TARGET2[29:0] |
| `target_armed` | output | 1 | STATUS |
| `target_hit` | output | 1 | IRQ_STATUS.TARGET |
| `ext_evt` | input | 1 | pin (pass-through) |
| `evt_valid` | output | 1 | IRQ_STATUS.EVENT |
| `evt_sec` | output | 48 | EVT0[31:0], EVT1[15:0] |
| `evt_ns` | output | 30 | EVT2[29:0] |
| `rx_dv` | input | 1 | pin (pass-through) |
| `rx_er` | input | 1 | pin (pass-through) |
| `rxd` | input | 8 | pin (pass-through) |
| `tx_en` | input | 1 | pin (pass-through) |
| `tx_er` | input | 1 | pin (pass-through) |
| `txd` | input | 8 | pin (pass-through) |
| `cfg_rx_lat_ns` | input | 16 | LAT[15:0] |
| `cfg_tx_lat_ns` | input | 16 | LAT[31:16] |
| `cfg_l2_en` | input | 1 | TSU_CFG[0:0] |
| `cfg_ipv4_en` | input | 1 | TSU_CFG[1:1] |
| `cfg_ipv6_en` | input | 1 | TSU_CFG[2:2] |
| `rxq_valid` | output | 1 | RXTS capture |
| `rxq_pop` | input | 1 | RXTS handshake |
| `rxq_type` | output | 4 | RXTS0[3:0] |
| `rxq_domain` | output | 8 | RXTS0[11:4] |
| `rxq_seq` | output | 16 | RXTS0[27:12] |
| `rxq_sec` | output | 48 | RXTS1[31:0], RXTS2[15:0] |
| `rxq_ns` | output | 30 | RXTS3[29:0] |
| `rxq_ovf` | output | 1 | IRQ_STATUS.RX_OVF |
| `txq_valid` | output | 1 | TXTS capture |
| `txq_pop` | input | 1 | TXTS handshake |
| `txq_type` | output | 4 | TXTS0[3:0] |
| `txq_domain` | output | 8 | TXTS0[11:4] |
| `txq_seq` | output | 16 | TXTS0[27:12] |
| `txq_sec` | output | 48 | TXTS1[31:0], TXTS2[15:0] |
| `txq_ns` | output | 30 | TXTS3[29:0] |
| `txq_ovf` | output | 1 | IRQ_STATUS.TX_OVF |

## APB wrapper

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

## Programming sequence

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

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.PTP sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.PTP syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/PTP_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.PTP apb` | `TEST PASSED: PTP_apb`, then Yosys without `ERROR` | console, `work/PTP_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh PTP`<br>`bash scripts/cov/run_cov.sh PTP_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/PTP/score.json`, `work/cov/PTP_apb/score.json` |

Expected end of a step 4 run:

```
===== PTP =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/PTP_tb.sv`): drives `PTP_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/PTP_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/PTP_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/PTP_sva.sv`, `tb/cov/PTP_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/PTP_top.sv` | not run | | | | | |
| wrapper `rtl/PTP_apb.sv` | not run | | | | | |
