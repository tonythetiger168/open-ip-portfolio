// SPDX-License-Identifier: Apache-2.0
// AXI4_Lite-specific part of tb/AXI4_Lite_apb_tb.sv. The TB is the AXI4-
// Lite manager: writes (AW, then W after a delay, then B after a delay)
// and reads (AR, then R after a delay), on their own or overlapping.
// Checked: read data against a model of the memory with byte strobes,
// OKAY / SLVERR, SLVERR writes dropping their data, SLVERR reads 0.
// Covered through the registers: ERR (held by the core until reset: a
// write-1 does not clear it), masked, left pending into reset.
initial begin
  awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
  araddr = 0; arvalid = 0; rready = 0;
end
logic [31:0] mdl [0:255];
function automatic bit in_range(input logic [31:0] a); return a[31:10] == 0 && a[1:0] == 0; endfunction
task automatic axi_wr(input logic [31:0] a, input logic [31:0] d, input logic [3:0] s, input int wdly, input int bdly);
  @(negedge PCLK);
  awaddr = a; awvalid = 1;
  wdata = d; wstrb = s; wvalid = wdly == 0;
  bready = bdly == 0;
  #1; while (!awready) begin @(negedge PCLK); #1; end
  @(negedge PCLK);
  awvalid = 0; awaddr = $urandom;
  repeat (wdly) @(negedge PCLK);
  wvalid = 1;
  #1; while (!wready) begin @(negedge PCLK); #1; end
  @(negedge PCLK);
  wvalid = 0; wdata = $urandom; wstrb = $urandom;
  repeat (bdly) @(negedge PCLK);
  bready = 1;
  #1; while (!bvalid) begin @(negedge PCLK); #1; end
  if (bresp !== (in_range(a) ? 2'b00 : 2'b10)) fail($sformatf("bresp %b for %h", bresp, a));
  if (in_range(a)) begin
    for (int b = 0; b < 4; b++) if (s[b]) mdl[a[9:2]][8*b +: 8] = d[8*b +: 8];
  end
  @(negedge PCLK);
  bready = 0;
endtask
task automatic axi_rd(input logic [31:0] a, input int rdly);
  logic [31:0] e;
  @(negedge PCLK);
  araddr = a; arvalid = 1;
  rready = rdly == 0;
  #1; while (!arready) begin @(negedge PCLK); #1; end
  @(negedge PCLK);
  arvalid = 0; araddr = $urandom;
  repeat (rdly) @(negedge PCLK);
  rready = 1;
  #1; while (!rvalid) begin @(negedge PCLK); #1; end
  e = in_range(a) ? mdl[a[9:2]] : 32'h0;
  if (rresp !== (in_range(a) ? 2'b00 : 2'b10)) fail($sformatf("rresp %b for %h", rresp, a));
  if (rdata !== e) fail($sformatf("read %h = %h, expected %h", a, rdata, e));
  @(negedge PCLK);
  rready = 0;
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // words written whole first, so every read has a defined value
  for (int i = 0; i < 32; i++) axi_wr(32'(i * 4), {$urandom}, 4'hF, $urandom % 3, $urandom % 3);
  axi_wr(32'h3FC, 32'hFFFF_FFFF, 4'hF, 0, 0);
  axi_rd(32'h3FC, 0);
  axi_wr(32'h3FC, 32'h0, 4'hF, 1, 2);
  axi_rd(32'h3FC, 2);
  // byte strobes, delays both ways
  for (int k = 0; k < 40; k++) begin : b_mix
    int w;
    w = $urandom % 32;
    axi_wr(32'(w * 4), {$urandom}, 4'($urandom), $urandom % 3, $urandom % 3);
    axi_rd(32'($urandom % 32) * 4, $urandom % 3);
  end
  // a read and a write overlapping (different words)
  for (int k = 0; k < 8; k++)
    fork
      axi_wr(32'(k * 4), {$urandom}, 4'hF, k % 3, k % 2);
      axi_rd(32'(k * 4 + 64), k % 3);
    join
  rd_exp(A_IRQ_STATUS, 0);
  // SLVERR: above the memory (every upper address bit) and misaligned
  axi_wr(32'hFFFF_FC00, 32'h1234_5678, 4'hF, 0, 0);
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
  if (!irq) fail("irq low with ERR set");
  wr(A_IRQ_STATUS, IRQ_ALL);                            // held by the core
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
  axi_rd(32'hFFFF_FC00, 1);
  axi_wr(32'h0000_0006, 32'h1234_5678, 4'hF, 1, 1);
  axi_rd(32'h0000_0005, 0);
  axi_rd(32'h0000_0000, 0);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  cycles(2);
  if (irq) fail("irq with ERR masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
endtask
