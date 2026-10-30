// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for PTP_top v1.0
//  * Clock model: the TB keeps its own {sec, ns, fraction} and compares
//    t_sec / t_ns with it on every clock, through rate changes, time_set,
//    positive and negative steps (also across second boundaries), snap,
//    pps, sec_tick and target times in the future, in the past and
//    disarmed.
//  * External events at random points between clock edges: evt_valid three
//    clocks after the pin edge with the time of the clock before.
//  * Frames on both GMII streams, built byte by byte with their own FCS:
//    layer 2, IPv4 (IHL 5..15) and IPv6 PTP event messages with and
//    without a VLAN tag, and every reason not to timestamp one (general
//    message, port 320, wrong version, other EtherType, non-UDP, IPv4
//    fragment, bad IP version / IHL, transport disabled, bad FCS, er byte,
//    runt, frame cut inside the PTP header, no SFD). The TB decides from
//    what it built whether the frame gets a timestamp, and with which
//    value (SFD time -/+ latency, borrow / carry into the seconds).
//  * FIFOs: popped at random times, full / overflow, pop and push in the
//    same clock, both streams at once.
// ============================================================================
`timescale 1ns/1ps
module PTP_tb;
  localparam int DEPTH = 4;
  localparam logic [31:0] GIGA = 32'd1_000_000_000;
  logic clk = 0, rst_n = 0;
  always #4 clk = ~clk;

  logic [7:0]  cfg_inc_ns = 8;
  logic [31:0] cfg_inc_frac = 0;
  logic        time_set = 0, time_step = 0, snap = 0;
  logic [47:0] set_sec = 0;
  logic [29:0] set_ns = 0;
  logic [31:0] step_ns = 0;
  wire  [47:0] t_sec, snap_sec, evt_sec, rxq_sec, txq_sec;
  wire  [29:0] t_ns, snap_ns, evt_ns, rxq_ns, txq_ns;
  logic        pps_en = 0;
  logic [29:0] pps_width_ns = 0;
  wire         pps, sec_tick, target_armed, target_hit, evt_valid;
  logic        target_arm = 0, target_disarm = 0;
  logic [47:0] target_sec = 0;
  logic [29:0] target_ns = 0;
  logic        ext_evt = 0;
  logic        rx_dv = 0, rx_er = 0, tx_en = 0, tx_er = 0;
  logic [7:0]  rxd = 0, txd = 0;
  logic [15:0] cfg_rx_lat_ns = 0, cfg_tx_lat_ns = 0;
  logic        cfg_l2_en = 1, cfg_ipv4_en = 1, cfg_ipv6_en = 1;
  wire         rxq_valid, txq_valid, rxq_ovf, txq_ovf;
  logic        rxq_pop = 0, txq_pop = 0;
  wire  [3:0]  rxq_type, txq_type;
  wire  [7:0]  rxq_domain, txq_domain;
  wire  [15:0] rxq_seq, txq_seq;

  PTP_top #(.FIFO_DEPTH(DEPTH)) dut (.*);

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction
  task automatic cyc(input int n); for (int i = 0; i < n; i++) @(negedge clk); endtask

  // ---------------- clock model ----------------
  logic [47:0] m_sec = 0, pm_sec = 0;      // now / before the last posedge
  logic [31:0] m_ns = 0, pm_ns = 0, m_frac = 0;
  bit          m_tick = 0, e_pps = 0;
  always @(posedge clk) begin
    logic [32:0] f;
    logic [31:0] n;
    pm_sec = m_sec; pm_ns = m_ns;
    e_pps = rst_n && pps_en && m_ns < pps_width_ns;
    m_tick = 0;
    if (!rst_n) begin m_sec = 0; m_ns = 0; m_frac = 0; end
    else if (time_set) begin
      m_sec = set_sec; m_ns = set_ns > 999_999_999 ? 999_999_999 : set_ns; m_frac = 0;
    end else begin
      f = m_frac + cfg_inc_frac;
      m_frac = f[31:0];
      n = m_ns + cfg_inc_ns + f[32];
      if (n >= GIGA) begin n = n - GIGA; m_sec = m_sec + 1; m_tick = !time_step; end
      if (time_step) begin
        if ($signed(n) + $signed(step_ns) < 0) begin n = n + step_ns + GIGA; m_sec = m_sec - 1; end
        else if (n + step_ns >= GIGA && !step_ns[31]) begin n = n + step_ns - GIGA; m_sec = m_sec + 1; end
        else n = n + step_ns;
      end
      m_ns = n;
    end
  end
  always @(negedge clk) if (rst_n) begin
    if (t_sec !== m_sec || t_ns !== m_ns[29:0])
      fail($sformatf("time %0d.%09d, expected %0d.%09d", t_sec, t_ns, m_sec, m_ns));
    if (sec_tick !== m_tick) fail("sec_tick");
  end
  // pps: registered from the time before the last edge
  bit pps_q = 0;
  int n_pps = 0, n_tick = 0;
  always @(negedge clk) if (rst_n) begin
    if (pps !== e_pps) fail("pps");
    if (pps && !pps_q) n_pps++;
    pps_q = pps;
    if (sec_tick) n_tick++;
  end

  // ---------------- clock pin tasks ----------------
  task automatic do_set(input logic [47:0] s, input logic [29:0] n);
    @(negedge clk); set_sec = s; set_ns = n; time_set = 1;
    @(negedge clk); time_set = 0; set_sec = $urandom; set_ns = $urandom;
  endtask
  task automatic do_step(input int s);
    @(negedge clk); step_ns = s; time_step = 1;
    @(negedge clk); time_step = 0; step_ns = $urandom;
  endtask
  task automatic do_snap;
    logic [47:0] es;
    logic [31:0] en;
    @(negedge clk); snap = 1; es = m_sec; en = m_ns;
    @(negedge clk); snap = 0;
    if (snap_sec !== es || snap_ns !== en[29:0]) fail("snap");
  endtask

  // ---------------- target time ----------------
  int hit_n = 0;
  logic [47:0] hit_sec;
  logic [31:0] hit_ns;
  always @(negedge clk) if (rst_n && target_hit) begin hit_n++; hit_sec = pm_sec; hit_ns = pm_ns; end
  task automatic target(input logic [47:0] s, input logic [29:0] n);
    @(negedge clk); target_sec = s; target_ns = n; target_arm = 1;
    @(negedge clk); target_arm = 0;
    if (!target_armed) fail("target not armed");
  endtask

  // ---------------- external event ----------------
  int ev_n = 0;
  realtime ev_t;
  always @(negedge clk) if (rst_n && evt_valid) begin
    ev_n++;
    if (evt_sec !== pm_sec || evt_ns !== pm_ns[29:0])
      fail($sformatf("event time %0d.%09d, expected %0d.%09d", evt_sec, evt_ns, pm_sec, pm_ns));
    // the third rising clock edge after the pin edge
    if ($realtime - ev_t < 2.0 * 8 + 4 || $realtime - ev_t > 3.0 * 8 + 4) fail("event latency");
  end
  task automatic event_pulse(input int hi);
    #($urandom_range(1, 7) + 0.25);
    ext_evt = 1; ev_t = $realtime;
    #(hi * 8 + 0.5);
    ext_evt = 0;
    cyc(4);
  endtask

  // ---------------- frames ----------------
  typedef struct packed {
    logic [3:0]  kind;     // 0 L2, 1 IPv4, 2 IPv6, 3 other EtherType, 4 IPv4 TCP, 5 IPv4 port 320,
                           // 6 IPv4 fragment, 7 IPv6 TCP, 8 IPv4 version 5, 9 IPv4 IHL 4,
                           // 10 IPv6 version 4, 11 IPv4 offset only (MF clear)
    logic        vlan;
    logic [3:0]  ihl;
    logic [3:0]  mtype;
    logic [3:0]  ver;
    logic [7:0]  dom;
    logic [15:0] seq;
    logic [2:0]  pre;      // preamble bytes before the SFD
    logic        no_sfd;
    logic        bad_fcs;
    logic [10:0] er_at;    // 0 = none, else byte index + 1
    logic [10:0] cut;      // 0 = whole frame, else total length (with FCS)
    logic [10:0] body;     // PTP message length (>= 34)
    logic        nopad;    // no padding to 64 bytes (a runt with a good FCS)
  } fr_t;

  logic [7:0] fb [0:1][0:2099];
  int         fn [0:1];
  int         f_er [0:1];
  logic [31:0] fcs;
  function automatic logic [31:0] crc8(input logic [31:0] c, input logic [7:0] b);
    logic [31:0] x;
    x = c ^ {24'd0, b};
    for (int i = 0; i < 8; i++) x = {1'b0, x[31:1]} ^ (x[0] ? 32'hEDB8_8320 : 32'h0);
    return x;
  endfunction
  // build frame f for stream s (without preamble); returns 1 when it must be timestamped
  function automatic bit build(input int s, input fr_t f);
    int n, l3, l4, p0, et, pl;
    bit ev, tr;
    n = 0;
    for (int i = 0; i < 6; i++) begin fb[s][n] = i == 0 ? 8'h01 : 8'($urandom); n++; end   // dst
    for (int i = 0; i < 6; i++) begin fb[s][n] = 8'($urandom) & 8'hFE; n++; end           // src
    if (f.vlan) begin
      fb[s][n] = 8'h81; fb[s][n + 1] = 8'h00; fb[s][n + 2] = 8'($urandom); fb[s][n + 3] = 8'($urandom);
      n += 4;
    end
    et = f.kind == 0 ? 16'h88F7 : f.kind == 3 ? 16'h88F8 : (f.kind == 2 || f.kind == 7 || f.kind == 10) ? 16'h86DD : 16'h0800;
    fb[s][n] = 8'(et >> 8); fb[s][n + 1] = 8'(et); n += 2;
    l3 = n; tr = 0; p0 = 0;
    if (f.kind == 0 || f.kind == 3) begin p0 = l3; tr = f.kind == 0 && cfg_l2_en; end
    else if (f.kind == 2 || f.kind == 7 || f.kind == 10) begin                   // IPv6
      pl = 8 + f.body;
      fb[s][n] = f.kind == 10 ? 8'h40 : 8'h60; n++;
      for (int i = 1; i < 4; i++) begin fb[s][n] = 8'($urandom); n++; end
      fb[s][n] = 8'(pl >> 8); fb[s][n + 1] = 8'(pl); n += 2;
      fb[s][n] = f.kind == 7 ? 8'd6 : 8'd17; n++;
      fb[s][n] = 8'($urandom); n++;                                                // hop limit
      for (int i = 0; i < 32; i++) begin fb[s][n] = 8'($urandom); n++; end         // addresses
      l4 = n; p0 = l4 + 8;
      tr = f.kind == 2 && cfg_ipv6_en;
    end else begin                                                                 // IPv4
      pl = 4 * f.ihl + 8 + f.body;
      fb[s][n] = {f.kind == 8 ? 4'd5 : 4'd4, f.kind == 9 ? 4'd4 : f.ihl}; n++;
      fb[s][n] = 8'($urandom); n++;
      fb[s][n] = 8'(pl >> 8); fb[s][n + 1] = 8'(pl); n += 2;
      fb[s][n] = 8'($urandom); fb[s][n + 1] = 8'($urandom); n += 2;                // identification
      // flags / fragment offset: DF may be set; kind 6 sets MF, kind 11 an offset
      // in the high bits (odd seq) or in the low byte only (even seq)
      fb[s][n] = {1'b0, 1'($urandom), f.kind == 6, f.kind == 11 && f.seq[0] ? 5'($urandom_range(1, 31)) : 5'd0};
      fb[s][n + 1] = f.kind != 11 ? 8'd0 : f.seq[0] ? 8'($urandom) : 8'($urandom_range(1, 255));
      n += 2;
      fb[s][n] = 8'($urandom); n++;                                                // TTL
      fb[s][n] = f.kind == 4 ? 8'd6 : 8'd17; n++;
      for (int i = 0; i < 4 * f.ihl - 10; i++) begin fb[s][n] = 8'($urandom); n++; end
      l4 = n; p0 = l4 + 8;
      tr = (f.kind == 1 || f.kind == 5) && cfg_ipv4_en && f.ihl >= 5;
      if (f.kind == 5) tr = 0;
    end
    if (p0 != l3) begin                                                            // UDP header
      fb[s][n] = 8'($urandom); fb[s][n + 1] = 8'($urandom); n += 2;
      fb[s][n] = 8'h01; fb[s][n + 1] = f.kind == 5 ? 8'h40 : 8'h3F; n += 2;       // 319 / 320
      fb[s][n] = 8'((8 + f.body) >> 8); fb[s][n + 1] = 8'(8 + f.body); n += 2;
      fb[s][n] = 8'($urandom); fb[s][n + 1] = 8'($urandom); n += 2;
    end
    // PTP header and body
    for (int i = 0; i < f.body; i++) begin
      fb[s][n] = i == 0 ? {4'($urandom), f.mtype} : i == 1 ? {4'($urandom), f.ver} : i == 4 ? f.dom :
                 i == 30 ? f.seq[15:8] : i == 31 ? f.seq[7:0] : 8'($urandom);
      n++;
    end
    while (n < 60 && !f.nopad) begin fb[s][n] = 8'h00; n++; end
    fcs = 32'hFFFF_FFFF;
    for (int i = 0; i < n; i++) fcs = crc8(fcs, fb[s][i]);
    fcs = ~fcs ^ (f.bad_fcs ? 32'h0000_0100 : 32'h0);
    for (int i = 0; i < 4; i++) begin fb[s][n] = fcs[8 * i +: 8]; n++; end
    if (f.cut != 0 && f.cut < n) n = f.cut;
    fn[s] = n;
    f_er[s] = int'(f.er_at) - 1;
    ev = tr && f.mtype <= 3 && f.ver == 2 && !f.bad_fcs && f.er_at == 0 && f.cut == 0 && !f.no_sfd
         && n >= 64 && n >= p0 + 38;
    return ev;
  endfunction

  // expected FIFO contents
  logic [105:0] eq [0:1][0:63];
  int          eq_h [0:1], eq_t [0:1];
  int          n_ovf [0:1], e_ovf [0:1], n_ts [0:1];
  initial for (int s = 0; s < 2; s++) begin eq_h[s] = 0; eq_t[s] = 0; n_ovf[s] = 0; e_ovf[s] = 0; n_ts[s] = 0; end
  // what the FIFO holds: pushes not yet popped (the TB pops only through pop_one)
  function automatic int occ(input int s); return eq_t[s] - eq_h[s]; endfunction

  function automatic logic [105:0] entry(input int s, input fr_t f, input logic [47:0] sec, input logic [31:0] ns);
    logic [47:0] es;
    logic [31:0] en;
    es = sec; en = ns;
    if (s == 1) begin
      en = ns + cfg_tx_lat_ns;
      if (en >= GIGA) begin en = en - GIGA; es = sec + 1; end
    end else if (ns < cfg_rx_lat_ns) begin en = ns + GIGA - cfg_rx_lat_ns; es = sec - 1; end
    else en = ns - cfg_rx_lat_ns;
    return {f.mtype, f.dom, f.seq, es, en[29:0]};
  endfunction

  // drive stream s: preamble, SFD, bytes; the SFD time is the model time at that edge
  bit last_b0 = 0, last_b1 = 0;            // the stream is on its last byte
  task automatic drive(input int s, input fr_t f, input bit ev);
    logic [47:0] ts;
    logic [31:0] tn;
    @(negedge clk);
    for (int i = 0; i < f.pre; i++) begin
      if (s == 0) begin rx_dv = 1; rxd = 8'h55; rx_er = 0; end else begin tx_en = 1; txd = 8'h55; tx_er = 0; end
      @(negedge clk);
    end
    if (s == 0) begin rx_dv = 1; rxd = f.no_sfd ? 8'h5D : 8'hD5; end else begin tx_en = 1; txd = f.no_sfd ? 8'h5D : 8'hD5; end
    ts = m_sec; tn = m_ns;
    @(negedge clk);
    for (int i = 0; i < fn[s]; i++) begin
      if (s == 0) begin rxd = fb[s][i]; rx_er = i == f_er[s]; end
      else begin txd = fb[s][i]; tx_er = i == f_er[s]; end
      if (i == fn[s] - 1) begin if (s == 0) last_b0 = 1; else last_b1 = 1; end
      @(negedge clk);
    end
    if (s == 0) begin rx_dv = 0; rx_er = 0; rxd = 8'($urandom); end
    else begin tx_en = 0; tx_er = 0; txd = 8'($urandom); end
    if (s == 0) last_b0 = 0; else last_b1 = 0;
    #1;                                   // after a pop decided at this edge
    if (ev) begin
      if (occ(s) >= DEPTH) e_ovf[s]++;
      else begin eq[s][eq_t[s] % 64] = entry(s, f, ts, tn); eq_t[s]++; end
    end
    cyc($urandom_range(1, 4));
  endtask
  // both streams from one process, starting in the same clock
  task automatic drive_both(input fr_t f0, input bit ev0, input fr_t f1, input bit ev1);
    logic [47:0] ts [0:1];
    logic [31:0] tn [0:1];
    int          len [0:1], pre [0:1];
    bit          ev [0:1], nsfd [0:1];
    ev[0] = ev0; ev[1] = ev1; pre[0] = f0.pre; pre[1] = f1.pre; nsfd[0] = f0.no_sfd; nsfd[1] = f1.no_sfd;
    for (int s = 0; s < 2; s++) len[s] = pre[s] + 1 + fn[s];
    @(negedge clk);
    for (int j = 0; j <= len[0] || j <= len[1]; j++) begin
      bit fin;
      fin = 0;
      for (int s = 0; s < 2; s++) begin
        logic [7:0] b;
        bit v, e;
        v = j < len[s]; e = 0;
        b = j < pre[s] ? 8'h55 : j == pre[s] ? (nsfd[s] ? 8'h5D : 8'hD5) : j < len[s] ? fb[s][j - pre[s] - 1] : 8'($urandom);
        if (j > pre[s] && j < len[s]) e = j - pre[s] - 1 == f_er[s];
        if (j == pre[s]) begin ts[s] = m_sec; tn[s] = m_ns; end
        if (j == len[s]) fin = 1;
        if (j <= len[s]) begin
          if (s == 0) begin rx_dv = v; rxd = b; rx_er = e; end else begin tx_en = v; txd = b; tx_er = e; end
        end
      end
      if (fin) begin
        #1;
        for (int s = 0; s < 2; s++)
          if (j == len[s] && ev[s]) begin
            if (occ(s) >= DEPTH) e_ovf[s]++;
            else begin eq[s][eq_t[s] % 64] = entry(s, s == 0 ? f0 : f1, ts[s], tn[s]); eq_t[s]++; end
          end
      end
      @(negedge clk);
    end
    cyc($urandom_range(1, 4));
  endtask
  // background driver process per stream (a forked drive() crashes Verilator 5.020)
  fr_t d_f0, d_f1;
  bit  d_e0, d_e1, go0 = 0, go1 = 0;
  initial forever begin @(posedge go0); drive(0, d_f0, d_e0); go0 = 0; end
  initial forever begin @(posedge go1); drive(1, d_f1, d_e1); go1 = 0; end
  task automatic start(input int s, input fr_t f, input bit ev);
    if (s == 0) begin d_f0 = f; d_e0 = ev; go0 = 1; end else begin d_f1 = f; d_e1 = ev; go1 = 1; end
    #0;
  endtask
  task automatic finish(input int s);
    while (s == 0 ? go0 : go1) @(negedge clk);
  endtask
  always @(negedge clk) if (rst_n) begin
    if (rxq_ovf) n_ovf[0]++;
    if (txq_ovf) n_ovf[1]++;
  end

  // pop one entry of stream s and compare (from a negedge)
  task automatic pop_one(input int s);
    @(negedge clk);
    pop_now(s);
  endtask
  task automatic pop_now(input int s);
    logic [105:0] got;
    if (!(s == 0 ? rxq_valid : txq_valid)) fail($sformatf("stream %0d: FIFO empty", s));
    else begin
      got = s == 0 ? {rxq_type, rxq_domain, rxq_seq, rxq_sec, rxq_ns} : {txq_type, txq_domain, txq_seq, txq_sec, txq_ns};
      if (occ(s) == 0) fail($sformatf("stream %0d: unexpected timestamp", s));
      else begin
        if (got !== eq[s][eq_h[s] % 64])
          fail($sformatf("stream %0d: entry type %0d dom %0d seq %0d %0d.%09d, expected type %0d dom %0d seq %0d %0d.%09d",
                         s, got[105:102], got[101:94], got[93:78], got[77:30], got[29:0],
                         eq[s][eq_h[s] % 64][105:102], eq[s][eq_h[s] % 64][101:94], eq[s][eq_h[s] % 64][93:78],
                         eq[s][eq_h[s] % 64][77:30], eq[s][eq_h[s] % 64][29:0]));
        eq_h[s]++; n_ts[s]++;
      end
      if (s == 0) rxq_pop = 1; else txq_pop = 1;
      @(negedge clk);
      rxq_pop = 0; txq_pop = 0;
    end
  endtask
  task automatic drain(input int s);
    int g;
    g = 0;
    while (occ(s) > 0 && g < 64) begin pop_one(s); g++; end
    @(negedge clk);
    if ((s == 0 ? rxq_valid : txq_valid) !== 0) fail($sformatf("stream %0d: FIFO not empty", s));
  endtask

  function automatic fr_t ev_frame(input int kind);
    fr_t f;
    f = '0;
    f.kind = 4'(kind); f.vlan = $urandom_range(1); f.ihl = 4'($urandom_range(5, 15));
    f.mtype = 4'($urandom_range(0, 3)); f.ver = 2; f.dom = 8'($urandom); f.seq = 16'($urandom);
    f.pre = 3'($urandom_range(0, 7)); f.body = 11'($urandom_range(34, 64));
    return f;
  endfunction
  function automatic fr_t rnd_frame();
    fr_t f;
    int r;
    f = ev_frame($urandom_range(0, 2));
    r = $urandom_range(0, 19);
    case (r)
      0: f.mtype = 4'($urandom_range(8, 15));               // general / reserved
      1: f.ver = 4'($urandom_range(0, 15));
      2: f.kind = 3;
      3: f.kind = 4;
      4: f.kind = 5;
      5: f.kind = 6;
      6: f.kind = 7;
      7: f.kind = 8;
      8: f.kind = 9;
      9: f.kind = 10;
      10: f.kind = 11;
      11: f.bad_fcs = 1;
      12: f.er_at = 11'($urandom_range(1, 60));
      13: f.cut = 11'($urandom_range(20, 63));
      14: f.no_sfd = 1;
      default: ;
    endcase
    return f;
  endfunction
  task automatic send(input int s, input fr_t f);
    bit ev;
    ev = build(s, f);
    drive(s, f, ev);
  endtask

  // ---------------- scenarios ----------------
  initial begin
    fr_t f, g;
    bit e0, e1;
    int k;
    cyc(3);
    if (t_sec !== 0 || t_ns !== 0 || pps !== 0 || rxq_valid !== 0 || txq_valid !== 0 || evt_valid !== 0)
      fail("reset values");
    rst_n = 1;
    cyc(5);

    // 1. clock: rate, set, steps, snap
    $display("[%0t] section 1: clock", $time);
    do_snap();
    do_set(48'h1234_5678_9ABC, 30'd999_999_900);              // carries into the seconds
    cyc(30);
    cfg_inc_frac = 32'h8000_0000;                             // 8.5 ns per clock
    cyc(20);
    cfg_inc_ns = 7; cfg_inc_frac = 32'hFFFF_FFFF;            // just under 8 ns
    cyc(20);
    cfg_inc_ns = 8; cfg_inc_frac = 0;
    do_step(1000);
    do_step(-1000);
    do_set(48'd77, 30'd500);
    do_step(-1000);                                           // borrows a second
    do_set(48'd77, 30'd999_999_000);
    do_step(5000);                                            // carries a second
    do_set(48'd77, 30'd999_999_996);
    do_step(0);                                               // the increment carries, step 0
    do_set(48'd78, 30'd100);
    do_step(-999_999_999);
    do_step(999_999_999);
    do_set(48'hFFFF_FFFF_FFFF, 30'd999_999_990);             // the seconds wrap
    cyc(4);
    do_set(48'd5, 30'h3FFF_FFFF);                             // out of range: 999,999,999
    cyc(2);
    for (int i = 0; i < 20; i++) begin
      do_set({$urandom, 16'($urandom)}, 30'($urandom_range(0, 999_999_999)));
      cfg_inc_ns = 8'($urandom_range(1, 255)); cfg_inc_frac = $urandom;
      cyc($urandom_range(1, 10));
      do_step($urandom_range(0, 1) ? int'($urandom_range(0, 999_999_999)) : -int'($urandom_range(0, 999_999_999)));
      do_snap();
    end
    cfg_inc_ns = 8; cfg_inc_frac = 0;

    // 2. pps and sec_tick
    $display("[%0t] section 2: pps", $time);
    pps_en = 1; pps_width_ns = 30'd200;
    do_set(48'd10, 30'd999_999_000);
    cyc(400);
    pps_width_ns = 30'd999_999_999;
    do_set(48'd11, 30'd999_999_900);
    cyc(30);
    pps_en = 0;
    cyc(5);
    if (n_pps < 2 || n_tick < 2) fail("pps / sec_tick not seen");

    // 3. target time
    $display("[%0t] section 3: target time", $time);
    do_set(48'd20, 30'd1000);
    target(48'd20, 30'd1400);                                  // 50 clocks ahead
    cyc(60);
    if (hit_n != 1 || hit_sec != 20 || hit_ns < 1400 || hit_ns >= 1408) fail("target hit in the same second");
    target(48'd21, 30'd0);                                     // next second
    do_set(48'd20, 30'd999_999_800);
    cyc(40);
    if (hit_n != 2 || hit_sec != 21) fail("target hit in the next second");
    target(48'd19, 30'd5);                                     // in the past
    cyc(2);
    if (hit_n != 3) fail("past target");
    target(48'd30, 30'd0);
    @(negedge clk); target_disarm = 1; @(negedge clk); target_disarm = 0;
    if (target_armed) fail("disarm");
    do_set(48'd30, 30'd0);
    cyc(5);
    if (hit_n != 3) fail("disarmed target hit");
    // arm and disarm in one clock: arm wins
    @(negedge clk); target_sec = 48'd40; target_arm = 1; target_disarm = 1;
    @(negedge clk); target_arm = 0; target_disarm = 0;
    if (!target_armed) fail("arm with disarm");
    @(negedge clk); target_disarm = 1; @(negedge clk); target_disarm = 0;
    target(48'd30, 30'd1000);                                   // equal seconds, ns below
    cyc(150);
    if (hit_n != 4) fail("target at equal seconds");

    // 4. external events
    $display("[%0t] section 4: external events", $time);
    for (int i = 0; i < 12; i++) event_pulse($urandom_range(1, 5));
    do_set(48'd50, 30'd999_999_990);
    event_pulse(1);
    if (ev_n != 13) fail($sformatf("%0d events", ev_n));

    // 5. frames on both streams
    $display("[%0t] section 5: frames", $time);
    cfg_rx_lat_ns = 16'd300; cfg_tx_lat_ns = 16'd500;
    for (int k2 = 0; k2 < 3; k2++)
      for (int v = 0; v < 2; v++) begin
        f = ev_frame(k2); f.vlan = v; send(0, f);
        g = ev_frame(k2); g.vlan = v; send(1, g);
        drain(0); drain(1);
      end
    // IHL 5..15, every event message type, preamble lengths
    for (int i = 5; i < 16; i++) begin f = ev_frame(1); f.ihl = 4'(i); f.mtype = 4'(i % 4); f.pre = 3'(i % 8); send(0, f); drain(0); end
    for (int i = 0; i < 16; i++) begin f = ev_frame(i % 3); f.mtype = 4'(i); send(1, f); end
    drain(1);
    // every reason not to timestamp
    for (int r = 3; r <= 11; r++) begin f = ev_frame(1); f.kind = 4'(r); send(0, f); send(1, f); end
    f = ev_frame(0); f.ver = 1; send(0, f);
    f = ev_frame(1); f.bad_fcs = 1; send(0, f);
    f = ev_frame(2); f.er_at = 11'd70; send(1, f);
    f = ev_frame(0); f.er_at = 11'd1; send(1, f);
    f = ev_frame(0); f.cut = 11'd40; send(0, f);                  // runt
    f = ev_frame(1); f.vlan = 1; f.ihl = 15; f.cut = 11'd110; send(0, f);   // cut inside the PTP header
    f = ev_frame(0); f.no_sfd = 1; send(1, f);
    f = ev_frame(0); f.body = 11'd34; send(0, f);                 // shortest: padded to 64
    f = ev_frame(0); f.body = 11'd34; f.nopad = 1; send(0, f); send(1, f);   // runt, good FCS
    f = ev_frame(2); f.vlan = 0; f.body = 11'd20; send(0, f); send(1, f);    // 86 bytes, header cut
    drain(0); drain(1);
    if (n_ts[0] != 18 || n_ts[1] != 10) fail($sformatf("timestamps %0d %0d, want 18 10", n_ts[0], n_ts[1]));
    @(negedge clk); rxq_pop = 1; txq_pop = 1;                       // pops on empty FIFOs
    @(negedge clk); rxq_pop = 0; txq_pop = 0;
    if (rxq_valid || txq_valid || rxq_ovf || txq_ovf) fail("pop on an empty FIFO");
    // transports disabled one by one
    for (int i = 0; i < 3; i++) begin
      cfg_l2_en = i != 0; cfg_ipv4_en = i != 1; cfg_ipv6_en = i != 2;
      for (int k2 = 0; k2 < 3; k2++) begin f = ev_frame(k2); send(0, f); send(1, f); end
      drain(0); drain(1);
    end
    cfg_l2_en = 1; cfg_ipv4_en = 1; cfg_ipv6_en = 1;
    // latency borrow / carry across the second
    for (int i = 0; i < 4; i++) begin
      do_set(48'd60 + i, i < 2 ? 30'd100 : 30'd999_999_700);
      f = ev_frame(i % 3); send(0, f);
      f = ev_frame(i % 3); send(1, f);
      drain(0); drain(1);
    end
    cfg_rx_lat_ns = 16'hFFFF; cfg_tx_lat_ns = 16'hFFFF;
    do_set(48'd70, 30'd999_990_000);
    f = ev_frame(0); send(0, f); f = ev_frame(0); send(1, f);
    do_set(48'd70, 30'd10_000);
    f = ev_frame(0); send(0, f); f = ev_frame(0); send(1, f);
    drain(0); drain(1);
    cfg_rx_lat_ns = 16'd300; cfg_tx_lat_ns = 16'd500;

    // 6. FIFO full and overflow; pop while a push lands
    $display("[%0t] section 6: FIFOs", $time);
    for (int s = 0; s < 2; s++) begin
      for (int i = 0; i < DEPTH + 2; i++) begin f = ev_frame(i % 3); send(s, f); end
      cyc(2);                                                 // the last q_ovf pulse
      if (n_ovf[s] != e_ovf[s] || n_ovf[s] < 2) fail($sformatf("stream %0d: %0d overflows, expected %0d", s, n_ovf[s], e_ovf[s]));
      drain(s);
    end
    // a pop in the clock of a push into the full FIFO: no overflow
    for (int s = 0; s < 2; s++) begin
      for (int i = 0; i < DEPTH; i++) begin f = ev_frame(i % 3); send(s, f); end
      f = ev_frame(1);
      e0 = build(s, f);
      start(s, f, e0);
      if (s == 0) wait (last_b0); else wait (last_b1);
      @(negedge clk);                                         // dv drops at this edge
      pop_now(s);
      finish(s);
      cyc(2);
      if (n_ovf[s] != e_ovf[s]) fail($sformatf("stream %0d: overflow with a pop", s));
      drain(s);
    end

    // 7. random traffic on both streams with random pops
    $display("[%0t] section 7: random traffic", $time);
    for (int i = 0; i < 150; i++) begin
      f = rnd_frame(); g = rnd_frame();
      e0 = build(0, f); e1 = build(1, g);
      if (i % 3 == 0) begin                 // both streams at once (every 6th: the same frame)
        if (i % 6 == 0) begin g = f; e1 = build(1, g); end
        drive_both(f, e0, g, e1);
      end else begin
        // one stream at a time (two drive() calls at once crash Verilator 5.020),
        // each with a random pop of either FIFO while its frame runs
        start(0, f, e0);
        k = $urandom_range(0, 3);
        if (k == 0 && occ(0) > 0) pop_one(0);
        if (k == 1 && occ(1) > 0) pop_one(1);
        finish(0);
        start(1, g, e1);
        k = $urandom_range(0, 3);
        if (k == 0 && occ(0) > 0) pop_one(0);
        if (k == 1 && occ(1) > 0) pop_one(1);
        finish(1);
      end
      if (i % 9 == 0) begin
        cfg_inc_frac = $urandom;
        do_step(-int'($urandom_range(0, 100000)));
      end
      if (i % 25 == 0) begin drain(0); drain(1); end
    end
    drain(0); drain(1);
    if (n_ovf[0] != e_ovf[0] || n_ovf[1] != e_ovf[1]) fail("overflow count");

    // 8. reset in the middle of a frame
    $display("[%0t] section 8: reset", $time);
    f = ev_frame(0); e0 = build(0, f);
    start(0, f, 0);
    cyc(20); rst_n = 0; cyc(2); rst_n = 1;
    finish(0);
    cyc(3);
    if (rxq_valid !== 0 || t_sec !== m_sec) fail("after reset");
    eq_h[0] = 0; eq_t[0] = 0;
    f = ev_frame(1); send(0, f); drain(0);

    // 9. corners: every seconds / nanoseconds bit in the captured times, wide
    // pps widths, a jumbo frame (the byte counter saturates), a cut preamble
    $display("[%0t] section 9: corners", $time);
    cfg_rx_lat_ns = 16'd300; cfg_tx_lat_ns = 16'd500;
    for (int r = 0; r < 3; r++) begin
      logic [47:0] sv;
      logic [29:0] nv;
      sv = r == 0 ? 48'hFFFF_FFFF_FFFE : r == 1 ? 48'd1 : 48'd3;
      nv = r == 0 ? 30'h1FFF_FE6F : r == 1 ? 30'h2000_0000 : 30'd1000;     // r 0: target all ones
      pps_en = 1; pps_width_ns = r == 0 ? 30'h1FFF_FFFF : r == 1 ? 30'h2000_0000 : 30'd200;
      do_set(sv, nv);
      k = hit_n;
      target(sv, nv + 30'd400);
      cyc(60);
      if (hit_n != k + 1 || hit_sec != sv) fail($sformatf("corner %0d: target", r));
      do_set(sv, r == 1 ? nv : nv - 30'd100);
      k = ev_n;
      event_pulse(1);
      if (ev_n != k + 1) fail($sformatf("corner %0d: event", r));
      do_set(sv, nv - 30'h1000);
      for (int i = 0; i < 3; i++) begin f = ev_frame(i); send(0, f); send(1, f); end
      drain(0); drain(1);
      pps_en = 0;
    end
    k = n_ts[0] + n_ts[1];
    f = ev_frame(0); f.body = 11'd2047; send(0, f); send(1, f);     // 2065 bytes
    drain(0); drain(1);
    if (n_ts[0] + n_ts[1] != k + 2) fail("jumbo frames");
    for (int s = 0; s < 2; s++) begin                               // preamble, then dv drops
      @(negedge clk);
      for (int i = 0; i < 3; i++) begin
        if (s == 0) begin rx_dv = 1; rxd = 8'h55; end else begin tx_en = 1; txd = 8'h55; end
        @(negedge clk);
      end
      rx_dv = 0; tx_en = 0;
      cyc(3);
      if (rxq_valid || txq_valid) fail("cut preamble");
      f = ev_frame(1); send(s, f); drain(s);
    end

    $display("timestamps: rx %0d tx %0d, overflows %0d/%0d, events %0d, target hits %0d, pps %0d",
             n_ts[0], n_ts[1], n_ovf[0], n_ovf[1], ev_n, hit_n, n_pps);
    if (errors == 0) $display("TEST PASSED: PTP");
    else $display("TEST FAILED: PTP (%0d errors)", errors);
    $finish;
  end
  initial begin
    #50ms;
    $display("TEST FAILED: PTP (timeout)");
    $finish;
  end
endmodule
