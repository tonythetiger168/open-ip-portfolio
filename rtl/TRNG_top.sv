// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// TRNG_top v1.0: true random number generator in the structure of NIST
// SP 800-90B: a noise source, health tests on every raw sample, and a vetted
// conditioning function that turns the raw bits into full-entropy seeds.
// ----------------------------------------------------------------------------
//  - Noise source: NRO free-running ring oscillators outside the core
//    (ro_in, asynchronous to clk). Their XOR passes a two-flop synchronizer
//    and is sampled once every smp_div + 1 clocks: one raw bit per sample.
//    src_sel = 1 replaces it by a 32-bit Galois LFSR loaded with lfsr_seed
//    (bring-up and test only: deterministic, no entropy, never marked FIPS).
//    Every raw sample is also driven on raw_valid / raw_bit, for the offline
//    entropy assessment of SP 800-90B (and for an external health monitor).
//  - Health tests (SP 800-90B 4.4) on every raw sample while enabled:
//      repetition count test: a run of rct_cutoff identical samples fails;
//      adaptive proportion test: in each window of 2^APT_WL samples (1024),
//      apt_cutoff occurrences of the window's first sample value fail.
//    With alpha = 2^-20 and a claimed min-entropy H per bit, the cutoffs are
//    1 + ceil(20 / H) and 1 + CRITBINOM(1024, 2^-H, 1 - alpha): H = 0.5 gives
//    41 and 793 (the reset values in the APB wrapper), H = 1 gives 21 and 589.
//    A cutoff of 0 or 1 fails on the first sample (a forced-failure test).
//  - Start-up: after en rises the first window (1024 samples) is tested and
//    discarded; only when it passes does the core collect. A failure at any
//    time stops the core (state FAIL): alert pulses, alert_rct / alert_apt
//    stay set, the buffers are cleared and nothing more is output until en is
//    dropped and raised again (which reruns the start-up test).
//  - Conditioning (SP 800-90B 3.1.5.1.1, a vetted function): the raw bits,
//    first bit as the MSB of the first byte, are collected in 512-bit blocks
//    and hashed with SHA-256 (64 rounds, one per clock), cond_blks + 1 blocks
//    per seed; the 256-bit digest of those 512 * (cond_blks + 1) bits is the
//    seed, output as eight 32-bit words (digest word 0 first). The default of
//    two blocks gives 1024 raw bits, at H = 0.5 512 bits of entropy for a
//    256-bit output (90B full entropy needs 256 + 64). Each seed is hashed
//    from fresh samples; samples taken while hashing or while the seed waits
//    to be read are health-tested and discarded.
//  - cond_bypass = 1: raw bits are output unconditioned, 32 per word (first
//    bit at bit 31), for characterization; never marked FIPS.
//  - src_sel, cond_bypass and cond_blks are taken when en rises; smp_div and
//    the cutoffs apply at once.
//  - Output: ent_valid / ent_ready / ent_data, with ent_fips set on words of a
//    conditioned seed from the ring oscillators. seed_rdy pulses when a seed
//    (or bypass word) becomes available. es_fips: running (start-up passed)
//    in the FIPS configuration (ring oscillators, conditioned).
//  - Monitors: rct_fails / apt_fails count failures since reset (saturating);
//    rct_hw / apt_hw hold the longest run and the highest window count seen
//    since en rose.
// ============================================================================
module TRNG_top #(
  parameter int NRO    = 4,             // ring oscillator inputs
  parameter int APT_WL = 10             // adaptive proportion window: 2^APT_WL samples
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic [NRO-1:0] ro_in,         // ring oscillator outputs (asynchronous)
  // configuration
  input  logic           en,
  input  logic           src_sel,       // 0 ring oscillators, 1 test LFSR
  input  logic           cond_bypass,
  input  logic [1:0]     cond_blks,     // 512-bit blocks per seed, minus 1
  input  logic [7:0]     smp_div,       // a sample every smp_div + 1 clocks
  input  logic [7:0]     rct_cutoff,
  input  logic [10:0]    apt_cutoff,
  input  logic [31:0]    lfsr_seed,
  // entropy output
  output logic           ent_valid,
  input  logic           ent_ready,
  output logic [31:0]    ent_data,
  output logic           ent_fips,
  output logic           seed_rdy,
  // raw samples
  output logic           raw_valid,
  output logic           raw_bit,
  // status
  output logic [2:0]     state,
  output logic           es_ok,
  output logic           es_fips,
  output logic           alert,
  output logic           alert_rct,
  output logic           alert_apt,
  output logic [7:0]     rct_fails,
  output logic [7:0]     apt_fails,
  output logic [7:0]     rct_hw,
  output logic [10:0]    apt_hw
);
  typedef enum logic [2:0] { S_IDLE, S_START, S_RUN, S_HASH, S_OUT, S_FAIL } st_t;
  st_t          st;                     // control state (on the state port)
  localparam logic [31:0] LFSR_TAPS = 32'h8020_0003;   // x^32 + x^22 + x^2 + x + 1

  // ---------------- SHA-256 ----------------
  localparam logic [32*64-1:0] KT = {
    32'hc67178f2, 32'hbef9a3f7, 32'ha4506ceb, 32'h90befffa,
    32'h8cc70208, 32'h84c87814, 32'h78a5636f, 32'h748f82ee,
    32'h682e6ff3, 32'h5b9cca4f, 32'h4ed8aa4a, 32'h391c0cb3,
    32'h34b0bcb5, 32'h2748774c, 32'h1e376c08, 32'h19a4c116,
    32'h106aa070, 32'hf40e3585, 32'hd6990624, 32'hd192e819,
    32'hc76c51a3, 32'hc24b8b70, 32'ha81a664b, 32'ha2bfe8a1,
    32'h92722c85, 32'h81c2c92e, 32'h766a0abb, 32'h650a7354,
    32'h53380d13, 32'h4d2c6dfc, 32'h2e1b2138, 32'h27b70a85,
    32'h14292967, 32'h06ca6351, 32'hd5a79147, 32'hc6e00bf3,
    32'hbf597fc7, 32'hb00327c8, 32'ha831c66d, 32'h983e5152,
    32'h76f988da, 32'h5cb0a9dc, 32'h4a7484aa, 32'h2de92c6f,
    32'h240ca1cc, 32'h0fc19dc6, 32'hefbe4786, 32'he49b69c1,
    32'hc19bf174, 32'h9bdc06a7, 32'h80deb1fe, 32'h72be5d74,
    32'h550c7dc3, 32'h243185be, 32'h12835b01, 32'hd807aa98,
    32'hab1c5ed5, 32'h923f82a4, 32'h59f111f1, 32'h3956c25b,
    32'he9b5dba5, 32'hb5c0fbcf, 32'h71374491, 32'h428a2f98
  };
  localparam logic [255:0] IV = {32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
                                 32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};
  function automatic logic [31:0] ror(input logic [31:0] x, input int n);
    ror = (x >> n) | (x << (32 - n));
  endfunction
  // the collection register: raw bits shift in at the bottom; during a
  // compression it is the schedule window W[t .. t + 15] (word 0 at the top)
  logic [511:0] blk;
  logic [255:0] hh;                     // chaining value, word 0 at the top
  logic [31:0]  sa, sb, sc, sd, se, sf, sg, sh;
  logic [6:0]   srnd;                   // round, 64 = idle
  logic         sha_go, sha_init;       // start a compression (from IV / from hh)
  logic         sha_done;               // the last round: the chaining value is added next
  wire          sha_run = srnd != 7'd64;
  wire          sha_busy = sha_run || sha_done;
  wire  [31:0]  w0 = blk[511:480];
  wire  [31:0]  s0 = ror(blk[479:448], 7) ^ ror(blk[479:448], 18) ^ (blk[479:448] >> 3);   // W[t + 1]
  wire  [31:0]  s1 = ror(blk[63:32], 17) ^ ror(blk[63:32], 19) ^ (blk[63:32] >> 10);        // W[t + 14]
  wire  [31:0]  wnew = s1 + blk[223:192] + s0 + w0;                                          // W[t + 16]
  wire  [31:0]  t1 = sh + (ror(se, 6) ^ ror(se, 11) ^ ror(se, 25)) + ((se & sf) ^ (~se & sg))
                     + KT[32 * srnd[5:0] +: 32] + w0;
  wire  [31:0]  t2 = (ror(sa, 2) ^ ror(sa, 13) ^ ror(sa, 22)) + ((sa & sb) ^ (sa & sc) ^ (sb & sc));

  // ---------------- noise source and sampling ----------------
  logic         ro_s1, ro_s2;           // synchronizer
  logic [31:0]  lfsr;
  logic [7:0]   dcnt;
  logic         src_l, byp_l;           // taken when en rises
  logic [2:0]   nblk;                   // blocks per seed
  wire          live = st == S_START || st == S_RUN || st == S_HASH || st == S_OUT;
  wire          tick = live && dcnt >= smp_div;
  wire          sbit = src_l ? lfsr[0] : ro_s2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ro_s1 <= 1'b0; ro_s2 <= 1'b0;
    end else begin
      ro_s1 <= ^ro_in; ro_s2 <= ro_s1;
    end
  end

  // ---------------- health tests ----------------
  logic         rct_a;                  // value of the current run
  logic [7:0]   rct_n;                  // its length (0: no sample yet)
  logic         apt_a;                  // first value of the window
  logic [10:0]  apt_c;                  // its count in the window
  logic [APT_WL-1:0] apt_i;             // position in the window
  // a passing run is shorter than rct_cutoff (at most 255), so rct_n + 1 cannot wrap
  wire  [7:0]   rct_nx = rct_n != 8'd0 && raw_bit == rct_a ? rct_n + 8'd1 : 8'd1;
  wire  [10:0]  apt_nx = apt_i == '0 ? 11'd1 : apt_c + 11'(raw_bit == apt_a);
  wire          f_rct = rct_nx >= rct_cutoff;
  wire          f_apt = apt_nx >= apt_cutoff;
  wire          smp = raw_valid && live;
  wire          hfail = smp && (f_rct || f_apt);
  wire          wend = apt_i == {APT_WL{1'b1}};

  // ---------------- control ----------------
  logic [8:0]   bcnt;                   // bits in the block
  logic [2:0]   bi;                     // data blocks hashed for this seed
  logic         pad;                    // the padding block is being hashed
  logic [255:0] dig;                    // the seed being output, word 0 at the top
  logic [3:0]   wcnt;                   // words left
  logic         en_q;
  logic         fips_l;
  assign state = st;
  assign ent_valid = st == S_OUT;
  assign ent_data = dig[255:224];
  assign ent_fips = ent_valid && fips_l;
  assign es_ok = st == S_RUN || st == S_HASH || st == S_OUT;
  assign es_fips = es_ok && fips_l;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; en_q <= 1'b0; src_l <= 1'b0; byp_l <= 1'b0; nblk <= 3'd1; fips_l <= 1'b0;
      lfsr <= '0; dcnt <= '0; raw_valid <= 1'b0; raw_bit <= 1'b0;
      rct_a <= 1'b0; rct_n <= '0; apt_a <= 1'b0; apt_c <= '0; apt_i <= '0;
      alert <= 1'b0; alert_rct <= 1'b0; alert_apt <= 1'b0; rct_fails <= '0; apt_fails <= '0;
      rct_hw <= '0; apt_hw <= '0;
      blk <= '0; bcnt <= '0; bi <= '0; pad <= 1'b0; dig <= '0; wcnt <= '0; seed_rdy <= 1'b0;
      sha_go <= 1'b0; sha_init <= 1'b0;
    end else begin
      en_q <= en;
      alert <= 1'b0; seed_rdy <= 1'b0; sha_go <= 1'b0;
      // sampling
      raw_valid <= tick;
      if (tick) begin
        dcnt <= '0;
        raw_bit <= sbit;
        lfsr <= lfsr[0] ? (lfsr >> 1) ^ LFSR_TAPS : lfsr >> 1;
      end else if (live) dcnt <= dcnt + 8'd1;
      // health tests on the sample of the previous clock
      if (smp) begin
        rct_a <= raw_bit; rct_n <= rct_nx;
        if (apt_i == '0) apt_a <= raw_bit;
        apt_c <= apt_nx; apt_i <= apt_i + 1'b1;
        if (rct_nx > rct_hw) rct_hw <= rct_nx;
        if (apt_nx > apt_hw) apt_hw <= apt_nx;
      end
      // the SHA-256 rounds shift the block register
      if (sha_run) blk <= {blk[479:0], wnew};
      if (!en && st != S_IDLE) begin
        // disabled: stop and clear
        st <= S_IDLE; blk <= '0; dig <= '0; raw_valid <= 1'b0;
      end else if (hfail) begin
        st <= S_FAIL; alert <= 1'b1; blk <= '0; dig <= '0; raw_valid <= 1'b0;
        if (f_rct) begin alert_rct <= 1'b1; if (rct_fails != 8'hFF) rct_fails <= rct_fails + 8'd1; end
        if (f_apt) begin alert_apt <= 1'b1; if (apt_fails != 8'hFF) apt_fails <= apt_fails + 8'd1; end
      end else
        case (st)
          S_IDLE:
            if (en && !en_q) begin
              st <= S_START; src_l <= src_sel; byp_l <= cond_bypass; nblk <= {1'b0, cond_blks} + 3'd1;
              fips_l <= !src_sel && !cond_bypass; lfsr <= lfsr_seed; dcnt <= '0;
              rct_n <= '0; apt_i <= '0; apt_c <= '0; rct_hw <= '0; apt_hw <= '0;
              alert_rct <= 1'b0; alert_apt <= 1'b0;
            end
          S_START:
            if (smp && wend) begin st <= S_RUN; bcnt <= '0; bi <= '0; pad <= 1'b0; end
          S_RUN:
            if (smp) begin
              blk <= {blk[510:0], raw_bit};
              bcnt <= bcnt + 9'd1;
              if (byp_l && bcnt[4:0] == 5'd31) begin
                st <= S_OUT; dig <= {blk[30:0], raw_bit, 224'd0}; wcnt <= 4'd1; seed_rdy <= 1'b1; blk <= '0;
              end else if (!byp_l && bcnt == 9'd511) begin
                st <= S_HASH; sha_go <= 1'b1; sha_init <= bi == 3'd0; bi <= bi + 3'd1;
              end
            end
          S_HASH:
            if (!sha_go && !sha_busy) begin
              if (pad) begin
                st <= S_OUT; dig <= hh; wcnt <= 4'd8; seed_rdy <= 1'b1; blk <= '0;
              end else if (bi == nblk) begin
                // the padding block of a message of nblk * 512 bits
                blk <= {32'h8000_0000, 416'd0, 32'd0, 20'd0, nblk, 9'd0};
                pad <= 1'b1; sha_go <= 1'b1; sha_init <= 1'b0;
              end else begin
                st <= S_RUN; bcnt <= '0;
              end
            end
          S_OUT:
            if (ent_ready) begin
              dig <= {dig[223:0], 32'd0};
              wcnt <= wcnt - 4'd1;
              if (wcnt == 4'd1) begin st <= S_RUN; bcnt <= '0; bi <= '0; pad <= 1'b0; end
            end
          S_FAIL: ;
          default: begin st <= S_FAIL; alert <= 1'b1; blk <= '0; dig <= '0; end
        endcase
    end
  end

  // SHA-256 compression: 64 rounds, one per clock; cleared outside hashing
  wire sha_clr = st != S_RUN && st != S_HASH;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hh <= '0; srnd <= 7'd64; sha_done <= 1'b0;
      sa <= '0; sb <= '0; sc <= '0; sd <= '0; se <= '0; sf <= '0; sg <= '0; sh <= '0;
    end else begin
      sha_done <= 1'b0;
      if (sha_clr) begin
        hh <= '0; srnd <= 7'd64;
        sa <= '0; sb <= '0; sc <= '0; sd <= '0; se <= '0; sf <= '0; sg <= '0; sh <= '0;
      end else if (sha_go) begin
        {sa, sb, sc, sd, se, sf, sg, sh} <= sha_init ? IV : hh;
        if (sha_init) hh <= IV;
        srnd <= '0;
      end else if (sha_run) begin
        sh <= sg; sg <= sf; sf <= se; se <= sd + t1; sd <= sc; sc <= sb; sb <= sa; sa <= t1 + t2;
        srnd <= srnd + 7'd1;
        if (srnd == 7'd63) sha_done <= 1'b1;
      end else if (sha_done) begin
        hh <= {hh[255:224] + sa, hh[223:192] + sb, hh[191:160] + sc, hh[159:128] + sd,
               hh[127:96] + se, hh[95:64] + sf, hh[63:32] + sg, hh[31:0] + sh};
      end
    end
  end
`ifdef FORMAL
  `include "TRNG_props.svh"
`endif
endmodule
