# CAN 2.0A/B controller

Protocol IP `CAN`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `CAN_top` (`rtl/CAN_top.sv`) |
| Register interface | APB4 slave `CAN_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x43410200 (code 0x4341, version 2.0) |
| Registers | 18 words, 0x000 to 0x044 |
| Interrupts | 14 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 2 pass-through |

## Overview

CAN 2.0A/B protocol controller (classical CAN, ISO 11898-1)

- Frames: base (11-bit ID) and extended (29-bit ID), data and remote,
DLC 0..15 (more than 8 sends 8 data bytes). Bit stuffing from SOF to
the end of the CRC sequence, CRC-15 (polynomial 0x4599).
- Bit timing: tq = cfg_brp+1 clocks; bit = SYNC (1 tq) + TSEG1
(cfg_tseg1+1 tq) + TSEG2 (cfg_tseg2+1 tq); the bus is sampled at the
end of TSEG1. Hard synchronisation on the SOF edge, resynchronisation
on recessive-to-dominant edges with jump width cfg_sjw+1 tq (at most
one per bit, none while this node drives dominant).
- Transmit: one buffer (tx_valid/tx_ready). Bitwise arbitration over the
ID/SRR/IDE/RTR field; losing it turns the node into a receiver and the
frame is retried, as after any error. tx_abort drops a buffered frame
when the node is not transmitting it (tx_aborted).
- Receive: frames that pass ((id ^ acc_code) & acc_mask) == 0 are
delivered on rx_valid at the 6th EOF bit. Own frames are not delivered.
The receiver drives the ACK slot dominant when its CRC matched.
- Errors: bit, stuff, CRC, form and ACK errors start an error frame
(6-bit active or passive error flag, wait for recessive, 8-bit
delimiter). Fault confinement: TEC +8 per transmit error, -1 per
frame sent; REC +1 per receive error, -1 per frame received (120 when
it was above 127). Error-passive at TEC or REC > 127 (passive flags,
8-bit suspend after transmitting), bus-off at TEC > 255, recovery
after 128 x 11 recessive bits. An error-passive transmitter's ACK
error and a stuff error on a recessive stuff bit in arbitration do not
raise TEC (ISO 11898-1 exceptions).
- A dominant bit in intermission is taken as SOF; a node with a pending
frame that sees it at the 3rd intermission bit transmits from the first
ID bit on (ISO 11898-1); so does a node with a pending frame that
synchronises to another node's SOF in bus idle.
Not implemented: overload frames, the +8 counter rules for dominant
bits around error flags, CAN FD.

## Files

| File | Content |
|---|---|
| `rtl/CAN_top.sv` | protocol core |
| `rtl/CAN_apb.sv` | APB4 register wrapper (generated) |
| `tb/CAN_tb.sv` | core testbench |
| `tb/CAN_apb_tb.sv`, `tb/apb/CAN_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CAN_sva.sv`, `tb/cov/CAN_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CAN.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.CAN sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.CAN apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh CAN          # core coverage (Verilator)
bash scripts/cov/run_cov.sh CAN_apb      # wrapper coverage
```

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `CAN_apb`. Widths of the pass-through pins are at the default parameters.

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
| `rxd` | input | 1 | protocol pin, core port `rxd` |
| `txd` | output | 1 | protocol pin, core port `txd` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rxd` | input | 1 | pin (pass-through) |
| `txd` | output | 1 | pin (pass-through) |
| `cfg_brp` | input | 6 | BTR[5:0] |
| `cfg_tseg1` | input | 4 | BTR[9:6] |
| `cfg_tseg2` | input | 3 | BTR[12:10] |
| `cfg_sjw` | input | 2 | BTR[14:13] |
| `acc_code` | input | 29 | ACC_CODE[28:0] |
| `acc_mask` | input | 29 | ACC_MASK[28:0] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_id` | input | 29 | TX2[28:0] |
| `tx_ide` | input | 1 | TX2[29:29] |
| `tx_rtr` | input | 1 | TX2[30:30] |
| `tx_dlc` | input | 4 | TX3[3:0] |
| `tx_data` | input | 64 | TX0[31:0], TX1[31:0] |
| `tx_abort` | input | 1 | CMD |
| `tx_done` | output | 1 | IRQ_STATUS.SENT |
| `tx_aborted` | output | 1 | IRQ_STATUS.ABORTED |
| `rx_valid` | output | 1 | RX capture |
| `rx_id` | output | 29 | RX2[28:0] |
| `rx_ide` | output | 1 | RX2[29:29] |
| `rx_rtr` | output | 1 | RX2[30:30] |
| `rx_dlc` | output | 4 | RX3[3:0] |
| `rx_data` | output | 64 | RX0[31:0], RX1[31:0] |
| `arb_lost` | output | 1 | IRQ_STATUS.ARB_LOST |
| `err_bit` | output | 1 | IRQ_STATUS.ERR_BIT |
| `err_stuff` | output | 1 | IRQ_STATUS.ERR_STUFF |
| `err_crc` | output | 1 | IRQ_STATUS.ERR_CRC |
| `err_form` | output | 1 | IRQ_STATUS.ERR_FORM |
| `err_ack` | output | 1 | IRQ_STATUS.ERR_ACK |
| `tec` | output | 9 | STATUS[8:0] |
| `rec` | output | 8 | STATUS[16:9] |
| `err_passive` | output | 1 | STATUS[17:17], IRQ_STATUS.ERR_PASSIVE |
| `bus_off` | output | 1 | STATUS[18:18], IRQ_STATUS.BUS_OFF |

## APB wrapper

`CAN_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxd`, `txd`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43410200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | BTR | RW | 0x00002941 | Bit timing (static while the bus is in use) |
| 0x018 | ACC_CODE | RW | 0x00000000 | Acceptance code |
| 0x01C | ACC_MASK | RW | 0x00000000 | Acceptance mask |
| 0x020 | TX0 | RW | 0x00000000 | Frame to transmit; writing TX3 (DLC) queues it |
| 0x024 | TX1 | RW | 0x00000000 | Frame to transmit; writing TX3 (DLC) queues it |
| 0x028 | TX2 | RW | 0x00000000 | Frame to transmit; writing TX3 (DLC) queues it |
| 0x02C | TX3 | RW | 0x00000000 | Frame to transmit; writing TX3 (DLC) queues it |
| 0x030 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x034 | RX0 | RO (pop) | 0x00000000 | Received frame; reading RX3 frees it |
| 0x038 | RX1 | RO (pop) | 0x00000000 | Received frame; reading RX3 frees it |
| 0x03C | RX2 | RO (pop) | 0x00000000 | Received frame; reading RX3 frees it |
| 0x040 | RX3 | RO (pop) | 0x00000000 | Received frame; reading RX3 frees it |
| 0x044 | STATUS | RO | core | Fault confinement |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x048 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4341 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 13:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 13:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| BTR | 5:0 | `cfg_brp` | RW | 0x1 | time quantum = BRP+1 clocks |
| BTR | 9:6 | `cfg_tseg1` | RW | 0x5 | TSEG1 = TSEG1+1 tq (propagation + phase 1) |
| BTR | 12:10 | `cfg_tseg2` | RW | 0x2 | TSEG2 = TSEG2+1 tq (phase 2) |
| BTR | 14:13 | `cfg_sjw` | RW | 0x1 | resynchronisation jump width = SJW+1 tq (at most TSEG2+1) |
| ACC_CODE | 28:0 | `acc_code` | RW | 0x0 | ID to match (base IDs in bits 10:0) |
| ACC_MASK | 28:0 | `acc_mask` | RW | 0x0 | 1 = the ID bit must equal ACC_CODE; 0 accepts every frame |
| TX0 | 31:0 | `tx_data[31:0]` | RW | 0x0 | data bytes, byte 0 in bits 7:0 (sent first) |
| TX1 | 31:0 | `tx_data[63:32]` | RW | 0x0 | data bytes, byte 0 in bits 7:0 (sent first) |
| TX2 | 28:0 | `tx_id` | RW | 0x0 | identifier (base frames: bits 10:0) |
| TX2 | 29 | `tx_ide` | RW | 0x0 | 1 = extended frame |
| TX2 | 30 | `tx_rtr` | RW | 0x0 | 1 = remote frame |
| TX3 | 3:0 | `tx_dlc` | RW | 0x0 | data length code |
| CMD | 0 | `tx_abort` | WO (pulse) | 0x0 | 1 = drop the queued frame when it is not being sent (IRQ ABORTED) |
| RX0 | 31:0 | `rx_data[31:0]` | RO (pop) | 0x0 | data bytes, byte 0 in bits 7:0 |
| RX1 | 31:0 | `rx_data[63:32]` | RO (pop) | 0x0 | data bytes, byte 0 in bits 7:0 |
| RX2 | 28:0 | `rx_id` | RO (pop) | 0x0 | identifier |
| RX2 | 29 | `rx_ide` | RO (pop) | 0x0 | extended frame |
| RX2 | 30 | `rx_rtr` | RO (pop) | 0x0 | remote frame |
| RX3 | 3:0 | `rx_dlc` | RO (pop) | 0x0 | data length code |
| STATUS | 8:0 | `tec` | RO | core | transmit error counter |
| STATUS | 16:9 | `rec` | RO | core | receive error counter |
| STATUS | 17 | `err_passive` | RO | core | error passive |
| STATUS | 18 | `bus_off` | RO | core | bus-off |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | SENT | a queued frame was sent |
| 1 | ABORTED | a queued frame was dropped by CMD.tx_abort |
| 2 | ARB_LOST | arbitration lost (the frame is retried) |
| 3 | ERR_BIT | bit error |
| 4 | ERR_STUFF | stuff error |
| 5 | ERR_CRC | CRC error |
| 6 | ERR_FORM | form error |
| 7 | ERR_ACK | acknowledgement error |
| 8 | ERR_PASSIVE | node is error passive (level) |
| 9 | BUS_OFF | node is bus-off (level) |
| 10 | TX_DONE | TX beat accepted by the core |
| 11 | TX_OVF | write to TX while full (dropped) |
| 12 | RX_AVAIL | RX captured a beat |
| 13 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_id`, `tx_ide`, `tx_rtr`, `tx_dlc`/`tx_valid`. Writing TX3 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_id`, `rx_ide`, `rx_rtr`, `rx_dlc` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX3 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43410200.
2. Write 0x3FFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write BTR (0x014), ACC_CODE (0x018), ACC_MASK (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3FFF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x020) then TX1 (0x024) then TX2 (0x028) then TX3 (0x02C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To issue a command, write 1 to `tx_abort` (CMD bit 0) at 0x030; the core sees a one-clock pulse, and the register reads 0.
7. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x034) then RX1 (0x038) then RX2 (0x03C) then RX3 (0x040). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 12) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
8. Read STATUS (0x044) for the core's live `tec`, `rec`, `err_passive`, `bus_off`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CAN_top.sv` | pass | 162/162 | 1402/1402 (+23 excl.) | 21/21 | 11/11 | 84/84 |
| wrapper `rtl/CAN_apb.sv` | pass | 54/54 | 1654/1654 | n/a | 21/21 | 110/110 |
