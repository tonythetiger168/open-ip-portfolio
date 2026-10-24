# DisplayPort source slice: one 8b/10b main-link lane, link training (clock recovery, TPS1) over a Manchester-coded AUX channel, I2C-over-AUX EDID read, video lines with blanking and MSA, HPD

Protocol IP `DisplayPort2`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `DisplayPort2_top` (`rtl/DisplayPort2_top.sv`) |
| Register interface | APB4 slave `DisplayPort2_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x44320200 (code 0x4432, version 2.0) |
| Registers | 8 words, 0x000 to 0x01C |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | 9 pass-through |

## Overview

DisplayPort2 protocol Open IP -- DisplayPort source (TX) educational slice: main link 1 lane with ANSI 8b/10b encoding (full D-code table + K28.5 / K23.7 / K27.7 / K29.7 / K30.7 control codes, running-disparity tracking), link-training FSM (D10.2 clock-recovery pattern -> TPS1 = K28.5 + D10.2 sequence with simplified TRAINING_PATTERN_SET semantics -> trained), video streaming (BS/BE blanking marks + pixel data + SS/SE framed MSA packet: VB-ID / Mvid[23:0] simplified to 4 dwords), AUX channel with Manchester-II coding (1 bit = 2 clk chips), SYNC 16'h0000 preamble + start bit, commands {native AUX write/read, I2C-over-AUX write/read}, addr[20] + len[8] + data + simplified stop (CRC replaced by stop chips), DPCD register window access (16 x 8: link rate / lane count / training pattern / lane status), I2C-over-AUX read of the first 8 EDID bytes, HPD unplug / replug. Documented simplifications (educational slice of the DP physical layer):

- 1 lane, serialisation 1 bit/clk; the 10-bit 8b/10b code is transmitted
'a' first (DP-native bit order), 10 clk per symbol, gap-free. The
running disparity restarts at RD- whenever the lane comes up.
- AUX Manchester-II at 2 clk chips per bit (IEEE 802.3 convention:
logical 1 = chips (1,0), logical 0 = chips (0,1)). Idle line = 1.
SYNC = 16 zero bits + one start bit (1). STOP = chips (1,1).
AUX CRC nibble is replaced by the STOP chip pair (documented).
- AUX reply: header byte {reply[3:0], 4'hx}; reply 0 = ACK, any other
code (NACK, DEFER, I2C NACK/DEFER) is a failed attempt and carries no
data: the STOP follows the header. An ACK carries exactly the
requested number of bytes. The reply must start within 200 clk of the
request STOP; a Manchester violation, a bad SYNC / start bit or a
missing STOP fails the attempt.
- DPCD window model: addr0 = LINK_RATE(0x14), addr1 = LANE_COUNT(1),
addr2 = TRAINING_PATTERN_SET (0x21=CR, 0x22=TPS1, 0x00=off),
addr3 = LANE0_STATUS (bit0 CR_DONE, bit1 EQ_DONE) -- lives in the sink.
- I2C-over-AUX: addr = {4'h0, i2c_dev[7:0], offset[7:0]}; write with
len=0 sets the EDID offset; read returns len bytes from EDID ROM.
- Link training: send >= 32 CR symbols then poll LANE0_STATUS; a poll
that is not done (or fails) re-polls after another 32 symbols, up to 3
retries per phase. Every AUX op is retried 3 times. Then train_fail +
irq, sticky until reset or HPD low; fill (K23.7) keeps the lane up.
- HPD (sink_present) is taken as already debounced: low drops the lane,
aborts any AUX transfer and clears edid_valid / train_fail; high
starts a new training.
- Video line (40 symbols, documented simplification):
BS(K27.7), 16 pixel D-symbols (pixel[i] = frame_cnt+i), BE(K28.5),
SS(K29.7), 16 MSA bytes (4 dwords LSB-first: {8'h00,8'h00,fc,8'h01},
32'h0012_3456 (Mvid), 32'h140 (Htotal), 32'h0F0 (Vtotal)), SE(K30.7),
FS(K23.7) + 3 x D00.0 fill. K23.7 fill is sent whenever the link is
up but no video/training pattern is active.

lane_p (main link, 1 bit per PCLK, 8b/10b, bit 'a' first), aux_tx_p / aux_tx_en / aux_rx_p (AUX, Manchester-II at two PCLK per bit) and sink_present (HPD) pass through unchanged; lane_valid, link_trained, train_fail and edid_valid also drive pins.
The core runs on its own: HPD high starts training (DPCD link rate, lane count, clock recovery and TPS1 with status polls, then the EDID read), each AUX operation retried three times. The APB side observes the result.

## Files

| File | Content |
|---|---|
| `rtl/DisplayPort2_top.sv` | protocol core |
| `rtl/DisplayPort2_apb.sv` | APB4 register wrapper (generated) |
| `tb/DisplayPort2_tb.sv` | core testbench |
| `tb/DisplayPort2_apb_tb.sv`, `tb/apb/DisplayPort2_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/DisplayPort2_sva.sv`, `tb/cov/DisplayPort2_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/DisplayPort2.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.DisplayPort2 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.DisplayPort2 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh DisplayPort2          # core coverage (Verilator)
bash scripts/cov/run_cov.sh DisplayPort2_apb      # wrapper coverage
```

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `DisplayPort2_apb`. Widths of the pass-through pins are at the default parameters.

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
| `lane_p` | output | 1 | protocol pin, core port `lane_p` |
| `lane_valid` | output | 1 | protocol pin, core port `lane_valid` (also read in a register) |
| `link_trained` | output | 1 | protocol pin, core port `link_trained` (also read in a register) |
| `train_fail` | output | 1 | protocol pin, core port `train_fail` (also read in a register) |
| `aux_tx_p` | output | 1 | protocol pin, core port `aux_tx_p` |
| `aux_tx_en` | output | 1 | protocol pin, core port `aux_tx_en` |
| `aux_rx_p` | input | 1 | protocol pin, core port `aux_rx_p` |
| `sink_present` | input | 1 | protocol pin, core port `sink_present` |
| `edid_valid` | output | 1 | protocol pin, core port `edid_valid` (also read in a register) |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `lane_p` | output | 1 | pin (pass-through) |
| `lane_valid` | output | 1 | STATUS[0:0] |
| `link_trained` | output | 1 | STATUS[1:1], IRQ_STATUS.TRAINED |
| `train_fail` | output | 1 | STATUS[2:2] |
| `aux_tx_p` | output | 1 | pin (pass-through) |
| `aux_tx_en` | output | 1 | pin (pass-through) |
| `aux_rx_p` | input | 1 | pin (pass-through) |
| `sink_present` | input | 1 | pin (pass-through) |
| `edid` | output | 64 | EDID0[31:0], EDID1[31:0] |
| `edid_valid` | output | 1 | STATUS[3:3] |
| `irq` | output | 1 | IRQ_STATUS.TRAIN_FAIL |

## APB wrapper

`DisplayPort2_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `lane_p`, `lane_valid`, `link_trained`, `train_fail`, `aux_tx_p`, `aux_tx_en`, `aux_rx_p`, `sink_present`, `edid_valid`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44320200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Link state, as driven on the pins |
| 0x018 | EDID0 | RO | core | EDID bytes 0 to 7 |
| 0x01C | EDID1 | RO | core | EDID bytes 0 to 7 |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x020 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4432 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `lane_valid` | RO | core | the main lane is up (training patterns, video or fill) |
| STATUS | 1 | `link_trained` | RO | core | training completed; video lines are being sent |
| STATUS | 2 | `train_fail` | RO | core | training failed after all retries (until HPD low or reset) |
| STATUS | 3 | `edid_valid` | RO | core | EDID holds the first 8 EDID bytes |
| EDID0 | 31:0 | `edid[31:0]` | RO | core | byte i in bits [8i+7:8i] (EDID0 holds bytes 0 to 3), valid with STATUS.edid_valid |
| EDID1 | 31:0 | `edid[63:32]` | RO | core | byte i in bits [8i+7:8i] (EDID0 holds bytes 0 to 3), valid with STATUS.edid_valid |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TRAINED | the link is trained; set on every clock it stays trained, so clear it once and mask it |
| 1 | TRAIN_FAIL | training failed; the core holds it until HPD low or reset, so the bit is set again on every clock until then |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44320200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
4. Read STATUS (0x014) for the core's live `lane_valid`, `link_trained`, `train_fail`, `edid_valid`; it needs no clearing.
5. Read EDID0 (0x018), EDID1 (0x01C) for the core's live `edid[31:0]`, `edid[63:32]`; it needs no clearing.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/DisplayPort2_top.sv` | pass | 219/219 | 500/500 | 81/81 | 11/11 | 27/27 |
| wrapper `rtl/DisplayPort2_apb.sv` | pass | 22/22 | 558/558 | n/a | 7/7 | 33/33 |
