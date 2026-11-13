<!-- SPDX-License-Identifier: Apache-2.0 -->
# D_PHY: design specification

A MIPI D-PHY lane pair (clock lane + one data lane) transmitter with a receive decoder for the
same lane: LP states, HS bursts with SoT / sync / EoT, escape mode with LPDT, ULPS and
Trigger-Reset, and an RX side that checks the line sequence. Simplified: every LP state and every
line bit lasts one clock; escape bits are 1 bit per clock (LP-10 = 1, LP-00 = 0) instead of
spaced-one-hot; the HS clock starts with the data burst. Core `D_PHY_top` (`rtl/D_PHY_top.sv`),
testbench `tb/D_PHY_tb.sv` (TX pads looped back to the RX inputs), checker
`tb/cov/D_PHY_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. LP states are written LP-{P}{N}. All pad outputs are
combinational from the transmit state, which changes once per clock.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one line state / bit per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `irq` | output | 1 | sticky RX protocol-error flag | high | `clk` | 0 |
| `irq_clear` | input | 1 | clear `irq` (a new error in the same clock wins) | high | `clk` | - |
| `hs_req` | input | 1 | request an HS burst (latched if busy) | high | `clk` | - |
| `hs_tx_data` | input | 8 | HS payload byte | - | `clk` | - |
| `hs_tx_valid` | input | 1 | HS payload byte offered | high | `clk` | - |
| `hs_tx_ready` | output | 1 | the one-byte buffer takes an HS byte this clock; combinational | high | comb | 0 |
| `hs_tx_done` | output | 1 | one-clock pulse: burst finished, lane back in LP-11 | high | `clk` | 0 |
| `esc_req` | input | 1 | request escape mode with `esc_cmd` (latched if busy) | high | `clk` | - |
| `esc_cmd` | input | 8 | 0x87 LPDT, 0x78 ULPS, 0x46 Trigger-Reset; others: entry, command, exit only | - | `clk` | - |
| `esc_release` | input | 1 | leave ULPS (only seen while in ULPS) | high | `clk` | - |
| `lpdt_data` | input | 8 | LPDT byte | - | `clk` | - |
| `lpdt_valid` | input | 1 | LPDT byte offered | high | `clk` | - |
| `lpdt_last` | input | 1 | the offered LPDT byte is the last | high | `clk` | - |
| `lpdt_ready` | output | 1 | the buffer takes an LPDT byte this clock; combinational | high | comb | 0 |
| `esc_done` | output | 1 | one-clock pulse: escape exit complete (LP-11) | high | `clk` | 0 |
| `d_lp_p` | output | 1 | data lane LP line P; combinational from the state | - | comb | 1 |
| `d_lp_n` | output | 1 | data lane LP line N | - | comb | 1 |
| `d_hs_p` | output | 1 | data lane HS P | - | comb | 0 |
| `d_hs_n` | output | 1 | data lane HS N | - | comb | 1 |
| `d_hs_en` | output | 1 | data lane HS driver on (LP pads read LP-11 then) | high | comb | 0 |
| `c_lp_p` | output | 1 | clock lane LP line P | - | comb | 1 |
| `c_lp_n` | output | 1 | clock lane LP line N | - | comb | 1 |
| `c_hs_p` | output | 1 | clock lane HS P (toggles during a burst) | - | comb | 0 |
| `c_hs_n` | output | 1 | clock lane HS N = !`c_hs_p` | - | comb | 1 |
| `c_hs_en` | output | 1 | clock lane HS driver on | high | comb | 0 |
| `r_lp_p` | input | 1 | RX data lane LP P (looped back from `d_lp_p` in the TB) | - | `clk` | - |
| `r_lp_n` | input | 1 | RX data lane LP N | - | `clk` | - |
| `r_hs_p` | input | 1 | RX data lane HS P | - | `clk` | - |
| `r_hs_n` | input | 1 | RX data lane HS N | - | `clk` | - |
| `r_hs_en` | input | 1 | RX: the HS driver is on | high | `clk` | - |
| `rx_hs_active` | output | 1 | RX in HS sync or data; combinational | high | comb | 0 |
| `rx_data` | output | 8 | received byte (HS payload or LPDT) | - | `clk` | 0 |
| `rx_data_valid` | output | 1 | one-clock pulse with `rx_data` | high | `clk` | 0 |
| `rx_esc_cmd` | output | 8 | received escape command | - | `clk` | 0 |
| `rx_esc_valid` | output | 1 | one-clock pulse with `rx_esc_cmd` | high | `clk` | 0 |
| `rx_ulps` | output | 1 | RX sees the lane in ULPS; combinational | high | comb | 0 |

### Internal signals used by the verification

fsm_cov binds both state machines; keep the names and encodings.

| Signal | Width | Meaning |
|---|---|---|
| `tstate` | 5 | TX: 0 STOP, 1 HS_REQ, 2 HS_SYNC0, 3 HS_HS0, 4 HS_SYNC, 5 HS_DATA, 6 HS_EOT1, 7 HS_EOT2, 8..11 ESC_E1..E4, 12 ESC_CMD, 13 LPDT, 14 ULPS, 15 TRIG, 16 EX_SP, 17 EX_10 |
| `rstate` | 4 | RX: 0 STOP, 1 HS1, 2 HS2, 3 HS_SYNC, 4 HS_DATA, 5..7 ESC1..3, 8 ESC_CMD, 9 LPDT, 10 ULPS, 11 TRIG, 12 EX1, 13 EX2, 14 ERR |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/D_PHY.md`](../ip/D_PHY.md) (source: `scripts/apb/specs/D_PHY.json`); do not edit by hand.

