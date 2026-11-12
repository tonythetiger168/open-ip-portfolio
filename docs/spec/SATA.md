# SATA: design specification

SATA host with OOB bring-up, a link layer with frame handshakes, and a built-in DMA command sequencer. It is scaled to one line bit per clock with no 8b/10b coding. There is no command bus: the core runs IDENTIFY, then WRITE / READ verify pairs on its own, and its behaviour is visible on the line and through `irq`. Core `SATA_top` (`rtl/SATA_top.sv`), testbench `tb/SATA_tb.sv`, checker `tb/cov/SATA_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock and line bit clock (one bit per clock) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `tx_n` | output | 1 | differential line, = `tx_on` && !bit; 0 with `tx_p` = electrical idle | high | comb | 0 |
| `tx_p` | output | 1 | differential line, = `tx_on` && bit | high | comb | 0 |
| `rx_n` | input | 1 | differential line in: a clock carries signal when `rx_p` != `rx_n` | - | `clk` | - |
| `rx_p` | input | 1 | differential line in; data bits are taken from `rx_p` | - | `clk` | - |
| `refclk` | input | 1 | unused (interface compatibility) | - | - | - |
| `irq` | output | 1 | one-clock pulse (OR of registered events): link loss, illegal primitive, receive frame error, transmit failure, unexpected / malformed FIS, status error, read mismatch, command timeout | high | `clk` | 0 |

### Internal signals used by the verification

The checker uses ports only. The FSM coverage binds these state registers.

| Signal | Width | Meaning |
|---|---|---|
| `lk` | 3 | PHY bring-up (FSM coverage): 0 RESET (COMRESET), 1 WINIT, 2 WAKE (COMWAKE), 3 WWAKE, 4 ALIGN, 5 READY |
| `rxs` | 2 | link receive (FSM coverage): 0 IDLE, 1 RDYS (R_RDY sent), 2 DATA, 3 STAT (R_OK / R_ERR) |
| `txs` | 3 | link transmit (FSM coverage): 0 IDLE, 1 XRDY, 2 SOF, 3 DATA, 4 CRC, 5 EOF, 6 WTRM |
| `q` | 4 | command sequencer (FSM coverage): 0 WAIT, 1 ID, 2 ID_DAT, 3 ID_STS, 4 FILL, 5 WR, 6 WR_ACT, 7 WR_DAT, 8 WR_STS, 9 RD, 10 RD_DAT, 11 RD_STS |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SATA.md`](../ip/SATA.md) (source: `scripts/apb/specs/SATA.json`); do not edit by hand.

`SATA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_n`, `tx_p`, `rx_n`, `rx_p`, `refclk`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5354 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | link loss, illegal primitive, receive frame error (CRC, overflow, abort, handshake timeout), transmit failure (resends exhausted, timeout), unexpected or malformed FIS, error status, read data mismatch, or a command response timeout |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53540200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Line and OOB

- **Line levels:** `tx_p` = `tx_n` = 0 is electrical idle. A data bit b is driven as `tx_p` = b and `tx_n` = !b.
- **OOB pattern:** 4 times (a gap of electrical idle, then a burst of 16 clocks).
  - The gap is 48 clocks for COMRESET and 16 clocks for COMWAKE.
  - A burst carries 0101... (bit = burst counter bit 0, so it starts with 0).
- **OOB detector:**
  - It measures runs of signal and of idle (saturating at 63).
  - A burst counts only if it is 12..20 clocks long.
  - A gap after a legal burst is classified as INIT (40..56 clocks) or WAKE (12..20 clocks).
  - Three equal gaps in a row detect COMINIT or COMWAKE. Any other run resets the count.
- **Dwords:** dwords are sent LSB first.

### 3.2 PHY bring-up

1. **RESET:** send COMRESET.
2. **WINIT:** wait for COMINIT, then go to WAKE.
3. **WAKE:** send COMWAKE.
4. **WWAKE:** wait for COMWAKE, then go to ALIGN.
5. **ALIGN:** send ALIGNp (0x7B4A4ABC) continuously.
   - The receiver aligns on the first ALIGNp it sees, bit by bit.
   - Two ALIGNp dwords in a row move to READY.
6. **READY:** the link layer runs.

Each wait (WINIT, WWAKE, ALIGN) times out after 1024 clocks and restarts at RESET. In READY, a clock of electrical idle on the receive side pulses `irq` (link loss) and restarts at RESET. No dword completes on an idle clock.

### 3.3 Link layer

Primitives are dword values:

| Primitive | Value |
|---|---|
| SYNC | 0xB5B5957C |
| X_RDY | 0x5757B57C |
| R_RDY | 0x4A4A957C |
| R_IP | 0x5555B57C |
| R_OK | 0x3535B57C |
| R_ERR | 0x5656B57C |
| SOF | 0x3737B57C |
| EOF | 0xD5D5B57C |
| WTRM | 0x5858B57C |

A received ALIGNp is dropped anywhere. Each transmitted dword is chosen at the dword boundary.

