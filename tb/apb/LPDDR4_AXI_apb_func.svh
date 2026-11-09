// SPDX-License-Identifier: Apache-2.0
// LPDDR4_AXI-specific part of tb/LPDDR4_AXI_apb_tb.sv: the shared DDR AXI body
// (tb/apb/ddr_axi_apb_body.svh). The core-level burst checks are in tb/LPDDR4_AXI_tb.sv.
`define DDR_AXI_APB_LP 1
`include "apb/ddr_axi_apb_body.svh"
`undef DDR_AXI_APB_LP
