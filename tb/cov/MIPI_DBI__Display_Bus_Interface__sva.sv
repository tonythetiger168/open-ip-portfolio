// SPDX-License-Identifier: Apache-2.0
// MIPI DBI host: concurrent SVA against an independent reference model,
// plus functional coverage.
//  * An accepted op becomes a list of phases, each (rd ? cfg_tr : cfg_tw)
//    + 1 clocks: Type A / B setup, strobe, hold; Type C an SCL low and an
//    SCL high phase per dummy clock and per bit; then a CSX-high phase
//    after op_last. Every pin is a function of the phase index (plus the
//    few levels that persist between ops).
//  * Read data is taken from d_i at the end of the strobe phase, from
//    sda_i at the end of each data-bit low phase.
// Every output is compared on every clock.
`include "cov_macros.svh"
module MIPI_DBI__Display_Bus_Interface__sva (
  input logic        clk, rst_n,
  input logic [1:0]  cfg_type,
  input logic        cfg_w16,
  input logic [3:0]  cfg_tw, cfg_tr,
  input logic [1:0]  cfg_dummy,
  input logic        op_valid, op_ready, op_dc, op_rd, op_last,
  input logic [15:0] op_data,
  input logic        rd_valid,
  input logic [15:0] rd_data,
  input logic        busy, csx, dcx, wrx, rdx,
  input logic [15:0] d_o,
  input logic        d_oe,
  input logic [15:0] d_i,
  input logic        scl, sda_o, sda_oe, sda_i
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- model ----------------
  bit          m_on, m_rd, m_dc, m_last, m_ser, m_prev_rd, m_csx, m_dcx, m_rdx_idle, m_sda, m_rv;
  logic [15:0] m_d, m_do, m_rdd;
  logic [7:0]  m_rsh;
  int          m_k, m_j, m_len, m_np, m_dum, m_nb;
  bit [1:0]    m_ty;
  // coverage
  bit          v_b2b, v_rd_nodum, v_dum [0:3], v_kind [0:3][0:1], v_w16 [0:1][0:1];
  bit          v_tw0, v_tw15, v_tr0, v_tr15, v_multi, v_rd_last;

  // bit b of a Type C write
  function automatic bit cbit(input int b);
    if (m_ty == 2'd2) return b == 0 ? m_dc : m_d[8 - b];
    return m_d[7 - b];
  endfunction

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      {m_on, m_rd, m_dc, m_last, m_ser, m_prev_rd, m_rv, m_sda} = '0;
      m_csx = 1; m_dcx = 1; m_rdx_idle = 1;
      m_d = 0; m_do = 0; m_rdd = 0; m_rsh = 0; m_k = 0; m_j = 0; m_len = 0; m_np = 0; m_dum = 0; m_nb = 0; m_ty = 0;
    end else begin
      m_rv = 0;
      if (!m_on) begin
        m_rdx_idle = cfg_type != 2'd0;
        if (op_valid) begin
          m_on = 1; m_k = 0; m_j = 0; m_ty = cfg_type; m_ser = cfg_type[1];
          m_rd = op_rd; m_dc = op_dc; m_last = op_last; m_d = op_data;
          m_len = int'(op_rd ? cfg_tr : cfg_tw);
          if (!m_ser) begin
            m_np = 3; m_dcx = op_dc;
            m_do = op_rd ? 16'd0 : (cfg_w16 ? op_data : {8'd0, op_data[7:0]});
            v_w16[op_rd][cfg_w16] = 1;
          end else begin
            if (cfg_type == 2'd3) m_dcx = op_dc;
            m_dum = op_rd && (!m_prev_rd || m_csx) ? int'(cfg_dummy) : 0;
            if (op_rd) begin v_dum[m_dum] = 1; if (m_prev_rd && !m_csx && cfg_dummy != 0) v_rd_nodum = 1; end
            m_nb = cfg_type == 2'd2 && !op_rd ? 9 : 8;
            m_np = 2 * (m_dum + m_nb);
            m_sda = op_rd ? 1'b0 : cbit(0);
          end
          if (!m_csx) v_multi = 1;
          if (op_rd && op_last) v_rd_last = 1;
          v_kind[cfg_type][op_rd] = 1;
          if (!op_rd && cfg_tw == 0) v_tw0 = 1;
          if (!op_rd && cfg_tw == 15) v_tw15 = 1;
          if (op_rd && cfg_tr == 0) v_tr0 = 1;
          if (op_rd && cfg_tr == 15) v_tr15 = 1;
          m_csx = 0;
        end
      end else if (m_j < m_len) m_j++;
      else begin : b_next
        // end of phase m_k
        if (!m_ser && m_k == 1 && m_rd) begin m_rv = 1; m_rdd = cfg_w16 ? d_i : {8'd0, d_i[7:0]}; end
        if (m_ser && m_k < m_np && m_k % 2 == 0 && m_rd && m_k / 2 >= m_dum) m_rsh = {m_rsh[6:0], sda_i};
        if (m_ser && m_k == m_np - 1 && m_rd) begin m_rv = 1; m_rdd = {8'd0, m_rsh}; end
        if (m_ser && m_k < m_np - 1 && m_k % 2 == 1 && !m_rd && (m_k + 1) / 2 >= m_dum)
          m_sda = cbit((m_k + 1) / 2 - m_dum);
        if (m_ser && m_k == m_np - 1) m_prev_rd = m_rd;
        m_k++; m_j = 0;
        m_len = int'(m_rd ? cfg_tr : cfg_tw);
        if (m_k == m_np && m_last) m_csx = 1;
        if (m_k == m_np + int'(m_last)) m_on = 0;
      end
    end

  wire       ab = m_on && !m_ser && m_k < 3;
  wire       cb = m_on && m_ser && m_k < m_np;
  wire       e_wrx = ab ? (m_ty == 2'd0 ? m_rd : !(m_k == 1 && !m_rd)) : 1'b1;
  wire       e_rdx = ab ? (m_ty == 2'd0 ? m_k == 1 : !(m_k == 1 && m_rd)) : m_rdx_idle;

  // ---------------- assertions ----------------
  `SVA_INV(a_op_ready, op_ready == !m_on)
  `SVA_INV(a_busy, busy == (m_on || !m_csx))
  `SVA_INV(a_csx, csx == m_csx)
  `SVA_INV(a_dcx, dcx == m_dcx)
  `SVA_INV(a_wrx, wrx == e_wrx)
  `SVA_INV(a_rdx, rdx == e_rdx)
  `SVA_INV(a_d_oe, d_oe == (ab && !m_rd))
  `SVA_INV(a_d_o, d_o == m_do)
  `SVA_INV(a_scl, scl == (cb && m_k % 2 == 1))
  `SVA_INV(a_sda_oe, sda_oe == (cb && !m_rd))
  `SVA_INV(a_sda_o, sda_o == m_sda)
  `SVA_INV(a_rd_valid, rd_valid == m_rv)
  `SVA_IMP(a_rd_data, m_rv, rd_data == m_rdd)
  // a strobe only with CSX low (the clock after a cfg_type change still shows
  // the old type's idle level)
  `SVA_IMP(a_strobe_csx, $stable(cfg_type) && ((cfg_type == 2'd1 && (!wrx || !rdx)) || (cfg_type == 2'd0 && rdx) || scl), !csx)
  `SVA_RST(a_reset, 1'b1, csx && !d_oe && !sda_oe && !scl && op_ready && !rd_valid)

  function automatic int dcls(input logic [15:0] v, input bit w16);
    logic [15:0] m;
    m = w16 ? 16'hFFFF : 16'h00FF;
    v &= m;
    return v == 0 ? 0 : v == m ? 1 : (v == (16'h5555 & m) || v == (16'hAAAA & m)) ? 2 : 3;
  endfunction
  // ops by interface type, direction and D/C; write and read data classes
  covergroup cg_dbi @(negedge clk);
    option.per_instance = 1;
    cp_type: coverpoint cfg_type iff (rst_n && op_valid && op_ready) { bins t[] = {[0:3]}; }
    cp_dir: coverpoint op_rd iff (rst_n && op_valid && op_ready) { bins wr = {0}; bins rd = {1}; }
    cp_dc: coverpoint op_dc iff (rst_n && op_valid && op_ready) { bins cmd = {0}; bins data = {1}; }
    x_op: cross cp_type, cp_dir;
    x_dir_dc: cross cp_dir, cp_dc;
    cp_wdata: coverpoint dcls(op_data, cfg_w16 && !cfg_type[1]) iff (rst_n && op_valid && op_ready && !op_rd)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls(rd_data, cfg_w16 && !cfg_type[1]) iff (rst_n && rd_valid)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_dbi u_cg_dbi = new;

  // ---------------- functional coverage ----------------
  `FC(type_a_write, v_kind[0][0])
  `FC(type_a_read, v_kind[0][1])
  `FC(type_b_write, v_kind[1][0])
  `FC(type_b_read, v_kind[1][1])
  `FC(type_c1_write, v_kind[2][0])
  `FC(type_c1_read, v_kind[2][1])
  `FC(type_c3_write, v_kind[3][0])
  `FC(type_c3_read, v_kind[3][1])
  `FC(write_8bit, v_w16[0][0])
  `FC(write_16bit, v_w16[0][1])
  `FC(read_8bit, v_w16[1][0])
  `FC(read_16bit, v_w16[1][1])
  `FC(dummy_0, v_dum[0])
  `FC(dummy_1, v_dum[1])
  `FC(dummy_2, v_dum[2])
  `FC(dummy_3, v_dum[3])
  `FC(read_after_read_no_dummy, v_rd_nodum)
  `FC(write_phase_min, v_tw0)
  `FC(write_phase_max, v_tw15)
  `FC(read_phase_min, v_tr0)
  `FC(read_phase_max, v_tr15)
  `FC(ops_in_one_transaction, v_multi)
  `FC(read_ends_transaction, v_rd_last)
  `FC(back_to_back, !op_ready && op_valid ##1 op_ready && op_valid)
  `FC(command, op_valid && op_ready && !op_dc)
  `FC(parameter, op_valid && op_ready && op_dc)
  `FC_RST(reset_in_transfer, rst_n && m_on ##1 !rst_n)
endmodule

bind MIPI_DBI__Display_Bus_Interface__top MIPI_DBI__Display_Bus_Interface__sva u_sva (.*);
