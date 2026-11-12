<!-- SPDX-License-Identifier: Apache-2.0 -->
# JESD204C: design specification

A JESD204C-style 64b/66b link layer for one lane: self-synchronous scrambling, the sync header
stream with CRC-12 and a command channel, multiblock and extended multiblock alignment. Not
implemented: multiple lanes, the transport layer, SYSREF / LEMC alignment and deterministic
latency, the CRC-3 and FEC sync header modes, pilot bits, the 64b/80b mode. The sync header layout
follows the CRC-12 mode as read from the standard, not checked against a compliant device. Core
`JESD204C_top` (`rtl/JESD204C_top.sv`), testbench `tb/JESD204C_tb.sv` (two ends with a
corrupting channel), checker `tb/cov/JESD204C_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; `tx_p` and the receive
outputs are registers.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one line bit per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `tx_p` | output | 1 | transmit line bit | - | `clk` | 0 |
| `rx_p` | input | 1 | receive line bit | - | `clk` | - |
| `cfg_e` | input | 4 | multiblocks per extended multiblock - 1 (E - 1) | - | static | - |
| `tx_valid` | input | 1 | a block payload is offered | high | `clk` | - |
| `tx_ready` | output | 1 | `tx_valid` in the clock a block's payload is taken; combinational | high | comb | 0 |
| `tx_data` | input | 64 | block payload, bit 0 sent first | - | `clk` | - |
| `tx_cmd` | input | 7 | command channel value, sampled at each multiblock start | - | `clk` | - |
| `tx_mb_start` | output | 1 | one-clock pulse: a multiblock starts (its first block was taken) | high | `clk` | 0 |
| `tx_underrun` | output | 1 | one-clock pulse: a block was sent with zeros (no `tx_valid`) | high | `clk` | 0 |
| `rx_valid` | output | 1 | one-clock pulse: a received block (with `emb_lock`) | high | `clk` | 0 |
| `rx_data` | output | 64 | received block payload, descrambled; holds | - | `clk` | 0 |
| `rx_mb_start` | output | 1 | with `rx_valid`: block 0 of a multiblock | high | `clk` | 0 |
| `rx_emb_start` | output | 1 | with `rx_valid`: block 0 of an extended multiblock | high | `clk` | 0 |
| `rx_mb_valid` | output | 1 | one-clock pulse at each multiblock end (with `emb_lock`) | high | `clk` | 0 |
| `rx_cmd` | output | 7 | command channel of that multiblock; holds | - | `clk` | 0 |
| `rx_crc_err` | output | 1 | its CRC field does not match the previous multiblock; holds | high | `clk` | 0 |
| `sh_lock` | output | 1 | sync header lock; combinational from the state | high | comb | 0 |
| `emb_lock` | output | 1 | extended multiblock lock; combinational from the state | high | comb | 0 |
| `err_sh` | output | 1 | one-clock pulse: an invalid sync header while locked | high | `clk` | 0 |
| `err_emb` | output | 1 | one-clock pulse: a multiblock / extended multiblock alignment error | high | `clk` | 0 |

### Internal signals used by the verification

The FSM coverage collector (`tb/cov/JESD204C_fsm_cov.sv`) binds these by name.

| Signal | Width | Meaning |
|---|---|---|
| `ss` | 2 | sync header state: 0 HUNT, 1 TEST, 2 LOCK |
| `es` | 2 | multiblock state: 0 INIT, 1 MB (aligned, waiting for an EoEMB), 2 LOCK |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/JESD204C.md`](../ip/JESD204C.md) (source: `scripts/apb/specs/JESD204C.json`); do not edit by hand.

