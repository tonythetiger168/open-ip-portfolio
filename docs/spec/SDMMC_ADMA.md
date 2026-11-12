<!-- SPDX-License-Identifier: Apache-2.0 -->
# SDMMC_ADMA: design specification

SD / eMMC host controller with an ADMA2 (32-bit) descriptor DMA on an AXI4 manager port. Software
runs the card protocol one command at a time (CMD0, CMD8, ACMD41 or CMD1, CMD2, CMD3, ...); the
host sends each command, receives and checks its response, and moves the data blocks of a data
command between the card and memory through the descriptor table. 1-, 4- and 8-bit data buses.
Core `SDMMC_ADMA_top` (`rtl/SDMMC_ADMA_top.sv`, uses `rtl/soc_ss_axi_engine.sv`), testbench
`tb/SDMMC_ADMA_tb.sv` (with the card model `tb/sdmmc_card_model.svh` and `tb/soc_ss_axi_mem.svh`).
There is no separate core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *rise* is the `clk` edge where the `sd_clk` flop goes from 0 to
1, a *fall* the edge where it goes from 1 to 0. The host samples `cmd` and `dat` at a rise (the
value present just before `sd_clk` goes high) and changes its outputs at a fall: a value chosen at
a rise is driven from the next fall. The *lines in use* are `dat[0]` (1-bit), `dat[3:0]` (4-bit)
or `dat[7:0]` (8-bit). W = words per block = `blksz` / 4; N = `blkcnt`, or 1 when `blkcnt` = 0.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `sd_clk` | output | 1 | card clock; half period `clk_div` + 1 clocks | - | `clk` | 0 |
| `cmd` | inout | 1 | command line; driven only while the host sends, else high-Z (needs a pull-up) | - | `sd_clk` fall | high-Z |
| `dat` | inout | 8 | data lines; driven only while the host sends a block, else high-Z (need pull-ups) | - | `sd_clk` fall | high-Z |
| `clk_div` | input | 10 | `sd_clk` half period - 1, in clocks | - | `clk` | - |
| `clk_en` | input | 1 | `sd_clk` runs; 0 freezes it at its current level | high | `clk` | - |
| `bus_w` | input | 2 | data bus width: 0 1-bit, 1 4-bit, 2 8-bit; taken at a data command's start | - | `clk` | - |
| `blksz` | input | 12 | block size in bytes, a multiple of 4, 4 to 1020; taken at a data command's start | - | `clk` | - |
| `blkcnt` | input | 16 | blocks in the transfer, 0 counts as 1; taken at a data command's start | - | `clk` | - |
| `dto` | input | 24 | data and busy timeout in `sd_clk` periods | - | `clk` | - |
| `adma_addr` | input | 32 | address of the first ADMA2 descriptor; taken at a data command's start | - | `clk` | - |
| `c_idx` | input | 6 | command index | - | `clk` | - |
| `c_arg` | input | 32 | command argument | - | `clk` | - |
| `c_rsp` | input | 2 | response: 0 none, 1 48-bit, 2 136-bit, 3 48-bit + busy on `dat[0]` | - | `clk` | - |
| `c_crc_chk` | input | 1 | check the response CRC7 | high | `clk` | - |
| `c_idx_chk` | input | 1 | check that a 48-bit response echoes the index | high | `clk` | - |
| `c_data` | input | 2 | 0 no data, 1 read (card to memory), 2 write (memory to card) | - | `clk` | - |
| `c_start` | input | 1 | send the command (§3.2) | high | `clk` | - |
| `dat_reset` | input | 1 | abort the data transfer in progress | high | `clk` | - |
| `rsp0` | output | 32 | 48-bit response: its argument (bits 39:8); 136-bit: response bits 31:0 | - | `clk` | 0 |
| `rsp1` | output | 32 | 136-bit response bits 63:32 | - | `clk` | 0 |
| `rsp2` | output | 32 | 136-bit response bits 95:64 | - | `clk` | 0 |
| `rsp3` | output | 32 | 136-bit response bits 127:96 | - | `clk` | 0 |
| `cmd_busy` | output | 1 | a command is in progress | high | `clk` | 0 |
| `dat_busy` | output | 1 | a data transfer is in progress | high | `clk` | 0 |
| `c_err` | output | 5 | command errors of the last command (§3.2) | high | `clk` | 0 |
| `d_err` | output | 8 | data errors of the last transfer (§3.5) | high | `clk` | 0 |
| `blk_done` | output | 16 | blocks completed in the current / last transfer | - | `clk` | 0 |
| `adma_cur` | output | 32 | address of the descriptor in use | - | `clk` | 0 |
| `cmd_done` | output | 1 | one-clock pulse when a command (and its busy) ends | high | `clk` | 0 |
| `cmd_err` | output | 1 | one-clock pulse with `cmd_done` when `c_err` != 0 | high | `clk` | 0 |
| `xfer_done` | output | 1 | one-clock pulse when a data transfer ends | high | `clk` | 0 |
| `xfer_err` | output | 1 | one-clock pulse with `xfer_done` when the transfer failed or was aborted | high | `clk` | 0 |
| `dma_int` | output | 1 | one-clock pulse when a tran descriptor with the int bit is done | high | `clk` | 0 |
| `m_awid` | output | 4 | write ID, constant `AXI_ID` | - | - | - |
| `m_awaddr` | output | 32 | burst start address (word aligned) | - | `clk` | 0 |
| `m_awlen` | output | 8 | beats - 1 (0 to 15) | - | `clk` | - |
| `m_awsize` | output | 3 | constant 2 (4 bytes) | - | - | 2 |
| `m_awburst` | output | 2 | constant 01 (INCR) | - | - | 01 |
| `m_awprot` | output | 3 | constant 3'b000 | - | - | 3'b000 |
| `m_awvalid` | output | 1 | write address valid; held until `m_awready` | high | `clk` | 0 |
| `m_awready` | input | 1 | write address ready | high | `clk` | - |
| `m_wdata` | output | 32 | write data, from the write FIFO | - | `clk` | - |
| `m_wstrb` | output | 4 | constant 4'hF | - | - | 4'hF |
| `m_wlast` | output | 1 | last beat of the burst | high | `clk` | 0 |
| `m_wvalid` | output | 1 | write data valid; never low inside a burst once AW is accepted | high | `clk` | 0 |
| `m_wready` | input | 1 | write data ready | high | `clk` | - |
| `m_bid` | input | 4 | write response ID; ignored (one write outstanding) | - | - | - |
| `m_bresp` | input | 2 | write response; anything but OKAY sets `err` | - | `clk` | - |
| `m_bvalid` | input | 1 | write response valid | high | `clk` | - |
| `m_bready` | output | 1 | 1 while waiting for the burst's response | high | `clk` | 0 |
| `m_arid` | output | 4 | read ID, constant `AXI_ID` | - | - | - |
| `m_araddr` | output | 32 | burst start address (word aligned) | - | `clk` | 0 |
| `m_arlen` | output | 8 | beats - 1 (0 to 15) | - | `clk` | - |
| `m_arsize` | output | 3 | constant 2 (4 bytes) | - | - | 2 |
| `m_arburst` | output | 2 | constant 01 (INCR) | - | - | 01 |
| `m_arprot` | output | 3 | constant 3'b000 | - | - | 3'b000 |
| `m_arvalid` | output | 1 | read address valid; held until `m_arready` | high | `clk` | 0 |
| `m_arready` | input | 1 | read address ready | high | `clk` | - |
| `m_rid` | input | 4 | read ID; ignored (one read outstanding) | - | - | - |
| `m_rdata` | input | 32 | read data | - | `clk` | - |
| `m_rresp` | input | 2 | read response; anything but OKAY sets `err` (the data is still used) | - | `clk` | - |
| `m_rlast` | input | 1 | last read beat; ends the burst (the beat count is not checked) | high | `clk` | - |
| `m_rvalid` | input | 1 | read data valid | high | `clk` | - |
| `m_rready` | output | 1 | 1 for the whole read data phase of a burst (never back-pressures) | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `hold` | 1 | the data engine wants `sd_clk` stopped: 1 while waiting for a read block's start bit with less than W free words in the buffer (§3.4) |

