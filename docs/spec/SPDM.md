# SPDM: design specification

Hardware SPDM 1.2 responder (DMTF DSP0274) for device attestation with a post-quantum ML-DSA identity key. It is built on three SHA3-384 transcript engines (`SPDM_th` around `SHA3_top`: M1, L1 and an auxiliary engine) and one `ML_DSA_top` engine (KeyGen and Sign). Message formats follow the public DSP0274 1.2 text. The asymmetric algorithm is an ExtAsym entry `asym_id`, and the IP is not claimed to be interoperable with a given requester stack.

Not implemented: sessions (KEY_EXCHANGE, PSK, secured messages), mutual authentication, slots 1-7, chunking, SPDM 1.0 / 1.1 / 1.3, RESPOND_IF_READY, opaque data, and raw bit-stream measurements.

Core `SPDM_top` (`rtl/SPDM_top.sv`), testbench `tb/SPDM_tb.sv`, checker `tb/cov/SPDM_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `ct_exp` | input | 8 | CAPABILITIES CTExponent | - | `clk` | - |
| `asym_id` | input | 32 | ExtAsym entry that names the ML-DSA key (no SPDM 1.2 code point exists) | - | `clk` | - |
| `pset` | input | 2 | KeyGen parameter set: 0 ML-DSA-44, 1 ML-DSA-65, 2 ML-DSA-87, 3 refused | - | `clk` | - |
| `cc_len` | input | CC_AW+1 | certificate chain length in bytes (0: slot 0 empty) | - | `clk` | - |
| `m_en` | input | NM | measurement index i + 1 present | high | `clk` | - |
| `m_tcb` | input | NM | index i + 1 is part of the TCB measurement summary | high | `clk` | - |
| `m_type` | input | NM*8 | DMTF measurement value type of index i + 1 in [8i+7:8i] | - | `clk` | - |
| `st_we` | input | 1 | store write | high | `clk` | - |
| `st_sel` | input | 1 | 0 certificate chain store, 1 measurement store | - | `clk` | - |
| `st_addr` | input | CC_AW-2 | store word address. Chain: byte address / 4. Measurements: index i in bits [..:4], word 0..11 in bits 3:0 | - | `clk` | - |
| `st_data` | input | 32 | store word, little-endian (byte 0 in bits 7:0) | - | `clk` | - |
| `kg_start` | input | 1 | run ML-DSA KeyGen (taken when idle) | high | `clk` | - |
| `kg_sel` | input | 1 | KeyGen seed: 0 `seed`, 1 `sl_seed` | - | `clk` | - |
| `seed` | input | 256 | KeyGen seed xi (byte 0 in bits 7:0) | - | `clk` | - |
| `sl_seed` | input | 256 | sideload seed (for example a DICE CDI) | - | `clk` | - |
| `sl_valid` | input | 1 | `sl_seed` valid | high | `clk` | - |
| `pk_open` | input | 1 | stream the public key out on `pk_*` (taken when idle with a key) | high | `clk` | - |
| `clr` | input | 1 | abort, wipe the key, seed and nonces, end the connection | high | `clk` | - |
| `pk_valid` | output | 1 | public key word valid | high | comb | 0 |
| `pk_data` | output | 32 | public key word (ML-DSA buffer order) | - | comb | - |
| `pk_last` | output | 1 | last public key word (328 / 488 / 648 words) | high | comb | - |
| `pk_ready` | input | 1 | consumer takes the word | high | `clk` | - |
| `rn_valid` | input | 1 | random word valid (for example from a TRNG) | high | `clk` | - |
| `rn_data` | input | 32 | random word | - | `clk` | - |
| `rn_ready` | output | 1 | random word taken (only while fetching a nonce or rnd) | high | comb | 0 |
| `rq_valid` | input | 1 | request byte valid | high | `clk` | - |
| `rq_data` | input | 8 | request byte | - | `clk` | - |
| `rq_last` | input | 1 | last request byte | high | `clk` | - |
| `rq_ready` | output | 1 | request byte taken; combinational (§3.1) | high | comb | 1 |
| `rs_valid` | output | 1 | response byte valid | high | comb | 0 |
| `rs_data` | output | 8 | response byte | - | comb | - |
| `rs_last` | output | 1 | last response byte | high | comb | - |
| `rs_ready` | input | 1 | consumer takes the byte | high | `clk` | - |
| `busy` | output | 1 | = `st` != IDLE | high | comb | 0 |
| `conn` | output | 2 | connection state: 0 none, 1 VERSION, 2 CAPABILITIES, 3 ALGORITHMS | - | `clk` | 0 |
| `key_ok` | output | 1 | a key pair is present | high | `clk` | 0 |
| `key_pset` | output | 2 | parameter set of the key | - | `clk` | 0 |
| `rsp_done` | output | 1 | one-clock pulse: a response was completed | high | `clk` | 0 |
| `rsp_err` | output | 1 | with `rsp_done`: it was an ERROR | high | `clk` | 0 |
| `err_code` | output | 8 | code of the last ERROR sent (held) | - | `clk` | 0 |
| `kg_done` | output | 1 | one-clock pulse: KeyGen finished, `key_ok` = 1 | high | `clk` | 0 |
| `cmd_err` | output | 1 | one-clock pulse, the clock after a refused `kg_start` / `pk_open` | high | `clk` | 0 |

### Internal signals used by the verification

The checker binds these (`.*`). They are the core's connection to its `ML_DSA_top` instance `u_mldsa` and its state. The TB also reads the ML-DSA byte buffer `u_mldsa.mem` (seed area at byte 0x2F60) to check that the seed was wiped.

| Signal | Width | Meaning |
|---|---|---|
| `st` | 5 | control FSM (also FSM coverage): 0 IDLE, 1 RX, 2 DEC, 3 AX (chain / summary hash), 4 RN (random words), 5 FRQ (request into the transcripts), 6 OUT, 7 FIN (transcript hash), 8 MW (write M'), 9 SG (Sign), 10 SIGO (signature out), 11 RPL (transcript restart with VCA), 12 KG (write seed), 13 KGW (KeyGen), 14 KGZ (wipe seed), 15 PK, 16 CLR (wipe) |
| `ml_start` | 1 | start pulse to `ML_DSA_top` (op = KeyGen in KGW, Sign in SG) |
| `ml_done` | 1 | `ML_DSA_top` done |
| `ml_busy` | 1 | `ML_DSA_top` busy |
| `hp_load` | 1 | ML-DSA host port: load the word pointer from `hp_addr` |
| `hp_addr` | 13 | ML-DSA buffer word address: PK 0x000, SK 0x288, SIG 0x750, XI (seed) 0xBD8, RND 0xBE8, MSG 0x1000 |
| `hw_valid` | 1 | ML-DSA host write word valid |
| `hw_data` | 32 | ML-DSA host write data |
| `hw_ready` | 1 | ML-DSA host port ready (engine idle) |
| `hr_en` | 1 | ML-DSA host read request |
| `hr_valid` | 1 | ML-DSA host read word valid |
| `hr_data` | 32 | ML-DSA host read word (signature bytes, public key words) |
| `hr_ready` | 1 | ML-DSA host read word taken (pointer increments) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SPDM.md`](../ip/SPDM.md) (source: `scripts/apb/specs/SPDM.json`); do not edit by hand.

