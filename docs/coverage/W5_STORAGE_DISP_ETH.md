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
| I2S | PASS | PASS | 50/50 (100%) | 156/157 | 2/2 | all pass | **closed (1 waiver: i2s-toggle-1)** |
| Ethernet_AVB_TSN | PASS | PASS | 173/175 | 309/327 | 16/16 | all pass | **closed (2 line + 4 toggle waivers)** |
| I2S_Audio | PASS | PASS | 125/127 | 336/340 | 4/4 | all pass | **closed (1 line + 2 toggle waivers)** |
| SAS | PASS | PASS | 352/371 | 490/594 | 22/22 | all pass | **closed (5 line + 4 toggle waivers)** |
| SATA | PASS | PASS | 420/437 | 1191/1279 | 31/31 | all pass | **closed (5 line + 3 toggle waivers)** |

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

- **I2S_Audio**: 120 randomized stereo loopback transactions, random format
  (I2S/LJ/RJ) x depth (16/24/32, encodings 2/3), random data with all-0/all-1
  corners, ~25% slave-mode (TB-generated bclk/wclk). Error classes: dropped
  bclk pulse (irq must pulse, then auto-resync and loop back correctly) and
  TX underrun (wire must carry zeros; RX checked against 0).

- **SAS**: the DUT initiator runs its own write/read-verify sequence over the
  loopback link; CRV = 120 randomized error-injection transactions flipping
  one random bit (position 0..31) of a random dword (HDR/PAY/CRC/EOF) of a
  random frame (write / read-req / read-rsp, via frame-skip 0..2). Per txn:
  injection must fire, DUT must flag it (irq from crc/proto/timeout error),
  link must stay alive (a later txn completes ok or caught-mismatch).
  Observed mix: 78 crc / 43 proto / 82 timeout flags on wr=37/rdreq=28/
  rdrsp=55 frames. Injection methodology note: arming must be edge-detected
  on TS_SOF and frame-skipped, otherwise every injection lands on the EOF of
  the in-flight read-response (arming moment is correlated with TX position).

- **SATA**: 120 randomized host-command transactions vs a 64-dword shadow
  sector model (seeded with the directed phase's surviving writes): ~45%
  random write + read-back (lba 0..60, corners), ~19% poisoned write (one
  random bit of a random dword incl. SOF of the command or data FIS -> host
  timeout + errf + irq, buffer unpolluted, recovery write/read), ~14%
  poisoned read, ~11% read-only of a written lba, ~11% unknown command
  (device error status 8'h51 + errf). Gotcha: Verilator 5.006 duplicates
  `$urandom_range` calls inlined in case expressions -- assign the selector
  to a temp first.

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
