<!-- SPDX-License-Identifier: Apache-2.0 -->
# SDIO: design specification

The card side of an SDIO subset: function 1 only, 4-bit bus, CMD52 (IO_RW_DIRECT) and CMD53
(IO_RW_EXTENDED, byte mode) with R5 responses, CRC7 on CMD and per-line CRC16 on DAT, a 128-byte
function 1 register file. Not implemented: card initialisation (CMD0/5/3/7), the CCCR / FBR, SPI
and 1-bit modes, block mode, interrupts on DAT1, read wait and suspend / resume. Core `SDIO_top`
(`rtl/SDIO_top.sv`), testbench `tb/SDIO_tb.sv` (a host BFM), checker `tb/cov/SDIO_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `sd_clk` and reset
asynchronously by `rst_n` low. A *bit tick* is an `sd_clk` edge where the divider reaches
`BIT_CLKS`-1 (every edge when `BIT_CLKS` = 1); all line sampling, driving and state changes happen
on bit ticks, and "bit time" means `BIT_CLKS` `sd_clk` periods. Frames go MSB first.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | reserved system clock; unused | - | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `sd_clk` | input | 1 | SD bus clock; everything is sampled and driven on its rising edge | rising edge | - | - |
| `cmd` | inout | 1 | CMD line: host commands in, R5 responses out; released (Hi-Z) otherwise, pulled up on the board | - | `sd_clk` | Hi-Z |
| `dat` | inout | 4 | DAT[3:0]: 4-bit data phase both ways and the CRC status token on DAT0; released otherwise | - | `sd_clk` | Hi-Z |
| `irq` | output | 1 | pulse of one bit time on an error (section 5) | high | `sd_clk` | 0 |

### Internal signals used by the verification

The bound checker (`.*`) reads the line drivers and the register file; fsm_cov binds `state`.

| Signal | Width | Meaning |
|---|---|---|
| `cmd_oe` | 1 | the card drives `cmd` |
| `cmd_out` | 1 | the bit driven on `cmd` |
| `dat_oe` | 4 | per line: the card drives `dat[l]` |
| `dat_out` | 4 | the nibble driven on `dat` |
| `reg1` | 8 x 128 | function 1 register file, unpacked `[0:127]`; reset to 0 |
| `state` | 4 | 0 IDLE, 1 CMD, 2 RSP_DLY, 3 RSP, 4 DWR_WAIT, 5 DWR_DATA, 6 DWR_CRC, 7 DWR_END, 8 DWR_STAT, 9 DRD_START, 10 DRD_DATA, 11 DRD_CRC, 12 DRD_END |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SDIO.md`](../ip/SDIO.md) (source: `scripts/apb/specs/SDIO.json`); do not edit by hand.

`SDIO_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sd_clk`, `cmd`, `dat`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53490200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5349 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a command was dropped (bad CRC7, bad framing, unsupported index or block mode) or a data block was discarded (bad CRC16 or end bits, no write block within 64 clocks) |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53490200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 CRCs

CRC7: polynomial x^7 + x^3 + 1, initial value 0, over the first 40 bits of a 48-bit frame, MSB
first. CRC16: CRC-16-CCITT x^16 + x^12 + x^5 + 1, initial value 0, computed separately for each
DAT line over the bits that line carries in the data phase, sent MSB first on that line.

### 3.2 Command frame

In IDLE, a 0 sampled on `cmd` is a start bit; the next 47 bit ticks shift in the rest. Frame:
start (0), transmission (1), index[5:0], argument[31:0], CRC7[6:0], end (1). The frame is decoded
on the tick that samples the end bit. It is accepted when start / transmission / end are right,
the CRC7 matches, and the index is 52, or 53 with argument bit 27 (block mode) = 0.

| Command | Argument |
|---|---|
| CMD52 | [31] write, [30:28] function, [27] RAW (no effect), [25:9] register address, [7:0] write data |
| CMD53 | [31] write, [30:28] function, [27] block mode (must be 0), [26] OP code (1 incrementing address), [25:9] address, [8:0] byte count |

A frame with bad framing or CRC7 sets the pending COM_CRC_ERROR flag; a good frame with any other
index (or CMD53 block mode) sets the pending ILLEGAL_COMMAND flag. Either way there is no
response and `irq` pulses. While a response or data phase is in progress `cmd` is not watched.

### 3.3 R5 response

R5 = start 0, transmission 0, index, 16 stuff bits 0, flags[7:0], data[7:0], CRC7, end 1.

