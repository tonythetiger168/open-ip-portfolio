# W5 family coverage report — storage 9 + display/AV 5 + ethernet 6

Branch: `crv-w5-storage-disp-eth`. Methodology and Verilator 5.006
compatibility rules: see `docs/COVERAGE.md`. Waivers live in
`scripts/verilator_cov/waiver_w5.vc` (cross-referenced by ID below).

Legend: LINE / TOGGLE from `coverage.dat` (DUT only), FSM from the TB
probe (`FSM_COV`), SVA from the counted immediate-assertion suite
(`SVA_CHECKS`). "closed" = 100% after listed waivers.

| Protocol | iverilog sim | Verilator run | LINE | TOGGLE | FSM | SVA_CHECKS | status |
|---|---|---|---|---|---|---|---|
| GMII | PASS | PASS | 46/47 | 263/264 | 2/2 | all pass | **closed (2 waivers: gmii-line-1, gmii-toggle-1)** |
| RGMII | PASS | PASS | 64/64 (100%) | 276/276 (100%) | 2/2 | all pass | **closed (no waivers)** |
| XGMII | PASS | PASS | 47/62 | 309/317 | 2/2 | all pass | **closed (6 waivers: xgmii-line-1..3, xgmii-toggle-1..3)** |

## CRV stimulus summary

- **GMII**: 120 loopback bursts, random length 1..8 (txq-depth boundary
  forced ~10%), random data with 00/FF corners, random read-back order.
  Error classes: wrong-address writes (must be ignored, verified by exact
  byte-count check) and `rx_er` assertion during reception (DUT has no
  rx_er handling; data must be unaffected). Byte-stream model scoreboard.
- **RGMII**: same burst scheme plus "poison byte" injection: `rx_ctl`
  masked for a whole standalone byte transmission (race-free fixed window
  armed while the link is idle); byte must be dropped and the stream must
  realign. 120 bursts, 22 full-depth, 33 wrong-addr, 19 byte-drop.
- **XGMII**: 120 loopback bursts of 4/8 bytes (TX emits whole 32-bit
  words; 8-byte bursts hit the txq-depth boundary), wrong-address writes,
  and "poison word" injection (`rxc` forced to all-control for one beat;
  word must be dropped). 516 bytes compared. Partial-lane `rxc` casez
  arms are dead code inside the `rxc==4'h0` guard (waiver xgmii-line-3).

## Suspected RTL issues (reported, NOT fixed — per SPEC)

- XGMII: partial-lane control-column arms (`rxc ∉ {0,F}`) are unreachable
  dead code (guarded by `rxc == 4'h0`); lane stores use constant offsets
  that would hole-clobber `rxq` if reachable. Harmless for loopback MAC
  operation. Logged for the orchestrator; no RTL change made.
- XGMII: `lane[1:0]` is dead state (reset-only, never read).
