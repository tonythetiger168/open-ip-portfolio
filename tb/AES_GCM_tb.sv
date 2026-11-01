// SPDX-License-Identifier: Apache-2.0
// AES_GCM_tb: self-checking testbench. The core runs with LEN_W = 14 so the
// length limits can be reached (16383 bytes of AAD, 16352 bytes of text).
//  - Every case of tb/AES_GCM_vec.svh (NIST CAVP and Wycheproof known
//    answers, the NIST encrypt cases decrypted again with their truncated
//    tags, seeded random cases; from scripts/aes_gcm/gen_vec.py) is streamed
//    in with random gaps, random output back-pressure, the key from the key
//    port or the sideload port, and the message end either on the last block
//    or on a separate empty block; outputs, tag and tag_ok are compared.
//  - The two long cases at the length limits (tag and XOR of all outputs),
//    and one byte more for each (too long).
//  - Every error, clr in every phase, start while busy (ignored), reset in
//    the middle of a message, back-to-back messages, and the throughput
//    (Nr + 1 clocks per text block, 4 per AAD block).
`timescale 1ns/1ps
module AES_GCM_tb;
  localparam int LW = 14;
  logic         clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  logic         key256, decrypt, key_sel, sl_valid, start, clr, busy;
  logic [3:0]   tag_len;
  logic [255:0] key, sl_key;
  logic [95:0]  iv;
  logic [127:0] tag_in, in_data, out_data, tag;
  logic         in_valid, in_ready, in_aad, in_last, out_valid, out_ready, out_last;
  logic [4:0]   in_bytes, out_bytes;
  logic         done, tag_ok, err;
  logic [2:0]   err_code;

  AES_GCM_top #(.LEN_W(LW)) u_dut (.*);

  `include "AES_GCM_vec.svh"

  int errors = 0;
  task automatic fail(input string m);
    $display("FAIL @%0t: %s", $time, m); errors++;
  endtask
  function automatic logic [127:0] r128();
    return {$urandom, $urandom, $urandom, $urandom};
  endfunction
  function automatic logic [127:0] mask(input int n);
    logic [127:0] m;
    for (int i = 0; i < 16; i++) m[127 - 8 * i -: 8] = i < n ? 8'hff : 8'h00;
    return m;
  endfunction
  // the long cases' data: block j is words (seed + 4j + k) * 0x9E3779B1
  function automatic logic [127:0] pat(input int seed, input int j);
    logic [127:0] b;
    for (int k = 0; k < 4; k++) b[127 - 32 * k -: 32] = 32'(seed + 4 * j + k) * 32'h9E3779B1;
    return b;
  endfunction

  // ---------------- output side ----------------
  int           rdy_pct = 100;          // out_ready probability
  int           nexp = 0, nout = 0;
  logic [127:0] exp_d [0:1023];         // expected text blocks of the current message
  logic [4:0]   exp_n [0:1023];
  logic         exp_l [0:1023];
  logic         fold_mode = 1'b0;
  logic [127:0] fold;
  always @(posedge clk) begin
    if (out_valid && out_ready && rst_n) begin
      if (fold_mode) fold <= fold ^ out_data;
      else if (nout >= nexp) fail("unexpected output block");
      else if (out_data !== exp_d[nout] || out_bytes !== exp_n[nout] || out_last !== exp_l[nout])
        fail($sformatf("output %0d: %h/%0d/%0d, expected %h/%0d/%0d", nout, out_data, out_bytes, out_last,
                       exp_d[nout], exp_n[nout], exp_l[nout]));
      nout <= nout + 1;
    end
    out_ready <= $urandom_range(0, 99) < rdy_pct;
  end
  // result pulses
  int ndone = 0, nerr = 0;
  always @(posedge clk) begin
    if (done) ndone++;
    if (err) nerr++;
  end

  // ---------------- input side ----------------
  int gap = 0;                          // up to this many idle clocks before a block
  task automatic idle_inputs();
    in_valid = 1'b0; in_data = r128(); in_bytes = 5'($urandom); in_aad = $urandom; in_last = $urandom;
  endtask
  task automatic send(input logic [127:0] d, input int n, input logic aad, input logic last);
    @(negedge clk);
    repeat ($urandom_range(0, gap)) begin idle_inputs(); @(negedge clk); end
    in_valid = 1'b1; in_data = d; in_bytes = 5'(n); in_aad = aad; in_last = last;
    while (!in_ready) @(negedge clk);
    @(posedge clk);
    #1 idle_inputs();
  endtask
  // configure and pulse start; ks: key from the sideload port
  task automatic begin_msg(input logic k256, input logic dec, input logic [255:0] k, input logic [95:0] v,
                           input logic [3:0] tl, input logic [127:0] ti, input logic ks);
    @(negedge clk);
    key256 = k256; decrypt = dec; iv = v; tag_len = tl; tag_in = ti; key_sel = ks;
    key = ks ? {r128(), r128()} : k;
    sl_key = ks ? k : {r128(), r128()};
    sl_valid = ks ? 1'b1 : $urandom;
    nexp = 0; nout = 0; ndone = 0; nerr = 0;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    if (!busy) fail("not busy after start");
    // the configuration ports are free once taken (tag_in is used at the end)
    key256 = $urandom; decrypt = $urandom; iv = r128(); tag_len = 4'($urandom); key = {r128(), r128()};
    key_sel = $urandom; sl_key = {r128(), r128()};
  endtask
  task automatic wait_done(input int tmax);
    int t;
    t = 0;
    while (!done && !err && t < tmax) begin @(posedge clk); #1; t++; end
    if (!done) fail("done timeout");
    @(negedge clk);
    if (busy) fail("busy after done");
  endtask

  // ---------------- one case of the vector file ----------------
  int nvec = 0;
  task automatic run_vec(input int i);
    int na, np;
    logic term, ks;
    na = (v_alen[i] + 15) / 16;
    np = (v_plen[i] + 15) / 16;
    // a separate empty end block: needed without data, allowed after a full last block
    term = na + np == 0 || (np == 0 ? 1'b1 : v_plen[i] % 16 == 0) && $urandom_range(0, 3) == 0;
    ks = $urandom_range(0, 3) == 0;
    begin_msg(v_k256[i], v_dec[i], v_key[i], v_iv[i], v_tlen[i], v_dec[i] ? v_tag[i] : r128(), ks);
    for (int j = 0; j < np; j++) begin
      exp_d[j] = vb[v_ob[i] + j] & mask(v_plen[i] - 16 * j);
      exp_n[j] = 5'(j == np - 1 ? v_plen[i] - 16 * j : 16);
      exp_l[j] = j == np - 1 && !term;
    end
    nexp = np;
    for (int j = 0; j < na; j++)
      send(vb[v_ab[i] + j] | (r128() & ~mask(v_alen[i] - 16 * j)), j == na - 1 ? v_alen[i] - 16 * j : 16, 1'b1,
           j == na - 1 && np == 0 && !term);
    for (int j = 0; j < np; j++)
      send(vb[v_xb[i] + j] | (r128() & ~mask(v_plen[i] - 16 * j)), j == np - 1 ? v_plen[i] - 16 * j : 16, 1'b0,
           j == np - 1 && !term);
    if (term) send(r128(), 0, $urandom, 1'b1);
    wait_done(5000);
    if (nout != np) fail($sformatf("case %0d: %0d output blocks, expected %0d", i, nout, np));
    if (v_dec[i]) begin
      if (tag !== 128'h0) fail($sformatf("case %0d: computed tag output on decrypt", i));
      if (tag_ok !== v_ok[i]) fail($sformatf("case %0d: tag_ok %0d, expected %0d", i, tag_ok, v_ok[i]));
    end else begin
      if (tag !== v_tag[i]) fail($sformatf("case %0d: tag %h, expected %h", i, tag, v_tag[i]));
      if (tag_ok !== 1'b0) fail($sformatf("case %0d: tag_ok on encrypt", i));
    end
    if (err) fail($sformatf("case %0d: error %0d", i, err_code));
    nvec++;
  endtask

  // ---------------- long cases (pattern data) ----------------
  // extra: one more byte of AAD (alen) or text, which must be refused
  task automatic run_long(input int i, input logic extra);
    int na, np, al, pl;
    al = l_alen[i] + (extra && l_plen[i] < 100 ? 1 : 0);
    pl = l_plen[i] + (extra && l_plen[i] >= 100 ? 1 : 0);
    na = (al + 15) / 16;
    np = (pl + 15) / 16;
    begin_msg(l_k256[i], 1'b0, l_key[i], l_iv[i], 4'd0, r128(), 1'b0);
    fold_mode = 1'b1; fold = '0;
    for (int j = 0; j < na && !err; j++)
      send(pat(l_seed[i], j) & mask(al - 16 * j), j == na - 1 ? al - 16 * j : 16, 1'b1, 1'b0);
    for (int j = 0; j < np && !err && busy; j++)
      send(pat(l_seed[i] + 32'h100_0000, j) & mask(pl - 16 * j), j == np - 1 ? pl - 16 * j : 16, 1'b0, j == np - 1);
    if (extra) begin
      @(posedge clk); #1;
      if (nerr != 1 || err_code != 3'd3 || busy) fail($sformatf("long case %0d + 1 byte: not refused", i));
      repeat (2) @(negedge clk);
    end else begin
      wait_done(400000);
      repeat (3) @(negedge clk);
      if (tag !== l_tag[i]) fail($sformatf("long case %0d: tag %h, expected %h", i, tag, l_tag[i]));
      if (fold !== l_fold[i]) fail($sformatf("long case %0d: output fold %h, expected %h", i, fold, l_fold[i]));
    end
    fold_mode = 1'b0;
  endtask

  // ---------------- error and abort cases ----------------
  task automatic expect_err(input logic [2:0] c, input string what);
    for (int t = 0; t < 3 && !err; t++) @(posedge clk);
    #1;
    if (!err || err_code !== c) fail($sformatf("%s: err %0d code %0d, expected code %0d", what, err, err_code, c));
    @(negedge clk);
    if (busy || out_valid) fail($sformatf("%s: still busy after the error", what));
    if (ndone != 0) fail($sformatf("%s: done after an error", what));
  endtask
  // a message with a random key (output blocks are only folded)
  task automatic quick(input logic dec, input logic k256);
    fold_mode = 1'b1;
    begin_msg(k256, dec, {r128(), r128()}, r128(), 4'd0, r128(), $urandom_range(0, 1));
  endtask
  task automatic error_cases();
    for (int n = 17; n < 32; n++) begin
      quick(0, $urandom); send(r128(), n, $urandom, $urandom); expect_err(3'd1, $sformatf("in_bytes %0d", n));
    end
    quick(0, $urandom); send(r128(), 0, 1'b1, 1'b0); expect_err(3'd1, "empty block without last");
    quick(1, $urandom); send(r128(), 0, 1'b0, 1'b0); expect_err(3'd1, "empty text block without last");
    quick(0, $urandom); send(r128(), 16, 1'b0, 1'b0); send(r128(), 16, 1'b1, 1'b0); expect_err(3'd2, "AAD after text");
    quick(1, $urandom); send(r128(), 16, 1'b0, 1'b0); send(r128(), 7, 1'b1, 1'b1); expect_err(3'd2, "AAD after text (last)");
    quick(0, $urandom); send(r128(), 9, 1'b1, 1'b0); send(r128(), 16, 1'b1, 1'b0); expect_err(3'd2, "AAD after partial AAD");
    quick(0, $urandom); send(r128(), 16, 1'b1, 1'b0); send(r128(), 5, 1'b0, 1'b0); expect_err(3'd2, "partial text not last");
    quick(1, $urandom); rdy_pct = 0;
    send(r128(), 16, 1'b0, 1'b0);
    repeat (40) @(negedge clk);
    if (!out_valid) fail("output not held");
    in_valid = 1'b1; in_bytes = 5'd20; in_last = 1'b0;      // refused only once the output is free
    repeat (5) @(negedge clk);
    if (err || in_ready) fail("block taken while the output is full");
    idle_inputs(); rdy_pct = 100;
    send(r128(), 20, 1'b0, 1'b0); expect_err(3'd1, "error with an output block pending");
    // sideload key not valid
    @(negedge clk);
    key_sel = 1'b1; sl_valid = 1'b0; ndone = 0; start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    if (busy || !err || err_code != 3'd4) fail("sideload key not valid: not refused");
    fold_mode = 1'b0;
  endtask
  // clr after t clocks of a message with na AAD and np text blocks (output held)
  task automatic clr_case(input int t, input int na, input int np, input logic hold, input logic k256);
    int sent;
    logic hs;
    quick($urandom, k256);
    rdy_pct = hold ? 0 : 100;
    sent = 0;
    for (int c = 0; c < t % 1000; c++) begin
      @(negedge clk);
      if (in_valid && hs) sent++;
      if (sent < na + np) begin
        in_valid = 1'b1; in_data = r128(); in_bytes = 5'd16; in_aad = sent < na; in_last = sent == na + np - 1;
      end else idle_inputs();
      hs = in_ready;                    // stable until the next clock edge
    end
    @(negedge clk);
    clr = 1'b1;
    @(negedge clk);
    clr = 1'b0;
    idle_inputs();
    @(negedge clk);
    if (busy || out_valid) fail($sformatf("clr after %0d clocks: still busy", t % 1000));
    if ((ndone != 0 || err) && t < 1000) fail($sformatf("clr after %0d clocks: done or err", t));
    rdy_pct = 100;
    fold_mode = 1'b0;
    repeat (3) @(negedge clk);
  endtask

  // ---------------- throughput ----------------
  task automatic rate(input logic k256, input logic aad, input int expect_clk);
    int t0, t1, nb;
    nb = 8;
    gap = 0; rdy_pct = 100;
    begin_msg(k256, 1'b0, {r128(), r128()}, r128(), 4'd0, r128(), 1'b0);
    fold_mode = 1'b1; fold = '0;
    send(r128(), 16, aad, 1'b0);
    t0 = $time;
    for (int j = 0; j < nb; j++) send(r128(), 16, aad, 1'b0);
    t1 = $time;
    send(r128(), 0, 1'b0, 1'b1);
    wait_done(1000);
    fold_mode = 1'b0;
    if ((t1 - t0) / 10 != nb * expect_clk)
      fail($sformatf("throughput: %0d clocks for %0d blocks, expected %0d per block", (t1 - t0) / 10, nb, expect_clk));
  endtask

  initial begin
    load_vecs();
    idle_inputs();
    key256 = 0; decrypt = 0; key_sel = 0; sl_valid = 0; start = 0; clr = 0; tag_len = 0;
    key = '0; sl_key = '0; iv = '0; tag_in = '0;
    repeat (3) @(posedge clk);
    #1 rst_n = 1'b1;
    repeat (2) @(negedge clk);
    if (busy || out_valid || in_ready || done || err) fail("outputs after reset");
    // throughput first, with no gaps
    // (AAD first: a message right after reset must take AAD)
    rate(1'b1, 1'b1, 4);
    rate(1'b0, 1'b0, 11);
    rate(1'b1, 1'b0, 15);
    // the vector file: alternate gap and back-pressure settings
    for (int i = 0; i < NV; i++) begin
      gap = i % 4 == 0 ? 0 : i % 4 == 1 ? 3 : 12;
      rdy_pct = i % 5 == 0 ? 100 : i % 5 == 1 ? 30 : 70;
      run_vec(i);
    end
    gap = 0; rdy_pct = 100;
    for (int i = 0; i < NL; i++) begin run_long(i, 1'b0); run_long(i, 1'b1); end
    error_cases();
    // clr in each phase: H, E(K, J0), first key stream block, AAD, text, output held, the end
    for (int t = 1; t <= 90; t++) begin
      clr_case(t, 1, 1, 1'b1, t % 2);
      if (t <= 30) clr_case(t, 1, 1, 1'b0, !(t % 2));
    end
    clr_case(60, 0, 3, 1'b1, 1'b0);
    // clr while the tag is computed (t + 1000: done may come first)
    for (int t = 33; t <= 46; t++) clr_case(t + 1000, 0, 1, 1'b0, 1'b0);
    // clr and start in the same clock: clr wins
    @(negedge clk); clr = 1'b1; start = 1'b1;
    @(negedge clk); clr = 1'b0; start = 1'b0;
    if (busy) fail("start with clr");
    // start while busy is ignored: run case 0 with a second start in the middle
    fork
      run_vec(1);
      begin repeat (30) @(negedge clk); start = 1'b1; key = '1; iv = '1; @(negedge clk); start = 1'b0; end
    join
    // back to back: start in the clock after done
    run_vec(2);
    run_vec(3);
    // reset in the middle of a message
    quick(0, $urandom);
    fold_mode = 1'b0;
    send(r128(), 16, 1'b1, 1'b0);
    send(r128(), 16, 1'b0, 1'b0);
    rst_n = 1'b0;
    repeat (2) @(negedge clk);
    if (busy || out_valid || done || err || tag !== 0 || tag_ok || err_code != 0) fail("outputs in reset");
    rst_n = 1'b1;
    run_vec(NV - 2);                      // with AAD: txt and apart must reset
    repeat (5) @(negedge clk);
    $display("%0d cases, %0d errors", nvec, errors);
    if (errors == 0) $display("TEST PASSED: AES_GCM");
    else $display("TEST FAILED: AES_GCM");
    $finish;
  end
  initial begin
    #500ms;
    $display("TEST FAILED: AES_GCM timeout");
    $finish;
  end
endmodule
