<!-- SPDX-License-Identifier: Apache-2.0 -->
# ML_DSA: design specification

An ML-DSA (FIPS 204) engine for ML-DSA-44, -65 and -87: KeyGen, Sign and Verify as the internal
algorithms of FIPS 204 section 6 (ML-DSA.KeyGen_internal, Sign_internal, Verify_internal). The
seed xi and the signing randomness rnd come from the host, and the host formats M'. A program
sequencer drives a Keccak-f[1600] unit (SHAKE128 / SHAKE256, one round per clock) and a pipelined
polynomial unit over a 32 KiB byte buffer and 43 polynomial slots. Not implemented: the random
source, the message formatting of ML-DSA.Sign / Verify and HashML-DSA, side-channel masking and
fault countermeasures. Core `ML_DSA_top` (`rtl/ML_DSA_top.sv`), testbench `tb/ML_DSA_tb.sv`
(FIPS 204 / ACVP vectors), checker `tb/cov/ML_DSA_sva.sv` (independent reference models of every
step).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. q = 8380417. Algorithm and field names follow FIPS 204.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `start` | input | 1 | run `op` (taken when idle) | high | `clk` | - |
| `op` | input | 2 | 0 KeyGen, 1 Sign, 2 Verify, 3 reserved | - | `clk` | - |
| `pset` | input | 2 | 0 ML-DSA-44, 1 ML-DSA-65, 2 ML-DSA-87, 3 reserved | - | `clk` | - |
| `ext_mu` | input | 1 | Sign / Verify take mu from the buffer (skip mu = H(tr \|\| M')) | high | `clk` | - |
| `mlen` | input | 15 | length of M' in bytes (at most 16384 without `ext_mu`) | - | `clk` | - |
| `busy` | output | 1 | an operation runs; combinational from the sequencer | high | comb | 0 |
| `done` | output | 1 | one-clock pulse: the operation finished | high | `clk` | 0 |
| `err` | output | 1 | one-clock pulse: `start` refused (reserved op / pset / mlen) | high | `clk` | 0 |
| `fail` | output | 1 | Verify: signature rejected; held from `done` to the next start | high | `clk` | 0 |
| `tries` | output | 16 | Sign: attempts of the rejection loop; held from `done` to the next start | - | `clk` | 0 |
| `hp_load` | input | 1 | load the host word pointer from `hp_addr` | high | `clk` | - |
| `hp_addr` | input | 13 | host word address (byte address / 4) | - | `clk` | - |
| `hw_valid` | input | 1 | host write word | high | `clk` | - |
| `hw_data` | input | 32 | host write data, little-endian (byte 0 in bits 7:0) | - | `clk` | - |
| `hw_ready` | output | 1 | = !`busy` | high | comb | 1 |
| `hr_en` | input | 1 | host read request | high | `clk` | - |
| `hr_valid` | output | 1 | = `hr_en` && !`busy` | high | comb | 0 |
| `hr_data` | output | 32 | buffer word at the pointer, combinational | - | comb | - |
| `hr_ready` | input | 1 | host takes the read word (pointer increments) | high | `clk` | - |

### Internal signals used by the verification

The checker (`.*`) follows every program step through these names (step parameters, the Keccak
unit, the polynomial pipeline's write port, the buffer write port and the sampler state); fsm_cov
also binds `qs` (sequencer: 0 IDLE, 1 ISSUE, 2 WAIT), `hst`, `c_op` and `c_fn` (the held copies of
`u_op` / `u_fn`). Keep the names, widths and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `mem` | 8 x 32768 | the byte buffer, unpacked `[0:32767]` |
| `pm` | 23 x 11008 | polynomial store: slot * 256 + index (43 slots), unpacked `[0:11007]` |
| `ugo` | 1 | a program step starts this clock (the units load the step) |
| `p_done` | 1 | the polynomial unit finished its step (one-clock pulse) |
| `h_done` | 1 | the Keccak unit finished a hash-to-buffer step (one-clock pulse) |
| `bad` | 1 | Sign: this attempt is rejected; Verify: the signature is rejected |
| `pc` | 7 | program counter (step number, section 3.4) |
| `ci` | 3 | loop counter i (over k or l) |
| `psr` | 2 | parameter set of the running operation |
| `opr` | 2 | operation being run |
| `u_op` | 5 | polynomial unit command of the step: 0 NONE, 1 NTT, 2 INTT, 3 PMUL, 4 ADD, 5 SUB, 6 SA (RejNTTPoly multiply-accumulate), 7 SS (RejBoundedPoly), 8 SY (ExpandMask), 9 SIB (SampleInBall), 10 CLD (load c), 11 DEC, 12 ENC, 13 HINT (MakeHint), 14 HDEC (HintBitUnpack row), 15 HZ (hint padding check), 16 FILL, 17 COPY, 18 CMP |
| `u_dst` | 6 | destination slot |
| `u_a` | 6 | first source slot |
| `u_b` | 6 | second source slot |
| `u_clr` | 1 | SA: clear the accumulator (first column) |
| `u_add` | 1 | SY: add the sampled y to slot `u_b` |
| `u_chk` | 1 | DEC / ENC: check the infinity norm (z) |
| `u_fn` | 3 | coefficient transform: 0 OFF (offset - x), 1 SHL (x * 2^13), 2 P2H (Power2Round high), 3 P2L (Power2Round low), 4 HB (HighBits), 5 UH (UseHint) |
| `u_n` | 5 | bits per packed coefficient |
| `u_off` | 20 | offset of the OFF transform / norm bound |
| `u_ma` | 14 | first buffer address of the step |
| `u_mb` | 14 | second buffer address of the step |
| `u_len` | 7 | byte count (COPY, FILL, CMP) |
| `h_on` | 1 | the step uses the Keccak unit |
| `h_strm` | 1 | squeezed bytes go to the samplers, not the buffer |
| `h_128` | 1 | SHAKE128 (rate 168), else SHAKE256 (rate 136) |
| `h_ol` | 8 | bytes to squeeze into the buffer |
| `hst` | 2 | Keccak unit: 0 IDLE, 1 ABS (absorb), 2 PERM, 3 SQZ |
| `kseg` | 2 | absorb input: 0 first buffer area, 1 second area, 2 immediate bytes |
| `k_in` | 1 | an input byte remains in the current segment |
| `h_wr` | 1 | a squeezed byte is written to the buffer this clock |
| `hs_valid` | 1 | squeezed bytes offered to the samplers |
| `hs_ready` | 1 | the sampler takes them |
| `hs_n` | 2 | bytes offered: 3 when the step takes 3-byte groups and they fit in the rate, else 1 |
| `hs_data` | 24 | the offered bytes (state bytes kpos..kpos+2) |
| `k_ib` | 8 | the byte being absorbed |
| `kbyte` | 8 | state byte at kpos (the squeezed byte) |
| `kpos` | 8 | byte position in the rate |
| `rate` | 8 | 168 or 136 |
| `kout` | 8 | bytes squeezed so far in the step |
| `pw0` | 1 | the last pipeline stage writes `o0` |
| `pw1` | 1 | the last pipeline stage writes `o1` |
| `o0` | 23 | first value written by the last stage |
| `o1` | 23 | second value written by the last stage |
| `cnz` | 256 | SampleInBall: c[i] != 0 |
| `cng` | 256 | SampleInBall: c[i] = -1 |
| `hv` | 256 | Verify: the hints of the current row |
| `hidx` | 7 | hint index (Sign: hints made, up to omega + 1; Verify: hints read) |
| `kap` | 16 | Sign: kappa (ExpandMask counter base) |
| `mw` | 1 | the engine writes a buffer byte this clock |
| `mw_a` | 14 | its address |
| `mw_d` | 8 | its data |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/ML_DSA.md`](../ip/ML_DSA.md) (source: `scripts/apb/specs/ML_DSA.json`); do not edit by hand.

`ML_DSA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4D640100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Operation and buffer read control |
| 0x018 | MLEN | RW | 0x00000000 | Length of M' in bytes |
| 0x01C | PTR | RW | 0x00000000 | Buffer word address for LOAD |
| 0x020 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x024 | DATA_IN | RW | 0x00000000 | Buffer write: the word goes to the pointer (little-endian bytes) and the pointer advances; taken while the engine is idle |
| 0x028 | DATA_OUT | RO (pop) | 0x00000000 | Buffer read: the word fetched while CTRL.hr_en is set; reading it fetches the next |
| 0x02C | STATUS | RO | core | Engine state and the last operation's result |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4D64 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 1:0 | `op` | RW | 0x0 | operation: 0 KeyGen, 1 Sign, 2 Verify (3 is reserved: START sets ERR) |
| CTRL | 3:2 | `pset` | RW | 0x0 | parameter set: 0 ML-DSA-44, 1 ML-DSA-65, 2 ML-DSA-87 (3 is reserved: START sets ERR) |
| CTRL | 4 | `hr_en` | RW | 0x0 | buffer read: while set and the engine is idle, the word at the pointer is fetched into DATA_OUT and the pointer advances |
| CTRL | 5 | `ext_mu` | RW | 0x0 | Sign and Verify take mu (64 bytes at 0x2FC0) from the buffer instead of computing H(tr || M') |
| MLEN | 14:0 | `mlen` | RW | 0x0 | bytes of M' at 0x4000 (Sign and Verify without ext_mu); above 16384 START sets ERR |
| PTR | 12:0 | `hp_addr` | RW | 0x0 | word address (byte address / 4) in the 32 KiB buffer |
| CMD | 0 | `start` | WO (pulse) | 0x0 | run CTRL.op on CTRL.pset; ignored while busy |
| CMD | 1 | `hp_load` | WO (pulse) | 0x0 | load the buffer pointer from PTR |
| DATA_IN | 31:0 | `hw_data` | RW | 0x0 | word |
| DATA_OUT | 31:0 | `hr_data` | RO (pop) | 0x0 | word |
| STATUS | 0 | `busy` | RO | core | an operation is running (the buffer port is closed) |
| STATUS | 1 | `fail` | RO | core | Verify: the signature was rejected (held from DONE to the next START) |
| STATUS | 17:2 | `tries` | RO | core | Sign: attempts of the rejection loop (held from DONE to the next START) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | the operation finished: results are in the buffer, STATUS.fail / tries are valid |
| 1 | ERR | START with a reserved op or parameter set, or MLEN above 16384 without ext_mu: nothing was run |
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

1. Release PRESETN. Read ID (0x000) and check it is 0x4D640100.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), MLEN (0x018), PTR (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `start` (CMD bit 0), `hp_load` (CMD bit 1) at 0x020; the core sees a one-clock pulse, and the register reads 0.
6. To send on DATA_IN: wait until FLAGS.DATA_IN_FULL (bit 0) is 0, or for IRQ DATA_IN_DONE, then write DATA_IN (0x024). The last write commits the beat. DATA_IN_OVF means a write came while the register was full and was dropped.
7. To receive on DATA_OUT: wait for IRQ DATA_OUT_AVAIL or FLAGS.DATA_OUT_AVAIL (bit 1), then read DATA_OUT (0x028). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.DATA_OUT_AVAIL (bit 4) to clear it.
8. Read STATUS (0x02C) for the core's live `busy`, `fail`, `tries`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write the inputs: PTR = word address, CMD.hp_load = 1, then the words to DATA_IN (KeyGen: xi; Sign: sk, rnd and M' or mu; Verify: pk, sig and M' or mu). Write MLEN.
2. CTRL = op | pset << 2 | ext_mu << 5, CMD.start = 1; wait for IRQ_STATUS.DONE (or STATUS.busy = 0). Verify: STATUS.fail = 0 accepts the signature.
3. Read the outputs: PTR = word address, CMD.hp_load = 1, CTRL.hr_en = 1, then read DATA_OUT once per word; clear CTRL.hr_en and read DATA_OUT once more to drop the prefetched word.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Control

In idle, `start` with op 3, pset 3, or (op != KeyGen, !`ext_mu`, `mlen` > 16384) pulses `err`
the next clock and does nothing. Otherwise the inputs are taken, `fail` and `tries` clear, and
`busy` is high from the next clock until `done` (one clock, `busy` low with it). `start` while
busy is ignored. Verify sets `fail` with `done` when the signature is rejected; Sign sets `tries`
to the number of attempts. Both hold until the next accepted start.

### 3.2 Host port

The buffer is read and written as 32-bit little-endian words at a word pointer: `hp_load` loads
`hp_addr`; each clock with `hw_valid` && `hw_ready` writes the word and each clock with
`hr_valid` && `hr_ready` reads one; both increment the pointer. `hw_ready` = !`busy`, `hr_valid` =
`hr_en` && !`busy`, `hr_data` = the word at the pointer (combinational).

### 3.3 Buffer map (byte offsets)

| Offset | Field | Use |
|---|---|---|
| 0x0000 | PK = rho \|\| t1 (32 + 320 k bytes) | KeyGen out, Verify in |
| 0x0A20 | SK = rho \|\| K \|\| tr \|\| s1 \|\| s2 \|\| t0 | KeyGen out, Sign in |
| 0x1D40 | SIG = c~ \|\| z \|\| h | Sign out, Verify in |
| 0x2F60 | xi (32) | KeyGen in |
| 0x2F80 | K copy (32), then 0x2FA0 rnd (32; zero for deterministic signing) | Sign |
| 0x2FC0 | mu (64) | in with `ext_mu`, else computed |
| 0x3000..0x3FFF | scratch (tr, hash output, c~', rho'', w1Encode) | engine |
| 0x4000 | M' (`mlen` bytes) | Sign, Verify in |

Fields are sized for ML-DSA-87; smaller sets use the start of each field. Sizes follow FIPS 204
(k, l = 4, 4 / 6, 5 / 8, 7; eta 2 / 4 / 2; |c~| 32 / 48 / 64; gamma1 2^17 / 2^19 / 2^19; gamma2
(q-1)/88 / (q-1)/32 / (q-1)/32; beta 78 / 196 / 120; omega 80 / 55 / 75; tau 39 / 49 / 60).

### 3.4 Programs

A step is issued (`ugo` one clock), then the sequencer waits until it is done (polynomial unit
done if it has a command, else the hash unit done), then moves on: next step, back to a loop body
(over j < l, i < l or i < k), the rejection decision, or the end.

| Op | Steps (pc) |
|---|---|
| KeyGen (0..14) | (rho, rho', K) = H(xi \|\| k \|\| l, 128); copy rho to PK and SK, K to SK; for each i < l: s1[i] = RejBoundedPoly(rho', i), Encode into SK, NTT; for each i < k: t^ = sum_j RejNTTPoly(rho, j, i) * s1^[j], NTT^-1, s2[i] = RejBoundedPoly(rho', l + i), Encode into SK, t = t + s2, Power2Round into t1 (PK) and t0 (SK); tr = H(PK, 64) into SK |
| Sign (16..45) | decode s1, s2, t0 from SK and NTT them; mu = H(tr \|\| M', 64) unless `ext_mu`; rho'' = H(K \|\| rnd \|\| mu, 64); loop: y[i] = ExpandMask(rho'', kappa + i), NTT; w = A^ y^ (NTT^-1), w1 = HighBits encoded; c~ = H(mu \|\| w1Encode, lambda/4) into SIG; c = SampleInBall(c~), NTT; z[i] = y[i] + c s1[i], Encode into SIG with the norm check; hints: zero the h field, for each i: w - c s2, c t0, MakeHint with its checks into h; if any check failed (bad) kappa += l and the loop repeats, else done |
| Verify (48..65) | tr = H(PK, 64), mu = H(tr \|\| M', 64) unless `ext_mu`; decode z with the norm check, NTT; c from c~ (SampleInBall), NTT; for each i: A^ z^ - c t1 2^13, NTT^-1, HintBitUnpack row i, UseHint encoded into w1; hint padding check; c~' = H(mu \|\| w1Encode); compare c~ and c~'; `fail` = any check failed |

Sign repeats the loop while `bad` is set at its end (`tries` counts attempts); Verify's `fail` is
`bad` at the end. `bad` is cleared at start and at the start of every Sign attempt, and set by:
a z coefficient with |z| >= gamma1 - beta, a MakeHint check (|r0| >= gamma2 - beta, |ct0| >=
gamma2, more than omega hints), a malformed hint encoding, non-zero hint padding, or c~ != c~'.

### 3.5 Units

- Keccak: absorbs one byte per clock from up to two buffer areas and up to two immediate bytes,
  pads (SHAKE domain 0x1F and the final bit), runs 24 rounds, one per clock, per permutation;
  squeezes one byte per clock into the buffer, or offers 1 or 3 bytes per clock to the samplers
  (`hs_valid` / `hs_ready`) until the polynomial step is done.
- Polynomial unit: an issue stage makes one token per clock (a butterfly, product, sample,
  packed coefficient or byte), the store has registered reads, and a 6-stage pipeline (product,
  three folds of 2^23 = 2^13 - 1 for the reduction mod q, butterfly / accumulate) writes up to two
  coefficients per clock from its last stage, in issue order. Zetas are 1753^BitRev8(i) mod q.
  The step is done when its last token has been written. Matrix A is sampled on the fly into the
  multiply-accumulate and never stored.

All coefficients in the store are kept in [0, q).

### 3.6 Reset

Idle, `busy` = `done` = `err` = `fail` = 0, `tries` = 0, host pointer 0, `hw_ready` = 1. The
buffer and polynomial store are not reset.

## 4. Parameters

None. The parameter set is chosen per operation with `pset`.

## 5. Errors and corner cases

- `err` is the only refusal; malformed keys or signatures are not errors: Verify returns `fail`.
- The host port is closed while busy (no reads or writes).
- Sign with rnd = 0 is the deterministic variant; with `ext_mu` the message is not read.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "not busy after start" | `busy` the clock after an accepted start | §3.1 |
| "host port open while busy" | `hw_ready` / `hr_valid` low while busy | §3.2 |
| "timeout" | each operation completes | §3.4 |
| "busy after done" | `busy` low with `done` | §3.1 |
| "reserved op not refused" | op 3: `err`, no run | §3.1 |
| "reserved pset not refused" | pset 3: `err` | §3.1 |
| "message length over 16384 not refused" | mlen > 16384 without ext_mu: `err` | §3.1 |
| "host word" | buffer contents after each operation equal the vector (keys, signatures) | §3.3 |
| "bad vector header" | (TB vector-file sanity) | - |
| "case" | Verify `fail` and Sign `tries` equal the vector | §3.4 |
| "not idle in reset" | reset values | §3.6 |
| "host port closed after reset" | `hw_ready` after reset | §3.6 |
| a_step_done_after_start | every step ends | §3.5 |
| a_verify_z_norm_checked | Verify checks the z norm while decoding | §3.4 |
| a_hash_to_buffer | squeezed buffer bytes equal a reference SHAKE | §3.5 |
| a_hash_to_sampler | bytes streamed to the samplers equal the reference | §3.5 |
| a_ntt | NTT step as FIPS 204 | §3.5 |
| a_intt | NTT^-1 step | §3.5 |
| a_pointwise | pointwise product | §3.5 |
| a_add | addition | §3.5 |
| a_sub | subtraction | §3.5 |
| a_rej_ntt_poly_mac | RejNTTPoly multiply-accumulate | §3.5 |
| a_rej_bounded_poly | RejBoundedPoly | §3.5 |
| a_expand_mask | ExpandMask BitUnpack | §3.5 |
| a_sample_in_ball | SampleInBall | §3.5 |
| a_load_c | c loaded into its slot | §3.5 |
| a_decode | Decode (BitUnpack) with its checks | §3.5 |
| a_encode | Encode (BitPack / SimpleBitPack, Power2Round, HighBits, UseHint) | §3.5 |
| a_make_hint | MakeHint and HintBitPack | §3.5 |
| a_hint_unpack | HintBitUnpack row with malformed-input checks | §3.5 |
| a_hint_padding | HintBitUnpack padding check | §3.5 |
| a_fill | FILL | §3.5 |
| a_copy | COPY | §3.5 |
| a_compare | CMP (c~ = c~') | §3.5 |
| a_coeff0_below_q | every coefficient written < q | §3.5 |
| a_coeff1_below_q | as above (second write port) | §3.5 |
| a_hw_ready | `hw_ready` = !busy | §3.2 |
| a_hr_valid | `hr_valid` = hr_en && !busy | §3.2 |
| a_busy | `busy` from start to done | §3.1 |
| a_hr_data | `hr_data` = buffer word at the pointer | §3.2 |
| a_err | `err` exactly for refused starts | §3.1 |
| a_done_only_busy | `done` only at the end of a run | §3.1 |
| a_sign_retry | Sign restarts the loop exactly when the attempt is rejected | §3.4 |
| a_sign_done | Sign ends at the first accepted attempt | §3.4 |
| a_verify_result | `fail` = reject flag at the end | §3.4 |
| a_no_fail_but_verify | `fail` only after Verify | §3.1 |
| a_results_held | `fail` / `tries` hold until the next start | §3.1 |
| a_reset | reset values | §3.6 |
