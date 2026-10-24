// SPDX-License-Identifier: Apache-2.0
// APB3 slave: concurrent SVA (protocol + shadow-memory data integrity) and
// functional coverage, bound into APB_top.
`include "cov_macros.svh"
module APB_sva #(parameter int DW = 32, AW = 32, DEPTH = 256) (
  input logic          clk, rst_n,
  input logic          psel, penable, pwrite,
  input logic [AW-1:0] paddr,
  input logic [DW-1:0] pwdata, prdata,
  input logic          pready, pslverr, irq,
  input logic          state, write_q, slow_q, err_q, waited_q,
  input logic [AW-1:0] addr_q,
  input logic          setup_cycle, access_finish
);
  `COV_CLOCKING(clk, !rst_n)
  wire [1:0] region = paddr[11] ? 2'd2 : paddr[10] ? 2'd1 : 2'd0;   // fast/slow/reserved

  // shadow register file: independent reference for read data
  logic [DW-1:0] shadow [0:DEPTH-1];
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) for (int i = 0; i < DEPTH; i++) shadow[i] <= '0;
    else if (access_finish && write_q && !err_q) shadow[addr_q[9:2]] <= pwdata;

  `SVA_RST(a_reset_quiet, !rst_n, !pready && !pslverr && !irq && state == 1'b0)
  `SVA_IMP(a_pslverr_at_completion, pslverr, psel && penable && pready)
  `SVA_INV(a_irq_is_pslverr, irq == pslverr)
  `SVA_IMP(a_pready_in_access, pready, penable && psel && state == 1'b1)
  `SVA_NXT(a_setup_to_access, setup_cycle, state == 1'b1)
  `SVA_NXT(a_completion_to_idle, access_finish, state == 1'b0)
  `SVA_NXT(a_slow_one_wait, setup_cycle && region == 2'd1, penable && !pready ##1 penable && pready)
  `SVA_NXT(a_fast_zero_wait, setup_cycle && region != 2'd1, penable && pready)
  `SVA_NXT(a_err_on_reserved, setup_cycle && region == 2'd2, pslverr)
  `SVA_NXT(a_no_err_on_valid, setup_cycle && region != 2'd2, !pslverr)
  `SVA_IMP(a_read_data, access_finish && !write_q && !err_q, prdata == shadow[addr_q[9:2]])
  `SVA_IMP(a_err_read_zero, pslverr, prdata == '0)
  `SVA_IMP(a_prdata_zero_outside_read, state == 1'b0 || write_q, prdata == '0)
  `SVA_IMP(a_attrs_stable_in_access, state == 1'b1 && !$past(setup_cycle),
           $stable(addr_q) && $stable(write_q))

  // ---------------- functional coverage ----------------
  covergroup cg_xfer @(posedge clk);
    option.per_instance = 1;
    cp_dir: coverpoint pwrite iff (rst_n && setup_cycle) { bins rd = {0}; bins wr = {1}; }
    cp_region: coverpoint region iff (rst_n && setup_cycle)
      { bins fast = {0}; bins slow = {1}; bins reserved = {2}; }
    cp_word: coverpoint paddr[9:2] iff (rst_n && setup_cycle && !paddr[11])
      { bins first = {0}; bins last = {DEPTH-1}; bins mid = {[1:DEPTH-2]}; }
    x_dir_region: cross cp_dir, cp_region;
  endgroup
  cg_xfer u_cg_xfer = new;

  `FC(back_to_back, access_finish ##1 setup_cycle)
  `FC(idle_gap, access_finish ##1 !psel)
  `FC(slow_read, setup_cycle && region == 2'd1 && !pwrite ##1 !pready ##1 pready)
  logic       last_wr_ok;     // previous transfer was a successful write
  logic [7:0] last_wr_word;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin last_wr_ok <= 1'b0; last_wr_word <= '0; end
    else if (access_finish) begin last_wr_ok <= write_q && !err_q; last_wr_word <= addr_q[9:2]; end
  `FC(read_after_write_same, setup_cycle && !pwrite && !paddr[11] && last_wr_ok &&
      paddr[9:2] == last_wr_word)
  // data classes moved, direction x word position, and the direction and
  // error status of back-to-back transfer pairs
  function automatic logic [1:0] dcls(input logic [DW-1:0] v);
    dcls = (v == '0) ? 2'd0 : (v == '1) ? 2'd1 :
           (v == {(DW/2){2'b01}} || v == {(DW/2){2'b10}}) ? 2'd2 : 2'd3;
  endfunction
  logic       m_fin_d, m_dir_d, m_err_d;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin m_fin_d <= 0; m_dir_d <= 0; m_err_d <= 0; end
    else begin m_fin_d <= access_finish; m_dir_d <= write_q; m_err_d <= err_q; end
  covergroup cg_data @(posedge clk);
    option.per_instance = 1;
    cp_wdata: coverpoint dcls(pwdata) iff (rst_n && access_finish && write_q && !err_q)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls(prdata) iff (rst_n && access_finish && !write_q && !err_q)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_dir: coverpoint pwrite iff (rst_n && setup_cycle && !paddr[11]) { bins rd = {0}; bins wr = {1}; }
    cp_word: coverpoint paddr[9:2] iff (rst_n && setup_cycle && !paddr[11])
      { bins first = {0}; bins last = {DEPTH-1}; bins mid = {[1:DEPTH-2]}; }
    x_dir_word: cross cp_dir, cp_word;
    cp_pair: coverpoint {m_dir_d, m_err_d, pwrite, region == 2'd2} iff (rst_n && m_fin_d && setup_cycle) {
      bins rd_rd = {4'b0000}; bins rd_wr = {4'b0010}; bins wr_rd = {4'b1000}; bins wr_wr = {4'b1010};
      bins err_then_ok = {4'b0100, 4'b0110, 4'b1100, 4'b1110};
      bins ok_then_err = {4'b0001, 4'b0011, 4'b1001, 4'b1011};
    }
  endgroup
  cg_data u_cg_data = new;
  `FC(slow_write, setup_cycle && region == 2'd1 && pwrite ##1 !pready ##1 pready)

  `FC_RST(reset_during_access, rst_n && setup_cycle ##1 !rst_n)
endmodule

bind APB_top APB_sva #(.DW(DW), .AW(AW), .DEPTH(DEPTH)) u_sva (.*);
