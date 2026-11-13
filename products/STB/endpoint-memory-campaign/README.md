# STB-ENDPOINT-MEMORY-01: proposal-only real endpoint

**PASS bounded campaign; six-metric closure NOT_CLOSED.** This is one new deterministic profile, one instantiated RTL endpoint (`u_ep.u_core`), one fixed5.052 binary and its exact replay. It does not merge old configurations/union counters or adopt pending width changes into main/PR28.

Sources: [draft PR29](https://github.com/tonythetiger168/open-ip-portfolio/pull/29), commit `48fb2afd65e6f2a41e3739708569aa746f0e15a1`; the two DUT RTL files match its SHA256 pins exactly. `endpoint_memory_tb.sv` derives from its passive endpoint bench with a new top name and a separately instantiated contract helper. DUT functionality is unchanged. `profile.json` pins sources, bench, generator, oracle and runner before execution. Original PR28 evidence, its16mutants, CI and gates remain untouched. Canonical product repository is `tonythetiger168/xuanji-core` (ID1376278559).

## Contract and execution

- DW32/AW32, one outstanding write and one read per direction, aligned byte addresses0..1020. AW/W VALID may appear AW-first, W-first or simultaneously. This implementation accepts W **after AW**; the W-first source holds VALID/data/strobes until accepted. No claim of pre-AW W buffering or arbitrary outstanding transactions.
- Explicitly initialize all1024bytes and read all256words before further partial writes. Normal byte-strobed writes use a bytearray/defined-byte-mask oracle. Reads of uninitialized memory are forbidden, rather than compared against simulator defaults.
- Exercise every order×WSTRB combination (3×16), zero/allones/alternating/walking data, first/middle/last addresses, zero/one/multiple B/R stalls. Hold new AW behind pending B and new AR behind pending R. Concurrent read/write uses different initialized words; same-address overwrite while R is outstanding is outside this contract.
- APB remains zero-wait. ID/status/enable/scratch accesses and all16scratch byte masks occur, including APB work during held AXI B/R responses. This normal-memory profile does not add error-IRQ/reset-drain/security claims.

Pinned existing image: `verilator/verilator@sha256:a5b73e2fce0b2c483396f3800940f33b6faa802331a061c21694dd27b7352120`, source `ea338be98e1e838d3518809ce8899f85a009963c`, Verilator5.052. Network disabled; no tool rebuild or warning suppression. Native build requests per-instance coverage and max-width8192, plus timing, assertions and traces. One3607cycle stimulus performs339writes/342reads, drains all accepted traffic, and passes both the independent bytearray oracle and the existing independent control/IRQ ledger. Same-binary replay has identical parsed trace and exact native point IDs/counts. It is **not added** to the coverage DB.

## Native counters and formal profile bins

DUT-only native counts: line20/22, branch subset30/36, toggle0→1 4588/8789, toggle1→0 525/8789. Expression65/86 remains a separate kind. Exclusions0, raw=effective. DUT hierarchy is exactly `TOP.endpoint_memory_tb.u_ep` and `.u_core`, with no wildcard/union. These are this build's instrumented points, not a full signal/construct inventory; raw toggle includes reset/initialization. No old5.032/5.052 DB or mutant DB is merged.

The complete proposed functional requirement inventory is [requirements-and-witnesses.json](evidence/requirements-and-witnesses.json). All355native bins are present and hit, with exact domain and native/passive **event-count** equality checked independently:

| Requirement | Raw native hit / denominator |
|---|---:|
| Accepted AW word index, all256words |256/256|
| AW/W presentation order |3/3|
| AXI WSTRB |16/16|
| Write data class |4/4|
| B stall length class |3/3|
| R stall length class |3/3|
| Successful B completion |1/1|
| Successful R completion |1/1|
| APB CSR selection |4/4|
| APB scratch strobe |16/16|
| Order×WSTRB cross |48/48|

These are named, finite **proposal-profile requirements**, not complete SoC functional coverage or an externally approved universal bin plan. Full bin labels, native point IDs, source location and raw event counts are preserved. Covergroup/helper/bench counters do not enter DUT line/branch/toggle denominators.

## SVA antecedent and completion witnesses

Eight actual assertions execute in `memory_contract.sv`. Each has two separately exported native USER cover points;16/16witness points hit. Native cover event counts match an independent check over passive pin traces:

| Property | Antecedent events | Completed events / antecedent denominator |
|---|---:|---:|
| AW VALID/address hold while stalled |4|4/4|
| W VALID/data/strobe hold while stalled |447|447/447|
| AR VALID/address hold while stalled |4|4/4|
| B VALID/response hold while stalled |389|389/389|
| R VALID/data/response hold while stalled |376|376/376|
| Accepted W produces BVALID next cycle |339|339/339|
| Accepted AR produces RVALID next cycle |342|342/342|
| APB access has READY in that cycle |40|40/40|

Denominators here are **native antecedent-cover events**, not a native assertion-attempt exporter. Properties are reset-disabled, but reset/vacuity/failure inventories for every assertion are not exported. Full native SVA denominator stays `null/NOT_MEASURED`; eight declarations and positive witnesses do not establish full SVA coverage.

## Sensitivity, gaps and replay

Three separately compiled real RTL mutants are detected by the independent passive oracle: ignoring WSTRB (read mismatch), BVALID gated by BREADY (W→B failure), corrupt read payload (read mismatch). They do not use the helper assertions to get credit, and their DBs are never coverage inputs. Commands, logs, traces and reconstructed exact mutated sources are retained. Original16mutant evidence is unchanged.

Native FSM state/arc records remain absent: **BLOCKED, denominator unknown**, never N/A/100%. Full branch conformance remains blocked because case outcomes can export as line records and the fixed tool has known construct-counter issues. UVM/SoC integration, arbitrary same-address overlap, reset while memory transactions are outstanding, CDC, security scrubbing and physical implementation were not run. Single-endpoint exact hierarchy does not resolve old normal/overlap union coverage.

Replay: bind this directory read-only to `/input`, an empty directory writable to `/output`, and run `python3 /input/run_campaign.py` inside the exact image with network disabled. Build objects stay under disposable `/tmp`. Then run `python analyze_campaign.py` over the resulting local `evidence` to verify exact functional domains and raw/passive event counts. `profile.json` seals executed files; analyzer/report hashes are retained separately in the artifact index. The first source-path launcher error and unsupported explicit-size bin warning are kept in `attempts/`; changing to standard unsized per-value bin arrays preserved all355planned domains, with no suppression or waiver.

Primary evidence: [result](evidence/result.json), [requirements and witnesses](evidence/requirements-and-witnesses.json), raw `native.dat`, passive `native.trace`, waveform `native.vcd`, functional/native point inventories, source/profile hashes and [artifact index](evidence/artifact-index.json).


## Dedicated CI entry

The separate stb-endpoint-memory workflow runs this fixed5.052 profile and the unchanged original9run/16mutant gate in separate jobs. The initialization/readback prefix is collected with the SAME binary before the full3607cycle run: complete native IDs must match, source/config denominators stay fixed, relevant counters cannot decrease, and newly hit IDs are retained. Before/full/replay and mutant DBs remain separate; no DB is merged. GITHUB_SHA/run ID, source snapshots and complete raw artifacts are retained14days even on failure. This extension changes runner bookkeeping only; the full stimulus must remain byte-identical to the original3607cycle campaign.

Future RAL integration requirements and precise transaction mappings are in [RAL-SEQUENCE-INTEGRATION.md](RAL-SEQUENCE-INTEGRATION.md); no UVM library build or runtime is part of this job.
