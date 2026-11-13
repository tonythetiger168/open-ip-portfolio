# SD: design specification

SD memory card host. It runs the init sequence CMD0 / CMD8 / ACMD41 / CMD2 / CMD3 / CMD7, then demo rounds of a CMD24 single-block write in 4-bit DAT mode, a CMD17 read-back compare and a CMD13 status poll. It checks R1 / R2 / R3 / R6 / R7 responses, CRC7 and CRC16. It is an educational slice:
- blocks are 32 bytes;
- the bus is 4 bits wide from the start (no ACMD6);
- CMD7's R1b busy is treated as R1.

There is no register port. Status is read from internal registers and `irq`. Core `SD_top` (`rtl/SD_top.sv`), testbench `tb/SD_tb.sv`, checker `tb/cov/SD_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | system clock; all logic runs on it | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `sd_clk` | output | 1 | SD bus clock: clk / ID_CLK_DIV until the RCA is published, clk / SD_CLK_DIV after; 50 % duty | - | `clk` | 0 |
| `cmd` | inout | 1 | CMD line: driven = `cmd_out_p` while `cmd_oe_p`, else Z (pull-up assumed); sampled at the sd_clk rising tick | - | `clk` | Z |
| `dat` | inout | 4 | DAT[3:0]: driven = `dat_out_p` while `dat_oe_p`, else Z; sampled at the rising tick | - | `clk` | Z |
| `irq` | output | 1 | error pulse, one sd_clk period long (set at a tick, cleared at the next) | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these signals (`dut.x`) and the checker binds them (`.*`). They are the IP's status interface and must exist with the same meaning.

| Signal | Width | Meaning |
|---|---|---|
| `tick` | 1 | combinational: the clk cycle where sd_clk rises (the divider wraps); the FSM steps and samples here |
| `fast` | 1 | data-transfer rate selected (set when the R6 of CMD3 is accepted, cleared on an init restart) |
| `state` | 3 | host FSM: 0 CTX (command out), 1 GAP, 2 RSP, 3 IDLE (between rounds), 4 WDAT, 5 RDAT |
| `cur` | 4 | command in flight: 0 CMD0, 1 CMD8, 2 CMD55, 3 ACMD41, 4 CMD2, 5 CMD3, 6 CMD7, 7 CMD24, 8 CMD17, 9 CMD13 |
| `dphase` | 3 | data sub-phase: 0 START, 1 DATA, 2 CRC, 3 END, 4 TOK (CRC status), 5 BUSY |
| `bit_cnt` | 8 | bit / nibble counter of the current phase |
| `cmd_oe_r` | 1 | CMD drive enable chosen at a tick (pins take it at the next falling edge) |
| `cmd_out_r` | 1 | CMD value chosen at a tick |
| `dat_oe_r` | 1 | DAT drive enable chosen at a tick |
| `dat_out_r` | 4 | DAT value chosen at a tick |
| `cmd_oe_p` | 1 | CMD pin enable (= `cmd_oe_r` sampled at the falling tick); reset 0 |
| `cmd_out_p` | 1 | CMD pin value; reset 1 |
| `dat_oe_p` | 1 | DAT pin enable; reset 0 |
| `dat_out_p` | 4 | DAT pin value; reset 0xF |
| `init_done` | 1 | CMD7 accepted: identification finished |
| `cid` | 128 | CID from the R2 of CMD2 (bits 127:1, end bit in bit 0) |
| `rca` | 16 | RCA from the R6 of CMD3 |
| `ccs` | 1 | OCR CCS from the R3 of ACMD41 (1 = high capacity, block addressing) |
| `round` | 8 | demo round number (wraps) |
| `match_cnt` | 8 | rounds completed with a good read-back and CMD13 (wraps) |
| `err_crc7` | 1 | sticky: response framing / CRC7 error (R1, R2, R3, R6, R7 framing) |
| `err_status` | 1 | sticky: R1 card-status error bits or R6 status error bits |
| `err_timeout` | 1 | sticky: response / data start / CRC status / busy timeout |
| `err_crc16` | 1 | sticky: read CRC16 or end-bit error, or write CRC status not 010 |
| `err_cmp` | 1 | sticky: read-back data differs from the written block |
| `err_r7` | 1 | sticky: R7 voltage or check pattern wrong |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SD.md`](../ip/SD.md) (source: `scripts/apb/specs/SD.json`); do not edit by hand.

