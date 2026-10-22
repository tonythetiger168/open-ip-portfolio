// SPDX-License-Identifier: Apache-2.0
// OCP-IP master: a pin-level model of the transaction sequencer (descriptor
// accept, write-word collect, per-beat issue under SCmdAccept, 64-clk
// accept timeout, response drain) predicts every OCP request pin, the
// CPU response port and irq.
`include "cov_macros.svh"
module OCP_IP_Open_Core_Protocol_sva #(parameter int DW = 32, parameter int AW = 32) (
  input logic          clk, rst_n,
  input logic          req_valid, req_ready, req_rw, req_posted,
  input logic [AW-1:0] req_addr,
  input logic [4:0]    req_len,
  input logic [DW-1:0] req_wdata,
  input logic          resp_valid, resp_err,
  input logic [DW-1:0] resp_rdata,
  input logic [2:0]    MCmd,
  input logic [AW-1:0] MAddr,
  input logic [DW-1:0] MData,
  input logic [3:0]    MByteEn,
  input logic [4:0]    MBurstLength,
  input logic [2:0]    MBurstSeq,
  input logic          SCmdAccept,
  input logic [1:0]    SResp,
  input logic [DW-1:0] SData,
  input logic          SRespLast,
  input logic          irq
);
  `COV_CLOCKING(clk, !rst_n)

  // model phases
  localparam logic [2:0] P_IDLE = 0, P_COLLECT = 1, P_REQ = 2, P_RD = 3, P_WR = 4, P_FIN = 5;
  logic [2:0]    ph;
  logic          m_wr, m_np, m_ferr, m_irq;
  logic [AW-1:0] m_addr;
  int            m_len, m_got, m_beat, m_rsp, m_wait;
  logic [DW-1:0] m_wd [0:7];

  wire [4:0] clamp = req_len == 0 ? 5'd1 : req_len > 8 ? 5'd8 : req_len;
  wire acc_desc   = ph == P_IDLE && req_valid;
  wire acc_word   = ph == P_COLLECT && req_valid;
  wire issuing    = ph == P_REQ;
  wire timeout    = issuing && !SCmdAccept && m_wait == 63;
  wire last_beat  = issuing && SCmdAccept && (!m_wr || m_beat == m_len - 1);
  wire in_rsp     = (ph == P_RD || ph == P_WR) && SResp != 2'd0;
  wire bad_rsp    = in_rsp && (SResp == 2'd2 || SResp == 2'd3);
  wire rd_done    = ph == P_RD && SResp != 2'd0 && (SRespLast || m_rsp + 1 == m_len);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= P_IDLE; m_wr <= 0; m_np <= 0; m_ferr <= 0; m_irq <= 0; m_addr <= '0;
      m_len <= 1; m_got <= 0; m_beat <= 0; m_rsp <= 0; m_wait <= 0;
    end else begin
      unique case (ph)
        P_IDLE: if (req_valid) begin
          m_wr <= req_rw; m_np <= req_posted; m_addr <= req_addr; m_len <= int'(clamp);
          m_beat <= 0; m_rsp <= 0; m_wait <= 0;
          if (req_len > 8) m_irq <= 1;
          if (req_rw) begin
            m_wd[0] <= req_wdata; m_got <= 1;
            ph <= clamp > 1 ? P_COLLECT : P_REQ;
          end else ph <= P_REQ;
        end
        P_COLLECT: if (req_valid) begin
          m_wd[m_got] <= req_wdata; m_got <= m_got + 1;
          if (m_got + 1 == m_len) ph <= P_REQ;
        end
        P_REQ: if (SCmdAccept) begin
          m_wait <= 0;
          if (!m_wr) ph <= P_RD;
          else if (m_beat == m_len - 1) begin
            if (m_np) begin m_ferr <= 0; ph <= P_FIN; end
            else ph <= P_WR;
          end else m_beat <= m_beat + 1;
        end else if (m_wait == 63) begin
          m_ferr <= 1; m_irq <= 1; ph <= P_FIN; m_wait <= m_wait + 1;
        end else m_wait <= m_wait + 1;
        P_RD: if (SResp != 0) begin
          if (SResp[1]) m_irq <= 1;
          if (rd_done) ph <= P_IDLE;
          m_rsp <= m_rsp + 1;
        end
        P_WR: if (SResp != 0) begin
          if (SResp[1]) m_irq <= 1;
          ph <= P_IDLE;
        end
        P_FIN: ph <= P_IDLE;
        default: ph <= P_IDLE;
      endcase
    end
  end

  wire [2:0] exp_cmd = !issuing ? 3'd0 : !m_wr ? 3'd2 : m_np ? 3'd5 : 3'd1;

  `SVA_RST(a_reset_quiet, !rst_n, MCmd == 3'd0 && req_ready && !resp_valid && !irq)
  `SVA_INV(a_req_ready, req_ready == (ph == P_IDLE || ph == P_COLLECT))
  `SVA_INV(a_mcmd, MCmd == exp_cmd)
  `SVA_IMP(a_maddr, issuing, MAddr == m_addr)
  `SVA_IMP(a_burst_len, issuing, MBurstLength == 5'(m_len))
  `SVA_IMP(a_wdata_beat, issuing && m_wr, MData == m_wd[m_beat])
  `SVA_INV(a_byteen_incr, MByteEn == 4'hF && MBurstSeq == 3'd0)
  `SVA_INV(a_resp_valid, resp_valid == (in_rsp || ph == P_FIN))
  `SVA_INV(a_resp_err, resp_err == (bad_rsp || (ph == P_FIN && m_ferr)))
  `SVA_IMP(a_resp_rdata, ph == P_RD && SResp != 2'd0, resp_rdata == SData)
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_NXT(a_req_held, issuing && !SCmdAccept && !timeout,
           MCmd == $past(MCmd) && MAddr == $past(MAddr) && MData == $past(MData))
  `SVA_NXT(a_timeout_abort, timeout, resp_valid && resp_err && MCmd == 3'd0)

  `FC(read_single, acc_desc && !req_rw && clamp == 1)
  `FC(read_burst8, acc_desc && !req_rw && clamp == 8)
  `FC(write_single, acc_desc && req_rw && !req_posted && clamp == 1)
  `FC(write_burst8, last_beat && m_wr && !m_np && m_len == 8)
  `FC(posted_burst, last_beat && m_wr && m_np && m_len > 1)
  `FC(len_zero, acc_desc && req_len == 5'd0)
  `FC(len_over, acc_desc && req_len > 5'd8)
  `FC(collect_gap, ph == P_COLLECT && !req_valid)
  `FC(backpressure_write_beat, issuing && m_wr && m_beat > 0 && !SCmdAccept)
  `FC(timeout_abort, timeout)
  `FC(read_err, ph == P_RD && SResp == 2'd3)
  `FC(read_fail, ph == P_RD && SResp == 2'd2)
  `FC(write_err, ph == P_WR && SResp == 2'd3)
  `FC(write_fail, ph == P_WR && SResp == 2'd2)
  `FC(read_ok_after_err_beat, ph == P_RD && SResp == 2'd3 ##[1:4] ph == P_RD && SResp == 2'd1)
  `FC(error_while_irq_set, bad_rsp && m_irq)
  `FC(back_to_back, rd_done ##1 acc_desc)
  `FC_RST(reset_mid_collect, rst_n && ph == P_COLLECT ##1 !rst_n)

  covergroup cg_len @(posedge clk iff (rst_n && acc_desc));
    coverpoint clamp { bins l1 = {1}; bins l2 = {2}; bins l3 = {3}; bins l4 = {4};
                       bins l5 = {5}; bins l6 = {6}; bins l7 = {7}; bins l8 = {8}; }
    coverpoint {req_rw, req_posted} { bins rd = {2'b00, 2'b01}; bins wr = {2'b10}; bins wrnp = {2'b11}; }
  endgroup
  cg_len u_cg_len = new();
endmodule

bind OCP_IP_Open_Core_Protocol_top OCP_IP_Open_Core_Protocol_sva #(.DW(DW), .AW(AW)) u_sva (.*);
