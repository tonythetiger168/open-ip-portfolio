# SAS_4__Serial_Attached_SCSI_: design specification

Simplified SAS-4 (24G) style initiator with a 128b/150b-style block code (here 130-bit blocks: a 2-bit sync header plus 128 bits), a self-synchronous scrambler and an OOB handshake. It has a 16-word target register file and a built-in initiator sequencer that writes and reads back over a reflecting link. This is not the full SPL specification; the scrambler polynomial is simplified. Core `SAS_4__Serial_Attached_SCSI__top` (`rtl/SAS_4__Serial_Attached_SCSI__top.sv`), testbench `tb/SAS_4__Serial_Attached_SCSI__tb.sv`, checker `tb/cov/SAS_4__Serial_Attached_SCSI__sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock and line bit clock (one bit per clock) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `tx_p` | output | 1 | serial line; 0 in reset; constant 1 during OOB bursts; block-coded bits after `link_up` | high | comb | 0 |
| `tx_n` | output | 1 | = !`tx_p` | - | comb | 1 |
| `rx_p` | input | 1 | serial line in, one bit per clock | high | `clk` | - |
| `rx_n` | input | 1 | unused (single-ended model) | - | `clk` | - |
| `link_up` | output | 1 | OOB finished (PHY READY); dropped by loss of sync | high | `clk` | 0 |
| `irq` | output | 1 | one-clock pulse: CRC error, protocol violation, sequencer timeout, read-verify mismatch or loss of sync | high | `clk` | 0 |

The checker uses ports only; it models the whole core from the line.

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SAS_4__Serial_Attached_SCSI_.md`](../ip/SAS_4__Serial_Attached_SCSI_.md) (source: `scripts/apb/specs/SAS_4__Serial_Attached_SCSI_.json`); do not edit by hand.

`SAS_4__Serial_Attached_SCSI__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_p`, `tx_n`, `rx_p`, `rx_n`, `link_up`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53340200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Link state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5334 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `link_up` | RO | core | OOB done and the link is up (cleared by a loss of sync, which restarts OOB) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | CRC error, protocol violation (control block out of place, missing EOF, length above 8, bad register address, unknown type), sequencer timeout, read-verify mismatch, or loss of sync |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53340200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `link_up`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 OOB

1. **CR_BURST:** drive `tx_p` = 1 for 106 clocks.
2. **CR_IDLE:** drive 0 for 318 clocks.
   - A burst is detected one clock after `rx_p` falls after a run of at least 64 ones.
   - If a burst was seen in the window, go to CI_BURST. Otherwise go back to CR_BURST.
3. **CI_BURST:** drive 1 for 106 clocks.
4. **CI_IDLE:** drive 0 for 318 clocks.
   - If a burst was seen, go to DONE and set `link_up` = 1.
   - Otherwise go back to CI_BURST.
5. **DONE:** `link_up` stays 1 until loss of sync.

A loss of sync (§3.4) restarts OOB from CR_BURST with `link_up` = 0. While `link_up` = 0 the transmitter, receiver and sequencer are held in their start states, and the scrambler and descrambler are reseeded.

### 3.2 Transmit block code

- **Block:** each block is 130 bits, sent MSB first at one bit per clock.
  - 2 sync header bits, unscrambled: 01 for a data block, 10 for a control block.
  - 128 payload bits.
- **Scrambler:** the payload bits are scrambled by a self-synchronous scrambler x^16 + x^5 + 1.
  - Output bit: o = d ^ s[15] ^ s[4]; the state shifts left with o (s = {s[14:0], o}).
  - The seed is 0xACE1, loaded when the link comes up.
  - The scrambler runs continuously over every payload, idle blocks included.
- **Control blocks:** the code is in payload bits 127:96, the rest is zero. IDLE = 0xA5C30000, SOF = 0xA5C30001, EOF = 0xA5C30002.
- **Between frames:** IDLE blocks are sent. At the end of each IDLE block, a queued read response (priority) or a sequencer request starts a frame.
- **Frame:** SOF (control), header, payload, CRC, EOF (control).
  - **Header block** (data): four dwords `{type, dst, src, len}`, each value in bits 7:0 of its dword with zeros above.
  - **Payload block** (data): only for len = 1. The value is in dword 0, and dwords 1..3 are 0.
  - **CRC block** (data): dword 0 = ~CRC, and the rest 0.
- **CRC:** Ethernet FCS style, polynomial 0x04C11DB7 used reflected, initial value all ones, LSB first per byte and bytes MSB first. It covers the header block and the zero-padded payload blocks, all 4 dwords each.
- **Frames sent:**

  | Frame | type | dst | src | len |
  |---|---|---|---|---|
  | write | 0x01 | register | 1 | 1 |
  | read request | 0x02 | register | 1 | 0 |
  | read response | 0x83 | requester's src | register number | 1 |

### 3.3 Receive

- **Descrambler:** a self-synchronous descrambler, d = rx ^ s[15] ^ s[4], with the state shifting in the line bit.
- **Hunting:**
  - An invalid sync header (00 or 11) slips one bit and clears the hunt counters.
  - The receiver locks after 4 consecutive valid sync headers plus one descrambled legal control code (IDLE, SOF or EOF) seen while hunting.
