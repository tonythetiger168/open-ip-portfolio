<!-- SPDX-License-Identifier: Apache-2.0 -->
# AES_GCM: design specification

An AES-GCM authenticated encryption engine (NIST SP 800-38D) with AES-128 and AES-256
(FIPS 197) and a 96-bit IV. Not implemented: IV lengths other than 96 bits, AES-192, and
masking against power analysis (secrets are cleared after each message and the tag compare
looks at all bytes at once). Core `AES_GCM_top`
(`rtl/AES_GCM_top.sv`), testbench `tb/AES_GCM_tb.sv` (NIST CAVP and Wycheproof vectors in
`tb/AES_GCM_vec.svh`, made by `scripts/aes_gcm/gen_vec.py`), checker `tb/cov/AES_GCM_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; registered outputs show a
decision of clock n in clock n+1. Nr is 10 for AES-128 and 14 for AES-256.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset; clears every secret | low | async | - |
| `key256` | input | 1 | 0 AES-128 (key in bits 255:128), 1 AES-256 (taken at `start`) | - | `clk` | - |
| `decrypt` | input | 1 | 0 encrypt, 1 decrypt (taken at `start`) | high | `clk` | - |
| `key_sel` | input | 1 | 0 `key` port, 1 sideload key `sl_key` (taken at `start`) | - | `clk` | - |
| `tag_len` | input | 4 | decrypt: bytes of `tag_in` compared, 0 = 16 (taken at `start`) | - | `clk` | - |
| `key` | input | 256 | key (taken at `start`) | - | `clk` | - |
| `iv` | input | 96 | 96-bit IV (taken at `start`) | - | `clk` | - |
| `tag_in` | input | 128 | expected tag (decrypt), used when the message ends | - | `clk` | - |
| `sl_key` | input | 256 | sideload key from a key manager (software cannot read it) | - | `clk` | - |
| `sl_valid` | input | 1 | `sl_key` is valid | high | `clk` | - |
| `start` | input | 1 | start a message; ignored while `busy` | high | `clk` | - |
| `clr` | input | 1 | abort the message and clear the secrets (wins over everything) | high | `clk` | - |
| `busy` | output | 1 | a message is open; combinational from the state | high | comb | 0 |
| `in_valid` | input | 1 | an input block is offered | high | `clk` | - |
| `in_ready` | output | 1 | a block is taken (§3.2); combinational | high | comb | 0 |
| `in_data` | input | 128 | block, big-endian (byte 0 in bits 127:120) | - | `clk` | - |
| `in_bytes` | input | 5 | valid bytes 0..16 from byte 0; below 16 only for the last block of its kind | - | `clk` | - |
| `in_aad` | input | 1 | 1 AAD block, 0 text block | - | `clk` | - |
| `in_last` | input | 1 | last block of the message | high | `clk` | - |
| `out_valid` | output | 1 | an output text block is waiting; cleared when taken | high | `clk` | 0 |
| `out_ready` | input | 1 | the host takes the output block | high | `clk` | - |
| `out_data` | output | 128 | ciphertext (encrypt) or plaintext (decrypt), bytes past `out_bytes` zero | - | `clk` | 0 |
| `out_bytes` | output | 5 | valid bytes of `out_data` | - | `clk` | 0 |
| `out_last` | output | 1 | `in_last` of the block | high | `clk` | 0 |
| `done` | output | 1 | one-clock pulse: the message ended and the result is valid | high | `clk` | 0 |
| `tag` | output | 128 | encrypt: the tag; decrypt: always 0. Held until the next `start` | - | `clk` | 0 |
| `tag_ok` | output | 1 | decrypt: the first `tag_len` bytes of the tag equal `tag_in`; held until the next `start` | high | `clk` | 0 |
| `err` | output | 1 | one-clock pulse: the message was dropped (§3.5) | high | `clk` | 0 |
| `err_code` | output | 3 | cause of the last error, held until the next `start` | - | `clk` | 0 |

### Internal signals used by the verification

The bound checker reads these secrets by name; all must be 0 whenever `busy` is 0, and the low
half of `kreg` must be 0 for AES-128. The FSM coverage collector (`tb/cov/AES_GCM_fsm_cov.sv`)
binds `m`.

| Signal | Width | Meaning |
|---|---|---|
| `kreg` | 256 | the message key (AES-128: bits 127:0 zero) |
| `kw` | 256 | {previous, current} AES round key |
| `st` | 128 | AES state; holds the key stream block when it is ready |
| `hk` | 128 | hash key H = E(K, 0^128) |
| `ej0` | 128 | E(K, J0) |
| `gz` | 128 | GHASH accumulator |
| `ga` | 96 | GHASH operand digits still to multiply |
| `m` | 2 | message state: 0 IDLE, 1 RUN, 2 LEN, 3 FIN |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/AES_GCM.md`](../ip/AES_GCM.md) (source: `scripts/apb/specs/AES_GCM.json`); do not edit by hand.

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

