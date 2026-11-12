<!-- SPDX-License-Identifier: Apache-2.0 -->
# HDCP_2_3_Content_Protection: design specification

An HDCP 2.3 transmitter as an educational slice: the authentication state machine (AKE_Init,
certificate, master key, session key, pairing, locality check with a 20-clock window, session
key exchange, repeater wait) over parallel message channels, and AES-128-CTR encryption of 32-bit
pixel words with a real FIPS-197 AES-128. Simplified (not production grade): RSA, HMAC-SHA256 and
the real KDF are replaced by single AES-128-ECB blocks or XOR masks (section 3.3); the DDC / I2C
transport is replaced by valid / ready channels; the certificate is one message; nonces come from
a free-running xorshift64, not a TRNG. Core `HDCP_2_3_Content_Protection_top`, testbench
`tb/HDCP_2_3_Content_Protection_tb.sv`, checker `tb/cov/HDCP_2_3_Content_Protection_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. AES(K, P) is AES-128 encryption with FIPS-197 byte order: byte i of
a 128-bit value is bits 127-8i..120-8i.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `reg_we` | input | 1 | register write strobe | high | `clk` | - |
| `reg_addr` | input | 3 | register address (section 3.5) | - | `clk` | - |
| `reg_wdata` | input | 8 | register write data | - | `clk` | - |
| `reg_rdata` | output | 8 | register read data, combinational from `reg_addr` | - | comb | - |
| `txm_valid` | output | 1 | a message to the receiver is offered; combinational from the state | high | comb | 0 |
| `txm_ready` | input | 1 | the receiver takes the message | high | `clk` | - |
| `txm_type` | output | 4 | message type (msg_id) | - | comb | - |
| `txm_data` | output | 128 | message body | - | comb | - |
| `rxm_valid` | input | 1 | a message from the receiver | high | `clk` | - |
| `rxm_ready` | output | 1 | high in every state that waits for a receiver message; combinational | high | comb | 0 |
| `rxm_type` | input | 4 | received message type | - | `clk` | - |
| `rxm_data` | input | 128 | received message body | - | `clk` | - |
| `pix_valid` | input | 1 | clear pixel word offered | high | `clk` | - |
| `pix_ready` | output | 1 | authenticated, keystream left, output free; combinational | high | comb | 0 |
| `pix_data` | input | 32 | clear pixel word | - | `clk` | - |
| `enc_valid` | output | 1 | encrypted word valid | high | `clk` | 0 |
| `enc_ready` | input | 1 | the sink takes the encrypted word | high | `clk` | - |
| `enc_data` | output | 32 | encrypted word; held while `enc_valid` && !`enc_ready` | - | `clk` | 0 |
| `irq` | output | 1 | any error flag set; combinational | high | comb | 0 |

### Internal signals used by the verification

fsm_cov binds the authentication state (also readable at register 6); keep its name and
encoding.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 4 | 0 IDLE, 1 AKE_INIT, 2 AKE_CERT, 3 PAIR_TX, 4 PAIR_RX, 5 LC_TX, 6 LC_WAIT, 7 SKE_TX, 8 RPT_WAIT, 9 AUTH |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/HDCP_2_3_Content_Protection.md`](../ip/HDCP_2_3_Content_Protection.md) (source: `scripts/apb/specs/HDCP_2_3_Content_Protection.json`); do not edit by hand.

