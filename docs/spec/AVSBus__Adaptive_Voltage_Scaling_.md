<!-- SPDX-License-Identifier: Apache-2.0 -->
# AVSBus__Adaptive_Voltage_Scaling_: design specification

A PMBus-style AVSBus slave for adaptive voltage scaling: a serial frame on SCLK / SDAT (open
drain) carries an address, a command, 16 data bits and a CRC-4; SET loads a 12-bit DAC target
that the core ramps to at 10 codes per clock, GET reads the DAC code back. Not implemented: the
PMBus 1.3 AVSBus frame format, command set and status response (the frame here is this design's
own), multiple rails, a real DAC. Core `AVSBus__Adaptive_Voltage_Scaling__top`
(`rtl/AVSBus__Adaptive_Voltage_Scaling__top.sv`), testbench
`tb/AVSBus__Adaptive_Voltage_Scaling__tb.sv` (a bit-banging master), checker
`tb/cov/AVSBus__Adaptive_Voltage_Scaling__sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. SCLK and SDAT pass three flops each; an SCLK rise is seen two to
three clocks after it happens, together with the SDAT value of the same moment. The SCLK period
must be long enough for that (the TB uses many clocks per half period).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `sclk` | input | 1 | bus clock from the master (asynchronous, three-flop synchronised) | rising edge | async | - |
| `sdat` | inout | 1 | open-drain data: the slave only pulls low (`sdat_oe`); needs a pull-up | - | async | - |
| `vdac` | output | 12 | current DAC code, 1 code = 1 mV | - | `clk` | 0 |
| `busy` | output | 1 | ramping: `vdac` differs from the target; combinational | high | comb | 0 |
| `irq` | output | 1 | one-clock pulse: a frame to this address with a bad CRC or a bad command | high | `clk` | 0 |

### Internal signals used by the verification

The TB and the bound checker read these by name; the FSM coverage collector binds `avstate`.

| Signal | Width | Meaning |
|---|---|---|
| `avstate` | 3 | 0 IDLE, 1 RECEIVE, 2 ACK, 3 TRANSMIT, 4 DONE |
| `sdat_oe` | 1 | pull SDAT low; combinational from the state (§3.2, §3.3) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/AVSBus__Adaptive_Voltage_Scaling_.md`](../ip/AVSBus__Adaptive_Voltage_Scaling_.md) (source: `scripts/apb/specs/AVSBus__Adaptive_Voltage_Scaling_.json`); do not edit by hand.

