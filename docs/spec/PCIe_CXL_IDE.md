# PCIe_CXL_IDE: design specification

Integrity and Data Encryption (IDE) for PCIe TLPs, CXL.io and CXL.cachemem, built on two `AES_GCM_top` engines with AES-256-GCM: `u_gtx` encrypts the transmit direction and `u_grx` decrypts the receive direction with a 96-bit tag. There are NS streams. Each stream has two key sets per direction, and each key set has three sub-stream keys with their own 64-bit IV invocation counters. Key management follows the IDE_KM style. The field layouts (prefix, MAC) follow the public descriptions of IDE but are this IP's own. They are not claimed to be bit-compatible with the member-only PCIe 6.x / CXL 3.x specifications. Core `PCIe_CXL_IDE_top` (`rtl/PCIe_CXL_IDE_top.sv`), testbench `tb/PCIe_CXL_IDE_tb.sv`, checker `tb/cov/PCIe_CXL_IDE_sva.sv`.

## 1. Interface

All block streams carry 128-bit blocks with byte 0 in bits 127:120 and a byte count. The link layer packs them into its own TLP or flit byte stream. A block moves on `valid && ready`.

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset: keys, counters, streams, both FSMs | low | async | - |
| `s_en` | input | NS | stream i enabled (bit i) | high | `clk` | - |
| `s_cm` | input | NS | stream i type: 0 PCIe / CXL.io TLPs, 1 CXL.cachemem flits | - | `clk` | - |
| `s_id` | input | NS*8 | Stream ID of stream i in [8i+7:8i] | - | `clk` | - |
| `s_ivfix` | input | NS*32 | IV fixed field (first 32 IV bits) of stream i in [32i+31:32i] | - | `clk` | - |
| `cm_agg` | input | 7 | cachemem MAC epoch: `cm_agg` + 1 flits | - | `clk` | - |
| `km_dir` | input | 1 | key-management direction: 0 transmit, 1 receive | - | `clk` | - |
| `km_sid` | input | 2 | key-management stream | - | `clk` | - |
| `km_ks` | input | 1 | key set (the prefix K bit) | - | `clk` | - |
| `km_sub` | input | 2 | `km_prog` sub-stream: 0 posted, 1 non-posted, 2 completion (cachemem: 0); 3 is an error | - | `clk` | - |
| `km_sel` | input | 1 | `km_prog` key source: 0 `km_key`, 1 `sl_key` | - | `clk` | - |
| `km_key` | input | 256 | AES-256 key (bits 255:248 the first key byte) | - | `clk` | - |
| `sl_key` | input | 256 | sideload key port | - | `clk` | - |
| `sl_valid` | input | 1 | `sl_key` is valid | high | `clk` | - |
| `km_prog` | input | 1 | one-clock command: load the key into slot (`km_dir`, `km_sid`, `km_ks`, `km_sub`), counter = 1 | high | `clk` | - |
| `km_go` | input | 1 | one-clock command: make key set `km_ks` active and the stream Secure | high | `clk` | - |
| `km_stop` | input | 1 | one-clock command: clear key set `km_ks` (keys, counters); Insecure if it was the active set of a Secure stream | high | `clk` | - |
| `clr` | input | 1 | clear every key, counter and stream state and abort both directions | high | `clk` | - |
| `sec_tx` | output | NS | transmit stream i Secure | high | `clk` | 0 |
| `sec_rx` | output | NS | receive stream i Secure | high | `clk` | 0 |
| `ks_tx` | output | NS | active transmit key set of stream i | - | `clk` | 0 |
| `ks_rx` | output | NS | active receive key set of stream i (follows the received K bit) | - | `clk` | 0 |
| `kv_tx` | output | NS*6 | transmit slot loaded, bit 6i + 3k + sub | high | `clk` | 0 |
| `kv_rx` | output | NS*6 | receive slot loaded, bit 6i + 3k + sub | high | `clk` | 0 |
| `tx_busy` | output | 1 | transmit FSM not idle or a cachemem epoch open (`t` != IDLE \|\| epoch) | high | comb | 0 |
| `rx_busy` | output | 1 | receive FSM not idle or a cachemem epoch open | high | comb | 0 |
| `km_err` | output | 1 | one-clock pulse: a key-management command was refused | high | `clk` | 0 |
| `km_code` | output | 3 | cause of the last refusal (§5), held | - | `clk` | 0 |
| `tx_done` | output | 1 | one-clock pulse with the MAC block: an IDE message / epoch was sent | high | `clk` | 0 |
| `tx_err` | output | 1 | one-clock pulse: a transmit message was dropped | high | `clk` | 0 |
| `tx_code` | output | 3 | cause of the last transmit error (§5), held | - | `clk` | 0 |
| `tx_esid` | output | 2 | stream of the last transmit error | - | `clk` | 0 |
| `rx_done` | output | 1 | one-clock pulse: an IDE message / epoch passed its MAC check | high | `clk` | 0 |
| `rx_err` | output | 1 | one-clock pulse: a receive error (the stream becomes Insecure, §5) | high | `clk` | 0 |
| `rx_code` | output | 3 | cause of the last receive error (§5), held | - | `clk` | 0 |
| `rx_eid` | output | 8 | Stream ID of the last receive error | - | `clk` | 0 |
| `tx_valid` | input | 1 | transmit input block valid | high | `clk` | - |
| `tx_ready` | output | 1 | transmit block taken; combinational, 0 in IDLE (the first block is classified, then taken in a later state) | high | comb | 0 |
| `tx_data` | input | 128 | block, byte 0 in bits 127:120 | - | `clk` | - |
| `tx_bytes` | input | 5 | valid bytes 1..16 (only the last header / payload block may be short) | - | `clk` | - |
| `tx_hdr` | input | 1 | TLP header block | high | `clk` | - |
| `tx_last` | input | 1 | last block of the TLP / flit | high | `clk` | - |
| `tx_ide` | input | 1 | first block: protect the message (0: pass through unchanged) | high | `clk` | - |
| `tx_sid` | input | 2 | first block: stream | - | `clk` | - |
| `tx_sub` | input | 2 | first block: sub-stream (TLP) | - | `clk` | - |
| `txo_valid` | output | 1 | transmit output block valid; held under back-pressure | high | `clk` | 0 |
| `txo_ready` | input | 1 | consumer takes the output block | high | `clk` | - |
| `txo_data` | output | 128 | output block | - | `clk` | 0 |
| `txo_bytes` | output | 5 | valid bytes: 4 PFX, 12 MAC, 0 nullified MAC | - | `clk` | 0 |
| `txo_kind` | output | 2 | 0 HDR, 1 DATA, 2 MAC, 3 PFX | - | `clk` | 0 |
| `txo_last` | output | 1 | last block of the TLP / flit (MAC blocks always) | high | `clk` | 0 |
| `txo_bad` | output | 1 | nullified MAC block: the message was dropped | high | `clk` | 0 |
| `txo_cm` | output | 1 | cachemem flit or epoch MAC | high | `clk` | 0 |
| `rx_valid` | input | 1 | receive input block valid | high | `clk` | - |
| `rx_ready` | output | 1 | receive block taken; combinational | high | comb | 0 |
| `rx_data` | input | 128 | block in the transmit output format | - | `clk` | - |
| `rx_bytes` | input | 5 | valid bytes | - | `clk` | - |
| `rx_kind` | input | 2 | 0 HDR, 1 DATA, 2 MAC, 3 PFX | - | `clk` | - |
| `rx_last` | input | 1 | last block of the TLP / flit | high | `clk` | - |
| `rx_cm` | input | 1 | cachemem flit / epoch MAC of stream `rx_sid` | high | `clk` | - |
| `rx_sid` | input | 2 | cachemem: stream | - | `clk` | - |
| `rxo_valid` | output | 1 | receive output block valid; held under back-pressure | high | `clk` | 0 |
| `rxo_ready` | input | 1 | consumer takes the output block | high | `clk` | - |
| `rxo_data` | output | 128 | output block (plaintext of IDE messages) | - | `clk` | 0 |
| `rxo_bytes` | output | 5 | valid bytes (0 for END) | - | `clk` | 0 |
| `rxo_kind` | output | 2 | 0 HDR, 1 DATA, 2 END | - | `clk` | 0 |
| `rxo_last` | output | 1 | last block of the TLP / flit / message | high | `clk` | 0 |
| `rxo_bad` | output | 1 | END: the MAC did not match or the message was dropped | high | `clk` | 0 |
| `rxo_cm` | output | 1 | cachemem | high | `clk` | 0 |

