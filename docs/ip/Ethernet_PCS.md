# Ethernet 400GBASE-R PCS (IEEE 802.3 clause 119) around the RS(544,514) FEC: 256B/257B transcoding, the 58-bit scrambler, alignment marker insertion and lock (16 lanes, Table 119-2), the two-codeword 10-bit symbol interleave, on two Ethernet_RS_FEC cores

Protocol IP `Ethernet_PCS`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Ethernet_PCS_top` (`rtl/Ethernet_PCS_top.sv`) |
| Register interface | APB4 slave `Ethernet_PCS_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x45500100 (code 0x4550, version 1.0) |
| Registers | 67 words, 0x000 to 0x108 |
| Interrupts | 13 sources into one level-high `irq` |
| Data streams | TX_IN (to the core), TX_OUT (from the core), RX_IN (to the core), RX_OUT (from the core) |
| Protocol pins | none (register access only) |

## Overview

Ethernet_PCS_top v1.0: 400GBASE-R PCS data path around the RS(544,514) FEC (IEEE 802.3 clause 119), transmit and receive, on two instances of Ethernet_RS_FEC_top (codewords A and B). Bit order: bit 0 of every vector is the first bit sent. A 66-bit block has its sync header in [1:0] (data 2'b10, control 2'b01: the first bit sent is 0 for data) and its payload in [65:2]; a control block's block type field is [9:2]. A group is four blocks, block j at [66j +: 66]. Transmit, one group per clock at most:

- 256B/257B transcoding (119.2.4.2 / 91.5.2.5): four data blocks give
header 1 and the four payloads; otherwise header 0, a flag per block
(1: data) and the payloads without the second nibble of the first
control block's type field. A group with an invalid sync header gives
all flags 1 (the receiver sees an invalid block).
- Scrambler 1 + x^39 + x^58, self-synchronizing, over all 257 bits.
- Alignment marker group (119.2.4.4.2) at the start of every AMP-th
pair of FEC messages (first after reset): the 16 lane markers of
Table 119-2, 10-bit interleaved, a 133-bit free-running PRBS9 pad
(x^9 + x^5 + 1) and the 3 status bits tx_am_sf: eight 257-bit blocks,
not scrambled. tx_in_ready is low for those 8 block times: the room
for the markers comes from the MAC side (idle deletion), not here.
- Pre-FEC distribution (119.2.4.5): 40 blocks (10280 bits) make two
514-symbol messages, the even 10-bit symbols to A, the odd to B.
- RS(544,514) encoding (Ethernet_RS_FEC_top, 32 symbols a beat).
- Symbol distribution (119.2.4.7): tx_out_data carries 64 symbols of
the interleaved pair a clock, symbol n at [10n +: 10], 17 beats a
pair (tx_out_first on the first); symbol n of a beat goes to PCS lane
n mod 16. Lane distribution to the PMA is outside the core.
Receive (input: the de-skewed, re-ordered lanes as the same 64-symbol
beats, rx_in_first on the first beat of a pair):
- the inverse distribution, RS decoding of A and B, the inverse pre-FEC
distribution into 257-bit blocks;
- marker lock: until a marker group (all 1920 marker bits) is found in
the first eight blocks of a pair nothing comes out; locked, the group
is expected every AMP pairs and removed (rx_am_sf takes its status
bits); a missing group of a correctable pair, or a group off its
period, pulses ev_am_err; three missing in a row drop the lock;
- descrambling and reverse transcoding into groups on rx_out_*. A
transcoded block with header 0 and all flags 1, or a first control
block type nibble that is not one of the 11 clause 82 types, gives
four blocks with sync header 2'b11 (ev_itb); so does every block of
a pair in which a codeword was uncorrectable (the FEC's d_out_bad,
which cfg_bypass_ind turns off).
Not implemented: 64B/66B encoding, idle deletion / insertion, the
per-lane alignment marker lock, deskew and lane reordering, BIP-free
lane error counters, the FEC_degraded_SER detector, the 200GBASE-R
(8-lane) variant, the test-pattern generators, EEE.

Features:

