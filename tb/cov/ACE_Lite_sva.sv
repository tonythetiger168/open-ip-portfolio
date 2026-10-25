// SPDX-License-Identifier: Apache-2.0
// ACE-Lite slave: concurrent SVA (handshake rules, per-beat range check,
// independent shadow-memory model with byte strobes) + functional coverage.
`include "cov_macros.svh"
module ACE_Lite_sva #(parameter int DW = 32, AW = 32) (
  input logic            clk, rst_n,
  input logic [AW-1:0]   awaddr, araddr,
  input logic [7:0]      awlen, arlen,
  input logic [2:0]      awsize, arsize, awsnoop,
  input logic [1:0]      awburst, arburst, bresp, rresp, awdomain, awbar, ardomain, arbar,
  input logic [3:0]      arsnoop,
  input logic            awvalid, awready, wvalid, wready, wlast, bvalid, bready,
  input logic            arvalid, arready, rvalid, rready, rlast,
  input logic [DW-1:0]   wdata, rdata,
  input logic [DW/8-1:0] wstrb,
  input logic            irq
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;
  wire aw_hs = awvalid && awready, w_hs = wvalid && wready, b_hs = bvalid && bready;
  wire ar_hs = arvalid && arready, r_hs = rvalid && rready;

  function automatic logic hdr_err(input logic [1:0] bu, input logic [2:0] sz,
                                   input logic [AW-1:0] a);
    return (bu != 2'b01) || (sz > 3'd2) || (a[AW-1:10] != '0);
  endfunction

  // ---------------- independent reference model ----------------
  // shadow of the (un-reset) memory: survives rst_n like the RTL array
  logic [DW-1:0] shadow [0:255];
  initial for (int i = 0; i < 256; i++) shadow[i] = '0;
  logic [AW-1:0] m_wa, m_ra;
  logic [7:0]    m_wlen, m_wbeat, m_rlen, m_rbeat;
  logic          m_werr, m_rerr, m_wbusy, m_rbusy, m_bpend;
  wire           w_oor  = m_wa[AW-1:10] != '0;
  wire           r_oor  = m_ra[AW-1:10] != '0;
  wire           w_end  = wlast || (m_wbeat == m_wlen);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_wbusy <= 0; m_rbusy <= 0; m_bpend <= 0; m_wbeat <= 0; m_rbeat <= 0;
      m_wa <= '0; m_ra <= '0; m_wlen <= 0; m_rlen <= 0; m_werr <= 0; m_rerr <= 0;
    end else begin
      if (aw_hs) begin
        m_wbusy <= 1; m_wa <= awaddr; m_wlen <= awlen; m_wbeat <= 0;
        m_werr <= hdr_err(awburst, awsize, awaddr);
      end else if (w_hs) begin
        if (!m_werr && !w_oor)
          for (int b = 0; b < DW/8; b++)
            if (wstrb[b]) shadow[m_wa[9:2]][8*b +: 8] <= wdata[8*b +: 8];
        if (w_oor) m_werr <= 1;
        m_wa <= m_wa + 4; m_wbeat <= m_wbeat + 1;
        if (w_end) m_bpend <= 1;
      end
      if (b_hs) begin m_wbusy <= 0; m_bpend <= 0; end
      if (ar_hs) begin
        m_rbusy <= 1; m_ra <= araddr; m_rlen <= arlen; m_rbeat <= 0;
        m_rerr <= hdr_err(arburst, arsize, araddr);
      end else if (r_hs) begin
        m_ra <= m_ra + 4; m_rbeat <= m_rbeat + 1;
        if (m_rbeat == m_rlen) m_rbusy <= 0;
      end
    end
  end
  wire r_bad = m_rerr || r_oor;

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_quiet, !rst_n, !bvalid && !rvalid && !wready && !irq)
  `SVA_NXT(a_b_stable, bvalid && !bready, bvalid && $stable(bresp))
  `SVA_NXT(a_r_stable, rvalid && !rready,
           rvalid && $stable(rdata) && $stable(rresp) && $stable(rlast))
  `SVA_IMP(a_aw_only_idle, awready, !m_wbusy)
  `SVA_IMP(a_ar_only_idle, arready, !m_rbusy)
  `SVA_IMP(a_wready_in_burst, wready, m_wbusy && !m_bpend)
  `SVA_IMP(a_bvalid_model, bvalid, m_bpend)
  `SVA_IMP(a_one_write_phase, 1'b1 ##0 (awready || wready || bvalid), $onehot({awready, wready, bvalid}))
  `SVA_IMP(a_bresp_model, bvalid, bresp == (m_werr ? SLVERR : OKAY))
  `SVA_IMP(a_rvalid_model, rvalid, m_rbusy)
  `SVA_IMP(a_rresp_model, rvalid, rresp == (r_bad ? SLVERR : OKAY) && rlast == (m_rbeat == m_rlen))
  `SVA_IMP(a_rdata_model, rvalid, rdata == (r_bad ? '0 : shadow[m_ra[9:2]]))
  `SVA_NXT(a_irq_on_werr, w_hs && w_end && (m_werr || w_oor), irq)
  `SVA_NXT(a_irq_on_rerr, r_hs && m_rbeat == m_rlen && r_bad, irq)
  `SVA_IMP(a_irq_cause, irq, $past((w_hs && w_end && (m_werr || w_oor)) ||
                                   (r_hs && m_rbeat == m_rlen && r_bad)))

  // ---------------- functional coverage ----------------
  covergroup cg_aw @(posedge clk);
    option.per_instance = 1;
    cp_burst: coverpoint awburst iff (rst_n && aw_hs)
      { bins fixed = {0}; bins incr = {1}; bins wrap = {2}; bins rsvd = {3}; }
    cp_len: coverpoint awlen iff (rst_n && aw_hs)
      { bins one = {0}; bins mid = {[1:14]}; bins max16 = {15}; bins long_ = {[16:255]}; }
    cp_size: coverpoint awsize iff (rst_n && aw_hs) { bins ok = {[0:2]}; bins too_big = {[3:7]}; }
    cp_addr: coverpoint (awaddr[AW-1:10] != 0) iff (rst_n && aw_hs) { bins in_rng = {0}; bins oor = {1}; }
    cp_snoop: coverpoint awsnoop iff (rst_n && aw_hs) { bins zero = {0}; bins nonzero = {[1:7]}; }
    cp_bar: coverpoint awbar iff (rst_n && aw_hs) { bins none = {0}; bins barrier = {[1:3]}; }
  endgroup
  covergroup cg_ar @(posedge clk);
    option.per_instance = 1;
    cp_burst: coverpoint arburst iff (rst_n && ar_hs)
      { bins fixed = {0}; bins incr = {1}; bins wrap = {2}; bins rsvd = {3}; }
    cp_len: coverpoint arlen iff (rst_n && ar_hs)
      { bins one = {0}; bins mid = {[1:14]}; bins max16 = {15}; bins long_ = {[16:255]}; }
    cp_size: coverpoint arsize iff (rst_n && ar_hs) { bins ok = {[0:2]}; bins too_big = {[3:7]}; }
    cp_addr: coverpoint (araddr[AW-1:10] != 0) iff (rst_n && ar_hs) { bins in_rng = {0}; bins oor = {1}; }
    cp_snoop: coverpoint arsnoop iff (rst_n && ar_hs) { bins zero = {0}; bins nonzero = {[1:15]}; }
    cp_bar: coverpoint arbar iff (rst_n && ar_hs) { bins none = {0}; bins barrier = {[1:3]}; }
  endgroup
  covergroup cg_w @(posedge clk);
    option.per_instance = 1;
    cp_strb: coverpoint wstrb iff (rst_n && w_hs)
      { bins none = {0}; bins full = {{(DW/8){1'b1}}}; bins partial = default; }
    cp_last: coverpoint {wlast, m_wbeat == m_wlen} iff (rst_n && w_hs)
      { bins normal_last = {2'b11}; bins mid = {2'b00}; bins early_last = {2'b10};
        bins missing_last = {2'b01}; }
  endgroup
  covergroup cg_resp @(posedge clk);
    option.per_instance = 1;
    cp_b: coverpoint bresp iff (rst_n && b_hs) { bins okay = {OKAY}; bins slverr = {SLVERR}; }
    cp_r: coverpoint rresp iff (rst_n && r_hs) { bins okay = {OKAY}; bins slverr = {SLVERR}; }
  endgroup
  cg_aw u_cg_aw = new; cg_ar u_cg_ar = new; cg_w u_cg_w = new; cg_resp u_cg_resp = new;

  `FC(b_backpressure, bvalid && !bready)
  `FC(r_backpressure, rvalid && !rready)
  `FC(w_bubble, wready && !wvalid)
  `FC(rw_concurrent, m_wbusy && m_rbusy)
  `FC(aw_ar_same_cycle, aw_hs && ar_hs)
  `FC(write_crosses_1kb, w_hs && w_oor && !m_werr)
  `FC(read_crosses_1kb, r_hs && r_oor && !m_rerr)
  `FC_RST(reset_mid_burst, rst_n && wready && rvalid ##1 !rst_n)
endmodule

bind ACE_Lite_top ACE_Lite_sva #(.DW(DW), .AW(AW)) u_sva (.*);
