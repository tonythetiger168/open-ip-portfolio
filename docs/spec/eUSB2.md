# eUSB2: design specification

A simplified eUSB2 device/repeater. It receives the eD+/eD- single-ended lines one cell per clock, retimes them onto standard USB2 `dp`/`dm`, and detects squelch (a long SE0). It also decodes control packets on the line (NRZI, bit unstuffing, CRC8) that write or read an 8 x 8 register file, and answers each read with a response frame driven on `dp`/`dm`. Line levels are plain logic levels, not 1.2 V analog signalling.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset value |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one line cell (bit time) per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `edp` | input | 1 | eD+ line level (J = `{edp,edm}` 10, K = 01, SE0 = 00, SE1 = 11 illegal) | - | `clk` | - |
| `edm` | input | 1 | eD- line level | - | `clk` | - |
| `dp` | output | 1 | USB2 D+: retimed `edp`, a read-response frame, or 0 while squelched | - | `clk` | 0 |
| `dm` | output | 1 | USB2 D-: retimed `edm`, a read-response frame, or 0 while squelched | - | `clk` | 0 |
| `squelch` | output | 1 | signal loss: SE0 held longer than the threshold in reg0; only a J cell clears it | high | `clk` | 0 |
| `irq` | output | 1 | sticky protocol error (SE1, bit-stuff error, bad control packet); cleared only by `rst_n` | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these through `dut.`, and the SVA checker binds `regfile`. A re-implementation must keep these names and encodings.

| Signal | Width | Meaning |
|---|---|---|
| `pstate` | 1 | receive parser state: 0 = P_IDLE (sync hunt), 1 = P_RUN (inside a packet) |
| `rstate` | 3 | response transmitter state: 0 R_IDLE, 1 R_SYNC, 2 R_BYTE, 3 R_EOP0, 4 R_EOP1, 5 R_EOPJ |
| `resp_active` | 1 | a read-response frame owns `dp`/`dm`; high whenever `rstate` is not R_IDLE |
| `se0_cnt` | 8 | consecutive SE0 cells seen, saturating at 255; cleared by J, K or SE1 |
| `regfile` | 8 x 8 (unpacked `[0:7]`) | control register file; reg0 = squelch threshold (reset 8), reg1 = termination config, reg2-7 scratch (reset 0) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/eUSB2.md`](../ip/eUSB2.md) (source: `scripts/apb/specs/eUSB2.json`); do not edit by hand.

`eUSB2_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `edp`, `edm`, `dp`, `dm`, `squelch`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x65550200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Line state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6555 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `squelch` | RO | core | signal loss: SE0 longer than the squelch threshold (cleared by J); same as the squelch pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | SE1 on the line, bit-stuff error, truncated or over-long control packet, or CRC8 mismatch. Sticky in the core until PRESETN, so the bit is set again on every clock |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x65550200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `squelch`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Line cells and the retime path

Every clock samples one cell `{edp, edm}`: J = 10, K = 01, SE0 = 00, SE1 = 11. The idle line is J.

`edp`/`edm` are registered once. The outputs are chosen combinationally, in this priority:
1. While `resp_active` is high, `dp`/`dm` carry the response frame (§3.5).
2. Otherwise, while `squelch` is high, `dp`/`dm` = 00.
3. Otherwise `dp`/`dm` equal `edp`/`edm` delayed by exactly one clock.

The input is never forwarded while a response is being sent.

### 3.2 Squelch

`se0_cnt` counts consecutive SE0 cells and saturates at 255. Each clock:
- On an SE0 cell, `se0_cnt` increments. If its value before the increment is already >= reg0, `squelch` is set at that edge. With threshold T, `squelch` rises at the edge that samples the (T+1)-th consecutive SE0 cell. reg0 resets to 8.
- On a J cell, `se0_cnt` and `squelch` both clear.
- On a K or SE1 cell, `se0_cnt` clears but `squelch` holds. Only J ends squelch.

While `squelch` is high:
- the outputs are 00 (unless a response is active);
- the receive parser is held in P_IDLE, so any packet in progress is dropped;
- line cells, SE1 included, are not checked for errors.

### 3.3 Receive parser

A cell pair forms a bit only when both the current and the previous cell are J or K; the first J/K cell after an SE0 or SE1 is not a bit. NRZI decoding gives 1 for no transition and 0 for a transition. Bits are LSB first within each byte.

