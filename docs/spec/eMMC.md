# eMMC: design specification

An eMMC host in 1-bit bus mode. After reset it runs the device hardware-reset and power-up sequence (RST_n, tRSCA, 74 clocks). It then identifies and selects the card with CMD0, CMD1 (polled), CMD2, CMD3 and CMD7, and from there repeats demo rounds on its own: a CMD24 single-block write of an internal pattern, then a CMD17 read of the same block with a read-back compare.

The blocks are 32 bytes (256 bits) instead of 512. All status is internal (sticky error flags, the CID, round counters), and `irq` pulses on each error. The core has no register port, and the `eMMC_apb` wrapper exposes only `irq` (through IRQ_STATUS), so the flags and counters can be read only hierarchically.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset value |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | system clock; CLK is divided from it | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous host reset; restarts the power-up sequence | low | async | - |
| `emmc_clk` | output | 1 | eMMC CLK: `clk` / `ID_CLK_DIV` during identification, `clk` / `CLK_DIV` from CMD7 on, 50% duty | - | `clk` | 0 |
| `cmd` | inout | 1 | CMD line: host drives commands, card drives responses; changes at CLK falling edges | - | CLK | high-Z |
| `dat` | inout | 8 | DAT lines: only `dat[0]` is used (1-bit mode); `dat[7:1]` are always high-Z | - | CLK | high-Z |
| `emmc_rst_n` | output | 1 | device hardware reset RST_n | low | `clk` | 0 |
| `irq` | output | 1 | one-`clk` pulse per detected error (§3.8) | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these through `dut.`, and the SVA checker binds them. A re-implementation must keep these names, widths, encodings and timings.

