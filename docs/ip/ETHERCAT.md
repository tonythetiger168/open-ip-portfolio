# EtherCAT slave controller frame processing: on-the-fly datagram execution, 1 KB process RAM, two FMMUs, FCS regeneration

Protocol IP `ETHERCAT`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `ETHERCAT_top` (`rtl/ETHERCAT_top.sv`) |
| Register interface | APB4 slave `ETHERCAT_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0xEC470100 (code 0xEC47, version 1.0) |
| Registers | 10 words, 0x000 to 0x024 |
| Interrupts | 2 sources into one level-high `irq` |
| Data streams | FRAME (from the core) |
| Protocol pins | 4 pass-through |

## Overview

ETHERCAT_top v1.0: EtherCAT slave controller (ESC) frame processing unit: datagrams are executed on the fly as the frame passes from rx to tx

- Byte stream: rx_dv / rx_d carry one octet per clock from the
destination MAC address to the FCS (no preamble); tx_dv / tx_d give the
same frame 5 clocks later. A frame ends when rx_dv falls; the 4 octets
before that are its FCS. The FCS is recomputed over the processed frame
(CRC-32); if the received FCS was wrong, the new one is inverted so the
next station sees the error too. Frames of fewer than 5 octets pass
unchanged.
- EtherCAT frames: EtherType 0x88A4 (octets 12..13), EtherCAT header
(2 octets, little endian: length[10:0], type[15:12]; type 1 =
datagrams). Each datagram: cmd, idx, address (4 octets: ADP, ADO or
a 32-bit logical address), length (2 octets: len[10:0], M[15] = more
datagrams follow), IRQ (2), len data octets, WKC (2). All fields are
little endian. Other frames pass unchanged.
- Commands: 0 NOP; 1..3 APRD / APWR / APRW (addressed when ADP = 0,
ADP + 1 forwarded); 4..6 FPRD / FPWR / FPRW (ADP = station address);
7..9 BRD / BWR / BRW (all; ADP + 1; BRD / BRW read as data OR memory);
10..12 LRD / LWR / LRW (logical, through the FMMUs); 13 ARMW (ADP = 0
reads, the others write; ADP + 1); 14 FRMW (station address reads,
the others write); others act as NOP.
- Working counter: + 1 for a read, + 1 for a write, + 3 for a read /
write (+ 1 read, + 2 write); a physical datagram counts when addressed,
a logical one per kind when at least one of its octets maps.
- Physical memory (ADO + i): 0x0010..0x0011 station address,
0x0600..0x061F FMMU 0 / 1 (16 octets each: logical start 0..3,
length 4..5, physical start 8..9, type 0x0B (bit 0 read, bit 1 write),
activate 0x0C bit 0; the other octets are stored only),
0x1000..0x13FF 1 KB process RAM; other addresses read 0 and ignore
writes. A logical octet maps through the first active FMMU whose
range [start, start + length) holds it (octet granular).
- Writes take effect as the octets pass (no commit on a good FCS).
- Host port: host_rd gives host_rdata the clock after; a host write to
the octet the frame writes in the same clock is dropped.
- fr_done at the end of every frame with fr_fcs_ok, fr_ecat (EtherCAT
datagram frame), fr_dgrams (datagrams processed) and fr_wkc (the sum
of this station's working counter increments, saturating at 255).
- Not implemented: distributed clocks, SyncManagers, AL state machine,
EEPROM / SII, mailbox, bit-granular FMMUs, VLAN tags, port forwarding
(one processing direction).

Features:

- Datagrams executed as the frame passes (5-clock latency): APRD / APWR / APRW, FPRD / FPWR / FPRW, BRD / BWR / BRW, LRD / LWR / LRW, ARMW / FRMW, NOP
- Working counter and ADP increment, BRD / BRW OR of read data, any number of datagrams per frame
- Two octet-granular FMMUs for logical addressing, 1 KB process RAM, station address register
- FCS recomputed over the forwarded frame; a bad received FCS is passed on inverted

rx_dv / rx_d carry the frame from the destination address to the FCS, one octet per PCLK; tx_dv / tx_d forward it. Frames need 5 idle clocks between them.
Not implemented: distributed clocks, SyncManagers, AL state machine, EEPROM / SII, mailbox, bit-granular FMMUs, VLAN tags, multiple ports.

## Files

| File | Content |
|---|---|
| `rtl/ETHERCAT_top.sv` | protocol core |
| `rtl/ETHERCAT_apb.sv` | APB4 register wrapper (generated) |
| `tb/ETHERCAT_tb.sv` | core testbench |
| `tb/ETHERCAT_apb_tb.sv`, `tb/apb/ETHERCAT_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/ETHERCAT_sva.sv`, `tb/cov/ETHERCAT_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/ETHERCAT.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `ETHERCAT_apb`. Widths of the pass-through pins are at the default parameters.

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
| `rx_dv` | input | 1 | protocol pin, core port `rx_dv` |
| `rx_d` | input | 8 | protocol pin, core port `rx_d` |
| `tx_dv` | output | 1 | protocol pin, core port `tx_dv` |
| `tx_d` | output | 8 | protocol pin, core port `tx_d` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rx_dv` | input | 1 | pin (pass-through) |
| `rx_d` | input | 8 | pin (pass-through) |
| `tx_dv` | output | 1 | pin (pass-through) |
| `tx_d` | output | 8 | pin (pass-through) |
| `host_rd` | input | 1 | CMD[1:1] |
| `host_wr` | input | 1 | CMD[0:0] |
| `host_addr` | input | 16 | MEM_ADDR[15:0] |
| `host_wdata` | input | 8 | MEM_WDATA[7:0] |
| `host_rdata` | output | 8 | MEM_RDATA[7:0] |
| `fr_done` | output | 1 | FRAME capture |
| `fr_fcs_ok` | output | 1 | FRAME[0:0] |
| `fr_ecat` | output | 1 | FRAME[1:1] |
| `fr_dgrams` | output | 8 | FRAME[9:2] |
| `fr_wkc` | output | 8 | FRAME[17:10] |

## APB wrapper

`ETHERCAT_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_dv`, `rx_d`, `tx_dv`, `tx_d`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0xEC470100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | MEM_ADDR | RW | 0x00000000 | ESC address for CMD.host_rd / host_wr |
| 0x018 | MEM_WDATA | RW | 0x00000000 | ESC write data |
| 0x01C | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x020 | MEM_RDATA | RO | core | ESC read data |
| 0x024 | FRAME | RO (pop) | 0x00000000 | Frame report, one per forwarded frame; reading it frees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0xEC47 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| MEM_ADDR | 15:0 | `host_addr` | RW | 0x0 | 0x0010..0x0011 station address, 0x0600..0x061F FMMU 0 / 1, 0x1000..0x13FF process RAM |
| MEM_WDATA | 7:0 | `host_wdata` | RW | 0x0 | octet written by CMD.host_wr |
| CMD | 0 | `host_wr` | WO (pulse) | 0x0 | 1 = write MEM_WDATA at MEM_ADDR (dropped if a frame writes the same octet in that clock) |
| CMD | 1 | `host_rd` | WO (pulse) | 0x0 | 1 = read MEM_ADDR into MEM_RDATA |
| MEM_RDATA | 7:0 | `host_rdata` | RO | core | octet read by CMD.host_rd |
| FRAME | 0 | `fr_fcs_ok` | RO (pop) | 0x0 | received FCS correct |
| FRAME | 1 | `fr_ecat` | RO (pop) | 0x0 | EtherCAT datagram frame |
| FRAME | 9:2 | `fr_dgrams` | RO (pop) | 0x0 | datagrams processed (modulo 256) |
| FRAME | 17:10 | `fr_wkc` | RO (pop) | 0x0 | this station's working counter increments, saturating at 255 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FRAME_AVAIL | FRAME captured a beat |
| 1 | FRAME_OVF | beat dropped, FRAME was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | FRAME_AVAIL | FRAME holds an unread beat |

### Streams

* **FRAME** captures `fr_fcs_ok`, `fr_ecat`, `fr_dgrams`, `fr_wkc` when `fr_done` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ FRAME_AVAIL. Reading FRAME pops it. A beat that arrives while the register is full is dropped and sets FRAME_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0xEC470100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write MEM_ADDR (0x014), MEM_WDATA (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `host_wr` (CMD bit 0), `host_rd` (CMD bit 1) at 0x01C; the core sees a one-clock pulse, and the register reads 0.
6. Read MEM_RDATA (0x020) for the core's live `host_rdata`; it needs no clearing.
7. To receive on FRAME: wait for IRQ FRAME_AVAIL or FLAGS.FRAME_AVAIL (bit 0), then read FRAME (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.FRAME_AVAIL (bit 0) to clear it. Read each beat before the next arrives, or it is dropped and FRAME_OVF is set.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write the station address (0x0010..0x0011) and FMMUs (0x0600..) through MEM_ADDR / MEM_WDATA / CMD.host_wr, preload the process RAM the same way.
2. On IRQ FRAME_AVAIL read FRAME for each frame; read process data with CMD.host_rd and MEM_RDATA.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.ETHERCAT sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.ETHERCAT syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/ETHERCAT_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.ETHERCAT apb` | `TEST PASSED: ETHERCAT_apb`, then Yosys without `ERROR` | console, `work/ETHERCAT_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh ETHERCAT`<br>`bash scripts/cov/run_cov.sh ETHERCAT_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/ETHERCAT/score.json`, `work/cov/ETHERCAT_apb/score.json` |

Expected end of a step 4 run:

```
===== ETHERCAT =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/ETHERCAT_tb.sv`): drives `ETHERCAT_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/ETHERCAT_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/ETHERCAT_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/ETHERCAT_sva.sv`, `tb/cov/ETHERCAT_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ETHERCAT_top.sv` | not run | | | | | |
| wrapper `rtl/ETHERCAT_apb.sv` | not run | | | | | |
