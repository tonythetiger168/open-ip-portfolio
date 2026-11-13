# Memory firewall: 4 address regions with read / write / secure-only permission on an AXI4 path

Protocol IP `Mem_Firewall`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Mem_Firewall_top` (`rtl/Mem_Firewall_top.sv`) |
| Register interface | APB4 slave `Mem_Firewall_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C070100 (code 0x7C07, version 1.0) |
| Registers | 22 words, 0x000 to 0x054 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 62 pass-through |

## Overview

Mem_Firewall: DRAM access firewall of the TV SoC (secure video path), placed between an initiator and the memory: AXI4 subordinate in (s_*), AXI4 manager out (m_*), APB4 registers

- Four regions n = 0..3: RGNn_BASE, RGNn_LIMIT (byte addresses, the region
is BASE..LIMIT inclusive) and RGNn_ATTR {secure_only, write, read, en}.
- A burst covers addr .. addr + (AxLEN + 1) * 2^AxSIZE - 1 (INCR; FIXED
covers one beat; WRAP its aligned container). It is allowed when one
enabled region contains all of it, grants the access (read / write) and,
for a secure_only region, AxPROT[1] = 0 (secure access).
- An allowed burst passes through unchanged (one read and one write burst
in flight at a time; W and R / B flow straight through). A denied burst
never reaches m_*: a write takes all its W beats and answers DECERR on B,
a read answers AxLEN + 1 beats of zero data with DECERR and RLAST.
- The first denied burst is recorded: FAULT {id[3:0], ns, perm, write,
valid} and FAULT_ADDR; FAULT pulses on every denied burst, DENIED_CNT
counts them (saturating). CMD.fault_clr empties the record.
- ENABLE 0: everything passes (no checks).

Features:

- Sits between an AXI4 manager (s_*) and memory (m_*); each burst is checked against 4 regions [RGNn_BASE, RGNn_LIMIT] with RGNn_ATTR {secure_only, write, read, enable}.
- A burst is allowed when its whole footprint (WRAP: the wrap container) lies in one enabled region that allows the access; secure_only regions need AxPROT[1] = 0.
- Denied bursts never reach m_*: writes get a DECERR B after their data, reads DECERR beats with zero data. The first fault is held in FAULT_INFO / FAULT_ADDR until FAULT_CLR.
- CTRL.enable 0: everything passes.

s_* is an AXI4 subordinate port and m_* an AXI4 manager port (32-bit address and data, 4-bit ID); both pass through the wrapper unchanged. Allowed bursts are forwarded unchanged, one read and one write at a time.

## Files