### Internal signals used by the verification

The checker `PCIe_CXL_IDE_sva` reads these core signals by name (`.*` bind). A re-implementation must provide them with the same meaning.

| Signal | Width | Meaning |
|---|---|---|
| `t` | 4 | transmit FSM (enum, also bound by the FSM coverage): 0 IDLE, 1 PFX, 2 HDR, 3 FL (AAD flush), 4 DATA, 5 END (GCM last), 6 WAIT (tag), 7 MAC, 8 DROP, 9 TERM (nullified MAC), 10 BYP |
| `r` | 4 | receive FSM: 0 IDLE, 1 HDR, 2 FL, 3 DATA, 4 MAC, 5 END, 6 WAIT (tag check), 7 ST (END block), 8 DROP, 9 TERM (bad END), 10 BYP |
| `gt_err` | 1 | transmit engine error (GCM length limit, error code 5) |
| `gr_err` | 1 | receive engine error |
| `gt_ov` | 1 | transmit engine output block valid |
| `gr_ov` | 1 | receive engine output block valid |
| `txo_free` | 1 | `!txo_valid \|\| txo_ready`: the output register can load |
| `rxo_free` | 1 | `!rxo_valid \|\| rxo_ready` |
| `gt_clr` | 1 | transmit engine abort: `clr \|\| te_v && te_term` (an error that ends an open message) |
| `gr_clr` | 1 | receive engine abort: `clr \|\| re_v && re_term` |
| `ktx` | NS*6*256 | transmit slot keys, slot j in [256j+255:256j], j = 6i + 3k + sub |
| `krx` | NS*6*256 | receive slot keys |
| `ctx` | NS*6*CTR_W | transmit slot invocation counters, slot j in [CTR_W*j +: CTR_W] |
| `crx` | NS*6*CTR_W | receive slot invocation counters |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/PCIe_CXL_IDE.md`](../ip/PCIe_CXL_IDE.md) (source: `scripts/apb/specs/PCIe_CXL_IDE.json`); do not edit by hand.

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
| STATUS | 15:13 | `tx_code` | RO | core | last transmit error: 1 format, 2 stream state, 3 sub-stream key not loaded, 4 counter exhausted, 5 too long |
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

### Programming sequence

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
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Key management

Slots: direction d, stream i, key set k, sub-stream sub; slot index 6i + 3k + sub. Commands are sampled each clock. The priority is `km_prog`, then `km_go`, then `km_stop`. Results (slots, `sec_*`, `ks_*`, `km_err`, `km_code`) are registered on that clock edge and visible the next clock.

- `km_prog`: loads `km_key` (or `sl_key` when `km_sel` = 1) into the slot, sets its counter to 1 and sets its `kv_*` bit. It is refused when `km_sid` >= NS or `km_sub` = 3 (code 1), when `km_sel` = 1 and `sl_valid` = 0 (code 3), or when the key set is the active set of a Secure stream (code 4).
- `km_go`: makes key set `km_ks` the stream's active set (`ks_*`) and the stream Secure (`sec_*`). It needs sub-stream 0 loaded, plus sub-streams 1 and 2 for a TLP stream (code 2 otherwise). A cachemem stream needs only sub-stream 0.
- `km_stop`: clears the three slots of the key set (key, counter and `kv` bit). If that set was the active set of a Secure stream, the stream becomes Insecure. Stopping the inactive set leaves the stream Secure. It is refused only for a bad stream (code 1).
- `clr`: clears every key, counter, `kv`, `sec` and `ks` bit, drops both output registers and aborts both engines and both FSMs. It takes effect at that clock edge.

### 3.2 Transmit, TLP mode (stream type 0)

Input: the TLP header blocks (`tx_hdr` = 1, 16 bytes each except the last), then the payload blocks (16 bytes each except the last), with `tx_last` on the last block. `tx_ide`, `tx_sid` and `tx_sub` are read on the first block.

1. IDLE: the first block is offered and classified without being taken (`tx_ready` = 0). If `tx_ide` = 0, the TLP goes to BYP and every block is copied to the output unchanged: kind HDR or DATA, same bytes and `last`. Otherwise the stream checks of §5 run. On success the slot counter is taken for the IV and incremented, and the engine starts.
2. PFX: when the output register is free, the prefix block is output: kind PFX, 4 bytes. It is `[31:24]` 0x92, `[23]` M = 1, `[22]` K (the active key set), `[21:20]` 0, `[19:18]` sub-stream, `[17:16]` 0, `[15:8]` Stream ID, `[7:0]` 0, in block bits 127:96.
3. HDR: each header block is taken when the output is free and the engine is ready. It is copied to the output (kind HDR) and fed to GCM as AAD. The AAD is prefix || header, so the bytes are carried 4 bytes behind. FL flushes the carried bytes.
4. DATA: each payload block is encrypted. The ciphertext block is output as kind DATA when the engine produces it, with `last` on the last block.
5. END / WAIT / MAC: after the last block the engine completes (END is used for a header-only TLP). WAIT takes the tag. MAC then outputs `{tag[127:32], 32'h0}` as kind MAC, 12 bytes, `last` = 1, and pulses `tx_done` in the same clock.

IV = `{s_ivfix[stream], 64-bit counter}` (CTR_W bits, zero-extended). GCM text = payload. MAC = the first 12 tag bytes.

### 3.3 Receive

The receive input uses the transmit output format.

- IDLE: a PFX block (4 bytes, not last) starts an IDE TLP. The prefix Stream ID is looked up among the enabled TLP streams (the lowest index wins). The prefix block is taken in the same clock with a combinational `rx_ready` when the checks pass. The K bit selects the key set and is written to `ks_rx`, so the receiver follows a key-set switch by the transmitter. Blocks that are not IDE (an HDR / DATA first block without `rx_cm`) go to BYP and pass through unchanged.
- HDR: header blocks are copied to the output and fed to GCM as AAD. DATA: payload blocks are decrypted, and the plaintext is output as kind DATA. A short last payload block is held until the MAC arrives, because GCM needs it flagged as the last block.
- MAC: the 12-byte MAC block (last) is taken. The engine checks the tag against `{MAC, 32'h0}` with tag length 12. ST then outputs an END block (kind 2, 0 bytes, `last`) with `rxo_bad` = !match. `rx_done` pulses on a match. `rx_err` with code 7 pulses on a mismatch, and the stream becomes Insecure.
- The consumer must hold the plaintext until END with `rxo_bad` = 0.

### 3.4 Cachemem mode (stream type 1)

One GCM message is a MAC epoch of `cm_agg` + 1 flits. There is no AAD and no prefix, and every block is 16 bytes. `tx_last` ends a flit.

- Transmit: the first flit opens the epoch (IDLE goes straight to DATA). After each flit the FSM returns to IDLE, and the next flit of the same stream continues the epoch. After flit `cm_agg` + 1 the MAC block is output with `txo_cm` = 1. Bypass TLPs (`tx_ide` = 0) may pass while the epoch is open. An IDE message for another stream, or a TLP stream, first closes the epoch early (truncated: the MAC is sent at once) and is then processed.
- Receive: flits carry `rx_cm` = 1 and `rx_sid`. The epoch ends with the MAC block (`rx_cm` = 1, kind MAC), and a truncated epoch with fewer flits is accepted. A data flit beyond `cm_agg` + 1 is a format error. A PFX block or another stream's cachemem flit while an epoch is open aborts the epoch with a format error on the epoch's stream (a bad END block). The interrupting block is then processed on its own, which may itself fail.

### 3.5 Flow control and latency

- Output blocks are registered. `txo_*` / `rxo_*` hold while `valid && !ready`, unless `clr` is high.
- An expected output block appears within 80 clocks once it is due, and an expected error within 64 clocks. The checker assertions bound these times. The AES engines set the throughput: one block per AES round sequence.

### 3.6 Reset

Both FSMs are idle, `tx_busy` = `rx_busy` = 0, no output is valid, and all keys, counters, `kv_*`, `sec_*` and `ks_*` are 0. The `*_err` / `*_done` pulses and codes are 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `NS` | 2 | 1..4 | number of IDE streams. Widths of `s_*`, `sec_*`, `ks_*` (NS), `kv_*` (NS*6), `s_id` (NS*8), `s_ivfix` (NS*32), `ktx` / `krx`, `ctx` / `crx` |
| `CTR_W` | 64 | 3..64 | IV invocation counter bits. The all-ones value is never used, so a small value lets the TB reach exhaustion |
| `LEN_W` | 16 | 8..36 (the `AES_GCM_top` range) | GCM byte counters: AAD (prefix + header) up to 2^LEN_W - 1 bytes and text up to 2^LEN_W - 32 bytes. Longer messages fail with code 5 |

## 5. Errors and corner cases

Error codes (`tx_code` / `rx_code`):

| Code | Meaning |
|---|---|
| 1 | format error |
| 2 | stream not enabled, not Secure, or not of that type |
| 3 | sub-stream key not loaded (for example a stream made Secure as cachemem, then switched to TLPs) |
| 4 | counter exhausted |
| 5 | too long for the GCM counters (`LEN_W`) |
| 6 | unknown Stream ID (receive) |
| 7 | MAC mismatch (receive) |

`km_code`:

| Code | Meaning |
|---|---|
| 1 | bad stream or sub-stream |
| 2 | key set incomplete at `km_go` |
| 3 | sideload key not valid |
| 4 | key set in use |

- Transmit format errors:
  - `tx_sub` = 3 on a TLP stream;
  - a byte count of 0 or more than 16;
  - a short header block that is not the last header block;
  - a header block after the payload;
  - a short payload block that is not the last;
  - a short cachemem block.
- Transmit, error at the first block: the message is dropped through its `tx_last` (DROP) and nothing is output. The one exception is a continuing cachemem flit, which ends the epoch with a nullified MAC.
- Transmit, error after blocks were sent (format, or length from the engine): the rest of the TLP is dropped, then TERM outputs a nullified MAC block (kind MAC, 0 bytes, `txo_bad` = 1, `last`). `tx_esid` is the message's stream.
- Transmit errors do not make the stream Insecure, except counter exhaustion (code 4), which clears `sec_tx`.
- Receive prefix checks:
  - the prefix must be 4 bytes, not last, type 0x92 and M = 1, otherwise code 1;
  - the Stream ID must be known, otherwise code 6;
  - the stream must be Secure, otherwise code 2;
  - sub-stream 3 gives code 1;
  - the key must be loaded, otherwise code 3;
  - the counter must not be all-ones, otherwise code 4.
- A receive error at the first block drops the message without output. A later error (format, length or MAC) ends what was output with END `rxo_bad` = 1.
- Every receive error on an identified stream makes that stream Insecure. This includes a MAC mismatch, an exhausted counter, and a prefix error once the Stream ID matched. `rx_eid` reports the Stream ID.
- After a prefix error the message is skipped through its `last`, and the next message is processed normally.
- The counter value all-ones is never used.
- A key set cannot be reprogrammed while it is the active set of a Secure stream (code 4). Stop it or switch sets first.
- The receive side decrypts and outputs plaintext before the MAC is checked. A consumer must buffer the plaintext until END.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "receive block" | every receive input block is taken | §3.3 |
| "km op" | each key-management command gives the expected `km_err` / `km_code` | §3.1, §5 |
| "loopback block" | transmit output fed to the receiver gives back the original blocks | §3.2, §3.3 |
| "bypass: last not passed" | `tx_ide` = 0 / non-IDE TLPs pass through with `last` | §3.2, §3.3 |
| "clr left keys or Secure streams" | `clr` clears `kv_*` and `sec_*` the next clock | §3.1 |
| "stopping the inactive set ended Secure" | `km_stop` on the inactive set keeps the stream Secure | §3.1 |
| "stopping the active set kept Secure" | `km_stop` on the active set makes it Insecure | §3.1 |
| "cachemem stream not Secure with sub-stream 0" | `km_go` on a cachemem stream needs only sub-stream 0 | §3.1 |
| "epoch loopback" | a cachemem epoch of `cm_agg` + 1 flits decrypts and ends with END rxo_bad = 0 | §3.4 |
| "truncated epoch" | an epoch closed early is accepted by the receiver | §3.4 |
| "Secure after a MAC mismatch" | MAC mismatch makes the receive stream Insecure | §5 |
| "message after prefix errors" | prefix errors drop the message without output; the next message is fine | §5 |
| "receiver did not follow the K bit" | the received K bit switches `ks_rx` | §3.3 |
| "Secure after the counter ran out" | counter exhaustion makes the transmit stream Insecure | §5 |
| "epoch interrupted by a prefix" | an IDE prefix during an open receive epoch: two errors (epoch E_FMT, then the message) | §3.4, §5 |
| "epoch interrupted by another stream" | another stream's cachemem flit during an open receive epoch: one error | §3.4, §5 |
| "transmit epoch closed by another stream" | another IDE message closes the transmit epoch with its MAC first | §3.4 |
| "clr: states" | (TB: reaching each FSM state before `clr`) | §3.1 |
| "transmit block" | each transmit output block (data, bytes, kind, last, bad, cm) equals the model | §3.2 |
| "output without a message" | no output for a message dropped at its first block | §5 |
| "no nullified MAC block" | a later transmit error ends the output with a nullified MAC | §5 |
| "no bad END block" | a later receive error ends the output with END rxo_bad = 1 | §5 |
| a_tx_output | every transmit output block equals the independent AES-256-GCM model | §3.2, §3.4 |
| a_rx_output | every receive output block (plaintext, END and verdict) equals the model | §3.3, §3.4 |
| a_tx_error | `tx_err` / `tx_code` / `tx_esid` as predicted | §5 |
| a_rx_error | `rx_err` / `rx_code` / `rx_eid` as predicted | §5 |
| a_tx_done | `tx_done` with each MAC block | §3.2 |
| a_rx_done | `rx_done` for each passed MAC check | §3.3 |
| a_km_error | `km_err` exactly for refused commands | §3.1, §5 |
| a_km_code | `km_code` value | §5 |
| a_key_slots | `ktx` / `krx` / `kv_*` follow the commands | §3.1 |
| a_counters | `ctx` / `crx`: 1 at `km_prog`, +1 per message, 0 at `km_stop` / `clr` | §3.1 |
| a_stream_state | `sec_*` / `ks_*` as predicted | §3.1, §5 |
| a_tx_error_in_time | an expected transmit error comes within 64 clocks | §3.5 |
| a_rx_error_in_time | an expected receive error comes within 64 clocks | §3.5 |
| a_tx_output_in_time | an expected transmit output block waits at most 80 clocks | §3.5 |
| a_rx_output_in_time | an expected receive output block waits at most 80 clocks | §3.5 |
| a_txo_hold | `txo_*` stable while `txo_valid && !txo_ready` (unless `clr`) | §3.5 |
| a_rxo_hold | `rxo_*` stable while `rxo_valid && !rxo_ready` | §3.5 |
| a_busy_tx | `t` != IDLE implies `tx_busy` | §3.2 |
| a_busy_rx | `r` != IDLE implies `rx_busy` | §3.3 |
| a_mac_bytes | MAC blocks are last, 12 bytes (0 when nullified) | §3.2 |
| a_end_block | END blocks are last with 0 bytes | §3.3 |
| a_clr_clears | the clock after `clr`: no keys, no Secure streams, no output valid | §3.1 |
| a_reset | reset values | §3.6 |
