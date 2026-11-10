// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// AXI_Async_Bridge checker: one independent order model per channel. A beat
// is queued at its write-side handshake (on that side's clock) and must be
// the next beat out on the other side, unchanged. Also: no beat beyond
// DEPTH in flight, VALID / payload held while READY is low, VALID low in
// reset. DUT outputs are read through copies taken at the falling edge of
// their own clock; each check result is registered and asserted one clock
// later, so the model never races the DUT.
`include "cov_macros.svh"
module AXI_Async_Bridge_sva #(parameter int IDW = 8, DEPTH = 8) (
  input logic           s_clk, s_rst_n, m_clk, m_rst_n,
  input logic [IDW-1:0] s_awid, s_bid, s_arid, s_rid, m_awid, m_bid, m_arid, m_rid,
  input logic [31:0]    s_awaddr, s_wdata, s_araddr, s_rdata, m_awaddr, m_wdata, m_araddr, m_rdata,
  input logic [7:0]     s_awlen, s_arlen, m_awlen, m_arlen,
  input logic [2:0]     s_awsize, s_arsize, m_awsize, m_arsize,
  input logic [1:0]     s_awburst, s_arburst, s_bresp, s_rresp, m_awburst, m_arburst, m_bresp, m_rresp,
  input logic [3:0]     s_wstrb, m_wstrb,
  input logic           s_awvalid, s_awready, s_wlast, s_wvalid, s_wready, s_bvalid, s_bready,
  input logic           s_arvalid, s_arready, s_rlast, s_rvalid, s_rready,
  input logic           m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready,
  input logic           m_arvalid, m_arready, m_rlast, m_rvalid, m_rready, resp_err
);
  `COV_CLOCKING(s_clk, !s_rst_n || !m_rst_n)
  wire rst_n = s_rst_n && m_rst_n;

  // One channel: NAME, payload width, write clock, write VALID / READY /
  // payload, read clock, read VALID / READY / payload.
