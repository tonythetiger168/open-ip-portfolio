// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// LPDDR: single-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=18,
// NCH=1). Educational slice of LPDDR1/2-generation SDRAM timing
// (CL=3, tRCD=3, tRP=3). Ports identical to family sibling DDR4_top
// (addr/ras_n/cas_n/we_n command bus, not the LPDDR4 CA bus); gem5 trace
// port unchanged. MEMCORE_top is not modified; PROTOCOL=18 is a family tag
// only (MEMCORE timing is fully parameterized via CL/TRCD/TRP).
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module LPDDR_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
  output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [15:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(18), .NCH(1), .CL(3), .TRCD(3), .TRP(3)) core (.*);
endmodule