`SPDM_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sl_seed`, `sl_valid`, `rq_valid`, `rq_data`, `rq_last`, `rq_ready`, `rs_valid`, `rs_data`, `rs_last`, `rs_ready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53640100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000000 | Responder configuration |
| 0x018 | ASYM | RW | 0x00000000 | ExtAsym entry of the ML-DSA key (RegistryID, reserved, AlgorithmID; little-endian as in the message) |
| 0x01C | CCLEN | RW | 0x00000000 | Certificate chain of slot 0 |
| 0x020 | MEAS | RW | 0x00000000 | Measurement indices |
| 0x024 | MTYPE | RW | 0x00000000 | DMTF measurement value types |
| 0x028 | STORE0 | RW | 0x00000000 | Store write: STORE0 = data word, STORE1 = {sel, address}, which commits it. sel 0: certificate chain word address (bytes 4a .. 4a + 3, little-endian); sel 1: measurement word 16 i + w (w = 0..11: digest bytes 4w .. 4w + 3 of index i + 1) |
| 0x02C | STORE1 | RW | 0x00000000 | Store write: STORE0 = data word, STORE1 = {sel, address}, which commits it. sel 0: certificate chain word address (bytes 4a .. 4a + 3, little-endian); sel 1: measurement word 16 i + w (w = 0..11: digest bytes 4w .. 4w + 3 of index i + 1) |
| 0x030 | SEED0 | WO | 0x00000000 | KeyGen seed xi, eight write-only words (SEED0 = bytes 3..0); reads return 0. Write zeros after CMD.kg_start |
| 0x034 | SEED1 | WO | 0x00000000 | KeyGen seed xi, eight write-only words (SEED0 = bytes 3..0); reads return 0. Write zeros after CMD.kg_start |
| 0x038 | SEED2 | WO | 0x00000000 | KeyGen seed xi, eight write-only words (SEED0 = bytes 3..0); reads return 0. Write zeros after CMD.kg_start |
| 0x03C | SEED3 | WO | 0x00000000 | KeyGen seed xi, eight write-only words (SEED0 = bytes 3..0); reads return 0. Write zeros after CMD.kg_start |
| 0x040 | SEED4 | WO | 0x00000000 | KeyGen seed xi, eight write-only words (SEED0 = bytes 3..0); reads return 0. Write zeros after CMD.kg_start |
| 0x044 | SEED5 | WO | 0x00000000 | KeyGen seed xi, eight write-only words (SEED0 = bytes 3..0); reads return 0. Write zeros after CMD.kg_start |
| 0x048 | SEED6 | WO | 0x00000000 | KeyGen seed xi, eight write-only words (SEED0 = bytes 3..0); reads return 0. Write zeros after CMD.kg_start |
| 0x04C | SEED7 | WO | 0x00000000 | KeyGen seed xi, eight write-only words (SEED0 = bytes 3..0); reads return 0. Write zeros after CMD.kg_start |
| 0x050 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x054 | PK0 | RO (pop) | 0x00000000 | Public key word (PK0 = bytes 3..0, little-endian), PK1 = last flag; reading PK1 pops it. 1312 / 1952 / 2592 bytes |
| 0x058 | PK1 | RO (pop) | 0x00000000 | Public key word (PK0 = bytes 3..0, little-endian), PK1 = last flag; reading PK1 pops it. 1312 / 1952 / 2592 bytes |
| 0x05C | RN | RW | 0x00000000 | Random word (from a TRNG): eight per responder nonce, eight more per signature (rnd); the core takes them while it answers CHALLENGE and GET_MEASUREMENTS |
| 0x060 | STATUS | RO | core | Responder state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x064 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5364 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 6:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 6:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 7:0 | `ct_exp` | RW | 0x0 | CAPABILITIES CTExponent: the requester's timeout is 2^ct_exp microseconds (cover the ML-DSA signing time) |
| CFG | 9:8 | `pset` | RW | 0x0 | CMD.kg_start parameter set: 0 ML-DSA-44, 1 ML-DSA-65, 2 ML-DSA-87 (3 is refused with CMD_ERR) |
| CFG | 10 | `kg_sel` | RW | 0x0 | CMD.kg_start seed: 0 the SEED registers, 1 the sideload port sl_seed (refused with CMD_ERR unless sl_valid) |
| ASYM | 31:0 | `asym_id` | RW | 0x0 | matched against the requester's ExtAsym list in NEGOTIATE_ALGORITHMS and returned in ALGORITHMS |
| CCLEN | 14:0 | `cc_len` | RW | 0x0 | bytes of the chain in the store (0: slot 0 empty); at most 16384 |
| MEAS | 3:0 | `m_en` | RW | 0x0 | bit i: measurement index i + 1 present |
| MEAS | 7:4 | `m_tcb` | RW | 0x0 | bit i: index i + 1 is part of the TCB measurement summary hash (CHALLENGE type 1) |
| MTYPE | 31:0 | `m_type` | RW | 0x0 | bits 8i+7:8i: DMTFSpecMeasurementValueType of index i + 1 (the value is a 48-byte SHA3-384 digest) |
| STORE0 | 31:0 | `st_data` | RW | 0x0 | data word |
| STORE1 | 11:0 | `st_addr` | RW | 0x0 | word address |
| STORE1 | 12 | `st_sel` | RW | 0x0 | 0 certificate chain, 1 measurement |
| SEED0 | 31:0 | `seed[31:0]` | WO | 0x0 | 32-byte ML-DSA KeyGen seed, little-endian |
| SEED1 | 31:0 | `seed[63:32]` | WO | 0x0 | 32-byte ML-DSA KeyGen seed, little-endian |
| SEED2 | 31:0 | `seed[95:64]` | WO | 0x0 | 32-byte ML-DSA KeyGen seed, little-endian |
| SEED3 | 31:0 | `seed[127:96]` | WO | 0x0 | 32-byte ML-DSA KeyGen seed, little-endian |
| SEED4 | 31:0 | `seed[159:128]` | WO | 0x0 | 32-byte ML-DSA KeyGen seed, little-endian |
| SEED5 | 31:0 | `seed[191:160]` | WO | 0x0 | 32-byte ML-DSA KeyGen seed, little-endian |
| SEED6 | 31:0 | `seed[223:192]` | WO | 0x0 | 32-byte ML-DSA KeyGen seed, little-endian |
| SEED7 | 31:0 | `seed[255:224]` | WO | 0x0 | 32-byte ML-DSA KeyGen seed, little-endian |
| CMD | 0 | `kg_start` | WO (pulse) | 0x0 | generate the identity key (ML-DSA KeyGen of CFG.pset from the seed); refused with CMD_ERR while busy |
| CMD | 1 | `pk_open` | WO (pulse) | 0x0 | stream the public key into PK; refused with CMD_ERR while busy or without a key |
| CMD | 2 | `clr` | WO (pulse) | 0x0 | abort what runs (after an ML-DSA operation in progress), wipe the private key, the seed area and the nonce, end the connection |
| PK0 | 31:0 | `pk_data` | RO (pop) | 0x0 | public-key bytes |
| PK1 | 0 | `pk_last` | RO (pop) | 0x0 | last word of the key |
| RN | 31:0 | `rn_data` | RW | 0x0 | random word |
| STATUS | 0 | `busy` | RO | core | a request, a command or a clr is in progress |
| STATUS | 2:1 | `conn` | RO | core | connection: 0 none, 1 after VERSION, 2 after CAPABILITIES, 3 after ALGORITHMS |
| STATUS | 3 | `key_ok` | RO | core | an identity key is present |
| STATUS | 5:4 | `key_pset` | RO | core | its parameter set |
| STATUS | 13:6 | `err_code` | RO | core | ErrorCode of the last ERROR response |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RSP_DONE | a response was sent |
| 1 | RSP_ERR | ... and it was an ERROR (STATUS.err_code) |
| 2 | KG_DONE | the identity key was generated |
| 3 | CMD_ERR | CMD.kg_start or CMD.pk_open was refused |
| 4 | PK_AVAIL | PK captured a beat |
| 5 | RN_DONE | RN beat accepted by the core |
| 6 | RN_OVF | write to RN while full (dropped) |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | PK_AVAIL | PK holds an unread beat |
| 1 | RN_FULL | RN holds a beat the core has not taken |

### Streams

* **STORE** feeds `st_data`, `st_addr`, `st_sel`; writing STORE1 pulses `st_we` for one clock.
* **PK** takes `pk_data`, `pk_last` from the core with `pk_valid` / `pk_ready`: `pk_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ PK_AVAIL. Reading PK1 pops it. Nothing is dropped: the core holds its data until the register is free.
* **RN** feeds `rn_data`/`rn_valid`. Writing RN commits the beat: FLAGS.RN_FULL is set and `rn_valid` stays high until the core's `rn_ready`; then RN_DONE is set. A write while full is dropped and sets RN_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53640100.
2. Write 0x7F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014), ASYM (0x018), CCLEN (0x01C), MEAS (0x020), MTYPE (0x024), SEED0 (0x030), SEED1 (0x034), SEED2 (0x038), SEED3 (0x03C), SEED4 (0x040), SEED5 (0x044), SEED6 (0x048), SEED7 (0x04C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7F enables all).
5. To send on STORE: write STORE0 (0x028) then STORE1 (0x02C). The last write pulses `st_we` for one clock; there is no back-pressure.
6. To issue a command, write 1 to `kg_start` (CMD bit 0), `pk_open` (CMD bit 1), `clr` (CMD bit 2) at 0x050; the core sees a one-clock pulse, and the register reads 0.
7. To receive on PK: wait for IRQ PK_AVAIL or FLAGS.PK_AVAIL (bit 0), then read PK0 (0x054) then PK1 (0x058). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.PK_AVAIL (bit 4) to clear it.
8. To send on RN: wait until FLAGS.RN_FULL (bit 1) is 0, or for IRQ RN_DONE, then write RN (0x05C). The last write commits the beat. RN_OVF means a write came while the register was full and was dropped.
9. Read STATUS (0x060) for the core's live `busy`, `conn`, `key_ok`, `key_pset`, `err_code`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write the certificate chain (DSP0274 format: length, reserved, root hash, DER certificates) with STORE (sel 0) and CCLEN; write the measurement digests with STORE (sel 1), MTYPE and MEAS. Write ASYM with the ExtAsym value the requesters use.
2. Generate the key: CFG.pset (and kg_sel), SEED (or the sideload port), CMD.kg_start = 1; wait for IRQ_STATUS.KG_DONE, write zeros to SEED. For a certificate request, CMD.pk_open = 1 and read PK0 / PK1 until the last flag.
3. Keep RN supplied with random words (FLAGS.RN_FULL = 0: write the next word) while requests are answered; requests and responses use the rq_* / rs_* byte pins. IRQ_STATUS.RSP_DONE / RSP_ERR report each response.
4. CMD.clr = 1 ends the connection and wipes the key (generate a new one before the next CHALLENGE).
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Request and response streams

