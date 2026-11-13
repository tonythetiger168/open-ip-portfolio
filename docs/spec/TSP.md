<!-- SPDX-License-Identifier: Apache-2.0 -->
# TSP: design specification

Transport stream processor, memory to memory: DVB-CISSA descrambling (AES-128-CBC, ETSI TS 103
127), PCR capture for clock recovery, and PID-based routing of 188-byte TS packets to two output
buffers. Core `TSP_top` (`rtl/TSP_top.sv`, uses `rtl/tsp_aes128_dec.sv`, which also holds the key
expander `tsp_aes128_lastkey`, and `rtl/soc_ss_axi_engine.sv`), testbench `tb/TSP_tb.sv` (with
`tb/tsp_cissa_kat.svh` and `tb/soc_ss_axi_mem.svh`). There is no separate core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Commands are one-clock pulses. A packet is 188 bytes = 47 words;
byte i of a packet is bits 8 x (i mod 4) + 7 : 8 x (i mod 4) of word i / 4 (address order).
Packet header bytes: 0 sync, 1 {TEI, PUSI, priority, PID[12:8]}, 2 PID[7:0], 3 {TSC[1:0],
AFC[1:0], CC[3:0]}; byte 4 the adaptation field length when AFC bit 1 is set.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async assert | - |
| `keep_tsc` | input | 1 | keep the scrambling control bits of descrambled packets | high | `clk` | - |
| `pcr_en` | input | 1 | capture PCRs of PID `pcr_pid` | high | `clk` | - |
| `pcr_pid` | input | 13 | PID carrying the PCR | - | `clk` | - |
| `src_addr` | input | 32 | input packets (word aligned); read at the start of each packet | - | `clk` | - |
| `pkts` | input | 16 | packets in the job; read at every packet end | - | `clk` | - |
| `outa_addr` | input | 32 | output buffer A | - | `clk` | - |
| `outa_max` | input | 16 | packets buffer A holds | - | `clk` | - |
| `outb_addr` | input | 32 | output buffer B | - | `clk` | - |
| `outb_max` | input | 16 | packets buffer B holds | - | `clk` | - |
| `slot` | input | 2 | slot addressed by `key_load` / `slot_load` | - | `clk` | - |
| `odd` | input | 1 | `key_load` loads the odd key (else the even key) | high | `clk` | - |
| `key0` | input | 32 | key bytes 0 to 3 (byte 0 in bits 7:0) | - | `clk` | - |
| `key1` | input | 32 | key bytes 4 to 7 | - | `clk` | - |
| `key2` | input | 32 | key bytes 8 to 11 | - | `clk` | - |
| `key3` | input | 32 | key bytes 12 to 15 | - | `clk` | - |
| `slot_pid` | input | 13 | PID of the slot (`slot_load`) | - | `clk` | - |
| `slot_valid` | input | 1 | the slot is in use (`slot_load`) | high | `clk` | - |
| `slot_route` | input | 2 | bit 0: copy to buffer A, bit 1: copy to buffer B (`slot_load`) | - | `clk` | - |
| `start` | input | 1 | command: start a job (ignored while `busy`) | high | `clk` | - |
| `key_load` | input | 1 | command: expand `key0`..`key3` into the slot's even / odd key (ignored while `key_busy`) | high | `clk` | - |
| `slot_load` | input | 1 | command: load `slot_pid`, `slot_valid`, `slot_route` into the slot | high | `clk` | - |
| `busy` | output | 1 | job running | high | `clk` | 0 |
| `key_busy` | output | 1 | key expansion running (10 clocks) | high | `clk` | 0 |
| `err` | output | 1 | the last job saw an AXI error response | high | `clk` | 0 |
| `a_cnt` | output | 16 | packets written to buffer A in this job | - | `clk` | 0 |
| `b_cnt` | output | 16 | packets written to buffer B in this job | - | `clk` | 0 |
| `desc_cnt` | output | 16 | packets descrambled (saturates) | - | `clk` | 0 |
| `nokey_cnt` | output | 16 | scrambled packets without a key (saturates) | - | `clk` | 0 |
| `sync_cnt` | output | 16 | packets dropped for a bad sync byte (saturates) | - | `clk` | 0 |
| `drop_cnt` | output | 16 | packets dropped for an unmatched PID (saturates) | - | `clk` | 0 |
| `ovf_cnt` | output | 16 | packet copies not written, buffer full (saturates) | - | `clk` | 0 |
| `pkt_cnt` | output | 16 | packets read (saturates) | - | `clk` | 0 |
| `pcr_base` | output | 32 | bits 31:0 of the last captured 33-bit PCR base | - | `clk` | 0 |
| `pcr_ext` | output | 10 | {base[32], extension[8:0]} of the last PCR | - | `clk` | 0 |
| `pcr_local` | output | 32 | clock counter value when that packet's read started | - | `clk` | 0 |
| `done` | output | 1 | pulse: the job ended | high | `clk` | 0 |
| `err_irq` | output | 1 | pulse with `done` when the job saw an AXI error | high | `clk` | 0 |
| `nokey` | output | 1 | pulse: a scrambled packet had no key | high | `clk` | 0 |
| `sync` | output | 1 | pulse: a packet had a bad sync byte | high | `clk` | 0 |
| `pcr` | output | 1 | pulse: a PCR was captured | high | `clk` | 0 |
| `ovf` | output | 1 | pulse: a packet copy found its buffer full | high | `clk` | 0 |
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

