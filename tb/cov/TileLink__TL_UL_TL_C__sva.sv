// SPDX-License-Identifier: Apache-2.0
// TileLink TL-UL slave: concurrent SVA against an independent request model
// (legality checks, AccessAck/AccessAckData, source/size echo, regfile
// shadow with mask merge) + functional coverage.
`include "cov_macros.svh"
module TileLink__TL_UL_TL_C__sva #(parameter int DW = 32, AW = 32) (
  input logic          clk, rst_n,
  input logic          a_valid, a_ready, d_valid, d_ready, d_error, irq,
  input logic [2:0]    a_opcode, a_param, a_size, d_opcode, d_size,
  input logic [7:0]    a_source, d_source,
  input logic [AW-1:0] a_address,
  input logic [3:0]    a_mask,
  input logic [DW-1:0] a_data, d_data
);
  `COV_CLOCKING(clk, !rst_n)
  wire a_hs = a_valid && a_ready, d_hs = d_valid && d_ready;
  wire is_get = a_opcode == 3'd4, is_pp = a_opcode == 3'd1, is_pf = a_opcode == 3'd0;
  wire legal = (is_get || is_pp || is_pf) && a_size == 3'd2 && a_address[1:0] == 0 &&
               a_address < 32'h100 && a_param == 0 &&
               (is_pp ? a_mask != 0 : a_mask == 4'hF);

  logic [DW-1:0] shadow [0:63];        // regfile is not reset
  initial for (int i = 0; i < 64; i++) shadow[i] = '0;
  logic          m_pend, m_err, m_get;
  logic [2:0]    m_size;
  logic [7:0]    m_src;
  logic [DW-1:0] m_data;
  logic          m_irq;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_pend <= 0; m_err <= 0; m_get <= 0; m_size <= 0; m_src <= 0; m_data <= '0; m_irq <= 0;
    end else begin
      if (a_hs) begin
        m_pend <= 1; m_err <= !legal; m_get <= is_get; m_size <= a_size; m_src <= a_source;
        m_data <= (is_get && legal) ? shadow[a_address[7:2]] : '0;
        if (legal && !is_get)
          for (int b = 0; b < 4; b++)
            if (a_mask[b]) shadow[a_address[7:2]][8*b +: 8] <= a_data[8*b +: 8];
        if (!legal) m_irq <= 1;
      end else if (d_hs) m_pend <= 0;
    end
  end

  `SVA_RST(a_reset_quiet, !rst_n, !d_valid && !irq && a_ready)
  `SVA_IMP(a_dvalid_model, 1'b1, d_valid == m_pend)
  `SVA_IMP(a_aready_model, 1'b1, a_ready == (!m_pend || d_ready))
  `SVA_IMP(a_resp_fields, d_valid, d_opcode == {2'b00, m_get} && d_size == m_size &&
                                   d_source == m_src && d_error == m_err)
  `SVA_IMP(a_resp_data, d_valid, d_data == m_data)
  `SVA_NXT(a_d_stable, d_valid && !d_ready, d_valid && $stable(d_data) && $stable(d_source) &&
                                            $stable(d_error) && $stable(d_opcode))
  `SVA_IMP(a_irq_model, 1'b1, irq == m_irq)

  covergroup cg_a @(posedge clk);
    option.per_instance = 1;
    cp_op: coverpoint a_opcode iff (rst_n && a_hs)
      { bins putfull = {0}; bins putpartial = {1}; bins get = {4}; bins illegal = {2, 3, 5, 6, 7}; }
    cp_err: coverpoint {a_param != 0, a_size != 2, a_address[1:0] != 0, a_address >= 32'h100}
            iff (rst_n && a_hs)
      { bins none = {0}; bins param = {8}; bins size = {4}; bins misaligned = {2}; bins range = {1}; }
    cp_mask: coverpoint a_mask iff (rst_n && a_hs && (is_pp || is_get))
      { bins zero = {0}; bins full = {4'hF}; bins partial = default; }
    cp_op_ok: coverpoint a_opcode iff (rst_n && a_hs && legal)
      { bins putfull = {0}; bins putpartial = {1}; bins get = {4}; }
    cp_op_bad: coverpoint a_opcode iff (rst_n && a_hs && !legal)
      { bins putfull = {0}; bins putpartial = {1}; bins get = {4}; bins illegal = {2, 3, 5, 6, 7}; }
  endgroup
  cg_a u_cg_a = new;

  `FC(d_backpressure, d_valid && !d_ready)
  `FC(back_to_back_accept, a_hs && d_hs)
  `FC(a_waits_on_d, a_valid && !a_ready)
  `FC_RST(reset_with_response_pending, rst_n && d_valid ##1 !rst_n)
endmodule

bind TileLink__TL_UL_TL_C__top TileLink__TL_UL_TL_C__sva #(.DW(DW), .AW(AW)) u_sva (.*);
