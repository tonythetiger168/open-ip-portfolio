# AI-EDA external regression follow-up — 2026-11-07

This tracks historical results at `e6a39a36d131c916688735a9874dfafb30474203` (129 IPs), not the current 142-IP main. No current-main RTL failure or closure claim is made.

## HDCP core coverage build: resource failure, not demonstrated RTL mismatch

The LF-normalized portfolio coverage run attempted 258 core/wrapper targets: 257 reported closed; HDCP_2_3_Content_Protection failed during C++ compilation. The earlier CRLF-contaminated batch was invalid and is excluded.

Verilator 5.052 emitted:
```text
g++: fatal error: Killed signal terminated program cc1plus
make: *** [.../verilated.mk:293: Vtop_vm_classes_3.o] Error 1
%Error: 'make -C work/cov/HDCP_2_3_Content_Protection/obj -f Vtop.mk -j 4' exited with 2
```
The invocation contained both `-j 4` and a later `-j 1`; generated make still used four jobs. Do not infer an RTL bug or OOM-killer attribution solely from SIGKILL.

Archived compressed build-log SHA256: `f40fe459bfdc18d93148fc0e7ce5e4aef8d9e5395e1a3adff3f88d83a41ee07b`.
Local archive: Helios `build/portfolio-extended-20261101/ip-coverage/HDCP_2_3_Content_Protection/evidence/build.log.gz`. This local artifact is not published by this PR.

Follow-up acceptance:
- [ ] Pin current main and tool versions; record source differences from the historical revision.
- [ ] Run `bash scripts/cov/run_cov.sh HDCP_2_3_Content_Protection` in a controlled single-target environment with all job flags normalized to one; capture effective compiler argv, resource limits, exit code and complete logs.
- [ ] Preserve SVA and functional covergroups. Report each coverage denominator and exclusions; never turn build failure into zero-bin closure.
- [ ] If the build completes, validate nonempty simulation/checker results and inspect remaining gaps. If it is killed again, retain resource-limited status and measured resource evidence.
- [ ] Keep HDCP's separate Icarus timeout investigation distinct (see existing PR #6).

## Historical baseline cases requiring controlled re-evaluation

At the same pinned revision: sim 128 pass / UCIe timeout; synthesis 126 pass / HBM4 and HBM5 timeout / Toggle_Mode_NAND resource_limited; APB 123 pass / Ethernet_PCS, Ethernet_RS_FEC, HBM3E, HBM4, HBM5 timeout / Toggle_Mode_NAND resource_limited.

These are execution outcomes, not confirmed functional defects. Baseline tools were Icarus 12.0, Yosys 0.52 and Verilator 5.032; current README calls for Icarus 13.0. Reproduce on supported tools before proposing RTL changes.

- [ ] Re-evaluate each timeout with bounded per-target budgets, progress logs and supported tools; classify tool/version/resource/testbench/RTL causes separately.
- [ ] Preserve original outcomes and attach new evidence rather than rewriting the baseline.

Minisim's historical 129 unsupported results are frontend limitations and are not upstream IP failures. VIP-only I2C bench changes belong to open-vip-portfolio, not this repository.
