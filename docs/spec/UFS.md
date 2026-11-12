<!-- SPDX-License-Identifier: Apache-2.0 -->
# UFS: design specification

A UFS host, as an educational slice: a simplified UniPro-style serial frame link with a training
handshake, and UPIU command transactions (TEST UNIT READY, READ10, WRITE10) against an internal
256 x 32-bit LUN 0 medium. Not implemented: the real M-PHY / UniPro stack (8b10b, PA/DL/N/T
layers, power modes), task management, query requests, multiple outstanding commands and more
than one LUN. Core `UFS_top` (`rtl/UFS_top.sv`), testbench `tb/UFS_tb.sv` (a device-side peer
with a shadow medium), checker `tb/cov/UFS_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *bit tick* is the clock where the free-running divider
`bd_cnt` equals `BIT_CLKS`-1 (every clock when `BIT_CLKS` = 1). Lane data moves one bit per bit
tick, most significant bit of each 32-bit dword first.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one serial bit every `BIT_CLKS` clocks | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `tx_p` | output | 1 | serial lane out, MSB first; idles high; combinational from the training FSM and the TX serializer register | - | `clk` | 1 |
| `tx_n` | output | 1 | complement of `tx_p` (`tx_n` = ~`tx_p`) | - | `clk` | 0 |
| `rx_p` | input | 1 | serial lane in, sampled on each bit tick, MSB first | - | `clk` | - |
| `rx_n` | input | 1 | differential complement of `rx_p`; unused | - | - | - |
| `refclk` | input | 1 | reference clock; unused (bit timing comes from `clk`) | - | - | - |
| `irq` | output | 1 | one-clock error pulse (section 5) | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads `link_up` and `lp_state`; the bound checker (`.*`) connects `storage`; fsm_cov binds
the three state registers. A re-implementation must keep these names and encodings.

| Signal | Width | Meaning |
|---|---|---|
| `link_up` | 1 | `lp_state` == LINKUP |
| `lp_state` | 2 | link FSM: 0 PWR_ON, 1 TX_TRAIN, 2 WAIT_RSP, 3 LINKUP |
| `rx_state` | 3 | RX frame FSM: 0 SOF hunt, 1 HDR, 2 PAY, 3 CRC, 4 EOF |
| `tx_state` | 1 | TX serializer: 0 IDLE, 1 RUN |
| `storage` | 32 x 256 | LUN 0 medium, unpacked `[0:255]`; not reset |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/UFS.md`](../ip/UFS.md) (source: `scripts/apb/specs/UFS.json`); do not edit by hand.

`UFS_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_n`, `tx_p`, `rx_n`, `rx_p`, `refclk`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55460200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5546 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | CRC mismatch, bad EOF, length above 8, malformed CDB, bad LUN, unknown opcode, out-of-range LBA or transfer length, WRITE10 length mismatch, or a command while a response is still owed |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55460200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Link training

| State | Line (`tx_p`) | Leaves when |
|---|---|---|
| PWR_ON (after reset) | 1 | 16 clocks (raw clocks, not scaled by `BIT_CLKS`), then TX_TRAIN |
| TX_TRAIN | TRAIN = 0xBC3C5A5A, MSB first, 8 times back to back (256 bit ticks); `tx_p` is combinational from the bit counter | after the last bit: WAIT_RSP |
| WAIT_RSP | 1 | see below |
| LINKUP | the TX serializer output (`tx_ser`, idle 1) | only by reset |

In WAIT_RSP, on each bit tick the 32-bit window {31 previous `rx_p` bits, current `rx_p`} is
compared with TRAIN (sliding search). A hit arms the check; exactly 32 bit ticks later the window
must equal TRAIN again (aligned second dword), which moves to LINKUP. If the second dword differs,
the search disarms and starts sliding again. A timer counts raw clocks in WAIT_RSP; when it reaches
`TR_TMO` = 4095 x `BIT_CLKS` (that is, on the `TR_TMO`+1-th clock in the state) the FSM goes back
to TX_TRAIN and sends the 8-dword burst again. The timeout wins over a LINKUP in the same clock.
`link_up` is high only in LINKUP.

### 3.2 Frame format

Both directions use the same frame, all dwords MSB first:

| Dword | Content |
|---|---|
| SOF | 0x55465301 |
| HDR | {type[7:0], task_tag[7:0], lun[7:0], len[7:0]} |
| payload | `len` dwords, 0..8 |
| CRC | CRC-32 of HDR and payload |
| EOF | 0x55465302 |

