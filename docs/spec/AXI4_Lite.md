<!-- SPDX-License-Identifier: Apache-2.0 -->
# AXI4_Lite: design specification

AXI4-Lite subordinate (slave) with a 256 x 32-bit register file: five channels with
VALID / READY handshakes, single-beat transfers, byte strobes, one write and one read in flight
at a time (the two paths are independent of each other), and SLVERR for any address outside
0x000..0x3FF or not word aligned. Core `AXI4_Lite_top` (`rtl/AXI4_Lite_top.sv`), testbench
`tb/AXI4_Lite_tb.sv` (an AXI4-Lite manager model with a scoreboard), checker
`tb/cov/AXI4_Lite_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A handshake on a channel happens at a rising edge where its VALID
and READY are both 1. All outputs except `irq` are combinational decodes of the state registers.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | ACLK | rising edge | - | - |
| `rst_n` | input | 1 | ARESETn: asynchronous reset of both state machines and `irq` (not the register file) | low | async | - |
| `awaddr` | input | `AW` | AWADDR, byte address; sampled at the AW handshake | - | `clk` | - |
| `awvalid` | input | 1 | AWVALID | high | `clk` | - |
| `awready` | output | 1 | AWREADY: 1 exactly when the write path is idle (no AW taken whose B has not been accepted) | high | comb | 1 |
| `wdata` | input | `DW` | WDATA; sampled at the W handshake | - | `clk` | - |
| `wstrb` | input | `DW/8` | WSTRB: byte lane k is written when bit k is 1 | high | `clk` | - |
| `wvalid` | input | 1 | WVALID | high | `clk` | - |
| `wready` | output | 1 | WREADY: 1 exactly between the AW handshake and the W handshake | high | comb | 0 |
| `bresp` | output | 2 | BRESP: 00 OKAY, 10 SLVERR (address error); valid with `bvalid` | - | comb | 00 |
| `bvalid` | output | 1 | BVALID: 1 from the clock after the W handshake until the B handshake | high | comb | 0 |
| `bready` | input | 1 | BREADY | high | `clk` | - |
| `araddr` | input | `AW` | ARADDR, byte address; sampled at the AR handshake | - | `clk` | - |
| `arvalid` | input | 1 | ARVALID | high | `clk` | - |
| `arready` | output | 1 | ARREADY: 1 exactly when the read path is idle | high | comb | 1 |
| `rdata` | output | `DW` | RDATA: the addressed word, 0 for an address error; valid with `rvalid` (§3.3) | - | comb | word 0 |
| `rresp` | output | 2 | RRESP: 00 OKAY, 10 SLVERR | - | comb | 00 |
| `rvalid` | output | 1 | RVALID: 1 from the clock after the AR handshake until the R handshake | high | comb | 0 |
| `rready` | input | 1 | RREADY | high | `clk` | - |
| `irq` | output | 1 | sticky address-error flag: set one clock after an AW or AR handshake with an errored address, cleared only by reset | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name (FSM coverage and an encoding check); a re-implementation must have
them with this encoding.

| Signal | Width | Meaning |
|---|---|---|
| `wstate` | 2 | write path: 0 W_IDLE (`awready`), 1 W_DATA (`wready`), 2 W_RESP (`bvalid`); 3 never occurs |
| `rstate` | 1 | read path: 0 R_IDLE (`arready`), 1 R_DATA (`rvalid`) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/AXI4_Lite.md`](../ip/AXI4_Lite.md) (source: `scripts/apb/specs/AXI4_Lite.json`); do not edit by hand.

`AXI4_Lite_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `awaddr`, `awvalid`, `awready`, `wdata`, `wstrb`, `wvalid`, `wready`, `bresp`, `bvalid`, `bready`, `araddr`, `arvalid`, `arready`, `rdata`, `rresp`, `rvalid`, `rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x414C0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x414C | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | an access outside the memory or misaligned was accepted (SLVERR); the core holds this until reset, so the bit cannot be cleared before then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x414C0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Write path

