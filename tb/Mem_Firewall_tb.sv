// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of Mem_Firewall_top (TV SoC, AXI4 subordinate
// in, AXI4 manager out). A TB initiator issues random bursts (INCR / FIXED /
// WRAP, 1..16 beats, secure and non-secure, IDs 0..15) against random region
// setups; an independent reference model (walks every beat address) decides
// allow / deny. Allowed bursts must reach the AXI4 memory model unchanged
// (write data in memory, read data back, OKAY); denied ones must never
// appear on m_* and answer DECERR (writes: all W beats taken, memory
// unchanged; reads: AxLEN + 1 zero beats with RLAST). Also: FAULT record
// (first fault kept until fault_clr), DENIED_CNT, ENABLE 0 bypass, reads and
// writes in parallel, random memory stalls, reset. Prints LAT lines.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module Mem_Firewall_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  logic        enable = 0, fault_clr = 0;
  logic [31:0] rgn0_base = 0, rgn0_limit = 0, rgn1_base = 0, rgn1_limit = 0;
  logic [31:0] rgn2_base = 0, rgn2_limit = 0, rgn3_base = 0, rgn3_limit = 0;
  logic [3:0]  rgn0_attr = 0, rgn1_attr = 0, rgn2_attr = 0, rgn3_attr = 0;
  wire  [7:0]  fault_info;
  wire  [31:0] fault_addr;
  wire  [15:0] denied_cnt;
  wire         fault;
  // subordinate side, driven by the TB initiator
  logic [3:0]  s_awid = 0, s_arid = 0;
  logic [31:0] s_awaddr = 0, s_araddr = 0, s_wdata = 0;
  logic [7:0]  s_awlen = 0, s_arlen = 0;
  logic [2:0]  s_awsize = 2, s_arsize = 2, s_awprot = 0, s_arprot = 0;
  logic [1:0]  s_awburst = 1, s_arburst = 1;
  logic        s_awvalid = 0, s_wvalid = 0, s_wlast = 0, s_bready = 0, s_arvalid = 0, s_rready = 0;
  logic [3:0]  s_wstrb = 4'hF;
  wire         s_awready, s_wready, s_bvalid, s_arready, s_rvalid, s_rlast;
  wire  [3:0]  s_bid, s_rid;
  wire  [1:0]  s_bresp, s_rresp;
  wire  [31:0] s_rdata;
  Mem_Firewall_top dut (.*);

  int n_fault = 0;
  always @(posedge clk) if (rst_n && fault) n_fault += int'(dut.w_den) + int'(dut.r_den);   // both may fire in one clock

  // ---------------- reference model ----------------
  function automatic bit ref_allowed(input logic [31:0] a, input int len, input int sz, input int bu,
                                     input bit ns, input bit wr);
    logic [31:0] lo, hi, b, cont, n;
    logic [31:0] bs [4], lm [4];
    logic [3:0]  at [4];
    bs = '{rgn0_base, rgn1_base, rgn2_base, rgn3_base};
    lm = '{rgn0_limit, rgn1_limit, rgn2_limit, rgn3_limit};
    at = '{rgn0_attr, rgn1_attr, rgn2_attr, rgn3_attr};
    if (!enable) return 1;
    n = 32'(len + 1) << sz;
    cont = a & ~(n - 1);
    lo = 32'hFFFF_FFFF; hi = 0;
    for (int i = 0; i <= len; i++) begin
      case (bu)
        0: b = a;
        2: b = cont + ((a - cont + 32'(i << sz)) % n);
        default: b = a + 32'(i << sz);
      endcase
      if (bu != 1 && b < lo) lo = b;
      if (bu == 1 && i == 0) lo = b;
      if (b + (32'd1 << sz) - 1 > hi) hi = b + (32'd1 << sz) - 1;
      if (bu == 1 && b + (32'd1 << sz) - 1 < b) return 0;      // wraps the address space
    end
    for (int r = 0; r < 4; r++)
      if (at[r][0] && lo >= bs[r] && hi <= lm[r] && (wr ? at[r][2] : at[r][1]) && (!at[r][3] || !ns)) return 1;
    return 0;
  endfunction

  // ---------------- TB initiator ----------------
  int n_bad = 0;
  task automatic wr_burst(input logic [31:0] a, input int len, input int sz, input int bu, input bit ns,
                          input logic [3:0] id);
    bit ok;
    logic [31:0] d [16], old [16];
    int nb0;
    ok = ref_allowed(a, len, sz, bu, ns, 1);
    for (int i = 0; i <= len; i++) begin d[i] = $urandom; old[i] = mem.peek(a + 32'(4 * i)); end
    nb0 = mem.n_wr_bursts;
    @(negedge clk);
    s_awaddr = a; s_awlen = 8'(len); s_awsize = 3'(sz); s_awburst = 2'(bu); s_awprot = {1'b0, ns, 1'b0};
    s_awid = id; s_awvalid = 1;
    @(posedge clk); while (!s_awready) @(posedge clk);
    @(negedge clk); s_awvalid = 0;
    for (int i = 0; i <= len; i++) begin
      if ($urandom % 3 == 0) clks(1 + $urandom % 3);
      s_wdata = d[i]; s_wlast = (i == len); s_wvalid = 1;
      @(posedge clk); while (!s_wready) @(posedge clk);
      @(negedge clk); s_wvalid = 0; s_wlast = 0;
    end
    s_bready = ($urandom % 2);
    while (1) begin
      @(posedge clk);
      if (s_bvalid && s_bready) break;
      #1 s_bready = 1;
    end
    if (s_bid !== id) fail($sformatf("BID %0d, expected %0d", s_bid, id));
    if (s_bresp !== (ok ? 2'b00 : 2'b11)) fail($sformatf("write %h len %0d sz %0d bu %0d ns %b: BRESP %b, allowed %b", a, len, sz, bu, ns, s_bresp, ok));
    @(negedge clk); s_bready = 0;
    if (ok) begin
      for (int i = 0; i <= len; i++) if (mem.peek(a + 32'(4 * i)) !== d[i] && n_bad++ < 5) fail($sformatf("write %h beat %0d not in memory", a, i));
    end else begin
      if (mem.n_wr_bursts != nb0) fail("a denied write reached memory");
      for (int i = 0; i <= len; i++) if (sz == 2 && bu == 1 && mem.peek(a + 32'(4 * i)) !== old[i]) fail("a denied write changed memory");
    end
  endtask
  task automatic rd_burst(input logic [31:0] a, input int len, input int sz, input int bu, input bit ns,
                          input logic [3:0] id);
    bit ok;
    int nb0;
    ok = ref_allowed(a, len, sz, bu, ns, 0);
    nb0 = mem.n_rd_bursts;
    @(negedge clk);
    s_araddr = a; s_arlen = 8'(len); s_arsize = 3'(sz); s_arburst = 2'(bu); s_arprot = {1'b0, ns, 1'b0};
    s_arid = id; s_arvalid = 1;
    @(posedge clk); while (!s_arready) @(posedge clk);
    @(negedge clk); s_arvalid = 0;
    for (int i = 0; i <= len; i++) begin
      s_rready = ($urandom % 3) != 0;
      while (1) begin
        @(posedge clk);
        if (s_rvalid && s_rready) break;
        #1 s_rready = 1;
      end
      if (s_rid !== id) fail("RID");
      if (s_rlast !== (i == len)) fail($sformatf("RLAST %b on beat %0d of %0d", s_rlast, i, len + 1));
      if (s_rresp !== (ok ? 2'b00 : 2'b11)) fail($sformatf("read %h len %0d sz %0d bu %0d ns %b: RRESP %b, allowed %b", a, len, sz, bu, ns, s_rresp, ok));
      if (ok && s_rdata !== mem.peek(a + 32'(4 * i)) && n_bad++ < 5) fail($sformatf("read %h beat %0d data", a, i));
      if (!ok && s_rdata !== 0) fail("denied read data not zero");
      @(negedge clk); s_rready = 0;
    end
    if (!ok && mem.n_rd_bursts != nb0) fail("a denied read reached memory");
  endtask

  // a random region layout in 0x1000_0000 .. 0x1010_0000
  task automatic rand_regions;
    logic [31:0] b, l;
    for (int r = 0; r < 4; r++) begin
      b = 32'h1000_0000 + 32'(($urandom % 64) * 1024);
      l = b + 32'(($urandom % 16 + 1) * 1024) - 1;
      case (r)
        0: begin rgn0_base = b; rgn0_limit = l; rgn0_attr = ($urandom % 2) ? 4'b0111 : 4'($urandom | 1); end
        1: begin rgn1_base = b; rgn1_limit = l; rgn1_attr = $urandom; end
        2: begin rgn2_base = b; rgn2_limit = l; rgn2_attr = $urandom; end
        default: begin rgn3_base = b; rgn3_limit = l; rgn3_attr = $urandom; end
      endcase
    end
  endtask
  // an address near a region edge (or anywhere in the window)
  function automatic logic [31:0] rand_addr;
    logic [31:0] e;
    case ($urandom % 7)
      0: e = rgn0_base; 1: e = rgn0_limit + 1; 2: e = rgn1_base; 3: e = rgn2_limit + 1;
      4, 5: e = rgn0_base + 32'($urandom % (rgn0_limit - rgn0_base + 1));
      default: e = 32'h1000_0000 + 32'($urandom % 32'h10_0000);
    endcase
    return (e + 32'(int'($urandom % 129) - 64)) & 32'hFFFF_FFFC;
  endfunction

  int n_allow = 0, n_deny = 0;
  task automatic rand_access(input bit wr);
    logic [31:0] a; int len, sz, bu; bit ns;
    a = rand_addr();
    len = $urandom % 16;
    a = a & ~32'hFFF | (a & 32'hFFF) % (32'd4096 - 32'(4 * (len + 1)));   // INCR never crosses 4 KB
    ns = $urandom % 2;
    sz = 2; bu = 1;
    if ($urandom % 4 == 0) begin
      // FIXED / WRAP / other sizes: only when denied (the memory model takes INCR words only)
      bu = ($urandom % 2) ? 0 : 2; if (bu == 2) len = (1 << ($urandom % 4 + 1)) - 1;
      sz = $urandom % 3;
      if (bu == 2) a = a & ~32'((1 << sz) - 1);
      if (ref_allowed(a, len, sz, bu, ns, wr)) begin sz = 2; bu = 1; end
      if (bu != 1 && enable == 0) begin sz = 2; bu = 1; end
    end
    if (ref_allowed(a, len, sz, bu, ns, wr)) n_allow++; else n_deny++;
    if (wr) wr_burst(a, len, sz, bu, ns, $urandom); else rd_burst(a, len, sz, bu, ns, $urandom);
  endtask

  initial begin
    lat_master = "fw";
    clks(3);
    rst_n = 1;
    clks(2);
    // disabled: everything passes
    rand_regions();
    for (int k = 0; k < 10; k++) rand_access(k % 2);
    if (denied_cnt != 0 || n_fault != 0) fail("faults while disabled");
    enable = 1;
    // random layouts, serial and parallel traffic
    for (int lay = 0; lay < 12; lay++) begin
      rand_regions();
      mem.stall = lay % 3 != 2;
      for (int k = 0; k < 12; k++) rand_access($urandom % 2);
      fork
        for (int k = 0; k < 6; k++) rand_access(1);
        for (int k = 0; k < 6; k++) rand_access(0);
      join
    end
    if (n_allow < 50 || n_deny < 50) fail($sformatf("weak mix: %0d allowed, %0d denied", n_allow, n_deny));
    if (denied_cnt !== 16'(n_deny)) fail($sformatf("DENIED_CNT %0d, expected %0d", denied_cnt, n_deny));
    if (n_fault != n_deny) fail("FAULT pulse count");
    // fault record: the first fault is kept, fault_clr empties it
    @(negedge clk); fault_clr = 1; @(negedge clk); fault_clr = 0;
    if (fault_info !== 0) fail("fault_clr");
    rgn0_base = 32'h2000_0000; rgn0_limit = 32'h2000_0FFF; rgn0_attr = 4'b1011;   // secure-only, read
    rgn1_attr = 0; rgn2_attr = 0; rgn3_attr = 0;
    rd_burst(32'h2000_0100, 3, 2, 1, 0, 4'h3);                                     // secure read: OK
    if (fault_info !== 0) fail("allowed access recorded a fault");
    rd_burst(32'h2000_0100, 3, 2, 1, 1, 4'h9);                                     // non-secure: denied
    if (fault_info !== {4'h9, 1'b1, 1'b1, 1'b0, 1'b1} || fault_addr !== 32'h2000_0100) fail($sformatf("fault record %h %h", fault_info, fault_addr));
    wr_burst(32'h2000_0200, 0, 2, 1, 0, 4'h2);                                     // write: no permission
    if (fault_addr !== 32'h2000_0100) fail("second fault overwrote the first");
    @(negedge clk); fault_clr = 1; @(negedge clk); fault_clr = 0;
    wr_burst(32'h2000_0200, 0, 2, 1, 0, 4'h2);
    if (fault_info !== {4'h2, 1'b0, 1'b1, 1'b1, 1'b1} || fault_addr !== 32'h2000_0200) fail($sformatf("write fault record %h %h", fault_info, fault_addr));
    // WRAP whose container ends at LIMIT but whose start + length would pass
    // it: allowed. The memory model takes INCR only and reports the WRAP type
    // once; that one report is expected and removed from its error count.
    begin
      int e0;
      rgn0_limit = 32'h2000_0FEF;
      e0 = mem.errors;
      $display("(expected below: one axi_mem report of AR burst type 2)");
      rd_burst(32'h2000_0FE8, 3, 2, 2, 0, 4'h6);
      if (mem.errors != e0 + 1) fail("WRAP inside the region not forwarded");
      mem.errors = e0;
      rd_burst(32'h2000_0FF8, 3, 2, 2, 0, 4'h6);                                   // container past LIMIT: denied
      rgn0_limit = 32'h2000_0FFF;
    end
    // a burst running past LIMIT by one word
    rd_burst(32'h2000_0FF0, 4, 2, 1, 0, 4'h1);
    // reset with traffic in flight
    fork
      rd_burst(32'h2000_0000, 15, 2, 1, 0, 4'h1);
      begin clks(6); rst_n = 0; end
    join_any
    disable fork;
    s_arvalid = 0; s_awvalid = 0; s_wvalid = 0; s_rready = 0; s_bready = 0;
    clks(2);
    if (m_arvalid || m_awvalid || m_wvalid || s_rvalid || s_bvalid) fail("not idle in reset");
    if (denied_cnt != 0 || fault_info != 0) fail("fault state not reset");
    rst_n = 1; clks(2);
    rd_burst(32'h2000_0000, 7, 2, 1, 0, 4'h1);
    lat_summary();
    finish("Mem_Firewall");
  end
endmodule
