<!-- SPDX-License-Identifier: Apache-2.0 -->
# I2C_Host: design specification

I2C controller (master) driven by byte commands in the style of the OpenCores I2C master: a
command is any combination of START (or repeated START), one byte WRITE or READ, and STOP.
SCL is driven push-pull (single controller, no clock stretching); SDA is open drain. One
quarter of an SCL period is `prescale` + 1 clocks. Core `I2C_Host_top`
(`rtl/I2C_Host_top.sv`), testbench `tb/I2C_Host_tb.sv` (target: the portfolio's `I2C_top`
at address 0x50, plus a bus monitor); no core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Q = `prescale` + 1. Edge C is the edge that accepts a command.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of every flop | low | async assert | - |
| `scl` | output | 1 | I2C clock, push-pull, from a flop | - | clk | 1 |
| `sda` | inout | 1 | I2C data, open drain: driven 0 when the internal `sda_lo` = 1, else high-Z (external pull-up) | low = driven | clk; read through one flop `sda_s` | released |
| `prescale` | input | 16 | quarter SCL period minus one, in clocks; read at every quarter reload | - | clk | - |
| `cmd_valid` | input | 1 | command strobe; accepted only when idle (`busy` = 0) | high | clk | - |
| `cmd_sta` | input | 1 | command flag: START (repeated START if the bus is held) | high | clk | - |
| `cmd_wr` | input | 1 | command flag: write `tx_data`, then read the target's ACK into `rx_ack` | high | clk | - |
| `cmd_rd` | input | 1 | command flag: read a byte into `rx_data`, then send ACK (or NACK if `cmd_nack`); ignored if `cmd_wr` is also set | high | clk | - |
| `cmd_sto` | input | 1 | command flag: STOP after the rest of the command | high | clk | - |
| `cmd_nack` | input | 1 | with `cmd_rd`: answer the byte with NACK (last byte of a read) | high | clk | - |
| `tx_data` | input | 8 | byte for `cmd_wr`, captured at edge C | - | clk | - |
| `rx_data` | output | 8 | byte of the last READ, updated at the end of its ACK bit | - | clk | 0x00 |
| `rx_ack` | output | 1 | ACK bit of the last WRITE: 0 = ACK, 1 = NACK | - | clk | 0 |
| `busy` | output | 1 | a command is running: `st != IDLE` (combinational from the state flop) | high | clk | 0 |
| `bus_held` | output | 1 | the controller owns the bus: set when a START ends, cleared at the SDA rise of a STOP | high | clk | 0 |
| `done` | output | 1 | one-clock pulse at the end of every accepted command (also of an empty one) | high | clk | 0 |

### Internal signals used by the verification

The TB times the target's next TX byte from these signals; a re-implementation must have them,
with these names, encodings and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `st` | 3 | state, encoded IDLE = 0, STA = 1, BIT = 2, ACK = 3, STO = 4 |
| `q` | 2 | quarter (0..3) of the current bit or condition |
| `qcnt` | 16 | clocks left in the current quarter; loaded with `prescale` at edge C and at each quarter end, so it equals `prescale` in the first clock of a quarter |
| `rd_q` | 1 | the running command reads a byte (`cmd_rd && !cmd_wr` at edge C) |

Other state (names free): `sda_lo`, `bi` (bit index 7..0), `sh` (shift register), captured
command flags, `sda_s` (= `sda !== 0`, sampled every clock).

## 2. Registers

The core has no registers of its own; the APB4 wrapper `I2C_Host_apb` holds `prescale` and
`tx_data`, makes the command strobe and flags from its CMD register, and reads `rx_data`,
`rx_ack`, `busy` and `bus_held`.

<!-- AUTO:registers -->
Generated from [`docs/ip/I2C_Host.md`](../ip/I2C_Host.md) (source: `scripts/apb/specs/I2C_Host.json`); do not edit by hand.