- **Sync (P_IDLE):** the parser hunts for seven 0-bits followed by a 1-bit (from idle J: K J K J K J K K). The 0-bit count saturates at 7, so a longer run of 0s still syncs. The final 1-bit moves `pstate` to P_RUN.
- **Unstuffing (P_RUN):** after six consecutive 1-bits the next bit must be 0, and it is dropped. If it is 1, `irq` is set and the parser returns to P_IDLE.
- **Packet layout:** a control packet has PID = 8'hC3 followed by:
  - CMD = `{rnw, addr[2:0], 4'b0}` (the low nibble is ignored);
  - for a write (`rnw` = 0): WDATA, then CRC8 over CMD and WDATA;
  - for a read (`rnw` = 1): CRC8 over CMD only.
- **CRC8:** polynomial 0x07, initial value 8'hFF, each byte processed MSB-first.
- **Other PIDs:** the parser only checks CRC and length for control packets. A packet with any other PID, or one that ends before its PID byte is complete, is ignored and raises no error.
- **EOP:** the first SE0 cell in P_RUN ends the packet and returns `pstate` to P_IDLE. For a control packet the parser then checks:
  1. If the CRC byte has not arrived, or a full extra byte followed it, `irq` is set and nothing is executed.
  2. Otherwise, if the received CRC differs from the computed one, `irq` is set and nothing is executed.
  3. Otherwise a write updates `regfile[addr]` at that edge, and a read posts a response request.

An SE1 cell outside squelch sets `irq` and returns the parser to P_IDLE.

### 3.4 Register file

| Reg | Reset | Use |
|---|---|---|
| 0 | 8'd8 | squelch threshold (§3.2) |
| 1 | 8'd0 | termination config (stored only; no hardware effect) |
| 2-7 | 8'd0 | scratch |

All eight registers are read/write through control packets. A write to reg0 changes the squelch threshold from the next clock.

### 3.5 Read response frame

