# W6-rest wave — coverage report & waiver log (v2.5 CRV)

Scope: 30 protocols (CXL, PCIe, UALink, UCIe, UEC, Interlaken_v1_2,
TileLink__TL_UL_TL_C_, JESD204C, Avalon_MM, Avalon_ST, OCP,
OCP_IP_Open_Core_Protocol, WTB, Wishbone, CPRI_v8_0__eCPRI_over_CPR_,
eCPRI_over_Ethernet, HSI, CAN, FlexRay, LIN, Bluetooth5, CSE,
Crypto___Security_Engine, _1_Wire, GPIO, JTAG, PWM, QSPI, SPI, UART).
Waivers: `scripts/verilator_cov/waiver_w6.vc`.

## Scoreboard (completed protocols)

| Protocol | iverilog sim | Verilator run | LINE | TOGGLE | FSM | SVA_CHECKS | status |
|---|---|---|---|---|---|---|---|
| GPIO   | PASS | PASS | 18/18 (100%) | 61/61 (100%) | N/A (no FSM: register/comb core) | 2694/2694 | **closed** |
| PWM    | PASS | PASS | 18/18 (100%) | 128/138 (92.8%) | N/A (no FSM: counter/comb core) | 42046564/42046564 | **closed (1 waiver)** |
| UART   | PASS | PASS | 91/93 (97.8%) | 67/80 (83.8%) | 8/8 (TX+RX FSMs) | 3294866/3294866 | **closed (5 waivers)** |
| SPI    | PASS | PASS | 32/32 (100%) | 54/54 (100%) | N/A (no FSM: shift datapath) | 57106/57106 | **closed** |
| QSPI   | PASS | PASS | 61/61 (100%) | 69/70 (98.6%) | N/A (no FSM: shift datapath) | 40576/40576 | **closed (1 waiver) + RTL bug recorded** |
| JTAG   | PASS | PASS | 62/63 (98.4%) | 71/71 (100%) | 16/16 (TAP) | 35041/35041 | **closed (1 waiver)** |
| UALink | PASS | PASS | 35/37 (94.6%) | 142/148 (95.9%) | 3/3 | 6278/6278 | **closed (5 waivers)** |
| UCIe   | PASS | PASS | 35/37 (94.6%) | 142/148 (95.9%) | 3/3 | 6278/6278 | **closed (5 waivers)** |
| CXL    | PASS | PASS | 132/138 (95.7%) | 458/495 (92.5%) | 5/5 (TX+RX) | 10431401/10431401 | **closed (6L+8T family waivers)** |
| PCIe   | PASS | PASS | 123/138 (89.1%) | 458/495 (92.5%) | 5/5 (TX+RX) | 10674441/10674441 | **closed (family waivers)** |
| UEC    | PASS | PASS | 123/138 (89.1%) | 458/495 (92.5%) | 5/5 (TX+RX) | 10674441/10674441 | **closed (family waivers)** |
| Interlaken_v1_2 | PASS | PASS | 123/138 (89.1%) | 458/495 (92.5%) | 5/5 (TX+RX) | 10674441/10674441 | **closed (family waivers)** |
| JESD204C | PASS | PASS | 123/138 (89.1%) | 458/495 (92.5%) | 5/5 (TX+RX) | 10674441/10674441 | **closed (family waivers)** |
| CAN    | PASS | PASS | 173/175 (98.9%) | 309/327 (94.5%) | 16/16 (TX+RX) | 2857639/2857639 | **closed (2L+4T family waivers)** |
| FlexRay | PASS | PASS | 173/175 (98.9%) | 309/327 (94.5%) | 16/16 (TX+RX) | 2857639/2857639 | **closed (family waivers)** |
| LIN    | PASS | PASS | 173/175 (98.9%) | 309/327 (94.5%) | 16/16 (TX+RX) | 2857639/2857639 | **closed (family waivers)** |
| Avalon_ST | PASS | PASS | 18/18 (100%) | 85/85 (100%) | N/A (no FSM: FIFO datapath) | 3101/3101 | **closed (no waivers)** |
| HSI    | PASS | PASS | 62/62 (100%) | 64/68 (94.1%) | 4/4 | 1244908/1244908 | **closed (2 waivers) + RTL bug W6-4** |
| TileLink__TL_UL_TL_C_ | PASS | PASS | 58/59 (98.3%) | 190/194 (97.9%) | 2/2 | 3637/3637 | **closed (2 waivers)** |
| _1_Wire | PASS | PASS | 67/68 (98.5%) | 61/64 (95.3%) | 8/8 | 12395653/12395653 | **closed (2 waivers) + RTL bug W6-5** |
| Avalon_MM | PASS | PASS | 84/106 (79.2%) | 168/176 (95.5%) | 3/3 | 21419/21419 | **closed (2L+1T waivers)** |
| Wishbone | PASS | PASS | 82/84 (97.6%) | 219/220 (99.5%) | 3/3 | 3082/3082 | **closed (2L+1T waivers)** |
| OCP    | PASS | PASS | 59/72 (81.9%) | 162/162 (100%) | 4/4 | 8992/8992 | **closed (2 waivers)** |
| OCP_IP_Open_Core_Protocol | PASS | PASS | 99/102 (97.1%) | 522/551 (94.7%) | 6/6 | 13597/13597 | **closed (2L+3T waivers)** |
| Crypto___Security_Engine | PASS | PASS | 167/177 (94.4%) | 1490/1493 (99.8%) | 5/5 | 260143/260143 | **closed (3L+1T waivers)** |

