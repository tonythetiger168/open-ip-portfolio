# UCIe-style Die-to-Die Adapter: 68-byte flits for two protocol stacks, capability exchange and the Adapter link state machine over the sideband, L1, retrain, and Retry (CRC-16, sequence numbers, Ack / Nak, replay buffer and timer)

Protocol IP `UCIe`, version 3.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `UCIe_top` (`rtl/UCIe_top.sv`) |
| Register interface | APB4 slave `UCIe_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55430300 (code 0x5543, version 3.0) |
| Registers | 41 words, 0x000 to 0x0A0 |
| Interrupts | 10 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 10 pass-through |

## Overview

UCIe_top v3.0: a UCIe-style Die-to-Die Adapter: 68-byte flits carrying 64-byte payloads for two protocol stacks, capability negotiation and the Adapter link state machine over the sideband, L1 entry and exit, retrain, and Retry (CRC, sequence numbers, Ack / Nak, replay buffer and timer)

- Protocol side (FDI-like, 64-byte width): tx_valid / tx_ready /
tx_stack / tx_data, one flit payload per transfer; rx_valid /
rx_stack / rx_data, payloads delivered once each, in order.
- Main band (RDI-like): lt_valid / lt_flit out, lr_valid / lr_flit in,
one 68-byte flit per transfer:
[543:528] header {DATA, STACK, NAK, RTY, SEQ[5:0], ACK[5:0]}
[527:16]  payload (64 bytes; zero in a NOP flit)
[15:0]    CRC-16 (polynomial 0x1021, seed 0xFFFF, MSB first) of
bits 543:16
phy_up: the physical layer is up. lp_retrain: a one-clock request to
the physical layer to retrain the link.
- Sideband: sb_tx_* / sb_rx_*, one 16-bit message {CODE[7:0],
DATA[7:0]} per transfer. Codes: 01 AdvCap and 02 FinCap (DATA[1:0] =
{stack 1, Retry}), 03 Req.Active, 04 Rsp.Active, 05 Req.L1,
06 Rsp.L1, 07 Rsp.PMNAK. Other DATA bits are ignored. When several
messages are owed, one goes out per clock in that order: AdvCap,
FinCap, Rsp.Active, Req.Active, Rsp.L1, Rsp.PMNAK, Req.L1.
- Link state (state): RESET 0, PARAM 1, ACTREQ 2, ACTIVE 3, L1 4,
RETRAIN 5, LINKERROR 6.
RESET -> PARAM: link_en and phy_up. The Adapter takes its
capabilities from {cfg_stack1, cfg_retry} and sends AdvCap. An
AdvCap from the far side is kept in RESET too.
PARAM: with the far AdvCap, cap = own AND far, sent in FinCap (again
for each later AdvCap). Once both FinCaps have crossed: equal ->
ACTREQ (Req.Active sent), different -> LINKERROR.
An AdvCap in ACTREQ, ACTIVE, L1 or RETRAIN: the far side started a
new session; -> RESET (everything cleared, the AdvCap kept).
ACTREQ -> ACTIVE: a Req.Active received (answered by Rsp.Active)
and a Rsp.Active received. Entering ACTIVE replays every flit
still outstanding. A Req.Active received in PARAM or RETRAIN is
answered on entering ACTREQ; one received in ACTIVE or L1 moves
to ACTREQ (both messages sent).
ACTIVE -> L1: pm_req (armed: it was low since the last request)
with nothing outstanding or owed and no tx_valid: Req.L1 is sent
and new flits wait. Rsp.L1 -> L1; Rsp.PMNAK -> stay (ev_pmnak). A
Req.L1 from the far side is accepted (Rsp.L1, -> L1) under the
same conditions with cfg_l1_ok and no flit arriving, else
answered by Rsp.PMNAK.
L1 -> ACTREQ: tx_valid (Req.Active sent).
phy_up low: PARAM -> RESET; ACTREQ, ACTIVE, L1 -> RETRAIN, keeping
the negotiated capabilities and the Retry state; RETRAIN ->
ACTREQ when phy_up returns.
PARAM or ACTREQ for HT clocks -> LINKERROR (handshake timeout).
link_en low: any state -> RESET; everything is cleared.
LINKERROR is left only through RESET (link_en low).
A sideband message not expected in the state is dropped (ev_proto).
- Flits are sent in ACTIVE only and received in ACTREQ and ACTIVE (any
other state: dropped, ev_proto). A flit whose RTY bit differs from
the negotiated Retry, or a DATA flit for stack 1 when stack 1 was not
negotiated, is dropped (ev_proto); with Retry its SEQ still counts as
received. A payload offered for stack 1 without it is taken and
dropped (ev_proto).
- Retry negotiated: every flit carries ACK (the last SEQ received in
order) and NAK. Transmit: a replay in progress first, then a new
payload (tx_ready: the RB-entry replay buffer has room, no replay
running), then a NOP when an Ack or Nak is owed. Receive: a bad CRC
is dropped (ev_crc) and a Nak is owed; the expected SEQ is delivered
and an Ack is owed; an old SEQ (a replayed duplicate) is dropped and
an Ack is owed; a SEQ ahead is dropped and a Nak is owed; one Nak
until the expected flit arrives. An ACK frees the buffer up to it (one
that is not within what is outstanding is ignored); NAK set replays
all outstanding. A replay also starts after TO clocks in ACTIVE
without progress while flits are outstanding (ev_replay). NR replays
without an Ack in between request a retrain (lp_retrain, ev_retrain).
- Retry not negotiated: DATA flits with SEQ, ACK, NAK and RTY 0; no
buffer, no Acks. A flit with a bad CRC is dropped (ev_crc) and the
Adapter enters LINKERROR (ev_lerr), since the payload is lost.
- cap: the negotiated {stack 1, Retry} (0 in RESET). tx_pend: flits
outstanding. ev_lerr: LINKERROR entered.
Not implemented: the 256-byte flit formats, the spec's flit header,
CRC and sideband packet formats (fields here are ours, not checked
against another Adapter), raw format, more than two stacks, L2, link
reset and disable messages, parity and runtime link testing, the
physical layer.

Features:

- 68-byte flits: a 2-byte header {DATA, STACK, NAK, RTY, SEQ, ACK}, a 64-byte payload, a CRC-16.
- Two protocol stacks multiplexed on one link; stack 1 only when both sides advertise it.
- Capability exchange (AdvCap / FinCap) and the Active handshake (Req.Active / Rsp.Active) over a sideband, with a handshake timeout.
- Adapter link state machine: RESET, PARAM, ACTREQ, ACTIVE, L1, RETRAIN, LINKERROR.
- L1 entry from either side (Req.L1 / Rsp.L1 / Rsp.PMNAK), crossed requests, exit on traffic.
- Retrain on phy_up loss, keeping the Retry state and replaying what is outstanding; a retrain request after NR replays without progress.
- Retry: sequence numbers, Ack / Nak, an RB-entry replay buffer and a replay timer. Without Retry a bad CRC is a link error.

lt_valid / lt_flit and lr_valid / lr_flit are the 68-byte flit interface to the physical layer, phy_up / lp_retrain its status and retrain request, and sb_tx_valid / sb_tx_msg and sb_rx_valid / sb_rx_msg the sideband; they pass through unchanged.
The core parameters RB (8), TO (64), NR (4) and HT (512) keep their defaults.
Field layouts, message codes and the CRC are ours; they follow the UCIe Adapter's structure but have not been checked against another UCIe Adapter.

## Files

| File | Content |
|---|---|
| `rtl/UCIe_top.sv` | protocol core |
| `rtl/UCIe_apb.sv` | APB4 register wrapper (generated) |
| `tb/UCIe_tb.sv` | core testbench |
| `tb/UCIe_apb_tb.sv`, `tb/apb/UCIe_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/UCIe_sva.sv`, `tb/cov/UCIe_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/UCIe.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`UCIe_apb` has the core's parameters and passes them to `UCIe_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `RB` | int | `8` |
| `TO` | int | `64` |
| `NR` | int | `4` |
| `HT` | int | `512` |