### Internal signals used by the coverage checker

`tb/cov/SDMMC_ADMA_sva.sv` is bound to `SDMMC_ADMA_top` with `.*`, so a re-implementation must have these
names (width as seen by the checker).

| Signal | Width | Meaning |
|---|---|---|
| `as_q` | 1 | core-internal signal read by name by the checker |
| `A_XWAIT` | 1 | core-internal signal read by name by the checker |
| `c_go` | 1 | core-internal signal read by name by the checker |
| `a_data` | 1 | the job in progress is a data job |
| `drop` | 1 | core-internal signal read by name by the checker |
| `dir_rd` | 1 | transfer direction: card to memory |
| `e_start` | 1 | core-internal signal read by name by the checker |
| `e_rd` | 1 | core-internal signal read by name by the checker |
| `e_wr` | 1 | core-internal signal read by name by the checker |
| `e_done` | 1 | core-internal signal read by name by the checker |
| `e_err` | 1 | core-internal signal read by name by the checker |
| `e_src` | [31:0] | core-internal signal read by name by the checker |
| `e_dst` | 1 | core-internal signal read by name by the checker |
| `e_len` | [15:0] | core-internal signal read by name by the checker |
| `rs_valid` | 1 | core-internal signal read by name by the checker |
| `rs_ready` | 1 | core-internal signal read by name by the checker |
| `ws_valid` | 1 | core-internal signal read by name by the checker |
| `ws_ready` | 1 | core-internal signal read by name by the checker |
| `rs_data` | [31:0] | core-internal signal read by name by the checker |
| `ws_data` | 1 | core-internal signal read by name by the checker |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SDMMC_ADMA.md`](../ip/SDMMC_ADMA.md) (source: `scripts/apb/specs/SDMMC_ADMA.json`); do not edit by hand.

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

### Programming sequence

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
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Card clock

`sd_clk` toggles every `clk_div` + 1 clocks while it runs. It runs when `clk_en` = 1 and not
(`hold` = 1 and `sd_clk` = 0): with `hold` it completes its high half and then stays low until
`hold` drops, so it always stops low. While stopped (or `clk_en` = 0) the half-period counter is
cleared, so the next half period is a full `clk_div` + 1 clocks.

### 3.2 Command

`c_start` is accepted when `cmd_busy` = 0 and, for a data command (`c_data` != 0), `dat_busy` = 0;
otherwise it is ignored. A command without data may be sent during a transfer (CMD12). At the
accepting edge `cmd_busy` <= 1 and `c_err` <= 0; the index, argument, response type and check
bits are taken.

1. Send: 48 bits MSB first, one per `sd_clk` period: 0 (start), 1 (transmission), `c_idx`,
   `c_arg`, CRC7 (x^7 + x^3 + 1, initial 0, over the first 40 bits), 1 (end). `cmd` is driven
   from the fall after the first rise to the fall after the 48th rise.
2. At the next rise the line is released. With no response the command ends there (`cmd_done`).
3. Response hunt: from the second rise after the end bit, a 0 on `cmd` is the response's start
   bit. If none is seen within 80 rises: `c_err[0]` (no response), the command ends.
4. Receive 48 or 136 bits (start bit included). Then:
   - `c_err[1]` if `c_crc_chk` and the CRC7 differs (48-bit: over bits 47:8; 136-bit: over the
     CID / CSD bits 127:8; received in bits 7:1);
   - `c_err[2]` if `c_idx_chk` and a 48-bit response's bits 45:40 != `c_idx`;
   - `c_err[3]` if the end bit is 0 or the transmission bit is 1 (framing);
   - the response is stored even with an error: 48-bit: `rsp0` = bits 39:8; 136-bit: `rsp3`..`rsp0`
     = bits 127:0 (`rsp0[0]` is the end bit).
   With an error, or for types 1 and 2, the command ends.
5. Busy (type 3, no error): after two more rises, `dat[0]` is sampled at every rise; 1 ends the
   command. If it is still 0 at the rise numbered `dto` + 1: `c_err[4]` (busy timeout), the
   command ends.

At the end `cmd_busy` <= 0 and `cmd_done` pulses for one clock, with `cmd_err` when `c_err` != 0.

### 3.3 Data transfer start

At the accepting edge of a data command: `dat_busy` <= 1, `d_err` <= 0, `blk_done` <= 0, the
256-word data buffer is emptied, `bus_w`, `blksz`, `blkcnt` are taken, and the ADMA2 engine starts
at `adma_addr` (§3.6) with W x N words to move. If the data command itself ends with `cmd_err`,
`d_err[7]` is set and the transfer aborts (§3.5).

Byte order: a memory word holds 4 bytes in address order (lowest address in bits [7:0]). On the
bus the bytes go in address order, each byte MSB first: 1-bit sends bit 7 .. bit 0 of each byte on
`dat[0]`; 4-bit sends the high then the low nibble on `dat[3:0]`; 8-bit sends one byte per period
on `dat[7:0]`.

### 3.4 Read (card to memory)

Per block:

1. Wait for a start bit: `dat[0]` = 0 at a rise. Accepted from the command's start (the card may
   send data before its response ends). While waiting, if the buffer has fewer than W free words
   `hold` = 1 and `sd_clk` stops low (§3.1), so the card can never overrun the buffer. If `dto`
   rises pass without a start bit (the count restarts per block): `d_err[0]`.
2. Data: W words, 32, 8 or 4 rises per word for 1, 4, 8 lines; each word goes to the buffer when
   complete. A CRC16 (CCITT x^16 + x^12 + x^5 + 1, initial 0) is computed on every line in use.
3. CRC: 16 rises, each line's CRC16 MSB first. `d_err[1]` if any line in use differs.
4. End bit: 1 rise; `d_err[2]` if any line in use is 0. `blk_done` increments.

After N blocks the transfer ends once the DMA has written every word to memory (all write
responses received): `xfer_done` (with `xfer_err` if `d_err` != 0).

### 3.5 Write (memory to card)

1. Wait until the transfer's own command has ended without error (its `cmd_done`).
2. Per block: 2 rises with the lines released (Nwr); then at the first rise where the buffer holds
   W words, a start bit (0 on every line in use), then W words (§3.3), then each line's CRC16 MSB
   first (16 periods), then an end bit (1), then the lines are released.
3. CRC status token on `dat[0]`: wait for a 0 (within `dto` rises, else `d_err[0]`), then 3 bits
   that must be 010 followed by a 1 (end bit); otherwise `d_err[3]`.
4. Busy: wait for `dat[0]` = 1 (within `dto` rises, else `d_err[0]`). `blk_done` increments; the
   next block starts at step 2.

After N blocks the transfer ends when the DMA is idle: `xfer_done` (with `xfer_err` if
`d_err` != 0).

Errors and abort: a data error (`d_err` bits 0 to 3, 7), a DMA error (bits 4 to 6) or `dat_reset`
while `dat_busy` aborts the transfer: the host releases the lines, stops sampling, and waits for
the DMA job in progress to finish with dummy data (zeros written to memory on a read, read words
discarded on a write) without fetching more descriptors. Then `dat_busy` <= 0 and `xfer_done` and
`xfer_err` pulse. `dat_reset` sets no `d_err` bit. The card is not stopped: software sends CMD12
(and waits for its busy) to end a multiple-block transfer, normal or aborted.

| `d_err` bit | Cause |
|---|---|
| 0 | data timeout: no read start bit, CRC status or busy release within `dto` `sd_clk` periods |
| 1 | read CRC16 mismatch |
| 2 | read end bit 0 |
| 3 | write CRC status not 010 (or its end bit 0) |
| 4 | invalid descriptor, or unaligned descriptor / buffer address or length |
| 5 | AXI error response (descriptor fetch or data) |
| 6 | the descriptor table ended (end bit) before the transfer had moved W x N words |
| 7 | the data command failed (`cmd_err`) |

### 3.6 ADMA2 engine

Descriptor: 8 bytes at a word-aligned address. Word 0: bit 0 valid, bit 1 end, bit 2 int, bits
5:4 act (00 nop, 01 reserved, 10 tran, 11 link), bits 31:16 length in bytes (0 = 65536). Word 1:
address. `adma_cur` shows the descriptor being used.

1. Fetch: a 2-word read at the current address (unaligned address: `d_err[4]`; error response:
   `d_err[5]`).
2. Decode:
   - valid = 0, a tran with an unaligned address or a length not a multiple of 4, or a link with
     an unaligned address: `d_err[4]`;
   - link: the address becomes word 1, fetch again;
   - tran: one engine job of min(length / 4, words still to move) words at word 1 (read: buffer
     to memory; write: memory to buffer). At its end: `dma_int` if int; error response
     `d_err[5]`; if every word has moved the DMA is done; else if end `d_err[6]`; else next
     descriptor (address + 8);
   - nop or reserved: if end, `d_err[6]`; else next descriptor.

A longer last tran is cut to what the transfer needs; the DMA stops when W x N words have moved
even without an end bit. On a write the engine reads as long as the buffer has room; on a read it
writes as soon as the buffer holds data (bursts once the engine has the whole burst). A DMA error
aborts the transfer (§3.5).

### 3.7 AXI data mover

The core moves data with `rtl/soc_ss_axi_engine.sv` (instance `u_eng`, FIFO depth 32
words per direction). One job reads `len` 32-bit words from `src` into the read stream (if the job
reads) and writes `len` words taken from the write stream to `dst` (if it writes). Bits [1:0] of
both addresses are ignored.

- Start: at the edge where `start` is accepted (not busy), `busy` <= 1, `err` <= 0,
  `cycles` <= 0 and the job parameters are latched. `start` while `busy` is ignored.
- Bursts: INCR, AxSIZE 2, WSTRB 4'hF, length min(16, words left, words to the next 4 KB
  boundary), so no burst crosses 4 KB. One read and one write burst may be outstanding at the same
  time, never two of the same kind. All IDs are the core's constant ID.
- Read side: a read burst is requested (ARVALID from the clock after the start edge at the
  earliest) only when the read FIFO has room for 16 more words, so `m_rready` is 1 for the whole
  data phase. Every RVALID beat goes into the FIFO; RLAST ends the burst.
- Write side: a write burst is requested only when the write FIFO already holds all of its beats,
  so once AW is accepted WVALID stays high until WLAST; then BREADY waits for the response.
- Error: any RRESP or BRESP other than OKAY sets `err` until the next start; the job still runs to
  the end with the data it got.
- Done: at the edge where both sides have finished every burst (all responses received) and the
  read FIFO is empty, `busy` <= 0 and `done` is 1 for one clock. `cycles` counts every edge while
  `busy` is 1, so it holds the number of clocks from the start edge to the done edge and keeps it
  until the next start. A job with `len` = 0 finishes at the edge after the start (`cycles` = 1).

### 3.8 Reset

`rst_n` low: `sd_clk` = 0, `cmd` and `dat` released, command and data engines idle, buffer empty,
all outputs 0, every AXI valid / ready output 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd11 | 4'd0 to 4'd15 | value of `m_awid` and `m_arid` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `c_start` while `cmd_busy`, or a data command while `dat_busy` | ignored |
| `blkcnt` = 0 | one block |
| read faster than memory | `sd_clk` stops low before the next block until the buffer has room for it |
| write with memory slow | the start bit waits until the buffer holds the whole block |
| last tran longer than the transfer | cut to the words still needed |
| response errors | the response registers are still loaded; the command ends without busy |
| data command fails | `d_err[7]`, the transfer aborts |
| `dat_reset` with no transfer | ignored |
| `clk_en` = 0 during a command or transfer | everything waits (timeouts count `sd_clk` periods) |
| abort during a read | the current DMA job writes zeros for its remaining words |
| reset in the middle of a transfer | everything idle at once; the card and the subordinate must be reset too |

## 6. TB check map

Messages are printed by `tb/SDMMC_ADMA_tb.sv` through `fail()` as `ERROR: <message>`. The card model
(`tb/sdmmc_card_model.svh`) answers SD and eMMC commands with correct CRCs and can inject faults
(no response, response CRC, endless busy, read CRC, bad CRC status). The TB initializes an SD
card (CMD0, CMD8, ACMD41, CMD2, CMD3, CMD7, ACMD6 to 4-bit) and an eMMC device (CMD1, CMD2, CMD3,
CMD7, EXT_CSD read, CMD6 to 8-bit), and runs random single and multiple-block reads and writes
of 64 to 512 bytes over 1 to 5 tran descriptors with nop and link descriptors.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "CMD" | `cmd_busy` = 1 the clock after `c_start`; an initialization command ends with `c_err` = 0 | §3.2 |
| "R7" | CMD8 echoes the check pattern 0x1AA in `rsp0` | §3.2 |
| "transfer did not end" | every transfer ends | §3.4, §3.5 |
| "data command: C_ERR" | data commands get a good response | §3.2 |
| "BLK_DONE" | `blk_done` = number of blocks after a transfer; memory and card array equal; `d_err` = 0; one `dma_int` per int descriptor | §3.4 to §3.6 |
| "ACMD41 OCR" | ACMD41 response argument in `rsp0` | §3.2 |
| "CID" | 136-bit response in `rsp3`..`rsp0`, bit 0 the end bit | §3.2 |
| "RCA" | CMD3 response argument in `rsp0` | §3.2 |
| "sd_clk ran with the buffer full" | with AW held off during an 8-block read, `sd_clk` stops | §3.1, §3.4 |
| "HOLD low with the buffer full" | internal `hold` = 1 while it is stopped | §3.4 |
| "no response: C_ERR" | no response gives exactly `c_err` = 00001 | §3.2 |
| "response CRC: C_ERR" | a bad CRC7 gives exactly 00010 | §3.2 |
| "busy timeout: C_ERR" | endless busy with `dto` = 300 gives exactly 10000 | §3.2 |
| "read CRC: D_ERR" | a read CRC16 error sets `d_err[1]` and `xfer_err` | §3.4 |
| "write CRC status: D_ERR" | a bad CRC status token sets `d_err[3]` and `xfer_err` | §3.5 |
| "abort case" | every abort ends with `xfer_err` | §3.5 |
| "invalid descriptor: D_ERR" | a not-valid descriptor sets `d_err[4]` | §3.6 |
| "short table: D_ERR" | an end descriptor before the transfer is complete sets `d_err[6]` | §3.6 |
| "SLVERR: D_ERR" | an AXI error response sets `d_err[5]` | §3.6 |
| "DAT_RESET: D_ERR" | `dat_reset` aborts with `d_err` = 0 | §3.5 |
| "CMD1 OCR" | eMMC CMD1 OCR access mode bits | §3.2 |
| "eMMC CID" | eMMC CID in `rsp3`..`rsp0` | §3.2 |
| "EXT_CSD read: D_ERR" | a 512-byte 1-bit read (CMD8) without errors | §3.4 |
| "EXT_CSD word" | EXT_CSD bytes in memory in address order | §3.3 |
| "EXT_CSD[183] not 2 after the switch" | after CMD6 the 8-bit read returns BUS_WIDTH = 2 | §3.3, §3.4 |
| "eMMC read CRC: D_ERR" | a read CRC16 error in 8-bit mode sets `d_err[1]` | §3.4 |
| "timeout" | the whole test ends within 400 ms | §3 |

The messages "read" / "write ... D_ERR" and "... word ... memory ..., card ..." (random
transfers) and "... DMA_INT, expected ..." start with a formatted value and so have no fixed
prefix. The TB also prints `LAT tb SDMMC_ADMA R|W <clocks>` from `c_start` to `xfer_done`
(performance report, not a check).

### Coverage-closure assertions

From `tb/cov/SDMMC_ADMA_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_cmd_frame | whenever `chk_cmd`: `c_got == c_exp` | §3 |
| a_cmd_errors | whenever `m_done`: `c_err[3:0] == m_cerr` | §3 |
| a_rsp | whenever `m_done && m_rsp_v`: `m_rsp_long ? {rsp3, rsp2, rsp1, rsp0} == m_rsp : rsp0 == m_rsp[31:0]` | §3 |
| a_data_word | whenever `chk_w`: `chk_w_ok` | §3 |
| a_wr_block_crc | whenever `chk_blk && !rd`: `chk_blk_crc_ok && chk_blk_end_ok` | §3 |
| a_rd_errors | whenever `xfer_done && rd && (d_err & 8'hF9) == 0`: `d_err[2:1] == {m_rd_end_err, m_rd_crc_err}` | §3 |
| a_fetch_addr | whenever `e_start && !a_data`: `e_src == a_desc && e_len == 2 && e_rd && !e_wr && a_on && !a_exp_job` | §3 |
| a_tran_job | whenever `e_start && a_data`: `a_exp_job && e_src == a_w1 && e_dst == a_w1 && e_len == 16'(a_job_w) && e_rd == !dir_rd && e_wr == dir_rd` | §3 |
| a_dma_errors | whenever `xfer_done && (d_err & 8'h8F) == 0`: `(d_err & 8'h70) == a_err` | §3 |