- **Taking a request:** `rq_ready` = 1 in RX, and in IDLE unless `clr` (or a pending clr), `kg_start` or `pk_open` is high that clock.
  - In IDLE the first byte is taken and the core goes to RX, or straight to DEC when it is also `rq_last`.
  - Requests are byte streams of at most RQ_MAX = 128 bytes. Longer ones are taken to the end and answered with ERROR InvalidRequest.
  - One request is handled at a time. `rq_ready` is low from DEC until the response is complete.
- **DEC:** one clock that decides the error code (§3.2) and the response.
- **FRQ:** the request bytes go into the transcripts it belongs to, at the transcript engines' pace. An ERROR goes straight to OUT without touching the transcripts.
- **OUT:** response bytes on `rs_*`.
  - `rs_valid` is combinational and needs the target transcript engines to be ready. Each byte taken also goes into those transcripts.
  - Output holds under back-pressure.
  - For an unsigned response, `rs_last` is on the last byte, and `rsp_done` (with `rsp_err` for an ERROR, and `err_code` updated) pulses the clock after it. The core is then idle.
- **`busy`** is 1 in every state but IDLE.

### 3.2 Request decode (in order)

| Order | Condition | Error |
|---|---|---|
| 1 | fewer than 4 bytes, or more than 128 | InvalidRequest 0x01 |
| 2 | GET_VERSION (0x84) with version != 0x10 | VersionMismatch 0x41 |
| 2 | GET_VERSION with length != 4 | InvalidRequest |
| 3 | code not one of 0xE1, 0xE3, 0x81, 0x82, 0x83, 0xE0 | UnsupportedRequest 0x07 (data = request code) |
| 4 | `conn` = 0 | UnexpectedRequest 0x04 |
| 5 | version != 0x12 | VersionMismatch |
| 6 | per-request checks, below | as listed |

