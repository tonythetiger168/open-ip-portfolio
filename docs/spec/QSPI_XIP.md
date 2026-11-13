<!-- SPDX-License-Identifier: Apache-2.0 -->
# QSPI_XIP: design specification

A quad-SPI NOR flash host controller with execute-in-place: an AXI4 read window over the flash and
a single-bit command port for flash commands (status, write enable, program, erase, ID). Not
implemented: DTR / octal modes, 4-byte addresses, continuous-read (mode bits) modes, XIP writes,
prefetch, more than one flash. Core `QSPI_XIP_top` (`rtl/QSPI_XIP_top.sv`), testbench
`tb/QSPI_XIP_tb.sv` (with the behavioural flash `tb/spi_nor_model.svh`). There is no SVA checker
for this core.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. SPI mode 0: the controller changes its output after each SCLK fall
(the first bit is set when CS# falls) and samples on each SCLK rise. Bytes go MSB first.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `sclk` | output | 1 | SPI clock, mode 0 (idles low) | - | `clk` | 0 |
| `csn` | output | 1 | flash chip select | low | `clk` | 1 |
| `io` | inout | 4 | IO0 (MOSI), IO1 (MISO), IO2 (WP#), IO3 (HOLD#) | - | `clk` | IO2/3 high |
| `div` | input | 8 | half an SCLK period is `div` + 1 clocks | - | static | - |
| `quad` | input | 1 | XIP uses quad output fast read 0x6B (else 0x0B) | high | static | - |
| `pc_cmd` | input | 8 | command byte | - | `clk` | - |
| `pc_has_addr` | input | 1 | the command carries a 24-bit address | high | `clk` | - |
| `pc_addr` | input | 24 | command address | - | `clk` | - |
| `pc_nwr` | input | 3 | data bytes to write, 0..4 | - | `clk` | - |
| `pc_nrd` | input | 3 | data bytes to read, 0..4 (larger values act as 4) | - | `clk` | - |
| `pc_wdata` | input | 32 | write bytes, byte 0 (sent first) in bits 7:0 | - | `clk` | - |
| `pc_start` | input | 1 | start a command (ignored while busy) | high | `clk` | - |
| `pc_rdata` | output | 32 | read bytes, byte 0 in bits 7:0 (cleared at start) | - | `clk` | 0 |
| `pc_busy` | output | 1 | a command is pending or running | high | `clk` | 0 |
| `pc_done` | output | 1 | one-clock pulse: the command finished | high | `clk` | 0 |
| `xip_cmds` | output | 16 | XIP read commands issued (wrapping) | - | `clk` | 0 |
| `xip_beats` | output | 16 | XIP read beats returned (wrapping) | - | `clk` | 0 |
| `s_awid` | input | 4 | write address channel (writes are refused) | - | `clk` | - |
| `s_awaddr` | input | 32 | write address channel (writes are refused) | - | `clk` | - |
| `s_awlen` | input | 8 | write address channel (writes are refused) | - | `clk` | - |
| `s_awsize` | input | 3 | write address channel (writes are refused) | - | `clk` | - |
| `s_awburst` | input | 2 | write address channel (writes are refused) | - | `clk` | - |
| `s_awvalid` | input | 1 | write address channel (writes are refused) | - | `clk` | - |
| `s_awready` | output | 1 | = `s_awvalid` when no write is in progress; combinational | high | comb | 0 |
| `s_wdata` | input | 32 | write data (discarded) | - | `clk` | - |
| `s_wstrb` | input | 4 | write data (discarded) | - | `clk` | - |
| `s_wlast` | input | 1 | write data (discarded) | - | `clk` | - |
| `s_wvalid` | input | 1 | write data (discarded) | - | `clk` | - |
| `s_wready` | output | 1 | 1 after the write address, until the beat with `s_wlast` | high | `clk` | 0 |
| `s_bid` | output | 4 | write ID | - | `clk` | 0 |
| `s_bresp` | output | 2 | always SLVERR (10) | - | comb | 10 |
| `s_bvalid` | output | 1 | write response | high | `clk` | 0 |
| `s_bready` | input | 1 | response taken | high | `clk` | - |
| `s_arid` | input | 4 | read address channel (flash address = `s_araddr`[23:0]) | - | `clk` | - |
| `s_araddr` | input | 32 | read address channel (flash address = `s_araddr`[23:0]) | - | `clk` | - |
| `s_arlen` | input | 8 | read address channel (flash address = `s_araddr`[23:0]) | - | `clk` | - |
| `s_arsize` | input | 3 | read address channel (flash address = `s_araddr`[23:0]) | - | `clk` | - |
| `s_arburst` | input | 2 | read address channel (flash address = `s_araddr`[23:0]) | - | `clk` | - |
| `s_arvalid` | input | 1 | read address channel (flash address = `s_araddr`[23:0]) | - | `clk` | - |
| `s_arready` | output | 1 | idle, no command pending, and `s_arvalid`; combinational | high | comb | 0 |
| `s_rid` | output | 4 | read ID | - | `clk` | 0 |
| `s_rdata` | output | 32 | the flash word holding the beat address, little endian | - | `clk` | 0 |
| `s_rresp` | output | 2 | always OKAY | - | comb | 00 |
| `s_rlast` | output | 1 | last beat | high | `clk` | 1 |
| `s_rvalid` | output | 1 | read beat valid | high | `clk` | 0 |
| `s_rready` | input | 1 | beat taken | high | `clk` | - |

### Internal signals used by the coverage checker

`tb/cov/QSPI_XIP_sva.sv` is bound to `QSPI_XIP_top` with `.*`, so a re-implementation must have these
names (width as seen by the checker).

| Signal | Width | Meaning |
|---|---|---|
| `pc_job` | 1 | the engine is running the command |
| `s_open` | 1 | the XIP read stream is open (CS low, in P_RD) |
| `w_last_v` | 1 | core-internal signal read by name by the checker |
| `s_next` | [21:0] | next word address of the open stream |
| `w_last_a` | 1 | core-internal signal read by name by the checker |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/QSPI_XIP.md`](../ip/QSPI_XIP.md) (source: `scripts/apb/specs/QSPI_XIP.json`); do not edit by hand.

`QSPI_XIP_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `csn`, `io`, `s_awid`, `s_awaddr`, `s_awlen`, `s_awsize`, `s_awburst`, `s_awvalid`, `s_awready`, `s_wdata`, `s_wstrb`, `s_wlast`, `s_wvalid`, `s_wready`, `s_bid`, `s_bresp`, `s_bvalid`, `s_bready`, `s_arid`, `s_araddr`, `s_arlen`, `s_arsize`, `s_arburst`, `s_arvalid`, `s_arready`, `s_rid`, `s_rdata`, `s_rresp`, `s_rlast`, `s_rvalid`, `s_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C530100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000101 | XIP read mode and SCLK timing |
| 0x018 | PC_CTRL | RW | 0x00000000 | Command port: the next command |
| 0x01C | PC_ADDR | RW | 0x00000000 | Command port: 24-bit flash address |
| 0x020 | PC_WDATA | RW | 0x00000000 | Command port: bytes to send, byte 0 (bits 7:0) first |
| 0x024 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x028 | PC_RDATA | RO | core | Command port: bytes read by the last command, byte 0 in bits 7:0 |
| 0x02C | STATUS | RO | core | State |
| 0x030 | XIP_CMDS | RO | core | XIP read commands issued |
| 0x034 | XIP_BEATS | RO | core | XIP read beats returned |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C53 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 7:0 | `div` | RW | 0x1 | half SCLK period - 1, in clocks |
| CFG | 8 | `quad` | RW | 0x1 | 1: XIP reads with 0x6B, 0: with 0x0B |
| PC_CTRL | 7:0 | `pc_cmd` | RW | 0x0 | command byte |
| PC_CTRL | 8 | `pc_has_addr` | RW | 0x0 | send PC_ADDR after the command |
| PC_CTRL | 11:9 | `pc_nwr` | RW | 0x0 | bytes sent from PC_WDATA (0..4) |
| PC_CTRL | 14:12 | `pc_nrd` | RW | 0x0 | bytes read into PC_RDATA (0..4) |
| PC_ADDR | 23:0 | `pc_addr` | RW | 0x0 | sent MSB first |
| PC_WDATA | 31:0 | `pc_wdata` | RW | 0x0 | data bytes |
| CMD | 0 | `pc_start` | WO (pulse) | 0x0 | run the command in PC_CTRL; ignored while busy |
| PC_RDATA | 31:0 | `pc_rdata` | RO | core | data bytes |
| STATUS | 0 | `pc_busy` | RO | core | a command is pending or running |
| XIP_CMDS | 15:0 | `xip_cmds` | RO | core | wraps at 0xFFFF |
| XIP_BEATS | 15:0 | `xip_beats` | RO | core | wraps at 0xFFFF |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PC_DONE | a command-port command ended |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C530100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014), PC_CTRL (0x018), PC_ADDR (0x01C), PC_WDATA (0x020). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. To issue a command, write 1 to `pc_start` (CMD bit 0) at 0x024; the core sees a one-clock pulse, and the register reads 0.
6. Read PC_RDATA (0x028) for the core's live `pc_rdata`; it needs no clearing.
7. Read STATUS (0x02C) for the core's live `pc_busy`; it needs no clearing.
8. Read XIP_CMDS (0x030) for the core's live `xip_cmds`; it needs no clearing.
9. Read XIP_BEATS (0x034) for the core's live `xip_beats`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CFG (DIV, QUAD for the flash part); XIP reads work from then on.
2. Flash command: PC_ADDR and PC_WDATA if used, PC_CTRL, CMD.pc_start, wait for PC_DONE, read PC_RDATA.
3. Program: 0x06 write enable, then 0x02 with the address and up to 4 bytes, then poll 0x05 status until WIP is 0. Erase: 0x06, then 0x20 with the address.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 SPI engine

A job: CS# low, the command byte on IO0, then optionally a 24-bit address on IO0, dummy clocks,
write bytes on IO0, and read bytes (single: IO1, MSB first; quad: IO3..0, high nibble first). Then
CS# high for `div` + 1 clocks before the next job. IO2 / IO3 are driven high except in the quad
dummy and data phases (where IO3..0 are released); IO0 is released while CS# is high.

### 3.2 XIP reads

A read of the window reads the flash word at `s_araddr`[23:2] with 0x6B (`quad`: address and
command single, 8 dummy clocks, quad data) or 0x0B (8 dummy clocks, single data). Four bytes make a
word, the byte at flash address A in bits 8 x A[1:0] + 7 : 8 x A[1:0]. Every beat returns the word
holding its address (FIXED, INCR and WRAP, any length, `s_arsize` 0..2). `s_rresp` is OKAY.

The read stream stays open after a burst (CS# low, SCLK stopped):

* a beat whose word is the last word read is returned at once;
* a beat (or a new burst) at the next word of the stream continues it without a new command;
* any other address closes CS# and starts a new read command (`xip_cmds` + 1).

SCLK stops at a word boundary while the beat is not taken, so `s_rready` low never loses data.
`xip_beats` counts every R handshake.

### 3.3 Command port

`pc_start` while not busy sets `pc_busy` and clears `pc_rdata`. The command waits for an XIP burst
in progress to finish and closes an open XIP stream; XIP bursts wait while `pc_busy`. The job
sends `pc_cmd`, the address if `pc_has_addr`, `pc_nwr` bytes of `pc_wdata` (byte 0 first), then
reads `pc_nrd` bytes into `pc_rdata` (byte i in bits 8i + 7 : 8i); no dummy clocks. `pc_done`
pulses and `pc_busy` drops after the CS# high time.

### 3.4 AXI writes

Every write is consumed (address, then all W beats until `s_wlast`) and answered with SLVERR.

### 3.5 Reset

While `rst_n` is low: idle, CS# high, SCLK low, stream closed, counters 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| AXI write | SLVERR, no flash access |
| burst not following the open stream | stream closed, new read command |
| `pc_nrd` over 4 | 4 bytes |
| `pc_start` while busy | ignored |
| command while a burst is in progress | waits for the burst |
| R held off | SCLK stops, no data lost |

## 6. TB check map

Messages are printed by `tb/QSPI_XIP_tb.sv` as `ERROR: <message>`. The TB runs 400 random bursts
in both modes at several `div` values against a flash model (which checks IO contention and
command legality), the command port flows and AXI writes.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "RID" | read ID | §3.2 |
| "RLAST on beat" | RLAST on the last beat | §3.2 |
| "RRESP" | OKAY | §3.2 |
| "XIP" | each beat's word | §3.2 |
| "command" | command port read data | §3.3 |
| "XIP_CMDS" | stream reuse | §3.2 |
| "XIP_BEATS" | beat count | §3.2 |
| "JEDEC ID" | 0x9F through the command port | §3.3 |
| "WEL low after write enable" | write enable | §3.3 |
| "page program did not AND the bytes in" | page program | §3.3 |
| "WEL high after page program" | flash state after program | §3.3 |
| "sector not erased" | sector erase | §3.3 |
| "AXI write not SLVERR" | writes refused | §3.4 |
| "timeout" | operations finish | §3 |

### Coverage-closure assertions

From `tb/cov/QSPI_XIP_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_reset_idle | while `!rst_n` (reset): `csn && !sclk && !pc_busy && !s_rvalid && !s_bvalid && xip_cmds == 0 && xip_beats == 0` | §3 |
| a_cmd | whenever `rise && k == n_cmd_end`: `d_cmd == f_cmd_exp` | §3 |
| a_addr | whenever `rise && k == n_addr_end && n_addr_end != n_cmd_end`: `d_addr == f_addr_exp` | §3 |
| a_wdata | whenever `rise && k == n_wr_end && n_wr_end != n_dmy_end`: `d_wr == (f_nwr == 1 ? 32'(f_wdata[7:0]) : f_nwr == 2 ? 32'({f_wdata[7:0], f_wdata[15:8]}) : f_nwr == 3 ? 32'({f_wdata[7:0], f_wdata[15:8], f_wdata[23:16]}) : {f_wdata[7:0], f_wdata[15:8], f_wdata[23:16], f_wdata[31:24]})` | §3 |
| a_pc_len | whenever `$rose(csn) && f_pc`: `k == n_wr_end + 8 * f_nrd` | §3 |
| a_pc_rdata | whenever `pc_done`: `pc_rdata == d_pc` | §3 |
| a_xip_rdata | whenever `s_rvalid`: `w_map.exists(a_q[23:2]) && s_rdata == w_map[a_q[23:2]] && s_rresp == 2'b00 && s_rlast == (b_n == b_len)` | §3 |
| a_half_period | whenever `sclk != sclk_q`: `m_hc >= div` | §3 |
| a_mode0 | always holds: `(csn != csn_q) -> !sclk` | §3 |
| a_wp_hold_high | always holds: `!in_quad -> io[3:2] == 2'b11` | §3 |
| a_counters | always holds: `$past(xip_cmds) == m_cmds && xip_beats == m_beats` | §3 |
| a_pc_busy | always holds: `pc_busy -> !(s_arready)` | §3 |
| a_axi_write | whenever `s_bvalid`: `s_bresp == 2'b10` | §3 |

### Further TB checks

| Check (TB message) | What it requires | Spec |
|---|---|---|
| "AXI write: BRESP" | fails when `s_bresp !== 2'b10 \|\| s_bid !== id` (`tb/QSPI_XIP_tb.sv` line 130) | §3 |
| "read command" | see `tb/QSPI_XIP_tb.sv` | §3 |
| "JEDEC ID with PC_NRD" | fails when `pc_rdata[23:0] !== 24'h18_40EF` (`tb/QSPI_XIP_tb.sv` line 204) | §3 |
| "not idle in reset" | fails when `!csn \|\| s_rvalid \|\| xip_cmds != 0` (`tb/QSPI_XIP_tb.sv` line 251) | §3 |
