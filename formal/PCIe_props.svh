// SPDX-License-Identifier: Apache-2.0
// Formal properties of PCIe_top (included at the end of the module under
// `ifdef FORMAL; run with scripts/formal/run_formal.sh PCIe). The symbol
// inputs, the host side and reset are left free after the first clock, so
// the far side may send anything at all. Each property is a wire (fa_*)
// with its own assertion, so a counterexample shows which one failed.
  logic f_done = 1'b0;                   // past the first clock (reset)
  wire  f_init = !f_done;
  always @(posedge clk) f_done <= 1'b1;
  always @(*) if (f_init) assume (!rst_n);

  // credits held in the receive buffer, by type: received + advertised - allocated
  wire [7:0]  f_hp = rch[0] + 8'(HP) - cah[0], f_hn = rch[1] + 8'(HNP) - cah[1], f_hc = rch[2] + 8'(HC) - cah[2];
  wire [11:0] f_dp = rcd[0] + 12'(DP) - cad[0], f_dn = rcd[1] + 12'(DNP) - cad[1], f_dc = rcd[2] + 12'(DC) - cad[2];
  wire [9:0]  f_hsum = {2'b00, f_hp} + {2'b00, f_hn} + {2'b00, f_hc};
  wire [QW:0] f_nq = rqw - rqr;           // TLPs in the receive buffer

  wire f_chk = !f_init && rst_n;
  // states are legal
  wire fa_pst   = pst != 2'd3 && (pst == P_L0 || dl_up);
  wire fa_tst   = tst != 2'd3 && rst != 2'd3;
  // replay buffer: at most TXN written and unacknowledged, the sent ones among them
  wire fa_txn   = 12'(wr_seq - ackd - 12'd1) <= 12'(TXN);
  wire fa_sent  = 12'(nsent - ackd - 12'd1) <= 12'(wr_seq - ackd - 12'd1);
  wire fa_ready = !tlp_ready || dl_up && pst == P_L0;
  // receive buffer: at most RXN TLPs and RXN * MAXLEN bytes
  wire fa_rxn   = f_nq <= (QW+1)'(RXN) && rx_valid == (f_nq != '0);
  wire fa_rxb   = (RW+1)'(rcp - rrp) <= (RW+1)'(RXN * MAXLEN);
  // credits held never above those advertised; one header credit per TLP held
  wire fa_hcr   = f_hp <= 8'(HP) && f_hn <= 8'(HNP) && f_hc <= 8'(HC);
  wire fa_dcr   = f_dp <= 12'(DP) && f_dn <= 12'(DNP) && f_dc <= 12'(DC);
  wire fa_hsum  = f_hsum == {7'd0, f_nq};
  wire fa_rgot  = !rx_valid || LW'(rgot) < r_len && r_len <= LW'(MAXLEN);
  always @(*) if (f_chk) assert (fa_pst);
  always @(*) if (f_chk) assert (fa_tst);
  always @(*) if (f_chk) assert (fa_txn);
  always @(*) if (f_chk) assert (fa_sent);
  always @(*) if (f_chk) assert (fa_ready);
  always @(*) if (f_chk) assert (fa_rxn);
  always @(*) if (f_chk) assert (fa_rxb);
  always @(*) if (f_chk) assert (fa_hcr);
  always @(*) if (f_chk) assert (fa_dcr);
  always @(*) if (f_chk) assert (fa_hsum);
  always @(*) if (f_chk) assert (fa_rgot);
