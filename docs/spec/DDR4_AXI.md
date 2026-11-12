<!-- SPDX-License-Identifier: Apache-2.0 -->
# DDR4_AXI: design specification

The unchanged `DDR4_top` memory controller (see [DDR4.md](DDR4.md)) behind the AXI4
subordinate front end `ddr_axi_slv`. Each 32-bit AXI word is two 16-bit host operations of the
core. Core `DDR4_AXI_top` (`rtl/DDR4_AXI_top.sv`, uses `rtl/ddr_axi_slv.sv` and `rtl/DDR4_top.sv`),
testbench `tb/DDR4_AXI_tb.sv` (shared body `tb/ddr_axi_tb.svh`). The core's own checker
`tb/cov/DDR4_sva.sv` binds to the core inside.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. *Host* signals are the core's `hvalid` / `hready` / `hcmd` /
`haddr` / `hwdata` / `hrdata` / `hdone` port ([DDR4.md](DDR4.md) §3.1).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `s_awid` | input | 4 | write address ID | - | `clk` | - |
| `s_awaddr` | input | 32 | write address (byte) | - | `clk` | - |
| `s_awlen` | input | 8 | beats - 1 (0 to 255) | - | `clk` | - |
| `s_awsize` | input | 3 | bytes per beat = 2^size; 0 to 2 legal | - | `clk` | - |
| `s_awburst` | input | 2 | 0 FIXED, 1 INCR, 2 WRAP | - | `clk` | - |
| `s_awvalid` | input | 1 | write address valid | high | `clk` | - |
| `s_awready` | output | 1 | write address accepted (§3.1) | high | `clk` | 0 |
| `s_wdata` | input | 32 | write data | - | `clk` | - |
| `s_wstrb` | input | 4 | byte strobes | high | `clk` | - |
| `s_wlast` | input | 1 | last write beat | high | `clk` | - |
| `s_wvalid` | input | 1 | write data valid | high | `clk` | - |
| `s_wready` | output | 1 | write beat accepted | high | `clk` | 0 |
| `s_bid` | output | 4 | = the write's AWID | - | `clk` | 0 |
| `s_bresp` | output | 2 | 0 OKAY, 2 SLVERR | - | `clk` | 0 |
| `s_bvalid` | output | 1 | write response valid | high | `clk` | 0 |
| `s_bready` | input | 1 | write response accepted | high | `clk` | - |
| `s_arid` | input | 4 | read address ID | - | `clk` | - |
| `s_araddr` | input | 32 | read address (byte) | - | `clk` | - |
| `s_arlen` | input | 8 | beats - 1 | - | `clk` | - |
| `s_arsize` | input | 3 | bytes per beat = 2^size; 0 to 2 legal | - | `clk` | - |
| `s_arburst` | input | 2 | 0 FIXED, 1 INCR, 2 WRAP | - | `clk` | - |
| `s_arvalid` | input | 1 | read address valid | high | `clk` | - |
| `s_arready` | output | 1 | read address accepted (§3.1) | high | `clk` | 0 |
| `s_rid` | output | 4 | = the read's ARID | - | `clk` | 0 |
| `s_rdata` | output | 32 | read data | - | `clk` | 0 |
| `s_rresp` | output | 2 | 0 OKAY, 2 SLVERR | - | `clk` | 0 |
| `s_rlast` | output | 1 | last read beat | high | `clk` | 0 |
| `s_rvalid` | output | 1 | read data valid | high | `clk` | 0 |
| `s_rready` | input | 1 | read data accepted | high | `clk` | - |
| `ck_t` | output | 1 | core DRAM clock (see [DDR4.md](DDR4.md)) | - | `clk` | - |
| `ck_c` | output | 1 | core DRAM clock complement | - | `clk` | - |
| `addr` | output | 17 | core pin address (see the core page) | - | `clk` | - |
| `ras_n` | output | 1 | core command pin | low | `clk` | - |
| `cas_n` | output | 1 | core command pin | low | `clk` | - |
| `we_n` | output | 1 | core command pin | low | `clk` | - |
| `dq` | inout | NCH x 16 | core data pins | - | `clk` | high-Z |
| `dqs` | inout | 2 | core data strobe pins | - | `clk` | high-Z |
| `cke` | output | 1 | core clock enable | high | `clk` | - |
| `trace_valid` | output | 1 | core command trace (as the core) | high | `clk` | 0 |
| `trace_cmd` | output | 3 | core command trace (as the core) | - | `clk` | - |
| `trace_addr` | output | 32 | core command trace (as the core) | - | `clk` | - |
| `n_rd` | output | 16 | read bursts completed (wraps) | - | `clk` | 0 |
| `n_wr` | output | 16 | write bursts completed (wraps) | - | `clk` | 0 |
| `n_rmw` | output | 16 | read-modify-writes (wraps) | - | `clk` | 0 |
| `n_err` | output | 16 | SLVERR responses (wraps) | - | `clk` | 0 |
| `err_irq` | output | 1 | one-clock pulse with each SLVERR response handshake | high | `clk` | 0 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/DDR4_AXI.md`](../ip/DDR4_AXI.md) (source: `scripts/apb/specs/DDR4_AXI.json`); do not edit by hand.

`DDR4_AXI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `s_awid`, `s_awaddr`, `s_awlen`, `s_awsize`, `s_awburst`, `s_awvalid`, `s_awready`, `s_wdata`, `s_wstrb`, `s_wlast`, `s_wvalid`, `s_wready`, `s_bid`, `s_bresp`, `s_bvalid`, `s_bready`, `s_arid`, `s_araddr`, `s_arlen`, `s_arsize`, `s_arburst`, `s_arvalid`, `s_arready`, `s_rid`, `s_rdata`, `s_rresp`, `s_rlast`, `s_rvalid`, `s_rready`, `ck_t`, `ck_c`, `addr`, `ras_n`, `cas_n`, `we_n`, `dq`, `dqs`, `cke`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5D040100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | N_RD | RO | core | AXI read bursts completed |
| 0x018 | N_WR | RO | core | AXI write bursts completed (B sent) |
| 0x01C | N_RMW | RO | core | Halfword read-modify-writes (one byte strobe of two) |
| 0x020 | N_ERR | RO | core | SLVERR responses (AxSIZE above 2, misplaced WLAST) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5D04 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| N_RD | 15:0 | `n_rd` | RO | core | wraps at 0xFFFF |
| N_WR | 15:0 | `n_wr` | RO | core | wraps at 0xFFFF |
| N_RMW | 15:0 | `n_rmw` | RO | core | wraps at 0xFFFF |
| N_ERR | 15:0 | `n_err` | RO | core | wraps at 0xFFFF |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | an AXI burst ended with SLVERR |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5D040100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read N_RD (0x014) for the core's live `n_rd`; it needs no clearing.
5. Read N_WR (0x018) for the core's live `n_wr`; it needs no clearing.
6. Read N_RMW (0x01C) for the core's live `n_rmw`; it needs no clearing.
7. Read N_ERR (0x020) for the core's live `n_err`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Transactions

