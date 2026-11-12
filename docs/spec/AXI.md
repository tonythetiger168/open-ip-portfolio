<!-- SPDX-License-Identifier: Apache-2.0 -->
# AXI: design specification

AXI3 subordinate with a 256 x 32-bit register file: five channels with VALID / READY handshakes,
INCR and FIXED bursts of 1 to 16 beats (4-bit AxLEN), a write data channel that carries WID (no
write interleaving: WID must match the AWID of the burst in progress), byte strobes, one burst in
flight per direction (independent paths), any 4-bit ID, SLVERR for address errors, WRAP, bad WLAST
and a WID mismatch, and DECERR for an unsupported size or burst type. It shares its structure with
[AXI4](AXI4.md); this page is complete on its own. Core `AXI_top` (`rtl/AXI_top.sv`), testbench
`tb/AXI_tb.sv` (an AXI3 manager model with a scoreboard), checker `tb/cov/AXI_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A handshake happens at a rising edge where VALID and READY are both
1. All outputs except `irq` are combinational from the state registers.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | ACLK | rising edge | - | - |
| `rst_n` | input | 1 | ARESETn: asynchronous reset of both paths and `irq` (not the memory) | low | async | - |
| `awid` | input | 4 | AWID, any value; echoed on `bid`; W beats must carry the same `wid` | - | `clk` | - |
| `awaddr` | input | `AW` | AWADDR, start byte address | - | `clk` | - |
| `awlen` | input | 4 | AWLEN (AXI3, 4 bits): beats - 1, 1 to 16 beats | - | `clk` | - |
| `awsize` | input | 3 | AWSIZE: 0 to 2 supported (more answers DECERR); the address always steps 4 per INCR beat | - | `clk` | - |
| `awburst` | input | 2 | AWBURST: 00 FIXED, 01 INCR supported; 10 WRAP answers SLVERR; 11 DECERR | - | `clk` | - |
| `awvalid` | input | 1 | AWVALID | high | `clk` | - |
| `awready` | output | 1 | AWREADY: 1 exactly when the write path is idle | high | comb | 1 |
| `wid` | input | 4 | WID: must equal the AWID of the burst (§3.1) | - | `clk` | - |
| `wdata` | input | `DW` | WDATA | - | `clk` | - |
| `wstrb` | input | `DW/8` | WSTRB: byte lane k written when bit k is 1 | high | `clk` | - |
| `wlast` | input | 1 | WLAST: must mark beat `awlen` (§3.1) | high | `clk` | - |
| `wvalid` | input | 1 | WVALID | high | `clk` | - |
| `wready` | output | 1 | WREADY: 1 from the AW handshake until the burst ends | high | comb | 0 |
| `bid` | output | 4 | BID = `awid` of the burst | - | comb | 0 |
| `bresp` | output | 2 | BRESP: 00 OKAY, 10 SLVERR, 11 DECERR (§3.3) | - | comb | 00 |
| `bvalid` | output | 1 | BVALID: from the clock after the last W beat until the B handshake | high | comb | 0 |
| `bready` | input | 1 | BREADY | high | `clk` | - |
| `arid` | input | 4 | ARID, any value; echoed on `rid` | - | `clk` | - |
| `araddr` | input | `AW` | ARADDR, start byte address | - | `clk` | - |
| `arlen` | input | 4 | ARLEN: beats - 1 | - | `clk` | - |
| `arsize` | input | 3 | ARSIZE: 0 to 2 supported | - | `clk` | - |
| `arburst` | input | 2 | ARBURST: as AWBURST | - | `clk` | - |
| `arvalid` | input | 1 | ARVALID | high | `clk` | - |
| `arready` | output | 1 | ARREADY: 1 exactly when the read path is idle | high | comb | 1 |
| `rid` | output | 4 | RID = `arid` | - | comb | 0 |
| `rdata` | output | `DW` | RDATA: word at the current beat address (combinational from the memory); 0 when that address is out of range | - | comb | word 0 |
| `rresp` | output | 2 | RRESP of the current beat (§3.3) | - | comb | 00 |
| `rlast` | output | 1 | RLAST: on beat `arlen` | high | comb | 0 |
| `rvalid` | output | 1 | RVALID: from the clock after the AR handshake until the R handshake of the last beat | high | comb | 0 |
| `rready` | input | 1 | RREADY | high | `clk` | - |
| `irq` | output | 1 | sticky protocol-error flag (§3.4), cleared only by reset | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name (FSM coverage and an encoding check); a re-implementation must have
them with this encoding.

| Signal | Width | Meaning |
|---|---|---|
| `wstate` | 2 | write path: 0 W_IDLE (`awready`), 1 W_DATA (`wready`), 2 W_RESP (`bvalid`); 3 never occurs |
| `rstate` | 1 | read path: 0 R_IDLE (`arready`), 1 R_DATA (`rvalid`) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/AXI.md`](../ip/AXI.md) (source: `scripts/apb/specs/AXI.json`); do not edit by hand.

