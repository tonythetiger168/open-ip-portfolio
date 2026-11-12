<!-- SPDX-License-Identifier: Apache-2.0 -->
# Toggle_Mode_NAND: design specification

A toggle-mode NAND flash target (the device side): SDR commands and addresses, DDR data with a
DQS strobe, a 16-page x 64-byte array. Not implemented: real geometry, timing modes and
on-die termination, ONFI parameter pages, cache / multi-plane commands, features, ECC, write
protect pin. Core `Toggle_Mode_NAND_top` (`rtl/Toggle_Mode_NAND_top.sv`), testbench
`tb/Toggle_Mode_NAND_tb.sv` (the TB is the host with a shadow array), checker
`tb/cov/Toggle_Mode_NAND_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Bus inputs are oversampled: WE#, RE# and DQS pass three flops (an
edge is seen between the second and third), CE#, CLE and ALE two, DQ two (aligned with the edge
detectors). A page is 64 bytes; a block is 4 pages.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock (oversamples the bus) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `ce_n` | input | 1 | chip enable | low | async | - |
| `cle` | input | 1 | command latch enable | high | async | - |
| `ale` | input | 1 | address latch enable | high | async | - |
| `we_n` | input | 1 | write strobe; commands / addresses latch on its rise | low | async | - |
| `re_n` | input | 1 | read strobe; every edge after the first fall presents a byte | low | async | - |
| `dq` | inout | 8 | data bus; driven by the target during data output | - | `clk` | Z |
| `dqs` | inout | 1 | data strobe: host during data input, target (echo of `re_n`) during output | - | `clk` | Z |
| `rb_n` | output | 1 | ready (1) / busy (0) | - | `clk` | 1 |
| `irq` | output | 1 | sticky protocol error (cleared by FFh or reset) | high | `clk` | 0 |

### Internal signals used by the verification

The checker is bound with `.*` and reads `drive_en` and `mem`; the TB reads `busy`; the FSM
coverage collector binds `state`, `omode` and `op`.

| Signal | Width | Meaning |
|---|---|---|
| `busy` | 1 | an operation is in flight (`rb_n` = !`busy`) |
| `drive_en` | 1 | the target drives DQ / DQS; combinational |
| `mem` | 8 x 1024 | the array (power-up and reset value 0xFF) |
| `state` | 3 | command sequence: 0 CMD, 1 Read ID address, 2 5-address phase, 3 wait 30h, 4 data in (wait 10h), 5 erase address, 6 wait D0h |
| `omode` | 2 | output: 0 none, 1 ID, 2 status, 3 page data |
| `op` | 2 | operation in flight: 0 read, 1 program, 2 erase, 3 reset |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Toggle_Mode_NAND.md`](../ip/Toggle_Mode_NAND.md) (source: `scripts/apb/specs/Toggle_Mode_NAND.json`); do not edit by hand.

