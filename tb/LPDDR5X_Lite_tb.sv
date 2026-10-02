// SPDX-License-Identifier: Apache-2.0
// LPDDR5X_Lite_tb -- S1 basic / S2 per-bank refresh isolation / S3 FSP(DVFS)
// switch / S4 randomized traffic + rotation liveness / WCK activity check.
`timescale 1ns/1ps
module LPDDR5X_Lite_tb;
  localparam integer T_RP=6, T_RCD=6, T_RAS=16, T_REFI=64;
  reg clk=0, rst_n, hvalid;
  reg [2:0] hcmd; reg [31:0] haddr; reg [15:0] hwdata;
  wire hready, hdone, irq, fsp;
  wire [15:0] hrdata;
  wire ck_t, ck_c, cke, wck_t, wck_c, cs_n, act_n, ras_n, cas_n, we_n;
  wire [2:0] ba; wire [13:0] addr;
  tri [15:0] dq; tri [1:0] dqs;
  wire trace_valid; wire [3:0] trace_cmd; wire [31:0] trace_addr;
  integer tb_err=0, cyc=0, seed=32'hC0FFEE;
  integer wck_edges=0, wck_seen=0, pbref_seen=0;

  LPDDR5X_Lite_top #(.T_REFI(T_REFI)) dut (
    .clk(clk), .rst_n(rst_n), .hvalid(hvalid), .hready(hready), .hcmd(hcmd),
    .haddr(haddr), .hwdata(hwdata), .hrdata(hrdata), .hdone(hdone), .irq(irq),
    .fsp(fsp), .ck_t(ck_t), .ck_c(ck_c), .cke(cke), .wck_t(wck_t), .wck_c(wck_c),
    .cs_n(cs_n), .act_n(act_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .addr(addr), .dq(dq), .dqs(dqs),
    .trace_valid(trace_valid), .trace_cmd(trace_cmd), .trace_addr(trace_addr));

  always #5 clk = ~clk;
  always @(posedge clk) cyc <= cyc + 1;

  function [15:0] data_word(input [31:0] a, input int b);
    data_word = a[15:0] ^ (16'h0101 * b[15:0]) ^ 16'h5A5A;
  endfunction

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

  task fe_mrw(input [2:0] i, input [7:0] v);
    begin
      @(negedge clk); hcmd <= 3'd3; haddr <= {29'h0,i}; hwdata <= {8'h0,v}; hvalid <= 1'b1;
      @(negedge clk); hvalid <= 1'b0; wait (hdone === 1'b1); @(negedge clk);
    end
  endtask
  task fe_mrr(input [2:0] i, input [7:0] e);
    begin
      @(negedge clk); hcmd <= 3'd4; haddr <= {29'h0,i}; hvalid <= 1'b1;
      @(negedge clk); hvalid <= 1'b0; wait (hdone === 1'b1); #1;
      if (hrdata[7:0] !== e) begin tb_err=tb_err+1; $display("FAIL: MRR %0d got=%h exp=%h",i,hrdata[7:0],e); end
      @(negedge clk);
    end
  endtask
  task fe_pbref(input [2:0] bnk);
    begin
      @(negedge clk); hcmd <= 3'd6; haddr <= {20'h0,bnk,7'h0}; hvalid <= 1'b1;
      @(negedge clk); hvalid <= 1'b0; wait (hdone === 1'b1); @(negedge clk);
    end
  endtask
  task fe_fspw(input v);
    begin
      @(negedge clk); hcmd <= 3'd7; haddr <= 32'h0; hwdata <= {15'h0,v[0]}; hvalid <= 1'b1;
      @(negedge clk); hvalid <= 1'b0; wait (hdone === 1'b1); @(negedge clk);
    end
  endtask

  // minimal timing monitor: tRP (PRE->ACT), tRAS (ACT->PRE), tRCD
  integer la[0:7], lp[0:7];
  initial begin for (int i=0;i<8;i++) begin la[i]=-1000; lp[i]=-1000; end end
  always @(posedge clk) if (rst_n && !cs_n) begin
    if (!act_n) begin
      if (cyc-lp[ba] < T_RP)  begin tb_err=tb_err+1; $display("FAIL: tRP cyc=%0d",cyc); end
      la[ba] <= cyc;
    end else if (!ras_n && !cas_n && addr[10]==1'b0 && we_n==1'b0) begin
      ; // PRE: checked via la on next ACT
    end else if (!ras_n && !cas_n && we_n==1'b1) begin
      if (addr[10]==1'b0) pbref_seen <= pbref_seen + 1;
    end else if (!ras_n && cas_n && !we_n) begin
      if (cyc-la[ba] < T_RAS) begin tb_err=tb_err+1; $display("FAIL: tRAS cyc=%0d",cyc); end
      lp[ba] <= cyc;
    end else if (ras_n && !cas_n) begin
      if (cyc-la[ba] < T_RCD) begin tb_err=tb_err+1; $display("FAIL: tRCD cyc=%0d",cyc); end
    end
  end

  // WCK activity: must toggle while a write burst is on dq
  reg wck_d = 1'b1;
  always @(posedge clk) if (rst_n) begin
    if (wck_t !== wck_d) begin wck_edges <= wck_edges + 1; wck_d <= wck_t; end
    if (dut.dq_oe === 1'b1 && dut.eng_we === 1'b1) wck_seen <= 1'b1;
  end

  reg [31:0] r_addr, wlog[0:255]; integer wlog_n=0;
  initial begin
    rst_n=0; hvalid=0; hcmd=0; haddr=0; hwdata=0;
    repeat (6) @(negedge clk); rst_n=1; repeat (2) @(negedge clk);

    // S1
    fe_write_line(32'h0); fe_read_check(32'h0);
    // S2: open rows in bank0 & bank5, PBREF bank0, bank5 must stay open (hit path)
    // address = (row<<10) | (bank<<7) | (line<<4)
    fe_write_line((32'd3<<10)|(32'd0<<7));
    fe_write_line((32'd7<<10)|(32'd5<<7));
    fe_pbref(3'd0);
    fe_read_check((32'd7<<10)|(32'd5<<7));   // bank5 untouched by PBREF
    fe_read_check((32'd3<<10)|(32'd0<<7));   // bank0 data survives its refresh
    // S3: DVFS -- program FSP0, switch to FSP1, verify
    fe_mrw(3'd0, 8'h04);   // writes FSP0 (active)
    fe_fspw(1'b1);         // switch to FSP1 (reset defaults CL=11,CWL=8)
    if (fsp !== 1'b1) begin tb_err=tb_err+1; $display("FAIL: fsp not 1"); end
    fe_mrr(3'd0, 8'h06);   // FSP1 MR0 default = CL-5 = 6
    fe_mrw(3'd1, 8'h02);   // FSP1 CWL = 7
    fe_write_line((32'd1<<10)|(32'd2<<7));
    fe_read_check((32'd1<<10)|(32'd2<<7));
    fe_fspw(1'b0);         // back to FSP0: MR0=0x04 (CL=9)
    fe_mrr(3'd0, 8'h04);
    // S4: randomized traffic; per-bank rotation refresh runs throughout
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
    if (pbref_seen < 8) begin tb_err=tb_err+1; $display("FAIL: pbref liveness %0d",pbref_seen); end
    if (!wck_seen || wck_edges < 16) begin tb_err=tb_err+1; $display("FAIL: WCK inactive"); end

    if (tb_err==0) $display("SIM_PASS: LPDDR5X_Lite_tb pbref=%0d wck_edges=%0d", pbref_seen, wck_edges);
    else $display("SIM_FAIL: %0d", tb_err);
    $finish;
  end
  initial begin #3_000_000; $display("SIM_FAIL: timeout"); $finish; end
endmodule
