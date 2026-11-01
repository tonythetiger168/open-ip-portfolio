// SPDX-License-Identifier: Apache-2.0
// PCIe_CXL_IDE_tb: self-checking testbench. The core runs with NS = 2
// streams, CTR_W = 4 (counters exhaust after 14 messages) and LEN_W = 9 (the
// GCM length limits are reachable).
//  - Known answers: every case of tb/PCIe_CXL_IDE_vec.svh (TLPs with header
//    and payload length sweeps, key refreshes, cachemem epochs; from
//    scripts/ide/gen_vec.py) is sent through the transmit side and its output
//    (prefix, header, ciphertext, MAC) compared; the output is then fed to the
//    receive side, which must return the header and payload with a good MAC.
//  - Loopback: seeded random TLPs, bypass TLPs and cachemem flits on both
//    streams and every sub-stream, epochs truncated by TLPs, random gaps and
//    back-pressure; every message must come back unchanged.
//  - Directed: key management rules and errors, every slot's key and counter
//    (to exhaustion), tampered messages (MAC mismatch), every format and
//    state error in both directions, epoch aborts, length limits, clr in
//    every state and reset in a message.
`timescale 1ns/1ps
module PCIe_CXL_IDE_tb;
  localparam int NS = 2, CW = 4, LW = 9;
  logic         clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  logic [NS-1:0]    s_en, s_cm;
  logic [NS*8-1:0]  s_id;
  logic [NS*32-1:0] s_ivfix;
  logic [6:0]       cm_agg;
  logic             km_dir, km_ks, km_sel, sl_valid, km_prog, km_go, km_stop, clr;
  logic [1:0]       km_sid, km_sub;
  logic [255:0]     km_key, sl_key;
  logic [NS-1:0]    sec_tx, sec_rx, ks_tx, ks_rx;
  logic [NS*6-1:0]  kv_tx, kv_rx;
  logic             tx_busy, rx_busy, km_err, tx_done, tx_err, rx_done, rx_err;
  logic [2:0]       km_code, tx_code, rx_code;
  logic [1:0]       tx_esid;
  logic [7:0]       rx_eid;
  logic             tx_valid, tx_ready, tx_hdr, tx_last, tx_ide;
  logic [127:0]     tx_data, txo_data, rx_data, rxo_data;
  logic [4:0]       tx_bytes, txo_bytes, rx_bytes, rxo_bytes;
  logic [1:0]       tx_sid, tx_sub, txo_kind, rx_kind, rx_sid, rxo_kind;
  logic             txo_valid, txo_ready, txo_last, txo_bad, txo_cm;
  logic             rx_valid, rx_ready, rx_last, rx_cm;
  logic             rxo_valid, rxo_ready, rxo_last, rxo_bad, rxo_cm;

  PCIe_CXL_IDE_top #(.NS(NS), .CTR_W(CW), .LEN_W(LW)) u_dut (.*);

  `include "PCIe_CXL_IDE_vec.svh"

  localparam logic [1:0] K_HDR = 2'd0, K_DATA = 2'd1, K_MAC = 2'd2, K_PFX = 2'd3, K_END = 2'd2;
  int errors = 0;
  task automatic fail(input string m);
    $display("FAIL @%0t: %s", $time, m); errors++;
  endtask
  function automatic logic [127:0] r128();
    r128 = {$urandom, $urandom, $urandom, $urandom};
  endfunction
  function automatic logic [127:0] mask(input int n);
    for (int i = 0; i < 16; i++) mask[127 - 8 * i -: 8] = i < n ? 8'hff : 8'h00;
  endfunction

  // ---------------- event counters ----------------
  int n_txd = 0, n_txe = 0, n_rxd = 0, n_rxe = 0, n_kme = 0;
  always @(posedge clk) begin
    if (tx_done) n_txd++;
    if (tx_err) n_txe++;
    if (rx_done) n_rxd++;
    if (rx_err) n_rxe++;
    if (km_err) n_kme++;
  end

  // ---------------- transmit output: captured into tq ----------------
  int           rdy_t = 100, rdy_r = 100;   // output ready probability (percent)
  int           tqn = 0, ron = 0;
  logic [127:0] tq_d [0:1023];
  logic [4:0]   tq_n [0:1023];
  logic [1:0]   tq_k [0:1023];
  logic         tq_l [0:1023], tq_b [0:1023], tq_c [0:1023];
  logic [127:0] ro_d [0:1023];
  logic [4:0]   ro_n [0:1023];
  logic [1:0]   ro_k [0:1023];
  logic         ro_l [0:1023], ro_b [0:1023], ro_c [0:1023];
  always @(posedge clk) begin
    if (rst_n && txo_valid && txo_ready) begin
      tq_d[tqn % 1024] <= txo_data; tq_n[tqn % 1024] <= txo_bytes; tq_k[tqn % 1024] <= txo_kind;
      tq_l[tqn % 1024] <= txo_last; tq_b[tqn % 1024] <= txo_bad; tq_c[tqn % 1024] <= txo_cm;
      tqn <= tqn + 1;
    end
    if (rst_n && rxo_valid && rxo_ready) begin
      ro_d[ron % 1024] <= rxo_data; ro_n[ron % 1024] <= rxo_bytes; ro_k[ron % 1024] <= rxo_kind;
      ro_l[ron % 1024] <= rxo_last; ro_b[ron % 1024] <= rxo_bad; ro_c[ron % 1024] <= rxo_cm;
      ron <= ron + 1;
    end
  end
  always @(negedge clk) begin
    txo_ready = $urandom_range(0, 99) < rdy_t;
    rxo_ready = $urandom_range(0, 99) < rdy_r;
  end

  // ---------------- input drivers ----------------
  int gap = 0;                          // up to this many idle clocks before a block
  int tx_tk = 0, rx_tk = 0;             // blocks taken
  always @(posedge clk) begin
    if (tx_valid && tx_ready) tx_tk <= tx_tk + 1;
    if (rx_valid && rx_ready) rx_tk <= rx_tk + 1;
  end
  // transmit packet buffer
  int           tpn;
  logic [127:0] tp_d [0:255];
  logic [4:0]   tp_n [0:255];
  logic         tp_h [0:255], tp_l [0:255];
  task automatic tp_add(input logic [127:0] d, input int n, input logic h, input logic l);
    tp_d[tpn] = d; tp_n[tpn] = 5'(n); tp_h[tpn] = h; tp_l[tpn] = l; tpn++;
  endtask
  // header of hl bytes and payload of pl bytes from vb (or random data)
  task automatic tp_tlp(input int hl, input int pl, input int hb0, input int pb0, input logic rnd);
    int nh, np;
    nh = (hl + 15) / 16; np = (pl + 15) / 16;
    tpn = 0;
    for (int j = 0; j < nh; j++)
      tp_add(rnd ? r128() : vb[hb0 + j] | (r128() & ~mask(hl - 16 * j)), j == nh - 1 ? hl - 16 * j : 16, 1'b1,
             j == nh - 1 && np == 0);
    for (int j = 0; j < np; j++)
      tp_add(rnd ? r128() : vb[pb0 + j] | (r128() & ~mask(pl - 16 * j)), j == np - 1 ? pl - 16 * j : 16, 1'b0,
             j == np - 1);
  endtask
  task automatic idle_tx();
    tx_valid = 1'b0; tx_data = r128(); tx_bytes = 5'($urandom); tx_hdr = $urandom; tx_last = $urandom;
    tx_ide = $urandom; tx_sid = 2'($urandom); tx_sub = 2'($urandom);
  endtask
  task automatic tx_block(input int j, input logic ide, input logic [1:0] sid, input logic [1:0] sub);
    int n0;
    @(negedge clk);
    for (int g = $urandom_range(0, gap); g > 0; g--) begin idle_tx(); @(negedge clk); end
    tx_valid = 1'b1; tx_data = tp_d[j]; tx_bytes = tp_n[j]; tx_hdr = tp_h[j]; tx_last = tp_l[j];
    tx_ide = ide; tx_sid = sid; tx_sub = sub;
    if (j != 0) begin tx_ide = $urandom; tx_sid = 2'($urandom); tx_sub = 2'($urandom); end
    n0 = tx_tk;
    while (tx_tk == n0) @(negedge clk);
    idle_tx();
  endtask
  task automatic tx_send(input logic ide, input logic [1:0] sid, input logic [1:0] sub);
    for (int j = 0; j < tpn; j++) tx_block(j, ide, sid, sub);
  endtask
  // receive input buffer
  int           rin;
  logic [127:0] ri_d [0:1023];
  logic [4:0]   ri_n [0:1023];
  logic [1:0]   ri_k [0:1023];
  logic         ri_l [0:1023], ri_c [0:1023];
  task automatic idle_rx();
    rx_valid = 1'b0; rx_data = r128(); rx_bytes = 5'($urandom); rx_kind = 2'($urandom); rx_last = $urandom;
    rx_cm = $urandom; rx_sid = 2'($urandom);
  endtask
  task automatic rx_block(input int j, input logic [1:0] sid, input int tmo);
    int n0, t;
    @(negedge clk);
    for (int g = $urandom_range(0, gap); g > 0; g--) begin idle_rx(); @(negedge clk); end
    rx_valid = 1'b1; rx_data = ri_d[j]; rx_bytes = ri_n[j]; rx_kind = ri_k[j]; rx_last = ri_l[j];
    rx_cm = ri_c[j]; rx_sid = sid;
    n0 = rx_tk; t = 0;
    while (rx_tk == n0 && t < tmo) begin @(negedge clk); t++; end
    if (rx_tk == n0) fail($sformatf("receive block %0d not taken", j));
    idle_rx();
  endtask
  // the transmit output blocks tq[a .. a + n - 1] as receive input
  task automatic ri_from_tq(input int a, input int n);
    rin = n;
    for (int j = 0; j < n; j++) begin
      ri_d[j] = tq_d[(a + j) % 1024] | (r128() & ~mask(tq_n[(a + j) % 1024]));
      ri_n[j] = tq_n[(a + j) % 1024]; ri_k[j] = tq_k[(a + j) % 1024];
      ri_l[j] = tq_l[(a + j) % 1024]; ri_c[j] = tq_c[(a + j) % 1024];
    end
  endtask
  task automatic rx_send(input logic [1:0] sid);
    for (int j = 0; j < rin; j++) rx_block(j, sid, 4000);
  endtask
  task automatic wait_q(input int tn, input int rn, input string what);
    int t;
    t = 0;
    while ((tqn < tn || ron < rn) && t < 20000) begin @(negedge clk); t++; end
    if (tqn < tn) fail($sformatf("%s: %0d transmit blocks, expected %0d", what, tqn, tn));
    if (ron < rn) fail($sformatf("%s: %0d receive blocks, expected %0d", what, ron, rn));
  endtask
  task automatic chk_tq(input int i, input logic [127:0] d, input int n, input logic [1:0] k, input logic l,
                        input logic b, input logic c, input string what);
    if (tq_d[i % 1024] !== d || tq_n[i % 1024] !== 5'(n) || tq_k[i % 1024] !== k || tq_l[i % 1024] !== l ||
        tq_b[i % 1024] !== b || tq_c[i % 1024] !== c)
      fail($sformatf("%s: transmit block %0d %h/%0d k%0d l%0d b%0d c%0d, expected %h/%0d k%0d l%0d b%0d c%0d", what,
                     i, tq_d[i % 1024], tq_n[i % 1024], tq_k[i % 1024], tq_l[i % 1024], tq_b[i % 1024],
                     tq_c[i % 1024], d, n, k, l, b, c));
  endtask
  task automatic chk_ro(input int i, input logic [127:0] d, input int n, input logic [1:0] k, input logic l,
                        input logic b, input logic c, input string what);
    if (ro_d[i % 1024] !== d || ro_n[i % 1024] !== 5'(n) || ro_k[i % 1024] !== k || ro_l[i % 1024] !== l ||
        ro_b[i % 1024] !== b || ro_c[i % 1024] !== c)
      fail($sformatf("%s: receive block %0d %h/%0d k%0d l%0d b%0d c%0d, expected %h/%0d k%0d l%0d b%0d c%0d", what,
                     i, ro_d[i % 1024], ro_n[i % 1024], ro_k[i % 1024], ro_l[i % 1024], ro_b[i % 1024],
                     ro_c[i % 1024], d, n, k, l, b, c));
  endtask

  // ---------------- configuration and key management ----------------
  task automatic cfg(input int s, input logic en, input logic cm, input logic [7:0] id, input logic [31:0] fix);
    @(negedge clk);
    s_en[s] = en; s_cm[s] = cm; s_id[8 * s +: 8] = id; s_ivfix[32 * s +: 32] = fix;
  endtask
  // op: 0 prog, 1 go, 2 stop; ec: the km_code expected (0 none)
  task automatic km(input int op, input logic dir, input logic [1:0] sid, input logic ks, input logic [1:0] sub,
                    input logic [255:0] key, input logic sel, input logic [2:0] ec);
    int e0;
    @(negedge clk);
    km_dir = dir; km_sid = sid; km_ks = ks; km_sub = sub; km_sel = sel;
    km_key = sel ? {r128(), r128()} : key;
    sl_key = sel ? key : {r128(), r128()};
    if (sel) sl_valid = ec != 3'd3;
    km_prog = op == 0; km_go = op == 1; km_stop = op == 2;
    e0 = n_kme;
    @(negedge clk);
    km_prog = 1'b0; km_go = 1'b0; km_stop = 1'b0;
    km_key = r128(); sl_key = r128(); sl_valid = $urandom; km_sel = $urandom;
    km_dir = $urandom; km_sid = 2'($urandom); km_ks = $urandom; km_sub = 2'($urandom);
    @(negedge clk);
    if (ec == 3'd0 && n_kme != e0) fail($sformatf("km op %0d: unexpected error %0d", op, km_code));
    if (ec != 3'd0 && (n_kme != e0 + 1 || km_code !== ec))
      fail($sformatf("km op %0d: error %0d code %0d, expected code %0d", op, n_kme - e0, km_code, ec));
  endtask
  // load key set ks of stream s in both directions and make it active
  task automatic load_set(input int s, input logic ks, input logic [255:0] key);
    for (int d = 0; d < 2; d++) begin
      for (int sub = 0; sub < 3; sub++) km(0, d, 2'(s), ks, 2'(sub), key, $urandom_range(0, 3) == 0, 3'd0);
      km(1, d, 2'(s), ks, 2'd0, '0, 1'b0, 3'd0);
    end
  endtask

  // both directions back to counter 1 on a fresh key (after transmit-only errors)
  task automatic resync_ks(input int s, input logic ks);
    for (int d = 0; d < 2; d++) begin km(2, d, 2'(s), 0, 2'd0, '0, 0, 3'd0); km(2, d, 2'(s), 1, 2'd0, '0, 0, 3'd0); end
    load_set(s, ks, {r128(), r128()});
  endtask
  task automatic resync(input int s);
    resync_ks(s, $urandom);
  endtask

  // ---------------- known-answer cases ----------------
  task automatic run_case(input int i);
    int s, t0, r0, nb, np, nh, plen, hlen;
    s = c_s[i];
    if (c_prog[i] != 0) begin
      cfg(s, 1'b1, c_cm[i] != 0, c_id[i], c_fix[i]);
      cm_agg = 7'(c_agg[i]);
      load_set(s, c_ks[i] != 0, c_key[i]);
    end
    t0 = tqn; r0 = ron;
    nh = c_nh[i]; np = c_np[i];
    hlen = nh == 0 ? 0 : 16 * (nh - 1) + c_hb[i];
    plen = np == 0 ? 0 : 16 * (np - 1) + c_pb[i];
    if (c_cm[i] != 0) begin
      for (int f = 0; f <= c_agg[i]; f++) begin
        tpn = 0;
        for (int j = 0; j < 4; j++) tp_add(vb[c_ib[i] + 4 * f + j], 16, 1'b0, j == 3);
        tx_send(1'b1, 2'(s), 2'($urandom));
      end
      nb = np + 1;
    end else begin
      tp_tlp(hlen, plen, c_ib[i], c_ib[i] + nh, 1'b0);
      tx_send(1'b1, 2'(s), 2'(c_sub[i]));
      nb = 1 + nh + np + 1;
    end
    wait_q(t0 + nb, r0, $sformatf("case %0d", i));
    // transmit output
    if (c_cm[i] == 0) begin
      chk_tq(t0, {c_pfx[i], 96'h0}, 4, K_PFX, 0, 0, 0, $sformatf("case %0d prefix", i));
      for (int j = 0; j < nh; j++)
        chk_tq(t0 + 1 + j, vb[c_ib[i] + j], j == nh - 1 ? c_hb[i] : 16, K_HDR, 0, 0, 0, $sformatf("case %0d header", i));
      for (int j = 0; j < np; j++)
        chk_tq(t0 + 1 + nh + j, vb[c_ob[i] + j], j == np - 1 ? c_pb[i] : 16, K_DATA, 0, 0, 0,
               $sformatf("case %0d payload", i));
    end else
      for (int j = 0; j < np; j++)
        chk_tq(t0 + j, vb[c_ob[i] + j], 16, K_DATA, j % 4 == 3, 0, 1, $sformatf("case %0d flit", i));
    chk_tq(t0 + nb - 1, {c_mac[i], 32'h0}, 12, K_MAC, 1, 0, c_cm[i] != 0, $sformatf("case %0d MAC", i));
    // back through the receive side
    ri_from_tq(t0, nb);
    rx_send(2'(s));
    wait_q(0, r0 + nb - (c_cm[i] != 0 ? 0 : 1), $sformatf("case %0d receive", i));
    for (int j = 0; j < nh; j++)
      chk_ro(r0 + j, vb[c_ib[i] + j], j == nh - 1 ? c_hb[i] : 16, K_HDR, 0, 0, 0, $sformatf("case %0d rx header", i));
    for (int j = 0; j < np; j++)
      chk_ro(r0 + nh + j, vb[c_ib[i] + nh + j], j == np - 1 ? c_pb[i] : 16, K_DATA, c_cm[i] != 0 && j % 4 == 3, 0,
             c_cm[i] != 0, $sformatf("case %0d rx data", i));
    chk_ro(r0 + nh + np, 128'h0, 0, K_END, 1, 0, c_cm[i] != 0, $sformatf("case %0d rx end", i));
  endtask

  // ---------------- loopback of random traffic ----------------
  // a random TLP (or bypass TLP) on stream s through both sides
  logic [127:0] lb_d [0:255];           // the original blocks
  task automatic loop_tlp(input int s, input logic [1:0] sub, input int hl, input int pl, input logic ide,
                          input logic expect_ok);
    int t0, r0, nb, nh, np;
    nh = (hl + 15) / 16; np = (pl + 15) / 16;
    tp_tlp(hl, pl, 0, 0, 1'b1);
    for (int j = 0; j < tpn; j++) lb_d[j] = tp_d[j] & mask(tp_n[j]);
    t0 = tqn; r0 = ron;
    tx_send(ide, 2'(s), sub);
    nb = ide ? nh + np + 2 : nh + np;
    wait_q(t0 + nb, r0, "loopback transmit");
    ri_from_tq(t0, nb);
    rx_send(2'(s));
    wait_q(0, r0 + nb - (ide ? 1 : 0), "loopback receive");
    for (int j = 0; j < nh + np; j++)
      if ((ro_d[(r0 + j) % 1024] & mask(ro_n[(r0 + j) % 1024])) !== lb_d[j] || ro_n[(r0 + j) % 1024] !== tp_n[j] ||
          ro_k[(r0 + j) % 1024] !== (tp_h[j] ? K_HDR : K_DATA))
        fail($sformatf("loopback block %0d differs", j));
    if (ide) chk_ro(r0 + nh + np, 128'h0, 0, K_END, 1, !expect_ok, 0, "loopback end");
    else if (!ro_l[(r0 + nb - 1) % 1024]) fail("bypass: last not passed");
  endtask


  // ---------------- directed tests ----------------
  task automatic drain(input int tmo);
    int q, t;
    q = 0; t = 0;
    while (q < 3 && t < tmo) begin
      @(negedge clk); t++;
      if (!tx_busy && !rx_busy && !txo_valid && !rxo_valid) q++; else q = 0;
    end
  endtask
  task automatic exp_err(input logic dir, input int e0, input logic [2:0] c, input string what);
    drain(3000);
    if (dir == 0 && (n_txe != e0 + 1 || tx_code !== c))
      fail($sformatf("%s: %0d transmit errors, code %0d, expected 1 with code %0d", what, n_txe - e0, tx_code, c));
    if (dir == 1 && (n_rxe != e0 + 1 || rx_code !== c))
      fail($sformatf("%s: %0d receive errors, code %0d, expected 1 with code %0d", what, n_rxe - e0, rx_code, c));
  endtask
  // the last output block is a nullified MAC / bad END
  task automatic exp_term(input logic dir, input string what);
    if (dir == 0 && (tq_k[(tqn - 1) % 1024] !== K_MAC || !tq_b[(tqn - 1) % 1024] || !tq_l[(tqn - 1) % 1024]))
      fail($sformatf("%s: no nullified MAC block", what));
    if (dir == 1 && (ro_k[(ron - 1) % 1024] !== K_END || !ro_b[(ron - 1) % 1024] || !ro_l[(ron - 1) % 1024]))
      fail($sformatf("%s: no bad END block", what));
  endtask
  // send tp as a TLP and expect a transmit error (term: a nullified MAC follows)
  task automatic tx_bad(input logic [1:0] sid, input logic [1:0] sub, input logic [2:0] c, input logic term,
                        input string what);
    int e0, t0;
    e0 = n_txe; t0 = tqn;
    tx_send(1'b1, sid, sub);
    exp_err(0, e0, c, what);
    if (term) exp_term(0, what);
    else if (tqn != t0) fail($sformatf("%s: output without a message", what));
  endtask
  // receive input buffer builders
  task automatic ri_add(input logic [127:0] d, input int n, input logic [1:0] k, input logic l, input logic c);
    ri_d[rin] = d; ri_n[rin] = 5'(n); ri_k[rin] = k; ri_l[rin] = l; ri_c[rin] = c; rin++;
  endtask
  task automatic rx_bad(input logic [1:0] sid, input logic [2:0] c, input logic term, input string what);
    int e0, r0;
    e0 = n_rxe; r0 = ron;
    rx_send(sid);
    exp_err(1, e0, c, what);
    if (term) exp_term(1, what);
    else if (ron != r0) fail($sformatf("%s: output without a message", what));
  endtask
  function automatic logic [127:0] pfx(input logic [7:0] id, input logic k, input logic [1:0] sub);
    pfx = {8'h92, 1'b1, k, 2'b00, sub, 2'b00, id, 8'h00, 96'h0};
  endfunction
  // a protected TLP from the transmit side, kept in sv_* for the receive tests
  int           svn;
  logic [127:0] sv_d [0:63];
  logic [4:0]   sv_n [0:63];
  logic [1:0]   sv_k [0:63];
  logic         sv_l [0:63];
  task automatic make_tlp(input int s, input logic [1:0] sub, input int hl, input int pl);
    int t0;
    tp_tlp(hl, pl, 0, 0, 1'b1);
    t0 = tqn;
    tx_send(1'b1, 2'(s), sub);
    drain(3000);
    svn = tqn - t0;
    for (int j = 0; j < svn; j++) begin
      sv_d[j] = tq_d[(t0 + j) % 1024]; sv_n[j] = tq_n[(t0 + j) % 1024]; sv_k[j] = tq_k[(t0 + j) % 1024];
      sv_l[j] = tq_l[(t0 + j) % 1024];
    end
  endtask
  task automatic ri_from_sv();
    rin = 0;
    for (int j = 0; j < svn; j++) ri_add(sv_d[j], sv_n[j], sv_k[j], sv_l[j], 1'b0);
  endtask

  task automatic do_clr();
    @(negedge clk);
    clr = 1'b1;
    @(negedge clk);
    clr = 1'b0;
    if (kv_tx != 0 || kv_rx != 0 || sec_tx != 0 || sec_rx != 0) fail("clr left keys or Secure streams");
  endtask
  task automatic t_km();
    do_clr();
    // bad stream / sub-stream, sideload key not valid
    km(0, 0, 2'd2, 0, 2'd0, '1, 0, 3'd1);
    km(0, 1, 2'd3, 1, 2'd1, '1, 0, 3'd1);
    km(0, 0, 2'd0, 0, 2'd3, '1, 0, 3'd1);
    km(0, 1, 2'd1, 1, 2'd0, '1, 1, 3'd3);
    km(1, 0, 2'd2, 0, 2'd0, '0, 0, 3'd1);
    km(2, 1, 2'd3, 0, 2'd0, '0, 0, 3'd1);
    // every slot: an all-ones key (the receive keys from the sideload port), then every set cleared
    for (int d = 0; d < 2; d++)
      for (int s = 0; s < NS; s++)
        for (int k = 0; k < 2; k++)
          for (int sub = 0; sub < 3; sub++) km(0, d, 2'(s), k, 2'(sub), '1, d, 3'd0);
    for (int d = 0; d < 2; d++)
      for (int s = 0; s < NS; s++)
        for (int k = 0; k < 2; k++) km(2, d, 2'(s), k, 2'd0, '0, 0, 3'd0);
    // a TLP stream needs all three sub-stream keys; a cachemem stream only sub-stream 0
    cfg(0, 1'b1, 1'b0, 8'h10, 32'h0);
    km(0, 0, 2'd0, 0, 2'd0, {r128(), r128()}, 0, 3'd0);
    km(0, 0, 2'd0, 0, 2'd1, {r128(), r128()}, 0, 3'd0);
    km(1, 0, 2'd0, 0, 2'd0, '0, 0, 3'd2);
    km(0, 0, 2'd0, 0, 2'd2, {r128(), r128()}, 0, 3'd0);
    km(1, 0, 2'd0, 0, 2'd0, '0, 0, 3'd0);
    km(0, 0, 2'd0, 0, 2'd1, {r128(), r128()}, 0, 3'd4);       // the active set is in use
    km(1, 0, 2'd0, 1, 2'd0, '0, 0, 3'd2);                       // the other set is empty
    km(2, 0, 2'd0, 1, 2'd0, '0, 0, 3'd0);                       // stop the inactive set: still Secure
    if (!sec_tx[0]) fail("stopping the inactive set ended Secure");
    km(2, 0, 2'd0, 0, 2'd0, '0, 0, 3'd0);                       // stop the active set
    if (sec_tx[0]) fail("stopping the active set kept Secure");
    cfg(1, 1'b1, 1'b1, 8'h11, 32'h0);
    km(0, 1, 2'd1, 1, 2'd0, {r128(), r128()}, 0, 3'd0);
    km(1, 1, 2'd1, 1, 2'd0, '0, 0, 3'd0);
    if (!sec_rx[1] || !ks_rx[1]) fail("cachemem stream not Secure with sub-stream 0");
    km(0, 1, 2'd1, 1, 2'd0, {r128(), r128()}, 0, 3'd4);
    km(2, 1, 2'd1, 1, 2'd0, '0, 0, 3'd0);
  endtask

  // transmit errors on stream 0 (TLP) and 1 (cachemem)
  task automatic t_tx_err();
    logic [255:0] k0;
    k0 = {r128(), r128()};
    cfg(0, 1'b1, 1'b0, 8'h21, 32'h0BAD_F00D);
    load_set(0, 0, k0);
    cfg(1, 1'b1, 1'b1, 8'h22, 32'h1);
    cm_agg = 7'd2;
    for (int d = 0; d < 2; d++) begin km(0, d, 2'd1, 0, 2'd0, k0, 0, 3'd0); km(1, d, 2'd1, 0, 2'd0, '0, 0, 3'd0); end
    // stream disabled, no such stream, sub-stream 3
    tp_tlp(12, 16, 0, 0, 1'b1);
    cfg(0, 1'b0, 1'b0, 8'h21, 32'h0BAD_F00D);
    tx_bad(2'd0, 2'd0, 3'd2, 0, "transmit on a disabled stream");
    cfg(0, 1'b1, 1'b0, 8'h21, 32'h0BAD_F00D);
    tx_bad(2'd2, 2'd0, 3'd2, 0, "transmit on stream 2");
    tx_bad(2'd3, 2'd1, 3'd2, 0, "transmit on stream 3");
    tx_bad(2'd0, 2'd3, 3'd1, 0, "transmit on sub-stream 3");
    // stream 1 made Secure as cachemem (sub-stream 0 only), then switched to TLPs
    cfg(1, 1'b1, 1'b0, 8'h22, 32'h1);
    tx_bad(2'd1, 2'd1, 3'd3, 0, "sub-stream key not loaded");
    cfg(1, 1'b1, 1'b1, 8'h22, 32'h1);
    // framing errors after the prefix
    tpn = 0; tp_add(r128(), 16, 1'b0, 1'b1);
    tx_bad(2'd0, 2'd0, 3'd1, 1, "TLP without a header");
    tpn = 0; tp_add(r128(), 16, 1'b0, 1'b0); tp_add(r128(), 16, 1'b0, 1'b1);
    tx_bad(2'd0, 2'd0, 3'd1, 1, "TLP without a header, two blocks");
    tpn = 0; tp_add(r128(), 8, 1'b1, 1'b0); tp_add(r128(), 16, 1'b1, 1'b1);
    tx_bad(2'd0, 2'd1, 3'd1, 1, "header after a partial header");
    tpn = 0; tp_add(r128(), 0, 1'b1, 1'b1);
    tx_bad(2'd0, 2'd2, 3'd1, 1, "empty header block");
    for (int n = 17; n < 32; n += 7) begin
      tpn = 0; tp_add(r128(), n, 1'b1, 1'b0); tp_add(r128(), 16, 1'b0, 1'b1);
      tx_bad(2'd0, 2'd0, 3'd1, 1, "header block over 16 bytes");
    end
    tpn = 0; tp_add(r128(), 16, 1'b1, 1'b0); tp_add(r128(), 0, 1'b0, 1'b1);
    tx_bad(2'd0, 2'd0, 3'd1, 1, "empty payload block");
    tpn = 0; tp_add(r128(), 12, 1'b1, 1'b0); tp_add(r128(), 31, 1'b0, 1'b1);
    tx_bad(2'd0, 2'd1, 3'd1, 1, "payload block over 16 bytes");
    tpn = 0; tp_add(r128(), 12, 1'b1, 1'b0); tp_add(r128(), 8, 1'b0, 1'b0); tp_add(r128(), 16, 1'b0, 1'b1);
    tx_bad(2'd0, 2'd2, 3'd1, 1, "partial payload block not last");
    tpn = 0; tp_add(r128(), 16, 1'b1, 1'b0); tp_add(r128(), 16, 1'b0, 1'b0); tp_add(r128(), 16, 1'b1, 1'b1);
    tx_bad(2'd0, 2'd0, 3'd1, 1, "header block in the payload");
    // cachemem: a header block, a partial block, then an epoch closed by a TLP and by a disabled stream
    tpn = 0; tp_add(r128(), 16, 1'b1, 1'b1);
    tx_bad(2'd1, 2'd0, 3'd1, 1, "header block in a flit");
    tpn = 0; tp_add(r128(), 16, 1'b0, 1'b0); tp_add(r128(), 8, 1'b0, 1'b1);
    tx_bad(2'd1, 2'd0, 3'd1, 1, "partial flit block");
    // length limits (LEN_W = 9): 480 payload bytes pass, 481 fail; AAD 4 + 507 passes, 4 + 508 fails
    resync(0);
    loop_tlp(0, 2'd0, 12, 480, 1'b1, 1'b1);
    tp_tlp(12, 481, 0, 0, 1'b1);
    tx_bad(2'd0, 2'd1, 3'd5, 1, "payload over the limit");
    tp_tlp(512, 0, 0, 0, 1'b1);
    tx_bad(2'd0, 2'd2, 3'd5, 1, "header over the limit (full blocks)");
    resync(0);
    loop_tlp(0, 2'd2, 507, 0, 1'b1, 1'b1);
    tp_tlp(508, 0, 0, 0, 1'b1);
    tx_bad(2'd0, 2'd0, 3'd5, 1, "header over the limit at the flush");
    tp_tlp(508, 32, 0, 0, 1'b1);
    tx_bad(2'd0, 2'd1, 3'd5, 1, "header over the limit before the payload");
    tp_tlp(509, 32, 0, 0, 1'b1);
    tx_bad(2'd0, 2'd1, 3'd5, 1, "header over the limit (partial block)");
  endtask

  // cachemem epochs on stream 1 (TLP stream 0 in between)
  task automatic flit(input logic [1:0] sid, input int nb);
    tpn = 0;
    for (int j = 0; j < nb; j++) tp_add(r128(), 16, 1'b0, j == nb - 1);
    tx_send(1'b1, sid, 2'($urandom));
  endtask
  task automatic t_cm();
    int t0, r0, e0, d0;
    logic [255:0] k1;
    k1 = {r128(), r128()};
    cfg(1, 1'b1, 1'b1, 8'h33, 32'hFFFF_FFFF);
    cm_agg = 7'd2;
    for (int d = 0; d < 2; d++) begin km(0, d, 2'd1, 1, 2'd0, k1, 0, 3'd0); km(1, d, 2'd1, 1, 2'd0, '0, 0, 3'd0); end
    // a full epoch of three flits, looped back
    t0 = tqn; r0 = ron;
    flit(2'd1, 4); flit(2'd1, 2); flit(2'd1, 1);
    drain(3000);
    ri_from_tq(t0, tqn - t0);
    rx_send(2'd1);
    drain(3000);
    if (ron - r0 != 8 || ro_k[(ron - 1) % 1024] !== K_END || ro_b[(ron - 1) % 1024]) fail("epoch loopback");
    // an epoch closed early by a TLP, with bypass traffic inside it; all of it
    // goes to the receiver in transmit order
    resync(0);
    t0 = tqn; r0 = ron; e0 = n_rxe; d0 = n_rxd;
    flit(2'd1, 2);
    tp_tlp(12, 0, 0, 0, 1'b1); tx_send(1'b0, 2'd0, 2'd0);
    tp_tlp(16, 20, 0, 0, 1'b1); tx_send(1'b1, 2'd0, 2'd1);
    drain(3000);
    ri_from_tq(t0, tqn - t0);
    rx_send(2'd1);
    drain(3000);
    if (n_rxe != e0 || n_rxd != d0 + 2 || ro_k[(ron - 1) % 1024] !== K_END || ro_b[(ron - 1) % 1024]) fail("truncated epoch");
    // the stream is stopped during an epoch: the next flit is refused and the epoch nullified
    flit(2'd1, 1);
    km(2, 0, 2'd1, 1, 2'd0, '0, 0, 3'd0);
    e0 = n_txe;
    flit(2'd1, 1);
    exp_err(0, e0, 3'd2, "flit after the stream stopped");
    exp_term(0, "flit after the stream stopped");
    // receive: MAC without an epoch, wrong kinds, a stream that is not cachemem / Secure
    rin = 0; ri_add(r128(), 12, K_MAC, 1'b1, 1'b1);
    rx_bad(2'd1, 3'd1, 0, "MAC without an epoch");
    rin = 0; ri_add(r128(), 16, K_HDR, 1'b1, 1'b1);
    rx_bad(2'd1, 3'd1, 0, "header block as a flit");
    rin = 0; ri_add(r128(), 16, K_DATA, 1'b1, 1'b1);
    rx_bad(2'd0, 3'd2, 0, "flit for a TLP stream");
    rin = 0; ri_add(r128(), 16, K_DATA, 1'b1, 1'b1);
    rx_bad(2'd3, 3'd2, 0, "flit for stream 3");
    rin = 0; ri_add(r128(), 16, K_DATA, 1'b1, 1'b1);
    rx_bad(2'd1, 3'd2, 0, "flit for a stopped stream");   // the stop above was transmit only: still Secure here?
  endtask

  // receive errors on stream 0 (TLP)
  task automatic rx_crafted(input logic [2:0] c, input logic term, input string what);
    rx_bad(2'd0, c, term, what);
    resync_ks(0, ks_rx[0]);
  endtask
  task automatic t_rx_err();
    logic [7:0] id;
    logic       k;
    id = 8'h44;
    cfg(0, 1'b1, 1'b0, id, 32'hA5A5_5A5A);
    cfg(1, 1'b1, 1'b0, 8'h45, 32'h0);
    resync(0);
    // tampered ciphertext, MAC and header: MAC mismatch, the stream becomes Insecure
    for (int w = 0; w < 3; w++) begin
      make_tlp(0, 2'(w), 12, 20);
      ri_from_sv();
      if (w == 0) ri_d[2][100] = !ri_d[2][100];
      if (w == 1) ri_d[4][40] = !ri_d[4][40];
      if (w == 2) ri_d[1][127] = !ri_d[1][127];
      rx_bad(2'd0, 3'd7, 1, "tampered message");
      if (sec_rx[0]) fail("Secure after a MAC mismatch");
      // the stream refuses everything now
      ri_from_sv();
      rx_bad(2'd0, 3'd2, 0, "message on an Insecure stream");
      resync(0);
    end
    // prefix errors (nothing taken from the counters)
    make_tlp(0, 2'd1, 16, 0);
    k = sv_d[0][118];
    rin = 0; ri_add(sv_d[0], 8, K_PFX, 1'b0, 1'b0); ri_add(sv_d[1], 16, K_HDR, 1'b1, 1'b0);
    rx_bad(2'd0, 3'd1, 0, "prefix of 8 bytes");
    rin = 0; ri_add(sv_d[0], 4, K_PFX, 1'b1, 1'b0);
    rx_bad(2'd0, 3'd1, 0, "prefix alone");
    rin = 0; ri_add(sv_d[0] ^ {8'h01, 120'h0}, 4, K_PFX, 1'b0, 1'b0); ri_add(sv_d[1], 16, K_HDR, 1'b1, 1'b0);
    rx_bad(2'd0, 3'd1, 0, "prefix type");
    rin = 0; ri_add(sv_d[0] & ~{8'h00, 1'b1, 119'h0}, 4, K_PFX, 1'b0, 1'b0); ri_add(sv_d[1], 16, K_HDR, 1'b1, 1'b0);
    rx_bad(2'd0, 3'd1, 0, "prefix without M");
    rin = 0; ri_add(pfx(8'h99, k, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(sv_d[1], 16, K_HDR, 1'b1, 1'b0);
    rx_bad(2'd0, 3'd6, 0, "unknown Stream ID");
    cfg(1, 1'b1, 1'b0, 8'h45, 32'h0);
    rin = 0; ri_add(pfx(8'h45, k, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(sv_d[1], 16, K_HDR, 1'b1, 1'b0);
    rx_bad(2'd0, 3'd2, 0, "Stream ID of a stream that is not Secure");
    // the good message still passes after all of these
    ri_from_sv();
    rx_send(2'd0);
    drain(3000);
    if (ro_b[(ron - 1) % 1024] || ro_k[(ron - 1) % 1024] !== K_END) fail("message after prefix errors");
    rin = 0; ri_add(pfx(id, k, 2'd3), 4, K_PFX, 1'b0, 1'b0); ri_add(sv_d[1], 16, K_HDR, 1'b1, 1'b0);
    rx_crafted(3'd1, 0, "sub-stream 3");
    rin = 0; ri_add(pfx(id, !ks_rx[0], 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(sv_d[1], 16, K_HDR, 1'b1, 1'b0);
    rx_crafted(3'd3, 0, "key set not loaded");
    // framing errors after the prefix
    k = ks_rx[0];
    rin = 0; ri_add(pfx(id, k, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(pfx(id, k, 2'd0), 4, K_PFX, 1'b0, 1'b0);
    ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "two prefixes");
    rin = 0; ri_add(pfx(id, k, 2'd1), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 16, K_DATA, 1'b0, 1'b0);
    ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "payload without a header");
    rin = 0; ri_add(pfx(id, k, 2'd2), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "MAC without a header");
    rin = 0; ri_add(pfx(id, k, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 8, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 16, K_HDR, 1'b0, 1'b0); ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "header after a partial header");
    rin = 0; ri_add(pfx(id, k, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 0, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "empty header block");
    rin = 0; ri_add(pfx(id, k, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 20, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "header block over 16 bytes");
    rin = 0; ri_add(pfx(id, k, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 16, K_HDR, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "header block marked last");
    rin = 0; ri_add(pfx(id, k, 2'd1), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 0, K_DATA, 1'b0, 1'b0); ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "empty payload block");
    rin = 0; ri_add(pfx(id, k, 2'd1), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 16, K_DATA, 1'b0, 1'b0); ri_add(r128(), 17, K_DATA, 1'b0, 1'b0); ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "payload block over 16 bytes");
    rin = 0; ri_add(pfx(id, k, 2'd2), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 8, K_DATA, 1'b0, 1'b0); ri_add(r128(), 16, K_DATA, 1'b0, 1'b0); ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "payload after a partial payload block");
    rin = 0; ri_add(pfx(id, k, 2'd2), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 16, K_DATA, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "payload block marked last");
    rin = 0; ri_add(pfx(id, k, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 16, K_DATA, 1'b0, 1'b0); ri_add(r128(), 16, K_HDR, 1'b0, 1'b0); ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "header block in the payload");
    rin = 0; ri_add(pfx(id, k, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 16, K_DATA, 1'b0, 1'b0); ri_add(pfx(id, k, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "prefix in the payload");
    rin = 0; ri_add(pfx(id, k, 2'd1), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 16, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "MAC of 16 bytes");
    rin = 0; ri_add(pfx(id, k, 2'd1), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 12, K_MAC, 1'b0, 1'b0); ri_add(r128(), 16, K_DATA, 1'b1, 1'b0);
    rx_crafted(3'd1, 1, "MAC not last");
    // length limits: 31 full payload blocks; 30 and a partial one; AAD over the limit
    rin = 0; ri_add(pfx(id, k, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_HDR, 1'b0, 1'b0);
    for (int j = 0; j < 31; j++) ri_add(r128(), 16, K_DATA, 1'b0, 1'b0);
    ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd5, 1, "receive payload over the limit");
    rin = 0; ri_add(pfx(id, k, 2'd1), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 12, K_HDR, 1'b0, 1'b0);
    for (int j = 0; j < 30; j++) ri_add(r128(), 16, K_DATA, 1'b0, 1'b0);
    ri_add(r128(), 1, K_DATA, 1'b0, 1'b0); ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd5, 1, "receive payload over the limit (held block)");
    rin = 0; ri_add(pfx(id, k, 2'd2), 4, K_PFX, 1'b0, 1'b0);
    for (int j = 0; j < 32; j++) ri_add(r128(), 16, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd5, 1, "receive header over the limit");
    rin = 0; ri_add(pfx(id, k, 2'd2), 4, K_PFX, 1'b0, 1'b0);
    for (int j = 0; j < 31; j++) ri_add(r128(), 16, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 12, K_HDR, 1'b0, 1'b0); ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd5, 1, "receive header over the limit at the flush");
    rin = 0; ri_add(pfx(id, k, 2'd2), 4, K_PFX, 1'b0, 1'b0);
    for (int j = 0; j < 31; j++) ri_add(r128(), 16, K_HDR, 1'b0, 1'b0);
    ri_add(r128(), 13, K_HDR, 1'b0, 1'b0); ri_add(r128(), 12, K_MAC, 1'b1, 1'b0);
    rx_crafted(3'd5, 1, "receive header over the limit (partial block)");
    // a key refresh seen by the receiver only through the K bit
    for (int d = 0; d < 2; d++)
      for (int sub = 0; sub < 3; sub++) km(0, d, 2'd0, !ks_tx[0], 2'(sub), 256'h1234, 0, 3'd0);
    km(1, 0, 2'd0, !ks_tx[0], 2'd0, '0, 0, 3'd0);
    loop_tlp(0, 2'd0, 12, 32, 1'b1, 1'b1);
    if (ks_rx[0] !== ks_tx[0]) fail("receiver did not follow the K bit");
  endtask

  // every counter to exhaustion, both directions (TLP streams), then the
  // cachemem counter
  task automatic t_ctr();
    cfg(0, 1'b1, 1'b0, 8'h50, 32'h0);
    cfg(1, 1'b1, 1'b0, 8'h51, 32'hFFFF_FFFF);
    for (int s = 0; s < NS; s++)
      for (int k = 0; k < 2; k++) begin
        resync_ks(s, k);
        for (int sub = 0; sub < 3; sub++) begin
          for (int m = 0; m < 14; m++) begin
            if (m == 13) make_tlp(s, 2'(sub), 4, 0);
            else loop_tlp(s, 2'(sub), 4, 0, 1'b1, 1'b1);
          end
          // the transmit counter is exhausted; the last message reaches the receiver
          ri_from_sv(); rx_send(2'(s)); drain(3000);
          tp_tlp(4, 0, 0, 0, 1'b1);
          tx_bad(2'(s), 2'(sub), 3'd4, 0, "transmit counter exhausted");
          if (sec_tx[s]) fail("Secure after the counter ran out");
          ri_from_sv();
          rx_bad(2'(s), 3'd4, 0, "receive counter exhausted");
          for (int d = 0; d < 2; d++) km(1, d, 2'(s), k, 2'd0, '0, 0, 3'd0);
        end
      end
    // cachemem: one-flit epochs on stream 1
    cfg(1, 1'b1, 1'b1, 8'h52, 32'h0);
    cm_agg = 7'd0;
    resync_ks(1, 0);
    for (int m = 0; m < 14; m++) begin
      int t0;
      t0 = tqn;
      flit(2'd1, 1);
      drain(3000);
      ri_from_tq(t0, tqn - t0);
      rx_send(2'd1);
    end
    drain(3000);
    tpn = 0; tp_add(r128(), 16, 1'b0, 1'b1);
    tx_bad(2'd1, 2'd0, 3'd4, 0, "cachemem transmit counter exhausted");
    rin = 0; ri_add(r128(), 16, K_DATA, 1'b1, 1'b1);
    rx_bad(2'd1, 3'd4, 0, "cachemem receive counter exhausted");
    // the counters and keys back to zero
    for (int d = 0; d < 2; d++)
      for (int s = 0; s < NS; s++)
        for (int k = 0; k < 2; k++) km(2, d, 2'(s), k, 2'd0, '0, 0, 3'd0);
  endtask

  // receive-side cachemem errors on stream 1 (stream 0 cachemem too for an
  // epoch interrupted by another stream)
  task automatic t_cm_rx();
    int t0, e0;
    cfg(1, 1'b1, 1'b1, 8'h61, 32'h1357_9BDF);
    cfg(0, 1'b1, 1'b1, 8'h60, 32'h0);
    cm_agg = 7'd1;
    resync(1); resync(0);
    // a good epoch with a wrong MAC
    t0 = tqn;
    flit(2'd1, 1); flit(2'd1, 2);
    drain(3000);
    ri_from_tq(t0, tqn - t0);
    ri_d[rin - 1][60] = !ri_d[rin - 1][60];
    rx_bad(2'd1, 3'd7, 1, "cachemem MAC mismatch");
    resync(1);
    // more flits than the epoch holds
    t0 = tqn;
    flit(2'd1, 1); flit(2'd1, 1);
    drain(3000);
    rin = 0; ri_add(tq_d[t0 % 1024], 16, K_DATA, 1'b1, 1'b1); ri_add(tq_d[(t0 + 1) % 1024], 16, K_DATA, 1'b1, 1'b1);
    rx_send(2'd1);
    rin = 0; ri_add(r128(), 16, K_DATA, 1'b1, 1'b1);
    rx_bad(2'd1, 3'd1, 1, "flit after a full epoch");
    resync(1);
    // a partial flit block, and a MAC inside a flit
    rin = 0; ri_add(r128(), 16, K_DATA, 1'b0, 1'b1); ri_add(r128(), 8, K_DATA, 1'b1, 1'b1);
    rx_bad(2'd1, 3'd1, 1, "partial flit block");
    resync(1);
    rin = 0; ri_add(r128(), 16, K_DATA, 1'b0, 1'b1); ri_add(r128(), 12, K_MAC, 1'b1, 1'b1);
    rx_bad(2'd1, 3'd1, 1, "MAC inside a flit");
    resync(1);
    rin = 0; ri_add(r128(), 16, K_DATA, 1'b1, 1'b1);
    rx_send(2'd1);
    rin = 0; ri_add(r128(), 16, K_MAC, 1'b1, 1'b1);
    rx_bad(2'd1, 3'd1, 1, "epoch MAC of 16 bytes");
    resync(1);
    // an open epoch interrupted by a TLP prefix and by another cachemem stream
    rin = 0; ri_add(r128(), 16, K_DATA, 1'b1, 1'b1);
    rx_send(2'd1);
    e0 = n_rxe;
    rin = 0; ri_add(pfx(8'h60, 0, 2'd0), 4, K_PFX, 1'b0, 1'b0); ri_add(r128(), 16, K_HDR, 1'b1, 1'b0);
    rx_send(2'd0);
    drain(3000);
    if (n_rxe != e0 + 2) fail("epoch interrupted by a prefix");
    resync(1);
    rin = 0; ri_add(r128(), 16, K_DATA, 1'b1, 1'b1);
    rx_send(2'd1);
    e0 = n_rxe;
    rin = 0; ri_add(r128(), 16, K_DATA, 1'b1, 1'b1);
    rx_send(2'd0);
    drain(3000);
    if (n_rxe != e0 + 1) fail("epoch interrupted by another stream");
    // stream 0's new epoch is ended by a wrong MAC
    rin = 0; ri_add(r128(), 12, K_MAC, 1'b1, 1'b1);
    rx_bad(2'd0, 3'd7, 1, "the other stream's epoch");
    resync(1); resync(0);
    // transmit: an epoch closed by another cachemem stream
    t0 = tqn;
    flit(2'd1, 1); flit(2'd0, 1); flit(2'd0, 1);
    drain(3000);
    if (tqn - t0 != 5) fail("transmit epoch closed by another stream");
    do_clr();
  endtask

  // output held back (ready ~10%) while the engines move on: prefix, MAC, status
  // and termination blocks wait for the output register
  task automatic t_stall();
    int e0;
    cfg(0, 1'b1, 1'b0, 8'h5A, 32'h1234_5678);
    resync(0);
    rdy_t = 10; rdy_r = 10;
    for (int i = 0; i < 6; i++) loop_tlp(0, 2'(i % 3), 12 + 4 * i, 16 * i + 8, 1'b1, 1'b1);
    // a protected TLP right behind a bypass TLP whose output is still held
    rdy_t = 2;
    tp_tlp(12, 20, 0, 0, 1'b1);
    tx_send(1'b0, 2'd0, 2'd0);
    tx_send(1'b1, 2'd0, 2'd0);
    drain(5000);
    rdy_t = 10;
    rdy_t = 2;
    tpn = 0; tp_add(r128(), 16, 1'b1, 1'b0);
    for (int j = 0; j < 4; j++) tp_add(r128(), 16, 1'b0, 1'b0);
    tp_add(r128(), 16, 1'b1, 1'b1);
    tx_bad(2'd0, 2'd0, 3'd1, 1, "header block in the payload, output held");
    rdy_t = 10;
    resync(0);
    // receive: a tampered message and a framing error after output started
    make_tlp(0, 2'd0, 32, 48);
    ri_from_sv();
    ri_d[1][3] = !ri_d[1][3];
    rx_bad(2'd0, 3'd7, 1, "tampered message, output held");
    resync(0);
    make_tlp(0, 2'd1, 32, 48);
    ri_from_sv();
    ri_k[4] = K_HDR;
    rdy_r = 2;
    rx_bad(2'd0, 3'd1, 1, "header block in the payload, output held");
    rdy_t = 100; rdy_r = 100;
    resync(0);
    // an epoch of up to 128 flits (cm_agg 127) runs into the engine length limit
    // (480 bytes in the testbench) at the 31st flit, on both sides
    cfg(1, 1'b1, 1'b1, 8'h5B, 32'h0);
    cm_agg = 7'd127;
    resync(1);
    e0 = n_txe;
    for (int i = 0; i < 31; i++) flit(2'd1, 1);
    exp_err(0, e0, 3'd5, "epoch over the length limit");
    exp_term(0, "epoch over the length limit");
    rin = 0;
    for (int i = 0; i < 31; i++) ri_add(r128(), 16, K_DATA, 1'b1, 1'b1);
    rx_bad(2'd1, 3'd5, 1, "receive epoch over the length limit");
    cm_agg = 7'd0;
    do_clr();
  endtask

  // clr and reset in the middle of messages
  logic       bg_tx = 1'b0, bg_rx = 1'b0;
  logic [1:0] bg_sid, bg_sub;
  initial forever begin
    @(negedge clk);
    if (bg_tx) begin tx_send(1'b1, bg_sid, bg_sub); bg_tx = 1'b0; end
  end
  initial forever begin
    @(negedge clk);
    if (bg_rx) begin rx_send(bg_sid); bg_rx = 1'b0; end
  end
  task automatic wait_bg();
    int t;
    t = 0;
    while ((bg_tx || bg_rx) && t < 20000) begin @(negedge clk); t++; end
    rdy_t = 100; rdy_r = 100;
    drain(3000);
  endtask
  // which: 1 transmit, 2 receive, 3 both; clr when the engines reach states ts / rs
  task automatic clr_in(input int which, input int ts, input int rs, input int rdy);
    int t;
    cfg(0, 1'b1, 1'b0, 8'h70, 32'h0);
    resync(0);
    make_tlp(0, 2'd1, 20, 40);
    ri_from_sv();
    resync_ks(0, ks_rx[0]);
    tp_tlp(20, 40, 0, 0, 1'b1);
    bg_sid = 2'd0; bg_sub = 2'd2;
    rdy_t = rdy; rdy_r = rdy;
    if (which & 1) bg_tx = 1'b1;
    if (which & 2) bg_rx = 1'b1;
    t = 0;
    while (t < 3000 && !((which & 1) == 0 || int'(u_dut.t) == ts) || t < 3000 && !((which & 2) == 0 || int'(u_dut.r) == rs))
    begin @(negedge clk); t++; end
    if (t >= 3000) fail($sformatf("clr: states %0d / %0d not reached", ts, rs));
    do_clr();
    rdy_t = 100; rdy_r = 100;
    wait_bg();
  endtask
  task automatic t_clr();
    clr_in(1, 2, 0, 0);                 // transmit header, output held
    clr_in(1, 4, 0, 100);               // transmit payload
    clr_in(1, 6, 0, 100);               // transmit, waiting for the MAC
    clr_in(2, 0, 1, 0);                 // receive header, output held
    clr_in(2, 0, 3, 100);               // receive payload
    clr_in(2, 0, 6, 100);               // receive, waiting for the MAC check
    clr_in(3, 2, 1, 0);                 // both
    do_clr();                           // idle
  endtask

  initial begin
    s_en = '0; s_cm = '0; s_id = '0; s_ivfix = '0; cm_agg = '0;
    km_dir = 0; km_sid = 0; km_ks = 0; km_sub = 0; km_sel = 0; km_key = '0; sl_key = '0; sl_valid = 0;
    km_prog = 0; km_go = 0; km_stop = 0; clr = 0;
    idle_tx(); idle_rx();
    load_vecs();
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
    // known answers, with gaps and back-pressure from case 20 on
    for (int i = 0; i < NC; i++) begin
      if (i == 20) begin gap = 2; rdy_t = 70; rdy_r = 70; end
      run_case(i);
    end
    $display("known-answer cases: %0d", NC);
    // random loopback TLPs on stream 0 (TLP type), fresh key set
    load_set(0, !ks_tx[0], {r128(), r128()});
    for (int i = 0; i < 20; i++)
      loop_tlp(0, 2'($urandom_range(0, 2)), $urandom_range(1, 40), $urandom_range(0, 70), $urandom_range(0, 4) != 0, 1'b1);
    gap = 0; rdy_t = 100; rdy_r = 100;
    t_km();
    $display("key management done");
    t_tx_err();
    $display("transmit errors done");
    t_cm();
    $display("cachemem done");
    t_rx_err();
    $display("receive errors done");
    t_cm_rx();
    $display("cachemem receive errors done");
    t_ctr();
    $display("counters done");
    t_clr();
    $display("clr done");
    t_stall();
    $display("stall and long epoch done");
    // reset in the middle of a message
    resync(0);
    tp_tlp(16, 64, 0, 0, 1'b1);
    bg_sid = 2'd0; bg_sub = 2'd0; bg_tx = 1'b1;
    while (int'(u_dut.t) != 4) @(negedge clk);
    rst_n = 1'b0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    wait_bg();
    // configuration and inputs back to zero
    s_en = '0; s_cm = '0; s_id = '0; s_ivfix = '0; cm_agg = '0;
    km_dir = 0; km_sid = 0; km_ks = 0; km_sub = 0; km_sel = 0; km_key = '0; sl_key = '0; sl_valid = 0;
    tx_valid = 0; tx_data = '0; tx_bytes = '0; tx_hdr = 0; tx_last = 0; tx_ide = 0; tx_sid = '0; tx_sub = '0;
    rx_valid = 0; rx_data = '0; rx_bytes = '0; rx_kind = '0; rx_last = 0; rx_cm = 0; rx_sid = '0;
    repeat (20) @(negedge clk);
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin
    #50ms;
    $display("TIMEOUT");
    $display("TEST FAILED");
    $finish;
  end
endmodule
