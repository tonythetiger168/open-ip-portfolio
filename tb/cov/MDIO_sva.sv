// SPDX-License-Identifier: Apache-2.0
// MDIO Clause-22 slave: an independent frame decoder on the pins predicts
// the register file, the PHY's turnaround/read-data drive and irq.
`include "cov_macros.svh"
module MDIO_sva #(parameter logic [4:0] PHY_ADDR = 5'h0C) (
  input logic        clk, rst_n, mdc, mdio, irq, drive_low,
  input logic [15:0] regs [0:31]
);
  `COV_CLOCKING(clk, !rst_n)

  logic        c1, c2, d1;
  logic        m_pre, m_st0, m_act, m_rd, m_match, m_ab1;
  logic [4:0]  m_cnt, m_reg;
  logic [28:0] m_sh;
  logic [15:0] m_regs [0:31];
  logic [1:0]  m_op;
  logic [5:0]  m_ones;                       // preamble length before ST
  wire         rise = c1 && !c2;
  // bits of the frame so far, oldest first in m_sh[m_cnt-1:0]
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c1 <= 0; c2 <= 0; d1 <= 1; m_pre <= 0; m_st0 <= 0; m_act <= 0; m_rd <= 0;
      m_match <= 0; m_cnt <= 0; m_reg <= 0; m_sh <= 0; m_op <= 0; m_ones <= 0; m_ab1 <= 0;
      for (int i = 0; i < 32; i++) m_regs[i] <= (i == 0) ? 16'h1140 : 16'h0;
    end else begin
      c1 <= mdc; c2 <= c1; d1 <= mdio;
      if (rise) begin
        if (!m_act) begin
          if (d1) begin
            m_act  <= m_st0; m_cnt <= 0;
            m_pre  <= !m_st0; m_st0 <= 0;
            m_ones <= m_st0 ? m_ones : (m_ones == 6'd63 ? m_ones : m_ones + 1);
            m_ab1  <= 0;
          end else begin
            m_st0 <= m_pre; m_pre <= 0; m_ab1 <= m_st0;   // 0,0 after ST[0]
            if (!m_pre) m_ones <= 0;
          end
        end else begin
          m_sh <= {m_sh[27:0], d1};
          m_cnt <= m_cnt + 1;
          if (m_cnt == 1)  m_op <= {m_sh[0], d1};
          if (m_cnt == 6)  m_match <= m_op == 2'b10 && {m_sh[3:0], d1} == PHY_ADDR;
          if (m_cnt == 11) m_reg <= {m_sh[3:0], d1};
          if (m_cnt == 29) begin
            m_act <= 0; m_match <= 0; m_ones <= 0; m_cnt <= 0;
            if (m_op == 2'b01 && m_sh[26:22] == PHY_ADDR) m_regs[m_sh[21:17]] <= {m_sh[14:0], d1};
          end
        end
      end
    end
  end
  wire [15:0] m_rdv   = m_regs[m_reg];
  wire        m_drive = m_match && m_cnt >= 13 && (m_cnt == 13 || !m_rdv[29 - m_cnt]);
  wire        last    = m_act && m_cnt == 29;

  `SVA_RST(a_reset_released, !rst_n, !drive_low)
  `SVA_INV(a_drive_model, drive_low == m_drive)
  logic regs_ok;
  always_comb begin
    regs_ok = 1'b1;
    for (int i = 0; i < 32; i++) if (regs[i] != m_regs[i]) regs_ok = 1'b0;
  end
  `SVA_INV(a_regs_model, regs_ok)
  `SVA_INV(a_irq_model, irq == last)
  `SVA_IMP(a_no_drive_outside_read, drive_low, m_match && m_cnt >= 13)

  wire wr_own   = last && rise && m_op == 2'b01 && m_sh[26:22] == PHY_ADDR;
  wire wr_other = last && rise && m_op == 2'b01 && m_sh[26:22] != PHY_ADDR;
  wire rd_other = m_act && rise && m_cnt == 6 && m_op == 2'b10 && {m_sh[3:0], d1} != PHY_ADDR;
  // every register written and read on this PHY, opcode x PHY address
  // match, write / read data classes, preamble length before ST
  function automatic logic [1:0] dcls(input logic [15:0] v);
    dcls = (v == 16'h0000) ? 2'd0 : (v == 16'hFFFF) ? 2'd1 :
           (v == 16'h5555 || v == 16'hAAAA) ? 2'd2 : 2'd3;
  endfunction
  wire rd_start = m_match && m_cnt == 13 && rise;
  covergroup cg_mgmt @(posedge clk);
    option.per_instance = 1;
    cp_wreg: coverpoint m_sh[21:17] iff (rst_n && wr_own) { bins r[] = {[0:31]}; }
    cp_rreg: coverpoint m_reg iff (rst_n && rd_start) { bins r[] = {[0:31]}; }
    cp_op: coverpoint m_op iff (rst_n && last && rise)
      { bins op00 = {0}; bins write = {1}; bins read = {2}; bins op11 = {3}; }
    cp_own: coverpoint (m_sh[26:22] == PHY_ADDR) iff (rst_n && last && rise)
      { bins other = {0}; bins own = {1}; }
    x_op_own: cross cp_op, cp_own;
    cp_wdata: coverpoint dcls({m_sh[14:0], d1}) iff (rst_n && wr_own)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls(m_rdv) iff (rst_n && rd_start)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_pre: coverpoint m_ones iff (rst_n && rise && !m_act && d1 && m_st0)
      { bins one = {1}; bins short_ = {[2:31]}; bins full = {[32:63]}; }
  endgroup
  cg_mgmt u_cg_mgmt = new;

  `FC(write_own_phy, wr_own)
  `FC(write_other_phy, wr_other)
  `FC(write_reg0, wr_own && m_sh[21:17] == 5'd0)
  `FC(write_reg31, wr_own && m_sh[21:17] == 5'd31)
  `FC(write_all_zero, wr_own && {m_sh[14:0], d1} == 16'h0000)
  `FC(write_all_ones, wr_own && {m_sh[14:0], d1} == 16'hFFFF)
  `FC(read_own_phy, m_match && m_cnt == 13)
  `FC(read_other_phy, rd_other)
  `FC(read_reg31, m_match && m_cnt == 13 && m_reg == 5'd31)
  `FC(op_00_ignored, last && m_op == 2'b00)
  `FC(op_11_ignored, last && m_op == 2'b11)
  `FC(st_not_after_two_zeros, m_ab1)
  `FC(one_bit_preamble, rise && !m_act && d1 && m_st0 && m_ones == 6'd1)
  `FC(full_preamble, rise && !m_act && d1 && m_st0 && m_ones >= 6'd32)
  `FC_RST(reset_during_read_data, rst_n && m_match && m_cnt > 13 ##1 !rst_n)
endmodule

bind MDIO_top MDIO_sva #(.PHY_ADDR(PHY_ADDR)) u_sva (.*);
