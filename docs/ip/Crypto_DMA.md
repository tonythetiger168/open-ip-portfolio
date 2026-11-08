# AES-GCM engine with an AXI4 DMA: AAD and text read from memory, the output text written back, tag in registers

Protocol IP `Crypto_DMA`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Crypto_DMA_top` (`rtl/Crypto_DMA_top.sv`) |
| Register interface | APB4 slave `Crypto_DMA_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C310100 (code 0x5C31, version 1.0) |
| Registers | 31 words, 0x000 to 0x078 |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | 33 pass-through |

## Overview

Crypto_DMA: AES-GCM engine with an AXI4 DMA (AXI4 manager, APB4 registers) The unchanged AES_GCM_top core (AES-128 / AES-256, 96-bit IV) streaming a message from memory to memory.

- Source buffer at SRC_ADDR: the AAD (AAD_LEN bytes) padded with zeros to
a 16-byte boundary, then the text (TXT_LEN bytes). Bytes are in address
order: byte 0 of a block is the byte at the lowest address (bits 7:0 of
the first word).
- The output text (ciphertext, or plaintext when decrypting) is written
to DST_ADDR, TXT_LEN bytes rounded up to 16 with zero padding.
- Encrypt: TAG holds the tag when the job ends. Decrypt: TAG_OK says
whether TAG_IN (first TAG_LEN bytes) matched. The plaintext is written
before the tag is checked: software uses it only when TAG_OK is 1.
- Two soc_ss_axi_engine instances share the AXI4 manager port: one reads
(AR / R channels), one writes (AW / W / B), so the read and the write
lengths can differ. Both use ID AXI_ID.
- DONE interrupt when the job ends (both transfers and the tag); ERR as
well when it saw an AXI error response (STATUS.err) or a core error
(STATUS.gcm_err with the core's ERR_CODE).
- AXI bursts of up to 16 beats, never across 4 KB.

Features:

- The unchanged AES_GCM_top core (AES-128 / AES-256, 96-bit IV, NIST SP 800-38D).
- Source: AAD_LEN bytes of AAD padded with zeros to 16 bytes, then TXT_LEN bytes of text; byte 0 of a block is the lowest address.
- The output text goes to DST_ADDR, rounded up to 16 bytes with zero padding.
- Decrypt: the plaintext is written before the tag is checked; use it only when STATUS.tag_ok is 1.
- Two copies of the shared AXI4 engine, one for reads and one for writes, on one manager port.

sl_key / sl_valid are the sideload key port of the core (CTRL.key_sel = 1); they pass through unchanged.
m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time. A read burst is issued only when its data has room, a write burst only when all its data is ready.

## Files

| File | Content |
|---|---|
| `rtl/Crypto_DMA_top.sv` | protocol core |
| `rtl/Crypto_DMA_apb.sv` | APB4 register wrapper (generated) |
| `tb/Crypto_DMA_tb.sv` | core testbench |
| `tb/Crypto_DMA_apb_tb.sv`, `tb/apb/Crypto_DMA_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Crypto_DMA_sva.sv`, `tb/cov/Crypto_DMA_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Crypto_DMA.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`Crypto_DMA_apb` has the core's parameters and passes them to `Crypto_DMA_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd9` |

## Wrapper pins

Pins of `Crypto_DMA_apb`. Widths of the pass-through pins are at the default parameters.

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
| `m_awid` | output | 4 | protocol pin, core port `m_awid` |
| `m_awaddr` | output | 32 | protocol pin, core port `m_awaddr` |
| `m_awlen` | output | 8 | protocol pin, core port `m_awlen` |
| `m_awsize` | output | 3 | protocol pin, core port `m_awsize` |
| `m_awburst` | output | 2 | protocol pin, core port `m_awburst` |
| `m_awprot` | output | 3 | protocol pin, core port `m_awprot` |
| `m_awvalid` | output | 1 | protocol pin, core port `m_awvalid` |
| `m_awready` | input | 1 | protocol pin, core port `m_awready` |
| `m_wdata` | output | 32 | protocol pin, core port `m_wdata` |
| `m_wstrb` | output | 4 | protocol pin, core port `m_wstrb` |
| `m_wlast` | output | 1 | protocol pin, core port `m_wlast` |
| `m_wvalid` | output | 1 | protocol pin, core port `m_wvalid` |
| `m_wready` | input | 1 | protocol pin, core port `m_wready` |
| `m_bid` | input | 4 | protocol pin, core port `m_bid` |
| `m_bresp` | input | 2 | protocol pin, core port `m_bresp` |
| `m_bvalid` | input | 1 | protocol pin, core port `m_bvalid` |
| `m_bready` | output | 1 | protocol pin, core port `m_bready` |
| `m_arid` | output | 4 | protocol pin, core port `m_arid` |
| `m_araddr` | output | 32 | protocol pin, core port `m_araddr` |
| `m_arlen` | output | 8 | protocol pin, core port `m_arlen` |
| `m_arsize` | output | 3 | protocol pin, core port `m_arsize` |
| `m_arburst` | output | 2 | protocol pin, core port `m_arburst` |
| `m_arprot` | output | 3 | protocol pin, core port `m_arprot` |
| `m_arvalid` | output | 1 | protocol pin, core port `m_arvalid` |
| `m_arready` | input | 1 | protocol pin, core port `m_arready` |
| `m_rid` | input | 4 | protocol pin, core port `m_rid` |
| `m_rdata` | input | 32 | protocol pin, core port `m_rdata` |
| `m_rresp` | input | 2 | protocol pin, core port `m_rresp` |
| `m_rlast` | input | 1 | protocol pin, core port `m_rlast` |
| `m_rvalid` | input | 1 | protocol pin, core port `m_rvalid` |
| `m_rready` | output | 1 | protocol pin, core port `m_rready` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `key256` | input | 1 | CTRL[0:0] |
| `decrypt` | input | 1 | CTRL[1:1] |
| `key_sel` | input | 1 | CTRL[2:2] |
| `tag_len` | input | 4 | CTRL[6:3] |
| `key` | input | 256 | KEY0[31:0], KEY1[31:0], KEY2[31:0], KEY3[31:0], KEY4[31:0], KEY5[31:0], KEY6[31:0], KEY7[31:0] |
| `iv` | input | 96 | IV0[31:0], IV1[31:0], IV2[31:0] |
| `tag_in` | input | 128 | TAG_IN0[31:0], TAG_IN1[31:0], TAG_IN2[31:0], TAG_IN3[31:0] |
| `sl_key` | input | 256 | pin (pass-through) |
| `sl_valid` | input | 1 | pin (pass-through) |
| `src_addr` | input | 32 | SRC_ADDR[31:0] |
| `dst_addr` | input | 32 | DST_ADDR[31:0] |
| `aad_len` | input | 16 | LEN[15:0] |
| `txt_len` | input | 16 | LEN[31:16] |
| `start` | input | 1 | CMD |
| `busy` | output | 1 | STATUS[0:0] |
| `err` | output | 1 | STATUS[1:1] |
| `gcm_err` | output | 1 | STATUS[2:2] |
| `err_code` | output | 3 | STATUS[5:3] |
| `tag_ok` | output | 1 | STATUS[6:6] |
| `tag` | output | 128 | TAG0[31:0], TAG1[31:0], TAG2[31:0], TAG3[31:0] |
| `cycles` | output | 32 | CYCLES[31:0] |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `err_irq` | output | 1 | IRQ_STATUS.ERR |
| `m_awid` | output | 4 | pin (pass-through) |
| `m_awaddr` | output | 32 | pin (pass-through) |
| `m_awlen` | output | 8 | pin (pass-through) |
| `m_awsize` | output | 3 | pin (pass-through) |
| `m_awburst` | output | 2 | pin (pass-through) |
| `m_awprot` | output | 3 | pin (pass-through) |
| `m_awvalid` | output | 1 | pin (pass-through) |
| `m_awready` | input | 1 | pin (pass-through) |
| `m_wdata` | output | 32 | pin (pass-through) |
| `m_wstrb` | output | 4 | pin (pass-through) |
| `m_wlast` | output | 1 | pin (pass-through) |
| `m_wvalid` | output | 1 | pin (pass-through) |
| `m_wready` | input | 1 | pin (pass-through) |
| `m_bid` | input | 4 | pin (pass-through) |
| `m_bresp` | input | 2 | pin (pass-through) |
| `m_bvalid` | input | 1 | pin (pass-through) |
| `m_bready` | output | 1 | pin (pass-through) |
| `m_arid` | output | 4 | pin (pass-through) |
| `m_araddr` | output | 32 | pin (pass-through) |
| `m_arlen` | output | 8 | pin (pass-through) |
| `m_arsize` | output | 3 | pin (pass-through) |
| `m_arburst` | output | 2 | pin (pass-through) |
| `m_arprot` | output | 3 | pin (pass-through) |
| `m_arvalid` | output | 1 | pin (pass-through) |
| `m_arready` | input | 1 | pin (pass-through) |
| `m_rid` | input | 4 | pin (pass-through) |
| `m_rdata` | input | 32 | pin (pass-through) |
| `m_rresp` | input | 2 | pin (pass-through) |
| `m_rlast` | input | 1 | pin (pass-through) |
| `m_rvalid` | input | 1 | pin (pass-through) |
| `m_rready` | output | 1 | pin (pass-through) |

## APB wrapper

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

## Programming sequence

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

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Crypto_DMA sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Crypto_DMA syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Crypto_DMA_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Crypto_DMA apb` | `TEST PASSED: Crypto_DMA_apb`, then Yosys without `ERROR` | console, `work/Crypto_DMA_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Crypto_DMA`<br>`bash scripts/cov/run_cov.sh Crypto_DMA_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Crypto_DMA/score.json`, `work/cov/Crypto_DMA_apb/score.json` |

Expected end of a step 4 run:

```
===== Crypto_DMA =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Crypto_DMA_tb.sv`): drives `Crypto_DMA_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Crypto_DMA_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Crypto_DMA_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Crypto_DMA_sva.sv`, `tb/cov/Crypto_DMA_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Crypto_DMA_top.sv` | not run | | | | | |
| wrapper `rtl/Crypto_DMA_apb.sv` | not run | | | | | |
