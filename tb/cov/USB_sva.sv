// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// USB FS device: a model fed only by the bus predicts the device's line
// drive on every clock. Received packets are collected as raw NRZI-decoded
// bits and judged as a whole at EOP (sync, unstuffing, PID check, CRC5 /
// CRC16); the device's endpoint / control-transfer state is modelled at
// transaction level and every response is built as a complete list of line
// symbols (SYNC, NRZI with stuffing, CRC16, EOP) replayed clock by clock.
`include "cov_macros.svh"
module USB_sva #(parameter int BIT_CLKS = 4) (
  input logic clk, rst_n, irq, tx_oe,
  input wire  dp, dm
);
  `COV_CLOCKING(clk, !rst_n)

  localparam int BC = BIT_CLKS, SP = BIT_CLKS / 2 - 1, TA = 4 * BIT_CLKS, ATO = 32 * BIT_CLKS;
  localparam int RSTC = 32 * BIT_CLKS;
  // control request in progress
  localparam int NONE = 0, DESC = 1, CFGGET = 2, ADDR = 3, CFGSET = 4, CNTSET = 5, STALL = 6, STS = 7;

  function automatic logic [4:0] crc5(input logic [10:0] v);
    logic [4:0] c = 5'h1F;
    for (int i = 0; i < 11; i++) c = (c[0] ^ v[i]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
    return ~c;
  endfunction
  function automatic logic [15:0] crc16(input logic [15:0] c, input logic [7:0] d);
    for (int k = 0; k < 8; k++) c = (c[0] ^ d[k]) ? ((c >> 1) ^ 16'hA001) : (c >> 1);
    return c;
  endfunction
  function automatic logic [7:0] desc(input int i);
    logic [7:0] d [18] = '{8'h12, 8'h01, 8'h00, 8'h02, 8'h00, 8'h00, 8'h00, 8'h08, 8'h09,
                           8'h12, 8'h01, 8'h00, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h01};
    return d[i];
  endfunction
  function automatic logic [7:0] conf(input int i);
    logic [7:0] d [25] = '{8'h09, 8'h02, 8'h19, 8'h00, 8'h01, 8'h01, 8'h00, 8'h80, 8'h32,
                           8'h09, 8'h04, 8'h00, 8'h00, 8'h01, 8'hFF, 8'h00, 8'h00, 8'h00,
                           8'h07, 8'h05, 8'h81, 8'h03, 8'h04, 8'h00, 8'h0A};
    return d[i];
  endfunction

  // ---------------- receiver
  logic [1:0]  ld;
  int          bt, rstate, nb;      // rstate 0 idle, 1 collecting, 2 wait J
  logic        prev, bits [400];
  int          se0;
  logic        m_brst;
  // decoded packet (valid at the clock after EOP, like the DUT's rx_done)
  logic        p_done, p_tok_ok, p_dat_ok;
  logic [3:0]  p_pid;
  logic [10:0] p_tok;
  logic [7:0]  p_buf [8];
  int          p_plen;
  // ---------------- device
  int          cs, rq, ack_t, d_len, d_off, tk, tn, toff;
  logic [6:0]  addr, n_addr;
  logic        cfg, n_cfg, exp_data, exp_setup, pstall, t0, t1, to, expect_ack, m_irq, dsel;
  logic [31:0] cnt, n_cnt;
  // ---------------- transmitter
  logic        m_oe, tx_go, tx_go_d, oe_q;
  logic [1:0]  syms [700];
  int          nsym, si, wait_c, busy;   // busy: 0 idle, 1 turnaround, 2 driving
  logic        tx_done_q;
  logic [1:0]  m_line;
  // coverage events
  logic v_desc_multi, v_desc_short, v_desc_zlp, v_addr, v_cfg1, v_cfg0, v_cfgget, v_cnt,
        v_stall_rq, v_stall_out, v_stall_ep, v_nak, v_ep1, v_ack_to, v_nak_retry, v_dup,
        v_bad_tok, v_bad_dat, v_stuff, v_bad_pid, v_bad_sync, v_trunc, v_other_addr,
        v_long_data, v_setup_short, v_brst, v_stuff_tx, v_sof, v_wack_other, v_stuff_eop,
        v_conf_multi, v_conf_full, v_sts_dev, v_sts_if, v_sts_ep0, v_sts_ep1;

  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  logic        c_tv, c_rv, c_qv, c_dv, c_av;
  logic [3:0]  c_tpid, c_rpid, c_dpid;
  logic [3:0]  c_ep;
  int          c_q;
  logic        c_dbad, c_a0;
  // build the line symbols of a packet: SYNC + bytes, NRZI, stuffing, EOP
  task automatic build(input logic [7:0] b [], input int n);
    logic lvl = 1'b1;   // J
    int   ones = 0;
    logic bit_;
    nsym = 0;
    for (int i = 0; i < n + 1; i++)
      for (int k = 0; k < 8; k++) begin
        bit_ = (i == 0) ? (k == 7) : b[i-1][k];
        if (!bit_) lvl = !lvl;
        syms[nsym++] = lvl ? 2'b10 : 2'b01;
        if (i > 0) begin
          ones = bit_ ? ones + 1 : 0;
          if (ones == 6) begin
            lvl = !lvl; syms[nsym++] = lvl ? 2'b10 : 2'b01; ones = 0; v_stuff_tx = 1;
            v_stuff_eop = i == n && k == 7;
          end
        end
      end
    syms[nsym++] = 2'b00; syms[nsym++] = 2'b00; syms[nsym++] = 2'b10;
  endtask

  task automatic respond(input int kind, input logic [3:0] pid, input int n, input logic ack);
    logic [7:0] b [] = new[11];
    logic [15:0] c = 16'hFFFF;
    b[0] = {~pid, pid};
    for (int i = 0; i < n; i++) begin
      case (kind)
        2: b[1+i] = dsel ? conf(toff + i) : desc(toff + i);
        3: b[1+i] = {7'd0, cfg};
        5: b[1+i] = 8'h00;
        default: b[1+i] = cnt[8*i +: 8];
      endcase
      c = crc16(c, b[1+i]);
    end
    b[1+n] = ~c[7:0]; b[2+n] = ~c[15:8];
    build(b, kind == 0 ? 1 : n + 3);
    tk = kind; tn = n; expect_ack = ack; tx_go = 1; cs = 1;
    c_rv = 1; c_rpid = pid;
  endtask

  // judge a collected packet (nb raw bits)
  task automatic judge();
    logic [7:0]  d [64];
    int          nd = 0, ones = 0, j;
    logic        serr = 0;
    logic [7:0]  sy = 0, pidb;
    logic [15:0] c = 16'hFFFF;
    p_done = 0;
    if (nb < 8) begin v_trunc = 1; return; end            // SE0 inside SYNC
    for (int k = 0; k < 8; k++) sy[k] = bits[k];
    p_done = 1; p_pid = 0; p_tok_ok = 0;
    if (sy != 8'h80) begin v_bad_sync = 1; return; end
    // unstuff the rest into data bits (as many as the receiver consumes)
    for (j = 8; j < nb; j++) begin
      if (ones == 6) begin ones = 0; if (bits[j]) serr = 1; continue; end
      d[nd / 8][nd % 8] = bits[j];
      nd++;
      ones = bits[j] ? ones + 1 : 0;
      if (nd == 8 && d[0][7:4] == ~d[0][3:0] && !(d[0][3:0] inside {4'h1, 4'h9, 4'h5, 4'hD,
                                                                      4'h3, 4'hB})) break;
      if (nd == 24 && d[0][3:0] inside {4'h1, 4'h9, 4'h5, 4'hD}) break;
      if (nd == 8 && d[0][7:4] != ~d[0][3:0]) break;
      if (nd == 8 * 64) break;
    end
    v_stuff = serr;
    if (nd < 8) return;
    pidb = d[0];
    if (pidb[7:4] != ~pidb[3:0]) begin v_bad_pid = 1; return; end
    p_pid = pidb[3:0];
    if (p_pid inside {4'h1, 4'h9, 4'h5, 4'hD}) begin
      if (nd < 24) return;
      p_tok = {d[2][2:0], d[1]};
      p_tok_ok = !serr && d[2][7:3] == crc5(p_tok);
      v_bad_tok = !p_tok_ok;
      v_sof = p_pid == 4'h5;
    end else if (p_pid inside {4'h3, 4'hB}) begin
      int nby = nd / 8 - 1;
      for (int i = 0; i < nby - 2; i++) c = crc16(c, d[1+i]);
      p_dat_ok = !serr && nby >= 2 && d[nby-1] == ~c[7:0] && d[nby] == ~c[15:8];
      p_plen = (nby > 31 ? 31 : nby) - 2;
      if (p_plen < 0) p_plen = 0;
      for (int i = 0; i < 8; i++) if (i < nby) p_buf[i] = d[1+i];
      v_bad_dat = !p_dat_ok;
      v_long_data = nby > 31;
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    logic [1:0]  l;
    logic        edge_, samp, rx_en, ack_ok, tgl_bad;
    logic [7:0]  bm, rqb;
    logic [15:0] val, idx, len;
    if (!rst_n) begin
      ld = 2'b10; bt = 0; rstate = 0; nb = 0; prev = 1; se0 = 0; m_brst = 0;
      p_done = 0; p_tok_ok = 0; p_dat_ok = 0; p_pid = 0; p_tok = 0; p_plen = 0;
      for (int i = 0; i < 8; i++) p_buf[i] = 0;
      cs = 0; rq = NONE; ack_t = 0; d_len = 0; d_off = 0; tk = 0; tn = 0; toff = 0;
      addr = 0; n_addr = 0; cfg = 0; n_cfg = 0; exp_data = 0; exp_setup = 0; pstall = 0;
      t0 = 0; t1 = 0; to = 0; expect_ack = 0; m_irq = 0; cnt = 0; n_cnt = 0; dsel = 0;
      m_oe = 0; tx_go = 0; tx_go_d = 0; oe_q = 0; nsym = 0; si = 0; wait_c = 0; busy = 0; tx_done_q = 0;
      m_line = 2'b10;
      {c_tv, c_rv, c_qv, c_dv, c_av, c_dbad, c_a0} = '0; c_tpid = 0; c_rpid = 0; c_dpid = 0; c_ep = 0; c_q = 0;
    end else begin
      {c_tv, c_rv, c_qv, c_dv, c_av} = '0;
      {v_desc_multi, v_desc_short, v_desc_zlp, v_addr, v_cfg1, v_cfg0, v_cfgget, v_cnt,
       v_stall_rq, v_stall_out, v_stall_ep, v_nak, v_ep1, v_ack_to, v_nak_retry, v_dup,
       v_bad_tok, v_bad_dat, v_stuff, v_bad_pid, v_bad_sync, v_trunc, v_other_addr,
       v_long_data, v_setup_short, v_brst, v_stuff_tx, v_sof, v_wack_other, v_stuff_eop,
       v_conf_multi, v_conf_full, v_sts_dev, v_sts_if, v_sts_ep0, v_sts_ep1} = '0;
      l = {dp, dm};
      rx_en = busy == 0;
      oe_q  = m_oe;
      // ================= device control (acts on the packet judged last clock)
      tx_go = 0;
      if (m_brst) begin
        cs = 0; rq = NONE; addr = 0; cfg = 0; exp_data = 0; t0 = 0; t1 = 0; to = 0;
        v_brst = 1;
      end else case (cs)
        0: if (p_done) begin
          case (p_pid)
            4'h9: begin
              exp_data = 0;
              if (!p_tok_ok) m_irq = 1;
              else if (p_tok[6:0] == addr) begin
                m_irq = 0;
                c_tv = 1; c_tpid = p_pid; c_ep = p_tok[10:7]; c_av = 1; c_a0 = addr == 0;
                if (p_tok[10:7] == 0) begin
                  case (rq)
                    DESC: begin
                      toff = d_off;
                      respond(2, t0 ? 4'hB : 4'h3, (d_len - d_off > 8) ? 8 : d_len - d_off, 1);
                      v_desc_zlp = d_len == d_off; v_desc_short = d_len - d_off inside {[1:7]};
                    end
                    CFGGET: begin
                      respond(3, t0 ? 4'hB : 4'h3, d_len - d_off, 1); v_cfgget = 1;
                    end
                    STS: respond(5, t0 ? 4'hB : 4'h3, d_len - d_off, 1);
                    ADDR, CFGSET, CNTSET: respond(1, t0 ? 4'hB : 4'h3, 0, 1);
                    default: begin respond(0, 4'hE, 0, 0); v_stall_rq = 1; end
                  endcase
                end else if (p_tok[10:7] == 1) begin
                  if (cfg) begin respond(4, t1 ? 4'hB : 4'h3, 4, 1); v_ep1 = 1; end
                  else begin respond(0, 4'hA, 0, 0); v_nak = 1; end
                end else begin respond(0, 4'hE, 0, 0); v_stall_ep = 1; end
              end else v_other_addr = 1;
            end
            4'h1, 4'hD: begin
              if (!p_tok_ok) m_irq = 1;
              else if (p_tok[6:0] == addr) begin
                m_irq = 0; exp_data = 1; exp_setup = p_pid == 4'hD;
                c_tv = 1; c_tpid = p_pid; c_ep = p_tok[10:7]; c_av = 1; c_a0 = addr == 0;
                pstall = p_tok[10:7] != 0 || (p_pid == 4'h1 && rq == STALL);
              end else v_other_addr = 1;
            end
            4'h3, 4'hB: if (exp_data) begin
              exp_data = 0;
              if (!p_dat_ok) m_irq = 1;
              else if (pstall) begin
                respond(0, 4'hE, 0, 0); v_stall_out = 1;
              end else begin
                respond(0, 4'h2, 0, 0);
                tgl_bad = (p_pid == 4'hB) != (exp_setup ? 1'b0 : to);
                v_dup = tgl_bad;
                c_dv = 1; c_dpid = p_pid; c_dbad = tgl_bad;
                if (!tgl_bad) begin
                  to = exp_setup ? 1'b1 : !to;
                  if (exp_setup) begin
                    bm = p_buf[0]; rqb = p_buf[1]; val = {p_buf[3], p_buf[2]};
                    idx = {p_buf[5], p_buf[4]}; len = {p_buf[7], p_buf[6]};
                    t0 = 1; d_off = 0;
                    n_addr = val[6:0]; n_cfg = val[0]; n_cnt = {idx, val};
                    dsel = val[9];
                    if (val[9]) d_len = len > 25 ? 25 : len[4:0];
                    else        d_len = len > 18 ? 18 : len[4:0];
                    if (p_plen != 8) begin rq = STALL; v_setup_short = 1; end
                    else if (bm == 8'h80 && rqb == 8'h06 && (val == 16'h0100 || val == 16'h0200)) rq = DESC;
                    else if (rqb == 8'h00 && val == 0 && len == 2 && bm == 8'h80 && idx == 0) begin
                      rq = STS; v_sts_dev = 1;
                    end else if (rqb == 8'h00 && val == 0 && len == 2 && bm == 8'h81 && idx == 0 && cfg) begin
                      rq = STS; v_sts_if = 1;
                    end else if (rqb == 8'h00 && val == 0 && len == 2 && bm == 8'h82 &&
                                 (idx == 16'h0000 || idx == 16'h0080)) begin
                      rq = STS; v_sts_ep0 = 1;
                    end else if (rqb == 8'h00 && val == 0 && len == 2 && bm == 8'h82 && idx == 16'h0081 && cfg) begin
                      rq = STS; v_sts_ep1 = 1;
                    end
                    else if (bm == 8'h80 && rqb == 8'h08 && val == 0 && idx == 0 && len == 1)
                      rq = CFGGET;
                    else if (bm == 8'h00 && rqb == 8'h05 && val < 128 && idx == 0 && len == 0)
                      rq = ADDR;
                    else if (bm == 8'h00 && rqb == 8'h09 && val < 2 && idx == 0 && len == 0)
                      rq = CFGSET;
                    else if (bm == 8'h40 && rqb == 8'h01 && len == 0) rq = CNTSET;
                    else rq = STALL;
                    if (bm == 8'h80 && rqb == 8'h08) d_len = 1;
                    if (rqb == 8'h00) d_len = 2;
                    c_qv = 1; c_q = rq;
                  end else if (rq == DESC || rq == CFGGET || rq == STS) rq = NONE;
                end
              end
            end
            default: ;
          endcase
        end
        1: if (tx_done_q) begin cs = expect_ack ? 2 : 0; ack_t = ATO; end
        default: begin
          if (p_done) begin
            cs = 0;
            v_wack_other = p_pid != 4'h2;
            if (p_pid == 4'h2) begin
              case (tk)
                4: begin t1 = !t1; cnt++; end
                1: begin
                  t0 = !t0;
                  if (rq == ADDR)   begin addr = n_addr; v_addr = 1; end
                  if (rq == CFGSET) begin cfg = n_cfg; v_cfg1 = n_cfg; v_cfg0 = !n_cfg; end
                  if (rq == CNTSET) begin cnt = n_cnt; v_cnt = 1; end
                  rq = NONE;
                end
                default: begin
                  t0 = !t0; d_off += tn; v_desc_multi = tk == 2 && !dsel && d_off > 8;
                  v_conf_multi = tk == 2 && dsel && d_off > 8; v_conf_full = tk == 2 && dsel && d_off == 25;
                end
              endcase
            end else v_nak_retry = p_pid == 4'hA;
          end else if (ack_t == 0) begin cs = 0; v_ack_to = 1; end
          else ack_t--;
        end
      endcase
      // ================= transmitter (start is seen one clock after the decision)
      tx_done_q = 0;
      case (busy)
        0: ;
        1: if (wait_c == TA - 1) begin busy = 2; m_oe = 1; si = 0; m_line = syms[0]; wait_c = 1; end
           else wait_c++;
        default: begin
          if (wait_c == BC) begin si++; wait_c = 0; end
          if (si == nsym) begin m_oe = 0; busy = 0; tx_done_q = 1; m_line = 2'b10; end
          else begin m_line = syms[si]; wait_c++; end
        end
      endcase
      if (tx_go_d) begin busy = 1; wait_c = 0; end
      tx_go_d = tx_go;
      // ================= receiver
      p_done = 0;
      m_brst = 0;
      if (l != 2'b00 || oe_q) se0 = 0;
      else if (se0 != RSTC) begin se0++; m_brst = se0 == RSTC; end
      edge_ = (l[1] ^ l[0]) && (ld[1] ^ ld[0]) && l != ld;
      samp  = bt == SP && (l[1] ^ l[0]);
      if (!rx_en) rstate = 0;
      else case (rstate)
        0: if (edge_ && l == 2'b01) begin rstate = 1; nb = 0; prev = 1; end
        1: if (l == 2'b00) begin judge(); rstate = 2; end
           else if (samp) begin
             if (nb < 400) bits[nb] = (dp == prev);
             nb++; prev = dp;
           end
        default: if (l == 2'b10) rstate = 0;
      endcase
      bt = (edge_ || bt == BC - 1) ? 0 : bt + 1;
      ld = l;
    end
  end

  `SVA_RST(a_reset_outputs, !rst_n, !tx_oe && !irq)
  `SVA_INV(a_tx_oe, tx_oe == m_oe)
  `SVA_IMP(a_line, m_oe, {dp, dm} == m_line)
  `SVA_INV(a_irq, irq == m_irq)

  // token PID x endpoint (to this device), response PID, setup request
  // decoded, DATA0 / DATA1 x toggle in step or duplicate, device address
  // zero or assigned
  function automatic int tokk(input logic [3:0] pid, input logic [3:0] ep);
    return (pid == 4'h9 ? 0 : (pid == 4'h1 ? 3 : 6)) + (ep == 0 ? 0 : (ep == 1 ? 1 : 2));
  endfunction
  covergroup cg_usb @(negedge clk);
    option.per_instance = 1;
    cp_tok: coverpoint tokk(c_tpid, c_ep) iff (rst_n && c_tv)
      { bins in_ep0 = {0}; bins in_ep1 = {1}; bins in_epx = {2}; bins out_ep0 = {3}; bins out_ep1 = {4};
        bins out_epx = {5}; bins setup_ep0 = {6}; bins setup_epx = {7, 8}; }
    cp_rsp: coverpoint c_rpid iff (rst_n && c_rv)
      { bins ack = {4'h2}; bins nak = {4'hA}; bins stall = {4'hE}; bins data0 = {4'h3}; bins data1 = {4'hB}; }
    cp_req: coverpoint c_q iff (rst_n && c_qv)
      { bins get_desc = {DESC}; bins get_cfg = {CFGGET}; bins set_addr = {ADDR}; bins set_cfg = {CFGSET};
        bins vendor = {CNTSET}; bins stall = {STALL}; bins get_status = {STS}; }
    cp_data: coverpoint {c_dpid == 4'hB, c_dbad} iff (rst_n && c_dv)
      { bins data0_ok = {2'b00}; bins data0_dup = {2'b01}; bins data1_ok = {2'b10}; bins data1_dup = {2'b11}; }
    cp_addr: coverpoint c_a0 iff (rst_n && c_av) { bins default_addr = {1}; bins assigned = {0}; }
  endgroup
  cg_usb u_cg_usb = new;

  `FC(get_descriptor_multi_packet, v_desc_multi)
  `FC(get_descriptor_short_packet, v_desc_short)
  `FC(get_descriptor_zlp, v_desc_zlp)
  `FC(set_address, v_addr)
  `FC(set_configuration_1, v_cfg1)
  `FC(set_configuration_0, v_cfg0)
  `FC(get_configuration, v_cfgget)
  `FC(get_config_descriptor_multi_packet, v_conf_multi)
  `FC(get_config_descriptor_complete, v_conf_full)
  `FC(get_status_device, v_sts_dev)
  `FC(get_status_interface, v_sts_if)
  `FC(get_status_ep0, v_sts_ep0)
  `FC(get_status_ep1, v_sts_ep1)
  `FC(vendor_counter_preset, v_cnt)
  `FC(ep0_protocol_stall, v_stall_rq)
  `FC(out_stalled, v_stall_out)
  `FC(in_bad_endpoint_stalled, v_stall_ep)
  `FC(ep1_nak_unconfigured, v_nak)
  `FC(ep1_counter_sent, v_ep1)
  `FC(ack_timeout, v_ack_to)
  `FC(host_nak_retry, v_nak_retry)
  `FC(duplicate_data_acked, v_dup)
  `FC(bad_token_crc, v_bad_tok)
  `FC(bad_data_crc, v_bad_dat)
  `FC(rx_stuff_error, v_stuff)
  `FC(rx_bad_pid, v_bad_pid)
  `FC(rx_bad_sync, v_bad_sync)
  `FC(rx_se0_in_sync, v_trunc)
  `FC(token_other_address, v_other_addr)
  `FC(rx_long_data_packet, v_long_data)
  `FC(setup_short_payload, v_setup_short)
  `FC(bus_reset, v_brst)
  `FC(tx_bit_stuffing, v_stuff_tx)
  `FC(tx_stuff_bit_before_eop, v_stuff_eop)
  `FC(sof_ignored, v_sof)
  `FC(wait_ack_got_other_packet, v_wack_other)
  `FC_RST(reset_while_transmitting, rst_n && tx_oe ##1 !rst_n)
endmodule

bind USB_top USB_sva #(.BIT_CLKS(BIT_CLKS)) u_sva (.clk, .rst_n, .irq, .tx_oe, .dp, .dm);
