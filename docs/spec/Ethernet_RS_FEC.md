<!-- SPDX-License-Identifier: Apache-2.0 -->
# Ethernet_RS_FEC: design specification

The Ethernet RS(544,514) "KP4" FEC (IEEE 802.3 clauses 91 / 119 / 172 codeword): an encoder and a
full-rate decoder, 32 ten-bit symbols per clock, one codeword in 17 clocks, with correction of up to
15 symbol errors, uncorrectable detection, correction and indication bypass, and event outputs. Not
implemented: the clause 45 statistics counters (built from the events outside) and the
reduced-latency bypass. `Ethernet_PCS` uses two of these cores. Core `Ethernet_RS_FEC_top`
(`rtl/Ethernet_RS_FEC_top.sv`), testbench `tb/Ethernet_RS_FEC_tb.sv` (reference vectors plus random
loopback), checker `tb/cov/Ethernet_RS_FEC_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. GF(2^10) with x^10 + x^3 + 1, alpha = x. A codeword c(x) has degree
543; the first transmitted symbol is the coefficient of x^543. Beat b carries codeword symbols
32b .. 32b + 31, symbol k of a beat at bits [10k +: 10].

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_bypass_corr` | input | 1 | decoder: no correction; codewords with a non-zero syndrome are reported bad (sampled per codeword at the correction pass) | high | `clk` | - |
| `cfg_bypass_ind` | input | 1 | decoder: never set `d_out_bad` (sampled per codeword) | high | `clk` | - |
| `e_in_valid` | input | 1 | encoder input beat valid | high | `clk` | - |
| `e_in_first` | input | 1 | the beat is beat 0 of a codeword (only needed to align or realign) | high | `clk` | - |
| `e_in_data` | input | 320 | 32 message symbols, symbol k at [10k +: 10], the first transmitted first | - | `clk` | - |
| `e_in_ready` | output | 1 | = !`e_out_valid` \|\| `e_out_ready`; combinational | high | comb | 1 |
| `e_out_valid` | output | 1 | encoder output beat valid | high | `clk` | 0 |
| `e_out_first` | output | 1 | output beat 0 | high | `clk` | 0 |
| `e_out_data` | output | 320 | codeword beat (beat 16: 2 message symbols then 30 parity symbols) | - | `clk` | 0 |
| `e_out_ready` | input | 1 | downstream takes the encoder output | high | `clk` | - |
| `d_in_valid` | input | 1 | decoder input beat valid | high | `clk` | - |
| `d_in_first` | input | 1 | beat 0 of a received codeword | high | `clk` | - |
| `d_in_data` | input | 320 | received symbols, layout as the encoder output | - | `clk` | - |
| `d_in_ready` | output | 1 | = !`d_out_valid` \|\| `d_out_ready`; combinational | high | comb | 1 |
| `d_out_valid` | output | 1 | decoded beat valid | high | `clk` | 0 |
| `d_out_first` | output | 1 | decoded beat 0 | high | `clk` | 0 |
| `d_out_bad` | output | 1 | every beat of an uncorrectable codeword (unless `cfg_bypass_ind`) | high | `clk` | 0 |
| `d_out_data` | output | 320 | corrected codeword beat (all 32 symbols, parity included) | - | `clk` | 0 |
| `d_out_ready` | input | 1 | downstream takes the decoder output | high | `clk` | - |
| `ev_corr` | output | 1 | one-clock pulse: a codeword had 1..15 symbols corrected | high | `clk` | 0 |
| `ev_uncorr` | output | 1 | one-clock pulse: a codeword was uncorrectable (bypass: non-zero syndrome) | high | `clk` | 0 |
| `ev_eresync` | output | 1 | one-clock pulse: `e_in_first` in the middle of a codeword | high | `clk` | 0 |
| `ev_dresync` | output | 1 | one-clock pulse: `d_in_first` in the middle of a codeword | high | `clk` | 0 |
| `st_nsym` | output | 4 | symbols corrected in the last codeword that reached the correction pass (0 when not corrected) | - | `clk` | 0 |

### Internal signals used by the verification

