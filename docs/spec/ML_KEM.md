<!-- SPDX-License-Identifier: Apache-2.0 -->
# ML_KEM: design specification

An ML-KEM (FIPS 203) key-encapsulation engine for ML-KEM-512, -768 and -1024: KeyGen, Encaps and
Decaps with implicit rejection, as the internal algorithms of FIPS 203 section 6 (the random d, z
and m come from the host). A program sequencer drives a Keccak-f[1600] unit (SHA3-256, SHA3-512,
SHAKE128, SHAKE256, one round per clock) and an 8-stage polynomial pipeline over an 8 KiB byte
buffer and ten polynomial slots. The operation sequence and its length depend only on the
parameter set and the public seed rho; Decaps always runs the re-encryption, comparison and key
selection in full and does not show whether the ciphertext was rejected. Not implemented: the
random source, the input checks of FIPS 203 7.2 / 7.3 (left to the host), masking. Core
`ML_KEM_top` (`rtl/ML_KEM_top.sv`), testbench `tb/ML_KEM_tb.sv` (FIPS 203 / ACVP vectors),
checker `tb/cov/ML_KEM_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. q = 3329. Names follow FIPS 203.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `start` | input | 1 | run `op` (taken when idle) | high | `clk` | - |
| `op` | input | 2 | 0 KeyGen, 1 Encaps, 2 Decaps, 3 reserved | - | `clk` | - |
| `pset` | input | 2 | 0 ML-KEM-512, 1 ML-KEM-768, 2 ML-KEM-1024, 3 reserved | - | `clk` | - |
| `busy` | output | 1 | an operation runs; combinational from the sequencer | high | comb | 0 |
| `done` | output | 1 | one-clock pulse: the operation finished | high | `clk` | 0 |
| `err` | output | 1 | one-clock pulse: `start` refused (reserved op / pset) | high | `clk` | 0 |
| `hp_load` | input | 1 | load the host word pointer from `hp_addr` | high | `clk` | - |
| `hp_addr` | input | 11 | host word address (byte address / 4) | - | `clk` | - |
| `hw_valid` | input | 1 | host write word | high | `clk` | - |
| `hw_data` | input | 32 | host write data, little-endian (byte 0 in bits 7:0) | - | `clk` | - |
| `hw_ready` | output | 1 | = !`busy` | high | comb | 1 |
| `hr_en` | input | 1 | host read request | high | `clk` | - |
| `hr_valid` | output | 1 | = `hr_en` && !`busy` | high | comb | 0 |
| `hr_data` | output | 32 | buffer word at the pointer, combinational | - | comb | - |
| `hr_ready` | input | 1 | host takes the read word (pointer increments) | high | `clk` | - |

### Internal signals used by the verification

The checker (`.*`) follows every program step through these names; fsm_cov also binds `qs`
(sequencer: 0 IDLE, 1 ISSUE, 2 WAIT), `hst` and `c_op` (the held copy of `u_op`). Keep the
names, widths and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `mem` | 8 x 8192 | the byte buffer, unpacked `[0:8191]` |
| `pm` | 12 x 2560 | polynomial store: slot * 256 + index (10 slots), unpacked `[0:2559]` |
| `ugo` | 1 | a program step starts this clock |
| `p_done` | 1 | the polynomial unit finished its step (one-clock pulse) |
| `h_done` | 1 | the Keccak unit finished a hash-to-buffer step (one-clock pulse) |
| `diff` | 1 | Decaps: c != c' (from the CMP step) |
| `u_op` | 4 | polynomial unit command: 0 NONE, 1 CBD (SamplePolyCBD), 2 SAMP (SampleNTT), 3 NTT, 4 INTT, 5 BMUL (MultiplyNTTs, accumulate), 6 ADD, 7 SUB, 8 ENC (ByteEncode, with Compress), 9 DEC (ByteDecode, with Decompress), 10 COPY, 11 CMP, 12 CSEL |
| `u_dst` | 4 | destination slot (0..3 T, 4..7 S, 8 ACC, 9 TMP) |
| `u_a` | 4 | first source slot |
| `u_b` | 4 | second source slot |
| `u_d` | 4 | bits per coefficient for ENC / DEC (12 when not compressing) |
| `u_eta3` | 1 | CBD with eta = 3 (else 2) |
| `u_cmp` | 1 | ENC / DEC with Compress_d / Decompress_d |
| `u_clr` | 1 | BMUL: clear the accumulator (first term) |
| `u_ma` | 8 | first buffer area, in 32-byte blocks |
| `u_mb` | 8 | second buffer area, in 32-byte blocks |
| `u_len` | 6 | length in 32-byte blocks (COPY, CMP, CSEL) |
| `h_on` | 1 | the step uses the Keccak unit |
| `h_strm` | 1 | squeezed bytes go to the samplers |
| `h_mode` | 2 | 0 SHA3-256, 1 SHA3-512, 2 SHAKE128, 3 SHAKE256 |
| `hst` | 2 | Keccak unit: 0 IDLE, 1 ABS, 2 PERM, 3 SQZ |
| `kseg` | 2 | absorb input: 0 first area, 1 second area, 2 immediate bytes |
| `h_ol` | 2 | output length in 32-byte blocks (hash to buffer) |
| `kout` | 7 | bytes squeezed so far |
| `k_in` | 1 | an input byte remains in the current segment |
| `h_wr` | 1 | a squeezed byte is written to the buffer this clock |
| `hs_valid` | 1 | a squeezed byte is offered to the samplers |
| `hs_ready` | 1 | the sampler takes it |
| `k_ib` | 8 | the byte being absorbed |
| `kbyte` | 8 | state byte at kpos |
| `kpos` | 8 | byte position in the rate |
| `rate` | 8 | 72 (SHA3-512), 168 (SHAKE128) or 136 |
| `pw0` | 1 | the last pipeline stage writes `pw0_d` |
| `pw1` | 1 | the last pipeline stage writes `pw1_d` |
| `pw0_d` | 12 | first value written |
| `pw1_d` | 12 | second value written |
| `spend` | 1 | SampleNTT: a second candidate of the 3-byte group is pending |
| `sbc` | 2 | SampleNTT: bytes of the current 3-byte group taken |
| `sd1` | 12 | SampleNTT: first candidate {b1[3:0], b0} |
| `sd2` | 12 | SampleNTT: second candidate {b2, b1[7:4]} |
| `pcnt` | 9 | coefficient / butterfly / pair index of the step |
| `mw` | 1 | the engine writes a buffer byte this clock |
| `mw_a` | 13 | its address |
| `mw_d` | 8 | its data |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/ML_KEM.md`](../ip/ML_KEM.md) (source: `scripts/apb/specs/ML_KEM.json`); do not edit by hand.

