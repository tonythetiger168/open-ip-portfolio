// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of TS_Demux_top (TV SoC, AXI4 manager).
// A TSI source sends 188-byte packets with random PIDs (filtered and not),
// PUSI, adaptation field control, continuity counters and payload, with
// random idle gaps between bytes. A reference model predicts which packets
// reach the ring and their descriptors; every PKT interrupt is checked
// against the next predicted packet (all 48 words of its slot in the AXI4
// memory model). Covers: bad sync byte, ts_err, TEI, short packets, CC
// discontinuities, packets without payload, ring wrap and ring full (OVF),
// AXI write errors, ENABLE off, random and zero memory stalls, reset.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module TS_Demux_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  logic        ts_valid = 0, ts_sync = 0, ts_err = 0;
  logic [7:0]  ts_data = 0;
  logic        enable = 0;
  logic [3:0]  pid_en = 0;
  logic [12:0] pid0 = 0, pid1 = 0, pid2 = 0, pid3 = 0;
  logic [31:0] ring_base = 0;
  logic [15:0] ring_pkts = 0, rd_idx = 0;
  wire  [15:0] wr_idx, pkt_cnt, drop_cnt, cc_err_cnt, ovf_cnt;
  wire         busy, err, pkt, drop, cc_err, err_irq;
  TS_Demux_top dut (.*);

  // ---------------- reference model ----------------
  logic [31:0] expq [$];                             // 48 words per predicted packet
  int          m_slot = 0, m_queued = 0;            // model WR_IDX and packets in flight
  bit          m_seen [4];
  logic [3:0]  m_cc [4];
  int          n_pkt = 0, n_drop = 0, n_cc = 0, n_err_irq = 0;
  bit          auto_consume = 1;
  int          exp_drop = 0, exp_cc = 0, exp_ovf = 0;
  int          nbad = 0;

  function automatic int npk; return ring_pkts == 0 ? 1 : ring_pkts; endfunction
  always @(posedge clk) if (rst_n) begin
    n_drop += drop; n_cc += cc_err; n_err_irq += err_irq;
    if (pkt) begin
      n_pkt++;
      if (expq.size() == 0) fail("PKT without a predicted packet");
      else begin
        logic [31:0] a, e;
        a = ring_base + 32'(m_slot) * 192;
        for (int i = 0; i < 48; i++) begin
          e = expq.pop_front();
          if (!err_irq && mem.peek(a + 32'(4 * i)) !== e)
            if (nbad++ < 8) fail($sformatf("slot %0d word %0d: %h, expected %h", m_slot, i, mem.peek(a + 32'(4 * i)), e));
        end
        m_slot = (m_slot + 1) % npk();
        m_queued--;
        if (auto_consume) rd_idx <= 16'(m_slot);
      end
    end
  end

  // one packet; kind: 0 good, 1 bad sync byte, 2 ts_err, 3 TEI, 4 short
  task automatic send(input logic [12:0] pid, input int kind, input bit pl, input logic [3:0] cc, input int gap);
    logic [7:0] b [188];
    int fsel, n;
    bit hit;
    b[0] = (kind == 1) ? 8'h46 : 8'h47;
    b[1] = {(kind == 3), 1'($urandom), 1'b0, pid[12:8]};
    b[2] = pid[7:0];
    b[3] = {2'b00, pl ? 2'b01 : 2'b10, cc};
    for (int i = 4; i < 188; i++) b[i] = $urandom;
    n = (kind == 4) ? 20 + $urandom % 150 : 188;
    for (int i = 0; i < n; i++) begin
      if (gap > 0) repeat ($urandom % (gap + 1)) begin @(negedge clk); ts_valid = 0; ts_sync = $urandom; end
      @(negedge clk);
      ts_valid = 1; ts_sync = (i == 0); ts_data = b[i]; ts_err = (kind == 2 && i == 100);
    end
    @(negedge clk); ts_valid = 0; ts_sync = 0; ts_err = 0;
    // prediction
    hit = 0; fsel = 0;
    for (int f = 3; f >= 0; f--) if (pid_en[f] && pid == (f == 0 ? pid0 : f == 1 ? pid1 : f == 2 ? pid2 : pid3)) begin hit = 1; fsel = f; end
    if (!enable) return;
    if (kind != 0) begin
      exp_drop++;                                     // a short packet counts when the next sync arrives
      return;
    end
    if (!hit) return;
    if (((m_slot + m_queued + 1) % npk()) == rd_idx || m_queued >= 2) begin exp_ovf++; return; end
    begin
      bit ccb;
      ccb = pl && m_seen[fsel] && cc != m_cc[fsel] + 4'd1;
      if (pl) begin m_seen[fsel] = 1; m_cc[fsel] = cc; end
      if (ccb) exp_cc++;
      for (int i = 0; i < 47; i++) expq.push_back({b[4*i+3], b[4*i+2], b[4*i+1], b[4*i]});
      expq.push_back({ccb, 1'b0, b[1][6], 2'(fsel), 7'b0, cc, 3'b0, pid});
      m_queued++;
    end
  endtask

  task automatic drain(input string what);
    int t;
    t = 0;
    while ((busy || expq.size() != 0) && t < 50000) begin @(negedge clk); t++; end
    if (expq.size() != 0) fail($sformatf("%s: %0d packets never written", what, expq.size() / 48));
    if (n_drop != exp_drop) fail($sformatf("%s: %0d DROP, expected %0d", what, n_drop, exp_drop));
    if (drop_cnt !== 16'(exp_drop)) fail($sformatf("%s: DROP_CNT %0d, expected %0d", what, drop_cnt, exp_drop));
    if (cc_err_cnt !== 16'(exp_cc) || n_cc != exp_cc) fail($sformatf("%s: CC_ERR %0d/%0d, expected %0d", what, cc_err_cnt, n_cc, exp_cc));
    if (ovf_cnt !== 16'(exp_ovf)) fail($sformatf("%s: OVF_CNT %0d, expected %0d", what, ovf_cnt, exp_ovf));
    if (pkt_cnt !== 16'(n_pkt)) fail($sformatf("%s: PKT_CNT %0d, PKT pulses %0d", what, pkt_cnt, n_pkt));
    if (wr_idx !== 16'(m_slot)) fail($sformatf("%s: WR_IDX %0d, expected %0d", what, wr_idx, m_slot));
  endtask

  logic [12:0] pids [4];
  function automatic logic [12:0] rpid;
    return ($urandom % 3 == 0) ? 13'($urandom) : pids[$urandom % 4];
  endfunction

  logic [3:0] ccs [8192];
  task automatic stream(input int n, input int gap, input int bad_pct);
    for (int k = 0; k < n; k++) begin
      logic [12:0] p; int kind; bit pl; logic [3:0] cc;
      p = rpid();
      kind = ($urandom % 100 < bad_pct) ? 1 + $urandom % 4 : 0;
      pl = ($urandom % 8) != 0;
      cc = ccs[p] + (pl ? 4'd1 : 4'd0);
      if ($urandom % 20 == 0) cc = $urandom;                // discontinuity
      ccs[p] = cc;
      send(p, kind, pl, cc, gap);
    end
  endtask

  initial begin
    lat_master = "tsd";
    for (int i = 0; i < 8192; i++) ccs[i] = 0;
    pids = '{13'h100, 13'h101, 13'h1FFF, 13'h0};
    pid0 = pids[0]; pid1 = pids[1]; pid2 = pids[2]; pid3 = pids[3];
    pid_en = 4'b0111;
    ring_base = 32'h0020_0000; ring_pkts = 7;
    clks(3);
    rst_n = 1;
    clks(2);
    // disabled: nothing happens
    send(13'h100, 0, 1, 0, 0);
    clks(20);
    if (busy || mem.n_wr_bursts != 0 || pkt_cnt != 0) fail("traffic while disabled");
    enable = 1;
    clks(1);
    // good stream, random gaps, stalls on and off
    for (int r = 0; r < 4; r++) begin
      mem.stall = r != 3;
      stream(20, r, 0);
      drain($sformatf("round %0d", r));
    end
    // errored packets
    stream(40, 1, 30);
    send(13'h100, 0, 1, ccs[13'h100] + 4'd1, 0);      // ends a trailing short packet
    ccs[13'h100] += 4'd1;
    drain("bad packets");
    // all four filters, filter 3 = PID 0 (PAT)
    pid_en = 4'hF;
    stream(16, 0, 0);
    drain("four filters");
    // ring full: the consumer stops
    auto_consume = 0;
    clks(1);
    for (int k = 0; k < 10; k++) begin
      ccs[13'h101] += 4'd1;
      send(13'h101, 0, 1, ccs[13'h101], 0);
      clks(200);
    end
    drain("ring full");
    if (ovf_cnt == 0) fail("ring full: no OVF");
    auto_consume = 1;
    rd_idx = 16'(m_slot);
    // AXI write error on a packet
    begin
      int ne0;
      ne0 = n_err_irq;
      mem.err_lo = ring_base + 32'(m_slot) * 192 + 40; mem.err_hi = mem.err_lo + 4;
      ccs[13'h100] += 4'd1;
      send(13'h100, 0, 1, ccs[13'h100], 0);
      drain("axi error");
      if (n_err_irq != ne0 + 1 || !err) fail("ERR after an AXI error response");
      mem.err_lo = '1; mem.err_hi = '1;
    end
    // ENABLE low: ERR and WR_IDX clear, CC history forgotten
    enable = 0; clks(3);
    if (err || wr_idx != 0) fail("ENABLE 0 does not clear ERR / WR_IDX");
    m_slot = 0; rd_idx = 0; m_seen = '{0, 0, 0, 0};
    enable = 1; clks(1);
    stream(10, 0, 0);
    drain("re-enable");
    // reset in the middle of a packet
    fork
      send(13'h100, 0, 1, 0, 0);
      begin clks(90); rst_n = 0; end
    join
    clks(2);
    if (busy || m_awvalid || m_wvalid) fail("not idle in reset");
    rst_n = 1;
    expq.delete(); m_slot = 0; m_queued = 0; rd_idx = 0; m_seen = '{0, 0, 0, 0};
    n_pkt = 0; n_drop = 0; n_cc = 0; exp_drop = 0; exp_cc = 0; exp_ovf = 0;
    clks(2);
    stream(8, 0, 0);
    drain("after reset");
    lat_summary();
    finish("TS_Demux");
  end
endmodule