`Toggle_Mode_NAND_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ce_n`, `cle`, `ale`, `we_n`, `re_n`, `dq`, `dqs`, `rb_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x544E0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Target state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x544E | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `rb_n` | RO | core | ready (1) / busy (0); same as the rb_n pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PROTO | unknown command, command out of sequence, address cycle outside an address phase, or a command other than 70h / FFh while busy. Held in the core until FFh, so the bit is set again on every clock until then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x544E0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `rb_n`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Commands and addresses

At a synchronised WE# rise with CE# low: CLE high latches a command, else ALE high latches an
address byte (from DQ).

| Sequence | Operation |
|---|---|
| 90h, 1 address | Read ID: 2C A5 90 16 54, repeating |
| 00h, 5 addresses, 30h | Page Read: column = address 0 [5:0], page = address 2 [3:0]; busy `T_R` |
| 80h, 5 addresses, data, 10h | Page Program: page buffer set to FF at 80h, data written from the column on, wrapping; busy `T_PROG`; then array &= buffer |
| 60h, 3 addresses, D0h | Block Erase: page = address 0 [3:0]; busy `T_ERASE`; then the block is FF |
| 70h | Read Status at any time (also while busy) |
| 00h without addresses after a completed read | return to the read data at the column |
| FFh | Reset at any time: aborts the operation, clears `irq` and FAIL; busy `T_RST` |

Status = {1 (WP_n), RDY, ARDY, 0000, FAIL}, RDY = ARDY = !busy. FAIL reports the last program or
erase (cleared at 80h, 60h, 30h and FFh). Block 3 (pages 12..15) is protected: program / erase
leave it unchanged and set FAIL.

`rb_n` is low for exactly the operation's busy count; the array changes when it ends.

### 3.2 Errors

`irq` is set (sticky) and the command is ignored for: an unknown command, a command out of
sequence (the sequence is abandoned), an address byte outside an address phase, any command but
70h / FFh while busy. 70h in the middle of a sequence also sets `irq` (and abandons it).

### 3.3 Data output

After Read ID, 70h, or a completed page read (unless 70h was given while it was busy, then
status stays), the target waits for the first synchronised RE# fall. From then on, while CE# is
low and CLE and ALE are low (raw pins, so a command or address cycle releases the bus at once),
it drives DQ with the current byte and DQS with the synchronised RE#. Each further RE# edge
presents the next byte (ID wraps after 5, data wraps at 64). A new command or address stops the
output.

### 3.4 Data input

During program data input, each synchronised DQS edge (with CE# low and the target not driving)
writes DQ into the page buffer at the pointer and advances it, wrapping at 64.

### 3.5 Reset

While `rst_n` is low: idle, not busy, `irq` and FAIL 0, page buffer and array 0xFF, outputs
released.

## 4. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `T_R` | 25 | page read busy, clocks |
| `T_PROG` | 200 | page program busy, clocks |
| `T_ERASE` | 1000 | block erase busy, clocks |
| `T_RST` | 5 | reset busy, clocks |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| unknown / out-of-sequence command, address out of place, command while busy | ignored, `irq` |
| program / erase of block 3 | array unchanged, FAIL |
| program bits 0 -> 1 | not possible (AND) |
| FFh during an operation | operation dropped |
| strobes with CE# high | ignored, no drive |
| more than 64 data bytes | wrap within the page |

## 6. TB check map

Messages are printed by `tb/Toggle_Mode_NAND_tb.sv` as `ERROR: <message>`. Assertions `a_*` are
in the bound checker `tb/cov/Toggle_Mode_NAND_sva.sv`. The TB is the host with a shadow array that
predicts every read.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "read page" | page data | §3.1, §3.3 |
| "dqs does not echo re_n" | DQS echo | §3.3 |
| "rb_n stuck busy" | operations end | §3.1 |
| "program: busy" | busy during program | §3.1 |
| "reset state" | reset values | §3.5 |
| "Read ID byte" | ID bytes | §3.1 |
| "status kept after the read completes" | status mode kept | §3.3 |
| "data after 00h" | return to data | §3.1 |
| "00h after a return to data" | 00h again | §3.1 |
| "00h after one address cycle: no irq" | 00h restarts the address phase | §3.1, §3.2 |
| "data driven after an abandoned read" | no output after an abandoned read | §3.3 |
| "read after 00h" | read after a return | §3.1 |
| "no data output after a reset read" | FFh drops the read | §3.1 |
| "strobe with ce_n high was taken" | CE# gating | §3.4 |
| "drives with ce_n high" | CE# gating | §3.3 |
| "rst_n mid-program" | reset during an operation | §3.5 |
| a_reset_state | reset values | §3.5 |
| a_rb_n | `rb_n` as the model | §3.1 |
| a_irq | `irq` as the model | §3.2 |
| a_drive_enable | drive enable as the model | §3.3 |
| a_dq_value | DQ value as the model | §3.3 |
| a_dqs_echo | DQS = synchronised RE# | §3.3 |
| a_array | array as the model | §3.1 |