### Internal signals used by the coverage checker

`tb/cov/TSP_sva.sv` is bound to `TSP_top` with `.*`, so a re-implementation must have these
names (width as seen by the checker).

| Signal | Width | Meaning |
|---|---|---|
| `clk_cnt` | 1 | core-internal signal read by name by the checker |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/TSP.md`](../ip/TSP.md) (source: `scripts/apb/specs/TSP.json`); do not edit by hand.

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

### Programming sequence

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
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Slots and keys

Four slots, each with a PID, a valid bit, a route and an even and an odd key.

- `slot_load`: the slot's PID, valid and route <= `slot_pid`, `slot_valid`, `slot_route`.
- `key_load` (ignored while `key_busy`): the key bytes are taken (AES key byte i = `key(i/4)`
  bits 8 x (i mod 4) + 7 : 8 x (i mod 4)); the slot's even (`odd` = 0) or odd key becomes
  unusable at once and is expanded in 10 clocks (`key_busy` = 1); then only the last round key
  is stored and the key is usable. Keys cannot be read back.
- The job does not start reading a packet while `key_busy` = 1.

### 3.2 Job

`start` while idle: `busy` <= 1, `a_cnt`, `b_cnt` and `err` <= 0. For each packet i = 0 to `pkts`
- 1: read it (one 47-word engine job at `src_addr` + 188 x i; `pkt_cnt` + 1), process it (§3.3),
write it (§3.4). After the last packet (at once when `pkts` = 0): `busy` <= 0 and `done` pulses for
one clock, with `err_irq` and `err` <= 1 if any engine job of the job saw an error response
(the data is used as received). The other counters are not cleared by `start`.

### 3.3 Packet processing

In order:

1. Sync: if byte 0 != 0x47: `sync` pulse, `sync_cnt` + 1, the packet is dropped.
2. PCR: if `pcr_en`, PID = `pcr_pid`, AFC bit 1 set, adaptation field length >= 7 and the PCR flag
   (byte 5 bit 4): from bytes 6 to 11, `pcr_base` <= base[31:0], `pcr_ext` <= {base[32],
   extension}, `pcr_local` <= the free-running clock counter (counts every clock from reset) at
   the start of this packet's read; `pcr` pulses. This happens whatever the slot match.
3. Slot match: the lowest-numbered valid slot whose PID equals the packet's. None: `drop_cnt` + 1,
   the packet is dropped.
4. Scrambling control TSC:
   - 00 or 01: the packet passes unchanged;
   - 10 (even) or 11 (odd) without that key usable in the slot: unchanged, `nokey` pulse,
     `nokey_cnt` + 1;
   - 10 or 11 with the key: `desc_cnt` + 1; TSC cleared to 00 unless `keep_tsc`; the payload is
     decrypted (below).

Payload: it starts at byte 4 (AFC = 01) or 5 + adaptation field length (AFC = 11); there is none
for AFC = 00 or 10 or when that start is 188 or more. Its first floor(length / 16) 16-byte blocks
are decrypted with AES-128-CBC, IV = the ASCII bytes "DVBTMCPTAESCISSA", block byte 0 first: P_k
= AES-1(C_k) xor C_(k-1), C_(-1) = IV. A trailing part under 16 bytes stays as it is. Each block
takes 16 clocks to load, 10 to decrypt and 16 to store.

### 3.4 Output

A matched packet is copied (after processing) to buffer A if route bit 0, then to buffer B if
route bit 1. A copy is one 47-word engine write at `outa_addr` + 188 x `a_cnt` (B likewise); if
`a_cnt` >= `outa_max` (`b_cnt` >= `outb_max`) the copy is not written, `ovf` pulses and `ovf_cnt` +
1. `a_cnt` / `b_cnt` increment when the write completes. Route 00: nothing is written.

### 3.5 AXI data mover

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

One engine job at a time; every job is 47 words.

### 3.6 Reset

`rst_n` low: idle, slots invalid and keys unusable (all 0), all counters, PCR registers and the
clock counter 0, every AXI valid / ready output 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd12 | 4'd0 to 4'd15 | value of `m_awid` and `m_arid` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| `start` while `busy` | ignored |
| `pkts` = 0 | `done` the clock after the start, nothing read |
| bad sync byte | dropped before the PCR and slot checks (`sync_cnt`) |
| unmatched PID | dropped (`drop_cnt`); its PCR is still captured |
| two valid slots with the same PID | the lower slot is used |
| scrambled, key not loaded or being expanded | passed unchanged with TSC kept, `nokey_cnt` |
| scrambled, no payload or payload under 16 bytes | counted in `desc_cnt`, TSC cleared, data unchanged |
| TSC 01 (reserved) | passed unchanged |
| buffer full | that copy is skipped (`ovf_cnt`); the other buffer is still written |
| AXI error response | the job completes with the data received; `err` and `err_irq` with `done` |
| `key_load` during a job | the job waits before its next packet read until the expansion ends |
| counters at 0xFFFF | they stay there |

## 6. TB check map

Messages are printed by `tb/TSP_tb.sv` through `fail()` as `ERROR: <message>`. The TB scrambles
packets with its own AES-128 encryption model in CBC mode with the CISSA IV, plus one known-answer
packet from Python cryptography (`tb/tsp_cissa_kat.svh`). Messages built from a step name (e.g.
"clear: A_CNT ...", "even: A byte ...", "...: counts desc ...") have no fixed prefix; they compare
buffers A and B byte by byte and every counter with the TB's model (§3.2 to §3.4).

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "TB key packing" | TB self-check of the key byte order | §3.1 |
| "TB AES model fails FIPS 197" | TB self-check of its AES model | §3.3 |
| "CISSA known answer word" | the known-answer packet descrambles to the reference plaintext | §3.3 |
| "known answer counts" | one packet written to A, one descrambled | §3.3, §3.4 |
| "PCR" | one `pcr` pulse with `pcr_base` = 0x23456789 and `pcr_ext` = {1, 0x1A5} | §3.3 |
| "PCR_LOCAL 0" | `pcr_local` holds the non-zero clock count | §3.3 |
| "no OVF interrupt" | a full buffer pulses `ovf` | §3.4 |
| "no ERR for a write error" | a write error response gives `err` and `err_irq` | §3.2 |
| "no ERR for a read error" | a read error response gives `err_irq` | §3.2 |
| "not idle in reset" | in reset: `busy` = 0, no AXI request | §3.6 |
| "counters not reset" | reset clears `desc_cnt` and `a_cnt` | §3.6 |

The TB also prints `LAT` lines (performance report, not a check).

### Coverage-closure assertions

From `tb/cov/TSP_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_reset_idle | while `!rst_n` (reset): `!busy && !m_arvalid && !m_awvalid && a_cnt == 0 && b_cnt == 0 && pkt_cnt == 0 && desc_cnt == 0 && sync_cnt == 0 && drop_cnt == 0 && ovf_cnt == 0 && !err` | §3 |
| a_start | whenever `go`, on the next clock: `busy \|\| done` | §3 |
| a_key_busy | whenever `key_load && !key_busy`, on the next clock: `key_busy` | §3 |
| a_read_addr | whenever `m_arvalid && m_arready`: `m_araddr == src_addr + 32'(j_pi) * 188 + 32'(ar_w) * 4 && ar_w + 32'(m_arlen) + 1 <= 47` | §3 |
| a_write_addr | whenever `m_awvalid && m_awready`: `wq_addr.size() != 0 && m_awaddr == wq_addr[0] + 32'(aw_w) * 4 && aw_w + 32'(m_awlen) + 1 <= 47` | §3 |
| a_write_data | whenever `m_wvalid && m_wready`: `wq_addr.size() != 0 && ((m_wdata ^ w_exp) & w_msk) == 0` | §3 |
| a_counters | whenever `done \|\| go`: `desc_cnt == c_desc && nokey_cnt == c_nokey && sync_cnt == c_sync && drop_cnt == c_drop && ovf_cnt == c_ovf && pkt_cnt == c_pkt` | §3 |
| a_pcr | whenever `pcr`: `e_pcr_v && pcr_base == e_pcr_b[31:0] && pcr_ext == {e_pcr_b[32], e_pcr_x}` | §3 |
| a_pcr_local | whenever `pcr`: `pcr_local <= p_t0 && p_t0 - pcr_local < 32'd64` | §3 |
| a_done | whenever `done`: `!busy && j_pi == pkts && a_cnt == j_a && b_cnt == j_b && wq_addr.size() == 0 && err_irq == j_err && n_sync_i == n_sync_e && n_nokey_i == n_nokey_e && n_ovf_i == n_ovf_e && n_pcr_i == n_pcr_e` | §3 |
| a_err | whenever `done && err_irq`, on the next clock: `err` | §3 |

