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

  // CMD.tlb_inv in the clock a walk read returns (inv_in_walk), or in the
  // lookup clock of a read (inv_at_lookup)
  bit inv_in_walk = 0, inv_at_lookup = 0;
  always @(negedge clk) if (inv_in_walk) tlb_inv <= m_rvalid && m_rready && dut.walk;

  // ---------------- upstream BFM ----------------
  logic [1:0] resp, resp_w, resp_r;   // last response; of the last write, of the last read
  logic [31:0] rbuf [256], wbuf [256];   // read data, write data of a burst
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
    if ($urandom % 3 == 0) repeat (1 + $urandom % 3) @(negedge clk);
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
    if (inv_at_lookup) begin   // CMD.tlb_inv in the lookup clock
      tlb_inv = 1; @(posedge clk); #1 tlb_inv = 0;
    end
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
  // a burst with the given attributes; no data check
  task automatic attr_burst(input bit w, input logic [31:0] va, input int n, input logic [3:0] id,
                            input logic [2:0] sz, input logic [1:0] bu, input logic [2:0] pr,
                            input logic [3:0] st);
    s_awsize = sz; s_arsize = sz; s_awburst = bu; s_arburst = bu; s_awprot = pr; s_arprot = pr; s_wstrb = st;
    for (int i = 0; i < n; i++) wbuf[i] = $urandom;
    if (w) wr_burst(va, n, id); else rd_burst(va, n, id);
    s_awsize = 2; s_arsize = 2; s_awburst = 1; s_arburst = 1; s_awprot = 0; s_arprot = 0; s_wstrb = 4'hF;
  endtask
  // slot of the direct-mapped test memory that holds address a
  bit used [256];   // slots taken
  logic [31:0] pt_bases [2] = '{32'h0010_0000, 32'hFFEF_FFFF};
  function automatic int slot(input logic [31:0] a);
    return mem.idx(a) >> 10;
  endfunction
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
    // page table: 12 pages, the top and bottom of the address space included.
    // The test memory is direct mapped (256 slots of 1024 words): the pages
    // are picked so that no data word shares a slot with a page table entry
    // (at either table base used below) or with another page.
    used[slot({20'h12345, 12'h0})] = 1;   // the not-valid page's PPN (never accessed, kept apart anyway)
    foreach (pt_bases[b]) begin
      used[slot(pt_bases[b] + {10'd0, 20'h00000, 2'b00})] = 1;
      used[slot(pt_bases[b] + {10'd0, 20'hFFFFF, 2'b00})] = 1;
      used[slot(pt_bases[b] + {10'd0, 20'h00321, 2'b00})] = 1;
    end
    for (int i = 2; i < 4; i++) begin
      logic [31:0] pg;
      pg = (i == 2) ? 32'hFFFF_E000 : 32'h0000_1000;
      used[slot(pg)] = 1; used[slot(pg + 32'hFFC)] = 1;
    end
    for (int i = 0; i < 12; i++) begin
      logic [19:0] ppn;
      if (i < 2) vp[i] = (i == 0) ? 20'h00000 : 20'hFFFFF;
      else begin
        do vp[i] = 20'($urandom) | 20'h00400;
        while (used[slot(pt_bases[0] + {10'd0, vp[i], 2'b00})] ||
               used[slot(pt_bases[1] + {10'd0, vp[i], 2'b00})]);
        used[slot(pt_bases[0] + {10'd0, vp[i], 2'b00})] = 1;
        used[slot(pt_bases[1] + {10'd0, vp[i], 2'b00})] = 1;
      end
      if (i == 2) ppn = 20'hFFFFE;
      else if (i == 3) ppn = 20'h00001;
      else begin
        do ppn = 20'($urandom) | 20'h80000;
        while (used[slot({ppn, 12'h0})] || used[slot({ppn, 12'hFFC})]);
        used[slot({ppn, 12'h0})] = 1; used[slot({ppn, 12'hFFC})] = 1;
      end
      map(vp[i], ppn, 1, i != 5);
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
    // four pages fit the TLB: no new walks (emptied first: with round-robin
    // refill, loading them into a TLB that already holds one of them can
    // evict another)
    inv();
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
    // ---------------- corners ----------------
    // every attribute forwarded unchanged (the coverage checker checks each
    // one): 1, 2 and 4-byte beats, FIXED / INCR / WRAP, every AxPROT and WSTRB,
    // unaligned addresses, IDs 0 to 15, up to 256 beats; the test memory
    // accepts any burst here (the data of such bursts is not checked)
    mem.any_burst = 1;
    for (int k = 0; k < 96; k++) begin
      int n;
      logic [1:0] bu;
      bu = 2'(k / 2 % 3);
      n = (bu == 2) ? 2 << (k % 4) : (k % 8 < 2) ? 256 : (k % 8 < 4) ? 100 : (k % 8 == 4) ? 16 : 1 + $urandom % 16;
      attr_burst(k % 2, {vp[(k % 12 == 5) ? 6 : k % 12], 12'h0} | 32'($urandom % 4), n, 4'(k), 3'(k % 3), bu,
                 3'(k / 3), 4'(k * 7));
      if (resp !== 0) fail($sformatf("attribute burst %0d: response %0d", k, resp));
    end
    // the page table at an unaligned base with every bit set, then back
    for (int b = 0; b < 2; b++) begin
      pt_base = pt_bases[1 - b];
      for (int i = 0; i < 12; i++) map(vp[i], pte[vp[i]][31:12], 1, i != 5);
      map(20'h00321, 20'h12345, 0, 1);
      inv();
      for (int i = 0; i < 12; i++) check_rd(vp[i], 2);
    end
    mem.any_burst = 0;
    mem.max_awlen = 0; mem.max_arlen = 0;   // (the long bursts above were on purpose)
    // forwarded RRESP / BRESP: every code
    for (int c = 0; c < 4; c++) begin
      mem.err_resp = 2'(c); mem.err_lo = xlate({vp[8], 12'h0}); mem.err_hi = mem.err_lo + 4096;
      rd_burst({vp[8], 12'h010}, 4, 4'd2);
      if (resp !== 2'(c)) fail($sformatf("downstream RRESP %0d passed as %0d", c, resp));
      wr_burst({vp[8], 12'h010}, 4, 4'd2);
      if (resp !== 2'(c)) fail($sformatf("downstream BRESP %0d passed as %0d", c, resp));
    end
    // a walk read with EXOKAY, SLVERR or DECERR: walk fault, on reads and writes
    for (int c = 1; c < 7; c++) begin
      mem.err_resp = 2'(1 + c % 3); mem.err_lo = pt_base + {10'd0, vp[7], 2'b00}; mem.err_hi = mem.err_lo + 4;
      inv();
      expect_fault(c / 4, vp[7], {1'b1, 1'(c / 4), 2'b00});
    end
    mem.err_lo = '1; mem.err_hi = '1; mem.err_resp = 2'b10;
    // faults at the top of the address space and at unaligned addresses
    map(20'h90321, 20'h12345, 0, 1);
    expect_fault(0, 20'h90321, 4'b0001);
    for (int k = 1; k < 4; k++) begin
      attr_burst(1, {vp[5], 12'h100} | 32'(k), 1, 4'd3, 3'd0, 2'd1, 3'd0, 4'h1);
      if (resp !== 2'b10 || fault_addr !== ({vp[5], 12'h100} | 32'(k))) fail("unaligned write fault");
    end
    // more faults (upstream stalls on the error response)
    for (int k = 0; k < 8; k++) expect_fault(k % 2, 20'h00321, {1'b0, 1'(k % 2), 2'b01});
    // CMD.tlb_inv in the lookup clock of a hit: the page is walked again
    check_rd(vp[2], 2);
    w0 = n_walks; inv_at_lookup = 1;
    check_rd(vp[2], 2);
    inv_at_lookup = 0;
    if (n_walks != w0 + 1) fail("no walk after CMD.tlb_inv in the lookup clock");
    // CMD.tlb_inv in the clock the walk read returns: the new entry is kept
    inv(); inv_in_walk = 1;
    check_rd(vp[4], 2);
    inv_in_walk = 0;
    w0 = n_walks;
    check_rd(vp[4], 2);
    if (n_walks != w0) fail("entry filled with CMD.tlb_inv lost");
    // read and write waiting together, both orders
    for (int k = 0; k < 4; k++) fork
      check_rd(vp[9 + k % 2], 1 + k);
      check_wr(vp[10 - k % 2], 2 + k);
    join
    // ENABLE dropped in the middle of a burst: the burst ends as translated
    fork
      check_rd(vp[0], 16);
      begin while (dut.st != 5) @(negedge clk); enable = 0; end
    join
    clks(2);
    enable = 1;
    // HITS and MISSES saturate at 16'hFFFF (long run: +cov_long, coverage only)
    if ($test$plusargs("cov_long")) begin
      mem.stall = 0;
      for (int k = 0; k < 65540; k++) rd_burst({20'h00321, 12'h0}, 1, 4'd1);   // a page that is not valid: never cached
      check_rd(vp[0], 1);
      for (int k = 0; k < 65540; k++) rd_burst({vp[0], 12'h0}, 1, 4'd1);
      if (hits !== 16'hFFFF || misses !== 16'hFFFF) fail($sformatf("HITS %h MISSES %h not saturated", hits, misses));
      mem.stall = 1;
    end
    // reset in the middle of a walk
    inv();
    fork : walk_mid
      rd_burst({vp[6], 12'h0}, 2, 4'd1);
    join_none
    while (dut.st != 3) @(negedge clk);
    @(negedge clk); rst_n = 0; clks(2);
    disable walk_mid;
    s_rready = 0;
    rst_n = 1; clks(3);
    // reset in the middle of a write burst
    fork : wr_mid
      wr_burst({vp[3], 12'h0}, 16, 4'd1);
    join_none
    while (dut.st != 6) @(negedge clk);
    @(negedge clk); rst_n = 0; clks(2);
    disable wr_mid;
    s_awvalid = 0; s_wvalid = 0; s_wlast = 0; s_bready = 0;
    rst_n = 1; clks(3);
    // reset in the middle of a read burst
    inv();
    @(negedge clk);
    s_araddr = {vp[0], 12'h0}; s_arlen = 15; s_arid = 1; s_arvalid = 1;
    @(posedge clk); while (!s_arready) @(posedge clk);
    #1 s_arvalid = 0;
    while (dut.st != 5) @(negedge clk);
    @(negedge clk);
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