The bound checker (`.*`) connects these decoder stage controls to check that the pipeline never
overruns; fsm_cov binds `bst`, `p1st` and `p2st`. Keep the names and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `dce` | 1 | decoder clock enable: !`d_out_valid` \|\| `d_out_ready` (the whole decoder holds otherwise) |
| `dacc` | 1 | a decoder input beat is accepted (`d_in_valid` && `dce`) |
| `bload` | 1 | `dacc` on beat 16: the codeword's syndromes go to riBM |
| `bst` | 2 | riBM: 0 IDLE, 1 RUN (15 clocks), 2 DONE |
| `p1load` | 1 | Chien pass 1 loads (riBM DONE) |
| `p1st` | 1 | pass 1: 0 IDLE, 1 RUN |
| `p1last` | 1 | pass 1 on its last beat (16) |
| `p1long` | 1 | the riBM length L exceeds 15 |
| `p2load` | 1 | pass 2 loads (= `p1last`) |
| `p2st` | 1 | pass 2: 0 IDLE, 1 RUN |
| `p2b` | 5 | pass 2 beat, 0..16 |
| `wsl` | 2 | codeword buffer slot being written by the input |
| `p2sl` | 2 | slot read by pass 2 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Ethernet_RS_FEC.md`](../ip/Ethernet_RS_FEC.md) (source: `scripts/apb/specs/Ethernet_RS_FEC.json`); do not edit by hand.

`Ethernet_RS_FEC_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x52530100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Decoder options (taken when a codeword reaches the correction pass) |
| 0x018 | ENC_IN0 | RW | 0x00000000 | Encoder input beat: 32 message symbols (beats 0..15) or 2 (beat 16, symbols 0..1); writing the last word sends it |
| 0x01C | ENC_IN1 | RW | 0x00000000 | Encoder input beat: 32 message symbols (beats 0..15) or 2 (beat 16, symbols 0..1); writing the last word sends it |
| 0x020 | ENC_IN2 | RW | 0x00000000 | Encoder input beat: 32 message symbols (beats 0..15) or 2 (beat 16, symbols 0..1); writing the last word sends it |
| 0x024 | ENC_IN3 | RW | 0x00000000 | Encoder input beat: 32 message symbols (beats 0..15) or 2 (beat 16, symbols 0..1); writing the last word sends it |
| 0x028 | ENC_IN4 | RW | 0x00000000 | Encoder input beat: 32 message symbols (beats 0..15) or 2 (beat 16, symbols 0..1); writing the last word sends it |
| 0x02C | ENC_IN5 | RW | 0x00000000 | Encoder input beat: 32 message symbols (beats 0..15) or 2 (beat 16, symbols 0..1); writing the last word sends it |
| 0x030 | ENC_IN6 | RW | 0x00000000 | Encoder input beat: 32 message symbols (beats 0..15) or 2 (beat 16, symbols 0..1); writing the last word sends it |
| 0x034 | ENC_IN7 | RW | 0x00000000 | Encoder input beat: 32 message symbols (beats 0..15) or 2 (beat 16, symbols 0..1); writing the last word sends it |
| 0x038 | ENC_IN8 | RW | 0x00000000 | Encoder input beat: 32 message symbols (beats 0..15) or 2 (beat 16, symbols 0..1); writing the last word sends it |
| 0x03C | ENC_IN9 | RW | 0x00000000 | Encoder input beat: 32 message symbols (beats 0..15) or 2 (beat 16, symbols 0..1); writing the last word sends it |
| 0x040 | ENC_IN10 | RW | 0x00000000 | Encoder input beat: 32 message symbols (beats 0..15) or 2 (beat 16, symbols 0..1); writing the last word sends it |
| 0x044 | ENC_OUT0 | RO (pop) | 0x00000000 | Encoder output beat: the message passed through, beat 16 with the 30 parity symbols in symbols 2..31; reading the last word pops it |
| 0x048 | ENC_OUT1 | RO (pop) | 0x00000000 | Encoder output beat: the message passed through, beat 16 with the 30 parity symbols in symbols 2..31; reading the last word pops it |
| 0x04C | ENC_OUT2 | RO (pop) | 0x00000000 | Encoder output beat: the message passed through, beat 16 with the 30 parity symbols in symbols 2..31; reading the last word pops it |
| 0x050 | ENC_OUT3 | RO (pop) | 0x00000000 | Encoder output beat: the message passed through, beat 16 with the 30 parity symbols in symbols 2..31; reading the last word pops it |
| 0x054 | ENC_OUT4 | RO (pop) | 0x00000000 | Encoder output beat: the message passed through, beat 16 with the 30 parity symbols in symbols 2..31; reading the last word pops it |
| 0x058 | ENC_OUT5 | RO (pop) | 0x00000000 | Encoder output beat: the message passed through, beat 16 with the 30 parity symbols in symbols 2..31; reading the last word pops it |
| 0x05C | ENC_OUT6 | RO (pop) | 0x00000000 | Encoder output beat: the message passed through, beat 16 with the 30 parity symbols in symbols 2..31; reading the last word pops it |
| 0x060 | ENC_OUT7 | RO (pop) | 0x00000000 | Encoder output beat: the message passed through, beat 16 with the 30 parity symbols in symbols 2..31; reading the last word pops it |
| 0x064 | ENC_OUT8 | RO (pop) | 0x00000000 | Encoder output beat: the message passed through, beat 16 with the 30 parity symbols in symbols 2..31; reading the last word pops it |
| 0x068 | ENC_OUT9 | RO (pop) | 0x00000000 | Encoder output beat: the message passed through, beat 16 with the 30 parity symbols in symbols 2..31; reading the last word pops it |
| 0x06C | ENC_OUT10 | RO (pop) | 0x00000000 | Encoder output beat: the message passed through, beat 16 with the 30 parity symbols in symbols 2..31; reading the last word pops it |
| 0x070 | DEC_IN0 | RW | 0x00000000 | Decoder input beat: 32 received symbols; writing the last word sends it |
| 0x074 | DEC_IN1 | RW | 0x00000000 | Decoder input beat: 32 received symbols; writing the last word sends it |
| 0x078 | DEC_IN2 | RW | 0x00000000 | Decoder input beat: 32 received symbols; writing the last word sends it |
| 0x07C | DEC_IN3 | RW | 0x00000000 | Decoder input beat: 32 received symbols; writing the last word sends it |
| 0x080 | DEC_IN4 | RW | 0x00000000 | Decoder input beat: 32 received symbols; writing the last word sends it |
| 0x084 | DEC_IN5 | RW | 0x00000000 | Decoder input beat: 32 received symbols; writing the last word sends it |
| 0x088 | DEC_IN6 | RW | 0x00000000 | Decoder input beat: 32 received symbols; writing the last word sends it |
| 0x08C | DEC_IN7 | RW | 0x00000000 | Decoder input beat: 32 received symbols; writing the last word sends it |
| 0x090 | DEC_IN8 | RW | 0x00000000 | Decoder input beat: 32 received symbols; writing the last word sends it |
| 0x094 | DEC_IN9 | RW | 0x00000000 | Decoder input beat: 32 received symbols; writing the last word sends it |
| 0x098 | DEC_IN10 | RW | 0x00000000 | Decoder input beat: 32 received symbols; writing the last word sends it |
| 0x09C | DEC_OUT0 | RO (pop) | 0x00000000 | Decoder output beat: the corrected symbols; reading the last word pops it |
| 0x0A0 | DEC_OUT1 | RO (pop) | 0x00000000 | Decoder output beat: the corrected symbols; reading the last word pops it |
| 0x0A4 | DEC_OUT2 | RO (pop) | 0x00000000 | Decoder output beat: the corrected symbols; reading the last word pops it |
| 0x0A8 | DEC_OUT3 | RO (pop) | 0x00000000 | Decoder output beat: the corrected symbols; reading the last word pops it |
| 0x0AC | DEC_OUT4 | RO (pop) | 0x00000000 | Decoder output beat: the corrected symbols; reading the last word pops it |
| 0x0B0 | DEC_OUT5 | RO (pop) | 0x00000000 | Decoder output beat: the corrected symbols; reading the last word pops it |
| 0x0B4 | DEC_OUT6 | RO (pop) | 0x00000000 | Decoder output beat: the corrected symbols; reading the last word pops it |
| 0x0B8 | DEC_OUT7 | RO (pop) | 0x00000000 | Decoder output beat: the corrected symbols; reading the last word pops it |
| 0x0BC | DEC_OUT8 | RO (pop) | 0x00000000 | Decoder output beat: the corrected symbols; reading the last word pops it |
| 0x0C0 | DEC_OUT9 | RO (pop) | 0x00000000 | Decoder output beat: the corrected symbols; reading the last word pops it |
| 0x0C4 | DEC_OUT10 | RO (pop) | 0x00000000 | Decoder output beat: the corrected symbols; reading the last word pops it |
| 0x0C8 | STATUS | RO | core | Last codeword decoded |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x0CC up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5253 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 9:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 9:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 3:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `cfg_bypass_corr` | RW | 0x0 | bypass correction: the data passes unchanged and every codeword with a non-zero syndrome is reported bad |
| CTRL | 1 | `cfg_bypass_ind` | RW | 0x0 | bypass indication: uncorrectable codewords are not marked on DEC_OUT.d_out_bad (the UNCORR interrupt still fires) |
| ENC_IN0 | 31:0 | `e_in_data[31:0]` | RW | 0x0 | symbols, symbol k at bits 10k + 9 .. 10k |
| ENC_IN1 | 31:0 | `e_in_data[63:32]` | RW | 0x0 | symbols, symbol k at bits 10k + 9 .. 10k |
| ENC_IN2 | 31:0 | `e_in_data[95:64]` | RW | 0x0 | symbols, symbol k at bits 10k + 9 .. 10k |
| ENC_IN3 | 31:0 | `e_in_data[127:96]` | RW | 0x0 | symbols, symbol k at bits 10k + 9 .. 10k |
| ENC_IN4 | 31:0 | `e_in_data[159:128]` | RW | 0x0 | symbols, symbol k at bits 10k + 9 .. 10k |
| ENC_IN5 | 31:0 | `e_in_data[191:160]` | RW | 0x0 | symbols, symbol k at bits 10k + 9 .. 10k |
| ENC_IN6 | 31:0 | `e_in_data[223:192]` | RW | 0x0 | symbols, symbol k at bits 10k + 9 .. 10k |
| ENC_IN7 | 31:0 | `e_in_data[255:224]` | RW | 0x0 | symbols, symbol k at bits 10k + 9 .. 10k |
| ENC_IN8 | 31:0 | `e_in_data[287:256]` | RW | 0x0 | symbols, symbol k at bits 10k + 9 .. 10k |
| ENC_IN9 | 31:0 | `e_in_data[319:288]` | RW | 0x0 | symbols, symbol k at bits 10k + 9 .. 10k |
| ENC_IN10 | 0 | `e_in_first` | RW | 0x0 | beat 0 of a codeword (realigns the beat counter) |
| ENC_OUT0 | 31:0 | `e_out_data[31:0]` | RO (pop) | 0x0 | symbols |
| ENC_OUT1 | 31:0 | `e_out_data[63:32]` | RO (pop) | 0x0 | symbols |
| ENC_OUT2 | 31:0 | `e_out_data[95:64]` | RO (pop) | 0x0 | symbols |
| ENC_OUT3 | 31:0 | `e_out_data[127:96]` | RO (pop) | 0x0 | symbols |
| ENC_OUT4 | 31:0 | `e_out_data[159:128]` | RO (pop) | 0x0 | symbols |
| ENC_OUT5 | 31:0 | `e_out_data[191:160]` | RO (pop) | 0x0 | symbols |
| ENC_OUT6 | 31:0 | `e_out_data[223:192]` | RO (pop) | 0x0 | symbols |
| ENC_OUT7 | 31:0 | `e_out_data[255:224]` | RO (pop) | 0x0 | symbols |
| ENC_OUT8 | 31:0 | `e_out_data[287:256]` | RO (pop) | 0x0 | symbols |
| ENC_OUT9 | 31:0 | `e_out_data[319:288]` | RO (pop) | 0x0 | symbols |
| ENC_OUT10 | 0 | `e_out_first` | RO (pop) | 0x0 | beat 0 of a codeword |
| DEC_IN0 | 31:0 | `d_in_data[31:0]` | RW | 0x0 | symbols |
| DEC_IN1 | 31:0 | `d_in_data[63:32]` | RW | 0x0 | symbols |
| DEC_IN2 | 31:0 | `d_in_data[95:64]` | RW | 0x0 | symbols |
| DEC_IN3 | 31:0 | `d_in_data[127:96]` | RW | 0x0 | symbols |
| DEC_IN4 | 31:0 | `d_in_data[159:128]` | RW | 0x0 | symbols |
| DEC_IN5 | 31:0 | `d_in_data[191:160]` | RW | 0x0 | symbols |
| DEC_IN6 | 31:0 | `d_in_data[223:192]` | RW | 0x0 | symbols |
| DEC_IN7 | 31:0 | `d_in_data[255:224]` | RW | 0x0 | symbols |
| DEC_IN8 | 31:0 | `d_in_data[287:256]` | RW | 0x0 | symbols |
| DEC_IN9 | 31:0 | `d_in_data[319:288]` | RW | 0x0 | symbols |
| DEC_IN10 | 0 | `d_in_first` | RW | 0x0 | beat 0 of a codeword (realigns the beat counter) |
| DEC_OUT0 | 31:0 | `d_out_data[31:0]` | RO (pop) | 0x0 | symbols |
| DEC_OUT1 | 31:0 | `d_out_data[63:32]` | RO (pop) | 0x0 | symbols |
| DEC_OUT2 | 31:0 | `d_out_data[95:64]` | RO (pop) | 0x0 | symbols |
| DEC_OUT3 | 31:0 | `d_out_data[127:96]` | RO (pop) | 0x0 | symbols |
| DEC_OUT4 | 31:0 | `d_out_data[159:128]` | RO (pop) | 0x0 | symbols |
| DEC_OUT5 | 31:0 | `d_out_data[191:160]` | RO (pop) | 0x0 | symbols |
| DEC_OUT6 | 31:0 | `d_out_data[223:192]` | RO (pop) | 0x0 | symbols |
| DEC_OUT7 | 31:0 | `d_out_data[255:224]` | RO (pop) | 0x0 | symbols |
| DEC_OUT8 | 31:0 | `d_out_data[287:256]` | RO (pop) | 0x0 | symbols |
| DEC_OUT9 | 31:0 | `d_out_data[319:288]` | RO (pop) | 0x0 | symbols |
| DEC_OUT10 | 0 | `d_out_first` | RO (pop) | 0x0 | beat 0 of a codeword |
| DEC_OUT10 | 1 | `d_out_bad` | RO (pop) | 0x0 | the codeword is uncorrectable (unless CTRL.cfg_bypass_ind) |
| STATUS | 3:0 | `st_nsym` | RO | core | symbols corrected in the last codeword that reached the correction pass |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CORR | a codeword was corrected (STATUS.st_nsym symbols) |
| 1 | UNCORR | an uncorrectable codeword (with correction bypassed: a codeword with errors) |
| 2 | ERESYNC | ENC_IN beat 0 (first) in the middle of a codeword: the partial codeword was dropped |
| 3 | DRESYNC | DEC_IN beat 0 (first) in the middle of a codeword: the partial codeword was dropped |
| 4 | ENC_IN_DONE | ENC_IN beat accepted by the core |
| 5 | ENC_IN_OVF | write to ENC_IN while full (dropped) |
| 6 | ENC_OUT_AVAIL | ENC_OUT captured a beat |
| 7 | DEC_IN_DONE | DEC_IN beat accepted by the core |
| 8 | DEC_IN_OVF | write to DEC_IN while full (dropped) |
| 9 | DEC_OUT_AVAIL | DEC_OUT captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | ENC_IN_FULL | ENC_IN holds a beat the core has not taken |
| 1 | ENC_OUT_AVAIL | ENC_OUT holds an unread beat |
| 2 | DEC_IN_FULL | DEC_IN holds a beat the core has not taken |
| 3 | DEC_OUT_AVAIL | DEC_OUT holds an unread beat |

