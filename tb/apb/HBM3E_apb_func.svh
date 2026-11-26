// SPDX-License-Identifier: Apache-2.0
// HBM3E-specific part of tb/HBM3E_apb_tb.sv: the address map of the core; the
// tests are the shared tb/apb/mem_apb_common.svh.
localparam int NBU = 256;
function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
  mk = $urandom;
  mk[31:18] = row; mk[10:8] = b[7:5]; mk[15:11] = b[4:0]; mk[7:0] = col;
endfunction
function automatic int cellof(input logic [31:0] a);
  cellof = {a[10:8], a[7:0]};
endfunction
// DRAM device (tb/mem_dev.svh): the core keeps no array of its own
localparam int NCH = 8;
`define MEM_DEV_RD ({ras_n, cas_n, we_n} == 3'b101)
`define MEM_DEV_WR ({ras_n, cas_n, we_n} == 3'b100)
`define MEM_DEV_CL 12
`define MEM_DEV_CH(a) int'(a[10:8])
`define MEM_DEV_X ecc
`define MEM_DEV_XW 5
`include "apb/mem_apb_common.svh"
// every channel's ecc check-bit lanes both ways: 0x0818 encodes to check
// bits 5'b11111, 0x0000 to 5'b00000 (channel = entry bits 7:5)
task automatic ip_func;
  mem_func();
  for (int ch = 0; ch < 8; ch++) begin
    m_wr(mk(32 * ch, 14'h5, 8'h31), 16'h0818); m_rd(mk(32 * ch, 14'h5, 8'h31));
    m_wr(mk(32 * ch, 14'h5, 8'h31), 16'h0000); m_rd(mk(32 * ch, 14'h5, 8'h31));
  end
endtask