- Transmit: 256B/257B transcoding of four 64B/66B blocks (clause 91.5.2.5 rules), the self-synchronizing scrambler 1 + x^39 + x^58 over all 257 bits, the alignment marker group every AMP pairs of codewords (16 lane markers of Table 119-2, 10-bit interleaved, 133-bit PRBS9 pad, 3 status bits; not scrambled), the 10-bit round-robin split into two 514-symbol messages, RS(544,514) encoding of each, and the 10-bit interleave of the two codewords onto 16 PCS lanes (119.2.4.2 to 119.2.4.7); bit-exact with the reference model scripts/ethpcs/pcs_ref.py.
- Receive: the inverse interleave, RS decoding of both codewords (up to 15 symbol errors each), alignment marker lock (found, expected every AMP pairs, lost after three missing groups), marker removal, descrambling and reverse transcoding; uncorrectable codewords and invalid transcoded blocks give blocks with sync header 11.
- Parameter AMP: pairs of codewords per marker period (4096 = 163840 blocks for 400GBASE-R; the wrapper and tests use a small value).

The core works on the de-skewed symbol stream: the per-lane block lock, deskew and lane reordering, 64B/66B encoding and decoding, idle deletion (the room for the markers: TX_IN is held during the marker slots) and the 200GBASE-R variant are outside it.
Through the registers a group takes 9 writes and a beat 21 reads, so the wrapper is for configuration, status and low-rate testing; at line rate the streams are driven directly.

## Files

| File | Content |
|---|---|
| `rtl/Ethernet_PCS_top.sv` | protocol core |
| `rtl/Ethernet_PCS_apb.sv` | APB4 register wrapper (generated) |
| `tb/Ethernet_PCS_tb.sv` | core testbench |
| `tb/Ethernet_PCS_apb_tb.sv`, `tb/apb/Ethernet_PCS_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Ethernet_PCS_sva.sv`, `tb/cov/Ethernet_PCS_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Ethernet_PCS.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`Ethernet_PCS_apb` has the core's parameters and passes them to `Ethernet_PCS_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AMP` | int | `4096` |

## Wrapper pins

Pins of `Ethernet_PCS_apb`. Widths of the pass-through pins are at the default parameters.

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

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_bypass_corr` | input | 1 | CTRL[0:0] |
| `cfg_bypass_ind` | input | 1 | CTRL[1:1] |
| `tx_am_sf` | input | 3 | CTRL[4:2] |
| `tx_in_valid` | input | 1 | TX_IN commit / FLAGS |
| `tx_in_data` | input | 264 | TX_IN0[31:0], TX_IN1[31:0], TX_IN2[31:0], TX_IN3[31:0], TX_IN4[31:0], TX_IN5[31:0], TX_IN6[31:0], TX_IN7[31:0], TX_IN8[7:0] |
| `tx_in_ready` | output | 1 | TX_IN handshake |
| `tx_out_valid` | output | 1 | TX_OUT capture |
| `tx_out_first` | output | 1 | TX_OUT20 |
| `tx_out_data` | output | 640 | TX_OUT0[31:0], TX_OUT1[31:0], TX_OUT2[31:0], TX_OUT3[31:0], TX_OUT4[31:0], TX_OUT5[31:0], TX_OUT6[31:0], TX_OUT7[31:0], TX_OUT8[31:0], TX_OUT9[31:0], TX_OUT10[31:0], TX_OUT11[31:0], TX_OUT12[31:0], TX_OUT13[31:0], TX_OUT14[31:0], TX_OUT15[31:0], TX_OUT16[31:0], TX_OUT17[31:0], TX_OUT18[31:0], TX_OUT19[31:0] |
| `tx_out_ready` | input | 1 | TX_OUT handshake |
| `rx_in_valid` | input | 1 | RX_IN commit / FLAGS |
| `rx_in_first` | input | 1 | RX_IN20 |
| `rx_in_data` | input | 640 | RX_IN0[31:0], RX_IN1[31:0], RX_IN2[31:0], RX_IN3[31:0], RX_IN4[31:0], RX_IN5[31:0], RX_IN6[31:0], RX_IN7[31:0], RX_IN8[31:0], RX_IN9[31:0], RX_IN10[31:0], RX_IN11[31:0], RX_IN12[31:0], RX_IN13[31:0], RX_IN14[31:0], RX_IN15[31:0], RX_IN16[31:0], RX_IN17[31:0], RX_IN18[31:0], RX_IN19[31:0] |
| `rx_in_ready` | output | 1 | RX_IN handshake |
| `rx_out_valid` | output | 1 | RX_OUT capture |
| `rx_out_data` | output | 264 | RX_OUT0[31:0], RX_OUT1[31:0], RX_OUT2[31:0], RX_OUT3[31:0], RX_OUT4[31:0], RX_OUT5[31:0], RX_OUT6[31:0], RX_OUT7[31:0], RX_OUT8[7:0] |
| `rx_out_ready` | input | 1 | RX_OUT handshake |
| `rx_am_lock` | output | 1 | STATUS[0:0] |
| `rx_am_sf` | output | 3 | STATUS[3:1] |
| `ev_am_err` | output | 1 | IRQ_STATUS.AM_ERR |
| `ev_itb` | output | 1 | IRQ_STATUS.ITB |
| `ev_corr_a` | output | 1 | IRQ_STATUS.CORR_A |
| `ev_corr_b` | output | 1 | IRQ_STATUS.CORR_B |
| `ev_uncorr_a` | output | 1 | IRQ_STATUS.UNCORR_A |
| `ev_uncorr_b` | output | 1 | IRQ_STATUS.UNCORR_B |
| `ev_resync` | output | 1 | IRQ_STATUS.RESYNC |
| `st_nsym_a` | output | 4 | STATUS[7:4] |
| `st_nsym_b` | output | 4 | STATUS[11:8] |

