// SPDX-License-Identifier: Apache-2.0
// DigRF endpoint: concurrent SVA against an independent reference model,
// plus functional coverage.
//  * 8b/10b by table search: a symbol is the (k, byte) whose code for the
//    current running disparity matches; the code for the other disparity
//    is a disparity error, no match a code violation.
//  * Transmitter: symbol slots of 10 clocks from the burst start; in each
//    slot the model picks the symbol (sync, start of frame from its own
//    pending sources by priority, header, payload, filler, end of burst)
//    and the next 10 line bits must be its code. Sources: the control /
//    interrupt handshakes, the register read data one clock after reg_re,
//    the data host's dtx_valid / dtx_data in the payload slots.
//  * Receiver: own comma hunt and symbol decoder, frame parser and
//    outputs; the read timeout as a deadline.
// Every output is compared on every clock.
`include "cov_macros.svh"
module DigRF_sva (
  input logic       clk, rst_n, tx_p, rx_p,
  input logic [3:0] cfg_sync,
  input logic [7:0] cfg_hold, cfg_timeout,
  input logic       ctl_valid, ctl_ready, ctl_rd,
  input logic [7:0] ctl_addr, ctl_wdata,
  input logic       rsp_valid,
  input logic [7:0] rsp_data,
  input logic       rsp_timeout, reg_we, reg_re,
  input logic [7:0] reg_addr, reg_wdata, reg_rdata,
  input logic       int_valid, int_ready,
  input logic [4:0] int_vec,
  input logic       int_rx,
  input logic [4:0] int_rx_vec,
  input logic       dtx_valid, dtx_ready,
  input logic [7:0] dtx_data,
  input logic [2:0] dtx_size,
  input logic [1:0] dtx_chan,
  input logic       drx_valid,
  input logic [7:0] drx_data,
  input logic       drx_sof, drx_eof,
  input logic [1:0] drx_chan,
  input logic       drx_abort, tx_on, rx_locked, err_code, err_frame, tx_underrun
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- 8b/10b tables ----------------
  function automatic logic [11:0] c6(input int x);   // {RD-, RD+}
    case (x)
      0: return 12'o4730;  1: return 12'o3542;  2: return 12'o5522;  3: return 12'o6161;
      4: return 12'o6512;  5: return 12'o5151;  6: return 12'o3131;  7: return 12'o7007;
      8: return 12'o7106;  9: return 12'o4545;  10: return 12'o2525; 11: return 12'o6464;
      12: return 12'o1515; 13: return 12'o5454; 14: return 12'o3434; 15: return 12'o2750;
      16: return 12'o3344; 17: return 12'o4343; 18: return 12'o2323; 19: return 12'o6262;
      20: return 12'o1313; 21: return 12'o5252; 22: return 12'o3232; 23: return 12'o7205;
      24: return 12'o6314; 25: return 12'o4646; 26: return 12'o2626; 27: return 12'o6611;
      28: return 12'o1616; 29: return 12'o5621; 30: return 12'o3641; 31: return 12'o5324;
      default: return 12'o1760;                       // K28
    endcase
  endfunction
  function automatic logic [7:0] c4(input int y);    // {RD-, RD+}; 8 = A7, 9.. = K28.y
    case (y)
      0: return 8'hB4; 1: return 8'h99; 2: return 8'h55; 3: return 8'hC3; 4: return 8'hD2;
      5: return 8'hAA; 6: return 8'h66; 7: return 8'hE1; 8: return 8'h78;
      9: return 8'hB4; 10: return 8'h69; 11: return 8'hA5; 12: return 8'hC3; 13: return 8'hD2;
      14: return 8'h5A; 15: return 8'h96; default: return 8'h78;
    endcase
  endfunction
  function automatic int n1(input logic [5:0] v);
    n1 = 0;
    for (int i = 0; i < 6; i++) n1 += v[i];
  endfunction
  // {rd after, symbol}
  function automatic logic [10:0] code(input logic [7:0] d, input bit k, input bit rd);
    int x, y, y4;
    logic [11:0] p6;
    logic [7:0]  p4;
    logic [5:0]  s6;
    logic [3:0]  s4;
    x = d[4:0]; y = d[7:5];
    p6 = c6(k && x == 28 ? 32 : x);
    s6 = rd ? p6[5:0] : p6[11:6];
    if (n1(s6) != 3) rd = !rd;
    if (k && x == 28) y4 = 9 + y;
    else if (y == 7 && (k || (!rd && (x == 17 || x == 18 || x == 20)) || (rd && (x == 11 || x == 13 || x == 14)))) y4 = 8;
    else y4 = y;
    p4 = c4(y4);
    s4 = rd ? p4[3:0] : p4[7:4];
    if (n1({2'b0, s4}) != 2) rd = !rd;
    return {rd, s6, s4};
  endfunction
  // 0: ok, 1: disparity error, 2: code violation; {k, byte} and rd after
  function automatic int dec(input logic [9:0] s, input bit rd, output logic [8:0] sym, output bit rd_n);
    logic [10:0] c;
    dec = 2; sym = 0; rd_n = rd;
    for (int k = 0; k < 2; k++)
      for (int d = 0; d < 256; d++) begin
        if (k == 1 && !(d[4:0] == 28 || (d[7:5] == 7 && (d[4:0] == 23 || d[4:0] == 27 || d[4:0] == 29 || d[4:0] == 30))))
          continue;
        c = code(d, k, rd);
        if (c[9:0] == s) begin dec = 0; sym = {1'(k), 8'(d)}; rd_n = c[10]; return dec; end
        c = code(d, k, !rd);
        if (c[9:0] == s) dec = 1;
      end
  endfunction

  localparam logic [8:0] SOF = 9'h13C, FIL = 9'h1BC, EOB = 9'h1FD;

  // ---------------- transmitter model ----------------
  bit          t_on, t_eob, t_rd, t_data;
  int          t_cnt, t_sync, t_idle, t_pay, t_qn;
  logic [8:0]  t_q [0:2];               // symbols of the frame still to send
  logic [9:0]  t_bits;                  // code in flight, current bit in [9]
  bit          p_rsp, p_int, p_ctl, p_ctl_rd, out_rd, cap1, cap2;
  logic [4:0]  p_rtag, p_ivec, ctag, otag;
  logic [7:0]  p_rd, p_ca, p_cd;
  longint      dl, now;
  bit          m_under, m_tmo;
  // ---------------- receiver model ----------------
  bit          r_q, r_lock, r_rd, r_first;
  logic [9:0]  r_sh;
  int          r_ph, r_st, r_left;      // r_st: 0 between frames, 1 header, 2 payload
  logic [2:0]  r_lct;
  logic [4:0]  r_f;
  logic [7:0]  r_b0;
  bit          m_we, m_re, m_rv, m_int, m_dv, m_sof, m_eof, m_abort, m_ec, m_ef;
  logic [7:0]  m_addr, m_wd, m_rdat, m_dd;
  logic [4:0]  m_iv;
  logic [1:0]  m_ch;
  // coverage
  bit v_lct [0:4];
  bit v_size [0:5];
  bit v_sync0, v_sync15, v_hold0, v_hold_max, v_under, v_tmo, v_late, v_stale;
  bit v_prio_rsp_int, v_prio_int_ctl, v_prio_ctl_dat, v_disp, v_viol, v_viol_frame;
  bit v_bad_lct, v_bad_size, v_dat_idle, v_foreign_k, v_k_in_frame, v_abort_k, v_abort_code, v_abort_eob;
  bit v_eob_rx;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit c_fv;
  int c_ch, c_sz;

  // a slot: the clock in which the transmitter picks its next symbol
  wire slot = t_on ? (t_cnt == 0 && !t_eob) : (p_rsp || p_int || p_ctl || dtx_valid);
  wire exp_ready = t_on && slot && t_sync == 0 && t_qn == 0 && t_pay > 0 && t_data && dtx_valid;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_on = 0; t_eob = 0; t_rd = 0; t_data = 0; t_cnt = 0; t_sync = 0; t_idle = 0; t_pay = 0; t_qn = 0;
      t_bits = 0; p_rsp = 0; p_int = 0; p_ctl = 0; p_ctl_rd = 0; out_rd = 0; cap1 = 0; cap2 = 0;
      p_rtag = 0; p_ivec = 0; ctag = 0; otag = 0; p_rd = 0; p_ca = 0; p_cd = 0; dl = 0; now = 0;
      m_under = 0; m_tmo = 0;
      r_q = 0; r_lock = 0; r_rd = 0; r_first = 0; r_sh = 0; r_ph = 0; r_st = 0; r_left = 0;
      r_lct = 0; r_f = 0; r_b0 = 0;
      {m_we, m_re, m_rv, m_int, m_dv, m_sof, m_eof, m_abort, m_ec, m_ef} = '0;
      m_addr = 0; m_wd = 0; m_rdat = 0; m_dd = 0; m_iv = 0; m_ch = 0;
    end else begin : b_step
      bit          any, load, p_int0, p_ctl0, out0, rv0;
      logic [4:0]  otag0;
      logic [8:0]  s;
      logic [10:0] c;
      now++;
      // values before the clock
      p_int0 = p_int; p_ctl0 = p_ctl; out0 = out_rd; otag0 = otag; rv0 = m_rv;
      any = p_rsp || p_int || p_ctl || dtx_valid;

      // ---- transmitter
      m_under = 0; c_fv = 0;
      load = 0; s = FIL;
      if (!t_on) begin
        if (any) begin
          load = 1; t_on = 1; t_rd = 0; t_idle = 0; t_pay = 0; t_qn = 0; t_data = 0;
          t_sync = cfg_sync == 0 ? 0 : int'(cfg_sync) - 1;
          if (cfg_sync == 0) v_sync0 = 1;
          if (cfg_sync == 15) v_sync15 = 1;
        end
      end else if (t_cnt == 0) begin
        if (t_eob) begin t_on = 0; t_eob = 0; end
        else begin
          load = 1;
          if (t_sync > 0) t_sync--;
          else if (t_qn > 0) begin s = t_q[0]; t_q[0] = t_q[1]; t_q[1] = t_q[2]; t_qn--; end
          else if (t_pay > 0) begin
            t_pay--;
            if (t_data) begin
              s = {1'b0, dtx_valid ? dtx_data : 8'h00};
              if (!dtx_valid) begin m_under = 1; v_under = 1; end
            end
          end else if (any) begin
            s = SOF; t_idle = 0; t_data = 0;
            if (p_rsp) begin
              if (p_int) v_prio_rsp_int = 1;
              t_q[0] = {4'd3, p_rtag}; t_q[1] = {1'b0, p_rd}; t_qn = 2; p_rsp = 0; v_lct[3] = 1;
            end else if (p_int) begin
              if (p_ctl) v_prio_int_ctl = 1;
              t_q[0] = {4'd4, p_ivec}; t_qn = 1; p_int = 0; v_lct[4] = 1;
            end else if (p_ctl) begin
              if (dtx_valid) v_prio_ctl_dat = 1;
              t_q[0] = {1'b0, p_ctl_rd ? 3'd2 : 3'd1, ctag}; t_q[1] = {1'b0, p_ca}; t_q[2] = {1'b0, p_cd};
              t_qn = p_ctl_rd ? 2 : 3; p_ctl = 0;
              if (p_ctl_rd) begin out_rd = 1; otag = ctag; dl = now + longint'(cfg_timeout) * 16 + 1; v_lct[2] = 1; end
              else v_lct[1] = 1;
              ctag++;
            end else begin : b_dat
              int sz;
              sz = dtx_size > 5 ? 5 : int'(dtx_size);
              v_size[sz] = 1; v_lct[0] = 1;
              c_fv = 1; c_ch = dtx_chan; c_sz = sz;
              t_q[0] = {4'd0, dtx_chan, 3'(sz)}; t_qn = 1; t_pay = 8 << sz; t_data = 1;
            end
          end else if (t_idle >= int'(cfg_hold)) begin
            s = EOB; t_eob = 1;
            if (cfg_hold == 0) v_hold0 = 1;
            if (cfg_hold == 255) v_hold_max = 1;
          end else t_idle++;
        end
      end
      if (load) begin
        c = code(s[7:0], s[8], t_rd);
        t_rd = c[10]; t_bits = c[9:0]; t_cnt = 9;
      end else if (t_on) begin t_bits = {t_bits[8:0], 1'b0}; t_cnt--; end

      // ---- sources: handshakes of this clock, after the slot
      if (cap2) begin p_rsp = 1; p_rd = reg_rdata; end
      cap2 = cap1; cap1 = 0;
      if (int_valid && !p_int0) begin p_int = 1; p_ivec = int_vec; end
      if (ctl_valid && !p_ctl0 && !out0) begin p_ctl = 1; p_ctl_rd = ctl_rd; p_ca = ctl_addr; p_cd = ctl_wdata; end
      // read deadline
      m_tmo = 0;
      if (out0) begin
        if (rv0) out_rd = 0;
        else if (now >= dl) begin out_rd = 0; m_tmo = 1; v_tmo = 1; end
      end

      // ---- receiver
      {m_we, m_re, m_rv, m_int, m_dv, m_abort, m_ec, m_ef} = '0;
      if (!r_lock) begin
        if (r_sh == 10'b0011111010 || r_sh == 10'b1100000101) begin
          r_lock = 1; r_ph = 1; r_rd = !r_sh[9]; r_st = 0;
        end
      end else begin
        if (r_ph == 0) begin : b_rx
          logic [8:0] y;
          bit rn;
          int e;
          e = dec(r_sh, r_rd, y, rn);
          if (e != 0) begin
            m_ec = 1; r_lock = 0;
            if (e == 1) v_disp = 1; else v_viol = 1;
            if (r_st != 0) v_viol_frame = 1;
            if (r_st == 2 && r_lct == 0) begin m_abort = 1; v_abort_code = 1; end
          end else begin
            r_rd = rn;
            if (y[8]) begin
              if (r_st != 0) v_k_in_frame = 1;
              if (r_st != 0 || (y != FIL && y != SOF && y != EOB)) m_ef = 1;
              if (r_st == 0 && y != FIL && y != SOF && y != EOB) v_foreign_k = 1;
              if (r_st == 2 && r_lct == 0) begin
                m_abort = 1;
                if (y == EOB) v_abort_eob = 1; else v_abort_k = 1;
              end
              r_st = y == SOF ? 1 : 0;
              if (y == EOB) begin r_lock = 0; v_eob_rx = 1; end
            end else if (r_st == 0) begin m_ef = 1; v_dat_idle = 1; end
            else if (r_st == 1) begin
              r_lct = y[7:5]; r_f = y[4:0]; r_first = 1; r_st = 2;
              case (y[7:5])
                3'd0: begin
                  r_left = 8 << y[2:0];
                  if (y[2:0] > 5) begin m_ef = 1; r_st = 0; v_bad_size = 1; end
                end
                3'd1: r_left = 2;
                3'd2, 3'd3: r_left = 1;
                3'd4: begin m_int = 1; m_iv = y[4:0]; r_st = 0; end
                default: begin m_ef = 1; r_st = 0; v_bad_lct = 1; end
              endcase
            end else begin
              r_left--;
              if (r_left == 0) r_st = 0;
              case (r_lct)
                3'd0: begin m_dv = 1; m_dd = y[7:0]; m_sof = r_first; m_eof = r_left == 0; m_ch = r_f[4:3]; end
                3'd1: if (r_left == 0) begin m_we = 1; m_addr = r_b0; m_wd = y[7:0]; end
                3'd2: begin m_re = 1; m_addr = y[7:0]; p_rtag = r_f; cap1 = 1; end
                default: begin
                  if (out0 && r_f == otag0) begin m_rv = 1; m_rdat = y[7:0]; end
                  else begin
                    m_ef = 1;
                    if (out0) v_stale = 1; else v_late = 1;
                  end
                end
              endcase
              r_first = 0; r_b0 = y[7:0];
            end
          end
        end
        r_ph = r_ph == 9 ? 0 : r_ph + 1;
      end
      r_sh = {r_sh[8:0], r_q};
      r_q = rx_p;
    end
  end

  // ---------------- assertions ----------------
  `SVA_IMP(a_tx_bit, t_on, tx_p == t_bits[9])
  `SVA_INV(a_tx_on, tx_on == t_on)
  `SVA_IMP(a_tx_off, !t_on, !tx_p)
  `SVA_INV(a_dtx_ready, dtx_ready == exp_ready)
  `SVA_INV(a_underrun, tx_underrun == m_under)
  `SVA_INV(a_ctl_ready, ctl_ready == (!p_ctl && !out_rd))
  `SVA_INV(a_int_ready, int_ready == !p_int)
  `SVA_INV(a_timeout, rsp_timeout == m_tmo)
  `SVA_INV(a_locked, rx_locked == r_lock)
  `SVA_INV(a_err, err_code == m_ec && err_frame == m_ef)
  `SVA_INV(a_reg, reg_we == m_we && reg_re == m_re)
  `SVA_IMP(a_reg_data, m_we || m_re, reg_addr == m_addr && (!m_we || reg_wdata == m_wd))
  `SVA_INV(a_rsp, rsp_valid == m_rv)
  `SVA_IMP(a_rsp_data, m_rv, rsp_data == m_rdat)
  `SVA_INV(a_int, int_rx == m_int)
  `SVA_IMP(a_int_vec, m_int, int_rx_vec == m_iv)
  `SVA_INV(a_drx, drx_valid == m_dv && drx_abort == m_abort)
  `SVA_IMP(a_drx_data, m_dv, drx_data == m_dd && drx_sof == m_sof && drx_eof == m_eof && drx_chan == m_ch)
  `SVA_RST(a_rst, 1'b1, !tx_p && !tx_on && !rx_locked && ctl_ready && int_ready && !drx_valid && !reg_we
                        && !reg_re && !rsp_valid && !int_rx && !err_code && !err_frame)

  function automatic int dcls(input logic [7:0] v);
    return v == 8'h00 ? 0 : v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA) ? 2 : 3;
  endfunction
  // data frames by channel and size, payload / register / response bytes,
  // interrupt vectors, both ways
  covergroup cg_digrf @(negedge clk);
    option.per_instance = 1;
    cp_tch: coverpoint c_ch iff (rst_n && c_fv) { bins c[] = {[0:3]}; }
    cp_tsz: coverpoint c_sz iff (rst_n && c_fv) { bins s[] = {[0:5]}; }
    x_tx: cross cp_tch, cp_tsz;
    cp_tdata: coverpoint dcls(dtx_data) iff (rst_n && dtx_valid && dtx_ready)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rch: coverpoint drx_chan iff (rst_n && drx_valid && drx_sof) { bins c[] = {[0:3]}; }
    cp_rdata: coverpoint dcls(drx_data) iff (rst_n && drx_valid)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_regw: coverpoint dcls(reg_wdata) iff (rst_n && reg_we)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rsp: coverpoint dcls(rsp_data) iff (rst_n && rsp_valid)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_int: coverpoint int_rx_vec iff (rst_n && int_rx) { bins zero = {0}; bins max = {31}; bins other = {[1:30]}; }
  endgroup
  cg_digrf u_cg_digrf = new;

  // ---------------- functional coverage ----------------
  `FC(frame_data, v_lct[0])
  `FC(frame_ctrl_wr, v_lct[1])
  `FC(frame_ctrl_rd, v_lct[2])
  `FC(frame_ctrl_rsp, v_lct[3])
  `FC(frame_int, v_lct[4])
  `FC(data_size0, v_size[0])
  `FC(data_size1, v_size[1])
  `FC(data_size2, v_size[2])
  `FC(data_size3, v_size[3])
  `FC(data_size4, v_size[4])
  `FC(data_size5, v_size[5])
  `FC(sync_0, v_sync0)
  `FC(sync_15, v_sync15)
  `FC(hold_0, v_hold0)
  `FC(hold_255, v_hold_max)
  `FC(underrun, v_under)
  `FC(read_timeout, v_tmo)
  `FC(response_late, v_late)
  `FC(response_stale_tag, v_stale)
  `FC(prio_rsp_over_int, v_prio_rsp_int)
  `FC(prio_int_over_ctl, v_prio_int_ctl)
  `FC(prio_ctl_over_data, v_prio_ctl_dat)
  `FC(rx_disparity_error, v_disp)
  `FC(rx_code_violation, v_viol)
  `FC(rx_code_error_in_frame, v_viol_frame)
  `FC(rx_bad_lct, v_bad_lct)
  `FC(rx_bad_size, v_bad_size)
  `FC(rx_data_between_frames, v_dat_idle)
  `FC(rx_foreign_control_symbol, v_foreign_k)
  `FC(rx_control_symbol_in_frame, v_k_in_frame)
  `FC(rx_abort_control_symbol, v_abort_k)
  `FC(rx_abort_code_error, v_abort_code)
  `FC(rx_abort_end_of_burst, v_abort_eob)
  `FC(rx_end_of_burst, v_eob_rx)
  `FC(write_and_read_pending, p_ctl && p_rsp)
  `FC_RST(reset_in_burst, rst_n && tx_on ##1 !rst_n)
endmodule

bind DigRF_top DigRF_sva u_sva (.*);
