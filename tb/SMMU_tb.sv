// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of SMMU_top (IOMMU between an upstream AXI4
// master and the interconnect). An upstream master BFM drives s_*; the
// behavioural AXI4 memory on m_* holds both the page table and the data.
// Checked against a reference page table: random read and write bursts of
// 1 to 16 beats on mapped pages land at the translated physical address
// (and only there), read data and BRESP / RRESP / IDs come back unchanged;
// page walks are single-beat reads at PT_BASE + 4 * VPN with ID PTW_ID;
// TLB hits and misses (4 entries, round robin), CMD.tlb_inv; faults on an
// invalid page, on a write to a read-only page, and on a walk read error:
// SLVERR upstream with every W beat taken, nothing forwarded, FAULT_ADDR /
// FAULT_INFO / the FAULT interrupt; bypass (ENABLE 0); read and write
// requests waiting together; reset in the middle of a burst.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module SMMU_tb;
  `include "soc_ss_tb_common.svh"
  logic        enable = 0, tlb_inv = 0;
  logic [31:0] pt_base = 32'h0010_0000;
  wire  [31:0] fault_addr;
  wire  [3:0]  fault_info;
  wire  [15:0] hits, misses;
  wire         busy, fault;
  // upstream port (driven by the BFM below)
  logic [3:0]  s_awid = 0, s_arid = 0;
  logic [31:0] s_awaddr = 0, s_araddr = 0, s_wdata = 0;
  logic [7:0]  s_awlen = 0, s_arlen = 0;
  logic [2:0]  s_awsize = 2, s_arsize = 2, s_awprot = 0, s_arprot = 0;
  logic [1:0]  s_awburst = 1, s_arburst = 1;
  logic [3:0]  s_wstrb = 4'hF;
  logic        s_awvalid = 0, s_arvalid = 0, s_wvalid = 0, s_wlast = 0, s_bready = 0, s_rready = 0;
  wire         s_awready, s_arready, s_wready, s_bvalid, s_rvalid, s_rlast;
  wire  [3:0]  s_bid, s_rid;
  wire  [1:0]  s_bresp, s_rresp;
  wire  [31:0] s_rdata;
  SMMU_top dut (.*);

  int n_fault = 0, n_walks = 0, n_fwd = 0;
  always @(posedge clk) if (rst_n) begin
    n_fault += fault;
    if (m_arvalid && m_arready) begin
      if (dut.walk) begin
        n_walks++;
        if (m_arid !== 4'hF || m_arlen !== 0) fail("walk read: ID or length");
      end else n_fwd++;
    end
    if (m_awvalid && m_awready) n_fwd++;
  end

  // reference page table: vpn -> pte
  logic [31:0] pte [1048576];
  function automatic void map(input logic [19:0] vpn, input logic [19:0] ppn, input bit v, input bit w);
    pte[vpn] = {ppn, 10'd0, w, v};
    mem.poke(pt_base + {10'd0, vpn, 2'b00}, pte[vpn]);
  endfunction
  function automatic logic [31:0] xlate(input logic [31:0] va);
    return enable ? {pte[va[31:12]][31:12], va[11:0]} : va;
  endfunction

  // ---------------- upstream BFM ----------------
  logic [1:0] resp, resp_w, resp_r;   // last response; of the last write, of the last read
  logic [31:0] rbuf [16], wbuf [16];   // read data, write data of a burst
  task automatic wr_burst(input logic [31:0] a, input int n, input logic [3:0] id);   // data: wbuf
    @(negedge clk);
    s_awaddr = a; s_awlen = 8'(n - 1); s_awid = id; s_awvalid = 1;
    @(posedge clk); while (!s_awready) @(posedge clk);
    #1 s_awvalid = 0;
    for (int i = 0; i < n; i++) begin
      if ($urandom % 3 == 0) repeat (1 + $urandom % 3) @(negedge clk);
      #1 s_wvalid = 1; s_wdata = wbuf[i]; s_wlast = (i == n - 1);
      @(posedge clk); while (!s_wready) @(posedge clk);
      #1 s_wvalid = 0; s_wlast = 0;
    end
    #1 s_bready = 1;
    @(posedge clk); while (!s_bvalid) @(posedge clk);
    resp_w = s_bresp; resp = resp_w;
    if (s_bid !== id) fail($sformatf("BID %h, expected %h", s_bid, id));
    #1 s_bready = 0;
  endtask
  task automatic rd_burst(input logic [31:0] a, input int n, input logic [3:0] id);
    @(negedge clk);
    s_araddr = a; s_arlen = 8'(n - 1); s_arid = id; s_arvalid = 1;
    @(posedge clk); while (!s_arready) @(posedge clk);
    #1 s_arvalid = 0;
    resp_r = 0;
    for (int i = 0; i < n; i++) begin
      #1 s_rready = ($urandom % 4 != 0);
      @(posedge clk); while (!(s_rvalid && s_rready)) begin #1 s_rready = 1; @(posedge clk); end
      rbuf[i] = s_rdata;
      if (s_rresp != 0) resp_r = s_rresp;
      if (s_rid !== id) fail($sformatf("RID %h, expected %h", s_rid, id));
      if (s_rlast !== (i == n - 1)) fail($sformatf("RLAST %b on beat %0d of %0d", s_rlast, i, n));
      #1 s_rready = 0;
    end
    resp = resp_r;
  endtask

  // a burst at a random offset of page vpn that fits in the page
  function automatic logic [31:0] va_in(input logic [19:0] vpn, input int n);
    return {vpn, 12'(4 * ($urandom % (1024 - n + 1)))};
  endfunction
  task automatic check_wr(input logic [19:0] vpn, input int n);
    logic [31:0] va, pa, d [16];
    va = va_in(vpn, n); pa = xlate(va);
    for (int i = 0; i < n; i++) begin d[i] = $urandom; mem.poke(va + 4 * i, 32'h5A5A_0000 ^ i); end
    for (int i = 0; i < 16; i++) wbuf[i] = d[i];
    wr_burst(va, n, 4'($urandom % 8));
    if (resp_w !== 0) fail($sformatf("write %h: BRESP %0d", va, resp_w));
    for (int i = 0; i < n; i++) if (mem.peek(pa + 4 * i) !== d[i]) begin
      fail($sformatf("write VA %h -> PA %h beat %0d: %h, expected %h", va, pa, i, mem.peek(pa + 4 * i), d[i])); break;
    end
    if (pa != va && mem.peek(va) !== 32'h5A5A_0000) fail("write reached the untranslated address");
  endtask
  task automatic check_rd(input logic [19:0] vpn, input int n);
    logic [31:0] va, pa;
    va = va_in(vpn, n); pa = xlate(va);
    for (int i = 0; i < n; i++) mem.poke(pa + 4 * i, $urandom);
    rd_burst(va, n, 4'($urandom % 8));
    if (resp_r !== 0) fail($sformatf("read %h: RRESP %0d", va, resp_r));
    for (int i = 0; i < n; i++) if (rbuf[i] !== mem.peek(pa + 4 * i)) begin
      fail($sformatf("read VA %h -> PA %h beat %0d: %h, expected %h", va, pa, i, rbuf[i], mem.peek(pa + 4 * i))); break;
    end
  endtask
  task automatic inv;
    @(negedge clk); tlb_inv = 1; @(negedge clk); tlb_inv = 0;
  endtask
  task automatic expect_fault(input bit w, input logic [19:0] vpn, input logic [3:0] info);
    logic [31:0] va;
    int f0, fw0;
    va = va_in(vpn, 4);
    f0 = n_fault; fw0 = n_fwd;
    for (int i = 0; i < 4; i++) wbuf[i] = $urandom;
    if (w) wr_burst(va, 4, 4'd3); else rd_burst(va, 4, 4'd3);
    clks(2);
    if (resp !== 2'b10) fail($sformatf("fault %h: response %0d, expected SLVERR", va, resp));
    if (n_fault != f0 + 1) fail("FAULT interrupt count");
    if (n_fwd != fw0) fail("faulting burst was forwarded");
    if (fault_addr !== va) fail($sformatf("FAULT_ADDR %h, expected %h", fault_addr, va));
    if (fault_info !== info) fail($sformatf("FAULT_INFO %b, expected %b", fault_info, info));
    if (!w) for (int i = 0; i < 4; i++) if (rbuf[i] !== 0) fail("fault read data not 0");
  endtask

  initial begin
    int h0, m0, w0;
    logic [19:0] vp [12];
    clks(3);
    rst_n = 1;
    clks(2);
    // bypass
    for (int k = 0; k < 6; k++) begin check_wr(20'($urandom), 1 + $urandom % 16); check_rd(20'($urandom), 1 + $urandom % 16); end
    if (n_walks != 0 || misses != 0) fail("walks in bypass");
    // page table: 12 pages, the top and bottom of the address space included
    for (int i = 0; i < 12; i++) begin
      vp[i] = (i == 0) ? 20'h00000 : (i == 1) ? 20'hFFFFF : 20'($urandom) | 20'h00400;
      map(vp[i], (i == 2) ? 20'hFFFFE : (i == 3) ? 20'h00001 : 20'($urandom) | 20'h80000, 1, i != 5);
    end
    map(20'h00321, 20'h12345, 0, 1);    // not valid
    enable = 1;
    inv();
    // first touch walks, second hits
    h0 = hits; m0 = misses; w0 = n_walks;
    check_rd(vp[0], 4);
    check_rd(vp[0], 8);
    if (misses != m0 + 1 || hits != h0 + 1 || n_walks != w0 + 1) fail($sformatf("miss / hit: %0d / %0d", misses - m0, hits - h0));
    // random traffic over 12 pages with a 4-entry TLB
    for (int k = 0; k < 120; k++) begin
      mem.stall = (k % 5) != 4;
      if ($urandom % 2 && pte[vp[k % 12]][1]) check_wr(vp[$urandom % 12] == vp[5] ? vp[6] : vp[k % 12], 1 + $urandom % 16);
      else check_rd(vp[$urandom % 12], 1 + $urandom % 16);
    end
    // four pages fit the TLB: no new walks
    for (int i = 0; i < 4; i++) check_rd(vp[i], 2);
    w0 = n_walks;
    for (int k = 0; k < 12; k++) check_rd(vp[k % 4], 2);
    if (n_walks != w0) fail("walks with the working set in the TLB");
    inv();
    w0 = n_walks;
    check_rd(vp[1], 2);
    if (n_walks != w0 + 1) fail("no walk after CMD.tlb_inv");
    // faults
    expect_fault(0, 20'h00321, 4'b0001);       // read, not valid
    expect_fault(1, 20'h00321, 4'b0101);       // write, not valid
    expect_fault(1, vp[5], 4'b0110);           // write to a read-only page
    check_rd(vp[5], 3);                        // reading it is fine
    mem.err_lo = pt_base + {10'd0, vp[7], 2'b00}; mem.err_hi = mem.err_lo + 4;
    inv();
    expect_fault(0, vp[7], 4'b1000);           // walk read error
    mem.err_lo = '1; mem.err_hi = '1;
    check_rd(vp[7], 3);                        // retried walk succeeds
    // downstream error responses pass through unchanged
    mem.err_lo = xlate({vp[8], 12'h0}); mem.err_hi = mem.err_lo + 4096;
    begin
      rd_burst({vp[8], 12'h010}, 4, 4'd2);
      if (resp !== 2'b10) fail("downstream SLVERR not passed on a read");
      wr_burst({vp[8], 12'h010}, 4, 4'd2);
      if (resp !== 2'b10) fail("downstream SLVERR not passed on a write");
    end
    mem.err_lo = '1; mem.err_hi = '1;
    // a read and a write waiting together are both served
    fork
      check_rd(vp[9], 8);
      check_wr(vp[10], 8);
    join
    // reset in the middle of a read burst
    @(negedge clk);
    s_araddr = {vp[0], 12'h0}; s_arlen = 15; s_arid = 1; s_arvalid = 1;
    @(posedge clk); while (!s_arready) @(posedge clk);
    #1 s_arvalid = 0;
    clks(4);
    rst_n = 0; clks(2);
    if (busy || m_arvalid || m_awvalid || s_rvalid || s_bvalid) fail("not idle in reset");
    rst_n = 1; clks(5);
    if (hits !== 0 || misses !== 0) fail("counters not reset");
    inv();
    check_rd(vp[2], 5);
    check_wr(vp[3], 5);
    $display("SMMU: %0d walks, %0d bursts forwarded, %0d faults", n_walks, n_fwd, n_fault);
    finish("SMMU");
  end
endmodule
