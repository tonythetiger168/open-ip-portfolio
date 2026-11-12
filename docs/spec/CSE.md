<!-- SPDX-License-Identifier: Apache-2.0 -->
# CSE: design specification

Crypto and Security Engine: an AES-128 (FIPS-197) ECB block core with on-the-fly key expansion, an
iterative one-round-per-clock datapath, a 4 x 32-bit key write port and a single-command interface.
Core `CSE_top` (`rtl/CSE_top.sv`), testbench `tb/CSE_tb.sv`, checker `tb/cov/CSE_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Edge E0 is the clock edge that samples `start` while idle.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `key_we` | input | 1 | write one 32-bit key word this clock | high | `clk` | - |
| `key_widx` | input | 2 | key word index: 0 = key bits 127:96 (first word of FIPS-197 order) .. 3 = bits 31:0 | - | `clk` | - |
| `key` | input | 32 | key word | - | `clk` | - |
| `start` | input | 1 | start one block operation (sampled while idle) | high | `clk` | - |
| `enc_dec` | input | 1 | 1 encrypt, 0 decrypt; sampled with `start` | - | `clk` | - |
| `din` | input | 128 | input block, FIPS-197 byte order (byte 0 = bits 127:120); sampled with `start` | - | `clk` | - |
| `busy` | output | 1 | an operation is in progress (`cs` != IDLE); combinational from the state | high | `clk` | 0 |
| `done` | output | 1 | one-clock pulse: the operation finished, `dout` valid | high | `clk` | 0 |
| `dout` | output | 128 | result block; held until the next result | - | `clk` | 0 |
| `irq` | output | 1 | one-clock pulse: a `start` or `key_we` while busy was ignored | high | `clk` | 0 |

### Internal signals used by the verification

fsm_cov binds the control state; keep its name and encoding.

| Signal | Width | Meaning |
|---|---|---|
| `cs` | 2 | control FSM: 0 IDLE, 1 KEY (key expansion), 2 RUN (rounds), 3 DONE |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/CSE.md`](../ip/CSE.md) (source: `scripts/apb/specs/CSE.json`); do not edit by hand.