Per-request checks:

- **GET_CAPABILITIES (0xE1):** needs `conn` = 1, otherwise Unexpected. It must be 20 bytes, DataTransferSize >= 42 and MaxSPDMmsgSize >= DataTransferSize, otherwise Invalid. The responder then uses `dts` = min(DataTransferSize, its own maximum).
- **NEGOTIATE_ALGORITHMS (0xE3):** needs `conn` = 2. The Length field must equal the bytes received, there must be at least 32 bytes, ExtAsymCount + ExtHashCount <= 20, and Length >= 32 + 4 * (counts). The core records:
  - `hash_ok`: BaseHashAlgo bit 4, SHA3-384;
  - `asym_ok`: an ExtAsym entry equals `asym_id`;
  - `meas_ok`: MeasurementSpecification bit 0, DMTF.
- **Common to the four requests below:** each needs `conn` = 3 with `hash_ok` and `asym_ok`, otherwise Unexpected.
- **GET_DIGESTS (0x81):** must be 4 bytes. If slot 0 is provisioned, `dts` must be at least 52, otherwise ResponseTooLarge 0x0D.
- **GET_CERTIFICATE (0x82):** must be 8 bytes, with slot 0 (Param1[3:0] = 0), slot 0 provisioned, and Offset < `cc_len`, otherwise Invalid.
- **CHALLENGE (0x83):** must be 36 bytes, with Param1 = 0, slot 0 provisioned, and Param2 (summary type) 0, 1 or 0xFF, otherwise Invalid. The response size 86 + (48 if summary) + signature must be <= `dts`, otherwise TooLarge.
- **GET_MEASUREMENTS (0xE0):**
  - `meas_ok` is required, otherwise Unsupported.
  - The length must be 37 bytes with a signature (Param1 bit 0), otherwise 4.
  - The index must be 0, 0xFF, or a present index 1..NM.
  - With a signature, SlotID (byte 36) must be 0 and slot 0 provisioned.
  - Any of the last three failing gives Invalid.
  - The response size 42 + 55 * blocks (+ signature) must be <= `dts`, otherwise TooLarge.