### Further TB checks

| Check (TB message) | What it requires | Spec |
|---|---|---|
| "0-packet job" | fails when `pkt_cnt != 0 && a_cnt != 0` (`tb/TSP_tb.sv` line 186) | §3 |
| "job not started during a key expansion" | fails when `!busy` (`tb/TSP_tb.sv` line 200) | §3 |
| "job ended before the key expansion" | fails when `!busy` (`tb/TSP_tb.sv` line 204) | §3 |
| "job started during a key expansion" | fails when `a_cnt != 1` (`tb/TSP_tb.sv` line 209) | §3 |
| "counter runs: sync" | fails when `sync_cnt != 16'hFFFF \|\| drop_cnt != 16'hFFFF \|\| nokey_cnt != 16'hFFFF \|\| desc_cnt < 16'd65535 \|\| ovf_cnt != 16'hFFFF \|\| pkt_cnt != 16'hFFFF \|\| a_cnt != 16'd44700 \|\| b_cnt != 16'd44700` (`tb/TSP_tb.sv` line 242) | §3 |
| "B overflow with OVF_CNT saturated" | fails when `ovf_cnt != 16'hFFFF \|\| b_cnt != 0` (`tb/TSP_tb.sv` line 253) | §3 |
| "PCR_LOCAL bit" | fails when `pcr_local[b] != (v != 1)` (`tb/TSP_tb.sv` line 266) | §3 |
