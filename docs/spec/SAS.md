# SAS: design specification

Simplified SAS initiator with an OOB handshake and an SSP-style frame link layer over one serial line. It contains a target register file and a built-in initiator sequencer that writes and reads back its own registers over the link. In loopback (tx to rx) the IP exercises itself. Its traffic is observable only on the line, through `irq`, and through the internal counters. Core `SAS_top` (`rtl/SAS_top.sv`), testbench `tb/SAS_tb.sv`, checker `tb/cov/SAS_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock and line clock (one bit every BIT_CLKS clocks) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `tx_n` | output | 1 | = !`tx_p` | - | comb | 1 |
| `tx_p` | output | 1 | serial line, MSB first per dword; 0 in reset; constant 1 during OOB bursts | high | comb | 0 |
| `rx_n` | input | 1 | unused (the receiver samples `rx_p` only) | - | `clk` | - |
| `rx_p` | input | 1 | serial line in, sampled every bit tick | high | `clk` | - |
| `refclk` | input | 1 | unused (kept for interface compatibility) | - | - | - |
| `irq` | output | 1 | one-clock pulse, one clock after a CRC error, protocol violation or link timeout | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these core signals (`dut.x`), and the checker binds `phy_ready`, `ok_cnt` and `mm_cnt`. A re-implementation must provide them with the same meaning.

| Signal | Width | Meaning |
|---|---|---|
| `phy_ready` | 1 | OOB finished (state DONE); the link layer runs only while it is 1 |
| `oob_state` | 3 | OOB FSM: 0 CR_BURST, 1 CR_IDLE, 2 CI_BURST, 3 CI_IDLE, 4 DONE |
| `tx_state` | 3 | transmit FSM: 0 ALIGN, 1 SOF, 2 HDR, 3 PAY, 4 CRC, 5 EOF (the dword now on the wire) |
| `rx_state` | 3 | receive FSM (FSM coverage): 0 IDLE (SOF hunt), 1 HDR, 2 PAY, 3 CRC, 4 EOF |
| `sq_state` | 3 | initiator sequencer: 0 INIT, 1 WR, 2 WR_WAIT, 3 RD, 4 RD_WAIT, 5 GAP |
| `regs` | 32 x 16 | target register file, unpacked `[0:15]`, reset 0 |
| `sq_addr` | 4 | register of the current transaction (0 after reset, +1 per transaction) |
| `sq_wdata` | 32 | value of the current transaction (0x5A5AC3C3 after reset, then xorshift32 per transaction) |
| `ok_cnt` | 8 | read-backs verified (wraps) |
| `mm_cnt` | 8 | read-backs with a wrong value or source (wraps) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SAS.md`](../ip/SAS.md) (source: `scripts/apb/specs/SAS.json`); do not edit by hand.

`SAS_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_n`, `tx_p`, `rx_n`, `rx_p`, `refclk`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53410200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5341 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a received frame failed (CRC error, bad EOF, oversize length, unknown type, bad register address, missing payload) or a transaction timed out |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53410200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 OOB (raw clocks, not scaled by BIT_CLKS)

1. **CR_BURST:** drive `tx_p` = 1 for 106 clocks.
2. **CR_IDLE:** drive 0 for 318 clocks and watch the receiver.
   - A burst is detected (`oob_det`) one clock after `rx_p` falls following at least 64 consecutive 1s.
   - If a burst was seen in the window, or ends on its last clock, go to CI_BURST. Otherwise go back to CR_BURST.
3. **CI_BURST:** drive 1 for 106 clocks.
4. **CI_IDLE:** drive 0 for 318 clocks.
   - A detected burst goes to DONE and sets `phy_ready` = 1.
   - Otherwise go back to CI_BURST.
5. **DONE:** stays until reset.

In loopback the core hears its own bursts, so it reaches `phy_ready` after two burst/idle pairs (848 clocks). While `phy_ready` = 0 the link layer is held in ALIGN / IDLE.

### 3.2 Transmit

- Each 32-bit dword is shifted out MSB first, one bit per bit tick. A bit tick happens every BIT_CLKS clocks.
- Between frames the transmitter sends ALIGN (0x7B4A4ABC). At the end of each ALIGN dword a pending request is loaded. A read response the target owes has priority over the sequencer's request.
- **Frame:** SOF (0xA5A50001), HDR, payload (when len = 1), CRC, EOF (0xA5A50002). HDR is `{len[31:24], type[23:16], dst[15:8], src[7:0]}`.
- **Frames the core sends:**

  | Frame | len | type | dst | src | Payload |
  |---|---|---|---|---|---|
  | write | 1 | 0x01 | register | 0x01 | the value |
  | read request | 0 | 0x02 | register | 0x01 | none |
  | read response | 1 | 0x83 | the requester's src | the register number | the value |

- **CRC:** Ethernet FCS style, polynomial 0x04C11DB7 used reflected (0xEDB88320), initial value all ones, LSB first within each byte, bytes MSB first. It covers HDR and the payload and is sent inverted (final XOR all ones).

### 3.3 Receive and target

