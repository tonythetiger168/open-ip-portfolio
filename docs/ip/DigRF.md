# DigRF v4-style baseband / RF IC serial link endpoint (8b/10b, framed logical channels)

Protocol IP `DigRF`, version 2.0. Apache-2.0.

## Overview

DigRF_top v2.0: DigRF v4-style baseband / RF IC serial link endpoint (one TX lane, one RX lane, 8b/10b, framed logical channels)

- Line: one bit per clk, symbol bit a first. A stopped lane is held at
0. 8b/10b coding (IEEE 802.3 clause 36 tables) with running
disparity; the transmitter starts every burst at RD-.
- Burst: max(cfg_sync, 1) x K28.5 (sync, the receiver aligns on the
first comma), frames, K28.5 fillers while the transmitter has nothing
to send, K29.7 (end of burst) once cfg_hold fillers came in a row; then
the lane stops. A frame waiting while the lane stops starts a new
burst.
- Frame: K28.1 (start of frame), header {LCT[2:0], F[4:0]}, payload:
LCT 0 DATA      F = {chan[1:0], size[2:0]}, 8 << size bytes (size 0..5)
LCT 1 CTRL_WR   F = tag, payload {addr, data}
LCT 2 CTRL_RD   F = tag, payload {addr}
LCT 3 CTRL_RSP  F = tag of the read, payload {data}
LCT 4 INT       F = vector, no payload
Transmit priority: read response, interrupt, control request, data.
A DATA frame takes dtx_size (sizes 6 and 7 are sent as 5) and
dtx_chan when it starts, i.e. while dtx_valid offers its first byte.
- Control master: ctl_valid / ctl_ready take a write or a read; a read
is outstanding until the response with its tag arrives (rsp_valid) or
cfg_timeout x 16 clocks pass (rsp_timeout); tags count up per request.
- Register slave: a received CTRL_WR pulses reg_we with reg_addr /
reg_wdata; a received CTRL_RD pulses reg_re with reg_addr and samples
reg_rdata in the next clock, then answers with CTRL_RSP.
- Data: dtx_* offers one frame at a time (size and channel with the
first byte); each payload byte is taken with dtx_ready; a missing byte
is sent as 0 and pulses tx_underrun. Received payload bytes come out
on drx_* as they arrive (no back-pressure); drx_abort ends a data
frame that broke off.
- Receiver: hunts for K28.5 at any bit offset, then decodes every
symbol. A code violation or disparity error (err_code) or K29.7 drops
the alignment; a bad header, a size code above 5, an unexpected
control symbol in a frame or a data byte between frames pulse
err_frame. A frame that breaks off is dropped (data frames: drx_abort).
Simplifications against DigRF v4: no M-PHY (no PWM / HS gears, no
PREPARE / DIF-P / line state handshake, no clock recovery: the receiver
runs on the transmitter's bit clock at any phase), one lane each way,
no CRC, no flow-control or retransmission, the header layout above.

tx_p / rx_p are the lanes (one bit per PCLK, held at 0 while stopped).
reg_we / reg_re / reg_addr / reg_wdata / reg_rdata connect to the local register bank the peer accesses; reg_rdata is sampled one PCLK after reg_re.
dtx_* and drx_* connect to the local data path (IQ samples): dtx_valid offers a frame byte by byte, dtx_size / dtx_chan with its first byte; drx_* delivers received bytes without back-pressure, drx_abort ends a frame that broke off.

## Files

| File | Content |
|---|---|
| `rtl/DigRF_top.sv` | protocol core |
| `rtl/DigRF_apb.sv` | APB4 register wrapper (generated) |
| `tb/DigRF_tb.sv` | core testbench |
| `tb/DigRF_apb_tb.sv`, `tb/apb/DigRF_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/DigRF_sva.sv`, `tb/cov/DigRF_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/DigRF.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.DigRF sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.DigRF apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh DigRF          # core coverage (Verilator)
bash scripts/cov/run_cov.sh DigRF_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_p` | output | 1 | pin (pass-through) |
| `rx_p` | input | 1 | pin (pass-through) |
| `cfg_sync` | input | 4 | CFG[3:0] |
| `cfg_hold` | input | 8 | CFG[11:4] |
| `cfg_timeout` | input | 8 | CFG[19:12] |
| `ctl_valid` | input | 1 | CTL commit / FLAGS |
| `ctl_ready` | output | 1 | CTL handshake |
| `ctl_rd` | input | 1 | CTL[16:16] |
| `ctl_addr` | input | 8 | CTL[15:8] |
| `ctl_wdata` | input | 8 | CTL[7:0] |
| `rsp_valid` | output | 1 | RSP capture |
| `rsp_data` | output | 8 | RSP[7:0] |
| `rsp_timeout` | output | 1 | IRQ_STATUS.RSP_TIMEOUT |
| `reg_we` | output | 1 | pin (pass-through) |
| `reg_re` | output | 1 | pin (pass-through) |
| `reg_addr` | output | 8 | pin (pass-through) |
| `reg_wdata` | output | 8 | pin (pass-through) |
| `reg_rdata` | input | 8 | pin (pass-through) |
| `int_valid` | input | 1 | INT_TX commit / FLAGS |
| `int_ready` | output | 1 | INT_TX handshake |
| `int_vec` | input | 5 | INT_TX[4:0] |
| `int_rx` | output | 1 | INT_RX capture |
| `int_rx_vec` | output | 5 | INT_RX[4:0] |
| `dtx_valid` | input | 1 | pin (pass-through) |
| `dtx_ready` | output | 1 | pin (pass-through) |
| `dtx_data` | input | 8 | pin (pass-through) |
| `dtx_size` | input | 3 | pin (pass-through) |
| `dtx_chan` | input | 2 | pin (pass-through) |
| `drx_valid` | output | 1 | pin (pass-through) |
| `drx_data` | output | 8 | pin (pass-through) |
| `drx_sof` | output | 1 | pin (pass-through) |
| `drx_eof` | output | 1 | pin (pass-through) |
| `drx_chan` | output | 2 | pin (pass-through) |
| `drx_abort` | output | 1 | pin (pass-through) |
| `tx_on` | output | 1 | STATUS[0:0] |
| `rx_locked` | output | 1 | STATUS[1:1] |
| `err_code` | output | 1 | IRQ_STATUS.ERR_CODE |
| `err_frame` | output | 1 | IRQ_STATUS.ERR_FRAME |
| `tx_underrun` | output | 1 | IRQ_STATUS.UNDERRUN |

## APB wrapper

`DigRF_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_p`, `rx_p`, `reg_we`, `reg_re`, `reg_addr`, `reg_wdata`, `reg_rdata`, `dtx_valid`, `dtx_ready`, `dtx_data`, `dtx_size`, `dtx_chan`, `drx_valid`, `drx_data`, `drx_sof`, `drx_eof`, `drx_chan`, `drx_abort`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44460200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00040102 | Burst and timeout configuration |
| 0x018 | CTL | RW | 0x00000000 | Register access to the peer; writing CTL commits it. A read is answered through RSP (or RSP_TIMEOUT); the next access waits for it |
| 0x01C | RSP | RO (pop) | 0x00000000 | Read data from the peer; reading RSP frees it |
| 0x020 | INT_TX | RW | 0x00000000 | Interrupt message to the peer; writing INT_TX commits it |
| 0x024 | INT_RX | RO (pop) | 0x00000000 | Interrupt message from the peer; reading INT_RX frees it |
| 0x028 | STATUS | RO | 0x00000000 | Lane state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4446 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CFG | 3:0 | `cfg_sync` | K28.5 sync symbols at the start of a burst (0 = 1) |
| CFG | 11:4 | `cfg_hold` | K28.5 fillers in a row before the lane stops (K29.7) |
| CFG | 19:12 | `cfg_timeout` | read timeout, x 16 PCLK |
| CTL | 7:0 | `ctl_wdata` | write data |
| CTL | 15:8 | `ctl_addr` | peer register address |
| CTL | 16 | `ctl_rd` | 1 = read, 0 = write |
| RSP | 7:0 | `rsp_data` | read data |
| INT_TX | 4:0 | `int_vec` | interrupt vector |
| INT_RX | 4:0 | `int_rx_vec` | interrupt vector |
| STATUS | 0 | `tx_on` | a burst is being sent |
| STATUS | 1 | `rx_locked` | the receiver is aligned to the incoming burst |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RSP_TIMEOUT | a read got no response within CFG.cfg_timeout |
| 1 | ERR_CODE | 8b/10b code violation or disparity error (the receiver realigns) |
| 2 | ERR_FRAME | bad header or size, unexpected control symbol, data between frames, or a response with no matching read |
| 3 | UNDERRUN | a data payload byte was missing and sent as 0 |
| 4 | CTL_DONE | CTL beat accepted by the core |
| 5 | CTL_OVF | write to CTL while full (dropped) |
| 6 | RSP_AVAIL | RSP captured a beat |
| 7 | RSP_OVF | beat dropped, RSP was full |
| 8 | INT_TX_DONE | INT_TX beat accepted by the core |
| 9 | INT_TX_OVF | write to INT_TX while full (dropped) |
| 10 | INT_RX_AVAIL | INT_RX captured a beat |
| 11 | INT_RX_OVF | beat dropped, INT_RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CTL_FULL | CTL holds a beat the core has not taken |
| 1 | RSP_AVAIL | RSP holds an unread beat |
| 2 | INT_TX_FULL | INT_TX holds a beat the core has not taken |
| 3 | INT_RX_AVAIL | INT_RX holds an unread beat |

### Streams

* **CTL** feeds `ctl_wdata`, `ctl_addr`, `ctl_rd`/`ctl_valid`. Writing CTL commits the beat: FLAGS.CTL_FULL is set and `ctl_valid` stays high until the core's `ctl_ready`; then CTL_DONE is set. A write while full is dropped and sets CTL_OVF.
* **RSP** captures `rsp_data` when `rsp_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RSP_AVAIL. Reading RSP pops it. A beat that arrives while the register is full is dropped and sets RSP_OVF.
* **INT_TX** feeds `int_vec`/`int_valid`. Writing INT_TX commits the beat: FLAGS.INT_TX_FULL is set and `int_valid` stays high until the core's `int_ready`; then INT_TX_DONE is set. A write while full is dropped and sets INT_TX_OVF.
* **INT_RX** captures `int_rx_vec` when `int_rx` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ INT_RX_AVAIL. Reading INT_RX pops it. A beat that arrives while the register is full is dropped and sets INT_RX_OVF.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/DigRF_top.sv` | pass | 172/172 | 748/748 | 15/15 | 19/19 | 36/36 |
| wrapper `rtl/DigRF_apb.sv` | pass | 44/44 | 842/842 | n/a | 16/16 | 95/95 |
