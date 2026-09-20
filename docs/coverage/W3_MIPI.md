# W3 MIPI Family — v2.5 CRV Coverage Report

Branch: `crv-w3-mipi` (worktree `$HOME/work-w3`). All CRV additions are
`` `ifdef VERILATOR ``-guarded; the iverilog directed path is untouched and
stays green. Waivers live in `scripts/verilator_cov/waiver_w3.vc`.
TB backups before edits: `/mnt/agents/output/.wave_backup/W3/`.

## Scoreboard (as of this commit)

| Protocol | iverilog | Verilator | LINE | TOGGLE | FSM | SVA | status |
|---|---|---|---|---|---|---|---|
| RFFE        | PASS | PASS | 62/62 (100%) | 64/68 (2 waivers) | 4/4 | all pass | **closed** |
| MIPI_RFFE   | PASS | PASS | 153/155 (2 waivers) | 227/227 (100%) | 7/7 | all pass | **closed** |
| SPMI        | PASS | PASS | 68/70 (2 waivers) | 74/75 (1 waiver) | 6/6 | all pass | **closed** |
| MIPI_SPMI   | PASS | PASS | 171/174 (3 waivers) | 226/226 (100%) | 8/8 | all pass | **closed** |
| I3C         | PASS | PASS | 77/78 (1 waiver) | 57/58 (1 waiver) | 7/7 | all pass | **closed** |
| MIPI_I3C    | PASS | PASS | 283/284 (1 waiver) | 261/274 (6 waivers) | 15/15 | all pass | **closed** |
| DigRF       | PASS | PASS | 62/62 (100%) | 64/68 (2 waivers) | 4/4 | all pass | **closed** |
| MIPI_SLIMbus| PASS | PASS | 62/62 (100%) | 64/68 (2 waivers) | 4/4 | all pass | **closed** |
| MIPI_SoundWire | PASS | PASS | 62/62 (100%) | 64/68 (2 waivers) | 4/4 | all pass | **closed** |
| MIPI_DBI    | PASS | PASS | 62/62 (100%) | 64/68 (2 waivers) | 4/4 | all pass | **closed** |
| MIPI_DPI    | PASS | PASS | 84/88 (4 open) | 198/555 (open) | 5/5 | all pass | **partial — open items below** |
| C_PHY, CSI_2, D_PHY, DSI, M_PHY, UniPro, UniPro_Mem | PASS (baseline, untouched) | — | — | — | — | — | **not started (step budget)** |

CRV stimulus: every upgraded TB runs >=100 randomized transactions
($urandom_range + rejection sampling) mixing normal / boundary (0x00/0xFF,
all-min timing) / error-injection classes, with scoreboard self-checks,
>=5 clock-sampled output invariants (`sva_check`), FSM probes, and chunked
timeout guards (`repeat (N) #1000;` — never a single long pending #delay).
Random phases are fully inlined via macros (single coroutine) per the
I2C-pilot scheduler workaround; error classes use round-robin selectors so
every class is guaranteed to run.

## MIPI_DPI open items (next pass)

- LINE 84/88: rtl/MIPI_DPI__Display_Pixel_Interface__top.sv:94 (attribution
  artifact candidate — ctrl-write branch, execution proven by every enable)
  and :144-146 (reg_rdata mux for addr 9/10/11 = frame_cnt/hcnt/vcnt;
  coverable by adding readback of those addresses — trivial, not yet added).
- TOGGLE 198/555: misses are the high bits of the 16-bit timing registers
  (values used 0..4), hcnt/vcnt high bits (frames kept small for runtime)
  and frame_cnt[15:8]. Closure plan: register write sweep (0xFFFF/0x5A5A/
  0xA5A5/0x0000 per reg), one wide frame (large hact), one tall frame
  (large vact), ~512 tiny back-to-back frames for frame_cnt; remainder
  (e.g. frame_cnt[15:9]) documented as sim-practicality waivers.

## RTL bugs found (RECORDED ONLY — not fixed, per v2.5 rules)

### BUG-W3-1: RFFE_top — read never drives tx_byte[0] (LSB always reads 1)
- File: rtl/RFFE_top.sv:79-85 (`ST_DATA` read arm).
- Root cause: the slave drives the next read bit on `sclk_fall` while
  `bit_cnt < 7`; at `bit_cnt == 4'd7` it parks the bus (`sd_oe <= 0`,
  `state <= ST_PARK`) instead of driving `tx_byte[0]`. Only tx_byte[7:1]
  are ever driven; the 8th bit floats to the tri1 pull-up.
- Failing signature: directed read with tx_byte=8'hC2 returns 8'hC3
  (got=c3 exp=C2). Masked by the shipped vector 8'hC3 (LSB=1).