`JESD204C_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_p`, `rx_p`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4A430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000000 | Extended multiblock length (both ends alike) |
| 0x018 | CMD | RW | 0x00000000 | Command channel |
| 0x01C | TX0 | RW | 0x00000000 | Transmit block payload (TX0 = bits 31:0, TX1 = bits 63:32; writing TX1 commits it); one block goes out every 66 PCLK, a block without data is sent as zeros (TX_UNDERRUN) |
| 0x020 | TX1 | RW | 0x00000000 | Transmit block payload (TX0 = bits 31:0, TX1 = bits 63:32; writing TX1 commits it); one block goes out every 66 PCLK, a block without data is sent as zeros (TX_UNDERRUN) |
| 0x024 | RX0 | RO (pop) | 0x00000000 | Received block (RX0 = bits 31:0, RX1 = bits 63:32, RX2 = start flags; reading RX2 frees it); one arrives every 66 PCLK while emb_lock |
| 0x028 | RX1 | RO (pop) | 0x00000000 | Received block (RX0 = bits 31:0, RX1 = bits 63:32, RX2 = start flags; reading RX2 frees it); one arrives every 66 PCLK while emb_lock |
| 0x02C | RX2 | RO (pop) | 0x00000000 | Received block (RX0 = bits 31:0, RX1 = bits 63:32, RX2 = start flags; reading RX2 frees it); one arrives every 66 PCLK while emb_lock |
| 0x030 | MB | RO (pop) | 0x00000000 | Multiblock received (with emb_lock); reading MB frees it |
| 0x034 | STATUS | RO | core | Receive alignment |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4A43 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 9:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 9:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 2:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 3:0 | `cfg_e` | RW | 0x0 | multiblocks per extended multiblock - 1 |
| CMD | 6:0 | `tx_cmd` | RW | 0x0 | command sent in each multiblock (sampled as the multiblock starts: IRQ TX_MB) |
| TX0 | 31:0 | `tx_data[31:0]` | RW | 0x0 | payload |
| TX1 | 31:0 | `tx_data[63:32]` | RW | 0x0 | payload |
| RX0 | 31:0 | `rx_data[31:0]` | RO (pop) | 0x0 | payload |
| RX1 | 31:0 | `rx_data[63:32]` | RO (pop) | 0x0 | payload |
| RX2 | 0 | `rx_mb_start` | RO (pop) | 0x0 | first block of a multiblock |
| RX2 | 1 | `rx_emb_start` | RO (pop) | 0x0 | first block of an extended multiblock |
| MB | 6:0 | `rx_cmd` | RO (pop) | 0x0 | its command |
| MB | 7 | `rx_crc_err` | RO (pop) | 0x0 | its CRC field did not match the previous multiblock |
| STATUS | 0 | `sh_lock` | RO | core | sync header lock |
| STATUS | 1 | `emb_lock` | RO | core | extended multiblock lock (blocks are delivered) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_MB | a transmit multiblock started (CMD sampled) |
| 1 | TX_UNDERRUN | a block went out as zeros: TX was empty |
| 2 | ERR_SH | an invalid sync header while locked |
| 3 | ERR_EMB | a multiblock or extended multiblock alignment error |
| 4 | TX_DONE | TX beat accepted by the core |
| 5 | TX_OVF | write to TX while full (dropped) |
| 6 | RX_AVAIL | RX captured a beat |
| 7 | RX_OVF | beat dropped, RX was full |
| 8 | MB_AVAIL | MB captured a beat |
| 9 | MB_OVF | beat dropped, MB was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |
| 2 | MB_AVAIL | MB holds an unread beat |

### Streams

* **TX** feeds `tx_data`/`tx_valid`. Writing TX1 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_mb_start`, `rx_emb_start` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX2 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.
* **MB** captures `rx_cmd`, `rx_crc_err` when `rx_mb_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ MB_AVAIL. Reading MB pops it. A beat that arrives while the register is full is dropped and sets MB_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4A430200.
2. Write 0x3FF to IRQ_STATUS (0x004) to clear any stale bits (TX_MB, TX_UNDERRUN may be set as soon as reset ends).
3. Configure the core: write CFG (0x014), CMD (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3FF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x01C) then TX1 (0x020). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x024) then RX1 (0x028) then RX2 (0x02C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 6) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
7. To receive on MB: wait for IRQ MB_AVAIL or FLAGS.MB_AVAIL (bit 2), then read MB (0x030). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.MB_AVAIL (bit 8) to clear it. Read each beat before the next arrives, or it is dropped and MB_OVF is set.
8. Read STATUS (0x034) for the core's live `sh_lock`, `emb_lock`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Block and scrambling

A block is 66 line bits: a 2-bit sync header (first bit = inverse of the second; the second is
the sync header stream bit; 00 and 11 are invalid) and 64 payload bits, bit 0 first. Payload bits
are scrambled by s[n] = d[n] XOR s[n-39] XOR s[n-58] (1 + x^39 + x^58, on the scrambled bit
stream, continuous across blocks); headers are not scrambled. The receiver descrambles with the
same taps on the received bits.

### 3.2 Sync header stream

A multiblock is 32 blocks; its 32 stream bits, block 0 first:

| Blocks | Bits |
|---|---|
| 0..15 | C11 C10 C9 1, C8 C7 C6 1, C5 C4 C3 1, C2 C1 C0 1 |
| 16..31 | M6 M5 M4 1, M3 M2 M1 1, M0 EoEMB 1 0, 0 0 0 1 |

