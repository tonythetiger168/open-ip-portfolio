// SPDX-License-Identifier: Apache-2.0
// GDDR7_Lite_tb -- S1 PAM2 round trip / S2 PAM3 mode (LUT encode+decode via
// data integrity, BL6 burst count on the symbol bus) / S3 dual channel /
// S4 mode switch back.
`timescale 1ns/1ps
module GDDR7_Lite_tb;
  localparam integer T_RP=6, T_RCD=6, T_RAS=16, T_REFI=64;
  reg clk=0, rst_n, hvalid;
  reg [2:0] hcmd; reg [31:0] haddr; reg [15:0] hwdata;
  wire hready, hdone, irq, pam3;
  wire [15:0] hrdata;
  wire ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n;
  wire [1:0] ba; wire [13:0] addr;
  tri [31:0] dq; tri [1:0] dqs;
  wire trace_valid; wire [3:0] trace_cmd; wire [31:0] trace_addr;
  integer tb_err=0, cyc=0, seed=32'hD00D;
  integer burst_beats=0, burst_len_err=0;

  GDDR7_Lite_top #(.T_REFI(T_REFI)) dut (
    .clk(clk), .rst_n(rst_n), .hvalid(hvalid), .hready(hready), .hcmd(hcmd),
    .haddr(haddr), .hwdata(hwdata), .hrdata(hrdata), .hdone(hdone), .irq(irq),
    .pam3(pam3), .ck_t(ck_t), .ck_c(ck_c), .cke(cke),
    .cs_n(cs_n), .act_n(act_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .addr(addr), .dq(dq), .dqs(dqs),
    .trace_valid(trace_valid), .trace_cmd(trace_cmd), .trace_addr(trace_addr));

  always #5 clk = ~clk;
  always @(posedge clk) cyc <= cyc + 1;

  function [15:0] data_word(input [31:0] a, input int b);
    data_word = a[15:0] ^ (16'h0101 * b[15:0]) ^ 16'h5A5A;
  endfunction
  function [31:0] mk(input ch, input [1:0] bnk, input [8:0] row, input [2:0] ln);
    mk = {13'h0, row, ch, bnk, ln, 4'h0};   // [18:10]=row [9]=ch [8:7]=bank
  endfunction                                // [6:4]=line

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

  // burst-length monitor: count dq-driven beats per burst, expect 8 (PAM2)
  // or 6 (PAM3); trit lanes [31:16] must be Z in PAM2
  reg dq_driven = 0;
  always @(posedge clk) if (rst_n) begin
    if (dut.dq_oe === 1'b1) begin
      if (!dq_driven) begin dq_driven <= 1'b1; burst_beats <= 1; end
      else burst_beats <= burst_beats + 1;
      if (!pam3 && dq[31:16] !== 16'hzzzz) begin
        tb_err = tb_err + 1; $display("FAIL: PAM2 upper lanes driven");
      end
    end else if (dq_driven) begin
      dq_driven <= 1'b0;
      if ((pam3 && burst_beats != 6) || (!pam3 && burst_beats != 8)) begin
        tb_err = tb_err + 1;
        $display("FAIL: burst len %0d in mode pam3=%b cyc=%0d", burst_beats, pam3, cyc);
      end
    end
  end

  integer la[0:7], lp[0:7];
  initial begin for (int i=0;i<8;i++) begin la[i]=-1000; lp[i]=-1000; end end
  wire [3:0] ent = {addr[11], ba};
  always @(posedge clk) if (rst_n && !cs_n) begin
    if (!act_n) begin
      if (cyc-lp[ent] < T_RP) begin tb_err=tb_err+1; $display("FAIL: tRP"); end
      la[ent] <= cyc;
    end else if (!ras_n && cas_n && !we_n) begin
      if (cyc-la[ent] < T_RAS) begin tb_err=tb_err+1; $display("FAIL: tRAS"); end
      lp[ent] <= cyc;
    end else if (ras_n && !cas_n) begin
      if (cyc-la[ent] < T_RCD) begin tb_err=tb_err+1; $display("FAIL: tRCD"); end
    end
  end

  reg [31:0] r_addr, wlog[0:255]; integer wlog_n=0;
  initial begin
    rst_n=0; hvalid=0; hcmd=0; haddr=0; hwdata=0;
    repeat (6) @(negedge clk); rst_n=1; repeat (2) @(negedge clk);

    // S1: PAM2 (reset default) round trip
    fe_write_line(mk(1'b0, 2'd1, 9'h05, 3'd3));
    fe_read_check(mk(1'b0, 2'd1, 9'h05, 3'd3));
    // S2: PAM3 on -- round trip proves encoder+decoder end to end
    fe_mrw(3'd0, 8'h07);            // MR0: CL=12, pam3=1
    if (pam3 !== 1'b1) begin tb_err=tb_err+1; $display("FAIL: pam3 not set"); end
    fe_write_line(mk(1'b1, 2'd2, 9'h011, 3'd0));
    fe_read_check(mk(1'b1, 2'd2, 9'h011, 3'd0));
    fe_write_line(mk(1'b0, 2'd0, 9'h020, 3'd7));
    fe_read_check(mk(1'b0, 2'd0, 9'h020, 3'd7));
    // S3: randomized traffic in PAM3
    wlog_n = 0;
    for (int t=0;t<60;t++) begin
      if ((t%2==0)||(wlog_n==0)) begin
        r_addr = {$random(seed)} & 32'h7FFF & ~32'hF;
        fe_write_line(r_addr); wlog[wlog_n]=r_addr; wlog_n=wlog_n+1;
      end else begin
        fe_read_check(wlog[($random(seed)&32'h7FFF_FFFF)%wlog_n]);
      end
    end
    for (int i=0;i<wlog_n;i++) fe_read_check(wlog[i]);
    // S4: back to PAM2; previously written PAM3 data is re-read through
    // the PAM2 path (mem holds the trit image -- read path decodes per
    // CURRENT mode, so this read checks mode-switch data consistency)
    fe_mrw(3'd0, 8'h06);            // pam3=0
    fe_read_check(mk(1'b1, 2'd2, 9'h011, 3'd0));

    if (tb_err==0) $display("SIM_PASS: GDDR7_Lite_tb");
    else $display("SIM_FAIL: %0d", tb_err);
    $finish;
  end
  initial begin #3_000_000; $display("SIM_FAIL: timeout"); $finish; end
endmodule