`ML_KEM_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4D4B0101 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Operation and buffer read control |
| 0x018 | PTR | RW | 0x00000000 | Buffer word address for LOAD |
| 0x01C | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x020 | DATA_IN | RW | 0x00000000 | Buffer write: the word goes to the pointer (little-endian bytes) and the pointer advances; taken while the engine is idle |
| 0x024 | DATA_OUT | RO (pop) | 0x00000000 | Buffer read: the word fetched while CTRL.hr_en is set; reading it fetches the next |
| 0x028 | STATUS | RO | core | Engine state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4D4B | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x01 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 1:0 | `op` | RW | 0x0 | operation: 0 KeyGen, 1 Encaps, 2 Decaps (3 is reserved: START sets ERR) |
| CTRL | 3:2 | `pset` | RW | 0x0 | parameter set: 0 ML-KEM-512, 1 ML-KEM-768, 2 ML-KEM-1024 (3 is reserved: START sets ERR) |
| CTRL | 4 | `hr_en` | RW | 0x0 | buffer read: while set and the engine is idle, the word at the pointer is fetched into DATA_OUT and the pointer advances |
| PTR | 10:0 | `hp_addr` | RW | 0x0 | word address (byte address / 4) in the 8 KiB buffer |
| CMD | 0 | `start` | WO (pulse) | 0x0 | run CTRL.op on CTRL.pset; ignored while busy |
| CMD | 1 | `hp_load` | WO (pulse) | 0x0 | load the buffer pointer from PTR |
| DATA_IN | 31:0 | `hw_data` | RW | 0x0 | word |
| DATA_OUT | 31:0 | `hr_data` | RO (pop) | 0x0 | word |
| STATUS | 0 | `busy` | RO | core | an operation is running (the buffer port is closed) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | the operation finished: results are in the buffer |
| 1 | ERR | START with a reserved op or parameter set: nothing was run |
| 2 | DATA_IN_DONE | DATA_IN beat accepted by the core |
| 3 | DATA_IN_OVF | write to DATA_IN while full (dropped) |
| 4 | DATA_OUT_AVAIL | DATA_OUT captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | DATA_IN_FULL | DATA_IN holds a beat the core has not taken |
| 1 | DATA_OUT_AVAIL | DATA_OUT holds an unread beat |

### Streams

* **DATA_IN** feeds `hw_data`/`hw_valid`. Writing DATA_IN commits the beat: FLAGS.DATA_IN_FULL is set and `hw_valid` stays high until the core's `hw_ready`; then DATA_IN_DONE is set. A write while full is dropped and sets DATA_IN_OVF.
* **DATA_OUT** takes `hr_data` from the core with `hr_valid` / `hr_ready`: `hr_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ DATA_OUT_AVAIL. Reading DATA_OUT pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4D4B0101.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), PTR (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `start` (CMD bit 0), `hp_load` (CMD bit 1) at 0x01C; the core sees a one-clock pulse, and the register reads 0.
6. To send on DATA_IN: wait until FLAGS.DATA_IN_FULL (bit 0) is 0, or for IRQ DATA_IN_DONE, then write DATA_IN (0x020). The last write commits the beat. DATA_IN_OVF means a write came while the register was full and was dropped.
7. To receive on DATA_OUT: wait for IRQ DATA_OUT_AVAIL or FLAGS.DATA_OUT_AVAIL (bit 1), then read DATA_OUT (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.DATA_OUT_AVAIL (bit 4) to clear it.
8. Read STATUS (0x028) for the core's live `busy`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write the inputs: PTR = word address, CMD.hp_load = 1, then the words to DATA_IN (for KeyGen d and z; Encaps ek and m; Decaps dk and c).
2. CTRL = op | pset << 2, CMD.start = 1; wait for IRQ_STATUS.DONE (or STATUS.busy = 0).
3. Read the outputs: PTR = word address, CMD.hp_load = 1, CTRL.hr_en = 1, then read DATA_OUT once per word; clear CTRL.hr_en and read DATA_OUT once more to drop the prefetched word.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Control

In idle, `start` with op 3 or pset 3 pulses `err` the next clock and does nothing. Otherwise
`busy` is high from the next clock until `done` (one clock, `busy` low with it). `start` while
busy is ignored. There is no result flag: Decaps rejection is implicit.

### 3.2 Host port

32-bit little-endian words at a word pointer: `hp_load` loads `hp_addr`; each clock with
`hw_valid` && `hw_ready` writes and each with `hr_valid` && `hr_ready` reads; both increment the
pointer. `hw_ready` = !`busy`, `hr_valid` = `hr_en` && !`busy`, `hr_data` = the word at the
pointer (combinational).

### 3.3 Buffer map (byte offsets)

| Offset | Field | Use |
|---|---|---|
| 0x0000 | ek (384 k + 32) | KeyGen out, Encaps in |
| 0x0620 | dk = dk_PKE \|\| ek \|\| H(ek) \|\| z (768 k + 96) | KeyGen out, Decaps in |
| 0x1280 | c (32 (du k + dv)) | Encaps out, Decaps in |
| 0x18A0 | c' (re-encryption) | Decaps scratch |
| 0x1EC0 | d (32) | KeyGen in |
| 0x1EE0 | z (32) | KeyGen in |
| 0x1F00 | m (32) | Encaps in |
| 0x1F20 | K (32) | Encaps / Decaps out (shared secret) |
| 0x1F40..0x1FFF | r, rho, sigma, H(ek), K_bar, m' | scratch |

Fields are sized for k = 4; smaller sets use the start of each field. k = 2 / 3 / 4, eta1 = 3 /
2 / 2, eta2 = 2, du = 10 / 10 / 11, dv = 4 / 4 / 5.

### 3.4 Programs

| Op | Steps |
|---|---|
| KeyGen | (rho, sigma) = G(d \|\| k); s[i] = CBD_eta1(PRF(sigma, i)), NTT; e[i] = CBD_eta1(PRF(sigma, k + i)), NTT; t^[i] = sum_j A^[i][j] s^[j] + e^[i] with A^[i][j] = SampleNTT(rho \|\| j \|\| i); ek = ByteEncode12(t^) \|\| rho; dk_PKE = ByteEncode12(s^); dk = dk_PKE \|\| ek \|\| H(ek) \|\| z |
| Encaps | (K, r) = G(m \|\| H(ek)); c = K-PKE.Encrypt(ek, m, r); K out |
| K-PKE.Encrypt | t^ = ByteDecode12(ek); y[i] = CBD_eta1(PRF(r, i)), NTT; u[i] = NTT^-1(sum_j A^[j][i] y^[j]) + CBD_eta2(PRF(r, k + i)), Compress_du; v = NTT^-1(t^ . y^) + CBD_eta2(PRF(r, 2k)) + Decompress_1(m), Compress_dv |
| Decaps | m' = Decode(Compress_1(v - NTT^-1(s^ . NTT(u)))); (K', r') = G(m' \|\| h); c' = K-PKE.Encrypt(ek, m', r'); K_bar = J(z \|\| c); diff = (c != c'); K = diff ? K_bar : K' |

