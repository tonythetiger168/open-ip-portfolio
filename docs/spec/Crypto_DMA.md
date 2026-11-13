<!-- SPDX-License-Identifier: Apache-2.0 -->
# Crypto_DMA: design specification

AES-GCM engine with an AXI4 DMA. The unchanged `AES_GCM_top` core (AES-128 / AES-256, 96-bit IV,
see the AES_GCM core documentation in [docs/ip/AES_GCM.md](../ip/AES_GCM.md)) streams one message
from memory to memory: the AAD and the input text are read from `src_addr`, the output text
(ciphertext, or plaintext when decrypting) is written to `dst_addr`, and the tag (encrypt) or the
tag check result (decrypt) is given on ports. Core `Crypto_DMA_top` (`rtl/Crypto_DMA_top.sv`,
uses `rtl/AES_GCM_top.sv` with `LEN_W` = 20 and two `rtl/soc_ss_axi_engine.sv` instances),
testbench `tb/Crypto_DMA_tb.sv` (with `tb/soc_ss_axi_mem.svh` and the vectors in
`tb/Crypto_DMA_vec.svh`). There is no separate core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *block* is 16 bytes. nab = ceil(`aad_len` / 16) AAD blocks,
ntb = ceil(`txt_len` / 16) text blocks, nbl = nab + ntb.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `key256` | input | 1 | 0 AES-128 (key in `key[255:128]`), 1 AES-256; taken at start | high | `clk` | - |
| `decrypt` | input | 1 | 0 encrypt, 1 decrypt; taken at start | high | `clk` | - |
| `key_sel` | input | 1 | 0 use `key`, 1 use the sideload key `sl_key`; taken at start | high | `clk` | - |
| `tag_len` | input | 4 | decrypt: bytes of `tag_in` compared, 0 = 16 | - | `clk` | - |
| `key` | input | 256 | AES key (AES-128 uses bits [255:128]) | - | `clk` | - |
| `iv` | input | 96 | GCM IV (96-bit IV only), big-endian | - | `clk` | - |
| `tag_in` | input | 128 | decrypt: expected tag, big-endian, first `tag_len` bytes used; read when the message ends | - | `clk` | - |
| `sl_key` | input | 256 | sideload key from a key manager; software cannot read it | - | `clk` | - |
| `sl_valid` | input | 1 | `sl_key` is valid; must be 1 at start when `key_sel` = 1 | high | `clk` | - |
| `src_addr` | input | 32 | source buffer (bits [1:0] ignored); read at the start edge | - | `clk` | - |
| `dst_addr` | input | 32 | output buffer (bits [1:0] ignored); read at the start edge | - | `clk` | - |
| `aad_len` | input | 16 | AAD bytes, 0 to 65535; must be held for the whole job | - | `clk` | - |
| `txt_len` | input | 16 | text bytes, 0 to 65535; must be held for the whole job | - | `clk` | - |
| `start` | input | 1 | starts a job when `busy` = 0 | high | `clk` | - |
| `busy` | output | 1 | job running | high | `clk` | 0 |
| `err` | output | 1 | an AXI error response was seen in the current / last job | high | `clk` | 0 |
| `gcm_err` | output | 1 | the AES-GCM core reported an error in the current / last job | high | `clk` | 0 |
| `err_code` | output | 3 | the core's error code when `gcm_err` = 1 (4 = sideload key not valid), else 0 | - | `clk` | 0 |
| `tag_ok` | output | 1 | decrypt: `tag_in` matched; valid from `done` until the next start | high | `clk` | 0 |
| `tag` | output | 128 | encrypt: the tag, big-endian; valid from `done` until the next start (0 after a decrypt) | - | `clk` | 0 |
| `cycles` | output | 32 | clocks of the current / last job (§3.5) | - | `clk` | 0 |
| `done` | output | 1 | one-clock pulse at the end of every job | high | `clk` | 0 |
| `err_irq` | output | 1 | `done && (err \|\| gcm_err)` | high | `clk` | 0 |
| `m_awid` | output | 4 | write ID, constant `AXI_ID` | - | - | - |
| `m_awaddr` | output | 32 | burst start address (word aligned) | - | `clk` | 0 |
| `m_awlen` | output | 8 | beats - 1 (0 to 15) | - | `clk` | - |
| `m_awsize` | output | 3 | constant 2 (4 bytes) | - | - | 2 |
| `m_awburst` | output | 2 | constant 01 (INCR) | - | - | 01 |
| `m_awprot` | output | 3 | constant 3'b000 | - | - | 3'b000 |
| `m_awvalid` | output | 1 | write address valid; held until `m_awready` | high | `clk` | 0 |
| `m_awready` | input | 1 | write address ready | high | `clk` | - |
| `m_wdata` | output | 32 | write data, from the write FIFO | - | `clk` | - |
| `m_wstrb` | output | 4 | constant 4'hF | - | - | 4'hF |
| `m_wlast` | output | 1 | last beat of the burst | high | `clk` | 0 |
| `m_wvalid` | output | 1 | write data valid; never low inside a burst once AW is accepted | high | `clk` | 0 |
| `m_wready` | input | 1 | write data ready | high | `clk` | - |
| `m_bid` | input | 4 | write response ID; ignored (one write outstanding) | - | - | - |
| `m_bresp` | input | 2 | write response; anything but OKAY sets `err` | - | `clk` | - |
| `m_bvalid` | input | 1 | write response valid | high | `clk` | - |
| `m_bready` | output | 1 | 1 while waiting for the burst's response | high | `clk` | 0 |
| `m_arid` | output | 4 | read ID, constant `AXI_ID` | - | - | - |
| `m_araddr` | output | 32 | burst start address (word aligned) | - | `clk` | 0 |
| `m_arlen` | output | 8 | beats - 1 (0 to 15) | - | `clk` | - |
| `m_arsize` | output | 3 | constant 2 (4 bytes) | - | - | 2 |
| `m_arburst` | output | 2 | constant 01 (INCR) | - | - | 01 |
| `m_arprot` | output | 3 | constant 3'b000 | - | - | 3'b000 |
| `m_arvalid` | output | 1 | read address valid; held until `m_arready` | high | `clk` | 0 |
| `m_arready` | input | 1 | read address ready | high | `clk` | - |
| `m_rid` | input | 4 | read ID; ignored (one read outstanding) | - | - | - |
| `m_rdata` | input | 32 | read data | - | `clk` | - |
| `m_rresp` | input | 2 | read response; anything but OKAY sets `err` (the data is still used) | - | `clk` | - |
| `m_rlast` | input | 1 | last read beat; ends the burst (the beat count is not checked) | high | `clk` | - |
| `m_rvalid` | input | 1 | read data valid | high | `clk` | - |
| `m_rready` | output | 1 | 1 for the whole read data phase of a burst (never back-pressures) | high | `clk` | 0 |

