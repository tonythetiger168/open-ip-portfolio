// SPDX-License-Identifier: Apache-2.0
// Avalon_MM-specific part of tb/Avalon_MM_apb_tb.sv. The TB is the
// Avalon-MM host: write bursts (beats with gaps, each held until
// waitrequest is low) and read bursts (the command held until accepted,
// then the readdatavalid beats counted and checked).
// Checked against a model of the memory: data with byte enables, the wait
// state of the slow window (commands, write beats, the idle cycle before
// each read beat), burstcount 0 and above 16, beats above the memory
// (writes dropped, reads 0), read and write together (taken as a write),
// waitrequest high while read data is returned.
// Covered through the registers: ERR (held by the core until reset: a
// write-1 does not clear it), masked, left pending into reset.
initial begin
  av_address = 0; av_read = 0; av_write = 0; av_writedata = 0; av_byteenable = 0; av_burstcount = 0;
end
logic [31:0] mdl [0:255];
bit          use_fix = 0;
logic [31:0] wfix;
function automatic bit in_valid(input logic [32:0] a); return a < 33'h400; endfunction
function automatic bit in_slow(input logic [32:0] a); return a >= 33'h200 && a < 33'h400; endfunction
function automatic int nbeats(input logic [7:0] bc); return bc == 0 ? 1 : bc > 16 ? 16 : int'(bc); endfunction
// hold the current command / beat until waitrequest is low; count waits
task automatic take(output int w);
  w = 0;
  #1; while (av_waitrequest) begin @(negedge PCLK); #1; w++; end
  @(negedge PCLK);
endtask
task automatic av_wr(input logic [31:0] a, input logic [7:0] bc, input bit full = 0, input bit both = 0);
  logic [32:0] ad;
  logic [31:0] d;
  logic [3:0]  be;
  int w;
  ad = {1'b0, a};
  @(negedge PCLK);
  for (int b = 0; b < nbeats(bc); b++) begin
    if (b != 0) repeat ($urandom % 3) @(negedge PCLK);
    d = use_fix ? wfix : $urandom; be = full ? 4'hF : 4'($urandom);
    av_write = 1; av_read = both && b == 0; av_writedata = d; av_byteenable = be;
    av_address = b == 0 ? a : $urandom; av_burstcount = b == 0 ? bc : $urandom;
    take(w);
    if (w != int'(in_slow(ad))) fail($sformatf("%0d wait states for a write beat at %h", w, ad));
    if (in_valid(ad)) for (int k = 0; k < 4; k++) if (be[k]) mdl[ad[9:2]][8*k +: 8] = d[8*k +: 8];
    ad += 4;
    av_write = 0; av_read = 0; av_writedata = $urandom; av_byteenable = $urandom; av_address = $urandom; av_burstcount = $urandom;
  end
endtask
task automatic av_rd(input logic [31:0] a, input logic [7:0] bc);
  logic [32:0] ad;
  logic [31:0] e;
  int w, gap;
  ad = {1'b0, a};
  @(negedge PCLK);
  av_read = 1; av_address = a; av_burstcount = bc; av_writedata = $urandom; av_byteenable = $urandom;
  take(w);
  if (w != int'(in_slow(ad))) fail($sformatf("%0d wait states for a read command at %h", w, ad));
  av_read = 0; av_address = $urandom; av_burstcount = $urandom;
  for (int b = 0; b < nbeats(bc); b++) begin
    gap = 0;
    #1;
    while (!av_readdatavalid) begin
      if (!av_waitrequest) fail("waitrequest low while read data is due");
      @(negedge PCLK); #1; gap++;
    end
    if (gap != int'(in_slow(ad)))
      fail($sformatf("%0d idle cycles before read beat %0d at %h", gap, b, ad));
    e = in_valid(ad) ? mdl[ad[9:2]] : 32'h0;
    if (av_readdata !== e) fail($sformatf("read beat %0d at %h = %h, expected %h", b, ad, av_readdata, e));
    if (!av_waitrequest) fail("waitrequest low while read data is returned");
    ad += 4;
    @(negedge PCLK);
  end
  #1;
  if (av_readdatavalid) fail("read data beyond the burst");
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // the whole memory in 16-beat bursts, then read back
  for (int i = 0; i < 16; i++) av_wr(32'(i * 64), 16, 1);
  for (int i = 0; i < 16; i++) av_rd(32'(i * 64), 16);
  // all data bits both ways
  use_fix = 1;
  wfix = 32'hFFFF_FFFF; av_wr(32'h204, 1, 1); av_rd(32'h204, 1);
  wfix = 32'h0;         av_wr(32'h204, 1, 1); av_rd(32'h204, 1);
  use_fix = 0;
  // random bursts within the memory, byte enables, burstcount 0
  for (int k = 0; k < 40; k++) begin : b_mix
    logic [7:0] bc;
    bc = 8'($urandom % 17);
    av_wr(32'($urandom % (257 - nbeats(bc))) * 4, bc);
    bc = 8'($urandom % 17);
    av_rd(32'($urandom % (257 - nbeats(bc))) * 4, bc);
  end
  // a burst across the window boundary both ways
  av_wr(32'h1F8, 4); av_rd(32'h1F8, 4);
  rd_exp(A_IRQ_STATUS, 0);
  // errors: beats above the memory, burstcount above 16, read with write
  av_wr(32'h3F8, 4);
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
  if (!irq) fail("irq low with ERR set");
  wr(A_IRQ_STATUS, IRQ_ALL);                            // held by the core
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
  av_rd(32'h3F8, 4);
  av_wr(32'hFFFF_FFFC, 2); av_rd(32'hFFFF_FFFC, 2);
  av_wr(32'h0, 8'hFF); av_rd(32'h40, 8'hFF);
  av_wr(32'h100, 1, 1, 1); av_rd(32'h100, 1);
  for (int i = 0; i < 4; i++) av_rd(32'(i * 64), 16);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  cycles(2);
  if (irq) fail("irq with ERR masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
endtask