`AXI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `awid`, `awaddr`, `awlen`, `awsize`, `awburst`, `awvalid`, `awready`, `wid`, `wdata`, `wstrb`, `wlast`, `wvalid`, `wready`, `bid`, `bresp`, `bvalid`, `bready`, `arid`, `araddr`, `arlen`, `arsize`, `arburst`, `arvalid`, `arready`, `rid`, `rdata`, `rresp`, `rlast`, `rvalid`, `rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41330200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4133 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a transfer got SLVERR or DECERR, or a write burst's WLAST came early or not at all, or a WID did not match the AWID; the core holds this until reset, so the bit cannot be cleared before then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41330200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Write path

| State | Outputs | Leaves at the edge with | To |
|---|---|---|---|
| W_IDLE | `awready` = 1 | AW handshake: address, length, burst, id captured; response code = header check (§3.3) | W_DATA |
| W_DATA | `wready` = 1 | W handshake of the last beat | W_RESP |
| W_RESP | `bvalid` = 1, `bresp`, `bid` | B handshake | W_IDLE |

* Each W handshake handles one beat (§3.3). A beat whose `wid` differs from the captured AWID is
  dropped and turns the response into SLVERR (write interleaving is not supported). Then, unless it was the last, the beat count advances
  and for INCR the address adds 4 (FIXED keeps it).
* The burst ends at the first beat with `wlast` = 1 or with beat count = `awlen`, whichever comes
  first. If the two do not agree on that beat (early or missing WLAST) and the response is still
  OKAY with the beat in range, the response becomes SLVERR; the beat itself is still written.
* W is only taken after AW; one write is outstanding; `bvalid` / `bresp` / `bid` hold until
  `bready`. A write takes at least 3 clocks for a single beat.

### 3.2 Read path

| State | Outputs | Leaves at the edge with | To |
|---|---|---|---|
| R_IDLE | `arready` = 1 | AR handshake: captured as for AW; response code = header check | R_DATA |
| R_DATA | `rvalid`, `rdata`, `rresp`, `rid`, `rlast` | R handshake of beat `arlen` | R_IDLE |

* Each R handshake moves to the next beat (INCR + 4, FIXED same address). The beat payload holds
  while `rready` is 0. AW and AR can be taken at the same edge.

### 3.3 Response codes and data

Header check at the AW / AR handshake, first match wins:

| Code | Condition |
|---|---|
| DECERR (11) | size > 2, or burst = 11 (reserved); every ID and length is legal |
| SLVERR (10) | start address not in range (`addr[AW-1:10]` != 0 or `addr[1:0]` != 0), or burst = WRAP |
| OKAY (00) | otherwise |

* Write beat: written (bytes with `wstrb[k]` = 1 of word `addr[9:2]`) only while the response is
  still OKAY, `wid` matches and the beat address is in range. A beat out of range (an INCR burst running past
  0x3FC) is dropped and turns the response into SLVERR; later beats are dropped too. `bresp` is the
  final code.
* Read beat: `rresp` = the header code; if that is OKAY but the beat address is out of range,
  SLVERR for that beat. `rdata` = word `addr[9:2]` read combinationally from the memory when the
  beat address is in range, else 0. So DECERR and WRAP reads to in-range addresses still show the
  memory word on `rdata` (with the error code).