`AVSBus__Adaptive_Voltage_Scaling__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `sdat`, `vdac`, `busy`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41560200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Voltage state, as driven on the pins |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4156 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 11:0 | `vdac` | RO | core | current DAC code (1 code = 1 mV), moving 10 codes per clock toward the last target SET |
| STATUS | 12 | `busy` | RO | core | high while vdac has not reached the target |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERROR | a frame to our address was NACKed for a bad CRC or a bad command (unknown command, or a SET code above 0xFFF) |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41560200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `vdac`, `busy`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Frame

All bits are taken at SCLK rises, MSB first. A frame is: START bit 1, address[6:0], command[7:0],
data[15:0], CRC[3:0], then an ACK slot (one SCLK period), then for an ACKed GET 20 read bits.
CRC-4: polynomial x^4 + x + 1, initial value 0, over the 31 bits address .. data. SDAT is open
drain: a released line reads 1 through the pull-up.

### 3.2 Receive and ACK

In IDLE an SCLK rise with SDAT = 1 is the START bit. The next 35 rises shift in address, command,
data and CRC; after the 35th the core is in ACK. In ACK the core pulls SDAT low (ACK) if address =
0x55, the CRC matches, and the command is GET (0x02) or SET (0x01) with data[15:12] = 0; else it
releases SDAT (NACK). At the next SCLK rise (where the master samples the slot):

* ACKed SET: the ramp target = data[11:0];
* ACKed GET: the read data is latched (below) and TRANSMIT begins;
* address 0x55 with a bad CRC or a bad command: `irq` pulses (other addresses never raise `irq`);
* otherwise DONE, then IDLE in the next clock.

### 3.3 GET read data

At the ACK slot's rise the core latches {4'h0, `vdac`} and its CRC-4 (over these 16 bits) as 20
bits and drives the first (pull low for 0, release for 1); each later SCLK rise moves to the next
bit, so the master samples bit k at rise k + 1 after the slot. After the 20th rise: DONE, IDLE.

### 3.4 Voltage ramp

Every clock, if `vdac` differs from the target it moves toward it by 10 codes, or by the
remaining difference if smaller. `busy` = `vdac` != target. A new SET retargets a running ramp.

### 3.5 Timeout and reset

Outside IDLE, `TIMEOUT` clocks without an SCLK rise drop the frame (IDLE), so the next START is
decoded from the first bit. While `rst_n` is low: IDLE, `vdac` and target 0, SDAT released,
`irq` 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | any | unused (kept for the framework) |
| `AW` | 32 | any | unused (kept for the framework) |
| `TIMEOUT` | 1024 | 1 or more | clocks without an SCLK rise before a frame is dropped |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| other address | NACK, no `irq`, no read data |
| bad CRC | NACK, `irq` (own address) |
| unknown command | NACK, `irq` (own address) |
| SET with data[15:12] != 0 | NACK, `irq`, target unchanged |
| master stops mid-frame | dropped after `TIMEOUT` clocks |
| SET while ramping | the ramp turns to the new target |
| reset mid-ramp | `vdac` 0 |

## 6. TB check map

Messages are printed by `tb/AVSBus__Adaptive_Voltage_Scaling__tb.sv` as `ERROR: <message>` (TB
checks) or `SVA_FAIL: <name>` (in-TB assertions A1..A5). Assertions `a_*` are in the bound checker
`tb/cov/AVSBus__Adaptive_Voltage_Scaling__sva.sv`. A bit-banging master sends SET and GET frames,
watches the ramp, checks ACK / NACK and the readback CRC, and sends illegal addresses, corrupted
CRCs, unknown commands and out-of-range codes, directed and random, plus a reset mid-ramp.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "AVSBus GET readback CRC mismatch: data" | GET readback CRC-4 matches its data | §3.3 |
| "AVSBus ramp did not complete (busy stuck)" | the ramp reaches the target | §3.4 |
| "AVSBus SET" | a SET is ACKed | §3.2 |
| "AVSBus busy not asserted during ramp to" | `busy` while ramping | §3.4 |
| "AVSBus vdac" | `vdac` reaches the code set | §3.4 |
| "AVSBus GET not ACKed" | a GET is ACKed | §3.2 |
| "AVSBus GET readback" | GET returns `vdac` | §3.3 |
| "AVSBus reset state busy" | reset values | §3.5 |
| "AVSBus illegal address was ACKed" | other addresses are NACKed | §3.2 |
| "AVSBus irq raised for foreign address (should be ignored)" | no `irq` for other addresses | §3.2 |
| "AVSBus corrupted-CRC frame was ACKed" | bad CRC NACKed | §3.2 |
| "AVSBus irq not asserted on CRC error" | bad CRC raises `irq` | §3.2 |
| "AVSBus voltage changed after NACKed SET: vdac" | a NACKed SET changes nothing | §3.2 |
| "AVSBus unknown command was ACKed" | unknown command NACKed | §3.2 |
| "AVSBus irq not asserted on unknown command" | unknown command raises `irq` | §3.2 |
| "AVSBus final GET ack" | GET after the error cases still works | §3.2 |
| "CRV SET" | random SET ACKed | §3.2 |
| "CRV SET vdac" | random SET reaches its code | §3.4 |
| "CRV GET ack" | random GET ACKed and read back | §3.3 |
| "CRV illegal addr" | random other address NACKed | §3.2 |
| "CRV irq raised for foreign address" | no `irq` for it | §3.2 |
| "CRV corrupted-CRC frame was ACKed" | random bad CRC NACKed | §3.2 |
| "CRV irq not asserted on CRC error" | with `irq` | §3.2 |
| "CRV voltage changed after NACKed SET" | no change | §3.2 |
| "CRV unknown cmd" | random unknown command NACKed | §3.2 |
| "CRV irq not asserted on unknown command" | with `irq` | §3.2 |
| "AVSBus out-of-range SET ack" | SET with data[15:12] != 0 NACKed | §3.2 |
| "AVSBus out-of-range SET changed vdac" | and ignored | §3.2 |
| "AVSBus not reset mid-ramp" | reset clears `vdac` and the ramp | §3.5 |
| "AVSBus foreign GET ACKed" | GET to another address NACKed, nothing sent | §3.2 |
| "AVSBus bad-CRC GET ACKed" | GET with a bad CRC NACKed | §3.2 |
| "AVSBus foreign unknown cmd ACKed" | NACKed | §3.2 |
| "AVSBus bad-CRC unknown cmd ACKed" | NACKed | §3.2 |
| "A1 reset: outputs quiescent" | outputs 0 in reset | §3.5 |
| "A2 irq single-cycle pulse" | `irq` never two clocks in a row | §3.2 |
| "A3 vdac ramp step <= 10/clk" | at most 10 codes per clock | §3.4 |
| "A4 sdat drive only in ACK/TX" | `sdat_oe` only in ACK / TX | §3.2, §3.3 |
| "A5 released sdat pulled high" | released line reads 1 | §3.1 |
| a_reset_idle | in reset: SDAT released, not busy, no `irq`, `vdac` 0 | §3.5 |
| a_drive_model | `sdat_oe` exactly as the checker's model | §3.2, §3.3 |
| a_irq_model | `irq` as the model | §3.2 |
| a_vdac_model | `vdac` and `busy` as the model | §3.4 |
| a_open_drain | when driven, SDAT is 0 | §3.1 |