| Flag bit | Meaning |
|---|---|
| 7 COM_CRC_ERROR | pending flag of an earlier rejected command; cleared once reported |
| 6 ILLEGAL_COMMAND | likewise |
| 5:4 IO_CURRENT_STATE | 01 (CMD) |
| 1 FUNCTION_NUMBER | function != 1 |
| 0 OUT_OF_RANGE | address above 127 (any of bits 16:7 set); CMD53 count 0 (512) or above 32; incrementing CMD53 with address + count > 128 |

A command with flag 1 or 0 set is answered but not executed and has no data phase. Data field:
for an executed CMD52 read, the register value; for an executed CMD52 write, the written value;
otherwise 0.

Timing: with T0 the tick that samples the command's end bit, the card leaves `cmd` released for
ticks T1..T3 and drives the R5 start bit from tick T4; the 48 bits are driven on ticks T4..T51,
one per tick. After T51 the card moves on (T52): with no data phase it releases `cmd` and is idle.

### 3.4 CMD52

An executed CMD52 write updates `reg1[address]` at T0 (decode). A read returns the register in R5.

### 3.5 CMD53 write (host to card)

From T52 the card waits for a start nibble 0000 on DAT; if none is seen within 64 bit ticks it
pulses `irq` and returns to idle. After the start, it takes 2 x count nibbles (high nibble of each
byte first) into a 32-byte buffer while computing the line CRCs, then 16 CRC bits per line, then
the end nibble. On the end tick (E) the block is accepted if the end nibble is 1111 and all four
CRCs match; it is then written to `reg1` (address + i when incrementing, else all bytes to the
same address, the last one winning); otherwise it is discarded and `irq` pulses.

CRC status token on DAT0 only: ticks E+1 and E+2 released, then driven on E+3 .. E+7: start 0,
status 010 (accepted) or 101 (CRC error), end 1; released again on E+8 and back to idle. DAT3..1
stay released.

### 3.6 CMD53 read (card to host)

On ticks T52 and T53 after the R5: at T53 all four lines are driven with the start nibble 0000.
Then 2 x count nibbles (high nibble first) of `reg1[address + i]` (incrementing) or
`reg1[address]` (fixed), read as each byte is sent; then 16 CRC16 bits per line; then the end
nibble 1111 for one tick; the lines are released on the next tick.

### 3.7 Reset

`cmd` and `dat` released, `irq` = 0, `reg1` all 0, pending flags clear, state IDLE. A reset during
a data phase releases the lines at once.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `BIT_CLKS` | 1 | 1 and up | `sd_clk` periods per bus bit: every sample, drive and timeout counts bit ticks; `irq` lasts one bit time |

## 5. Errors and corner cases

| Error | Response | `irq` |
|---|---|---|
| bad framing or CRC7 on a command | none; COM_CRC_ERROR in the next R5 | pulse |
| unsupported index, or CMD53 block mode | none; ILLEGAL_COMMAND in the next R5 | pulse |
| function != 1 | R5 with FUNCTION_NUMBER, not executed | none |
| address / count out of range | R5 with OUT_OF_RANGE, not executed | none |
| write block CRC16 or end bits bad | CRC status 101, block discarded | pulse |
| no write block start within 64 bit ticks | none, back to idle | pulse |

`irq` is registered and lasts one bit time. Both pending flags are reported (and cleared) by the
next accepted command's R5, whether or not that command executes.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "CMD53 read" | R5 flags / data of a CMD53 read, and every read block byte equals the register file (incrementing or fixed address) | §3.3, §3.6 |
| "R5 framing / CRC7" | R5 start, transmission bit 0, CRC7 and end bit | §3.3 |
| "CRC status start bit" | the token starts with 0 on DAT0 | §3.5 |
| "CRC status end bit" | the token ends with 1 | §3.5 |
| "CRC status" | 010 for a good block, 101 for a bad one | §3.5 |
| "read block start bits" | 0000 start on all lines | §3.6 |
| "read block CRC16" | per-line CRC16 of the read block | §3.6 |
| "read block end bits" | 1111 end | §3.6 |
| "CMD53 write irq" | `irq` only for a bad write block | §3.5, §5 |
| "missing write block: irq" | no block start within 64 bit times: `irq` | §3.5 |
| "reset: lines released" | in reset `cmd` and `dat` are released, `irq` = 0 | §3.7 |
| "reset mid-block releases the lines" | a reset during a data phase releases the lines | §3.7 |
| a_reset_released | in reset: `cmd_oe` = 0, `dat_oe` = 0, `irq` = 0 | §3.7 |
| a_cmd_driver | `cmd_oe` and the driven bit equal the checker's model | §3.3 |
| a_dat_driver | `dat_oe` and the driven nibble equal the model | §3.5, §3.6 |
| a_irq | `irq` equals the model | §5 |
| a_register_file | `reg1` equals the model after every command and block | §3.4, §3.5 |
