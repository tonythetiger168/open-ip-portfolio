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
| Exhaustive | `python3 scripts/formal/exhaust_ml_kem.py`, `python3 scripts/formal/exhaust_ethfec.py` (Verilator): the arithmetic functions and constant tables, cut out of the RTL, against their definitions | every input matches |
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
| ML-KEM 1.0 | clean | 100% / 100% | 36/40 killed, 4 equivalent listed | exhaustive arithmetic: pass (see below) | 104.0 kGE logic (1750 flip-flops) + 94 kbit RAM | 176 gate levels (RAM read, butterfly, reduction) |
| Ethernet RS-FEC 1.0 | clean | 100% / 100% | 40/40 killed (6 equivalent listed) | exhaustive arithmetic: pass (see below) | 365.2 kGE (3341 flip-flops) | 82 gate levels |

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

Changes made for this bar:

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

- **Ethernet PCS.** The RS-FEC core is RS(544,514) over 32-symbol beats
  only. The rest of an 802.3 200G/400G/800G PCS (256b/257b transcoding,
  scrambler, alignment-marker insertion and lock, the two-way codeword
  interleave and lane distribution) is not built yet.
- **Specification compliance.** ML-KEM is checked bit-exact against FIPS
  203 (NIST ACVP vectors), but has not been through CAVP / CMVP
  validation. The UCIe and PCIe specifications are
  member-only. Field layouts, message codes and CRCs follow the structure of
  the specifications as we read them but have not been checked against them,
  against another implementation, or with compliance tests or commercial VIP.
- **Timing closure.** No foundry standard-cell library, no STA with
  constraints and corners. The deepest paths (ML-KEM 176 levels through the
  asynchronous RAM read, butterfly and reduction; Ethernet RS-FEC 82; PCIe 64
  in the transmit scheduler; UCIe 44) would need pipelining for a GHz-class clock in a
  modern node.
- **Memories.** The replay and receive buffers are flip-flop arrays (most of
  the flip-flops counted above); a product would use SRAM macros, with BIST.
  ML-KEM's buffer and polynomial store are behavioural arrays with several
  read ports (the NTT reads and writes two coefficients of one polynomial
  per clock, base-case multiplication reads six); mapping them to SRAM
  needs banking (by coefficient index per NTT layer) or a slower schedule.
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
