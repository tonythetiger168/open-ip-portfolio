# SD / eMMC host controller: software-driven commands, 1- / 4- / 8-bit data, ADMA2 descriptor DMA on an AXI4 manager port

Protocol IP `SDMMC_ADMA`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SDMMC_ADMA_top` (`rtl/SDMMC_ADMA_top.sv`) |
| Register interface | APB4 slave `SDMMC_ADMA_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C610100 (code 0x5C61, version 1.0) |
| Registers | 19 words, 0x000 to 0x048 |
| Interrupts | 5 sources into one level-high `irq` |
| Protocol pins | 34 pass-through |

## Overview

SDMMC_ADMA: SD / eMMC host controller with an ADMA2 descriptor DMA (AXI4 manager) The software-driven host that the fixed-sequence SD_top / eMMC_top demos do not cover (SD card and eMMC storage of the IP camera SoC). One IP for both: the card protocol (CMD0 / CMD8 / ACMD41 or CMD1, CMD2, CMD3, ...) is run by software, one command at a time.

- Bus: sd_clk, CMD, DAT[7:0] (1-, 4- or 8-bit data, BUS_W 0 / 1 / 2).
Half an sd_clk period is CLK_DIV + 1 clocks; CLK_EN gates it. The host
samples CMD / DAT at the rising sd_clk edge and changes them at the
falling edge.
- Command: C_IDX, C_ARG, C_RSP (0 none, 1 48-bit, 2 136-bit, 3 48-bit +
busy on DAT0), C_CRC_CHK (CRC7), C_IDX_CHK (index echo); C_START sends
it (ignored while CMD_BUSY, or while DAT_BUSY for a data command).
RSP0..3: a 48-bit response's argument in RSP0; a 136-bit response's
bits 127:0 (CID / CSD with the end bit in bit 0) in RSP3..RSP0.
C_ERR: bit 0 no response within 80 clocks, 1 CRC7, 2 index, 3 framing
(transmission or end bit), 4 busy longer than DTO clocks. CMD_DONE
pulses when the command (and its busy) ends, CMD_ERR as well on an
error.
- Data (C_DATA 1 read, 2 write): BLKCNT blocks (0 counts as 1) of BLKSZ
bytes (a multiple of 4, 4..1020), per-line CRC16, the CRC status token
and the busy after each write block. Read data is accepted from when
the command starts; write data starts 2 clocks after the response. A
read block starts only when the 256-word buffer has room for it:
otherwise sd_clk stops (low) at the block boundary, so the card never
overruns it. Bytes are little-endian in a memory word and go out in
address order, MSB first.
- ADMA2 (32-bit): ADMA_ADDR points at 8-byte descriptors {word 0: bit 0
valid, 1 end, 2 int, 5:4 act (00 nop, 01 reserved, 10 tran, 11 link),
31:16 length in bytes (0 = 65536); word 1: address}. tran moves its
length (capped at what the transfer still needs) to / from its
address, link continues at its address, nop / reserved skip. int
pulses DMA_INT when the descriptor is done. Addresses and lengths must
be word aligned. The transfer ends when BLKSZ * BLKCNT bytes have
moved, even before an end descriptor.
- D_ERR: 0 data timeout (DTO sd_clk periods with no start bit, CRC
status or busy release), 1 read CRC16, 2 end bit, 3 write CRC status
not "010", 4 invalid or unaligned descriptor, 5 AXI error response, 6
descriptor table ended before the transfer, 7 the data command failed.
Any of them, or DAT_RESET, aborts the transfer: the DMA job in progress
is finished with dummy data and nothing more is fetched. XFER_DONE
pulses when the transfer has ended (for a read: when the last word is
in memory), XFER_ERR as well on an abort. Software ends an open-ended
multiple-block transfer with CMD12.
- AXI4 manager through soc_ss_axi_engine: ID AXI_ID, INCR bursts of up to
16 beats, never across 4 KB.

Features:

