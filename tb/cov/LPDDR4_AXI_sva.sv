// SPDX-License-Identifier: Apache-2.0
// LPDDR4_AXI coverage checker: the core (LPDDR4_top) is closed by its own run;
// this run closes the AXI4 subordinate front end ddr_axi_slv, whose checker
// (shared with the other memory controller built on it) is bound here.
`include "ddr_axi_slv_sva.svh"