CRV stimulus summary:
- GPIO: 120 txns (output write+loopback / external input drive / illegal-address
  write+read injection); TB model of out_q/in_q.
- PWM: 110 txns (normal / boundary duty=0,period / misuse duty>period /
  illegal-address) + deterministic all-ones register flush + 2^22-period long run;
  expected high-count = min(duty, period).
- UART: 120 txns (random loopback bytes incl. 0x00/0xFF and back-to-back frames /
  false-start glitch injection via breakable loopback). Coverage build uses
  BAUD=100k (DIV16=31) for div_cnt low-bit toggle; iverilog path keeps 1Mbaud.
- SPI: 110 txns (full-duplex random frames / mid-frame CS abort / illegal addr).
- QSPI: 120 txns (std full-duplex / quad read with random mode encodings 1-3 /
  quad write / illegal addr) + RTL-bug demo (below).
- JTAG: 100 scans (IDCODE / USER write+readback / BYPASS shift model / reserved-IR
  falls back to BYPASS) + random TMS walks (16/16 states) + mid-scan async TRST
  injection (covers the trst_n branches).
- UALink/UCIe: 110 flits (random txnID/addr, all-zero/all-one boundary, junk flit
  while busy must be ignored); rsp {txnID, addr[15:0], opcode=OK} self-check.

- CXL family (CXL/PCIe/UEC/Interlaken_v1_2/JESD204C, identical 204-line
  framed-echo template, one TB sed-copied x4): 127 frames — 100 good
  (LEN 9..16 random + all-zero/all-one), 2 bad-STP (echo still expected),
  8 bad-CRC, 12 long (LEN=17/18 bad-CRC, toggles buf_mem[22:23] via the RX
  store port), 2 bad-END, 3 zero-len (LEN=0x40/0x80/0xC0 -> len_q=0, echo of
  16 tx_mem bytes). Shadow model predicts the Verilator OOB-masked echo copy
  (tx_mem[0..3] <= buf_mem[18..21]) exactly (shadow-err+=0). Echo first byte
  predicted 8'h00 (RTL bug W6-2 below). Verilator bit sampling is
  clock-counted: 40 posedges + negedge per bit cell (a 39-posedge + negedge
  cell drifts -0.5 clk/bit and desynchronises after ~80 bits — measured).

- CAN family (CAN/FlexRay/LIN, identical 253-line controller template, one
  TB sed-copied x2): 120 frames through the register interface in loopback —
  100 good (random 11-bit id, dlc 0..8, every 7th misuse dlc 9..15 — both
  ends wrap dlc[2:0] consistently, all-zero/all-one stuffing boundaries,
  illegal-address reads expect 8'h00), 10 live bit-flip injections (rxd =~ txd
  for one 40-clk cell in the data phase — a *held* injected value misses when
  txd transitions mid-window, measured 5/10; live inversion is exact), 10
  recovery frames proving sticky rx_err clears on the next SOF.

- Avalon_ST: 14 reset rounds x (1..16 random beats with eop/irq inline
  checks + 2 overflow drops on full rounds + full readback), ~112 pushes.