`HDCP_2_3_Content_Protection_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `pix_valid`, `pix_ready`, `pix_data`, `enc_valid`, `enc_ready`, `enc_data`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x48430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW (core) | core | write: bit 0 start a session (from IDLE or AUTH; ignored while authenticating), bit 2 clear the error flags (an error in the same clock wins); reads 0 |
| 0x018 | HSTATUS | RW (core) | core | [0] busy, [1] authenticated, [2] encryption active, [3] last session failed, [4] the peer is a repeater, [5] keystream exhausted (read only) |
| 0x01C | VER | RW (core) | core | 0x23 (read only) |
| 0x020 | ERR | RW (core) | core | error flags: [0] locality timeout, [1] pairing ack mismatch, [2] locality mismatch, [3] unexpected message type, [4] message timeout, [5] keystream exhausted (read only; cleared by CTRL bit 2 or a new session) |
| 0x024 | KMIDX | RW (core) | core | [3:0] byte index for KMDAT and KSDAT |
| 0x028 | KMDAT | RW (core) | core | master key km byte KMIDX (km[8*KMIDX +: 8]) |
| 0x02C | STATE | RW (core) | core | [3:0] authentication state: 0 IDLE, 1 AKE_INIT, 2 AKE_CERT, 3 PAIR_TX, 4 PAIR_RX, 5 LC_TX, 6 LC_WAIT, 7 SKE_TX, 8 RPT_WAIT, 9 AUTH (read only) |
| 0x030 | KSDAT | RW (core) | core | session key ks byte KMIDX (read only) |
| 0x034 | TXM0 | RO (pop) | 0x00000000 | Message to the receiver; reading the type word frees it and lets the core go on |
| 0x038 | TXM1 | RO (pop) | 0x00000000 | Message to the receiver; reading the type word frees it and lets the core go on |
| 0x03C | TXM2 | RO (pop) | 0x00000000 | Message to the receiver; reading the type word frees it and lets the core go on |
| 0x040 | TXM3 | RO (pop) | 0x00000000 | Message to the receiver; reading the type word frees it and lets the core go on |
| 0x044 | TXM4 | RO (pop) | 0x00000000 | Message to the receiver; reading the type word frees it and lets the core go on |
| 0x048 | RXM0 | RW | 0x00000000 | Message from the receiver; writing the type word sends it, and it is taken when the core waits for a message |
| 0x04C | RXM1 | RW | 0x00000000 | Message from the receiver; writing the type word sends it, and it is taken when the core waits for a message |
| 0x050 | RXM2 | RW | 0x00000000 | Message from the receiver; writing the type word sends it, and it is taken when the core waits for a message |
| 0x054 | RXM3 | RW | 0x00000000 | Message from the receiver; writing the type word sends it, and it is taken when the core waits for a message |
| 0x058 | RXM4 | RW | 0x00000000 | Message from the receiver; writing the type word sends it, and it is taken when the core waits for a message |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x05C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4843 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 7:0 | core register | RW (core) | core | written at core register 0 and read from core register 0 |
| HSTATUS | 7:0 | core register | RW (core) | core | written at core register 1 and read from core register 1 |
| VER | 7:0 | core register | RW (core) | core | written at core register 2 and read from core register 2 |
| ERR | 7:0 | core register | RW (core) | core | written at core register 3 and read from core register 3 |
| KMIDX | 7:0 | core register | RW (core) | core | written at core register 4 and read from core register 4 |
| KMDAT | 7:0 | core register | RW (core) | core | written at core register 5 and read from core register 5 |
| STATE | 7:0 | core register | RW (core) | core | written at core register 6 and read from core register 6 |
| KSDAT | 7:0 | core register | RW (core) | core | written at core register 7 and read from core register 7 |
| TXM0 | 31:0 | `txm_data[31:0]` | RO (pop) | 0x0 | message body |
| TXM1 | 31:0 | `txm_data[63:32]` | RO (pop) | 0x0 | message body |
| TXM2 | 31:0 | `txm_data[95:64]` | RO (pop) | 0x0 | message body |
| TXM3 | 31:0 | `txm_data[127:96]` | RO (pop) | 0x0 | message body |
| TXM4 | 3:0 | `txm_type` | RO (pop) | 0x0 | message type: 2 AKE_Init, 4 AKE_No_Stored_km (E_km), 9 LC_Init, 11 SKE_Send_Eks |
| RXM0 | 31:0 | `rxm_data[31:0]` | RW | 0x0 | message body |
| RXM1 | 31:0 | `rxm_data[63:32]` | RW | 0x0 | message body |
| RXM2 | 31:0 | `rxm_data[95:64]` | RW | 0x0 | message body |
| RXM3 | 31:0 | `rxm_data[127:96]` | RW | 0x0 | message body |
| RXM4 | 3:0 | `rxm_type` | RW | 0x0 | message type: 3 AKE_Send_Cert, 7 pairing ack, 10 LC_Send_L_prime, 12 repeater ack |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERROR | an ERR flag is set; level in the core, so the bit is set again on every clock until CTRL bit 2 clears the flags |
| 1 | TXM_AVAIL | TXM captured a beat |
| 2 | RXM_DONE | RXM beat accepted by the core |
| 3 | RXM_OVF | write to RXM while full (dropped) |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TXM_AVAIL | TXM holds an unread beat |
| 1 | RXM_FULL | RXM holds a beat the core has not taken |

### Core register port

The REGS words reach the core's own register port. A write to one pulses `reg_we` for one clock with `reg_addr` (the core register) and `reg_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `reg_addr` (the core register) during the access phase and returns `reg_rdata`.

