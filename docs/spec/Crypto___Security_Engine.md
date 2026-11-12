<!-- SPDX-License-Identifier: Apache-2.0 -->
# Crypto___Security_Engine: design specification

A SHA-256 (FIPS 180-4) and HMAC-SHA-256 (RFC 2104) engine for messages of up to one block. Not
implemented: messages longer than 64 bytes, keys longer than 64 bytes (software hashes them
first), other hash functions, side-channel countermeasures. Core `Crypto___Security_Engine_top`
(`rtl/Crypto___Security_Engine_top.sv`), testbench `tb/Crypto___Security_Engine_tb.sv`, checker
`tb/cov/Crypto___Security_Engine_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Message and key are 512-bit blocks written as four 128-bit words,
word 0 holding the first bytes in its most significant bits.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `msg_we` | input | 1 | write a message word (ignored with `irq` while busy) | high | `clk` | - |
| `msg_widx` | input | 2 | word index: 0 = bytes 0..15 (most significant first) | - | `clk` | - |
| `msg` | input | 128 | message word | - | `clk` | - |
| `key_we` | input | 1 | write a key word (ignored with `irq` while busy) | high | `clk` | - |
| `key_widx` | input | 2 | word index: 0 = key bytes 0..15 | - | `clk` | - |
| `key` | input | 128 | key word (the driver zero-pads keys under 64 bytes) | - | `clk` | - |
| `msg_len` | input | 7 | message length in bytes, 0..64 | - | `clk` | - |
| `start` | input | 1 | start hashing | high | `clk` | - |
| `mode` | input | 1 | 0 SHA-256, 1 HMAC-SHA-256 | - | `clk` | - |
| `busy` | output | 1 | an operation is running; combinational from flops | high | `clk` | 0 |
| `done` | output | 1 | one-clock pulse: `digest` is valid | high | `clk` | 0 |
| `digest` | output | 256 | last digest, bytes in order from bit 255; holds | - | `clk` | 0 |
| `irq` | output | 1 | one-clock pulse: write or start while busy, or `msg_len` over 64 | high | `clk` | 0 |

### Internal signals used by the verification

The TB's inline checks read these; the FSM coverage collector binds `cs`.

| Signal | Width | Meaning |
|---|---|---|
| `cs` | 3 | 0 IDLE, 1 BLOCK (load a block), 2 ROUNDS, 3 FINISH (add to the hash state), 4 DONE |
| `rcnt` | 6 | round 0..63 |
| `blk_type` | 3 | block being compressed: 0 none, 1 key ^ ipad, 2 message block 1, 3 message block 2, 4 key ^ opad, 5 outer (inner digest) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Crypto___Security_Engine.md`](../ip/Crypto___Security_Engine.md) (source: `scripts/apb/specs/Crypto___Security_Engine.json`); do not edit by hand.