`define ABR_CH(NAME, W, WCLK, WV, WR, WD, RCLK, RV, RR, RD) \
  logic [W-1:0] q_``NAME [$]; \
  logic         qwr_``NAME, qrv_``NAME; \
  logic [W-1:0] qrd_``NAME; \
  always @(negedge WCLK) qwr_``NAME <= WR; \
  always @(negedge RCLK) begin qrv_``NAME <= RV; qrd_``NAME <= RD; end \
  logic push_``NAME, room_``NAME, pe_``NAME, pl_``NAME; \
  always @(posedge WCLK or negedge rst_n) begin \
    if (!rst_n) begin \
      q_``NAME.delete(); push_``NAME <= 0; room_``NAME <= 1; pe_``NAME <= 0; pl_``NAME <= 0; \
    end else begin \
      push_``NAME <= (WV) && qwr_``NAME; \
      room_``NAME <= q_``NAME.size() < DEPTH; \
      pe_``NAME   <= (WV) && qwr_``NAME && q_``NAME.size() == 0; \
      pl_``NAME   <= (WV) && qwr_``NAME && q_``NAME.size() == DEPTH - 1; \
      if ((WV) && qwr_``NAME) q_``NAME.push_back(WD); \
    end \
  end \
  logic pop_``NAME, ok_``NAME; \
  always @(posedge RCLK or negedge rst_n) begin \
    if (!rst_n) begin \
      pop_``NAME <= 0; ok_``NAME <= 1; \
    end else begin \
      pop_``NAME <= qrv_``NAME && (RR); \
      ok_``NAME  <= q_``NAME.size() != 0 && q_``NAME[0] == qrd_``NAME; \
      if (qrv_``NAME && (RR) && q_``NAME.size() != 0) void'(q_``NAME.pop_front()); \
    end \
  end \
  `SVA_IMP_CK(a_``NAME``_order, RCLK, pop_``NAME, ok_``NAME) \
  `SVA_IMP_CK(a_``NAME``_room, WCLK, push_``NAME, room_``NAME) \
  a_``NAME``_hold: assert property (@(posedge RCLK) (RV) && !(RR) |=> (RV) && $stable(RD)) \
    else $display("SVA_FAIL: %s @%0t", `"a_``NAME``_hold`", $time); \
  a_``NAME``_hold__ante: cover property (@(posedge RCLK) (RV) && !(RR)); \
  `FC_CK(NAME``_full, WCLK, (WV) && !(WR)) \
  `FC_CK(NAME``_empty_wait, RCLK, (RR) && !(RV)) \
  `FC_CK(NAME``_push_into_empty, WCLK, pe_``NAME) \
  `FC_CK(NAME``_push_last_slot, WCLK, pl_``NAME)

  `ABR_CH(aw, IDW + 45, s_clk, s_awvalid, s_awready, ({s_awid, s_awaddr, s_awlen, s_awsize, s_awburst}),
          m_clk, m_awvalid, m_awready, ({m_awid, m_awaddr, m_awlen, m_awsize, m_awburst}))
  `ABR_CH(w, 37, s_clk, s_wvalid, s_wready, ({s_wdata, s_wstrb, s_wlast}),
          m_clk, m_wvalid, m_wready, ({m_wdata, m_wstrb, m_wlast}))
  `ABR_CH(ar, IDW + 45, s_clk, s_arvalid, s_arready, ({s_arid, s_araddr, s_arlen, s_arsize, s_arburst}),
          m_clk, m_arvalid, m_arready, ({m_arid, m_araddr, m_arlen, m_arsize, m_arburst}))
  `ABR_CH(b, IDW + 2, m_clk, m_bvalid, m_bready, ({m_bid, m_bresp}),
          s_clk, s_bvalid, s_bready, ({s_bid, s_bresp}))
  `ABR_CH(r, IDW + 35, m_clk, m_rvalid, m_rready, ({m_rid, m_rdata, m_rresp, m_rlast}),
          s_clk, s_rvalid, s_rready, ({s_rid, s_rdata, s_rresp, s_rlast}))
`undef ABR_CH

  // RESP_ERR: exactly one clock after each error response beat on the s side
  wire err_hs = (s_bvalid && s_bready && s_bresp[1]) || (s_rvalid && s_rready && s_rresp[1]);
  `SVA_NXT(a_resp_err_on_err, err_hs, resp_err)
  `SVA_IMP(a_resp_err_cause, resp_err, $past(err_hs))
  `FC(both_err_same_clock, s_bvalid && s_bready && s_bresp[1] && s_rvalid && s_rready && s_rresp[1])
  // VALID low while either side is in reset
  `SVA_RST(a_reset_quiet, !s_rst_n && !m_rst_n,
           !m_awvalid && !m_wvalid && !m_arvalid && !s_bvalid && !s_rvalid && !resp_err)

  // ---------------- functional coverage ----------------
  // clock ratio: s_clk edges in the last m_clk period
  int s_edges, s_last;
  logic [1:0] ratio;
  always @(posedge s_clk) s_edges <= s_edges + 1;
  always @(posedge m_clk) begin
    ratio  <= (s_edges - s_last == 0) ? 2'd0 : (s_edges - s_last == 1) ? 2'd1 : 2'd2;
    s_last <= s_edges;
  end
  covergroup cg_ratio @(posedge m_clk);
    cp_ratio: coverpoint ratio iff (rst_n) { bins s_slower = {0}; bins similar = {1}; bins s_faster = {2}; }
    cp_m_stall: coverpoint (m_awvalid && !m_awready) iff (rst_n) { bins flowing = {0}; bins stalled = {1}; }
    cp_s_full: coverpoint (s_wvalid && !s_wready) iff (rst_n) { bins room = {0}; bins full = {1}; }
    x_ratio_stall: cross cp_ratio, cp_m_stall;
    x_ratio_full: cross cp_ratio, cp_s_full;
  endgroup
  function automatic logic [1:0] dcls(input logic [31:0] v);
    return (v == '0) ? 2'd0 : (v == '1) ? 2'd1 : (v == 32'h5555_5555 || v == 32'hAAAA_AAAA) ? 2'd2 : 2'd3;
  endfunction
  covergroup cg_m @(posedge m_clk);
    cp_awburst: coverpoint m_awburst iff (rst_n && m_awvalid && m_awready);
    cp_awsize: coverpoint m_awsize iff (rst_n && m_awvalid && m_awready);
    cp_awlen: coverpoint m_awlen iff (rst_n && m_awvalid && m_awready)
      { bins one = {0}; bins short = {[1:15]}; bins long = {[16:254]}; bins max = {255}; }
    cp_arburst: coverpoint m_arburst iff (rst_n && m_arvalid && m_arready);
    cp_arsize: coverpoint m_arsize iff (rst_n && m_arvalid && m_arready);
    cp_arlen: coverpoint m_arlen iff (rst_n && m_arvalid && m_arready)
      { bins one = {0}; bins short = {[1:15]}; bins long = {[16:254]}; bins max = {255}; }
    cp_wdata: coverpoint dcls(m_wdata) iff (rst_n && m_wvalid && m_wready)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_wstrb: coverpoint m_wstrb iff (rst_n && m_wvalid && m_wready)
      { bins none = {0}; bins full = {4'hF}; bins partial = default; }
    cp_wlast: coverpoint m_wlast iff (rst_n && m_wvalid && m_wready);
  endgroup
  covergroup cg_s @(posedge s_clk);
    cp_bresp: coverpoint s_bresp iff (rst_n && s_bvalid && s_bready)
      { bins okay = {0}; bins exokay = {1}; bins slverr = {2}; bins decerr = {3}; }
    cp_rresp: coverpoint s_rresp iff (rst_n && s_rvalid && s_rready)
      { bins okay = {0}; bins exokay = {1}; bins slverr = {2}; bins decerr = {3}; }
    cp_rdata: coverpoint dcls(s_rdata) iff (rst_n && s_rvalid && s_rready)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rlast: coverpoint s_rlast iff (rst_n && s_rvalid && s_rready);
  endgroup
  cg_ratio u_cg_ratio = new; cg_m u_cg_m = new; cg_s u_cg_s = new;

  // reset while beats are in flight
  `FC_RST(reset_with_data, !rst_n && $past(m_awvalid && m_wvalid && m_arvalid && s_bvalid && s_rvalid))
endmodule

bind AXI_Async_Bridge_top AXI_Async_Bridge_sva #(.IDW(IDW), .DEPTH(DEPTH)) u_sva (.*);
