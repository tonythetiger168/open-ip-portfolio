# SPDX-License-Identifier: Apache-2.0
# Coverage-only unit: the shared AXI4 manager engine of the SoC subsystem IPs
# (rtl/soc_ss_axi_engine.sv). It has no release package or APB wrapper; it is
# closed here once, with its own testbench (tb/soc_ss_axi_engine_tb.sv) and
# checker, and every IP that uses it lists it under COVLIB.
#   bash scripts/cov/run_cov.sh soc_ss_axi_engine
S      := soc_ss_axi_engine
DEPS   :=