### Streams

* **TXM** takes `txm_data`, `txm_type` from the core with `txm_valid` / `txm_ready`: `txm_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ TXM_AVAIL. Reading TXM4 pops it. Nothing is dropped: the core holds its data until the register is free.
* **RXM** feeds `rxm_data`, `rxm_type`/`rxm_valid`. Writing RXM4 commits the beat: FLAGS.RXM_FULL is set and `rxm_valid` stays high until the core's `rxm_ready`; then RXM_DONE is set. A write while full is dropped and sets RXM_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x48430200.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
4. Access the core's registers through the REGS words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. To receive on TXM: wait for IRQ TXM_AVAIL or FLAGS.TXM_AVAIL (bit 0), then read TXM0 (0x034) then TXM1 (0x038) then TXM2 (0x03C) then TXM3 (0x040) then TXM4 (0x044). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.TXM_AVAIL (bit 1) to clear it.
6. To send on RXM: wait until FLAGS.RXM_FULL (bit 1) is 0, or for IRQ RXM_DONE, then write RXM0 (0x048) then RXM1 (0x04C) then RXM2 (0x050) then RXM3 (0x054) then RXM4 (0x058). The last write commits the beat. RXM_OVF means a write came while the register was full and was dropped.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Nonce source

A 64-bit xorshift register starts at 0x9E3779B97F4A7C15 and steps every clock (x ^= x >> 12;
x ^= x << 25; x ^= x >> 27). rtx and the locality challenge L are taken as one step past its
current value at the moment they are needed.

### 3.2 Authentication sequence

| State | Action | Next |
|---|---|---|
| IDLE | wait for CTRL.start | AKE_INIT; rtx taken |
| AKE_INIT | offer type 2 (AKE_Init), data {64'h0, rtx} | AKE_CERT when `txm_ready` |
| AKE_CERT | wait type 3 (AKE_Send_Cert): REPEATER = data[0], hrx = data[95:64]; ks = AES(km, {rtx, rtx}) | PAIR_TX |
| PAIR_TX | offer type 4, data E_km | PAIR_RX when `txm_ready` |
| PAIR_RX | wait type 7 (H'): data[31:0] must equal AES(km, hrx pad)[31:0] | LC_TX, L taken; else pairing error |
| LC_TX | offer type 9 (LC_Init), data {64'h0, L} | LC_WAIT when `txm_ready` |
| LC_WAIT | wait type 10 (L'): data[63:0] must equal L ^ ks[63:0] | SKE_TX; else locality mismatch |
| SKE_TX | offer type 11 (SKE_Send_Eks), data ks ^ km | RPT_WAIT if REPEATER, else AUTH, when `txm_ready`; CTR = 0 |
| RPT_WAIT | wait type 12 (any data) | AUTH |
| AUTH | encrypt pixels | new session on CTRL.start |

`txm_valid` / `txm_type` / `txm_data` and `rxm_ready` are combinational from the state, so a
message is offered (or accepted) for as long as the state lasts; a message is consumed in the
clock it is seen. In a wait state a message of another type is an unexpected-message error.
Waiting for types 3, 7 and 12 times out after MSG_TIMEOUT + 1 clocks without a message; waiting
for type 10 after 21 clocks (the locality window). Any error returns to IDLE.

### 3.3 Derived values

- ks = AES(km, {rtx, rtx})
- hrx pad = {hrx, hrx, hrx, hrx}
- E_km = AES(hrx pad, km)
- H' = AES(km, hrx pad)[31:0]
- L' = L ^ ks[63:0]
- Eks = ks ^ km

### 3.4 Pixel encryption (AUTH)

`pix_ready` = AUTH and not exhausted and (`enc_valid` low or `enc_ready`). A word taken gives, in
the next clock, `enc_valid` with `enc_data` = `pix_data` ^ AES(ks, {rtx, 48'h0, CTR})[127:96]; CTR
(16 bits, 0 at session start) then increments. `enc_valid` drops after `enc_ready` without a new
word. The word taken at CTR = 0xFFFF sets the exhausted flag and ERR bit 5: no more words are
taken until a new session. Leaving AUTH (new session) drops a word still waiting for `enc_ready`.

### 3.5 Registers

| Addr | Name | Access | Content |
|---|---|---|---|
| 0 | CTRL | WO (reads 0) | bit 0 start (only in IDLE or AUTH: clears ERR, fail and exhausted, takes rtx, goes to AKE_INIT); bit 2 clear (ERR and fail) |
| 1 | STATUS | RO | {2'b0, exhausted, REPEATER, fail, AUTH, AUTH, not IDLE} |
| 2 | VERSION | RO | 0x23 |
| 3 | ERR | RO | {2'b0, err[5:0]}: 0 locality timeout, 1 pairing failure, 2 locality mismatch, 3 unexpected message, 4 message timeout, 5 keystream exhausted |
| 4 | KMIDX | RW | byte index 0..15 (bits 3:0) |
| 5 | KMDAT | RW | km byte KMIDX = km[8 KMIDX + 7 : 8 KMIDX] (writable in any state) |
| 6 | STATE | RO | {4'h0, state} |
| 7 | KSDAT | RO | ks byte KMIDX, same bit numbering |

`fail` is set with every authentication error (bits 0..4). An error raised in the same clock as a
clear stays set.

### 3.6 Reset

IDLE, km = ks = 0, KMIDX = 0, ERR = 0, fail = exhausted = 0, `enc_valid` = 0, `enc_data` = 0,
nonce register at its seed.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `MSG_TIMEOUT` | 255 | 0..255 | wait limit for AKE_Send_Cert, H' and the repeater message, in clocks (+1) |

## 5. Errors and corner cases

`irq` = ERR != 0 (level), cleared by CTRL bit 2 or a new session. The exhausted flag itself is
cleared only by a new session, so after CTRL bit 2 `pix_ready` stays low with `irq` low.

- CTRL.start during authentication is ignored.
- km may be changed at any time; it is used when ks, E_km, H' and Eks are formed.
- rxm_data bits not listed in section 3.2 are ignored.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "TX message held" | a transmitted message stays until `txm_ready` | §3.2 |
| "receiver channel ready" | `rxm_ready` exactly in the wait states | §3.2 |
| "AKE_Init upper half" | AKE_Init data[127:64] = 0 | §3.2 |
| "E_km" | E_km = AES(hrx pad, km) | §3.3 |
| "LC_Init upper half" | LC_Init data[127:64] = 0 | §3.2 |
| "SKE Eks" | Eks = ks ^ km | §3.3 |
| "STATUS authenticated" | STATUS bits in AUTH | §3.5 |
| "pixel decrypts" | encrypted words decrypt with the AES-CTR keystream | §3.4 |
| "TB AES FIPS-197 vector" | (TB self-check of its AES reference) | §3.3 |
| "reset outputs" | reset values | §3.6 |
| "version" | VERSION = 0x23 | §3.5 |
| "CTRL reads 0" | CTRL reads 0 | §3.5 |
| "STATUS idle" | STATUS = 0 in IDLE without errors | §3.5 |
| "km byte" | KMDAT writes / reads km byte KMIDX | §3.5 |
| "KMIDX" | KMIDX holds 4 bits | §3.5 |
| "version is read-only" | writes to VERSION are ignored | §3.5 |
| "ERR is read-only" | writes to ERR are ignored | §3.5 |
| "ks byte" | KSDAT reads ks byte KMIDX | §3.5 |
| "reset mid-auth" | reset returns to IDLE with all flags clear | §3.6 |
| "error set wins over clear" | an error in the clearing clock stays set | §3.5 |
| "keystream exhausted" | after 65536 words `pix_ready` stays low | §3.4 |
| "ERR exhausted" | ERR bit 5 | §3.4 |
| "STATUS exhausted" | STATUS bit 5 | §3.5 |
| "no more pixels" | no word taken once exhausted | §3.4 |
| "new session clears the error" | CTRL.start clears ERR, fail and exhausted | §3.5 |
| a_reset_outputs | reset values | §3.6 |
| a_txm_valid | `txm_valid` equals the checker's model | §3.2 |
| a_txm_message | `txm_type` / `txm_data` as the model | §3.2, §3.3 |
| a_rxm_ready | `rxm_ready` as the model | §3.2 |
| a_pix_ready | `pix_ready` as the model | §3.4 |
| a_enc_valid | `enc_valid` as the model | §3.4 |
| a_enc_data | `enc_data` as the model | §3.4 |
| a_irq | `irq` as the model | §5 |
| a_reg_rdata | `reg_rdata` as the model | §3.5 |
| a_enc_held_under_backpressure | `enc_data` stable while `enc_valid` && !`enc_ready` | §3.4 |