- Minimal repro: `sed "s/8'hC3/8'hC2/" tb/RFFE_tb.sv` (+exp text),
  `iverilog -g2012 rtl/RFFE_top.sv <mod>_tb.sv && ./a.out` -> TEST FAILED.
- Same bug family present in the clones DigRF_top, MIPI_SLIMbus_top,
  MIPI_SoundWire_top, MIPI_DBI__Display_Bus_Interface__top (identical RTL).
- CRV handles it by comparing read data[7:1] and asserting read LSB==1.

### BUG-W3-2: SPMI_top — sd_oe not cleared on ACKP->IDLE (bus wedge)
- File: rtl/SPMI_top.sv:92-98 (`ST_ACKP` read arm) + missing `sd_oe`
  assignment on the transition to ST_IDLE.
- Root cause: after the 8th read bit, `sd_oe <= (tx_byte[0]==0)` and
  `state <= ST_IDLE`; ST_IDLE (via `default: ;`) never clears `sd_oe`, so
  after any read whose tx_byte[0]=0 the slave keeps SDATA pulled low
  forever. SSC detection (`sdata` falling while `sclk` high) can never
  fire again -> all subsequent frames are ignored (permanent wedge).
- Failing signature (iverilog probe, `$HOME/bugcheck/spmi_probe_tb.sv`):
  read tx_byte=8'hC2 -> `after read: sdata=0 dut.sd_oe=1 state=0`;
  following write never receives rx_valid (timeout).
- CRV handles it by rejection-sampling read values to LSB=1 (documented
  in the TB) — the wedge itself is locked by the probe above.

### BUG-W3-3: I3C_top — first read byte drives tx_byte[6] first (MSB lost)
- File: rtl/I3C_top.sv:86-92 (`ST_TX`): on entry from ST_ACK the first
  `scl_fall` drives `ack_low <= (tx_byte[6-bit_cnt]==0)` with bit_cnt=0,
  i.e. tx_byte[6]; tx_byte[7] is never driven for the first byte. The
  master's first read sample sees the released bus (pull-up 1).
- Failing signature: directed read with tx_byte=8'h73 returns 8'hF3
  (got=f3 exp=73). Masked by the shipped vector 8'hC3 (MSB=1).
  Same bug class as the already-fixed I2C first-byte MSB issue.
- Minimal repro: `sed "s/8'hC3/8'h73/" tb/I3C_tb.sv` (+exp text) under
  iverilog -> TEST FAILED.
- Note: the ST_TXACK->ST_TX re-entry path (line 104) drives tx_byte[7]
  correctly, so byte 2+ of multi-byte reads are correct; CRV compares
  byte1 with the documented mask and byte2 in full.

## Verilator 5.006 `__` name-mangling workaround (run_cov.sh)

Protocols with double underscores in the module name (W3: MIPI_DBI__,
MIPI_DPI__; also W4-W6 DFI_5_0__, SAS_4__, TileLink__, CPRI_v8_0__,
Crypto___, OCP_IP_ etc.) fail in run_cov.sh: Verilator mangles the model
class/header to `V<name with __->_05F>` while the fixed sim_main.cpp
template includes `V<literal>.h`. Fix (no infra change): after the first
(failed) run_cov.sh attempt, drop a shim header into `$BUILD/obj/` and
re-run — Verilator does not delete unknown files. Shim for DBI:

```c
// obj/VMIPI_DBI__Display_Bus_Interface__tb.h
#ifndef VMIPI_DBI_SHIM_H
#define VMIPI_DBI_SHIM_H
#include "VMIPI_DBI___05FDisplay_Bus_Interface___05Ftb.h"
#define VMIPI_DBI__Display_Bus_Interface__tb VMIPI_DBI___05FDisplay_Bus_Interface___05Ftb
#endif
```

(Pattern: `#include` the mangled header, `#define` the literal class name
to the mangled one.) Documented for other waves; a proper fix would teach
run_cov.sh to mangle @TOP@ the same way.

## Other notes

- TB self-check sequencing fix (not RTL): MIPI_I3C IBI transactions have
  no START, so a sticky irq from a preceding error-class txn must be
  cleared with a dummy START/STOP first.
- SVA timing: assertions that refer to registered side effects of a
  control write must sample the control one cycle delayed (DPI A2/A3).
- The first posedge after time 0 must be excluded from assertion sampling
  (DUT reset values land in that NBA region) — see `first_cycle` guards.
- echo-copy OOB template pattern (tx_mem[i-2] loop) grepped across all 18
  W3 RTLs: NOT present.
