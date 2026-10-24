# MIPI RFFE-style bus master: register, extended and extended long write / read sequences

Protocol IP `RFFE`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `RFFE_top` (`rtl/RFFE_top.sv`) |
| Register interface | APB4 slave `RFFE_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x52460200 (code 0x5246, version 2.0) |
| Registers | 10 words, 0x000 to 0x024 |
| Interrupts | 7 sources into one level-high `irq` |
| Data streams | CMD (to the core), WR (to the core), RD (from the core) |
| Protocol pins | 4 pass-through |

## Overview

RFFE_top v2.0: MIPI RFFE-style bus master (the bus owner) The master drives SCLK and runs one command sequence per host command:

- SSC: with SCLK low, SDATA high for one SCLK period, then low; the
first SCLK rising edge follows half a period later.
- Every bit is one SCLK period (2 x (cfg_div + 1) PCLK, high half
first). The master drives a bit at the rising edge; the slaves sample
it at the falling edge. In a read, the slave drives each bit after the
rising edge and the master samples it at the falling edge (SDATA
through two flops, so cfg_div must cover the slave's delay; 7 or more
with MIPI_RFFE_top).
- Command frame SA[3:0] C[7:0] P, address and data frames D[7:0] P, all
MSB first with odd parity:
0 Register 0 write       C = 1 D[6:0]           (data in cmd_addr[6:0])
1 Register write         C = 010 A[4:0], data frame
2 Register read          C = 011 A[4:0], read frame
3 Extended write         C = 0000 BC, A[7:0], BC + 1 data frames
4 Extended read          C = 0010 BC, A[7:0], BC + 1 read frames
5 Extended long write    C = 00110 BC[2:0], A[15:8], A[7:0], data
6 Extended long read     C = 00111 BC[2:0], A[15:8], A[7:0], read
7 reserved: no bus activity, done at once
- Write sequences end with a bus park cycle (the master drives SDATA low
while SCLK is high and releases it at the falling edge). Reads put the
bus park cycle before the read frames, and end with the slave's bus
park cycle (one more SCLK period, SDATA left to the slave, and half a
period more before the master may drive SDATA again).
- Data bytes come from the wr_* stream, one per data frame. With no byte
ready, the master holds SCLK low (and SDATA) until one arrives.
- Each read frame is delivered on rd_* with rd_perr when its parity
fails; done pulses at the end of the sequence, with done_perr when any
read frame of it failed.
SDATA is released outside sequences (a bus holder keeps it low).
Not implemented: half-speed reads, masked writes, interrupt and
master-ownership-handover sequences.

sclk, sdata_o / sdata_oe and sdata_i are the bus pins (SDATA bidirectional with a bus holder); all pass through unchanged.

## Files

| File | Content |
|---|---|
| `rtl/RFFE_top.sv` | protocol core |
| `rtl/RFFE_apb.sv` | APB4 register wrapper (generated) |
| `tb/RFFE_tb.sv` | core testbench |
| `tb/RFFE_apb_tb.sv`, `tb/apb/RFFE_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/RFFE_sva.sv`, `tb/cov/RFFE_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/RFFE.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.RFFE sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.RFFE apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh RFFE          # core coverage (Verilator)
bash scripts/cov/run_cov.sh RFFE_apb      # wrapper coverage
```

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `RFFE_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sclk` | output | 1 | protocol pin, core port `sclk` |
| `sdata_o` | output | 1 | protocol pin, core port `sdata_o` |
| `sdata_oe` | output | 1 | protocol pin, core port `sdata_oe` |
| `sdata_i` | input | 1 | protocol pin, core port `sdata_i` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_div` | input | 4 | CFG[3:0] |
| `sclk` | output | 1 | pin (pass-through) |
| `sdata_o` | output | 1 | pin (pass-through) |
| `sdata_oe` | output | 1 | pin (pass-through) |
| `sdata_i` | input | 1 | pin (pass-through) |
| `cmd_valid` | input | 1 | CMD commit / FLAGS |
| `cmd_ready` | output | 1 | CMD handshake |
| `cmd_type` | input | 3 | CMD[2:0] |
| `cmd_sa` | input | 4 | CMD[6:3] |
| `cmd_addr` | input | 16 | CMD[22:7] |
| `cmd_bc` | input | 4 | CMD[26:23] |
| `wr_valid` | input | 1 | WR commit / FLAGS |
| `wr_ready` | output | 1 | WR handshake |
| `wr_data` | input | 8 | WR[7:0] |
| `rd_valid` | output | 1 | RD capture |
| `rd_data` | output | 8 | RD[7:0] |
| `rd_perr` | output | 1 | RD[8:8] |
| `done` | output | 1 | IRQ_STATUS.SEQ_DONE |
| `done_perr` | output | 1 | STATUS[1:1] |
| `busy` | output | 1 | STATUS[0:0] |

