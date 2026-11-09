# Transport stream processor: DVB-CISSA (AES-128-CBC) descrambling with 4 PID slots, PCR capture, PES / section routing of TS packets over AXI4

Protocol IP `TSP`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `TSP_top` (`rtl/TSP_top.sv`) |
| Register interface | APB4 slave `TSP_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C0C0100 (code 0x7C0C, version 1.0) |
| Registers | 28 words, 0x000 to 0x06C |
| Interrupts | 6 sources into one level-high `irq` |
| Protocol pins | 31 pass-through |

## Overview

TSP: transport stream processor of the STB SoC: DVB-CISSA descrambling (AES-128-CBC, ETSI TS 103 127), PCR capture for clock recovery and PES / section routing of 188-byte TS packets, memory to memory (AXI4 manager, APB4 registers)

- A job (CMD.start) takes PKTS packets, 47 words each, from SRC_ADDR (byte
i of a packet in word i / 4, bits 8 * (i % 4) + 7 : 8 * (i % 4)) and
handles them one at a time: read, descramble, write.
- PID slots 0..3 (SLOT_CFG: PID, valid, route; loaded into the slot
SLOT_SEL.slot by CMD.slot_load). A packet whose PID matches no valid slot
is dropped (UNMATCHED in DROP_CNT). Route bit 0 copies the packet to
buffer A (OUTA_ADDR, OUTA_MAX packets, e.g. PES / video), bit 1 to
buffer B (OUTB_ADDR, OUTB_MAX, e.g. sections), at 188 bytes per packet;
A_CNT / B_CNT count the packets written. A packet that finds its buffer
full is not written there (OVF_CNT, OVF interrupt).
- Keys: KEY0..KEY3 (key byte i in KEY(i / 4) bits 8 * (i % 4) + 7 :
8 * (i % 4)) loaded by CMD.key_load into slot SLOT_SEL.slot, even
(SLOT_SEL.odd 0) or odd key; the core keeps only the last round key (10
clocks to expand; STATUS.key_busy). Keys cannot be read back.
- Descrambling: transport_scrambling_control 10 (even) or 11 (odd) with
that key loaded: the payload (after the adaptation field) is decrypted
in 16-byte AES-128-CBC blocks with the CISSA IV "DVBTMCPTAESCISSA"; a
trailing part under 16 bytes stays as it is. The control bits are then
cleared (unless CTRL.keep_tsc) and DESC_CNT counts the packet. Scrambled
without a key: passed unchanged (NOKEY_CNT, NOKEY interrupt). Control 00
or 01: passed unchanged.
- Sync byte other than 0x47: the packet is dropped (SYNC_CNT, SYNC
interrupt).
- PCR: a packet of PID PCR_PID (with PCR_EN) whose adaptation field has
the PCR flag loads PCR_BASE (bits 31:0 of the 33-bit base), PCR_EXT
({base[32], extension[8:0]}) and PCR_LOCAL (the free-running clock
counter when the packet was read), PCR interrupt; software compares PCR
and PCR_LOCAL deltas to steer the system clock.
- DONE when the job ends; ERR as well after an AXI error response.

Features:

- 188-byte TS packets memory to memory: PKTS packets from SRC_ADDR, one at a time (read, descramble, write).
- 4 PID slots (PID, valid, route): route bit 0 writes the packet to buffer A, bit 1 to buffer B (OUTA / OUTB address and size in packets, A_CNT / B_CNT); unmatched PIDs are dropped (DROP_CNT), a full buffer skips the packet (OVF_CNT).
- DVB-CISSA (ETSI TS 103 127): AES-128-CBC with the IV DVBTMCPTAESCISSA over the payload's 16-byte blocks, even / odd key per slot from transport_scrambling_control; the residue under 16 bytes stays clear; the control bits are cleared unless CTRL.keep_tsc.
- Keys are write-only: KEY0..KEY3 and CMD.key_load expand the key to its last round key (10 clocks); the AES runs one round per clock with the round keys derived backwards.
- PCR capture on PCR_PID for clock recovery: PCR_BASE, PCR_EXT and PCR_LOCAL (the clock counter when the packet was read).
- Counters: PKT_CNT, DESC_CNT, NOKEY_CNT (scrambled without a key, passed unchanged), SYNC_CNT (sync byte not 0x47, dropped).

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time.
One DMA job at a time on one engine: 47-word packet reads, then 47-word writes to A and / or B.
DVB-CSA is not implemented (licensed); CISSA is the open AES-based DVB scrambler.
The core testbench prints one `LAT <master> dram R|W <cycles>` line per AXI burst (tb/tv_lat_mon.svh), the regression suite's latency format.

## Files

| File | Content |
|---|---|
| `rtl/TSP_top.sv` | protocol core |
| `rtl/TSP_apb.sv` | APB4 register wrapper (generated) |
| `tb/TSP_tb.sv` | core testbench |
| `tb/TSP_apb_tb.sv`, `tb/apb/TSP_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/TSP_sva.sv`, `tb/cov/TSP_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/TSP.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`TSP_apb` has the core's parameters and passes them to `TSP_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd12` |

