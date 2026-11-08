# AES-GCM authenticated encryption (NIST SP 800-38D), AES-128 / AES-256, 96-bit IV: one AES round per clock, GHASH overlapped with the AES, streaming AAD and text, constant-time tag check, sideload key port

Protocol IP `AES_GCM`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `AES_GCM_top` (`rtl/AES_GCM_top.sv`) |
| Register interface | APB4 slave `AES_GCM_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x41470100 (code 0x4147, version 1.0) |
| Registers | 37 words, 0x000 to 0x090 |
| Interrupts | 5 sources into one level-high `irq` |
| Data streams | IN (to the core), OUT (from the core) |
| Protocol pins | 2 pass-through |

## Overview

AES_GCM_top v1.0: AES-GCM authenticated encryption engine (NIST SP 800-38D) with AES-128 and AES-256 (FIPS 197) and a 96-bit IV.

- AES: one round per clock with the round keys expanded on the fly (four
S-boxes for the key, sixteen for the state); a block takes Nr + 1 clocks
(11 for AES-128, 15 for AES-256). Only the forward cipher is needed: GCM
decrypts with the same key stream.
- The AES runs ahead of the data: after H = E(K, 0) and E(K, J0) it
encrypts the next counter block while the current one is being used, so
text blocks stream at one per Nr + 1 clocks.
- GHASH: multiplication by H in GF(2^128), 32 bits of the operand per
clock (4 clocks per block); it runs in parallel with the AES of the
next counter block. AAD blocks stream at one per 4 clocks.
- A message is started with start (key, IV and mode are taken then), then
streamed in as 128-bit blocks: first the AAD blocks (in_aad = 1), then
the text blocks; only the last block of each kind may be partial
(in_bytes 1..15), and in_last marks the last block of the message. A
block with in_bytes = 0 and in_last = 1 ends a message without adding
data (an empty message, or AAD whose last block was already sent).
Data is big-endian: byte 0 of a block is in_data[127:120].
- Each text block comes out on the output port (ciphertext when
encrypting, plaintext when decrypting), bytes past out_bytes zero.
- Encrypt: done pulses with the 128-bit tag on tag. Decrypt: the tag is
computed, compared in constant time with the first tag_len bytes of
tag_in, and only the result (tag_ok) is given: the computed tag of a
decryption is never output, so the engine cannot be used to forge a
tag. The plaintext comes out before the tag is checked: it must be held
back until tag_ok.
- Key: from the key port, or (key_sel = 1) from a sideload port that a
key manager (e.g. Root_of_Trust key_out) drives and software cannot
read. The key, H, E(K, J0), the AES and GHASH state are cleared when a
message ends (done, an error, or clr).
- Errors (err pulses, err_code holds the cause, the message is dropped):
1 format (in_bytes > 16, or 0 without in_last), 2 order (AAD after text,
a block after a partial block of its kind), 3 too long (AAD over
2^LEN_W - 1 bytes, text over 2^LEN_W - 32 bytes: at LEN_W = 36 the
SP 800-38D limit of 2^32 - 2 counter blocks), 4 sideload key not valid.

Features:

- AES-GCM (NIST SP 800-38D) encryption and decryption with AES-128 or AES-256 (FIPS 197) and a 96-bit IV; checked against the NIST CAVP GCM vectors and Project Wycheproof.
- AES: one round per clock, round keys expanded on the fly (no round-key storage); 11 clocks per block for AES-128, 15 for AES-256. The AES encrypts the next counter block while the current one is used, so text streams at one block per 11 / 15 clocks.
- GHASH: 32 bits of the operand per clock with a balanced partial-product tree (4 clocks per block), in parallel with the AES; AAD streams at one block per 4 clocks.
- Streaming: any AAD length (up to 2^36 - 1 bytes) and text length (up to 2^36 - 32 bytes, the SP 800-38D limit), partial last blocks, an optional empty end block; output back-pressure.
- Decrypt: the tag is checked in constant time against the first 1-16 bytes of TAG_IN and only the result (STATUS.tag_ok) is given; the computed tag is never readable after a decryption, so the engine cannot be used to forge tags.
- Key: the write-only KEY registers or a sideload port (sl_key / sl_valid, passing through the wrapper) for a key manager such as Root_of_Trust's key_out; the key, H, E(K, J0) and all AES and GHASH state are cleared at the end of every message, on an error and on CMD.clr.
- Errors drop the message: block size over 16 or an empty block without last (1), AAD after text or a block after a partial block of its kind (2), length over the limit (3), sideload key not valid at start (4).

Data is big-endian: byte 0 of a block is bits 127:120, which is IN3 / OUT3 bits 31:24.
The plaintext of a decryption comes out before the tag is checked: software must not use it before IRQ DONE with STATUS.tag_ok = 1.
Only 96-bit IVs, the length SP 800-38D recommends; other IV lengths would first need a GHASH over the IV.
Each block takes five register writes (IN0..IN4) and an output block five reads: for line-rate use, drive the core's stream ports from a DMA.
Not implemented (public functional baseline): side-channel (power / EM) countermeasures such as masking, and fault-injection detection; a key manager and a TRNG for IVs are outside the IP.

## Files

| File | Content |
|---|---|
| `rtl/AES_GCM_top.sv` | protocol core |
| `rtl/AES_GCM_apb.sv` | APB4 register wrapper (generated) |
| `tb/AES_GCM_tb.sv` | core testbench |
| `tb/AES_GCM_apb_tb.sv`, `tb/apb/AES_GCM_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/AES_GCM_sva.sv`, `tb/cov/AES_GCM_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/AES_GCM.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`AES_GCM_apb` has the core's parameters and passes them to `AES_GCM_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `LEN_W` | int | `36` |

