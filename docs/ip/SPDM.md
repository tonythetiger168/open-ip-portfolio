# SPDM 1.2 responder (DMTF DSP0274): device attestation in hardware with VERSION / CAPABILITIES / ALGORITHMS, DIGESTS, CERTIFICATE, CHALLENGE_AUTH and MEASUREMENTS, SHA3-384 transcripts on three SHA-3 engines and ML-DSA-44 / 65 / 87 signatures on an ML-DSA engine

Protocol IP `SPDM`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SPDM_top` (`rtl/SPDM_top.sv`) |
| Register interface | APB4 slave `SPDM_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53640100 (code 0x5364, version 1.0) |
| Registers | 25 words, 0x000 to 0x060 |
| Interrupts | 7 sources into one level-high `irq` |
| Data streams | STORE (to the core), PK (from the core), RN (to the core) |
| Protocol pins | 10 pass-through |

## Overview

SPDM_top v1.0: hardware SPDM 1.2 responder (DMTF DSP0274 Security Protocol and Data Model): device attestation with a post-quantum ML-DSA identity key, built on three SHA3_top engines (SHA3-384 transcripts) and one ML_DSA_top engine (KeyGen and Sign). Message formats follow the public DSP0274 1.2 text; the asymmetric algorithm is selected through an ExtAsym entry whose 32-bit value is a configuration input (asym_id), since SPDM 1.2 has no ML-DSA code point. Not claimed to be interoperable with a given requester stack.

- Transport: one request at a time on a byte stream (rq_*, rq_last on
the last byte; from a DOE mailbox or an MCTP / SPDM-over-x binding),
the response on a byte stream (rs_*, rs_last). rq_ready is low while a
request is answered. Requests of more than RQ_MAX = 128 bytes are
drained and answered with ERROR InvalidRequest.
- Requests: GET_VERSION (VERSION 1.2), GET_CAPABILITIES (CERT_CAP,
CHAL_CAP, MEAS_CAP with signature), NEGOTIATE_ALGORITHMS (BaseHash
SHA3-384, ExtAsym asym_id, DMTF measurements with SHA3-384), and after
them GET_DIGESTS, GET_CERTIFICATE, CHALLENGE and GET_MEASUREMENTS. Any
other code gets ERROR UnsupportedRequest. Errors: InvalidRequest (0x01,
bad length or field), UnexpectedRequest (0x04, out of order, or no
common hash / asymmetric algorithm), UnsupportedRequest (0x07, data =
request code), ResponseTooLarge (0x0D, more than the requester's
DataTransferSize), VersionMismatch (0x41). An ERROR leaves the
connection state and the transcripts unchanged.
- Slot 0 only: the certificate chain (the DSP0274 format: length,
reserved, root hash, DER certificates) is written by the host into the
chain store (st_sel = 0) and has cc_len bytes; slot 0 is provisioned
when cc_len != 0 and a key pair is present. DIGESTS returns SHA3-384 of
the chain, computed by the third SHA3 engine at every GET_DIGESTS and
CHALLENGE.
- Measurements: NM indices (1..NM); index i + 1 is present when m_en[i];
its value is a 48-byte digest written by the host into the measurement
store (st_sel = 1, words 12 i .. 12 i + 11) with the DMTF value type
m_type[8i +: 8]; m_tcb[i] puts it into the TCB measurement summary hash.
A measurement block is 55 bytes: index, 0x01, size 51, type, size 48,
digest.
- Transcripts (DSP0274 1.2, SHA3-384): M1 = VCA || GET_DIGESTS, DIGESTS,
GET_CERTIFICATE, CERTIFICATE ... || CHALLENGE || CHALLENGE_AUTH up to
the signature; L1 = VCA || GET_MEASUREMENTS, MEASUREMENTS ... up to the
signature. VCA (GET_VERSION .. ALGORITHMS, at most 256 bytes) is kept
so that each transcript restarts with it after it has been signed.
- Signature: ML-DSA (FIPS 204, pure, empty context) of the combined SPDM
prefix ("dmtf-spdm-v1.2.*" four times, zero padding, the context string
"responder-challenge_auth signing" or "responder-measurements signing")
followed by the transcript hash; the signing randomness rnd and the
responder nonces come from the random word stream (rn_*, e.g. a TRNG).
- Key: kg_start runs ML-DSA KeyGen (parameter set pset) from a 32-byte
seed (kg_sel = 0 the seed input, 1 the sideload port, e.g. a DICE CDI
from Root_of_Trust); the seed is wiped from the engine afterwards. The
private key never leaves ML_DSA_top; pk_open streams the public key out
(pk_*) for a certificate request. clr aborts what is running (after the
ML-DSA operation in progress), wipes the private key, the seed and the
nonces, ends the connection, and drops the rest of a request being
received.
Not implemented: sessions (KEY_EXCHANGE, PSK, secured messages, so IDE
key programming over a session needs firmware), mutual authentication,
slots 1-7, chunking (CHUNK_SEND / CHUNK_GET), SPDM 1.0 / 1.1 / 1.3,
RESPOND_IF_READY, opaque data, raw bit-stream measurements.

