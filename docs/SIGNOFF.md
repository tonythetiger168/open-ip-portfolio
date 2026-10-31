# Sign-off status

What each hardened IP has been put through, with the open-source flow this
repository can run, and what a production (SoC vendor) sign-off would still
need. IPs are added here as they are brought up to this bar; the others have
the five-metric coverage of [COVERAGE_CLOSURE.md](COVERAGE_CLOSURE.md) only.

## Checks

| Check | How | Pass criterion |
|---|---|---|
| Lint | `verilator --lint-only -Wall rtl/<P>_top.sv` | no warnings |
| Simulation | `make -f Makefile.<P> sim`, `make -f Makefile.<P> apb` (Icarus) | TEST PASSED |
| Coverage | `bash scripts/cov/run_cov.sh <P>` and `<P>_apb` (Verilator, bound checker with an independent model) | line, toggle, FSM, SVA, functional all 100% (exclusions justified in `scripts/cov/exclude/`) |
| Mutation | `python3 scripts/mut/run_mut.py <P> --flow cov -n N` | every mutant killed, or listed as equivalent with a reason in `scripts/mut/equivalent.txt` |
| Formal | `bash scripts/formal/run_formal.sh <P>` (yosys SAT): the properties in `formal/<P>_props.svh` with every input free after reset | bounded proof to the depth in `formal/<P>.cfg`; k-induction where it closes |
| Exhaustive | `python3 scripts/formal/exhaust_ml_kem.py`, `python3 scripts/formal/exhaust_ethfec.py`, `python3 scripts/formal/exhaust_ethpcs.py` (Verilator): the arithmetic and data functions and constant tables, cut out of the RTL, against their definitions or the checker's own versions; for the PCS also every reachable gearbox state | every input matches |
| Area / depth | `bash scripts/syn/ppa_report.sh <P>` (yosys + ABC, 2-input gates) | area in NAND2 gate equivalents and the deepest flip-flop to flip-flop path in gate levels |

The area and depth numbers are technology-independent estimates: no foundry
library is used, the GE weights are the textbook ones, and the depth is in
gate levels, not picoseconds. They rank designs and find deep paths; they are
not a timing sign-off.

## Results

| IP | Lint | Coverage (core / APB) | Mutation | Formal | Area | Deepest path |
|---|---|---|---|---|---|---|
| UCIe 3.0 | clean | 100% / 100% | 40/40 killed (2 equivalent listed) | bounded proof, 5 properties, depth 20 | 53.7 kGE (5244 flip-flops) | 44 gate levels |
| PCIe 3.0 | clean | 100% / 100% | 40/40 killed | bounded proof, 11 properties, depth 25 | 27.0 kGE (2765 flip-flops) | 64 gate levels |
| CXL 3.0 | clean | 100% / 100% | 40/40 killed (7 equivalent listed) | bounded proof, 10 properties, depth 36 | 139.4 kGE (16554 flip-flops) | 82 gate levels |
| ML-KEM 1.1 | clean | 100% / 100% | 40/40 killed (4 equivalent listed) | exhaustive arithmetic: pass (see below) | 100.7 kGE logic (2891 flip-flops) + 94 kbit RAM | 53 gate levels |
| Ethernet RS-FEC 1.0 | clean | 100% / 100% | 40/40 killed (6 equivalent listed) | exhaustive arithmetic: pass (see below) | 366.9 kGE (3661 flip-flops) | 82 gate levels |
| Ethernet PCS 1.0 | clean | 100% / 100% | 40/40 killed (3 equivalent listed) | exhaustive functions and gearboxes: pass (see below) | 63.4 kGE (2773 flip-flops) + 2 RS-FEC cores | 40 gate levels (82 in the RS-FEC) |
| Root of Trust 1.0 | clean | 100% / 100% | 40/40 killed (1 equivalent listed) | bounded proof, 13 properties, depth 24 | 27.2 kGE (1783 flip-flops) | 74 gate levels |

Formal properties:

- **UCIe** (`formal/UCIe_props.svh`): the link state is one of the seven; at
  most RB flits outstanding, with the replay pointer among them; payloads are
  taken only in ACTIVE and not while an L1 request is pending; the negotiated
  capabilities are a subset of our own. The main band, sideband and protocol
  side are free inputs: the far side may send any flit or message.
