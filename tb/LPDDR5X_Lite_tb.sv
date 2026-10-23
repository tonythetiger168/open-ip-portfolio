// SPDX-License-Identifier: Apache-2.0
// LPDDR5X_Lite TB: 8 banks (haddr[9:7]), row haddr[18:10], line
// haddr[6:4]; per-bank refresh every tREFI = 150 clocks (a full rotation
// every 1200). Shared host tests in lite_tb_common.svh (line writes with
// and without beat gaps, reads, row conflicts, MR file and programmed CL /
// CWL, host and auto refresh, rejected commands, busy, back-to-back,
// random traffic, reset with a read in flight); ip_extra adds host bank
// refresh to open and closed banks, FSP switching with different CL / CWL
// per set, timing corner cases and a full refresh rotation with every bank
// open. The checker tb/cov/LPDDR5X_Lite_sva.sv checks every pin, WCK and
// the refresh rotation.
`timescale 1ns/1ps
`define TB_NO_DLL
`define TB_OOR 32'h0008_0000
`define TB_NO_BAD_CMD
module LPDDR5X_Lite_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready, hdone, irq;
  logic fsp;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic ck_t, ck_c, cke, wck_t, wck_c, cs_n, act_n, ras_n, cas_n, we_n;
  logic [2:0] ba;
  logic [13:0] addr;
  tri [15:0] dq; tri [1:0] dqs;
  logic trace_valid; logic [3:0] trace_cmd; logic [31:0] trace_addr;

  localparam int T_REFI = 150, NBANK = 8, NLINES = 8 * 512 * 8, CL0 = 11, CWL0 = 8;
  LPDDR5X_Lite_top #(.T_RC(40), .T_WTR(8), .T_REFI(T_REFI), .CL(CL0), .CWL(CWL0)) dut (.*);
  always #5 clk = ~clk;

  function automatic logic [31:0] mk(input int b, input int row, input int line);
    mk = $urandom;
    mk[31:19] = 0; mk[9:7] = b[2:0]; mk[18:10] = row[8:0]; mk[6:4] = line[2:0];
  endfunction
  function automatic int lidx(input logic [31:0] a);
    return int'({a[9:7], a[18:10], a[6:4]});
  endfunction
  task automatic fspw(input bit f); cmd(3'd7, $urandom, {15'($urandom), f}); wait_done(); @(negedge clk); endtask
  task automatic ip_extra;
    // the far rows
    wrl(mk(7, 511, 5)); rdl(mk(7, 511, 5)); rdl(mk(7, 0, 5));
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
      mrw(i, 8'hFF); mrr(i, 8'hFF); mrw(i, 8'h00); mrr(i, 8'h00);
    end
    mrw(0, 8'h0F); mrw(1, 8'h0F);        // CL 20, CWL 20
    for (int b = 0; b < NBANK; b++) begin wrl(mk(b, 4, b)); rdl(mk(b, 4, b)); end
    mrw(0, 8'(CL0 - 5)); mrw(1, 8'(CWL0 - 5));
    // host bank refresh: every bank open, then closed; a write right after
    for (int b = 0; b < NBANK; b++) begin
      rdl(mk(b, 13, 1)); imm(3'd6, mk(b, 0, 0)); imm(3'd6, mk(b, 0, 0));
      wrl(mk(b, 13, 2)); rdl(mk(b, 13, 2));
    end
    // FSP1: its own CL / CWL and MR contents; FSP0 keeps its values
    fspw(1);
    mrr(0, 8'(CL0 - 5)); mrw(0, 8'h01); mrw(1, 8'h0D); mrw(5, 8'hA5); mrr(5, 8'hA5);
    for (int b = 0; b < NBANK; b++) begin wrl(mk(b, 14, b)); rdl(mk(b, 14, b)); end
    fspw(1);                              // no change
    fspw(0);
    mrr(0, 8'(CL0 - 5)); mrr(5, 8'h00);
    for (int b = 0; b < NBANK; b++) rdl(mk(b, 14, b));
    fspw(1); mrr(0, 8'h01); mrr(1, 8'h0D);
    for (int k = 0; k < 40; k++) begin
      if ($urandom_range(0, 3) == 0) fspw($urandom_range(0, 1));
      if ($urandom_range(0, 1)) wrl(rnd_addr(), $urandom_range(0, 1)); else rdl(rnd_addr());
      if ($urandom_range(0, 7) == 0) imm(3'd6, rnd_addr());
    end
    // every FSP1 MR bit both ways, then its reset values back
    fspw(1);
    for (int i = 0; i < 8; i++) begin
      mrw(i, 8'hFF); mrr(i, 8'hFF); mrw(i, 8'h00); mrr(i, 8'h00);
    end
    mrw(0, 8'(CL0 - 5)); mrw(1, 8'(CWL0 - 5)); fspw(0);
    // a full refresh rotation with every bank left open
    for (int b = 0; b < NBANK; b++) rdl(mk(b, 12, 0));
    idle(T_REFI * NBANK + 200);
  endtask

  `include "lite_tb_common.svh"

  initial begin
    repeat (8000) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
