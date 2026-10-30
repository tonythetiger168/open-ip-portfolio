# Hardware root of trust: device lifecycle (RAW / TEST / DEV / PROD / RMA / SCRAP) in OTP with token-gated transitions, SHA-256 secure boot of the first image with anti-rollback, and HMAC-SHA256 device key derivation (DICE-style) on a sideload port

Protocol IP `Root_of_Trust`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Root_of_Trust_top` (`rtl/Root_of_Trust_top.sv`) |
| Register interface | APB4 slave `Root_of_Trust_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x52540100 (code 0x5254, version 1.0) |
| Registers | 16 words, 0x000 to 0x03C |
| Interrupts | 6 sources into one level-high `irq` |
| Data streams | IMG (to the core) |
| Protocol pins | 14 pass-through |

## Overview

Root_of_Trust_top v1.0: hardware root of trust for an SoC. It owns the device lifecycle, verifies the first boot image before the application CPU may run, and derives the device key that the image is bound to.

- OTP: 64 words of 32 bits in a one-time-programmable macro outside the
core (programming can only set bits). Map:
0-7   UDS, the unique device secret (never readable by software)
8-15  boot image digest (SHA-256)          16-23 SHA-256 of the test-exit token
24-31 SHA-256 of the RMA token             32    lifecycle word
33    scrap word                           34    anti-rollback (thermometer)
35-63 spare
Secrets are read from the OTP when they are used and are not kept in
the core: the UDS only passes through the hash block register while the
key is derived, and that register is cleared afterwards.
- Lifecycle: RAW, TEST (unlocked), DEV, PROD, RMA, SCRAP. The lifecycle
word is a union of four 8-bit groups (RAW 0, TEST A, DEV A|B, PROD A|C,
RMA A|B|C|D), so every legal transition only sets bits; any other value
(a partly set group, a group set out of order) decodes as INVALID. A set
scrap word is SCRAP whatever the lifecycle word says; a partly set one
is INVALID. Transitions: RAW -> TEST (a token whose SHA-256 is fixed in
the netlist), TEST -> DEV or PROD (the test-exit token), DEV or PROD ->
RMA (the RMA token), and any state -> SCRAP (no token). The token is
hashed and compared with the stored hash; the new word is programmed
and read back, and takes effect at the next reset. Three wrong tokens
lock the command port until reset.
- Secure boot: in DEV and PROD the first boot image is streamed in as
32-bit words (first word: the image version), hashed with SHA-256 and
compared with the OTP digest; its version must be at least the number
of anti-rollback bits set. Only then is cpu_en raised. TEST and RMA
boot without verification; RAW, SCRAP and INVALID do not boot.
- Key derivation: after a verified boot, key_out = HMAC-SHA256(UDS,
image digest || lifecycle word), a DICE-style compound device
identifier, valid on a sideload port for a crypto engine; it is not
readable through the command port. TEST and RMA give no key.
- Debug: dbg_en in TEST, DEV and RMA only.
- Escalation: esc (from a tamper sensor or an alert handler) clears the
key, cpu_en and dbg_en and stops the core until reset.
- Commands (one at a time, cmd_busy while running): 0 read an OTP word
(not the UDS), 1 program an OTP word (the region must be open in the
current state), 2 lifecycle transition to cmd_data[2:0] with token.
- Alerts: alert pulses with alert_code: 1 invalid lifecycle, 2 boot image
rejected, 3 wrong token, 4 access refused (UDS read, region closed),
5 OTP program did not read back, 6 escalation, 7 state register fault.

Features:

- Lifecycle in OTP: RAW, TEST, DEV, PROD, RMA and SCRAP, encoded so that every legal transition only sets bits; any other OTP value decodes as INVALID (no boot, no debug, alert). RAW -> TEST, TEST -> DEV / PROD and DEV / PROD -> RMA need a 128-bit token whose SHA-256 matches the stored (or, for RAW, built-in) hash; SCRAP needs none. The new word is programmed, read back, and takes effect at the next reset. Three wrong tokens lock the command port until reset.
- Secure boot in DEV and PROD: the first image is streamed in, hashed with SHA-256 (one round per clock) and compared with the digest in OTP; its version (first word) must be at least the number of anti-rollback bits set. Only then is cpu_en raised. TEST and RMA boot without verification; RAW, SCRAP and INVALID do not boot.
- Device key: after a verified boot, key_out = HMAC-SHA256(UDS, image digest || lifecycle word) on a sideload port (key_out / key_valid pass through the wrapper), never readable through the registers. The UDS is read from OTP only for this and only passes through the hash block, which is cleared afterwards.
- OTP access through the command port: read any word but the UDS; program only words open in the current state (UDS and token hashes in TEST, the boot digest in TEST / DEV, anti-rollback in DEV / PROD, spare words in TEST / DEV / PROD; never the lifecycle or scrap word); each program is read back.
- Escalation input esc (passes through the wrapper): clears the key, cpu_en and dbg_en and stops the core until reset.