- HSI: 110 txns (45 writes / 45 reads / 20 wrong slave-address). Bit-banged
  SSC + SA + PC + AD + data via single-coroutine #delay macros.
- TileLink: 174 txns (64-entry regfile random write sweep + 4 sweep readbacks
  + 110 random valid PutFull/PutPartial/Get with shadow-regfile check + 5
  round-robin error classes with full-random addresses + 4 post-error
  readbacks). a_param wiggled between txns (functionally unused input).
- _1_Wire: 105 txns, each under a hard rst_n pulse (see W6-5): 600us reset +
  presence + random command write + random read byte; every 10th a 100us
  glitch (must return to IDLE with no presence).

- Avalon_MM: 126 txns (16-burst 256-word sweep + 110 random write/read
  bursts in fast/slow/OOR-straddle/far-OOR windows, burstcount 0/clamp>16,
  byteenable merge, simultaneous r+w, OOR truncation) via shadow regfile +
  in-order read scoreboard.
- Wishbone: 376 txns (256-word pipelined sweep + 120 random classic/pipe
  beats in fast/slow/hole windows + reserved-region err beats incl. one
  queued behind a burst for q_rsv[1]). Lesson: classic single-beat tasks
  correlate ack_o with their own request -> bursts must drain
  (exp_rd==exp_wr) before any classic beat.