`SD_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sd_clk`, `cmd`, `dat`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53440200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5344 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a response, CRC status, read block or busy phase failed (framing, CRC7, index, card-status error bits, R7 contents, negative CRC status, CRC16, end bit, read compare, timeout); the host retries |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53440200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Clock and pins

- **Divider:** a counter runs on `clk`.
  - `tick` is the clock where it wraps (divider - 1): `sd_clk` rises at that edge.
  - `ftick` is at divider / 2 - 1: `sd_clk` falls there.
  - The rate (`fast`) changes only at a tick, so every period is whole.
- **Sampling and driving:** the FSM steps only at ticks.
  - It samples `cmd` / `dat` at the tick (the sd_clk rising edge) and sets `*_r`.
  - The pin registers `*_p` copy `*_r` at the next falling tick, half a period before the card samples them.
  - CMD and DAT therefore never change while `sd_clk` is high.
- **Clock rate:** identification (CMD0 to CMD3) runs at clk / ID_CLK_DIV. From CMD7 on, after the R6, it runs at clk / SD_CLK_DIV.

### 3.2 Commands and init

- **Command frame:** 48 bits, MSB first: start 0, transmission 1, index[5:0], argument[31:0], CRC7 (x^7 + x^3 + 1, initial value 0, over the first 40 bits), end 1.
- **Response timing:** after the end bit CMD is released (GAP, one tick). The start bit is looked for from the next tick, which catches N_CR = 2, for up to 64 ticks; otherwise it is a timeout.

**Init sequence:**

| Step | Command | Argument | Response check | On success |
|---|---|---|---|---|
| 1 | CMD0 | 0 | no response | wait 8 ticks, then CMD8 |
| 2 | CMD8 | 0x000001AA | R7: R1 framing and CRC7, plus voltage nibble = 1 and check pattern 0xAA (`err_r7` otherwise) | CMD55 |
| 3 | CMD55 | 0 | R1 | ACMD41 |
| 4 | ACMD41 | 0x40FF8000 | R3: start 0, bits 45:40 = 111111, bits 7:0 = 0xFF | if OCR bit 31 (power-up done) is set, `ccs` = OCR bit 30 and go to CMD2; otherwise poll with CMD55 / ACMD41 again |
| 5 | CMD2 | 0 | R2: 136 bits, start 0, 111111, the CID's own CRC7 in bits 7:1 over CID[127:8], end bit 1 | `cid` stored, CMD3 |
| 6 | CMD3 | 0 | R6: R1 framing, status bits {23, 22, 19, 3} (`R6_MASK` 0xE008) clear, else `err_status` | `rca` = response bits 39:24, `fast` = 1, CMD7 |
| 7 | CMD7 | {RCA, 0} | R1 | `init_done` = 1 |

R1 checks: start 0, transmission 0, the command index, CRC7 and end bit 1 (`err_crc7` otherwise). The card status must have no bit of ERR_MASK 0xFDF98008 set, otherwise `err_status`. Status bits outside ERR_MASK are ignored.

### 3.3 Demo rounds

Each round:
1. Wait 8 ticks in IDLE.
2. CMD24 with the round's block argument, then an R1.
3. Write the block on DAT:
   - one tick of 1111, the start bits 0000, 64 nibbles (block bits 255:252 first, bit i on DAT[i]);
   - 16 CRC16 bits per line (CCITT 0x1021, initial value 0, one CRC per line, MSB first);
   - end bits 1111;
   - then release DAT.
   - Block word i of round r = 0xA5003C00 ^ r ^ (i * 0x00010101), word 0 first.
4. The CRC status token on DAT0 (0, 3 bits, 1) must be 0 010 1, otherwise `err_crc16`. Wait for the busy release (DAT0 = 1), then 6 ticks.
5. CMD17 with the same argument, then an R1.
6. Wait for the start bits 0000 on all lines. Read 64 nibbles and 16 CRC bits per line, then the end bits 1111. A wrong CRC on any line or bad end bits gives `err_crc16`. Data that differs from the written block gives `err_cmp`.
7. CMD13 with {RCA, 0}, then an R1.
8. `match_cnt` + 1 and `round` + 1, both wrapping at 256.

