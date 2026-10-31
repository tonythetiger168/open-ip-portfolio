// SPDX-License-Identifier: Apache-2.0
// Ethernet_RS_FEC_top testbench.
//  1. Vectors (tb/Ethernet_RS_FEC_vec.hex, scripts/ethfec/gen_vec.py from the
//     reference model, whose encoder matches reedsolo): every message is
//     encoded and compared with the reference codeword, every received word
//     decoded and compared with the reference output, flag and symbol count.
//  2. Loopback: random messages through the encoder, random symbol errors
//     (0..15 corrected, 16..40 uncorrectable) into the decoder, compared with
//     the encoder's codeword; back-to-back codewords at full rate (the output
//     must come out back-to-back too, at a fixed latency), random input gaps
//     and output back-pressure, correction and indication bypass.
//  3. Realignment: *_first in the middle of a codeword (the codeword is
//     dropped, ev_*resync), and a reset with codewords in flight.
`timescale 1ns/1ps
module Ethernet_RS_FEC_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  logic         cfg_bypass_corr = 0, cfg_bypass_ind = 0;
  logic         e_in_valid = 0, e_in_first = 0, e_out_ready = 1;
  logic [319:0] e_in_data = 0;
  logic         d_in_valid = 0, d_in_first = 0, d_out_ready = 1;
  logic [319:0] d_in_data = 0;
  wire          e_in_ready, e_out_valid, e_out_first, d_in_ready, d_out_valid, d_out_first, d_out_bad;
  wire  [319:0] e_out_data, d_out_data;
  wire          ev_corr, ev_uncorr, ev_eresync, ev_dresync;
  wire  [3:0]   st_nsym;
  Ethernet_RS_FEC_top dut (.*);

  function automatic logic [319:0] rnd320();
    logic [319:0] r;
    for (int i = 0; i < 10; i++) r[32*i +: 32] = $urandom;
    return r;
  endfunction

  // ---------------- drivers (a beat is taken on the rising edge) ----------------
  int e_gap = 0, d_gap = 0, bp = 0;             // % idle clocks, % output stalls
  task automatic e_beat(input logic [319:0] d, input bit f);
    while ($urandom_range(0, 99) < e_gap) @(negedge clk);
    @(negedge clk); e_in_valid = 1; e_in_data = d; e_in_first = f; #1;
    while (!e_in_ready) begin @(negedge clk); #1; end
    @(posedge clk); #1 e_in_valid = 0; e_in_first = 0;
  endtask
  task automatic d_beat(input logic [319:0] d, input bit f);
    while ($urandom_range(0, 99) < d_gap) @(negedge clk);
    @(negedge clk); d_in_valid = 1; d_in_data = d; d_in_first = f; #1;
    while (!d_in_ready) begin @(negedge clk); #1; end
    @(posedge clk); #1 d_in_valid = 0; d_in_first = 0;
  endtask
  always @(negedge clk) begin
    e_out_ready = $urandom_range(0, 99) >= bp;
    d_out_ready = $urandom_range(0, 99) >= bp;
  end

  // a message (514 symbols in the low bits) as 17 beats; the 30 unused
  // symbols of the last beat are random (the encoder must ignore them)
  task automatic encode(input logic [5439:0] m, input bit f0);
    logic [319:0] r;
    r = rnd320();
    for (int b = 0; b < 17; b++)
      e_beat(b < 16 ? m[320*b +: 320] : {r[319:20], m[5139:5120]}, b == 0 && f0);
  endtask
  task automatic decode(input logic [5439:0] c, input bit f0);
    for (int b = 0; b < 17; b++) d_beat(c[320*b +: 320], b == 0 && f0);
  endtask

  // ---------------- monitors ----------------
  logic [5439:0] e_got [$];                     // encoder codewords out
  logic [5439:0] eacc, dacc;
  int            ebc = 0, dbc = 0;
  always @(posedge clk) if (rst_n && e_out_valid && e_out_ready) begin
    if (e_out_first) ebc = 0;
    eacc[320*ebc +: 320] = e_out_data;
    ebc++;
    if (ebc == 17) begin e_got.push_back(eacc); ebc = 0; end
  end

  logic [5440:0] d_exp [$];                     // {bad, data} expected
  logic [5:0]    v_exp [$];                     // {corr, uncorr, nsym} expected events
  int            n_dec = 0, n_corr = 0, n_unc = 0, n_ers = 0, n_drs = 0, n_sym = 0;
  logic          dbad;
  logic [5440:0] dx;
  logic [5:0]    vx;
  always @(posedge clk) if (rst_n && d_out_valid && d_out_ready) begin
    if (d_out_first != (dbc == 0)) fail($sformatf("d_out_first %b at beat %0d", d_out_first, dbc));
    if (dbc == 0) dbad = d_out_bad;
    else if (d_out_bad != dbad) fail("d_out_bad changes inside a codeword");
    dacc[320*dbc +: 320] = d_out_data;
    dbc++;
    if (dbc == 17) begin
      dbc = 0; n_dec++;
      if (d_exp.size() == 0) fail("decoder: unexpected codeword");
      else begin
        dx = d_exp.pop_front();
        if (dx[5440] != dbad) fail($sformatf("decoder codeword %0d: bad %b want %b", n_dec, dbad, dx[5440]));
        if (dx[5439:0] != dacc) begin
          fail($sformatf("decoder codeword %0d: data mismatch", n_dec));
          for (int i = 0; i < 544; i++)
            if (dx[10*i +: 10] != dacc[10*i +: 10])
              $display("   symbol %0d: got %h want %h", i, dacc[10*i +: 10], dx[10*i +: 10]);
        end
      end
    end
  end
  bit ign_ev = 0;                               // random words in flight at the reset
  always @(posedge clk) if (rst_n && !ign_ev) begin
    if (ev_eresync) n_ers++;
    if (ev_dresync) n_drs++;
    if (ev_corr || ev_uncorr) begin
      if (ev_corr) begin n_corr++; n_sym += int'(st_nsym); end
      if (ev_uncorr) n_unc++;
      if (v_exp.size() == 0) fail("unexpected event");
      else begin
        vx = v_exp.pop_front();
        if (vx != {ev_corr, ev_uncorr, st_nsym})
          fail($sformatf("events {corr, uncorr, nsym} %b %b %0d want %b %b %0d", ev_corr, ev_uncorr, st_nsym,
                         vx[5], vx[4], vx[3:0]));
      end
    end
  end

  // ---------------- expected decoder results ----------------
  // a received word with ne symbol errors (ne <= 15 correctable; the rare
  // miscorrection of a word with more is not expected with these seeds)
  task automatic expect_dec(input logic [5439:0] cw, input logic [5439:0] rx, input int ne);
    bit bad, fix;
    bad = cfg_bypass_corr ? ne != 0 : ne > 15;
    fix = !cfg_bypass_corr && ne <= 15;
    d_exp.push_back({bad && !cfg_bypass_ind, fix ? cw : rx});
    if (fix && ne != 0) v_exp.push_back({2'b10, 4'(ne)});
    else if (bad) v_exp.push_back({2'b01, 4'd0});
  endtask
  bit used [0:543];
  task automatic corrupt(input logic [5439:0] cw, input int ne, output logic [5439:0] rx);
    int p;
    rx = cw;
    for (int i = 0; i < 544; i++) used[i] = 0;
    for (int i = 0; i < ne; i++) begin
      p = $urandom_range(0, 543);
      while (used[p]) p = $urandom_range(0, 543);
      used[p] = 1;
      rx[10*p +: 10] = rx[10*p +: 10] ^ 10'($urandom_range(1, 1023));
    end
  endtask
  task automatic drain();
    int n;
    n = 0;
    while (n < 120) begin
      @(negedge clk);
      if (d_out_valid || e_out_valid) n = 0; else n++;
    end
    if (d_exp.size() != 0) fail($sformatf("%0d decoder codewords missing", d_exp.size()));
    if (v_exp.size() != 0) fail($sformatf("%0d events missing", v_exp.size()));
  endtask
  function automatic int pick_ne(input int hi);
    int r;
    r = $urandom_range(0, 99);
    if (r < 10) return 0;
    if (r < 75) return $urandom_range(1, 15);
    if (r < 85) return 15;
    return $urandom_range(16, hi);
  endfunction

  // ---------------- vectors ----------------
  logic [9:0] vec [0:60000];
  int vp = 0, nvec = 0;
  task automatic vec_cases();
    logic [5439:0] m, cw, rx, ex;
    logic [9:0]    h;
    h = vec[vp];
    while (h != 10'h3ff) begin
      m = '0;
      for (int i = 0; i < 514; i++) m[10*i +: 10] = vec[vp + 1 + i];
      for (int i = 0; i < 544; i++) begin
        cw[10*i +: 10] = vec[vp + 515 + i];
        rx[10*i +: 10] = vec[vp + 1059 + i];
        ex[10*i +: 10] = vec[vp + 1603 + i];
      end
      vp += 2147;
      encode(m, 1);
      while (e_got.size() == 0) @(posedge clk);
      if (e_got[0] != cw) fail($sformatf("encoder vector %0d mismatch", nvec));
      void'(e_got.pop_front());
      d_exp.push_back({h[4], ex});
      if (h[4]) v_exp.push_back({2'b01, 4'd0});
      else if (h[3:0] != 0) v_exp.push_back({2'b10, h[3:0]});
      decode(rx, 1);
      nvec++;
      h = vec[vp];
    end
    drain();
  endtask

  // ---------------- loopback ----------------
  task automatic loop(input int n, input int hi);
    logic [5439:0] m, cw, rx;
    int ne;
    for (int i = 0; i < n; i++) begin
      for (int b = 0; b < 17; b++) m[320*b +: 320] = rnd320();
      encode(m, 1'($urandom_range(0, 1)));
      while (e_got.size() == 0) @(posedge clk);
      cw = e_got.pop_front();
      if (cw[5139:0] != m[5139:0]) fail("encoder: message not passed through");
      ne = pick_ne(hi);
      corrupt(cw, ne, rx);
      expect_dec(cw, rx, ne);
      decode(rx, 1'($urandom_range(0, 1)));
    end
    drain();
  endtask

  // back-to-back codewords: the decoder output must be back-to-back too
  int lat0 = -1;
  task automatic burst(input int n);
    logic [5439:0] cws [0:19];
    logic [5439:0] m, rx;
    int ne, t_last, t_first, run;
    for (int i = 0; i < n; i++) begin
      for (int b = 0; b < 17; b++) m[320*b +: 320] = rnd320();
      encode(m, i == 0);
      while (e_got.size() == 0) @(posedge clk);
      cws[i] = e_got.pop_front();
    end
    t_first = -1; run = 0;
    fork
      for (int i = 0; i < n; i++) begin
        ne = pick_ne(30);
        corrupt(cws[i], ne, rx);
        expect_dec(cws[i], rx, ne);
        decode(rx, 0);
      end
      begin : b_mon
        int t;
        t = 0;
        while (t_first < 0 || run < 17 * n) begin
          @(posedge clk); t++;
          if (d_in_valid && d_in_ready) t_last = t;
          if (d_out_valid) begin
            if (t_first < 0) t_first = t;
            run++;
          end else if (t_first >= 0 && run < 17 * n) fail($sformatf("burst: output gap after %0d beats", run));
        end
      end
    join
    // first beat out vs the last beat of the first codeword in (16 clocks after its first)
    if (lat0 < 0) begin
      lat0 = t_first - (t_last - 17 * (n - 1));
      $display("decoder latency: %0d clocks from the last beat in to the first beat out", lat0);
    end
    drain();
  endtask

  // a partial codeword, then a full one starting with *_first
  task automatic resync();
    logic [5439:0] m, cw;
    int b0, b1;
    b0 = n_ers; b1 = n_drs;
    for (int b = 0; b < 17; b++) m[320*b +: 320] = rnd320();
    for (int b = 0; b < 5; b++) e_beat(m[320*b +: 320], b == 0);
    encode(m, 1);
    while (e_got.size() == 0) @(posedge clk);
    cw = e_got.pop_front();
    for (int b = 0; b < 9; b++) d_beat(cw[320*b +: 320], b == 0);
    expect_dec(cw, cw, 0);
    decode(cw, 1);
    drain();
    if (n_ers != b0 + 1 || n_drs != b1 + 1) fail($sformatf("resync events %0d %0d", n_ers - b0, n_drs - b1));
  endtask

  initial begin
    if ($fopen("tb/Ethernet_RS_FEC_vec.hex", "r") != 0) $readmemh("tb/Ethernet_RS_FEC_vec.hex", vec);
    else if ($fopen("../tb/Ethernet_RS_FEC_vec.hex", "r") != 0) $readmemh("../tb/Ethernet_RS_FEC_vec.hex", vec);
    else $readmemh("../../../../tb/Ethernet_RS_FEC_vec.hex", vec);
    repeat (3) @(negedge clk);
    rst_n = 1;
    vec_cases();
    $display("vectors: %0d cases", nvec);
    burst(20);
    e_gap = 30; d_gap = 30; bp = 30;
    loop(`ifdef VERILATOR 120 `else 30 `endif, 40);
    e_gap = 0; d_gap = 0; bp = 0;
    cfg_bypass_ind = 1;
    loop(20, 30);
    cfg_bypass_corr = 1;
    loop(15, 20);
    cfg_bypass_ind = 0;
    loop(15, 20);
    cfg_bypass_corr = 0;
    resync();
    bp = 50;
    burst(6);
    bp = 0;
    // reset with codewords in flight (random words: their events are not checked)
    ign_ev = 1;
    fork
      begin
        logic [5439:0] m;
        for (int b = 0; b < 17; b++) m[320*b +: 320] = rnd320();
        encode(m, 1);
        encode(m, 0);
      end
      begin
        repeat (8) @(posedge clk);
        decode({17{rnd320()}}, 1);
        decode({17{rnd320()}}, 0);
      end
      begin
        repeat (70) @(negedge clk);
        rst_n = 0;
      end
    join
    @(negedge clk);
    e_got.delete(); d_exp.delete(); v_exp.delete(); ebc = 0; dbc = 0; ign_ev = 0;
    rst_n = 1;
    loop(10, 30);
    if (errors == 0)
      $display("TEST PASSED: Ethernet_RS_FEC (%0d codewords decoded, %0d corrected / %0d symbols, %0d uncorrectable)",
               n_dec, n_corr, n_sym, n_unc);
    else $display("TEST FAILED: Ethernet_RS_FEC (%0d errors)", errors);
    $finish;
  end

  initial begin
    #50ms;
    $display("TEST FAILED: Ethernet_RS_FEC (timeout)");
    $finish;
  end
endmodule
