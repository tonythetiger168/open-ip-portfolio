<!-- SPDX-License-Identifier: Apache-2.0 -->
# MIPI_I3C: design specification

An I3C target (slave) controller: legacy I2C-style register access on a static or dynamic
address (16 x 8 register file), the broadcast CCCs ENTDAA and RSTDAA and the CCC GETPID, ENTDAA
dynamic address assignment with arbitration, and in-band interrupts. Simplified: data bytes are
acknowledged like I2C (no T-bit), HDR modes, hot-join, secondary-master roles and most CCCs are
not implemented, and timing is set by the oversampling clock. Core `MIPI_I3C_top`
(`rtl/MIPI_I3C_top.sv`), testbench `tb/MIPI_I3C_tb.sv`, checker `tb/cov/MIPI_I3C_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. "Rise" / "fall" are SCL edges as seen through the synchronisers.
Bytes go MSB first.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | system clock; oversamples the bus | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `scl` | input | 1 | I3C clock from the master (synchronised inside) | - | async | - |
| `sda` | inout | 1 | I3C data: driven `pp_val` when `pp_en`, else 0 when `od_low`, else released | - | `clk` | released |
| `ibi_req` | input | 1 | level: request an in-band interrupt (latched) | high | `clk` | - |
| `ibi_data` | input | 8 | IBI payload byte (read when the master accepts the IBI) | - | `clk` | - |
| `dyn_addr` | output | 7 | assigned dynamic address | - | `clk` | 0 |
| `dyn_addr_valid` | output | 1 | a dynamic address is assigned | high | `clk` | 0 |
| `irq` | output | 1 | sticky error / IBI-loss flag, cleared by the next START | high | `clk` | 0 |

### Internal signals used by the verification

The checker (`.*`) compares the SDA drivers and the register file; fsm_cov binds `state` (0 IDLE,
1 ADDR, 2 ADDR_ACK, 3 RX_DATA, 4 RX_ACK, 5 TX_DATA, 6 TX_ACK, 7 DAA_TX, 8 DAA_RX, 9 DAA_ACK,
10 IBI_ARB, 11 IBI_ACK, 12 IBI_TX, 13 IBI_TXACK, 14 WAIT_STOP).

| Signal | Width | Meaning |
|---|---|---|
| `od_low` | 1 | open-drain driver: pull SDA low |
| `pp_en` | 1 | push-pull driver enable |
| `pp_val` | 1 | push-pull value |
| `mem` | 8 x 16 | register file, unpacked `[0:15]`; reset 0 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/MIPI_I3C.md`](../ip/MIPI_I3C.md) (source: `scripts/apb/specs/MIPI_I3C.json`); do not edit by hand.

