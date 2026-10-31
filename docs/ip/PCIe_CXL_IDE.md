# PCIe / CXL Integrity and Data Encryption (IDE): AES-256-GCM protection of PCIe TLPs, CXL.io and CXL.cachemem flits over two IDE streams, key sets with sub-stream keys and IV invocation counters, MAC epochs

Protocol IP `PCIe_CXL_IDE`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `PCIe_CXL_IDE_top` (`rtl/PCIe_CXL_IDE_top.sv`) |
| Register interface | APB4 slave `PCIe_CXL_IDE_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x49440100 (code 0x4944, version 1.0) |
| Registers | 41 words, 0x000 to 0x0A0 |
| Interrupts | 11 sources into one level-high `irq` |
| Data streams | TX (to the core), TXO (from the core), RX (to the core), RXO (from the core) |
| Protocol pins | 2 pass-through |

## Overview

PCIe_CXL_IDE_top v1.0: Integrity and Data Encryption (IDE) for PCIe TLPs, CXL.io and CXL.cachemem, built on two AES_GCM_top engines (AES-256-GCM, one for transmit, one for receive). The block streams carry 128-bit blocks (byte 0 in bits 127:120) with a byte count; the link layer packs them into its own TLP / flit byte stream. The field layouts are ours (the PCIe 6.x / CXL 3.x specifications are member-only): they follow the public descriptions of IDE but are not claimed to be bit-compatible.

- Streams: NS IDE streams (0..NS-1). Each has an enable, an 8-bit Stream
ID, a type (0: PCIe / CXL.io TLPs, 1: CXL.cachemem flits) and the 32-bit
fixed field of its IVs. Per direction and stream there are two key sets
(K = 0 / 1) of three sub-stream keys (0 posted, 1 non-posted,
2 completion; cachemem streams use sub-stream 0 only), each with its own
IV invocation counter.
- Keys (IDE_KM style), commands with km_dir / km_sid / km_ks / km_sub:
km_prog loads the key port (or, km_sel = 1, the sideload port) into a
slot and sets its counter to 1; km_go makes a key set the active one of
a stream and the stream Secure (its sub-stream keys must be loaded);
km_stop clears a key set (keys, counters) and makes the stream Insecure
if that set was active; clr clears every key and stream and aborts both
directions. A key set cannot be reprogrammed while it is the active set
of a Secure stream.
- IV = {fixed field, 64-bit invocation counter}; each message takes the
counter of its slot and increments it; the all-ones value is never used
(exhausted: error, stream Insecure).
- TLP mode (stream type 0). Transmit input: the TLP header blocks
(tx_hdr = 1, all 16 bytes but the last), then the payload blocks (all
16 bytes but the last), tx_last on the last block; tx_ide selects
protection (stream tx_sid, sub-stream tx_sub), tx_ide = 0 passes the TLP
through unchanged. Output: the IDE prefix block (4 bytes, kind PFX), the
header blocks unchanged (HDR), the encrypted payload (DATA) and the
96-bit MAC (kind MAC, 12 bytes, last). GCM AAD = prefix || header, text
= payload, MAC = the first 12 bytes of the tag. Prefix (ours):
[31:24] 0x92, [23] M = 1, [22] K, [21:20] 0, [19:18] sub-stream,
[17:16] 0, [15:8] Stream ID, [7:0] 0.
- Cachemem mode (stream type 1, CXL.cachemem): one GCM message is a MAC
epoch of cm_agg + 1 flits (no AAD, every block 16 bytes, tx_last ends a
flit); the MAC block (txo_cm = 1) follows the last flit of the epoch.
An epoch is closed early (truncated, MAC sent at once) when another IDE
message must use the engine; bypass traffic passes while it is open.
- Receive input uses the transmit output format (rx_kind; rx_cm marks
cachemem flits of stream rx_sid and their MAC block). An IDE TLP is
found by its prefix (Stream ID lookup, K selects the key set and, if
the other set is loaded, switches to it), decrypted and checked; other
TLPs pass through. Output: header blocks, plaintext, then an END block
(kind END, last) whose rxo_bad says whether the MAC matched: the
plaintext must be held until then. Any error on an IDE message makes
the stream Insecure and ends what was output with END rxo_bad = 1.
- Transmit errors drop the message; if blocks were already sent it is
ended by a nullified MAC block (txo_bad = 1, 0 bytes).
- Error codes (tx_code / rx_code): 1 format, 2 stream not enabled /
Secure / of that type, 3 sub-stream key not loaded (a stream made
Secure as cachemem, then switched to TLPs), 4 counter exhausted,
5 too long for the GCM counters (LEN_W), 6 unknown Stream ID (receive),
7 MAC mismatch (receive). km_code: 1 bad stream / sub-stream, 2 key set
incomplete at km_go, 3 sideload key not valid, 4 key set in use.

Features:

- Integrity and Data Encryption for PCIe TLPs, CXL.io and CXL.cachemem: AES-256-GCM with 96-bit MACs, in the style of PCIe 6.x / CXL 3.x IDE (field layouts are this IP's own; the specifications are member-only).
- Two AES_GCM_top engines, one per direction, so transmit and receive run at the same time; one GCM message in flight per direction.
- NS IDE streams (2 in the wrapper), each with an enable, an 8-bit Stream ID, a type (TLP or cachemem) and the 32-bit IV fixed field. Per direction and stream two key sets (K = 0 / 1) of three sub-stream keys (posted, non-posted, completion), each with its own 64-bit IV invocation counter.
- IDE_KM-style key commands: program a slot (key from the KEY registers or the sideload port), make a key set active (stream Secure), stop a key set, clear all. A set in use cannot be reprogrammed; the receive side switches key sets on the prefix K bit.
- TLP mode: IDE prefix (Stream ID, K, sub-stream), header as AAD in the clear, encrypted payload, 96-bit MAC; receive finds the stream by Stream ID, decrypts and checks, other TLPs pass through. Cachemem mode: MAC epochs of 1..128 flits, truncated early when another IDE message needs the engine.
- Errors drop the message (nullified MAC on transmit, END with bad flag on receive), any receive error makes the stream Insecure; counter exhaustion and the GCM length limit are refused before a key stream could repeat.

Data is big-endian: byte 0 of a block is bits 127:120, which is TX3 / TXO3 / RX3 / RXO3 bits 31:24.
The receive plaintext comes out before the MAC check: the link layer must hold it until the END block and drop it when rxo_bad = 1.
Field layouts (prefix, MAC placement, epoch framing) follow the public descriptions of IDE but are not claimed to be bit-compatible with PCIe 6.x / CXL 3.x.
Each block takes five register writes or reads: for line-rate use, drive the core's stream ports from the link layer or a DMA.
Not implemented (public functional baseline): side-channel (power / EM) countermeasures, fault-injection detection, IDE_KM message transport (DOE / SPDM) and the CXL.cachemem containment / skid modes; key exchange is outside the IP.

## Files

| File | Content |
|---|---|
| `rtl/PCIe_CXL_IDE_top.sv` | protocol core |
| `rtl/PCIe_CXL_IDE_apb.sv` | APB4 register wrapper (generated) |
| `tb/PCIe_CXL_IDE_tb.sv` | core testbench |
| `tb/PCIe_CXL_IDE_apb_tb.sv`, `tb/apb/PCIe_CXL_IDE_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/PCIe_CXL_IDE_sva.sv`, `tb/cov/PCIe_CXL_IDE_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/PCIe_CXL_IDE.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`PCIe_CXL_IDE_apb` has the core's parameters and passes them to `PCIe_CXL_IDE_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NS` | int | `2` |
| `CTR_W` | int | `64` |
| `LEN_W` | int | `16` |