CRC-32: polynomial 0x04C11DB7 in the reflected shift form, one bit per step:
`fb = c[0] ^ bit; c = (c >> 1) ^ (fb ? 0xEDB88320 : 0)`, initial value 0xFFFFFFFF, fed with the
on-wire bits of HDR then payload in transmission order (MSB of each dword first); the CRC dword
is the final value XOR 0xFFFFFFFF, sent MSB first.

Receive: the decoder runs only while `link_up` and only on bit ticks. In SOF hunt it compares
the sliding 32-bit window with SOF on every bit; a hit starts HDR and loads the CRC with all-ones.
HDR, payload, CRC and EOF are then taken as aligned 32-bit dwords. At the end of HDR, len > 8
drops the frame (back to SOF hunt) and pulses `irq`; len = 0 goes straight to CRC. At the end of
CRC a mismatch drops the frame with `irq`. At the end of EOF the frame is processed (section 3.3)
and the decoder returns to SOF hunt. After any drop the hunt restarts on the following bits, so a
SOF pattern inside the rest of a dropped frame can resynchronise.

### 3.3 Command handling

At the last bit tick of a good EOF dword, by HDR type:

- type 0x01 (COMMAND): processed as below unless the transmitter is busy (section 3.4).
- any other type (including DATA 0x02 and RESPONSE 0x81): ignored, no `irq`, no response.