- **Idle:** SYNC. The transmitter leaves idle only at a dword boundary, so at least one SYNC goes out between two frames.
- **Transmit:**
  1. Send X_RDY until R_RDY arrives.
  2. Send SOF, the FIS dwords, ~CRC and EOF.
  3. Send WTRM until R_OK (done) or R_ERR.
  - R_ERR resends the frame, at most 2 resends; the third R_ERR is a failure.
  - If the device raises X_RDY while the host sends X_RDY (a collision), the host backs off and receives first.
  - The X_RDY and WTRM waits time out after 64 dwords, which is a failure.
  - A failure pulses `irq`.
- **Receive:**
  1. X_RDY in idle: send R_RDY until SOF. SYNC withdraws; 64 dwords without SOF is a timeout with `irq`.
  2. Send R_IP during the frame.
  3. At EOF send R_OK, or R_ERR, until SYNC; a 64-dword timeout here pulses `irq`. The frame is good when it has at least 2 dwords, at most 9 FIS dwords plus CRC, and the last dword equals ~CRC of the dwords before it. A bad frame pulses `irq`.
  - SYNC inside a frame aborts it with `irq`.
  - An unknown primitive in idle pulses `irq`.
- **CRC32:** polynomial 0x04C11DB7 used reflected (0xEDB88320), initial value all ones, one dword per step LSB first, complemented on the wire.

### 3.4 FIS formats

| FIS | Dwords | Content |
|---|---|---|
| Register H2D (0x27) | 5 | dword 0 `{00, command, 0x80, 0x27}`; dword 1 `{0x40, LBA}` (LBA in bits 5:0); dword 3 = 1 (one sector); others 0 |
| Data (0x46) | 9 | dword 0 = 0x46, then 8 data dwords |
| Register D2H (0x34) | 5 | status OK when bit 16 (ERR) = 0 and bits 31:24 (error) = 0 |
| DMA Activate (0x39) | 1 | |

### 3.5 Command sequencer

1. **WAIT, then IDENTIFY DEVICE** (0xEC): send the command, then expect a Data FIS with max LBA = dword 1 bits 5:0, then a good D2H. Any other answer or a timeout pulses `irq` and restarts IDENTIFY. A transmit failure retries silently.
2. **FILL:** generate 8 data dwords with xorshift32 (seed 0x2545F491; x ^= x << 13; x ^= x >> 17; x ^= x << 5).
3. **WRITE DMA EXT** (0x35) to the current LBA. Expect DMA Activate, send the Data FIS, then expect a good D2H.
4. **READ DMA EXT** (0x25) of the same LBA. Expect a Data FIS, which is compared with the written data (a mismatch pulses `irq`), then a good D2H.
5. Move to the next LBA, wrapping to 0 after max LBA, and go back to FILL.

The response timeout is 4096 clocks after a FIS is sent. An error D2H, a wrong FIS or a timeout pulses `irq` and moves to the next LBA. So does a transmit failure, but without a sequencer event (the link event has already pulsed `irq`). A received FIS while the sequencer expects none pulses `irq`. Leaving READY returns the sequencer to WAIT, which starts again with IDENTIFY. The data generator keeps its state, and the LBA restarts at 0 after the IDENTIFY.

### 3.6 Reset

`tx_p` = `tx_n` = 0 in reset. After reset the core starts COMRESET with a gap, and `irq` = 0.

## 4. Parameters

None.

## 5. Errors and corner cases

`irq` sources:
- link loss;
- an illegal primitive in idle;
- a receive CRC error, an overflow (more than 9 FIS dwords), an abort or a handshake timeout;
- a transmit failure (resends exhausted or a timeout);
- an unexpected or malformed FIS;
- a D2H status error;
- a read data mismatch;
- a command timeout.

Other behaviour:
- Several sources in the same clock give one pulse.
- A D2H with ERR set ends the command early.
- max LBA 0 makes every command use LBA 0.
- Only the IDENTIFY answer sets max LBA, and it is limited to 6 bits.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "unexpected FIS from host" | the host sends only the FIS the command flow allows | §3.5 |
| "host stopped issuing commands" | the sequencer keeps running write / read pairs | §3.5 |
| "write dword" | the Data FIS of a WRITE carries the xorshift32 data | §3.5 |
| "reset state" | line idle and no irq in reset | §3.6 |
| "first command is not IDENTIFY" | IDENTIFY DEVICE first after READY | §3.5 |
| "expected WRITE lba" | WRITE DMA EXT to the next LBA (wrapping after max) | §3.5 |
| "expected READ lba" | READ DMA EXT of the LBA just written | §3.5 |
| "link loss irq" | electrical idle in READY: irq and bring-up restart | §3.2 |
| "IDENTIFY retries" | a failed IDENTIFY is retried | §3.5 |
| "IDENTIFY faults" | bad IDENTIFY responses pulse irq | §3.5, §5 |
| "max LBA 0" | max LBA 0: every command uses LBA 0 | §3.5 |
| a_reset_outputs | in reset: `tx_p` = `tx_n` = 0, no irq | §3.6 |
| a_tx_p | `tx_p` equals the reference model (OOB, primitives, frames, CRC, sequencer) every clock | §3 |
| a_tx_n | `tx_n` equals the model | §3 |
| a_irq | `irq` equals the model's events | §5 |
| a_idle_is_both_low | both lines low only when the model is in electrical idle | §3.1 |
