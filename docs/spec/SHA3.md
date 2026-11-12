<!-- SPDX-License-Identifier: Apache-2.0 -->
# SHA3: design specification

A SHA-3 / SHAKE hash engine (FIPS 202): SHA3-224, SHA3-256, SHA3-384, SHA3-512, SHAKE128 and
SHAKE256 on one Keccak-f[1600] core computing one round per clock. Not implemented: cSHAKE, KMAC
and TupleHash framing (SP 800-185; the host can build them on SHAKE by prefixing the encoded
strings), more than one round per clock, masking against power analysis. Core `SHA3_top`
(`rtl/SHA3_top.sv`), testbench `tb/SHA3_tb.sv` (vectors from Python `hashlib` in
`tb/SHA3_vec.hex`, made by `scripts/sha3/gen_vec.py`), checker `tb/cov/SHA3_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge. Lane (x, y) of the
1600-bit state is bits 64(x + 5y) +: 64; lane k below means bits 64k +: 64.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset; clears the Keccak state | low | async | - |
| `start` | input | 1 | clear the state and open a message in `mode` (taken in every state, §3.1) | high | `clk` | - |
| `mode` | input | 3 | 0 SHA3-224, 1 SHA3-256, 2 SHA3-384, 3 SHA3-512, 4 SHAKE128, 5 SHAKE256; 6, 7 reserved (wipe) | - | with `start` | - |
| `in_valid` | input | 1 | a message word is offered | high | `clk` | - |
| `in_data` | input | 64 | message word, little-endian (message byte 0 in bits 7:0) | - | `clk` | - |
| `in_bytes` | input | 4 | valid bytes of the word from byte 0 up, 0..8; below 8 only with `in_last` | - | `clk` | - |
| `in_last` | input | 1 | last word of the message | high | `clk` | - |
| `in_ready` | output | 1 | absorbing (state ABSORB); combinational | high | comb | 0 |
| `out_valid` | output | 1 | a digest / output word is available (state SQUEEZE); combinational | high | comb | 0 |
| `out_data` | output | 64 | output word, little-endian lane of the state; combinational | - | comb | - |
| `out_last` | output | 1 | last digest word (SHA3 modes only); combinational | high | comb | 0 |
| `out_ready` | input | 1 | the host takes the output word | high | `clk` | - |
| `busy` | output | 1 | not idle: from `start` until the digest is read (always for SHAKE until the next start); combinational | high | comb | 0 |
| `done` | output | 1 | one-clock pulse after the last SHA3 digest word was taken | high | `clk` | 0 |
| `err` | output | 1 | one-clock pulse after a bad word or a reserved mode | high | `clk` | 0 |

### Internal signals used by the verification

The TB and the bound checker read `ks` by name (it must be all-zero whenever the core is idle);
the FSM coverage collector (`tb/cov/SHA3_fsm_cov.sv`) binds `st` and `ret`.

| Signal | Width | Meaning |
|---|---|---|
| `ks` | 1600 | Keccak state |
| `st` | 3 | state: 0 IDLE, 1 ABSORB, 2 PAD, 3 PERMUTE, 4 SQUEEZE |
| `ret` | 2 | where a permutation returns: 0 ABSORB, 1 PAD, 2 SQUEEZE |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SHA3.md`](../ip/SHA3.md) (source: `scripts/apb/specs/SHA3.json`); do not edit by hand.

