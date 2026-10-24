// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for CAN_top v2.0
//  * Two controllers A and B on one wired-AND bus, on clocks that differ by
//    a few 0.1% (both directions), so resynchronisation is exercised.
//  * A bus-functional node (BFM) on A's clock builds frames itself (own
//    stuffing and CRC), with optional edge jitter and fault injection (bit
//    flip, wrong CRC, missing stuff bit, dominant delimiters / EOF).
//  * A bus monitor decodes every frame on the bus independently; every valid
//    frame must be delivered by each active non-transmitting controller
//    whose acceptance filter matches (and by no other), and each tx_done
//    must match the frame the monitor saw.
//  * Directed scenarios: base/extended, data/remote, DLC 0..15, filters,
//    arbitration (ID, base vs extended, data vs remote), errors of every
//    kind, error-passive, bus-off and recovery, abort, bit-timing extremes,
//    reset in the middle of a frame.
// ============================================================================
`timescale 1ns/1ps
module CAN_tb;
  localparam int TIMEOUT_BITS = 4000;
  typedef logic [98:0] frame_t;         // {id[28:0], ide, rtr, dlc[3:0], data[63:0]}

  logic clk_a = 0, clk_b = 0;
  logic rst_a = 0, rst_b = 0;
  real  hb = 5.015;                     // B's half period (A: 5.000 ns)
  always #5 clk_a = ~clk_a;
  always #(hb) clk_b = ~clk_b;

  logic [5:0]  cfg_brp = 1;
  logic [3:0]  cfg_tseg1 = 5;
  logic [2:0]  cfg_tseg2 = 2;
  logic [1:0]  cfg_sjw = 1;

  // ---------------- node ports ----------------
  logic        a_txd, b_txd;
  logic [28:0] a_acc_code = 0, a_acc_mask = 0, b_acc_code = 0, b_acc_mask = 0;
  logic        a_tx_valid = 0, b_tx_valid = 0, a_tx_abort = 0, b_tx_abort = 0;
  logic [28:0] a_tx_id = 0, b_tx_id = 0;
  logic        a_tx_ide = 0, b_tx_ide = 0, a_tx_rtr = 0, b_tx_rtr = 0;
  logic [3:0]  a_tx_dlc = 0, b_tx_dlc = 0;
  logic [63:0] a_tx_data = 0, b_tx_data = 0;
  logic        a_tx_ready, b_tx_ready, a_tx_done, b_tx_done, a_tx_aborted, b_tx_aborted;
  logic        a_rx_valid, b_rx_valid, a_rx_ide, b_rx_ide, a_rx_rtr, b_rx_rtr;
  logic [28:0] a_rx_id, b_rx_id;
  logic [3:0]  a_rx_dlc, b_rx_dlc;
  logic [63:0] a_rx_data, b_rx_data;
  logic        a_arb_lost, b_arb_lost;
  logic        a_err_bit, a_err_stuff, a_err_crc, a_err_form, a_err_ack;
  logic        b_err_bit, b_err_stuff, b_err_crc, b_err_form, b_err_ack;
  logic [8:0]  a_tec, b_tec;
  logic [7:0]  a_rec, b_rec;
  logic        a_err_passive, b_err_passive, a_bus_off, b_bus_off;

  // ---------------- bus ----------------
  logic bfm_drv = 1;                    // BFM / global disturbance
  logic dis_a = 1, dis_b = 1;           // local disturbance (0 forces dominant at one node)
  wire  bus  = a_txd & b_txd & bfm_drv;
  wire  rx_a = bus & dis_a;
  wire  rx_b = bus & dis_b;

  CAN_top u_a (
    .clk(clk_a), .rst_n(rst_a), .rxd(rx_a), .txd(a_txd),
    .cfg_brp(cfg_brp), .cfg_tseg1(cfg_tseg1), .cfg_tseg2(cfg_tseg2), .cfg_sjw(cfg_sjw),
    .acc_code(a_acc_code), .acc_mask(a_acc_mask),
    .tx_valid(a_tx_valid), .tx_ready(a_tx_ready), .tx_id(a_tx_id), .tx_ide(a_tx_ide),
    .tx_rtr(a_tx_rtr), .tx_dlc(a_tx_dlc), .tx_data(a_tx_data), .tx_abort(a_tx_abort),
    .tx_done(a_tx_done), .tx_aborted(a_tx_aborted),
    .rx_valid(a_rx_valid), .rx_id(a_rx_id), .rx_ide(a_rx_ide), .rx_rtr(a_rx_rtr),
    .rx_dlc(a_rx_dlc), .rx_data(a_rx_data), .arb_lost(a_arb_lost),
    .err_bit(a_err_bit), .err_stuff(a_err_stuff), .err_crc(a_err_crc), .err_form(a_err_form),
    .err_ack(a_err_ack), .tec(a_tec), .rec(a_rec), .err_passive(a_err_passive), .bus_off(a_bus_off));

  CAN_top u_b (
    .clk(clk_b), .rst_n(rst_b), .rxd(rx_b), .txd(b_txd),
    .cfg_brp(cfg_brp), .cfg_tseg1(cfg_tseg1), .cfg_tseg2(cfg_tseg2), .cfg_sjw(cfg_sjw),
    .acc_code(b_acc_code), .acc_mask(b_acc_mask),
    .tx_valid(b_tx_valid), .tx_ready(b_tx_ready), .tx_id(b_tx_id), .tx_ide(b_tx_ide),
    .tx_rtr(b_tx_rtr), .tx_dlc(b_tx_dlc), .tx_data(b_tx_data), .tx_abort(b_tx_abort),
    .tx_done(b_tx_done), .tx_aborted(b_tx_aborted),
    .rx_valid(b_rx_valid), .rx_id(b_rx_id), .rx_ide(b_rx_ide), .rx_rtr(b_rx_rtr),
    .rx_dlc(b_rx_dlc), .rx_data(b_rx_data), .arb_lost(b_arb_lost),
    .err_bit(b_err_bit), .err_stuff(b_err_stuff), .err_crc(b_err_crc), .err_form(b_err_form),
    .err_ack(b_err_ack), .tec(b_tec), .rec(b_rec), .err_passive(b_err_passive), .bus_off(b_bus_off));

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction
  task automatic ca(input int n); repeat (n) @(negedge clk_a); endtask

  function automatic int bt();          // bit time in clk_a cycles
    return (cfg_brp + 1) * (cfg_tseg1 + cfg_tseg2 + 3);
  endfunction
  function automatic int spt();         // sample point after the edge
    return (cfg_brp + 1) * (cfg_tseg1 + 2);
  endfunction
  task automatic bits(input int n); ca(n * bt()); endtask

  // ---------------- frames ----------------
  function automatic frame_t mkf(input logic [28:0] id, input logic ide, input logic rtr,
                                 input logic [3:0] dlc, input logic [63:0] d);
    return {id, ide, rtr, dlc, d};
  endfunction
  // canonical form as a receiver reports it
  function automatic frame_t norm(input frame_t f);
    int n;
    logic [63:0] d;
    n = f[68] ? 0 : (f[67:64] > 8 ? 8 : int'(f[67:64]));
    d = 0;
    for (int i = 0; i < 64; i++) if (i < 8 * n) d[i] = f[i];
    return {f[69] ? f[98:70] : {18'h0, f[80:70]}, f[69], f[68], f[67:64], d};
  endfunction
  function automatic logic acc(input frame_t f, input logic [28:0] code, input logic [28:0] mask);
    return ((norm(f) >> 70 ^ code) & mask) == 0;
  endfunction
  function automatic string fs(input frame_t f);
    return $sformatf("%s id=%h rtr=%0d dlc=%0d data=%h", f[69] ? "EXT" : "STD",
                     f[69] ? f[98:70] : f[80:70], f[68], f[67:64], f[63:0]);
  endfunction
  function automatic frame_t rnd_frame();
    frame_t f;
    f = {$urandom, $urandom, $urandom, $urandom};
    f[67:64] = $urandom % 16;
    f[68] = ($urandom % 5) == 0;
    return f;
  endfunction

  function automatic logic [14:0] crc15(input logic [14:0] c, input logic b);
    logic fb;
    fb = b ^ c[14];
    c = c << 1;
    if (fb) c = c ^ 15'h4599;
    return c;
  endfunction

  // ---------------- bit-stream builder (BFM) ----------------
  logic ds  [0:127];                    // de-stuffed SOF..CRC
  logic raw [0:159];                    // stuffed
  int   raw_pos [0:159];                // de-stuffed index of each raw bit (-1: stuff)
  int   n_ds, n_raw, n_arb;
  function automatic void build(input frame_t f, input logic bad_crc);
    logic [14:0] c;
    int n, k, run;
    logic last;
    frame_t g;
    g = norm(f);
    n = 0;
    ds[n++] = 0;
    if (g[69]) begin
      for (int i = 28; i >= 18; i--) ds[n++] = g[70 + i];
      ds[n++] = 1; ds[n++] = 1;                     // SRR, IDE
      for (int i = 17; i >= 0; i--) ds[n++] = g[70 + i];
      ds[n++] = g[68]; ds[n++] = 0; ds[n++] = 0;    // RTR, r1, r0
      n_arb = 32;
    end else begin
      for (int i = 10; i >= 0; i--) ds[n++] = g[70 + i];
      ds[n++] = g[68]; ds[n++] = 0; ds[n++] = 0;    // RTR, IDE, r0
      n_arb = 12;
    end
    for (int i = 3; i >= 0; i--) ds[n++] = g[64 + i];
    k = g[68] ? 0 : (g[67:64] > 8 ? 8 : int'(g[67:64]));
    for (int i = 0; i < 8 * k; i++) ds[n++] = g[8 * (i / 8) + 7 - i % 8];
    c = 0;
    for (int i = 0; i < n; i++) c = crc15(c, ds[i]);
    if (bad_crc) c = c ^ 15'h0001;
    for (int i = 14; i >= 0; i--) ds[n++] = c[i];
    n_ds = n;
    k = 0; run = 0; last = 1'bx;
    for (int i = 0; i < n; i++) begin
      raw_pos[k] = i; raw[k++] = ds[i];
      if (ds[i] === last) run++; else begin run = 1; last = ds[i]; end
      if (run == 5) begin raw_pos[k] = -1; raw[k++] = ~last; last = ~last; run = 1; end
    end
    n_raw = k;
  endfunction

  // ---------------- BFM ----------------
  int bfm_jitter = 0;                   // max +-tq shift of each edge from the ideal grid
  int bfm_jprev = 0;
  int bfm_flip = -1;                    // raw index to invert (-1: none)
  int bfm_skip_stuff = -1;              // raw index of a stuff bit to drop
  int bfm_tail_dom = -1;                // 0 CRC delim, 2 ACK delim, 3..9 EOF bit: drive dominant
  bit bfm_ack;                          // ACK slot was dominant
  bit bfm_lost;                         // lost arbitration
  bit bfm_err;                          // saw a dominant bit where it drove recessive
  task automatic bfm_bit(input logic v, output logic seen);
    int len, j;
    len = bt();
    if (bfm_jitter > 0) begin                     // next edge displaced by j tq (not cumulative)
      j = $urandom_range(0, 2 * bfm_jitter) - bfm_jitter;
      len = len + (j - bfm_jprev) * (cfg_brp + 1);
      bfm_jprev = j;
    end
    bfm_drv = v;
    ca(spt());
    seen = bus;
    ca(len - spt());
  endtask
  bit bfm_sync = 0;                     // 1: start at once (SOF of another node)
  task automatic bfm_send(input frame_t f, input logic bad_crc);
    logic s;
    int stuffs;
    if (!bfm_sync) idle(3);
    bfm_sync = 0;
    build(f, bad_crc);
    bfm_ack = 0; bfm_lost = 0; bfm_err = 0; stuffs = 0;
    for (int i = 0; i < n_raw && !bfm_lost && !bfm_err; i++) begin
      if (i != bfm_skip_stuff) begin
        bfm_bit(i == bfm_flip ? ~raw[i] : raw[i], s);
        if (raw[i] && !s && i != bfm_flip) begin
          if (raw_pos[i] >= 1 && raw_pos[i] <= n_arb) begin bfm_lost = 1; bfm_drv = 1; end
          else bfm_err = 1;
        end
        if (i == bfm_flip || (bfm_skip_stuff >= 0 && i == bfm_skip_stuff + 1)) bfm_err = 1;  // receivers flag it
      end
    end
    // CRC delimiter, ACK slot, ACK delimiter, EOF; stop at the first error
    for (int t = 0; t < 10 && !bfm_lost && !bfm_err; t++) begin
      bfm_bit(t == bfm_tail_dom ? 1'b0 : 1'b1, s);
      if (t == bfm_tail_dom) bfm_err = 1;
      else if (t == 1) begin bfm_ack = !s; if (s) bfm_err = 1; end
      else if (!s) bfm_err = 1;
    end
    bfm_drv = 1;
    bfm_flip = -1; bfm_skip_stuff = -1; bfm_tail_dom = -1;
    if (bfm_jprev > 0) ca(bfm_jprev * (cfg_brp + 1));
    bfm_jprev = 0;
  endtask
  // wait until the bus has been recessive for n bit times
  task automatic idle(input int n);
    int r, guard;
    r = 0; guard = 0;
    while (r < n * bt() && guard < TIMEOUT_BITS * bt()) begin
      @(negedge clk_a);
      r = bus ? r + 1 : 0;
      guard++;
    end
    if (guard >= TIMEOUT_BITS * bt()) fail("bus never idle");
  endtask

  // ---------------- bus monitor ----------------
  frame_t mon_f;
  int     mon_n = 0, mon_bad = 0;
  event   mon_done;
  logic   m_prev = 1;
  int     m_cnt = 0, m_rec = 99, m_st = 0, m_k, m_run, m_nds, m_req = 11;
  logic   m_last;
  int     m_prev_rec = 0;
  logic   m_ds [0:127];
  always @(posedge clk_a) begin : monitor
    logic smp, ok;
    logic [14:0] c;
    int nb;
    frame_t g;
    smp = 1'bx;
    if (m_prev && !bus) m_cnt = spt();
    else if (m_cnt > 0) m_cnt--;
    m_prev = bus;
    if (m_cnt == 1) begin
      m_cnt = bt() + 1;
      smp = bus;
      m_prev_rec = m_rec;
      m_rec = smp ? m_rec + 1 : 0;
      case (m_st)
        0: if (!smp && m_prev_rec >= m_req) begin           // SOF: from the 3rd IFS bit on, 11 bits after an error
             m_st = 1; m_nds = 1; m_ds[0] = 0; m_run = 1; m_last = 0; m_k = 0;
           end
        1: begin
             if (m_run == 5) begin                          // stuff bit
               if (smp == m_last) begin m_st = 0; mon_bad++; m_req = 11; end
               m_run = 1; m_last = smp;
             end else begin
               m_ds[m_nds++] = smp;
               if (smp == m_last) m_run++; else begin m_run = 1; m_last = smp; end
               // header known: compute the CRC end
               nb = 0;
               if (m_nds > 19) begin
                 if (m_ds[13]) nb = m_nds > 39 ? (m_ds[32] ? 0 : dlcn(m_ds[35], m_ds[36], m_ds[37], m_ds[38])) : 99;
                 else nb = m_ds[12] ? 0 : dlcn(m_ds[15], m_ds[16], m_ds[17], m_ds[18]);
                 if (nb != 99 && m_nds == (m_ds[13] ? 39 : 19) + 8 * nb + 15) begin
                   m_st = 2; m_k = 0;
                 end
               end
             end
           end
        2: if (m_run == 5) begin                            // stuff bit after the CRC
             if (smp == m_last) begin m_st = 0; mon_bad++; m_req = 11; end
             m_run = 0;
           end else if (!smp) begin m_st = 0; mon_bad++; m_req = 11; end   // CRC delimiter
           else begin m_st = 3; m_k = 1; end
        3: begin
             m_k++;
             if (m_k == 2 && smp) begin m_st = 0; mon_bad++; m_req = 11; end     // no ACK
             else if (m_k >= 3 && m_k <= 9 && !smp) begin m_st = 0; mon_bad++; m_req = 11; end   // EOF bit 7 may be dominant
             else if (m_k == 10) begin
               // decode and check the CRC
               c = 0;
               nb = m_nds - 15;
               for (int i = 0; i < nb; i++) c = crc15(c, m_ds[i]);
               ok = 1;
               for (int i = 0; i < 15; i++) if (m_ds[nb + i] !== c[14 - i]) ok = 0;
               g = 0;
               if (m_ds[13]) begin
                 for (int i = 0; i < 11; i++) g[98 - i] = m_ds[1 + i];
                 for (int i = 0; i < 18; i++) g[87 - i] = m_ds[14 + i];
                 g[69] = 1; g[68] = m_ds[32];
                 for (int i = 0; i < 4; i++) g[67 - i] = m_ds[35 + i];
               end else begin
                 for (int i = 0; i < 11; i++) g[80 - i] = m_ds[1 + i];
                 g[68] = m_ds[12];
                 for (int i = 0; i < 4; i++) g[67 - i] = m_ds[15 + i];
               end
               for (int i = 0; i < nb - (m_ds[13] ? 39 : 19); i++)
                 g[8 * (i / 8) + 7 - i % 8] = m_ds[(m_ds[13] ? 39 : 19) + i];
               m_st = 0;
               if (!ok) begin mon_bad++; m_req = 11; end
               else begin mon_f = g; mon_n++; -> mon_done; m_rec = 0; m_req = 2; end
             end
           end
        default: ;
      endcase
    end
  end
  function automatic int dlcn(input logic a, input logic b, input logic c, input logic d);
    int v;
    v = {a, b, c, d};
    return v > 8 ? 8 : v;
  endfunction

  // ---------------- delivery scoreboard ----------------
  frame_t a_rxq [$], b_rxq [$];
  int a_rxn = 0, b_rxn = 0, a_txn = 0, b_txn = 0;
  frame_t a_cur, b_cur;                 // frame in each node's transmit buffer
  frame_t a_last, b_last;               // frame of the last tx_done
  realtime a_done_t = 0, b_done_t = 0;
  always @(posedge clk_a) if (rst_a) begin
    if (a_tx_done) begin a_txn++; a_last = a_cur; a_done_t = $time; end   // before a new frame is taken
    if (a_tx_valid && a_tx_ready) a_cur = {a_tx_id, a_tx_ide, a_tx_rtr, a_tx_dlc, a_tx_data};
    if (a_rx_valid) begin a_rxq.push_back({a_rx_id, a_rx_ide, a_rx_rtr, a_rx_dlc, a_rx_data}); a_rxn++; end
  end
  always @(posedge clk_b) if (rst_b) begin
    if (b_tx_done) begin b_txn++; b_last = b_cur; b_done_t = $time; end   // before a new frame is taken
    if (b_tx_valid && b_tx_ready) b_cur = {b_tx_id, b_tx_ide, b_tx_rtr, b_tx_dlc, b_tx_data};
    if (b_rx_valid) begin b_rxq.push_back({b_rx_id, b_rx_ide, b_rx_rtr, b_rx_dlc, b_rx_data}); b_rxn++; end
  end
  // after each valid frame on the bus: who sent it, who must have received it
  bit chk_on = 1;
  initial forever begin : deliveries
    frame_t f;
    bit ta, tb, fa, fb;
    realtime t0;
    @(mon_done);
    f = mon_f;
    t0 = $realtime;
    ta = rst_a && u_a.is_tx;
    tb = rst_b && u_b.is_tx;
    fa = acc(f, a_acc_code, a_acc_mask);
    fb = acc(f, b_acc_code, b_acc_mask);
    ca(bt() / 2 + 4);
    if (chk_on) begin
      if (ta && (a_done_t < t0 - 10.0 * bt() || norm(a_last) !== f)) fail($sformatf("A sent %s, bus had %s", fs(a_last), fs(f)));
      if (tb && (b_done_t < t0 - 10.0 * bt() || norm(b_last) !== f)) fail($sformatf("B sent %s, bus had %s", fs(b_last), fs(f)));
      if (rst_a && !ta && !a_bus_off && fa) begin
        if (a_rxq.size() != 1 || a_rxq[0] !== f) fail($sformatf("A did not deliver %s", fs(f)));
      end else if (a_rxq.size() != 0) fail("A delivered a frame it should not");
      if (rst_b && !tb && !b_bus_off && fb) begin
        if (b_rxq.size() != 1 || b_rxq[0] !== f) fail($sformatf("B did not deliver %s", fs(f)));
      end else if (b_rxq.size() != 0) fail("B delivered a frame it should not");
    end
    a_rxq.delete(); b_rxq.delete();
  end

  // ---------------- host tasks ----------------
  task automatic a_send(input frame_t f);
    @(negedge clk_a);
    while (!a_tx_ready) @(negedge clk_a);
    {a_tx_id, a_tx_ide, a_tx_rtr, a_tx_dlc, a_tx_data} = f;
    a_tx_valid = 1;
    @(negedge clk_a);
    a_tx_valid = 0;
    {a_tx_id, a_tx_ide, a_tx_rtr, a_tx_dlc, a_tx_data} = {$urandom, $urandom, $urandom, $urandom};
  endtask
  task automatic b_send(input frame_t f);
    @(negedge clk_b);
    while (!b_tx_ready) @(negedge clk_b);
    {b_tx_id, b_tx_ide, b_tx_rtr, b_tx_dlc, b_tx_data} = f;
    b_tx_valid = 1;
    @(negedge clk_b);
    b_tx_valid = 0;
    {b_tx_id, b_tx_ide, b_tx_rtr, b_tx_dlc, b_tx_data} = {$urandom, $urandom, $urandom, $urandom};
  endtask
  task automatic wait_ready(input bit a, input bit b);
    int g;
    g = 0;
    while (((a && !a_tx_ready) || (b && !b_tx_ready)) && g < TIMEOUT_BITS * bt()) begin
      @(negedge clk_a); g++;
    end
    if (g >= TIMEOUT_BITS * bt()) fail("transmit never completed");
    bits(2);                                       // let the monitor finish the frame
  endtask
  task automatic a_abort;
    @(negedge clk_a); a_tx_abort = 1; @(negedge clk_a); a_tx_abort = 0;
  endtask
  task automatic b_abort;
    @(negedge clk_b); b_tx_abort = 1; @(negedge clk_b); b_tx_abort = 0;
  endtask
  task automatic reset_all;
    rst_a = 0; rst_b = 0;
    m_st = 0; m_cnt = 0; m_rec = 99; m_req = 0;          // bit time may have changed
    ca(5);
    if (a_txd !== 1 || b_txd !== 1 || a_tec !== 0 || a_rec !== 0 || !a_tx_ready) fail("reset values");
    rst_a = 1; rst_b = 1;
    idle(12);
  endtask
  task automatic exp_cnt(input int at, input int ar, input int bt_, input int br);
    if (at >= 0 && a_tec != at) fail($sformatf("A TEC %0d, expected %0d", a_tec, at));
    if (ar >= 0 && a_rec != ar) fail($sformatf("A REC %0d, expected %0d", a_rec, ar));
    if (bt_ >= 0 && b_tec != bt_) fail($sformatf("B TEC %0d, expected %0d", b_tec, bt_));
    if (br >= 0 && b_rec != br) fail($sformatf("B REC %0d, expected %0d", b_rec, br));
  endtask
  // drive one node's input dominant for n bits once the node is k bits into its own frame
  task automatic hit_a(input int k, input int n);
    while (!(u_a.is_tx && u_a.mode == 2 && u_a.pos == 1)) @(negedge clk_a);
    bits(k - 1);
    dis_a = 0; bits(n); dis_a = 1;
  endtask

  // ---------------- scenarios ----------------
  initial begin
    frame_t f, g;
    int m0;
    ca(4);
    rst_a = 1; rst_b = 1;
    idle(12);

    // 1. A -> B and B -> A: base/extended, data/remote, DLC 0..15
    $display("[%0t] section 1: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    for (int i = 0; i < 16; i++) begin
      f = rnd_frame(); f[67:64] = i; f[68] = 0; f[69] = i[0];
      a_send(f); wait_ready(1, 0); idle(3);
      g = rnd_frame(); g[67:64] = 15 - i; g[69] = ~i[0];
      b_send(g); wait_ready(0, 1); idle(3);
    end
    f = mkf(29'h1FFF_FFFF, 1, 0, 8, 64'hFFFF_FFFF_FFFF_FFFF); a_send(f); wait_ready(1, 0);
    f = mkf(29'h0, 1, 0, 8, 64'h0); b_send(f); wait_ready(0, 1);
    f = mkf(29'h7FF, 0, 1, 0, 0); a_send(f); wait_ready(1, 0);
    f = mkf(29'h0, 0, 0, 8, 64'h0); b_send(f); wait_ready(0, 1);
    for (int i = 0; i < 20; i++) begin
      if (i % 2) a_send(rnd_frame()); else b_send(rnd_frame());
      wait_ready(1, 1);
    end
    exp_cnt(0, 0, 0, 0);

    // 2. acceptance filters
    $display("[%0t] section 2: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    b_acc_mask = 29'h7FF; b_acc_code = 29'h123;
    a_send(mkf(29'h123, 0, 0, 2, 64'hBEEF)); wait_ready(1, 0);
    a_send(mkf(29'h124, 0, 0, 2, 64'hBEEF)); wait_ready(1, 0);
    a_send(mkf(29'h1FFF_F923, 1, 0, 1, 64'h5)); wait_ready(1, 0);
    b_acc_mask = 0; a_acc_mask = 29'h1FFF_FFFF; a_acc_code = 29'h0ABC_DEF1;
    b_send(mkf(29'h0ABC_DEF1, 1, 1, 3, 0)); wait_ready(0, 1);
    b_send(mkf(29'h0ABC_DEF0, 1, 1, 3, 0)); wait_ready(0, 1);
    a_acc_mask = 0;
    // with a zero mask the code does not matter
    a_acc_code = 29'h1FFF_FFFF; b_acc_code = 29'h1FFF_FFFF;
    a_send(mkf(29'h00F, 0, 0, 15, 64'h0123_4567_89AB_CDEF)); wait_ready(1, 0);
    b_send(mkf(29'h1234_5678, 1, 0, 15, 64'hFEDC_BA98_7654_3210)); wait_ready(0, 1);
    a_acc_code = 0; b_acc_code = 0;
    a_send(mkf(29'h00E, 0, 0, 1, 64'h1)); wait_ready(1, 0);

    // 3. arbitration: both queued while the bus is busy, so both start together
    $display("[%0t] section 3: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    for (int i = 0; i < 7; i++) begin
      bfm_send(rnd_frame(), 0);
      case (i)
        0: begin f = mkf(29'h100, 0, 0, 1, 64'h11); g = mkf(29'h101, 0, 0, 1, 64'h22); end
        1: begin f = mkf(29'h300, 0, 0, 1, 64'h11); g = mkf(29'h0FF, 0, 0, 1, 64'h22); end
        2: begin f = mkf(29'h155 << 18, 1, 0, 2, 64'h33); g = mkf(29'h155, 0, 0, 2, 64'h44); end
        3: begin f = mkf(29'h2AA, 0, 1, 2, 64'h0); g = mkf(29'h2AA, 0, 0, 2, 64'h55); end
        4: begin f = mkf(29'h1555_5555, 1, 0, 3, 64'h66); g = mkf(29'h1555_5554, 1, 0, 3, 64'h77); end
        5: begin f = mkf(29'h0F0F_0F0F, 1, 1, 2, 64'h0); g = mkf(29'h0F0F_0F0F, 1, 0, 2, 64'h88); end  // RTR bit
        default: begin f = mkf(29'h0AA << 18 | 29'h3, 1, 1, 0, 0); g = mkf(29'h0AA, 0, 1, 0, 0); end
      endcase
      fork
        begin while (u_a.mode == 0) @(negedge clk_a); a_send(f); end
        begin while (u_b.mode == 0) @(negedge clk_b); b_send(g); end
      join
      wait_ready(1, 1);
      idle(11);
    end
    // the BFM loses arbitration against A
    a_send(mkf(29'h010, 0, 0, 1, 64'h1));
    @(negedge bus);
    bfm_sync = 1;
    bfm_send(mkf(29'h011, 0, 0, 1, 64'h2), 0);
    if (!bfm_lost) fail("BFM should have lost arbitration");
    wait_ready(1, 0);
    idle(11);
    // A's frame is pending at the end of a BFM frame; the BFM's next SOF comes
    // at the 3rd intermission bit, A joins with its first ID bit and loses
    fork
      bfm_send(mkf(29'h020, 0, 0, 1, 64'h5), 0);
      begin bits(10); a_send(mkf(29'h030, 0, 0, 1, 64'h6)); end
    join
    ca(2 * bt());
    bfm_sync = 1;
    bfm_send(mkf(29'h021, 0, 0, 1, 64'h7), 0);
    if (bfm_lost || bfm_err || !bfm_ack) fail("BFM frame at the 3rd intermission bit");
    wait_ready(1, 0);
    idle(11);

    // 4. BFM frames with jitter (resynchronisation), then received by both
    $display("[%0t] section 4: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    // edges displaced by up to +-1 tq: phase errors up to 2 tq, within SJW = 2,
    // then beyond SJW = 1 (still inside the sample-point margin)
    bfm_jitter = 1;
    for (int i = 0; i < 40; i++) begin
      if (i == 20) begin cfg_sjw = 0; reset_all(); end
      bfm_send(rnd_frame(), 0);
      if (!bfm_ack) fail("BFM frame not acknowledged");
      idle(3);
    end
    bfm_jitter = 0;
    cfg_sjw = 1; reset_all();
    hb = 4.985;                                          // B now faster than A
    for (int i = 0; i < 10; i++) begin
      if (i % 2) a_send(rnd_frame()); else b_send(rnd_frame());
      wait_ready(1, 1);
    end

    // 5. receive errors from the BFM: each one +1 REC at A and B
    $display("[%0t] section 5: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    exp_cnt(0, 0, 0, 0);
    bfm_flip = 20;           bfm_send(mkf(29'h3C3, 0, 0, 4, 64'h1234_5678), 0); idle(11);  // stuff/CRC/form
    bfm_send(mkf(29'h0F0, 0, 0, 1, 64'h5A), 1); idle(11);                                  // CRC error
    build(mkf(29'h000, 0, 0, 0, 0), 0);
    bfm_skip_stuff = 5;      bfm_send(mkf(29'h000, 0, 0, 0, 0), 0); idle(11);              // stuff error
    bfm_tail_dom = 0;        bfm_send(mkf(29'h0F1, 0, 0, 0, 0), 0); idle(11);              // CRC delimiter
    bfm_tail_dom = 2;        bfm_send(mkf(29'h0F2, 0, 0, 0, 0), 0); idle(11);              // ACK delimiter
    bfm_tail_dom = 5;        bfm_send(mkf(29'h0F3, 0, 0, 0, 0), 0); idle(11);              // EOF
    exp_cnt(0, 6, 0, 6);
    bfm_tail_dom = 9;        bfm_send(mkf(29'h0F4, 0, 0, 0, 0), 0); idle(11);              // EOF bit 7: ignored
    exp_cnt(0, 5, 0, 5);

    // 6. transmit errors: bit error seen only by A, then A's error flag at B
    $display("[%0t] section 6: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    a_send(mkf(29'h555, 0, 0, 8, 64'hFFFF_FFFF_FFFF_FFFF));
    hit_a(22, 7);
    wait_ready(1, 0);
    exp_cnt(7, -1, 0, -1);
    // a local bit error in the arbitration field reads as lost arbitration
    // (nobody else transmits: the frame is aborted by stuff errors)
    a_send(mkf(29'h7FF, 0, 0, 0, 0));
    hit_a(2, 1);
    wait_ready(1, 0);
    idle(11);
    // a dominant recessive stuff bit in arbitration: stuff error, TEC unchanged
    a_send(mkf(29'h000, 0, 0, 0, 0));
    hit_a(5, 1);
    wait_ready(1, 0);
    idle(11);
    // form error at the transmitter: dominant CRC delimiter at A only
    a_send(mkf(29'h3A5, 0, 0, 1, 64'h9));
    while (!(u_a.is_tx && u_a.mode == 2 && u_a.known && 8'(u_a.pos - u_a.crc_ls) == 8'd1)) @(negedge clk_a);
    dis_a = 0; bits(1); dis_a = 1;
    wait_ready(1, 0);
    idle(11);

    // 7. error passive: B offline, A gets no ACK; TEC stops at 128
    $display("[%0t] section 7: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    rst_b = 0;
    a_send(mkf(29'h321, 0, 0, 2, 64'hABCD));
    begin : wait_flag
      int g2;
      g2 = 0;
      while (!a_err_passive && g2 < 200000) begin @(negedge clk_a); g2++; end
      if (!a_err_passive) fail("A never became error passive");
    end
    bits(200);                                           // passive ACK errors: no change
    if (a_tec < 128 || a_tec > 135) fail($sformatf("passive TEC %0d", a_tec));
    m0 = a_tec;
    bits(200);
    if (a_tec != m0) fail("TEC moved on passive ACK errors");
    a_abort();
    wait_ready(1, 0);
    rst_b = 1;
    idle(11);
    // passive transmitter succeeds (suspend after it), then counts down
    for (int i = 0; i < 4; i++) begin a_send(rnd_frame()); b_send(rnd_frame()); wait_ready(1, 1); end
    // passive error flag at A while B transmits: local disturbance at A
    b_send(mkf(29'h0F, 0, 0, 8, 64'h0));
    @(negedge b_txd); bits(25); dis_a = 0; bits(1); dis_a = 1;
    wait_ready(0, 1);
    idle(11);

    // 8. bus-off: repeated bit errors at A, then recovery after 128 x 11 bits
    $display("[%0t] section 8: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    a_send(mkf(29'h2F0, 0, 0, 8, 64'h0F0F_0F0F_0F0F_0F0F));
    for (int i = 0; i < 40 && !a_bus_off; i++) hit_a(20, 7);
    if (!a_bus_off) fail("A never went bus-off");
    if (a_tec < 256) fail("bus-off with TEC below 256");
    // B's frame gets no ACK while A is bus-off; B's passive retries leave
    // enough 11-bit recessive runs for A to recover
    b_send(mkf(29'h77, 0, 0, 1, 64'h7));
    begin : wait_recovery
      int g2;
      g2 = 0;
      while (a_bus_off && g2 < 12000 * bt()) begin @(negedge clk_a); g2++; end
      if (a_bus_off) fail("no bus-off recovery");
    end
    exp_cnt(0, 0, -1, -1);
    wait_ready(1, 1);                                    // both pending frames go out
    idle(11);

    // 9. REC above 127 (error passive receiver), then 120 after a good frame
    $display("[%0t] section 9: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    for (int i = 0; i < 128; i++) begin bfm_send(mkf(i, 0, 0, 0, 0), 1); idle(11); end
    exp_cnt(-1, 128, -1, -1);                            // just above 127
    if (!a_err_passive || !b_err_passive) fail("receivers not error passive");
    bfm_send(mkf(29'h44, 0, 0, 1, 64'h4), 0); idle(11);
    exp_cnt(-1, 120, -1, 120);
    // REC saturates at 255
    for (int i = 0; i < 140; i++) begin bfm_send(mkf(i, 0, 1, 0, 0), 1); idle(11); end
    exp_cnt(-1, 255, -1, 255);
    reset_all();

    // 10. abort: buffered while the bus is busy, and abort during own frame
    $display("[%0t] section 10: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    // tx_valid held while a frame is pending: taken only after tx_done
    a_send(mkf(29'h4, 0, 0, 8, 64'h0404_0404_0404_0404));
    @(negedge clk_a);
    {a_tx_id, a_tx_ide, a_tx_rtr, a_tx_dlc, a_tx_data} = mkf(29'h5, 0, 0, 2, 64'h0505);
    a_tx_valid = 1;
    @(posedge clk_a);
    while (!a_tx_ready) @(posedge clk_a);
    @(negedge clk_a) a_tx_valid = 0;
    wait_ready(1, 0);
    idle(11);
    fork
      bfm_send(mkf(29'h1, 0, 0, 8, 64'h0), 0);
      begin bits(10); a_send(mkf(29'h2, 0, 0, 1, 64'h1)); a_abort(); end
    join
    wait_ready(1, 0);
    idle(11);
    a_send(mkf(29'h3, 0, 0, 8, 64'h1));
    @(negedge a_txd); bits(5);
    a_abort();                                           // too late: frame completes
    wait_ready(1, 0);
    rst_b = 0;                                           // retrying frame aborted between attempts
    a_send(mkf(29'h4, 0, 0, 0, 0));
    bits(30);
    a_abort();
    wait_ready(1, 0);
    rst_b = 1;
    idle(11);
    // abort while queued behind an arbitration loss
    bfm_send(mkf(29'h1, 0, 0, 1, 64'h0), 0);
    fork
      begin while (u_a.mode == 0) @(negedge clk_a); a_send(mkf(29'h600, 0, 0, 1, 64'h1)); end
      begin while (u_b.mode == 0) @(negedge clk_b); b_send(mkf(29'h080, 0, 0, 8, 64'h2)); end
    join
    while (!a_arb_lost) @(negedge clk_a);
    a_abort();
    wait_ready(1, 1);
    idle(11);

    // 11. bit timing extremes (with jitter at the widest SJW)
    $display("[%0t] section 11: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    reset_all();
    cfg_brp = 63; cfg_tseg1 = 15; cfg_tseg2 = 7; cfg_sjw = 3;
    reset_all();
    a_send(mkf(29'h5A5, 0, 0, 1, 64'hA5)); wait_ready(1, 0);
    cfg_brp = 2; cfg_tseg1 = 9; cfg_tseg2 = 7; cfg_sjw = 3;
    reset_all();
    bfm_jitter = 1;                                      // phase errors up to 2 tq (SJW = 4)
    for (int i = 0; i < 20; i++) begin
      bfm_send(rnd_frame(), 0);
      if (!bfm_ack) fail("BFM frame not acknowledged");
      idle(3);
    end
    bfm_jitter = 0;
    b_send(rnd_frame()); wait_ready(0, 1);
    // 1-clock tq: the 2-clock input synchroniser eats into TSEG1, keep the
    // sample point near the middle
    cfg_brp = 0; cfg_tseg1 = 4; cfg_tseg2 = 4; cfg_sjw = 0;
    reset_all();
    a_send(rnd_frame()); b_send(rnd_frame()); wait_ready(1, 1);
    cfg_brp = 1; cfg_tseg1 = 7; cfg_tseg2 = 2; cfg_sjw = 1;  // 12 tq
    reset_all();
    a_send(rnd_frame()); b_send(rnd_frame()); wait_ready(1, 1);
    cfg_brp = 1; cfg_tseg1 = 5; cfg_tseg2 = 2; cfg_sjw = 1;
    reset_all();
    // dominant EOF bit 7 at the transmitter only: form error, the frame is
    // sent again (receivers took it at EOF bit 6 already: delivered twice)
    chk_on = 0;
    a_send(mkf(29'h0E7, 0, 0, 1, 64'hE7));
    while (!(u_a.is_tx && u_a.mode == 2 && u_a.known && 8'(u_a.pos - u_a.crc_ls) == 8'd10)) @(negedge clk_a);
    dis_a = 0; bits(1); dis_a = 1;
    wait_ready(1, 0);
    idle(11);
    chk_on = 1;

    // 12. reset in the middle of frames
    $display("[%0t] section 12: A tec %0d rec %0d, B tec %0d rec %0d", $time, a_tec, a_rec, b_tec, b_rec);
    chk_on = 0;
    a_send(mkf(29'h6, 0, 0, 8, 64'h1));
    @(negedge a_txd); bits(30);
    rst_b = 0; bits(2); rst_b = 1;
    wait_ready(1, 0);
    b_send(mkf(29'h7, 0, 0, 8, 64'h1));
    @(negedge b_txd); bits(40);
    rst_a = 0; rst_b = 0; ca(3);
    rst_a = 1; rst_b = 1;
    idle(12);
    chk_on = 1;
    a_send(rnd_frame()); wait_ready(1, 0);
    // identifier corners per format, payload patterns both ways, an
    // extended remote frame with no data
    a_send(mkf(29'h123, 0, 0, 8, 64'h0)); wait_ready(1, 0);
    a_send(mkf(29'h124, 0, 0, 8, {16{4'hA}})); wait_ready(1, 0);
    b_send(mkf(29'h7FF, 0, 0, 8, {64{1'b1}})); wait_ready(0, 1);
    b_send(mkf(29'h1FFF_FFFF, 1, 0, 8, {16{4'h5}})); wait_ready(0, 1);
    b_send(mkf(29'h0123_4567, 1, 1, 0, 64'h0)); wait_ready(0, 1);

    idle(3);
    $display("monitor: %0d valid frames, %0d broken; A tx %0d rx %0d, B tx %0d rx %0d",
             mon_n, mon_bad, a_txn, a_rxn, b_txn, b_rxn);
    if (errors == 0) $display("TEST PASSED: CAN");
    else $display("TEST FAILED: CAN (%0d errors)", errors);
    $finish;
  end

`ifdef CAN_DBG
  always @(posedge clk_a) if ($time > 64'd9_800_000) begin
    if (u_a.tx_valid && u_a.tx_ready) $display("%0t A accept %h", $time, u_a.tx_id);
    if (u_b.tx_valid && u_b.tx_ready) $display("%0t B accept %h", $time, u_b.tx_id);
    if (u_a.arb_lost) $display("%0t A arb_lost", $time);
    if (u_b.arb_lost) $display("%0t B arb_lost", $time);
    if (u_a.tx_done) $display("%0t A tx_done", $time);
    if (u_b.tx_done) $display("%0t B tx_done", $time);
    if (u_a.mode == 2 && u_a.pos == 1 && u_a.sample) $display("%0t A frame is_tx %b", $time, u_a.is_tx);
    if (u_b.mode == 2 && u_b.pos == 1 && u_b.sample) $display("%0t B frame is_tx %b", $time, u_b.is_tx);
    if (u_a.err_bit|u_a.err_stuff|u_a.err_crc|u_a.err_form|u_a.err_ack) $display("%0t A err %b%b%b%b%b pos %0d crc_ls %0d tx %b", $time, u_a.err_bit,u_a.err_stuff,u_a.err_crc,u_a.err_form,u_a.err_ack, u_a.pos, u_a.crc_ls, u_a.is_tx);
    if (u_b.err_bit|u_b.err_stuff|u_b.err_crc|u_b.err_form|u_b.err_ack) $display("%0t B err %b%b%b%b%b pos %0d crc_ls %0d tx %b", $time, u_b.err_bit,u_b.err_stuff,u_b.err_crc,u_b.err_form,u_b.err_ack, u_b.pos, u_b.crc_ls, u_b.is_tx);
    if (u_a.crc_err && !$past(u_a.crc_err)) $display("%0t A crc_err pos %0d crc_st %0d", $time, u_a.pos, u_a.crc_st);
    if ($time > 64'd9_893_600 && $time < 64'd9_907_200 && (u_a.fall || u_a.rs_ok))
      $display("%0t A fall %b rs_ok %b late %b end %b skip %b tq %0d resynced %b last_smp %b drv %b | B tq %0d pos %0d", $time,
        u_a.fall, u_a.rs_ok, u_a.rs_late, u_a.rs_end, u_a.rs_skip, u_a.tq_cnt, u_a.resynced, u_a.last_smp, u_a.drv, u_b.tq_cnt, u_b.pos);
    if (0)
      $display("%0t bus %b | A drv %b rx %b tq %0d pos %0d crcerr %b bs %b sm %b | B drv %b rx %b tq %0d pos %0d sm %b", $time, bus,
        u_a.drv, u_a.rx_s, u_a.tq_cnt, u_a.pos, u_a.crc_err, u_a.bit_start, u_a.sample, u_b.drv, u_b.rx_s, u_b.tq_cnt, u_b.pos, u_b.sample);
    if (0)
      $display("%0t A smp b=%b pos %0d tq_at_edge? B pos %0d B drv %b B tq %0d", $time, u_a.rx_s, u_a.pos, u_b.pos, u_b.drv, u_b.tq_cnt);
    if (0)
      $display("%0t bus %b | A drv %b rx %b tq %0d brp %0d pos %0d tx %b m %0d sm %b | B drv %b rx %b tq %0d brp %0d pos %0d tx %b m %0d sm %b", $time, bus,
        u_a.drv, u_a.rx_s, u_a.tq_cnt, u_a.brp_cnt, u_a.pos, u_a.is_tx, u_a.mode, u_a.sample,
        u_b.drv, u_b.rx_s, u_b.tq_cnt, u_b.brp_cnt, u_b.pos, u_b.is_tx, u_b.mode, u_b.sample);
  end
`endif
  initial begin
    #20ms;
    $display("TEST FAILED: CAN (timeout)");
    $finish;
  end
endmodule
