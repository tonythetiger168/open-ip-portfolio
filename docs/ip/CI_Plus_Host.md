# DVB Common Interface / CI+ host (EN 50221 on an 8-bit PC Card bus): CAM power, CIS / COR, command interface messages over AXI4, TS routing

Protocol IP `CI_Plus_Host`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `CI_Plus_Host_top` (`rtl/CI_Plus_Host_top.sv`) |
| Register interface | APB4 slave `CI_Plus_Host_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C0B0100 (code 0x7C0B, version 1.0) |
| Registers | 22 words, 0x000 to 0x054 |
| Interrupts | 8 sources into one level-high `irq` |
| Protocol pins | 58 pass-through |

## Overview

CI_Plus_Host: DVB Common Interface / CI+ host controller of the STB SoC (EN 50221 on a PC Card (PCMCIA) 8-bit bus): CAM power and reset, CIS read and COR write in attribute memory, the command interface in I/O space with its messages moved over AXI4, and the transport stream routed through the CAM (AXI4 manager, APB4 registers) Card pins: ci_vcc_en (card power), ci_reset (RESET, high active), ci_cd_n (card detect, low = present), the address ci_a[14:0], the data bus (ci_d_o / ci_d_oe out, ci_d_i in), the strobes ci_ce_n, ci_reg_n, ci_oe_n, ci_we_n, ci_iord_n, ci_iowr_n, ci_wait_n (the card stretches a cycle) and ci_ireq_n (READY in memory mode, IREQ# in I/O mode). ci_cd_n, ci_wait_n and ci_ireq_n are synchronised with two flops.

- Power (CMD.power_on, card present, ENABLE): VCC on, RESET high for
RST_CLKS clocks, then low; once ci_ireq_n (READY) is high the card is
ready (STATUS.ready, READY interrupt). CMD.power_off, card removal or
ENABLE off: VCC off, RESET low, I/O mode left; an operation in progress
ends (its DMA is flushed, STATUS.tx_fail for a TX).
- Bus cycle: CE# and REG# low with the address (and write data) for
SETUP + 1 clocks, then the strobe (OE#, WE#, IORD#, IOWR#) low for
STROBE + 1 clocks and as long as WAIT# is low (seen 2 clocks late through
its synchroniser, so cards that use WAIT# need STROBE >= 2); read data
is taken when the strobe ends; then HOLD + 1 clocks with CE# low. A cycle
whose WAIT# lasts WAIT_MAX clocks (0: no limit) ends at once, reads
0xFF (BUS_TO interrupt, TO_CNT).
- CMD.cis_read: CIS_LEN bytes of attribute memory (even addresses
0, 2, 4 ...) are written to memory at CIS_ADDR, 4 per word,
little-endian (CFG interrupt). CMD.cor_write writes COR_VAL to attribute
address COR_ADDR and enters I/O mode (STATUS.io_mode, CFG interrupt).
- Command interface (I/O mode; I/O addresses 0 DATA, 1 COMMAND / STATUS,
2 SIZE_LS, 3 SIZE_MS; status bits DA 0x80, FR 0x40; command bits RS 0x08,
SR 0x04, SW 0x02, HC 0x01). CMD.if_reset: RS set and cleared, then STATUS
polled until FR (CFG interrupt). CMD.tx_start: TX_LEN bytes from TX_ADDR
(byte i in word i / 4) are sent: wait for FR, set HC, check FR again
(else clear HC and start over), write the size, the bytes to DATA, clear
HC (TX_DONE interrupt). STATUS is polled every POLL_DIV + 1 clocks; after
FR_MAX polls without FR (0: no limit) the TX ends with STATUS.tx_fail.
- RX (CTRL.poll, I/O mode, the RX buffer free): STATUS is read every
POLL_DIV + 1 clocks; with DA set: set SR, read the size, clear SR, read
that many bytes from DATA. The first RX_MAX go to memory at RX_ADDR (4
per word); RX_LEN is the size, STATUS.rx_ovf flags a size over RX_MAX.
The buffer stays full (STATUS.rx_full) until CMD.rx_arm (RX interrupt).
Commands that arrive while an operation runs wait for it (STATUS.busy);
a polled RX never starts while a command waits.
- Transport stream: with CTRL.ts_route, I/O mode and power, the input
stream goes to the CAM (ci_mo_*) and the output stream comes from it
(ci_mi_*, packets counted in TS_CNT); otherwise the CAM is bypassed.
Both are registered once.
- Interrupts: DET (card detect changed), READY, CFG (CIS read, COR write
or interface reset ended), TX_DONE, RX, IREQ (ci_ireq_n fell in I/O
mode), BUS_TO, ERR (an AXI error response, with CFG, TX_DONE or RX).

Features:

- Card pins: ci_vcc_en, ci_reset, ci_cd_n, ci_a[14:0], ci_d_o / ci_d_oe / ci_d_i, CE#, REG#, OE#, WE#, IORD#, IOWR#, WAIT#, IREQ# (READY before I/O mode).
- Power-up (CMD.power_on): VCC on, RESET high for RST_CLKS clocks, then READY awaited (STATUS.ready, READY interrupt); power-off by command, card removal or ENABLE off.
- Bus cycles with programmable SETUP, STROBE and HOLD clocks, stretched by WAIT#; WAIT_MAX ends a stuck cycle (reads 0xFF, BUS_TO, TO_CNT).
- CMD.cis_read copies CIS_LEN bytes of attribute memory (even addresses) to memory at CIS_ADDR; CMD.cor_write writes COR_VAL to COR_ADDR and enters I/O mode.
- EN 50221 command interface: interface reset (RS, wait for FR); host-to-module messages of TX_LEN bytes from TX_ADDR (FR / HC handshake, size, data; FR_MAX polls before giving up); module-to-host messages polled (DA), sized (SR) and stored at RX_ADDR (up to RX_MAX bytes, RX_LEN, STATUS.rx_ovf), the buffer held until CMD.rx_arm.
- Transport stream routed through the CAM (ci_mo_* out, ci_mi_* back, TS_CNT packets) with CTRL.ts_route in I/O mode, bypassed otherwise.
- One AXI4 DMA engine: write bursts for CIS and RX data, read bursts for TX data (bytes packed 4 per word, little-endian).

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time.
One DMA job at a time on one engine: CIS and RX data use the write channel, TX data the read channel.
The card bus runs on the core clock; the I/O mode command interface sits at I/O addresses 0..3. ci_d_oe enables the host's data drivers.
The core testbench prints one `LAT <master> dram R|W <cycles>` line per AXI burst (tb/tv_lat_mon.svh), the regression suite's latency format.

## Files

| File | Content |
|---|---|
| `rtl/CI_Plus_Host_top.sv` | protocol core |
| `rtl/CI_Plus_Host_apb.sv` | APB4 register wrapper (generated) |
| `tb/CI_Plus_Host_tb.sv` | core testbench |
| `tb/CI_Plus_Host_apb_tb.sv`, `tb/apb/CI_Plus_Host_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CI_Plus_Host_sva.sv`, `tb/cov/CI_Plus_Host_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CI_Plus_Host.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`CI_Plus_Host_apb` has the core's parameters and passes them to `CI_Plus_Host_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd11` |

