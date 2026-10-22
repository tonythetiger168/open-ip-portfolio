# TSN egress transmission selection (802.1Qbv gates, 802.1Qav shapers, strict priority, PTP time)

Protocol IP `Ethernet_AVB_TSN`, version 2.0. Apache-2.0.

## Overview

Ethernet_AVB_TSN_top v2.0: TSN egress transmission selection for one

port with 4 traffic classes: IEEE 802.1Qbv time-aware gates, 802.1Qav
credit-based shapers, strict priority, a PTP time counter and egress
timestamps
- Line: one byte per clk. A frame of L bytes occupies the line for
L + 20 clocks (preamble + SFD 8, inter-frame gap 12). The MAC is told
which frame to send (tx_start, tx_tc, tx_len, tx_ts); the queues show
their head frame (q_valid[c], q_len[c]) and get q_pop[c] when it is
taken.
- Time: {time_ns, 16-bit fraction} advances by {cfg_inc_ns,
cfg_inc_frac} every clk; time_set loads time_set_ns (fraction 0);
time_adj adds the signed time_adj_ns. tx_ts = time_ns in the clock
the frame is selected.
- Gate control list (802.1Qbv): entries 0..gcl_last of {gates[3:0],
interval ns}, written through gcl_we / gcl_waddr (write while
gcl_en = 0). With gcl_en the schedule starts in the first clock with
time_ns >= gcl_base and then runs in elapsed time (cfg_inc_ns per
clk; time_set / time_adj do not move it): entry k lasts its interval,
the last entry lasts until the cycle ends, a cycle lasts gcl_cycle ns
(entries beyond it are cut). Gate changes and cycle starts happen in
the first clock at or after their time; the remainder is carried.
Without gcl_en, and before the schedule starts, every gate is open.
Intervals and the cycle must be at least cfg_inc_ns.
- Guard band: while the schedule runs, a frame of class c starts only
if gate c stays open for its whole line time (L + 20) * cfg_inc_ns,
counted from now to the next close of gate c or the end of the cycle,
whichever is first (a frame never crosses a cycle boundary).
- Credit-based shaper (802.1Qav), per class with cbs_en[c]: credit
(20-bit signed, saturating, units 1/256 byte) changes every clock by
cbs_idle[c] - 256 while class c transmits; by cbs_idle[c] while a
frame waits and the gate is open; it is held while a frame waits
behind a closed gate; with no frame queued, a positive credit drops
to 0 and a negative one rises by cbs_idle[c] up to 0. A class is
eligible only with credit >= 0. Without cbs_en[c] the credit is 0.
- Selection: when the line is free, the highest class with a frame
that passes its gate, guard band and shaper starts.
Not implemented: frame preemption (802.1Qbu), per-stream filtering,
gate-list switching at a config change time, hold/release, PTP message
handling (timestamps only), more than 4 classes.

