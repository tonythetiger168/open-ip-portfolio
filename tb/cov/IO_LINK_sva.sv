// SPDX-License-Identifier: Apache-2.0
// IO-Link (IEC 61131-9) master / device: concurrent SVA against an
// independent, cycle-accurate reference model, plus functional coverage.
//  * Transmit model: an octet player gives tx_en / txd for every clock of a
//    master message or a device reply (one idle clock with the driver on,
//    11 bit times per octet, two idle clocks between octets, one after the
//    last); octet values come from the model's own message rules: MC, the
//    CKT checksum over the payload, payload addresses per channel, the CKS.
//  * Receive model: its own synchroniser and UART decoder (samples at
//    cfg_bit/2 + k * cfg_bit clocks after the falling edge), silence in bit
//    times, the master's reply handling (stored octets, CKS check, errors,
//    timeout) and the device's frame rules (reports, drop time, tA, wake-up
//    window). m_* and d_* outputs, buffer writes and host reads are compared
//    on every clock.
`include "cov_macros.svh"
module IO_LINK_sva (
  input  logic        clk, rst_n, cfg_master,
  input  logic [15:0] cfg_bit, cfg_wurq,
  input  logic [1:0]  cfg_mtype,
  input  logic [5:0]  cfg_pdout_len, cfg_pdin_len, cfg_od_len,
  input  logic        txd, tx_en, rxd,
  input  logic        host_rd, host_wr,
  input  logic [7:0]  host_addr, host_wdata, host_rdata,
  input  logic [7:0]  cfg_resp_timeout,
  input  logic        m_wurq, m_start,
  input  logic [7:0]  m_mc,
  input  logic        m_busy, m_done, m_err_timeout, m_err_uart, m_err_cks,
  input  logic [7:0]  m_cks,
  input  logic [6:0]  m_cnt,
  input  logic [3:0]  cfg_ta,
  input  logic        cfg_event, cfg_pd_invalid,
  input  logic        d_wurq, d_msg,
  input  logic [7:0]  d_msg_mc,
  input  logic [2:0]  d_msg_why,
  input  logic [7:0]  ram [0:255]
);
  `COV_CLOCKING(clk, !rst_n)

  function automatic logic [5:0] csum6(input logic [7:0] x);
    logic [5:0] c;
    c[5] = ^(x & 8'b1010_1010); c[4] = ^(x & 8'b0101_0101); c[3] = ^x[7:6];
    c[2] = ^x[5:4];             c[1] = ^x[3:2];             c[0] = ^x[1:0];
    return c;
  endfunction
  function automatic int len32(input logic [5:0] n);
    return n > 32 ? 32 : int'(n);
  endfunction
  int cb, n_o, n_pdo, n_pdi;
  always @* begin
    cb = int'(cfg_bit); n_o = len32(cfg_od_len); n_pdo = len32(cfg_pdout_len); n_pdi = len32(cfg_pdin_len);
  end

  // =========================================================================
  // line: synchroniser and UART decoder
  // =========================================================================
  logic l1, l2, lp;
  bit   u_busy, u_v, u_pe, u_fe;
  int   u_m, u_k;
  logic [10:0] u_bits;
  logic [7:0]  u_d;
  // one clock of the decoder (off while the own driver is on)
  task automatic u_step;
    u_v = 0;
    if (tx_en) begin
      u_busy = 0; lp = 1;
    end else if (!u_busy) begin
      if (lp && !l2) begin u_busy = 1; u_m = 0; u_k = 0; end
      lp = l2;
    end else begin
      u_m++;
      if (u_m == cb / 2 + u_k * cb) begin
        u_bits[u_k] = l2;
        if (u_k == 0 && l2) begin u_busy = 0; f_glitch = 1; end
        else if (u_k == 10) begin
          u_busy = 0; u_v = 1;
          u_d = u_bits[8:1]; u_pe = ^u_bits[9:1]; u_fe = !l2;
        end
        u_k++;
      end
      lp = l2;
    end
    l2 = l1; l1 = rxd;
  endtask
  wire u_break = u_v && u_fe && u_d == 8'h00 && !u_pe;
  wire u_bad   = u_v && (u_pe || u_fe);

  // bit times of silence: whole bit times since the last octet event (end of
  // the own transmission, an octet received); decoder activity restarts the
  // current bit time
  int  s_clk, s_bits;
  bit  s_tick;

  // =========================================================================
  // octet player (both roles)
  // =========================================================================
  bit         p_on, e_ten, e_txd;
  int         p_k, p_n, p_c;                 // octet, octets, clock in the octet slot (-1: idle before)
  logic [7:0] p_v, p_acc;
  logic [7:0] p_mc, p_ckt;
  bit         p_master, p_done;
  // octet k: master message or device reply
  function automatic logic [7:0] octet(input int k);
    int j, a;
    if (p_master) begin
      if (k == 0) return p_mc;
      if (k == 1) return p_ckt;
      j = k - 2;
      a = j < n_pdo ? j : 32 + (j - n_pdo);
      return ram[a];
    end
    if (k == p_n - 1) return {cfg_event, cfg_pd_invalid, csum6(p_acc ^ {cfg_event, cfg_pd_invalid, 6'd0})};
    if (p_mc[7] && k < n_o) begin
      if (p_mc[6:5] == 2'd1) return ram[128 + ((int'(p_mc[4:0]) + k) % 32)];
      return ram[32 + k];
    end
    j = k - (p_mc[7] ? n_o : 0);
    return ram[j];
  endfunction
  task automatic p_start(input bit master, input int n);
    p_on = 1; p_master = master; p_n = n; p_k = 0; p_c = -1; e_ten = 1; e_txd = 1; p_acc = 8'h52;
  endtask
  // one clock of the player; p_done for the clock the driver turns off
  task automatic p_step;
    int b;
    p_done = 0;
    if (!p_on) return;
    if (p_c == -1) begin
      p_v = octet(p_k); p_c = 0;
      if (!(p_master || p_k == p_n - 1)) p_acc = p_acc ^ p_v;
    end else p_c++;
    if (p_c < 11 * cb) begin
      b = p_c / cb;
      e_txd = b == 0 ? 1'b0 : b <= 8 ? p_v[b - 1] : b == 9 ? ^p_v : 1'b1;
    end else begin
      e_txd = 1;
      if (p_c == 11 * cb + 1) begin
        if (p_k == p_n - 1) begin p_on = 0; e_ten = 0; p_done = 1; end
        else begin p_k++; p_c = -1; end
      end
    end
  endtask

  // =========================================================================
  // master and device model
  // =========================================================================
  typedef enum int {M_IDLE, M_WURQ, M_SUM, M_TX, M_RX, D_RX, D_DROP, D_TA, D_TX} ms_t;
  ms_t        q;
  bit         inwin, clr, ev, role_q;
  int         q_n, q_k, w_c, q_lowc;
  logic [7:0] q_mc, q_ckt, q_acc;
  bit         e_busy, e_done, e_tmo, e_uart, e_cks, e_wurq, e_msg;
  logic [7:0] e_mcks, e_mmc;
  logic [6:0] e_cnt;
  logic [2:0] e_why;
  // buffer write expected on this clock, host read data expected
  bit         w_pend, hr_pend, hw_pend;
  logic [7:0] w_a, w_d, hr_d, hw_a, hw_d;
  // coverage flags (one clock)
  bit f_wurq_m, f_wurq_d, f_wurq_lo, f_wurq_hi, f_wurq_ta, f_break, f_glitch, f_m_ok, f_m_tmo0, f_m_tmo_gap,
      f_m_uart, f_m_cks, f_m_ev, f_m_pdinv, f_d_ok, f_d_uart_mc, f_d_uart_pl, f_d_cks, f_d_type, f_d_gap,
      f_d_drop, f_d_reply, f_ta0, f_ta15, f_len0, f_len32, f_clamp, f_page_wrap, f_collision, f_hrd,
      f_start_busy, f_role;
  int  c_ty, c_ch, c_rw;

  function automatic int m_payload(input logic [7:0] mc);
    return n_pdo + (mc[7] ? 0 : n_o);
  endfunction

  task automatic d_report(input logic [7:0] mc, input logic [2:0] why);
    e_msg = 1; e_mmc = mc; e_why = why;
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q = M_IDLE; p_on = 0; e_ten = 0; e_txd = 1; p_done = 0; s_clk = 0; s_bits = 0; s_tick = 0;
      l1 = 1; l2 = 1; lp = 1; u_busy = 0; u_v = 0; u_pe = 0; u_fe = 0; u_m = 0; u_k = 0; u_d = 0; u_bits = 0;
      e_busy = 0; e_done = 0; e_tmo = 0; e_uart = 0; e_cks = 0; e_wurq = 0; e_msg = 0;
      e_mcks = 0; e_mmc = 0; e_cnt = 0; e_why = 0; q_lowc = 0; q_k = 0; q_n = 0; w_c = 0;
      q_mc = 0; q_ckt = 0; q_acc = 0; p_mc = 0; p_ckt = 0; w_pend = 0; hr_pend = 0; hw_pend = 0; role_q = 0;
    end else begin
      // host port: read data one clock later; write lands unless the core writes there
      hr_pend = host_rd; hr_d = ram[host_addr]; f_hrd = host_rd;
      // checks of the previous clock's writes happen in the assertions; new ones here
      w_pend = 0;
      e_done = 0; e_wurq = 0; e_msg = 0;
      f_wurq_m = 0; f_wurq_d = 0; f_wurq_lo = 0; f_wurq_hi = 0; f_wurq_ta = 0; f_break = 0; f_glitch = 0;
      f_m_ok = 0; f_m_tmo0 = 0; f_m_tmo_gap = 0; f_m_uart = 0; f_m_cks = 0; f_m_ev = 0; f_m_pdinv = 0;
      f_d_ok = 0; f_d_uart_mc = 0; f_d_uart_pl = 0; f_d_cks = 0; f_d_type = 0; f_d_gap = 0; f_d_drop = 0;
      f_d_reply = 0; f_ta0 = 0; f_ta15 = 0; f_len0 = 0; f_len32 = 0; f_clamp = 0; f_page_wrap = 0;
      f_collision = 0; f_start_busy = 0; c_ty = -1; f_role = 0;
      p_step();
      inwin = q == M_RX || (q == D_RX && q_k != 0) || q == D_TA || q == D_DROP;
      clr = u_busy || u_v || p_done || !inwin;
      ev = u_v || p_done;
      if (cfg_master != role_q) begin
        q = cfg_master ? M_IDLE : D_RX; q_k = 0; p_on = 0; e_ten = 0; e_txd = 1; e_busy = 0; f_role = 1;
      end else if (cfg_master) begin
        case (q)
          M_IDLE: begin
            if (m_wurq) begin
              q = M_WURQ; w_c = int'(cfg_wurq); e_ten = 1; e_txd = 0; e_busy = 1; f_wurq_m = 1;
            end else if (m_start) begin
              q = M_SUM; q_mc = m_mc; q_k = m_payload(m_mc); e_busy = 1;
              e_tmo = 0; e_uart = 0; e_cks = 0; e_mcks = 0; e_cnt = 0;
              f_len0 = n_pdo == 0 && n_pdi == 0; f_len32 = n_pdo == 32 && n_pdi == 32 && n_o == 32;
              f_clamp = cfg_pdout_len > 32 || cfg_pdin_len > 32 || cfg_od_len > 32;
            end
          end
          M_WURQ: begin
            if (w_c > 1) w_c--;
            else begin q = M_IDLE; e_ten = 0; e_txd = 1; e_busy = 0; e_done = 1; end
          end
          M_SUM: begin
            f_start_busy = m_start;
            if (q_k > 0) q_k--;
            else begin
              q_acc = 8'h52 ^ q_mc ^ {cfg_mtype, 6'd0};
              for (int j = 0; j < m_payload(q_mc); j++)
                q_acc ^= ram[j < n_pdo ? j : 32 + (j - n_pdo)];
              p_mc = q_mc; p_ckt = {cfg_mtype, csum6(q_acc)};
              q = M_TX; p_start(1, m_payload(q_mc) + 2);
            end
          end
          M_TX: begin
            f_start_busy = m_start;
            if (p_done) begin
              q = M_RX; q_k = 0; q_acc = 8'h52;
              q_n = (q_mc[7] ? n_o : 0) + n_pdi + 1;
            end
          end
          M_RX: begin
            f_start_busy = m_start;
            if (u_v) begin
              e_cnt++;
              if (u_bad) begin
                e_uart = 1; q = M_IDLE; e_busy = 0; e_done = 1; q_k = 0; f_m_uart = 1;
              end else if (q_k == q_n - 1) begin
                e_mcks = u_d;
                e_cks = csum6(q_acc ^ {u_d[7:6], 6'd0}) != u_d[5:0];
                q = M_IDLE; e_busy = 0; e_done = 1; q_k = 0;
                f_m_cks = e_cks; f_m_ok = !e_cks; f_m_ev = u_d[7]; f_m_pdinv = u_d[6];
                if (!e_cks) begin c_ty = cfg_mtype; c_ch = q_mc[6:5]; c_rw = q_mc[7]; end
              end else begin
                w_pend = 1; w_d = u_d;
                w_a = q_mc[7] && q_k < n_o ? 8'(96 + q_k) : 8'(64 + q_k - (q_mc[7] ? n_o : 0));
                q_acc ^= u_d; q_k++;
              end
            end else if (!u_busy && s_bits >= int'(cfg_resp_timeout)) begin
              f_m_tmo0 = q_k == 0; f_m_tmo_gap = q_k != 0;
              e_tmo = 1; q = M_IDLE; e_busy = 0; e_done = 1; q_k = 0;
            end
          end
          default: q = M_IDLE;
        endcase
      end else begin
        // ---------------------------- device ----------------------------
        if (q < D_RX) q = D_RX;
        if (l2 && q_lowc != 0 && q_lowc >= int'(cfg_wurq) - int'(cfg_wurq) / 16 &&
            q_lowc <= int'(cfg_wurq) + int'(cfg_wurq) / 16) begin
          e_wurq = 1; f_wurq_d = 1; f_wurq_ta = q == D_TA;
          f_wurq_lo = q_lowc == int'(cfg_wurq) - int'(cfg_wurq) / 16;
          f_wurq_hi = q_lowc == int'(cfg_wurq) + int'(cfg_wurq) / 16;
          q = D_RX; q_k = 0;
          if (p_on) begin p_on = 0; e_ten = 0; e_txd = 1; end
        end else case (q)
          D_RX: begin
            if (u_break) begin
              q_k = 0; f_break = 1;
            end else if (u_bad) begin
              f_d_uart_mc = q_k == 0; f_d_uart_pl = q_k != 0;
              d_report(q_k == 0 ? u_d : q_mc, 3'd1); q = D_DROP; q_k = 0;
            end else if (u_v) begin
             
              if (q_k == 0) begin
                q_mc = u_d; q_acc = 8'h52 ^ u_d; q_k = 1;
                q_n = 2 + n_pdo + (u_d[7] ? 0 : n_o);
              end else begin
                if (q_k == 1) begin q_ckt = u_d; q_acc ^= {u_d[7:6], 6'd0}; end
                else begin
                  q_acc ^= u_d; w_pend = 1; w_d = u_d;
                  w_a = q_k - 2 < n_pdo ? 8'(64 + q_k - 2) : 8'(96 + q_k - 2 - n_pdo);
                end
                q_k++;
                if (q_k == q_n) begin
                  q_k = 0;
                  if (q_ckt[7:6] != cfg_mtype) begin d_report(q_mc, 3'd3); f_d_type = 1; end
                  else if (csum6(q_acc) != q_ckt[5:0]) begin d_report(q_mc, 3'd2); f_d_cks = 1; end
                  else begin
                    d_report(q_mc, 3'd0); q = D_TA; f_d_ok = 1;
                    f_ta0 = cfg_ta == 0; f_ta15 = cfg_ta == 15;
                  end
                end
              end
            end else if (q_k != 0 && !u_busy && s_bits >= 16) begin
              d_report(q_mc, 3'd4); q_k = 0; f_d_gap = 1;
            end
          end
          D_DROP: begin
            if (!u_v && !u_busy && s_bits >= 16) begin q = D_RX; f_d_drop = 1; end
          end
          D_TA: begin
            if (s_bits >= int'(cfg_ta) && s_bits != 0) begin
              p_mc = q_mc; q = D_TX; f_d_reply = 1;
              f_page_wrap = q_mc[7] && q_mc[6:5] == 2'd1 && int'(q_mc[4:0]) + n_o > 32;
              p_start(0, (q_mc[7] ? n_o : 0) + n_pdi + 1);
            end
          end
          default: begin                                         // D_TX
            if (p_done) q = D_RX;
          end
        endcase
        q_lowc = (l2 || tx_en) ? 0 : q_lowc < 65535 ? q_lowc + 1 : 65535;
      end
      // silence, then the decoder and synchroniser
      s_bits = ev ? 0 : (s_tick && s_bits != 255) ? s_bits + 1 : s_bits;
      s_tick = !clr && s_clk + 1 >= cb;
      s_clk  = (clr || s_clk + 1 >= cb) ? 0 : s_clk + 1;
      u_step();
      role_q = cfg_master;
      // host write: lands unless the core writes the same address on this clock
      hw_pend = host_wr; hw_a = host_addr;
      hw_d = (w_pend && w_a == host_addr) ? w_d : host_wdata;
      f_collision = host_wr && w_pend && w_a == host_addr;
    end
  end

  // =========================================================================
  // assertions
  // =========================================================================
  `SVA_INV(a_tx_en, tx_en == e_ten)
  `SVA_IMP(a_txd, tx_en, txd == e_txd)
  `SVA_INV(a_m_busy, !cfg_master || m_busy == e_busy)
  `SVA_INV(a_m_done, m_done == e_done)
  `SVA_IMP(a_m_result, m_done, {m_err_timeout, m_err_uart, m_err_cks, m_cnt} == {e_tmo, e_uart, e_cks, e_cnt}
                                && m_cks == e_mcks)
  `SVA_INV(a_d_wurq, d_wurq == e_wurq)
  `SVA_INV(a_d_msg, d_msg == e_msg)
  `SVA_IMP(a_d_report, d_msg, d_msg_mc == e_mmc && d_msg_why == e_why)
  `SVA_IMP(a_core_write, w_pend, ram[w_a] == w_d)
  `SVA_IMP(a_host_write, hw_pend, ram[hw_a] == hw_d)
  `SVA_IMP(a_host_read, hr_pend, host_rdata == hr_d)

  // =========================================================================
  // functional coverage
  // =========================================================================
  `FC(m_wake_up_sent, f_wurq_m)
  `FC(d_wake_up_detected, f_wurq_d)
  `FC(d_wake_up_shortest, f_wurq_lo)
  `FC(d_wake_up_longest, f_wurq_hi)
  `FC(d_wake_up_during_ta, f_wurq_ta)
  `FC(d_break_octet_ignored, f_break)
  `FC(start_bit_glitch, f_glitch)
  `FC(m_exchange_ok, f_m_ok)
  `FC(m_no_reply_timeout, f_m_tmo0)
  `FC(m_timeout_in_reply, f_m_tmo_gap)
  `FC(m_reply_uart_error, f_m_uart)
  `FC(m_reply_checksum_error, f_m_cks)
  `FC(m_cks_event_flag, f_m_ev)
  `FC(m_cks_pd_invalid, f_m_pdinv)
  `FC(m_start_while_busy_ignored, f_start_busy)
  `FC(d_message_ok, f_d_ok)
  `FC(d_uart_error_first_octet, f_d_uart_mc)
  `FC(d_uart_error_later_octet, f_d_uart_pl)
  `FC(d_checksum_error, f_d_cks)
  `FC(d_mtype_error, f_d_type)
  `FC(d_gap_error, f_d_gap)
  `FC(d_drop_time_ended, f_d_drop)
  `FC(d_reply_sent, f_d_reply)
  `FC(d_ta_0_acts_as_1, f_ta0)
  `FC(d_ta_15, f_ta15)
  `FC(lengths_0, f_len0)
  `FC(lengths_32, f_len32)
  `FC(lengths_clamped, f_clamp)
  `FC(d_page_read_wraps, f_page_wrap)
  `FC(host_write_collision, f_collision)
  `FC(host_read, f_hrd)
  `FC(role_changed, f_role)
  `FC(bit_time_4, cfg_master && tx_en && cfg_bit == 16'd4)
  `FC(bit_time_65535, cfg_master && tx_en && cfg_bit == 16'hFFFF)
  `FC_RST(reset_while_replying, !cfg_master && tx_en ##1 !rst_n)

  covergroup cg_iol @(negedge clk);
    option.per_instance = 1;
    cp_ty: coverpoint c_ty iff (c_ty >= 0) { bins t[] = {[0:3]}; }
    cp_ch: coverpoint c_ch iff (c_ty >= 0) { bins process = {0}; bins page = {1}; bins diag = {2}; bins isdu = {3}; }
    cp_rw: coverpoint c_rw iff (c_ty >= 0) { bins wr = {0}; bins rd = {1}; }
    x_ch_rw: cross cp_ch, cp_rw;
  endgroup
  cg_iol u_cg_iol = new;
endmodule

bind IO_LINK_top IO_LINK_sva u_sva (.*);