- OCP: 376 txns (256-word sweep + 120 random WR/RD/WRNP x valid/misaligned/
  reserved). Directed forked irq monitors replaced by a module-level irq
  flag under VERILATOR (fork branches lose wakeups, mode #2).
- OCP_IP: 146 txns (16 posted seed bursts + 130 random read/write bursts,
  len 1..8, len=0 clamp, posted, len>8 clamp via custom 8-word flow,
  reserved SResp=ERR, 64-clk dead-region timeout aborts, post-abort
  recovery + shadow re-verify). to_cnt overshoots to 64 for one cycle on
  the abort cycle (internal counter, no functional impact; A5 bound set
  accordingly).

- Crypto: 110 randomized SHA-256/HMAC ops, each run twice back-to-back
  (bit-identical determinism check), HMAC != SHA cross-mode sanity, padding
  boundary lengths 0/1/55/56/63/64, + 10 busy-violation injections
  (msg/key/start while busy -> irq). No second SHA model in the TB; exact
  correctness anchored by the directed NIST/RFC4231 vectors.

## RTL bugs recorded (NOT fixed, per wave discipline)

### QSPI-1: std-mode MOSI contention (slave drives io[0])
- File: rtl/QSPI_top.sv:32 — `assign io = io_oe ? io_out : 4'bzzzz;`
- Root cause: the 4-bit `io_oe` vector is used as a *boolean*, so whenever any
  OE bit is set (std mode io_oe=4'b0010) the DUT drives **all four** io bits.
  In std mode `io_out[0]` holds tx_q[4] (presentation branch, rtl/QSPI_top.sv:46),
  so the slave drives the MOSI line against the master.
- Failure signature: whenever tx_q[4]=1, all 8 sampled MOSI bits read back 1
  (rx_q=8'hFF) under the toolchain's tri resolution; 100% correlation
  (8/8 failing CRV frames had tx_q[4]=1, io_out[0]=1). In iverilog the same
  contention yields X. Latent in v2.4: the directed TB never checked std-mode
  rx_q.
- TB handling: CRV std-mode tx values reject bit4=1 (documented in tb/QSPI_tb.sv);
  a deterministic demo (tx_q=0x10, MOSI=0xA5 -> rx_q=0xFF) runs after the CRV
  loop and prints an RTL-BUG note. Candidate for the v2.5.1 fix list.

### W6-1: CXL-family echo-copy OOB (template bug, CONFIRMED in 5 more protocols)
- Files: rtl/CXL_top.sv:196-197, rtl/PCIe_top.sv:196-197, rtl/UEC_top.sv:196-197,
  rtl/Interlaken_v1_2_top.sv:196-197, rtl/JESD204C_top.sv:196-197 —
  `for (int i = 2; i < HB + MAXB + 6; i++) tx_mem[i-2] <= buf_mem[i];`
  (i=2..21, tx_mem is [0:15] -> indices 16..19 out of bounds).
- Behaviour: iverilog drops the OOB writes; Verilator masks the index so
  buf_mem[18..21] clobber tx_mem[0..3] (later NBA wins over the i=2..5 writes).
- TB handling: VERILATOR-path shadow buf_mem model predicts the masked result;
  105 echoes byte-verified, 0 mismatches. Same root cause as the previously
  confirmed NVMe/FC/Ethernet/USB3_2/USB4 instances.

### W6-2: CXL-family TX never transmits STP (stale shift register)
- Files: rtl/<P>_top.sv:60-64 (same five) — T_IDLE -> T_PKT transition sets
  oe_q/out_q/tbit/tfld but never loads tx_shift with STP; the tfld==0 ("STP")
  field therefore shifts out the stale register, which is deterministically
  8'h00 (after the previous frame's END byte shifts out; also 0 after reset).
- Failure signature: every echoed frame's first wire byte is 8'h00 instead of
  STP (8'h5C for CXL, 8'hFB for the rest). A real link partner would reject
  every echo with rx_err (bad STP).
- Latent in v2.4: the directed TB discards the first received byte.
- Minimal repro: send any valid frame; observe echo byte0 == 8'h00.

### W6-3: CXL-family LEN=8 (zero-payload) TX data overrun
- Files: rtl/<P>_top.sv:90 (same five) — data-field end compare is
  `if (tcur == (tlen[3:0] - 4'd1))`; for tlen=8 this is 8==7, never true at
  the tcur=8 start, so TX sends 16 data bytes (tx_mem[8..15] then tx_mem[0..7])
  instead of 0. The wire frame is 16 bytes longer than its own LEN field.
- Minimal repro: send a valid LEN=8 frame; echo carries 24 data bytes.
- CRV good/bad-STP frames use LEN 9..16 (LEN=8 exercises only the no-echo
  error injections). Documented, not fixed.

### W6-4: HSI read: last data bit never driven (read LSB always 1)
- File: rtl/HSI_top.sv:80-83 — in ST_DATA read at sclk_fall the block assigns
  `sd_oe <= 1'b1; sd_out <= tx_byte[7-bit_cnt];` then, when bit_cnt==7,
  `sd_oe <= 1'b0` in the same cycle (last assignment wins), so tx_byte[0] is
  never driven onto sdata.
- Failure signature: every read returns tx_byte | 8'h01 (the tri1 pullup
  supplies the undriven LSB); 18/45 CRV reads with even tx_byte failed.
- Latent in v2.4: the directed read used tx_byte=8'hC3 (LSB already 1).
- Minimal repro: rffe_read with tx_byte even, e.g. 8'h02 -> reads 8'h03.
- TB handling: CRV read shadow predicts d|8'h01. Candidate for v2.5.1.

### W6-5: 1-Wire reset pulse only detected from ST_IDLE
- File: rtl/_1_Wire_top.sv:50-51,70-71 — reset-pulse detection
  (`ST_IDLE: if (!dq_s) -> ST_RESET_CNT`) exists only in ST_IDLE; in
  ST_WAIT_SLOT a falling edge is interpreted as a write slot
  (ST_W_SAMPLE), so a 600us bus reset after a completed read phase is
  mis-sampled as a 0 data bit and the slave's bit_cnt desynchronises from
  the master (real 1-Wire slaves detect the reset pulse from any state).
- Minimal repro: run one full reset+write+read transaction, then issue a
  second 600us reset pulse: the slave samples it as a write-0 bit
  (bit_cnt advances) and the next command byte is misaligned.
- TB handling: each CRV txn runs under a hard rst_n pulse; documented, not
  fixed.

### Template OOB advisory (cross-wave notice)
Lead advisory: echo-copy template `for (i=2; i<=21; i=i+1) tx_mem[i-2] <= buf_mem[i];`
with 16-entry tx_mem (OOB write). Grep of the W6 protocol list RTLs for this
pattern: **not present** in the 8 completed protocols (no tx_mem/buf_mem echo
template in GPIO/PWM/UART/SPI/QSPI/JTAG/UALink/UCIe). Remaining unworked
protocols not yet audited.

## Verilator 5.006 scheduler failure mode #2 (new, important)

Distinct from the documented long-pending-#delay heap corruption (COVERAGE.md
note 1): on UALink/UCIe (credit-based flit DUT + TB with 2+ active coroutines),
processes **lose @(posedge) wakeups for multi-clock windows**:
- Symptom A (first form): a second `forever` coroutine (periodic credit-grant
  initial block) silently stopped; the DUT starved in C_SEND waiting for tx_crd;
  main coroutine hung in `wait (rxrspflitv)`. Workaround: in the `ifdef
  VERILATOR` path drive the grant input **constant** (no forever coroutine).
