# Root_of_Trust: design specification

Hardware root of trust for an SoC. It owns the device lifecycle and verifies the first boot image with SHA-256 against an OTP digest before the application CPU may run. It also derives a DICE-style device key, HMAC-SHA256(UDS, image digest || lifecycle word), that is bound to the image. Core `Root_of_Trust_top` (`rtl/Root_of_Trust_top.sv`), testbench `tb/Root_of_Trust_tb.sv`, checker `tb/cov/Root_of_Trust_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset; the lifecycle is re-read after every reset | low | async | - |
| `otp_req` | output | 1 | OTP request, held until `otp_ack` (dropped the clock after it) | high | `clk` | 0 |
| `otp_we` | output | 1 | 1 program (sets the bits of `otp_wdata`), 0 read | high | `clk` | 0 |
| `otp_addr` | output | 6 | OTP word address (map in §3.1) | - | `clk` | 0 |
| `otp_wdata` | output | 32 | program data | - | `clk` | 0 |
| `otp_ack` | input | 1 | OTP done; `otp_rdata` valid for a read | high | `clk` | - |
| `otp_rdata` | input | 32 | OTP read data | - | `clk` | - |
| `cmd_start` | input | 1 | start command `cmd_op` (taken only when idle) | high | `clk` | - |
| `cmd_op` | input | 2 | 0 read an OTP word, 1 program an OTP word, 2 lifecycle transition, 3 reserved (refused) | - | `clk` | - |
| `cmd_addr` | input | 6 | OTP word address (read / program) | - | `clk` | - |
| `cmd_data` | input | 32 | program data; transition target in bits 2:0 (lifecycle code) | - | `clk` | - |
| `token` | input | 128 | transition token (hashed with SHA-256) | - | `clk` | - |
| `cmd_busy` | output | 1 | not idle: init, a command, a boot verification, key derivation or escalation (= `ms` != IDLE) | high | comb | 1 |
| `cmd_done` | output | 1 | one-clock pulse: the command finished (also for a refused one) | high | `clk` | 0 |
| `cmd_err` | output | 1 | with `cmd_done`: refused or failed | high | `clk` | 0 |
| `cmd_rdata` | output | 32 | read result, held | - | `clk` | 0 |
| `img_valid` | input | 1 | boot image word valid | high | `clk` | - |
| `img_data` | input | 32 | image word (the first word is the image version) | - | `clk` | - |
| `img_last` | input | 1 | last image word | high | `clk` | - |
| `img_ready` | output | 1 | image word taken (= `ms` == IMG) | high | comb | 0 |
| `init_done` | output | 1 | the lifecycle has been read and decoded | high | `clk` | 0 |
| `lc_state` | output | 3 | 0 RAW, 1 TEST, 2 DEV, 3 PROD, 4 RMA, 5 SCRAP, 6 INVALID, 7 ESCALATED | - | comb | 0 |
| `boot_done` | output | 1 | the boot decision is made | high | `clk` | 0 |
| `boot_ok` | output | 1 | boot allowed (verified, or TEST / RMA) | high | `clk` | 0 |
| `cpu_en` | output | 1 | the application CPU may run | high | `clk` | 0 |
| `dbg_en` | output | 1 | debug allowed: TEST, DEV, RMA after init and not escalated | high | comb | 0 |
| `key_valid` | output | 1 | `key_out` valid (verified DEV / PROD boot) | high | `clk` | 0 |
| `key_out` | output | 256 | derived device key (sideload port, not readable by commands) | - | `clk` | 0 |
| `alert` | output | 1 | one-clock pulse with `alert_code` | high | `clk` | 0 |
| `alert_code` | output | 3 | 1 invalid lifecycle, 2 boot image rejected, 3 wrong token, 4 access refused, 5 OTP program did not read back, 6 escalation, 7 state register fault | - | `clk` | 0 |
| `esc` | input | 1 | escalation (tamper sensor / alert handler) | high | `clk` | - |

### Internal signals used by the verification

| Signal | Width | Meaning |
|---|---|---|
| `blk` | 512 | SHA-256 message block / schedule window register. It carries the UDS during key derivation and must be all zero whenever the core is idle after init |
| `nw_ovf` | 1 | the image had 2^IMG_AW or more words (cleared by reset) |
| `ms` | 5 | control FSM (FSM coverage): 0 INIT, 1 IDLE, 2 RD, 3 PG, 4 PV, 5 TOKH, 6 TOKC, 7 TRPG, 8 TRPV, 9 IMG, 10 IMGH, 11 PAD, 12 PADH, 13 VER, 14 KLD, 15 KH, 16 KMH, 17 ESC |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Root_of_Trust.md`](../ip/Root_of_Trust.md) (source: `scripts/apb/specs/Root_of_Trust.json`); do not edit by hand.

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

### Programming sequence

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
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 OTP

The OTP is 64 words of 32 bits in an external one-time-programmable macro. A program can only set bits.

