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
| MDIO | PASS | PASS | 48/48 (100%) | 72/73 | 2/2 | all pass | **closed (1 waiver: mdio-toggle-1)** |
| NVMe | PASS | PASS | 123/138 | 440/495 | 5/5 | all pass | **closed (4 line + 4 toggle waivers)** |
| FC | PASS | PASS | 123/138 | 440/495 | 5/5 | all pass | **closed (4 line + 4 toggle waivers)** |
| Ethernet | PASS | PASS | 123/138 | 440/495 | 5/5 | all pass | **closed (4 line + 4 toggle waivers)** |

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

- **MDIO**: 120 Clause-22 frames vs a shadow register model: ~45% random
  writes (0000/FFFF corners), ~25% read-backs, ~15% write+read same reg
  (reg 0/31 boundary bias), ~10% wrong-PHY writes (must be ignored;
  verified by read-back), ~5% wrong-PHY reads (open bus -> 16'hFFFF).
- **NVMe / FC / Ethernet** (identical generated echo-frame RTL): 120
  frames each, random payload 0..8 bytes (0/8 boundary biased), random
  header/payload, full header+payload echo compare. Error injection:
  bad CRC (rx_err latches, no echo), bad END (rx_err, no echo), bad STP
  (rx_err, frame still completes and echoes). Sticky `rx_err` checked
  against the TB injection history after every frame. The Verilator-only
  echo model includes the W5-RTL-1 artifact (below).

## Suspected RTL issues (reported, NOT fixed — per SPEC)

- **W5-RTL-1 (NVMe / FC / Ethernet)**: `rtl/NVMe_top.sv:196` (same line
  in `rtl/FC_top.sv` and `rtl/Ethernet_top.sv` — identical generated
  RTL): `for (int i = 2; i < HB + MAXB + 6; i++) tx_mem[i-2] <= buf_mem[i];`
  writes `tx_mem[0..19]` but `tx_mem` has only 16 entries — the last four
  iterations are out-of-bounds writes of `buf_mem[18..21]`. iverilog
  drops OOB writes (correct echo). Verilator masks dynamic OOB indices,
  so `tx_mem[0..3]` are clobbered by `buf_mem[18..21]` on every
  `rx_done` and the echoed `hdr[0..3]` is wrong. Minimal repro:
  `/tmp/repro/r.sv` (copy loop into a 16-entry array; Verilator writes
  element `[i-2 & 15]`, iverilog drops). Root cause: loop bound should be
  `HB + MAXB + 2`. The v2.5.1 fix should repair all three protocols
  together. The CRV phases predict the deterministic Verilator behavior
  with an exact `sh_buf` shadow of `buf_mem` (agreed with orchestrator).
- **XGMII**: partial-lane control-column arms (`rxc ∉ {0,F}`) are
  unreachable dead code (guarded by `rxc == 4'h0`); lane stores use
  constant offsets that would hole-clobber `rxq` if reachable. Harmless
  for loopback MAC operation. Logged; no RTL change made.
- **XGMII**: `lane[1:0]` is dead state (reset-only, never read).

  operation. Logged for the orchestrator; no RTL change made.