## APB wrapper

`Ethernet_PCS_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x45500100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Configuration |
| 0x018 | TX_IN0 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x01C | TX_IN1 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x020 | TX_IN2 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x024 | TX_IN3 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x028 | TX_IN4 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x02C | TX_IN5 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x030 | TX_IN6 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x034 | TX_IN7 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x038 | TX_IN8 | RW | 0x00000000 | Transmit group: four 66-bit blocks, block j at bits 66j+65:66j (sync header in the low 2 bits, bit 0 sent first); writing TX_IN8 commits it |
| 0x03C | TX_OUT0 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x040 | TX_OUT1 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x044 | TX_OUT2 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x048 | TX_OUT3 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x04C | TX_OUT4 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x050 | TX_OUT5 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x054 | TX_OUT6 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x058 | TX_OUT7 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x05C | TX_OUT8 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x060 | TX_OUT9 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x064 | TX_OUT10 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x068 | TX_OUT11 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x06C | TX_OUT12 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x070 | TX_OUT13 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x074 | TX_OUT14 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x078 | TX_OUT15 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x07C | TX_OUT16 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x080 | TX_OUT17 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x084 | TX_OUT18 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x088 | TX_OUT19 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x08C | TX_OUT20 | RO (pop) | 0x00000000 | Transmit beat: 64 symbols of the interleaved codeword pair, symbol n at bits 10n+9:10n (PCS lane n mod 16); TX_OUT20 bit 0 marks the first beat of a pair; reading TX_OUT20 pops it |
| 0x090 | RX_IN0 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x094 | RX_IN1 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x098 | RX_IN2 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x09C | RX_IN3 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0A0 | RX_IN4 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0A4 | RX_IN5 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0A8 | RX_IN6 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0AC | RX_IN7 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0B0 | RX_IN8 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0B4 | RX_IN9 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0B8 | RX_IN10 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0BC | RX_IN11 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0C0 | RX_IN12 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0C4 | RX_IN13 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0C8 | RX_IN14 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0CC | RX_IN15 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0D0 | RX_IN16 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0D4 | RX_IN17 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0D8 | RX_IN18 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0DC | RX_IN19 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0E0 | RX_IN20 | RW | 0x00000000 | Receive beat (de-skewed lanes, same layout as TX_OUT); RX_IN20 bit 0 marks the first beat of a pair; writing RX_IN20 commits it |
| 0x0E4 | RX_OUT0 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0E8 | RX_OUT1 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0EC | RX_OUT2 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0F0 | RX_OUT3 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0F4 | RX_OUT4 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0F8 | RX_OUT5 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x0FC | RX_OUT6 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x100 | RX_OUT7 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x104 | RX_OUT8 | RO (pop) | 0x00000000 | Receive group, same layout as TX_IN; reading RX_OUT8 pops it |
| 0x108 | STATUS | RO | core | Receive state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x10C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4550 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 12:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 12:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 3:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `cfg_bypass_corr` | RW | 0x0 | FEC correction off: data passes as received, codewords with errors are reported uncorrectable |
| CTRL | 1 | `cfg_bypass_ind` | RW | 0x0 | FEC error indication off: uncorrectable codewords do not corrupt the sync headers |
| CTRL | 4:2 | `tx_am_sf` | RW | 0x0 | the 3 status bits sent in every alignment marker group ({FEC_degraded_SER, 0, 0} in clause 119) |
| TX_IN0 | 31:0 | `tx_in_data[31:0]` | RW | 0x0 | four 66-bit blocks |
| TX_IN1 | 31:0 | `tx_in_data[63:32]` | RW | 0x0 | four 66-bit blocks |
| TX_IN2 | 31:0 | `tx_in_data[95:64]` | RW | 0x0 | four 66-bit blocks |
| TX_IN3 | 31:0 | `tx_in_data[127:96]` | RW | 0x0 | four 66-bit blocks |
| TX_IN4 | 31:0 | `tx_in_data[159:128]` | RW | 0x0 | four 66-bit blocks |
| TX_IN5 | 31:0 | `tx_in_data[191:160]` | RW | 0x0 | four 66-bit blocks |
| TX_IN6 | 31:0 | `tx_in_data[223:192]` | RW | 0x0 | four 66-bit blocks |
| TX_IN7 | 31:0 | `tx_in_data[255:224]` | RW | 0x0 | four 66-bit blocks |
| TX_IN8 | 7:0 | `tx_in_data[263:256]` | RW | 0x0 | four 66-bit blocks |
| TX_OUT0 | 31:0 | `tx_out_data[31:0]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT1 | 31:0 | `tx_out_data[63:32]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT2 | 31:0 | `tx_out_data[95:64]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT3 | 31:0 | `tx_out_data[127:96]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT4 | 31:0 | `tx_out_data[159:128]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT5 | 31:0 | `tx_out_data[191:160]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT6 | 31:0 | `tx_out_data[223:192]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT7 | 31:0 | `tx_out_data[255:224]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT8 | 31:0 | `tx_out_data[287:256]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT9 | 31:0 | `tx_out_data[319:288]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT10 | 31:0 | `tx_out_data[351:320]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT11 | 31:0 | `tx_out_data[383:352]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT12 | 31:0 | `tx_out_data[415:384]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT13 | 31:0 | `tx_out_data[447:416]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT14 | 31:0 | `tx_out_data[479:448]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT15 | 31:0 | `tx_out_data[511:480]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT16 | 31:0 | `tx_out_data[543:512]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT17 | 31:0 | `tx_out_data[575:544]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT18 | 31:0 | `tx_out_data[607:576]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT19 | 31:0 | `tx_out_data[639:608]` | RO (pop) | 0x0 | 64 10-bit symbols |
| TX_OUT20 | 0 | `tx_out_first` | RO (pop) | 0x0 | first beat of a pair |
| RX_IN0 | 31:0 | `rx_in_data[31:0]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN1 | 31:0 | `rx_in_data[63:32]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN2 | 31:0 | `rx_in_data[95:64]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN3 | 31:0 | `rx_in_data[127:96]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN4 | 31:0 | `rx_in_data[159:128]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN5 | 31:0 | `rx_in_data[191:160]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN6 | 31:0 | `rx_in_data[223:192]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN7 | 31:0 | `rx_in_data[255:224]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN8 | 31:0 | `rx_in_data[287:256]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN9 | 31:0 | `rx_in_data[319:288]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN10 | 31:0 | `rx_in_data[351:320]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN11 | 31:0 | `rx_in_data[383:352]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN12 | 31:0 | `rx_in_data[415:384]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN13 | 31:0 | `rx_in_data[447:416]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN14 | 31:0 | `rx_in_data[479:448]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN15 | 31:0 | `rx_in_data[511:480]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN16 | 31:0 | `rx_in_data[543:512]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN17 | 31:0 | `rx_in_data[575:544]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN18 | 31:0 | `rx_in_data[607:576]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN19 | 31:0 | `rx_in_data[639:608]` | RW | 0x0 | 64 10-bit symbols |
| RX_IN20 | 0 | `rx_in_first` | RW | 0x0 | first beat of a pair |
| RX_OUT0 | 31:0 | `rx_out_data[31:0]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT1 | 31:0 | `rx_out_data[63:32]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT2 | 31:0 | `rx_out_data[95:64]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT3 | 31:0 | `rx_out_data[127:96]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT4 | 31:0 | `rx_out_data[159:128]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT5 | 31:0 | `rx_out_data[191:160]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT6 | 31:0 | `rx_out_data[223:192]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT7 | 31:0 | `rx_out_data[255:224]` | RO (pop) | 0x0 | four 66-bit blocks |
| RX_OUT8 | 7:0 | `rx_out_data[263:256]` | RO (pop) | 0x0 | four 66-bit blocks |
| STATUS | 0 | `rx_am_lock` | RO | core | alignment marker lock |
| STATUS | 3:1 | `rx_am_sf` | RO | core | status bits of the last marker group received |
| STATUS | 7:4 | `st_nsym_a` | RO | core | symbols corrected in the last codeword A |
| STATUS | 11:8 | `st_nsym_b` | RO | core | symbols corrected in the last codeword B |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | AM_ERR | a marker group missing (correctable pair) or off its period |
| 1 | ITB | an invalid transcoded block (its four blocks come out with sync header 11) |
| 2 | CORR_A | codeword A corrected |
| 3 | CORR_B | codeword B corrected |
| 4 | UNCORR_A | codeword A uncorrectable |
| 5 | UNCORR_B | codeword B uncorrectable |
| 6 | RESYNC | RX_IN first beat in the middle of a pair: the pair was dropped |
| 7 | TX_IN_DONE | TX_IN beat accepted by the core |
| 8 | TX_IN_OVF | write to TX_IN while full (dropped) |
| 9 | TX_OUT_AVAIL | TX_OUT captured a beat |
| 10 | RX_IN_DONE | RX_IN beat accepted by the core |
| 11 | RX_IN_OVF | write to RX_IN while full (dropped) |
| 12 | RX_OUT_AVAIL | RX_OUT captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_IN_FULL | TX_IN holds a beat the core has not taken |
| 1 | TX_OUT_AVAIL | TX_OUT holds an unread beat |
| 2 | RX_IN_FULL | RX_IN holds a beat the core has not taken |
| 3 | RX_OUT_AVAIL | RX_OUT holds an unread beat |

