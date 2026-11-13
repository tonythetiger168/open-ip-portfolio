// SPDX-License-Identifier: Apache-2.0
// ddr_axi_slv (AXI4 subordinate front end of DDR4_AXI / LPDDR4_AXI): concurrent
// SVA against an independent transaction-level model, + functional coverage.
// The model takes each accepted burst, works out every beat address from the
// AXI4 rules (A3.4.1: FIXED, INCR, WRAP) and from it the host operations the
// burst must make, in order: per 32-bit beat the low then the high halfword
// at haddr = {h[24:11], 7'b0, h[10:0]} (h = byte address / 2); reads: one RD
// each, the R beat carrying the two halfwords read; writes: per halfword a WR
// of the data (both strobes), nothing (no strobe) or an RD then a WR of the
// merged halfword (one strobe). Errors (AxSIZE > 2, WLAST on the wrong beat):
// SLVERR, no host operation from the error on, the W beats taken up to
// WLAST. Also checked: the AR / AW turn-taking, RLAST / RID / BID, the R and
// B responses only once their work is done, N_RD / N_WR / N_RMW / N_ERR and
// ERR_IRQ.
`include "cov_macros.svh"
module ddr_axi_slv_sva (
  input logic        clk, rst_n,
  input logic [3:0]  s_awid, s_arid, s_bid, s_rid, s_wstrb,
  input logic [31:0] s_awaddr, s_araddr, s_wdata, s_rdata,
  input logic [7:0]  s_awlen, s_arlen,
  input logic [2:0]  s_awsize, s_arsize,
  input logic [1:0]  s_awburst, s_arburst, s_bresp, s_rresp,
  input logic        s_awvalid, s_awready, s_wlast, s_wvalid, s_wready, s_bvalid, s_bready,
  input logic        s_arvalid, s_arready, s_rlast, s_rvalid, s_rready,
  input logic        hvalid, hready, hdone,
  input logic [2:0]  hcmd,
  input logic [31:0] haddr,
  input logic [15:0] hwdata, hrdata,
  input logic [15:0] n_rd, n_wr, n_rmw, n_err,
  input logic        err_irq
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [2:0] C_RD = 3'd2, C_WR = 3'd3;

  // AXI4 A3.4.1 address of beat n
  function automatic logic [31:0] beat_addr(input logic [31:0] start, input logic [2:0] sz,
                                            input logic [1:0] bt, input logic [7:0] len, input logic [7:0] n);
    logic [32:0] nb, aligned, wsize, lower, a;
    nb = 33'd1 << sz;
    aligned = {1'b0, start} & ~(nb - 33'd1);
    if (bt == 2'b00 || n == 0) return start;
    a = aligned + 33'(n) * nb;
    if (bt == 2'b10) begin
      wsize = nb * (33'(len) + 33'd1);
      lower = {1'b0, start} & ~(wsize - 33'd1);
      if (a >= lower + wsize) a = a - wsize;
    end
    return a[31:0];
  endfunction
  function automatic logic [31:0] hmap(input logic [31:0] a, input logic h);
    logic [30:0] w;
    w = {a[31:2], h};
    return {w[24:11], 7'b0, w[10:0]};
  endfunction

  typedef enum logic [1:0] {M_IDLE, M_RD, M_WR} mph_e;
  mph_e        mph;
  logic        last_pref, bad, wr_resp_ok;
  logic [3:0]  id;
  logic [31:0] start;
  logic [7:0]  len, n, wn;       // beat (reads: current; writes: of the W beat held), W beats taken
  logic [2:0]  size;
  logic [1:0]  burst;
  // reads: halfwords read for the current beat
  logic [1:0]  r_iss, r_got;     // RDs issued / data taken for this beat
  logic        r_cap, r_capq;    // an HDONE of a read: take HRDATA next clock
  logic [15:0] r_lo, r_hi;
  // writes
  logic        w_have, w_last;   // a W beat is being worked on; its WLAST
  logic [31:0] w_data;
  logic [3:0]  w_strb;
  logic [1:0]  w_half;           // next halfword to look at (2: beat done)
  logic        w_rmw, w_rmw_got, w_capq;
  logic [15:0] w_rmw_d;
  logic        w_seen_last;      // the beat with WLAST has been taken
  logic [15:0] m_rd, m_wr, m_rmw, m_err;

  wire [31:0] ba = beat_addr(start, size, burst, len, n);
  wire        ar_hs = s_arvalid && s_arready;
  wire        aw_hs = s_awvalid && s_awready;
  wire        w_hs  = s_wvalid && s_wready;
  wire        r_hs  = s_rvalid && s_rready;
  wire        b_hs  = s_bvalid && s_bready;
  wire        h_hs  = hvalid && hready;
  // write: the halfword the next host operation is for
  wire [1:0]  s0 = w_strb[1:0], s1 = w_strb[3:2];
  wire        w_h  = (w_half == 0 && s0 == 2'b00) ? 1'b1 : w_half[0];
  wire [1:0]  w_s  = w_h ? s1 : s0;
  wire [15:0] w_d  = w_h ? w_data[31:16] : w_data[15:0];
  wire        w_pending = w_have && !bad && w_half != 2 && !(w_h && s1 == 2'b00) && w_s != 2'b00;
  wire [15:0] w_merged = {w_s[1] ? w_d[15:8] : w_rmw_d[15:8], w_s[0] ? w_d[7:0] : w_rmw_d[7:0]};
  wire        w_exp_rd = w_s != 2'b11 && !w_rmw;
  wire        w_bad_now = w_hs && (bad || s_wlast != (wn == len));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mph <= M_IDLE; last_pref <= 0; bad <= 0; id <= 0; start <= 0; len <= 0; n <= 0; wn <= 0; size <= 0; burst <= 0;
      r_iss <= 0; r_got <= 0; r_capq <= 0; r_lo <= 0; r_hi <= 0;
      w_have <= 0; w_last <= 0; w_data <= 0; w_strb <= 0; w_half <= 0; w_rmw <= 0; w_rmw_got <= 0;
      w_capq <= 0; w_rmw_d <= 0; w_seen_last <= 0; wr_resp_ok <= 0;
      m_rd <= 0; m_wr <= 0; m_rmw <= 0; m_err <= 0;
    end else begin
      r_capq <= mph == M_RD && hdone;
      w_capq <= mph == M_WR && hdone && w_rmw;   // the RD of a merge
      case (mph)
        M_IDLE:
          if (ar_hs) begin
            mph <= M_RD; last_pref <= 1; id <= s_arid; start <= s_araddr; len <= s_arlen; size <= s_arsize;
            burst <= s_arburst; bad <= s_arsize > 3'd2; n <= 0; r_iss <= 0; r_got <= 0;
          end else if (aw_hs) begin
            mph <= M_WR; last_pref <= 0; id <= s_awid; start <= s_awaddr; len <= s_awlen; size <= s_awsize;
            burst <= s_awburst; bad <= s_awsize > 3'd2; n <= 0; wn <= 0; w_have <= 0; w_seen_last <= 0;
          end
        M_RD: begin
          if (h_hs) r_iss <= r_iss + 1;
          if (r_capq) begin
            if (r_got == 0) r_lo <= hrdata; else r_hi <= hrdata;
            r_got <= r_got + 1;
          end
          if (r_hs) begin
            n <= n + 1; r_iss <= 0; r_got <= 0;
            if (n == len) begin
              mph <= M_IDLE; m_rd <= m_rd + 1; if (bad) m_err <= m_err + 1;
            end
          end
        end
        M_WR: begin
          if (w_hs) begin
            w_have <= 1; w_data <= s_wdata; w_strb <= s_wstrb; w_last <= s_wlast; w_half <= 0; w_rmw <= 0;
            w_rmw_got <= 0;
            n <= wn; wn <= wn + 1;
            if (s_wlast) w_seen_last <= 1;
            if (s_wlast != (wn == len)) bad <= 1;
          end
          if (w_capq) begin w_rmw_d <= hrdata; w_rmw_got <= 1; end
          if (h_hs) begin
            if (w_exp_rd) begin w_rmw <= 1; m_rmw <= m_rmw + 1; end
            else begin w_rmw <= 0; w_rmw_got <= 0; w_half <= 2'(w_h) + 2'd1; end
          end
          if (b_hs) begin
            mph <= M_IDLE; m_wr <= m_wr + 1; if (bad) m_err <= m_err + 1;
          end
        end
        default: mph <= M_IDLE;
      endcase
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, !s_awready && !s_arready && !s_wready && !s_bvalid && !s_rvalid && !hvalid
                                 && n_rd == 0 && n_wr == 0 && n_rmw == 0 && n_err == 0 && !err_irq)
  `SVA_INV(a_accept, s_arready == (mph == M_IDLE && s_arvalid && !(s_awvalid && last_pref))
                  && s_awready == (mph == M_IDLE && s_awvalid && !(s_arvalid && !last_pref)))
  `SVA_INV(a_counters, n_rd == m_rd && n_wr == m_wr && n_rmw == m_rmw && n_err == m_err)
  `SVA_INV(a_err_irq, err_irq == (bad && ((mph == M_WR && b_hs) || (mph == M_RD && r_hs && n == len))))
  `SVA_INV(a_host_idle, mph == M_IDLE -> !hvalid)
  `SVA_INV(a_host_bad, bad -> !hvalid)
  // reads: two RDs per beat, the R beat once both halfwords are in
  `SVA_IMP(a_rd_op, mph == M_RD && h_hs, hcmd == C_RD && r_iss != 2 && haddr == hmap(ba, r_iss[0]))
  `SVA_INV(a_rd_one_at_a_time, (mph == M_RD && hvalid) -> r_iss == r_got)
  `SVA_INV(a_r_beat, (mph == M_RD && s_rvalid) == (mph == M_RD && (bad || r_got == 2)))
  `SVA_IMP(a_r_data, s_rvalid, mph == M_RD && s_rid == id && s_rlast == (n == len)
                               && s_rresp == (bad ? 2'b10 : 2'b00) && (bad || s_rdata == {r_hi, r_lo}))
  // writes: the host operations of each halfword, in order
  `SVA_IMP(a_wr_op, mph == M_WR && h_hs, w_pending && haddr == hmap(ba, w_h)
                    && (w_exp_rd ? hcmd == C_RD : (hcmd == C_WR && hwdata == (w_s == 2'b11 ? w_d : w_merged))))
  `SVA_INV(a_wr_merge_data, (mph == M_WR && hvalid && w_rmw) -> w_rmw_got)
  `SVA_INV(a_w_ready, s_wready -> (mph == M_WR && !w_pending && !(w_have && (bad ? w_last : n == len))))
  `SVA_IMP(a_b_resp, s_bvalid, mph == M_WR && w_have && (bad ? w_last : w_seen_last) && !w_pending
                               && s_bid == id && s_bresp == (bad ? 2'b10 : 2'b00))

  // ---------------------------------------------------------------- coverage
  function automatic logic [2:0] lc(input logic [7:0] l);
    lc = (l == 0) ? 3'd0 : (l < 15) ? 3'd1 : (l == 15) ? 3'd2 : (l < 255) ? 3'd3 : 3'd4;
  endfunction
  covergroup cg_ddr_axi @(posedge clk);
    option.per_instance = 1;
    cp_rd_kind: coverpoint {s_arburst, s_arsize[1:0]} iff (rst_n && ar_hs && s_arsize <= 2)
      { bins fixed[] = {0, 1, 2}; bins incr[] = {4, 5, 6}; bins wrap[] = {8, 9, 10}; }
    cp_wr_kind: coverpoint {s_awburst, s_awsize[1:0]} iff (rst_n && aw_hs && s_awsize <= 2)
      { bins fixed[] = {0, 1, 2}; bins incr[] = {4, 5, 6}; bins wrap[] = {8, 9, 10}; }
    cp_rlen: coverpoint lc(s_arlen) iff (rst_n && ar_hs)
      { bins one = {0}; bins short_ = {1}; bins sixteen = {2}; bins long_ = {3}; bins max = {4}; }
    cp_wlen: coverpoint lc(s_awlen) iff (rst_n && aw_hs)
      { bins one = {0}; bins short_ = {1}; bins sixteen = {2}; bins long_ = {3}; bins max = {4}; }
    cp_strb_lo: coverpoint s_wstrb[1:0] iff (rst_n && w_hs && !w_bad_now);
    cp_strb_hi: coverpoint s_wstrb[3:2] iff (rst_n && w_hs && !w_bad_now);
    cp_err: coverpoint {mph == M_WR, s_wlast} iff (rst_n && w_hs && !bad && s_wlast != (wn == len))
      { bins wlast_early = {2'b11}; bins wlast_missing = {2'b10}; }
    cp_size_err: coverpoint {aw_hs, aw_hs ? s_awsize : s_arsize} iff (rst_n && (ar_hs || aw_hs)
                                                               && (aw_hs ? s_awsize : s_arsize) > 2)
      { bins rd[] = {[4'b0011:4'b0111]}; bins wr[] = {[4'b1011:4'b1111]}; }
  endgroup
  cg_ddr_axi u_cg_ddr_axi = new;

  `FC(rd_and_wr_waiting_rd_turn, mph == M_IDLE && s_arvalid && s_awvalid && !last_pref)
  `FC(rd_and_wr_waiting_wr_turn, mph == M_IDLE && s_arvalid && s_awvalid && last_pref)
  `FC(wrap_wraps, (mph != M_IDLE) && burst == 2'b10 && n != 0 && ba < start)
  `FC(r_stall, s_rvalid && !s_rready)
  `FC(b_stall, s_bvalid && !s_bready)
  `FC(w_gap, s_wready && !s_wvalid)
  `FC(host_stall, hvalid && !hready)
  `FC(beats_after_error, mph == M_WR && bad && w_hs && !s_wlast)
  `FC(rmw_both_halves, mph == M_WR && w_hs && s_wstrb[1:0] inside {2'b01, 2'b10} && s_wstrb[3:2] inside {2'b01, 2'b10})
  `FC(addr_top, ar_hs && s_araddr[31:28] == 4'hF)
  `FC_RST(reset_mid_read, rst_n && mph == M_RD ##1 !rst_n)
  `FC_RST(reset_mid_write, rst_n && mph == M_WR ##1 !rst_n)
endmodule

bind ddr_axi_slv ddr_axi_slv_sva u_sva (.*);
