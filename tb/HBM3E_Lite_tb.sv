// SPDX-License-Identifier: Apache-2.0
// HBM3E_Lite TB: 32 entries = 8 pseudo-channels (haddr[11:9]) x 4 banks
// (haddr[8:7]), row haddr[20:12], line haddr[6:4]; per-entry refresh every
// tREFI = 150 clocks (a full rotation every 4800), host all-entry refresh.
// Shared host tests in lite_tb_common.svh (line writes with and without
// beat gaps, reads, row conflicts, MR file and programmed CL / CWL, host
// and auto refresh, rejected commands, busy, back-to-back, random traffic,
// reset with a read in flight); the checker tb/cov/HBM3E_Lite_sva.sv checks
// every pin, the per-entry refresh rotation and pc_act.
`timescale 1ns/1ps
`define TB_NO_DLL
`define TB_OOR 32'h0020_0000
module HBM3E_Lite_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready, hdone, irq;
  logic [2:0] pc_act;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic [127:0] rdline;
  logic ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n;
  logic [1:0] ba;
  logic [13:0] addr;
  tri [15:0] dq; tri [1:0] dqs;
  logic trace_valid; logic [3:0] trace_cmd; logic [31:0] trace_addr;

  localparam int T_REFI = 150, NBANK = 32, NLINES = 32 * 512 * 8, CL0 = 11, CWL0 = 8;
  HBM3E_Lite_top #(.T_RC(40), .T_WTR(8), .T_REFI(T_REFI), .CL(CL0), .CWL(CWL0)) dut (.*);
  always #5 clk = ~clk;

`ifndef VERILATOR
  // refresh overrun: with tREFI = 1 an entry falls due again before the
  // engine has served it, which must set the sticky irq. A second, idle
  // instance (Icarus only: the bound checker models the main instance's
  // timing). Its irq stays low through reset and rises within a rotation.
  logic o_hready, o_hdone, o_irq, o_ck_t, o_ck_c, o_cke, o_cs_n, o_act_n, o_ras_n, o_cas_n, o_we_n;
  logic o_tv; logic [3:0] o_tc; logic [31:0] o_ta; logic [2:0] o_pc;
  logic [15:0] o_hrdata; logic [127:0] o_rdline; logic [1:0] o_ba; logic [13:0] o_addr;
  tri [15:0] o_dq; tri [1:0] o_dqs;
  HBM3E_Lite_top #(.T_REFI(1)) dut_ovr (
    .clk(clk), .rst_n(rst_n), .hvalid(1'b0), .hready(o_hready), .hcmd(3'd0), .haddr(32'd0),
    .hwdata(16'd0), .hrdata(o_hrdata), .rdline(o_rdline), .hdone(o_hdone), .irq(o_irq),
    .pc_act(o_pc), .ck_t(o_ck_t), .ck_c(o_ck_c), .cke(o_cke), .cs_n(o_cs_n), .act_n(o_act_n),
    .ras_n(o_ras_n), .cas_n(o_cas_n), .we_n(o_we_n), .ba(o_ba), .addr(o_addr), .dq(o_dq),
    .dqs(o_dqs), .trace_valid(o_tv), .trace_cmd(o_tc), .trace_addr(o_ta));
  initial begin
    @(posedge rst_n);
    if (o_irq !== 1'b0) begin errors++; $display("ERROR: overrun irq set in reset"); end
    repeat (32 * 40) @(posedge clk);
    if (o_irq !== 1'b1) begin errors++; $display("ERROR: no irq on a refresh overrun"); end
  end
`endif

  function automatic logic [31:0] mk(input int b, input int row, input int line);
    mk = $urandom;
    mk[31:21] = 0; mk[11:7] = b[4:0]; mk[20:12] = row[8:0]; mk[6:4] = line[2:0];
  endfunction
  function automatic int lidx(input logic [31:0] a);
    return int'({a[11:7], a[20:12], a[6:4]});
  endfunction
  task automatic ip_extra;
    // the far rows
    wrl(mk(31, 511, 5)); rdl(mk(31, 511, 5)); rdl(mk(31, 0, 5));
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
    for (int b = 0; b < NBANK; b++) begin wrl(mk(b, 4, b % 8)); rdl(mk(b, 4, b % 8)); end
    mrw(0, 8'(CL0 - 5)); mrw(1, 8'(CWL0 - 5));
    // a full refresh rotation with every entry left open
    for (int b = 0; b < NBANK; b++) rdl(mk(b, 12, 0));
    idle(T_REFI * NBANK + 200);
  endtask

  `include "lite_tb_common.svh"

  initial begin
    repeat (8000) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
