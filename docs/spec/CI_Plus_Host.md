<!-- SPDX-License-Identifier: Apache-2.0 -->
# CI_Plus_Host: design specification

DVB Common Interface / CI+ host controller (EN 50221 on an 8-bit PC Card bus). It powers and
resets the CAM, reads the CIS and writes the COR in attribute memory, runs the command
interface in I/O space (messages moved between memory and the CAM over AXI4), and routes the
transport stream through the CAM. Core `CI_Plus_Host_top` (`rtl/CI_Plus_Host_top.sv`, uses
`rtl/soc_ss_axi_engine.sv`), testbench `tb/CI_Plus_Host_tb.sv` (with the CAM model
`tb/ci_cam_model.svh` and `tb/soc_ss_axi_mem.svh`). There is no separate core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Commands are one-clock pulses. *On* means the power state machine
is in its ready state (`ready` = 1); anything else is *off* for the sequencer.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `ci_vcc_en` | output | 1 | card power (VCC) on | high | `clk` | 0 |
| `ci_reset` | output | 1 | card RESET | high | `clk` | 0 |
| `ci_cd_n` | input | 1 | card detect, 0 = card present | low | async (2 flops) | - |
| `ci_a` | output | 15 | card address | - | `clk` | 0 |
| `ci_d_o` | output | 8 | card data out (write cycles) | - | `clk` | 0 |
| `ci_d_oe` | output | 1 | drive `ci_d_o` on the data bus | high | `clk` | 0 |
| `ci_d_i` | input | 8 | card data in, taken when the read strobe ends | - | `clk` | - |
| `ci_ce_n` | output | 1 | card enable (CE1#) | low | `clk` | 1 |
| `ci_reg_n` | output | 1 | REG#: low with CE# for every cycle (attribute and I/O space) | low | `clk` | 1 |
| `ci_oe_n` | output | 1 | attribute memory read strobe | low | `clk` | 1 |
| `ci_we_n` | output | 1 | attribute memory write strobe | low | `clk` | 1 |
| `ci_iord_n` | output | 1 | I/O read strobe | low | `clk` | 1 |
| `ci_iowr_n` | output | 1 | I/O write strobe | low | `clk` | 1 |
| `ci_wait_n` | input | 1 | WAIT#: the card stretches the strobe | low | async (2 flops) | - |
| `ci_ireq_n` | input | 1 | READY (memory mode, high = ready) / IREQ# (I/O mode) | - | async (2 flops) | - |
| `ts_in_data` | input | 8 | transport stream from the demodulator | - | `clk` | - |
| `ts_in_valid` | input | 1 | `ts_in_data` valid | high | `clk` | - |
| `ts_in_sop` | input | 1 | first byte of a packet | high | `clk` | - |
| `ts_out_data` | output | 8 | transport stream to the demultiplexer (§3.10) | - | `clk` | 0 |
| `ts_out_valid` | output | 1 | `ts_out_data` valid | high | `clk` | 0 |
| `ts_out_sop` | output | 1 | first byte of a packet | high | `clk` | 0 |
| `ci_mo_data` | output | 8 | stream to the CAM (MOVAL / MOSTRT bus); 0 when not routed | - | `clk` | 0 |
| `ci_mo_val` | output | 1 | `ci_mo_data` valid | high | `clk` | 0 |
| `ci_mo_strt` | output | 1 | first byte of a packet to the CAM | high | `clk` | 0 |
| `ci_mi_data` | input | 8 | stream from the CAM | - | `clk` | - |
| `ci_mi_val` | input | 1 | `ci_mi_data` valid | high | `clk` | - |
| `ci_mi_strt` | input | 1 | first byte of a packet from the CAM | high | `clk` | - |
| `enable` | input | 1 | controller enabled; 0 powers the card off | high | `clk` | - |
| `ts_route` | input | 1 | route the transport stream through the CAM | high | `clk` | - |
| `poll` | input | 1 | poll the CAM for module-to-host messages (§3.7) | high | `clk` | - |
| `setup` | input | 4 | address setup: CE# low `setup` + 1 clocks before the strobe | - | `clk` | - |
| `strobe` | input | 8 | strobe low for at least `strobe` + 1 clocks | - | `clk` | - |
| `hold` | input | 4 | CE# stays low `hold` + 1 clocks after the strobe | - | `clk` | - |
| `wait_max` | input | 16 | strobe clocks spent waiting on WAIT# before the cycle times out; 0 = no limit | - | `clk` | - |
| `rst_clks` | input | 16 | RESET high time in clocks (at least 1) | - | `clk` | - |
| `poll_div` | input | 16 | gap between STATUS polls: `poll_div` + 1 clocks | - | `clk` | - |
| `fr_max` | input | 16 | STATUS polls without FR before giving up; 0 = no limit | - | `clk` | - |
| `cis_addr` | input | 32 | memory address for the CIS bytes | - | `clk` | - |
| `cis_len` | input | 16 | CIS bytes to read | - | `clk` | - |
| `cor_addr` | input | 15 | attribute address of the COR | - | `clk` | - |
| `cor_val` | input | 8 | value written to the COR | - | `clk` | - |
| `tx_addr` | input | 32 | memory address of the host-to-module message | - | `clk` | - |
| `tx_len` | input | 16 | message length in bytes | - | `clk` | - |
| `rx_addr` | input | 32 | memory address for module-to-host messages | - | `clk` | - |
| `rx_max` | input | 16 | bytes of a module-to-host message stored at most | - | `clk` | - |
| `power_on` | input | 1 | command: power the card up | high | `clk` | - |
| `power_off` | input | 1 | command: power the card down | high | `clk` | - |
| `cis_read` | input | 1 | command: read the CIS to memory | high | `clk` | - |
| `cor_write` | input | 1 | command: write the COR and enter I/O mode | high | `clk` | - |
| `if_reset` | input | 1 | command: command-interface reset (I/O mode only) | high | `clk` | - |
| `tx_start` | input | 1 | command: send a message (I/O mode, `tx_len` != 0) | high | `clk` | - |
| `rx_arm` | input | 1 | command: the RX buffer is free again | high | `clk` | - |
| `powered` | output | 1 | = `ci_vcc_en` | high | `clk` | 0 |
| `ready` | output | 1 | the card is powered and READY was seen | high | `clk` | 0 |
| `io_mode` | output | 1 | the COR was written; I/O space in use | high | `clk` | 0 |
| `busy` | output | 1 | an operation is running or a command waits | high | `clk` | 0 |
| `rx_full` | output | 1 | a received message is in the RX buffer | high | `clk` | 0 |
| `rx_ovf` | output | 1 | the last message was longer than `rx_max` | high | `clk` | 0 |
| `tx_fail` | output | 1 | the last TX gave up (FR_MAX) or was cut by power loss | high | `clk` | 0 |
| `err` | output | 1 | an AXI error response was seen; cleared by `power_on` | high | `clk` | 0 |
| `present` | output | 1 | card present (synchronised `ci_cd_n` inverted) | high | `clk` | 0 |
| `last_st` | output | 8 | last command-interface STATUS byte read | - | `clk` | 0 |
| `rx_len` | output | 16 | size of the last received message | - | `clk` | 0 |
| `tx_cnt` | output | 16 | messages sent (saturates) | - | `clk` | 0 |
| `rx_cnt` | output | 16 | messages received (saturates) | - | `clk` | 0 |
| `ts_cnt` | output | 16 | packets received from the CAM while routed (saturates) | - | `clk` | 0 |
| `to_cnt` | output | 16 | bus cycles that timed out (saturates) | - | `clk` | 0 |
| `det` | output | 1 | pulse: the synchronised card detect changed | high | `clk` | 0 |
| `rdy` | output | 1 | pulse: the card became ready | high | `clk` | 0 |
| `cfg` | output | 1 | pulse: CIS read, COR write or interface reset ended | high | `clk` | 0 |
| `tx_done` | output | 1 | pulse: a TX ended (sent or failed) | high | `clk` | 0 |
| `rx` | output | 1 | pulse: a message was received | high | `clk` | 0 |
| `ireq` | output | 1 | pulse: IREQ# fell in I/O mode | high | `clk` | 0 |
| `bus_to` | output | 1 | pulse: a bus cycle timed out | high | `clk` | 0 |
| `err_irq` | output | 1 | pulse: an operation ended with an AXI error (with `cfg`, `tx_done` or `rx`) | high | `clk` | 0 |
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
| `e_busy` | 1 | the AXI data mover is busy; must be 0 shortly after an operation is cut by card removal (§3.9) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/CI_Plus_Host.md`](../ip/CI_Plus_Host.md) (source: `scripts/apb/specs/CI_Plus_Host.json`); do not edit by hand.

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

### Programming sequence

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
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Synchronisers and detect

`ci_cd_n`, `ci_wait_n` and `ci_ireq_n` go through two flops each. `present` is the synchronised
card detect inverted; `det` pulses for one clock when it changes. `ireq` pulses for one clock when
the synchronised `ci_ireq_n` falls while `io_mode` = 1 and the card is on.

### 3.2 Power

- Off: `power_on` with `present` and `enable`: `ci_vcc_en` <= 1 and `ci_reset` <= 1.
- `ci_reset` stays high max(`rst_clks`, 1) clocks, then goes low.
- Then, after 3 clocks, at the first clock where the synchronised `ci_ireq_n` (READY) is 1: the
  card is on (`ready` = 1) and `rdy` pulses.
- In any state but off, `power_off`, `present` = 0 or `enable` = 0 turn it off at once:
  `ci_vcc_en` <= 0, `ci_reset` <= 0. Leaving the on state also leaves I/O mode and cuts the
  operation in progress (§3.9).
- `power_on` while off also clears `err`, `rx_full`, `rx_ovf` and `tx_fail`.

### 3.3 Bus cycle

One cycle at a time; kinds: attribute read (`ci_oe_n`), attribute write (`ci_we_n`), I/O read
(`ci_iord_n`), I/O write (`ci_iowr_n`). From the clock after the request:

1. `ci_a`, `ci_d_o` (writes; `ci_d_oe` = 1), `ci_ce_n` = 0 and `ci_reg_n` = 0 for `setup` + 1
   clocks;
2. the strobe low for `strobe` + 1 clocks, then as long as the synchronised WAIT# is low (seen
   2 clocks late, so cards that use WAIT# need `strobe` >= 2). With `wait_max` != 0 the cycle
   ends when `wait_max` clocks have been spent waiting: it reads 0xFF and `bus_to` pulses
   (`to_cnt` + 1). Read data is `ci_d_i` at the edge where the strobe goes high;
3. `ci_ce_n` (and `ci_reg_n`, `ci_d_oe`) stay low `hold` + 1 clocks more, then go high.

When the card is not on every strobe, `ci_ce_n`, `ci_reg_n` and `ci_d_oe` go inactive at once.

### 3.4 Commands and the sequencer

While the card is on, `cis_read` and `cor_write` are always taken, `if_reset` only in I/O mode,
`tx_start` only in I/O mode with `tx_len` != 0; otherwise they are ignored. A taken command waits
(`busy` = 1) until the sequencer is idle; then, in priority order: interface reset, CIS read, COR
write, TX, and last a polled RX (§3.7), which never starts while a command waits. Each operation
ends with its DMA job finished (every word written or read) and a pulse: `cfg`, `tx_done` or
`rx`, with `err_irq` (and `err` <= 1) if that job saw an AXI error response.

Command interface registers (I/O addresses): 0 DATA, 1 COMMAND / STATUS, 2 SIZE_LS, 3 SIZE_MS.
STATUS bits: DA 0x80, FR 0x40. COMMAND bits: RS 0x08, SR 0x04, SW 0x02, HC 0x01.

*FR wait*: read STATUS (`last_st` <= the byte); if FR is set go on; else wait `poll_div` + 1
clocks and read again. With `fr_max` != 0, after `fr_max` reads without FR (counted from the
start of the operation) the wait gives up.

### 3.5 CIS read and COR write

CIS read: a DMA write job of ceil(`cis_len` / 4) words to `cis_addr` starts; attribute bytes at
addresses 0, 2, 4, ... (byte i at 2i) are read one by one and packed four per word, byte i in
bits 8 x (i mod 4) of word i / 4, the unused bytes of the last word 0. Then `cfg`. With
`cis_len` = 0 there is no bus or DMA traffic, only `cfg`.

COR write: one attribute write of `cor_val` to `cor_addr`; then `io_mode` <= 1 and `cfg`.

### 3.6 Interface reset and TX

Interface reset: I/O write 0x08 (RS) to COMMAND, I/O write 0x00 to COMMAND, then the FR wait;
then `cfg` (also when the FR wait gave up; `last_st` shows the last STATUS).

TX (host to module): a DMA read job of ceil(`tx_len` / 4) words from `tx_addr` starts and
`tx_fail` <= 0. Then:

1. FR wait (giving up: `tx_fail` <= 1, the DMA job is drained, `tx_done` without `tx_cnt`);
2. I/O write 0x01 (HC) to COMMAND; read STATUS: if FR is gone (the module took the buffer), I/O
   write 0x00 to COMMAND and go back to step 1;
3. I/O write the size low byte to SIZE_LS and high byte to SIZE_MS;
4. `tx_len` I/O writes to DATA, byte i being bits 8 x (i mod 4) of word i / 4;
5. I/O write 0x00 to COMMAND (HC cleared); `tx_done`, `tx_cnt` + 1.

### 3.7 RX (module to host)

When idle with `poll` = 1, I/O mode, `rx_full` = 0 and the poll timer at 0: read STATUS
(`last_st`). Without DA, the poll timer is loaded with `poll_div` and the sequencer is idle again
(the next poll comes `poll_div` clocks later at the earliest; the timer is also loaded after every
operation). With DA:

1. I/O write 0x04 (SR) to COMMAND; read SIZE_LS, then SIZE_MS (size n); I/O write 0x00 to COMMAND;
2. store = min(n, `rx_max`); a DMA write job of ceil(store / 4) words to `rx_addr` (none if
   store = 0);
3. n I/O reads of DATA; the first store bytes are packed like the CIS (unused bytes 0), the rest
   are read and dropped;
4. after the DMA: `rx`, `rx_full` <= 1, `rx_len` <= n, `rx_ovf` <= (n > store), `rx_cnt` + 1.

`rx_full` stays 1 (no more polls) until `rx_arm`.

### 3.8 AXI data mover

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

One engine job at a time: reads for a TX, writes for a CIS read or an RX.

### 3.9 Power loss during an operation

When the card leaves the on state: `io_mode` <= 0, waiting commands are dropped, the bus cycle is
cut, and an operation in progress stops at once. Its DMA job is let finish: a read job is
drained, a write job is completed with zero words. Then the sequencer is idle; a TX ends with
`tx_fail` = 1 and `tx_done` (no `tx_cnt`); a CIS read, COR write, interface reset or RX ends
without a pulse. `err` is set if the job saw an error response.

### 3.10 Transport stream

Routed = `ts_route` and `io_mode` and the card on. Every output is registered once:

- routed: `ci_mo_*` <= `ts_in_*` (`ci_mo_strt` = valid and sop); `ts_out_*` <= `ci_mi_*`
  (`ts_out_sop` = valid and strt); `ts_cnt` + 1 for each valid `ci_mi_strt`;
- not routed (bypass): `ts_out_*` <= `ts_in_*`; `ci_mo_val` = `ci_mo_strt` = 0, `ci_mo_data` = 0.

### 3.11 Reset

`rst_n` low: card power off, all strobes and `ci_ce_n` high, data bus released, sequencer idle,
all status and counters 0, every AXI valid / ready output 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd11 | 4'd0 to 4'd15 | value of `m_awid` and `m_arid` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `power_on` without a card or with `enable` = 0 | ignored |
| commands while the card is not on | ignored |
| `if_reset` / `tx_start` outside I/O mode, `tx_start` with `tx_len` = 0 | ignored |
| WAIT# held past `wait_max` | the cycle ends, reads 0xFF, `bus_to`, `to_cnt` + 1; the operation goes on |
| FR never comes (TX) | after `fr_max` polls: `tx_fail`, `tx_done`, no `tx_cnt` |
| FR never comes (interface reset) | after `fr_max` polls: `cfg`; `last_st` shows FR = 0 |
| FR taken away between HC and the size | HC cleared, FR waited for again |
| message longer than `rx_max` | the first `rx_max` bytes stored, the rest read and dropped; `rx_ovf` |
| a message waits while `rx_full` = 1 | not polled until `rx_arm` |
| AXI error response | the operation completes; `err` (sticky until `power_on`) and `err_irq` with its end pulse |
| card removed or powered off mid-operation | §3.9 |
| counters at 0xFFFF | they stay there |

## 6. TB check map

Messages are printed by `tb/CI_Plus_Host_tb.sv` through `fail()` as `ERROR: <message>`. The CAM model
(`tb/ci_cam_model.svh`) checks the bus cycle timing and implements the CIS, the COR and the EN
50221 command interface (it can take FR away once, never set FR, hold WAIT#, and send messages).
Messages built from a step name (e.g. "power-up: not ready", "CIS: byte ...", "TX: CAM got ...",
"RX: RX_LEN ...") have no fixed prefix; they check §3.2 and §3.5 to §3.7 step by step.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "powered without a card" | `power_on` without a card does nothing | §3.2 |
| "DET / present on insertion" | one `det` and `present` = 1 on insertion | §3.1 |
| "COR not written / no I/O mode" | COR write reaches the CAM and sets `io_mode` | §3.5 |
| "FR during the interface reset" | RS is written, then cleared, before FR is polled | §3.6 |
| "LAST_ST without FR after the interface reset" | `last_st` holds the STATUS read with FR | §3.4, §3.6 |
| "FR steal not exercised" | the HC / FR re-check of a TX runs | §3.6 |
| "TX_CNT" | `tx_cnt` counts sent messages only | §3.6 |
| "RX while the buffer is full" | no RX until `rx_arm` | §3.7 |
| "second RX message" | the next message is stored after `rx_arm` | §3.7 |
| "RX_CNT" | `rx_cnt` counts received messages | §3.7 |
| "timed-out bytes" | two timed-out CIS reads store 0xFF; `to_cnt` = 2 | §3.3 |
| "no ERR for a CIS write error" | an AXI write error gives `err` and one `err_irq` | §3.4 |
| "no ERR for a TX read error" | an AXI read error gives `err_irq` | §3.4 |
| "no IREQ" | IREQ# falling in I/O mode gives one `ireq` | §3.1 |
| "TS through the CAM" | routed, the 188 output bytes come from the CAM with a start | §3.10 |
| "TS byte" | every routed output byte is the CAM's | §3.10 |
| "TS_CNT" | one packet start from the CAM counted | §3.10 |
| "TS bypass" | not routed, the input stream reaches the output | §3.10 |
| "removal during a TX" | card removal mid-TX: `tx_fail`, power off, `io_mode` = 0, `busy` = 0, `tx_done` | §3.9 |
| "DMA not flushed" | the DMA job (internal `e_busy`) has finished | §3.9 |
| "power-off" | `power_off` removes power and `ready` | §3.2 |
| "not idle in reset" | in reset: power off, `ci_ce_n` = 1, no AXI request | §3.11 |

The TB also prints `LAT` lines (performance report, not a check).

### Coverage-closure assertions

From `tb/cov/CI_Plus_Host_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_reset_idle | while `!rst_n` (reset): `!ci_vcc_en && !ci_reset && ci_ce_n && ci_oe_n && ci_we_n && ci_iord_n && ci_iowr_n && !ci_d_oe && !busy && !io_mode && tx_cnt == 0 && rx_cnt == 0 && !m_awvalid && !m_arvalid` | §3 |
| a_power_up | whenever `!powered && power_on && present && enable`, on the next clock: `ci_vcc_en && ci_reset` | §3 |
| a_reset_len | whenever `!ci_reset && $past(ci_reset) && ci_vcc_en`: `$past(rh) + 16'd1 == rst_n_clks` | §3 |
| a_power_off | whenever `powered && go_off`, on the next clock: `!ci_vcc_en && !ci_reset` | §3 |
| a_status | always holds: `present == !cd_s[1] && det == (cd_s[1] != cd_q) && powered == ci_vcc_en && (!ready \|\| ci_vcc_en)` | §3 |
| a_ready | whenever `ready && !$past(ready)`: `$past(rdy) && iq_s[1] && $past(rh) == 0` | §3 |
| a_ireq | always holds: `ireq == (io_mode && ready && iq_q && !iq_s[1])` | §3 |
| a_one_strobe | always holds: `$countones(strb) <= 1 && (strb == 0 \|\| (!ci_ce_n && !ci_reg_n))` | §3 |
| a_setup | whenever `s_fall`: `c_set == 32'(setup) + 1 && ci_a == c_a` | §3 |
| a_strobe | whenever `s_rise && ready`: `c_strb == 32'(strobe) + 1 + c_wait && (wait_max == 0 \|\| c_wait < 32'(wait_max))` | §3 |
| a_no_wait_no_stretch | whenever `s_rise && ready && c_wait == 0`: `c_strb == 32'(strobe) + 1` | §3 |
| a_hold | whenever `ci_ce_n && !ce_q && after_strb && ready`: `c_hold == 32'(hold) + 1` | §3 |
| a_stable | whenever `!ci_ce_n && !ce_q && ready`: `ci_a == $past(ci_a) && (!ci_d_oe \|\| ci_d_o == $past(ci_d_o))` | §3 |
| a_drive | always holds: `!ci_d_oe \|\| ci_ce_n \|\| (ci_oe_n && ci_iord_n)` | §3 |
| a_bus_to | whenever `bus_to`: `s_rise && wait_max != 0 && c_wait == 32'(wait_max) - 1` | §3 |
| a_write_word | whenever `m_wvalid && m_wready && ready`: `w_ok && m_wdata == w_exp` | §3 |
| a_tx_byte | whenever `s_rise && ready && c_kind == 4'b1000 && c_a[1:0] == 2'd0`: `tq.size() != 0 && c_d == tq[0]` | §3 |
| a_tx_size | whenever `s_rise && ready && c_kind == 4'b1000 && c_a[1:1] == 1'b1`: `c_d == (c_a[0] ? tx_len[15:8] : tx_len[7:0])` | §3 |
| a_tx_done | whenever `tx_done && !tx_fail`: `tx_dw == tx_len` | §3 |
| a_rx | whenever `rx`: `rx_len == r_size && rx_ovf == (r_size > rx_max) && r_got == r_size && rx_full` | §3 |
| a_counters | always holds: `$past(tx_cnt) == m_tx && $past(rx_cnt) == m_rx && to_cnt == m_to && ts_cnt == m_ts` | §3 |
| a_err_irq | always holds: `!err_irq \|\| j_err` | §3 |
| a_err_end | whenever `(cfg \|\| tx_done \|\| rx) && j_err && $past(ready)`: `##1 err` | §3 |
| a_ts | always holds: `!$past(rst_n) \|\| ci_mo_val == ($past(route) && $past(ts_in_valid)) && ci_mo_data == ($past(route) ? $past(ts_in_data) : 8'h00) && ts_out_valid == ($past(route) ? $past(ci_mi_val) : $past(ts_in_valid)) && ts_out_data == ($past(route) ? $past(ci_mi_data) : $past(ts_in_data))` | §3 |

### Further TB checks

| Check (TB message) | What it requires | Spec |
|---|---|---|
| "response" | fails when `!err` (`tb/CI_Plus_Host_tb.sv` line 400) | §3 |
| "power-off during a CIS read" | fails when `busy \|\| !err \|\| ci_vcc_en` (`tb/CI_Plus_Host_tb.sv` line 422) | §3 |
| "power-off during an RX message" | fails when `busy \|\| ci_vcc_en` (`tb/CI_Plus_Host_tb.sv` line 442) | §3 |
| "counter runs: TX" | fails when `tx_cnt != 16'hFFFF \|\| rx_cnt != 16'hFFFF \|\| to_cnt != 16'hFFFF \|\| ts_cnt != 16'hFFFF` (`tb/CI_Plus_Host_tb.sv` line 502) | §3 |
| "ENABLE off" | fails when `ci_vcc_en \|\| ready` (`tb/CI_Plus_Host_tb.sv` line 531) | §3 |