`MIPI_I3C_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `scl`, `sda`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4D330200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x018 | IBI | RW | 0x00000000 | In-band interrupt payload |
| 0x01C | STATUS | RO | core | Dynamic address |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x020 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4D33 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD | 0 | `ibi_req` | WO (pulse) | 0x0 | write 1: request an in-band interrupt carrying IBI.ibi_data; held until a dynamic address is assigned and the bus is idle, kept after a NACK, dropped after a lost arbitration |
| IBI | 7:0 | `ibi_data` | RW | 0x0 | the IBI data byte (read when the IBI goes out) |
| STATUS | 6:0 | `dyn_addr` | RO | core | dynamic address assigned by ENTDAA |
| STATUS | 7 | `dyn_addr_valid` | RO | core | a dynamic address is assigned (cleared by RSTDAA) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PROTO | protocol error or IBI arbitration lost: register pointer out of range, unknown CCC, 7E/R outside ENTDAA, ENTDAA parity error, lost IBI. Held in the core until the next START, so the bit is set again on every clock until then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4D330200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write IBI (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. To issue a command, write 1 to `ibi_req` (CMD bit 0) at 0x014; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x01C) for the core's live `dyn_addr`, `dyn_addr_valid`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Bus sampling and driving

`scl` and `sda` pass three flops. START = SDA falling while SCL is high, STOP = SDA rising
while SCL is high; both are ignored while this target drives SDA. Bits are sampled at SCL rise;
the target changes its drivers at SCL fall. Address, ACK and arbitration phases use the
open-drain driver (`od_low`); data the target transmits uses push-pull (`pp_en` / `pp_val`). The
two are never on together.

### 3.2 Address phase

After a START (or repeated START) 8 bits {address, RnW} are taken. The target ACKs (pulls SDA low
from the fall after the 8th bit to the next fall) when:

- address = STATIC_ADDR, or = `dyn_addr` with `dyn_addr_valid`;
- address = 0x7E with RnW = 0 (broadcast write);
- address = 0x7E with RnW = 1 while it still needs an address in ENTDAA.

Otherwise it NACKs and ignores the bus until the next START or STOP.

### 3.3 Register access

Write (own address /W): the first byte is the register pointer; a value >= 16 is NACKed with
`irq` (transfer ignored), else ACKed. Each following byte is written to `mem[pointer]` and the
pointer increments (4-bit wrap); all ACKed. Read (own address /R): push-pull bytes from
`mem[pointer]`; the first bit is driven at the fall that ends the ACK, each next bit at a fall;
SDA is released for the master's ACK, sampled at the 9th rise. ACK: the pointer increments and
the next byte follows; NACK: the read ends.

### 3.4 CCCs (7E/W, then the code byte)

| Code | Action |
|---|---|
| 0x07 ENTDAA | ACK; ENTDAA active until STOP; the target takes part if it has no dynamic address |
| 0x06 RSTDAA | ACK; `dyn_addr_valid` = 0 |
| 0x8C GETPID | ACK; the next own-address read (after Sr) in this transfer returns PID bytes 47:40, 39:32, ..., 7:0, then byte 7:0 repeated |
| others | NACK and `irq` |

### 3.5 ENTDAA

Each 7E/R in ENTDAA that the target ACKs is followed by its 64-bit answer {PID, BCR, DCR},
open-drain (released for 1, pulled for 0), first bit at the fall that ends the ACK. If a bit it
released reads 0 at the rise, it lost arbitration: it stops driving and waits for the next
repeated START (it answers again at the next 7E/R). After 64 bits it takes 8 bits {address[6:0],
parity}: if the 8 bits have odd parity the address is taken (`dyn_addr`, `dyn_addr_valid`) and
ACKed; otherwise NACK and `irq`. A 7E/R in ENTDAA when the target has an address (or got one) is
NACKed without `irq`; a 7E/R outside ENTDAA is NACKed with `irq`.

### 3.6 In-band interrupt

`ibi_req` sets a pending flag. When the target is idle (after STOP or reset) with a pending
request and a dynamic address, it pulls SDA low. At the master's first SCL fall it sends {dyn_addr,
1} open-drain with arbitration: losing (a released 1 reads 0) releases SDA, drops the pending
request and sets `irq`. After the 8 bits SDA is released and the master's ACK is sampled at the
9th rise. ACK: `ibi_data` is sent push-pull, then SDA is released and the request is cleared at
the following fall. NACK: the request stays pending for a later attempt.

### 3.7 irq

Set by: pointer >= 16, unknown CCC, 7E/R outside ENTDAA, ENTDAA parity error, lost IBI
arbitration. It stays set until the next START (which clears it) or reset.

### 3.8 Reset

SDA released, `mem` = 0, no dynamic address, no pending IBI, `irq` = 0, IDLE.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `STATIC_ADDR` | 0x3C | any 7-bit value except 0x7E | static address |
| `PID` | 0x0123456789AB | any | 48-bit provisioned ID (ENTDAA, GETPID) |
| `BCR` | 0x06 | any | bus characteristics register (ENTDAA) |
| `DCR` | 0x5A | any | device characteristics register (ENTDAA) |

## 5. Errors and corner cases

- Bytes written after a CCC code in the same transfer go down the register-write path (normally
  written at the current pointer); the target does not track CCC payloads.
- STOP ends ENTDAA and GETPID; the dynamic address survives STOP and is cleared only by RSTDAA or
  reset.
- An IBI request is only latched; a short `ibi_req` pulse is enough.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "write address ACK" | own address /W is ACKed | §3.2 |
| "pointer ACK" | pointer byte < 16 is ACKed | §3.3 |
| "data ACK" | data bytes are ACKed and written | §3.3 |
| "read address ACK" | own address /R is ACKed | §3.2 |
| "ENTDAA 64-bit answer" | ENTDAA answer is PID, BCR, DCR MSB first | §3.5 |
| "7E/W ACK" | the broadcast address /W is always ACKed | §3.2 |
| "ENTDAA address taken" | a good dynamic address byte is ACKed and taken | §3.5 |
| "second 7E/R NACKed without irq" | 7E/R inside ENTDAA with an address already assigned: NACK, no `irq` | §3.5 |
| "dynamic address" | `dyn_addr` / `dyn_addr_valid` | §3.5 |
| "IBI arbitration header" | IBI header is {dynamic address, 1} | §3.6 |
| "reset state" | reset values | §3.8 |
| "pointer 0x10 NACKed" | pointer >= 16 NACKed | §3.3 |
| "irq for bad pointer" | ...with `irq` | §3.3 |
| "START clears irq" | `irq` cleared at START | §3.7 |
| "other address NACKed" | other addresses are not acknowledged | §3.2 |
| "7E/R NACK" | 7E/R outside ENTDAA is NACKed | §3.5 |
| "irq for 7E/R outside ENTDAA" | ...with `irq` | §3.5 |
| "irq for unknown CCC" | unknown CCC: NACK and `irq` | §3.4 |
| "no IBI without a dynamic address" | no IBI before a dynamic address | §3.6 |
| "ENTDAA lost to the other slave" | a slave losing ENTDAA arbitration drops out | §3.5 |
| "ENTDAA parity error" | bad parity: NACK, `irq`, no address | §3.5 |
| "ENTDAA after the retries" | the slave answers again at the next 7E/R | §3.5 |
| "nothing left" | ...until assigned | §3.5 |
| "dynamic address 2A" | the assigned value is used | §3.5 |
| "held IBI delivered" | an IBI request waits for bus idle | §3.6 |
| "GETPID read ACK" | after GETPID the own read is ACKed | §3.4 |
| "IBI NACKed" | a NACKed IBI header keeps the request | §3.6 |
| "IBI retried and delivered" | ...and the IBI is retried | §3.6 |
| "IBI arbitration lost" | losing IBI arbitration sets `irq` | §3.6 |
| "lost IBI is dropped" | ...and drops the request | §3.6 |
| "RSTDAA" | RSTDAA clears the dynamic address | §3.4 |
| "assigned slave stays out of ENTDAA" | a slave with an address does not answer ENTDAA | §3.5 |
| "reset mid-read" | reset releases SDA at once | §3.8 |
| a_reset_state | reset values | §3.8 |
| a_open_drain | `od_low` equals the checker's model | §3 |
| a_push_pull | `pp_en` / `pp_val` as the model | §3 |
| a_dynamic_address | `dyn_addr` / `dyn_addr_valid` as the model | §3.5 |
| a_irq | `irq` as the model | §3.7 |
| a_register_file | `mem` as the model | §3.3 |
| a_never_both_drivers | `od_low` and `pp_en` never together | §3.1 |
