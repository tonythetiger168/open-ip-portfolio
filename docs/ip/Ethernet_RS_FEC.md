# Ethernet RS(544,514) "KP4" FEC: encoder and decoder at 32 symbols (320 bits) per clock, one codeword in 17 clocks, with syndrome, riBM, two-pass Chien / Forney correction and uncorrectable-codeword marking

Protocol IP `Ethernet_RS_FEC`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Ethernet_RS_FEC_top` (`rtl/Ethernet_RS_FEC_top.sv`) |
| Register interface | APB4 slave `Ethernet_RS_FEC_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x52530100 (code 0x5253, version 1.0) |
| Registers | 51 words, 0x000 to 0x0C8 |
| Interrupts | 10 sources into one level-high `irq` |
| Data streams | ENC_IN (to the core), ENC_OUT (from the core), DEC_IN (to the core), DEC_OUT (from the core) |
| Protocol pins | none (register access only) |

## Overview

Ethernet_RS_FEC_top v1.0: Ethernet RS(544,514) "KP4" FEC encoder and decoder (IEEE 802.3 clause 91 / 119 / 172 codeword: GF(2^10) with x^10 + x^3 + 1, g(x) = prod_{j=0..29} (x - alpha^j), t = 15), 32 symbols (320 bits) per clock, one codeword in 17 clocks.