### Streams

* **TX_IN** feeds `tx_in_data`/`tx_in_valid`. Writing TX_IN8 commits the beat: FLAGS.TX_IN_FULL is set and `tx_in_valid` stays high until the core's `tx_in_ready`; then TX_IN_DONE is set. A write while full is dropped and sets TX_IN_OVF.
* **TX_OUT** takes `tx_out_data`, `tx_out_first` from the core with `tx_out_valid` / `tx_out_ready`: `tx_out_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ TX_OUT_AVAIL. Reading TX_OUT20 pops it. Nothing is dropped: the core holds its data until the register is free.
* **RX_IN** feeds `rx_in_data`, `rx_in_first`/`rx_in_valid`. Writing RX_IN20 commits the beat: FLAGS.RX_IN_FULL is set and `rx_in_valid` stays high until the core's `rx_in_ready`; then RX_IN_DONE is set. A write while full is dropped and sets RX_IN_OVF.
* **RX_OUT** takes `rx_out_data` from the core with `rx_out_valid` / `rx_out_ready`: `rx_out_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_OUT_AVAIL. Reading RX_OUT8 pops it. Nothing is dropped: the core holds its data until the register is free.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x45500100.
2. Write 0x1FFF to IRQ_STATUS (0x004) to clear any stale bits (TX_OUT_AVAIL may be set as soon as reset ends).
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FFF enables all).
5. To send on TX_IN: wait until FLAGS.TX_IN_FULL (bit 0) is 0, or for IRQ TX_IN_DONE, then write TX_IN0 (0x018) then TX_IN1 (0x01C) then TX_IN2 (0x020) then TX_IN3 (0x024) then TX_IN4 (0x028) then TX_IN5 (0x02C) then TX_IN6 (0x030) then TX_IN7 (0x034) then TX_IN8 (0x038). The last write commits the beat. TX_IN_OVF means a write came while the register was full and was dropped.
6. To receive on TX_OUT: wait for IRQ TX_OUT_AVAIL or FLAGS.TX_OUT_AVAIL (bit 1), then read TX_OUT0 (0x03C) then TX_OUT1 (0x040) then TX_OUT2 (0x044) then TX_OUT3 (0x048) then TX_OUT4 (0x04C) then TX_OUT5 (0x050) then TX_OUT6 (0x054) then TX_OUT7 (0x058) then TX_OUT8 (0x05C) then TX_OUT9 (0x060) then TX_OUT10 (0x064) then TX_OUT11 (0x068) then TX_OUT12 (0x06C) then TX_OUT13 (0x070) then TX_OUT14 (0x074) then TX_OUT15 (0x078) then TX_OUT16 (0x07C) then TX_OUT17 (0x080) then TX_OUT18 (0x084) then TX_OUT19 (0x088) then TX_OUT20 (0x08C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.TX_OUT_AVAIL (bit 9) to clear it.
7. To send on RX_IN: wait until FLAGS.RX_IN_FULL (bit 2) is 0, or for IRQ RX_IN_DONE, then write RX_IN0 (0x090) then RX_IN1 (0x094) then RX_IN2 (0x098) then RX_IN3 (0x09C) then RX_IN4 (0x0A0) then RX_IN5 (0x0A4) then RX_IN6 (0x0A8) then RX_IN7 (0x0AC) then RX_IN8 (0x0B0) then RX_IN9 (0x0B4) then RX_IN10 (0x0B8) then RX_IN11 (0x0BC) then RX_IN12 (0x0C0) then RX_IN13 (0x0C4) then RX_IN14 (0x0C8) then RX_IN15 (0x0CC) then RX_IN16 (0x0D0) then RX_IN17 (0x0D4) then RX_IN18 (0x0D8) then RX_IN19 (0x0DC) then RX_IN20 (0x0E0). The last write commits the beat. RX_IN_OVF means a write came while the register was full and was dropped.
8. To receive on RX_OUT: wait for IRQ RX_OUT_AVAIL or FLAGS.RX_OUT_AVAIL (bit 3), then read RX_OUT0 (0x0E4) then RX_OUT1 (0x0E8) then RX_OUT2 (0x0EC) then RX_OUT3 (0x0F0) then RX_OUT4 (0x0F4) then RX_OUT5 (0x0F8) then RX_OUT6 (0x0FC) then RX_OUT7 (0x100) then RX_OUT8 (0x104). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_OUT_AVAIL (bit 12) to clear it.
9. Read STATUS (0x108) for the core's live `rx_am_lock`, `rx_am_sf`, `st_nsym_a`, `st_nsym_b`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL; for each group write TX_IN0..TX_IN8 (TX_IN8 commits), and read beats from TX_OUT0..TX_OUT20 (TX_OUT20 pops) when FLAGS says one is available.
2. Receive: write each beat to RX_IN0..RX_IN20 (RX_IN20 commits, bit 0 = first beat of a pair); STATUS.rx_am_lock comes up at the first marker group; read groups from RX_OUT0..RX_OUT8.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Ethernet_PCS sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Ethernet_PCS syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Ethernet_PCS_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Ethernet_PCS apb` | `TEST PASSED: Ethernet_PCS_apb`, then Yosys without `ERROR` | console, `work/Ethernet_PCS_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Ethernet_PCS`<br>`bash scripts/cov/run_cov.sh Ethernet_PCS_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Ethernet_PCS/score.json`, `work/cov/Ethernet_PCS_apb/score.json` |

Expected end of a step 4 run:

```
===== Ethernet_PCS =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Ethernet_PCS_tb.sv`): drives `Ethernet_PCS_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Ethernet_PCS_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Ethernet_PCS_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Ethernet_PCS_sva.sv`, `tb/cov/Ethernet_PCS_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Ethernet_PCS_top.sv` | pass | 158/158 | 10340/10340 (+8 excl.) | 9/9 | 14/14 | 41/41 |
| wrapper `rtl/Ethernet_PCS_apb.sv` | pass | 156/156 | 5356/5356 | n/a | 44/44 | 211/211 |

Transmit vectors from the reference model (9 pairs, all block mixes and invalid sync headers) compared beat by beat; receive vectors with correctable and uncorrectable codewords, invalid transcoded blocks, a marker group off its period, missing groups, a lock loss and a relock; loopback through both directions with random symbol errors, stalls on every port, bypass modes, realignment and resets in flight.
The core checker has its own marker table, transcoder, scrambler, PRBS9, GF(2^10) and RS encoder written bit by bit from clause 119, and checks every beat out, every group out, the lock state, status bits and events.
