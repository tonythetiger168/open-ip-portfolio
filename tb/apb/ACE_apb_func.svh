// SPDX-License-Identifier: Apache-2.0
// ACE-specific part of tb/ACE_apb_tb.sv. The TB is the ACE interconnect:
// write bursts (AW, the W beats with gaps, B after a delay), read bursts
// (AR, the R beats with gaps), on their own or overlapping, and snoops
// (AC, then CR and CD after delays), with random ACE fields.
// Checked against a model of the 64-line cache: read data on a hit and 0
// on a miss, byte strobes, a burst ended early by WLAST or without one,
// OKAY / SLVERR, every snoop response (DataTransfer, PassDirty, IsShared,
// WasUnique) and its data, a snoop held off while a write is in progress
// and a write address held off while a snoop is.
// Covered through the registers: ERR set by write and read bursts, masked
// and left pending into reset.
initial begin
  awaddr = 0; awlen = 0; awsize = 0; awburst = 0; awsnoop = 0; awdomain = 0; awbar = 0; awvalid = 0;
  wdata = 0; wstrb = 0; wlast = 0; wvalid = 0; bready = 0;
  araddr = 0; arlen = 0; arsize = 0; arburst = 0; arsnoop = 0; ardomain = 0; arbar = 0; arvalid = 0; rready = 0;
  acvalid = 0; acaddr = 0; acsnoop = 0; crready = 0; cdready = 0;
end
// cache model
bit          c_v [0:63], c_d [0:63];
logic [23:0] c_t [0:63];
logic [31:0] c_x [0:63];
initial for (int i = 0; i < 64; i++) begin c_v[i] = 0; c_d[i] = 0; end
bit          w_busy = 0, s_busy = 0;                    // a write / a snoop in progress
bit          use_fix = 0;                                // write data wfix instead of random
logic [31:0] wfix;
function automatic bit err0(input logic [2:0] sz, input logic [1:0] bu, input logic [31:0] a);
  return bu != 2'b01 || sz > 2 || a[31:16] != 0;
endfunction
// lm: 0 WLAST on the last beat, 1 WLAST early (on beat e), 2 no WLAST
task automatic axi_wr(input logic [31:0] a, input logic [7:0] len, input logic [2:0] sz, input logic [1:0] bu,
                      input int lm = 0, input int e = 0, input bit full = 0);
  bit er;
  logic [31:0] ad, d;
  logic [3:0]  s;
  int nb;
  @(negedge PCLK);
  awaddr = a; awlen = len; awsize = sz; awburst = bu; awvalid = 1;
  awsnoop = $urandom; awdomain = $urandom; awbar = $urandom;
  #1; while (!awready) begin @(negedge PCLK); #1; end
  if (s_busy) fail("write address taken during a snoop");
  w_busy = 1;
  @(negedge PCLK);
  awvalid = 0; awaddr = $urandom; awlen = $urandom; awsize = $urandom; awburst = $urandom;
  awsnoop = $urandom; awdomain = $urandom; awbar = $urandom;
  er = err0(sz, bu, a);
  nb = lm == 1 ? e + 1 : int'(len) + 1;
  ad = a;
  for (int b = 0; b < nb; b++) begin
    repeat ($urandom % 3) @(negedge PCLK);
    d = use_fix ? wfix : $urandom; s = full ? 4'hF : 4'($urandom);
    wdata = d; wstrb = s; wvalid = 1;
    wlast = lm == 0 ? b == int'(len) : lm == 1 ? b == e : 0;
    #1; while (!wready) begin @(negedge PCLK); #1; end
    if (!er) begin : b_fill
      logic [31:0] x;
      x = c_x[ad[7:2]];
      for (int k = 0; k < 4; k++) if (s[k]) x[8*k +: 8] = d[8*k +: 8];
      c_x[ad[7:2]] = x; c_v[ad[7:2]] = 1; c_d[ad[7:2]] = 1; c_t[ad[7:2]] = ad[31:8];
    end
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
  bready = 0; w_busy = 0;