### Internal signals used by the coverage checker

`tb/cov/Crypto_DMA_sva.sv` is bound to `Crypto_DMA_top` with `.*`, so a re-implementation must have these
names (width as seen by the checker).

| Signal | Width | Meaning |
|---|---|---|
| `rs_valid` | 1 | core-internal signal read by name by the checker |
| `rs_ready` | 1 | core-internal signal read by name by the checker |
| `ws_valid` | 1 | core-internal signal read by name by the checker |
| `ws_ready` | 1 | core-internal signal read by name by the checker |
| `rs_data` | [31:0] | core-internal signal read by name by the checker |
| `ws_data` | 1 | core-internal signal read by name by the checker |
| `in_valid` | 1 | core-internal signal read by name by the checker |
| `in_ready` | 1 | core-internal signal read by name by the checker |
| `in_aad` | 1 | core-internal signal read by name by the checker |
| `in_last` | 1 | core-internal signal read by name by the checker |
| `in_data` | [127:0] | core-internal signal read by name by the checker |
| `out_data` | 1 | core-internal signal read by name by the checker |
| `in_bytes` | [4:0] | core-internal signal read by name by the checker |
| `out_valid` | 1 | core-internal signal read by name by the checker |
| `out_ready` | 1 | core-internal signal read by name by the checker |
| `c_done` | 1 | core-internal signal read by name by the checker |
| `c_err` | 1 | core-internal signal read by name by the checker |
| `c_code` | [2:0] | core-internal signal read by name by the checker |
| `r_done` | 1 | core-internal signal read by name by the checker |
| `r_err` | 1 | core-internal signal read by name by the checker |
| `w_done` | 1 | core-internal signal read by name by the checker |
| `w_err` | 1 | core-internal signal read by name by the checker |
| `r_busy` | 1 | core-internal signal read by name by the checker |
| `w_busy` | 1 | core-internal signal read by name by the checker |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Crypto_DMA.md`](../ip/Crypto_DMA.md) (source: `scripts/apb/specs/Crypto_DMA.json`); do not edit by hand.

`Crypto_DMA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sl_key`, `sl_valid`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C310100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Message configuration, taken by CMD.start |
| 0x018 | KEY0 | WO | 0x00000000 | Key, 256 bits over eight write-only words (KEY7 holds bits 255:224, the first key bytes; AES-128 uses KEY7..KEY4); reads return 0 |
| 0x01C | KEY1 | WO | 0x00000000 | Key, 256 bits over eight write-only words (KEY7 holds bits 255:224, the first key bytes; AES-128 uses KEY7..KEY4); reads return 0 |
| 0x020 | KEY2 | WO | 0x00000000 | Key, 256 bits over eight write-only words (KEY7 holds bits 255:224, the first key bytes; AES-128 uses KEY7..KEY4); reads return 0 |
| 0x024 | KEY3 | WO | 0x00000000 | Key, 256 bits over eight write-only words (KEY7 holds bits 255:224, the first key bytes; AES-128 uses KEY7..KEY4); reads return 0 |
| 0x028 | KEY4 | WO | 0x00000000 | Key, 256 bits over eight write-only words (KEY7 holds bits 255:224, the first key bytes; AES-128 uses KEY7..KEY4); reads return 0 |
| 0x02C | KEY5 | WO | 0x00000000 | Key, 256 bits over eight write-only words (KEY7 holds bits 255:224, the first key bytes; AES-128 uses KEY7..KEY4); reads return 0 |
| 0x030 | KEY6 | WO | 0x00000000 | Key, 256 bits over eight write-only words (KEY7 holds bits 255:224, the first key bytes; AES-128 uses KEY7..KEY4); reads return 0 |
| 0x034 | KEY7 | WO | 0x00000000 | Key, 256 bits over eight write-only words (KEY7 holds bits 255:224, the first key bytes; AES-128 uses KEY7..KEY4); reads return 0 |
| 0x038 | IV0 | RW | 0x00000000 | 96-bit IV over three words (IV2 holds bits 95:64, the first IV bytes) |
| 0x03C | IV1 | RW | 0x00000000 | 96-bit IV over three words (IV2 holds bits 95:64, the first IV bytes) |
| 0x040 | IV2 | RW | 0x00000000 | 96-bit IV over three words (IV2 holds bits 95:64, the first IV bytes) |
| 0x044 | TAG_IN0 | RW | 0x00000000 | Decrypt: the expected tag over four words (TAG_IN3 holds bits 127:96, the first tag bytes); compared when the message ends |
| 0x048 | TAG_IN1 | RW | 0x00000000 | Decrypt: the expected tag over four words (TAG_IN3 holds bits 127:96, the first tag bytes); compared when the message ends |
| 0x04C | TAG_IN2 | RW | 0x00000000 | Decrypt: the expected tag over four words (TAG_IN3 holds bits 127:96, the first tag bytes); compared when the message ends |
| 0x050 | TAG_IN3 | RW | 0x00000000 | Decrypt: the expected tag over four words (TAG_IN3 holds bits 127:96, the first tag bytes); compared when the message ends |
| 0x054 | SRC_ADDR | RW | 0x00000000 | Source buffer (byte address, word aligned) |
| 0x058 | DST_ADDR | RW | 0x00000000 | Destination buffer (byte address, word aligned) |
| 0x05C | LEN | RW | 0x00000000 | Message lengths in bytes |
| 0x060 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x064 | STATUS | RO | core | Job state and result (cleared by start) |
| 0x068 | TAG0 | RO | core | Encrypt: the 128-bit tag (TAG3 holds bits 127:96, the first tag bytes); 0 after a decryption |
| 0x06C | TAG1 | RO | core | Encrypt: the 128-bit tag (TAG3 holds bits 127:96, the first tag bytes); 0 after a decryption |
| 0x070 | TAG2 | RO | core | Encrypt: the 128-bit tag (TAG3 holds bits 127:96, the first tag bytes); 0 after a decryption |
| 0x074 | TAG3 | RO | core | Encrypt: the 128-bit tag (TAG3 holds bits 127:96, the first tag bytes); 0 after a decryption |
| 0x078 | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x07C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C31 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `key256` | RW | 0x0 | 0 AES-128 (key in KEY7..KEY4), 1 AES-256 |
| CTRL | 1 | `decrypt` | RW | 0x0 | 0 encrypt, 1 decrypt |
| CTRL | 2 | `key_sel` | RW | 0x0 | 0 the KEY registers, 1 the sideload key port |
| CTRL | 6:3 | `tag_len` | RW | 0x0 | decrypt: bytes of TAG_IN compared (the first ones), 0 = 16 |
| KEY0 | 31:0 | `key[31:0]` | WO | 0x0 | AES key, big-endian |
| KEY1 | 31:0 | `key[63:32]` | WO | 0x0 | AES key, big-endian |
| KEY2 | 31:0 | `key[95:64]` | WO | 0x0 | AES key, big-endian |
| KEY3 | 31:0 | `key[127:96]` | WO | 0x0 | AES key, big-endian |
| KEY4 | 31:0 | `key[159:128]` | WO | 0x0 | AES key, big-endian |
| KEY5 | 31:0 | `key[191:160]` | WO | 0x0 | AES key, big-endian |
| KEY6 | 31:0 | `key[223:192]` | WO | 0x0 | AES key, big-endian |
| KEY7 | 31:0 | `key[255:224]` | WO | 0x0 | AES key, big-endian |
| IV0 | 31:0 | `iv[31:0]` | RW | 0x0 | initialization vector, big-endian |
| IV1 | 31:0 | `iv[63:32]` | RW | 0x0 | initialization vector, big-endian |
| IV2 | 31:0 | `iv[95:64]` | RW | 0x0 | initialization vector, big-endian |
| TAG_IN0 | 31:0 | `tag_in[31:0]` | RW | 0x0 | expected tag, big-endian, left-aligned when truncated |
| TAG_IN1 | 31:0 | `tag_in[63:32]` | RW | 0x0 | expected tag, big-endian, left-aligned when truncated |
| TAG_IN2 | 31:0 | `tag_in[95:64]` | RW | 0x0 | expected tag, big-endian, left-aligned when truncated |
| TAG_IN3 | 31:0 | `tag_in[127:96]` | RW | 0x0 | expected tag, big-endian, left-aligned when truncated |
| SRC_ADDR | 31:0 | `src_addr` | RW | 0x0 | AAD, then the text |
| DST_ADDR | 31:0 | `dst_addr` | RW | 0x0 | output text |
| LEN | 15:0 | `aad_len` | RW | 0x0 | AAD bytes |
| LEN | 31:16 | `txt_len` | RW | 0x0 | text bytes |
| CMD | 0 | `start` | WO (pulse) | 0x0 | start a job; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a job is running |
| STATUS | 1 | `err` | RO | core | the current / last job saw an AXI error response |
| STATUS | 2 | `gcm_err` | RO | core | the core reported an error (ERR_CODE) |
| STATUS | 5:3 | `err_code` | RO | core | core error cause: 1 format, 2 order, 3 too long, 4 sideload key not valid |
| STATUS | 6 | `tag_ok` | RO | core | the last decryption's tag matched |
| TAG0 | 31:0 | `tag[31:0]` | RO | core | authentication tag of the last encryption |
| TAG1 | 31:0 | `tag[63:32]` | RO | core | authentication tag of the last encryption |
| TAG2 | 31:0 | `tag[95:64]` | RO | core | authentication tag of the last encryption |
| TAG3 | 31:0 | `tag[127:96]` | RO | core | authentication tag of the last encryption |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended with an AXI or core error |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C310100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), KEY0 (0x018), KEY1 (0x01C), KEY2 (0x020), KEY3 (0x024), KEY4 (0x028), KEY5 (0x02C), KEY6 (0x030), KEY7 (0x034), IV0 (0x038), IV1 (0x03C), IV2 (0x040), TAG_IN0 (0x044), TAG_IN1 (0x048), TAG_IN2 (0x04C), TAG_IN3 (0x050), SRC_ADDR (0x054), DST_ADDR (0x058), LEN (0x05C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x060; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x064) for the core's live `busy`, `err`, `gcm_err`, `err_code`, `tag_ok`; it needs no clearing.
7. Read TAG0 (0x068), TAG1 (0x06C), TAG2 (0x070), TAG3 (0x074) for the core's live `tag[31:0]`, `tag[63:32]`, `tag[95:64]`, `tag[127:96]`; it needs no clearing.
8. Read CYCLES (0x078) for the core's live `cycles`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL, KEY, IV (and TAG_IN when decrypting).
2. Write SRC_ADDR, DST_ADDR (word aligned) and LEN.
3. Write IRQ_ENABLE and CMD.start = 1.
4. Wait for irq; read TAG (encrypt) or STATUS.tag_ok (decrypt); write 1s to IRQ_STATUS.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Buffers and byte order

Source buffer at `src_addr`: the AAD (`aad_len` bytes) padded to a 16-byte boundary, then the text
(`txt_len` bytes) padded to a 16-byte boundary; nbl blocks, 4 x nbl words in all. Bytes are in
address order: byte 0 of a block is the byte at the lowest address, bits [7:0] of the block's
first word. The padding bytes are ignored (the core is told how many bytes of the last AAD block
and the last text block are valid), so they may hold anything.

Output buffer at `dst_addr`: ntb blocks (`txt_len` rounded up to 16 bytes), the same byte order,
bytes past `txt_len` written as 0. Nothing is written past the last block. Each 32-bit word is
converted to and from the core's big-endian block by a byte swap: word k of a block holds block
bytes 4k to 4k + 3, byte 4k in bits [7:0].

### 3.2 Job start

At the edge where `start && !busy` (*the start edge*): `busy` <= 1; `err`, `gcm_err`, `err_code`,
`cycles` <= 0; the AES-GCM core starts (taking `key256`, `decrypt`, `key_sel`, `tag_len`, `key`,
`iv`); the read engine `u_rd` starts on 4 x nbl words from `src_addr` if nbl != 0, and the write
engine `u_wr` starts on 4 x ntb words to `dst_addr` if ntb != 0. `start` while `busy` is ignored.

### 3.3 Message flow

Read words are collected four at a time into a block (the first word is the most significant
32 bits after the byte swap). A full block is offered to the core: blocks 0 to nab - 1 as AAD
(`in_aad`), the rest as text; the last AAD block carries `aad_len` mod 16 valid bytes when that is
not 0, the last text block `txt_len` mod 16 likewise, and the last block of the message is marked
last. The read stream is held while a full block waits for the core.

When the message has no text, a closing empty block (0 bytes, last) is sent after the last AAD
block; when it has neither AAD nor text, the closing block is the only one. Each output block of
the core is split into four words (byte swapped) for the write engine; the core is held while
the previous output block has not been taken.

Encrypt: `tag` holds the tag from the core's `done`. Decrypt: the core compares its tag with the
first `tag_len` bytes of `tag_in` in constant time and gives only `tag_ok`; the plaintext is
written before the tag is checked, so software must use it only when `tag_ok` = 1.

### 3.4 Core error

If the core reports an error (with this wrapper only error 4 can occur: `key_sel` = 1 and
`sl_valid` = 0 at start), `gcm_err` <= 1, `err_code` <= the code, and the job enters drop mode
until it ends: read words are taken and discarded, no more blocks go to the core, and the write
engine is fed zero words, so the job still reads all 4 x nbl and writes all 4 x ntb words (the
output buffer ends up holding zeros where no output block was produced).

### 3.5 Job end

`done` = `busy` && the core has finished (its `done` or an error) && each started engine has
finished (its `done`) && neither engine is busy. `done` is combinational from these flops; at the
same edge `busy` <= 0. `err` is set by an engine finishing with an AXI error. `err_irq` = `done`
&& (`err` \|\| `gcm_err`). `cycles` counts every edge after the start edge while `busy` is 1,
including the edge where `busy` falls, so it is the job length in clocks. It is counted by this
wrapper, not by the engines.

Throughput is set by the core: one text block per Nr + 1 clocks (11 for AES-128, 15 for AES-256),
one AAD block per 4 clocks, plus the core's key setup at the start.

### 3.6 AXI data mover

The core moves data with `rtl/soc_ss_axi_engine.sv` (instances `u_rd` for reads and `u_wr` for writes, FIFO depth 32
words per direction). One job reads `len` 32-bit words from `src` into the read stream (if the job
reads) and writes `len` words taken from the write stream to `dst` (if it writes). Bits [1:0] of
both addresses are ignored.

- Start: at the edge where `start` is accepted (not busy), `busy` <= 1, `err` <= 0,
  `cycles` <= 0 and the job parameters are latched. `start` while `busy` is ignored.
- Bursts: INCR, AxSIZE 2, WSTRB 4'hF, length min(16, words left, words to the next 4 KB
  boundary), so no burst crosses 4 KB. One read and one write burst may be outstanding at the same
  time, never two of the same kind. All IDs are the core's constant ID.
- Read side: a read burst is requested (ARVALID from the clock after the start edge at the
  earliest) only when the read FIFO has room for 16 more words, so `m_rready` is 1 for the whole
  data phase. Every RVALID beat goes into the FIFO; RLAST ends the burst.
- Write side: a write burst is requested only when the write FIFO already holds all of its beats,
  so once AW is accepted WVALID stays high until WLAST; then BREADY waits for the response.
- Error: any RRESP or BRESP other than OKAY sets `err` until the next start; the job still runs to
  the end with the data it got.
- Done: at the edge where both sides have finished every burst (all responses received) and the
  read FIFO is empty, `busy` <= 0 and `done` is 1 for one clock. `cycles` counts every edge while
  `busy` is 1, so it holds the number of clocks from the start edge to the done edge and keeps it
  until the next start. A job with `len` = 0 finishes at the edge after the start (`cycles` = 1).

The two engines share the AXI4 manager port: `u_rd` drives only AR / R, `u_wr` only AW / W / B.
Both use ID `AXI_ID`. The engines' own `busy`, `done`, `err` and `cycles` are internal; this core's outputs are defined in §3.5.

### 3.7 Reset

`rst_n` low: no job (`busy` = 0), the core reset (`tag` = 0, `tag_ok` = 0), all status 0, all AXI
valid / ready outputs 0. A job in progress is abandoned.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd9 | 4'd0 to 4'd15 | value of `m_awid` and `m_arid` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `start` while `busy` | ignored |
| `len` = 0 | no bus traffic, `done` one clock after the start, `cycles` = 1 |
| buffer crossing a 4 KB boundary | the burst is split at the boundary |
| AXI error response (read or write) | `err` set until the next start; the job completes; the affected words are still written |
| unaligned `src` / `dst` | bits [1:0] ignored |
| reset in the middle of a job | `busy` = 0 and every AXI valid / ready output 0 at once; the subordinate must be reset too |
| `aad_len` = `txt_len` = 0 | no bus traffic; one empty last block to the core; `tag` is the tag of the empty message |
| AAD only (`txt_len` = 0) | no writes; a closing empty block after the AAD |
| text only (`aad_len` = 0) | every block is text |
| AXI error response | `err` = 1 and `err_irq`; the job completes with the data received; `tag` / `tag_ok` are not meaningful |
| `key_sel` = 1, `sl_valid` = 0 | core error 4: `gcm_err` = 1, drop mode (§3.4), the job still ends with `done` and `err_irq` |
| decrypt with a wrong or truncated tag | `tag_ok` = 0 (for a truncated tag only the first `tag_len` bytes are compared); the plaintext is written anyway |
| `aad_len` / `txt_len` changed during a job | not allowed: the block counts are computed from the live inputs |

## 6. TB check map

Messages are printed by `tb/Crypto_DMA_tb.sv` through `fail()` as `ERROR: <message>`. The TB runs 48
messages from `tb/Crypto_DMA_vec.svh` (made by `scripts/crypto_dma/gen_vec.py`: random keys,
IVs, AAD of 0 to 69 bytes and text of 0 to 1000 bytes, AES-128 and AES-256, encrypt and decrypt
with right, truncated and corrupted tags; expected values from Python cryptography) from random
buffers against `tb/soc_ss_axi_mem.svh`, which checks every burst and injects random stalls and
error responses. Every job fills the source padding with random bytes and the output buffer plus
one block with a marker.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "busy low after start" | `busy` = 1 in the clock after the start edge | §3.2 |
| "case" | per message: the job ends within the time limit; `err` / `gcm_err` exactly when an error was injected; no core error otherwise; every output byte (zero padding included) correct; `tag` (encrypt) and `tag_ok` (decrypt) correct | §3.1, §3.3, §3.5 |
| "ERR interrupt count" | one `err_irq` per failed job (AXI error or core error), none otherwise | §3.5 |
| "sideload: GCM_ERR" | `key_sel` = 1 with `sl_valid` = 0 gives `gcm_err` = 1 and `err_code` = 4, and the job still ends | §3.4 |
| "written past the output" | the word after the last output block is untouched | §3.1 |
| "CYCLES = 0" | `cycles` non-zero after every job | §3.5 |
| "largest message timed out" | 65535 AAD bytes + 65535 text bytes (AES-256) end within 2000000 clocks | §3.5 |
| "largest message: ERR" | no error on the largest message | §3.5 |
| "largest message" | the largest message reads exactly 8192 x 4 words and writes 4096 x 4 | §3.2 |
| "not idle in reset" | reset mid-job: `busy`, `m_awvalid`, `m_arvalid`, `m_wvalid` all 0 | §3.7 |

The TB also prints `LAT Crypto_DMA axi R|W <clocks>` for every burst (performance report, not a
check). A second `start` while busy is issued in some jobs and must be ignored ("case" timing and
the DONE count).

### Coverage-closure assertions

From `tb/cov/Crypto_DMA_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_reset_idle | while `!rst_n` (reset): `!busy && !done && !err && !gcm_err && !in_valid && !ws_valid` | §3 |
| a_busy | always holds: `busy == m_run && done == m_fin && err == m_ax && gcm_err == m_gerr && err_code == m_code && err_irq == (m_fin && (m_ax \|\| m_gerr))` | §3 |
| a_rd_job | always holds: `u_rd.start == (go && m_nbl != 0) && (!u_rd.start \|\| (u_rd.src == src_addr && u_rd.len == {m_nbl, 2'b00} && u_rd.rd_en && !u_rd.wr_en))` | §3 |
| a_wr_job | always holds: `u_wr.start == (go && m_ntb != 0) && (!u_wr.start \|\| (u_wr.dst == dst_addr && u_wr.len == {1'b0, m_ntb, 2'b00} && !u_wr.rd_en && u_wr.wr_en))` | §3 |
| a_rs_ready | always holds: `rs_ready == (m_run && (m_drop \|\| !m_ifull))` | §3 |
| a_in_valid | always holds: `in_valid == (!m_drop && m_run && (m_term \|\| m_ifull))` | §3 |
| a_in_term | whenever `in_valid && m_term`: `in_data == 0 && in_bytes == 0 && in_last && !in_aad` | §3 |
| a_in_block | whenever `in_valid && !m_term`: `in_data == m_ib && in_aad == (m_bi < 14'(m_nab)) && in_last == (m_bi >= 14'(m_nab) && m_bi + 1 == m_nbl) && in_bytes == ((m_bi < 14'(m_nab)) ? ((m_last_aad && aad_len[3:0] != 0) ? 5'(aad_len[3:0]) : 5'd16) : ((m_bi + 1 == m_nbl && txt_len[3:0] != 0) ? 5'(txt_len[3:0]) : 5'd16))` | §3 |
| a_out_ready | always holds: `out_ready == !m_ofull` | §3 |
| a_out_words | always holds: `ws_valid == (m_ofull \|\| m_drop) && (!ws_valid \|\| ws_data == (m_drop ? 32'd0 : bsw(m_ob[127:96])))` | §3 |

### Further TB checks

| Check (TB message) | What it requires | Spec |
|---|---|---|
| "random job timed out" | fails when `busy` (`tb/Crypto_DMA_tb.sv` line 121) | §3 |
| "random job" | fails when `err \|\| gcm_err` (`tb/Crypto_DMA_tb.sv` line 122) | §3 |