### Programming sequence

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
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Start and AES

At an edge with `start`, not `busy` and not `clr`: if `key_sel` = 1 and `sl_valid` = 0 the start
is refused (`err`, code 4). Otherwise the message opens (state RUN): mode, key, IV and `tag_len`
are taken, `tag` / `tag_ok` / `err_code` cleared. J0 = IV || 0x00000001; the first text block uses
counter block IV || 2, each later one + 1.

The AES computes one round per clock with round keys expanded on the fly; a block takes Nr + 1
clocks (a load clock and Nr rounds). It runs in order H = E(K, 0), E(K, J0), then key stream
blocks, staying one block ahead of the data: the next counter block is started as soon as the
current one is used (or is not yet ready).

### 3.2 Input blocks

`in_ready` = RUN and a key stream block ready and GHASH idle and `out_valid` = 0. So the first
block is taken after three AES blocks (H, E(J0), key stream 1), and an output block must be read
before the next block is taken. A block taken (without error):

* AAD block with `in_bytes` > 0: its first `in_bytes` bytes (the rest zeroed) enter GHASH;
* text block with `in_bytes` > 0: `out_data` = (`in_data` XOR key stream) masked to `in_bytes`
  bytes, with `out_bytes`, `out_last`, and `out_valid` in the next clock; the key stream block is
  used. GHASH takes the ciphertext (the output when encrypting, the masked input when
  decrypting);
* `in_bytes` = 0 with `in_last` = 1: no data (an empty message, or ends the message after its
  last block was already sent);
* `in_last` = 1: the message moves to LEN.

GHASH multiplies by H 32 bits per clock: 4 clocks per block, in parallel with the AES. So text
blocks stream at one per Nr + 1 clocks and AAD blocks at one per 4 clocks.

### 3.3 Message end

In LEN, once GHASH is idle, the length block {64-bit AAD bit length, 64-bit text bit length} is
hashed (4 clocks), then FIN. In FIN, once GHASH is idle and the output block was read: `done`
pulses; encrypt: `tag` = GHASH XOR E(K, J0), `tag_ok` = 0; decrypt: `tag` = 0 and `tag_ok` =
(first `tag_len` bytes of the computed tag equal those of `tag_in`, compared over all bytes at
once). The message state and every secret are cleared (IDLE). The computed tag of a decryption
is never output; the plaintext is output before `tag_ok` and must be held back by the user.

### 3.4 Clear

`clr` at an edge: IDLE, every secret cleared, the output block dropped; no `done`, no `err`. A
`start` in the same clock is ignored. `tag` / `tag_ok` / `err_code` keep their values.

### 3.5 Errors

Checked on each block taken, in this order; the message is dropped, everything cleared (as
`clr`), `err` pulses and `err_code` holds the code:

| Code | Cause |
|---|---|
| 1 | `in_bytes` > 16, or `in_bytes` = 0 without `in_last` |
| 2 | AAD (non-empty) after a text block or after a partial AAD block; a partial text block without `in_last` |
| 3 | AAD over 2^`LEN_W` - 1 bytes, or text over 2^`LEN_W` - 32 bytes (at `LEN_W` = 36 the SP 800-38D limit of 2^32 - 2 counter blocks) |
| 4 | `start` with `key_sel` = 1 and `sl_valid` = 0 (not started) |