Slot 0 is provisioned when `cc_len` != 0 and `key_ok`. An ERROR leaves the connection state and the transcripts unchanged.

### 3.3 Responses

All little-endian. The version byte is 0x12, except in VERSION and in ERRORs sent before a connection or to a GET_VERSION, which use 0x10.

| Response | Bytes |
|---|---|
| ERROR | `{ver, 0x7F, code, data}` |
| VERSION (0x04) | 0x10, 0x04, 0, 0, 0, count 1, entry 0x1200. It sets `conn` = 1 and starts all transcripts (VCA, M1, L1) afresh |
| CAPABILITIES (0x61) | 20 bytes. CTExponent = `ct_exp`. Flags = 0x00000016 (CERT_CAP, CHAL_CAP, MEAS_CAP = with signature). DataTransferSize = MaxSPDMmsgSize = DTS, the largest response (CHALLENGE_AUTH or all MEASUREMENTS with ML-DSA-87). `conn` = 2 |
| ALGORITHMS (0x63) | 36 bytes, or 40 with the ExtAsym selection. Length; MeasurementSpecificationSel = `meas_ok`; MeasurementHashAlgo = 0x20 (SHA3-384) when `meas_ok`; BaseAsymSel 0; BaseHashSel = 0x10 when `hash_ok`; ExtAsymSelCount = `asym_ok`, then `asym_id`. `conn` = 3 |
| DIGESTS (0x01) | header with Param2 = slot mask (1 when slot 0 is provisioned), then SHA3-384 of the chain. The chain hash is computed by the auxiliary engine at every GET_DIGESTS and CHALLENGE |
| CERTIFICATE (0x02) | header, PortionLength, RemainderLength, then chain bytes from Offset. The portion is limited by Length, by what remains, and by `dts` - 8 |
| CHALLENGE_AUTH (0x03) | header with Param2 = slot mask 1; chain hash (48); nonce (32, from `rn_*`); measurement summary hash (48) when Param2 != 0; OpaqueDataLength 0; signature |
| MEASUREMENTS (0x60) | header with Param1 = number of indices when the index is 0; NumberOfBlocks; record length (3 bytes); blocks; nonce (32); OpaqueDataLength 0; signature when requested |

