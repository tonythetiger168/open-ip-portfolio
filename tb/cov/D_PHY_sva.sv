// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// D-PHY lane pair: a cycle-level model fed only by the pins predicts every
// output on every clock. The transmitter is modelled as a list of line
// symbols per phase (SoT, sync, payload bits, EoT; escape entry, command,
// LPDT bits, hold, exit) driven from the host handshakes; the receiver as a
// symbol classifier walking the same grammar on the r_* inputs.
`include "cov_macros.svh"
module D_PHY_sva (
  input logic       clk, rst_n, irq, irq_clear,
  input logic       hs_req, hs_tx_valid, hs_tx_ready, hs_tx_done,
  input logic [7:0] hs_tx_data,
  input logic       esc_req, esc_release, lpdt_valid, lpdt_last, lpdt_ready, esc_done,
  input logic [7:0] esc_cmd, lpdt_data,
  input logic       d_lp_p, d_lp_n, d_hs_p, d_hs_n, d_hs_en,
  input logic       c_lp_p, c_lp_n, c_hs_p, c_hs_n, c_hs_en,
  input logic       r_lp_p, r_lp_n, r_hs_p, r_hs_n, r_hs_en,
  input logic       rx_hs_active, rx_data_valid, rx_esc_valid, rx_ulps,
  input logic [7:0] rx_data, rx_esc_cmd
);
  `COV_CLOCKING(clk, !rst_n)

  // TX phases
  localparam int STOP = 0, REQ = 1, BR = 2, HS0 = 3, SYNC = 4, DATA = 5, EOT1 = 6, EOT2 = 7,
                 E1 = 8, E2 = 9, E3 = 10, E4 = 11, CMD = 12, LPDT = 13, ULPS = 14, TRIG = 15,
                 XSP = 16, X10 = 17;
  // RX phases
  localparam int R_STOP = 0, R_REQ = 1, R_BR = 2, R_SYNC = 3, R_DATA = 4, R_E1 = 5, R_E2 = 6,
                 R_E3 = 7, R_CMD = 8, R_LPDT = 9, R_ULPS = 10, R_TRIG = 11, R_X1 = 12,
                 R_X2 = 13, R_ERR = 14;

  // transmitter
  int          tp, tb, hold;
  logic [7:0]  word, cmd, pcmd, bd;
  logic        hp, ep, bv, bl, wl, lastb, ck;
  logic        m_done_hs, m_done_esc;
  // receiver
  int          rp, rb;
  logic [7:0]  rw, m_rdata, m_rcmd;
  logic        m_rvalid, m_cvalid, m_err;
  // coverage events
  logic v_hs0, v_hs3, v_hs_stall, v_hs_pend, v_esc_pend, v_both, v_esc_replace, v_lpdt0,
        v_lpdt3, v_lpdt_under, v_ulps, v_trig, v_unknown, v_rel_early, v_clr_set,
        v_e_stop00, v_e_req, v_e_br, v_e_sync_en, v_e_sync_diff, v_e_sync_bad, v_e_data_diff,
        v_e_esc1, v_e_esc2, v_e_esc3, v_e_cmd_lp, v_e_cmd_unk, v_e_lpdt, v_e_ulps, v_e_trig,
        v_e_x1, v_e_x2, v_err_hs, v_hs_rx, v_lpdt_rx, v_esc_rx;

  // pad levels of the current TX phase
  function automatic logic [1:0] t_lp(input int p, input logic b0, input logic xs);
    case (p)
      REQ, E3, XSP: t_lp = 2'b01;
      BR, E2, E4, ULPS, TRIG: t_lp = 2'b00;
      E1, X10: t_lp = 2'b10;
      CMD: t_lp = b0 ? 2'b10 : 2'b00;
      LPDT: t_lp = xs ? 2'b01 : (b0 ? 2'b10 : 2'b00);
      default: t_lp = 2'b11;
    endcase
  endfunction

  logic        lpdt_b0, lpdt_x;
  logic [1:0]  m_dlp, m_clp;
  logic        m_hs_en, m_hs_b, m_rdy_hs, m_rdy_lp;
  always_comb begin
    lpdt_x   = tp == LPDT && tb == 0 && !bv;
    lpdt_b0  = (tp == LPDT && tb == 0) ? bd[0] : word[0];
    m_dlp    = t_lp(tp, lpdt_b0, lpdt_x);
    m_clp    = (tp == REQ || tp == BR) ? m_dlp : 2'b11;
    m_hs_en  = tp inside {HS0, SYNC, DATA, EOT1, EOT2};
    m_hs_b   = (tp == SYNC || tp == DATA) ? word[0] : (tp == EOT1) ? !lastb :
               (tp == EOT2) ? lastb : 1'b0;
    m_rdy_hs = !bv && (tp == SYNC || tp == DATA) && tb != 7;
    m_rdy_lp = !bv && ((tp == LPDT && tb != 0) || (tp == CMD && cmd == 8'h87));
  end

  always @(posedge clk or negedge rst_n) begin
    logic        fill_hs, fill_lp, byte_end;
    logic [1:0]  l;
    logic [7:0]  nb;
    if (!rst_n) begin
      tp = STOP; tb = 0; hold = 0; word = 0; cmd = 0; pcmd = 0; bd = 0;
      hp = 0; ep = 0; bv = 0; bl = 0; wl = 0; lastb = 0; ck = 0;
      m_done_hs = 0; m_done_esc = 0;
      rp = R_STOP; rb = 0; rw = 0; m_rdata = 0; m_rcmd = 0; m_rvalid = 0; m_cvalid = 0;
      m_err = 0;
    end else begin
      {v_hs0, v_hs3, v_hs_stall, v_hs_pend, v_esc_pend, v_both, v_esc_replace, v_lpdt0,
       v_lpdt3, v_lpdt_under, v_ulps, v_trig, v_unknown, v_rel_early, v_clr_set,
       v_e_stop00, v_e_req, v_e_br, v_e_sync_en, v_e_sync_diff, v_e_sync_bad, v_e_data_diff,
       v_e_esc1, v_e_esc2, v_e_esc3, v_e_cmd_lp, v_e_cmd_unk, v_e_lpdt, v_e_ulps, v_e_trig,
       v_e_x1, v_e_x2, v_err_hs, v_hs_rx, v_lpdt_rx, v_esc_rx} = '0;
      // ================= transmitter
      m_done_hs = 0; m_done_esc = 0;
      fill_hs = hs_tx_valid && m_rdy_hs;
      fill_lp = !fill_hs && lpdt_valid && m_rdy_lp;
      v_both        = hs_req && esc_req && tp == STOP;
      v_hs_pend     = hs_req && tp != STOP;
      v_esc_pend    = esc_req && tp != STOP;
      v_esc_replace = esc_req && ep && tp != STOP;
      v_rel_early   = esc_release && tp != ULPS;
      if (hs_req) hp = 1;
      if (esc_req) begin ep = 1; pcmd = esc_cmd; end
      ck = m_hs_en ? !ck : 1'b0;
      case (tp)
        STOP: if (hp) begin tp = REQ; hp = 0; end
              else if (ep) begin tp = E1; ep = 0; cmd = esc_req ? esc_cmd : pcmd; end
        REQ:  tp = BR;
        BR:   tp = HS0;
        HS0:  begin tp = SYNC; tb = 0; word = 8'hB8; hold = 0; end
        SYNC, DATA: begin
          lastb = word[0]; word = word >> 1;
          if (tb == 7) begin
            tb = 0;
            if (bv) begin
              tp = DATA; word = bd; bv = 0; hold++;
            end else begin
              v_hs0 = hold == 0; v_hs3 = hold == 3; v_hs_stall = hs_tx_valid;
              tp = EOT1;
            end
          end else tb++;
        end
        EOT1: tp = EOT2;
        EOT2: begin tp = STOP; m_done_hs = 1; end
        E1:   tp = E2;
        E2:   tp = E3;
        E3:   tp = E4;
        E4:   begin tp = CMD; tb = 0; word = cmd; hold = 0; end
        CMD: begin
          word = word >> 1;
          if (tb == 7) begin
            tb = 0;
            case (cmd)
              8'h87: tp = LPDT;
              8'h78: begin tp = ULPS; v_ulps = 1; end
              8'h46: begin tp = TRIG; hold = 0; v_trig = 1; end
              default: begin tp = X10; v_unknown = 1; end
            endcase
          end else tb++;
        end
        LPDT: begin
          if (tb == 0) begin
            if (bv) begin
              word = bd >> 1; wl = bl; bv = 0; tb = 1; hold++;
            end else begin
              tp = X10; v_lpdt0 = hold == 0; v_lpdt_under = hold > 0;
            end
          end else begin
            word = word >> 1;
            if (tb == 7) begin
              tb = 0;
              if (wl) begin tp = XSP; v_lpdt3 = hold == 3; end
            end else tb++;
          end
        end
        ULPS: if (esc_release) tp = X10;
        TRIG: if (hold == 3) tp = X10; else hold++;
        XSP:  tp = X10;
        default: begin tp = STOP; m_done_esc = 1; end
      endcase
      if (fill_hs) begin bv = 1; bd = hs_tx_data; end
      if (fill_lp) begin bv = 1; bd = lpdt_data; bl = lpdt_last; end
      // ================= receiver
      m_rvalid = 0; m_cvalid = 0;
      v_clr_set = 0;
      if (irq_clear) m_err = 0;
      l = {r_lp_p, r_lp_n};
      case (rp)
        R_STOP: if (l == 2'b01) rp = R_REQ;
                else if (l == 2'b10) rp = R_E1;
                else if (l == 2'b00) begin rp = R_ERR; m_err = 1; v_e_stop00 = 1; end
        R_REQ:  if (l == 2'b00) rp = R_BR;
                else if (l != 2'b01) begin rp = R_ERR; m_err = 1; v_e_req = 1; end
        R_BR:   if (r_hs_en && !r_hs_p && r_hs_n) begin rp = R_SYNC; rb = 0; end
                else begin rp = R_ERR; m_err = 1; v_e_br = 1; end
        R_SYNC, R_DATA: begin
          if (!r_hs_en && rp == R_DATA) rp = R_STOP;
          else if (!r_hs_en || r_hs_p == r_hs_n) begin
            m_err = 1;
            v_e_sync_en   = rp == R_SYNC && !r_hs_en;
            v_e_sync_diff = rp == R_SYNC && r_hs_en;
            v_e_data_diff = rp == R_DATA;
            rp = R_ERR;
          end else begin
            nb = {r_hs_p, rw[7:1]};
            rw = nb;
            if (rb == 7) begin
              rb = 0;
              if (rp == R_DATA) begin m_rdata = nb; m_rvalid = 1; v_hs_rx = 1; end
              else if (nb == 8'hB8) rp = R_DATA;
              else begin rp = R_ERR; m_err = 1; v_e_sync_bad = 1; end
            end else rb++;
          end
        end
        R_E1:   if (l == 2'b00) rp = R_E2; else begin rp = R_ERR; m_err = 1; v_e_esc1 = 1; end
        R_E2:   if (l == 2'b01) rp = R_E3; else begin rp = R_ERR; m_err = 1; v_e_esc2 = 1; end
        R_E3:   if (l == 2'b00) begin rp = R_CMD; rb = 0; end
                else begin rp = R_ERR; m_err = 1; v_e_esc3 = 1; end
        R_CMD:  if (l == 2'b10 || l == 2'b00) begin
                  nb = {r_lp_p, rw[7:1]};
                  rw = nb;
                  if (rb == 7) begin
                    rb = 0; m_rcmd = nb; m_cvalid = 1; v_esc_rx = 1;
                    case (nb)
                      8'h87: rp = R_LPDT;
                      8'h78: rp = R_ULPS;
                      8'h46: rp = R_TRIG;
                      default: begin rp = R_ERR; m_err = 1; v_e_cmd_unk = 1; end
                    endcase
                  end else rb++;
                end else begin rp = R_ERR; m_err = 1; v_e_cmd_lp = 1; end
        R_LPDT: if (rb == 0 && l == 2'b01) rp = R_X1;
                else if (l == 2'b10 || l == 2'b00) begin
                  nb = {r_lp_p, rw[7:1]};
                  rw = nb;
                  if (rb == 7) begin rb = 0; m_rdata = nb; m_rvalid = 1; v_lpdt_rx = 1; end
                  else rb++;
                end else begin rp = R_ERR; m_err = 1; v_e_lpdt = 1; end
        R_ULPS, R_TRIG:
                if (l == 2'b10) rp = R_X2;
                else if (l != 2'b00) begin
                  v_e_ulps = rp == R_ULPS; v_e_trig = rp == R_TRIG;
                  rp = R_ERR; m_err = 1;
                end
        R_X1:   if (l == 2'b10) rp = R_X2; else begin rp = R_ERR; m_err = 1; v_e_x1 = 1; end
        R_X2:   if (l == 2'b11) rp = R_STOP; else begin rp = R_ERR; m_err = 1; v_e_x2 = 1; end
        default: begin
          v_err_hs = l == 2'b11 && r_hs_en;
          if (l == 2'b11 && !r_hs_en) rp = R_STOP;
        end
      endcase
      v_clr_set = irq_clear && m_err;
    end
  end

  `SVA_RST(a_reset_outputs, !rst_n, {d_lp_p, d_lp_n, c_lp_p, c_lp_n} == 4'hF && !d_hs_en &&
           !c_hs_en && !irq && !hs_tx_done && !esc_done && !rx_data_valid && !rx_esc_valid)
  `SVA_INV(a_d_lp, {d_lp_p, d_lp_n} == m_dlp)
  `SVA_INV(a_c_lp, {c_lp_p, c_lp_n} == m_clp)
  `SVA_INV(a_d_hs_en, d_hs_en == m_hs_en)
  `SVA_INV(a_c_hs_en, c_hs_en == m_hs_en)
  `SVA_IMP(a_d_hs, d_hs_en, d_hs_p == m_hs_b && d_hs_n == !m_hs_b)
  `SVA_INV(a_c_hs, c_hs_p == ck && c_hs_n == !ck)
  `SVA_INV(a_hs_tx_ready, hs_tx_ready == m_rdy_hs)
  `SVA_INV(a_lpdt_ready, lpdt_ready == m_rdy_lp)
  `SVA_INV(a_done, hs_tx_done == m_done_hs && esc_done == m_done_esc)
  `SVA_INV(a_irq, irq == m_err)
  `SVA_INV(a_rx_state, rx_hs_active == (rp == R_SYNC || rp == R_DATA) && rx_ulps == (rp == R_ULPS))
  `SVA_INV(a_rx_valid, rx_data_valid == m_rvalid && rx_esc_valid == m_cvalid)
  `SVA_IMP(a_rx_data, rx_data_valid, rx_data == m_rdata)
  `SVA_IMP(a_rx_cmd, rx_esc_valid, rx_esc_cmd == m_rcmd)

  function automatic int dcls(input logic [7:0] v);
    return v == 8'h00 ? 0 : v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA) ? 2 : 3;
  endfunction
  // bytes taken by each transmitter and handed out by the receiver, escape
  // commands sent and received
  covergroup cg_dphy @(negedge clk);
    option.per_instance = 1;
    cp_hs_tx: coverpoint dcls(hs_tx_data) iff (rst_n && hs_tx_valid && hs_tx_ready)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_lp_tx: coverpoint dcls(lpdt_data) iff (rst_n && lpdt_valid && lpdt_ready)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_hs_rx: coverpoint dcls(rx_data) iff (rst_n && rx_data_valid && rx_hs_active)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_lp_rx: coverpoint dcls(rx_data) iff (rst_n && rx_data_valid && !rx_hs_active)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_esc_tx: coverpoint esc_cmd iff (rst_n && esc_req)
      { bins lpdt = {8'h87}; bins ulps = {8'h78}; bins trigger = {8'h46};
        bins unknown = {[8'h00:8'h45], [8'h47:8'h77], [8'h79:8'h86], [8'h88:8'hFF]}; }
    cp_esc_rx: coverpoint rx_esc_cmd iff (rst_n && rx_esc_valid)
      { bins lpdt = {8'h87}; bins ulps = {8'h78}; bins trigger = {8'h46}; }
  endgroup
  cg_dphy u_cg_dphy = new;

  `FC(hs_burst_empty, v_hs0)
  `FC(hs_burst_three_bytes, v_hs3)
  `FC(hs_host_underrun_ends_burst, v_hs_stall)
  `FC(hs_request_while_busy, v_hs_pend)
  `FC(esc_request_while_busy, v_esc_pend)
  `FC(hs_and_esc_request_together, v_both)
  `FC(esc_pending_command_replaced, v_esc_replace)
  `FC(lpdt_no_bytes, v_lpdt0)
  `FC(lpdt_three_bytes_last, v_lpdt3)
  `FC(lpdt_host_underrun, v_lpdt_under)
  `FC(ulps_entered, v_ulps)
  `FC(trigger_sent, v_trig)
  `FC(unknown_command_sent, v_unknown)
  `FC(release_outside_ulps, v_rel_early)
  `FC(irq_clear_and_set_together, v_clr_set)
  `FC(rx_hs_byte, v_hs_rx)
  `FC(rx_lpdt_byte, v_lpdt_rx)
  `FC(rx_escape_command, v_esc_rx)
  `FC(rx_err_lp00_from_stop, v_e_stop00)
  `FC(rx_err_hs_request, v_e_req)
  `FC(rx_err_no_hs0, v_e_br)
  `FC(rx_err_hs_dropped_in_sync, v_e_sync_en)
  `FC(rx_err_invalid_level_in_sync, v_e_sync_diff)
  `FC(rx_err_bad_sync, v_e_sync_bad)
  `FC(rx_err_invalid_level_in_data, v_e_data_diff)
  `FC(rx_err_escape_entry_1, v_e_esc1)
  `FC(rx_err_escape_entry_2, v_e_esc2)
  `FC(rx_err_escape_entry_3, v_e_esc3)
  `FC(rx_err_lp_in_command, v_e_cmd_lp)
  `FC(rx_err_unknown_command, v_e_cmd_unk)
  `FC(rx_err_lpdt_level, v_e_lpdt)
  `FC(rx_err_ulps_level, v_e_ulps)
  `FC(rx_err_trigger_level, v_e_trig)
  `FC(rx_err_lpdt_exit, v_e_x1)
  `FC(rx_err_escape_exit, v_e_x2)
  `FC(rx_err_waits_for_hs_off, v_err_hs)
  `FC_RST(reset_during_hs, rst_n && d_hs_en ##1 !rst_n)
  `FC_RST(reset_during_escape, rst_n && d_lp_p != d_lp_n ##1 !rst_n)
endmodule

bind D_PHY_top D_PHY_sva u_sva (.*);