COMMAND UPIU payload: dword0 = {opcode[7:0], lba[23:0]}, dword1 = {xfer[7:0], 24'h0}, dwords 2..3
unused, WRITE10 data in dwords 4..7. Checks, in order:

| Condition | Result |
|---|---|
| len < 4 | dropped: `irq`, no response |
| lun != 0 | CHECK response, `irq` |
| opcode 0x00 TEST UNIT READY | GOOD response |
| opcode 0x2A WRITE10, n = len-4: len >= 5, xfer == n, lba + n <= 256 (full 24-bit lba) | storage[lba .. lba+n-1] = payload[4 .. 3+n], written in this clock; GOOD response |
| WRITE10, any of those false | CHECK response, `irq`, no write |
| opcode 0x28 READ10: 1 <= xfer <= 8 and lba + xfer <= 256 | GOOD response, then a DATA UPIU of xfer dwords (section 3.4) |
| READ10, otherwise | CHECK response, `irq` |
| any other opcode | CHECK response, `irq` |

WRITE10 can carry at most 4 dwords (len <= 8). The RESPONSE UPIU is SOF,
{0x81, task_tag, lun, 0x01}, {sense[15:0], status[15:0]}, CRC, EOF, where the tag and lun echo the
command; GOOD is 0x00000000 and CHECK CONDITION / ILLEGAL REQUEST is 0x00050001.

### 3.4 Transmit serializer

A response is requested (`tx_req`) in the clock that processed the command. On the next bit tick
the idle serializer starts (CRC loaded with all-ones); from the bit tick after that, one bit per
bit tick is registered into `tx_ser`, so for `BIT_CLKS` = 1 the SOF MSB is on `tx_p` two clocks
after the command's EOF. The CRC is computed over the HDR and payload dwords as they are sent and
inserted in place of the CRC dword. After the last EOF bit:

- if a READ10 is owed, the DATA UPIU follows with no idle gap: SOF, {0x02, task_tag, 0x00, n},
  storage[lba .. lba+n-1] (read at this moment), CRC, EOF;
- otherwise the serializer returns to idle and the line is 1 from the next bit tick.

The transmitter is busy while a request is pending, a frame is on the wire, or a DATA UPIU is
still owed. A COMMAND whose EOF completes while busy is dropped with `irq`; the frame in progress
and any owed DATA UPIU (its tag and data) are not affected.

### 3.5 Reset

Reset clears the link FSM to PWR_ON, the RX FSM to SOF hunt, the serializer to idle (`tx_ser` = 1),
any pending response or owed DATA UPIU, and `irq`. `tx_p` = 1 and `tx_n` = 0 during and after
reset until TX_TRAIN. `storage` is not reset and keeps its contents.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `BIT_CLKS` | 1 | 1 and up | clocks per serial bit: RX sampling, TX bits and training bits move on bit ticks; the WAIT_RSP timeout scales to 4095 x `BIT_CLKS` clocks; the 16-clock PWR_ON delay does not scale |

Internal constants: SOF 0x55465301, EOF 0x55465302, TRAIN 0xBC3C5A5A, `TR_TMO` = 4095 x
`BIT_CLKS`.

## 5. Errors and corner cases

`irq` is a registered one-clock pulse, raised in the clock of the bit tick that ends the dword
where the error is seen:

| Error | Seen at | Frame | Response |
|---|---|---|---|
| len > 8 | end of HDR | dropped | none |
| CRC mismatch | end of CRC | dropped | none |
| EOF dword != 0x55465302 | end of EOF | dropped | none |
| COMMAND while the transmitter is busy | end of EOF | dropped | none (owed frames still go out) |
| COMMAND with len < 4 | end of EOF | dropped | none |
| lun != 0, unknown opcode, bad WRITE10, bad READ10 | end of EOF | processed | CHECK |

Corner cases:

- No `irq` for a good non-COMMAND frame, a good TEST UNIT READY, WRITE10 or READ10.
- Frames are only decoded in LINKUP; bits received before that are ignored.
- The LBA range check uses all 24 lba bits, so lba 0xFFFFFF fails even though only lba[7:0]
  indexes the medium.
- `rx_n` and `refclk` have no effect.
- `storage` is not initialised; a READ10 of a word never written returns whatever the array holds.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "timeout waiting for response SOF" | a response frame starts after every command that is answered | §3.4 |
| "response len" | a sent header carries len at most 8 | §3.2 |
| "READ10 lba" | DATA UPIU payload equals the medium at lba..lba+n-1 | §3.3 |
| "response CRC32 mismatch" | sent CRC-32 over HDR and payload | §3.2 |
| "response EOF marker mismatch" | sent frames end with EOF 0x55465302 | §3.2 |
| "LINKUP not reached after training exchange" | two aligned TRAIN dwords give LINKUP | §3.1 |
| "LINKUP on a bad second training dword" | the second dword must be TRAIN exactly 32 bits later | §3.1 |
| "RESPONSE UPIU header" | RESPONSE header {0x81, tag, lun, 1} | §3.3 |
| "RESPONSE status/sense" | GOOD = 0, CHECK = 0x00050001 | §3.3 |
| "irq on a good WRITE10" | no `irq` on a legal WRITE10 | §3.3 |
| "DATA UPIU header" | DATA header {0x02, tag, 0x00, n} | §3.4 |
| "irq asserted during reset" | `irq` = 0 in reset | §3.5 |
| "tx_p not idle during reset" | `tx_p` = 1 in reset | §3.5 |
| "link_up asserted before training" | `link_up` = 0 until training completes | §3.1 |
| "no retrain after the response timeout" | WAIT_RSP times out back to TX_TRAIN | §3.1 |
| "irq on TEST UNIT READY" | TEST UNIT READY is GOOD, no `irq` | §3.3 |
| "no irq on CRC-corrupted frame" | CRC error: `irq`, no response | §5 |
| "no irq on bad EOF" | bad EOF: `irq`, no response | §5 |
| "no irq on malformed CDB" | len < 4 on a COMMAND: `irq`, no response | §5 |
| "no irq on oversize length" | len > 8: `irq`, frame dropped | §5 |
| "irq on a non-command UPIU" | other UPIU types are ignored silently | §3.3 |
| "busy: DATA UPIU header / task tag" | the owed DATA UPIU still goes out when a command arrives while busy | §3.4 |
| "busy: DATA UPIU data" | its data is unchanged | §3.4 |
| "no irq on a command while busy" | a command while busy is dropped with `irq` | §5 |
| "reset did not idle the link" | reset returns `tx_p` = 1 and `link_up` = 0 | §3.5 |
| "BIT_CLKS=2: no irq on CRC error" | the same error rules at `BIT_CLKS` = 2 | §4 |
| a_reset_idle | in reset: `tx_p` = 1, `tx_n` = 0, `irq` = 0 | §3.5 |
| a_tx_line | `tx_p` equals the checker's bit-exact line model (training, idle, frames) | §3.1, §3.4 |
| a_differential | `tx_n` = ~`tx_p` always | §1 |
| a_irq | `irq` equals the checker's error model, clock for clock | §5 |
| a_medium | `storage` equals the checker's medium model | §3.3 |