- **Measurement summary hash:** SHA3-384 over the blocks of the indices in `m_en` (type 0xFF), or `m_en & m_tcb` (type 1).
- **Measurement block:** 55 bytes: index, 0x01, size 51 (2 bytes), type `m_type`, size 48 (2 bytes), and the 48-byte digest (measurement store words 12i..12i+11, little-endian).

### 3.4 Transcripts

- **VCA:** the GET_VERSION through ALGORITHMS messages, up to 256 bytes, kept in a buffer.
- **M1:** VCA || GET_DIGESTS, DIGESTS, GET_CERTIFICATE, CERTIFICATE, ... || CHALLENGE || CHALLENGE_AUTH up to the signature.
- **L1:** VCA || GET_MEASUREMENTS, MEASUREMENTS, ... up to the signature. Unsigned measurement exchanges keep accumulating.
- **After a signature:** the signed transcript is restarted with VCA (state RPL), and `rsp_done` follows the end of that replay.

### 3.5 Signing

1. **Random words:** a signed response first takes 8 random words for the nonce and 8 for the ML-DSA rnd, from `rn_*` (state RN). An unsigned MEASUREMENTS response takes only the 8 nonce words.
2. **Message:** after the last header byte, the transcript hash is finished. M' (150 bytes) is written to the ML-DSA buffer:
   - 0, 0 (pure ML-DSA, empty context);
   - "dmtf-spdm-v1.2.*" four times;
   - the zero-padded context "responder-challenge_auth signing" or "responder-measurements signing";
   - the 48-byte hash.