| Signal | Width | Meaning |
|---|---|---|
| `tick` | 1 | combinational: this `clk` edge is a CLK rising edge; the FSM samples CMD/DAT0 and steps only here |
| `fast` | 1 | CLK runs at `CLK_DIV` (set when CMD3 succeeds, cleared by any identification failure) |
| `state` | 3 | host FSM: 0 H_CTX, 1 H_GAP, 2 H_RSP, 3 H_IDLE, 4 H_WDAT, 5 H_RDAT, 6 H_PWR |
| `cur` | 3 | command in flight: 0 CMD0, 1 CMD1, 2 CMD2, 3 CMD3, 4 CMD24, 5 CMD17, 6 CMD7 |
| `dphase` | 3 | data sub-phase: 0 START, 1 DATA, 2 CRC, 3 END, 4 TOK, 5 BUSY |
| `bit_cnt` | 9 | bit counter of the current frame or data phase |
| `cmd_oe_r` | 1 | FSM's next CMD drive enable (set at a tick) |
| `cmd_out_r` | 1 | FSM's next CMD value |
| `dat0_oe_r` | 1 | FSM's next DAT0 drive enable |
| `dat0_out_r` | 1 | FSM's next DAT0 value |
| `cmd_oe_p` | 1 | CMD pin enable: `cmd_oe_r` copied at each CLK falling edge |
| `cmd_out_p` | 1 | CMD pin value: `cmd_out_r` copied at each CLK falling edge |
| `dat0_oe_p` | 1 | DAT0 pin enable: `dat0_oe_r` copied at each CLK falling edge |
| `dat0_out_p` | 1 | DAT0 pin value: `dat0_out_r` copied at each CLK falling edge |
| `init_done` | 1 | CMD7 completed: identification and selection done |
| `cid` | 128 | CID from the last good R2 (CID[127:1] plus the end bit in bit 0) |
| `round` | 8 | demo round counter (wraps); block address = `round[1:0]` |
| `match_cnt` | 8 | successful read-back compares (wraps) |
| `err_crc7` | 1 | sticky: response framing / CRC7 / CID CRC error |
| `err_status` | 1 | sticky: R1 card-status error bit set |
| `err_timeout` | 1 | sticky: response, token, read access or busy timeout |
| `err_crc16` | 1 | sticky: write CRC status token not accepted, or read CRC16 / end bit error |
| `err_cmp` | 1 | sticky: read-back data differs from the written pattern |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/eMMC.md`](../ip/eMMC.md) (source: `scripts/apb/specs/eMMC.json`); do not edit by hand.

`eMMC_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `emmc_clk`, `cmd`, `dat`, `emmc_rst_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x654D0300 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x654D | IP code |
| ID | 15:8 | MAJOR | RO | 0x03 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a response, CRC status, busy or read phase failed (framing, CRC7, command index, card-status error bits, timeout, negative or missing CRC status, busy timeout, read CRC16 / end bit / compare); the host retries |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x654D0300.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 CLK and pin timing

CLK is divided from `clk` by an even divider:
- The divider runs from reset. CLK rises at the `tick` edge and falls `DIV`/2 clocks later (`ftick`), so the period is `DIV` clocks at 50% duty.
- `DIV` is `ID_CLK_DIV` while `fast` = 0 and `CLK_DIV` while `fast` = 1. The rate changes only at a tick, so every period is whole.
- `fast` is set at the tick where CMD3's R1 passes, so CMD7 and everything after run at the fast rate. Every identification restart clears it.

Pin timing:
- The FSM samples `cmd` and `dat[0]` and steps only at ticks (CLK rising edges).
- It sets the `_r` drive registers at a tick, and the `_p` pin registers copy them at the next CLK falling edge. CMD and DAT0 therefore change only while CLK is low, half a period before the card samples them.

### 3.2 Power-up (state H_PWR)

This sequence runs after `rst_n`, counting in `clk` cycles:
1. `emmc_rst_n` stays low for `RST_LOW` clocks, then rises.
2. The host waits `RST_WAIT` clocks (tRSCA).
3. It counts 74 CLK ticks with CMD and DAT0 released.
4. At the 74th tick it issues CMD0.

### 3.3 Identification and selection

| Step | Command (argument) | Response | Next |
|---|---|---|---|
| 1 | CMD0 (0) | none; 8 CLK gap with CMD released | CMD1 |
| 2 | CMD1 (0x40FF8080) | R3: start 0, transmission 0, bits 45:40 = 111111, bits 7:0 = 8'hFF | OCR bit 31 = 1: CMD2; 0: CMD1 again |
| 3 | CMD2 (0) | R2 (136 bits): transmission 0, 111111, CID with CRC7(CID[127:8]) = CID[7:1], end bit 1 | store `cid`; CMD3 |
| 4 | CMD3 (0x00010000, RCA 1) | R1 | `fast` = 1; CMD7 |
| 5 | CMD7 (0x00010000) | R1b | `init_done` = 1; H_IDLE |

If any response check fails or times out during identification:
- the matching error flag is set and `irq` pulses;
- `fast` clears and the host restarts at CMD0.

The power-up sequence is not repeated.

### 3.4 Command frames and responses

**Command frame:** 48 bits, MSB first: start 0, transmission 1, index[5:0], argument[31:0], CRC7, end 1. The CRC7 uses poly 0x09, init 0, over the first 40 bits.

**Issue:** issuing a command enables the CMD driver at once, so the line is driven high for one CLK before the start bit. The 48 bits follow on consecutive CLKs. CMD is released one CLK after the end bit.

**Response hunt:** the host looks for the response start bit from the first tick after release. That catches N_CR = 2. It looks for up to 64 ticks; no start bit means a timeout.

**R1 checks** (48 bits, after CMD3, CMD7, CMD24 and CMD17):
- transmission bit 0;
- index equal to the command;
- CRC7 over bits 47:8;
- end bit 1.

Any failure is a framing/CRC error. If `status & 0xFDF98080` != 0 the response is a card-status error. Other status bits are ignored.

**Next command:** it is issued at the tick that samples the last response bit, so it can start 2 CLKs after the end bit.

### 3.5 Idle gap and R1b busy (state H_IDLE)

Between rounds, and after CMD7, the host needs 8 consecutive ticks with DAT0 high before it issues CMD24.
- While DAT0 is low (R1b busy), the gap counter restarts.
- If the busy lasts `BUSY_TIMEOUT` ticks, `err_timeout` is set and `irq` pulses once. The host then keeps waiting, and the round runs when DAT0 is released.

### 3.6 Demo round

The round uses block address `round[1:0]`. Its block is 8 words, word 0 first and MSB first:

`word i = 32'hA5003C00 ^ round ^ (i * 32'h00010101)`

**Write (CMD24, argument = block address).** After a good R1 the host drives DAT0 as follows:
1. one CLK at 1;
2. start bit 0;
3. 256 data bits;
4. CRC16 (poly 0x1021, init 0, MSB first);
5. end bit 1.

On the next tick it releases DAT0. Then:
- The card's CRC status token must start (DAT0 = 0) within 64 ticks.
- The token's next four bits must be 0101 (status 010, end bit 1). Anything else is `err_crc16`.
- The host then waits for DAT0 to go high (busy release) for up to `BUSY_TIMEOUT` ticks.
- After 6 more ticks it issues CMD17.

**Read (CMD17, same address).** After a good R1, the host hunts for the data start bit for up to `RD_TIMEOUT` ticks. It then takes 256 data bits, 16 CRC bits and the end bit.
- If the end bit is 1, the CRC matches and the data equals the pattern: `match_cnt` and `round` increment (both mod 256) and the host returns to H_IDLE.
- If the data differs: `err_cmp`.
- If the CRC or the end bit is bad: `err_crc16`.

### 3.7 Data-phase errors

After `init_done`, a failure in a response, token, busy or read phase does three things:
- it sets its flag;
- it pulses `irq`;
- it returns the host to H_IDLE without advancing `round`, so the same round is retried from CMD24.

### 3.8 Errors and irq

| Flag | Set by |
|---|---|
| `err_crc7` | R1/R2/R3 framing, CRC7 or CID CRC failure |
| `err_status` | R1 card-status bit in ERR_MASK (8'hFDF98080) |
| `err_timeout` | no response start within 64 CLKs, no CRC token within 64 CLKs, read access > `RD_TIMEOUT`, busy > `BUSY_TIMEOUT` |
| `err_crc16` | CRC status token != 010, or read CRC16 / end bit error |
| `err_cmp` | read-back data differs |

The flags stay set until `rst_n`. `irq` is a single `clk`-cycle pulse for each error.

### 3.9 Reset

`rst_n` low resets the host:
- `emmc_clk` = 0 and `emmc_rst_n` = 0;
- CMD and DAT0 are released (`cmd_out_r` = 1), and `irq` = 0;
- `state` = H_PWR, `fast` = 0;
- all flags, `cid`, `round` and `match_cnt` are cleared.

A reset at any point, including mid-transfer or during power-up, restarts the power-up sequence.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `CLK_DIV` | 2 | even, >= 2 | `clk` cycles per CLK period after CMD3 |
| `ID_CLK_DIV` | 128 | even, >= 2 | `clk` cycles per CLK period during identification; keep CLK <= 400 kHz |
| `RST_LOW` | 64 | >= 1 | `clk` cycles RST_n is held low (tRSTW) |
| `RST_WAIT` | 16384 | >= 1 | `clk` cycles from RST_n high to the 74 clocks (tRSCA) |
| `RD_TIMEOUT` | 2600000 | >= 1 | read access limit in CLK cycles |
| `BUSY_TIMEOUT` | 6500000 | >= 1 | write and R1b busy limit in CLK cycles |

## 5. Errors and corner cases

- **Short N_RC:** a new command can start 2 CLKs after a response's end bit, which is shorter than the JESD84 minimum N_RC of 8. Cards that enforce N_RC are not supported.
- **Early read data:** read data must start after the R1 response has been fully received. A card that starts the data block during the response is not supported.
- **Hidden status:** the error flags are never cleared except by `rst_n`, and software cannot read them; it sees only `irq` pulses.
- **Identification restart:** a failure during identification restarts at CMD0, not at the power-up sequence.
- **Only 1-bit mode:** `dat[7:1]` are never driven or sampled, and are high-Z.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "RST_n low time" | `emmc_rst_n` rises `RST_LOW` clocks after `rst_n` rises | §3.2 |
| "CLK period" | CLK period is `ID_CLK_DIV` before CMD7 and `CLK_DIV` from CMD7 | §3.1 |
| "identification at the fast rate" | CMD0-CMD3 are sent at the identification rate | §3.1 |
| "CMD / DAT0 changed while CLK is high" | pins change only at CLK falling edges | §3.1 |
| "reset state" | reset values | §3.9 |
| "power-up sequence" | RST_n low, tRSCA wait, 74 clocks, then CMD0 | §3.2 |
| "CID / selected" | CID captured and card selected | §3.3 |
| "card store contents" | blocks hold the patterns of the last rounds written to them | §3.6 |
| "host command frames / selection" | well-formed commands; CMD24/CMD17 only after CMD7 | §3.3, §3.4 |
| "err_crc7" | framing / CRC faults set `err_crc7` | §3.8 |
| "err_status" | card-status errors set `err_status` | §3.8 |
| "err_timeout" | timeouts set `err_timeout` | §3.8 |
| "err_crc16" | token / CRC16 faults set `err_crc16` | §3.8 |
| "err_cmp" | compare faults set `err_cmp` | §3.8 |
| "long read access / busy raised irq" | read access and busy just inside the limits are not errors | §3.6, §3.7 |
| "benign status bits raised irq" | R1 status bits outside ERR_MASK are ignored | §3.4 |
| "CMD7 busy timeout flags" | an over-long CMD7 busy flags `err_timeout` but init completes | §3.5 |
| "inverted CID" | every CID bit is captured | §3.3 |
| "CID again" | every CID bit is captured | §3.3 |
| "counters before wrap" | `round` and `match_cnt` count good rounds | §3.6 |
| "round wrapped" | `round` wraps at 256 | §3.6 |
| "host command frame errors" | no malformed host command frame | §3.4 |
| "CMD24 / CMD17 before CMD7" | no data command before selection | §3.3 |
| "N_CR = 2 responses / both clock rates / RST_n pulses seen" | coverage of response timing, both clock rates and RST_n | §3.1-§3.4 |
| "second host made progress" | a second instance with other dividers also completes rounds | §4 |
| a_reset_state | in reset: CMD and DAT0 not driven, `irq` = 0, `emmc_rst_n` = 0, `emmc_clk` = 0 | §3.9 |
| a_clk | `emmc_clk` equals the checker's divider model | §3.1 |
| a_rst_n | `emmc_rst_n` equals the model | §3.2 |
| a_pins | pin registers follow the `_r` values at CLK falling edges | §3.1 |
| a_cmd_driver | `cmd_oe_r`/`cmd_out_r` equal the model | §3.3, §3.4 |
| a_dat0_driver | `dat0_oe_r`/`dat0_out_r` equal the model | §3.6, §3.7 |
| a_irq | `irq` equals the modelled error pulses | §3.8 |
| a_cid | `cid` equals the model | §3.3 |
| a_round_and_matches | `round` and `match_cnt` equal the model | §3.6 |
