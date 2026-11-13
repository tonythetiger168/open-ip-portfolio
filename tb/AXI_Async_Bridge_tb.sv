// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench of AXI_Async_Bridge_top
// ----------------------------------------------------------------------------
//  - Every channel is driven as a stream with random contents: AW, W and AR
//    from the s side, B and R from the m side. Each beat is queued when its
//    write-side handshake happens and must come out on the other side next,
//    unchanged (a scoreboard per channel).
//  - Phases with different clock ratios (s faster, m faster, nearly equal)
//    and different valid gaps / ready rates, so every FIFO runs empty, full
//    and in between.
//  - Reset of both sides while the FIFOs hold data: nothing may come out
//    afterwards except what is sent after the reset.
// ============================================================================
`timescale 1ns/1ps
module AXI_Async_Bridge_tb;
  localparam int IDW = 8, DEPTH = 8;
  localparam int AW_W = IDW + 32 + 8 + 3 + 2, W_W = 32 + 4 + 1, B_W = IDW + 2, R_W = IDW + 32 + 2 + 1;

  real  hs = 5.0, hm = 13.5;                 // half periods (ns)
  logic s_clk = 0, m_clk = 0, s_rst_n = 0, m_rst_n = 0;
  always #(hs) s_clk = ~s_clk;
  always #(hm) m_clk = ~m_clk;

  logic [IDW-1:0] s_awid, s_bid, s_arid, s_rid, m_awid, m_bid, m_arid, m_rid;
  logic [31:0]    s_awaddr, s_wdata, s_araddr, s_rdata, m_awaddr, m_wdata, m_araddr, m_rdata;
  logic [7:0]     s_awlen, s_arlen, m_awlen, m_arlen;
  logic [2:0]     s_awsize, s_arsize, m_awsize, m_arsize;
  logic [1:0]     s_awburst, s_arburst, s_bresp, s_rresp, m_awburst, m_arburst, m_bresp, m_rresp;
  logic [3:0]     s_wstrb, m_wstrb;
  logic s_awvalid = 0, s_awready, s_wlast, s_wvalid = 0, s_wready, s_bvalid, s_bready = 0;
  logic s_arvalid = 0, s_arready, s_rlast, s_rvalid, s_rready = 0;
  logic m_awvalid, m_awready = 0, m_wlast, m_wvalid, m_wready = 0, m_bvalid = 0, m_bready;
  logic m_arvalid, m_arready = 0, m_rlast, m_rvalid = 0, m_rready;
  logic resp_err;

  AXI_Async_Bridge_top #(.IDW(IDW), .DEPTH(DEPTH)) dut (.*);

  int errors = 0;
  // RESP_ERR: one pulse per B / R beat with SLVERR or DECERR handed to the s side
  int n_resp_err = 0, n_resp_err_exp = 0;
  always @(posedge s_clk) begin
    if (resp_err) n_resp_err++;
    if ((s_bvalid && s_bready && s_bresp[1]) || (s_rvalid && s_rready && s_rresp[1])) n_resp_err_exp++;
  end
  int sent[5], rcvd[5];
  // ready / valid rates (percent), set per phase
  int s_rdy = 100, m_rdy = 100, s_gap = 0, m_gap = 0;

  logic [AW_W-1:0] q_aw [$];
  logic [W_W-1:0]  q_w  [$];
  logic [AW_W-1:0] q_ar [$];
  logic [B_W-1:0]  q_b  [$];
  logic [R_W-1:0]  q_r  [$];

  function automatic logic [31:0] rdata32(input int k);
    // data classes now and then: zeros, ones, 0x55.., 0xAA..
    case ($urandom_range(0, 9))
      0: return 32'h0;
      1: return 32'hFFFF_FFFF;
      2: return k[0] ? 32'hAAAA_AAAA : 32'h5555_5555;
      default: return $urandom;
    endcase
  endfunction

  // ---------------- s-side producers ----------------
  task automatic p_aw(input int n);
    logic [AW_W-1:0] v;
    for (int k = 0; k < n; k++) begin
      @(negedge s_clk); s_awvalid = 0;
      while ($urandom_range(0, 99) < s_gap) @(negedge s_clk);
      v = {IDW'($urandom), 32'($urandom), 8'($urandom), 3'($urandom), 2'($urandom)};
      {s_awid, s_awaddr, s_awlen, s_awsize, s_awburst} = v; s_awvalid = 1;
      while (!s_awready) @(negedge s_clk);
      @(posedge s_clk); q_aw.push_back(v); sent[0]++;
    end
    @(negedge s_clk); s_awvalid = 0;
  endtask
  task automatic p_w(input int n);
    logic [W_W-1:0] v;
    for (int k = 0; k < n; k++) begin
      @(negedge s_clk); s_wvalid = 0;
      while ($urandom_range(0, 99) < s_gap) @(negedge s_clk);
      v = {rdata32(k), 4'($urandom), 1'($urandom)};
      {s_wdata, s_wstrb, s_wlast} = v; s_wvalid = 1;
      while (!s_wready) @(negedge s_clk);
      @(posedge s_clk); q_w.push_back(v); sent[1]++;
    end
    @(negedge s_clk); s_wvalid = 0;
  endtask
  task automatic p_ar(input int n);
    logic [AW_W-1:0] v;
    for (int k = 0; k < n; k++) begin
      @(negedge s_clk); s_arvalid = 0;
      while ($urandom_range(0, 99) < s_gap) @(negedge s_clk);
      v = {IDW'($urandom), 32'($urandom), 8'($urandom), 3'($urandom), 2'($urandom)};
      {s_arid, s_araddr, s_arlen, s_arsize, s_arburst} = v; s_arvalid = 1;
      while (!s_arready) @(negedge s_clk);
      @(posedge s_clk); q_ar.push_back(v); sent[2]++;
    end
    @(negedge s_clk); s_arvalid = 0;
  endtask
  // ---------------- m-side producers ----------------
  task automatic p_b(input int n);
    logic [B_W-1:0] v;
    for (int k = 0; k < n; k++) begin
      @(negedge m_clk); m_bvalid = 0;
      while ($urandom_range(0, 99) < m_gap) @(negedge m_clk);
      v = {IDW'($urandom), 2'($urandom)};
      {m_bid, m_bresp} = v; m_bvalid = 1;
      while (!m_bready) @(negedge m_clk);
      @(posedge m_clk); q_b.push_back(v); sent[3]++;
    end
    @(negedge m_clk); m_bvalid = 0;
  endtask
  task automatic p_r(input int n);
    logic [R_W-1:0] v;
    for (int k = 0; k < n; k++) begin
      @(negedge m_clk); m_rvalid = 0;
      while ($urandom_range(0, 99) < m_gap) @(negedge m_clk);
      v = {IDW'($urandom), rdata32(k), 2'($urandom), 1'($urandom)};
      {m_rid, m_rdata, m_rresp, m_rlast} = v; m_rvalid = 1;
      while (!m_rready) @(negedge m_clk);
      @(posedge m_clk); q_r.push_back(v); sent[4]++;
    end
    @(negedge m_clk); m_rvalid = 0;
  endtask

  // ---------------- consumers (always running) ----------------
  task automatic miss(input string ch, input logic [127:0] got, input logic [127:0] exp, input bit empty);
    errors++;
    if (empty) $display("ERROR: %s beat %h with nothing sent", ch, got);
    else       $display("ERROR: %s beat %h, expected %h", ch, got, exp);
  endtask
  initial forever begin
    @(negedge m_clk); m_awready = $urandom_range(0, 99) < m_rdy;
    if (m_awvalid && m_awready) begin
      @(posedge m_clk);
      if (q_aw.size() == 0) miss("AW", {m_awid, m_awaddr, m_awlen, m_awsize, m_awburst}, 0, 1);
      else if ({m_awid, m_awaddr, m_awlen, m_awsize, m_awburst} !== q_aw[0])
        miss("AW", {m_awid, m_awaddr, m_awlen, m_awsize, m_awburst}, q_aw[0], 0);
      if (q_aw.size() != 0) void'(q_aw.pop_front());
      rcvd[0]++;
    end
  end
  initial forever begin
    @(negedge m_clk); m_wready = $urandom_range(0, 99) < m_rdy;
    if (m_wvalid && m_wready) begin
      @(posedge m_clk);
      if (q_w.size() == 0) miss("W", {m_wdata, m_wstrb, m_wlast}, 0, 1);
      else if ({m_wdata, m_wstrb, m_wlast} !== q_w[0]) miss("W", {m_wdata, m_wstrb, m_wlast}, q_w[0], 0);
      if (q_w.size() != 0) void'(q_w.pop_front());
      rcvd[1]++;
    end
  end
  initial forever begin
    @(negedge m_clk); m_arready = $urandom_range(0, 99) < m_rdy;
    if (m_arvalid && m_arready) begin
      @(posedge m_clk);
      if (q_ar.size() == 0) miss("AR", {m_arid, m_araddr, m_arlen, m_arsize, m_arburst}, 0, 1);
      else if ({m_arid, m_araddr, m_arlen, m_arsize, m_arburst} !== q_ar[0])
        miss("AR", {m_arid, m_araddr, m_arlen, m_arsize, m_arburst}, q_ar[0], 0);
      if (q_ar.size() != 0) void'(q_ar.pop_front());
      rcvd[2]++;
    end
  end
  initial forever begin
    @(negedge s_clk); s_bready = $urandom_range(0, 99) < s_rdy;
    if (s_bvalid && s_bready) begin
      @(posedge s_clk);
      if (q_b.size() == 0) miss("B", {s_bid, s_bresp}, 0, 1);
      else if ({s_bid, s_bresp} !== q_b[0]) miss("B", {s_bid, s_bresp}, q_b[0], 0);
      if (q_b.size() != 0) void'(q_b.pop_front());
      rcvd[3]++;
    end
  end
  initial forever begin
    @(negedge s_clk); s_rready = $urandom_range(0, 99) < s_rdy;
    if (s_rvalid && s_rready) begin
      @(posedge s_clk);
      if (q_r.size() == 0) miss("R", {s_rid, s_rdata, s_rresp, s_rlast}, 0, 1);
      else if ({s_rid, s_rdata, s_rresp, s_rlast} !== q_r[0])
        miss("R", {s_rid, s_rdata, s_rresp, s_rlast}, q_r[0], 0);
      if (q_r.size() != 0) void'(q_r.pop_front());
      rcvd[4]++;
    end
  end

  // ---------------- phases ----------------
  task automatic phase(input string name, input real h_s, input real h_m, input int sr, input int mr,
                       input int sg, input int mg, input int n);
    int t;
    hs = h_s; hm = h_m; s_rdy = sr; m_rdy = mr; s_gap = sg; m_gap = mg;
    fork
      p_aw(n); p_w(n); p_ar(n); p_b(n); p_r(n);
    join
    // drain
    s_rdy = 100; m_rdy = 100;
    t = 0;
    while ((q_aw.size() || q_w.size() || q_ar.size() || q_b.size() || q_r.size()) && t < 100000) begin
      @(posedge s_clk); t++;
    end
    if (t >= 100000) begin errors++; $display("ERROR: phase %s did not drain", name); end
    $display("phase %-10s s %4.1f ns m %4.1f ns: AW %0d W %0d AR %0d B %0d R %0d", name, 2 * h_s, 2 * h_m,
             rcvd[0], rcvd[1], rcvd[2], rcvd[3], rcvd[4]);
  endtask

  initial begin
    s_awid = 0; s_awaddr = 0; s_awlen = 0; s_awsize = 0; s_awburst = 0; s_wdata = 0; s_wstrb = 0; s_wlast = 0;
    s_arid = 0; s_araddr = 0; s_arlen = 0; s_arsize = 0; s_arburst = 0;
    m_bid = 0; m_bresp = 0; m_rid = 0; m_rdata = 0; m_rresp = 0; m_rlast = 0;
    repeat (3) @(posedge m_clk);
    s_rst_n = 1; m_rst_n = 1;
    //     name         s half  m half  s rdy m rdy s gap m gap beats
    phase("s_fast",      5.0,   13.5,   100,  100,  0,    0,    600);
    phase("m_fast",     15.5,    3.5,    50,   50,  0,    0,    600);
    phase("m_fast_full", 15.5,   3.5,     5,    5,  0,    0,    200);   // fast but rarely ready: full FIFOs
    phase("near_equal",  5.0,    5.15,   60,   60,  30,   30,   600);
    phase("fill",        5.0,    9.0,    10,   10,  0,    0,    400);   // slow consumers: full FIFOs
    phase("sparse",      7.0,    6.0,   100,  100,  90,   90,   200);   // FIFOs mostly empty

    // reset both sides while the FIFOs hold data
    m_rdy = 0; s_rdy = 0;
    fork p_aw(DEPTH); p_w(DEPTH); p_ar(DEPTH); p_b(DEPTH); p_r(DEPTH); join
    repeat (6) @(posedge m_clk);
    if (!(m_awvalid && m_wvalid && m_arvalid && s_bvalid && s_rvalid)) begin
      errors++; $display("ERROR: full FIFOs show no data before the reset");
    end
    @(negedge s_clk); s_rst_n = 0; m_rst_n = 0;
    q_aw.delete(); q_w.delete(); q_ar.delete(); q_b.delete(); q_r.delete();
    repeat (3) @(posedge m_clk);
    // AXI: VALID low during reset (READY may be either; nobody sends then)
    if (m_awvalid || m_wvalid || m_arvalid || s_bvalid || s_rvalid) begin
      errors++; $display("ERROR: VALID during reset");
    end
    @(negedge s_clk); s_rst_n = 1; m_rst_n = 1;
    phase("after_rst",   5.0,   13.5,   100,  100,  10,   10,   100);

    for (int c = 0; c < 5; c++)
      if (sent[c] != rcvd[c] + DEPTH) begin
        errors++; $display("ERROR: channel %0d sent %0d received %0d (+%0d lost in the reset)", c, sent[c], rcvd[c], DEPTH);
      end
    @(posedge s_clk); @(posedge s_clk);
    if (n_resp_err != n_resp_err_exp || n_resp_err == 0) begin
      errors++; $display("ERROR: RESP_ERR pulsed %0d times, expected %0d", n_resp_err, n_resp_err_exp);
    end
    if (errors == 0) $display("TEST PASSED: AXI_Async_Bridge");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #10ms;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end
endmodule
