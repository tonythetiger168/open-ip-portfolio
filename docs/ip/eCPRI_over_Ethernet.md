# eCPRI over Ethernet node: 64-byte Ethernet frames with FCS, address and Ethertype filter, eCPRI IQ data into a 32-word buffer with seq_id gap tracking, generic memory transfer against a 64 x 32-bit memory, remote reset, event indication with fault / sync acks, and CPU fault injection

Protocol IP `eCPRI_over_Ethernet`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `eCPRI_over_Ethernet_top` (`rtl/eCPRI_over_Ethernet_top.sv`) |
| Register interface | APB4 slave `eCPRI_over_Ethernet_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x65430200 (code 0x6543, version 2.0) |
| Registers | 18 words, 0x000 to 0x044 |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CORE (13 words) |
| Protocol pins | 5 pass-through |

## Overview

eCPRI over Ethernet -- eCPRI message layer slice (node side)

- Ethernet frame parse/generate: DMAC + SMAC + Ethertype 0xAEFE +
payload + FCS (CRC-32/ISO-HDLC reflected, init/xorout 0xFFFFFFFF,
FCS sent LSB-byte first; rx residue check == 0xDEBB20E3).
Preamble/SFD/IFG are handled by the external MAC (byte stream i/f).
- Every frame is a minimum-size (64 byte) Ethernet frame: an eCPRI
payload is at most 40 bytes, so TX zero-pads to 60 bytes + FCS and RX
requires exactly 64 bytes. tx_en drops for at least one cycle between
frames.
- RX address filter: DMAC must be the node's own MAC (cfg_smac) or
broadcast; other frames and non-0xAEFE frames are dropped silently.
- eCPRI common header {rev[4]=1,rsvd[3],c[1], msgtype[8], payload_size[16]}
- msgtype 0: IQ data -- pc_id[16] + seq_id[16] + IQ bytes (<=32B, must be
a multiple of 4) packed big-endian into a 32x32 IQ buffer (cpu pop);
seq_id gap tracking per link
- msgtype 4: generic memory transfer -- remote_addr[32] + rw[8]
(1=write + data[32], 0=read) against a 64x32 memory (byte address,
word aligned, < 256); read triggers a response frame (rw=2)
- msgtype 5: remote reset -- reset_id[16] + op[8] (1=request, plus
optional vendor bytes); drives reset_op and answers op=2 (response)
- msgtype 6: event indication -- event_id + type + seq + n_elem and
n_elem x 8-byte elements (payload_size == 4 + 8*n_elem, n_elem <= 4).
type 0 (fault) is answered with type 1 (fault ack), type 3 (sync
request) with type 4 (sync ack); type 1 matching the last injected
fault clears ack_wait; types 2/4/5 are recorded only.
- cpu fault injection queues a fault indication frame (one element,
element id 0xFFFF, raise/cease + 12-bit fault number, own seq).
- rx_smac (cpu regs 10/11) holds the source MAC of the last accepted
message.
- errors (sticky irq): bad FCS; bad length / revision / payload shape;
concatenated message (c=1); unsupported msgtype; IQ buffer or TX
queue overflow and injection while one is still pending.

rx_d / rx_dv (received frame bytes), tx_d / tx_en (transmitted frame bytes) and reset_op pass through unchanged. Preamble, SFD and IFG belong to the external MAC.
The core's CPU port is mapped one word per register; a write with PSTRB != 4'hF to a writable word is dropped with PSLVERR.

## Files

| File | Content |
|---|---|
| `rtl/eCPRI_over_Ethernet_top.sv` | protocol core |
| `rtl/eCPRI_over_Ethernet_apb.sv` | APB4 register wrapper (generated) |
| `tb/eCPRI_over_Ethernet_tb.sv` | core testbench |
| `tb/eCPRI_over_Ethernet_apb_tb.sv`, `tb/apb/eCPRI_over_Ethernet_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/eCPRI_over_Ethernet_sva.sv`, `tb/cov/eCPRI_over_Ethernet_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/eCPRI_over_Ethernet.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `eCPRI_over_Ethernet_apb`. Widths of the pass-through pins are at the default parameters.

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
| `rx_d` | input | 8 | protocol pin, core port `rx_d` |
| `rx_dv` | input | 1 | protocol pin, core port `rx_dv` |
| `tx_d` | output | 8 | protocol pin, core port `tx_d` |
| `tx_en` | output | 1 | protocol pin, core port `tx_en` |
| `reset_op` | output | 16 | protocol pin, core port `reset_op` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rx_d` | input | 8 | pin (pass-through) |
| `rx_dv` | input | 1 | pin (pass-through) |
| `tx_d` | output | 8 | pin (pass-through) |
| `tx_en` | output | 1 | pin (pass-through) |
| `reset_op` | output | 16 | pin (pass-through) |
| `cpu_we` | input | 1 | write to a CORE word |
| `cpu_re` | input | 1 | read of a CORE word |
| `cpu_addr` | input | 4 | CORE word index |
| `cpu_wdata` | input | 32 | CORE write data |
| `cpu_rdata` | output | 32 | CORE read data |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`eCPRI_over_Ethernet_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_d`, `rx_dv`, `tx_d`, `tx_en`, `reset_op`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x65430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | DMAC_LO | RW (core) | core | peer MAC [31:0] (DMAC of transmitted frames); reset 0xCCDDEEFF |
| 0x018 | DMAC_HI | RW (core) | core | [15:0] peer MAC [47:32]; reset 0xAABB |
| 0x01C | SMAC_LO | RW (core) | core | own MAC [31:0] (SMAC of transmitted frames, RX address filter); reset 0x33445566 |
| 0x020 | SMAC_HI | RW (core) | core | [15:0] own MAC [47:32]; reset 0x1122 |
| 0x024 | IQ | RO (core) | core | IQ buffer head (32 x 32-bit, big-endian packed IQ bytes); the read pops it |
| 0x028 | COUNTS | RO (core) | core | {rx error count[7:0], rx ok count[7:0], seq_id gap count[7:0], 2'b0, IQ words[5:0]} |
| 0x02C | IQ_LAST | RO (core) | core | {pc_id[15:0], seq_id[15:0]} of the last IQ message |
| 0x030 | EVENT | RW (core) | core | write: inject a fault indication {raise[20], fault number[19:8], event_id[7:0]}; read: last recorded event {8'h0, seq[7:0], 5'h0, type[2:0], event_id[7:0]} |
| 0x034 | ERRORS | RW (core) | core | {concat, overflow, malformed, msgtype, fcs} error flags (sticky, write 1 to clear; a new error in the same clock wins) |
| 0x038 | RESET_OP | RW (core) | core | [15:0] reset_id of the last remote reset request (also the reset_op pin); write bit 0 = 1 to clear |
| 0x03C | RX_SMAC_LO | RO (core) | core | source MAC [31:0] of the last accepted message |
| 0x040 | RX_SMAC_HI | RO (core) | core | [15:0] source MAC [47:32] of the last accepted message |
| 0x044 | TX_STATUS | RO (core) | core | {14'h0, ack_wait, injection pending, tx seq[7:0], 5'h0, TX queue count[2:0]} |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x048 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6543 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| DMAC_LO | 31:0 | core register | RW (core) | core | written at core register 0 and read from core register 0 |
| DMAC_HI | 31:0 | core register | RW (core) | core | written at core register 1 and read from core register 1 |
| SMAC_LO | 31:0 | core register | RW (core) | core | written at core register 2 and read from core register 2 |
| SMAC_HI | 31:0 | core register | RW (core) | core | written at core register 3 and read from core register 3 |
| IQ | 31:0 | core register | RO (core) | core | read from core register 4 |
| COUNTS | 31:0 | core register | RO (core) | core | read from core register 5 |
| IQ_LAST | 31:0 | core register | RO (core) | core | read from core register 6 |
| EVENT | 31:0 | core register | RW (core) | core | written at core register 7 and read from core register 7 |
| ERRORS | 31:0 | core register | RW (core) | core | written at core register 8 and read from core register 8 |
| RESET_OP | 31:0 | core register | RW (core) | core | written at core register 9 and read from core register 9 |
| RX_SMAC_LO | 31:0 | core register | RO (core) | core | read from core register 10 |
| RX_SMAC_HI | 31:0 | core register | RO (core) | core | read from core register 11 |
| TX_STATUS | 31:0 | core register | RO (core) | core | read from core register 12 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | any ERRORS flag is set (FCS, msgtype, malformed message, IQ buffer / TX queue overflow, concatenation); held until ERRORS is cleared, so the bit is set again on every clock until then |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `cpu_we` for one clock with `cpu_addr` (the core register) and `cpu_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `cpu_addr` (the core register) and pulses `cpu_re` during the access phase and returns `cpu_rdata`.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x65430200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.eCPRI_over_Ethernet sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.eCPRI_over_Ethernet syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/eCPRI_over_Ethernet_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.eCPRI_over_Ethernet apb` | `TEST PASSED: eCPRI_over_Ethernet_apb`, then Yosys without `ERROR` | console, `work/eCPRI_over_Ethernet_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh eCPRI_over_Ethernet`<br>`bash scripts/cov/run_cov.sh eCPRI_over_Ethernet_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/eCPRI_over_Ethernet/score.json`, `work/cov/eCPRI_over_Ethernet_apb/score.json` |

Expected end of a step 4 run:

```
===== eCPRI_over_Ethernet =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/eCPRI_over_Ethernet_tb.sv`): drives `eCPRI_over_Ethernet_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/eCPRI_over_Ethernet_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/eCPRI_over_Ethernet_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/eCPRI_over_Ethernet_sva.sv`, `tb/cov/eCPRI_over_Ethernet_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/eCPRI_over_Ethernet_top.sv` | pass | 217/217 | 1986/1986 | 8/8 | 6/6 | 87/87 |
| wrapper `rtl/eCPRI_over_Ethernet_apb.sv` | pass | 32/32 | 618/618 | n/a | 11/11 | 50/50 |
