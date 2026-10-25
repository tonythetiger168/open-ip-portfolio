# HDCP 2.3 transmitter (educational slice): AKE, pairing, locality check and session key exchange with a receiver over message channels, then AES-128-CTR encryption of the pixel stream

Protocol IP `HDCP_2_3_Content_Protection`, version 2.0. Apache-2.0.

## Overview

HDCP 2.3 Content Protection Open IP -- HDCP 2.3 transmitter (educational slice) Full authentication FSM: AKE_Init -> rtx/rxcaps exchange -> master key km -> session key derivation -> pairing -> locality check (20 clk challenge) -> session key exchange -> repeater-ready (if peer REPEATER bit) -> authenticated streaming cipher on the pixel interface. Crypto is now REAL AES-128 (FIPS-197): the encrypt datapath below (SubBytes/ShiftRows/MixColumns/AddRoundKey + key expansion) is copied from the FIPS-197-vector-verified CSE_top.sv core. It is packaged here as a single-clock combinational function (aes128_enc) -- an educational-slice choice; a production core would iterate 1 round/clk like CSE. Real-AES usage in this slice:

- Session key derivation: ks = AES-128-ECB(key=km, pt={rtx,rtx}).  The
real HDCP KDF is AES-128 based; this slice uses a single ECB block.
- Pairing "encrypted master key": E_km = AES-128-ECB(key=hrx_pad, pt=km),
replacing the old XOR placeholder (real HDCP uses RSA-OAEP).
- Pairing ack H' = AES-128-ECB(key=km, pt=hrx_pad)[31:0].
- Content encryption: AES-128-CTR. Per 32-bit pixel word the keystream is
AES-128(key=ks, counter={rtx, 48'h0, ctr})[127:96], XORed with the
pixel word; rtx is fresh per session, the 16-bit ctr advances per pixel
word. After 65536 words the keystream is exhausted: pix_ready stays low
and irq is raised until a new session is started.
Protocol errors (all raise irq, set ERR flags; the first five also fail
the session and return to IDLE): locality timeout (20 clk), pairing ack
mismatch, locality value mismatch, a message of an unexpected type in a
wait state, no message within MSG_TIMEOUT clocks while waiting for
AKE_Send_Cert / the pairing ack / the repeater ack, keystream exhausted.
A new session (CTRL.start, from IDLE or AUTH) discards a pixel word still
waiting on enc_ready.
Documented residual simplifications (still NOT production-grade):
- Locality check response is L XOR ks[63:0]; the real protocol uses
HMAC-SHA256 over (L, receiver id) with the session key. The 20-clock
response window models the real locality timer.
- SKE carries Eks = ks XOR km (a mask), not the real AES-wrapped Eks.
- The DDC/I2C transport of real HDCP is replaced by parallel
valid/ready message channels (txm_*/rx_*).
- Certificate exchange is collapsed to a single AKE_Send_Cert message
carrying rxcaps (REPEATER bit) and a 32-bit rx pubkey-hash placeholder
(replicated to a 128-bit AES key for the pairing wrap).
- rtx / locality nonces come from a free-running xorshift64, not a TRNG.

pix_valid / pix_ready / pix_data (plain pixel words in) and enc_valid / enc_ready / enc_data (encrypted words out) pass through unchanged; words flow only while authenticated.
The core's 8-bit register window sits at REGS: each word is one core register, and only bits [7:0] are used. KMDAT is written byte by byte with KMIDX before CTRL.start.
The locality check allows 20 clocks from LC_Init to the answer: read TXM words 0, 1 and the type word, then write RXM words 0, 1 and the type word back to back (RXM words 2 and 3 can be written in advance).

## Files

| File | Content |
|---|---|
| `rtl/HDCP_2_3_Content_Protection_top.sv` | protocol core |
| `rtl/HDCP_2_3_Content_Protection_apb.sv` | APB4 register wrapper (generated) |
| `tb/HDCP_2_3_Content_Protection_tb.sv` | core testbench |
| `tb/HDCP_2_3_Content_Protection_apb_tb.sv`, `tb/apb/HDCP_2_3_Content_Protection_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/HDCP_2_3_Content_Protection_sva.sv`, `tb/cov/HDCP_2_3_Content_Protection_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/HDCP_2_3_Content_Protection.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.HDCP_2_3_Content_Protection sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.HDCP_2_3_Content_Protection apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh HDCP_2_3_Content_Protection          # core coverage (Verilator)
bash scripts/cov/run_cov.sh HDCP_2_3_Content_Protection_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `reg_we` | input | 1 | write to a REGS word |
| `reg_addr` | input | 3 | REGS word index |
| `reg_wdata` | input | 8 | REGS write data |
| `reg_rdata` | output | 8 | REGS read data |
| `txm_valid` | output | 1 | TXM capture |
| `txm_ready` | input | 1 | TXM handshake |
| `txm_type` | output | 4 | TXM4[3:0] |
| `txm_data` | output | 128 | TXM0[31:0], TXM1[31:0], TXM2[31:0], TXM3[31:0] |
| `rxm_valid` | input | 1 | RXM commit / FLAGS |
| `rxm_ready` | output | 1 | RXM handshake |
| `rxm_type` | input | 4 | RXM4[3:0] |
| `rxm_data` | input | 128 | RXM0[31:0], RXM1[31:0], RXM2[31:0], RXM3[31:0] |
| `pix_valid` | input | 1 | pin (pass-through) |
| `pix_ready` | output | 1 | pin (pass-through) |
| `pix_data` | input | 32 | pin (pass-through) |
| `enc_valid` | output | 1 | pin (pass-through) |
| `enc_ready` | input | 1 | pin (pass-through) |
| `enc_data` | output | 32 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERROR |

## APB wrapper

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
| 0x014 | CTRL | RW (core) | 0x00000000 | write: bit 0 start a session (from IDLE or AUTH; ignored while authenticating), bit 2 clear the error flags (an error in the same clock wins); reads 0 |
| 0x018 | HSTATUS | RW (core) | 0x00000000 | [0] busy, [1] authenticated, [2] encryption active, [3] last session failed, [4] the peer is a repeater, [5] keystream exhausted (read only) |
| 0x01C | VER | RW (core) | 0x00000000 | 0x23 (read only) |
| 0x020 | ERR | RW (core) | 0x00000000 | error flags: [0] locality timeout, [1] pairing ack mismatch, [2] locality mismatch, [3] unexpected message type, [4] message timeout, [5] keystream exhausted (read only; cleared by CTRL bit 2 or a new session) |
| 0x024 | KMIDX | RW (core) | 0x00000000 | [3:0] byte index for KMDAT and KSDAT |
| 0x028 | KMDAT | RW (core) | 0x00000000 | master key km byte KMIDX (km[8*KMIDX +: 8]) |
| 0x02C | STATE | RW (core) | 0x00000000 | [3:0] authentication state: 0 IDLE, 1 AKE_INIT, 2 AKE_CERT, 3 PAIR_TX, 4 PAIR_RX, 5 LC_TX, 6 LC_WAIT, 7 SKE_TX, 8 RPT_WAIT, 9 AUTH (read only) |
| 0x030 | KSDAT | RW (core) | 0x00000000 | session key ks byte KMIDX (read only) |
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

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4843 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CTRL | 7:0 | core register | written at core register 0 and read from core register 0 |
| HSTATUS | 7:0 | core register | written at core register 1 and read from core register 1 |
| VER | 7:0 | core register | written at core register 2 and read from core register 2 |
| ERR | 7:0 | core register | written at core register 3 and read from core register 3 |
| KMIDX | 7:0 | core register | written at core register 4 and read from core register 4 |
| KMDAT | 7:0 | core register | written at core register 5 and read from core register 5 |
| STATE | 7:0 | core register | written at core register 6 and read from core register 6 |
| KSDAT | 7:0 | core register | written at core register 7 and read from core register 7 |
| TXM0 | 31:0 | `txm_data[31:0]` | message body |
| TXM1 | 31:0 | `txm_data[63:32]` | message body |
| TXM2 | 31:0 | `txm_data[95:64]` | message body |
| TXM3 | 31:0 | `txm_data[127:96]` | message body |
| TXM4 | 3:0 | `txm_type` | message type: 2 AKE_Init, 4 AKE_No_Stored_km (E_km), 9 LC_Init, 11 SKE_Send_Eks |
| RXM0 | 31:0 | `rxm_data[31:0]` | message body |
| RXM1 | 31:0 | `rxm_data[63:32]` | message body |
| RXM2 | 31:0 | `rxm_data[95:64]` | message body |
| RXM3 | 31:0 | `rxm_data[127:96]` | message body |
| RXM4 | 3:0 | `rxm_type` | message type: 3 AKE_Send_Cert, 7 pairing ack, 10 LC_Send_L_prime, 12 repeater ack |

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

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/HDCP_2_3_Content_Protection_top.sv` | pass | 178/178 (+1 excl.) | 3430/3430 | 25/25 | 10/10 | 16/16 |
| wrapper `rtl/HDCP_2_3_Content_Protection_apb.sv` | pass | 54/54 | 1688/1688 | n/a | 17/17 | 80/80 |
