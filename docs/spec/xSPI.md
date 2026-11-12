<!-- SPDX-License-Identifier: Apache-2.0 -->
# xSPI: design specification

An xSPI (JESD251) 8D-8D-8D octal DDR NOR flash target with a 2^`MEM_AW` byte array, a Profile
1.0 style command set and a DQS read strobe. Not implemented: 1S-1S-1S and other modes, address
bits above A15, ECC, data-strobe on writes, suspend / resume, security registers, deep power down,
real program / erase times (one byte per clock here). Core `xSPI_top` (`rtl/xSPI_top.sv`),
testbench `tb/xSPI_tb.sv` (the TB is the host), checker `tb/cov/xSPI_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. CK, CS# and DQ are sampled on `clk`; an edge is a clock where CS# is
low and `ck` differs from its value one clock earlier; it is acted on in that clock. A frame is
CS# low to CS# high; its end is seen in the clock where `csn` is first 1.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock (oversamples the xSPI pins) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `ck` | input | 1 | xSPI CK; idles low; each level held 2 or more clocks | - | async | - |
| `csn` | input | 1 | chip select | low | async | - |
| `dq_i` | input | 8 | DQ from the host; stable one clock before and after a CK edge | - | async | - |
| `dq_o` | output | 8 | DQ to the host (read data) | - | `clk` | 0 |
| `dq_oe` | output | 1 | device drives DQ | high | `clk` | 0 |
| `dqs_o` | output | 1 | read data strobe | - | `clk` | 0 |
| `dqs_oe` | output | 1 | device drives DQS | high | `clk` | 0 |
| `sr` | output | 2 | status {WEL, WIP}; combinational from flops | - | `clk` | 0 |
| `dummy` | output | 5 | read latency in CK cycles | - | `clk` | `DUMMY` |
| `err_code` | output | 3 | last error (0 none, 1..7 below); holds | - | `clk` | 0 |
| `irq_cmd` | output | 1 | one-clock pulse: a frame was accepted | high | `clk` | 0 |
| `irq_done` | output | 1 | one-clock pulse: a program or erase finished | high | `clk` | 0 |
| `irq_err` | output | 1 | one-clock pulse: an error | high | `clk` | 0 |

### Internal signals used by the verification

The TB compares the array with its model by name; the FSM coverage collector binds `st`.

| Signal | Width | Meaning |
|---|---|---|
| `mem` | 8 x 2^`MEM_AW` | the array; not cleared by reset (simulation starts it at 0) |
| `st` | 3 | frame phase: 0 CMD, 1 ADDR, 2 DUMMY, 3 DATA, 4 END, 5 IGNORE |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/xSPI.md`](../ip/xSPI.md) (source: `scripts/apb/specs/xSPI.json`); do not edit by hand.

`xSPI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ck`, `csn`, `dq_i`, `dq_o`, `dq_oe`, `dqs_o`, `dqs_oe`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x78530100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Device state as the host sees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7853 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 1:0 | `sr` | RO | core | status register bits: [1] WEL (write enable latch), [0] WIP (program / erase in progress) |
| STATUS | 6:2 | `dummy` | RO | core | read latency in CK cycles (WRCR, 4..31; 8 after reset or RESET) |
| STATUS | 9:7 | `err_code` | RO | core | last error: 1 bad extension, 2 unknown command, 3 busy, 4 WEL not set, 5 bad frame length or CS# with CK high, 6 dummy setting below 4, 7 RESET without RESET ENABLE |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CMD | a frame ended and its command was accepted |
| 1 | DONE | a page program, sector erase or chip erase finished (WIP and WEL cleared) |
| 2 | ERR | a frame was rejected; the cause is in STATUS.err_code |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x78530100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
4. Read STATUS (0x014) for the core's live `sr`, `dummy`, `err_code`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Frame

Every CK edge (rising and falling) carries one byte on DQ:

| Edges | Content |
|---|---|
| 0, 1 | command, then its inverse |
| 2..5 | address A[31:24] .. A[7:0] (commands with an address) |
| 2 x `dummy` | dummy (reads) |
| then | data, one byte per edge |

Only the array bits of A[15:0] are used and A0 is forced to 0; the read address then wraps
around the array.

| Command | Op | Address | Dummy / read | Needs WEL |
|---|---|---|---|---|
| 06 F9 | WREN | - | - | - |
| 04 FB | WRDI | - | - | - |
| 05 FA | RDSR: byte {000000, WEL, WIP} | yes | yes | - |
| 9F 60 | RDID: 4F, 58, `MEM_AW`, 00, ... | yes | yes | - |
| EE 11 | READ | yes | yes | - |
| 12 ED | PAGE PROGRAM | yes | - | yes |
| 21 DE | SECTOR ERASE | yes | - | yes |
| 60 9F | CHIP ERASE | - | - | yes |
| 81 7E | WRCR: dummy = first data byte [4:0] | yes | - | yes |
| 85 7A | RDCR: byte {000, `dummy`} | yes | yes | - |
| 66 99 | RESET ENABLE | - | - | - |
| 99 66 | RESET: `dummy` = `DUMMY`, WEL = 0 | - | - | - |

