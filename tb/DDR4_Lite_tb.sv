// SPDX-License-Identifier: Apache-2.0
// DDR4_Lite TB: 4 banks (haddr[8:7]), row haddr[17:9], line haddr[6:4].
// Shared host tests in lite_tb_common.svh (line writes with and without
// beat gaps, reads, row conflicts, MR file and programmed CL / CWL, host
// and auto refresh, rejected commands, busy, back-to-back, random traffic,
// reset with a read in flight); the checker tb/cov/DDR4_Lite_sva.sv checks
// every pin.
`timescale 1ns/1ps
module DDR4_Lite_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready, hdone, irq;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic [127:0] rdline;
  logic ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n;
  logic [1:0] ba;
  logic [13:0] addr;
  tri [15:0] dq; tri [1:0] dqs;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;

  localparam int T_REFI = 400, NBANK = 4, NLINES = 4 * 512 * 8, CL0 = 11, CWL0 = 8;
  DDR4_Lite_top #(.T_RC(40), .T_WTR(8), .T_REFI(T_REFI), .CL(CL0), .CWL(CWL0)) dut (.*);
  always #5 clk = ~clk;

  function automatic logic [31:0] mk(input int b, input int row, input int line);
    mk = $urandom;
    mk[31:18] = 0; mk[8:7] = b[1:0]; mk[17:9] = row[8:0]; mk[6:4] = line[2:0];
  endfunction
  function automatic int lidx(input logic [31:0] a);
    return int'({a[8:7], a[17:9], a[6:4]});
  endfunction
  task automatic ip_extra;
    // the far rows
    wrl(mk(2, 511, 5)); rdl(mk(2, 511, 5)); rdl(mk(2, 0, 5));
    // RD right after a WR (tWTR), PRE right after a WR (tWR), and a
    // conflict right after the row opened (tRC)
    for (int b = 0; b < NBANK; b++) begin
      wrl(mk(b, 6, 1)); rdl(mk(b, 6, 2));
      wrl(mk(b, 6, 3)); rdl(mk(b, 7, 3));
      rdl(mk(b, 8, 0)); rdl(mk(b, 9, 0));
    end
    // the far row and back in every bank
    for (int b = 0; b < NBANK; b++) begin
      wrl(mk(b, 511, 6)); rdl(mk(b, 511, 6)); rdl(mk(b, 0, 6));
    end
    // every MR bit both ways
    for (int i = 0; i < 8; i++) begin
      mrw(i, 8'hFF); mrr(i, (i == 0) ? 8'h7F : 8'hFF); mrw(i, 8'h00); mrr(i, 8'h00);
    end
    mrw(0, 8'h0F); mrw(1, 8'h0F);        // CL 20, CWL 20
    for (int b = 0; b < NBANK; b++) begin wrl(mk(b, 4, b)); rdl(mk(b, 4, b)); end
    mrw(0, 8'(CL0 - 5)); mrw(1, 8'(CWL0 - 5));
  endtask

  `include "lite_tb_common.svh"

  initial begin
    repeat (2000) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