G = SHA3-512, H = SHA3-256, J and PRF = SHAKE256, XOF = SHAKE128. A step is issued (`ugo` one
clock), and the sequencer waits until it is done, then goes to the next step, a loop body (over
i or j < k), a jump, or the end.

### 3.5 Units

- Keccak: absorbs one byte per clock from up to two buffer areas (32-byte blocks) and up to two
  immediate bytes, pads (0x06 for SHA3, 0x1F for SHAKE, plus the final bit), 24 rounds one per
  clock; squeezes one byte per clock to the buffer or to the samplers (`hs_valid` /
  `hs_ready`).
- Polynomial unit: one token per clock (a butterfly, a MultiplyNTTs pair, an addition, a sample,
  a packed coefficient); the store has registered reads; an 8-stage pipeline with exact
  constant-divisor reductions mod q (floor(x / q) = floor(x * 20642679 / 2^36) for x < 2^25)
  writes up to two coefficients per clock in issue order. SampleNTT takes 3-byte groups and
  accepts each 12-bit candidate below q. CSEL copies K_bar or K' by `diff` byte by byte, so both
  paths take the same clocks.

All coefficients in the store are in [0, q).

### 3.6 Reset

Idle, `busy` = `done` = `err` = 0, host pointer 0, `hw_ready` = 1. The buffer and the polynomial
store are not reset.