## Wrapper pins

Pins of `CI_Plus_Host_apb`. Widths of the pass-through pins are at the default parameters.

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
| `ci_vcc_en` | output | 1 | protocol pin, core port `ci_vcc_en` |
| `ci_reset` | output | 1 | protocol pin, core port `ci_reset` |
| `ci_cd_n` | input | 1 | protocol pin, core port `ci_cd_n` |
| `ci_a` | output | 15 | protocol pin, core port `ci_a` |
| `ci_d_o` | output | 8 | protocol pin, core port `ci_d_o` |
| `ci_d_oe` | output | 1 | protocol pin, core port `ci_d_oe` |
| `ci_d_i` | input | 8 | protocol pin, core port `ci_d_i` |
| `ci_ce_n` | output | 1 | protocol pin, core port `ci_ce_n` |
| `ci_reg_n` | output | 1 | protocol pin, core port `ci_reg_n` |
| `ci_oe_n` | output | 1 | protocol pin, core port `ci_oe_n` |
| `ci_we_n` | output | 1 | protocol pin, core port `ci_we_n` |
| `ci_iord_n` | output | 1 | protocol pin, core port `ci_iord_n` |
| `ci_iowr_n` | output | 1 | protocol pin, core port `ci_iowr_n` |
| `ci_wait_n` | input | 1 | protocol pin, core port `ci_wait_n` |
| `ci_ireq_n` | input | 1 | protocol pin, core port `ci_ireq_n` |
| `ts_in_data` | input | 8 | protocol pin, core port `ts_in_data` |
| `ts_in_valid` | input | 1 | protocol pin, core port `ts_in_valid` |
| `ts_in_sop` | input | 1 | protocol pin, core port `ts_in_sop` |
| `ts_out_data` | output | 8 | protocol pin, core port `ts_out_data` |
| `ts_out_valid` | output | 1 | protocol pin, core port `ts_out_valid` |
| `ts_out_sop` | output | 1 | protocol pin, core port `ts_out_sop` |
| `ci_mo_data` | output | 8 | protocol pin, core port `ci_mo_data` |
| `ci_mo_val` | output | 1 | protocol pin, core port `ci_mo_val` |
| `ci_mo_strt` | output | 1 | protocol pin, core port `ci_mo_strt` |
| `ci_mi_data` | input | 8 | protocol pin, core port `ci_mi_data` |
| `ci_mi_val` | input | 1 | protocol pin, core port `ci_mi_val` |
| `ci_mi_strt` | input | 1 | protocol pin, core port `ci_mi_strt` |
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
| `ci_vcc_en` | output | 1 | pin (pass-through) |
| `ci_reset` | output | 1 | pin (pass-through) |
| `ci_cd_n` | input | 1 | pin (pass-through) |
| `ci_a` | output | 15 | pin (pass-through) |
| `ci_d_o` | output | 8 | pin (pass-through) |
| `ci_d_oe` | output | 1 | pin (pass-through) |
| `ci_d_i` | input | 8 | pin (pass-through) |
| `ci_ce_n` | output | 1 | pin (pass-through) |
| `ci_reg_n` | output | 1 | pin (pass-through) |
| `ci_oe_n` | output | 1 | pin (pass-through) |
| `ci_we_n` | output | 1 | pin (pass-through) |
| `ci_iord_n` | output | 1 | pin (pass-through) |
| `ci_iowr_n` | output | 1 | pin (pass-through) |
| `ci_wait_n` | input | 1 | pin (pass-through) |
| `ci_ireq_n` | input | 1 | pin (pass-through) |
| `ts_in_data` | input | 8 | pin (pass-through) |
| `ts_in_valid` | input | 1 | pin (pass-through) |
| `ts_in_sop` | input | 1 | pin (pass-through) |
| `ts_out_data` | output | 8 | pin (pass-through) |
| `ts_out_valid` | output | 1 | pin (pass-through) |
| `ts_out_sop` | output | 1 | pin (pass-through) |
| `ci_mo_data` | output | 8 | pin (pass-through) |
| `ci_mo_val` | output | 1 | pin (pass-through) |
| `ci_mo_strt` | output | 1 | pin (pass-through) |
| `ci_mi_data` | input | 8 | pin (pass-through) |
| `ci_mi_val` | input | 1 | pin (pass-through) |
| `ci_mi_strt` | input | 1 | pin (pass-through) |
| `enable` | input | 1 | CTRL[0:0] |
| `ts_route` | input | 1 | CTRL[1:1] |
| `poll` | input | 1 | CTRL[2:2] |
| `setup` | input | 4 | TIMING[3:0] |
| `strobe` | input | 8 | TIMING[11:4] |
| `hold` | input | 4 | TIMING[15:12] |
| `wait_max` | input | 16 | WAITS[15:0] |
| `rst_clks` | input | 16 | WAITS[31:16] |
| `poll_div` | input | 16 | POLL[15:0] |
| `fr_max` | input | 16 | POLL[31:16] |
| `cis_addr` | input | 32 | CIS_ADDR[31:0] |
| `cis_len` | input | 16 | CIS_LEN[15:0] |
| `cor_addr` | input | 15 | COR[14:0] |
| `cor_val` | input | 8 | COR[22:15] |
| `tx_addr` | input | 32 | TX_ADDR[31:0] |
| `tx_len` | input | 16 | TX_LEN[15:0] |
| `rx_addr` | input | 32 | RX_ADDR[31:0] |
| `rx_max` | input | 16 | RX_MAX[15:0] |
| `power_on` | input | 1 | CMD[0:0] |
| `power_off` | input | 1 | CMD[1:1] |
| `cis_read` | input | 1 | CMD[2:2] |
| `cor_write` | input | 1 | CMD[3:3] |
| `if_reset` | input | 1 | CMD[4:4] |
| `tx_start` | input | 1 | CMD[5:5] |
| `rx_arm` | input | 1 | CMD[6:6] |
| `powered` | output | 1 | STATUS[0:0] |
| `ready` | output | 1 | STATUS[1:1] |
| `io_mode` | output | 1 | STATUS[2:2] |
| `busy` | output | 1 | STATUS[3:3] |
| `rx_full` | output | 1 | STATUS[4:4] |
| `rx_ovf` | output | 1 | STATUS[5:5] |
| `tx_fail` | output | 1 | STATUS[6:6] |
| `err` | output | 1 | STATUS[7:7] |
| `present` | output | 1 | STATUS[8:8] |
| `last_st` | output | 8 | LAST_ST[7:0] |
| `rx_len` | output | 16 | RX_LEN[15:0] |
| `tx_cnt` | output | 16 | COUNTS[15:0] |
| `rx_cnt` | output | 16 | COUNTS[31:16] |
| `ts_cnt` | output | 16 | TS_TO[15:0] |
| `to_cnt` | output | 16 | TS_TO[31:16] |
| `det` | output | 1 | IRQ_STATUS.DET |
| `rdy` | output | 1 | IRQ_STATUS.READY |
| `cfg` | output | 1 | IRQ_STATUS.CFG |
| `tx_done` | output | 1 | IRQ_STATUS.TX_DONE |
| `rx` | output | 1 | IRQ_STATUS.RX |
| `ireq` | output | 1 | IRQ_STATUS.IREQ |
| `bus_to` | output | 1 | IRQ_STATUS.BUS_TO |
| `err_irq` | output | 1 | IRQ_STATUS.ERR |
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