Features:

- SPDM 1.2 responder in hardware: GET_VERSION, GET_CAPABILITIES, NEGOTIATE_ALGORITHMS, GET_DIGESTS, GET_CERTIFICATE, CHALLENGE and GET_MEASUREMENTS are parsed, checked and answered without firmware; every other request code gets ERROR UnsupportedRequest. Error responses: InvalidRequest, UnexpectedRequest, UnsupportedRequest, ResponseTooLarge, VersionMismatch.
- Post-quantum identity: ML-DSA-44, -65 or -87 (FIPS 204) signs CHALLENGE_AUTH and MEASUREMENTS; the key pair is generated inside from a 32-byte seed (a register or a sideload port, e.g. a DICE CDI from Root_of_Trust) and the private key never leaves the ML-DSA engine. The public key can be read for a certificate request.
- Transcripts M1 and L1 hashed on the fly with SHA3-384 by two SHA3 engines; a third hashes the certificate chain for DIGESTS / CHALLENGE_AUTH and the measurement summary (TCB or all). The signed message is the DSP0274 1.2 combined SPDM prefix and context string followed by the transcript hash.
- Byte-stream request / response port for a DOE mailbox or an MCTP binding; responses up to 4889 bytes are streamed as they are formed (the signature last), the requester's DataTransferSize is honoured (CERTIFICATE portions are clipped to it, larger responses get ResponseTooLarge).
- Slot 0 certificate chain store of 16 KiB and four measurement indices (48-byte digests with DMTF value types) written through STORE.

Message layouts follow the public DSP0274 1.2 text. SPDM 1.2 has no ML-DSA code point, so the key is negotiated through one ExtAsym entry (ASYM); the core is not claimed to be interoperable with a given requester stack.
The core needs no response buffer: header fields are formed from the request, digests come from the SHA3 engines, certificate and measurement bytes from the stores, the signature from the ML-DSA buffer.
Signing time: about 63k / 91k / 128k clocks per attempt of the ML-DSA rejection loop (4.25 / 5.1 / 3.85 attempts on average) for ML-DSA-44 / 65 / 87; set CFG.ct_exp so that the requester waits long enough (RESPOND_IF_READY is not implemented).
The stores and the CFG / MEAS registers are read while a request is answered: change them only while STATUS.busy = 0 and no request is in flight.
Not implemented: secured sessions (KEY_EXCHANGE, PSK_EXCHANGE, FINISH, secured messages; so IDE key programming by IDE_KM still needs a session from firmware), mutual authentication, slots 1-7, CHUNK_SEND / CHUNK_GET, SPDM 1.0 / 1.1 / 1.3, opaque data, raw bit-stream measurements, masking against power analysis.

## Files