- Beat layout: symbol k of a beat is data[10k +: 10]; beat b carries the
codeword symbols 32b .. 32b + 31, the first transmitted symbol (the
coefficient of x^543) first. A codeword is 17 beats; *_first marks beat
0. A beat counter keeps the alignment, so *_first is only needed to
(re)align: *_first in the middle of a codeword drops the codeword
started (ev_eresync / ev_dresync) and starts a new one.
- Encoder: beats 0..15 carry 32 message symbols each and pass through;
beat 16 carries the last 2 message symbols in symbols 0..1, and comes
out with the 30 parity symbols in symbols 2..31. One clock of latency.
The parity update is linear: the remainder times x^32 (x^2 on beat 16)
plus the beat times x^30, mod g.
- Decoder: syndromes S_0..S_29 (Horner, one beat per clock), then the
reformulated inversionless Berlekamp-Massey (riBM, two iterations per
clock, 15 clocks) giving Lambda, Omega and the length L = (30 - k) / 2,
then two Chien passes of 17 clocks each: the first counts the roots of
Lambda over the 544 positions (a codeword is uncorrectable when L > 15
or the roots found are not L; Lambda(0), a product of discrepancies,
is never 0), the second evaluates Forney's
e = X^-30 Omega(X^-1) / (X^-1 Lambda'(X^-1)) and corrects the beats
read back from the codeword buffer (4 codewords). Each stage takes a
new codeword every 17 clocks, so the decoder runs at the full rate.
Latency: 36 clocks from the last beat in to the first beat out.
- d_out_bad marks every beat of an uncorrectable codeword (for the PCS
to corrupt the 257b block headers) unless cfg_bypass_ind is set.
cfg_bypass_corr turns correction off: the data passes unchanged and
every codeword with a non-zero syndrome is reported bad. Both are taken
when a codeword reaches the correction pass.
- ev_corr / ev_uncorr pulse once per corrected / bad codeword (when it
reaches the correction pass, two clocks before its first beat comes
out), st_nsym holds the symbols corrected in that codeword.
- Flow control: *_out_ready low with *_out_valid high holds the whole
encoder (decoder) and drops *_in_ready; at line rate tie them high.
The 400GBASE-R PCS around the FEC (256b/257b transcoding, scrambling,
alignment markers, the codeword interleaving) is Ethernet_PCS_top, which
uses two of these cores. Not implemented: the clause 45 statistics
counters (built from the event outputs) and the reduced-latency
correction bypass.

Features:

- RS(544,514) over GF(2^10) (x^10 + x^3 + 1), g(x) = prod (x - alpha^j), j = 0..29, t = 15: the IEEE 802.3 clause 91 / 119 / 172 "KP4" FEC codeword used by 100G..1.6T Ethernet.
- 32 symbols (320 bits) per clock in and out of both encoder and decoder: one codeword every 17 clocks, at full rate with back-to-back codewords.
- Encoder: systematic, one clock of latency; the parity update for a whole beat is one GF(2)-linear map.
- Decoder: syndromes, reformulated inversionless Berlekamp-Massey (two iterations per clock), a Chien pass that counts the roots (uncorrectable when the LFSR length is above 15 or the roots are not as many), a Chien / Forney pass that corrects; a 4-codeword buffer; 36 clocks from the last beat in to the first beat out.
- Uncorrectable codewords marked on every beat (d_out_bad), correction and indication bypass, per-codeword events and corrected-symbol count, realignment on first, ready / valid flow control that holds the pipeline.

Through the registers a beat is 11 words: data bits 32k .. 32k + 31 in word k = 0..9 (symbol s is bits 10s .. 10s + 9), then first (and bad) in word 10. The data path is meant to be wired to the PCS directly; the registers serve set-up, status and test.
The 400GBASE-R PCS around the FEC (256b/257b transcoding, scrambling, alignment markers, the 2-way codeword interleaving) is the Ethernet_PCS IP, built on two of these cores. Not implemented: the clause 45 statistics counters (they count the CORR / UNCORR events and STATUS.st_nsym), and the reduced-latency path of correction bypass.
Throughput: 320 bits per clock carry 302 message bits (514 / 544); one instance at 1 GHz is about 302 Gb/s of FEC payload, so 800G needs three instances (four with interleaving) and 1.6T six (eight).

## Files

| File | Content |
|---|---|
| `rtl/Ethernet_RS_FEC_top.sv` | protocol core |
| `rtl/Ethernet_RS_FEC_apb.sv` | APB4 register wrapper (generated) |
| `tb/Ethernet_RS_FEC_tb.sv` | core testbench |
| `tb/Ethernet_RS_FEC_apb_tb.sv`, `tb/apb/Ethernet_RS_FEC_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Ethernet_RS_FEC_sva.sv`, `tb/cov/Ethernet_RS_FEC_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Ethernet_RS_FEC.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `Ethernet_RS_FEC_apb`. Widths of the pass-through pins are at the default parameters.

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
| `e_in_valid` | input | 1 | ENC_IN commit / FLAGS |
| `e_in_first` | input | 1 | ENC_IN10 |
| `e_in_data` | input | 320 | ENC_IN0[31:0], ENC_IN1[31:0], ENC_IN2[31:0], ENC_IN3[31:0], ENC_IN4[31:0], ENC_IN5[31:0], ENC_IN6[31:0], ENC_IN7[31:0], ENC_IN8[31:0], ENC_IN9[31:0] |
| `e_in_ready` | output | 1 | ENC_IN handshake |
| `e_out_valid` | output | 1 | ENC_OUT capture |
| `e_out_first` | output | 1 | ENC_OUT10 |
| `e_out_data` | output | 320 | ENC_OUT0[31:0], ENC_OUT1[31:0], ENC_OUT2[31:0], ENC_OUT3[31:0], ENC_OUT4[31:0], ENC_OUT5[31:0], ENC_OUT6[31:0], ENC_OUT7[31:0], ENC_OUT8[31:0], ENC_OUT9[31:0] |
| `e_out_ready` | input | 1 | ENC_OUT handshake |
| `d_in_valid` | input | 1 | DEC_IN commit / FLAGS |
| `d_in_first` | input | 1 | DEC_IN10 |
| `d_in_data` | input | 320 | DEC_IN0[31:0], DEC_IN1[31:0], DEC_IN2[31:0], DEC_IN3[31:0], DEC_IN4[31:0], DEC_IN5[31:0], DEC_IN6[31:0], DEC_IN7[31:0], DEC_IN8[31:0], DEC_IN9[31:0] |
| `d_in_ready` | output | 1 | DEC_IN handshake |
| `d_out_valid` | output | 1 | DEC_OUT capture |
| `d_out_first` | output | 1 | DEC_OUT10[0:0] |
| `d_out_bad` | output | 1 | DEC_OUT10[1:1] |
| `d_out_data` | output | 320 | DEC_OUT0[31:0], DEC_OUT1[31:0], DEC_OUT2[31:0], DEC_OUT3[31:0], DEC_OUT4[31:0], DEC_OUT5[31:0], DEC_OUT6[31:0], DEC_OUT7[31:0], DEC_OUT8[31:0], DEC_OUT9[31:0] |
| `d_out_ready` | input | 1 | DEC_OUT handshake |
| `ev_corr` | output | 1 | IRQ_STATUS.CORR |
| `ev_uncorr` | output | 1 | IRQ_STATUS.UNCORR |
| `ev_eresync` | output | 1 | IRQ_STATUS.ERESYNC |
| `ev_dresync` | output | 1 | IRQ_STATUS.DRESYNC |
| `st_nsym` | output | 4 | STATUS[3:0] |

## APB wrapper

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

## Programming sequence

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

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Ethernet_RS_FEC sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Ethernet_RS_FEC syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Ethernet_RS_FEC_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Ethernet_RS_FEC apb` | `TEST PASSED: Ethernet_RS_FEC_apb`, then Yosys without `ERROR` | console, `work/Ethernet_RS_FEC_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Ethernet_RS_FEC`<br>`bash scripts/cov/run_cov.sh Ethernet_RS_FEC_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Ethernet_RS_FEC/score.json`, `work/cov/Ethernet_RS_FEC_apb/score.json` |

Expected end of a step 4 run:

```
===== Ethernet_RS_FEC =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Ethernet_RS_FEC_tb.sv`): drives `Ethernet_RS_FEC_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Ethernet_RS_FEC_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Ethernet_RS_FEC_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Ethernet_RS_FEC_sva.sv`, `tb/cov/Ethernet_RS_FEC_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Ethernet_RS_FEC_top.sv` | pass | 89/89 | 8658/8658 | 14/14 | 15/15 | 24/24 |
| wrapper `rtl/Ethernet_RS_FEC_apb.sv` | pass | 124/124 | 5732/5732 | n/a | 35/35 | 167/167 |

Test vectors (tb/Ethernet_RS_FEC_vec.hex, `make -f Makefile.Ethernet_RS_FEC vec` rebuilds them) from the reference model scripts/ethfec/rs_ref.py, whose encoder matches the reedsolo library: clean codewords, single errors at both ends, bursts, 1..15 random errors, 15 errors in the parity, errors at beat boundaries, 16..200 errors and a word with an LFSR length above 15. Every message is encoded and every received word decoded and compared.
Loopback with random messages and 0..40 random symbol errors, back-to-back codewords at full rate (the output must come out back-to-back, at the fixed latency), random input gaps and output back-pressure, both bypasses, realignment, and a reset with codewords in flight.
The core checker has its own GF(2^10), generator polynomial, symbol-serial LFSR encoder and a classic Berlekamp-Massey / Chien / Forney decoder with a syndrome check of the result, and compares every beat out of the encoder and decoder, the events and the symbol count; plus the ready / valid rules and the stage occupancy the 17-clock schedule relies on.
