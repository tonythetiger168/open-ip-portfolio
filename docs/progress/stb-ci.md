# STB CI repair: PR13 coverage stimuli

2026-11-01, Asia/Taipei. Parent PR13 head: 725bc9161f7e277107b0a00ed8eb865639630509. This bounded patch is intended for PR13's branch, not a second copy of its 11-IP feature changes against main.

Original run: https://github.com/tonythetiger168/open-ip-portfolio/actions/runs/41103390842 (shards3,5,6). Functional reset-with-pending-IRQ holes affect IO_LINK_apb, MIL_STD_1553_apb and RAPIDIO_apb; MIL_STD_1553 additionally misses seven falling input toggles. Same-head regression/mutation succeeded. Main e6a39a36 does not include these three new IPs, so its green coverage cannot substitute.

Four testbenches now create real pending enabled interrupts before the existing reset-value/readback checks, and sweep idle host/configuration inputs in both directions using valid RT addresses30,1,0 before restoring the original configuration. No DUT, checker, exclusion, threshold, scoring or workflow change.

Actual validation: Icarus12 MIL core and all three APB testbenches passed. Constant-select warnings are retained in raw build logs. The first new MIL APB trial failed because the preceding test restored RT mode; the test now explicitly sets BC mode before the status transaction and passes. Native Verilator5.052 seed1 baseline/fixed comparison is an additional required gate; its current results and raw evidence are tracked in the repair PR description and STB product CI checkpoint. This is per-IP five-metric legacy coverage, not six-category SoC UVM signoff or physical verification.

Local source/build/run evidence is retained in the STB product workspace. Coverage workflow on the repair draft remains a separate required result; no blind rerun of the old failing head, no threshold reduction or waiver was introduced.