`Crypto___Security_Engine_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53480200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | MSG0 | RW | 0x00000000 | Message staging |
| 0x018 | MSG1 | RW | 0x00000000 | Message staging |
| 0x01C | MSG2 | RW | 0x00000000 | Message staging |
| 0x020 | MSG3 | RW | 0x00000000 | Message staging |
| 0x024 | KEY0 | RW | 0x00000000 | HMAC key staging |
| 0x028 | KEY1 | RW | 0x00000000 | HMAC key staging |
| 0x02C | KEY2 | RW | 0x00000000 | HMAC key staging |
| 0x030 | KEY3 | RW | 0x00000000 | HMAC key staging |
| 0x034 | CTRL | RW | 0x00000000 | Operation |
| 0x038 | CMD | WO (pulse) | 0x00000000 | Commands (refused while busy: PROTOCOL) |
| 0x03C | DIGEST0 | RO | core | Result |
| 0x040 | DIGEST1 | RO | core | Result |
| 0x044 | DIGEST2 | RO | core | Result |
| 0x048 | DIGEST3 | RO | core | Result |
| 0x04C | DIGEST4 | RO | core | Result |
| 0x050 | DIGEST5 | RO | core | Result |
| 0x054 | DIGEST6 | RO | core | Result |
| 0x058 | DIGEST7 | RO | core | Result |
| 0x05C | STATUS | RO | core | Engine state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x060 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5348 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| MSG0 | 31:0 | `msg[31:0]` | RW | 0x0 | 128 bits of the message block, loaded into slot CTRL.msg_widx by CMD.msg_we (slot 0: the first 16 message bytes, byte 0 in MSG3 bits [31:24]) |
| MSG1 | 31:0 | `msg[63:32]` | RW | 0x0 | 128 bits of the message block, loaded into slot CTRL.msg_widx by CMD.msg_we (slot 0: the first 16 message bytes, byte 0 in MSG3 bits [31:24]) |
| MSG2 | 31:0 | `msg[95:64]` | RW | 0x0 | 128 bits of the message block, loaded into slot CTRL.msg_widx by CMD.msg_we (slot 0: the first 16 message bytes, byte 0 in MSG3 bits [31:24]) |
| MSG3 | 31:0 | `msg[127:96]` | RW | 0x0 | 128 bits of the message block, loaded into slot CTRL.msg_widx by CMD.msg_we (slot 0: the first 16 message bytes, byte 0 in MSG3 bits [31:24]) |
| KEY0 | 31:0 | `key[31:0]` | RW | 0x0 | 128 bits of the key block, loaded into slot CTRL.key_widx by CMD.key_we (same byte order as MSG; a key shorter than 64 bytes is zero-padded by software) |
| KEY1 | 31:0 | `key[63:32]` | RW | 0x0 | 128 bits of the key block, loaded into slot CTRL.key_widx by CMD.key_we (same byte order as MSG; a key shorter than 64 bytes is zero-padded by software) |
| KEY2 | 31:0 | `key[95:64]` | RW | 0x0 | 128 bits of the key block, loaded into slot CTRL.key_widx by CMD.key_we (same byte order as MSG; a key shorter than 64 bytes is zero-padded by software) |
| KEY3 | 31:0 | `key[127:96]` | RW | 0x0 | 128 bits of the key block, loaded into slot CTRL.key_widx by CMD.key_we (same byte order as MSG; a key shorter than 64 bytes is zero-padded by software) |
| CTRL | 6:0 | `msg_len` | RW | 0x0 | message length in bytes, 0..64; START with more is refused (PROTOCOL) |
| CTRL | 7 | `mode` | RW | 0x0 | 0: SHA-256, 1: HMAC-SHA-256 |
| CTRL | 9:8 | `msg_widx` | RW | 0x0 | message slot (0..3) written by CMD.msg_we |
| CTRL | 11:10 | `key_widx` | RW | 0x0 | key slot (0..3) written by CMD.key_we |
| CMD | 0 | `msg_we` | WO (pulse) | 0x0 | write 1: load MSG into message slot CTRL.msg_widx |
| CMD | 1 | `key_we` | WO (pulse) | 0x0 | write 1: load KEY into key slot CTRL.key_widx |
| CMD | 2 | `start` | WO (pulse) | 0x0 | write 1: hash the message (CTRL.msg_len bytes) in CTRL.mode |
| DIGEST0 | 31:0 | `digest[31:0]` | RO | core | the digest of the last operation, valid from DONE (DIGEST7 bits [31:24] is the first digest byte) |
| DIGEST1 | 31:0 | `digest[63:32]` | RO | core | the digest of the last operation, valid from DONE (DIGEST7 bits [31:24] is the first digest byte) |
| DIGEST2 | 31:0 | `digest[95:64]` | RO | core | the digest of the last operation, valid from DONE (DIGEST7 bits [31:24] is the first digest byte) |
| DIGEST3 | 31:0 | `digest[127:96]` | RO | core | the digest of the last operation, valid from DONE (DIGEST7 bits [31:24] is the first digest byte) |
| DIGEST4 | 31:0 | `digest[159:128]` | RO | core | the digest of the last operation, valid from DONE (DIGEST7 bits [31:24] is the first digest byte) |
| DIGEST5 | 31:0 | `digest[191:160]` | RO | core | the digest of the last operation, valid from DONE (DIGEST7 bits [31:24] is the first digest byte) |
| DIGEST6 | 31:0 | `digest[223:192]` | RO | core | the digest of the last operation, valid from DONE (DIGEST7 bits [31:24] is the first digest byte) |
| DIGEST7 | 31:0 | `digest[255:224]` | RO | core | the digest of the last operation, valid from DONE (DIGEST7 bits [31:24] is the first digest byte) |
| STATUS | 0 | `busy` | RO | core | an operation is running |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | an operation finished; DIGEST holds the result |
| 1 | PROTOCOL | a command while busy, or START with msg_len above 64 (refused) |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53480200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write MSG0 (0x014), MSG1 (0x018), MSG2 (0x01C), MSG3 (0x020), KEY0 (0x024), KEY1 (0x028), KEY2 (0x02C), KEY3 (0x030), CTRL (0x034). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `msg_we` (CMD bit 0), `key_we` (CMD bit 1), `start` (CMD bit 2) at 0x038; the core sees a one-clock pulse, and the register reads 0.
6. Read DIGEST0 (0x03C), DIGEST1 (0x040), DIGEST2 (0x044), DIGEST3 (0x048), DIGEST4 (0x04C), DIGEST5 (0x050), DIGEST6 (0x054), DIGEST7 (0x058) for the core's live `digest[31:0]`, `digest[63:32]`, `digest[95:64]`, `digest[127:96]`, `digest[159:128]`, `digest[191:160]`, `digest[223:192]`, `digest[255:224]`; it needs no clearing.
7. Read STATUS (0x05C) for the core's live `busy`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Operation

`start` in IDLE with `msg_len` <= 64 captures `mode` and `msg_len` and starts; with `msg_len` over
64 `irq` pulses and the engine stays idle. Message and key writes are taken only while idle.

Blocks compressed, in order:

| Mode | `msg_len` | Blocks | n |
|---|---|---|---|
| SHA-256 | 0..55 | message (padded) | 1 |
| SHA-256 | 56..64 | message, padding block | 2 |
| HMAC | 0..55 | K ^ 0x36.., message, K ^ 0x5c.., outer | 4 |
| HMAC | 56..64 | K ^ 0x36.., message, padding, K ^ 0x5c.., outer | 5 |

Padding is standard: the message bytes, 0x80, zeros, and the 64-bit bit length (of the key block
plus the message for HMAC's inner hash); with 56..64 bytes the length goes in a second block
(and the 0x80 too when the message is 64 bytes). The outer block is the inner digest, 0x80, zeros
and the length 768.

Each block takes 66 clocks: load, 64 rounds (one per clock), add to the hash state. The hash state
restarts from the initial value for the outer hash. `done` pulses 2 + 66 x n clocks after the
clock that takes `start`, with `digest` set in the same clock; `busy` is high from the clock after
`start` until that clock.

### 3.2 Violations

While busy, `msg_we`, `key_we` or `start` each pulse `irq` one clock later and are ignored; the
operation continues.

### 3.3 Reset

While `rst_n` is low: idle, message, key and digest 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `msg_len` over 64 | rejected, `irq` |
| write or start while busy | ignored, `irq` |
| `msg_len` 55 / 56 / 64 | one block / two blocks / 0x80 in the second block |
| empty message | hashed (one block) |

## 6. TB check map

The TB prints `ERROR: <message>` for most checks and `SVA_FAIL: <name>` for its inline assertions
(A1..A6). Assertions `a_*` are in the bound checker `tb/cov/Crypto___Security_Engine_sva.sv`, which
computes the expected digest itself. The TB runs NIST SHA-256 and RFC 4231 HMAC vectors,
violations, back-to-back operations and a random phase (CRV).

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "timeout waiting for done" | operations finish | §3.1 |
| "busy after reset" | reset | §3.3 |
| "done after reset" | reset | §3.3 |
| "irq after reset" | reset | §3.3 |
| "busy not set during hashing" | `busy` | §3.1 |
| "no irq on busy violation" | violations flagged | §3.2 |
| "timeout after busy violation" | operation continues | §3.2 |
| "msg_len 65 not rejected" | length limit | §3.1 |
| "reset during hash" | reset | §3.3 |
| "CRV non-deterministic t" | same input, same digest | §3.1 |
| "CRV HMAC == SHA t" | modes differ | §3.1 |
| "CRV busy stuck after done t" | `busy` drops | §3.1 |
| "CRV violation op timeout t" | operation continues | §3.2 |
| "CRV no irq on busy violation t" | violations flagged | §3.2 |
| "A1 reset: outputs quiescent" | reset | §3.3 |
| "A2 busy == !S_IDLE" | `busy` | §3.1 |
| "A3 done pulse observed in S_IDLE" | `done` with the return to idle | §3.1 |
| "A4 state legal" | legal states | §3.1 |
| "A5 rcnt <= 63" | 64 rounds | §3.1 |
| "A6 blk_type legal" | legal blocks | §3.1 |
| a_reset_quiet | reset | §3.3 |
| a_busy_model | `busy` as the model | §3.1 |
| a_digest | digest as the reference | §3.1 |
| a_latency | 2 + 66 x n clocks | §3.1 |
| a_done_only_when_busy | `done` ends an operation | §3.1 |
| a_violation_irq | violations flagged | §3.2 |
| a_no_spurious_irq | no other `irq` | §3.2 |
| a_reject_stays_idle | over-long start rejected | §3.1 |