The block argument for round n uses block n[1:0]. It is the block number when `ccs` = 1, otherwise the byte address n[1:0] * 32.

### 3.4 Errors

Each error sets its sticky flag (never cleared except by reset) and pulses `irq` for one sd_clk period.

| Phase | Error | Result |
|---|---|---|
| Init, before `init_done` (including CMD7) | any | restart with CMD0 at the identification rate (`fast` = 0) |
| Rounds | any | return to IDLE; the same round is retried (`round` unchanged) |

The timeout is 64 ticks. It applies to the response start bit, the read start bits, the CRC status token and the busy release.

### 3.5 Throughput

One bus bit (command / response) or one nibble (data) per sd_clk period. A command takes 48 ticks, and an R2 response 136.

### 3.6 Reset

- `sd_clk` = 0, the pins are released (`cmd_oe_p` = `dat_oe_p` = 0), and `irq` = 0.
- `cmd_oe_r` = 1 and `cmd_out_r` = 1, because the first act after reset is to send CMD0.
- All identity registers, counters and error flags are 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `SD_CLK_DIV` | 4 | even, >= 2 | clk cycles per sd_clk period after identification |
| `ID_CLK_DIV` | 128 | even, >= 2 | clk cycles per sd_clk period during identification (<= 400 kHz: 128 is enough for clk up to 51.2 MHz) |

## 5. Errors and corner cases

- The error flags are sticky and have no clear. Software would need a register wrapper; the TB reads them hierarchically.
- An R1 with both a framing error and status bits counts as `err_crc7` only.
- An ACMD41 that never reports power-up done is polled forever, with no timeout.
- A read block with a good CRC but wrong data gives `err_cmp`. The round is retried and is not counted.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "sd_clk period" | sd_clk period = ID_CLK_DIV during identification, SD_CLK_DIV after | §3.1 |
| "identification at the fast rate" | CMD0..CMD3 at the identification rate | §3.1 |
| "CMD / DAT changed while sd_clk is high" | pins change only at the falling edge | §3.1 |
| "reset state" | reset values | §3.6 |
| "CID / RCA / CCS" | identity registers from the responses | §3.2 |
| "card store contents" | the card holds the pattern blocks written | §3.3 |
| "err_crc7" | framing / CRC7 errors set `err_crc7` and irq | §3.4 |
| "err_status" | status error bits set `err_status` | §3.4 |
| "err_timeout" | missing responses / tokens / busy release set `err_timeout` | §3.4 |
| "err_crc16" | bad CRC16 or CRC status sets `err_crc16` | §3.4 |
| "err_cmp" | read-back mismatch sets `err_cmp` | §3.3 |
| "benign status bits raised irq" | status bits outside ERR_MASK do not raise irq | §3.4 |
| "err_r7" | wrong R7 contents set `err_r7` | §3.2 |
| "CID / RCA / CCS 2" | identity after a re-init | §3.2 |
| "counters before wrap" | `round` and `match_cnt` count rounds | §3.3 |
| "round wrapped" | `round` wraps at 256 | §3.3 |
| "host command frames / arguments" | every command frame and argument is correct | §3.2, §3.3 |
| "N_CR = 2 responses / both clock rates seen" | a response at N_CR = 2 is caught | §3.2 |
| a_reset_state | in reset: `cmd_oe_r` = `cmd_out_r` = 1, `dat_oe_r` = 0, no irq, sd_clk 0 | §3.6 |
| a_sd_clk | `sd_clk` as the model's divider | §3.1 |
| a_cmd_dat_pins | pin registers as the model | §3.1 |
| a_cmd_driver | `cmd_oe_r` / `cmd_out_r` as the model | §3.2 |
| a_dat_driver | `dat_oe_r` / `dat_out_r` as the model | §3.3 |
| a_irq | `irq` as the model | §3.4 |
| a_card_identity | `cid` / `rca` / `ccs` as the model | §3.2 |
| a_round_and_matches | `round` / `match_cnt` as the model | §3.3 |
