<!-- SPDX-License-Identifier: Apache-2.0 -->
# UCIe: design specification

A UCIe-style Die-to-Die Adapter: 68-byte flits carrying 64-byte payloads for two protocol stacks,
capability negotiation and the Adapter link state machine over a sideband, L1 entry and exit,
retrain, and Retry (CRC-16, sequence numbers, Ack / Nak, replay buffer and replay timer). Not
implemented: the 256-byte flit formats, the specification's flit header, CRC and sideband packet
formats (fields here are this design's own), raw format, more than two stacks, L2, link reset and
disable messages, parity and runtime link testing, the physical layer. Core `UCIe_top`
(`rtl/UCIe_top.sv`), testbench `tb/UCIe_tb.sv` (two Adapters joined by a TB physical layer that
delays, corrupts and drops flits), checker `tb/cov/UCIe_sva.sv` (a cycle-exact model of every
output).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; registered outputs show a
decision of clock n in clock n+1. Valids and events are one-clock pulses.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `link_en` | input | 1 | enable the link; 0 sends any state to RESET and clears everything (§3.2) | high | `clk` | - |
| `cfg_retry` | input | 1 | own capability: Retry (sampled on RESET -> PARAM) | high | `clk` | - |
| `cfg_stack1` | input | 1 | own capability: protocol stack 1 (sampled on RESET -> PARAM) | high | `clk` | - |
| `cfg_l1_ok` | input | 1 | accept an L1 request from the far side | high | `clk` | - |
| `pm_req` | input | 1 | ask for L1 (level; must have been low since the last request, §3.4) | high | `clk` | - |
| `tx_valid` | input | 1 | a 64-byte payload is offered; in L1 it also wakes the link | high | `clk` | - |
| `tx_stack` | input | 1 | stack of the payload (0 or 1) | - | `clk` | - |
| `tx_data` | input | 512 | payload | - | `clk` | - |
| `tx_ready` | output | 1 | the payload is taken (§3.5); combinational | high | comb | 0 |
| `rx_valid` | output | 1 | one-clock pulse: a payload delivered | high | `clk` | 0 |
| `rx_stack` | output | 1 | its stack; holds | - | `clk` | 0 |
| `rx_data` | output | 512 | its payload (flit bits 527:16); holds | - | `clk` | 0 |
| `phy_up` | input | 1 | the physical layer is up | high | `clk` | - |
| `lp_retrain` | output | 1 | one-clock request to the physical layer to retrain (§3.6) | high | `clk` | 0 |
| `lt_valid` | output | 1 | one-clock pulse: a flit sent on the main band | high | `clk` | 0 |
| `lt_flit` | output | 544 | flit sent (§3.1); holds | - | `clk` | 0 |
| `lr_valid` | input | 1 | a flit received on the main band | high | `clk` | - |
| `lr_flit` | input | 544 | flit received | - | `clk` | - |
| `sb_tx_valid` | output | 1 | one-clock pulse: a sideband message sent | high | `clk` | 0 |
| `sb_tx_msg` | output | 16 | sideband message {CODE, DATA} (§3.3); holds | - | `clk` | 0 |
| `sb_rx_valid` | input | 1 | a sideband message received | high | `clk` | - |
| `sb_rx_msg` | input | 16 | sideband message received; DATA[7:2] ignored | - | `clk` | - |
| `state` | output | 3 | link state: 0 RESET, 1 PARAM, 2 ACTREQ, 3 ACTIVE, 4 L1, 5 RETRAIN, 6 LINKERROR | - | `clk` | 0 |
| `cap` | output | 2 | negotiated {stack 1, Retry}; 0 in RESET | - | `clk` | 0 |
| `tx_pend` | output | `log2(RB)`+1 | flits outstanding (sent with Retry, not acknowledged); combinational | - | comb | 0 |
| `ev_crc` | output | 1 | pulse after a flit with a bad CRC was received | high | `clk` | 0 |
| `ev_replay` | output | 1 | pulse after a replay started (Nak or timeout) | high | `clk` | 0 |
| `ev_retrain` | output | 1 | pulse with `lp_retrain` | high | `clk` | 0 |
| `ev_pmnak` | output | 1 | pulse after the far side refused L1 (Rsp.PMNAK) | high | `clk` | 0 |
| `ev_proto` | output | 1 | pulse after an unexpected sideband message or flit was dropped (§3.7) | high | `clk` | 0 |
| `ev_lerr` | output | 1 | pulse when LINKERROR is entered | high | `clk` | 0 |

### Internal signals used by the verification

The FSM coverage collector (`tb/cov/UCIe_fsm_cov.sv`) binds to this by name; a re-implementation
must have it.

| Signal | Width | Meaning |
|---|---|---|
| `st` | 3 | link state register, the value on `state` |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/UCIe.md`](../ip/UCIe.md) (source: `scripts/apb/specs/UCIe.json`); do not edit by hand.

`UCIe_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `phy_up`, `lp_retrain`, `lt_valid`, `lt_flit`, `lr_valid`, `lr_flit`, `sb_tx_valid`, `sb_tx_msg`, `sb_rx_valid`, `sb_rx_msg`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55430300 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x0000000E | Link control and capabilities |
| 0x018 | TX0 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x01C | TX1 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x020 | TX2 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x024 | TX3 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x028 | TX4 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x02C | TX5 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x030 | TX6 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x034 | TX7 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x038 | TX8 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x03C | TX9 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x040 | TX10 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x044 | TX11 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x048 | TX12 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x04C | TX13 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x050 | TX14 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x054 | TX15 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x058 | TX16 | RW | 0x00000000 | 64-byte flit payload to send and its stack; writing the last word sends it (the Adapter takes it in ACTIVE when the replay buffer has room and no replay is running; in L1 it wakes the link) |
| 0x05C | RX0 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x060 | RX1 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x064 | RX2 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x068 | RX3 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x06C | RX4 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x070 | RX5 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x074 | RX6 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x078 | RX7 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x07C | RX8 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x080 | RX9 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x084 | RX10 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x088 | RX11 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x08C | RX12 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x090 | RX13 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x094 | RX14 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x098 | RX15 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x09C | RX16 | RO (pop) | 0x00000000 | 64-byte payload received and its stack; reading the last word pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x0A0 | STATUS | RO | core | Link state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x0A4 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5543 | IP code |
| ID | 15:8 | MAJOR | RO | 0x03 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 9:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 9:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `link_en` | RW | 0x0 | enable the link: with phy_up the Adapter starts the capability exchange; clearing it returns to RESET and clears everything |
| CTRL | 1 | `cfg_retry` | RW | 0x1 | Retry capability advertised in AdvCap (taken when the link starts) |
| CTRL | 2 | `cfg_stack1` | RW | 0x1 | stack 1 capability advertised in AdvCap (taken when the link starts) |
| CTRL | 3 | `cfg_l1_ok` | RW | 0x1 | accept L1 requests from the far side |
| CTRL | 4 | `pm_req` | RW | 0x0 | request L1 when the link is idle (armed again once cleared) |
| TX0 | 31:0 | `tx_data[31:0]` | RW | 0x0 | payload |
| TX1 | 31:0 | `tx_data[63:32]` | RW | 0x0 | payload |
| TX2 | 31:0 | `tx_data[95:64]` | RW | 0x0 | payload |
| TX3 | 31:0 | `tx_data[127:96]` | RW | 0x0 | payload |
| TX4 | 31:0 | `tx_data[159:128]` | RW | 0x0 | payload |
| TX5 | 31:0 | `tx_data[191:160]` | RW | 0x0 | payload |
| TX6 | 31:0 | `tx_data[223:192]` | RW | 0x0 | payload |
| TX7 | 31:0 | `tx_data[255:224]` | RW | 0x0 | payload |
| TX8 | 31:0 | `tx_data[287:256]` | RW | 0x0 | payload |
| TX9 | 31:0 | `tx_data[319:288]` | RW | 0x0 | payload |
| TX10 | 31:0 | `tx_data[351:320]` | RW | 0x0 | payload |
| TX11 | 31:0 | `tx_data[383:352]` | RW | 0x0 | payload |
| TX12 | 31:0 | `tx_data[415:384]` | RW | 0x0 | payload |
| TX13 | 31:0 | `tx_data[447:416]` | RW | 0x0 | payload |
| TX14 | 31:0 | `tx_data[479:448]` | RW | 0x0 | payload |
| TX15 | 31:0 | `tx_data[511:480]` | RW | 0x0 | payload |
| TX16 | 0 | `tx_stack` | RW | 0x0 | protocol stack (1 is dropped unless negotiated) |
| RX0 | 31:0 | `rx_data[31:0]` | RO (pop) | 0x0 | payload |
| RX1 | 31:0 | `rx_data[63:32]` | RO (pop) | 0x0 | payload |
| RX2 | 31:0 | `rx_data[95:64]` | RO (pop) | 0x0 | payload |
| RX3 | 31:0 | `rx_data[127:96]` | RO (pop) | 0x0 | payload |
| RX4 | 31:0 | `rx_data[159:128]` | RO (pop) | 0x0 | payload |
| RX5 | 31:0 | `rx_data[191:160]` | RO (pop) | 0x0 | payload |
| RX6 | 31:0 | `rx_data[223:192]` | RO (pop) | 0x0 | payload |
| RX7 | 31:0 | `rx_data[255:224]` | RO (pop) | 0x0 | payload |
| RX8 | 31:0 | `rx_data[287:256]` | RO (pop) | 0x0 | payload |
| RX9 | 31:0 | `rx_data[319:288]` | RO (pop) | 0x0 | payload |
| RX10 | 31:0 | `rx_data[351:320]` | RO (pop) | 0x0 | payload |
| RX11 | 31:0 | `rx_data[383:352]` | RO (pop) | 0x0 | payload |
| RX12 | 31:0 | `rx_data[415:384]` | RO (pop) | 0x0 | payload |
| RX13 | 31:0 | `rx_data[447:416]` | RO (pop) | 0x0 | payload |
| RX14 | 31:0 | `rx_data[479:448]` | RO (pop) | 0x0 | payload |
| RX15 | 31:0 | `rx_data[511:480]` | RO (pop) | 0x0 | payload |
| RX16 | 0 | `rx_stack` | RO (pop) | 0x0 | protocol stack |
| STATUS | 2:0 | `state` | RO | core | link state: 0 RESET, 1 PARAM, 2 ACTREQ, 3 ACTIVE, 4 L1, 5 RETRAIN, 6 LINKERROR |
| STATUS | 4:3 | `cap` | RO | core | negotiated capabilities {stack 1, Retry} |
| STATUS | 8:5 | `tx_pend` | RO | core | flits sent and not yet acknowledged |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CRC | a flit with a bad CRC was received and dropped |
| 1 | REPLAY | a replay started: a Nak from the far side, or the replay timeout |
| 2 | RETRAIN | NR replays without progress: a retrain was requested (lp_retrain) |
| 3 | PMNAK | the far side refused an L1 request |
| 4 | PROTO | a sideband message not expected in the state, or a flit dropped (wrong state, RTY mismatch, stack 1 not negotiated) |
| 5 | LINKERR | LINKERROR entered: FinCap mismatch, handshake timeout, or a bad CRC without Retry |
| 6 | TX_DONE | TX beat accepted by the core |
| 7 | TX_OVF | write to TX while full (dropped) |
| 8 | RX_AVAIL | RX captured a beat |
| 9 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_stack`/`tx_valid`. Writing TX16 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_stack` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX16 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55430300.
2. Write 0x3FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3FF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x018) then TX1 (0x01C) then TX2 (0x020) then TX3 (0x024) then TX4 (0x028) then TX5 (0x02C) then TX6 (0x030) then TX7 (0x034) then TX8 (0x038) then TX9 (0x03C) then TX10 (0x040) then TX11 (0x044) then TX12 (0x048) then TX13 (0x04C) then TX14 (0x050) then TX15 (0x054) then TX16 (0x058). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x05C) then RX1 (0x060) then RX2 (0x064) then RX3 (0x068) then RX4 (0x06C) then RX5 (0x070) then RX6 (0x074) then RX7 (0x078) then RX8 (0x07C) then RX9 (0x080) then RX10 (0x084) then RX11 (0x088) then RX12 (0x08C) then RX13 (0x090) then RX14 (0x094) then RX15 (0x098) then RX16 (0x09C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 8) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
7. Read STATUS (0x0A0) for the core's live `state`, `cap`, `tx_pend`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL with link_en set (and the capabilities wanted); poll STATUS until state reads 3 (ACTIVE) and check cap.
2. Send: write TX0..TX15 (payload) and TX16 (stack); the last write commits it. Receive: on RX_AVAIL read RX0..RX16; reading RX16 pops it.
3. Set pm_req to let the link enter L1 when idle; a TX write wakes it.
4. On LINKERR, clear link_en, then set it again to restart the link.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Flit

