# IO-Link (IEC 61131-9 SDCI) master port or device data link layer: wake-up, M-sequences with PD / OD, checksums, 256-byte message buffer

Protocol IP `IO_LINK`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `IO_LINK_top` (`rtl/IO_LINK_top.sv`) |
| Register interface | APB4 slave `IO_LINK_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x10C90100 (code 0x10C9, version 1.0) |
| Registers | 15 words, 0x000 to 0x038 |
| Interrupts | 4 sources into one level-high `irq` |
| Data streams | D_MSG (from the core) |
| Protocol pins | 3 pass-through |

## Overview

IO_LINK_top v1.0: IO-Link (IEC 61131-9 / SDCI) master port and device data link layer, selected by cfg_master

- Physical layer side: txd / tx_en drive the C/Q transceiver, rxd is the
received line (UART level: 1 idle). The line is only read while tx_en
is low, so the own transmission is never received.
- UART: start bit, 8 data bits LSB first, even parity, one stop bit;
cfg_bit clocks per bit (COM1 4.8, COM2 38.4, COM3 230.4 kbit/s).
The receiver samples in the middle of each bit.
- Wake-up request (WURQ): the master drives the line low for cfg_wurq
clocks (80 us); a device accepts a low pulse of cfg_wurq +- 1/16
(75..85 us) and pulses d_wurq. The break octet it causes is dropped.
- M-sequence, master to device: MC {R/W (1 read), channel (0 process,
1 page, 2 diagnosis, 3 ISDU), address}, CKT {M-sequence type
cfg_mtype, checksum}, cfg_pdout_len PD octets, and on a write
cfg_od_len OD octets. Device to master: on a read cfg_od_len OD
octets, cfg_pdin_len PD octets, then CKS {event flag, PD invalid,
checksum}. Lengths are 0..32 (larger values act as 32).
- Checksum: the XOR of 0x52 and every octet of the message (its own
6 checksum bits 0), compressed to 6 bits:
c5 = x7^x5^x3^x1, c4 = x6^x4^x2^x0, c3 = x7^x6, c2 = x5^x4,
c1 = x3^x2, c0 = x1^x0.
- Message buffer, 256 x 8, host port (host_rdata the clock after
host_rd; a host write to the address the core writes in the same
clock is dropped):
0x00 tx PD (master: PD out, device: PD in)   0x20 tx OD
0x40 rx PD (master: PD in, device: PD out)   0x60 rx OD
0x80 device parameter page (page channel reads, address + i mod 32)
0xA0..0xFF free
- Master: m_start sends the message for m_mc, then waits for the reply
(up to cfg_resp_timeout bit times of silence after its own last
octet and between reply octets). The reply is stored as it comes;
m_done ends every request with m_err_timeout (silence), m_err_uart
(parity / framing, the reply is not read further) or m_err_cks;
m_cks / m_cnt hold the CKS octet and the octets received. m_wurq
sends a wake-up request (m_done, no error).
- Device: stores PD out at 0x40 and written OD at 0x60 as they come;
a complete message pulses d_msg with d_msg_mc and d_msg_why
(0 ok, 1 parity / framing, 2 checksum, 3 M-sequence type, 4 more
than 16 bit times between two octets). After an error it waits for
16 idle bit times. Only a message without error is answered,
cfg_ta bit times (1..15, 0 acts as 1) after its last stop bit;
reads take the OD from the page (channel 1) or 0x20.

Features:

- Master port: wake-up request, M-sequences of any type with 0..32 PD octets each way and 0..32 OD octets, reply timeout, checksum, parity and framing checks
- Device: wake-up detection (+-1/16), frame checks with reports, 16-bit-time drop after errors, programmable reply delay, page channel served from a 32-octet parameter page
- UART 8E1 at any bit time from 4 PCLK cycles (COM1 / COM2 / COM3), 256 x 8 message buffer

txd / tx_en drive the C/Q transceiver, rxd is the received line (1 idle); the line is ignored while tx_en is high.
Not implemented: ISDU segmentation, event memory and the startup / preoperate state machines (host software uses the channels directly).

## Files

| File | Content |
|---|---|
| `rtl/IO_LINK_top.sv` | protocol core |
| `rtl/IO_LINK_apb.sv` | APB4 register wrapper (generated) |
| `tb/IO_LINK_tb.sv` | core testbench |
| `tb/IO_LINK_apb_tb.sv`, `tb/apb/IO_LINK_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/IO_LINK_sva.sv`, `tb/cov/IO_LINK_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/IO_LINK.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `IO_LINK_apb`. Widths of the pass-through pins are at the default parameters.

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
| `txd` | output | 1 | protocol pin, core port `txd` |
| `tx_en` | output | 1 | protocol pin, core port `tx_en` |
| `rxd` | input | 1 | protocol pin, core port `rxd` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_master` | input | 1 | CTRL[0:0] |
| `cfg_bit` | input | 16 | TIMING[15:0] |
| `cfg_wurq` | input | 16 | TIMING[31:16] |
| `cfg_mtype` | input | 2 | CTRL[2:1] |
| `cfg_pdout_len` | input | 6 | LENGTHS[5:0] |
| `cfg_pdin_len` | input | 6 | LENGTHS[11:6] |
| `cfg_od_len` | input | 6 | LENGTHS[17:12] |
| `txd` | output | 1 | pin (pass-through) |
| `tx_en` | output | 1 | pin (pass-through) |
| `rxd` | input | 1 | pin (pass-through) |
| `host_rd` | input | 1 | CMD[3:3] |
| `host_wr` | input | 1 | CMD[2:2] |
| `host_addr` | input | 8 | MEM_ADDR[7:0] |
| `host_wdata` | input | 8 | MEM_WDATA[7:0] |
| `host_rdata` | output | 8 | MEM_RDATA[7:0] |
| `cfg_resp_timeout` | input | 8 | LENGTHS[25:18] |
| `m_wurq` | input | 1 | CMD[1:1] |
| `m_start` | input | 1 | CMD[0:0] |
| `m_mc` | input | 8 | MC[7:0] |
| `m_busy` | output | 1 | M_STATUS[0:0] |
| `m_done` | output | 1 | IRQ_STATUS.M_DONE |
| `m_err_timeout` | output | 1 | M_STATUS[1:1] |
| `m_err_uart` | output | 1 | M_STATUS[2:2] |
| `m_err_cks` | output | 1 | M_STATUS[3:3] |
| `m_cks` | output | 8 | M_STATUS[11:4] |
| `m_cnt` | output | 7 | M_STATUS[18:12] |
| `cfg_ta` | input | 4 | CTRL[6:3] |
| `cfg_event` | input | 1 | CTRL[7:7] |
| `cfg_pd_invalid` | input | 1 | CTRL[8:8] |
| `d_wurq` | output | 1 | IRQ_STATUS.WURQ |
| `d_msg` | output | 1 | D_MSG capture |
| `d_msg_mc` | output | 8 | D_MSG[7:0] |
| `d_msg_why` | output | 3 | D_MSG[10:8] |

## APB wrapper

`IO_LINK_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `txd`, `tx_en`, `rxd`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x10C90100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000010 | Role, M-sequence type, device reply |
| 0x018 | TIMING | RW | 0x0FA000D9 | Bit time and wake-up length |
| 0x01C | LENGTHS | RW | 0x00401000 | Octet counts and master reply timeout |
| 0x020 | MC | RW | 0x00000000 | Master: M-sequence control octet |
| 0x024 | MEM_ADDR | RW | 0x00000000 | Message buffer address for CMD.host_rd / host_wr |
| 0x028 | MEM_WDATA | RW | 0x00000000 | Message buffer write data |
| 0x02C | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x030 | MEM_RDATA | RO | core | Message buffer read data |
| 0x034 | M_STATUS | RO | core | Master: result of the last request |
| 0x038 | D_MSG | RO (pop) | 0x00000000 | Device: message report; reading it frees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x03C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x10C9 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `cfg_master` | RW | 0x0 | 1 = master port, 0 = device |
| CTRL | 2:1 | `cfg_mtype` | RW | 0x0 | M-sequence type in CKT (the device answers only this type) |
| CTRL | 6:3 | `cfg_ta` | RW | 0x2 | device: reply delay in bit times after the middle of the last stop bit (0 acts as 1) |
| CTRL | 7 | `cfg_event` | RW | 0x0 | device: CKS event flag |
| CTRL | 8 | `cfg_pd_invalid` | RW | 0x0 | device: CKS PD status (1 = invalid) |
| TIMING | 15:0 | `cfg_bit` | RW | 0xD9 | PCLK cycles per bit, >= 4 (217 = COM3 at 50 MHz) |
| TIMING | 31:16 | `cfg_wurq` | RW | 0xFA0 | PCLK cycles of the wake-up request (80 us at 50 MHz); a device accepts +-1/16 |
| LENGTHS | 5:0 | `cfg_pdout_len` | RW | 0x0 | PD octets master to device, 0..32 |
| LENGTHS | 11:6 | `cfg_pdin_len` | RW | 0x0 | PD octets device to master, 0..32 |
| LENGTHS | 17:12 | `cfg_od_len` | RW | 0x1 | OD octets per message, 0..32 |
| LENGTHS | 25:18 | `cfg_resp_timeout` | RW | 0x10 | master: bit times of silence before a timeout |
| MC | 7:0 | `m_mc` | RW | 0x0 | {R/W (1 read), channel (0 process, 1 page, 2 diagnosis, 3 ISDU), address} |
| MEM_ADDR | 7:0 | `host_addr` | RW | 0x0 | 0x00 tx PD, 0x20 tx OD, 0x40 rx PD, 0x60 rx OD, 0x80 device page |
| MEM_WDATA | 7:0 | `host_wdata` | RW | 0x0 | octet written by CMD.host_wr |
| CMD | 0 | `m_start` | WO (pulse) | 0x0 | 1 = master: send the M-sequence for MC (when M_STATUS.m_busy = 0) |
| CMD | 1 | `m_wurq` | WO (pulse) | 0x0 | 1 = master: send a wake-up request |
| CMD | 2 | `host_wr` | WO (pulse) | 0x0 | 1 = write MEM_WDATA at MEM_ADDR |
| CMD | 3 | `host_rd` | WO (pulse) | 0x0 | 1 = read MEM_ADDR into MEM_RDATA |
| MEM_RDATA | 7:0 | `host_rdata` | RO | core | octet read by CMD.host_rd |
| M_STATUS | 0 | `m_busy` | RO | core | a request is under way |
| M_STATUS | 1 | `m_err_timeout` | RO | core | no reply or a gap in it |
| M_STATUS | 2 | `m_err_uart` | RO | core | parity or framing error in the reply |
| M_STATUS | 3 | `m_err_cks` | RO | core | reply checksum error |
| M_STATUS | 11:4 | `m_cks` | RO | core | CKS octet {event, PD invalid, checksum} |
| M_STATUS | 18:12 | `m_cnt` | RO | core | reply octets received |
| D_MSG | 7:0 | `d_msg_mc` | RO (pop) | 0x0 | MC octet |
| D_MSG | 10:8 | `d_msg_why` | RO (pop) | 0x0 | 0 ok (answered), 1 parity / framing, 2 checksum, 3 M-sequence type, 4 gap |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | M_DONE | master: the request or wake-up ended (M_STATUS) |
| 1 | WURQ | device: wake-up request detected |
| 2 | D_MSG_AVAIL | D_MSG captured a beat |
| 3 | D_MSG_OVF | beat dropped, D_MSG was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | D_MSG_AVAIL | D_MSG holds an unread beat |

