// SPDX-License-Identifier: Apache-2.0
// AXI-specific part of tb/AXI_apb_tb.sv. The TB is the AXI3 manager:
// write bursts (AW, the W beats with gaps, B after a delay) and read
// bursts (AR, the R beats with gaps), on their own or overlapping.
// Checked against a model of the memory and of the responses: data with
// byte strobes, INCR / FIXED addressing, any ID, BID / RID, RLAST, OKAY,
// SLVERR (out of range, misaligned, WRAP, running past the memory, WLAST
// early or missing, a WID other than the AWID) and DECERR (size, burst
// type), writes dropped from the first error on.
// Covered through the registers: ERR (held by the core until reset: a
// write-1 does not clear it), masked, left pending into reset.
initial begin
  awid = 0; awaddr = 0; awlen = 0; awsize = 0; awburst = 0; awvalid = 0;
  wid = 0; wdata = 0; wstrb = 0; wlast = 0; wvalid = 0; bready = 0;
  arid = 0; araddr = 0; arlen = 0; arsize = 0; arburst = 0; arvalid = 0; rready = 0;
end
logic [31:0] mdl [0:255];
bit          use_fix = 0;                                // write data wfix instead of random
logic [31:0] wfix;
function automatic bit in_range(input logic [31:0] a); return a[31:10] == 0 && a[1:0] == 0; endfunction
function automatic logic [1:0] resp0(input logic [2:0] sz, input logic [1:0] bu, input logic [31:0] a);
  if (sz > 2 || bu == 2'b11) return 2'b11;
  if (!in_range(a) || bu == 2'b10) return 2'b10;
  return 2'b00;
endfunction
// lm: 0 WLAST on the last beat, 1 WLAST early (on beat e), 2 no WLAST,
// 3 a WID other than the AWID on beat e
task automatic axi_wr(input logic [31:0] a, input logic [3:0] len, input logic [2:0] sz, input logic [1:0] bu,
                      input logic [3:0] id, input int lm = 0, input int e = 0, input bit full = 0);
  logic [1:0]  er, ep;
  logic [31:0] ad, d;
  logic [3:0]  s;
  int nb;
  @(negedge PCLK);
  awid = id; awaddr = a; awlen = len; awsize = sz; awburst = bu; awvalid = 1;
  #1; while (!awready) begin @(negedge PCLK); #1; end
  @(negedge PCLK);
  awvalid = 0; awid = $urandom; awaddr = $urandom; awlen = $urandom; awsize = $urandom; awburst = $urandom;
  er = resp0(sz, bu, a);
  nb = lm == 1 ? e + 1 : int'(len) + 1;
  ad = a;
  for (int b = 0; b < nb; b++) begin
    repeat ($urandom % 3) @(negedge PCLK);
    d = use_fix ? wfix : $urandom; s = full ? 4'hF : 4'($urandom);
    wdata = d; wstrb = s; wvalid = 1;
    wid = lm == 3 && b == e ? ~id : id;
    wlast = lm == 0 ? b == int'(len) : lm == 1 ? b == e : 0;
    #1; while (!wready) begin @(negedge PCLK); #1; end
    ep = er;
    if (ep == 0) begin
      if (wid != id) er = 2'b10;
      else if (in_range(ad)) begin for (int k = 0; k < 4; k++) if (s[k]) mdl[ad[9:2]][8*k +: 8] = d[8*k +: 8]; end
      else er = 2'b10;
    end
    if (b == nb - 1 && wlast != (b == int'(len)) && ep == 0 && in_range(ad)) er = 2'b10;
    if (bu == 2'b01) ad += 4;
    @(negedge PCLK);
    wvalid = 0; wid = $urandom; wdata = $urandom; wstrb = $urandom; wlast = $urandom;
  end
  wlast = 0;
  repeat ($urandom % 3) @(negedge PCLK);
  bready = 1;
  #1; while (!bvalid) begin @(negedge PCLK); #1; end
  if (bid !== id || bresp !== er) fail($sformatf("B id %h resp %b, expected %h %b (write %h)", bid, bresp, id, er, a));
  @(negedge PCLK);
  bready = 0;
endtask
task automatic axi_rd(input logic [31:0] a, input logic [3:0] len, input logic [2:0] sz, input logic [1:0] bu,
                      input logic [3:0] id);
  logic [1:0]  er, re;
  logic [31:0] ad, e;
  @(negedge PCLK);
  arid = id; araddr = a; arlen = len; arsize = sz; arburst = bu; arvalid = 1;
  #1; while (!arready) begin @(negedge PCLK); #1; end
  @(negedge PCLK);
  arvalid = 0; arid = $urandom; araddr = $urandom; arlen = $urandom; arsize = $urandom; arburst = $urandom;
  er = resp0(sz, bu, a);
  ad = a;
  for (int b = 0; b <= int'(len); b++) begin
    repeat ($urandom % 3) @(negedge PCLK);
    rready = 1;
    #1; while (!rvalid) begin @(negedge PCLK); #1; end
    e = in_range(ad) ? mdl[ad[9:2]] : 32'h0;
    re = er == 0 && !in_range(ad) ? 2'b10 : er;
    if (rid !== id || rresp !== re || rlast !== (b == int'(len)) || rdata !== e)
      fail($sformatf("R beat %0d: id %h resp %b last %b data %h, expected %h %b %b %h (read %h)",
                     b, rid, rresp, rlast, rdata, id, re, b == int'(len), e, a));
    if (bu == 2'b01) ad += 4;
    @(negedge PCLK);
    rready = 0;
  end
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // the whole memory in 16-beat INCR bursts, so every read has a value
  for (int i = 0; i < 16; i++) axi_wr(32'(i * 64), 15, 2, 2'b01, 0, 0, 0, 1);
  axi_wr(32'h3FC, 0, 2, 2'b01, 0, 0, 0, 1);
  // all data bits both ways
  use_fix = 1;
  wfix = 32'hFFFF_FFFF; axi_wr(32'h100, 0, 2, 2'b01, 0, 0, 0, 1); axi_rd(32'h100, 0, 2, 2'b01, 0);
  wfix = 32'h0;         axi_wr(32'h100, 0, 2, 2'b01, 0, 0, 0, 1); axi_rd(32'h100, 0, 2, 2'b01, 0);
  use_fix = 0;
  // random bursts, sizes 1, 2, 4, both burst types
  for (int k = 0; k < 40; k++) begin : b_mix
    logic [3:0] len;
    len = 4'($urandom);                                  // within the memory
    axi_wr(32'($urandom % (256 - int'(len))) * 4, len, 3'($urandom % 3), 2'($urandom % 2), 4'($urandom));
    axi_rd(32'($urandom % 192) * 4, 4'($urandom), 3'($urandom % 3), 2'($urandom % 2), 4'($urandom));
  end
  // a read and a write overlapping (different words)
  for (int k = 0; k < 6; k++)
    fork
      axi_wr(32'(k * 16), 3, 2, 2'b01, 4'(k));
      axi_rd(32'(k * 16 + 512), 3, 2, 2'b01, 4'(k + 8));
    join
  rd_exp(A_IRQ_STATUS, 0);
  // errors: run past the memory, out of range, misaligned, WRAP, WLAST
  // early and missing, WID mismatch, DECERR for size and burst type
  axi_wr(32'h3F8, 3, 2, 2'b01, 0, 0, 0, 1);
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
  if (!irq) fail("irq low with ERR set");
  wr(A_IRQ_STATUS, IRQ_ALL);                            // held by the core
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
  axi_rd(32'h3F8, 3, 2, 2'b01, 0);
  axi_wr(32'hFFFF_FC00, 1, 2, 2'b00, 0);
  axi_rd(32'hFFFF_FC00, 1, 2, 2'b00, 0);
  axi_wr(32'h0000_0102, 0, 2, 2'b01, 0);
  axi_rd(32'h0000_0101, 0, 2, 2'b01, 0);
  axi_wr(32'h0000_0040, 3, 2, 2'b10, 0);
  axi_rd(32'h0000_0040, 3, 2, 2'b10, 0);
  axi_wr(32'h0000_0080, 5, 2, 2'b01, 0, 1, 2);
  axi_wr(32'h0000_00C0, 2, 2, 2'b01, 0, 2);
  axi_wr(32'h0000_0100, 3, 2, 2'b01, 4'h5, 3, 1);
  axi_wr(32'h0000_0000, 0, 2, 2'b01, 4'hF, 3, 0);
  axi_wr(32'h0000_0000, 0, 3'h7, 2'b01, 0);
  axi_rd(32'h0000_0000, 0, 3'h7, 2'b01, 0);
  axi_wr(32'h0000_0000, 0, 2, 2'b11, 0);
  axi_rd(32'h0000_0000, 0, 2, 2'b11, 0);
  for (int i = 0; i < 4; i++) axi_rd(32'(i * 64), 15, 2, 2'b01, 0);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  cycles(2);
  if (irq) fail("irq with ERR masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
endtask
