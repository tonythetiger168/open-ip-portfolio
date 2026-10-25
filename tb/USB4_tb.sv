// SPDX-License-Identifier: Apache-2.0
// USB4_top testbench. Part 1: two adapters A and B xr-connected, with
// path configurations changed between sessions (HopIDs, crossed paths,
// disabled paths) and channels that flip single header bits. Part 2:
// adapter A against a TB link partner (BFM) that sends any byte stream and
// watches what A sends.
//  - host writers write packets of 1..MAXL bytes and longer ones that get
//    cut, interleaving the two paths byte by byte, with gaps; readers read
//    with random back-pressure
//  - receive scoreboards: every packet written to a path at one end comes
//    out of the path it is routed to at the other exactly once, in order,
//    whole, across link drops (a packet cut by one is sent again)
//  - a monitor parses each line from link up and checks every header's HEC
//    (before the channel); single-bit header errors are injected after it
//  - from the BFM: delineation (HUNT, PRESYNC, false headers, SYNC lost),
//    every correctable bit, uncorrectable errors, every receive error, credit
//    grants good and bad; A's packets, grants and credit use are checked
// The bound checker (tb/cov/USB4_sva.sv) checks every output of both
// adapters on every clock.
`timescale 1ns/1ps
module USB4_tb;
  localparam int MAXL = 32, RXB = 2, DELTA = 4, REFRESH = 128, LEAD = 2 * DELTA;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  // ---------------- adapters: index 0 = A, 1 = B ----------------
  logic [1:0]       link = 0, tx_valid = 0, tx_last = 0, tx_path = 0, rx_ready = 0;
  logic [1:0][7:0]  tx_data = 0;
  logic [1:0][1:0]  path_en = 0;
  logic [1:0][10:0] hop_tx0 = 0, hop_tx1 = 0, hop_rx0 = 0, hop_rx1 = 0;
  wire  [1:0][7:0]  tx_sym, rx_data;
  wire  [1:0]       tx_ready, rx_valid, rx_last, rx_path, sync;
  wire  [1:0][1:0]  path_up;
  wire  [1:0]       ev_hec_fix, ev_hec_bad, ev_proto, ev_hop, ev_len, ev_overflow;
  // channels: d = 0 A -> B, d = 1 B -> A; bits flipped
  logic [1:0][7:0]  xs = 0;
  // BFM in place of B on A's receive side
  bit               bfm = 0;
  logic [7:0]       b_sym = 0;
  wire  [7:0]       rs0 = bfm ? b_sym : tx_sym[1] ^ xs[1];
  wire  [7:0]       rs1 = tx_sym[0] ^ xs[0];

  USB4_top #(.MAXL(MAXL), .RXB(RXB), .DELTA(DELTA), .REFRESH(REFRESH)) u_a (
    .clk(clk), .rst_n(rst_n), .link_up(link[0]), .tx_sym(tx_sym[0]), .rx_sym(rs0), .path_en(path_en[0]),
    .hop_tx0(hop_tx0[0]), .hop_tx1(hop_tx1[0]), .hop_rx0(hop_rx0[0]), .hop_rx1(hop_rx1[0]),
    .tx_valid(tx_valid[0]), .tx_ready(tx_ready[0]), .tx_data(tx_data[0]), .tx_last(tx_last[0]),
    .tx_path(tx_path[0]), .rx_valid(rx_valid[0]), .rx_ready(rx_ready[0]), .rx_data(rx_data[0]),
    .rx_last(rx_last[0]), .rx_path(rx_path[0]), .sync(sync[0]), .path_up(path_up[0]),
    .ev_hec_fix(ev_hec_fix[0]), .ev_hec_bad(ev_hec_bad[0]), .ev_proto(ev_proto[0]), .ev_hop(ev_hop[0]),
    .ev_len(ev_len[0]), .ev_overflow(ev_overflow[0]));
  USB4_top #(.MAXL(MAXL), .RXB(RXB), .DELTA(DELTA), .REFRESH(REFRESH)) u_b (
    .clk(clk), .rst_n(rst_n), .link_up(link[1]), .tx_sym(tx_sym[1]), .rx_sym(rs1), .path_en(path_en[1]),
    .hop_tx0(hop_tx0[1]), .hop_tx1(hop_tx1[1]), .hop_rx0(hop_rx0[1]), .hop_rx1(hop_rx1[1]),
    .tx_valid(tx_valid[1]), .tx_ready(tx_ready[1]), .tx_data(tx_data[1]), .tx_last(tx_last[1]),
    .tx_path(tx_path[1]), .rx_valid(rx_valid[1]), .rx_ready(rx_ready[1]), .rx_data(rx_data[1]),
    .rx_last(rx_last[1]), .rx_path(rx_path[1]), .sync(sync[1]), .path_up(path_up[1]),
    .ev_hec_fix(ev_hec_fix[1]), .ev_hec_bad(ev_hec_bad[1]), .ev_proto(ev_proto[1]), .ev_hop(ev_hop[1]),
    .ev_len(ev_len[1]), .ev_overflow(ev_overflow[1]));

  // ---------------- HEC ----------------
  function automatic logic [7:0] crc8(input logic [23:0] d);
    logic [7:0] c;
    c = 0;
    for (int i = 23; i >= 0; i--) c = {c[6:0], 1'b0} ^ ((c[7] ^ d[i]) ? 8'h07 : 8'h00);
    return c;
  endfunction
  function automatic logic [31:0] mkh(input logic [3:0] pdf, input logic [10:0] hop, input logic [7:0] len);
    return {pdf, 1'b0, hop, len, crc8({pdf, 1'b0, hop, len}) ^ 8'h55};
  endfunction
  function automatic int pad4(input int l);
    return (l + 3) / 4 * 4;
  endfunction

  // ---------------- host writers and scoreboards ----------------
  // byte queues, {last, byte} (Icarus has no arrays of queues): EP + 2 * e
  // + q: packets end e must hand out on its path q; BP + q: what A must
  // hand out on its path q (from the BFM); AX + p: what A must send on its
  // path p (to the BFM)
  localparam int EP = 0, BP = 4, AX = 6;
  logic [8:0] q0 [$], q1 [$], q2 [$], q3 [$], q4 [$], q5 [$], q6 [$], q7 [$];
  task automatic qpush(input int i, input logic [8:0] x);
    case (i)
      0: q0.push_back(x); 1: q1.push_back(x); 2: q2.push_back(x); 3: q3.push_back(x);
      4: q4.push_back(x); 5: q5.push_back(x); 6: q6.push_back(x); default: q7.push_back(x);
    endcase
  endtask
  task automatic qpop(input int i, output logic [8:0] x);
    case (i)
      0: x = q0.pop_front(); 1: x = q1.pop_front(); 2: x = q2.pop_front(); 3: x = q3.pop_front();
      4: x = q4.pop_front(); 5: x = q5.pop_front(); 6: x = q6.pop_front(); default: x = q7.pop_front();
    endcase
  endtask
  function automatic int qsize(input int i);
    case (i)
      0: return q0.size(); 1: return q1.size(); 2: return q2.size(); 3: return q3.size();
      4: return q4.size(); 5: return q5.size(); 6: return q6.size(); default: return q7.size();
    endcase
  endfunction
  logic [7:0] wbuf [0:1][0:1][0:127];
  int         wn [0:1][0:1], wpos [0:1][0:1], wgap [0:1], nrx [0:1], gap_max = 20, rdy_pct [0:1];
  bit         wen [0:1][0:1];                     // end e writes to its path p
  int         wsel [0:1];                         // the path offered now
  bit         wtk [0:1];
  bit         wact [0:1][0:1];                    // a unit is open on the path
  int         route [0:1][0:1];                   // end e path p -> the other end's path (-1: nowhere)
  int         wmode = 0;                          // 1: long writes only
  bit         ilv = 1;                            // interleave the paths byte by byte
  initial for (int e = 0; e < 2; e++) begin
    nrx[e] = 0; wgap[e] = 0; rdy_pct[e] = 100; wtk[e] = 0; wsel[e] = 0;
    for (int p = 0; p < 2; p++) begin wn[e][p] = 0; wpos[e][p] = 0; wen[e][p] = 0; wact[e][p] = 0; route[e][p] = p; end
  end
  // a packet of the unit written at end e path p, from byte s, l bytes
  task expect_pkt(input int e, input int p, input int s, input int l);
    for (int i = 0; i < l; i++) qpush(EP + 2 * (1 - e) + route[e][p], {i == l - 1, wbuf[e][p][s + i]});
  endtask
  task new_unit(input int e, input int p);
    int s;
    if (wmode == 1 || $urandom % 100 < 5) wn[e][p] = MAXL + 1 + $urandom % 40;   // cut
    else if ($urandom % 4 == 0) wn[e][p] = 1 + $urandom % 4;
    else wn[e][p] = 1 + $urandom % MAXL;
    for (int i = 0; i < wn[e][p]; i++) wbuf[e][p][i] = $urandom;
    s = 0;
    while (wn[e][p] - s > MAXL) begin expect_pkt(e, p, s, MAXL); s += MAXL; end
    expect_pkt(e, p, s, wn[e][p] - s);
  endtask
  always @(posedge clk)
    for (int e = 0; e < 2; e++) begin
      if (tx_valid[e] && tx_ready[e] && !bfm) wtk[e] = 1;
      if (rx_valid[e] && rx_ready[e]) begin : b_read
        logic [8:0] x;
        int q;
        q = rx_path[e];
        if (e == 0 && bfm) begin
          // from the BFM
          if (qsize(BP + q) == 0) fail($sformatf("A path %0d: byte %h never sent", q, rx_data[e]));
          else begin
            qpop(BP + q, x);
            if ({rx_last[e], rx_data[e]} !== x) fail($sformatf("A path %0d: byte %b %h, expected %h", q, rx_last[e], rx_data[e], x));
            if (rx_last[e]) nrx[e]++;
          end
        end else if (qsize(EP + 2 * e + q) == 0) fail($sformatf("end %0d path %0d: byte %h never written", e, q, rx_data[e]));
        else begin
          qpop(EP + 2 * e + q, x);
          if ({rx_last[e], rx_data[e]} !== x)
            fail($sformatf("end %0d path %0d: byte %b %h, expected %b %h", e, q, rx_last[e], rx_data[e], x[8], x[7:0]));
          if (rx_last[e]) nrx[e]++;
        end
      end
    end
  always @(negedge clk)
    for (int e = 0; e < 2; e++) begin
      if (wtk[e]) begin : b_taken
        int p;
        p = wsel[e];
        wtk[e] = 0; tx_valid[e] = 0; wpos[e][p]++;
        if (wpos[e][p] == wn[e][p]) begin wpos[e][p] = 0; wact[e][p] = 0; wgap[e] = $urandom % (gap_max + 1); end
      end
      // offer a byte until taken; interleaving, the offer may move to the
      // other path's next byte while it waits
      if (rst_n && !bfm) begin : b_offer
        bit c [0:1];
        int p;
        for (int k = 0; k < 2; k++) c[k] = wen[e][k] || wact[e][k];
        p = -1;
        if (!tx_valid[e]) begin
          if (wgap[e] > 0) wgap[e]--;
          else if ((c[0] || c[1]) && $urandom % 8 != 0) begin
            if (!ilv && wact[e][0]) p = 0;
            else if (!ilv && wact[e][1]) p = 1;
            else p = c[0] && c[1] ? $urandom % 2 : c[1];
          end
        end else if (ilv && c[!wsel[e]] && $urandom % 4 == 0) p = !wsel[e];
        if (p >= 0) begin
          if (!wact[e][p]) begin new_unit(e, p); wact[e][p] = 1; end
          wsel[e] = p;
          tx_valid[e] = 1; tx_path[e] = p; tx_data[e] = wbuf[e][p][wpos[e][p]];
          tx_last[e] = wpos[e][p] == wn[e][p] - 1;
        end
      end
      rx_ready[e] = ($urandom % 100) < rdy_pct[e];
    end

  // ---------------- line monitors ----------------
  // parse the line of adapter e from link up: every header's HEC must be
  // good; m_hdr: the byte on the line now is header byte m_pos
  int         m_pos [0:1], m_left [0:1], m_pkts [0:1];
  bit         m_lk [0:1];                         // the link was up on the last clock
  logic [31:0] m_w [0:1];
  bit         m_hdr [0:1];
  // A's packets as the BFM sees them: data per path, grants
  logic [7:0] a_pay [$];
  int         a_kind = 0, a_hop = 0, a_len = 0, a_data [0:1], a_gcnt [0:1];
  initial for (int e = 0; e < 2; e++) begin m_pos[e] = 0; m_left[e] = 0; m_pkts[e] = 0; m_hdr[e] = 1; m_lk[e] = 0; end
  initial for (int p = 0; p < 2; p++) begin a_data[p] = 0; a_gcnt[p] = -1; end
  always @(posedge clk)
    for (int e = 0; e < 2; e++) begin
      if (!rst_n || !link[e] || !m_lk[e]) begin
        m_pos[e] = 0; m_left[e] = 0; m_hdr[e] = 1;
        if (e == 0) a_pay.delete();
      end else if (m_left[e] != 0) begin
        m_left[e]--;
        if (e == 0) begin
          a_pay.push_back(tx_sym[0]);
          if (m_left[e] == 0) a_done();
        end
        if (m_left[e] == 0) m_hdr[e] = 1;
      end else begin
        m_w[e] = {m_w[e][23:0], tx_sym[e]};
        m_pos[e]++;
        if (m_pos[e] == 4) begin
          m_pos[e] = 0; m_pkts[e]++;
          if (m_w[e] !== mkh(m_w[e][31:28], m_w[e][26:16], m_w[e][15:8]) || m_w[e][27])
            fail($sformatf("end %0d: header %h with a bad HEC", e, m_w[e]));
          m_left[e] = pad4(m_w[e][15:8]);
          if (e == 0) begin a_kind = m_w[e][31:28]; a_hop = m_w[e][26:16]; a_len = m_w[e][15:8]; a_pay.delete(); end
          if (m_left[e] != 0) m_hdr[e] = 0;
          else if (e == 0) a_done();
        end
      end
      m_lk[e] = rst_n && link[e];
    end
  // a packet of A seen whole
  task a_done;
    if (a_hop == 0) begin
      if (a_kind == 1) begin
        logic [7:0] b0, b1;
        b0 = a_pay[0]; b1 = a_pay[1];
        if (a_len != 4 || b0[7:3] != 0 || a_pay[2] != 0) fail("A: bad credit grant");
        if ({b0[2:0], b1} == hop_rx0[0]) a_gcnt[0] = a_pay[3];
        if ({b0[2:0], b1} == hop_rx1[0]) a_gcnt[1] = a_pay[3];
      end else if (a_kind != 0 || a_len != 0) fail("A: bad Idle");
    end else if (bfm) begin : b_data
      int p;
      p = a_hop == hop_tx0[0] && path_en[0][0] ? 0 : 1;
      if (a_hop != (p ? hop_tx1[0] : hop_tx0[0])) fail($sformatf("A: data on HopID %h", a_hop));
      a_data[p]++;
      if (qsize(AX + p) < a_len) fail($sformatf("A path %0d: %0d bytes, %0d written", p, a_len, qsize(AX + p)));
      else for (int i = 0; i < a_len; i++) begin : b_byte
        logic [8:0] x;
        qpop(AX + p, x);
        if ({i == a_len - 1, a_pay[i]} !== x) fail($sformatf("A path %0d: byte %h, expected %h", p, a_pay[i], x));
      end
      for (int i = a_len; i < a_pay.size(); i++) if (a_pay[i] != 0) fail("A: padding not zero");
    end
  endtask
  // single-bit header errors on channel d, one per header, while hdr_err
  int hdr_err [0:1], n_fix [0:1];
  bit hit_once [0:1];
  initial begin hdr_err[0] = 0; hdr_err[1] = 0; n_fix[0] = 0; n_fix[1] = 0; hit_once[0] = 0; hit_once[1] = 0; end
  always @(negedge clk)
    for (int d = 0; d < 2; d++) begin
      xs[d] = 0;
      if (m_pos[d] == 0) hit_once[d] = 0;
      if (hdr_err[d] != 0 && link[d] && m_hdr[d] && !hit_once[d] && $urandom % hdr_err[d] == 0) begin
        xs[d] = 8'd1 << ($urandom % 8); hit_once[d] = 1;
      end
    end
  always @(posedge clk) for (int e = 0; e < 2; e++) if (ev_hec_fix[e]) n_fix[e]++;

  // ---------------- BFM ----------------
  // the line never pauses: with nothing queued the BFM sends Idle packets
  // (b_fill) or zeros
  logic [7:0] bq [$];
  logic [7:0] fq [$];
  bit         b_fill = 0;
  always @(negedge clk) begin
    if (fq.size() == 0 && bq.size() == 0 && b_fill) begin
      fq.push_back(8'h00); fq.push_back(8'h00); fq.push_back(8'h00); fq.push_back(8'h55);
    end
    if (fq.size() != 0) b_sym = fq.pop_front();
    else if (bq.size() != 0) b_sym = bq.pop_front();
    else b_sym = 8'h00;
  end
  task automatic bwait;
    while (bq.size() != 0) @(negedge clk);
    @(negedge clk);
  endtask
  // a header; x: bits flipped
  task automatic bhdr(input logic [3:0] pdf, input logic [10:0] hop, input logic [7:0] len,
                      input logic [31:0] x = 0);
    logic [31:0] w;
    w = mkh(pdf, hop, len) ^ x;
    for (int i = 3; i >= 0; i--) bq.push_back(w[8 * i +: 8]);
  endtask
  task automatic bidle(input int n = 1, input logic [31:0] x = 0);
    for (int i = 0; i < n; i++) bhdr(0, 0, 0, x);
  endtask
  // n bytes on the line: random (or z: zeros)
  task automatic bbytes(input int n, input bit z = 0);
    for (int i = 0; i < n; i++) bq.push_back(z ? 8'h00 : 8'($urandom));
  endtask
  // a data packet of l bytes to HopID hop; q >= 0: A must hand it out on
  // its path q
  task bdata(input logic [10:0] hop, input int l, input int q = -1, input logic [31:0] x = 0);
    logic [7:0] b;
    bhdr(0, hop, 8'(l), x);
    for (int i = 0; i < pad4(l); i++) begin
      b = i < l ? 8'($urandom) : 8'h00;
      bq.push_back(b);
      if (q >= 0 && i < l) qpush(BP + q, {i == l - 1, b});
    end
  endtask
  task automatic bgrant(input logic [10:0] hop, input logic [7:0] cnt, input logic [4:0] res = 0,
                        input logic [7:0] mid = 0, input logic [7:0] len = 4);
    bhdr(1, 0, len, 0);
    bq.push_back({res, hop[10:8]}); bq.push_back(hop[7:0]); bq.push_back(mid); bq.push_back(cnt);
    for (int i = 4; i < pad4(len); i++) bq.push_back(8'h00);
  endtask

  // ---------------- helpers ----------------
  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask
  task automatic wait_sync(input int e, input int n = 2000);
    int t;
    t = 0;
    while (!sync[e] && t < n) begin @(negedge clk); t++; end
    if (!sync[e]) fail($sformatf("end %0d: no SYNC", e));
  endtask
  // writing paused: every packet delivered
  task automatic drain(input int n = 40000);
    int t;
    bit [3:0] w;
    for (int e = 0; e < 2; e++) for (int p = 0; p < 2; p++) begin w[2 * e + p] = wen[e][p]; wen[e][p] = 0; end
    t = 0;
    while (t < n && (qsize(0) + qsize(1) + qsize(2) + qsize(3) != 0 ||
                     wact[0][0] || wact[0][1] || wact[1][0] || wact[1][1])) begin @(negedge clk); t++; end
    if (t >= n) fail($sformatf("not drained: %0d %0d %0d %0d bytes", qsize(0), qsize(1), qsize(2), qsize(3)));
    for (int e = 0; e < 2; e++) for (int p = 0; p < 2; p++) wen[e][p] = w[2 * e + p];
  endtask
  task automatic link_cycle(input int n = 5);
    @(negedge clk);
    link = 0;
    wait_clk(n);
  endtask
  function automatic logic [10:0] rhop;
    logic [10:0] h;
    h = 0;
    while (h == 0) h = $urandom;
    return h;
  endfunction
  // a session configuration: xr: A path p -> B path p ^ 1 (and back);
  // en: paths enabled at both ends (by A's path index)
  task automatic configure(input bit xr, input logic [1:0] en);
    logic [10:0] h [0:3];
    h[0] = rhop(); h[1] = rhop(); h[2] = rhop(); h[3] = rhop();
    while (h[1] == h[0]) h[1] = rhop();
    while (h[3] == h[2]) h[3] = rhop();
    hop_tx0[0] = h[0]; hop_tx1[0] = h[1]; hop_rx0[0] = h[2]; hop_rx1[0] = h[3];
    route[0][0] = xr; route[0][1] = !xr; route[1][0] = xr; route[1][1] = !xr;
    path_en[0] = en;
    path_en[1] = xr ? {en[0], en[1]} : en;
    if (xr) begin hop_rx1[1] = h[0]; hop_rx0[1] = h[1]; hop_tx1[1] = h[2]; hop_tx0[1] = h[3]; end
    else begin hop_rx0[1] = h[0]; hop_rx1[1] = h[1]; hop_tx0[1] = h[2]; hop_tx1[1] = h[3]; end
    wen[0][0] = en[0]; wen[0][1] = en[1];
    wen[1][0] = xr ? en[1] : en[0]; wen[1][1] = xr ? en[0] : en[1];
  endtask

  int n_drop = 0;
  initial begin
    wait_clk(3);
    rst_n = 1;
    wait_clk(5);
    // ================= part 1: A <-> B =================
    for (int s = 0; s < 6; s++) begin
      configure(s % 2, s == 2 ? 2'b01 : s == 3 ? 2'b10 : 2'b11);
      link = 2'b11;
      wait_sync(0); wait_sync(1);
      wait_clk(6000);
      if (s == 1) begin
        // no gaps, both paths always busy
        gap_max = 0;
        wait_clk(8000);
        gap_max = 20;
        // long writes cut at MAXL, one path at a time
        wmode = 1; ilv = 0;
        wait_clk(3000);
        wmode = 0; ilv = 1;
      end
      if (s == 4) begin
        // slow readers: credits run out, grants on every read
        rdy_pct[0] = 5; rdy_pct[1] = 5;
        wait_clk(6000);
        rdy_pct[0] = 100; rdy_pct[1] = 100;
        // single-bit header errors both ways: corrected
        hdr_err[0] = 3; hdr_err[1] = 3;
        wait_clk(8000);
        hdr_err[0] = 0; hdr_err[1] = 0;
      end
      // the link drops with traffic going on
      for (int i = 0; i < 3; i++) begin
        wait_clk(300 + $urandom % 1500);
        link_cycle(2 + $urandom % 10);
        n_drop++;
        link = 2'b11;
      end
      wait_clk(2000);
      // (no writes into the next configuration with this one's routes)
      for (int e = 0; e < 2; e++) for (int p = 0; p < 2; p++) wen[e][p] = 0;
      drain();
      link_cycle();
    end
    if (n_fix[0] + n_fix[1] < 50) fail($sformatf("only %0d header errors corrected", n_fix[0] + n_fix[1]));

    // ================= part 2: A against the BFM =================
    for (int e = 0; e < 2; e++) for (int p = 0; p < 2; p++) wen[e][p] = 0;
    // from reset
    rst_n = 0;
    wait_clk(2);
    rst_n = 1;
    bfm = 1;
    hop_tx0[0] = 11'h001; hop_tx1[0] = 11'h7FE; hop_rx0[0] = 11'h2AA; hop_rx1[0] = 11'h555;
    path_en[0] = 2'b11;
    link[0] = 1;
    // zeros: no HEC fits; random bytes: false headers come and go
    bbytes(40, 1);
    bbytes(3000);
    bwait();
    if (sync[0]) fail("A in SYNC on random bytes");
    bbytes(300, 1);                               // out of any false PRESYNC
    // PRESYNC broken, twice, then SYNC
    bidle(2); bbytes(3); bidle(DELTA - 2); bidle(1, 32'h0000_0100);
    bidle(DELTA - 1);
    bidle(2);
    while (bq.size() > 8) @(negedge clk);
    if (sync[0]) fail("A in SYNC early");
    b_fill = 1;
    bwait();
    wait_clk(4);
    if (!sync[0]) fail("A not in SYNC");
    // A's grants: RXB for each path
    wait_clk(100);
    if (a_gcnt[0] != RXB || a_gcnt[1] != RXB) fail($sformatf("A granted %0d %0d", a_gcnt[0], a_gcnt[1]));
    // data to A: every length, both paths, padding
    for (int l = 1; l <= MAXL; l++) begin bdata(l % 2 ? 11'h2AA : 11'h555, l, l % 2 ? 0 : 1); bwait(); end
    bwait();
    wait_clk(50);
    // every single-bit error in a header: corrected
    for (int b = 0; b < 32; b++) begin
      if (b % 3 == 0) bidle(1, 32'd1 << b);
      else bdata(b % 2 ? 11'h2AA : 11'h555, 1 + $urandom % MAXL, b % 2 ? 0 : 1, 32'd1 << b);
      bwait();
      wait_clk(MAXL);
    end
    bwait();
    wait_clk(50);
    if (!sync[0]) fail("A lost SYNC on single-bit errors");
    // receive errors, each skipped by its length
    bhdr(4'h2, 0, 0);                             // HopID 0, unknown PDF
    bhdr(4'h0, 0, 8'd4); bbytes(4);               // Idle with a length
    bgrant(11'h001, 2, 0, 0, 8'd8);               // grant of the wrong length
    bdata(11'h123, 20);                           // no such path
    bdata(11'h2AA, 0);                            // length 0
    bdata(11'h555, MAXL + 1);                     // too long
    bhdr(4'h0, 11'h2AA, 8'd255); bbytes(256);     // longest
    bhdr(4'h0, 11'h555, 8'd254); bbytes(256);
    bdata(11'h2AA, 5, 0);
    bwait();
    wait_clk(50);
    // overflow: A does not read; RXB + 1 packets on path 0
    rdy_pct[0] = 0;
    wait_clk(20);
    for (int i = 0; i < RXB; i++) bdata(11'h2AA, 8, 0);
    bdata(11'h2AA, 8);
    bdata(11'h555, 8, 1);                          // the other path still has room
    bwait();
    wait_clk(20);
    rdy_pct[0] = 100;
    wait_clk(200);
    // credit grants to A: path 0 gets 1, path 1 gets 2
    bgrant(11'h001, 1); bgrant(11'h7FE, 2);
    bwait();
    if (path_up[0] !== 2'b11) fail("A paths not up");
    // A sends: one packet on path 0, two on path 1, then waits
    a_write(0, 10); a_write(1, 3); a_write(1, MAXL); a_write(0, 7);
    wait_clk(400);
    if (a_data[0] != 1 || a_data[1] != 2) fail($sformatf("A sent %0d %0d packets", a_data[0], a_data[1]));
    // grants: refresh (same count), more for path 0
    bgrant(11'h001, 1);
    bgrant(11'h001, 2);
    bwait();
    wait_clk(200);
    if (a_data[0] != 2) fail("A did not use the new credit");
    // bad grants: reserved bits, middle byte, no such HopID, more than RXB
    // ahead, HopID 0
    bgrant(11'h001, 3, 5'h10);
    bgrant(11'h001, 3, 0, 8'h01);
    bgrant(11'h0F0, 3);
    bgrant(11'h7FE, 8'(2 + RXB + 1));
    bgrant(11'h000, 3);
    bwait();
    wait_clk(50);
    // both paths with credit: round robin
    bgrant(11'h001, 4); bgrant(11'h7FE, 4);
    bwait();
    for (int i = 0; i < 2; i++) begin a_write(0, 4 + i); a_write(1, 9 + i); end
    wait_clk(500);
    if (a_data[0] != 4 || a_data[1] != 4) fail($sformatf("A sent %0d %0d packets (round robin)", a_data[0], a_data[1]));
    // a path disabled: its packet waits, the HopID is unknown, grants for
    // it are refused; enabled again, it is sent
    bgrant(11'h7FE, 5);                           // a credit left over
    bwait();
    path_en[0] = 2'b01;
    bgrant(11'h7FE, 5);
    bdata(11'h555, 8);
    a_write(1, 6);
    bwait();
    wait_clk(300);
    if (a_data[1] != 4) fail("A sent on a disabled path");
    path_en[0] = 2'b10;                            // and path 0 disabled
    bdata(11'h2AA, 8);
    bwait();
    path_en[0] = 2'b11;
    wait_clk(300);
    if (a_data[1] != 5) fail("A did not send after the path was enabled");
    // the same egress HopID on both paths: path 0 takes the grant
    hop_tx1[0] = 11'h001;
    bgrant(11'h001, 5);
    bwait();
    hop_tx1[0] = 11'h7FE;
    a_write(0, 9);
    wait_clk(100);
    if (a_data[0] != 5) fail("path 0 did not take the grant");
    // HopID 0 configured: a grant for HopID 0 is still refused
    hop_tx0[0] = 11'h000;
    bgrant(11'h000, 5);
    bwait();
    hop_tx0[0] = 11'h001;
    hop_tx1[0] = 11'h000;
    bgrant(11'h000, 5);
    bwait();
    hop_tx1[0] = 11'h7FE;
    // the same ingress HopID on both paths: path 0 takes the data
    hop_rx1[0] = 11'h2AA;
    bdata(11'h2AA, 6, 0);
    bwait();
    wait_clk(50);
    hop_rx1[0] = 11'h555;
    // the link drops while A sends a long packet: sent again
    bgrant(11'h001, 6);
    bwait();
    a_write(0, MAXL);
    while (!(u_a.tkind == 2 && u_a.tcnt == 10)) @(negedge clk);
    link_cycle();
    for (int p = 0; p < 2; p++) a_data[p] = 0;
    link[0] = 1;
    bidle(LEAD); bwait();
    bgrant(11'h001, 1); bgrant(11'h7FE, 1);
    bwait();
    wait_clk(200);
    if (a_data[0] != 1) fail("A did not send the cut packet again");
    // a grant cut by the link: link down while it comes in
    bgrant(11'h7FE, 1);
    wait_clk(3);
    link_cycle();
    bq.delete();
    link[0] = 1;
    bidle(LEAD); bwait();
    // grant refresh: A sends its grants again every REFRESH clocks
    a_gcnt[0] = -1; a_gcnt[1] = -1;
    wait_clk(REFRESH + 50);
    if (a_gcnt[0] != RXB || a_gcnt[1] != RXB) fail("A did not refresh its grants");
    // SYNC lost: an uncorrectable header (double-bit), then A hunts again
    bidle(2, 32'h0001_0001);
    bdata(11'h2AA, 12);                           // lost while hunting
    bidle(DELTA + 2);
    bdata(11'h2AA, 3, 0);
    bwait();
    wait_clk(50);
    if (!sync[0]) fail("A not in SYNC again");
    // a reset with the link up
    @(negedge clk);
    rst_n = 0;
    q4.delete(); q5.delete(); q6.delete(); q7.delete();
    wait_clk(3);
    rst_n = 1;
    wait_clk(20);
    link[0] = 0;

    if (errors == 0) $display("TEST PASSED: USB4 (%0d / %0d packets, %0d header errors corrected)", nrx[0], nrx[1],
                              n_fix[0] + n_fix[1]);
    else $display("TEST FAILED: USB4 (%0d errors)", errors);
    $finish;
  end

  // the host at A writes a packet of l bytes to path p (one byte a clock
  // while the buffer is free); the BFM expects it
  task a_write(input int p, input int l);
    logic [7:0] b;
    for (int i = 0; i < l; i++) begin
      b = $urandom;
      qpush(AX + p, {i == l - 1, b});
      tx_valid[0] = 1; tx_path[0] = p; tx_data[0] = b; tx_last[0] = i == l - 1;
      @(posedge clk);
      while (!tx_ready[0]) @(posedge clk);
      @(negedge clk);
      tx_valid[0] = 0;
    end
  endtask

  initial begin
    #40ms;
    $display("A: sync %0d up %b tst %0d tkind %0d occ %0d %0d | B: sync %0d up %b", sync[0], path_up[0], u_a.tst,
             u_a.tkind, u_a.occ[0], u_a.occ[1], sync[1], path_up[1]);
    $display("TEST FAILED: USB4 (timeout)");
    $finish;
  end
endmodule