## Wrapper pins

Pins of `AES_GCM_apb`. Widths of the pass-through pins are at the default parameters.

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
| `key256` | input | 1 | CTRL[0:0] |
| `decrypt` | input | 1 | CTRL[1:1] |
| `key_sel` | input | 1 | CTRL[2:2] |
| `tag_len` | input | 4 | CTRL[6:3] |
| `key` | input | 256 | KEY0[31:0], KEY1[31:0], KEY2[31:0], KEY3[31:0], KEY4[31:0], KEY5[31:0], KEY6[31:0], KEY7[31:0] |
| `iv` | input | 96 | IV0[31:0], IV1[31:0], IV2[31:0] |
| `tag_in` | input | 128 | TAG_IN0[31:0], TAG_IN1[31:0], TAG_IN2[31:0], TAG_IN3[31:0] |
| `sl_key` | input | 256 | pin (pass-through) |
| `sl_valid` | input | 1 | pin (pass-through) |
| `start` | input | 1 | CMD[0:0] |
| `clr` | input | 1 | CMD[1:1] |
| `busy` | output | 1 | STATUS[0:0] |
| `in_valid` | input | 1 | IN commit / FLAGS |
| `in_ready` | output | 1 | IN handshake |
| `in_data` | input | 128 | IN0[31:0], IN1[31:0], IN2[31:0], IN3[31:0] |
| `in_bytes` | input | 5 | IN4[4:0] |
| `in_aad` | input | 1 | IN4[5:5] |
| `in_last` | input | 1 | IN4[6:6] |
| `out_valid` | output | 1 | OUT capture |
| `out_ready` | input | 1 | OUT handshake |
| `out_data` | output | 128 | OUT0[31:0], OUT1[31:0], OUT2[31:0], OUT3[31:0] |
| `out_bytes` | output | 5 | OUT4[4:0] |
| `out_last` | output | 1 | OUT4[5:5] |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `tag` | output | 128 | TAG0[31:0], TAG1[31:0], TAG2[31:0], TAG3[31:0] |
| `tag_ok` | output | 1 | STATUS[1:1] |
| `err` | output | 1 | IRQ_STATUS.ERR |
| `err_code` | output | 3 | STATUS[4:2] |

## APB wrapper

