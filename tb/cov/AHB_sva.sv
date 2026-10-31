// SPDX-License-Identifier: Apache-2.0
// AHB-Lite slave: concurrent SVA against an independent data-phase model
// (region decode, wait/ERROR timing, register-file shadow) + functional coverage.
`include "cov_macros.svh"
module AHB_sva #(parameter int DW = 32, AW = 32) (
  input logic          clk, rst_n,
  input logic          hsel, hwrite, hready, hreadyout, hresp, irq,
  input logic [1:0]    htrans,
  input logic [AW-1:0] haddr,
  input logic [2:0]    hsize,
  input logic [DW-1:0] hwdata, hrdata
);
  `COV_CLOCKING(clk, !rst_n)
  wire cap = hsel && hready && htrans[1];

  // ---------------- independent data-phase model ----------------
  logic [DW-1:0] shadow [0:255];      // RTL clears its register file on reset
  logic          m_valid, m_write, m_slow, m_err;
  logic [AW-1:0] m_addr;
  logic [1:0]    m_cyc;               // cycles spent in this data phase
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 256; i++) shadow[i] <= '0;
      m_valid <= 0; m_write <= 0; m_slow <= 0; m_err <= 0; m_addr <= '0; m_cyc <= 0;
    end else begin
      if (hreadyout && m_valid && m_write && !m_err) shadow[m_addr[9:2]] <= hwdata;
      if (hreadyout) begin
        m_valid <= cap; m_cyc <= 0;
        if (cap) begin
          m_write <= hwrite; m_addr <= haddr;
          m_slow <= haddr[11:10] == 2'b01; m_err <= haddr[11];
        end
      end else m_cyc <= m_cyc + 1;
    end
  end
  wire first = m_valid && m_cyc == 0;

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_quiet, !rst_n, hreadyout && !hresp && !irq && hrdata == '0)
  `SVA_IMP(a_idle_okay, !m_valid, hreadyout && !hresp)
  `SVA_IMP(a_fast_zero_wait, m_valid && !m_slow && !m_err, hreadyout && !hresp)
  `SVA_IMP(a_slow_wait, first && m_slow && !m_err, !hreadyout && !hresp)
  `SVA_IMP(a_slow_done, m_valid && m_slow && !m_err && m_cyc == 1, hreadyout && !hresp)
  `SVA_IMP(a_err_cycle1, first && m_err, hresp && !hreadyout && irq)
  `SVA_NXT(a_err_cycle2, hresp && !hreadyout, hresp && hreadyout)
  `SVA_IMP(a_hresp_only_err, hresp, m_valid && m_err)
  `SVA_IMP(a_irq_only_err1, irq, first && m_err)
  `SVA_IMP(a_wait_bounded, !hreadyout, m_cyc == 0)
  `SVA_IMP(a_rdata_model, m_valid && !m_write && !m_err, hrdata == shadow[m_addr[9:2]])
  `SVA_IMP(a_rdata_zero, !(m_valid && !m_write && !m_err), hrdata == '0)

  // ---------------- functional coverage ----------------
  covergroup cg_addr @(posedge clk);
    option.per_instance = 1;
    cp_trans: coverpoint htrans iff (rst_n && hsel && hready)
      { bins idle = {0}; bins busy = {1}; bins nonseq = {2}; bins seq = {3}; }
    cp_region: coverpoint {haddr[11], haddr[11:10] == 2'b01} iff (rst_n && cap)
      { bins fast = {2'b00}; bins slow = {2'b01}; bins reserved = {2'b10}; }
    cp_dir: coverpoint hwrite iff (rst_n && cap) { bins rd = {0}; bins wr = {1}; }
    x_region_dir: cross cp_region, cp_dir;
  endgroup
  cg_addr u_cg_addr = new;

  // data classes moved, and the pipelined pair (data phase in flight, next
  // address captured): previous direction / region x next direction
  function automatic logic [1:0] dcls(input logic [DW-1:0] v);
    dcls = (v == '0) ? 2'd0 : (v == '1) ? 2'd1 :
           (v == {(DW/2){2'b01}} || v == {(DW/2){2'b10}}) ? 2'd2 : 2'd3;
  endfunction
  wire [1:0] m_reg = m_err ? 2'd2 : m_slow ? 2'd1 : 2'd0;
  covergroup cg_data @(posedge clk);
    option.per_instance = 1;
    cp_wdata: coverpoint dcls(hwdata) iff (rst_n && hreadyout && m_valid && m_write && !m_err)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls(hrdata) iff (rst_n && hreadyout && m_valid && !m_write && !m_err)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_prev: coverpoint {m_write, m_reg} iff (rst_n && cap && m_valid && hreadyout)
      { bins rd_fast = {3'b000}; bins rd_slow = {3'b001}; bins rd_err = {3'b010};
        bins wr_fast = {3'b100}; bins wr_slow = {3'b101}; bins wr_err = {3'b110}; }
    cp_next: coverpoint hwrite iff (rst_n && cap && m_valid && hreadyout) { bins rd = {0}; bins wr = {1}; }
    x_pipe: cross cp_prev, cp_next;
  endgroup
  cg_data u_cg_data = new;

  `FC(pipelined_back_to_back, cap && m_valid && !m_slow && !m_err && m_write)
  `FC(pipelined_read_after_read, cap && !hwrite && m_valid && !m_write && !m_err)
  `FC(next_captured_on_slow_done, cap && m_valid && m_slow && !m_err)
  `FC(next_captured_on_err2, cap && m_valid && m_err)
  `FC(addr_held_during_wait, hsel && htrans[1] && !hreadyout)
  `FC(busy_during_data_phase, hsel && htrans == 2'b01 && m_valid)
  `FC(unselected_traffic, !hsel && htrans[1])
  `FC_RST(reset_in_wait, rst_n && !hreadyout ##1 !rst_n)
endmodule

bind AHB_top AHB_sva #(.DW(DW), .AW(AW)) u_sva (.*);