q_valid / q_len / q_pop connect to the four class queues of the frame buffer (head frame length, pop when taken); tx_start, tx_tc, tx_len, tx_ts and tx_busy connect to the MAC. One byte per PCLK: a frame of L bytes occupies the line for L + 20 clocks.
The wrapper takes tx_start and tx_busy into IRQ_STATUS and STATUS; the MAC uses |q_pop as the frame start strobe (q_pop is one-hot in exactly that clock). tx_ts is the time in the clock the frame was selected (the egress timestamp before the MAC's fixed latency).

## Files

| File | Content |
|---|---|
| `rtl/Ethernet_AVB_TSN_top.sv` | protocol core |
| `rtl/Ethernet_AVB_TSN_apb.sv` | APB4 register wrapper (generated) |
| `tb/Ethernet_AVB_TSN_tb.sv` | core testbench |
| `tb/Ethernet_AVB_TSN_apb_tb.sv`, `tb/apb/Ethernet_AVB_TSN_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Ethernet_AVB_TSN_sva.sv`, `tb/cov/Ethernet_AVB_TSN_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Ethernet_AVB_TSN.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.Ethernet_AVB_TSN sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.Ethernet_AVB_TSN apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh Ethernet_AVB_TSN          # core coverage (Verilator)
bash scripts/cov/run_cov.sh Ethernet_AVB_TSN_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_inc_ns` | input | 8 | CFG0[7:0] |
| `cfg_inc_frac` | input | 16 | CFG0[23:8] |
| `time_set` | input | 1 | TIME_SET commit / FLAGS |
| `time_set_ns` | input | 64 | TIME_SET0[31:0], TIME_SET1[31:0] |
| `time_adj` | input | 1 | TIME_ADJ commit / FLAGS |
| `time_adj_ns` | input | 32 | TIME_ADJ[31:0] |
| `time_ns` | output | 64 | TIME0[31:0], TIME1[31:0] |
| `gcl_en` | input | 1 | CFG0[24:24] |
| `gcl_base` | input | 64 | GCL_BASE0[31:0], GCL_BASE1[31:0] |
| `gcl_cycle` | input | 24 | CFG1[23:0] |
| `gcl_last` | input | 3 | CFG0[27:25] |
| `gcl_we` | input | 1 | GCL_WR commit / FLAGS |
| `gcl_waddr` | input | 3 | GCL_WR[30:28] |
| `gcl_wgates` | input | 4 | GCL_WR[27:24] |
| `gcl_wivl` | input | 24 | GCL_WR[23:0] |
| `cbs_en` | input | 4 | CFG0[31:28] |
| `cbs_idle` | input | 36 | CBS_IDLE0[31:0], CBS_IDLE1[3:0] |
| `q_valid` | input | 4 | pin (pass-through) |
| `q_len` | input | 44 | pin (pass-through) |
| `q_pop` | output | 4 | pin (pass-through) |
| `tx_start` | output | 1 | IRQ_STATUS.TX |
| `tx_tc` | output | 2 | pin (pass-through) |
| `tx_len` | output | 11 | pin (pass-through) |
| `tx_ts` | output | 64 | pin (pass-through) |
| `tx_busy` | output | 1 | STATUS[8:8] |
| `gcl_running` | output | 1 | STATUS[0:0] |
| `gcl_entry` | output | 3 | STATUS[3:1] |
| `gate_state` | output | 4 | STATUS[7:4] |
| `cycle_start` | output | 1 | IRQ_STATUS.CYCLE |
| `cbs_credit` | output | 80 | CREDIT0[31:0], CREDIT1[31:0], CREDIT2[15:0] |

## APB wrapper

`Ethernet_AVB_TSN_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `q_valid`, `q_len`, `q_pop`, `tx_tc`, `tx_len`, `tx_ts`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x54530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG0 | RW | 0x00000008 | Time increment, schedule and shaper enables |
| 0x018 | CFG1 | RW | 0x000F4240 | Time increment, schedule and shaper enables |
| 0x01C | GCL_BASE0 | RW | 0x00000000 | Schedule start time, ns: the list starts in the first clock with time >= GCL_BASE |
| 0x020 | GCL_BASE1 | RW | 0x00000000 | Schedule start time, ns: the list starts in the first clock with time >= GCL_BASE |
| 0x024 | CBS_IDLE0 | RW | 0x00000000 | Shaper idle slopes, class c in bits 9c+8:9c, in 1/256 of the line rate (0..256) |
| 0x028 | CBS_IDLE1 | RW | 0x00000000 | Shaper idle slopes, class c in bits 9c+8:9c, in 1/256 of the line rate (0..256) |
| 0x02C | GCL_WR | RW | 0x00000000 | Writes one gate control list entry; writing GCL_WR commits it. Write entries while CFG.gcl_en = 0 |
| 0x030 | TIME_SET0 | RW | 0x00000000 | Loads the time (fraction 0); writing TIME_SET1 commits it |
| 0x034 | TIME_SET1 | RW | 0x00000000 | Loads the time (fraction 0); writing TIME_SET1 commits it |
| 0x038 | TIME_ADJ | RW | 0x00000000 | Adds a signed offset to the time once; writing TIME_ADJ commits it |
| 0x03C | TIME0 | RO | 0x00000000 | Current time, ns. TIME0 and TIME1 are read separately: read TIME1, TIME0, TIME1 again and retry if TIME1 changed |
| 0x040 | TIME1 | RO | 0x00000000 | Current time, ns. TIME0 and TIME1 are read separately: read TIME1, TIME0, TIME1 again and retry if TIME1 changed |
| 0x044 | STATUS | RO | 0x00000000 | Schedule and line state |
| 0x048 | CREDIT0 | RO | 0x00000000 | Shaper credits, class c in bits 20c+19:20c, signed, 1/256 byte |
| 0x04C | CREDIT1 | RO | 0x00000000 | Shaper credits, class c in bits 20c+19:20c, signed, 1/256 byte |
| 0x050 | CREDIT2 | RO | 0x00000000 | Shaper credits, class c in bits 20c+19:20c, signed, 1/256 byte |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5453 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CFG0 | 7:0 | `cfg_inc_ns` | time increment per clock, whole ns (8: 125 MHz) |
| CFG0 | 23:8 | `cfg_inc_frac` | time increment per clock, 1/65536 ns |
| CFG0 | 24 | `gcl_en` | 1 = run the gate control list from GCL_BASE; 0 = all gates open |
| CFG0 | 27:25 | `gcl_last` | last gate control list entry (0..7) |
| CFG0 | 31:28 | `cbs_en` | credit-based shaper enable per class |
| CFG1 | 23:0 | `gcl_cycle` | cycle time, ns |
| GCL_BASE0 | 31:0 | `gcl_base[31:0]` | base time, ns |
| GCL_BASE1 | 31:0 | `gcl_base[63:32]` | base time, ns |
| CBS_IDLE0 | 31:0 | `cbs_idle[31:0]` | idle slopes of classes 0..3 |
| CBS_IDLE1 | 3:0 | `cbs_idle[35:32]` | idle slopes of classes 0..3 |
| GCL_WR | 23:0 | `gcl_wivl` | interval, ns (at least CFG.cfg_inc_ns) |
| GCL_WR | 27:24 | `gcl_wgates` | gate states, bit c = class c open |
| GCL_WR | 30:28 | `gcl_waddr` | entry |
| TIME_SET0 | 31:0 | `time_set_ns[31:0]` | new time, ns |
| TIME_SET1 | 31:0 | `time_set_ns[63:32]` | new time, ns |
| TIME_ADJ | 31:0 | `time_adj_ns` | signed offset, ns |
| TIME0 | 31:0 | `time_ns[31:0]` | time, ns |
| TIME1 | 31:0 | `time_ns[63:32]` | time, ns |
| STATUS | 0 | `gcl_running` | 1 = the gate control list runs |
| STATUS | 3:1 | `gcl_entry` | current entry |
| STATUS | 7:4 | `gate_state` | gate state per class (all open while the list does not run) |
| STATUS | 8 | `tx_busy` | a frame occupies the line |
| CREDIT0 | 31:0 | `cbs_credit[31:0]` | credits of classes 0..3 |
| CREDIT1 | 31:0 | `cbs_credit[63:32]` | credits of classes 0..3 |
| CREDIT2 | 15:0 | `cbs_credit[79:64]` | credits of classes 0..3 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CYCLE | a gate control list cycle started |
| 1 | TX | a frame was selected for transmission |

### Streams

* **GCL_WR** feeds `gcl_wivl`, `gcl_wgates`, `gcl_waddr`; writing GCL_WR pulses `gcl_we` for one clock.
* **TIME_SET** feeds `time_set_ns`; writing TIME_SET1 pulses `time_set` for one clock.
* **TIME_ADJ** feeds `time_adj_ns`; writing TIME_ADJ pulses `time_adj` for one clock.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Ethernet_AVB_TSN_top.sv` | pass | 61/61 | 2336/2336 | n/a | 11/11 | 31/31 |
| wrapper `rtl/Ethernet_AVB_TSN_apb.sv` | pass | 55/55 | 2140/2140 | n/a | 26/26 | 62/62 |