| Words | Content |
|---|---|
| 0-7 | UDS (unique device secret; never readable by commands) |
| 8-15 | boot image digest (SHA-256, word 8 = digest bits 255:224) |
| 16-23 | SHA-256 of the test-exit token |
| 24-31 | SHA-256 of the RMA token |
| 32 | lifecycle word |
| 33 | scrap word |
| 34 | anti-rollback (thermometer: the number of set bits) |
| 35-63 | spare |

Handshake: `otp_req` rises with `otp_we` / `otp_addr` / `otp_wdata` and is held until `otp_ack`. It drops on the clock after the ack. Each access waits for the previous one to finish. Secrets are read only when used and are not kept in the core.

### 3.2 Init and lifecycle decode

After reset the core reads words 32, 33 and 34 in that order. On the third ack it decodes the state, sets `init_done` and goes idle. The groups are A = 0x000000FF, B = 0x0000FF00, C = 0x00FF0000, D = 0xFF000000.

| State | Lifecycle word |
|---|---|
| RAW | 0 |
| TEST | A |
| DEV | A\|B |
| PROD | A\|C |
| RMA | A\|B\|C\|D |

- Any other lifecycle word decodes as INVALID: for example a partly set group, or a group set out of order.
- A scrap word of 0xFFFFFFFF gives SCRAP, whatever the lifecycle word holds.
- Any other non-zero scrap word gives INVALID.
- INVALID pulses alert 1 at init.
- TEST and RMA set `boot_done` = `boot_ok` = `cpu_en` = 1 at init, without verification.
- RAW, SCRAP and INVALID set `boot_done` = 1 and `boot_ok` = 0. They never boot.
- DEV and PROD wait for an image.

### 3.3 Commands

`cmd_start` is taken only in IDLE. A start while busy is ignored, and `cmd_busy` is also high during init, boot verification and key derivation. Every command ends with a one-clock `cmd_done`, with `cmd_err` = 1 when it was refused or failed.

| Op | Command | Behaviour |
|---|---|---|
| 0 | read | OTP word `cmd_addr` into `cmd_rdata` |
| 1 | program | OTP word `cmd_addr` with `cmd_data`, then read back |
| 2 | transition | lifecycle transition to `cmd_data[2:0]` with `token` |
| 3 | reserved | refused, with no alert |

- **Read:** words 0-7 (the UDS) are refused with alert 4.
- **Program permissions:** a program the region does not allow is refused with alert 4.
  - UDS (0-7) and token hashes (16-31): TEST only.
  - Boot digest (8-15): TEST and DEV.
  - Anti-rollback (34): DEV and PROD.
  - Spare (35-63): TEST, DEV and PROD.
  - Lifecycle and scrap (32, 33): never.
- **Program read-back:** after a program the word is read back. If it does not hold every programmed bit, the command fails with alert 5.
- **Allowed transitions:**
  - RAW to TEST, with a token whose SHA-256 is fixed in the netlist (the token "RAW_UNLOCK_TOKEN").
  - TEST to DEV or PROD, with the test-exit token (hash in words 16-23).
  - DEV or PROD to RMA, with the RMA token (hash in words 24-31).
  - Any state to SCRAP, with no token.

  Any other target is refused with `cmd_err` and no alert.
- **Transition steps:**
  1. The 128-bit token is hashed as one SHA-256 block of 64 rounds, one per clock.
  2. The eight hash words are compared with the expected words. These come from the netlist constant for RAW, otherwise from OTP reads.
  3. A mismatch gives `cmd_err` and alert 3. Three wrong tokens since reset lock the command port, and every command is then refused with no alert.
  4. On a match the target lifecycle word is programmed to word 32 (word 33 = all ones for SCRAP) and read back. The read-back must be equal, otherwise alert 5.
- **After a transition:** the new state takes effect at the next reset. Until then, programs and transitions are refused with no alert; reads still work.

### 3.4 Secure boot (DEV and PROD)

In IDLE with no command, `img_valid` before the boot decision starts verification. `img_ready` = 1 in state IMG.

1. Each image word is taken in one clock, filling a 16-word block. A full block is hashed in 64 + 2 clocks while `img_ready` is low.
2. After `img_last`, SHA-256 padding is added: the 0x80000000 word, zeros, and the 64-bit bit length.
3. The digest is compared with OTP words 8-15. All eight are read, whatever they hold.
4. The image is accepted only if the digest matches, the image is shorter than 2^IMG_AW words, and its first word (the version) is at least the number of anti-rollback bits set.
5. On rejection: `boot_done` = 1, `boot_ok` = 0, and alert 2.
6. On acceptance: key derivation (§3.5) runs, and then `boot_done` = `boot_ok` = `cpu_en` = `key_valid` = 1 are set together.

There is only one image per reset.

### 3.5 Key derivation

`key_out` = HMAC-SHA256(UDS, digest || lifecycle word). The UDS words are read from the OTP straight into the block register, XORed with ipad / opad, and are never kept elsewhere. The derivation runs two hashes of two blocks each. `blk` and the inner hash are cleared at the end and on every boot rejection or wrong token, so `blk` = 0 whenever the core is idle after init. TEST and RMA give no key.

### 3.6 Debug