### 3.2 Command checks (at edge 1)

In this order, the first failing check ends the frame as ignored (`irq_err` pulses, `err_code`
set): 1 the second byte is not the inverse; 2 unknown command; 3 WIP set and the command is not
RDSR; 4 WEL needed and not set; 7 RESET not directly after an accepted RESET ENABLE frame.

### 3.3 Reads

At the last address edge the device drives DQS low (preamble). At the last dummy edge it turns
on DQ. On each data edge it puts the next byte on DQ and toggles DQS, so the host captures byte
2k on a DQS rise and byte 2k + 1 on a DQS fall. All drivers turn off at the frame end.

### 3.4 Frame end

An edge after the header of a command that has no data (WREN, WRDI, CE, RESET ENABLE, RESET after
2 edges; SE after 6) is error 5 at that edge, and the frame is ignored. At CS# high, for a frame
not ignored:

* an odd number of edges, a frame cut in the address, or PP / WRCR without data: error 5;
* WRCR with a value below 4: error 6;
* no edge at all: nothing;
* otherwise `irq_cmd` pulses and the command takes effect: WREN / WRDI set / clear WEL; WRCR loads
  `dummy` and clears WEL; RESET restores `dummy` and clears WEL; PP / SE / CE start in the
  background. The RESET ENABLE flag is set by an accepted RESET ENABLE frame and cleared by any
  other accepted frame.

### 3.5 Program and erase

PP data bytes go into a page buffer at consecutive addresses, wrapping inside the 2^`PAGE_AW`
page. In the background WIP = 1 and one array byte per clock is processed from the first to the
last byte of the page (PP), sector (SE) or array (CE): erase writes FF; program writes
old AND data for the bytes received (others unchanged). At the last byte WIP and WEL clear and
`irq_done` pulses, so WIP is high for exactly one clock per byte.

### 3.6 Reset

While `rst_n` is low: idle phase, drivers off, WEL / WIP / RESET ENABLE 0, `dummy` = `DUMMY`,
`err_code` 0, pulses 0. A background operation stops; the array keeps its contents.

## 4. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `MEM_AW` | 9 | array of 2^`MEM_AW` bytes (9..16) |
| `PAGE_AW` | 5 | program page of 2^`PAGE_AW` bytes |
| `SECT_AW` | 7 | erase sector of 2^`SECT_AW` bytes |
| `DUMMY` | 8 | read latency after reset, CK cycles |

## 5. Errors and corner cases

| `err_code` | Cause |
|---|---|
| 1 | second byte is not the inverted command |
| 2 | unknown command |
| 3 | command other than RDSR while WIP |
| 4 | PP / SE / CE / WRCR without WEL |
| 5 | bad frame length or CS# raised with CK high |
| 6 | WRCR value below 4 |
| 7 | RESET without RESET ENABLE |

An ignored frame is ignored to its end (including later edges). A CS# pulse with no edges does
nothing. Reads may end anywhere after the address (even edge count). Program never sets bits.
WRCR uses only the first data byte.

## 6. TB check map

Messages are printed by `tb/xSPI_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/xSPI_sva.sv`, an edge-counting model of the device. The TB is the host and has a
frame-level model that predicts every read byte, pulse, error code and the array.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "read" | right number of bytes and data | §3.1, §3.3 |
| "RDSR byte" | status read while busy | §3.1, §3.5 |
| "frame" | `irq_cmd` / `irq_err` / `err_code` / `sr` / `dummy` after each frame | §3.2, §3.4 |
| "WIP never cleared" | operations finish | §3.5 |
| "array[" | the array as the model | §3.5 |
| "DQ driven by host and device" | DQ only after the dummy phase | §3.3 |
| "DQS preamble not low" | DQS starts low | §3.3 |
| "DQ changed without a DQS edge" | DQ changes with DQS | §3.3 |
| "DQS toggled with DQ not driven" | DQS toggles only with DQ driven | §3.3 |
| "drivers on with CS# high" | drivers off at the frame end | §3.3 |
| "WIP high" | one clock per array byte | §3.5 |
| "reset values" | reset values | §3.6 |
| "an erase cut by reset ran to the end of the page" | reset stops a background operation | §3.6 |
| a_sr | WEL / WIP as the model | §3.4, §3.5 |
| a_dummy | `dummy` as the model | §3.4 |
| a_irq | the three pulses and `err_code` as the model | §3.2, §3.4, §3.5 |
| a_drivers | `dq_oe` / `dqs_oe` as the model | §3.3 |
| a_dqs | DQS level as the model | §3.3 |
| a_read_data | each read byte as the model | §3.1, §3.3 |
| a_quiet_cs_high | no drivers with CS# high | §3.3 |
| a_no_x | outputs never X | §1 |
| a_rst | reset values | §3.6 |