## Wrapper pins

Pins of `TSP_apb`. Widths of the pass-through pins are at the default parameters.

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
| `keep_tsc` | input | 1 | CTRL[0:0] |
| `pcr_en` | input | 1 | CTRL[1:1] |
| `pcr_pid` | input | 13 | PCR_PID[12:0] |
| `src_addr` | input | 32 | SRC_ADDR[31:0] |
| `pkts` | input | 16 | PKTS[15:0] |
| `outa_addr` | input | 32 | OUTA_ADDR[31:0] |
| `outa_max` | input | 16 | OUTA_MAX[15:0] |
| `outb_addr` | input | 32 | OUTB_ADDR[31:0] |
| `outb_max` | input | 16 | OUTB_MAX[15:0] |
| `slot` | input | 2 | SLOT_SEL[1:0] |
| `odd` | input | 1 | SLOT_SEL[2:2] |
| `key0` | input | 32 | KEY0[31:0] |
| `key1` | input | 32 | KEY1[31:0] |
| `key2` | input | 32 | KEY2[31:0] |
| `key3` | input | 32 | KEY3[31:0] |
| `slot_pid` | input | 13 | SLOT_CFG[12:0] |
| `slot_valid` | input | 1 | SLOT_CFG[13:13] |
| `slot_route` | input | 2 | SLOT_CFG[15:14] |
| `start` | input | 1 | CMD[0:0] |
| `key_load` | input | 1 | CMD[1:1] |
| `slot_load` | input | 1 | CMD[2:2] |
| `busy` | output | 1 | STATUS[0:0] |
| `key_busy` | output | 1 | STATUS[1:1] |
| `err` | output | 1 | STATUS[2:2] |
| `a_cnt` | output | 16 | OUT_CNT[15:0] |
| `b_cnt` | output | 16 | OUT_CNT[31:16] |
| `desc_cnt` | output | 16 | DESC_CNT[15:0] |
| `nokey_cnt` | output | 16 | DESC_CNT[31:16] |
| `sync_cnt` | output | 16 | ERR_CNT[15:0] |
| `drop_cnt` | output | 16 | ERR_CNT[31:16] |
| `ovf_cnt` | output | 16 | PKT_CNT[15:0] |
| `pkt_cnt` | output | 16 | PKT_CNT[31:16] |
| `pcr_base` | output | 32 | PCR_BASE[31:0] |
| `pcr_ext` | output | 10 | PCR_EXT[9:0] |
| `pcr_local` | output | 32 | PCR_LOCAL[31:0] |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `err_irq` | output | 1 | IRQ_STATUS.ERR |
| `nokey` | output | 1 | IRQ_STATUS.NOKEY |
| `sync` | output | 1 | IRQ_STATUS.SYNC |
| `pcr` | output | 1 | IRQ_STATUS.PCR |
| `ovf` | output | 1 | IRQ_STATUS.OVF |
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