- Symptom B (after A was fixed): deterministic accept loss every 9th transaction
  when the stimulus used `while (!txreqlcrdv) @(posedge clk);` polling followed
  by an NBA flit drive. Traces showed the accept window (flitv=1, cstate=IDLE,
  rx_crd=8) fully present, yet the DUT's always_ff produced **no** state
  transition and no side effects for that window — as if the DUT process was not
  resumed for ~7 clocks — then resumed. 100% reproducible per build.
  Workaround: replace credit polling with a fixed `repeat (2) @(posedge clk);`
  settle (8-deep acceptance credit can never be exhausted at ~1 flit / 9 clks
  with a 6-clk response loop). Result: 110/110 flits accepted + answered.
- Defensive pattern applied: all CRV waits are **bounded** (counter + error
  print) so any residual scheduler loss becomes a diagnosable error, never a
  silent timeout.

Also confirmed (from COVERAGE.md): single long `#delay` timeouts must stay
chunked (`repeat (N) #1000;`) — applied in every TB of this wave.

## Waiver summary (see waiver_w6.vc for full text)

| ID | Point | Justification |
|---|---|---|
| pwm-toggle-1 | counter[31:22] | bit k toggles only in a >=2^(k+1)-clock single period; carry chain proven through bit 21 by the 2^22 long run |
| uart-line-1/2 | default arms (tstate/rstate) | dead: 2-bit states fully cased |
| uart-toggle-1 | div_cnt[15:5] | DIV16=31 in coverage build; upper bits are 16-bit generic headroom |
| uart-toggle-2/3 | tbit[3]/rbit[3] | bit counters wrap at 4'd7 (8N1) |
| qspi-toggle-1 | qcnt[1] | nibble counter wraps at 2'd1 |
| jtag-line-1 | default: tap_q <= TLR | dead: 4-bit TAP fully cased |
| ualink-line-1 / ucie-line-1 | C_SEND arm attribution artifact | execution proven by 110 received responses |
| ualink-line-2 / ucie-line-2 | default: cstate <= C_IDLE | dead: 2-bit state, 3 encodings cased |
| ualink-toggle-1 / ucie-toggle-1 | rxrspflit[33:30] | constant opcode 5'b00001 upper bits |
| ualink-toggle-2/3 / ucie-toggle-2/3 | crd_timer[3] (wraps 7), lat_cnt[3] (RSP_LAT=4) | counter wrap limits |

## Not completed (step budget exhausted)

CXL, PCIe, UEC, Interlaken_v1_2, TileLink__TL_UL_TL_C_, JESD204C, Avalon_MM,
Avalon_ST, OCP, OCP_IP_Open_Core_Protocol, WTB, Wishbone,
CPRI_v8_0__eCPRI_over_CPR_, eCPRI_over_Ethernet, HSI, CAN, FlexRay, LIN,
Bluetooth5, CSE, Crypto___Security_Engine, _1_Wire — untouched; iverilog
regression for these remains at the v2.4 baseline (PASS).

## Final status (W6 continuation coder, this session)

**Completed this session (17 protocols, all four metrics closed):**
CXL, PCIe, UEC, Interlaken_v1_2, JESD204C (family batch), CAN, FlexRay, LIN
(family batch), Avalon_ST, HSI, TileLink, _1_Wire, Avalon_MM, Wishbone, OCP,
OCP_IP, Crypto. Together with the previous coder's 8 (GPIO..UCIe), the wave
stands at **25/30**.

**Not completed (5):** WTB, Bluetooth5, CPRI_v8_0__eCPRI_over_CPR_,
eCPRI_over_Ethernet, CSE — step budget exhausted. These are the five largest
remaining protocols (365-542 lines: token-ring station FSM, BLE link layer,
CPRI 8b/10b sync engine, eCPRI message dispatch, CSE cipher core). Their
directed TBs still pass iverilog untouched. Recommended next-session order:
CSE (engine-style, similar to Crypto) -> CPRI (3-state sync FSM; existing TB
already has a full 8b/10b peer model + enc/dec functions to reuse for a
random IQ-stream CRV) -> eCPRI -> WTB -> Bluetooth5.