### Streams

* **D_MSG** captures `d_msg_mc`, `d_msg_why` when `d_msg` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ D_MSG_AVAIL. Reading D_MSG pops it. A beat that arrives while the register is full is dropped and sets D_MSG_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x10C90100.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), TIMING (0x018), LENGTHS (0x01C), MC (0x020), MEM_ADDR (0x024), MEM_WDATA (0x028). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
5. To issue a command, write 1 to `m_start` (CMD bit 0), `m_wurq` (CMD bit 1), `host_wr` (CMD bit 2), `host_rd` (CMD bit 3) at 0x02C; the core sees a one-clock pulse, and the register reads 0.
6. Read MEM_RDATA (0x030) for the core's live `host_rdata`; it needs no clearing.
7. Read M_STATUS (0x034) for the core's live `m_busy`, `m_err_timeout`, `m_err_uart`, `m_err_cks`, `m_cks`, `m_cnt`; it needs no clearing.
8. To receive on D_MSG: wait for IRQ D_MSG_AVAIL or FLAGS.D_MSG_AVAIL (bit 0), then read D_MSG (0x038). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.D_MSG_AVAIL (bit 2) to clear it. Read each beat before the next arrives, or it is dropped and D_MSG_OVF is set.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Master: CTRL.cfg_master = 1, TIMING, LENGTHS; CMD.m_wurq, then for each cycle write the PD out / OD octets, MC, CMD.m_start; on IRQ M_DONE read M_STATUS and the reply at 0x40 / 0x60.
2. Device: CTRL, TIMING, LENGTHS; keep PD in at 0x00, OD at 0x20 and the page at 0x80; on IRQ D_MSG_AVAIL read D_MSG and the received octets at 0x40 / 0x60.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.IO_LINK sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.IO_LINK syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/IO_LINK_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.IO_LINK apb` | `TEST PASSED: IO_LINK_apb`, then Yosys without `ERROR` | console, `work/IO_LINK_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh IO_LINK`<br>`bash scripts/cov/run_cov.sh IO_LINK_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/IO_LINK/score.json`, `work/cov/IO_LINK_apb/score.json` |

Expected end of a step 4 run:

```
===== IO_LINK =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/IO_LINK_tb.sv`): drives `IO_LINK_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/IO_LINK_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/IO_LINK_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/IO_LINK_sva.sv`, `tb/cov/IO_LINK_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/IO_LINK_top.sv` | not run | | | | | |
| wrapper `rtl/IO_LINK_apb.sv` | not run | | | | | |