- **PCIe** (`formal/PCIe_props.svh`): ASPM, transmit and receive states legal,
  L1 only with the link up; at most TXN TLPs written and unacknowledged, the
  sent ones among them; `tlp_ready` only in L0 with the link up; at most RXN
  TLPs and RXN x MAXLEN bytes in the receive buffer; the header and data
  credits held per type never exceed those advertised, and the header credits
  held equal the TLPs in the buffer; the byte being read lies inside its TLP.
  The symbol inputs are free: the far side may send any symbol stream.
- **CXL** (`formal/CXL_props.svh`, 10 properties): the BI engine is in one
  of its three states and takes a device request only when idle with HDM-DB
  on; the snoop-filter count equals the number of lines not Invalid; the
  Req FIFO, the RwD ring and the CXL.io buffers never hold more than their
  size, and the CXL.io read beat stays inside its flit; the credits owed
  back to the host never exceed the buffer sizes; the unpacker stays inside
  the flit and an RwD owes at most one line of data; a DRS sends its data
  only after its header; a beat offered on the link stays, unchanged, until
  it is taken. Depth 36 covers a whole flit in each direction. The link
  receive side, the CXL.io ports, the device BI requests, the HDM base,
  bi_en and reset are free: the host may send any beat stream, with or
  without credits. k-induction does not close within 4 steps, so the result
  is the bounded one.
- **Root of Trust** (`formal/Root_of_Trust_props.svh`, 13 properties): the
  control state is legal; the device key is out only after a verified boot
  in DEV or PROD and is zero otherwise; the CPU runs in DEV and PROD only
  with the key, in TEST and RMA without, never in RAW, SCRAP or INVALID;
  after an escalation there is no CPU, debug, key or OTP access and no
  secret left in the hash block; the UDS is read only for the key
  derivation (and the read-back of its own program in TEST), never by a
  command; a command programs only a word open in the current state; the
  lifecycle and scrap words are programmed only by a transition, with a
  legal target and the right value, and never after three wrong tokens; an
  image is taken only in DEV or PROD before the boot decision. The OTP
  data, commands, tokens, image words and the escalation input are all
  free: the OTP may return anything, and any command sequence is tried.

- **ML-KEM**: no SAT proof: the 8 KiB buffer and the 2560 x 12-bit
  polynomial store are too large for the open solver flow. Instead
  `scripts/formal/exhaust_ml_kem.py` cuts the arithmetic out of
  `rtl/ML_KEM_top.sv` unchanged and checks it for every input it can get:
  the reduction mod q for every x < 2^25 (the largest product is below
  2^24), addq / subq for every pair below q, Compress_d / Decompress_d for
  every input and d in {1, 4, 5, 10, 11}, the 128-entry zeta and gamma
  tables against 17^BitRev7(i), and the 24 Keccak round constants against
  the FIPS 202 LFSR. Functional correctness is shown by the FIPS 203
  vectors (NIST ACVP and the reference model, which passes all 240 ACVP
  cases) and by the bound checker, which recomputes every Keccak
  permutation and polynomial step from its inputs.
- **Ethernet RS-FEC**: the datapath is GF(2^10) arithmetic and constant
  GF(2)-linear maps (encoder, syndromes, Chien / Forney evaluation and the
  per-beat rescaling). `scripts/formal/exhaust_ethfec.py` cuts them out of
  `rtl/Ethernet_RS_FEC_top.sv` unchanged and checks gmul for all 2^20
  pairs, the inverse for all 1024 inputs, and every column of every matrix
  against its definition (computed from alpha, g(x) and x^e mod g by long
  division); a linear map that is right on every unit vector is right on
  every input. The control (riBM, uncorrectable detection, pipeline) is
  checked by 23 vectors from the Python reference model and by the bound
  checker, which re-encodes and decodes every codeword with a classic
  Berlekamp-Massey decoder of its own.
