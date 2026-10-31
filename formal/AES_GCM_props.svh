// SPDX-License-Identifier: Apache-2.0
// Formal properties of AES_GCM_top (included at the end of the module under
// `ifdef FORMAL; run with scripts/formal/run_formal.sh AES_GCM). Every input
// is free after the first clock: configuration, keys, data blocks, block
// sizes and flags, back-pressure, start and clr may change in any clock, in
// any order. The properties are the security and protocol rules of the
// core; each is a wire (fa_*) with its own assertion, so a counterexample
// shows which one failed.
  logic f_done = 1'b0;                   // past the first clock (reset)
  wire  f_init = !f_done;
  always @(posedge clk) f_done <= 1'b1;
  always @(*) if (f_init) assume (!rst_n);
  logic f_dec;                           // the last message taken was a decryption
  always @(posedge clk or negedge rst_n)
    if (!rst_n) f_dec <= 1'b0;
    else if (start && !busy && !clr && !st_bad) f_dec <= decrypt;

  wire f_chk = !f_init && rst_n;
  wire f_secret0 = kreg == '0 && kw == '0 && st == '0 && hk == '0 && ej0 == '0 && gz == '0 && ga == '0 && ivr == '0;
  // idle: no key, round key, AES state, H, E(K, J0), GHASH state or IV left,
  // and nothing running or pending
  wire fa_idle  = m != M_IDLE || f_secret0 && !a_act && !a_vld && !h_ok && !j_ok && g_cnt == 2'd0 && !out_valid
                                 && alen == '0 && clen == '0;
  // AES-128 keeps no second key half
  wire fa_k128  = k256 || kreg[127:0] == '0;
  // the AES round counter stays within the rounds of the key size
  wire fa_rnd   = !a_act || a_rnd >= 4'd1 && a_rnd <= (k256 ? NR256 : NR128);
  // AES jobs in order: H, then E(K, J0), then the key stream; a key stream
  // block is held only once both are known
  wire fa_jobs  = (!j_ok || h_ok) && (!a_act || (a_job == J_H ? !h_ok : a_job == J_J0 ? h_ok && !j_ok
                                                  : a_job == J_KS && j_ok))
                  && (!a_vld || j_ok && a_job == J_KS && !a_act);
  // a block is taken only while a message runs, with a key stream block
  // ready, GHASH idle and the output free
  wire fa_ready = !in_ready || m == M_RUN && a_vld && g_cnt == 2'd0 && !out_valid;
  // the tag is computed only with E(K, J0) known
  wire fa_endj0 = !(m == M_LEN || m == M_FIN) || j_ok;
  // an output block only within a message
  wire fa_out   = !out_valid || m != M_IDLE;
  // GHASH: the operand register is empty when no multiplication runs
  wire fa_ga    = g_cnt != 2'd0 || ga == '0;
  // a decryption never gives out the computed tag; tag_ok only for a decryption
  wire fa_dtag  = !f_dec || tag == '0;
  wire fa_tagok = !tag_ok || f_dec;
  // the lengths stay within the limits
  wire fa_len   = clen <= TXT_MAX;
  // done and err end the message
  wire fa_end   = !(done || err) || m == M_IDLE;
  always @(*) if (f_chk) assert (fa_idle);
  always @(*) if (f_chk) assert (fa_k128);
  always @(*) if (f_chk) assert (fa_rnd);
  always @(*) if (f_chk) assert (fa_jobs);
  always @(*) if (f_chk) assert (fa_ready);
  always @(*) if (f_chk) assert (fa_endj0);
  always @(*) if (f_chk) assert (fa_out);
  always @(*) if (f_chk) assert (fa_ga);
  always @(*) if (f_chk) assert (fa_dtag);
  always @(*) if (f_chk) assert (fa_tagok);
  always @(*) if (f_chk) assert (fa_len);
  always @(*) if (f_chk) assert (fa_end);