## Wrapper pins

Pins of `PCIe_CXL_IDE_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sl_key` | input | 256 | protocol pin, core port `sl_key` |
| `sl_valid` | input | 1 | protocol pin, core port `sl_valid` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `s_en` | input | 2 | CFG[1:0] |
| `s_cm` | input | 2 | CFG[3:2] |
| `s_id` | input | 16 | SID[15:0] |
| `s_ivfix` | input | 64 | IVFIX0[31:0], IVFIX1[31:0] |
| `cm_agg` | input | 7 | CFG[10:4] |
| `km_dir` | input | 1 | KM[0:0] |
| `km_sid` | input | 2 | KM[2:1] |
| `km_ks` | input | 1 | KM[3:3] |
| `km_sub` | input | 2 | KM[5:4] |
| `km_sel` | input | 1 | KM[6:6] |
| `km_key` | input | 256 | KEY0[31:0], KEY1[31:0], KEY2[31:0], KEY3[31:0], KEY4[31:0], KEY5[31:0], KEY6[31:0], KEY7[31:0] |
| `sl_key` | input | 256 | pin (pass-through) |
| `sl_valid` | input | 1 | pin (pass-through) |
| `km_prog` | input | 1 | CMD[0:0] |
| `km_go` | input | 1 | CMD[1:1] |
| `km_stop` | input | 1 | CMD[2:2] |
| `clr` | input | 1 | CMD[3:3] |
| `sec_tx` | output | 2 | STATUS[1:0] |
| `sec_rx` | output | 2 | STATUS[3:2] |
| `ks_tx` | output | 2 | STATUS[5:4] |
| `ks_rx` | output | 2 | STATUS[7:6] |
| `kv_tx` | output | 12 | KV[11:0] |
| `kv_rx` | output | 12 | KV[23:12] |
| `tx_busy` | output | 1 | STATUS[8:8] |
| `rx_busy` | output | 1 | STATUS[9:9] |
| `km_err` | output | 1 | IRQ_STATUS.KM_ERR |
| `km_code` | output | 3 | STATUS[12:10] |
| `tx_done` | output | 1 | IRQ_STATUS.TX_MSG |
| `tx_err` | output | 1 | IRQ_STATUS.TX_ERR |
| `tx_code` | output | 3 | STATUS[15:13] |
| `tx_esid` | output | 2 | STATUS[17:16] |
| `rx_done` | output | 1 | IRQ_STATUS.RX_MSG |
| `rx_err` | output | 1 | IRQ_STATUS.RX_ERR |
| `rx_code` | output | 3 | STATUS[20:18] |
| `rx_eid` | output | 8 | STATUS[28:21] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 128 | TX0[31:0], TX1[31:0], TX2[31:0], TX3[31:0] |
| `tx_bytes` | input | 5 | TX4[4:0] |
| `tx_hdr` | input | 1 | TX4[5:5] |
| `tx_last` | input | 1 | TX4[6:6] |
| `tx_ide` | input | 1 | TX4[7:7] |
| `tx_sid` | input | 2 | TX4[9:8] |
| `tx_sub` | input | 2 | TX4[11:10] |
| `txo_valid` | output | 1 | TXO capture |
| `txo_ready` | input | 1 | TXO handshake |
| `txo_data` | output | 128 | TXO0[31:0], TXO1[31:0], TXO2[31:0], TXO3[31:0] |
| `txo_bytes` | output | 5 | TXO4[4:0] |
| `txo_kind` | output | 2 | TXO4[6:5] |
| `txo_last` | output | 1 | TXO4[7:7] |
| `txo_bad` | output | 1 | TXO4[8:8] |
| `txo_cm` | output | 1 | TXO4[9:9] |
| `rx_valid` | input | 1 | RX commit / FLAGS |
| `rx_ready` | output | 1 | RX handshake |
| `rx_data` | input | 128 | RX0[31:0], RX1[31:0], RX2[31:0], RX3[31:0] |
| `rx_bytes` | input | 5 | RX4[4:0] |
| `rx_kind` | input | 2 | RX4[6:5] |
| `rx_last` | input | 1 | RX4[7:7] |
| `rx_cm` | input | 1 | RX4[8:8] |
| `rx_sid` | input | 2 | RX4[10:9] |
| `rxo_valid` | output | 1 | RXO capture |
| `rxo_ready` | input | 1 | RXO handshake |
| `rxo_data` | output | 128 | RXO0[31:0], RXO1[31:0], RXO2[31:0], RXO3[31:0] |
| `rxo_bytes` | output | 5 | RXO4[4:0] |
| `rxo_kind` | output | 2 | RXO4[6:5] |
| `rxo_last` | output | 1 | RXO4[7:7] |
| `rxo_bad` | output | 1 | RXO4[8:8] |
| `rxo_cm` | output | 1 | RXO4[9:9] |

