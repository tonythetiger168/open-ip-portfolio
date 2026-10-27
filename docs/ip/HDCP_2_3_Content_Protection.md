# HDCP 2.3 transmitter (educational slice): AKE, pairing, locality check and session key exchange with a receiver over message channels, then AES-128-CTR encryption of the pixel stream

Protocol IP `HDCP_2_3_Content_Protection`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `HDCP_2_3_Content_Protection_top` (`rtl/HDCP_2_3_Content_Protection_top.sv`) |
| Register interface | APB4 slave `HDCP_2_3_Content_Protection_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x48430200 (code 0x4843, version 2.0) |
| Registers | 23 words, 0x000 to 0x058 |
| Interrupts | 4 sources into one level-high `irq` |
| Data streams | TXM (from the core), RXM (to the core) |
| Core register port | REGS (8 words) |
| Protocol pins | 6 pass-through |

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

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`HDCP_2_3_Content_Protection_apb` has the core's parameters and passes them to `HDCP_2_3_Content_Protection_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `MSG_TIMEOUT` | int | `255` |

## Wrapper pins

Pins of `HDCP_2_3_Content_Protection_apb`. Widths of the pass-through pins are at the default parameters.

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
| `PSLVERR` | output | 1 | error: unmapped or misaligned address, or partial write to a core register word |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `pix_valid` | input | 1 | protocol pin, core port `pix_valid` |
| `pix_ready` | output | 1 | protocol pin, core port `pix_ready` |
| `pix_data` | input | 32 | protocol pin, core port `pix_data` |
| `enc_valid` | output | 1 | protocol pin, core port `enc_valid` |
| `enc_ready` | input | 1 | protocol pin, core port `enc_ready` |
| `enc_data` | output | 32 | protocol pin, core port `enc_data` |

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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x48430200.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
4. Access the core's registers through the REGS words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. To receive on TXM: wait for IRQ TXM_AVAIL or FLAGS.TXM_AVAIL (bit 0), then read TXM0 (0x034) then TXM1 (0x038) then TXM2 (0x03C) then TXM3 (0x040) then TXM4 (0x044). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.TXM_AVAIL (bit 1) to clear it.
6. To send on RXM: wait until FLAGS.RXM_FULL (bit 1) is 0, or for IRQ RXM_DONE, then write RXM0 (0x048) then RXM1 (0x04C) then RXM2 (0x050) then RXM3 (0x054) then RXM4 (0x058). The last write commits the beat. RXM_OVF means a write came while the register was full and was dropped.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.HDCP_2_3_Content_Protection sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.HDCP_2_3_Content_Protection syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/HDCP_2_3_Content_Protection_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.HDCP_2_3_Content_Protection apb` | `TEST PASSED: HDCP_2_3_Content_Protection_apb`, then Yosys without `ERROR` | console, `work/HDCP_2_3_Content_Protection_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh HDCP_2_3_Content_Protection`<br>`bash scripts/cov/run_cov.sh HDCP_2_3_Content_Protection_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/HDCP_2_3_Content_Protection/score.json`, `work/cov/HDCP_2_3_Content_Protection_apb/score.json` |

Expected end of a step 4 run:

```
===== HDCP_2_3_Content_Protection =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/HDCP_2_3_Content_Protection_tb.sv`): drives `HDCP_2_3_Content_Protection_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/HDCP_2_3_Content_Protection_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/HDCP_2_3_Content_Protection_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/HDCP_2_3_Content_Protection_sva.sv`, `tb/cov/HDCP_2_3_Content_Protection_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/HDCP_2_3_Content_Protection_top.sv` | pass | 178/178 (+1 excl.) | 3430/3430 | 25/25 | 10/10 | 71/71 |
| wrapper `rtl/HDCP_2_3_Content_Protection_apb.sv` | pass | 54/54 | 1688/1688 | n/a | 17/17 | 80/80 |