`CSE_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43450200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | KEY0 | WO (core) | core | key bits [127:96] (write only; reset 0); a write while busy is refused (PROTOCOL) |
| 0x018 | KEY1 | WO (core) | core | key bits [95:64] (write only; reset 0) |
| 0x01C | KEY2 | WO (core) | core | key bits [63:32] (write only; reset 0) |
| 0x020 | KEY3 | WO (core) | core | key bits [31:0] (write only; reset 0) |
| 0x024 | DIN0 | RW | 0x00000000 | Input block |
| 0x028 | DIN1 | RW | 0x00000000 | Input block |
| 0x02C | DIN2 | RW | 0x00000000 | Input block |
| 0x030 | DIN3 | RW | 0x00000000 | Input block |
| 0x034 | CTRL | RW | 0x00000001 | Operation |
| 0x038 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x03C | DOUT0 | RO | core | Result |
| 0x040 | DOUT1 | RO | core | Result |
| 0x044 | DOUT2 | RO | core | Result |
| 0x048 | DOUT3 | RO | core | Result |
| 0x04C | STATUS | RO | core | Engine state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x050 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4345 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| KEY0 | 31:0 | core register | WO (core) | core | written at core register 0 |
| KEY1 | 31:0 | core register | WO (core) | core | written at core register 1 |
| KEY2 | 31:0 | core register | WO (core) | core | written at core register 2 |
| KEY3 | 31:0 | core register | WO (core) | core | written at core register 3 |
| DIN0 | 31:0 | `din[31:0]` | RW | 0x0 | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| DIN1 | 31:0 | `din[63:32]` | RW | 0x0 | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| DIN2 | 31:0 | `din[95:64]` | RW | 0x0 | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| DIN3 | 31:0 | `din[127:96]` | RW | 0x0 | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| CTRL | 0 | `enc_dec` | RW | 0x1 | 1: encrypt, 0: decrypt; taken by START |
| CMD | 0 | `start` | WO (pulse) | 0x0 | write 1: run one block with the current key, DIN and CTRL (21 clocks); refused while busy (PROTOCOL) |
| DOUT0 | 31:0 | `dout[31:0]` | RO | core | the 128-bit result of the last operation, valid from DONE |
| DOUT1 | 31:0 | `dout[63:32]` | RO | core | the 128-bit result of the last operation, valid from DONE |
| DOUT2 | 31:0 | `dout[95:64]` | RO | core | the 128-bit result of the last operation, valid from DONE |
| DOUT3 | 31:0 | `dout[127:96]` | RO | core | the 128-bit result of the last operation, valid from DONE |
| STATUS | 0 | `busy` | RO | core | an operation is running (key expansion, then the rounds) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | an operation finished; DOUT holds the result |
| 1 | PROTOCOL | START or a KEY write while busy (refused) |

### Core register port

The KEY words reach the core's own register port. A write to one pulses `key_we` for one clock with `key_widx` (the core register) and `key` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. 

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43450200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write DIN0 (0x024), DIN1 (0x028), DIN2 (0x02C), DIN3 (0x030), CTRL (0x034). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. Access the core's registers through the KEY words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
6. To issue a command, write 1 to `start` (CMD bit 0) at 0x038; the core sees a one-clock pulse, and the register reads 0.
7. Read DOUT0 (0x03C), DOUT1 (0x040), DOUT2 (0x044), DOUT3 (0x048) for the core's live `dout[31:0]`, `dout[63:32]`, `dout[95:64]`, `dout[127:96]`; it needs no clearing.
8. Read STATUS (0x04C) for the core's live `busy`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Algorithm

Standard AES-128 per FIPS-197: the 128-bit block and key map to the state with byte i at bits
127-8i .. 120-8i (state[r][c] = in[4c+r]). Encrypt: AddRoundKey(rk0), rounds 1..9 (SubBytes,
ShiftRows, MixColumns, AddRoundKey), round 10 without MixColumns. Decrypt is the straight inverse
cipher: AddRoundKey(rk10), then for rounds 9..1 InvShiftRows, InvSubBytes, AddRoundKey(rk_r),
InvMixColumns, and finally InvShiftRows, InvSubBytes, AddRoundKey(rk0). Round keys follow the
FIPS-197 key expansion (Rcon 01, 02, 04, 08, 10, 20, 40, 80, 1B, 36). The TB checks the FIPS-197 Appendix B, AESAVS
all-zero, SP 800-38A F.1.1 and all-ones known-answer vectors both ways.

### 3.2 Operation timing

| Edge | State after the edge | Work |
|---|---|---|
| E0 | KEY | `start` sampled while IDLE: `enc_dec`, `din` and the key register (as it was before E0) captured as round key 0 |
| E1 .. E10 | KEY, RUN after E10 | round keys 1..10, one per clock; at E10 the state is loaded with `din` ^ rk0 (encrypt) or `din` ^ rk10 (decrypt) |
| E11 .. E19 | RUN | rounds 1..9 (encrypt) or 9..1 (decrypt), one per clock |
| E20 | DONE | last round; `dout` takes the result |
| E21 | IDLE | `done` = 1 for one clock |

`busy` is high from just after E0 to just after E21 (21 clocks) and falls with `done` rising.
Encrypt and decrypt take the same time. `dout` is updated at E20 and holds until the next
operation's E20. A new `start` is accepted in the first clock after E21 (IDLE).

### 3.3 Key writes and violations

`key_we` while idle writes `key` into key bits 127-32 x `key_widx` .. 96-32 x `key_widx`; the key
register is not cleared between operations. A key write in the same clock as the `start` that
launches an operation updates the key register, but that operation captured the old key; the next
operation uses the new word.

While `busy` (KEY, RUN and DONE), `key_we` and `start` are protocol violations: the key and the
operation are not changed and `irq` pulses high for one clock after the clock in which either was
high (one pulse when both are high together).

### 3.4 Reset

`busy` = 0, `done` = 0, `irq` = 0, `dout` = 0, the key register = 0 (all-zero key) and the state
IDLE. A reset during an operation aborts it with no `done`.

## 4. Parameters

None.

## 5. Errors and corner cases

- `start` or `key_we` while busy: ignored, `irq` pulse (section 3.3). There is no error status
  other than `irq`.
- `start` during DONE (the clock `done` is about to rise) is still a violation.
- `key_widx` has no illegal values. Writing fewer than four words keeps the other words' old
  contents.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "reset state" | reset values | §3.4 |
| "random round trip" | decrypt(encrypt(x)) == x for random keys and blocks | §3.1, §3.2 |
| "violations ignored with irq" | `start` / `key_we` while busy pulse `irq` and change nothing | §3.3 |
| "start with key write: old key used" | a key word written in the `start` clock is not used by that operation | §3.3 |
| "the next operation uses the new key word" | ...but by the next one | §3.3 |
| "reset while busy" | reset aborts the operation | §3.4 |
| "decrypt(0) inverse round trip" | encrypt(decrypt(0)) = 0 | §3.2 |
| "decrypt(1s) inverse round trip" | encrypt(decrypt(all ones)) = all ones | §3.2 |
| a_reset_idle | in reset: `busy`, `done`, `irq` = 0, `dout` = 0 | §3.4 |
| a_busy | `busy` exactly for the 21 clocks of an operation | §3.2 |
| a_done_after_21 | `done` with the right `dout` 21 clocks after `start` | §3.2 |
| a_done_only_at_end | no other `done` | §3.2 |
| a_irq | `irq` = ($past(`key_we` \|\| `start`) while busy) | §3.3 |