`D_PHY_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `d_lp_p`, `d_lp_n`, `d_hs_p`, `d_hs_n`, `d_hs_en`, `c_lp_p`, `c_lp_n`, `c_hs_p`, `c_hs_n`, `c_hs_en`, `r_lp_p`, `r_lp_n`, `r_hs_p`, `r_hs_n`, `r_hs_en`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD | WO (pulse) | 0x00000000 | Lane requests (latched by the core and served from the next LP-11 stop, HS first) |
| 0x018 | ESC | RW | 0x00000000 | Escape command |
| 0x01C | HS_TX | RW | 0x00000000 | HS payload byte; one byte every eight clocks, and the burst ends (EoT) when the next byte is not there in time |
| 0x020 | LPDT | RW | 0x00000000 | LPDT byte; the escape ends after a byte with last set, or when the next byte is not there in time |
| 0x024 | RX | RO (pop) | 0x00000000 | Byte decoded from the receive lane (HS payload or LPDT); reading RX frees it |
| 0x028 | RX_ESC | RO (pop) | 0x00000000 | Escape command decoded from the receive lane; reading RX_ESC frees it |
| 0x02C | STATUS | RO | core | Receiver state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4450 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 10:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 10:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 3:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD | 0 | `hs_req` | WO (pulse) | 0x0 | write 1: request an HS burst; its bytes come from HS_TX |
| CMD | 1 | `esc_req` | WO (pulse) | 0x0 | write 1: request escape mode with ESC.esc_cmd (a second request before it is served replaces the command) |
| CMD | 2 | `esc_release` | WO (pulse) | 0x0 | write 1: leave ULPS |
| CMD | 3 | `irq_clear` | WO (pulse) | 0x0 | write 1: clear the receiver's sticky error |
| ESC | 7:0 | `esc_cmd` | RW | 0x0 | 0x87 LPDT (bytes from LPDT), 0x78 ULPS, 0x46 trigger reset; taken by CMD.esc_req |
| HS_TX | 7:0 | `hs_tx_data` | RW | 0x0 | HS payload byte; one byte every eight clocks, and the burst ends (EoT) when the next byte is not there in time |
| LPDT | 7:0 | `lpdt_data` | RW | 0x0 | LPDT payload byte |
| LPDT | 8 | `lpdt_last` | RW | 0x0 | last byte |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | Byte decoded from the receive lane (HS payload or LPDT); reading RX frees it |
| RX_ESC | 7:0 | `rx_esc_cmd` | RO (pop) | 0x0 | Escape command decoded from the receive lane; reading RX_ESC frees it |
| STATUS | 0 | `rx_hs_active` | RO | core | an HS burst is being decoded |
| STATUS | 1 | `rx_ulps` | RO | core | the receive lane is in ULPS |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | HS_SENT | an HS burst finished and the lane is back in LP-11 |
| 1 | ESC_DONE | an escape sequence finished (LP-11) |
| 2 | ERROR | the receiver saw a protocol violation (bad HS sync, invalid HS level, unknown escape command, illegal LP sequence); sticky in the core, so the bit is set again on every clock until CMD.irq_clear |
| 3 | HS_TX_DONE | HS_TX beat accepted by the core |
| 4 | HS_TX_OVF | write to HS_TX while full (dropped) |
| 5 | LPDT_DONE | LPDT beat accepted by the core |
| 6 | LPDT_OVF | write to LPDT while full (dropped) |
| 7 | RX_AVAIL | RX captured a beat |
| 8 | RX_OVF | beat dropped, RX was full |
| 9 | RX_ESC_AVAIL | RX_ESC captured a beat |
| 10 | RX_ESC_OVF | beat dropped, RX_ESC was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | HS_TX_FULL | HS_TX holds a beat the core has not taken |
| 1 | LPDT_FULL | LPDT holds a beat the core has not taken |
| 2 | RX_AVAIL | RX holds an unread beat |
| 3 | RX_ESC_AVAIL | RX_ESC holds an unread beat |

### Streams

* **HS_TX** feeds `hs_tx_data`/`hs_tx_valid`. Writing HS_TX commits the beat: FLAGS.HS_TX_FULL is set and `hs_tx_valid` stays high until the core's `hs_tx_ready`; then HS_TX_DONE is set. A write while full is dropped and sets HS_TX_OVF.
* **LPDT** feeds `lpdt_data`, `lpdt_last`/`lpdt_valid`. Writing LPDT commits the beat: FLAGS.LPDT_FULL is set and `lpdt_valid` stays high until the core's `lpdt_ready`; then LPDT_DONE is set. A write while full is dropped and sets LPDT_OVF.
* **RX** captures `rx_data` when `rx_data_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.
* **RX_ESC** captures `rx_esc_cmd` when `rx_esc_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_ESC_AVAIL. Reading RX_ESC pops it. A beat that arrives while the register is full is dropped and sets RX_ESC_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44500200.
2. Write 0x7FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write ESC (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7FF enables all).
5. To issue a command, write 1 to `hs_req` (CMD bit 0), `esc_req` (CMD bit 1), `esc_release` (CMD bit 2), `irq_clear` (CMD bit 3) at 0x014; the core sees a one-clock pulse, and the register reads 0.
6. To send on HS_TX: wait until FLAGS.HS_TX_FULL (bit 0) is 0, or for IRQ HS_TX_DONE, then write HS_TX (0x01C). The last write commits the beat. HS_TX_OVF means a write came while the register was full and was dropped.
7. To send on LPDT: wait until FLAGS.LPDT_FULL (bit 1) is 0, or for IRQ LPDT_DONE, then write LPDT (0x020). The last write commits the beat. LPDT_OVF means a write came while the register was full and was dropped.
8. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 2), then read RX (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 7) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
9. To receive on RX_ESC: wait for IRQ RX_ESC_AVAIL or FLAGS.RX_ESC_AVAIL (bit 3), then read RX_ESC (0x028). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_ESC_AVAIL (bit 9) to clear it. Read each beat before the next arrives, or it is dropped and RX_ESC_OVF is set.
10. Read STATUS (0x02C) for the core's live `rx_hs_active`, `rx_ulps`; it needs no clearing.
11. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Requests

`hs_req` and `esc_req` are latched (the last `esc_cmd` wins). In STOP (LP-11) a request present
in that clock or pending starts the next state in the following clock, HS before escape. There is
at least one STOP clock between two operations.

### 3.2 HS burst

One clock each: LP-01 (both lanes), LP-00 (both lanes), HS-0 (both HS drivers on). Then the sync
byte 0xB8 and the payload bytes, LSB first, one bit per clock (`d_hs_p` = bit, `d_hs_n` = !bit),
then EoT: one clock of the last bit inverted, one clock of the last bit, then LP-11; `hs_tx_done`
pulses in that first LP-11 clock. The clock lane drives HS from HS-0 through EoT, `c_hs_p`
toggling every clock starting at 0 (`c_hs_n` = !`c_hs_p`). While a lane's HS driver is off its HS
pads rest at P = 0, N = 1.

Payload: a one-byte buffer. `hs_tx_ready` = buffer empty, in sync or data, and not in a byte's
bit 7. At bit 7 of the byte on the line the buffered byte (if any) becomes the next byte;
otherwise EoT follows. So the first byte must be given during sync bits 0..6, and each next byte
before bit 7 of the current one; a burst with no byte sends sync and EoT only (last bit = 1).

### 3.3 Escape mode

Entry: LP-10, LP-00, LP-01, LP-00 (one clock each). Then the 8-bit command LSB first (LP-10 = 1,
LP-00 = 0). Then by command:

| Command | Data lane |
|---|---|
| 0x87 LPDT | data bytes, same coding (section 3.4) |
| 0x78 ULPS | LP-00 until a clock with `esc_release` (a release before that is not kept), then LP-10 |
| 0x46 Trigger-Reset | LP-00 for 4 clocks, then LP-10 |
| other | LP-10 at once |

After LP-10 the lane returns to LP-11 and `esc_done` pulses in that first LP-11 clock. The clock
lane stays LP-11.

### 3.4 LPDT

`lpdt_ready` = buffer empty and either in the command of an LPDT escape or in LPDT bits 1..7. At
each byte boundary the buffered byte's bit 0 is driven in that clock (bits 1..7 follow); with no
byte buffered the boundary clock drives LP-01 (exit space), then LP-10, then LP-11. After a byte
offered with `lpdt_last`, the lane drives LP-01, LP-10, LP-11. The host must not offer bytes
after the last one.

### 3.5 Receive decoder

The decoder follows `r_*` one clock at a time:

- From STOP: LP-01 starts an HS entry (then LP-00 and HS-0 with `r_hs_en` are required; LP-01 may
  repeat), LP-10 an escape entry (then exactly LP-00, LP-01, LP-00). LP-00 from STOP is an error.
- HS: the 8 sync bits must be 0xB8, then each 8 bits give `rx_data` with `rx_data_valid` in the
  following clock. `r_hs_en` low ends the burst (back to STOP; leftover bits, such as the two EoT
  bits, are dropped). A level with `r_hs_p` = `r_hs_n`, or `r_hs_en` low during sync, is an
  error.
- Escape: 8 command bits (only LP-10 / LP-00 allowed) give `rx_esc_cmd` / `rx_esc_valid`; LPDT,
  ULPS and Trigger continue, any other command is an error. LPDT: LP-01 at a byte boundary is the
  exit space (then LP-10, LP-11 required); bytes as for HS. ULPS / Trigger: LP-00 until LP-10, then
  LP-11.
- Any other level is an error. An error sets `irq` (sticky until `irq_clear`; a new error in the
  clearing clock keeps it) and the decoder waits for LP-11 with `r_hs_en` low.

`rx_hs_active` = in HS sync or data; `rx_ulps` = in ULPS.

### 3.6 Reset

TX in STOP (LP-11 on both lanes, HS drivers off), nothing pending, buffer empty; RX in STOP;
`irq` = 0; all pulses 0.

## 4. Parameters

None.

## 5. Errors and corner cases

- The transmitter sends unknown escape commands (entry, command, exit); its own decoder flags
  them.
- An `esc_release` outside ULPS is ignored.
- The LP pads read LP-11 while the HS driver is on; a receiver must use `r_hs_en`.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "lpdt command not decoded" | the RX decodes the LPDT command | §3.5 |
| "reset state" | reset values | §3.6 |
| "SoT LP-01" | SoT: LP-01 for one clock | §3.2 |
| "SoT LP-00" | then LP-00 | §3.2 |
| "SoT HS-0" | then HS-0 with the HS driver on | §3.2 |
| "HS differential" | `d_hs_n` = !`d_hs_p` during the burst | §3.2 |
| "sync byte" | 0xB8 LSB first | §3.2 |
| "EoT inverted bit" | EoT: the last bit inverted | §3.2 |
| "EoT hold bit" | then the last bit | §3.2 |
| "EoT stop" | then LP-11 | §3.2 |
| "queued hs request not served" | a request while busy is served at the next STOP | §3.1 |
| "ULPS not observed" | the RX enters ULPS | §3.5 |
| "ULPS not held" | LP-00 until `esc_release` | §3.3 |
| "irq after trigger" | no RX error on Trigger-Reset | §3.3, §3.5 |
| "ulps/trigger cmds" | the RX reports the commands | §3.5 |
| "unknown command irq" | an unknown command is an RX error | §3.5 |
| "pending requests" | both requests latched while busy; HS first | §3.1 |
| "pending command replaced" | a second `esc_req` replaces the pending command | §3.1 |
| "irq after queued traffic" | no RX error on back-to-back traffic | §3.5 |
| "irq clear collision" | an error in the clearing clock keeps `irq` | §3.5 |
| a_reset_outputs | reset values | §3.6 |
| a_d_lp | data lane LP pads equal the checker's model | §3.2, §3.3 |
| a_c_lp | clock lane LP pads as the model | §3.2 |
| a_d_hs_en | `d_hs_en` as the model | §3.2 |
| a_c_hs_en | `c_hs_en` as the model | §3.2 |
| a_d_hs | data lane HS pads as the model | §3.2 |
| a_c_hs | clock lane HS pads as the model | §3.2 |
| a_hs_tx_ready | `hs_tx_ready` as the model | §3.2 |
| a_lpdt_ready | `lpdt_ready` as the model | §3.4 |
| a_done | `hs_tx_done` / `esc_done` as the model | §3.2, §3.3 |
| a_irq | `irq` as the model | §3.5 |
| a_rx_state | `rx_hs_active` / `rx_ulps` as the model | §3.5 |
| a_rx_valid | `rx_data_valid` / `rx_esc_valid` as the model | §3.5 |
| a_rx_data | `rx_data` as the model | §3.5 |
| a_rx_cmd | `rx_esc_cmd` as the model | §3.5 |