### Further TB checks

| Check (TB message) | What it requires | Spec |
|---|---|---|
| "65536-byte descriptor: D_ERR" | fails when `d_err != 0 \|\| blk_done != (c ? 16'd1 : 16'd2)` (`tb/SDMMC_ADMA_tb.sv` line 309) | §3 |
| "index: C_ERR" | fails when `e !== 5'b00100` (`tb/SDMMC_ADMA_tb.sv` line 312) | §3 |
| "end bit: C_ERR" | fails when `!e[3]` (`tb/SDMMC_ADMA_tb.sv` line 313) | §3 |
| "read end bit: D_ERR" | fails when `!d_err[2]` (`tb/SDMMC_ADMA_tb.sv` line 319) | §3 |
| "data timeout: D_ERR" | fails when `!d_err[0]` (`tb/SDMMC_ADMA_tb.sv` line 322) | §3 |
| "data command failed: D_ERR" | fails when `!d_err[7]` (`tb/SDMMC_ADMA_tb.sv` line 325) | §3 |
| "DAT_RESET during a write: no XFER_ERR" | fails when `!xfer_err_seen` (`tb/SDMMC_ADMA_tb.sv` line 347) | §3 |
| "gated / overlapped read: D_ERR" | fails when `d_err != 0` (`tb/SDMMC_ADMA_tb.sv` line 356) | §3 |
| "random CID" | fails when `{rsp3, rsp2, rsp1, rsp0} !== card.cid` (`tb/SDMMC_ADMA_tb.sv` line 376) | §3 |
| "CMD1 OCR echo" | fails when `rsp0[14:8] !== 7'h7F` (`tb/SDMMC_ADMA_tb.sv` line 381) | §3 |
| "table error" | fails when `!xfer_err_seen \|\| d_err != (c == 0 ? 8'h10 : c == 1 ? 8'h20 : 8'h40)` (`tb/SDMMC_ADMA_tb.sv` line 396) | §3 |
| "high table: D_ERR" | fails when `d_err != 0 \|\| blk_done != 2 \|\| n_dma_int != 1` (`tb/SDMMC_ADMA_tb.sv` line 429) | §3 |
| "high buffer word" | fails when `mem.peek(a) !== {card.mem[b + 3], card.mem[b + 2], card.mem[b + 1], card.mem[b]}` (`tb/SDMMC_ADMA_tb.sv` line 436) | §3 |
| "long descriptor" | fails when `!xfer_err_seen` (`tb/SDMMC_ADMA_tb.sv` line 453) | §3 |
| "4-byte blocks: stopped at" | fails when `!blk_done[15]` (`tb/SDMMC_ADMA_tb.sv` line 465) | §3 |
| "longest data timeout: D_ERR" | fails when `dat_busy \|\| !d_err[0]` (`tb/SDMMC_ADMA_tb.sv` line 479) | §3 |
| "longest busy timeout: C_ERR" | fails when `cmd_busy \|\| c_err !== 5'b10000` (`tb/SDMMC_ADMA_tb.sv` line 484) | §3 |
| "not idle in reset" | fails when `dat_busy \|\| cmd_busy` (`tb/SDMMC_ADMA_tb.sv` line 494) | §3 |
