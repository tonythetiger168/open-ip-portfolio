// SPDX-License-Identifier: Apache-2.0
// HBM3E_Lite_tb -- S1 8-pseudo-channel sweep / S2 pseudo-channel
// independence / S3 randomized traffic + per-bank rotation liveness /
// pc_act coverage.
`timescale 1ns/1ps
module HBM3E_Lite_tb;
  localparam integer T_RP=6, T_RCD=6, T_RAS=16, T_REFI=48;
  reg clk=0, rst_n, hvalid;
  reg [2:0] hcmd; reg [31:0] haddr; reg [15:0] hwdata;
  wire hready, hdone, irq;
  wire [15:0] hrdata;
  wire [2:0] pc_act;
  wire ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n;
  wire [1:0] ba; wire [13:0] addr;
  tri [15:0] dq; tri [1:0] dqs;
  wire trace_valid; wire [3:0] trace_cmd; wire [31:0] trace_addr;
  integer tb_err=0, cyc=0, seed=32'hBEEF;
  integer pbref_seen=0;
  reg [7:0] pc_hit = 8'h0;

  HBM3E_Lite_top #(.T_REFI(T_REFI)) dut (
    .clk(clk), .rst_n(rst_n), .hvalid(hvalid), .hready(hready), .hcmd(hcmd),
    .haddr(haddr), .hwdata(hwdata), .hrdata(hrdata), .hdone(hdone), .irq(irq),
    .pc_act(pc_act), .ck_t(ck_t), .ck_c(ck_c), .cke(cke),
    .cs_n(cs_n), .act_n(act_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .addr(addr), .dq(dq), .dqs(dqs),
    .trace_valid(trace_valid), .trace_cmd(trace_cmd), .trace_addr(trace_addr));

  always #5 clk = ~clk;
  always @(posedge clk) cyc <= cyc + 1;
  always @(posedge clk) if (rst_n) pc_hit[pc_act] <= 1'b1;

  function [15:0] data_word(input [31:0] a, input int b);
    data_word = a[15:0] ^ (16'h0101 * b[15:0]) ^ 16'h5A5A;
  endfunction
  function [31:0] mk(input [2:0] pc, input [1:0] bnk, input [8:0] row, input [2:0] ln);
    mk = {10'h0, pc, bnk, 1'b0, row, ln, 4'h0};   // [21:19]=pc [18:17]=bank
  endfunction                                        // [15:7]=row [6:4]=line

  task fe_write_line(input [31:0] a);
    begin
      @(negedge clk); hcmd <= 3'd2; haddr <= a; hvalid <= 1'b1;
      @(negedge clk); hvalid <= 1'b0;
      for (int b=0;b<8;b++) begin hwdata <= data_word(a,b); @(negedge clk); end
      wait (hdone === 1'b1); @(negedge clk);
    end
  endtask
  task fe_read_check(input [31:0] a);
    reg [15:0] got;
    begin
      @(negedge clk); hcmd <= 3'd1; haddr <= a; hvalid <= 1'b1;
      @(negedge clk); hvalid <= 1'b0;
      wait (hready === 1'b0); wait (hready === 1'b1);
      for (int b=0;b<8;b++) begin
        @(posedge clk); #1 got = hrdata;
        if (got !== data_word(a,b)) begin
          tb_err = tb_err + 1;
          $display("FAIL: rd mismatch a=%h b=%0d got=%h exp=%h cyc=%0d", a,b,got,data_word(a,b),cyc);
        end
      end
      @(negedge clk);
    end
  endtask

  integer la[0:31], lp[0:31];
  initial begin for (int i=0;i<32;i++) begin la[i]=-1000; lp[i]=-1000; end end
  wire [4:0] ent = {addr[13:11], ba};
  always @(posedge clk) if (rst_n && !cs_n) begin
    if (!act_n) begin
      if (cyc-lp[ent] < T_RP) begin tb_err=tb_err+1; $display("FAIL: tRP cyc=%0d",cyc); end
      la[ent] <= cyc;
    end else if (!ras_n && !cas_n && we_n==1'b1 && addr[10]==1'b0) begin
      pbref_seen <= pbref_seen + 1;
    end else if (!ras_n && cas_n && !we_n) begin
      if (cyc-la[ent] < T_RAS) begin tb_err=tb_err+1; $display("FAIL: tRAS cyc=%0d",cyc); end
      lp[ent] <= cyc;
    end else if (ras_n && !cas_n) begin
      if (cyc-la[ent] < T_RCD) begin tb_err=tb_err+1; $display("FAIL: tRCD cyc=%0d",cyc); end
    end
  end

  reg [31:0] r_addr, wlog[0:255]; integer wlog_n=0;
  initial begin
    rst_n=0; hvalid=0; hcmd=0; haddr=0; hwdata=0;
    repeat (6) @(negedge clk); rst_n=1; repeat (2) @(negedge clk);

    // S1: sweep all 8 pseudo-channels
    for (int p=0;p<8;p++) begin
      fe_write_line(mk(p[2:0], 2'd1, 9'h010, 3'd2));
      fe_read_check(mk(p[2:0], 2'd1, 9'h010, 3'd2));
    end
    // S2: same bank index, different PCs, different rows (independent row buf)
    fe_write_line(mk(3'd3, 2'd0, 9'h0AA, 3'd0));
    fe_write_line(mk(3'd4, 2'd0, 9'h0BB, 3'd0));   // must NOT disturb PC3
    fe_read_check(mk(3'd3, 2'd0, 9'h0AA, 3'd0));
    fe_read_check(mk(3'd4, 2'd0, 9'h0BB, 3'd0));
    // S3: randomized across PCs; 32-bank rotation refresh throughout
    wlog_n = 0;
    for (int t=0;t<100;t++) begin
      if ((t%2==0)||(wlog_n==0)) begin
        r_addr = {$random(seed)} & 32'h7FFF & ~32'hF;
        fe_write_line(r_addr); wlog[wlog_n]=r_addr; wlog_n=wlog_n+1;
      end else begin
        fe_read_check(wlog[($random(seed)&32'h7FFF_FFFF)%wlog_n]);
      end
    end
    for (int i=0;i<wlog_n;i++) fe_read_check(wlog[i]);
    if (pbref_seen < 8) begin tb_err=tb_err+1; $display("FAIL: rotation liveness %0d",pbref_seen); end
    if (pc_hit !== 8'hFF) begin tb_err=tb_err+1; $display("FAIL: pc coverage %b",pc_hit); end

    if (tb_err==0) $display("SIM_PASS: HBM3E_Lite_tb pbref=%0d pcs=%b", pbref_seen, pc_hit);
    else $display("SIM_FAIL: %0d", tb_err);
    $finish;
  end
  initial begin #3_000_000; $display("SIM_FAIL: timeout"); $finish; end
endmodule