3. **Sign:** ML-DSA Sign runs.
4. **Output:** the signature (2420 / 3309 / 4627 bytes) is streamed from the ML-DSA buffer as the rest of the response, with `rs_last` on its last byte.

`rsp_done` comes within 600 clocks after the last byte.

### 3.6 Key commands

Commands are taken only in IDLE. `kg_start` or `pk_open` while busy pulses `cmd_err` and is ignored.

- **`kg_start`:**
  - Refused (`cmd_err`) for pset 3, `kg_sel` = 1 with `sl_valid` = 0, or while a request is being drained.
  - Otherwise `key_ok` = 0 and `key_pset` = `pset`. The 32-byte seed is written to the ML-DSA buffer (XI) and KeyGen runs.
  - The seed is then wiped from the buffer (8 zero words), and `key_ok` = 1 with a `kg_done` pulse.
  - The private key never leaves `ML_DSA_top`.
- **`pk_open`:**
  - Refused without a key or while draining.
  - Otherwise the public key words (328 / 488 / 648) are streamed on `pk_*`, with `pk_last` on the last.

### 3.7 clr

`clr` is remembered until it can act, which is after the ML-DSA operation in progress (KeyGen or Sign). The core then enters CLR:
- the output stops at once (no `rs_valid` the clock after `clr`) and no `rsp_done` follows;
- `key_ok` = 0, `conn` = 0;
- the VCA, nonces, chain hash, seed and negotiated flags are cleared;
- the three transcript engines are wiped;
- the ML-DSA buffer words 0x288..0xBEF (SK, SIG, seed, RND) are zeroed, 2408 clocks.

The rest of a request being received when `clr` arrives is drained: `rq_ready` stays 1 in IDLE until its `rq_last`.

### 3.8 Reset

Idle; `conn` = 0, `key_ok` = 0, `key_pset` = 0, `err_code` = 0; no stream valid; `rq_ready` = 1.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `NM` | 4 | 1..8 | measurement indices (1..NM); measurement store of 12 * NM words |
| `CC_AW` | 14 | <= 16, and CC_AW - 2 >= 4 + clog2(NM) so every measurement word is addressable | certificate chain store of 2^CC_AW bytes; width of `cc_len` and `st_addr` |

## 5. Errors and corner cases