OTP map (32-bit words): 0-7 UDS, 8-15 boot image digest, 16-23 SHA-256 of the test-exit token, 24-31 SHA-256 of the RMA token, 32 lifecycle word, 33 scrap word, 34 anti-rollback (thermometer), 35-63 spare. The OTP macro port (otp_*) passes through the wrapper.
TOKEN can be read back through the registers: clear it after a transition. The token itself is never stored in the core.
Each image word takes two register writes (IMG0, then IMG1 with the last flag). For a faster boot, drive the core's image port from a DMA instead.
Not implemented: side-channel protection of the SHA-256 core; fault-injection hardening beyond the state register check (alert 7); a TRNG for the UDS (it is programmed from outside in TEST).

## Files

| File | Content |
|---|---|
| `rtl/Root_of_Trust_top.sv` | protocol core |
| `rtl/Root_of_Trust_apb.sv` | APB4 register wrapper (generated) |
| `tb/Root_of_Trust_tb.sv` | core testbench |
| `tb/Root_of_Trust_apb_tb.sv`, `tb/apb/Root_of_Trust_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Root_of_Trust_sva.sv`, `tb/cov/Root_of_Trust_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Root_of_Trust.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`Root_of_Trust_apb` has the core's parameters and passes them to `Root_of_Trust_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `IMG_AW` | int | `14` |

## Wrapper pins

Pins of `Root_of_Trust_apb`. Widths of the pass-through pins are at the default parameters.

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
| `otp_req` | output | 1 | protocol pin, core port `otp_req` |
| `otp_we` | output | 1 | protocol pin, core port `otp_we` |
| `otp_addr` | output | 6 | protocol pin, core port `otp_addr` |
| `otp_wdata` | output | 32 | protocol pin, core port `otp_wdata` |
| `otp_ack` | input | 1 | protocol pin, core port `otp_ack` |
| `otp_rdata` | input | 32 | protocol pin, core port `otp_rdata` |
| `lc_state` | output | 3 | protocol pin, core port `lc_state` (also read in a register) |
| `cpu_en` | output | 1 | protocol pin, core port `cpu_en` (also read in a register) |
| `dbg_en` | output | 1 | protocol pin, core port `dbg_en` (also read in a register) |
| `key_valid` | output | 1 | protocol pin, core port `key_valid` (also read in a register) |
| `key_out` | output | 256 | protocol pin, core port `key_out` |
| `alert` | output | 1 | protocol pin, core port `alert` (also read in a register) |
| `alert_code` | output | 3 | protocol pin, core port `alert_code` (also read in a register) |
| `esc` | input | 1 | protocol pin, core port `esc` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `otp_req` | output | 1 | pin (pass-through) |
| `otp_we` | output | 1 | pin (pass-through) |
| `otp_addr` | output | 6 | pin (pass-through) |
| `otp_wdata` | output | 32 | pin (pass-through) |
| `otp_ack` | input | 1 | pin (pass-through) |
| `otp_rdata` | input | 32 | pin (pass-through) |
| `cmd_start` | input | 1 | CMD |
| `cmd_op` | input | 2 | CTRL[1:0] |
| `cmd_addr` | input | 6 | CTRL[7:2] |
| `cmd_data` | input | 32 | CMD_DATA[31:0] |
| `token` | input | 128 | TOKEN0[31:0], TOKEN1[31:0], TOKEN2[31:0], TOKEN3[31:0] |
| `cmd_busy` | output | 1 | STATUS[0:0] |
| `cmd_done` | output | 1 | IRQ_STATUS.CMD_DONE |
| `cmd_err` | output | 1 | IRQ_STATUS.CMD_ERR |
| `cmd_rdata` | output | 32 | RDATA[31:0] |
| `img_valid` | input | 1 | IMG commit / FLAGS |
| `img_data` | input | 32 | IMG0[31:0] |
| `img_last` | input | 1 | IMG1 |
| `img_ready` | output | 1 | IMG handshake |
| `init_done` | output | 1 | STATUS[1:1] |
| `lc_state` | output | 3 | STATUS[4:2] |
| `boot_done` | output | 1 | IRQ_STATUS.BOOT |
| `boot_ok` | output | 1 | STATUS[5:5] |
| `cpu_en` | output | 1 | STATUS[6:6] |
| `dbg_en` | output | 1 | STATUS[7:7] |
| `key_valid` | output | 1 | STATUS[8:8] |
| `key_out` | output | 256 | pin (pass-through) |
| `alert` | output | 1 | IRQ_STATUS.ALERT |
| `alert_code` | output | 3 | STATUS[11:9] |
| `esc` | input | 1 | pin (pass-through) |

