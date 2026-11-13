// SPDX-License-Identifier: Apache-2.0
// soc_ss_axi_engine (shared AXI4 manager data mover of the SoC subsystem
// IPs): concurrent SVA against an independent job / burst model fed only by
// the engine's input pins, and functional coverage of the job and burst
// space. The model tracks the words left, the next address and the occupancy
// of both FIFOs, cuts bursts at 16 beats and at 4 KB, and keeps its own copy
// of both FIFOs' contents to check the streamed and the written data.
`include "cov_macros.svh"
module soc_ss_axi_engine_sva #(
  parameter logic [3:0] ID    = 4'd0,
  parameter logic [2:0] PROT  = 3'b000,
  parameter int         DEPTH = 32
) (
  input logic        clk, rst_n, start, rd_en, wr_en,
  input logic [31:0] src, dst,
  input logic [15:0] len,
  input logic        busy, done, err,
  input logic [31:0] cycles,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data,
  input logic [3:0]  m_awid, m_arid, m_bid, m_rid,
  input logic [31:0] m_awaddr, m_araddr, m_wdata, m_rdata,
  input logic [7:0]  m_awlen, m_arlen,
  input logic [2:0]  m_awsize, m_arsize, m_awprot, m_arprot,
  input logic [1:0]  m_awburst, m_arburst, m_bresp, m_rresp,
  input logic [3:0]  m_wstrb,
  input logic        m_awvalid, m_awready, m_wlast, m_wvalid, m_wready,
  input logic        m_bvalid, m_bready, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int CW = $clog2(DEPTH) + 1;

  // burst size for an address and the words left: at most 16, never past 4 KB
  function automatic int blen(input logic [31:0] a, input int left);
    int to4k;
    to4k = (4096 - int'(a[11:0])) / 4;
    blen = left < 16 ? left : 16;
    if (to4k < blen) blen = to4k;
  endfunction

  // ---------------- model ----------------
  logic        m_busy, m_done, m_err, m_rd, m_wr;
  logic [31:0] m_cyc, m_ra, m_wa;
  int          m_rl, m_wl, m_wt;        // words left to read / write / take
  int          m_rph, m_wph;            // 0 idle, 1 address, 2 data, 3 response
  int          m_rb, m_wb, m_wc;        // beats of the burst, beats sent
  int          m_rf, m_wf;              // FIFO occupancy
  logic [31:0] rq [DEPTH];              // model copies of the two FIFOs
  logic [31:0] wq [DEPTH];
  int          rq_h, rq_t, wq_h, wq_t;
  wire s_start = start;
  wire go      = start && !m_busy;
  wire rd_fin  = m_rl == 0 && m_rph == 0;
  wire wr_fin  = m_wl == 0 && m_wph == 0;
  wire e_rpush = m_rph == 2 && m_rvalid;
  wire e_rpop  = m_rf != 0 && rs_ready;
  wire e_wok   = m_busy && m_wr && m_wt != 0 && m_wf != DEPTH;
  wire e_wpush = ws_valid && e_wok;
  wire e_wpop  = m_wph == 2 && m_wready;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_busy <= 0; m_done <= 0; m_err <= 0; m_rd <= 0; m_wr <= 0; m_cyc <= 0;
      m_ra <= 0; m_wa <= 0; m_rl <= 0; m_wl <= 0; m_wt <= 0;
      m_rph <= 0; m_wph <= 0; m_rb <= 0; m_wb <= 0; m_wc <= 0; m_rf <= 0; m_wf <= 0;
      rq_h <= 0; rq_t <= 0; wq_h <= 0; wq_t <= 0;
    end else begin
      m_done <= 0;
      if (m_busy) m_cyc <= m_cyc + 1;
      if (go) begin
        m_busy <= 1; m_err <= 0; m_cyc <= 0; m_rd <= rd_en; m_wr <= wr_en;
        m_ra <= {src[31:2], 2'b00}; m_wa <= {dst[31:2], 2'b00};
        m_rl <= rd_en ? int'(len) : 0; m_wl <= wr_en ? int'(len) : 0;
        m_wt <= wr_en ? int'(len) : 0;
      end else if (m_busy && rd_fin && wr_fin && m_rf == 0) begin
        m_busy <= 0; m_done <= 1;
      end
      if (e_wpush) m_wt <= m_wt - 1;
      // read bursts: issued when the read FIFO has room for 16 words
      case (m_rph)
        0: if (m_busy && m_rl != 0 && m_rf <= DEPTH - 16) begin m_rb <= blen(m_ra, m_rl); m_rph <= 1; end
        1: if (m_arready) m_rph <= 2;
        default: if (m_rvalid) begin
          if (m_rresp != 2'b00) m_err <= 1;
          if (m_rlast) begin m_ra <= m_ra + 32'(4 * m_rb); m_rl <= m_rl - m_rb; m_rph <= 0; end
        end
      endcase
      // write bursts: issued when the write FIFO holds the whole burst
      case (m_wph)
        0: if (m_busy && m_wl != 0 && m_wf >= blen(m_wa, m_wl)) begin
             m_wb <= blen(m_wa, m_wl); m_wc <= 0; m_wph <= 1;
           end
        1: if (m_awready) m_wph <= 2;
        2: if (m_wready) begin m_wc <= m_wc + 1; if (m_wc == m_wb - 1) m_wph <= 3; end
        default: if (m_bvalid) begin
          if (m_bresp != 2'b00) m_err <= 1;
          m_wa <= m_wa + 32'(4 * m_wb); m_wl <= m_wl - m_wb; m_wph <= 0;
        end
      endcase
      m_rf <= m_rf + int'(e_rpush) - int'(e_rpop);
      m_wf <= m_wf + int'(e_wpush) - int'(e_wpop);
      if (e_rpush) begin rq[rq_t] <= m_rdata; rq_t <= (rq_t + 1) % DEPTH; end
      if (e_rpop)  rq_h <= (rq_h + 1) % DEPTH;
      if (e_wpush) begin wq[wq_t] <= ws_data; wq_t <= (wq_t + 1) % DEPTH; end
      if (e_wpop)  wq_h <= (wq_h + 1) % DEPTH;
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_idle, !rst_n, !busy && !done && !err && cycles == 0 && !rs_valid && !ws_ready
                                 && !m_awvalid && !m_wvalid && !m_bready && !m_arvalid && !m_rready)
  `SVA_INV(a_busy, busy == m_busy)
  `SVA_INV(a_done, done == m_done)
  `SVA_INV(a_err, err == m_err)
  `SVA_INV(a_cycles, cycles == m_cyc)
  `SVA_INV(a_arvalid, m_arvalid == (m_rph == 1))
  `SVA_INV(a_rready, m_rready == (m_rph == 2))
  `SVA_INV(a_awvalid, m_awvalid == (m_wph == 1))
  `SVA_INV(a_wvalid, m_wvalid == (m_wph == 2))
  `SVA_INV(a_bready, m_bready == (m_wph == 3))
  `SVA_IMP(a_ar_req, m_arvalid, m_araddr == m_ra && int'(m_arlen) == m_rb - 1 && m_arid == ID
                                && m_arsize == 3'd2 && m_arburst == 2'b01 && m_arprot == PROT)
  `SVA_IMP(a_aw_req, m_awvalid, m_awaddr == m_wa && int'(m_awlen) == m_wb - 1 && m_awid == ID
                                && m_awsize == 3'd2 && m_awburst == 2'b01 && m_awprot == PROT)
  `SVA_IMP(a_ar_4k, m_arvalid, 32'(m_araddr[11:0]) + 4 * (32'(m_arlen) + 1) <= 4096)
  `SVA_IMP(a_aw_4k, m_awvalid, 32'(m_awaddr[11:0]) + 4 * (32'(m_awlen) + 1) <= 4096)
  `SVA_IMP(a_wbeat, m_wvalid, m_wstrb == 4'hF && m_wlast == (m_wc == m_wb - 1) && m_wdata == wq[wq_h])
  `SVA_INV(a_rs_valid, rs_valid == (m_rf != 0))
  `SVA_IMP(a_rs_data, rs_valid, rs_data == rq[rq_h])
  `SVA_INV(a_ws_ready, ws_ready == e_wok)
  `SVA_INV(a_fifo_bounds, m_rf <= DEPTH && m_wf <= DEPTH)
  `SVA_NXT(a_ar_stable, m_arvalid && !m_arready, m_arvalid && $stable(m_araddr) && $stable(m_arlen))
  `SVA_NXT(a_aw_stable, m_awvalid && !m_awready, m_awvalid && $stable(m_awaddr) && $stable(m_awlen))
  `SVA_NXT(a_w_stable, m_wvalid && !m_wready, m_wvalid && $stable(m_wdata) && $stable(m_wlast))

  // ---------------- functional coverage ----------------
  function automatic logic [2:0] lcls(input int n);
    lcls = n == 0 ? 3'd0 : n == 1 ? 3'd1 : n < 16 ? 3'd2 : n == 16 ? 3'd3 :
           n < 1024 ? 3'd4 : n < 65535 ? 3'd5 : 3'd6;
  endfunction
  covergroup cg_job @(posedge clk);
    option.per_instance = 1;
    cp_kind: coverpoint {rd_en, wr_en} iff (rst_n && go);
    cp_len: coverpoint lcls(int'(len)) iff (rst_n && go)
      { bins zero = {0}; bins one = {1}; bins short_ = {2}; bins sixteen = {3};
        bins mid = {4}; bins long_ = {5}; bins max = {6}; }
    x_kind_len: cross cp_kind, cp_len;
    cp_src_lo: coverpoint src[1:0] iff (rst_n && go && rd_en);
    cp_dst_lo: coverpoint dst[1:0] iff (rst_n && go && wr_en);
    cp_start_busy: coverpoint m_busy iff (rst_n && s_start);   // (start is a covergroup method name)
    cp_done_err: coverpoint m_err iff (rst_n && m_done);
  endgroup
  cg_job u_cg_job = new;

  wire ar_cut = m_arvalid && int'(m_arlen) + 1 < (m_rl < 16 ? m_rl : 16);
  wire aw_cut = m_awvalid && int'(m_awlen) + 1 < (m_wl < 16 ? m_wl : 16);
  covergroup cg_burst @(posedge clk);
    option.per_instance = 1;
    cp_arlen: coverpoint m_arlen[3:0] iff (rst_n && m_arvalid && m_arready);
    cp_awlen: coverpoint m_awlen[3:0] iff (rst_n && m_awvalid && m_awready);
    cp_ar_cut: coverpoint ar_cut iff (rst_n && m_arvalid && m_arready);
    cp_aw_cut: coverpoint aw_cut iff (rst_n && m_awvalid && m_awready);
    cp_ar_wait: coverpoint m_arready iff (rst_n && m_arvalid);
    cp_aw_wait: coverpoint m_awready iff (rst_n && m_awvalid);
    cp_w_wait: coverpoint m_wready iff (rst_n && m_wvalid);
    cp_rresp: coverpoint m_rresp iff (rst_n && m_rvalid && m_rready);
    cp_bresp: coverpoint m_bresp iff (rst_n && m_bvalid && m_bready);
    cp_rid: coverpoint m_rid iff (rst_n && m_rvalid && m_rready);
    cp_bid: coverpoint m_bid iff (rst_n && m_bvalid && m_bready);
    x_both: coverpoint {m_rph == 2, m_wph == 2} iff (rst_n && m_busy);
  endgroup
  cg_burst u_cg_burst = new;

  function automatic logic [2:0] fcls(input int n);
    fcls = n == 0 ? 3'd0 : n < 16 ? 3'd1 : n == 16 ? 3'd2 : n < DEPTH ? 3'd3 : 3'd4;
  endfunction
  function automatic logic [1:0] dcls(input logic [31:0] v);
    dcls = v == 0 ? 2'd0 : v == '1 ? 2'd1 : (v == 32'h5555_5555 || v == 32'hAAAA_AAAA) ? 2'd2 : 2'd3;
  endfunction
  covergroup cg_stream @(posedge clk);
    option.per_instance = 1;
    cp_rfill: coverpoint fcls(m_rf) iff (rst_n && m_busy && m_rd)
      { bins empty = {0}; bins low = {1}; bins half = {2}; bins high = {3}; bins full = {4}; }
    cp_wfill: coverpoint fcls(m_wf) iff (rst_n && m_busy && m_wr)
      { bins empty = {0}; bins low = {1}; bins half = {2}; bins high = {3}; bins full = {4}; }
    cp_rs_stall: coverpoint rs_ready iff (rst_n && rs_valid);
    cp_ws_stall: coverpoint ws_ready iff (rst_n && ws_valid && m_busy && m_wr && m_wt != 0);
    cp_rdata: coverpoint dcls(m_rdata) iff (rst_n && m_rvalid && m_rready)
      { bins other = {3}; bins zero = {0}; }
  endgroup
  cg_stream u_cg_stream = new;

  `FC(back_to_back_jobs, done ##1 start)
  `FC(start_while_busy, start && m_busy)
  `FC(err_on_read, m_rvalid && m_rph == 2 && m_rresp != 2'b00)
  `FC(err_on_write, m_bvalid && m_wph == 3 && m_bresp != 2'b00)
  `FC(read_and_write_burst_overlap, m_rph == 2 && m_wph == 2 && m_rvalid && m_wready)
  `FC(write_fifo_full_backpressure, ws_valid && m_busy && m_wr && m_wt != 0 && m_wf == DEPTH)
  `FC(read_held_for_fifo_room, m_rph == 0 && m_busy && m_rl != 0 && m_rf > DEPTH - 16)
  `FC(burst_at_4k_end, m_arvalid && m_arready && 32'(m_araddr[11:0]) + 4 * (32'(m_arlen) + 1) == 4096)
  `FC_RST(reset_mid_job, rst_n && m_busy ##1 !rst_n)
endmodule

bind soc_ss_axi_engine soc_ss_axi_engine_sva #(.ID(ID), .PROT(PROT), .DEPTH(DEPTH)) u_sva (.*);