- **Frame, once locked:**
  - SOF: a SOF control block starts a frame.
  - Header: must be a data block with len (bits 7:0 of dword 3) <= 8, otherwise a protocol error. The fields are taken from bits 7:0 of each dword, and higher bits are ignored.
  - Payload: len 1..4 takes one data block, len 5..8 takes two. Only dword 0 of the first block is kept, and all payload dwords go into the CRC. A control block here is a protocol error.
  - CRC: a data block whose dword 0 must equal ~CRC. A control block is a protocol error, and a mismatch is a CRC error.
  - EOF: must be an EOF control block, otherwise a protocol error. Only here does a CRC-good frame take effect.
- **Frame effect at EOF:**

  | Type | Condition | Action | Error case |
  |---|---|---|---|
  | write | len >= 1 and dst < 16 | `regs[dst]` = payload 0 | otherwise protocol error |
  | read request | dst < 16 | queue a read response to src with `regs[dst]` | otherwise protocol error |
  | read response | len >= 1 | delivered to the sequencer | otherwise protocol error |
  | any other type | | | protocol error |

- One read response can wait for the transmitter, and a newer request replaces it.
- After any error the receiver returns to waiting for SOF.

### 3.4 Loss of sync

While locked, a block with an invalid sync header is dropped and alignment is kept. Eight consecutive invalid headers set `loss_sync` for one clock. On the next clock `link_up` = 0, `irq` = 1, and OOB restarts. Seven do not drop the link, and any valid header resets the count.

### 3.5 Initiator sequencer

1. **INIT:** wait until the receiver is locked, then 64 clocks.
2. **WR:** queue a write of `sq_wdata` to register `sq_addr`. When the transmitter takes it, go to WR_WAIT.
3. **WR_WAIT:** wait for a received write to register `sq_addr`. On a timeout, `irq` pulses. Either way, continue to RD.
4. **RD:** queue a read request. When the transmitter takes it, go to RD_WAIT.
5. **RD_WAIT:** wait for a read response with src = `sq_addr`.
   - A value other than `sq_wdata` pulses `irq` (mismatch).
   - A timeout also pulses `irq`.
   - Then `sq_wdata` = xorshift32(`sq_wdata`) (x ^= x << 13; x ^= x >> 17; x ^= x << 5) and `sq_addr` + 1.
6. **GAP:** 32 clocks, then the next WR.

The timeout is 4095 clocks. Events for other registers, such as a late frame of a timed-out transaction or a frame from another node, are ignored. After reset `sq_wdata` = 0x5A5A0001 and `sq_addr` = 0; neither is reset by a link drop.

### 3.6 irq

`irq` is registered: a one-clock pulse one clock after the cause. The causes are a CRC error, a protocol error, a sequencer timeout, a mismatch, or a loss of sync.

### 3.7 Reset

`tx_p` = 0 and `tx_n` = 1 while `rst_n` is low. After reset: `link_up` = 0, no `irq`, `regs` = 0 and OOB in CR_BURST.

## 4. Parameters

None.

## 5. Errors and corner cases

- A frame with len 2..8 is accepted by the receiver; the transmitter sends only len 0 and 1.
- A CRC error still consumes the EOF block, and the frame is discarded.
- The register file keeps its contents across a loss of sync (it is reset only by `rst_n`).
- A burst shorter than 64 clocks is not detected, so OOB keeps retrying.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "DUT header junk bits" | header dwords carry the field in bits 7:0 and zeros above | §3.2 |
| "DUT frame structure" | SOF, header, 0 or 1 payload block, CRC, EOF | §3.2 |
| "DUT payload padding" | payload dwords 1..3 are zero | §3.2 |
| "DUT frame CRC" | CRC block dword 0 is the right CRC, the rest zero | §3.2 |
| "DUT write header" | write: type 0x01, dst = register, src 1, len 1 | §3.2 |
| "DUT read request header" | read request: type 0x02, src 1, len 0 | §3.2 |
| "DUT read response header" | read response: type 0x83, dst = requester, src = register, len 1 | §3.2 |
| "read response reg" | the response carries the register value | §3.3 |
| "DUT frame type" | only the three frame types are sent | §3.2 |
| "DUT sync header" | sync headers 01 for data blocks, 10 for control blocks | §3.2 |
| "DUT idle block" | idle control blocks between frames | §3.2 |
| "DUT frame too long" | no frame longer than 5 blocks | §3.2 |
| "link did not come up" | OOB completes | §3.1 |
| "only" | the target answers every read request | §3.3 |
| "reset state" | outputs in reset | §3.7 |
| "OOB bursts" | burst count until link up | §3.1 |
| "irq during clean traffic" | no irq on a clean loopback | §3.5 |
| "peer read responses" | read requests from a peer are answered | §3.3 |
| "sequencer faults: missing irq" | timeouts and mismatches pulse irq | §3.5 |
| "7 bad headers dropped the link" | 7 bad sync headers keep the link | §3.4 |
| "loss of sync: no irq" | 8 bad sync headers: irq and link down | §3.4 |
| "OOB threshold: bursts" | a burst shorter than 64 clocks is not detected | §3.1 |
| "no sequencer traffic" | the sequencer runs after lock | §3.5 |
| a_reset_outputs | in reset: `tx_p` = 0, `tx_n` = 1, no `link_up`, no irq | §3.7 |
| a_tx_p | `tx_p` equals the reference model's line bit every clock (OOB, block code, scrambler, frames) | §3.1, §3.2 |
| a_tx_n | `tx_n` = !`tx_p` | §1 |
| a_link_up | `link_up` as the model | §3.1, §3.4 |
| a_irq | `irq` as the model | §5 |
| a_link_drop_irq | loss of sync: the next clock `link_up` = 0 and `irq` = 1 | §3.4 |
