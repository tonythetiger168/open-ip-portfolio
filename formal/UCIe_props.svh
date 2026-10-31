// SPDX-License-Identifier: Apache-2.0
// Formal properties of UCIe_top (included at the end of the module under
// `ifdef FORMAL; run with scripts/formal/run_formal.sh UCIe). The main band,
// the sideband, the protocol side, the configuration and reset are left free
// after the first clock, so the far side may send any flit or message at
// all. Each property is a wire (fa_*) with its own assertion, so a
// counterexample shows which one failed.
  logic f_done = 1'b0;                   // past the first clock (reset)
  wire  f_init = !f_done;
  always @(posedge clk) f_done <= 1'b1;
  always @(*) if (f_init) assume (!rst_n);

  wire f_chk = !f_init && rst_n;
  // the state is one of the seven
  wire fa_state  = st <= S_LINKERR;
  // Retry: at most RB flits outstanding, the replay pointer among them
  wire fa_outst  = 6'(ws - as) <= 6'(RB);
  wire fa_replay = 6'(rp - as) <= 6'(ws - as);
  // payloads are taken only in ACTIVE, and not while waiting for L1
  wire fa_ready  = !tx_ready || st == S_ACTIVE && !l1_wait;
  // the negotiated capabilities are among our own
  wire fa_cap    = (fc & ~oc) == 2'b00;
  always @(*) if (f_chk) assert (fa_state);
  always @(*) if (f_chk) assert (fa_outst);
  always @(*) if (f_chk) assert (fa_replay);
  always @(*) if (f_chk) assert (fa_ready);
  always @(*) if (f_chk) assert (fa_cap);
