// SPDX-License-Identifier: Apache-2.0
// Formal properties of CXL_top (included at the end of the module under
// `ifdef FORMAL; run with scripts/formal/run_formal.sh CXL). The link
// receive side, the CXL.io ports, the device BI requests, the HDM base,
// bi_en and reset are free after the first clock, so the host may send any
// beat stream, with or without credits. Each property is a wire (fa_*) with
// its own assertion, so a counterexample shows which one failed.
  logic f_done = 1'b0;                   // past the first clock (reset)
  wire  f_init = !f_done;
  always @(posedge clk) f_done <= 1'b1;
  always @(*) if (f_init) assume (!rst_n);

  // the last clock's link transmit side
  logic        f_prst = 1'b0, f_ptv = 1'b0, f_ptr = 1'b0;
  logic [63:0] f_ptd = '0;
  always @(posedge clk) begin
    f_prst <= rst_n; f_ptv <= tx_valid; f_ptr <= tx_ready; f_ptd <= tx_data;
  end
  // lines not Invalid
  logic [DW:0] f_sf;
  always @(*) begin
    f_sf = '0;
    for (int l = 0; l < LINES; l++) f_sf = f_sf + (DW+1)'(meta[l] != 2'b00);
  end

  wire f_chk = !f_init && rst_n;
  // the BI engine is in one of its three states; it takes a device request
  // only when idle with HDM-DB on
  wire fa_bist  = bi_st == BI_IDLE || bi_st == BI_SEND || bi_st == BI_WAIT;
  wire fa_bird  = !bi_ready || bi_en && bi_st == BI_IDLE;
  // the snoop filter count is the number of lines not Invalid
  wire fa_sf    = sf_cnt == f_sf;
  // buffers never hold more than their size
  wire fa_rq    = r_cnt <= (QW+1)'(RQD);
  wire fa_wq    = (WW+1)'(wqw - wqr) <= (WW+1)'(WQD);
  wire fa_io    = (IW+1)'(iwf - irf) <= (IW+1)'(IOD) && irw <= 5'd29 && (io_rx_valid || irw == 5'd0);
  // credits owed to the host never above the buffer sizes
  wire fa_owed  = p_req <= PQ'(RQD) && p_rwd <= PW'(WQD) && p_io <= PI'(IOD);
  // the unpacker stays inside the flit; an RwD owes at most one line of data
  wire fa_unp   = (!u_act || uj <= 5'd29) && ro_cnt <= 4'd8;
  // a DRS sends at most eight data units, only after its header
  wire fa_drs   = (!drs_hs || drs_v) && (!drs_v || drs_hs || d_wc == 3'd0);
  // a beat offered on the link stays until it is taken
  wire fa_hold  = !(f_prst && f_ptv && !f_ptr) || tx_valid && tx_data == f_ptd;
  always @(*) if (f_chk) assert (fa_bist);
  always @(*) if (f_chk) assert (fa_bird);
  always @(*) if (f_chk) assert (fa_sf);
  always @(*) if (f_chk) assert (fa_rq);
  always @(*) if (f_chk) assert (fa_wq);
  always @(*) if (f_chk) assert (fa_io);
  always @(*) if (f_chk) assert (fa_owed);
  always @(*) if (f_chk) assert (fa_unp);
  always @(*) if (f_chk) assert (fa_drs);
  always @(*) if (f_chk) assert (fa_hold);