`SHA3_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53330100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000001 | Hash mode |
| 0x018 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x01C | MSG0 | RW | 0x00000000 | Message word: MSG0 = bytes 3..0, MSG1 = bytes 7..4 (little-endian), then MSG2 = {last, bytes}, which commits it |
| 0x020 | MSG1 | RW | 0x00000000 | Message word: MSG0 = bytes 3..0, MSG1 = bytes 7..4 (little-endian), then MSG2 = {last, bytes}, which commits it |
| 0x024 | MSG2 | RW | 0x00000000 | Message word: MSG0 = bytes 3..0, MSG1 = bytes 7..4 (little-endian), then MSG2 = {last, bytes}, which commits it |
| 0x028 | DIGEST0 | RO (pop) | 0x00000000 | Digest / SHAKE output word: DIGEST0 = bytes 3..0, DIGEST1 = bytes 7..4, DIGEST2 = last flag; reading DIGEST2 pops it |
| 0x02C | DIGEST1 | RO (pop) | 0x00000000 | Digest / SHAKE output word: DIGEST0 = bytes 3..0, DIGEST1 = bytes 7..4, DIGEST2 = last flag; reading DIGEST2 pops it |
| 0x030 | DIGEST2 | RO (pop) | 0x00000000 | Digest / SHAKE output word: DIGEST0 = bytes 3..0, DIGEST1 = bytes 7..4, DIGEST2 = last flag; reading DIGEST2 pops it |
| 0x034 | STATUS | RO | core | Engine state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5333 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 2:0 | `mode` | RW | 0x1 | 0 SHA3-224, 1 SHA3-256, 2 SHA3-384, 3 SHA3-512, 4 SHAKE128, 5 SHAKE256 (6 and 7 are refused with ERR and wipe the state) |
| CMD | 0 | `start` | WO (pulse) | 0x0 | clear the state and open a message in CTRL.mode (abandons a running message or output stream) |
| MSG0 | 31:0 | `in_data[31:0]` | RW | 0x0 | message bytes, byte 0 in bits 7:0 |
| MSG1 | 31:0 | `in_data[63:32]` | RW | 0x0 | message bytes, byte 0 in bits 7:0 |
| MSG2 | 3:0 | `in_bytes` | RW | 0x0 | valid bytes, 8 except in the last word (0..8) |
| MSG2 | 4 | `in_last` | RW | 0x0 | last word of the message |
| DIGEST0 | 31:0 | `out_data[31:0]` | RO (pop) | 0x0 | output bytes, byte 0 in bits 7:0 |
| DIGEST1 | 31:0 | `out_data[63:32]` | RO (pop) | 0x0 | output bytes, byte 0 in bits 7:0 |
| DIGEST2 | 0 | `out_last` | RO (pop) | 0x0 | last word of a SHA3 digest (never set for SHAKE) |
| STATUS | 0 | `busy` | RO | core | a message or an output stream is open |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | the last digest word was read |
| 1 | ERR | a message word was refused (short without last, or more than 8 bytes) or start had a reserved mode |
| 2 | MSG_DONE | MSG beat accepted by the core |
| 3 | MSG_OVF | write to MSG while full (dropped) |
| 4 | DIGEST_AVAIL | DIGEST captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | MSG_FULL | MSG holds a beat the core has not taken |
| 1 | DIGEST_AVAIL | DIGEST holds an unread beat |

### Streams

* **MSG** feeds `in_data`, `in_bytes`, `in_last`/`in_valid`. Writing MSG2 commits the beat: FLAGS.MSG_FULL is set and `in_valid` stays high until the core's `in_ready`; then MSG_DONE is set. A write while full is dropped and sets MSG_OVF.
* **DIGEST** takes `out_data`, `out_last` from the core with `out_valid` / `out_ready`: `out_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ DIGEST_AVAIL. Reading DIGEST2 pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53330100.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x018; the core sees a one-clock pulse, and the register reads 0.
6. To send on MSG: wait until FLAGS.MSG_FULL (bit 0) is 0, or for IRQ MSG_DONE, then write MSG0 (0x01C) then MSG1 (0x020) then MSG2 (0x024). The last write commits the beat. MSG_OVF means a write came while the register was full and was dropped.
7. To receive on DIGEST: wait for IRQ DIGEST_AVAIL or FLAGS.DIGEST_AVAIL (bit 1), then read DIGEST0 (0x028) then DIGEST1 (0x02C) then DIGEST2 (0x030). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.DIGEST_AVAIL (bit 4) to clear it.
8. Read STATUS (0x034) for the core's live `busy`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. CTRL.mode = function, CMD.start = 1.
2. For each message word: wait for FLAGS.MSG_FULL = 0, write MSG0, MSG1, then MSG2 = bytes | last << 4 (bytes = 8 except in the last word; an empty message is one word with bytes 0 and last).
3. Read the output: wait for FLAGS.DIGEST_AVAIL, read DIGEST0, DIGEST1, DIGEST2 (DIGEST2 pops the word); for SHA3, IRQ_STATUS.DONE follows the word with last set. For SHAKE read as many words as needed, then start the next message (or CMD.start with a reserved mode to wipe the state).
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Modes and start

| `mode` | Algorithm | Rate r / 64 (lanes) | Domain + first pad bit | Output |
|---|---|---|---|---|
| 0 | SHA3-224 | 18 | 0x06 | 4 words, the 4th with bits 63:32 = 0, `out_last` on it |
| 1 | SHA3-256 | 17 | 0x06 | 4 words |
| 2 | SHA3-384 | 13 | 0x06 | 6 words |
| 3 | SHA3-512 | 9 | 0x06 | 8 words |
| 4 | SHAKE128 | 21 | 0x1F | endless stream |
| 5 | SHAKE256 | 17 | 0x1F | endless stream |

`start` wins over everything at its edge: the state, the lane index and the round counter are
cleared; a mode 0..5 is stored and the core enters ABSORB (in the next clock `in_ready` = 1);
a mode 6 or 7 pulses `err` and leaves the core in IDLE (the stored mode is unchanged). A start
during a message or an output stream abandons it; no `done` follows.