`AES_GCM_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sl_key`, `sl_valid`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41470100 | IP identification: code, major and minor version |
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
| 0x054 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x058 | IN0 | RW | 0x00000000 | Input block: IN0..IN3 the 128-bit block (IN3 holds bytes 0-3), then IN4 with the byte count, AAD flag and last flag, which commits it |
| 0x05C | IN1 | RW | 0x00000000 | Input block: IN0..IN3 the 128-bit block (IN3 holds bytes 0-3), then IN4 with the byte count, AAD flag and last flag, which commits it |
| 0x060 | IN2 | RW | 0x00000000 | Input block: IN0..IN3 the 128-bit block (IN3 holds bytes 0-3), then IN4 with the byte count, AAD flag and last flag, which commits it |
| 0x064 | IN3 | RW | 0x00000000 | Input block: IN0..IN3 the 128-bit block (IN3 holds bytes 0-3), then IN4 with the byte count, AAD flag and last flag, which commits it |
| 0x068 | IN4 | RW | 0x00000000 | Input block: IN0..IN3 the 128-bit block (IN3 holds bytes 0-3), then IN4 with the byte count, AAD flag and last flag, which commits it |
| 0x06C | OUT0 | RO (pop) | 0x00000000 | Output text block (ciphertext when encrypting, plaintext when decrypting): read OUT0..OUT3, then OUT4, which pops it |
| 0x070 | OUT1 | RO (pop) | 0x00000000 | Output text block (ciphertext when encrypting, plaintext when decrypting): read OUT0..OUT3, then OUT4, which pops it |
| 0x074 | OUT2 | RO (pop) | 0x00000000 | Output text block (ciphertext when encrypting, plaintext when decrypting): read OUT0..OUT3, then OUT4, which pops it |
| 0x078 | OUT3 | RO (pop) | 0x00000000 | Output text block (ciphertext when encrypting, plaintext when decrypting): read OUT0..OUT3, then OUT4, which pops it |
| 0x07C | OUT4 | RO (pop) | 0x00000000 | Output text block (ciphertext when encrypting, plaintext when decrypting): read OUT0..OUT3, then OUT4, which pops it |
| 0x080 | TAG0 | RO | core | Encrypt: the 128-bit tag (TAG3 holds bits 127:96, the first tag bytes); 0 after a decryption |
| 0x084 | TAG1 | RO | core | Encrypt: the 128-bit tag (TAG3 holds bits 127:96, the first tag bytes); 0 after a decryption |
| 0x088 | TAG2 | RO | core | Encrypt: the 128-bit tag (TAG3 holds bits 127:96, the first tag bytes); 0 after a decryption |
| 0x08C | TAG3 | RO | core | Encrypt: the 128-bit tag (TAG3 holds bits 127:96, the first tag bytes); 0 after a decryption |
| 0x090 | STATUS | RO | core | Engine state and result |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x094 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4147 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
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
| CMD | 0 | `start` | WO (pulse) | 0x0 | start a message with CTRL, KEY (or the sideload key) and IV; ignored while busy |
| CMD | 1 | `clr` | WO (pulse) | 0x0 | abort the message and clear the key, state and pending output |
| IN0 | 31:0 | `in_data[31:0]` | RW | 0x0 | block, big-endian |
| IN1 | 31:0 | `in_data[63:32]` | RW | 0x0 | block, big-endian |
| IN2 | 31:0 | `in_data[95:64]` | RW | 0x0 | block, big-endian |
| IN3 | 31:0 | `in_data[127:96]` | RW | 0x0 | block, big-endian |
| IN4 | 4:0 | `in_bytes` | RW | 0x0 | valid bytes 0..16 (0 only with in_last: end of message) |
| IN4 | 5 | `in_aad` | RW | 0x0 | 1 AAD block, 0 text block |
| IN4 | 6 | `in_last` | RW | 0x0 | last block of the message |
| OUT0 | 31:0 | `out_data[31:0]` | RO (pop) | 0x0 | block, big-endian, bytes past out_bytes zero |
| OUT1 | 31:0 | `out_data[63:32]` | RO (pop) | 0x0 | block, big-endian, bytes past out_bytes zero |
| OUT2 | 31:0 | `out_data[95:64]` | RO (pop) | 0x0 | block, big-endian, bytes past out_bytes zero |
| OUT3 | 31:0 | `out_data[127:96]` | RO (pop) | 0x0 | block, big-endian, bytes past out_bytes zero |
| OUT4 | 4:0 | `out_bytes` | RO (pop) | 0x0 | valid bytes 1..16 |
| OUT4 | 5 | `out_last` | RO (pop) | 0x0 | the input block was marked last |
| TAG0 | 31:0 | `tag[31:0]` | RO | core | authentication tag of the last encryption |
| TAG1 | 31:0 | `tag[63:32]` | RO | core | authentication tag of the last encryption |
| TAG2 | 31:0 | `tag[95:64]` | RO | core | authentication tag of the last encryption |
| TAG3 | 31:0 | `tag[127:96]` | RO | core | authentication tag of the last encryption |
| STATUS | 0 | `busy` | RO | core | a message is running |
| STATUS | 1 | `tag_ok` | RO | core | the last decryption's tag matched |
| STATUS | 4:2 | `err_code` | RO | core | cause of the last error: 1 format, 2 block order, 3 too long, 4 sideload key not valid |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a message finished: TAG (encrypt) or STATUS.tag_ok (decrypt) is valid |
| 1 | ERR | a message was dropped (STATUS.err_code gives the cause) |
| 2 | IN_DONE | IN beat accepted by the core |
| 3 | IN_OVF | write to IN while full (dropped) |
| 4 | OUT_AVAIL | OUT captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | IN_FULL | IN holds a beat the core has not taken |
| 1 | OUT_AVAIL | OUT holds an unread beat |

### Streams