## 4. Parameters

None. The parameter set is chosen per operation with `pset`.

## 5. Errors and corner cases

- Malformed ek or dk (the FIPS 203 input checks) are not detected; the host must check them.
- Decaps with a wrong ciphertext returns K_bar without any visible difference.
- The host port is closed while busy.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "not busy after start" | `busy` the clock after an accepted start | §3.1 |
| "host port open while busy" | host port closed while busy | §3.2 |
| "timeout" | each operation completes | §3.4 |
| "busy after done" | `busy` low with `done` | §3.1 |
| "reserved op not refused" | op 3: `err` | §3.1 |
| "reserved pset not refused" | pset 3: `err` | §3.1 |
| "host word" | outputs (keys, ciphertext, shared secret) equal the vector | §3.3, §3.4 |
| "bad vector header" | (TB vector-file sanity) | - |
| "case" | (TB case bookkeeping) | - |
| "not idle in reset" | reset values | §3.6 |
| "host port closed after reset" | `hw_ready` after reset | §3.6 |
| a_hash_to_buffer | squeezed buffer bytes equal a reference SHA3 / SHAKE | §3.5 |
| a_hash_to_sampler | bytes streamed to the samplers equal the reference | §3.5 |
| a_ntt | NTT step as FIPS 203 | §3.5 |
| a_intt | NTT^-1 step | §3.5 |
| a_basemul | MultiplyNTTs (with accumulation) | §3.5 |
| a_add | addition | §3.5 |
| a_sub | subtraction | §3.5 |
| a_cbd | SamplePolyCBD | §3.5 |
| a_sample_ntt | SampleNTT | §3.5 |
| a_encode | ByteEncode / Compress | §3.5 |
| a_decode | ByteDecode / Decompress | §3.5 |
| a_copy | COPY | §3.5 |
| a_compare | CMP sets `diff` | §3.5 |
| a_select | CSEL picks K_bar or K' | §3.5 |
| a_coeff0_below_q | every coefficient written < q | §3.5 |
| a_coeff1_below_q | as above (second port) | §3.5 |
| a_hw_ready | `hw_ready` = !busy | §3.2 |
| a_hr_valid | `hr_valid` = hr_en && !busy | §3.2 |
| a_busy | `busy` from start to done | §3.1 |
| a_hr_data | `hr_data` = buffer word at the pointer | §3.2 |
| a_err | `err` exactly for refused starts | §3.1 |
| a_done_only_busy | `done` only at the end of a run | §3.1 |
| a_reset | reset values | §3.6 |