| State | Outputs | Leaves at the edge with | To |
|---|---|---|---|
| W_IDLE | `awready` = 1 | AW handshake: `awaddr` captured, error flag = address error (§3.3) | W_DATA |
| W_DATA | `wready` = 1 | W handshake: the word is written (§3.3) | W_RESP |
| W_RESP | `bvalid` = 1, `bresp` | B handshake | W_IDLE |

* A write therefore takes at least 3 clocks (AW, W, B handshakes on consecutive edges) and the
  next AW can be taken in the clock after the B handshake.
* AW must come first: `wready` stays 0 until the AW handshake, so a manager that raises `wvalid`
  before (or with) `awvalid` waits; its W is taken at the first edge in W_DATA.
* Only one write is outstanding; `awready` is 0 from the AW handshake until the B handshake.
* `bvalid` and `bresp` hold until `bready` (no timeout).

### 3.2 Read path

| State | Outputs | Leaves at the edge with | To |
|---|---|---|---|
| R_IDLE | `arready` = 1 | AR handshake: `araddr` captured, error flag | R_DATA |
| R_DATA | `rvalid` = 1, `rdata`, `rresp` | R handshake | R_IDLE |

* A read takes at least 2 clocks; the next AR can be taken in the clock after the R handshake.
* The read path is independent of the write path: AW and AR can be taken at the same edge, and a
  read proceeds while a write waits for W or B.

### 3.3 Address decode and data

* An address is in range when `addr[AW-1:10]` = 0 and `addr[1:0]` = 0 (word aligned, byte
  offsets 0x000..0x3FC). Anything else is an address error: misaligned or out of range.
* Write, at the W handshake: if the captured address is in range, byte lane k of word
  `addr[9:2]` takes `wdata[8k+7:8k]` for every k with `wstrb[k]` = 1 (`wstrb` = 0 writes nothing
  and still answers OKAY). On an address error nothing is written and the W data is discarded;
  `bresp` = SLVERR.
* Read: `rdata` = word `addr[9:2]` of the captured address, read combinationally from the array
  while `rvalid` is 1; `rdata` = 0 and `rresp` = SLVERR on an address error.