1. The EOP edge of a good read posts a single request slot.
2. On the next clock the transmitter, in R_IDLE, takes the request. It sets `resp_active`, latches `addr` and `regfile[addr]` (the value at that moment), and drives J.
3. **R_SYNC (8 clocks):** seven toggles and one hold: K J K J K J K K.
4. **R_BYTE:** four bytes, LSB first, NRZI encoded (a 0 toggles, a 1 holds) and bit-stuffed (after six 1s, an extra toggle is inserted):
   - 8'h3C;
   - `{1'b1, addr, 4'b0000}`;
   - data;
   - CRC8 (init 8'hFF, poly 0x07) over the echo and data bytes only.

   A stuffed bit needed after the last CRC bit is sent before the EOP.
5. **R_EOP0, R_EOP1:** SE0, SE0.
6. **R_EOPJ:** `resp_active` falls at the edge that leaves R_EOPJ, and the outputs go back to the retime/squelch path.

The frame never drives SE1. It is at most 46 cells long, while the shortest read request is 35 cells. The single request slot therefore cannot overflow. The parser keeps receiving while a response is being sent.

### 3.6 irq

`irq` is set by any of:
- SE1 outside squelch;
- a bit-stuff error;
- a truncated or over-long control packet;
- a control-packet CRC mismatch.

It stays set until `rst_n`. Good traffic, non-control packets and runt packets never set it.

### 3.7 Reset

`rst_n` low clears everything at once:
- `squelch` and `irq` are cleared;
- the retime registers become 0, so `dp`/`dm` = 00 during and right after reset;
- both state machines go idle and a response in progress is abandoned;
- `regfile` returns to {8, 0, 0, 0, 0, 0, 0, 0}.

## 4. Parameters

None.

## 5. Errors and corner cases

- **Threshold 0:** reg0 = 0 makes the first SE0 cell of every EOP raise `squelch` until the next J, so the outputs are silenced for the EOP. Packets still execute, because the EOP is decoded at the first SE0 edge, before `squelch` is high.
- **No error checks while squelched:** an SE1 seen while `squelch` is high does not set `irq`.
- **Read data timing:** read data is sampled one clock after the EOP, so a register write landing in that clock is not seen.
- **Partial extra byte:** extra bits after the CRC that do not complete a full byte are not reported as over-long.
- **No response queue:** a second read request posted while one is waiting would overwrite the first. By the cell-count argument in §3.5 this cannot happen with legal framing.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "timeout waiting for read response" | a read request is answered with a response frame (sync K) within 300 clocks | §3.5 |
| "SE1 inside read response" | the response frame never drives SE1 | §3.5 |
| "bit-stuff error in read response" | the response is bit-stuffed: a 0 after every six 1s | §3.5 |
| "read response EOP missing" | the response ends with SE0 SE0 | §3.5 |
| "response byte count" | the response carries exactly 4 bytes | §3.5 |
| "response PID" | response byte 0 is 8'h3C | §3.5 |
| "response cmd" | response byte 1 echoes {1, addr, 4'b0} | §3.5 |
| "read data" | response byte 2 is the register value | §3.4, §3.5 |
| "response CRC8" | response byte 3 is CRC8 over the echo and data bytes | §3.5 |
| "runt packet raised irq" | a packet that ends before its PID byte is complete is not an error | §3.3 |
| "reset during response" | `rst_n` during a response clears `irq` and `squelch` | §3.7 |
| "CRV irq not set on first error injection" | the first injected error sets `irq` | §3.6 |
| "CRV irq dropped (must be sticky)" | `irq` stays set | §3.6 |
| "CRV squelch not detected" | SE0 beyond the threshold raises `squelch` | §3.2 |
| "CRV outputs not silenced during squelch" | `dp`/`dm` = 00 while squelched | §3.2 |
| "CRV squelch cleared by K" | K does not clear `squelch` | §3.2 |
| "CRV squelch did not clear on J" | J clears `squelch` | §3.2 |
| "CRV retime mismatch after squelch" | after squelch ends the outputs are the 1-clock retimed copy again | §3.1 |
| "reset dp/dm" | reset outputs 00 | §3.7 |
| "reset squelch" | reset `squelch` = 0 | §3.7 |
| "reset irq" | reset `irq` = 0 | §3.7 |
| "idle J not retimed, dp/dm" | an idle J line appears on `dp`/`dm` one clock later | §3.1 |
| "irq set during error-free operations" | good traffic never sets `irq` | §3.6 |
| "squelch not detected after long SE0" | SE0 beyond the threshold raises `squelch` | §3.2 |
| "outputs not silenced during squelch" | `dp`/`dm` = 00 while squelched | §3.2 |
| "squelch cleared by K (only J may clear)" | K does not clear `squelch` | §3.2 |
| "outputs not silenced during squelched K" | K cells are not forwarded while squelched | §3.2 |
| "squelch did not clear on J" | J clears `squelch` | §3.2 |
| "irq not set after SE1 injection" | SE1 on the line sets `irq` | §3.6 |
| "CRV" | any other mismatch in the constrained-random phase (100 transactions) | §3 |
| "TIMEOUT" | simulation watchdog | - |
| "A1 reset: outputs quiescent" | in reset `dp`/`dm` = 00, `squelch` = 0, `irq` = 0 | §3.7 |
| "A2 state encodings legal" | `pstate` <= 1 and `rstate` <= 5 | §1 |
| "A3 irq sticky" | `irq` never falls outside reset | §3.6 |
| "A4 squelch silences dp/dm" | `squelch` and no response: `dp`/`dm` = 00 | §3.2 |
| "A5 rstate active implies resp_active" | `rstate` != R_IDLE implies `resp_active` | §3.5 |
| "A6 response never SE1" | `resp_active` implies `dp`/`dm` != 11 | §3.5 |
| "A7 squelch threshold held during SE0" | squelched SE0 implies `se0_cnt` >= reg0 | §3.2 |
| a_reset_state | in reset: `squelch` = 0, `irq` = 0, `{dp,dm}` = 00 | §3.7 |
| a_outputs | `{dp,dm}` equals the checker's model (response > squelch silence > retimed input) | §3.1, §3.5 |
| a_squelch | `squelch` equals the modelled SE0-count rule | §3.2 |
| a_irq | `irq` equals the modelled error rule | §3.6 |
| a_register_file | `regfile` equals the modelled register writes | §3.4 |
| a_response_never_se1 | no response cell is SE1 | §3.5 |
