// SPDX-License-Identifier: Apache-2.0
// GDDR7_Lite TB: 2 channels x 4 banks (haddr[9] channel, haddr[8:7] bank),
// row haddr[18:10], line haddr[6:4]. Shared host tests in
// lite_tb_common.svh (line writes with and without beat gaps, reads, row
// conflicts, MR file and programmed CL / CWL, host and auto refresh,
// rejected commands, busy, back-to-back, random traffic, reset with a read
// in flight); ip_extra adds PAM3 (BL6 symbol bus) traffic in every entry,
// lines written in one mode and read in the other, both channels, timing
// corner cases and random traffic with mode switches. The checker
// tb/cov/GDDR7_Lite_sva.sv checks every pin, including each PAM3 symbol.
`timescale 1ns/1ps
`define TB_NO_DLL
`define TB_OOR 32'h0008_0000
module GDDR7_Lite_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready, hdone, irq, pam3;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n;
  logic [1:0] ba;
  logic [13:0] addr;
  tri [31:0] dq; tri [1:0] dqs;
  logic trace_valid; logic [3:0] trace_cmd; logic [31:0] trace_addr;

  localparam int T_REFI = 400, NBANK = 8, NLINES = 8 * 512 * 8, CL0 = 11, CWL0 = 8;
  GDDR7_Lite_top #(.T_RC(40), .T_WTR(8), .T_REFI(T_REFI), .CL(CL0), .CWL(CWL0)) dut (.*);
  always #5 clk = ~clk;

  function automatic logic [31:0] mk(input int b, input int row, input int line);
    mk = $urandom;
    mk[31:19] = 0; mk[9:7] = b[2:0]; mk[18:10] = row[8:0]; mk[6:4] = line[2:0];
  endfunction
  function automatic int lidx(input logic [31:0] a);
    return int'({a[9:7], a[18:10], a[6:4]});
  endfunction
  task automatic pam(input bit on); mrw(2, {7'h0, on}); endtask
  task automatic ip_extra;
    logic [31:0] a;
    // the far rows
    wrl(mk(6, 511, 5)); rdl(mk(6, 511, 5)); rdl(mk(6, 0, 5));
    // PAM3: every entry, closed bank / hit / conflict, lines written in
    // PAM2 read back in PAM3 and the other way round
    pam(1);
    for (int b = 0; b < NBANK; b++) begin
      rdl(mk(b, 1, 0)); wrl(mk(b, 1, 2), 1); rdl(mk(b, 1, 2));
      wrl(mk(b, 5, 4)); rdl(mk(b, 5, 4)); rdl(mk(b, 1, 7));
    end
    pam(0);
    for (int b = 0; b < NBANK; b++) begin rdl(mk(b, 1, 2)); rdl(mk(b, 5, 4)); end
    // RD right after a WR (tWTR), PRE right after a WR (tWR), and a
    // conflict right after the row opened (tRC), in both modes
    for (int m = 0; m < 2; m++) begin
      pam(m[0]);
      for (int b = 0; b < NBANK; b++) begin
        wrl(mk(b, 6, 1)); rdl(mk(b, 6, 2));
        wrl(mk(b, 6, 3)); rdl(mk(b, 7, 3));
        rdl(mk(b, 8, 0)); rdl(mk(b, 9, 0));
      end
    end
    pam(0);
    // the far row and back in every entry
    for (int b = 0; b < NBANK; b++) begin
      wrl(mk(b, 511, 6)); rdl(mk(b, 511, 6)); rdl(mk(b, 0, 6));
    end
    // every MR bit both ways
    for (int i = 0; i < 8; i++) begin
      mrw(i, 8'hFF); mrr(i, 8'hFF); mrw(i, 8'h00); mrr(i, 8'h00);
    end
    mrw(0, 8'h0F); mrw(1, 8'h0F);        // CL 20, CWL 20
    for (int b = 0; b < NBANK; b++) begin
      pam(b[0]); wrl(mk(b, 4, b)); rdl(mk(b, 4, b));
    end
    mrw(0, 8'(CL0 - 5)); mrw(1, 8'(CWL0 - 5));
    // random traffic with mode switches and refreshes
    for (int k = 0; k < 300; k++) begin
      a = mk($urandom_range(0, NBANK - 1), $urandom_range(0, 3), $urandom_range(0, 7));
      case ($urandom_range(0, 11))
        0: refh();
        1: pam($urandom_range(0, 1));
        2, 3, 4, 5: rdl(a);
        default: wrl(a, $urandom_range(0, 3) == 0);
      endcase
      if ($urandom_range(0, 19) == 0) idle($urandom_range(1, T_REFI));
    end
    pam(0);
  endtask

  `include "lite_tb_common.svh"

  initial begin
    repeat (4000) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