* **IN** feeds `in_data`, `in_bytes`, `in_aad`, `in_last`/`in_valid`. Writing IN4 commits the beat: FLAGS.IN_FULL is set and `in_valid` stays high until the core's `in_ready`; then IN_DONE is set. A write while full is dropped and sets IN_OVF.
* **OUT** takes `out_data`, `out_bytes`, `out_last` from the core with `out_valid` / `out_ready`: `out_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ OUT_AVAIL. Reading OUT4 pops it. Nothing is dropped: the core holds its data until the register is free.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41470100.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), KEY0 (0x018), KEY1 (0x01C), KEY2 (0x020), KEY3 (0x024), KEY4 (0x028), KEY5 (0x02C), KEY6 (0x030), KEY7 (0x034), IV0 (0x038), IV1 (0x03C), IV2 (0x040), TAG_IN0 (0x044), TAG_IN1 (0x048), TAG_IN2 (0x04C), TAG_IN3 (0x050). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `start` (CMD bit 0), `clr` (CMD bit 1) at 0x054; the core sees a one-clock pulse, and the register reads 0.
6. To send on IN: wait until FLAGS.IN_FULL (bit 0) is 0, or for IRQ IN_DONE, then write IN0 (0x058) then IN1 (0x05C) then IN2 (0x060) then IN3 (0x064) then IN4 (0x068). The last write commits the beat. IN_OVF means a write came while the register was full and was dropped.
7. To receive on OUT: wait for IRQ OUT_AVAIL or FLAGS.OUT_AVAIL (bit 1), then read OUT0 (0x06C) then OUT1 (0x070) then OUT2 (0x074) then OUT3 (0x078) then OUT4 (0x07C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.OUT_AVAIL (bit 4) to clear it.
8. Read TAG0 (0x080), TAG1 (0x084), TAG2 (0x088), TAG3 (0x08C) for the core's live `tag[31:0]`, `tag[63:32]`, `tag[95:64]`, `tag[127:96]`; it needs no clearing.
9. Read STATUS (0x090) for the core's live `busy`, `tag_ok`, `err_code`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL, KEY0..KEY7 (or set CTRL.key_sel and drive the sideload port), IV0..IV2 and, to decrypt, TAG_IN0..TAG_IN3; write CMD.start.
2. For each AAD block, then each text block: wait for FLAGS.IN_FULL = 0, write IN0..IN3 and then IN4 = bytes | aad << 5 | last << 6. Only the last block of each kind may be partial; mark the last block of the message (or send IN4 = 1 << 6 with no data).
3. Read each output block when FLAGS.OUT_AVAIL is set: OUT0..OUT3, then OUT4 (pops it).
4. Wait for IRQ_STATUS.DONE (or ERR); read TAG0..TAG3 (encrypt) or STATUS.tag_ok (decrypt). Clear the KEY registers if the key is not reused.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.AES_GCM sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.AES_GCM syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/AES_GCM_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.AES_GCM apb` | `TEST PASSED: AES_GCM_apb`, then Yosys without `ERROR` | console, `work/AES_GCM_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh AES_GCM`<br>`bash scripts/cov/run_cov.sh AES_GCM_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/AES_GCM/score.json`, `work/cov/AES_GCM_apb/score.json` |

Expected end of a step 4 run:

```
===== AES_GCM =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/AES_GCM_tb.sv`): drives `AES_GCM_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/AES_GCM_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/AES_GCM_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/AES_GCM_sva.sv`, `tb/cov/AES_GCM_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/AES_GCM_top.sv` | pass | 92/92 | 8438/8438 | 8/8 | 19/19 | 57/57 |
| wrapper `rtl/AES_GCM_apb.sv` | pass | 93/93 | 4310/4310 | n/a | 37/37 | 113/113 |

Core: tb/AES_GCM_tb.sv runs 758 cases from tb/AES_GCM_vec.svh: 483 known-answer tests (NIST CAVP gcmEncryptExtIV128 / gcmDecrypt128, one per section with a 96-bit IV, and every Wycheproof case with a 96-bit IV and a 128- or 256-bit key, valid and invalid), the NIST encryptions decrypted again with their truncated tags, and seeded random cases (AES-128 / AES-256, lengths 0-300 bytes, tags of 1-16 bytes, wrong tags); with random gaps, output back-pressure and the key from either port. Then messages at the length limits (core built with LEN_W = 14) and one byte over, every error, clr in every phase, start while busy, reset in a message and the throughput (11 / 15 clocks per text block, 4 per AAD block).
All expected values come from scripts/aes_gcm/gcm_ref.py, written from FIPS 197 and SP 800-38D and checked against the FIPS 197 and GCM specification examples and Python's cryptography package. The core checker has its own AES (S-box computed from the field inverse) and bit-serial GHASH and recomputes every output block, error, tag and tag_ok, and checks that no secret is left in the core when it is idle.
