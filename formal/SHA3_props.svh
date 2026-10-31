// SPDX-License-Identifier: Apache-2.0
// Formal properties of SHA3_top (included at the end of the module under
// `ifdef FORMAL; run with scripts/formal/run_formal.sh SHA3). Every input is
// free after the first clock: start and mode, message words of any length
// and flags, and output back-pressure come in any order. Each property is a
// wire (fa_*) with its own assertion, so a counterexample shows which one
// failed.
  logic f_done = 1'b0;                   // past the first clock (reset)
  wire  f_init = !f_done;
  always @(posedge clk) f_done <= 1'b1;
  always @(*) if (f_init) assume (!rst_n);

  wire f_chk = !f_init && rst_n;
  // the control state, the return state and the mode are legal ones
  wire fa_state = st <= S_SQZ && ret <= R_SQZ && md <= M_X256;
  // the lane index stays inside the rate block; a permutation starts at lane 0
  wire fa_lane  = (st == S_IDLE) || (li <= rlm1) && (st != S_PERM || li == 5'd0);
  // the round counter runs only in a permutation
  wire fa_round = rnd <= 5'd23 && (st == S_PERM || rnd == 5'd0);
  // a SHA3 digest is squeezed from the first block only, within its length
  wire fa_dig   = st != S_SQZ || xof || li < 5'(digest_words(md));
  // idle: nothing out, nothing taken, and the state is clear (no data left behind)
  wire fa_wipe  = st != S_IDLE || ks == '0 && !in_ready && !out_valid;
  // never ready for input and offering output at once
  wire fa_excl  = !(in_ready && out_valid);
  // done and err never in the same clock
  wire fa_flags = !(done && err);
  always @(*) if (f_chk) assert (fa_state);
  always @(*) if (f_chk) assert (fa_lane);
  always @(*) if (f_chk) assert (fa_round);
  always @(*) if (f_chk) assert (fa_dig);
  always @(*) if (f_chk) assert (fa_wipe);
  always @(*) if (f_chk) assert (fa_excl);
  always @(*) if (f_chk) assert (fa_flags);
