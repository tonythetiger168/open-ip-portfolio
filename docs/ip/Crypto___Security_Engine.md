# Crypto & Security Engine: SHA-256 (FIPS 180-4) of a message of up to 64 bytes and HMAC-SHA-256 (RFC 2104) with a 64-byte key block, padding done in the core, one round per clock

Protocol IP `Crypto___Security_Engine`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Crypto___Security_Engine_top` (`rtl/Crypto___Security_Engine_top.sv`) |
| Register interface | APB4 slave `Crypto___Security_Engine_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53480200 (code 0x5348, version 2.0) |
| Registers | 24 words, 0x000 to 0x05C |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | none (register access only) |

## Overview

Crypto & Security Engine -- real SHA-256 (FIPS 180-4) + HMAC (RFC 2104). * Full SHA-256 compression function, 64 rounds, 1 round/clk, K constant table, on-the-fly message schedule * Message port: 512-bit block written as 4x128 words + msg_len (bytes, 0..64); start triggers hashing; padding (0x80 || 0 || len64) is done internally, including the 56..64-byte two-block corner case * HMAC mode: 512-bit key block written as 4x128 words; ipad/opad and the two-pass H(K^opad || H(K^ipad || msg)) are computed automatically * digest[255:0] + done; any start/key/msg write while busy -> irq pulse; a start with msg_len > 64 is rejected (irq pulse, engine stays idle)

Wide values are little-endian across words (MSG0, KEY0 and DIGEST0 hold bits [31:0]); the message, key and digest are big-endian byte strings, so the first byte of each is in the highest word.
A SHA-256 takes one or two compressions of 64 clocks (two when 56 or more bytes leave no room for the padding); HMAC takes four or five.

## Files

| File | Content |
|---|---|
| `rtl/Crypto___Security_Engine_top.sv` | protocol core |
| `rtl/Crypto___Security_Engine_apb.sv` | APB4 register wrapper (generated) |
| `tb/Crypto___Security_Engine_tb.sv` | core testbench |
| `tb/Crypto___Security_Engine_apb_tb.sv`, `tb/apb/Crypto___Security_Engine_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Crypto___Security_Engine_sva.sv`, `tb/cov/Crypto___Security_Engine_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Crypto___Security_Engine.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.Crypto___Security_Engine sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.Crypto___Security_Engine apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh Crypto___Security_Engine          # core coverage (Verilator)
bash scripts/cov/run_cov.sh Crypto___Security_Engine_apb      # wrapper coverage
```

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `Crypto___Security_Engine_apb`. Widths of the pass-through pins are at the default parameters.

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

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `msg_we` | input | 1 | CMD[0:0] |
| `msg_widx` | input | 2 | CTRL[9:8] |
| `msg` | input | 128 | MSG0[31:0], MSG1[31:0], MSG2[31:0], MSG3[31:0] |
| `key_we` | input | 1 | CMD[1:1] |
| `key_widx` | input | 2 | CTRL[11:10] |
| `key` | input | 128 | KEY0[31:0], KEY1[31:0], KEY2[31:0], KEY3[31:0] |
| `msg_len` | input | 7 | CTRL[6:0] |
| `start` | input | 1 | CMD[2:2] |
| `mode` | input | 1 | CTRL[7:7] |
| `busy` | output | 1 | STATUS |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `digest` | output | 256 | DIGEST0[31:0], DIGEST1[31:0], DIGEST2[31:0], DIGEST3[31:0], DIGEST4[31:0], DIGEST5[31:0], DIGEST6[31:0], DIGEST7[31:0] |
| `irq` | output | 1 | IRQ_STATUS.PROTOCOL |

## APB wrapper

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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53480200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write MSG0 (0x014), MSG1 (0x018), MSG2 (0x01C), MSG3 (0x020), KEY0 (0x024), KEY1 (0x028), KEY2 (0x02C), KEY3 (0x030), CTRL (0x034). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `msg_we` (CMD bit 0), `key_we` (CMD bit 1), `start` (CMD bit 2) at 0x038; the core sees a one-clock pulse, and the register reads 0.
6. Read DIGEST0 (0x03C), DIGEST1 (0x040), DIGEST2 (0x044), DIGEST3 (0x048), DIGEST4 (0x04C), DIGEST5 (0x050), DIGEST6 (0x054), DIGEST7 (0x058) for the core's live `digest[31:0]`, `digest[63:32]`, `digest[95:64]`, `digest[127:96]`, `digest[159:128]`, `digest[191:160]`, `digest[223:192]`, `digest[255:224]`; it needs no clearing.
7. Read STATUS (0x05C) for the core's live `busy`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Crypto___Security_Engine_top.sv` | pass | 112/112 (+1 excl.) | 2982/2982 | 11/11 | 8/8 | 82/82 |
| wrapper `rtl/Crypto___Security_Engine_apb.sv` | pass | 57/57 | 2036/2036 | n/a | 22/22 | 68/68 |