One AXI transaction at a time. While idle, `s_arready` = `s_arvalid` and `s_awready` =
`s_awvalid` (combinationally), except that when both are valid they take turns: the one that did
not get the last turn wins (after reset, AR first). After an accepted AR or AW nothing else is
accepted until its last R beat or its B response has been handshaken.

Burst addresses follow AXI4: FIXED keeps the address, INCR adds 2^size (from the aligned
address), WRAP (len 1, 3, 7, 15) wraps inside the (len + 1) x 2^size window. There is no 4 KB
check.

### 3.2 Address map

Halfword h = {`addr[31:2]`, half} where half = 0 for bits [15:0] and 1 for bits [31:16] of the
word (`addr[1:0]` is ignored). The host address is `haddr` = {h[24:11], 7'b0, h[10:0]}: column
h[7:0], channel h[8], bank h[10:9], row h[24:11]. Storage is the core's: NCH = 1: the channel bit is ignored, so only column h[7:0] selects storage: 256 halfwords (512 bytes) of the AXI space are distinct and everything above aliases.

### 3.3 Read

Per beat: a host RD of the low halfword, its `hrdata` taken the clock after `hdone`, then a host RD
of the high halfword likewise; then the beat is offered (`s_rvalid` = 1, `s_rdata` = {high, low},
`s_rlast` on beat `len`) and held until `s_rready`. Both halfwords are always read, also for
narrow transfers (the manager picks its byte lanes). After the last beat's handshake `n_rd` + 1.

### 3.4 Write

Per beat: `s_wready` = 1 until a W beat is taken. If `s_wlast` differs from (this is beat `len`),
the transaction becomes SLVERR. Then each halfword, low first, by its two strobes:

- both set: one host WR of the halfword;
- none: nothing;
- one: read-modify-write: a host RD (`n_rmw` + 1), then a host WR of the merged halfword (the
  strobed byte from `s_wdata`, the other from the read).

After the last beat's host commands have been taken and the host port is ready again,
`s_bvalid` = 1 until `s_bready`; then `n_wr` + 1.

### 3.5 Errors

SLVERR (`s_rresp` / `s_bresp` = 2) when AxSIZE > 2, or (writes) `s_wlast` on the wrong beat.

- Read with AxSIZE > 2: no host command; `len` + 1 beats are returned with SLVERR and stale
  data.
- Write with AxSIZE > 2: every beat is taken until `s_wlast` and nothing is written.
- Write with a wrong `s_wlast`: the beats before the error were written; from the erroring beat on
  nothing more is written, and beats are taken until `s_wlast` (also past `len`).

At the handshake of an SLVERR B response, or of the last R beat of an SLVERR read, `n_err` + 1
and `err_irq` pulses for one clock.

### 3.6 Reset

`rst_n` low: idle, all AXI valid / ready outputs 0, counters 0, `s_rdata` 0; the core is reset
too ([DDR4.md](DDR4.md)).

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `NCH` | 1 | 1 or 2 | core channels (see the core page); NCH = 2 makes `haddr` channel bit h[8] select storage |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| AR and AW valid together | they alternate |
| narrow read (size 0 / 1) | both halfwords of the word are read; `s_rdata` is the whole word |
| write strobe 0000 | nothing written for that beat |
| one byte strobe of a halfword | read-modify-write of that halfword |
| AxSIZE = 3 | SLVERR, no array change |
| early or missing WLAST | SLVERR; the rest of the beats up to WLAST are not written |
| addresses above the storage size | alias onto the same cells (§3.2) |
| counters | 16 bits, wrap |

## 6. TB check map

Messages are printed by `tb/DDR4_AXI_tb.sv` (shared body `tb/ddr_axi_tb.svh`) as `ERROR: <message>`.
The TB sends random INCR / FIXED / WRAP bursts of 1 to 32 beats, AxSIZE 0 to 2, random strobes and
IDs, random BREADY / RREADY stalls, against a model of the core's halfword array, plus SLVERR
cases (AxSIZE = 3 read and write, early WLAST).

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "BID" | `s_bid` = AWID | §3.1 |
| "BRESP" | OKAY, or SLVERR for an erroring write | §3.5 |
| "RID" | `s_rid` = ARID | §3.1 |
| "RLAST" | `s_rlast` only on the last beat | §3.3 |
| "RRESP" | OKAY, or SLVERR for AxSIZE > 2 | §3.5 |
| "read" | every read beat equals the model (aliasing, strobes, read-modify-write) | §3.2 to §3.4 |
| "N_RD" | `n_rd` = read bursts | §3.3 |
| "N_WR" | `n_wr` = write bursts | §3.4 |
| "N_ERR" | `n_err` = SLVERR responses | §3.5 |
| "no read-modify-write was exercised" | partial strobes cause read-modify-writes (`n_rmw` > 0) | §3.4 |
| "ERR_IRQ pulsed" | one `err_irq` per SLVERR response | §3.5 |
| "timeout" | the whole test ends within 50 ms | §3.1 |

The core's checker assertions (see [DDR4.md](DDR4.md) §6) also run on the core inside. The TB
prints `LAT tb DDR4_AXI R|W <clocks>` per burst (performance report, not a check).