## APB wrapper

`Root_of_Trust_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `otp_req`, `otp_we`, `otp_addr`, `otp_wdata`, `otp_ack`, `otp_rdata`, `lc_state`, `cpu_en`, `dbg_en`, `key_valid`, `key_out`, `alert`, `alert_code`, `esc`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x52540100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Command operands |
| 0x018 | CMD_DATA | RW | 0x00000000 | Command data |
| 0x01C | TOKEN0 | RW | 0x00000000 | Transition token, 128 bits over four words (TOKEN0 is bits 31:0) |
| 0x020 | TOKEN1 | RW | 0x00000000 | Transition token, 128 bits over four words (TOKEN0 is bits 31:0) |
| 0x024 | TOKEN2 | RW | 0x00000000 | Transition token, 128 bits over four words (TOKEN0 is bits 31:0) |
| 0x028 | TOKEN3 | RW | 0x00000000 | Transition token, 128 bits over four words (TOKEN0 is bits 31:0) |
| 0x02C | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x030 | IMG0 | RW | 0x00000000 | Boot image word: write the word to IMG, then the last flag to IMG1, which commits it (the first word is the image version) |
| 0x034 | IMG1 | RW | 0x00000000 | Boot image word: write the word to IMG, then the last flag to IMG1, which commits it (the first word is the image version) |
| 0x038 | RDATA | RO | core | Command result |
| 0x03C | STATUS | RO | core | Lifecycle and boot state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x040 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5254 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 5:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 5:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 1:0 | `cmd_op` | RW | 0x0 | command: 0 read an OTP word, 1 program an OTP word, 2 lifecycle transition (3 is refused with ERR) |
| CTRL | 7:2 | `cmd_addr` | RW | 0x0 | OTP word address for read and program |
| CMD_DATA | 31:0 | `cmd_data` | RW | 0x0 | program: the bits to set; transition: the target state in [2:0] (1 TEST, 2 DEV, 3 PROD, 4 RMA, 5 SCRAP) |
| TOKEN0 | 31:0 | `token[31:0]` | RW | 0x0 | token whose SHA-256 must match the stored hash of the transition |
| TOKEN1 | 31:0 | `token[63:32]` | RW | 0x0 | token whose SHA-256 must match the stored hash of the transition |
| TOKEN2 | 31:0 | `token[95:64]` | RW | 0x0 | token whose SHA-256 must match the stored hash of the transition |
| TOKEN3 | 31:0 | `token[127:96]` | RW | 0x0 | token whose SHA-256 must match the stored hash of the transition |
| CMD | 0 | `cmd_start` | WO (pulse) | 0x0 | run the command in CTRL; ignored while busy |
| IMG0 | 31:0 | `img_data` | RW | 0x0 | image word |
| IMG1 | 0 | `img_last` | RW | 0x0 | last word of the image |
| RDATA | 31:0 | `cmd_rdata` | RO | core | the OTP word of the last read command |
| STATUS | 0 | `cmd_busy` | RO | core | a command is running |
| STATUS | 1 | `init_done` | RO | core | the lifecycle has been read from the OTP |
| STATUS | 4:2 | `lc_state` | RO | core | 0 RAW, 1 TEST, 2 DEV, 3 PROD, 4 RMA, 5 SCRAP, 6 INVALID, 7 escalated |
| STATUS | 5 | `boot_ok` | RO | core | the boot image was accepted (or the state boots without verification) |
| STATUS | 6 | `cpu_en` | RO | core | the application CPU may run |
| STATUS | 7 | `dbg_en` | RO | core | debug is open |
| STATUS | 8 | `key_valid` | RO | core | the device key is valid on the sideload port |
| STATUS | 11:9 | `alert_code` | RO | core | cause of the last alert: 1 invalid lifecycle, 2 boot image rejected, 3 wrong token, 4 access refused, 5 OTP readback, 6 escalation, 7 state fault |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CMD_DONE | a command finished (RDATA holds a read's result) |
| 1 | CMD_ERR | a command was refused or failed |
| 2 | BOOT | the boot decision is made (STATUS.boot_ok gives it) |
| 3 | ALERT | an alert was raised (STATUS.alert_code gives the cause) |
| 4 | IMG_DONE | IMG beat accepted by the core |
| 5 | IMG_OVF | write to IMG while full (dropped) |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | IMG_FULL | IMG holds a beat the core has not taken |

### Streams

* **IMG** feeds `img_data`, `img_last`/`img_valid`. Writing IMG1 commits the beat: FLAGS.IMG_FULL is set and `img_valid` stays high until the core's `img_ready`; then IMG_DONE is set. A write while full is dropped and sets IMG_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x52540100.
2. Write 0x3F to IRQ_STATUS (0x004) to clear any stale bits (BOOT, ALERT may be set as soon as reset ends).
3. Configure the core: write CTRL (0x014), CMD_DATA (0x018), TOKEN0 (0x01C), TOKEN1 (0x020), TOKEN2 (0x024), TOKEN3 (0x028). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3F enables all).
5. To issue a command, write 1 to `cmd_start` (CMD bit 0) at 0x02C; the core sees a one-clock pulse, and the register reads 0.
6. To send on IMG: wait until FLAGS.IMG_FULL (bit 0) is 0, or for IRQ IMG_DONE, then write IMG0 (0x030) then IMG1 (0x034). The last write commits the beat. IMG_OVF means a write came while the register was full and was dropped.
7. Read RDATA (0x038) for the core's live `cmd_rdata`; it needs no clearing.
8. Read STATUS (0x03C) for the core's live `cmd_busy`, `init_done`, `lc_state`, `boot_ok`, `cpu_en`, `dbg_en`, `key_valid`, `alert_code`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. After reset, wait for STATUS.init_done; STATUS.lc_state gives the lifecycle.
2. Secure boot (DEV / PROD): for each image word write IMG0 = word, then IMG1 = last; wait for IRQ_STATUS.BOOT, then STATUS.boot_ok and STATUS.cpu_en.
3. OTP read: CTRL = op 0 | addr << 2, CMD = 1, wait for IRQ_STATUS.CMD_DONE, read RDATA (CMD_ERR set if refused).
4. Transition: TOKEN0..TOKEN3 = token (TOKEN3 holds bits 127:96, the first bytes hashed), CMD_DATA = target state, CTRL = op 2, CMD = 1, wait for CMD_DONE; check CMD_ERR; clear TOKEN; reset to take the new state.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Root_of_Trust sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Root_of_Trust syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Root_of_Trust_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Root_of_Trust apb` | `TEST PASSED: Root_of_Trust_apb`, then Yosys without `ERROR` | console, `work/Root_of_Trust_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Root_of_Trust`<br>`bash scripts/cov/run_cov.sh Root_of_Trust_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Root_of_Trust/score.json`, `work/cov/Root_of_Trust_apb/score.json` |

Expected end of a step 4 run:

```
===== Root_of_Trust =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Root_of_Trust_tb.sv`): drives `Root_of_Trust_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Root_of_Trust_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Root_of_Trust_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Root_of_Trust_sva.sv`, `tb/cov/Root_of_Trust_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Root_of_Trust_top.sv` | pass | 170/170 (+1 excl.) | 4548/4548 | 46/46 | 16/16 | 57/57 |
| wrapper `rtl/Root_of_Trust_apb.sv` | pass | 51/51 | 2034/2034 | n/a | 18/18 | 69/69 |

Core: tb/Root_of_Trust_tb.sv with an OTP model (random latency, random read data between accesses, a stuck-bit fault) runs every lifecycle state, every legal and illegal transition with right and wrong tokens, the token lockout, programs into open and closed regions, readback failures, and 52 boot cases (image lengths 1-34, 47-49, 63-65, 100, 257 words, rollback, bad digest) against vectors from scripts/rot/gen_vec.py (hashlib / hmac).
The core checker has its own SHA-256 (constants computed from the primes) and HMAC and recomputes the expected digest, boot decision and device key, plus the lifecycle decode, OTP access rules, escalation and the secret-handling rules (UDS read only for the key, block cleared when idle).
