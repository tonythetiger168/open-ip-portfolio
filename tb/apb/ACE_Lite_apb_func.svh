// SPDX-License-Identifier: Apache-2.0
// ACE_Lite-specific part of tb/ACE_Lite_apb_tb.sv. The TB is the ACE-Lite
// manager: write bursts (AW, the W beats with gaps, B after a delay) and
// read bursts (AR, the R beats with gaps), on their own or overlapping,
// with random snoop, domain and barrier fields.
// Checked against a model of the memory and of the responses: data with
// byte strobes, RLAST, a burst ended early by WLAST or without one, OKAY,
// SLVERR (burst type, size, start above the memory, beats running past
// it), writes in error dropped, reads in error 0.
// Covered through the registers: ERR set by write and read bursts, masked
// and left pending into reset.
initial begin
  awaddr = 0; awlen = 0; awsize = 0; awburst = 0; awsnoop = 0; awdomain = 0; awbar = 0; awvalid = 0;
  wdata = 0; wstrb = 0; wlast = 0; wvalid = 0; bready = 0;
  araddr = 0; arlen = 0; arsize = 0; arburst = 0; arsnoop = 0; ardomain = 0; arbar = 0; arvalid = 0; rready = 0;
end
logic [31:0] mdl [0:255];
bit          use_fix = 0;                                // write data wfix instead of random
logic [31:0] wfix;
// lm: 0 WLAST on the last beat, 1 WLAST early (on beat e), 2 no WLAST
task automatic axi_wr(input logic [31:0] a, input logic [7:0] len, input logic [2:0] sz, input logic [1:0] bu,
                      input int lm = 0, input int e = 0, input bit full = 0);
  bit er, oor;
  logic [31:0] ad, d;
  logic [3:0]  s;
  int nb;
  @(negedge PCLK);
  awaddr = a; awlen = len; awsize = sz; awburst = bu; awvalid = 1;
  awsnoop = $urandom; awdomain = $urandom; awbar = $urandom;
  #1; while (!awready) begin @(negedge PCLK); #1; end
  @(negedge PCLK);
  awvalid = 0; awaddr = $urandom; awlen = $urandom; awsize = $urandom; awburst = $urandom;
  awsnoop = $urandom; awdomain = $urandom; awbar = $urandom;
  er = bu != 2'b01 || sz > 2 || a[31:10] != 0;
  nb = lm == 1 ? e + 1 : int'(len) + 1;
  ad = a;
  for (int b = 0; b < nb; b++) begin
    repeat ($urandom % 3) @(negedge PCLK);
    d = use_fix ? wfix : $urandom; s = full ? 4'hF : 4'($urandom);
    wdata = d; wstrb = s; wvalid = 1;
    wlast = lm == 0 ? b == int'(len) : lm == 1 ? b == e : 0;
    #1; while (!wready) begin @(negedge PCLK); #1; end
    oor = ad[31:10] != 0;
    if (!er && !oor) for (int k = 0; k < 4; k++) if (s[k]) mdl[ad[9:2]][8*k +: 8] = d[8*k +: 8];
    if (oor) er = 1;
    ad += 4;
    @(negedge PCLK);
    wvalid = 0; wdata = $urandom; wstrb = $urandom; wlast = $urandom;
  end
  wlast = 0;
  repeat ($urandom % 3) @(negedge PCLK);
  bready = 1;
  #1; while (!bvalid) begin @(negedge PCLK); #1; end
  if (bresp !== (er ? 2'b10 : 2'b00)) fail($sformatf("bresp %b, expected %b (write %h)", bresp, er ? 2'b10 : 2'b00, a));
  @(negedge PCLK);
  bready = 0;