| File | Content |
|---|---|
| `rtl/Mem_Firewall_top.sv` | protocol core |
| `rtl/Mem_Firewall_apb.sv` | APB4 register wrapper (generated) |
| `tb/Mem_Firewall_tb.sv` | core testbench |
| `tb/Mem_Firewall_apb_tb.sv`, `tb/apb/Mem_Firewall_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Mem_Firewall_sva.sv`, `tb/cov/Mem_Firewall_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Mem_Firewall.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `Mem_Firewall_apb`. Widths of the pass-through pins are at the default parameters.

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
| `s_awid` | input | 4 | protocol pin, core port `s_awid` |
| `s_awaddr` | input | 32 | protocol pin, core port `s_awaddr` |
| `s_awlen` | input | 8 | protocol pin, core port `s_awlen` |
| `s_awsize` | input | 3 | protocol pin, core port `s_awsize` |
| `s_awburst` | input | 2 | protocol pin, core port `s_awburst` |
| `s_awprot` | input | 3 | protocol pin, core port `s_awprot` |
| `s_awvalid` | input | 1 | protocol pin, core port `s_awvalid` |
| `s_awready` | output | 1 | protocol pin, core port `s_awready` |
| `s_wdata` | input | 32 | protocol pin, core port `s_wdata` |
| `s_wstrb` | input | 4 | protocol pin, core port `s_wstrb` |
| `s_wlast` | input | 1 | protocol pin, core port `s_wlast` |
| `s_wvalid` | input | 1 | protocol pin, core port `s_wvalid` |
| `s_wready` | output | 1 | protocol pin, core port `s_wready` |
| `s_bid` | output | 4 | protocol pin, core port `s_bid` |
| `s_bresp` | output | 2 | protocol pin, core port `s_bresp` |
| `s_bvalid` | output | 1 | protocol pin, core port `s_bvalid` |
| `s_bready` | input | 1 | protocol pin, core port `s_bready` |
| `s_arid` | input | 4 | protocol pin, core port `s_arid` |
| `s_araddr` | input | 32 | protocol pin, core port `s_araddr` |
| `s_arlen` | input | 8 | protocol pin, core port `s_arlen` |
| `s_arsize` | input | 3 | protocol pin, core port `s_arsize` |
| `s_arburst` | input | 2 | protocol pin, core port `s_arburst` |
| `s_arprot` | input | 3 | protocol pin, core port `s_arprot` |
| `s_arvalid` | input | 1 | protocol pin, core port `s_arvalid` |
| `s_arready` | output | 1 | protocol pin, core port `s_arready` |
| `s_rid` | output | 4 | protocol pin, core port `s_rid` |
| `s_rdata` | output | 32 | protocol pin, core port `s_rdata` |
| `s_rresp` | output | 2 | protocol pin, core port `s_rresp` |
| `s_rlast` | output | 1 | protocol pin, core port `s_rlast` |
| `s_rvalid` | output | 1 | protocol pin, core port `s_rvalid` |
| `s_rready` | input | 1 | protocol pin, core port `s_rready` |
| `m_awid` | output | 4 | protocol pin, core port `m_awid` |
| `m_awaddr` | output | 32 | protocol pin, core port `m_awaddr` |
| `m_awlen` | output | 8 | protocol pin, core port `m_awlen` |
| `m_awsize` | output | 3 | protocol pin, core port `m_awsize` |
| `m_awburst` | output | 2 | protocol pin, core port `m_awburst` |
| `m_awprot` | output | 3 | protocol pin, core port `m_awprot` |
| `m_awvalid` | output | 1 | protocol pin, core port `m_awvalid` |
| `m_awready` | input | 1 | protocol pin, core port `m_awready` |
| `m_wdata` | output | 32 | protocol pin, core port `m_wdata` |
| `m_wstrb` | output | 4 | protocol pin, core port `m_wstrb` |
| `m_wlast` | output | 1 | protocol pin, core port `m_wlast` |
| `m_wvalid` | output | 1 | protocol pin, core port `m_wvalid` |
| `m_wready` | input | 1 | protocol pin, core port `m_wready` |
| `m_bid` | input | 4 | protocol pin, core port `m_bid` |
| `m_bresp` | input | 2 | protocol pin, core port `m_bresp` |
| `m_bvalid` | input | 1 | protocol pin, core port `m_bvalid` |
| `m_bready` | output | 1 | protocol pin, core port `m_bready` |
| `m_arid` | output | 4 | protocol pin, core port `m_arid` |
| `m_araddr` | output | 32 | protocol pin, core port `m_araddr` |
| `m_arlen` | output | 8 | protocol pin, core port `m_arlen` |
| `m_arsize` | output | 3 | protocol pin, core port `m_arsize` |
| `m_arburst` | output | 2 | protocol pin, core port `m_arburst` |
| `m_arprot` | output | 3 | protocol pin, core port `m_arprot` |
| `m_arvalid` | output | 1 | protocol pin, core port `m_arvalid` |
| `m_arready` | input | 1 | protocol pin, core port `m_arready` |
| `m_rid` | input | 4 | protocol pin, core port `m_rid` |
| `m_rdata` | input | 32 | protocol pin, core port `m_rdata` |
| `m_rresp` | input | 2 | protocol pin, core port `m_rresp` |
| `m_rlast` | input | 1 | protocol pin, core port `m_rlast` |
| `m_rvalid` | input | 1 | protocol pin, core port `m_rvalid` |
| `m_rready` | output | 1 | protocol pin, core port `m_rready` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `enable` | input | 1 | CTRL |
| `rgn0_base` | input | 32 | RGN0_BASE[31:0] |
| `rgn0_limit` | input | 32 | RGN0_LIMIT[31:0] |
| `rgn0_attr` | input | 4 | RGN0_ATTR[3:0] |
| `rgn1_base` | input | 32 | RGN1_BASE[31:0] |
| `rgn1_limit` | input | 32 | RGN1_LIMIT[31:0] |
| `rgn1_attr` | input | 4 | RGN1_ATTR[3:0] |
| `rgn2_base` | input | 32 | RGN2_BASE[31:0] |
| `rgn2_limit` | input | 32 | RGN2_LIMIT[31:0] |
| `rgn2_attr` | input | 4 | RGN2_ATTR[3:0] |
| `rgn3_base` | input | 32 | RGN3_BASE[31:0] |
| `rgn3_limit` | input | 32 | RGN3_LIMIT[31:0] |
| `rgn3_attr` | input | 4 | RGN3_ATTR[3:0] |
| `fault_clr` | input | 1 | CMD |
| `fault_info` | output | 8 | FAULT_INFO[7:0] |
| `fault_addr` | output | 32 | FAULT_ADDR[31:0] |
| `denied_cnt` | output | 16 | DENIED[15:0] |
| `fault` | output | 1 | IRQ_STATUS.FAULT |
| `s_awid` | input | 4 | pin (pass-through) |
| `s_awaddr` | input | 32 | pin (pass-through) |
| `s_awlen` | input | 8 | pin (pass-through) |
| `s_awsize` | input | 3 | pin (pass-through) |
| `s_awburst` | input | 2 | pin (pass-through) |
| `s_awprot` | input | 3 | pin (pass-through) |
| `s_awvalid` | input | 1 | pin (pass-through) |
| `s_awready` | output | 1 | pin (pass-through) |
| `s_wdata` | input | 32 | pin (pass-through) |
| `s_wstrb` | input | 4 | pin (pass-through) |
| `s_wlast` | input | 1 | pin (pass-through) |
| `s_wvalid` | input | 1 | pin (pass-through) |
| `s_wready` | output | 1 | pin (pass-through) |
| `s_bid` | output | 4 | pin (pass-through) |
| `s_bresp` | output | 2 | pin (pass-through) |
| `s_bvalid` | output | 1 | pin (pass-through) |
| `s_bready` | input | 1 | pin (pass-through) |
| `s_arid` | input | 4 | pin (pass-through) |
| `s_araddr` | input | 32 | pin (pass-through) |
| `s_arlen` | input | 8 | pin (pass-through) |
| `s_arsize` | input | 3 | pin (pass-through) |
| `s_arburst` | input | 2 | pin (pass-through) |
| `s_arprot` | input | 3 | pin (pass-through) |
| `s_arvalid` | input | 1 | pin (pass-through) |
| `s_arready` | output | 1 | pin (pass-through) |
| `s_rid` | output | 4 | pin (pass-through) |
| `s_rdata` | output | 32 | pin (pass-through) |
| `s_rresp` | output | 2 | pin (pass-through) |
| `s_rlast` | output | 1 | pin (pass-through) |
| `s_rvalid` | output | 1 | pin (pass-through) |
| `s_rready` | input | 1 | pin (pass-through) |
| `m_awid` | output | 4 | pin (pass-through) |
| `m_awaddr` | output | 32 | pin (pass-through) |
| `m_awlen` | output | 8 | pin (pass-through) |
| `m_awsize` | output | 3 | pin (pass-through) |
| `m_awburst` | output | 2 | pin (pass-through) |
| `m_awprot` | output | 3 | pin (pass-through) |
| `m_awvalid` | output | 1 | pin (pass-through) |
| `m_awready` | input | 1 | pin (pass-through) |
| `m_wdata` | output | 32 | pin (pass-through) |
| `m_wstrb` | output | 4 | pin (pass-through) |
| `m_wlast` | output | 1 | pin (pass-through) |
| `m_wvalid` | output | 1 | pin (pass-through) |
| `m_wready` | input | 1 | pin (pass-through) |
| `m_bid` | input | 4 | pin (pass-through) |
| `m_bresp` | input | 2 | pin (pass-through) |
| `m_bvalid` | input | 1 | pin (pass-through) |
| `m_bready` | output | 1 | pin (pass-through) |
| `m_arid` | output | 4 | pin (pass-through) |
| `m_araddr` | output | 32 | pin (pass-through) |
| `m_arlen` | output | 8 | pin (pass-through) |
| `m_arsize` | output | 3 | pin (pass-through) |
| `m_arburst` | output | 2 | pin (pass-through) |
| `m_arprot` | output | 3 | pin (pass-through) |
| `m_arvalid` | output | 1 | pin (pass-through) |
| `m_arready` | input | 1 | pin (pass-through) |
| `m_rid` | input | 4 | pin (pass-through) |
| `m_rdata` | input | 32 | pin (pass-through) |
| `m_rresp` | input | 2 | pin (pass-through) |
| `m_rlast` | input | 1 | pin (pass-through) |
| `m_rvalid` | input | 1 | pin (pass-through) |
| `m_rready` | output | 1 | pin (pass-through) |

## APB wrapper

`Mem_Firewall_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `s_awid`, `s_awaddr`, `s_awlen`, `s_awsize`, `s_awburst`, `s_awprot`, `s_awvalid`, `s_awready`, `s_wdata`, `s_wstrb`, `s_wlast`, `s_wvalid`, `s_wready`, `s_bid`, `s_bresp`, `s_bvalid`, `s_bready`, `s_arid`, `s_araddr`, `s_arlen`, `s_arsize`, `s_arburst`, `s_arprot`, `s_arvalid`, `s_arready`, `s_rid`, `s_rdata`, `s_rresp`, `s_rlast`, `s_rvalid`, `s_rready`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C070100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Enable |
| 0x018 | RGN0_BASE | RW | 0x00000000 | Region 0 base |
| 0x01C | RGN0_LIMIT | RW | 0x00000000 | Region 0 limit |
| 0x020 | RGN0_ATTR | RW | 0x00000000 | Region 0 permissions |
| 0x024 | RGN1_BASE | RW | 0x00000000 | Region 1 base |
| 0x028 | RGN1_LIMIT | RW | 0x00000000 | Region 1 limit |
| 0x02C | RGN1_ATTR | RW | 0x00000000 | Region 1 permissions |
| 0x030 | RGN2_BASE | RW | 0x00000000 | Region 2 base |
| 0x034 | RGN2_LIMIT | RW | 0x00000000 | Region 2 limit |
| 0x038 | RGN2_ATTR | RW | 0x00000000 | Region 2 permissions |
| 0x03C | RGN3_BASE | RW | 0x00000000 | Region 3 base |
| 0x040 | RGN3_LIMIT | RW | 0x00000000 | Region 3 limit |
| 0x044 | RGN3_ATTR | RW | 0x00000000 | Region 3 permissions |
| 0x048 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x04C | FAULT_INFO | RO | core | First fault |
| 0x050 | FAULT_ADDR | RO | core | First fault address |
| 0x054 | DENIED | RO | core | Denied bursts |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x058 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C07 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `enable` | RW | 0x0 | check bursts |
| RGN0_BASE | 31:0 | `rgn0_base` | RW | 0x0 | first byte |
| RGN0_LIMIT | 31:0 | `rgn0_limit` | RW | 0x0 | last byte |
| RGN0_ATTR | 3:0 | `rgn0_attr` | RW | 0x0 | {secure_only, write, read, enable} |
| RGN1_BASE | 31:0 | `rgn1_base` | RW | 0x0 | first byte |
| RGN1_LIMIT | 31:0 | `rgn1_limit` | RW | 0x0 | last byte |
| RGN1_ATTR | 3:0 | `rgn1_attr` | RW | 0x0 | {secure_only, write, read, enable} |
| RGN2_BASE | 31:0 | `rgn2_base` | RW | 0x0 | first byte |
| RGN2_LIMIT | 31:0 | `rgn2_limit` | RW | 0x0 | last byte |
| RGN2_ATTR | 3:0 | `rgn2_attr` | RW | 0x0 | {secure_only, write, read, enable} |
| RGN3_BASE | 31:0 | `rgn3_base` | RW | 0x0 | first byte |
| RGN3_LIMIT | 31:0 | `rgn3_limit` | RW | 0x0 | last byte |
| RGN3_ATTR | 3:0 | `rgn3_attr` | RW | 0x0 | {secure_only, write, read, enable} |
| CMD | 0 | `fault_clr` | WO (pulse) | 0x0 | clear the held fault |
| FAULT_INFO | 7:0 | `fault_info` | RO | core | {id[3:0], non-secure, permission, write, valid} |
| FAULT_ADDR | 31:0 | `fault_addr` | RO | core | AxADDR of the first denied burst |
| DENIED | 15:0 | `denied_cnt` | RO | core | bursts denied since reset |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FAULT | a burst was denied |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C070100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), RGN0_BASE (0x018), RGN0_LIMIT (0x01C), RGN0_ATTR (0x020), RGN1_BASE (0x024), RGN1_LIMIT (0x028), RGN1_ATTR (0x02C), RGN2_BASE (0x030), RGN2_LIMIT (0x034), RGN2_ATTR (0x038), RGN3_BASE (0x03C), RGN3_LIMIT (0x040), RGN3_ATTR (0x044). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. To issue a command, write 1 to `fault_clr` (CMD bit 0) at 0x048; the core sees a one-clock pulse, and the register reads 0.
6. Read FAULT_INFO (0x04C) for the core's live `fault_info`; it needs no clearing.
7. Read FAULT_ADDR (0x050) for the core's live `fault_addr`; it needs no clearing.
8. Read DENIED (0x054) for the core's live `denied_cnt`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write RGNn_BASE / RGNn_LIMIT / RGNn_ATTR for the regions in use.
2. Write CTRL.enable = 1 and IRQ_ENABLE with FAULT.
3. On FAULT read FAULT_INFO / FAULT_ADDR, then CMD.fault_clr and IRQ_STATUS.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Mem_Firewall sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Mem_Firewall syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Mem_Firewall_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Mem_Firewall apb` | `TEST PASSED: Mem_Firewall_apb`, then Yosys without `ERROR` | console, `work/Mem_Firewall_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Mem_Firewall`<br>`bash scripts/cov/run_cov.sh Mem_Firewall_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Mem_Firewall/score.json`, `work/cov/Mem_Firewall_apb/score.json` |

Expected end of a step 4 run:

```
===== Mem_Firewall =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Mem_Firewall_tb.sv`): drives `Mem_Firewall_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Mem_Firewall_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Mem_Firewall_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Mem_Firewall_sva.sv`, `tb/cov/Mem_Firewall_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Mem_Firewall_top.sv` | not run | | | | | |
| wrapper `rtl/Mem_Firewall_apb.sv` | not run | | | | | |