`TSP_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C0C0100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Control |
| 0x018 | PCR_PID | RW | 0x00000000 | PCR PID |
| 0x01C | SRC_ADDR | RW | 0x00000000 | Input packets |
| 0x020 | PKTS | RW | 0x00000000 | Packets per job |
| 0x024 | OUTA_ADDR | RW | 0x00000000 | Buffer A |
| 0x028 | OUTA_MAX | RW | 0x00000000 | Buffer A size |
| 0x02C | OUTB_ADDR | RW | 0x00000000 | Buffer B |
| 0x030 | OUTB_MAX | RW | 0x00000000 | Buffer B size |
| 0x034 | SLOT_SEL | RW | 0x00000000 | Slot for key_load / slot_load |
| 0x038 | KEY0 | WO | 0x00000000 | Key bytes 0..3 (byte 0 in bits 7:0), write-only |
| 0x03C | KEY1 | WO | 0x00000000 | Key bytes 4..7, write-only |
| 0x040 | KEY2 | WO | 0x00000000 | Key bytes 8..11, write-only |
| 0x044 | KEY3 | WO | 0x00000000 | Key bytes 12..15, write-only |
| 0x048 | SLOT_CFG | RW | 0x00000000 | Slot configuration for slot_load |
| 0x04C | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x050 | STATUS | RO | core | State |
| 0x054 | OUT_CNT | RO | core | Packets written in this job |
| 0x058 | DESC_CNT | RO | core | Descrambling counters |
| 0x05C | ERR_CNT | RO | core | Error counters |
| 0x060 | PKT_CNT | RO | core | Packet counters |
| 0x064 | PCR_BASE | RO | core | PCR base bits 31:0 |
| 0x068 | PCR_EXT | RO | core | PCR base bit 32 and extension |
| 0x06C | PCR_LOCAL | RO | core | Clock counter at the PCR packet |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x070 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C0C | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 5:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 5:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `keep_tsc` | RW | 0x0 | keep the scrambling control bits of descrambled packets |
| CTRL | 1 | `pcr_en` | RW | 0x0 | capture the PCR of PCR_PID |
| PCR_PID | 12:0 | `pcr_pid` | RW | 0x0 | PID that carries the PCR |
| SRC_ADDR | 31:0 | `src_addr` | RW | 0x0 | packet 0, word aligned |
| PKTS | 15:0 | `pkts` | RW | 0x0 | packets to process |
| OUTA_ADDR | 31:0 | `outa_addr` | RW | 0x0 | packet 0 of buffer A, word aligned |
| OUTA_MAX | 15:0 | `outa_max` | RW | 0x0 | packets |
| OUTB_ADDR | 31:0 | `outb_addr` | RW | 0x0 | packet 0 of buffer B, word aligned |
| OUTB_MAX | 15:0 | `outb_max` | RW | 0x0 | packets |
| SLOT_SEL | 1:0 | `slot` | RW | 0x0 | slot 0..3 |
| SLOT_SEL | 2 | `odd` | RW | 0x0 | key_load: 1 odd key, 0 even key |
| KEY0 | 31:0 | `key0` | WO | 0x0 | CMD.key_load copies it |
| KEY1 | 31:0 | `key1` | WO | 0x0 | CMD.key_load copies it |
| KEY2 | 31:0 | `key2` | WO | 0x0 | CMD.key_load copies it |
| KEY3 | 31:0 | `key3` | WO | 0x0 | CMD.key_load copies it |
| SLOT_CFG | 12:0 | `slot_pid` | RW | 0x0 | PID |
| SLOT_CFG | 13 | `slot_valid` | RW | 0x0 | slot in use |
| SLOT_CFG | 15:14 | `slot_route` | RW | 0x0 | bit 0 buffer A, bit 1 buffer B |
| CMD | 0 | `start` | WO (pulse) | 0x0 | process PKTS packets (ignored while busy) |
| CMD | 1 | `key_load` | WO (pulse) | 0x0 | load KEY0..3 into the selected slot and parity |
| CMD | 2 | `slot_load` | WO (pulse) | 0x0 | load SLOT_CFG into the selected slot |
| STATUS | 0 | `busy` | RO | core | a job runs |
| STATUS | 1 | `key_busy` | RO | core | a key is being expanded |
| STATUS | 2 | `err` | RO | core | the last job saw an AXI error response |
| OUT_CNT | 15:0 | `a_cnt` | RO | core | buffer A |
| OUT_CNT | 31:16 | `b_cnt` | RO | core | buffer B |
| DESC_CNT | 15:0 | `desc_cnt` | RO | core | packets descrambled |
| DESC_CNT | 31:16 | `nokey_cnt` | RO | core | scrambled packets without a key |
| ERR_CNT | 15:0 | `sync_cnt` | RO | core | bad sync bytes |
| ERR_CNT | 31:16 | `drop_cnt` | RO | core | unmatched PIDs |
| PKT_CNT | 15:0 | `ovf_cnt` | RO | core | packets that found their buffer full |
| PKT_CNT | 31:16 | `pkt_cnt` | RO | core | packets read |
| PCR_BASE | 31:0 | `pcr_base` | RO | core |  |
| PCR_EXT | 9:0 | `pcr_ext` | RO | core | {base[32], extension[8:0]} |
| PCR_LOCAL | 31:0 | `pcr_local` | RO | core | clocks |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | the job ended |
| 1 | ERR | the job saw an AXI error response (with DONE) |
| 2 | NOKEY | a scrambled packet had no key |
| 3 | SYNC | a packet had a bad sync byte |
| 4 | PCR | a PCR was captured |
| 5 | OVF | a packet found its buffer full |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C0C0100.
2. Write 0x3F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), PCR_PID (0x018), SRC_ADDR (0x01C), PKTS (0x020), OUTA_ADDR (0x024), OUTA_MAX (0x028), OUTB_ADDR (0x02C), OUTB_MAX (0x030), SLOT_SEL (0x034), KEY0 (0x038), KEY1 (0x03C), KEY2 (0x040), KEY3 (0x044), SLOT_CFG (0x048). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3F enables all).
5. To issue a command, write 1 to `start` (CMD bit 0), `key_load` (CMD bit 1), `slot_load` (CMD bit 2) at 0x04C; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x050) for the core's live `busy`, `key_busy`, `err`; it needs no clearing.
7. Read OUT_CNT (0x054) for the core's live `a_cnt`, `b_cnt`; it needs no clearing.
8. Read DESC_CNT (0x058) for the core's live `desc_cnt`, `nokey_cnt`; it needs no clearing.
9. Read ERR_CNT (0x05C) for the core's live `sync_cnt`, `drop_cnt`; it needs no clearing.
10. Read PKT_CNT (0x060) for the core's live `ovf_cnt`, `pkt_cnt`; it needs no clearing.
11. Read PCR_BASE (0x064) for the core's live `pcr_base`; it needs no clearing.
12. Read PCR_EXT (0x068) for the core's live `pcr_ext`; it needs no clearing.
13. Read PCR_LOCAL (0x06C) for the core's live `pcr_local`; it needs no clearing.
14. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. For each service PID: write SLOT_SEL and SLOT_CFG, then CMD.slot_load.
2. For each control word: write SLOT_SEL (slot, odd), KEY0..KEY3, CMD.key_load; wait for STATUS.key_busy low before loading the next key.
3. Write CTRL, PCR_PID, OUTA / OUTB address and size, SRC_ADDR, PKTS and IRQ_ENABLE, then CMD.start; on DONE read OUT_CNT and the counters.
4. On PCR compare PCR_BASE / PCR_EXT with PCR_LOCAL against the previous capture to steer the system clock.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.TSP sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.TSP syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/TSP_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.TSP apb` | `TEST PASSED: TSP_apb`, then Yosys without `ERROR` | console, `work/TSP_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh TSP`<br>`bash scripts/cov/run_cov.sh TSP_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/TSP/score.json`, `work/cov/TSP_apb/score.json` |

Expected end of a step 4 run:

```
===== TSP =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/TSP_tb.sv`): drives `TSP_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/TSP_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/TSP_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/TSP_sva.sv`, `tb/cov/TSP_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/TSP_top.sv` | not run | | | | | |
| wrapper `rtl/TSP_apb.sv` | not run | | | | | |