### 3.2 Absorbing

In ABSORB `in_ready` = 1 and each `in_valid` word is taken at the edge:

* bad word (`in_bytes` > 8, or `in_bytes` != 8 without `in_last`): dropped, `err` pulses, ABSORB
  continues;
* full word, not last: XORed into lane `li`; at the last rate lane (`li` = r/64 - 1) the block is
  permuted and ABSORB resumes at lane 0, else `li` + 1;
* short last word (`in_bytes` 0..7): XOR the valid bytes (bytes above `in_bytes` are ignored),
  the domain byte at byte `in_bytes`, and 0x80 in byte 7 of the last rate lane (both in the same
  lane if it is the last); then permute and SQUEEZE. `in_bytes` = 0 is an empty last word (an
  empty message);
* full last word: XOR it; if it was the last rate lane, permute and go to PAD at lane 0; else go
  to PAD at `li` + 1. PAD (one clock) XORs the domain byte into byte 0 of the lane and 0x80 into
  byte 7 of the last rate lane, then permutes and goes to SQUEEZE.

So a full last word and a full word followed by an empty last word give the same digest.

### 3.3 Permutation

24 clocks, one Keccak-f[1600] round per clock (theta, rho, pi, chi, iota with the FIPS 202
round constants, round 0 first). `in_ready` and `out_valid` are 0 meanwhile; `busy` stays 1.

### 3.4 Squeezing

In SQUEEZE `out_valid` = 1 and `out_data` = lane `li` (for the SHA3-224 last word, bits 31:0 of
it, zero-extended). At each edge with `out_ready`:

* SHA3 last word (`out_last`): the state and `li` are cleared, `done` pulses in the next clock,
  IDLE (`busy` 0);
* SHAKE at the last rate lane: permute, then SQUEEZE from lane 0 (an endless stream until the
  next `start`);
* otherwise `li` + 1.

### 3.5 Reset

While `rst_n` is low: IDLE, state 0, every output 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| short word without `in_last` | dropped, `err` |
| `in_bytes` > 8 | dropped, `err` |
| bytes above `in_bytes` not zero | ignored |
| message filling its last word exactly | padding in the next lane, or in a new block (PAD state) |
| `start` in any state | restarts; the old message or stream is abandoned without `done` |
| reserved mode 6 / 7 | `err`, state wiped, IDLE: the way to wipe a SHAKE state |
| `in_valid` while not ABSORB | not taken (`in_ready` 0) |
| reset in the middle of a hash | state cleared |

## 6. TB check map

Messages are printed by `tb/SHA3_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/SHA3_sva.sv`. Test vectors (every mode, message lengths around the rate
boundaries, long SHAKE streams) are streamed in with random gaps, random junk above `in_bytes`,
both encodings of a message filling its last word, and random output back-pressure; every output
word is compared with `hashlib`. Then bad words, `start` in every state, the reserved modes and a
reset in the middle of a hash.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "busy low after start" | `busy` from the clock after `start` | §3.1 |
| "bad word: no err pulse" | bad words pulse `err` | §3.2 |
| "no done pulse after the digest" | one `done` per SHA3 digest | §3.4 |
| "busy after the digest" | IDLE after the last word | §3.4 |
| "state not cleared after the digest" | `ks` = 0 after the digest | §3.4 |
| "reserved mode did not wipe the SHAKE state" | mode 6 / 7 clears `ks` and goes IDLE | §3.1 |
| "outputs not at their reset values" | reset values | §3.5 |
| "in_ready during the permutation" | `in_ready` 0 for the 24 rounds | §3.3 |
| "reserved mode: no err or busy" | reserved mode: `err` and not busy | §3.1 |
| "in_ready while idle" | no `in_ready` in IDLE | §3.1 |
| "reset did not clear the core" | reset clears outputs and `ks` | §3.5 |
| a_in_ready | `in_ready` exactly in ABSORB, not during a permutation or PAD | §3.2, §3.3 |
| a_out_valid | `out_valid` exactly in SQUEEZE, not during a permutation | §3.3, §3.4 |
| a_out_data | each output word as the checker's own Keccak model | §3.4 |
| a_out_last | `out_last` on the last SHA3 word | §3.4 |
| a_busy | `busy` from start to the digest end | §3.1, §3.4 |
| a_err | `err` exactly after a bad word or reserved mode | §3.1, §3.2 |
| a_done | `done` exactly after the last digest word | §3.4 |
| a_exclusive | never `in_ready` and `out_valid` together | §3.2, §3.4 |
| a_wipe_idle | `ks` = 0 whenever `busy` = 0 | §3.1, §3.4 |
| a_start_restarts | after `start`, no `out_valid` and no `done` | §3.1 |
| a_reset | in reset: outputs 0, `ks` = 0 | §3.5 |