### Streams

* **ENC_IN** feeds `e_in_data`, `e_in_first`/`e_in_valid`. Writing ENC_IN10 commits the beat: FLAGS.ENC_IN_FULL is set and `e_in_valid` stays high until the core's `e_in_ready`; then ENC_IN_DONE is set. A write while full is dropped and sets ENC_IN_OVF.
* **ENC_OUT** takes `e_out_data`, `e_out_first` from the core with `e_out_valid` / `e_out_ready`: `e_out_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ ENC_OUT_AVAIL. Reading ENC_OUT10 pops it. Nothing is dropped: the core holds its data until the register is free.
* **DEC_IN** feeds `d_in_data`, `d_in_first`/`d_in_valid`. Writing DEC_IN10 commits the beat: FLAGS.DEC_IN_FULL is set and `d_in_valid` stays high until the core's `d_in_ready`; then DEC_IN_DONE is set. A write while full is dropped and sets DEC_IN_OVF.
* **DEC_OUT** takes `d_out_data`, `d_out_first`, `d_out_bad` from the core with `d_out_valid` / `d_out_ready`: `d_out_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ DEC_OUT_AVAIL. Reading DEC_OUT10 pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x52530100.
2. Write 0x3FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3FF enables all).
5. To send on ENC_IN: wait until FLAGS.ENC_IN_FULL (bit 0) is 0, or for IRQ ENC_IN_DONE, then write ENC_IN0 (0x018) then ENC_IN1 (0x01C) then ENC_IN2 (0x020) then ENC_IN3 (0x024) then ENC_IN4 (0x028) then ENC_IN5 (0x02C) then ENC_IN6 (0x030) then ENC_IN7 (0x034) then ENC_IN8 (0x038) then ENC_IN9 (0x03C) then ENC_IN10 (0x040). The last write commits the beat. ENC_IN_OVF means a write came while the register was full and was dropped.
6. To receive on ENC_OUT: wait for IRQ ENC_OUT_AVAIL or FLAGS.ENC_OUT_AVAIL (bit 1), then read ENC_OUT0 (0x044) then ENC_OUT1 (0x048) then ENC_OUT2 (0x04C) then ENC_OUT3 (0x050) then ENC_OUT4 (0x054) then ENC_OUT5 (0x058) then ENC_OUT6 (0x05C) then ENC_OUT7 (0x060) then ENC_OUT8 (0x064) then ENC_OUT9 (0x068) then ENC_OUT10 (0x06C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.ENC_OUT_AVAIL (bit 6) to clear it.
7. To send on DEC_IN: wait until FLAGS.DEC_IN_FULL (bit 2) is 0, or for IRQ DEC_IN_DONE, then write DEC_IN0 (0x070) then DEC_IN1 (0x074) then DEC_IN2 (0x078) then DEC_IN3 (0x07C) then DEC_IN4 (0x080) then DEC_IN5 (0x084) then DEC_IN6 (0x088) then DEC_IN7 (0x08C) then DEC_IN8 (0x090) then DEC_IN9 (0x094) then DEC_IN10 (0x098). The last write commits the beat. DEC_IN_OVF means a write came while the register was full and was dropped.
8. To receive on DEC_OUT: wait for IRQ DEC_OUT_AVAIL or FLAGS.DEC_OUT_AVAIL (bit 3), then read DEC_OUT0 (0x09C) then DEC_OUT1 (0x0A0) then DEC_OUT2 (0x0A4) then DEC_OUT3 (0x0A8) then DEC_OUT4 (0x0AC) then DEC_OUT5 (0x0B0) then DEC_OUT6 (0x0B4) then DEC_OUT7 (0x0B8) then DEC_OUT8 (0x0BC) then DEC_OUT9 (0x0C0) then DEC_OUT10 (0x0C4). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.DEC_OUT_AVAIL (bit 9) to clear it.
9. Read STATUS (0x0C8) for the core's live `st_nsym`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Set CTRL (both bypasses 0 for normal operation); enable the interrupts wanted.
2. Encode: write 17 beats to ENC_IN (first set on beat 0), reading ENC_OUT after each beat (ENC_IN is held while ENC_OUT is full).
3. Decode: write 17 beats to DEC_IN; the corrected codeword comes out of DEC_OUT, 17 beats, about 36 clocks after the last beat in; CORR / UNCORR and STATUS.st_nsym report it.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Encoder

g(x) = prod_{j=0..29} (x - alpha^j); systematic: c(x) = m(x) x^30 + (m(x) x^30 mod g(x)). Beats
0..15 carry 32 message symbols each and pass through; beat 16 carries the last 2 message symbols
in symbols 0..1 and leaves with the 30 parity symbols (the coefficient of x^29 first) in symbols
2..31; whatever is in symbols 2..31 of input beat 16 is replaced. Latency: one clock (registered).
`e_in_ready` = !`e_out_valid` \|\| `e_out_ready`; with `e_out_ready` low and an output waiting, the
encoder holds. A beat counter keeps the alignment; `e_in_first` restarts it at beat 0.

### 3.2 Decoding

Syndromes S_j = c(alpha^j), j = 0..29. Error locator Lambda and evaluator Omega by the
reformulated inversionless Berlekamp-Massey algorithm; the codeword is uncorrectable when L > 15 or
the number of roots of Lambda among the 544 positions differs from L. Error values by Forney:
e = X^-30 Omega(X^-1) / (X^-1 Lambda'(X^-1)) at each root X^-1. A correctable codeword is output
with the errors corrected (parity symbols too); otherwise unchanged.

### 3.3 Decoder pipeline

| Stage | Duration |
|---|---|
| input: syndromes, beat written to a 4-codeword buffer | 17 clocks (one beat per clock) |
| riBM (two iterations per clock), loaded with the beat-16 syndromes | 15 clocks RUN + 1 DONE |
| Chien pass 1: count roots | 17 clocks |
| Chien pass 2 + Forney + buffer read | 17 clocks |
| output register | 1 clock |

Latency: 36 clocks from the last input beat to the first output beat; each stage takes a new
codeword every 17 clocks, so back-to-back input codewords come out back to back. Every stage runs
only while `dce` = !`d_out_valid` \|\| `d_out_ready`; `d_in_ready` = `dce`. `d_out_first` marks
beat 0; `d_out_bad` is the codeword's mark on all 17 beats.

### 3.4 Events and bypass

At the last beat of pass 1 (two clocks before the codeword's first output beat), with `unc` = the
uncorrectable condition and `nz` = non-zero syndrome:

| | normal | `cfg_bypass_corr` |
|---|---|---|
| correction applied | !`unc` | none |
| `d_out_bad` (unless `cfg_bypass_ind`) | `unc` | `nz` |
| `ev_corr` | !`unc` && L != 0 | 0 |
| `ev_uncorr` | `unc` | `nz` |
| `st_nsym` | L when corrected, else 0 | 0 |

The bypass inputs are sampled at that moment, per codeword.

### 3.5 Realignment

`e_in_first` (`d_in_first`) on an accepted beat whose counter is not 0 drops the codeword being
collected, starts a new one at beat 0 and pulses `ev_eresync` (`ev_dresync`) in the next clock.
The dropped codeword produces no output and no event.

### 3.6 Reset

Both output valids 0, all events 0, `st_nsym` = 0, beat counters 0, decoder stages idle. Codewords in
flight are lost.

## 4. Parameters

None.

## 5. Errors and corner cases

Up to 15 symbol errors are corrected. Beyond that the decoder normally detects the failure (L > 15
or a root-count mismatch) and marks the codeword; as with any RS decoder, a pattern can also
decode to a wrong codeword without detection. Lambda(0) is a product of discrepancies and never 0.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "d_out_first" | `d_out_first` exactly on beat 0 of each decoded codeword | §3.3 |
| "d_out_bad changes inside a codeword" | `d_out_bad` is constant over the 17 beats | §3.3 |
| "decoder: unexpected codeword" | no output without an input codeword | §3.3 |
| "decoder codeword" | each decoded codeword and its bad flag equal the reference | §3.2, §3.3 |
| "unexpected event" | no event without a codeword | §3.4 |
| "events {corr, uncorr, nsym}" | `ev_corr`, `ev_uncorr`, `st_nsym` per codeword | §3.4 |
| "encoder vector" | each encoded codeword equals the reference | §3.1 |
| "encoder: message not passed through" | the 514 message symbols pass unchanged | §3.1 |
| "burst: output gap after" | back-to-back input gives back-to-back output at fixed latency | §3.3 |
| "resync events" | one resync pulse per mid-codeword `*_first` | §3.5 |
| a_e_ready | `e_in_ready` = !`e_out_valid` \|\| `e_out_ready` | §3.1 |
| a_d_ready | `d_in_ready` = !`d_out_valid` \|\| `d_out_ready` | §3.3 |
| a_e_hold | a stalled encoder output holds | §3.1 |
| a_d_hold | a stalled decoder output holds | §3.3 |
| a_encoder | every encoder output beat equals the checker's encoder | §3.1 |
| a_decoder | every decoder output beat equals the checker's decoder | §3.2, §3.3 |
| a_events | `ev_corr` / `ev_uncorr` as the model | §3.4 |
| a_nsym | `st_nsym` as the model | §3.4 |
| a_eresync | `ev_eresync` | §3.5 |
| a_dresync | `ev_dresync` | §3.5 |
| a_bm_free | a new codeword never enters riBM while it is running | §3.3 |
| a_chien1_free | Chien pass 1 is free (or on its last beat) when loaded | §3.3 |
| a_chien2_free | pass 2 is free (or on its last beat) when loaded | §3.3 |
| a_buffer_slot | the slot being written is never the one pass 2 reads | §3.3 |
| a_reset | reset values | §3.6 |