- The decode order of §3.2 decides which ERROR a request with several faults gets.
- GET_VERSION is accepted in any connection state and restarts the connection. It is also the only request accepted with `conn` = 0.
- A request with no common hash or asymmetric algorithm is accepted at NEGOTIATE_ALGORITHMS. The later attestation requests then get UnexpectedRequest.
- An index request for an index that is not present gives InvalidRequest, and index 0 returns only the count.
- `rn_valid` must keep up: the response waits for the random words with no timeout.
- `clr` during Sign takes effect only after Sign finishes.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "still busy" | the core returns to idle after each step | §3.1 |
| "case" | each request: the full expected response, `rs_last`, one `rsp_done`, `rsp_err` / `err_code`, all random words taken, no key / connection after clr | §3.2-§3.5 |
| "KeyGen not refused" | `kg_start` with pset 3 or an invalid sideload seed: `cmd_err` | §3.6 |
| "key after clr in KeyGen" | clr during KeyGen leaves no key | §3.7 |
| "KeyGen" | KeyGen gives `kg_done`, `key_ok`, `key_pset` | §3.6 |
| "seed not wiped" | the seed area of the ML-DSA buffer is zero after KeyGen | §3.6 |
| "pk_open not refused" | `pk_open` without a key: `cmd_err` | §3.6 |
| "PK word" | the public key stream equals the vector | §3.6 |
| "busy after PK" | idle after the last public key word | §3.6 |
| "clr" | clr ends the connection and wipes the key | §3.7 |
| "commands while busy not refused" | `kg_start` / `pk_open` while busy: `cmd_err` | §3.6 |
| "VERSION length" | VERSION response length | §3.3 |
| "request taken with a command" | no request byte is taken in the clock of `kg_start` / `pk_open` | §3.1 |
| "reset" | reset values | §3.8 |
| a_rs_expected | no response byte outside an expected response | §3.1 |
| a_rs_data | every response byte before the signature equals the model | §3.3, §3.4 |
| a_rs_last | `rs_last` on the last byte | §3.1 |
| a_rs_sig_data | signature bytes come from the ML-DSA buffer | §3.5 |
| a_rs_hold | `rs_*` held while `rs_valid && !rs_ready` (unless clr) | §3.1 |
| a_rs_clr_stop | no response byte the clock after clr | §3.7 |
| a_no_rs_after_clr | nothing more of an aborted response | §3.7 |
| a_done_due | `rsp_done` only after a complete response | §3.1 |
| a_done_err | `rsp_err` = the response was an ERROR | §3.1 |
| a_done_next | `rsp_done` the clock after the last byte of an unsigned response | §3.1 |
| a_done_bound | `rsp_done` within 600 clocks of the last byte | §3.5 |
| a_reset_quiet | in reset: quiet outputs | §3.8 |
| a_host_quiet | no ML-DSA host-port activity while idle | §3.6 |
| a_err_code | `err_code` = the code of the ERROR sent | §3.2 |
| a_err_hold | `err_code` changes only with `rsp_done` | §3.1 |
| a_rq_hold_off | `rq_ready` low while a response is pending | §3.1 |
| a_rq_open | `rq_ready` high when idle with no command | §3.1 |
| a_rq_drain | the rest of an aborted request is drained | §3.7 |
| a_busy_answer | `busy` while answering, in KeyGen or streaming the public key | §3.1 |
| a_conn | `conn` as the model | §3.2 |
| a_conn_clr | after a clr: `conn` = 0 and no key | §3.7 |
| a_rn_only_when_asked | random words are taken only for a nonce / rnd | §3.5 |
| a_rn_all_taken | all 8 (or 16) random words are taken | §3.5 |
| a_sign_input | at Sign the buffer holds M' and rnd | §3.5 |
| a_keygen_input | at KeyGen the buffer holds the seed | §3.6 |
| a_key_wiped | the key area is wiped after clr | §3.7 |
| a_seed_wiped | the seed is wiped after KeyGen | §3.6 |
| a_kg_done | `kg_done` with `key_ok` and the right `key_pset` | §3.6 |
| a_key_ok | `key_ok` as the model | §3.6, §3.7 |
| a_ml_sign | Sign starts only for a signed response, after its last header byte | §3.5 |
| a_cmd_busy | command while busy: `cmd_err` | §3.6 |
| a_cmd_bad_kg | bad KeyGen command: `cmd_err` | §3.6 |
| a_cmd_bad_pk | `pk_open` without a key: `cmd_err` | §3.6 |
| a_cmd_ok | a valid command is not refused | §3.6 |
| a_cmd_cause | `cmd_err` only after a command | §3.6 |
| a_pk_count | public key stream length and `pk_last` | §3.6 |
| a_pk_data | `pk_data` = ML-DSA buffer word | §3.6 |
| a_idle_quiet | idle: no `rs_valid`, `pk_valid`, `rn_ready`, ML-DSA busy | §3.1 |
| a_reset | reset values | §3.8 |