- **Ethernet PCS**: `scripts/formal/exhaust_ethpcs.py` cuts the 256b/257b
  transcoder, the receive transcoder, the scrambler and the block-type
  decode out of `rtl/Ethernet_PCS_top.sv` unchanged and compares them with
  the bit-serial versions in the checker (written separately from clause
  119): every sync-header combination with the zero and every one-hot
  payload (the payload is moved bit for bit, so this covers every input;
  65792 inputs), every header / flag / block-type class of the receive side
  (132096), and the scrambler, which is linear, on every unit vector in
  both directions. It also enumerates every reachable state of the two
  gearboxes (257-bit blocks to 640-bit beats, 17 beats per codeword pair):
  the fill registers never overflow, and transmit fill bit 6 is never set
  (the one toggle exclusion). The alignment-marker group is a constant
  table generated by `scripts/ethpcs/gen_tables.py` from Table 119-2
  (`--check` compares it with the RTL). The marker lock, the codeword
  interleave and the error marking are checked by vectors from the Python
  model (`scripts/ethpcs/pcs_ref.py`) and by the bound checker, which
  re-encodes every pair bit-serially with its own marker table, scrambler
  and RS encoder.

Changes made for this bar:

- CXL 3.0 deepens the CXL.mem Type 3 slice of 2.0 with a 256-byte flit
  link layer (header and sequence number, 14 generic slots, credit return,
  CRC-64), a CXL.io pass-through path with its own credits, and HDM-DB
  back-invalidation (snoop filter, eviction by BISnpInv, device-initiated
  BISnpCur / BISnpData / BISnpInv, BIRsp legality checks, BIConflict /
  BIConflictAck). The formal run found that a host sending messages without
  credit could push the credits owed back past the buffer size, where the
  counters wrapped and the device would have returned the wrong number of
  credits; a message is now accepted only into a buffer backed by a credit
  the host holds (in use plus owed below the size), otherwise it is dropped
  with ev_ovf. Mutation testing showed that no test made the first
  arbitration ties after reset (a directed phase now does), and that two
  terms of the DRS-before-NDR order flag had no effect (removed). The core
  and APB tests share one host model (`tb/CXL_host.svh`).
- Ethernet PCS 1.0 is new: the 802.3 clause 119 PCS (400GBASE-R, 16-lane markers)
  around two RS-FEC cores, with 256b/257b transcoding, the 1+x^39+x^58
  scrambler, the alignment-marker group every 4096 codeword pairs
  (inserted on transmit; lock, loss of lock and status on receive), the
  two-way 10-bit symbol interleave and the 17-beat gearbox. The flows now
  take `COVLIB` in a Makefile: files that are IPs of their own (here the
  RS-FEC) are compiled in but not scored in the coverage of the IP that
  uses them, are skipped by the FSM extraction, and are read as black
  boxes by the area report (their area is in their own row).
- Root of Trust 1.0 is new. Mutation testing found a read-strobe register
  that only repeated `otp_req`: removed, the OTP handshake now uses
  `otp_req` / `otp_ack` directly. It also found two test gaps, now closed:
  the oversized-image test was refused by its digest alone, so a core that
  let the word counter wrap would have passed it (the OTP now holds the
  digest a wrapped counter gives, `IMG_WRAP_DIG`); and the rejected-digest
  cases now flip a bit in the first, the last and a middle digest word.
- Ethernet PCS: mutation testing showed no test had a marker group with
  only its first block damaged (the lock compares all eight); one was added.

- ML-KEM 1.1: the polynomial unit is an 8-stage pipeline. An issue stage
  walks the step and issues one token per clock (up to six reads, a value,
  up to two writes or an Encode byte); the polynomial store has registered
  reads; products, the Barrett quotient and the remainder are separate
  stages, and all tokens write back from the last stage in order. A step
  ends 8 clocks after its last token. The NTT layer boundaries were checked
  for read-after-write hazards: the last 8 butterflies of a layer and the
  first 8 of the next touch disjoint coefficients, in both directions and
  into the scaling pass. The step parameters are registered at the start of
  a step, so the program decode is off the datapath. The deepest path went
  from 176 to 53 gate levels; clock counts grew by about 1%. The PPA flow now
  splits registered RAM reads out of the RAM cell (memory_nordff) and does
  not share resources across pipeline stages (-noshare); this also moved the
  Ethernet RS-FEC figures to 366.9 kGE and 3661 flip-flops (the read
  registers are now counted), with the same depth.