## APB wrapper

`PCIe_CXL_IDE_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sl_key`, `sl_valid`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x49440100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000000 | Stream configuration |
| 0x018 | SID | RW | 0x00000000 | Stream IDs |
| 0x01C | IVFIX0 | RW | 0x00000000 | IV fixed fields: IVFIX0 stream 0, IVFIX1 stream 1 |
| 0x020 | IVFIX1 | RW | 0x00000000 | IV fixed fields: IVFIX0 stream 0, IVFIX1 stream 1 |
| 0x024 | KM | RW | 0x00000000 | Key management target, used by CMD.km_prog / km_go / km_stop |
| 0x028 | KEY0 | WO | 0x00000000 | AES-256 key for CMD.km_prog, eight write-only words (KEY7 holds bits 255:224, the first key bytes); reads return 0 |
| 0x02C | KEY1 | WO | 0x00000000 | AES-256 key for CMD.km_prog, eight write-only words (KEY7 holds bits 255:224, the first key bytes); reads return 0 |
| 0x030 | KEY2 | WO | 0x00000000 | AES-256 key for CMD.km_prog, eight write-only words (KEY7 holds bits 255:224, the first key bytes); reads return 0 |
| 0x034 | KEY3 | WO | 0x00000000 | AES-256 key for CMD.km_prog, eight write-only words (KEY7 holds bits 255:224, the first key bytes); reads return 0 |
| 0x038 | KEY4 | WO | 0x00000000 | AES-256 key for CMD.km_prog, eight write-only words (KEY7 holds bits 255:224, the first key bytes); reads return 0 |
| 0x03C | KEY5 | WO | 0x00000000 | AES-256 key for CMD.km_prog, eight write-only words (KEY7 holds bits 255:224, the first key bytes); reads return 0 |
| 0x040 | KEY6 | WO | 0x00000000 | AES-256 key for CMD.km_prog, eight write-only words (KEY7 holds bits 255:224, the first key bytes); reads return 0 |
| 0x044 | KEY7 | WO | 0x00000000 | AES-256 key for CMD.km_prog, eight write-only words (KEY7 holds bits 255:224, the first key bytes); reads return 0 |
| 0x048 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x04C | TX0 | RW | 0x00000000 | Transmit input block: TX0..TX3 the 128-bit block (TX3 holds bytes 0-3), then TX4 with the byte count and flags, which commits it |
| 0x050 | TX1 | RW | 0x00000000 | Transmit input block: TX0..TX3 the 128-bit block (TX3 holds bytes 0-3), then TX4 with the byte count and flags, which commits it |
| 0x054 | TX2 | RW | 0x00000000 | Transmit input block: TX0..TX3 the 128-bit block (TX3 holds bytes 0-3), then TX4 with the byte count and flags, which commits it |
| 0x058 | TX3 | RW | 0x00000000 | Transmit input block: TX0..TX3 the 128-bit block (TX3 holds bytes 0-3), then TX4 with the byte count and flags, which commits it |
| 0x05C | TX4 | RW | 0x00000000 | Transmit input block: TX0..TX3 the 128-bit block (TX3 holds bytes 0-3), then TX4 with the byte count and flags, which commits it |
| 0x060 | TXO0 | RO (pop) | 0x00000000 | Transmit output block: read TXO0..TXO3, then TXO4, which pops it |
| 0x064 | TXO1 | RO (pop) | 0x00000000 | Transmit output block: read TXO0..TXO3, then TXO4, which pops it |
| 0x068 | TXO2 | RO (pop) | 0x00000000 | Transmit output block: read TXO0..TXO3, then TXO4, which pops it |
| 0x06C | TXO3 | RO (pop) | 0x00000000 | Transmit output block: read TXO0..TXO3, then TXO4, which pops it |
| 0x070 | TXO4 | RO (pop) | 0x00000000 | Transmit output block: read TXO0..TXO3, then TXO4, which pops it |
| 0x074 | RX0 | RW | 0x00000000 | Receive input block (the transmit output format): RX0..RX3 the block, then RX4, which commits it |
| 0x078 | RX1 | RW | 0x00000000 | Receive input block (the transmit output format): RX0..RX3 the block, then RX4, which commits it |
| 0x07C | RX2 | RW | 0x00000000 | Receive input block (the transmit output format): RX0..RX3 the block, then RX4, which commits it |
| 0x080 | RX3 | RW | 0x00000000 | Receive input block (the transmit output format): RX0..RX3 the block, then RX4, which commits it |
| 0x084 | RX4 | RW | 0x00000000 | Receive input block (the transmit output format): RX0..RX3 the block, then RX4, which commits it |
| 0x088 | RXO0 | RO (pop) | 0x00000000 | Receive output block: read RXO0..RXO3, then RXO4, which pops it |
| 0x08C | RXO1 | RO (pop) | 0x00000000 | Receive output block: read RXO0..RXO3, then RXO4, which pops it |
| 0x090 | RXO2 | RO (pop) | 0x00000000 | Receive output block: read RXO0..RXO3, then RXO4, which pops it |
| 0x094 | RXO3 | RO (pop) | 0x00000000 | Receive output block: read RXO0..RXO3, then RXO4, which pops it |
| 0x098 | RXO4 | RO (pop) | 0x00000000 | Receive output block: read RXO0..RXO3, then RXO4, which pops it |
| 0x09C | STATUS | RO | core | Stream state and the causes of the last errors |
| 0x0A0 | KV | RO | core | Loaded key slots, bit 6i + 3k + sub: stream i, key set k, sub-stream sub |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x0A4 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4944 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 10:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 10:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 3:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 1:0 | `s_en` | RW | 0x0 | bit i: stream i enabled |
| CFG | 3:2 | `s_cm` | RW | 0x0 | bit i: stream i type, 0 PCIe / CXL.io TLPs, 1 CXL.cachemem flits |
| CFG | 10:4 | `cm_agg` | RW | 0x0 | cachemem MAC epoch: cm_agg + 1 flits |
| SID | 15:0 | `s_id` | RW | 0x0 | Stream ID of stream i in bits 8i+7:8i |
| IVFIX0 | 31:0 | `s_ivfix[31:0]` | RW | 0x0 | the first 32 IV bits of stream i (IVFIXi) |
| IVFIX1 | 31:0 | `s_ivfix[63:32]` | RW | 0x0 | the first 32 IV bits of stream i (IVFIXi) |
| KM | 0 | `km_dir` | RW | 0x0 | 0 transmit, 1 receive |
| KM | 2:1 | `km_sid` | RW | 0x0 | stream |
| KM | 3 | `km_ks` | RW | 0x0 | key set (the prefix K bit) |
| KM | 5:4 | `km_sub` | RW | 0x0 | km_prog: sub-stream, 0 posted, 1 non-posted, 2 completion (cachemem: 0) |
| KM | 6 | `km_sel` | RW | 0x0 | km_prog: 0 the KEY registers, 1 the sideload key port |
| KEY0 | 31:0 | `km_key[31:0]` | WO | 0x0 | AES-256 key, big-endian |
| KEY1 | 31:0 | `km_key[63:32]` | WO | 0x0 | AES-256 key, big-endian |
| KEY2 | 31:0 | `km_key[95:64]` | WO | 0x0 | AES-256 key, big-endian |
| KEY3 | 31:0 | `km_key[127:96]` | WO | 0x0 | AES-256 key, big-endian |
| KEY4 | 31:0 | `km_key[159:128]` | WO | 0x0 | AES-256 key, big-endian |
| KEY5 | 31:0 | `km_key[191:160]` | WO | 0x0 | AES-256 key, big-endian |
| KEY6 | 31:0 | `km_key[223:192]` | WO | 0x0 | AES-256 key, big-endian |
| KEY7 | 31:0 | `km_key[255:224]` | WO | 0x0 | AES-256 key, big-endian |
| CMD | 0 | `km_prog` | WO (pulse) | 0x0 | load the key into the KM slot and set its invocation counter to 1 |
| CMD | 1 | `km_go` | WO (pulse) | 0x0 | make KM's key set the stream's active set and the stream Secure |
| CMD | 2 | `km_stop` | WO (pulse) | 0x0 | clear KM's key set; the stream becomes Insecure if that set was active |
| CMD | 3 | `clr` | WO (pulse) | 0x0 | clear every key, counter and stream state and abort both directions |
| TX0 | 31:0 | `tx_data[31:0]` | RW | 0x0 | block, big-endian |
| TX1 | 31:0 | `tx_data[63:32]` | RW | 0x0 | block, big-endian |
| TX2 | 31:0 | `tx_data[95:64]` | RW | 0x0 | block, big-endian |
| TX3 | 31:0 | `tx_data[127:96]` | RW | 0x0 | block, big-endian |
| TX4 | 4:0 | `tx_bytes` | RW | 0x0 | valid bytes 1..16 |
| TX4 | 5 | `tx_hdr` | RW | 0x0 | TLP header block |
| TX4 | 6 | `tx_last` | RW | 0x0 | last block of the TLP / flit |
| TX4 | 7 | `tx_ide` | RW | 0x0 | first block: protect the message (0 passes it through) |
| TX4 | 9:8 | `tx_sid` | RW | 0x0 | first block: stream |
| TX4 | 11:10 | `tx_sub` | RW | 0x0 | first block: sub-stream (TLP) |
| TXO0 | 31:0 | `txo_data[31:0]` | RO (pop) | 0x0 | block, big-endian |
| TXO1 | 31:0 | `txo_data[63:32]` | RO (pop) | 0x0 | block, big-endian |
| TXO2 | 31:0 | `txo_data[95:64]` | RO (pop) | 0x0 | block, big-endian |
| TXO3 | 31:0 | `txo_data[127:96]` | RO (pop) | 0x0 | block, big-endian |
| TXO4 | 4:0 | `txo_bytes` | RO (pop) | 0x0 | valid bytes 0..16 |
| TXO4 | 6:5 | `txo_kind` | RO (pop) | 0x0 | 0 header, 1 data, 2 MAC, 3 IDE prefix |
| TXO4 | 7 | `txo_last` | RO (pop) | 0x0 | last block of the TLP / flit |
| TXO4 | 8 | `txo_bad` | RO (pop) | 0x0 | nullified MAC: the message was dropped |
| TXO4 | 9 | `txo_cm` | RO (pop) | 0x0 | cachemem flit or epoch MAC |
| RX0 | 31:0 | `rx_data[31:0]` | RW | 0x0 | block, big-endian |
| RX1 | 31:0 | `rx_data[63:32]` | RW | 0x0 | block, big-endian |
| RX2 | 31:0 | `rx_data[95:64]` | RW | 0x0 | block, big-endian |
| RX3 | 31:0 | `rx_data[127:96]` | RW | 0x0 | block, big-endian |
| RX4 | 4:0 | `rx_bytes` | RW | 0x0 | valid bytes |
| RX4 | 6:5 | `rx_kind` | RW | 0x0 | 0 header, 1 data, 2 MAC, 3 IDE prefix |
| RX4 | 7 | `rx_last` | RW | 0x0 | last block of the TLP / flit |
| RX4 | 8 | `rx_cm` | RW | 0x0 | cachemem flit or epoch MAC of stream rx_sid |
| RX4 | 10:9 | `rx_sid` | RW | 0x0 | cachemem: stream |
| RXO0 | 31:0 | `rxo_data[31:0]` | RO (pop) | 0x0 | block, big-endian (plaintext of IDE messages) |
| RXO1 | 31:0 | `rxo_data[63:32]` | RO (pop) | 0x0 | block, big-endian (plaintext of IDE messages) |
| RXO2 | 31:0 | `rxo_data[95:64]` | RO (pop) | 0x0 | block, big-endian (plaintext of IDE messages) |
| RXO3 | 31:0 | `rxo_data[127:96]` | RO (pop) | 0x0 | block, big-endian (plaintext of IDE messages) |
| RXO4 | 4:0 | `rxo_bytes` | RO (pop) | 0x0 | valid bytes 0..16 |
| RXO4 | 6:5 | `rxo_kind` | RO (pop) | 0x0 | 0 header, 1 data, 2 END of an IDE message |
| RXO4 | 7 | `rxo_last` | RO (pop) | 0x0 | last block of the TLP / flit / message |
| RXO4 | 8 | `rxo_bad` | RO (pop) | 0x0 | END: the MAC did not match or the message was dropped |
| RXO4 | 9 | `rxo_cm` | RO (pop) | 0x0 | cachemem |
| STATUS | 1:0 | `sec_tx` | RO | core | bit i: transmit stream i Secure |
| STATUS | 3:2 | `sec_rx` | RO | core | bit i: receive stream i Secure |
| STATUS | 5:4 | `ks_tx` | RO | core | bit i: active transmit key set of stream i |
| STATUS | 7:6 | `ks_rx` | RO | core | bit i: active receive key set of stream i |
| STATUS | 8 | `tx_busy` | RO | core | transmit message or cachemem epoch open |
| STATUS | 9 | `rx_busy` | RO | core | receive message or cachemem epoch open |
| STATUS | 12:10 | `km_code` | RO | core | last key management error: 1 bad stream / sub-stream, 2 key set incomplete, 3 sideload key not valid, 4 key set in use |
| STATUS | 15:13 | `tx_code` | RO | core | last transmit error: 1 format, 2 stream state, 4 counter exhausted, 5 too long |
| STATUS | 17:16 | `tx_esid` | RO | core | stream of the last transmit error |
| STATUS | 20:18 | `rx_code` | RO | core | last receive error: 1 format, 2 stream state, 3 key set not loaded, 4 counter exhausted, 5 too long, 6 unknown Stream ID, 7 MAC mismatch |
| STATUS | 28:21 | `rx_eid` | RO | core | Stream ID of the last receive error |
| KV | 11:0 | `kv_tx` | RO | core | transmit slots loaded |
| KV | 23:12 | `kv_rx` | RO | core | receive slots loaded |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_MSG | an IDE message (or cachemem epoch) was sent with its MAC |
| 1 | TX_ERR | a transmit message was dropped (STATUS.tx_code, tx_esid) |
| 2 | RX_MSG | an IDE message (or cachemem epoch) passed its MAC check |
| 3 | RX_ERR | a receive message failed (STATUS.rx_code, rx_eid); the stream is Insecure |
| 4 | KM_ERR | a key management command was refused (STATUS.km_code) |
| 5 | TX_DONE | TX beat accepted by the core |
| 6 | TX_OVF | write to TX while full (dropped) |
| 7 | TXO_AVAIL | TXO captured a beat |
| 8 | RX_DONE | RX beat accepted by the core |
| 9 | RX_OVF | write to RX while full (dropped) |
| 10 | RXO_AVAIL | RXO captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | TXO_AVAIL | TXO holds an unread beat |
| 2 | RX_FULL | RX holds a beat the core has not taken |
| 3 | RXO_AVAIL | RXO holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_bytes`, `tx_hdr`, `tx_last`, `tx_ide`, `tx_sid`, `tx_sub`/`tx_valid`. Writing TX4 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **TXO** takes `txo_data`, `txo_bytes`, `txo_kind`, `txo_last`, `txo_bad`, `txo_cm` from the core with `txo_valid` / `txo_ready`: `txo_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ TXO_AVAIL. Reading TXO4 pops it. Nothing is dropped: the core holds its data until the register is free.
* **RX** feeds `rx_data`, `rx_bytes`, `rx_kind`, `rx_last`, `rx_cm`, `rx_sid`/`rx_valid`. Writing RX4 commits the beat: FLAGS.RX_FULL is set and `rx_valid` stays high until the core's `rx_ready`; then RX_DONE is set. A write while full is dropped and sets RX_OVF.
* **RXO** takes `rxo_data`, `rxo_bytes`, `rxo_kind`, `rxo_last`, `rxo_bad`, `rxo_cm` from the core with `rxo_valid` / `rxo_ready`: `rxo_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RXO_AVAIL. Reading RXO4 pops it. Nothing is dropped: the core holds its data until the register is free.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x49440100.
2. Write 0x7FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014), SID (0x018), IVFIX0 (0x01C), IVFIX1 (0x020), KM (0x024), KEY0 (0x028), KEY1 (0x02C), KEY2 (0x030), KEY3 (0x034), KEY4 (0x038), KEY5 (0x03C), KEY6 (0x040), KEY7 (0x044). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7FF enables all).
5. To issue a command, write 1 to `km_prog` (CMD bit 0), `km_go` (CMD bit 1), `km_stop` (CMD bit 2), `clr` (CMD bit 3) at 0x048; the core sees a one-clock pulse, and the register reads 0.
6. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x04C) then TX1 (0x050) then TX2 (0x054) then TX3 (0x058) then TX4 (0x05C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
7. To receive on TXO: wait for IRQ TXO_AVAIL or FLAGS.TXO_AVAIL (bit 1), then read TXO0 (0x060) then TXO1 (0x064) then TXO2 (0x068) then TXO3 (0x06C) then TXO4 (0x070). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.TXO_AVAIL (bit 7) to clear it.
8. To send on RX: wait until FLAGS.RX_FULL (bit 2) is 0, or for IRQ RX_DONE, then write RX0 (0x074) then RX1 (0x078) then RX2 (0x07C) then RX3 (0x080) then RX4 (0x084). The last write commits the beat. RX_OVF means a write came while the register was full and was dropped.
9. To receive on RXO: wait for IRQ RXO_AVAIL or FLAGS.RXO_AVAIL (bit 3), then read RXO0 (0x088) then RXO1 (0x08C) then RXO2 (0x090) then RXO3 (0x094) then RXO4 (0x098). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RXO_AVAIL (bit 10) to clear it.
10. Read STATUS (0x09C) for the core's live `sec_tx`, `sec_rx`, `ks_tx`, `ks_rx`, `tx_busy`, `rx_busy`, `km_code`, `tx_code`, `tx_esid`, `rx_code`, `rx_eid`; it needs no clearing.
11. Read KV (0x0A0) for the core's live `kv_tx`, `kv_rx`; it needs no clearing.
12. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CFG (s_en, s_cm, cm_agg), SID and IVFIX0..IVFIX1.
2. For each direction and sub-stream: write KM (dir, stream, key set, sub-stream), KEY0..KEY7 and CMD.km_prog; then CMD.km_go with the same KM: the stream is Secure (STATUS). Clear the KEY registers afterwards.
3. Transmit: for each block wait for FLAGS.TX_FULL = 0, write TX0..TX3 and then TX4 = bytes | hdr << 5 | last << 6 | ide << 7 | sid << 8 | sub << 10. Read each TXO block (TXO0..TXO3, then TXO4) when FLAGS.TXO_AVAIL is set.
4. Receive: write RX0..RX3 and RX4 = bytes | kind << 5 | last << 7 | cm << 8 | sid << 9 for each received block; read RXO blocks; use the plaintext only after the END block with rxo_bad = 0 (IRQ RX_MSG).
5. On IRQ TX_ERR / RX_ERR / KM_ERR read STATUS for the cause; re-key a stream that became Insecure with km_stop, km_prog and km_go.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.PCIe_CXL_IDE sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.PCIe_CXL_IDE syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/PCIe_CXL_IDE_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.PCIe_CXL_IDE apb` | `TEST PASSED: PCIe_CXL_IDE_apb`, then Yosys without `ERROR` | console, `work/PCIe_CXL_IDE_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh PCIe_CXL_IDE`<br>`bash scripts/cov/run_cov.sh PCIe_CXL_IDE_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/PCIe_CXL_IDE/score.json`, `work/cov/PCIe_CXL_IDE_apb/score.json` |

