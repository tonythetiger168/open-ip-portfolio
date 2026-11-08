// SPDX-License-Identifier: Apache-2.0
// Formal properties of SPDM_top (included at the end of the module under
// `ifdef FORMAL; run with scripts/formal/run_formal.sh SPDM). Every input is
// free after the first clock: request bytes and lengths, commands, clr,
// random words and back-pressure come in any order, and the cut SHA3 and
// ML-DSA engines answer anything at any time. Each property is a wire (fa_*)
// with its own assertion, so a counterexample shows which one failed.
  logic f_done = 1'b0;                   // past the first clock (reset)
  wire  f_init = !f_done;
  always @(posedge clk) f_done <= 1'b1;
  always @(*) if (f_init) assume (!rst_n);

  wire f_chk = !f_init && rst_n;
  wire f_sign = st == S_FIN || st == S_MW || st == S_SG || st == S_SIGO || st == S_RPL;
  wire f_kg   = st == S_KG || st == S_KGW || st == S_KGZ;
  function automatic logic f_code(input logic [7:0] c);
    f_code = c == 8'h00 || c == E_INV || c == E_UNEXP || c == E_UNSUP || c == E_BIG || c == E_VER;
  endfunction
  // the control state, the segment and the response kind are legal ones
  wire fa_state = st <= S_CLR && seg <= 3'(G_OPQ) && (st != S_OUT || seg_en[seg]);
  // a request is taken only when idle or receiving; a response byte is offered
  // only from the response states, and never while a request is taken
  wire fa_rq    = !rq_ready || st == S_IDLE || st == S_RX;
  wire fa_rs    = !rs_valid || st == S_OUT || st == S_SIGO;
  wire fa_excl  = !(rq_ready && rs_valid) && !(rs_valid && pk_valid) && !(rn_ready && rs_valid);
  // the public key goes out only in S_PK and only with a key
  wire fa_pk    = !pk_valid || st == S_PK && key_ok;
  // random words are taken only for a nonce / signing randomness
  wire fa_rn    = !rn_ready || st == S_RN;
  // ML-DSA starts only to sign or for KeyGen; signing only with a key
  wire fa_ml    = !ml_start || st == S_SG && key_ok || st == S_KGW;
  // a signing sequence belongs to CHALLENGE_AUTH or a signed MEASUREMENTS, with a key
  wire fa_sign  = !f_sign || sgn && key_ok && (rt == R_CHAL || rt == R_MEAS);
  wire fa_sgn   = !sgn || rt == R_CHAL && !sg_cm || rt == R_MEAS && sg_cm;
  // there is no key while KeyGen runs
  wire fa_kg    = !f_kg || !key_ok;
  // negotiated algorithms only once ALGORITHMS was sent
  wire fa_alg   = conn == 2'd3 || !hash_ok && !asym_ok && !meas_ok;
  // only the five ERROR codes are ever chosen or reported
  wire fa_err   = f_code(d_err) && f_code(e_code) && f_code(err_code) && (!is_err || e_code != 8'h00);
  // the done / error / KeyGen pulses: an ERROR is a response; one kind per clock
  wire fa_flags = (!rsp_err || rsp_done) && !(rsp_done && kg_done);
  // a request cut by clr is drained only while idle (or wiping again)
  wire fa_drain = !drain || st == S_IDLE || st == S_CLR;
  // a request being decoded holds at least one byte
  wire fa_dec   = st != S_DEC || rq_n != 8'd0;
  always @(*) if (f_chk) assert (fa_state);
  always @(*) if (f_chk) assert (fa_rq);
  always @(*) if (f_chk) assert (fa_rs);
  always @(*) if (f_chk) assert (fa_excl);
  always @(*) if (f_chk) assert (fa_pk);
  always @(*) if (f_chk) assert (fa_rn);
  always @(*) if (f_chk) assert (fa_ml);
  always @(*) if (f_chk) assert (fa_sign);
  always @(*) if (f_chk) assert (fa_sgn);
  always @(*) if (f_chk) assert (fa_kg);
  always @(*) if (f_chk) assert (fa_alg);
  always @(*) if (f_chk) assert (fa_err);
  always @(*) if (f_chk) assert (fa_flags);
  always @(*) if (f_chk) assert (fa_drain);
  always @(*) if (f_chk) assert (fa_dec);