`I2C_Host_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `scl`, `sda`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C510100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | PRESCALE | RW | 0x00000063 | SCL timing |
| 0x018 | TX_DATA | RW | 0x00000000 | Byte sent by the next WR command |
| 0x01C | CMD | WO (pulse) | 0x00000000 | Command (write 1s; one command per write) |
| 0x020 | RX | RO | core | Result of the last command |
| 0x024 | STATUS | RO | core | State |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C51 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| PRESCALE | 15:0 | `prescale` | RW | 0x63 | quarter SCL period - 1, in clocks (reset 0x63: 100 kHz at 40 MHz) |
| TX_DATA | 7:0 | `tx_data` | RW | 0x0 | MSB first |
| CMD | 0 | `cmd_valid` | WO (pulse) | 0x0 | issue the command made of the other bits |
| CMD | 1 | `cmd_sta` | WO (pulse) | 0x0 | START (repeated START when the bus is held) |
| CMD | 2 | `cmd_wr` | WO (pulse) | 0x0 | write TX_DATA |
| CMD | 3 | `cmd_rd` | WO (pulse) | 0x0 | read a byte (ignored with WR) |
| CMD | 4 | `cmd_sto` | WO (pulse) | 0x0 | STOP at the end |
| CMD | 5 | `cmd_nack` | WO (pulse) | 0x0 | RD: answer NACK instead of ACK |
| RX | 7:0 | `rx_data` | RO | core | byte read by the last RD |
| RX | 8 | `rx_ack` | RO | core | ACK bit after the last WR: 0 ACK, 1 NACK |
| STATUS | 0 | `busy` | RO | core | a command is running |
| STATUS | 1 | `bus_held` | RO | core | between a START and a STOP |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a command ended |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C510100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write PRESCALE (0x014), TX_DATA (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. To issue a command, write 1 to `cmd_valid` (CMD bit 0), `cmd_sta` (CMD bit 1), `cmd_wr` (CMD bit 2), `cmd_rd` (CMD bit 3), `cmd_sto` (CMD bit 4), `cmd_nack` (CMD bit 5) at 0x01C; the core sees a one-clock pulse, and the register reads 0.
6. Read RX (0x020) for the core's live `rx_data`, `rx_ack`; it needs no clearing.
7. Read STATUS (0x024) for the core's live `busy`, `bus_held`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write PRESCALE.
2. Write TX_DATA = {address, R/W}, then CMD = valid | sta | wr; wait for DONE, check RX.rx_ack.
3. For each data byte: TX_DATA and CMD = valid | wr (| sto on the last), or CMD = valid | rd (| nack | sto on the last) and read RX.rx_data.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Accepting a command

At edge C (`busy` = 0, `cmd_valid` = 1) the flags and `tx_data` are captured, `q` <= 0,
`bi` <= 7, `qcnt` <= `prescale`, and the first phase is chosen:

1. `cmd_sta` → START phase;
2. else `cmd_wr` or `cmd_rd` → byte phase;
3. else `cmd_sto` and `bus_held` → STOP phase;
4. else nothing on the wire: `done` <= 1 at edge C, `busy` never rises.

`cmd_valid` while `busy` is ignored.

### 3.2 Quarter grid

While busy, `qcnt` counts down from `prescale` and reloads at 0, so quarter actions happen at
edges C + k·Q, k = 1, 2, ...; each phase is 4 quarters (q = 0..3) and the phases follow each
other on the same grid. Every SCL high and low time is a whole number of quarters, at least Q.

### 3.3 Phases (action at the end of quarter q)

| Phase | q = 0 | q = 1 | q = 2 | q = 3 |
|---|---|---|---|---|
| START (from idle or held bus) | release SDA | SCL <= 1 | SDA <= 0 (START while SCL high) | SCL <= 0, `bus_held` <= 1; next: byte phase if WR/RD, else STOP if STO, else end |
| byte bit (×8, MSB first) | WR: SDA <= bit (drive 0 for a 0, release for a 1); RD: release | SCL <= 1 | RD: shift in `sda_s` | SCL <= 0; after bit 0: ACK phase |
| ACK bit | RD: SDA <= 0 for ACK, release for NACK; WR: release | SCL <= 1 | WR: `rx_ack` <= `sda_s` | SCL <= 0; RD: `rx_data` <= byte; next: STOP if STO, else release SDA and end |
| STOP | SDA <= 0 | SCL <= 1 | SDA released (STOP), `bus_held` <= 0 | end (bus free time) |

"End" sets `st` <= IDLE and `done` <= 1 at that edge, so `busy` falls and `done` is high for the
clock after it. `sda_s` is `sda` sampled at the previous edge, so a sample "at q = 2" sees SDA
one clock before the middle of the SCL high time. SDA only changes while SCL is low except in
START and STOP.

Durations from C to the end: START alone 4Q, WRITE or READ byte 36Q (8 bits + ACK), STOP 4Q,
summed for combined commands (for example START + WRITE + STOP = 44Q).

### 3.4 Bus held between commands

After a command without STOP the bus stays held: SCL low, SDA released. A following START is a
repeated START (SDA released at q0 with SCL low, then the START sequence). A command with only
STOP while the bus is free does nothing on the wire (case 4 of §3.1).

### 3.5 Reset

`rst_n` low: `scl` = 1, SDA released, `busy` = 0, `bus_held` = 0, `done` = 0, `rx_data` = 0,
`rx_ack` = 0, `st` = IDLE. A transfer in progress is cut off (the bus may need a STOP from the
next command).

## 4. Parameters

The core has no parameters.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| target NACKs an address or byte | `rx_ack` = 1; the command still completes; software decides to STOP |
| `cmd_wr` and `cmd_rd` both set | write only |
| command while busy | ignored; one `done` per accepted command |
| empty command / STOP with bus free | `done` pulse only |
| target that samples on its own clock (`I2C_top`) | needs Q ≥ 3 |
| `prescale` changed during a command | takes effect at the next quarter reload |

## 6. TB check map

Messages are printed by `tb/I2C_Host_tb.sv` as `ERROR: <message>`. The bus monitor decodes
START, STOP and the 9 bits of every byte independently of the core and the target.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "SCL" (`SCL low/high for N clocks`) | every SCL level lasts at least `prescale` + 1 clocks | §3.2 |
| "busy low after a command" | `busy` = 1 the clock after a command that does something on the wire | §3.1 |
| `N DONE pulses for one command` | exactly one `done` per command, also when another command is strobed while busy | §3.1, §5 |
| "BUS_HELD" | after a command with STOP `bus_held` = 0; with START (no STOP) 1; otherwise unchanged | §1, §3.3 |
| "address" | after the address byte: `rx_ack` = 0 for 0x50, 1 for 0x51 | §3.3, §5 |
| "byte" | after each written byte: `rx_ack` = target's ACK | §3.3 |
| "target got" | the target receives as many bytes as were written | §3.3 |
| "target byte" | each received byte equals the byte written | §3.3 |
| "a byte reached the target at another address" | nothing is delivered after a NACKed address | §5 |
| "wire address byte" | on the wire: address + R/W bit + ACK bit as expected | §3.3 |
| "wire byte" | on the wire: each data byte + ACK bit | §3.3 |
| "read address not acknowledged" | read address 0x50/R is ACKed | §3.3 |
| "read byte" | `rx_data` after each READ equals the target's byte (ACK on all but the last, NACK + STOP on the last, also after a repeated START) | §3.3, §3.4 |
| "monitor saw" | the monitor counted exactly one START per START command and one STOP per STOP with the bus held | §3.3, §3.4 |
| "BUS_HELD at the end" | `bus_held` = 0 after the last STOP | §3.3 |
| "timeout" | the test finishes within 50 ms | §3.2 |

### Coverage-closure assertions

From `tb/cov/I2C_Host_sva.sv` (macros in `tb/cov/cov_macros.svh`; names such as
`t_head` or `m_err` are the checker's own reference model). Each row is the property as written.

| Assertion | What it requires | Spec |
|---|---|---|
| a_reset_idle | while `!rst_n` (reset): `scl && sd && !busy && !bus_held && !done` | §3 |
| a_sda_moves_with_scl_low | always holds: `(scl && scl_q && sd != sd_q) -> (start_c ? (c_sta && busy) : (c_sto && busy))` | §3 |
| a_bus_held | whenever `done`: `bus_held == held` | §3 |
| a_scl_timing | whenever `scl != scl_q && busy`: `m_hc >= prescale` | §3 |
| a_done_conditions | whenever `done`: `n_sta == (c_sta ? 1 : 0) && n_sto == ((c_sto && (c_held \|\| c_sta)) ? 1 : 0) && e_n == (xfer ? 9 : 0)` | §3 |
| a_done_write | whenever `done && c_wr`: `e_bits[8:1] == c_tx && rx_ack == e_bits[0]` | §3 |
| a_done_read | whenever `done && c_rd`: `rx_data == e_bits[8:1] && e_bits[0] == c_nack` | §3 |
| a_busy | whenever `go && (cmd_sta \|\| cmd_wr \|\| cmd_rd \|\| (cmd_sto && held))`, on the next clock: `busy` | §3 |
| a_nothing | whenever `go && !cmd_sta && !cmd_wr && !cmd_rd && !(cmd_sto && held)`, on the next clock: `done && !busy` | §3 |

### Further TB checks

| Check (TB message) | What it requires | Spec |
|---|---|---|
| "not idle in reset" | fails when `bus_held \|\| busy \|\| scl !== 1'b1` (`tb/I2C_Host_tb.sv` line 187) | §3 |