endtask
task automatic axi_rd(input logic [31:0] a, input logic [7:0] len, input logic [2:0] sz, input logic [1:0] bu);
  bit er;
  logic [31:0] ad, e;
  @(negedge PCLK);
  araddr = a; arlen = len; arsize = sz; arburst = bu; arvalid = 1;
  arsnoop = $urandom; ardomain = $urandom; arbar = $urandom;
  #1; while (!arready) begin @(negedge PCLK); #1; end
  @(negedge PCLK);
  arvalid = 0; araddr = $urandom; arlen = $urandom; arsize = $urandom; arburst = $urandom;
  arsnoop = $urandom; ardomain = $urandom; arbar = $urandom;
  er = err0(sz, bu, a);
  ad = a;
  for (int b = 0; b <= int'(len); b++) begin
    repeat ($urandom % 3) @(negedge PCLK);
    rready = 1;
    #1; while (!rvalid) begin @(negedge PCLK); #1; end
    e = c_v[ad[7:2]] && c_t[ad[7:2]] == ad[31:8] ? c_x[ad[7:2]] : 32'h0;
    if (rresp !== (er ? 2'b10 : 2'b00) || rlast !== (b == int'(len)) || rdata !== e)
      fail($sformatf("R beat %0d: resp %b last %b data %h, expected %b %b %h (read %h)",
                     b, rresp, rlast, rdata, er ? 2'b10 : 2'b00, b == int'(len), e, a));
    ad += 4;
    @(negedge PCLK);
    rready = 0;
  end
endtask
// one snoop: AC, then CR, then CD when data is transferred
task automatic snoop(input logic [31:0] a, input logic [3:0] op);
  bit hit, xf, dt, sh, un;
  logic [5:0] i;
  @(negedge PCLK);
  acaddr = a; acsnoop = op; acvalid = 1;
  #1; while (!acready) begin @(negedge PCLK); #1; end
  if (w_busy) fail("snoop taken during a write");
  s_busy = 1;
  i = a[7:2];
  hit = c_v[i] && c_t[i] == a[31:8];
  {xf, dt, sh, un} = 0;
  case (op)
    4'b0001, 4'b0010: if (hit) begin xf = 1; sh = 1; dt = c_d[i]; un = c_d[i]; c_d[i] = 0; end
    4'b1101: begin c_v[i] = 0; c_d[i] = 0; end
    4'b1001: if (hit) begin if (c_d[i]) begin xf = 1; dt = 1; un = 1; end c_v[i] = 0; c_d[i] = 0; end
    default: ;
  endcase
  @(negedge PCLK);
  acvalid = 0; acaddr = $urandom; acsnoop = $urandom;
  repeat ($urandom % 3) @(negedge PCLK);
  crready = 1;
  #1; while (!crvalid) begin @(negedge PCLK); #1; end
  if (crresp !== {un, sh, dt, 1'b0, xf}) fail($sformatf("crresp %b, expected %b (snoop %b at %h)", crresp, {un, sh, dt, 1'b0, xf}, op, a));
  @(negedge PCLK);
  crready = 0;
  if (xf) begin
    repeat ($urandom % 3) @(negedge PCLK);
    cdready = 1;
    #1; while (!cdvalid) begin @(negedge PCLK); #1; end
    if (cddata !== c_x[i] || !cdlast) fail($sformatf("CD %h last %b, expected %h", cddata, cdlast, c_x[i]));
    @(negedge PCLK);
    cdready = 0;
  end
  s_busy = 0;
  #1;
  if (cdvalid || crvalid) fail("snoop channels busy after the response");
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
  // every line filled whole, then read back
  axi_wr(32'h0, 8'h3F, 2, 2'b01, 0, 0, 1);
  axi_rd(32'h0, 8'h3F, 2, 2'b01);
  // all data bits both ways, on the R and CD channels
  use_fix = 1;
  wfix = 32'hFFFF_FFFF; axi_wr(32'h10, 0, 2, 2'b01, 0, 0, 1); axi_rd(32'h10, 0, 2, 2'b01); snoop(32'h10, 4'b0001);
  wfix = 32'h0;         axi_wr(32'h10, 0, 2, 2'b01, 0, 0, 1); axi_rd(32'h10, 0, 2, 2'b01); snoop(32'h10, 4'b0010);
  use_fix = 0;
  // random traffic within 64 KB: bursts, sizes 1, 2, 4, any alignment,
  // snoops of every kind on lines that hit and miss
  for (int k = 0; k < 80; k++) begin : b_mix
    logic [31:0] a;
    a = {16'h0, 8'($urandom % 4), 8'($urandom)};
    case ($urandom % 3)
      0: axi_wr(a, 8'($urandom % 8), 3'($urandom % 3), 2'b01);
      1: axi_rd(a, 8'($urandom % 8), 3'($urandom % 3), 2'b01);
      default: snoop(a & 32'h3FC | 32'($urandom % 4), 4'($urandom));
    endcase
  end
  for (int k = 0; k < 16; k++) begin
    axi_wr(32'(k * 4), 0, 2, 2'b01);
    snoop(32'(k * 4), k % 2 ? 4'b0001 : 4'b0010);
    snoop(32'(k * 4), 4'b0010);
    snoop(32'(k * 4), k % 4 < 2 ? 4'b1001 : 4'b1101);
    snoop(32'(k * 4), 4'b1001);
    axi_rd(32'(k * 4), 0, 2, 2'b01);
  end
  snoop(32'hFFFF_FFFF, 4'hF);
  // WLAST early (burst ends there) and missing (ends after AWLEN + 1)
  axi_wr(32'h80, 5, 2, 2'b01, 1, 2);
  axi_wr(32'hC0, 2, 2, 2'b01, 2);
  axi_rd(32'h80, 7, 2, 2'b01);
  // overlapping: a read with a write, a read with a snoop; a snoop offered
  // during a write waits for it, and a write address during a snoop
  for (int k = 0; k < 6; k++) begin
    fork
      axi_wr(32'(k * 16), 3, 2, 2'b01);
      axi_rd(32'(k * 16 + 128), 3, 2, 2'b01);
    join
    fork
      axi_rd(32'(k * 16), 3, 2, 2'b01);
      snoop(32'(k * 16 + 128), 4'b0001);
    join
    fork
      axi_wr(32'(k * 4 + 256), 3, 2, 2'b01);
      begin @(negedge PCLK); snoop(32'(k * 4 + 256), 4'b1001); end   // AW taken first
    join
    fork
      snoop(32'(k * 4 + 256), 4'b0001);
      begin @(negedge PCLK); axi_wr(32'(k * 4 + 256), 0, 2, 2'b01); end   // AC taken first
    join
  end
  rd_exp(A_IRQ_STATUS, 0);
  // SLVERR: a start at 64 KB and above, FIXED, WRAP, size
  axi_wr(32'hFFFF_0000, 1, 2, 2'b01);
  irq_expect(IRQ_ERR);
  axi_rd(32'hFFFF_0000, 1, 2, 2'b01);
  irq_expect(IRQ_ERR);
  axi_wr(32'h40, 1, 2, 2'b00); axi_rd(32'h40, 1, 2, 2'b00);
  axi_wr(32'h40, 1, 2, 2'b10); axi_rd(32'h40, 1, 2, 2'b10);
  axi_wr(32'h40, 1, 2, 2'b11); axi_rd(32'h40, 1, 2, 2'b11);
  axi_wr(32'h40, 1, 3'h7, 2'b01); axi_rd(32'h40, 1, 3'h7, 2'b01);
  irq_expect(IRQ_ERR);
  axi_rd(32'h0, 8'h3F, 2, 2'b01);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  axi_rd(32'h10000, 0, 2, 2'b01);
  cycles(2);
  if (irq) fail("irq with ERR masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
endtask