`CI_Plus_Host_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ci_vcc_en`, `ci_reset`, `ci_cd_n`, `ci_a`, `ci_d_o`, `ci_d_oe`, `ci_d_i`, `ci_ce_n`, `ci_reg_n`, `ci_oe_n`, `ci_we_n`, `ci_iord_n`, `ci_iowr_n`, `ci_wait_n`, `ci_ireq_n`, `ts_in_data`, `ts_in_valid`, `ts_in_sop`, `ts_out_data`, `ts_out_valid`, `ts_out_sop`, `ci_mo_data`, `ci_mo_val`, `ci_mo_strt`, `ci_mi_data`, `ci_mi_val`, `ci_mi_strt`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C0B0100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Control |
| 0x018 | TIMING | RW | 0x00000000 | Bus cycle timing (clocks) |
| 0x01C | WAITS | RW | 0x00000000 | Wait and reset times (clocks) |
| 0x020 | POLL | RW | 0x00000000 | Command interface polling |
| 0x024 | CIS_ADDR | RW | 0x00000000 | CIS copy address |
| 0x028 | CIS_LEN | RW | 0x00000000 | CIS bytes |
| 0x02C | COR | RW | 0x00000000 | Configuration option register |
| 0x030 | TX_ADDR | RW | 0x00000000 | TX buffer address |
| 0x034 | TX_LEN | RW | 0x00000000 | TX message size |
| 0x038 | RX_ADDR | RW | 0x00000000 | RX buffer address |
| 0x03C | RX_MAX | RW | 0x00000000 | RX buffer size |
| 0x040 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x044 | STATUS | RO | core | State |
| 0x048 | LAST_ST | RO | core | Last command interface status byte |
| 0x04C | RX_LEN | RO | core | Size of the last message received |
| 0x050 | COUNTS | RO | core | Message counters |
| 0x054 | TS_TO | RO | core | Stream and timeout counters |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x058 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C0B | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 7:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 7:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `enable` | RW | 0x0 | controller on; 0 powers the card off |
| CTRL | 1 | `ts_route` | RW | 0x0 | route the transport stream through the CAM (in I/O mode) |
| CTRL | 2 | `poll` | RW | 0x0 | poll the command interface for module-to-host messages |
| TIMING | 3:0 | `setup` | RW | 0x0 | address to strobe: SETUP + 1 |
| TIMING | 11:4 | `strobe` | RW | 0x0 | strobe low at least STROBE + 1 (>= 3 for cards that use WAIT#) |
| TIMING | 15:12 | `hold` | RW | 0x0 | strobe end to CE# high: HOLD + 1 |
| WAITS | 15:0 | `wait_max` | RW | 0x0 | longest WAIT# before the cycle is ended (0: no limit) |
| WAITS | 31:16 | `rst_clks` | RW | 0x0 | RESET high at power-up |
| POLL | 15:0 | `poll_div` | RW | 0x0 | clocks between STATUS polls: POLL_DIV + 1 |
| POLL | 31:16 | `fr_max` | RW | 0x0 | STATUS polls without FR before a TX or interface reset gives up (0: no limit) |
| CIS_ADDR | 31:0 | `cis_addr` | RW | 0x0 | word aligned |
| CIS_LEN | 15:0 | `cis_len` | RW | 0x0 | bytes to copy (attribute addresses 0, 2, 4 ...) |
| COR | 14:0 | `cor_addr` | RW | 0x0 | attribute address of the COR |
| COR | 22:15 | `cor_val` | RW | 0x0 | value written (configuration index) |
| TX_ADDR | 31:0 | `tx_addr` | RW | 0x0 | byte 0, word aligned |
| TX_LEN | 15:0 | `tx_len` | RW | 0x0 | bytes |
| RX_ADDR | 31:0 | `rx_addr` | RW | 0x0 | byte 0, word aligned |
| RX_MAX | 15:0 | `rx_max` | RW | 0x0 | bytes stored at most |
| CMD | 0 | `power_on` | WO (pulse) | 0x0 | power the card up (card present, ENABLE) |
| CMD | 1 | `power_off` | WO (pulse) | 0x0 | power the card off |
| CMD | 2 | `cis_read` | WO (pulse) | 0x0 | copy the CIS |
| CMD | 3 | `cor_write` | WO (pulse) | 0x0 | write the COR, enter I/O mode |
| CMD | 4 | `if_reset` | WO (pulse) | 0x0 | reset the command interface (I/O mode) |
| CMD | 5 | `tx_start` | WO (pulse) | 0x0 | send a message (I/O mode, TX_LEN > 0) |
| CMD | 6 | `rx_arm` | WO (pulse) | 0x0 | free the RX buffer for the next message |
| STATUS | 0 | `powered` | RO | core | VCC is on |
| STATUS | 1 | `ready` | RO | core | the card is powered and ready |
| STATUS | 2 | `io_mode` | RO | core | the COR is written |
| STATUS | 3 | `busy` | RO | core | an operation runs or waits |
| STATUS | 4 | `rx_full` | RO | core | the RX buffer holds a message |
| STATUS | 5 | `rx_ovf` | RO | core | the last message was longer than RX_MAX |
| STATUS | 6 | `tx_fail` | RO | core | the last TX gave up (FR_MAX) or lost the card |
| STATUS | 7 | `err` | RO | core | an AXI error response since power-up |
| STATUS | 8 | `present` | RO | core | card detect |
| LAST_ST | 7:0 | `last_st` | RO | core | DA bit 7, FR bit 6 |
| RX_LEN | 15:0 | `rx_len` | RO | core | bytes (only RX_MAX stored) |
| COUNTS | 15:0 | `tx_cnt` | RO | core | messages sent |
| COUNTS | 31:16 | `rx_cnt` | RO | core | messages received |
| TS_TO | 15:0 | `ts_cnt` | RO | core | TS packets returned by the CAM |
| TS_TO | 31:16 | `to_cnt` | RO | core | bus cycles ended by WAIT_MAX |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DET | card inserted or removed |
| 1 | READY | the card is ready after power-up |
| 2 | CFG | a CIS read, COR write or interface reset ended |
| 3 | TX_DONE | a host-to-module message ended (see STATUS.tx_fail) |
| 4 | RX | a module-to-host message is in the RX buffer |
| 5 | IREQ | the CAM requested an interrupt (I/O mode) |
| 6 | BUS_TO | a bus cycle was ended by WAIT_MAX |
| 7 | ERR | an AXI error response in a CIS write, TX read or RX write (with CFG, TX_DONE or RX) |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C0B0100.
2. Write 0xFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), TIMING (0x018), WAITS (0x01C), POLL (0x020), CIS_ADDR (0x024), CIS_LEN (0x028), COR (0x02C), TX_ADDR (0x030), TX_LEN (0x034), RX_ADDR (0x038), RX_MAX (0x03C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xFF enables all).
5. To issue a command, write 1 to `power_on` (CMD bit 0), `power_off` (CMD bit 1), `cis_read` (CMD bit 2), `cor_write` (CMD bit 3), `if_reset` (CMD bit 4), `tx_start` (CMD bit 5), `rx_arm` (CMD bit 6) at 0x040; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x044) for the core's live `powered`, `ready`, `io_mode`, `busy`, `rx_full`, `rx_ovf`, `tx_fail`, `err`, `present`; it needs no clearing.
7. Read LAST_ST (0x048) for the core's live `last_st`; it needs no clearing.
8. Read RX_LEN (0x04C) for the core's live `rx_len`; it needs no clearing.
9. Read COUNTS (0x050) for the core's live `tx_cnt`, `rx_cnt`; it needs no clearing.
10. Read TS_TO (0x054) for the core's live `ts_cnt`, `to_cnt`; it needs no clearing.
11. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write TIMING, WAITS, POLL, CIS_ADDR, CIS_LEN, COR, TX / RX buffer registers and IRQ_ENABLE, then CTRL.enable.
2. On DET with STATUS.present write CMD.power_on; on READY write CMD.cis_read and parse the CIS in memory on CFG (it gives the COR address and value).
3. Write COR and CMD.cor_write (CFG), CMD.if_reset (CFG), then CTRL.poll and CTRL.ts_route.
4. Send a message: fill the TX buffer, write TX_LEN and CMD.tx_start; TX_DONE ends it (check STATUS.tx_fail).
5. On RX read RX_LEN bytes from the RX buffer, then write CMD.rx_arm.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.CI_Plus_Host sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.CI_Plus_Host syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/CI_Plus_Host_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.CI_Plus_Host apb` | `TEST PASSED: CI_Plus_Host_apb`, then Yosys without `ERROR` | console, `work/CI_Plus_Host_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh CI_Plus_Host`<br>`bash scripts/cov/run_cov.sh CI_Plus_Host_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/CI_Plus_Host/score.json`, `work/cov/CI_Plus_Host_apb/score.json` |

Expected end of a step 4 run:

```
===== CI_Plus_Host =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/CI_Plus_Host_tb.sv`): drives `CI_Plus_Host_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/CI_Plus_Host_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/CI_Plus_Host_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/CI_Plus_Host_sva.sv`, `tb/cov/CI_Plus_Host_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CI_Plus_Host_top.sv` | not run | | | | | |
| wrapper `rtl/CI_Plus_Host_apb.sv` | not run | | | | | |