Expected end of a step 4 run:

```
===== PCIe_CXL_IDE =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/PCIe_CXL_IDE_tb.sv`): drives `PCIe_CXL_IDE_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/PCIe_CXL_IDE_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/PCIe_CXL_IDE_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/PCIe_CXL_IDE_sva.sv`, `tb/cov/PCIe_CXL_IDE_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/PCIe_CXL_IDE_top.sv` | pass | 340/340 (+2 excl.) | 18012/18012 (+10 excl.) | 62/62 | 23/23 | 51/51 |
| wrapper `rtl/PCIe_CXL_IDE_apb.sv` | pass | 107/107 | 4836/4836 | n/a | 53/53 | 155/155 |

Core: tb/PCIe_CXL_IDE_tb.sv (NS = 2, CTR_W = 4, LEN_W = 9) runs 72 known-answer cases from tb/PCIe_CXL_IDE_vec.svh (TLPs on every sub-stream and key set, header and payload lengths 4..480 bytes, cachemem epochs of 1..4 flits, key refreshes), each sent through the transmit side, compared, then looped back through the receive side; random loopback TLPs; every key management error; every transmit and receive error (framing, stream state, key set, counter exhaustion on all 24 slots, length limits, unknown Stream ID, tampered ciphertext / header / MAC); epoch truncation and bypass traffic inside epochs; clr and reset in every phase; output back-pressure down to 2 % ready.
Expected values come from scripts/ide/ide_ref.py (on scripts/aes_gcm/gcm_ref.py), every case cross-checked against Python's cryptography AESGCM. The core checker tb/cov/PCIe_CXL_IDE_sva.sv has its own AES-256 (S-box computed from the field inverse) and GHASH and models the key slots, counters, stream states and both directions block by block: every output block, error, done pulse, key slot and counter is compared every clock.