## Wrapper pins

Pins of `UCIe_apb`. Widths of the pass-through pins are at the default parameters.

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
| `phy_up` | input | 1 | protocol pin, core port `phy_up` |
| `lp_retrain` | output | 1 | protocol pin, core port `lp_retrain` |
| `lt_valid` | output | 1 | protocol pin, core port `lt_valid` |
| `lt_flit` | output | 544 | protocol pin, core port `lt_flit` |
| `lr_valid` | input | 1 | protocol pin, core port `lr_valid` |
| `lr_flit` | input | 544 | protocol pin, core port `lr_flit` |
| `sb_tx_valid` | output | 1 | protocol pin, core port `sb_tx_valid` |
| `sb_tx_msg` | output | 16 | protocol pin, core port `sb_tx_msg` |
| `sb_rx_valid` | input | 1 | protocol pin, core port `sb_rx_valid` |
| `sb_rx_msg` | input | 16 | protocol pin, core port `sb_rx_msg` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `link_en` | input | 1 | CTRL[0:0] |
| `cfg_retry` | input | 1 | CTRL[1:1] |
| `cfg_stack1` | input | 1 | CTRL[2:2] |
| `cfg_l1_ok` | input | 1 | CTRL[3:3] |
| `pm_req` | input | 1 | CTRL[4:4] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_stack` | input | 1 | TX16 |
| `tx_data` | input | 512 | TX0[31:0], TX1[31:0], TX2[31:0], TX3[31:0], TX4[31:0], TX5[31:0], TX6[31:0], TX7[31:0], TX8[31:0], TX9[31:0], TX10[31:0], TX11[31:0], TX12[31:0], TX13[31:0], TX14[31:0], TX15[31:0] |
| `tx_ready` | output | 1 | TX handshake |
| `rx_valid` | output | 1 | RX capture |
| `rx_stack` | output | 1 | RX16 |
| `rx_data` | output | 512 | RX0[31:0], RX1[31:0], RX2[31:0], RX3[31:0], RX4[31:0], RX5[31:0], RX6[31:0], RX7[31:0], RX8[31:0], RX9[31:0], RX10[31:0], RX11[31:0], RX12[31:0], RX13[31:0], RX14[31:0], RX15[31:0] |
| `phy_up` | input | 1 | pin (pass-through) |
| `lp_retrain` | output | 1 | pin (pass-through) |
| `lt_valid` | output | 1 | pin (pass-through) |
| `lt_flit` | output | 544 | pin (pass-through) |
| `lr_valid` | input | 1 | pin (pass-through) |
| `lr_flit` | input | 544 | pin (pass-through) |
| `sb_tx_valid` | output | 1 | pin (pass-through) |
| `sb_tx_msg` | output | 16 | pin (pass-through) |
| `sb_rx_valid` | input | 1 | pin (pass-through) |
| `sb_rx_msg` | input | 16 | pin (pass-through) |
| `state` | output | 3 | STATUS[2:0] |
| `cap` | output | 2 | STATUS[4:3] |
| `tx_pend` | output | 4 | STATUS[8:5] |
| `ev_crc` | output | 1 | IRQ_STATUS.CRC |
| `ev_replay` | output | 1 | IRQ_STATUS.REPLAY |
| `ev_retrain` | output | 1 | IRQ_STATUS.RETRAIN |
| `ev_pmnak` | output | 1 | IRQ_STATUS.PMNAK |
| `ev_proto` | output | 1 | IRQ_STATUS.PROTO |
| `ev_lerr` | output | 1 | IRQ_STATUS.LINKERR |

## APB wrapper

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

## Programming sequence

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

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.UCIe sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.UCIe syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/UCIe_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.UCIe apb` | `TEST PASSED: UCIe_apb`, then Yosys without `ERROR` | console, `work/UCIe_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh UCIe`<br>`bash scripts/cov/run_cov.sh UCIe_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/UCIe/score.json`, `work/cov/UCIe_apb/score.json` |

Expected end of a step 4 run:

```
===== UCIe =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/UCIe_tb.sv`): drives `UCIe_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/UCIe_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/UCIe_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/UCIe_sva.sv`, `tb/cov/UCIe_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/UCIe_top.sv` | pass | 146/146 (+7 excl.) | 4562/4562 (+22 excl.) | 7/7 | 8/8 | 230/230 |
| wrapper `rtl/UCIe_apb.sv` | pass | 98/98 | 6936/6936 (+22 excl.) | n/a | 30/30 | 139/139 |