- In IDLE the receiver compares the last 32 received bits with SOF on every bit tick (bit alignment), then takes whole dwords.
- **HDR checks:**
  - len > 16 is a protocol error (`irq`), and the frame is dropped.
  - len = 0 skips the payload.
  - Otherwise len payload dwords follow. Only dword 0 is kept; the rest are CRC-checked only.
- **CRC:** a mismatch pulses `irq` and the frame is discarded. The EOF dword is still consumed.
- **At EOF** of a CRC-good frame (EOF must be 0xA5A50002, otherwise protocol error):

  | Type | Condition | Action | Error case |
  |---|---|---|---|
  | write (0x01) | len >= 1 and dst < 16 | `regs[dst]` = payload 0 | otherwise protocol error |
  | read request (0x02) | dst < 16 | queue a read response to `src` with `regs[dst]` | otherwise protocol error |
  | read response (0x83) | len >= 1 | delivered to the sequencer | otherwise protocol error |
  | any other type | | | protocol error |

- A frame takes effect only at its EOF.

### 3.4 Initiator sequencer

1. **INIT:** wait 64 clocks after `phy_ready`.
2. **WR:** request a write of `sq_wdata` to register `sq_addr`.
3. **WR_WAIT:** when the transmitter takes the request, wait for the target to apply a write.
   - The looped-back write sets `wr_evt`.
   - On timeout, `irq` pulses.
   - Either way, continue to RD.
4. **RD:** request a read.
5. **RD_WAIT:** wait for a read response.
   - If its value equals `sq_wdata` and its src equals `{0, sq_addr}`, `ok_cnt` + 1. Otherwise `mm_cnt` + 1.
   - On timeout, `irq` pulses and neither counter changes.
   - Then `sq_wdata` = xorshift32(`sq_wdata`) (x ^= x << 13; x ^= x >> 17; x ^= x << 5) and `sq_addr` + 1.
6. **GAP:** 32 clocks, then the next WR.

The timeout is 512 * BIT_CLKS clocks from the request being taken. Any write or read response received while waiting counts, including one injected by another device.

### 3.5 Bit rate

Every bit of the transmitter and receiver advances on the bit tick (every BIT_CLKS clocks). The OOB timing, the init and gap counters run on raw clocks; the timeout scales with BIT_CLKS.

### 3.6 Reset

`tx_p` = 0 (`tx_n` = 1) while `rst_n` is low. After reset: OOB in CR_BURST, no `irq`, `regs` = 0, counters 0, `sq_wdata` = 0x5A5AC3C3, `sq_addr` = 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `BIT_CLKS` | 1 | >= 1 | clocks per serial bit; also scales the link timeout |

## 5. Errors and corner cases

`irq` sources:
- a CRC error;
- len > 16;
- a bad EOF;
- an unknown type;
- dst >= 16 on a write or read request;
- a write or read response with len = 0;
- a sequencer timeout.

Other behaviour:
- A bit error in the SOF makes the receiver miss the frame. A bit error in the header length may make it read too many or too few dwords; the frame then fails its CRC or EOF check.
- A read response that arrives while a frame is on the wire is queued and sent after that frame.
- Only one response can be queued. A second read request before the first response is sent overwrites it.
- `ok_cnt` / `mm_cnt` wrap at 256.
- A reset in the middle of a frame restarts OOB.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "tx_n is ~tx_p" | `tx_n` = !`tx_p` always | §1 |
| "DUT frame CRC" | every transmitted frame carries the right CRC | §3.2 |
| "DUT frame EOF" | every transmitted frame ends with EOF | §3.2 |
| "DUT frame source" | source byte bits 7:4 are 0 | §3.2 |
| "reset state" | in reset: `tx_p` = 0, `tx_n` = 1, no irq, not ready | §3.6 |
| "no irq during OOB" | OOB retries raise no irq | §3.1 |
| "clean: no mismatch / irq" | on a clean loopback every read-back verifies | §3.4 |
| "frames decoded" | the initiator keeps sending frames | §3.4 |
| "injected write" | a write frame from any source updates `regs` | §3.3 |
| "read response to the requester" | a read request is answered to its source with the register value | §3.3 |
| "16-dword write" | len 16 is accepted; only payload dword 0 is used | §3.3 |
| "mismatches counted" | a wrong value or source counts in `mm_cnt` | §3.4 |
| "write timeout irq" | no write echo within the timeout: irq | §3.4 |
| "read timeout irq" | no read response within the timeout: irq | §3.4 |
| "half-rate initiator verified" | BIT_CLKS = 2 works end to end | §3.5 |
| "half-rate initiator recovered" | BIT_CLKS = 2 recovers after errors | §3.5 |
| a_reset_line | in reset: `tx_p` = 0, `tx_n` = 1, no irq, `phy_ready` = 0 | §3.6 |
| a_tx_p | `tx_p` equals the reference model's line bit every clock | §3.1, §3.2 |
| a_tx_n | `tx_n` = !`tx_p` | §1 |
| a_irq | `irq` as the model | §5 |
| a_phy_ready | `phy_ready` as the model's OOB | §3.1 |
| a_counters | `ok_cnt` / `mm_cnt` as the model | §3.4 |