| File | Content |
|---|---|
| `rtl/SPDM_top.sv` | protocol core |
| `rtl/SPDM_apb.sv` | APB4 register wrapper (generated) |
| `tb/SPDM_tb.sv` | core testbench |
| `tb/SPDM_apb_tb.sv`, `tb/apb/SPDM_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SPDM_sva.sv`, `tb/cov/SPDM_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SPDM.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`SPDM_apb` has the core's parameters and passes them to `SPDM_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NM` | int | `4` |
| `CC_AW` | int | `14` |

## Wrapper pins

Pins of `SPDM_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sl_seed` | input | 256 | protocol pin, core port `sl_seed` |
| `sl_valid` | input | 1 | protocol pin, core port `sl_valid` |
| `rq_valid` | input | 1 | protocol pin, core port `rq_valid` |
| `rq_data` | input | 8 | protocol pin, core port `rq_data` |
| `rq_last` | input | 1 | protocol pin, core port `rq_last` |
| `rq_ready` | output | 1 | protocol pin, core port `rq_ready` |
| `rs_valid` | output | 1 | protocol pin, core port `rs_valid` |
| `rs_data` | output | 8 | protocol pin, core port `rs_data` |
| `rs_last` | output | 1 | protocol pin, core port `rs_last` |
| `rs_ready` | input | 1 | protocol pin, core port `rs_ready` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `ct_exp` | input | 8 | CFG[7:0] |
| `asym_id` | input | 32 | ASYM[31:0] |
| `pset` | input | 2 | CFG[9:8] |
| `cc_len` | input | 15 | CCLEN[14:0] |
| `m_en` | input | 4 | MEAS[3:0] |
| `m_tcb` | input | 4 | MEAS[7:4] |
| `m_type` | input | 32 | MTYPE[31:0] |
| `st_we` | input | 1 | STORE commit / FLAGS |
| `st_sel` | input | 1 | STORE1[12:12] |
| `st_addr` | input | 12 | STORE1[11:0] |
| `st_data` | input | 32 | STORE0[31:0] |
| `kg_start` | input | 1 | CMD[0:0] |
| `kg_sel` | input | 1 | CFG[10:10] |
| `seed` | input | 256 | SEED0[31:0], SEED1[31:0], SEED2[31:0], SEED3[31:0], SEED4[31:0], SEED5[31:0], SEED6[31:0], SEED7[31:0] |
| `sl_seed` | input | 256 | pin (pass-through) |
| `sl_valid` | input | 1 | pin (pass-through) |
| `pk_open` | input | 1 | CMD[1:1] |
| `clr` | input | 1 | CMD[2:2] |
| `pk_valid` | output | 1 | PK capture |
| `pk_data` | output | 32 | PK0[31:0] |
| `pk_last` | output | 1 | PK1 |
| `pk_ready` | input | 1 | PK handshake |
| `rn_valid` | input | 1 | RN commit / FLAGS |
| `rn_data` | input | 32 | RN[31:0] |
| `rn_ready` | output | 1 | RN handshake |
| `rq_valid` | input | 1 | pin (pass-through) |
| `rq_data` | input | 8 | pin (pass-through) |
| `rq_last` | input | 1 | pin (pass-through) |
| `rq_ready` | output | 1 | pin (pass-through) |
| `rs_valid` | output | 1 | pin (pass-through) |
| `rs_data` | output | 8 | pin (pass-through) |
| `rs_last` | output | 1 | pin (pass-through) |
| `rs_ready` | input | 1 | pin (pass-through) |
| `busy` | output | 1 | STATUS[0:0] |
| `conn` | output | 2 | STATUS[2:1] |
| `key_ok` | output | 1 | STATUS[3:3] |
| `key_pset` | output | 2 | STATUS[5:4] |
| `rsp_done` | output | 1 | IRQ_STATUS.RSP_DONE |
| `rsp_err` | output | 1 | IRQ_STATUS.RSP_ERR |
| `err_code` | output | 8 | STATUS[13:6] |
| `kg_done` | output | 1 | IRQ_STATUS.KG_DONE |
| `cmd_err` | output | 1 | IRQ_STATUS.CMD_ERR |

## APB wrapper

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

## Programming sequence

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

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SPDM sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SPDM syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SPDM_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SPDM apb` | `TEST PASSED: SPDM_apb`, then Yosys without `ERROR` | console, `work/SPDM_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SPDM`<br>`bash scripts/cov/run_cov.sh SPDM_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SPDM/score.json`, `work/cov/SPDM_apb/score.json` |

Expected end of a step 4 run:

```
===== SPDM =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SPDM_tb.sv`): drives `SPDM_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SPDM_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SPDM_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SPDM_sva.sv`, `tb/cov/SPDM_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SPDM_top.sv` | pass | 368/368 | 5674/5674 (+24 excl.) | 43/43 | 37/37 | 77/77 |
| wrapper `rtl/SPDM_apb.sv` | not run | | | | | |

Core: tb/SPDM_tb.sv runs 122 requests from scripts/spdm/gen_vec.py, an SPDM 1.2 responder model (scripts/spdm/spdm_ref.py) with the FIPS 204 model scripts/mldsa/mldsa_ref.py; every response is compared byte for byte, signatures of all three parameter sets included (and the generator checks each signature with ML-DSA Verify against the transcript). The requests cover every request code with every error it can get, both DataTransferSize limits, the measurement summary types, interleaved M1 / L1 transcripts, VCA restarts, the key commands and clr while a request is received, signed, sent and while KeyGen runs.
The core checker has its own SHA3-384 and keeps the transcripts as byte queues: it decides each request, forms every response byte but the signature (digests included), and checks the seed, M' and rnd in the ML-DSA buffer when KeyGen / Sign start, the wipes, the handshakes and the status outputs.