### 3.6 Reset

While `rst_n` is low: IDLE, every secret and output 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `LEN_W` | 36 | 8..36 | width of the AAD and text byte counters (sets the length limits) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| empty message (no AAD, no text) | one block with `in_bytes` 0 and `in_last` 1: the tag of the empty message |
| `start` while busy | ignored |
| output block not read | `in_ready` stays 0; `done` waits for it |
| decrypt with a wrong tag | `tag_ok` 0; the plaintext was already output |
| `tag_len` 1..15 | only that many leading bytes compared |
| sideload key not valid at `start` | refused, code 4 |
| reset or `clr` mid-message | everything cleared, no result |

## 6. TB check map

Messages are printed by `tb/AES_GCM_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the
bound checker `tb/cov/AES_GCM_sva.sv`. The core runs with `LEN_W` = 14 so the length limits are
reachable. Every vector case is streamed with random gaps and back-pressure, the key from either
port, and the end on the last block or on a separate empty block; then the two length-limit cases
(and one byte more), every error, `clr` in every phase, `start` while busy, a reset mid-message,
back-to-back messages and the throughput.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "unexpected output block" | one output block per text block | §3.2 |
| "output" | each output block, `out_bytes`, `out_last` as the vector | §3.2 |
| "not busy after start" | `busy` after `start` | §3.1 |
| "done timeout" | the message ends | §3.3 |
| "busy after done" | IDLE after `done` | §3.3 |
| "case" | per case: output count, `tag` (encrypt), `tag` 0 and `tag_ok` (decrypt), no error | §3.3 |
| "long case" | length-limit cases: tag and outputs; one byte more refused with code 3 | §3.5 |
| "output not held" | `out_valid` held until read | §3.2 |
| "block taken while the output is full" | no block taken while `out_valid` | §3.2 |
| "sideload key not valid: not refused" | code 4 | §3.5 |
| "clr after" | `clr` in any phase ends the message without `done` / `err` | §3.4 |
| "throughput" | Nr + 1 clocks per text block, 4 per AAD block | §3.2 |
| "outputs after reset" | reset values | §3.6 |
| "start with clr" | `start` with `clr` is ignored | §3.4 |
| "outputs in reset" | reset values | §3.6 |
| a_busy | `busy` as the model | §3.1, §3.3 |
| a_ready_only_running | `in_ready` only in a message before its end, with no output waiting | §3.2 |
| a_output_expected | `out_valid` as the model | §3.2 |
| a_output_block | output block as the checker's own AES-GCM model | §3.2 |
| a_output_hold | output stable until read | §3.2 |
| a_error_pulse | `err` exactly as the model | §3.5 |
| a_error_code | `err_code` with `err` | §3.5 |
| a_error_code_held | `err_code` held | §3.5 |
| a_done_only_at_end | `done` only after the last block and its output | §3.3 |
| a_tag_encrypt | encrypt: `tag` as the model, `tag_ok` 0 | §3.3 |
| a_tag_decrypt | decrypt: `tag` 0, `tag_ok` as the masked compare | §3.3 |
| a_result_cleared_in_message | `tag` 0 and `tag_ok` 0 while busy | §3.1 |
| a_no_tag_after_decrypt | `tag` stays 0 after a decryption | §3.3 |
| a_result_held | `tag` / `tag_ok` change only at `done` or `start` | §3.3 |
| a_stall_bound | `in_ready` returns within 3 x Nr + 3 clocks | §3.1, §3.2 |
| a_end_bound | `done` within 10 clocks of the end conditions | §3.3 |
| a_idle_no_secret | every secret 0 when not busy | §3.3, §3.4 |
| a_aes128_key_half | AES-128: low key half 0 | §3.1 |
| a_reset | in reset: outputs 0 | §3.6 |