endtask
task automatic axi_rd(input logic [31:0] a, input logic [7:0] len, input logic [2:0] sz, input logic [1:0] bu);
  bit er, x;
  logic [31:0] ad, e;
  @(negedge PCLK);
  araddr = a; arlen = len; arsize = sz; arburst = bu; arvalid = 1;
  arsnoop = $urandom; ardomain = $urandom; arbar = $urandom;
  #1; while (!arready) begin @(negedge PCLK); #1; end
  @(negedge PCLK);
  arvalid = 0; araddr = $urandom; arlen = $urandom; arsize = $urandom; arburst = $urandom;
  arsnoop = $urandom; ardomain = $urandom; arbar = $urandom;
  er = bu != 2'b01 || sz > 2 || a[31:10] != 0;
  ad = a;
  for (int b = 0; b <= int'(len); b++) begin
    repeat ($urandom % 3) @(negedge PCLK);
    rready = 1;
    #1; while (!rvalid) begin @(negedge PCLK); #1; end
    x = er || ad[31:10] != 0;
    e = x ? 32'h0 : mdl[ad[9:2]];
    if (rresp !== (x ? 2'b10 : 2'b00) || rlast !== (b == int'(len)) || rdata !== e)
      fail($sformatf("R beat %0d: resp %b last %b data %h, expected %b %b %h (read %h)",
                     b, rresp, rlast, rdata, x ? 2'b10 : 2'b00, b == int'(len), e, a));
    ad += 4;
    @(negedge PCLK);
    rready = 0;
  end
endtask
task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // the whole memory in one 256-beat burst, then read back in one
  axi_wr(32'h0, 8'hFF, 2, 2'b01, 0, 0, 1);
  axi_rd(32'h0, 8'hFF, 2, 2'b01);
  // all data bits both ways
  use_fix = 1;
  wfix = 32'hFFFF_FFFF; axi_wr(32'h100, 0, 2, 2'b01, 0, 0, 1); axi_rd(32'h100, 0, 2, 2'b01);
  wfix = 32'h0;         axi_wr(32'h100, 0, 2, 2'b01, 0, 0, 1); axi_rd(32'h100, 0, 2, 2'b01);
  use_fix = 0;
  // random bursts within the memory, sizes 1, 2, 4, any alignment
  for (int k = 0; k < 40; k++) begin : b_mix
    logic [7:0] len;
    len = 8'($urandom % 16);
    axi_wr(32'($urandom % (256 - int'(len))) * 4 + 32'($urandom % 4), len, 3'($urandom % 3), 2'b01);
    axi_rd(32'($urandom % 192) * 4 + 32'($urandom % 4), 8'($urandom % 16), 3'($urandom % 3), 2'b01);
  end
  // WLAST early (burst ends there) and missing (ends after AWLEN + 1)
  axi_wr(32'h80, 5, 2, 2'b01, 1, 2);
  axi_wr(32'hC0, 2, 2, 2'b01, 2);
  axi_rd(32'h80, 7, 2, 2'b01);
  // a read and a write overlapping (different words)
  for (int k = 0; k < 6; k++)
    fork
      axi_wr(32'(k * 16), 3, 2, 2'b01);
      axi_rd(32'(k * 16 + 512), 3, 2, 2'b01);
    join
  rd_exp(A_IRQ_STATUS, 0);
  // SLVERR: running past the memory, a start above it, FIXED, WRAP, size
  axi_wr(32'h3F8, 3, 2, 2'b01, 0, 0, 1);
  irq_expect(IRQ_ERR);
  axi_rd(32'h3F8, 3, 2, 2'b01);
  irq_expect(IRQ_ERR);
  axi_wr(32'hFFFF_FC00, 1, 2, 2'b01);
  irq_expect(IRQ_ERR);
  axi_rd(32'hFFFF_FC00, 1, 2, 2'b01);
  irq_expect(IRQ_ERR);
  axi_wr(32'h40, 1, 2, 2'b00); axi_rd(32'h40, 1, 2, 2'b00);
  axi_wr(32'h40, 1, 2, 2'b10); axi_rd(32'h40, 1, 2, 2'b10);
  axi_wr(32'h40, 1, 2, 2'b11); axi_rd(32'h40, 1, 2, 2'b11);
  axi_wr(32'h40, 1, 3'h7, 2'b01); axi_rd(32'h40, 1, 3'h7, 2'b01);
  irq_expect(IRQ_ERR);
  axi_rd(32'h0, 8'hFF, 2, 2'b01);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  axi_wr(32'h3FC, 1, 2, 2'b01);
  cycles(2);
  if (irq) fail("irq with ERR masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
endtask
