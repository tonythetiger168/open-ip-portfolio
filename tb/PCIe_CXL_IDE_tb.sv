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
    if (sel && ec != 3'd3) sl_valid = 1'b1;
    km_prog = op == 0; km_go = op == 1; km_stop = op == 2;
    e0 = n_kme;
    @(negedge clk);
    km_prog = 1'b0; km_go = 1'b0; km_stop = 1'b0;
    km_key = r128(); sl_key = r128(); sl_valid = $urandom; km_sel = $urandom;
    km_dir = $urandom; km_sid = 2'($urandom); km_ks = $urandom; km_sub = 2'($urandom);
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
