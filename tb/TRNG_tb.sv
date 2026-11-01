// SPDX-License-Identifier: Apache-2.0
// TRNG_tb: self-checking testbench. The ring oscillator inputs are driven by
// a noise model (random bits, a stuck source, or runs of ones and zeros);
// the output is read with random back-pressure. A model in the testbench
// runs the SP 800-90B health tests on every raw sample the core puts out and
// predicts each failure, the alert flags, the failure counters and the
// high-water marks; it collects the samples the core takes into a seed and
// hashes them with its own SHA-256 (checked first against hashlib vectors
// from scripts/trng/gen_vec.py), and compares every output word and its FIPS
// flag. Then the failure cases in every state, the forced-failure cutoffs,
// counter saturation, en dropped in every state and a reset mid-output.
`timescale 1ns/1ps
module TRNG_tb;
  logic        clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  logic [3:0]  ro_in = 4'h0;
  logic        en = 1'b0, src_sel = 1'b0, cond_bypass = 1'b0;
  logic [1:0]  cond_blks = 2'd1;
  logic [7:0]  smp_div = 8'd0, rct_cutoff = 8'd41;
  logic [10:0] apt_cutoff = 11'd793;
  logic [31:0] lfsr_seed = 32'h1;
  logic        ent_valid, ent_ready = 1'b1, ent_fips, seed_rdy, raw_valid, raw_bit, es_ok, es_fips;
  logic        alert, alert_rct, alert_apt;
  logic [31:0] ent_data;
  logic [2:0]  state;
  logic [7:0]  rct_fails, apt_fails, rct_hw;
  logic [10:0] apt_hw;

  TRNG_top u_dut (.*);

  `include "TRNG_vec.svh"
  localparam logic [2:0] S_IDLE = 0, S_START = 1, S_RUN = 2, S_HASH = 3, S_OUT = 4, S_FAIL = 5;
  localparam int W = 1024;

  int errors = 0;
  task automatic fail(input string m);
    $display("ERROR @%0t: %s", $time, m); errors++;
  endtask

  // ---------------- SHA-256 (FIPS 180-4) ----------------
  localparam logic [32*64-1:0] K = {
    32'h428a2f98, 32'h71374491, 32'hb5c0fbcf, 32'he9b5dba5, 32'h3956c25b, 32'h59f111f1, 32'h923f82a4, 32'hab1c5ed5,
    32'hd807aa98, 32'h12835b01, 32'h243185be, 32'h550c7dc3, 32'h72be5d74, 32'h80deb1fe, 32'h9bdc06a7, 32'hc19bf174,
    32'he49b69c1, 32'hefbe4786, 32'h0fc19dc6, 32'h240ca1cc, 32'h2de92c6f, 32'h4a7484aa, 32'h5cb0a9dc, 32'h76f988da,
    32'h983e5152, 32'ha831c66d, 32'hb00327c8, 32'hbf597fc7, 32'hc6e00bf3, 32'hd5a79147, 32'h06ca6351, 32'h14292967,
    32'h27b70a85, 32'h2e1b2138, 32'h4d2c6dfc, 32'h53380d13, 32'h650a7354, 32'h766a0abb, 32'h81c2c92e, 32'h92722c85,
    32'ha2bfe8a1, 32'ha81a664b, 32'hc24b8b70, 32'hc76c51a3, 32'hd192e819, 32'hd6990624, 32'hf40e3585, 32'h106aa070,
    32'h19a4c116, 32'h1e376c08, 32'h2748774c, 32'h34b0bcb5, 32'h391c0cb3, 32'h4ed8aa4a, 32'h5b9cca4f, 32'h682e6ff3,
    32'h748f82ee, 32'h78a5636f, 32'h84c87814, 32'h8cc70208, 32'h90befffa, 32'ha4506ceb, 32'hbef9a3f7, 32'hc67178f2};
  function automatic logic [31:0] rotr(input logic [31:0] x, input int n);
    rotr = (x >> n) | (x << (32 - n));
  endfunction
  function automatic logic [255:0] compress(input logic [255:0] h, input logic [511:0] m);
    logic [31:0] w [0:63];
    logic [31:0] a, b, c, d, e, f, g, hh, x, y;
    for (int t = 0; t < 16; t++) w[t] = m[32 * (15 - t) +: 32];
    for (int t = 16; t < 64; t++)
      w[t] = (rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)) + w[t - 7]
             + (rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)) + w[t - 16];
    a = h[255:224]; b = h[223:192]; c = h[191:160]; d = h[159:128];
    e = h[127:96]; f = h[95:64]; g = h[63:32]; hh = h[31:0];
    for (int t = 0; t < 64; t++) begin
      x = hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[32 * (63 - t) +: 32] + w[t];
      y = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
      hh = g; g = f; f = e; e = d + x; d = c; c = b; b = a; a = x + y;
    end
    compress = {h[255:224] + a, h[223:192] + b, h[191:160] + c, h[159:128] + d,
                h[127:96] + e, h[95:64] + f, h[63:32] + g, h[31:0] + hh};
  endfunction
  // SHA-256 of the n * 512 bits in the low bits of m (first bit at the top)
  function automatic logic [255:0] sha256(input logic [2047:0] m, input int n);
    logic [255:0] h;
    logic [511:0] b;
    h = {32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a, 32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};
    for (int j = 0; j <= n; j++) begin
      if (j < n) b = m[512 * (n - 1 - j) +: 512];
      else b = {32'h8000_0000, 416'd0, 64'(n * 512)};
      h = compress(h, b);
    end
    sha256 = h;
  endfunction

  // ---------------- noise source and output stimulus ----------------
  int ro_mode = 0;                      // 0 random, 1 stuck, 2 runs of run1 ones and run0 zeros
  int run1 = 3, run0 = 2, rpos = 0;
  int rdy_mode = 0;                     // 0 ready, 1 random, 2 held low
  always @(negedge clk) begin
    logic b;
    logic [2:0] r;
    r = 3'($urandom);
    case (ro_mode)
      0: b = 1'($urandom);
      1: b = 1'b0;
      default: begin
        b = rpos < run1;
        rpos = rpos + 1 >= run1 + run0 ? 0 : rpos + 1;
      end
    endcase
    ro_in <= {r, b ^ (^r)};             // the core samples the XOR of the four
    ent_ready <= rdy_mode == 0 ? 1'b1 : rdy_mode == 1 ? 1'($urandom) : 1'b0;
  end

  // ---------------- reference model ----------------
  logic [2:0]  st_q = S_IDLE;
  int          m_rn, m_ac, m_ai, m_rhw, m_ahw, m_rf = 0, m_af = 0;
  logic        m_ra, m_aa;
  bit          m_alr, m_ala;
  bit          pend = 0, pend_f, pend_en;
  bit          cfg_byp, cfg_fips, byp_q, src_q, cfg_src = 0;
  logic        rh0 = 0, rh1 = 0, rh2 = 0;
  int          nb_q;
  int          cfg_nblk;
  logic [2047:0] cbuf;
  int          cn;
  logic [31:0] expw [0:63];
  bit          expf [0:63];
  int          eh = 0, et = 0;
  int          nwords = 0, nseeds = 0, nrdy = 0, nsmp = 0, nfail = 0;
  function automatic bit live(input logic [2:0] s);
    live = s == S_START || s == S_RUN || s == S_HASH || s == S_OUT;
  endfunction
  task automatic push(input logic [31:0] w, input bit f);
    expw[et % 64] = w; expf[et % 64] = f; et++;
  endtask
  always @(negedge clk) begin
    #1;
    // a ring oscillator sample is the XOR of the inputs three clocks before
    // (two synchronizer flops, then the sample register; 0 from reset)
    if (raw_valid && !cfg_src && raw_bit != rh2) fail("raw sample is not the synchronized ring oscillator XOR");
    rh2 = rh1; rh1 = rh0; rh0 = rst_n ? ^ro_in : 1'b0;
    if (!rst_n) begin
      pend = 0; eh = 0; et = 0; cn = 0; m_rf = 0; m_af = 0; m_alr = 0; m_ala = 0; m_rhw = 0; m_ahw = 0;
      if (state != S_IDLE || alert || alert_rct || alert_apt || raw_valid || ent_valid || seed_rdy || rct_hw != 0)
        fail("outputs in reset");
    end else begin
      // the outcome of the sample of the previous clock
      if (pend) begin
        if (pend_f && pend_en) begin
          if (state != S_FAIL || !alert) fail("health test failure not flagged");
        end else if (state == S_FAIL && st_q != S_FAIL) fail("unexpected health test failure");
      end
      pend = 0;
      if (st_q == S_IDLE && state == S_START) begin
        m_rn = 0; m_ai = 0; m_ac = 0; m_rhw = 0; m_ahw = 0; m_alr = 0; m_ala = 0;
        // the configuration at the clock en rose (seen at the previous monitor step)
        cfg_byp = byp_q; cfg_src = src_q; cfg_fips = !src_q && !byp_q; cfg_nblk = nb_q + 1; cn = 0;
      end
      if (!live(state)) begin eh = et; cn = 0; end
      if (rct_hw != 8'(m_rhw) || apt_hw != 11'(m_ahw)) fail($sformatf("high-water marks %0d %0d, expected %0d %0d",
                                                                      rct_hw, apt_hw, m_rhw, m_ahw));
      if (rct_fails != 8'(m_rf) || apt_fails != 8'(m_af)) fail("failure counters");
      if (alert_rct != m_alr || alert_apt != m_ala) fail("sticky alert flags");
      if (raw_valid && !live(state)) fail("raw sample while stopped");
      if (es_ok != (state == S_RUN || state == S_HASH || state == S_OUT)) fail("es_ok");
      if (es_fips != (es_ok && cfg_fips)) fail("es_fips");
      if (ent_valid != (state == S_OUT)) fail("ent_valid");
      if (ent_valid && eh == et) fail("output with no seed expected");
      if (!ent_valid && (ent_data != 0 || ent_fips)) fail("output data while not valid");
      if (seed_rdy != (state == S_OUT && st_q != S_OUT)) fail("seed_rdy");
      if (seed_rdy) nrdy++;
      // the sample the core takes at the next clock
      if (raw_valid && live(state)) begin
        int rnx, anx;
        bit fr, fa;
        nsmp++;
        rnx = m_rn != 0 && raw_bit == m_ra ? m_rn + 1 : 1;
        anx = m_ai == 0 ? 1 : m_ac + (raw_bit == m_aa);
        fr = rnx >= rct_cutoff;
        fa = anx >= apt_cutoff;
        m_ra = raw_bit; m_rn = rnx;
        if (m_ai == 0) m_aa = raw_bit;
        m_ac = anx; m_ai = (m_ai + 1) % W;
        if (rnx > m_rhw) m_rhw = rnx;
        if (anx > m_ahw) m_ahw = anx;
        pend = 1; pend_f = fr || fa; pend_en = en;
        if ((fr || fa) && en) begin
          nfail++;
          if (fr) begin m_alr = 1; if (m_rf < 255) m_rf++; end
          if (fa) begin m_ala = 1; if (m_af < 255) m_af++; end
        end
        if (!(fr || fa) && en && state == S_RUN) begin
          cbuf = {cbuf[2046:0], raw_bit};
          cn++;
          if (cfg_byp && cn == 32) begin push(cbuf[31:0], 0); cn = 0; nseeds++; end
          else if (!cfg_byp && cn == 512 * cfg_nblk) begin
            logic [255:0] d;
            d = sha256(cbuf, cfg_nblk);
            for (int i = 0; i < 8; i++) push(d[32 * (7 - i) +: 32], cfg_fips);
            cn = 0; nseeds++;
          end
        end
        if (ent_valid && ent_ready && en && !(fr || fa)) begin
          if (ent_data != expw[eh % 64] || ent_fips != expf[eh % 64])
            fail($sformatf("output word %h fips %0d, expected %h %0d", ent_data, ent_fips, expw[eh % 64], expf[eh % 64]));
          eh++; nwords++;
        end
      end else if (ent_valid && ent_ready && en) begin
        if (ent_data != expw[eh % 64] || ent_fips != expf[eh % 64])
          fail($sformatf("output word %h fips %0d, expected %h %0d", ent_data, ent_fips, expw[eh % 64], expf[eh % 64]));
        eh++; nwords++;
      end
      st_q = state; byp_q = cond_bypass; src_q = src_sel; nb_q = cond_blks;
    end
  end

  // ---------------- helpers ----------------
  task automatic cycles(input int n);
    repeat (n) @(negedge clk);
  endtask
  task automatic do_reset;
    @(negedge clk); rst_n = 1'b0; en = 1'b0;
    cycles(3);
    rst_n = 1'b1;
    st_q = S_IDLE;
    cycles(2);
  endtask
  task automatic start(input bit src, input bit byp, input logic [1:0] nb, input logic [7:0] div,
                       input logic [31:0] seed);
    @(negedge clk); en = 1'b0;
    cycles(2);
    src_sel = src; cond_bypass = byp; cond_blks = nb; smp_div = div; lfsr_seed = seed;
    en = 1'b1;
    cycles(1);
    // configuration is taken when en rises: changing it now has no effect
    src_sel = ~src; cond_bypass = ~byp; cond_blks = ~nb;
  endtask
  task automatic wait_state(input logic [2:0] s, input int tmo);
    int n;
    n = 0;
    while (state != s && n < tmo) begin @(negedge clk); n++; end
    if (state != s) fail($sformatf("timeout waiting for state %0d (in %0d)", s, state));
  endtask
  task automatic wait_words(input int k, input int tmo);
    int n, w0;
    n = 0; w0 = nwords;
    while (nwords < w0 + k && n < tmo) begin @(negedge clk); n++; end
    if (nwords < w0 + k) fail($sformatf("timeout waiting for %0d words (state %0d)", k, state));
  endtask

  initial begin
    // ---- the testbench SHA-256 against hashlib
    for (int i = 0; i < NKAT; i++)
      if (sha256(kat_msg(i), int'(kat_n(i))) != kat_dig(i)) fail($sformatf("SHA-256 vector %0d", i));
    do_reset();
    if (state != S_IDLE || ent_valid || raw_valid || alert || alert_rct || alert_apt || es_ok || rct_fails != 0
        || apt_fails != 0 || ent_data != 0) fail("reset values");

    // ---- conditioned seeds from the test LFSR, every block count, random back-pressure
    rdy_mode = 1;
    for (int nb = 0; nb < 4; nb++) begin
      start(1, 0, 2'(nb), 8'd0, $urandom | 32'h1);
      wait_words(24, 200000);
      if (ent_fips) fail("LFSR seed marked FIPS");
    end
    // ---- from the ring oscillators, slower sampling; FIPS flagged
    rdy_mode = 0;
    start(0, 0, 2'd1, 8'd1, 32'h0);
    wait_state(S_OUT, 100000);
    if (!ent_fips) fail("ring oscillator seed not marked FIPS");
    wait_words(16, 200000);
    start(0, 0, 2'd0, 8'd3, 32'h0);
    wait_words(16, 200000);
    // ---- bypass (raw words), both sources
    rdy_mode = 1;
    start(0, 1, 2'd0, 8'd0, 32'h0);
    wait_words(40, 100000);
    start(1, 1, 2'd2, 8'd2, 32'hFFFF_FFFF);
    wait_words(40, 100000);
    // ---- the slowest sampling rate
    start(0, 1, 2'd0, 8'd255, 32'h0);
    wait_words(1, 400000);
    rdy_mode = 0;

    // ---- repetition count failure in each state
    ro_mode = 1;                                            // stuck from the start
    start(0, 0, 2'd1, 8'd0, 32'h0);
    wait_state(S_FAIL, 1000);
    if (!alert_rct || alert_apt) fail("start-up RCT failure flags");
    cycles(20);
    if (ent_valid || es_ok) fail("output after a failure");
    ro_mode = 0;
    start(0, 0, 2'd1, 8'd0, 32'h0);
    wait_state(S_RUN, 5000);
    cycles(100);
    ro_mode = 1;                                            // in RUN
    wait_state(S_FAIL, 1000);
    ro_mode = 0;
    start(0, 0, 2'd0, 8'd0, 32'h0);
    wait_state(S_HASH, 5000);
    ro_mode = 1;                                            // in HASH
    wait_state(S_FAIL, 1000);
    ro_mode = 0;
    rdy_mode = 2;
    start(0, 0, 2'd0, 8'd0, 32'h0);
    wait_state(S_OUT, 5000);
    ro_mode = 1;                                            // in OUT, while the seed waits
    wait_state(S_FAIL, 1000);
    ro_mode = 0;
    rdy_mode = 0;
    // ---- adaptive proportion failure: 60% ones in runs of three, no long run
    ro_mode = 2; run1 = 3; run0 = 2;
    apt_cutoff = 11'd600;
    start(0, 0, 2'd1, 8'd0, 32'h0);
    wait_state(S_FAIL, 5000);
    if (alert_rct || !alert_apt) fail("APT failure flags");
    // the same source passes at the H = 0.5 cutoff (the APT is in RUN, HASH and OUT too)
    apt_cutoff = 11'd793;
    start(0, 0, 2'd0, 8'd0, 32'h0);
    wait_words(16, 50000);
    apt_cutoff = 11'd600;                                   // and fails later on, while running
    wait_state(S_FAIL, 5000);
    apt_cutoff = 11'd793;
    ro_mode = 0;
    // an APT cutoff lowered to 2 fails within a few samples: in RUN, HASH and OUT
    for (int s = 2; s <= 4; s++) begin
      rdy_mode = s == 4 ? 2 : 0;
      start(0, 0, 2'd0, 8'd0, 32'h0);
      wait_state(3'(s), 5000);
      if (s == 2) cycles(20);
      apt_cutoff = 11'd2;
      wait_state(S_FAIL, 100);
      apt_cutoff = 11'd793;
      if (alert_rct || !alert_apt) fail("APT failure in a running state");
    end
    rdy_mode = 0;
    // ---- long runs: high-water marks near their limits (RCT 250, APT ~1020)
    ro_mode = 2; run1 = 250; run0 = 1;
    rct_cutoff = 8'd255; apt_cutoff = 11'd2047;
    start(0, 0, 2'd0, 8'd0, 32'h0);
    wait_words(8, 10000);
    if (rct_hw != 8'd250 || apt_hw < 11'd1000) fail("high-water marks after long runs");
    rct_cutoff = 8'd200;                                    // a lowered cutoff applies at once
    wait_state(S_FAIL, 1000);
    rct_cutoff = 8'd41; apt_cutoff = 11'd793;
    ro_mode = 0;
    // ---- forced failures: cutoff 0 and 1, both tests at once; the counters saturate
    rct_cutoff = 8'd0;
    start(0, 0, 2'd1, 8'd0, 32'h0);
    wait_state(S_FAIL, 100);
    rct_cutoff = 8'd1;
    for (int i = 0; i < 260; i++) begin start(1, 0, 2'd1, 8'd0, 32'h5); wait_state(S_FAIL, 100); end
    if (rct_fails != 8'hFF) fail("RCT failure counter does not saturate");
    rct_cutoff = 8'd41; apt_cutoff = 11'd1;
    for (int i = 0; i < 260; i++) begin start(0, 0, 2'd1, 8'd0, 32'h0); wait_state(S_FAIL, 100); end
    if (apt_fails != 8'hFF) fail("APT failure counter does not saturate");
    rct_cutoff = 8'd1;
    start(0, 0, 2'd1, 8'd0, 32'h0);
    wait_state(S_FAIL, 100);
    if (!alert_rct || !alert_apt) fail("both tests failing together");
    rct_cutoff = 8'd41; apt_cutoff = 11'd793;
    // a zero LFSR seed is a stuck source
    start(1, 0, 2'd1, 8'd0, 32'h0);
    wait_state(S_FAIL, 1000);
    // ---- recovery: a good source runs again after en is raised again
    start(0, 0, 2'd1, 8'd0, 32'h0);
    wait_words(8, 50000);
    if (alert_rct || alert_apt) fail("alert flags not cleared on restart");

    // ---- en dropped in every state
    start(0, 0, 2'd0, 8'd0, 32'h0);
    cycles(50); en = 1'b0;                                  // START
    cycles(3);
    if (state != S_IDLE) fail("en dropped in START");
    start(0, 0, 2'd0, 8'd0, 32'h0);
    wait_state(S_RUN, 5000); cycles(30); en = 1'b0;
    cycles(3);
    start(0, 0, 2'd0, 8'd0, 32'h0);
    wait_state(S_HASH, 5000); cycles(10); en = 1'b0;
    cycles(3);
    rdy_mode = 2;
    start(0, 0, 2'd0, 8'd0, 32'h0);
    wait_state(S_OUT, 5000); cycles(10); en = 1'b0;
    cycles(3);
    if (ent_valid || u_dut.dig != '0 || u_dut.blk != '0) fail("buffers not cleared after en dropped");
    rdy_mode = 0;
    rct_cutoff = 8'd1;
    start(0, 0, 2'd0, 8'd0, 32'h0);
    wait_state(S_FAIL, 100); en = 1'b0;
    cycles(3);
    rct_cutoff = 8'd41;
    // ---- en held high through a reset: the core starts as reset ends
    src_sel = 1'b0; cond_bypass = 1'b1; cond_blks = 2'd0; smp_div = 8'd0;
    @(negedge clk); rst_n = 1'b0; en = 1'b1;
    cycles(3);
    rst_n = 1'b1;
    st_q = S_IDLE;
    @(negedge clk); #2;
    if (state != S_START) fail("not started with en high out of reset");
    wait_words(4, 5000);
    // ---- reset in the middle of an output
    rdy_mode = 2;
    start(1, 0, 2'd0, 8'd0, 32'h77);
    wait_state(S_OUT, 5000);
    do_reset();
    if (ent_valid || state != S_IDLE || rct_fails != 0 || u_dut.dig != '0) fail("state after a reset mid-output");
    rdy_mode = 0;
    start(1, 0, 2'd0, 8'd0, 32'h77);
    wait_words(8, 50000);
    en = 1'b0;
    cycles(5);

    $display("TRNG: %0d samples, %0d seeds / raw words collected, %0d output, %0d words checked, %0d health failures",
             nsmp, nseeds, nrdy, nwords, nfail);
    if (errors == 0) $display("TEST PASSED: TRNG");
    else $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin
    #200ms;
    $display("TEST FAILED: watchdog");
    $finish;
  end
endmodule