* The memory is not reset: it keeps its contents through `rst_n` and is undefined until written
  (a 2-state simulator shows 0; the checker's shadow starts at 0).

### 3.4 irq

`irq` is set at the edge after any of these and stays 1 until reset:

* an AW or AR handshake whose header check is not OKAY;
* a W handshake whose `wid` mismatches, whose beat address is out of range, or whose `wlast`
  disagrees with the beat count;
* an R handshake of a beat with `rresp` != OKAY.

### 3.5 Reset

While `rst_n` is low: both paths idle (`awready` = `arready` = 1, `wready` = `bvalid` = `rvalid` =
`rlast` = 0), `bresp` = `rresp` = OKAY, `bid` = `rid` = 0, `irq` = 0. Bursts in flight are
abandoned; beats already written stay.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | 32 | data width; the memory has 4-byte words and INCR steps 4 per beat |
| `AW` | 32 | 11 to 32 | address width; bits `AW-1:10` must be 0 (the INCR step is a 32-bit add) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| size > 2 or burst 11 | DECERR for the whole burst; nothing written; `irq` |
| W beat with `wid` != AWID | dropped, response SLVERR (later beats dropped too), `irq`; earlier beats stay written |
| start address out of range or misaligned | SLVERR; nothing written; read beats 0; `irq` |
| WRAP burst | SLVERR; nothing written; reads still show the memory words; `irq` |
| INCR burst running past 0x3FC | in-range beats written / read OKAY, later beats dropped / 0 with SLVERR; write `bresp` SLVERR; `irq` |
| early WLAST | burst ends there, SLVERR (beat written), `irq` |
| missing WLAST on beat `awlen` | burst ends by count, SLVERR, `irq` |
| FIXED burst | every beat at the start address |
| write to a word a stalled R beat returns | `rdata` is read live, so it changes under the stall (AXI stability violation); the TB never overlaps them |
| reset mid burst | abandoned; written beats remain; `irq` cleared |

## 6. TB check map

Messages are printed by `tb/AXI_tb.sv` as `ERROR: <message>`; its immediate checks print
`SVA_FAIL: <name>`. Assertions `a_*` are in the bound checker `tb/cov/AXI_sva.sv`, which keeps an
independent burst model (with WID) and shadow memory. The TB checks reset, bursts of 1 / 2 / 4 /
16 beats (INCR and FIXED) with W gaps, B / R back-pressure and `rready` withdrawn mid burst,
out-of-range starts and bursts running out of range, a WID mismatch mid burst, DECERR on a bad size,
early / missing WLAST, back-to-back
and concurrent bursts, reset mid burst, and (Verilator) random bursts.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "bresp" | BRESP of each burst as expected | §3.3 |
| "bid" | BID echoes AWID | §3.1 |
| "bvalid dropped before bready" | `bvalid` held | §3.1 |
| "bresp changed while bready low" | `bresp` stable | §3.1 |
| "rresp beat" | per-beat RRESP as expected | §3.3 |
| "rlast beat" | RLAST on beat `arlen` only | §3.2 |
| "rid" | RID echoes ARID | §3.2 |
| "rdata" | RDATA = scoreboard word | §3.3 |
| "rvalid dropped under backpressure beat" | `rvalid` held | §3.2 |
| "rdata unstable under backpressure beat" | `rdata` stable | §3.2, §5 |
| "irq" | `irq` value after each scenario | §3.4 |
| "awready!=1 after reset" | `awready` 1 out of reset | §3.5 |
| "arready!=1 after reset" | `arready` 1 out of reset | §3.5 |
| "wready!=0 after reset" | `wready` 0 out of reset | §3.5 |
| "bvalid!=0 after reset" | `bvalid` 0 out of reset | §3.5 |
| "rvalid!=0 after reset" | `rvalid` 0 out of reset | §3.5 |
| "wid-mismatch survivor" | after a WID mismatch on beat 1, beat 0 is in memory and beat 1 is not | §3.1 |
| "rresp" | RRESP of a single read (DECERR for a bad size) | §3.3 |
| "reset with burst in flight: channels/irq not cleared" | reset mid burst clears the channels and `irq` | §3.5 |
| "not ready after mid-run reset" | `awready` / `arready` 1 after it | §3.5 |
| "TIMEOUT" | the test finishes | §3.1, §3.2 |
| "A1 reset: b/rvalid low" | no `bvalid` / `rvalid` in reset | §3.5 |
| "A2 bvalid/bresp/bid held until bready" | B payload stable | §3.1 |
| "A3 rvalid/rdata/rresp held until rready" | R payload stable | §3.2 |
| "A4 bresp legal" | `bresp` is not EXOKAY (01) | §3.3 |
| "A5 rresp legal" | `rresp` is not EXOKAY | §3.3 |
| "A6 rlast implies rvalid" | `rlast` only with `rvalid` | §3.2 |
| "A7 irq sticky" | `irq` never falls | §3.4 |
| "A8 wstate encoding legal" | `wstate` <= 2 | §1 |
| "A9 one write phase hot" | exactly one of `awready`, `wready`, `bvalid` | §3.1 |
| a_reset_quiet | in reset: `bvalid`, `rvalid`, `wready`, `irq` 0 | §3.5 |
| a_b_stable | B payload held while `bready` 0 | §3.1 |
| a_r_stable | R payload held while `rready` 0 | §3.2 |
| a_aw_only_idle | `awready` only with no write in flight | §3.1 |
| a_ar_only_idle | `arready` only with no read in flight | §3.2 |
| a_wready_in_burst | `wready` only inside a write burst | §3.1 |
| a_bvalid_after_burst | `bvalid` rises after the last W beat | §3.1 |
| a_bresp_model | `bresp` / `bid` as the model (WID mismatch included) | §3.3 |
| a_rresp_model | `rresp` / `rid` as the model | §3.3 |
| a_rlast_model | `rlast` on beat `arlen` | §3.2 |
| a_rdata_model | OKAY beat `rdata` = shadow word | §3.3 |
| a_rdata_zero_oor | out-of-range beat `rdata` = 0 | §3.3 |
| a_irq_sticky | `irq` stays 1 | §3.4 |
| a_irq_on_aw_err | errored AW header sets `irq` | §3.4 |
| a_irq_on_r_err | non-OKAY R beat sets `irq` | §3.4 |
| a_irq_cause | `irq` rises only after a handshake | §3.4 |
