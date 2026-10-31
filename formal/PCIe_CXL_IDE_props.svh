// SPDX-License-Identifier: Apache-2.0
// Formal properties of PCIe_CXL_IDE_top (included at the end of the module
// under `ifdef FORMAL; run with scripts/formal/run_formal.sh PCIe_CXL_IDE).
// Every input is free after the first clock: stream configuration, key
// commands, keys, blocks, flags and back-pressure may change in any clock.
// The properties are the key-handling and framing rules of the core; each
// is a wire (fa_*) with its own assertion.
  logic f_done = 1'b0;                   // past the first clock (reset)
  wire  f_init = !f_done;
  always @(posedge clk) f_done <= 1'b1;
  always @(*) if (f_init) assume (!rst_n);
  wire  f_chk = !f_init && rst_n;

  logic fa_zero, fa_ctr, fa_sec;
  always @(*) begin
    fa_zero = 1'b1; fa_ctr = 1'b1; fa_sec = 1'b1;
    for (int i = 0; i < NSL; i++) begin
      // an unloaded slot holds no key and no counter
      if (!kv_tx[i] && (ktx[256 * i +: 256] != '0 || ctx[CTR_W * i +: CTR_W] != '0)) fa_zero = 1'b0;
      if (!kv_rx[i] && (krx[256 * i +: 256] != '0 || crx[CTR_W * i +: CTR_W] != '0)) fa_zero = 1'b0;
      // a loaded slot's counter starts at 1 and never wraps to 0
      if (kv_tx[i] && ctx[CTR_W * i +: CTR_W] == '0) fa_ctr = 1'b0;
      if (kv_rx[i] && crx[CTR_W * i +: CTR_W] == '0) fa_ctr = 1'b0;
    end
    // a Secure stream's active key set has a loaded key
    for (int s = 0; s < NS; s++) begin
      if (sec_tx[s] && kv_tx[6 * s + (ks_tx[s] ? 3 : 0) +: 3] == 3'b000) fa_sec = 1'b0;
      if (sec_rx[s] && kv_rx[6 * s + (ks_rx[s] ? 3 : 0) +: 3] == 3'b000) fa_sec = 1'b0;
    end
  end
  // the state registers hold encoded states only
  wire fa_state = t <= T_BYP && r <= R_BYP;
  // output framing: a prefix is 4 bytes and never last; a MAC block is last,
  // 12 bytes or (nullified) 0 bytes; only a MAC is nullified (bypass blocks
  // pass unchanged, so their byte counts are not checked)
  wire fa_pfx   = !txo_valid || txo_kind != K_PFX || txo_bytes == 5'd4 && !txo_last && !txo_cm;
  wire fa_mac   = !txo_valid || txo_kind != K_MAC || txo_last && txo_bytes == (txo_bad ? 5'd0 : 5'd12);
  wire fa_tbad  = !txo_valid || !txo_bad || txo_kind == K_MAC;
  // receive: an END block is last and empty; only an END block is bad
  wire fa_end   = !rxo_valid || rxo_kind != K_END || rxo_last && rxo_bytes == 5'd0;
  wire fa_rbad  = !rxo_valid || !rxo_bad || rxo_kind == K_END;
  always @(*) if (f_chk) assert (fa_zero);
  always @(*) if (f_chk) assert (fa_ctr);
  always @(*) if (f_chk) assert (fa_sec);
  always @(*) if (f_chk) assert (fa_state);
  always @(*) if (f_chk) assert (fa_pfx);
  always @(*) if (f_chk) assert (fa_mac);
  always @(*) if (f_chk) assert (fa_tbad);
  always @(*) if (f_chk) assert (fa_end);
  always @(*) if (f_chk) assert (fa_rbad);
