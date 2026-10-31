// SPDX-License-Identifier: Apache-2.0
// Formal properties of TRNG_top (included at the end of the module under
// `ifdef FORMAL; run with scripts/formal/run_formal.sh TRNG). Every input is
// free after the first clock: the ring oscillators, the configuration, the
// cutoffs (which may change at any clock), en and the output ready. Shadow
// counters written here, separately from the core's, follow the raw samples
// the core tests: the length of the current run and the count of the
// window's first value, since the start-up began. The properties are the
// SP 800-90B rules of the core; each is a wire (fa_*) with its own
// assertion, so a counterexample shows which one failed. Within the bound
// the core passes the start-up window and collects; a seed (512 samples)
// lies beyond it, so the output side is left to the simulation checker.
  logic f_done = 1'b0;                   // past the first clock (reset)
  wire  f_init = !f_done;
  always @(posedge clk) f_done <= 1'b1;
  always @(*) if (f_init) assume (!rst_n);
  wire  f_chk = !f_init && rst_n;

  localparam int FW = 1 << APT_WL;
  st_t          f_st_q = S_IDLE;
  logic         f_val = 1'b0, f_ref = 1'b0;
  logic [8:0]   f_run = '0;              // current run (0: no sample yet)
  logic [11:0]  f_wcnt = '0;             // the window's first value, counted
  logic [APT_WL:0] f_wpos = '0;          // samples in the window
  logic [APT_WL+1:0] f_ns = '0;          // samples tested since the start (saturating)
  logic         f_cause = 1'b0;          // the previous sample failed a test (and en was high)
  logic         f_en_q = 1'b0;
  wire          f_smp = raw_valid && (st == S_START || st == S_RUN || st == S_HASH || st == S_OUT);
  wire  [8:0]   f_run_nx = f_run != 0 && raw_bit == f_val ? f_run + 9'd1 : 9'd1;
  wire  [11:0]  f_wcnt_nx = f_wpos == 0 || f_wpos == FW[APT_WL:0] ? 12'd1 : f_wcnt + 12'(raw_bit == f_ref);
  wire          f_fail_nx = f_smp && en && (f_run_nx >= 9'(rct_cutoff) || f_wcnt_nx >= 12'(apt_cutoff));
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_st_q <= S_IDLE; f_run <= '0; f_wcnt <= '0; f_wpos <= '0; f_ns <= '0; f_cause <= 1'b0; f_en_q <= 1'b0;
    end else begin
      f_st_q <= st; f_en_q <= en;
      f_cause <= f_fail_nx;
      if (st == S_IDLE && en && !f_en_q) begin
        f_run <= '0; f_wpos <= '0; f_ns <= '0;
      end else if (f_smp) begin
        f_val <= raw_bit; f_run <= f_run_nx;
        if (f_wpos == 0 || f_wpos == FW[APT_WL:0]) begin f_ref <= raw_bit; f_wpos <= 1; end
        else f_wpos <= f_wpos + 1'b1;
        f_wcnt <= f_wcnt_nx;
        if (f_ns != {(APT_WL + 2){1'b1}}) f_ns <= f_ns + 1'b1;
      end
    end
  end

  // the control state is a legal one
  wire fa_state  = st <= S_FAIL;
  // a run of rct_cutoff equal samples, or apt_cutoff of the window's first
  // value, stops the core at the next clock (unless en dropped)
  wire fa_detect = !f_cause || st == S_FAIL || st == S_IDLE;
  // and the core never fails without such a sample
  wire fa_cause  = !(st == S_FAIL && f_st_q != S_FAIL) || f_cause;
  // nothing is collected or output before a whole window has passed the tests
  wire fa_start  = !es_ok || f_ns >= (APT_WL + 2)'(FW);
  // a raised alert flag means the core is stopped; stopped means no output
  // and no sample data held
  wire fa_alert  = !(alert_rct || alert_apt) || st == S_FAIL || st == S_IDLE;
  wire fa_stop   = st != S_FAIL && st != S_IDLE && st != S_START || !ent_valid && !es_ok && blk == '0 && dig == '0;
  wire fa_hh     = st == S_RUN || st == S_HASH || f_st_q == S_RUN || f_st_q == S_HASH || hh == '0;
  always @(*) if (f_chk) assert (fa_state);
  always @(*) if (f_chk) assert (fa_detect);
  always @(*) if (f_chk) assert (fa_cause);
  always @(*) if (f_chk) assert (fa_start);
  always @(*) if (f_chk) assert (fa_alert);
  always @(*) if (f_chk) assert (fa_stop);
  always @(*) if (f_chk) assert (fa_hh);