## APB wrapper

`RFFE_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `sdata_o`, `sdata_oe`, `sdata_i`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x52460200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000007 | Bus speed |
| 0x018 | CMD | RW | 0x00000000 | Command sequence; writing CMD commits it, the core takes it when idle |
| 0x01C | WR | RW | 0x00000000 | Write data byte for the next data frame (SCLK waits while WR is empty) |
| 0x020 | RD | RO (pop) | 0x00000000 | Read data byte; reading RD frees it |
| 0x024 | STATUS | RO | core | Sequence state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5246 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 6:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 6:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 2:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 3:0 | `cfg_div` | RW | 0x7 | SCLK half period - 1 in PCLK (7 or more for reads from MIPI_RFFE_top) |
| CMD | 2:0 | `cmd_type` | RW | 0x0 | 0 register 0 write, 1 register write, 2 register read, 3 extended write, 4 extended read, 5 extended long write, 6 extended long read, 7 reserved (no bus activity) |
| CMD | 6:3 | `cmd_sa` | RW | 0x0 | slave address (0 = broadcast) |
| CMD | 22:7 | `cmd_addr` | RW | 0x0 | register address (type 0: data in [6:0]) |
| CMD | 26:23 | `cmd_bc` | RW | 0x0 | byte count - 1 (extended; long uses [2:0]) |
| WR | 7:0 | `wr_data` | RW | 0x0 | data byte |
| RD | 7:0 | `rd_data` | RO (pop) | 0x0 | data byte |
| RD | 8 | `rd_perr` | RO (pop) | 0x0 | the frame's parity failed |
| STATUS | 0 | `busy` | RO | core | a sequence is running |
| STATUS | 1 | `done_perr` | RO | core | a read frame of the last finished sequence failed its parity |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | SEQ_DONE | a sequence finished (STATUS.done_perr updated) |
| 1 | CMD_DONE | CMD beat accepted by the core |
| 2 | CMD_OVF | write to CMD while full (dropped) |
| 3 | WR_DONE | WR beat accepted by the core |
| 4 | WR_OVF | write to WR while full (dropped) |
| 5 | RD_AVAIL | RD captured a beat |
| 6 | RD_OVF | beat dropped, RD was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CMD_FULL | CMD holds a beat the core has not taken |
| 1 | WR_FULL | WR holds a beat the core has not taken |
| 2 | RD_AVAIL | RD holds an unread beat |

### Streams

* **CMD** feeds `cmd_type`, `cmd_sa`, `cmd_addr`, `cmd_bc`/`cmd_valid`. Writing CMD commits the beat: FLAGS.CMD_FULL is set and `cmd_valid` stays high until the core's `cmd_ready`; then CMD_DONE is set. A write while full is dropped and sets CMD_OVF.
* **WR** feeds `wr_data`/`wr_valid`. Writing WR commits the beat: FLAGS.WR_FULL is set and `wr_valid` stays high until the core's `wr_ready`; then WR_DONE is set. A write while full is dropped and sets WR_OVF.
* **RD** captures `rd_data`, `rd_perr` when `rd_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RD_AVAIL. Reading RD pops it. A beat that arrives while the register is full is dropped and sets RD_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x52460200.
2. Write 0x7F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7F enables all).
5. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD (0x018). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
6. To send on WR: wait until FLAGS.WR_FULL (bit 1) is 0, or for IRQ WR_DONE, then write WR (0x01C). The last write commits the beat. WR_OVF means a write came while the register was full and was dropped.
7. To receive on RD: wait for IRQ RD_AVAIL or FLAGS.RD_AVAIL (bit 2), then read RD (0x020). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RD_AVAIL (bit 5) to clear it. Read each beat before the next arrives, or it is dropped and RD_OVF is set.
8. Read STATUS (0x024) for the core's live `busy`, `done_perr`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/RFFE_top.sv` | pass | 70/70 | 236/236 | 16/16 | 10/10 | 18/18 |
| wrapper `rtl/RFFE_apb.sv` | pass | 40/40 | 664/664 | n/a | 15/15 | 68/68 |
