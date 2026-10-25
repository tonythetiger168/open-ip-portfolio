// SPDX-License-Identifier: Apache-2.0
// AXI3 slave (WID, 4-bit len): concurrent SVA (handshake rules, response decode, independent
// shadow-memory model with byte strobes) + functional coverage.
`include "cov_macros.svh"
module AXI_sva #(parameter int DW = 32, AW = 32) (
  input logic            clk, rst_n,
  input logic [3:0]      awid, arid, bid, rid, wid,
  input logic [AW-1:0]   awaddr, araddr,
  input logic [3:0]      awlen, arlen,
  input logic [2:0]      awsize, arsize,
  input logic [1:0]      awburst, arburst, bresp, rresp,
  input logic            awvalid, awready, wvalid, wready, wlast, bvalid, bready,
  input logic            arvalid, arready, rvalid, rready, rlast,
  input logic [DW-1:0]   wdata, rdata,
  input logic [DW/8-1:0] wstrb,
  input logic            irq
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10, DECERR = 2'b11;
  wire aw_hs = awvalid && awready, w_hs = wvalid && wready, b_hs = bvalid && bready;
  wire ar_hs = arvalid && arready, r_hs = rvalid && rready;

  function automatic logic in_rng(input logic [AW-1:0] a);
    return (a[AW-1:10] == '0) && (a[1:0] == 2'b00);
  endfunction
  function automatic logic [1:0] addr_resp(input logic [3:0] id, input logic [2:0] sz,
      input logic [1:0] bu, input logic [3:0] len, input logic [AW-1:0] a);
    if (sz > 3'd2 || bu == 2'b11) return DECERR;   // any ID / len is legal
    if (!in_rng(a) || bu == 2'b10) return SLVERR;
    return OKAY;
  endfunction

  // ---------------- independent reference model ----------------
  // shadow of the (un-reset) register file: survives rst_n like the RTL memory
  logic [DW-1:0] shadow [0:255];
  initial for (int i = 0; i < 256; i++) shadow[i] = '0;
  logic [AW-1:0] m_wa, m_ra;          // model addresses
  logic [3:0]    m_wlen, m_wbeat, m_rlen, m_rbeat;
  logic [1:0]    m_wbu, m_rbu, m_bresp, m_rerr;
  logic          m_wbusy, m_rbusy;
  logic [3:0]    m_wid, m_rid;
  wire           w_last_exp = (m_wbeat == m_wlen);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_wbusy <= 0; m_rbusy <= 0; m_wbeat <= 0; m_rbeat <= 0;
      m_wa <= '0; m_ra <= '0; m_wlen <= 0; m_rlen <= 0; m_wbu <= 0; m_rbu <= 0;
      m_bresp <= OKAY; m_rerr <= OKAY; m_wid <= 0; m_rid <= 0;
    end else begin
      if (aw_hs) begin
        m_wbusy <= 1; m_wa <= awaddr; m_wlen <= awlen; m_wbeat <= 0; m_wbu <= awburst;
        m_wid <= awid; m_bresp <= addr_resp(awid, awsize, awburst, awlen, awaddr);
      end else if (w_hs) begin
        if (m_bresp == OKAY) begin
          if (wid != m_wid) m_bresp <= SLVERR;          // no write interleaving
          else if (in_rng(m_wa)) begin
            for (int b = 0; b < DW/8; b++)
              if (wstrb[b]) shadow[m_wa[9:2]][8*b +: 8] <= wdata[8*b +: 8];
            if (wlast != w_last_exp) m_bresp <= SLVERR;
          end else m_bresp <= SLVERR;
        end
        if (!(wlast || w_last_exp)) begin
          m_wbeat <= m_wbeat + 1;
          if (m_wbu == 2'b01) m_wa <= m_wa + 4;
        end
      end
      if (b_hs) m_wbusy <= 0;
      if (ar_hs) begin
        m_rbusy <= 1; m_ra <= araddr; m_rlen <= arlen; m_rbeat <= 0; m_rbu <= arburst;
        m_rid <= arid; m_rerr <= addr_resp(arid, arsize, arburst, arlen, araddr);
      end else if (r_hs) begin
        if (m_rbeat == m_rlen) m_rbusy <= 0;
        else begin
          m_rbeat <= m_rbeat + 1;
          if (m_rbu == 2'b01) m_ra <= m_ra + 4;
        end
      end
    end
  end
  wire [1:0] r_exp = (m_rerr == OKAY && !in_rng(m_ra)) ? SLVERR : m_rerr;

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_quiet, !rst_n, !bvalid && !rvalid && !wready && !irq)
  // slave-driven channel stability under backpressure
  `SVA_NXT(a_b_stable, bvalid && !bready, bvalid && $stable(bresp) && $stable(bid))
  `SVA_NXT(a_r_stable, rvalid && !rready,
           rvalid && $stable(rdata) && $stable(rresp) && $stable(rlast) && $stable(rid))
  // single outstanding transaction per direction
  `SVA_IMP(a_aw_only_idle, awready, !m_wbusy)
  `SVA_IMP(a_ar_only_idle, arready, !m_rbusy)
  `SVA_IMP(a_wready_in_burst, wready, m_wbusy && !bvalid)
  `SVA_IMP(a_bvalid_after_burst, $rose(bvalid), $past(w_hs && (wlast || w_last_exp)))
  // response / data integrity against the reference model
  `SVA_IMP(a_bresp_model, bvalid, bresp == m_bresp && bid == m_wid)
  `SVA_IMP(a_rresp_model, rvalid, rresp == r_exp && rid == m_rid)
  `SVA_IMP(a_rlast_model, rvalid, rlast == (m_rbeat == m_rlen))
  `SVA_IMP(a_rdata_model, rvalid && r_exp == OKAY, rdata == shadow[m_ra[9:2]])
  `SVA_IMP(a_rdata_zero_oor, rvalid && !in_rng(m_ra), rdata == '0)
  // irq: sticky, raised by any error-bearing handshake
  `SVA_NXT(a_irq_sticky, irq, irq)
  `SVA_NXT(a_irq_on_aw_err, aw_hs && addr_resp(awid, awsize, awburst, awlen, awaddr) != OKAY, irq)
  `SVA_NXT(a_irq_on_r_err, r_hs && rresp != OKAY, irq)
  `SVA_IMP(a_irq_cause, $rose(irq), $past(aw_hs || w_hs || ar_hs || r_hs))

  // ---------------- functional coverage ----------------
  covergroup cg_aw @(posedge clk);
    option.per_instance = 1;
    cp_burst: coverpoint awburst iff (rst_n && aw_hs)
      { bins fixed = {0}; bins incr = {1}; bins wrap = {2}; bins rsvd = {3}; }
    cp_len: coverpoint awlen iff (rst_n && aw_hs)
      { bins one = {0}; bins mid = {[1:14]}; bins max16 = {15}; }
    cp_size: coverpoint awsize iff (rst_n && aw_hs)
      { bins b1 = {0}; bins b2 = {1}; bins b4 = {2}; bins too_big = {[3:7]}; }
    cp_id: coverpoint (awid != 0) iff (rst_n && aw_hs) { bins zero = {0}; bins nonzero = {1}; }
    cp_addr: coverpoint {awaddr[AW-1:10] != 0, awaddr[1:0] != 0} iff (rst_n && aw_hs)
      { bins ok = {2'b00}; bins misaligned = {2'b01}; bins oor = {2'b10}; }
    cp_burst_ok: coverpoint awburst iff (rst_n && aw_hs && awburst inside {0, 1})
      { bins fixed = {0}; bins incr = {1}; }
    cp_len_ok: coverpoint awlen iff (rst_n && aw_hs && awlen < 16)
      { bins one = {0}; bins mid = {[1:14]}; bins max16 = {15}; }
    x_burst_len: cross cp_burst_ok, cp_len_ok;
  endgroup
  covergroup cg_ar @(posedge clk);
    option.per_instance = 1;
    cp_burst: coverpoint arburst iff (rst_n && ar_hs)
      { bins fixed = {0}; bins incr = {1}; bins wrap = {2}; bins rsvd = {3}; }
    cp_len: coverpoint arlen iff (rst_n && ar_hs)
      { bins one = {0}; bins mid = {[1:14]}; bins max16 = {15}; }
    cp_size: coverpoint arsize iff (rst_n && ar_hs)
      { bins b4 = {2}; bins narrow = {[0:1]}; bins too_big = {[3:7]}; }
    cp_id: coverpoint (arid != 0) iff (rst_n && ar_hs) { bins zero = {0}; bins nonzero = {1}; }
    cp_addr: coverpoint {araddr[AW-1:10] != 0, araddr[1:0] != 0} iff (rst_n && ar_hs)
      { bins ok = {2'b00}; bins misaligned = {2'b01}; bins oor = {2'b10}; }
  endgroup
  covergroup cg_w @(posedge clk);
    option.per_instance = 1;
    cp_strb: coverpoint wstrb iff (rst_n && w_hs)
      { bins none = {0}; bins full = {{(DW/8){1'b1}}}; bins partial = default; }
    cp_last: coverpoint {wlast, w_last_exp} iff (rst_n && w_hs)
      { bins normal_last = {2'b11}; bins mid = {2'b00}; bins early_last = {2'b10};
        bins missing_last = {2'b01}; }
  endgroup
  covergroup cg_resp @(posedge clk);
    option.per_instance = 1;
    cp_b: coverpoint bresp iff (rst_n && b_hs) { bins okay = {OKAY}; bins slverr = {SLVERR}; bins decerr = {DECERR}; }
    cp_r: coverpoint rresp iff (rst_n && r_hs) { bins okay = {OKAY}; bins slverr = {SLVERR}; bins decerr = {DECERR}; }
  endgroup
  cg_aw u_cg_aw = new; cg_ar u_cg_ar = new; cg_w u_cg_w = new; cg_resp u_cg_resp = new;

  `FC(wid_mismatch, w_hs && wid != m_wid)
  `FC(b_backpressure, bvalid && !bready)
  `FC(r_backpressure, rvalid && !rready)
  `FC(w_bubble, m_wbusy && !bvalid && !wvalid)
  `FC(rw_concurrent, m_wbusy && m_rbusy)
  `FC(incr_runs_out_of_range, w_hs && !in_rng(m_wa) && m_bresp == OKAY && $past(m_wbusy))
  `FC(read_runs_out_of_range, r_hs && rresp == SLVERR && m_rerr == OKAY)
  `FC(aw_ar_same_cycle, aw_hs && ar_hs)
endmodule

bind AXI_top AXI_sva #(.DW(DW), .AW(AW)) u_sva (.*);
