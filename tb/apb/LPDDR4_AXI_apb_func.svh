// SPDX-License-Identifier: Apache-2.0
// LPDDR4_AXI-specific part of tb/LPDDR4_AXI_apb_tb.sv: single-beat AXI4 writes and
// reads through the pass-through subordinate port, checked against a
// word model, then the N_RD / N_WR / N_RMW / N_ERR counters and the ERR
// interrupt (an AxSIZE = 3 write and read) through the registers.
// The burst, WRAP / FIXED and narrow-transfer checks are in tb/LPDDR4_AXI_tb.sv.
initial begin
  s_awid = 0; s_awaddr = 0; s_awlen = 0; s_awsize = 2; s_awburst = 1; s_awvalid = 0;
  s_wdata = 0; s_wstrb = 0; s_wlast = 0; s_wvalid = 0; s_bready = 0;
  s_arid = 0; s_araddr = 0; s_arlen = 0; s_arsize = 2; s_arburst = 1; s_arvalid = 0; s_rready = 0;
end
task automatic axi_w(input logic [31:0] a, input logic [31:0] d, input logic [3:0] s,
                     input logic [2:0] sz, output logic [1:0] resp);
  @(negedge PCLK);
  s_awaddr = a; s_awsize = sz; s_awlen = 0; s_awburst = 1; s_awid = 4'($urandom); s_awvalid = 1;
  @(posedge PCLK); while (!s_awready) @(posedge PCLK);
  @(negedge PCLK); s_awvalid = 0; s_wdata = d; s_wstrb = s; s_wlast = 1; s_wvalid = 1;
  @(posedge PCLK); while (!s_wready) @(posedge PCLK);
  @(negedge PCLK); s_wvalid = 0; s_bready = 1;
  @(posedge PCLK); while (!s_bvalid) @(posedge PCLK);
  resp = s_bresp; if (s_bid !== s_awid) fail("BID mismatch");
  @(negedge PCLK); s_bready = 0;
endtask
task automatic axi_r(input logic [31:0] a, input logic [2:0] sz, output logic [31:0] d,
                     output logic [1:0] resp);
  @(negedge PCLK);
  s_araddr = a; s_arsize = sz; s_arlen = 0; s_arburst = 1; s_arid = 4'($urandom); s_arvalid = 1;
  @(posedge PCLK); while (!s_arready) @(posedge PCLK);
  @(negedge PCLK); s_arvalid = 0; s_rready = 1;
  @(posedge PCLK); while (!s_rvalid) @(posedge PCLK);
  d = s_rdata; resp = s_rresp;
  if (s_rid !== s_arid) fail("RID mismatch");
  if (s_rlast !== 1'b1) fail("RLAST low on a single-beat read");
  @(negedge PCLK); s_rready = 0;
endtask
task automatic ip_func;
  logic [31:0] m [0:63];
  logic [31:0] d;
  logic [1:0]  r;
  int nrmw;
  nrmw = 0;
  // word-aligned addresses 0..0xFC never alias in the core (256 columns)
  for (int i = 0; i < 64; i++) begin m[i] = 32'h0; end
  for (int k = 0; k < 120; k++) begin
    int i;
    logic [3:0] s;
    i = $urandom % 64;
    if ($urandom % 2) begin
      s = ($urandom % 2) ? 4'hF : 4'($urandom);
      d = $urandom;
      axi_w(32'(i * 4), d, s, 3'd2, r);
      if (r != 2'b00) fail($sformatf("BRESP %0d", r));
      if (s[1:0] == 2'b01 || s[1:0] == 2'b10) nrmw++;
      if (s[3:2] == 2'b01 || s[3:2] == 2'b10) nrmw++;
      m[i] = merge(m[i], d, s);
    end else begin
      axi_r(32'(i * 4), 3'd2, d, r);
      if (r != 2'b00) fail($sformatf("RRESP %0d", r));
      if (d !== m[i]) fail($sformatf("AXI read %h = %h, expected %h", i * 4, d, m[i]));
    end
  end
  rd_exp(A_N_RMW, 32'(nrmw));
  rd_exp(A_N_ERR, 0);
  rd_exp(A_IRQ_STATUS, 0);
  // AxSIZE = 3 is beyond the 32-bit bus: SLVERR, counted, ERR interrupt
  wr(A_IRQ_ENABLE, 32'h1);
  axi_w(32'h0, 32'hDEAD_BEEF, 4'hF, 3'd3, r);
  if (r != 2'b10) fail("no SLVERR on an AxSIZE 3 write");
  axi_r(32'h0, 3'd3, d, r);
  if (r != 2'b10) fail("no SLVERR on an AxSIZE 3 read");
  axi_r(32'h0, 3'd2, d, r);
  if (d !== m[0]) fail("an erroring write changed the memory");
  rd_exp(A_N_ERR, 2);
  rd_exp(A_IRQ_STATUS, 32'h1);
  if (irq !== 1'b1) fail("irq low with ERR pending and enabled");
  wr(A_IRQ_STATUS, 32'h1); rd_exp(A_IRQ_STATUS, 0);
  if (irq !== 1'b0) fail("irq still high after W1C");
  rd(A_N_RD); if (rdv == 0) fail("N_RD did not count");
  rd(A_N_WR); if (rdv == 0) fail("N_WR did not count");
  wr(A_IRQ_ENABLE, 32'h0);
endtask
