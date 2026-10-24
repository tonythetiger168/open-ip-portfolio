// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// UniPro data link layer: a cycle-level model fed only by the pins predicts
// tx_bit, cpu_rdata and irq on every clock. The receive side is a symbol
// sampler, a de-framer (COF / ESC_DL, CRC residue) and a frame judge; the
// send side picks the next frame (resend, FIFO'd ACK / NAC / PACP answer,
// CPU PACP request, TC1, TC0), expands it into its escaped symbol list
// (COF, header, payload, CRC, COF) and plays it through a symbol serializer.
`include "cov_macros.svh"
module UniPro_sva #(parameter int ACK_WAIT = 600) (
  input logic        clk, rst_n, rx_bit, tx_bit, cpu_we, cpu_re, irq,
  input logic [2:0]  cpu_addr,
  input logic [31:0] cpu_wdata, cpu_rdata
);
  `COV_CLOCKING(clk, !rst_n)

  localparam logic [7:0] COF = 8'h7E, ESC = 8'h9D;

  function automatic logic [15:0] crc16(input logic [15:0] c, input logic [7:0] d);
    c = c ^ {d, 8'h00};
    for (int i = 0; i < 8; i++) c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
    crc16 = c;
  endfunction

  // ------------------------------------------------------- symbol sampler
  int         rs, rbc;
  logic [7:0] rsr, bb;
  logic       bv, x_frm;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin rs <= 0; rbc <= 0; rsr <= 0; bb <= 0; bv <= 0; x_frm <= 0; end
    else begin
      bv <= 0; x_frm <= 0;
      if (rs == 0) begin if (!rx_bit) begin rs <= 1; rbc <= 0; end end
      else if (rs == 1) begin
        rsr[rbc] <= rx_bit;
        if (rbc == 7) rs <= 2; else rbc <= rbc + 1;
      end else begin
        rs <= 0;
        if (rx_bit) begin bb <= rsr; bv <= 1; end else x_frm <= 1;
      end
    end

  // ------------------------------------------------------------ de-framer
  logic [7:0]  fb [0:18];
  int          fl, fl_l;
  logic [15:0] fc, fc_l;
  bit          fe, fd, fend;
  bit          v_esc_rx, v_long, v_esc_esc;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin fl <= 0; fc <= 16'hFFFF; fe <= 0; fd <= 0; fend <= 0; fl_l <= 0; fc_l <= 0; end
    else begin : df
      logic [7:0] d;
      fend <= 0;
      {v_esc_rx, v_long, v_esc_esc} = '0;
      if (bv) begin
        d = fe ? bb ^ 8'h20 : bb;
        if (bb == COF) begin
          if (fl != 0 && !fd) begin fend <= 1; fl_l <= fl; fc_l <= fc; end
          v_long = fd;
          fl <= 0; fc <= 16'hFFFF; fe <= 0; fd <= 0;
        end else if (bb == ESC && !fe) fe <= 1;
        else begin
          fe <= 0;
          v_esc_rx = fe; v_esc_esc = fe && bb == ESC;
          if (fl == 32) fd <= 1;
          else begin
            if (fl < 19) fb[fl] <= d;
            fl <= fl + 1; fc <= crc16(fc, d);
          end
        end
      end
    end

  // ----------------------------------------------------------- frame judge
  logic [7:0]  attr [0:15];
  logic [7:0]  cf_c [0:3], cf_a [0:3], cf_b [0:3];   // control FIFO {cmd, arg1, arg2}
  int          cf_n, cf_w, cf_r;
  logic [7:0]  mb [0:31];
  int          m_n, m_w, m_r;
  logic [3:0]  xseq;
  logic [7:0]  p_val;
  bit          p_vld, p_cnf;
  bit          g_ack, g_nac;
  logic [3:0]  g_seq;
  bit          x_crc, x_mof, x_cof;
  bit          cpop;                                 // control FIFO pop (from the sender)
  bit v_crc, v_len, v_big, v_ctl_len, v_get, v_set, v_getrsp, v_setcnf, v_ack_in, v_nac_in,
      v_unk, v_up, v_other, v_dup, v_oos, v_full, v_cf_ovf, v_len0, v_len16, v_mpop_empty,
      v_cf_full_pop;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      cf_n <= 0; cf_w <= 0; cf_r <= 0; m_n <= 0; m_w <= 0; m_r <= 0; xseq <= 0;
      p_val <= 0; p_vld <= 0; p_cnf <= 0; g_ack <= 0; g_nac <= 0; g_seq <= 0;
      x_crc <= 0; x_mof <= 0; x_cof <= 0;
      for (int i = 0; i < 16; i++) attr[i] <= 0;
    end else begin : judge
      bit ok, ctl, push, up;
      logic [7:0] pc, pa, pb;
      int add, len;
      {v_crc, v_len, v_big, v_ctl_len, v_get, v_set, v_getrsp, v_setcnf, v_ack_in, v_nac_in, v_unk,
       v_up, v_other, v_dup, v_oos, v_full, v_cf_ovf, v_len0, v_len16, v_mpop_empty,
       v_cf_full_pop} = '0;
      g_ack <= 0; g_nac <= 0; x_crc <= 0; x_mof <= 0; x_cof <= 0;
      push = 0; add = 0; pc = 0; pa = 0; pb = 0;
      ctl = fb[0][3:0] == 4'hF;
      len = int'(fb[2]);
      ok  = fend && fc_l == 0 && fl_l >= 5 && len == fl_l - 5 && len <= 16 && (!ctl || len == 3);
      if (fend && !ok) begin
        x_crc <= 1;
        v_crc = fc_l != 0;
        v_len = fc_l == 0 && (fl_l < 5 || len != fl_l - 5);
        v_big = fc_l == 0 && fl_l >= 5 && len == fl_l - 5 && len > 16;
        v_ctl_len = fc_l == 0 && fl_l >= 5 && len == fl_l - 5 && len <= 16 && ctl;
      end
      if (ok && ctl)
        case (fb[3])
          8'd0: begin push = 1; pc = 8'd2; pa = fb[4]; pb = attr[fb[4][3:0]]; v_get = 1; end
          8'd1: begin attr[fb[4][3:0]] <= fb[5]; push = 1; pc = 8'd3; pa = fb[4]; v_set = 1; end
          8'd2: begin p_val <= fb[5]; p_vld <= 1; v_getrsp = 1; end
          8'd3: begin p_cnf <= 1; v_setcnf = 1; end
          8'd4: begin g_ack <= 1; g_seq <= fb[4][3:0]; v_ack_in = 1; end
          8'd5: begin g_nac <= 1; v_nac_in = 1; end
          default: v_unk = 1;
        endcase
      if (ok && !ctl) begin
        push = 1;
        up = fb[0][3:0] == 0;
        if (fb[1][3:0] == xseq) begin
          if (up && m_n + len > 32) begin
            pc = 8'd5; pa = {4'h0, xseq}; x_mof <= 1; v_full = 1;
          end else begin
            pc = 8'd4; pa = {4'h0, xseq}; xseq <= xseq + 1;
            if (up) add = len;
            v_up = up; v_other = !up; v_len0 = len == 0; v_len16 = up && len == 16;
          end
        end else if (fb[1][3:0] == xseq - 4'd1) begin pc = 8'd4; pa = {4'h0, fb[1][3:0]}; v_dup = 1; end
        else begin pc = 8'd5; pa = {4'h0, xseq}; v_oos = 1; end
      end
      for (int i = 0; i < 16; i++) if (i < add) mb[(m_w + i) % 32] <= fb[3 + i];
      m_w <= (m_w + add) % 32;
      if (push && cf_n == 4) begin push = 0; x_cof <= 1; v_cf_ovf = 1; end
      v_cf_full_pop = push && cf_n == 3 && cpop;
      if (push) begin cf_c[cf_w] <= pc; cf_a[cf_w] <= pa; cf_b[cf_w] <= pb; cf_w <= (cf_w + 1) % 4; end
      if (cpop) cf_r <= (cf_r + 1) % 4;
      cf_n <= cf_n + int'(push) - int'(cpop);
      v_mpop_empty = cpu_re && cpu_addr == 4 && m_n == 0;
      if (cpu_re && cpu_addr == 4 && m_n != 0) begin m_r <= (m_r + 1) % 32; m_n <= m_n + add - 1; end
      else m_n <= m_n + add;
      if (cpu_re && cpu_addr == 6) begin p_vld <= 0; p_cnf <= 0; end
    end

  // --------------------------------------------------------------- sender
  logic [35:0] tq [0:1][0:7];
  int          tq_n [0:1], tq_w [0:1], tq_r [0:1];
  bit          tpop [0:1];
  logic [3:0]  cport;
  bit          rq_pend, rq_set;
  logic [3:0]  rq_idx;
  logic [7:0]  rq_val;
  bit          o, rl, oq;                     // outstanding, relaunch pending, its queue
  logic [35:0] od;                            // its {cport, payload}
  logic [3:0]  os, tseq;
  int          tries, tmr;
  bit          x_rex, x_qof;
  // frame in flight: escaped symbol list
  logic [7:0]  sl [0:24];
  int          sn, si;
  bit          act, a_ctl;
  // symbol serializer
  bit          sv, sbusy;
  logic [7:0]  sbyte, ssh;
  int          scnt;
  logic        m_tx;
  bit v_rex, v_qof0, v_qof1, v_nac_resend, v_tmo_resend, v_ack_wrong, v_ack_late, v_tc1_first,
      v_ctl_while_out, v_pacp_replace, v_esc_tx, v_resend_ok, v_push_on_pop, v_pacp_behind_resend;

  wire s_ready = !sbusy && !sv;

  function automatic void add_sym(inout logic [7:0] l [0:24], inout int n, input logic [7:0] b,
                                  input bit raw = 0);
    if (!raw && (b == COF || b == ESC)) begin l[n] = ESC; l[n + 1] = b ^ 8'h20; n += 2; end
    else begin l[n] = b; n += 1; end
  endfunction

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      sv <= 0; sbusy <= 0; sbyte <= 0; ssh <= 0; scnt <= 0; m_tx <= 1;
    end else if (!sbusy) begin
      m_tx <= !sv;
      if (sv) begin sbusy <= 1; ssh <= sbyte; scnt <= 0; end
    end else begin
      m_tx <= scnt == 8 ? 1'b1 : ssh[0];
      ssh <= ssh >> 1;
      if (scnt == 8) sbusy <= 0; else scnt <= scnt + 1;
    end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int t = 0; t < 2; t++) begin tq_n[t] <= 0; tq_w[t] <= 0; tq_r[t] <= 0; tpop[t] <= 0; end
      cport <= 0; rq_pend <= 0; rq_set <= 0; rq_idx <= 0; rq_val <= 0;
      o <= 0; rl <= 0; oq <= 0; od <= 0; os <= 0; tseq <= 0; tries <= 0; tmr <= 0;
      x_rex <= 0; x_qof <= 0; sn <= 0; si <= 0; act <= 0; a_ctl <= 0; cpop <= 0; sv <= 0;
    end else begin : snd
      bit push [0:1];
      logic [7:0] c [0:6];
      int nc, n;
      logic [15:0] crc;
      logic [7:0] l [0:24];
      {v_rex, v_qof0, v_qof1, v_nac_resend, v_tmo_resend, v_ack_wrong, v_ack_late, v_tc1_first,
       v_ctl_while_out, v_pacp_replace, v_esc_tx, v_resend_ok, v_push_on_pop, v_pacp_behind_resend} = '0;
      sv <= 0; cpop <= 0; x_rex <= 0; x_qof <= 0;
      for (int t = 0; t < 2; t++) tpop[t] <= 0;
      // cpu writes
      for (int t = 0; t < 2; t++) push[t] = cpu_we && cpu_addr == 3'(t) && (tq_n[t] < 8 || tpop[t]);
      for (int t = 0; t < 2; t++) begin
        if (push[t]) begin tq[t][tq_w[t]] <= {cport, cpu_wdata}; tq_w[t] <= (tq_w[t] + 1) % 8; end
        v_push_on_pop |= push[t] && tq_n[t] == 8;
        if (tpop[t]) tq_r[t] <= (tq_r[t] + 1) % 8;
        tq_n[t] <= tq_n[t] + int'(push[t]) - int'(tpop[t]);
      end
      if (cpu_we && cpu_addr <= 1 && !push[cpu_addr[0]]) begin
        x_qof <= 1; v_qof0 = cpu_addr == 0; v_qof1 = cpu_addr == 1;
      end
      if (cpu_we && (cpu_addr == 2 || cpu_addr == 3)) begin
        v_pacp_replace = rq_pend;
        rq_pend <= 1; rq_set <= cpu_addr == 2; rq_idx <= cpu_wdata[3:0];
        rq_val <= cpu_addr == 2 ? cpu_wdata[15:8] : 8'h00;
      end
      if (cpu_we && cpu_addr == 4) cport <= cpu_wdata[3:0];

      // ACK / NAC / timeout
      v_ack_wrong = o && g_ack && g_seq != os;
      v_ack_late  = o && g_ack && g_seq == os && act && !a_ctl;
      if (o && g_ack && g_seq == os) begin
        o <= 0; rl <= 0; tries <= 0; tseq <= tseq + 1; tpop[oq] <= 1; v_resend_ok = tries != 0;
      end else if (o && !rl && !(act && !a_ctl)) begin
        if (g_nac || tmr == ACK_WAIT - 1) begin
          tmr <= 0;
          if (tries != 3) begin
            tries <= tries + 1; rl <= 1; v_nac_resend = g_nac; v_tmo_resend = !g_nac;
          end else begin
            o <= 0; tries <= 0; tseq <= tseq + 1; x_rex <= 1; tpop[oq] <= 1; v_rex = 1;
          end
        end else tmr <= tmr + 1;
      end

      // play the frame in flight
      if (act && s_ready) begin
        sv <= 1; sbyte <= sl[si];
        v_esc_tx = sl[si] == ESC;
        si <= si + 1;
        if (si + 1 == sn) act <= 0;
      end
      // pick the next frame
      nc = 0;
      if (!act) begin
        if (rl) begin
          rl <= 0; nc = 7; v_pacp_behind_resend = rq_pend;
          c[0] = {oq, 3'b000, od[35:32]}; c[1] = {4'h0, os}; c[2] = 8'd4;
          for (int i = 0; i < 4; i++) c[3 + i] = od[31 - 8*i -: 8];
        end else if (cf_n != 0) begin
          cpop <= 1; nc = 6;
          c[0] = 8'h0F; c[1] = 0; c[2] = 8'd3; c[3] = cf_c[cf_r]; c[4] = cf_a[cf_r]; c[5] = cf_b[cf_r];
          v_ctl_while_out = o;
        end else if (rq_pend) begin
          nc = 6;
          if (!(cpu_we && (cpu_addr == 2 || cpu_addr == 3))) rq_pend <= 0;
          c[0] = 8'h0F; c[1] = 0; c[2] = 8'd3; c[3] = {7'd0, rq_set}; c[4] = {4'h0, rq_idx}; c[5] = rq_val;
        end else if (!o && !tpop[0] && !tpop[1] && (tq_n[1] != 0 || tq_n[0] != 0)) begin
          logic t;
          t = tq_n[1] != 0;
          v_tc1_first = t && tq_n[0] != 0;
          o <= 1; tmr <= 0; oq <= t; od <= tq[t][tq_r[t]]; os <= tseq; nc = 7;
          c[0] = {t, 3'b000, tq[t][tq_r[t]][35:32]}; c[1] = {4'h0, tseq}; c[2] = 8'd4;
          for (int i = 0; i < 4; i++) c[3 + i] = tq[t][tq_r[t]][31 - 8*i -: 8];
        end
        if (nc != 0) begin
          n = 0; crc = 16'hFFFF;
          add_sym(l, n, COF, 1);
          for (int i = 0; i < nc; i++) begin add_sym(l, n, c[i]); crc = crc16(crc, c[i]); end
          add_sym(l, n, crc[15:8]); add_sym(l, n, crc[7:0]);
          add_sym(l, n, COF, 1);
          sl <= l; sn <= n; si <= 0; act <= 1; a_ctl <= nc == 6;
        end
      end
    end

  // the frame launch above decides on cycle k and starts symbol playing on
  // k + 1, like the RTL's F_IDLE -> F_COF1 step

  wire [31:0] m_status = {p_cnf, p_vld, act, rq_pend, o, 2'(tries), 3'(cf_n), xseq, tseq,
                          6'(m_n), 4'(tq_n[1]), 4'(tq_n[0])};
  wire [31:0] m_rdata  = cpu_addr == 4 ? {24'd0, mb[m_r]} :
                         cpu_addr == 5 ? m_status :
                         cpu_addr == 6 ? {22'd0, p_cnf, p_vld, p_val} : 32'd0;
  wire        m_irq    = x_crc | x_frm | x_mof | x_cof | x_rex | x_qof;

  // covergroup: CPU queue writes (TC, CPort, data), acknowledged sends
  // (sequence, attempt), good received frames (kind, length, sequence,
  // payload), control commands, message buffer reads
  function automatic int dcls(input logic [31:0] v, input int w);
    logic [31:0] m;
    m = w == 32 ? 32'hFFFF_FFFF : (32'd1 << w) - 1;
    v = v & m;
    dcls = v == 0 ? 0 : v == m ? 1 : (v == (32'h5555_5555 & m) || v == (32'hAAAA_AAAA & m)) ? 2 : 3;
  endfunction
  int c_qt, c_qp, c_qd, c_as, c_at, c_rk, c_rl, c_rs, c_rd, c_rc, c_md;
  always @(posedge clk) begin : cgs
    bit ok;
    c_qt = -1; c_as = -1; c_rk = -1; c_rc = -1; c_md = -1;
    if (rst_n && cpu_we && cpu_addr <= 1) begin c_qt = cpu_addr[0]; c_qp = cport; c_qd = dcls(cpu_wdata, 32); end
    if (rst_n && o && g_ack && g_seq == os) begin c_as = os; c_at = tries; end
    ok = fend && fc_l == 0 && fl_l >= 5 && int'(fb[2]) == fl_l - 5 && int'(fb[2]) <= 16;
    if (rst_n && ok && fb[0][3:0] != 4'hF && fb[1][3:0] == xseq) begin
      c_rk = fb[0][3:0] == 0 ? 0 : 1; c_rl = int'(fb[2]); c_rs = xseq;
      c_rd = int'(fb[2]) == 0 ? 4 : dcls(32'(fb[3]), 8);
    end
    if (rst_n && ok && fb[0][3:0] == 4'hF && fb[2] == 3) c_rc = fb[3] > 5 ? 6 : int'(fb[3]);
    if (rst_n && cpu_re && cpu_addr == 4 && m_n != 0) c_md = dcls(32'(mb[m_r]), 8);
  end
  covergroup cg_unipro @(negedge clk);
    cp_qtc: coverpoint c_qt iff (c_qt >= 0) { bins tc[] = {[0:1]}; }
    cp_qport: coverpoint c_qp iff (c_qt >= 0) { bins p[] = {[0:14]}; }
    cp_qdata: coverpoint c_qd iff (c_qt >= 0) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    x_q: cross cp_qtc, cp_qdata;
    cp_aseq: coverpoint c_as iff (c_as >= 0) { bins s[] = {[0:15]}; }
    cp_atry: coverpoint c_at iff (c_as >= 0) { bins t[] = {[0:3]}; }
    cp_rkind: coverpoint c_rk iff (c_rk >= 0) { bins cport0 = {0}; bins other = {1}; }
    cp_rlen: coverpoint c_rl iff (c_rk >= 0) { bins empty = {0}; bins one = {1}; bins mid = {[2:15]}; bins full = {16}; }
    x_r: cross cp_rkind, cp_rlen;
    cp_rseq: coverpoint c_rs iff (c_rk >= 0) { bins s[] = {[0:15]}; }
    cp_rdata: coverpoint c_rd iff (c_rk >= 0) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; bins none = {4}; }
    cp_rcmd: coverpoint c_rc iff (c_rc >= 0) { bins get = {0}; bins set = {1}; bins get_rsp = {2}; bins set_cnf = {3};
                                               bins ack = {4}; bins nac = {5}; bins unknown = {6}; }
    cp_mdata: coverpoint c_md iff (c_md >= 0) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_unipro u_cg_unipro = new();

  `SVA_RST(a_reset_outputs, !rst_n, tx_bit && !irq)
  `SVA_INV(a_tx_bit, tx_bit == m_tx)
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_INV(a_cpu_rdata, cpu_addr == 4 && m_n == 0 || cpu_rdata == m_rdata)
  `SVA_IMP(a_mbuf_data, cpu_addr == 4 && m_n != 0, cpu_rdata == m_rdata)

  `FC(rx_escaped_byte, v_esc_rx)
  `FC(rx_escaped_esc, v_esc_esc)
  `FC(rx_long_frame_dropped, v_long)
  `FC(rx_framing_error, x_frm)
  `FC(rx_crc_error, v_crc)
  `FC(rx_len_mismatch, v_len)
  `FC(rx_len_over_16, v_big)
  `FC(rx_control_len_not_3, v_ctl_len)
  `FC(rx_pacp_get, v_get)
  `FC(rx_pacp_set, v_set)
  `FC(rx_get_response, v_getrsp)
  `FC(rx_set_confirm, v_setcnf)
  `FC(rx_ack, v_ack_in)
  `FC(rx_nac, v_nac_in)
  `FC(rx_unknown_command, v_unk)
  `FC(rx_cport0_uplink, v_up)
  `FC(rx_uplink_16_bytes, v_len16)
  `FC(rx_other_cport, v_other)
  `FC(rx_empty_payload, v_len0)
  `FC(rx_duplicate, v_dup)
  `FC(rx_out_of_sequence, v_oos)
  `FC(rx_buffer_full_nac, v_full)
  `FC(control_fifo_overflow, v_cf_ovf)
  `FC(control_fifo_full, cf_n == 4)
  `FC(mbuf_read_when_empty, v_mpop_empty)
  `FC(tx_queue0_overflow, v_qof0)
  `FC(tx_queue1_overflow, v_qof1)
  `FC(tx_push_while_full_pop, v_push_on_pop)
  `FC(tx_tc1_before_tc0, v_tc1_first)
  `FC(tx_escape, v_esc_tx)
  `FC(tx_resend_after_nac, v_nac_resend)
  `FC(tx_resend_after_timeout, v_tmo_resend)
  `FC(tx_resend_acked, v_resend_ok)
  `FC(tx_resend_budget_exhausted, v_rex)
  `FC(tx_ack_wrong_seq, v_ack_wrong)
  `FC(tx_control_frame_while_outstanding, v_ctl_while_out)
  `FC(cpu_pacp_request_replaced, v_pacp_replace)
  `FC(cpu_pacp_request_waits_behind_resend, v_pacp_behind_resend)
  `FC_RST(reset_while_sending, !tx_bit ##1 !rst_n)
endmodule

bind UniPro_top UniPro_sva #(.ACK_WAIT(ACK_WAIT)) u_sva (.*);