* The register file is not reset: it keeps its contents through `rst_n` and is undefined until
  written (a 2-state simulator shows 0; the checker's shadow starts at 0).

### 3.4 irq

`irq` is set at the edge after an AW or AR handshake whose address is an address error (so it is
1 from the next clock) and stays 1 until reset. It never rises for any other reason.

### 3.5 Reset

While `rst_n` is low both paths are idle: `awready` = `arready` = 1, `wready` = `bvalid` =
`rvalid` = 0, `bresp` = `rresp` = OKAY, `irq` = 0. A write whose AW was taken but whose W was not
is abandoned (nothing written). `rdata` shows word 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | 32 | data width; the decode assumes 4-byte words (`addr[1:0]`, `addr[9:2]`) |
| `AW` | 32 | 11 to 64 | address width; bits `AW-1:10` must be 0 for an in-range access |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| address >= 0x400 (any of bits `AW-1:10` set) | write: W accepted and discarded, `bresp` SLVERR; read: `rdata` 0, `rresp` SLVERR; `irq` set |
| misaligned address (`addr[1:0]` != 0) | same as out of range, even with `wstrb` = 0 |
| `wstrb` = 0 to an in-range word | OKAY, nothing written |
| partial strobes | only the strobed bytes change |
| W before AW | waits; taken in the clock after the AW handshake at the earliest |
| `bready` / `rready` held low | `bvalid` / `rvalid` and their payload hold; no new AW / AR is taken on that path |
| AW and AR at the same edge | both taken; the paths run in parallel |
| write to the word a pending read returns | `rdata` is read live from the array, so a W handshake to the same word while `rvalid` waits for `rready` changes `rdata` under a stalled R (an AXI stability violation). The TB never overlaps a read with a write to the same word; a re-implementation should register the read word at the AR handshake |
| reset with a write in flight | the write is abandoned; `irq` cleared; both paths idle |

## 6. TB check map

Messages are printed by `tb/AXI4_Lite_tb.sv` as `ERROR: <message>`; the TB's own immediate
checks (Verilator runs) print `SVA_FAIL: <name>`. Assertions `a_*` are in the bound checker
`tb/cov/AXI4_Lite_sva.sv`, which keeps a shadow of the register file and of the outstanding
write / read. The TB checks the reset state, writes and reads with and without B / R
backpressure and W gaps, the last word, partial strobes, out-of-range and misaligned accesses
(write and read), that errors leave memory unchanged, back-to-back and concurrent write + read,
reset with a write in flight, W before AW with B accepted after 0 / 2 / 3 clocks, eager reads,
and (Verilator) 140 random transactions over every address class.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "bresp" | BRESP of each write as expected (OKAY / SLVERR) | §3.3 |
| "bvalid dropped before bready" | `bvalid` holds until `bready` | §3.1 |
| "bresp changed while bready low" | `bresp` stable while `bvalid` waits | §3.1 |
| "rresp" | RRESP of each read as expected | §3.3 |
| "rdata" | RDATA equals the scoreboard word | §3.3 |
| "rvalid dropped under backpressure" | `rvalid` holds until `rready` | §3.2 |
| "rdata unstable under backpressure" | `rdata` stable while `rvalid` waits | §3.2, §5 |
| "wfirst bresp" | W presented before AW still completes with the right BRESP | §3.1 |
| "eager read" | read with `rready` already high returns the written word | §3.2 |
| "irq" | `irq` 0 after reset and normal traffic, 1 after an address error | §3.4 |
| "awready!=1 after reset" | `awready` = 1 out of reset | §3.5 |
| "arready!=1 after reset" | `arready` = 1 out of reset | §3.5 |
| "wready!=0 after reset" | `wready` = 0 out of reset | §3.5 |
| "bvalid!=0 after reset" | `bvalid` = 0 out of reset | §3.5 |
| "rvalid!=0 after reset" | `rvalid` = 0 out of reset | §3.5 |
| "reset with write in flight: channels/irq not cleared" | reset after an AW clears `wready`, `bvalid`, `rvalid`, `irq` | §3.5 |
| "not ready after mid-run reset" | `awready` / `arready` = 1 after that reset | §3.5 |
| "TIMEOUT" | the test finishes (no hung handshake) | §3.1, §3.2 |
| "A1 reset: b/rvalid low" | no `bvalid` / `rvalid` in reset | §3.5 |
| "A2 bvalid/bresp held until bready" | B payload stable under backpressure | §3.1 |
| "A3 rvalid/rdata/rresp held until rready" | R payload stable under backpressure | §3.2 |
| "A4 bresp legal" | `bresp` is OKAY or SLVERR | §3.3 |
| "A5 rresp legal" | `rresp` is OKAY or SLVERR | §3.3 |
| "A6 one write phase hot" | exactly one of `awready`, `wready`, `bvalid` is 1 | §3.1 |
| "A7 irq sticky" | `irq` never falls out of reset | §3.4 |
| "A8 wstate encoding legal" | `wstate` <= 2 | §1 |
| a_reset_quiet | in reset: `bvalid`, `rvalid`, `wready`, `irq` all 0 | §3.5 |
| a_b_stable | `bvalid` and `bresp` held while `bready` is 0 | §3.1 |
| a_r_stable | `rvalid`, `rdata`, `rresp` held while `rready` is 0 | §3.2 |
| a_aw_only_idle | `awready` only with no write outstanding | §3.1 |
| a_w_after_aw | `wready` only after an AW handshake | §3.1 |
| a_b_after_w | `bvalid` only after the W handshake | §3.1 |
| a_ar_only_idle | `arready` only with no read outstanding | §3.2 |
| a_bresp_model | `bresp` = OKAY iff the AW address is in range | §3.3 |
| a_rresp_model | `rresp` = OKAY iff the AR address is in range | §3.3 |
| a_rdata_model | `rdata` = shadow word (with byte strobes applied), 0 on an error | §3.3 |
| a_irq_sticky | `irq` stays 1 | §3.4 |
| a_irq_on_err | an errored AW / AR handshake sets `irq` by the next clock | §3.4 |
| a_irq_cause | `irq` rises only after an errored AW / AR handshake | §3.4 |