- UCIe: the 528-bit CRC-16 was a 528-step serial loop (292 gate levels after
  synthesis); it is now a parallel XOR network built at elaboration (44
  levels for the whole design).
- PCIe: each replay-buffer slot keeps its TLP's credit type and data credits
  as the TLP is written, instead of decoding them from the buffer when the
  TLP is scheduled (70 to 65 levels). Credits held are derived from received
  minus allocated counters, which fixed a lost count when a TLP arrived and
  another was read out on the same clock. Mutation testing found three
  statements with no effect (an Ack-timer reset already done elsewhere and
  a request flag cleared on a path where it is never read): removed. It
  also showed that L1 could be entered with an Ack, Nak or UpdateFC still
  owed, only to leave it again on the next clock: L1 is now entered (on a
  PM_Request_Ack or a request from the far side) only with nothing owed,
  and a test sends a TLP right before the PM_Request_Ack to check it.

## Still open for a production sign-off

These need tools, data or documents this repository does not have:

- **CXL.** The flit and message layouts are our own simplified encoding of
  the CXL 3.x 256-byte flit (no 68-byte or latency-optimised flit); there
  is no link-layer retry (a bad flit is dropped and reported), no FEC
  correction, no IDE (planned once AES-GCM is in), no CXL.cache, no PBR or
  multi-headed devices; CXL.io carries the payload to an external
  transaction layer. Device memory is 16 lines of flip-flops.
- **Ethernet PCS.** The PCS works on the aggregate 640-bit stream (two
  interleaved codewords per 17 beats); distribution over the 8 or 16 PMA
  lanes, per-lane alignment-marker lock and deskew are not built yet. The
  marker period is a parameter (4096 pairs, the 400G value; tests use 3).
  200GBASE-R (8 lanes) needs its own marker table.
- **Root of Trust.** The OTP is a model, with no ECC; there is no
  entropy source, attestation signature (the key is for a crypto engine
  on the sideload port), glitch or clock monitor, or masking of the
  SHA-256; the RAW-exit token hash is fixed in the netlist.
- **Specification compliance.** ML-KEM is checked bit-exact against FIPS
  203 (NIST ACVP vectors), but has not been through CAVP / CMVP
  validation. The UCIe, PCIe and CXL specifications are
  member-only. Field layouts, message codes and CRCs follow the structure of
  the specifications as we read them but have not been checked against them,
  against another implementation, or with compliance tests or commercial VIP.
- **Timing closure.** No foundry standard-cell library, no STA with
  constraints and corners. The deepest paths (Ethernet RS-FEC 82 levels in
  the Berlekamp-Massey step; CXL 82; PCIe 64 in the transmit scheduler; ML-KEM 53 in
  the compress stage; Root of Trust 74 in the SHA-256 round; UCIe 44) would need pipelining for a GHz-class clock in a
  modern node.
- **Memories.** The replay and receive buffers are flip-flop arrays (most of
  the flip-flops counted above); a product would use SRAM macros, with BIST.
  ML-KEM's buffer and polynomial store are behavioural arrays. The
  polynomial store has registered reads (since v1.1) but six read ports and
  two write ports (base-case multiplication reads six coefficients per
  clock, the NTT reads and writes two); mapping it to SRAM needs banking
  (by coefficient index per NTT layer) or a slower schedule. The 8 KiB
  buffer still has asynchronous reads.
- **Side channels (ML-KEM).** The operation sequence and clock count depend
  only on the parameter set and the public seed rho, and the Decaps
  rejection is not visible; there is no masking against power or EM
  analysis and no fault-attack protection, which a certified product
  (FIPS 140-3 / CC) would need, along with a validated random source.
- **CDC / RDC.** Each core has one clock and one asynchronous active-low
  reset, so it has no clock crossings; reset deassertion must be synchronised
  by the integrator (no reset synchroniser inside the core), and no RDC tool
  has been run.
- **DFT, power intent, gate level.** No scan insertion or ATPG, no UPF, no
  gate-level simulation, no equivalence check of a netlist.
- **Formal depth.** The bounded proofs use shrunken parameters (see
  `formal/<P>.cfg`) and do not close by induction; they show the properties
  hold for every input sequence up to that depth, not forever.
- **Methodology.** The testbenches are SystemVerilog with an independent
  reference model and SVA, not UVM.
