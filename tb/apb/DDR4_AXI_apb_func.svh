// SPDX-License-Identifier: Apache-2.0
// DDR4_AXI-specific part of tb/DDR4_AXI_apb_tb.sv: the shared DDR AXI body
// (tb/apb/ddr_axi_apb_body.svh). The core-level burst checks are in tb/DDR4_AXI_tb.sv.
`define DDR_AXI_APB_LP 0
`include "apb/ddr_axi_apb_body.svh"
`undef DDR_AXI_APB_LP