C = CRC-12 (x^12 + x^11 + x^3 + x^2 + x + 1, init 0, payload bit 0 first, unscrambled) of the
previous multiblock's 2048 payload bits (0 in the first multiblock after reset); M = command;
EoEMB = 1 in the last multiblock of each extended multiblock of `cfg_e` + 1. The pattern 00001
ends a multiblock and occurs nowhere else.

### 3.3 Transmit

The transmitter runs continuously, 66 clocks per block. In the clock that starts a block:
`tx_ready` = `tx_valid` and the payload is taken (`tx_data`, or zeros with `tx_underrun`
pulsing); at block 0 of a multiblock `tx_cmd` is sampled and `tx_mb_start` pulses. The first
header bit is on `tx_p` from the next clock, then the second, then the 64 scrambled payload bits.

### 3.4 Receive: sync header lock

The receiver splits the line into 66-bit slots. At each header:

* HUNT: valid -> TEST (count 1); invalid -> slide by one bit (the next bit is taken as the
  second header bit).
* TEST: invalid -> HUNT and slide; the 64th valid header in a row -> LOCK.
* LOCK: headers are counted in windows of 64; each invalid one pulses `err_sh`; the 16th invalid
  header within a window -> HUNT (the 64th header of a window is not counted toward the next).

### 3.5 Receive: multiblock lock and output

At each block end (only while `sh_lock`; losing it returns to INIT):

* INIT: 00001 at the end of the stream bits -> MB, block index 0.
* MB / LOCK at block 31: no 00001 -> `err_emb`, INIT. With 00001: in MB, EoEMB = 1 -> LOCK
  (extended multiblock index 0). In LOCK: `rx_mb_valid` with `rx_cmd` = M and `rx_crc_err` = (C
  != the CRC of the previous multiblock); EoEMB not matching the expected position (index =
  `cfg_e`) -> `err_emb` and MB.
* MB / LOCK at another block: 00001 -> `err_emb`, MB realigned to this point.

With `emb_lock`, every block goes out on `rx_data` with `rx_valid` (one clock) and
`rx_mb_start` / `rx_emb_start`, starting with the block after the multiblock that gave the lock.

### 3.6 Reset

While `rst_n` is low: `tx_p` 0, counters and scramblers 0, both locks off, all pulses 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| bit slip on the line | headers become invalid; 16 in a window drop `sh_lock`, then HUNT realigns |
| fewer than 16 invalid headers in a window | `err_sh` pulses, lock kept |
| payload bit errors | descrambler spreads them (3 bits); CRC error at the next multiblock |
| dropped or repeated block | `err_emb`, realign |
| `cfg_e` differs between the ends | `err_emb` at each EoEMB mismatch |
| no `tx_valid` | zero payload, `tx_underrun` |
| reset | locks lost, line 0 |

## 6. TB check map

Messages are printed by `tb/JESD204C_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the
bound checker `tb/cov/JESD204C_sva.sv`. Two ends A and B are cross-connected; the A -> B line runs
through a TB channel that adds or drops bits, drops or repeats blocks and flips bits. Scoreboards
check that every block after a lock is the next one sent, every command, and no CRC error on a
clean line; alignment is tested at every bit offset, at and below the unlock threshold, and with
`cfg_e` differing between the ends.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "end" | per end: first block after lock was sent, blocks in order with `rx_mb_start` / `rx_emb_start`, commands, no CRC error on a clean line, lock reached | §3.3..§3.5 |
| "lock lost at cfg_e" | lock holds for every `cfg_e` | §3.5 |
| "lock lost over payload errors" | payload errors do not drop lock | §3.5 |
| "lock lost below the error threshold" | fewer than 16 invalid headers keep `sh_lock` | §3.4 |
| "unlocked before the 16th header error" | unlock exactly at the 16th | §3.4 |
| "still locked after 16 header errors" | unlock at the 16th | §3.4 |
| "no clean multiblock seen" | some multiblock passes the CRC | §3.2, §3.5 |
| a_tx_bit | `tx_p` exactly as the checker's line model | §3.1..§3.3 |
| a_tx_ready | `tx_ready` as the model | §3.3 |
| a_tx_events | `tx_mb_start` / `tx_underrun` as the model | §3.3 |
| a_lock | `sh_lock` / `emb_lock` as the model | §3.4, §3.5 |
| a_errors | `err_sh` / `err_emb` as the model | §3.4, §3.5 |
| a_rx_valid | `rx_valid` / `rx_mb_valid` as the model | §3.5 |
| a_rx_data | block data and start flags as the model | §3.5 |
| a_rx_mb | `rx_cmd` / `rx_crc_err` as the model | §3.5 |
| a_reset | in reset: line 0, no locks, no pulses | §3.6 |