- The software-driven host that the fixed-sequence SD_top / eMMC_top demos do not cover: SD card and eMMC storage. Software runs the card protocol one command at a time.
- Commands with no response, a 48-bit response, a 136-bit response (CID / CSD) or a 48-bit response plus busy on DAT0 (R1b); CRC7 and index checks can be switched off per command (R3).
- Data: BLKCNT blocks of BLKSZ bytes (a multiple of 4, 4..1020) in 1-, 4- or 8-bit mode, with per-line CRC16, the CRC status token and the busy after each write block.
- A 256-word buffer between the bus and the DMA: when it has no room for the next read block, sd_clk stops at the block boundary, so the card never overruns it.
- ADMA2 (32-bit descriptors: valid, end, int, act nop / tran / link, 16-bit length, address) through the shared soc_ss_axi_engine AXI4 manager (INCR bursts of up to 16 beats, never across 4 KB).
- Half an sd_clk period is CLK_DIV + 1 clocks.

The bus pins (sd_clk, cmd, dat[7:0]) and the AXI4 manager port (m_*) pass through the wrapper unchanged. CMD and DAT need pull-ups.
AXI ID 11 (parameter AXI_ID of the core). Descriptor word 0: bit 0 valid, 1 end, 2 int, 5:4 act (00 nop, 01 reserved, 10 tran, 11 link), 31:16 length in bytes (0 = 65536); word 1: address. Addresses and lengths must be word aligned. The transfer ends once BLKSZ * BLKCNT bytes have moved.

## Files