`dbg_en` = 1 in TEST, DEV and RMA once `init_done` is set. It is cleared by escalation.

### 3.7 Escalation

`esc` takes effect at the next clock edge, from any state:
- the state goes to ESC (`lc_state` = 7);
- `cpu_en`, `key_valid`, `key_out`, `blk` and the inner hash are cleared, `otp_req` is dropped and the hash engine is stopped;
- alert 6 pulses.

After that the core does nothing until reset: `cmd_busy` = 1 and no image is taken.

### 3.8 Reset

Every output is 0 except `cmd_busy` = 1, which reports init. `lc_state` = RAW until init completes. A reset during boot restarts init with no boot state.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `IMG_AW` | 14 | 1..58 | image length counter: an image of 2^IMG_AW or more words is rejected |

## 5. Errors and corner cases

- An oversized image is rejected even when the OTP digest matches the hash of the wrapped length.
- An unknown control state (a fault) goes to ESC with alert 7.
- Refusals without an alert: a reserved op, an illegal transition target, the port locked after three wrong tokens, and programs / transitions after a transition before reset.
- A program that does not read back (a stuck OTP bit) fails with alert 5, even though some bits are now set.
- The OTP decode is done once per reset. A programmed lifecycle word does not change `lc_state` until the next reset.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "init_done" | `init_done` after the three init reads | §3.2 |
| "cmd timeout" | each command ends with `cmd_done` | §3.3 |
| "busy after done" | `cmd_busy` low with `cmd_done` | §3.3 |
| "command" | accepted / refused commands with the expected alert code | §3.3, §5 |
| "boot timeout" | the boot decision is made | §3.4 |
| "case" | per lifecycle / image case: `lc_state`, `boot_ok`, key, alert | §3.2, §3.4, §3.5 |
| "dbg_en" | `dbg_en` per lifecycle state | §3.6 |
| "booted before the image" | DEV / PROD do not boot before the image is verified | §3.4 |
| "block register not cleared" | `blk` all zero after a boot decision | §3.5 |
| "second image" | no second image after the boot decision | §3.4 |
| "lifecycle" | `lc_state` decode of the OTP words | §3.2 |
| "boot state" | boot outputs for states that do not verify | §3.4 |
| "init alert" | INVALID gives alert 1 at init, other states none | §3.2 |
| "image taken" | no image taken in TEST / RMA / RAW / SCRAP / INVALID | §3.4 |
| "lifecycle word" | the programmed lifecycle word value | §3.3 |
| "after the transition" | the new state after the next reset | §3.3 |
| "spare word" | program and read a spare word | §3.3 |
| "token hash read" | token hash words are readable | §3.3 |
| "stuck word" | a program that does not read back fails with alert 5 | §3.3 |
| "start while busy" | `cmd_start` while busy is ignored | §3.3 |
| "half-programmed lifecycle word" | a partial group decodes as INVALID | §3.2 |
| "escalation in idle" | `esc` in idle: ESCALATED, no debug / CPU, alert 6 | §3.7 |
| "commands after escalation" | no command runs after escalation | §3.7 |
| "escalation in phase" | `esc` in any phase clears key, CPU, debug, OTP request and `blk` | §3.7 |
| "image E" | a valid image boots with a key | §3.4, §3.5 |
| "escalation after boot" | `esc` after a boot clears the key and `cpu_en` | §3.7 |
| "state after a reset during boot" | a reset during verification restarts without boot | §3.8 |
| "oversized image" | an image of 2^IMG_AW words or more is rejected (alert 2) | §5 |
| "after reset" | `boot_done` and `nw_ovf` cleared by reset | §3.8 |
| a_init_order | init reads the lifecycle, scrap and anti-rollback words before anything else | §3.2 |
| a_lifecycle | `lc_state` equals the decoded OTP state | §3.2 |
| a_debug | `dbg_en` per state | §3.6 |
| a_otp_program | OTP programs only as a command allows | §3.3 |
| a_uds_read_only_for_key | UDS words are read only during key derivation | §3.5 |
| a_command_result | `cmd_done` / `cmd_err` / `cmd_rdata` as the model | §3.3 |
| a_boot_decision | boot result as the model (digest, version, length) | §3.4 |
| a_key | `key_out` = HMAC-SHA256(UDS, digest \|\| lifecycle word) | §3.5 |
| a_image_only_when_verifying | `img_ready` only in DEV / PROD before the decision | §3.4 |
| a_cpu_only_after_boot | `cpu_en` implies `boot_done && boot_ok` | §3.4 |
| a_key_only_after_verified_boot | `key_valid` only after a verified DEV / PROD boot | §3.5 |
| a_escalation | after `esc`: ESCALATED, no CPU / debug / key / OTP request / image, busy | §3.7 |
| a_escalation_alert | `esc` gives alert 6 the next clock | §3.7 |
| a_idle_block_clear | `blk` = 0 while idle after init | §3.5 |
| a_otp_req_hold | `otp_req` / `otp_addr` / `otp_we` held until `otp_ack` (unless `esc`) | §3.1 |
| a_reset | reset values | §3.8 |
