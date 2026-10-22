// SPDX-License-Identifier: Apache-2.0
// OCP slave: concurrent SVA against an independent request/response model
// (accept latency per ACCEPT_DLY, fixed 2-cycle DVA, posted writes, regfile
// shadow with MByteEn merge, ERR on bad address / unsupported MCmd) +
// functional coverage. Bound to every OCP_top instance.
`include "cov_macros.svh"
module OCP_sva #(parameter int DW = 32, AW = 32, ACCEPT_DLY = 1) (
  input logic            clk, rst_n,
  input logic [2:0]      mcmd,
  input logic [AW-1:0]   maddr,
  input logic [DW-1:0]   mdata, sdata,
  input logic [DW/8-1:0] mbyteen,
  input logic [1:0]      mthreadid, sresp, sthreadid,
  input logic            scmdaccept, irq
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [2:0] WR = 3'd1, RD = 3'd2, WRNP = 3'd5;
  localparam logic [1:0] NUL = 2'd0, DVA = 2'd1, ERR = 2'd2;
  wire cmd      = mcmd != 3'd0;
  wire acc      = scmdaccept && cmd;
  wire addr_bad = (maddr[AW-1:10] != '0) || (maddr[1:0] != 2'b00);
  wire supp     = mcmd inside {WR, RD, WRNP};
  wire bad      = addr_bad || !supp;
  wire posted   = mcmd == WRNP;

  // ---------------- independent reference model ----------------
  logic [DW-1:0] shadow [0:255];       // regfile is not reset
  initial for (int i = 0; i < 256; i++) shadow[i] = '0;
  logic [1:0]    m_pipe;               // [0]: latency cycle, [1]: response cycle
  logic [1:0]    m_rsp, m_tid;
  logic          m_rd;
  logic [DW-1:0] m_rdata;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_pipe <= 0; m_rsp <= NUL; m_tid <= 0; m_rd <= 0; m_rdata <= '0;
    end else begin
      m_pipe <= {m_pipe[0], acc && !posted};
      if (acc) begin
        m_rsp <= bad ? ERR : DVA; m_tid <= mthreadid; m_rd <= mcmd == RD;
        m_rdata <= shadow[maddr[9:2]];
        if (!addr_bad && (mcmd == WR || mcmd == WRNP))
          for (int b = 0; b < DW/8; b++)
            if (mbyteen[b]) shadow[maddr[9:2]][8*b +: 8] <= mdata[8*b +: 8];
      end
    end
  end
  wire busy = m_pipe != 0;

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_quiet, !rst_n, sresp == NUL && !scmdaccept && !irq)
  `SVA_IMP(a_no_accept_when_busy, busy, !scmdaccept)
  `SVA_IMP(a_accept_same_cycle, ACCEPT_DLY == 0 && !busy && cmd, scmdaccept)
  `SVA_IMP(a_accept_wait_one, ACCEPT_DLY == 1 && !busy && cmd && !$past(cmd && !busy && !acc),
           !scmdaccept)
  `SVA_NXT(a_accept_next_cycle, ACCEPT_DLY == 1 && !busy && cmd && !scmdaccept, scmdaccept)
  `SVA_IMP(a_accept_needs_cmd, scmdaccept, cmd)
  `SVA_IMP(a_resp_timing, 1'b1, (sresp != NUL) == m_pipe[1])
  `SVA_IMP(a_resp_value, m_pipe[1], sresp == m_rsp && sthreadid == m_tid)
  `SVA_IMP(a_read_data, m_pipe[1] && m_rd && m_rsp == DVA, sdata == m_rdata)
  `SVA_NXT(a_irq_on_bad, acc && bad, irq)
  `SVA_IMP(a_irq_cause, irq, $past(acc && bad))

  // ---------------- functional coverage ----------------
  covergroup cg_req @(posedge clk);
    option.per_instance = 1;
    cp_cmd: coverpoint mcmd iff (rst_n && acc)
      { bins wr = {WR}; bins rd = {RD}; bins wrnp = {WRNP}; bins unsupported = {3, 4, 6, 7}; }
    cp_addr: coverpoint {maddr[AW-1:10] != 0, maddr[1:0] != 0} iff (rst_n && acc)
      { bins ok = {2'b00}; bins misaligned = {2'b01}; bins out_of_range = {2'b10, 2'b11}; }
    cp_cmd_ok: coverpoint mcmd iff (rst_n && acc && supp)
      { bins wr = {WR}; bins rd = {RD}; bins wrnp = {WRNP}; }
    cp_be: coverpoint mbyteen iff (rst_n && acc && (mcmd == WR || mcmd == WRNP))
      { bins full = {4'hF}; bins none = {0}; bins partial = default; }
    cp_tid: coverpoint mthreadid iff (rst_n && acc && !posted);
    x_cmd_addr: cross cp_cmd_ok, cp_addr;
  endgroup
  cg_req u_cg_req = new;

  `FC(accept_right_after_resp, acc && $past(m_pipe[1]))
  `FC(cmd_after_posted, acc && $past(acc && posted))
  `FC(cmd_waits_while_busy, cmd && busy)
  `FC(accept_dly0, ACCEPT_DLY == 0 && acc)
  `FC(accept_dly1, ACCEPT_DLY == 1 && acc)
  `FC_RST(reset_during_latency, rst_n && busy ##1 !rst_n)
endmodule

bind OCP_top OCP_sva #(.DW(DW), .AW(AW), .ACCEPT_DLY(ACCEPT_DLY)) u_sva (.*);
