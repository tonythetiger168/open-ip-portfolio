// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DDR: single-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=17,
// NCH=1). Educational slice of DDR3-generation SDRAM timing
// (CL=5, tRCD=5, tRP=5). Ports identical to family sibling DDR4_top;
// gem5 trace port unchanged. MEMCORE_top is not modified; PROTOCOL=17 is a
// family tag only (MEMCORE timing is fully parameterized via CL/TRCD/TRP).
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module DDR_top (
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
  MEMCH_top #(.PROTOCOL(17), .NCH(1), .CL(5), .TRCD(5), .TRP(5)) core (.*);
endmodule