| Bits | Field |
|---|---|
| 543 | DATA (1: payload flit, 0: NOP) |
| 542 | STACK |
| 541 | NAK |
| 540 | RTY (Retry negotiated) |
| 539:534 | SEQ |
| 533:528 | ACK (last SEQ received in order) |
| 527:16 | payload (0 in a NOP) |
| 15:0 | CRC-16 of bits 543:16: polynomial 0x1021, initial value 0xFFFF, bit 543 first, no final XOR |

Without Retry a flit has NAK, RTY, SEQ and ACK 0.

### 3.2 Link state machine

| From | To | When |
|---|---|---|
| RESET | PARAM | `link_en` and `phy_up`: own capability = {`cfg_stack1`, `cfg_retry`}, AdvCap owed |
| PARAM | (FinCap) | with a far AdvCap (received now or before): negotiated = own AND far, FinCap owed with it; again for each later AdvCap |
| PARAM | ACTREQ | own FinCap owed or sent and a far FinCap received (now or before) equal to the negotiated value: Req.Active owed, Rsp.Active owed if a Req.Active was already received |
| PARAM | LINKERROR | the far FinCap differs |
| PARAM | RESET | `phy_up` = 0 |
| ACTREQ | ACTIVE | a Req.Active received (answered with Rsp.Active) and a Rsp.Active received (both may arrive in the same or earlier clocks of ACTREQ). Every outstanding flit is replayed |
| ACTIVE, L1 | ACTREQ | a Req.Active received: Rsp.Active and Req.Active owed |
| ACTIVE | L1 | own request accepted (Rsp.L1) or the far request accepted (§3.4) |
| L1 | ACTREQ | `tx_valid`: Req.Active owed |
| ACTREQ, ACTIVE, L1 | RETRAIN | `phy_up` = 0: owed messages, the Active / L1 handshake progress and the replay timer / count cleared; capabilities and Retry state kept |
| RETRAIN | ACTREQ | `phy_up` = 1: Req.Active owed, Rsp.Active owed if a Req.Active was received in RETRAIN |
| PARAM, ACTREQ | LINKERROR | `HT` clocks in the state (handshake timeout) |
| ACTREQ, ACTIVE | LINKERROR | a bad CRC without Retry |
| ACTREQ, ACTIVE, L1, RETRAIN | RESET | a far AdvCap (new session): everything cleared, the AdvCap kept for the next PARAM |
| any but RESET | RESET | `link_en` = 0: everything cleared (negotiated capability, Retry counters, owed messages) |