| File | Content |
|---|---|
| `rtl/SDMMC_ADMA_top.sv` | protocol core |
| `rtl/SDMMC_ADMA_apb.sv` | APB4 register wrapper (generated) |
| `tb/SDMMC_ADMA_tb.sv` | core testbench |
| `tb/SDMMC_ADMA_apb_tb.sv`, `tb/apb/SDMMC_ADMA_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SDMMC_ADMA_sva.sv`, `tb/cov/SDMMC_ADMA_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SDMMC_ADMA.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`SDMMC_ADMA_apb` has the core's parameters and passes them to `SDMMC_ADMA_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd11` |

## Wrapper pins

Pins of `SDMMC_ADMA_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sd_clk` | output | 1 | protocol pin, core port `sd_clk` |
| `cmd` | inout | 1 | protocol pin, core port `cmd` |
| `dat` | inout | 8 | protocol pin, core port `dat` |
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
| `sd_clk` | output | 1 | pin (pass-through) |
| `cmd` | inout | 1 | pin (pass-through) |
| `dat` | inout | 8 | pin (pass-through) |
| `clk_div` | input | 10 | CFG[9:0] |
| `clk_en` | input | 1 | CFG[10:10] |
| `bus_w` | input | 2 | CFG[12:11] |
| `blksz` | input | 12 | BLK[11:0] |
| `blkcnt` | input | 16 | BLK[27:12] |
| `dto` | input | 24 | DTO[23:0] |
| `adma_addr` | input | 32 | ADMA_ADDR[31:0] |
| `c_idx` | input | 6 | CMD_CTRL[5:0] |
| `c_arg` | input | 32 | CMD_ARG[31:0] |
| `c_rsp` | input | 2 | CMD_CTRL[7:6] |
| `c_crc_chk` | input | 1 | CMD_CTRL[8:8] |
| `c_idx_chk` | input | 1 | CMD_CTRL[9:9] |
| `c_data` | input | 2 | CMD_CTRL[11:10] |
| `c_start` | input | 1 | CMD[0:0] |
| `dat_reset` | input | 1 | CMD[1:1] |
| `rsp0` | output | 32 | RSP0[31:0] |
| `rsp1` | output | 32 | RSP1[31:0] |
| `rsp2` | output | 32 | RSP2[31:0] |
| `rsp3` | output | 32 | RSP3[31:0] |
| `cmd_busy` | output | 1 | STATUS[0:0] |
| `dat_busy` | output | 1 | STATUS[1:1] |
| `c_err` | output | 5 | STATUS[6:2] |
| `d_err` | output | 8 | STATUS[14:7] |
| `blk_done` | output | 16 | BLK_DONE[15:0] |
| `adma_cur` | output | 32 | ADMA_CUR[31:0] |
| `cmd_done` | output | 1 | IRQ_STATUS.CMD_DONE |
| `cmd_err` | output | 1 | IRQ_STATUS.CMD_ERR |
| `xfer_done` | output | 1 | IRQ_STATUS.XFER_DONE |
| `xfer_err` | output | 1 | IRQ_STATUS.XFER_ERR |
| `dma_int` | output | 1 | IRQ_STATUS.DMA_INT |
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

`SDMMC_ADMA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sd_clk`, `cmd`, `dat`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C610100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x000000F9 | Bus clock and width |
| 0x018 | BLK | RW | 0x00001200 | Transfer size |
| 0x01C | DTO | RW | 0x00FFFFFF | Data and busy timeout |
| 0x020 | ADMA_ADDR | RW | 0x00000000 | ADMA2 descriptor table address (word aligned) |
| 0x024 | CMD_ARG | RW | 0x00000000 | Command argument |
| 0x028 | CMD_CTRL | RW | 0x00000300 | Command to send |
| 0x02C | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x030 | RSP0 | RO | core | Response bits 31:0 (a 48-bit response's argument) |
| 0x034 | RSP1 | RO | core | Response bits 63:32 (136-bit) |
| 0x038 | RSP2 | RO | core | Response bits 95:64 (136-bit) |
| 0x03C | RSP3 | RO | core | Response bits 127:96 (136-bit) |
| 0x040 | STATUS | RO | core | State and errors of the last command / transfer |
| 0x044 | BLK_DONE | RO | core | Blocks of the current / last transfer done |
| 0x048 | ADMA_CUR | RO | core | Address of the descriptor in use (the faulty one after a descriptor error) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x04C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C61 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 9:0 | `clk_div` | RW | 0xF9 | half sd_clk period - 1, in clocks (400 kHz or less for identification) |
| CFG | 10 | `clk_en` | RW | 0x0 | sd_clk running |
| CFG | 12:11 | `bus_w` | RW | 0x0 | data bus: 0 1-bit, 1 4-bit, 2 8-bit (set after ACMD6 / CMD6) |
| BLK | 11:0 | `blksz` | RW | 0x200 | bytes per block, a multiple of 4, 4..1020 |
| BLK | 27:12 | `blkcnt` | RW | 0x1 | blocks (0 counts as 1) |
| DTO | 23:0 | `dto` | RW | 0xFFFFFF | sd_clk periods allowed for a start bit, a CRC status or a busy release |
| ADMA_ADDR | 31:0 | `adma_addr` | RW | 0x0 | first descriptor of the next data command |
| CMD_ARG | 31:0 | `c_arg` | RW | 0x0 | 32-bit argument |
| CMD_CTRL | 5:0 | `c_idx` | RW | 0x0 | command index |
| CMD_CTRL | 7:6 | `c_rsp` | RW | 0x0 | response: 0 none, 1 48-bit, 2 136-bit, 3 48-bit + busy |
| CMD_CTRL | 8 | `c_crc_chk` | RW | 0x1 | check the response CRC7 |
| CMD_CTRL | 9 | `c_idx_chk` | RW | 0x1 | check the response index (48-bit) |
| CMD_CTRL | 11:10 | `c_data` | RW | 0x0 | data: 0 none, 1 read (card to memory), 2 write |
| CMD | 0 | `c_start` | WO (pulse) | 0x0 | send CMD_CTRL / CMD_ARG; ignored while STATUS.cmd_busy, or while STATUS.dat_busy for a data command |
| CMD | 1 | `dat_reset` | WO (pulse) | 0x0 | abort the data transfer in progress |
| RSP0 | 31:0 | `rsp0` | RO | core | response |
| RSP1 | 31:0 | `rsp1` | RO | core | response |
| RSP2 | 31:0 | `rsp2` | RO | core | response |
| RSP3 | 31:0 | `rsp3` | RO | core | response |
| STATUS | 0 | `cmd_busy` | RO | core | a command (or its busy) is running |
| STATUS | 1 | `dat_busy` | RO | core | a data transfer is running |
| STATUS | 6:2 | `c_err` | RO | core | command: 0 no response, 1 CRC7, 2 index, 3 framing, 4 busy timeout |
| STATUS | 14:7 | `d_err` | RO | core | data: 0 timeout, 1 read CRC16, 2 end bit, 3 write CRC status, 4 bad descriptor, 5 AXI error, 6 table too short, 7 data command failed |
| BLK_DONE | 15:0 | `blk_done` | RO | core | blocks |
| ADMA_CUR | 31:0 | `adma_cur` | RO | core | address |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CMD_DONE | a command (and its busy) ended |
| 1 | CMD_ERR | a command ended with an error (STATUS.c_err) |
| 2 | XFER_DONE | a data transfer ended (for a read: the last word is in memory) |
| 3 | XFER_ERR | a data transfer was aborted (STATUS.d_err, or DAT_RESET) |
| 4 | DMA_INT | a descriptor with int set is done |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C610100.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014), BLK (0x018), DTO (0x01C), ADMA_ADDR (0x020), CMD_ARG (0x024), CMD_CTRL (0x028). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `c_start` (CMD bit 0), `dat_reset` (CMD bit 1) at 0x02C; the core sees a one-clock pulse, and the register reads 0.
6. Read RSP0 (0x030) for the core's live `rsp0`; it needs no clearing.
7. Read RSP1 (0x034) for the core's live `rsp1`; it needs no clearing.
8. Read RSP2 (0x038) for the core's live `rsp2`; it needs no clearing.
9. Read RSP3 (0x03C) for the core's live `rsp3`; it needs no clearing.
10. Read STATUS (0x040) for the core's live `cmd_busy`, `dat_busy`, `c_err`, `d_err`; it needs no clearing.
11. Read BLK_DONE (0x044) for the core's live `blk_done`; it needs no clearing.
12. Read ADMA_CUR (0x048) for the core's live `adma_cur`; it needs no clearing.
13. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. CFG: CLK_DIV for 400 kHz, clk_en; wait 74 clocks. Identify the card with CMD0, CMD8 / ACMD41 (SD) or CMD1 (eMMC), CMD2, CMD3, CMD7: CMD_ARG, CMD_CTRL, CMD.c_start, wait for CMD_DONE, read RSPn and STATUS.
2. Bus width: ACMD6 (SD) or CMD6 SWITCH of EXT_CSD[183] (eMMC), then CFG.bus_w and a faster CLK_DIV.
3. Transfer: build the ADMA2 table in memory, write ADMA_ADDR and BLK, send CMD17 / 18 / 24 / 25 with CMD_CTRL.c_data; wait for XFER_DONE; after CMD18 / 25 send CMD12 (R1b).

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SDMMC_ADMA sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SDMMC_ADMA syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SDMMC_ADMA_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SDMMC_ADMA apb` | `TEST PASSED: SDMMC_ADMA_apb`, then Yosys without `ERROR` | console, `work/SDMMC_ADMA_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SDMMC_ADMA`<br>`bash scripts/cov/run_cov.sh SDMMC_ADMA_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SDMMC_ADMA/score.json`, `work/cov/SDMMC_ADMA_apb/score.json` |

Expected end of a step 4 run:

```
===== SDMMC_ADMA =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SDMMC_ADMA_tb.sv`): drives `SDMMC_ADMA_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SDMMC_ADMA_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SDMMC_ADMA_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SDMMC_ADMA_sva.sv`, `tb/cov/SDMMC_ADMA_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SDMMC_ADMA_top.sv` | not run | | | | | |
| wrapper `rtl/SDMMC_ADMA_apb.sv` | not run | | | | | |
