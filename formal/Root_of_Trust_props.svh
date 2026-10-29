// SPDX-License-Identifier: Apache-2.0
// Formal properties of Root_of_Trust_top (included at the end of the module
// under `ifdef FORMAL; run with scripts/formal/run_formal.sh Root_of_Trust).
// Every input is free after the first clock: the OTP may answer with any
// data at any time, and commands, tokens, image words and the escalation
// input may come in any order. The properties are the security rules of the
// core; each is a wire (fa_*) with its own assertion, so a counterexample
// shows which one failed.
  logic f_done = 1'b0;                   // past the first clock (reset)
  wire  f_init = !f_done;
  always @(posedge clk) f_done <= 1'b1;
  always @(*) if (f_init) assume (!rst_n);

  wire f_chk = !f_init && rst_n;
  wire f_rd  = otp_req && !otp_we;
  wire f_pg  = otp_req && otp_we;
  // the control state is a legal one
  wire fa_state = ms <= M_ESC;
  // the device key is out only after a verified boot in DEV or PROD, and is
  // zero otherwise
  wire fa_key   = !key_valid || cpu_en && boot_ok && boot_dev && ms != M_ESC;
  wire fa_keyz  = key_valid || key_out == '0;
  // in DEV and PROD the CPU runs only with the key (after the digest matched);
  // in TEST and RMA without; never in RAW, SCRAP or INVALID
  wire fa_cpu   = !cpu_en || boot_ok && (boot_dev ? key_valid : lc == S_TEST || lc == S_RMA);
  // escalated: no CPU, no debug, no key, no OTP access, no secret in the hash
  wire fa_esc   = ms != M_ESC || !cpu_en && !dbg_en && !key_valid && !otp_req && blk == '0 && inner == '0
                                 && hh == '0 && !sha_run;
  // the UDS is read only for the key derivation (or the read-back of its own
  // program in TEST), and never to the command port
  wire fa_uds   = !(f_rd && otp_addr < O_DIG) || ms == M_KLD || ms == M_PV && lc == S_TEST;
  wire fa_cmdrd = ms != M_RD || otp_addr >= O_DIG;
  // a command program only into a word open in this state
  wire fa_prog  = !(f_pg && ms == M_PG) || prog_ok(otp_addr, lc);
  // the lifecycle and scrap words are programmed only by a transition, which
  // the command port cannot reach after three wrong tokens or a transition
  wire fa_lcw   = !(f_pg && (otp_addr == O_LC || otp_addr == O_SCRAP)) || ms == M_TRPG && tfail != 2'd3 && !lc_pend;
  wire fa_lcv   = !(f_pg && otp_addr == O_LC) || otp_wdata == lc_word(tgt) && trans_ok(lc, tgt) && tgt != S_SCRAP;
  wire fa_scrap = !(f_pg && otp_addr == O_SCRAP) || tgt == S_SCRAP && otp_wdata == 32'hFFFF_FFFF;
  // an image is taken only in DEV or PROD before the boot decision
  wire fa_img   = !img_ready || boot_dev && !boot_done;
  // no OTP program outside the command and transition states
  wire fa_pgst  = !f_pg || ms == M_PG || ms == M_TRPG;
  always @(*) if (f_chk) assert (fa_state);
  always @(*) if (f_chk) assert (fa_key);
  always @(*) if (f_chk) assert (fa_keyz);
  always @(*) if (f_chk) assert (fa_cpu);
  always @(*) if (f_chk) assert (fa_esc);
  always @(*) if (f_chk) assert (fa_uds);
  always @(*) if (f_chk) assert (fa_cmdrd);
  always @(*) if (f_chk) assert (fa_prog);
  always @(*) if (f_chk) assert (fa_lcw);
  always @(*) if (f_chk) assert (fa_lcv);
  always @(*) if (f_chk) assert (fa_scrap);
  always @(*) if (f_chk) assert (fa_img);
  always @(*) if (f_chk) assert (fa_pgst);
