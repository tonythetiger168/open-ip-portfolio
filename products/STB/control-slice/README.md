# STB control conformance slice

2026-11-02. **Executable real-RTL bench, limited control-plane verification.** Not an integrated STB SoC, UVM environment, native coverage report or physical signoff. No production missing IP is replaced with a stub.

Run from the product workspace: `python products/STB/control-slice/run.py`. Supports native Linux Python or Windows Python with Ubuntu WSL, with qualified Icarus12.0/vvp. Standard-library scoreboard; no network access or credentials needed for replay. Optimized Python is rejected so checker assertions cannot silently disappear. Original Apache-2.0 source headers are retained. `sources.json` pins Git blobs/commits, checked before every run; `evidence/result.json` records exact commands, Python/tool versions, source/harness hashes, seeds, hierarchy, parameters and hashed raw artifacts. The runner fails on compile/simulation errors, missing cycles, scoreboard mismatches, absent scenario witnesses or surviving mutants. Compiler constant-select warnings remain in build logs.

CI publication: open-ip-portfolio, branch codex/stb-control-conformance-20261102, based on main46f6ec5cb03c33785a7c7d6f168d904c4e8d5b31. Only products/STB/control-slice/, a dedicated .github/workflows/stb-control-conformance.yml and docs/progress/stb-control-ci.md are added. The workflow runs Ubuntu24.04/Python3.12, rejects nonqualified Icarus versions, preserves warnings and uploads raw evidence even on failure. No native coverage thresholds or unrelated workflows change. Raw generated artifacts are uploaded, not committed. source-freshness.json records review against current main and PR22/27 path checks; source pins are frozen and the router remains an unmerged prototype.

## Contract and real hierarchy

| Instance | Source and scope |
|---|---|
| `control_slice_tb.u_router` | Unchanged `apb_window_router` prototype from open-ip-portfolio PR22 head c05c902f7eeaeb2587c447e08670203999741580, blob20b2e9ed9d437707130c0e6162a85a9e7b805b7c; proposed, not merged production fabric |
| `u_reg0`, `u_reg1` | Unchanged `AXI4_Lite_apb` from main e6a39a36d131c916688735a9874dfafb30474203 |
| `u_reg0.u_core`, `u_reg1.u_core` | Real `AXI4_Lite_top` memory-subordinate cores from the same main; AXI requests tied idle, response ready high; AXI traffic/ordering/DMA are not tested |

Filelist: rtl/apb_window_router.sv, rtl/AXI4_Lite_top.sv, rtl/AXI4_Lite_apb.sv, control_slice_tb.sv. Single 10ns bench PCLK; active-low asynchronous reset asserted/released at negative edges. No CDC, power or SKU frequency claim. Test-only windows are [0x10000000,0x10001000) and [0x10001000,0x10002000); overlap configuration intentionally assigns both to the first interval. These are not frozen SoC physical addresses. Full32-bit upstream address must match exactly one interval and be word-aligned before forwarding the low12bits. Unmapped/misaligned/overlap accesses complete with error and select no child. PPROT forwards unchanged; this is not an authorization/firewall policy.

Each real wrapper is zero-wait: offsets0/4/8/12/16 expose ID/pending IRQ/enable/flags/scratch; other aligned offsets return child error. ID=0x414c0200; flags/pending IRQ remain zero with idle AXI. Scratch writes honor four independent PSTRB byte lanes; enable bit0 honors lane0. No injected IRQ/priority/W1C-race claim. State belongs independently to each endpoint. Reset clears scratch/enable, suppresses router outputs and cancels a prepared, unaccepted write. The bench does not test accepted AXI draining or reset epochs across outstanding memory traffic.

## Independent checking and actual result

The stimulus file contains only driver controls. A separate passive monitor emits actual input/child/output wires at each rising edge before NBA register updates. Python independently checks an interval-based route oracle, byte-array CSR state, read values, forwarding, error responses, reset behavior and APB setup/access stability. The scoreboard imports no RTL/parser/reference model. A separate driver-consumption check compares monitor inputs with intended stimulus and requires exactly one observed row per cycle.

Three fixed seeds (1,17,20261102), each in normal and overlapping-window configurations: **6/6 PASS,4448observed cycles**. Normal runs require witnesses for both endpoints, all16strobes/all8PPROT values, setup/idle/reset, high-address holes, child holes, misalignment and read comparisons. Back-to-back transfers, independent scratch state, rejected writes followed by readback and reset during setup are exercised. These counters are software campaign witnesses, not native functional coverage or a 100% claim.

Nine sensitivity checks detected: seven altered-observation cases (wrong route/read byte/reset ready/strobe/write/protection and lost cycle), plus two genuinely compiled RTL mutants (ignore address bit31; forward unaligned requests). Mutant traces and first mismatch witnesses are separate from six passing baseline runs. Trace mutation proves checker sensitivity to observations; it does not prove all possible DUT faults are detectable.

Canonical requirement evidence is partial: STB-001 full-address routing for this two-window fixture; STB-002 APB strobe subset only, no AXI-Lite AW/W test; STB-003 CSR/reset subset only, no full codec RAL/IRQ; STB-022 bounded checker/replay qualification. The 22-requirement SoC matrix remains PLANNED/NOT_RUN. Native line/FSM-state+arc/toggle-both-directions/branch/SVA-nonvacuity/functional measurements are all NOT_MEASURED for this slice. No exclusions or replacement coverage numbers.

Next: extend the existing checker with independently observed real AXI transactions and IRQ events when selected interfaces are approved; bind qualified UVM monitors/SVA to this exact hierarchy; qualify each native metric separately. Full SoC CPU/map/firmware/media/security/PHY dependencies remain blocked. PR22 consumer adoption and production map/timing are still proposals.
