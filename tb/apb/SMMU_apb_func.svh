// SPDX-License-Identifier: Apache-2.0
// SMMU-specific part of tb/SMMU_apb_tb.sv. An soc_ss_axi_mem subordinate on
// m_* holds the page table and data; an upstream master BFM drives s_*.
// Covered through the registers: bypass, translation with a page table at
// PT_BASE (pages at the top and bottom of the address space), TLB_STATS
// hits and misses, CMD.tlb_inv, faults (not valid, read-only page) with
// FAULT_ADDR, FAULT_INFO and the FAULT interrupt, STATUS.busy idle.
`SOC_SS_AXI_MEM(mem, PCLK, PRESETN)
initial begin
  s_awid = 0; s_awaddr = 0; s_awlen = 0; s_awsize = 2; s_awburst = 1; s_awprot = 0; s_awvalid = 0;
  s_wdata = 0; s_wstrb = 4'hF; s_wlast = 0; s_wvalid = 0; s_bready = 0;
  s_arid = 0; s_araddr = 0; s_arlen = 0; s_arsize = 2; s_arburst = 1; s_arprot = 0; s_arvalid = 0; s_rready = 0;
end
logic [1:0]  sresp;
logic [31:0] sbuf [4];
task automatic s_wr(input logic [31:0] a, input int n);   // data: sbuf
  @(negedge PCLK);
  s_awaddr = a; s_awlen = 8'(n - 1); s_awid = 4'h5; s_awvalid = 1;
  @(posedge PCLK); while (!s_awready) @(posedge PCLK);
  #1 s_awvalid = 0;
  for (int i = 0; i < n; i++) begin
    #1 s_wvalid = 1; s_wdata = sbuf[i]; s_wlast = (i == n - 1);
    @(posedge PCLK); while (!s_wready) @(posedge PCLK);
    #1 s_wvalid = 0; s_wlast = 0;
  end
  #1 s_bready = 1;
  @(posedge PCLK); while (!s_bvalid) @(posedge PCLK);
  sresp = s_bresp;
  if (s_bid !== 4'h5) fail("BID");
  #1 s_bready = 0;
endtask
task automatic s_rd(input logic [31:0] a, input int n);
  @(negedge PCLK);
  s_araddr = a; s_arlen = 8'(n - 1); s_arid = 4'h6; s_arvalid = 1;
  @(posedge PCLK); while (!s_arready) @(posedge PCLK);
  #1 s_arvalid = 0; s_rready = 1;
  sresp = 0;
  for (int i = 0; i < n; i++) begin
    @(posedge PCLK); while (!s_rvalid) @(posedge PCLK);
    sbuf[i] = s_rdata;
    if (s_rresp != 0) sresp = s_rresp;
    if (s_rid !== 4'h6) fail("RID");
  end
  #1 s_rready = 0;
endtask

task automatic ip_func;
  logic [31:0] pt;
  pt = 32'hFFC0_0000;                               // the table for VA 0..4 GB
  // bypass
  for (int i = 0; i < 4; i++) sbuf[i] = $urandom;
  s_wr(32'h0000_1000, 4);
  if (sresp !== 0 || mem.peek(32'h0000_1000) !== sbuf[0]) fail("bypass write");
  s_rd(32'h0000_1000, 4);
  if (sresp !== 0 || sbuf[3] !== mem.peek(32'h0000_100C)) fail("bypass read");
  // table: VA page 0x00001 -> 0xFFFFE, VA 0xFFFFF -> 0x00002 (read-only), VA 0x00003 not valid
  mem.poke(pt + 4 * 32'h00001, {20'hFFFFE, 12'h003});
  mem.poke(pt + 4 * 32'hFFFFF, {20'h00002, 12'h001});
  mem.poke(pt + 4 * 32'h00003, 32'h0);
  wr(A_PT_BASE, pt);
  wr(A_CMD, 1);
  wr(A_CTRL, 1);
  for (int i = 0; i < 4; i++) sbuf[i] = $urandom;
  s_wr(32'h0000_1FF0, 4);
  if (sresp !== 0 || mem.peek(32'hFFFF_EFF0) !== sbuf[0] || mem.peek(32'hFFFF_EFFC) !== sbuf[3]) fail("translated write");
  mem.poke(32'h0000_2FF8, 32'hCAFE_F00D);
  s_rd(32'hFFFF_FFF8, 2);
  if (sresp !== 0 || sbuf[0] !== 32'hCAFE_F00D) fail("translated read");
  s_rd(32'hFFFF_F000, 1);                           // same page: TLB hit
  rd_exp(A_TLB_STATS, {16'd2, 16'd1});
  wr(A_CMD, 1);                                     // invalidate: walk again
  s_rd(32'hFFFF_F000, 1);
  rd_exp(A_TLB_STATS, {16'd3, 16'd1});
  // faults
  wr(A_IRQ_STATUS, IRQ_ALL);
  s_rd(32'h0000_3010, 2);
  if (sresp !== 2'b10) fail("no SLVERR on an invalid page");
  rd_exp(A_FAULT_ADDR, 32'h0000_3010);
  rd_exp(A_FAULT_INFO, 4'b0001);
  rd(A_IRQ_STATUS); if (!rdv[IRQ_FAULT]) fail("FAULT not set");
  wr(A_IRQ_ENABLE, 1); cycles(1);
  if (irq !== 1) fail("irq low");
  wr(A_IRQ_STATUS, IRQ_ALL); wr(A_IRQ_ENABLE, 0);
  for (int i = 0; i < 4; i++) sbuf[i] = $urandom;
  s_wr(32'hFFFF_F800, 3);
  if (sresp !== 2'b10) fail("no SLVERR on a read-only page");
  rd_exp(A_FAULT_ADDR, 32'hFFFF_F800);
  rd_exp(A_FAULT_INFO, 4'b0110);
  rd_exp(A_STATUS, 0);
  wr(A_CTRL, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  if (mem.errors != 0) fail("AXI rule violations");
endtask
