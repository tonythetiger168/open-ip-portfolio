// SPDX-License-Identifier: Apache-2.0
// TRNG: concurrent SVA against a cycle model built from the ports, plus
// functional coverage. The model
//  * synchronizes the XOR of the ring oscillator inputs, runs its own test
//    LFSR and sample divider, and predicts every raw sample;
//  * runs the SP 800-90B repetition count and adaptive proportion tests on
//    the predicted samples, and from them every failure, alert flag, failure
//    counter and high-water mark;
//  * follows the control flow (start-up window, collection, hashing time,
//    output, failure, en dropped), collects the samples a seed is made of
//    and hashes them with its own SHA-256 (round constants and initial value
//    computed from the cube and square roots of the first primes, as FIPS
//    180-4 defines them), and compares every output word and flag.
// It also checks that the collection and hash registers hold no sample data
// whenever the core is not collecting or hashing.
`include "cov_macros.svh"
module TRNG_sva #(parameter int NRO = 4, parameter int APT_WL = 10) (
  input logic           clk, rst_n,
  input logic [NRO-1:0] ro_in,
  input logic           en, src_sel, cond_bypass,
  input logic [1:0]     cond_blks,
  input logic [7:0]     smp_div, rct_cutoff,
  input logic [10:0]    apt_cutoff,
  input logic [31:0]    lfsr_seed,
  input logic           ent_valid, ent_ready, ent_fips, seed_rdy, raw_valid, raw_bit, es_ok, es_fips,
  input logic           alert, alert_rct, alert_apt,
  input logic [31:0]    ent_data,
  input logic [2:0]     state,
  input logic [7:0]     rct_fails, apt_fails, rct_hw,
  input logic [10:0]    apt_hw,
  // internal: the collection / schedule register and the chaining value
  input logic [511:0]   blk,
  input logic [255:0]   hh
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [2:0] IDLE = 0, START = 1, RUN = 2, HASH = 3, OUT = 4, FAIL = 5;
  localparam int WIN = 1 << APT_WL;
  // clocks in HASH per compression: the start, 64 rounds, the feed-forward, the hand-over
  localparam int HCLK = 67;

  // ---------------- SHA-256 from its definition ----------------
  logic [31:0] k [0:63];
  logic [255:0] iv;
  function automatic logic [31:0] frac32(input real x);
    real f;
    f = x - $floor(x);
    frac32 = 32'($floor(f * 4294967296.0));
  endfunction
  initial begin
    int p, n;
    n = 0; p = 2;
    while (n < 64) begin
      bit pr;
      pr = 1;
      for (int d = 2; d * d <= p; d++) if (p % d == 0) pr = 0;
      if (pr) begin
        k[n] = frac32($pow(real'(p), 1.0 / 3.0));
        if (n < 8) iv[32 * (7 - n) +: 32] = frac32($sqrt(real'(p)));
        n++;
      end
      p++;
    end
  end
  function automatic logic [31:0] rr(input logic [31:0] x, input int n);
    rr = (x >> n) | (x << (32 - n));
  endfunction
  function automatic logic [255:0] compress(input logic [255:0] h, input logic [511:0] m);
    logic [31:0] w [0:63];
    logic [31:0] a, b, c, d, e, f, g, hq, x, y;
    for (int t = 0; t < 16; t++) w[t] = m[32 * (15 - t) +: 32];
    for (int t = 16; t < 64; t++)
      w[t] = (rr(w[t - 2], 17) ^ rr(w[t - 2], 19) ^ (w[t - 2] >> 10)) + w[t - 7]
             + (rr(w[t - 15], 7) ^ rr(w[t - 15], 18) ^ (w[t - 15] >> 3)) + w[t - 16];
    {a, b, c, d, e, f, g, hq} = h;
    for (int t = 0; t < 64; t++) begin
      x = hq + (rr(e, 6) ^ rr(e, 11) ^ rr(e, 25)) + ((e & f) ^ (~e & g)) + k[t] + w[t];
      y = (rr(a, 2) ^ rr(a, 13) ^ rr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
      hq = g; g = f; f = e; e = d + x; d = c; c = b; b = a; a = x + y;
    end
    for (int i = 0; i < 8; i++) compress[32 * (7 - i) +: 32] = h[32 * (7 - i) +: 32] + {a, b, c, d, e, f, g, hq}[32 * (7 - i) +: 32];
  endfunction
  // the seed: SHA-256 of the n blocks in mb (block 0 in mb[0]), with the padding block
  logic [511:0] mb [0:3];
  function automatic logic [255:0] seed_of(input int n);
    logic [255:0] h;
    h = iv;
    for (int j = 0; j < n; j++) h = compress(h, mb[j]);
    seed_of = compress(h, {1'b1, 447'd0, 64'(n * 512)});
  endfunction

  // ---------------- the model ----------------
  // predicted registers of the core (their values after the last clock)
  logic [2:0]  m_st;
  logic        m_s1, m_s2, m_rv, m_rb;
  logic [31:0] m_lfsr;
  int          m_dcnt;
  bit          m_src, m_byp, m_fips;
  int          m_nblk;
  int          m_rn, m_ac, m_ai, m_rhw, m_ahw, m_rf, m_af;
  logic        m_ra, m_aa;
  bit          m_alert, m_alr, m_ala, m_rdy;
  int          m_bits, m_bi, m_hc;
  logic [511:0] m_cur;
  logic [255:0] m_out;
  int          m_wl;
  bit          m_en_q;
  // coverage events
  int          c_fail = -1, c_drop = -1, c_seed = -1, c_mode = -1, c_div = -1;
  bit          v_bp, v_b2b, v_rsat, v_asat, v_forced, v_rhw, v_ahw, v_dhash, v_dout, v_cfg, v_win;
  function automatic bit is_live(input logic [2:0] s);
    is_live = s == START || s == RUN || s == HASH || s == OUT;
  endfunction
  always @(posedge clk) begin
    c_fail <= -1; c_drop <= -1; c_seed <= -1; c_mode <= -1; c_div <= -1;
    if (!rst_n) begin
      m_st = IDLE; m_s1 = 0; m_s2 = 0; m_rv = 0; m_rb = 0; m_lfsr = 0; m_dcnt = 0; m_src = 0; m_byp = 0;
      m_fips = 0; m_nblk = 1; m_rn = 0; m_ac = 0; m_ai = 0; m_rhw = 0; m_ahw = 0; m_rf = 0; m_af = 0;
      m_ra = 0; m_aa = 0; m_alert = 0; m_alr = 0; m_ala = 0; m_rdy = 0; m_bits = 0; m_bi = 0; m_hc = 0;
      m_out = '0; m_wl = 0; m_en_q = 0;
    end else begin
      bit lv, tk, smp, fr, fa, hf, sb, ob;
      int rnx, anx;
      ob = m_rb;                                          // the sample taken at this clock
      lv = is_live(m_st);
      tk = lv && m_dcnt >= int'(smp_div);
      smp = m_rv && lv;
      rnx = m_rn != 0 && m_rb == m_ra ? m_rn + 1 : 1;
      anx = m_ai == 0 ? 1 : m_ac + (m_rb == m_aa ? 1 : 0);
      fr = smp && rnx >= int'(rct_cutoff);
      fa = smp && anx >= int'(apt_cutoff);
      hf = fr || fa;
      sb = m_src ? m_lfsr[0] : m_s2;
      m_alert = 0; m_rdy = 0;
      // coverage of what this clock does
      if (hf && en) c_fail <= (int'(m_st) - 1) * 3 + (fr && fa ? 2 : fa ? 1 : 0);
      if (!en && m_st != IDLE) c_drop <= int'(m_st);
      if (smp && en && !hf) begin
        if (m_st == HASH) v_dhash <= 1;
        if (m_st == OUT) v_dout <= 1;
        if (m_st == RUN && m_ai == WIN - 1) v_win <= 1;
      end
      if (hf && en && m_rn == 0 && (rct_cutoff <= 8'd1 || apt_cutoff <= 11'd1)) v_forced <= 1;
      if (m_st == OUT && !ent_ready) v_bp <= 1;
      if (lv && (src_sel != m_src || cond_bypass != m_byp)) v_cfg <= 1;
      if (tk) c_div <= smp_div == 8'd0 ? 0 : smp_div == 8'd1 ? 1 : smp_div == 8'd255 ? 3 : 2;
      // samples and health tests (they run in every live state)
      if (smp) begin
        m_ra = m_rb; m_rn = rnx;
        if (m_ai == 0) m_aa = m_rb;
        m_ac = anx; m_ai = (m_ai + 1) % WIN;
        if (rnx > m_rhw) m_rhw = rnx;
        if (anx > m_ahw) m_ahw = anx;
      end
      if (tk) begin
        m_rb = sb;
        m_lfsr = m_lfsr[0] ? (m_lfsr >> 1) ^ 32'h8020_0003 : m_lfsr >> 1;
        m_dcnt = 0;
      end else if (lv) m_dcnt++;
      m_rv = tk;
      m_s2 = m_s1; m_s1 = ^ro_in;
      // control
      if (!en && m_st != IDLE) begin
        m_st = IDLE; m_rv = 0; m_out = '0; m_wl = 0;
      end else if (hf) begin
        m_st = FAIL; m_alert = 1; m_rv = 0; m_out = '0; m_wl = 0;
        if (fr) begin m_alr = 1; if (m_rf < 255) m_rf++; end
        if (fa) begin m_ala = 1; if (m_af < 255) m_af++; end
        if (m_rf == 255) v_rsat <= 1;
        if (m_af == 255) v_asat <= 1;
      end else
        case (m_st)
          IDLE:
            if (en && !m_en_q) begin
              m_st = START; m_src = src_sel; m_byp = cond_bypass; m_nblk = int'(cond_blks) + 1;
              m_fips = !src_sel && !cond_bypass; m_lfsr = lfsr_seed; m_dcnt = 0;
              m_rn = 0; m_ai = 0; m_ac = 0; m_rhw = 0; m_ahw = 0; m_alr = 0; m_ala = 0;
            end
          START:
            if (smp && m_ai == 0) begin m_st = RUN; m_bits = 0; m_bi = 0; end   // the window just completed
          RUN:
            if (smp) begin
              m_cur = {m_cur[510:0], ob};
              m_bits++;
              if (m_byp && m_bits == 32) begin
                m_st = OUT; m_out = {m_cur[31:0], 224'd0}; m_wl = 1; m_rdy = 1;
                c_mode <= m_src ? 3 : 2;
              end else if (!m_byp && m_bits == 512) begin
                mb[m_bi] = m_cur; m_bi++;
                m_st = HASH; m_hc = m_bi == m_nblk ? 2 * HCLK : HCLK;
              end
            end
          HASH:
            if (m_hc == 1) begin
              if (m_bi == m_nblk) begin
                m_st = OUT; m_out = seed_of(m_nblk); m_wl = 8; m_rdy = 1;
                c_seed <= m_nblk - 1; c_mode <= m_src ? 1 : 0;
              end else begin m_st = RUN; m_bits = 0; end
            end else m_hc--;
          OUT:
            if (ent_ready) begin
              m_out = {m_out[223:0], 32'd0}; m_wl--;
              if (m_wl == 0) begin m_st = RUN; m_bits = 0; m_bi = 0; v_b2b <= 1; end
            end
          default: ;
        endcase
      m_en_q = en;
      if (m_rhw >= 128) v_rhw <= 1;
      if (m_ahw >= 512) v_ahw <= 1;
    end
  end

  `SVA_INV(a_state, state == m_st)
  `SVA_INV(a_raw_sample, raw_valid == m_rv && (!m_rv || raw_bit == m_rb))
  `SVA_INV(a_health_alert, alert == m_alert && alert_rct == m_alr && alert_apt == m_ala)
  `SVA_INV(a_fail_counters, rct_fails == 8'(m_rf) && apt_fails == 8'(m_af))
  `SVA_INV(a_high_water, rct_hw == 8'(m_rhw) && apt_hw == 11'(m_ahw))
  `SVA_IMP(a_output_word, ent_valid, ent_data == m_out[255:224] && ent_fips == m_fips)
  `SVA_INV(a_output_valid, ent_valid == (m_st == OUT) && seed_rdy == m_rdy)
  `SVA_IMP(a_output_quiet, !ent_valid, ent_data == '0 && !ent_fips)
  `SVA_INV(a_es_ok, es_ok == (state == RUN || state == HASH || state == OUT) && es_fips == (es_ok && m_fips))
  // nothing is output after a failure, and the buffers hold no sample data
  // unless the core is collecting or hashing
  `SVA_IMP(a_no_output_after_fail, alert_rct || alert_apt, !ent_valid && !es_ok)
  // (the chaining value is cleared one clock after the digest moved to the output)
  logic [2:0] st_q;
  always @(posedge clk) st_q <= state;
  `SVA_IMP(a_clear_when_stopped, state != RUN && state != HASH, blk == '0)
  `SVA_IMP(a_chain_cleared, state != RUN && state != HASH && st_q != RUN && st_q != HASH, hh == '0)
  `SVA_RST(a_reset, 1'b1, state == IDLE && !ent_valid && !raw_valid && !alert && !alert_rct && !alert_apt
                          && rct_fails == '0 && apt_fails == '0 && blk == '0 && hh == '0)

  // ---------------- functional coverage ----------------
  covergroup cg_trng @(negedge clk);
    option.per_instance = 1;
    // health test failures: test (RCT, APT, both) x state it hit in
    cp_fail: coverpoint c_fail iff (c_fail >= 0)
      { bins rct_start = {0}; bins apt_start = {1}; bins both_start = {2};
        bins rct_run = {3}; bins apt_run = {4}; bins rct_hash = {6}; bins apt_hash = {7};
        bins rct_out = {9}; bins apt_out = {10}; }
    // en dropped in each state
    cp_drop: coverpoint c_drop iff (c_drop >= 0)
      { bins start = {1}; bins run = {2}; bins hash = {3}; bins out = {4}; bins fail = {5}; }
    // seeds of 1 to 4 blocks
    cp_seed: coverpoint c_seed iff (c_seed >= 0) { bins blocks[] = {[0:3]}; }
    // output kinds: conditioned / raw from the ring oscillators / the LFSR
    cp_mode: coverpoint c_mode iff (c_mode >= 0)
      { bins cond_ro = {0}; bins cond_lfsr = {1}; bins raw_ro = {2}; bins raw_lfsr = {3}; }
    // sampling rate
    cp_div: coverpoint c_div iff (c_div >= 0) { bins every = {0}; bins half = {1}; bins mid = {2}; bins slowest = {3}; }
  endgroup
  cg_trng u_cg_trng = new;

  `FC(back_pressure, v_bp)
  `FC(seed_after_seed, v_b2b)
  `FC(rct_counter_saturated, v_rsat)
  `FC(apt_counter_saturated, v_asat)
  `FC(forced_failure, v_forced)
  `FC(long_run, v_rhw)
  `FC(high_proportion, v_ahw)
  `FC(sample_dropped_hashing, v_dhash)
  `FC(sample_dropped_output, v_dout)
  `FC(config_change_running, v_cfg)
  `FC(window_end_collecting, v_win)
  `FC_RST(reset_while_running, rst_n && es_ok ##1 !rst_n)
endmodule

bind TRNG_top TRNG_sva #(.NRO(NRO), .APT_WL(APT_WL)) u_sva (.*);