LINKERROR is left only through `link_en` = 0. Entering LINKERROR pulses `ev_lerr` and drops owed
sideband messages. A `phy_up` drop in the same clock as a LINKERROR cause gives RETRAIN (RESET from PARAM).

### 3.3 Sideband

One 16-bit message {CODE[7:0], DATA[7:0]} per transfer.

| CODE | Message | DATA |
|---|---|---|
| 01 | AdvCap | {6'b0, stack 1, Retry} own capability |
| 02 | FinCap | {6'b0, negotiated} |
| 03 | Req.Active | 0 |
| 04 | Rsp.Active | 0 |
| 05 | Req.L1 | 0 |
| 06 | Rsp.L1 | 0 |
| 07 | Rsp.PMNAK | 0 |

Messages are owed (one flag each) and sent one per clock, in the next clock, in the order AdvCap,
FinCap, Rsp.Active, Req.Active, Rsp.L1, Rsp.PMNAK, Req.L1. A message received where the table in
§3.7 does not accept it is dropped with `ev_proto`.

### 3.4 L1

* Own entry: in ACTIVE, not already waiting, `pm_req` = 1 and armed (`pm_req` was 0 in some clock
  since the last request or since reset), nothing outstanding, no Ack / Nak owed, `tx_valid` = 0,
  and no sideband message moving the state this clock: Req.L1 owed, the Adapter waits
  (`tx_ready` 0). Rsp.L1 -> L1; Rsp.PMNAK -> ACTIVE goes on, `ev_pmnak`.
* Far request: Req.L1 in ACTIVE is accepted when `cfg_l1_ok` = 1, nothing outstanding, no Ack /
  Nak owed, `tx_valid` = 0 and `lr_valid` = 0: Rsp.L1 owed, -> L1. Otherwise Rsp.PMNAK owed.
* Entering L1 disarms `pm_req`.

### 3.5 Main band transmit (ACTIVE only)

`tx_ready` = ACTIVE and not waiting for L1 and (no Retry, or fewer than `RB` outstanding and no
replay running). A payload taken for stack 1 when stack 1 was not negotiated is dropped with
`ev_proto`. With Retry, in priority order per clock:

1. a replay running: resend the buffer entry at the replay pointer (its SEQ and stack);
2. a new payload: SEQ = next new number, stored in the replay buffer;
3. a NOP when an Ack or Nak is owed.

Every flit sent with Retry carries ACK = next expected SEQ - 1 and NAK = Nak owed, and clears the
owed Ack / Nak (a flit received in the same clock may owe them again). Without Retry only payload
flits are sent. The flit appears on `lt_flit` with `lt_valid` in the next clock.

### 3.6 Main band receive and Retry

Flits are accepted in ACTREQ and ACTIVE; in other states they are dropped with `ev_proto`. Then:

* Bad CRC: `ev_crc`. Without Retry: LINKERROR. With Retry: a Nak owed, unless one was already
  sent since the last in-order flit.
* RTY bit not equal to the negotiated Retry: dropped, `ev_proto`.
* With Retry: ACK frees the flits up to it if it is within what is outstanding (else ignored);
  freeing at least one is progress. NAK = 1 replays everything still outstanding (`ev_replay`).
  A DATA flit with the expected SEQ is delivered (unless for an unnegotiated stack 1: dropped,
  `ev_proto`, but its SEQ is consumed) and an Ack is owed; an old SEQ (1..`RB` behind) is dropped
  with an Ack owed; any other SEQ is dropped with one Nak.
* Without Retry: a DATA flit is delivered; a NOP or an unnegotiated stack 1 is dropped with
  `ev_proto`.
* Delivered payloads appear on `rx_*` in the next clock.

Replay timer: counts clocks in ACTIVE with Retry while flits are outstanding, no replay is
running and no progress happens; after `TO` such clocks a replay of everything outstanding
starts (`ev_replay`). Each replay without progress in between counts; the `NR`-th pulses
`lp_retrain` and `ev_retrain` and the count restarts. Entering ACTIVE also replays everything
outstanding (no `ev_replay`).

### 3.7 Unexpected messages and flits (`ev_proto`)

| Message | Accepted in |
|---|---|
| AdvCap | every state but LINKERROR |
| FinCap | PARAM |
| Req.Active | PARAM, ACTREQ, ACTIVE, L1, RETRAIN |
| Rsp.Active | ACTREQ |
| Req.L1 | ACTIVE (answered Rsp.L1 or Rsp.PMNAK) |
| Rsp.L1 | ACTIVE while waiting for L1; ignored silently in L1 |
| Rsp.PMNAK | ACTIVE while waiting for L1 |
| other codes | never |

### 3.8 Reset

While `rst_n` is low: RESET, every output 0 (including `tx_ready` and `cap`), replay buffer and
counters cleared, `pm_req` disarmed.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `RB` | 8 | power of 2, 2..32 | replay buffer entries (most flits outstanding) |
| `TO` | 64 | 2 or more | replay timeout, clocks |
| `NR` | 4 | 2 or more | replays without progress before a retrain request |
| `HT` | 512 | 2 or more | sideband handshake timeout in PARAM / ACTREQ, clocks |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| FinCap values differ | LINKERROR |
| no handshake progress for `HT` clocks | LINKERROR |
| bad CRC without Retry | LINKERROR (the payload is lost) |
| bad CRC with Retry | Nak (once), the sender replays |
| ACK outside what is outstanding | ignored |
| duplicate (replayed) flit | dropped, Ack owed |
| `phy_up` lost in ACTIVE with flits outstanding | RETRAIN, then replayed on re-entering ACTIVE |
| far AdvCap during a session | RESET and a new negotiation |
| `pm_req` held high | only one L1 request until it drops |
| far L1 request with traffic pending | Rsp.PMNAK |
| payload for stack 1 not negotiated | dropped, `ev_proto` |
| reset with traffic in flight | everything cleared |

## 6. TB check map

Messages are printed by `tb/UCIe_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/UCIe_sva.sv`, which computes every output of both Adapters in every clock. Two
Adapters A and B are joined by a TB physical layer with variable delay, corruption and drops;
payloads for both stacks are scoreboarded both ways. Bring-up with every mix of capabilities,
retrain with traffic, retrain requests after `NR` replays, L1 from either side, crossed requests,
PMNAK and L1 exit are run; then the TB takes B's place to send crafted flits and sideband
messages, and a reset with traffic in flight.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "A not in PARAM while B is disabled" | PARAM waits for the far AdvCap | §3.2 |
| "bring-up: cap" | negotiated = own AND far | §3.2 |
| "A asked for L1 again without pm_req dropping" | `pm_req` re-arms only after it is 0 | §3.4 |
| "L1 refused, but not ACTIVE" | after Rsp.PMNAK both stay ACTIVE | §3.4 |
| "crafted Req.Active: A not in ACTREQ" | Req.Active in ACTIVE -> ACTREQ | §3.2 |
| "crafted Rsp.Active: A not ACTIVE" | Rsp.Active completes ACTREQ -> ACTIVE | §3.2 |
| "crafted: too few flits outstanding" | ACK outside the outstanding range is ignored | §3.6 |
| "Retry off, bad CRC: A not in LINKERROR" | bad CRC without Retry -> LINKERROR | §3.6 |
| "Retry off with corruption: no LINKERROR" | the same with a corrupting physical layer | §3.6 |
| "PARAM timeout: A not in LINKERROR" | `HT` clocks in PARAM -> LINKERROR | §3.2 |
| "ACTREQ timeout: A not in LINKERROR" | `HT` clocks in ACTREQ -> LINKERROR | §3.2 |
| "FinCap mismatch: A not in LINKERROR" | FinCap compare | §3.2 |
| "crafted bring-up: A not ACTIVE" | handshake against the crafted peer | §3.2, §3.3 |
| "crafted Req.L1: A not in L1" | far Req.L1 accepted | §3.4 |
| "crafted L1 exit: A not ACTIVE" | L1 -> ACTREQ -> ACTIVE | §3.2 |
| "crafted Rsp.L1: A not in L1" | own request answered by Rsp.L1 | §3.4 |
| "crafted retrain: A not ACTIVE" | RETRAIN -> ACTREQ -> ACTIVE | §3.2 |
| "A asked for L1 after reset without pm_req dropping" | `pm_req` disarmed by reset | §3.4, §3.8 |
| a_flit | `lt_valid` / `lt_flit` exactly as the model | §3.1, §3.5 |
| a_rx | `rx_valid` / `rx_data` / `rx_stack` exactly as the model | §3.6 |
| a_sb | `sb_tx_valid` / `sb_tx_msg` exactly as the model | §3.3 |
| a_state | `state` and `cap` exactly as the model | §3.2 |
| a_status | `tx_ready` and `tx_pend` exactly as the model | §3.5, §3.6 |
| a_retrain | `lp_retrain` / `ev_retrain` exactly as the model | §3.6 |
| a_events | `ev_crc`, `ev_replay`, `ev_pmnak`, `ev_proto`, `ev_lerr` exactly as the model | §3.6, §3.7 |
| a_reset | in reset: every output 0 | §3.8 |
