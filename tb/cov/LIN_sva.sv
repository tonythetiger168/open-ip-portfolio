// SPDX-License-Identifier: Apache-2.0
// LIN 2.2A node: concurrent SVA against an independent pin-level reference
// model, plus functional coverage.
//  * Time-stamp model instead of counters and state encodings: a clock
//    counter `now`; the sync byte is checked from the time of each falling
//    edge, the byte receiver samples bit k at start + bt/2 + k*bt, the
//    transmitter drives bit j of a pre-built serial stream (header: 13
//    dominant, delimiter, 0x55, PID; response: data bytes and checksum) for
//    clocks start+1+j*B .. start+(j+1)*B, reading it back at mid-bit.
//  * Response timeout from the time the PID completed; a published
//    response starts half a bit after the PID stop-bit sample at the earliest.
// Every output is compared on every clock.
`include "cov_macros.svh"
module LIN_sva (
  input logic        clk, rst_n, rxd, txd,
  input logic [15:0] cfg_bit,
  input logic        cfg_autobaud,
  input logic        hdr_valid, hdr_ready,
  input logic [5:0]  hdr_id,
  input logic        pid_valid,
  input logic [5:0]  pid_id,
  input logic        rsp_ready, rsp_valid, rsp_pub,
  input logic [2:0]  rsp_len,
  input logic        rsp_enh,
  input logic [63:0] rsp_data,
  input logic        tx_done, rx_valid,
  input logic [5:0]  rx_id,
  input logic [2:0]  rx_len,
  input logic [63:0] rx_data,
  input logic        err_bit, err_sync, err_parity, err_frame, err_chk, err_timeout,
  input logic [15:0] bit_time
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int P_IDLE = 0, P_BRK = 1, P_SYN = 2, P_PID = 3, P_RSP = 4, P_RX = 5, P_TX = 6;

  function automatic logic [7:0] prot(input logic [5:0] id);
    logic p0, p1;
    p0 = ^{id[0], id[1], id[2], id[4]};
    p1 = !(^{id[1], id[3], id[4], id[5]});
    prot = {p1, p0, id};
  endfunction

  // ---------------- model state ----------------
  logic        q1, q2, q3;            // synchroniser: q2 = sampled bus, q3 = previous
  longint      now, drun;             // clock count; dominant run before this clock
  int          ph;
  int          bt;                    // bit time of the frame
  // sync byte
  int          nedge;
  longint      t_ref, t_e1;           // last edge (or delimiter start), first edge
  // byte receiver
  bit          rb;
  longint      rbs;                   // byte start (time of the start-bit edge)
  int          rbt, rk;               // its bit time, next sample index
  logic [7:0]  rbyte;
  // response
  logic [7:0]  pidm;
  int          len;                   // data bytes - 1
  int          idx;                   // bytes received
  logic [63:0] dat;
  longint      t_pid;                 // PID complete
  logic [7:0]  seed;                  // checksum seed: PID (enhanced) or 0
  bit          pend;                  // publish decided, transmitter not started yet
  // transmitter
  bit          tb;                    // sending
  bit          thdr;
  longint      t0, t_hdr_end;
  int          tB, tn;                // bit time, stream length in bits
  bit          stream [0:99];
  bit          rs_stream [0:99];      // response stream built at the decision
  int          rs_n;
  bit          md;                    // model txd
  // registered outputs
  bit          m_pidv, m_txd_done, m_rxv;
  logic [5:0]  m_pid, m_rxid;
  logic [2:0]  m_rxlen;
  logic [63:0] m_rxdat;
  bit  [5:0]   m_err;                 // {bit, sync, parity, frame, chk, timeout}
  int          m_bt;
  // coverage events
  bit v_ignored, v_late_dec, v_classic_forced, v_enh, v_glitch_pid, v_glitch_rx, v_ab_diff, v_ab_sat, v_abandoned;
  bit v_es_short, v_es_missing, v_es_delim, v_es_bit7, v_es_stop;
  bit v_eb_brk, v_eb_del, v_eb_hdr_byte, v_eb_rsp, v_cmd_pub;
  bit v_ef_pid, v_ef_rx;

  wire fall_m = q3 && !q2;
  wire hdr_ok_m = (ph == P_IDLE || ph == P_RSP) && !tb;

  function automatic longint smp_time(input longint s, input int b, input int k);
    smp_time = s + longint'(b / 2) + longint'(k) * longint'(b);
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q1 = 1; q2 = 1; q3 = 1; now = 0; drun = 0; ph = P_IDLE; bt = 0;
      nedge = 0; t_ref = 0; t_e1 = 0; rb = 0; rbs = 0; rbt = 0; rk = 0; rbyte = 0;
      pidm = 0; len = 0; idx = 0; dat = 0; t_pid = 0; seed = 0; pend = 0;
      tb = 0; thdr = 0; t0 = 0; t_hdr_end = -10; tB = 0; tn = 0; rs_n = 0; md = 1;
      m_pidv = 0; m_txd_done = 0; m_rxv = 0; m_pid = 0; m_rxid = 0; m_rxlen = 0; m_rxdat = 0;
      m_err = 0; m_bt = 0;
    end else begin
      bit     smp, brk_now, start_rx, rspv_c, rb0, pend0;
      int     k, nph;
      longint gap;
      logic [7:0] b;
      {v_ignored, v_late_dec, v_classic_forced, v_enh, v_glitch_pid, v_glitch_rx, v_ab_diff, v_ab_sat, v_abandoned} = '0;
      {v_es_short, v_es_missing, v_es_delim, v_es_bit7, v_es_stop} = '0;
      {v_eb_brk, v_eb_del, v_eb_hdr_byte, v_eb_rsp, v_cmd_pub} = '0;
      {v_ef_pid, v_ef_rx} = '0;
      m_pidv = 0; m_txd_done = 0; m_rxv = 0; m_err = 0;
      brk_now = !q2 && drun + 1 == 11 * longint'(cfg_bit);
      nph = ph;

      // ---- receiver sample this clock
      rb0 = rb; pend0 = pend;
      smp = rb && now == smp_time(rbs, rbt, rk);
      k = rk;
      if (smp) begin
        if (k >= 1 && k <= 8) rbyte = {q2, rbyte[7:1]};
        rk++;
        if ((k == 0 && q2) || k == 9) rb = 0;
        if (k == 0 && q2) begin
          if (ph == P_PID) v_glitch_pid = 1;
          if (ph == P_RX) v_glitch_rx = 1;
        end
      end
      b = rbyte;

      // ---- frame
      start_rx = 0;
      rspv_c = 0;
      case (ph)
        P_BRK: if (q2) begin nph = P_SYN; nedge = 0; t_ref = now; end
        P_SYN: begin
          gap = now - t_ref - 1;             // clocks since the reference, exclusive
          if (rb0) begin
            if (smp && k == 8 && q2) begin m_err[4] = 1; nph = P_IDLE; v_es_bit7 = 1; end
            if (smp && k == 9) begin
              if (!q2) begin m_err[4] = 1; nph = P_IDLE; v_es_stop = 1; end
              else nph = P_PID;
            end
          end else if (fall_m) begin
            if (nedge != 0 && gap < longint'(cfg_bit) + longint'(cfg_bit / 2)) begin
              m_err[4] = 1; nph = P_IDLE; v_es_short = 1;
            end else if (nedge == 0) t_e1 = now;
            else if (nedge == 4) begin
              bt = cfg_autobaud ? (now - t_e1 + 4 >= 8 * 65536 ? 65535 : int'((now - t_e1 + 4) / 8)) : int'(cfg_bit);
              v_ab_diff = bt != int'(cfg_bit);
              v_ab_sat = cfg_autobaud && now - t_e1 + 4 >= 8 * 65536;
              rb = 1; rbt = bt; rk = 8; rbs = now - 8 * longint'(bt);
            end
            nedge++;
            t_ref = now;
          end else if (nedge != 0 ? gap == 2 * longint'(cfg_bit) + longint'(cfg_bit / 2)
                                  : gap == 14 * longint'(cfg_bit)) begin
            m_err[4] = 1; nph = P_IDLE;
            if (nedge != 0) v_es_missing = 1; else v_es_delim = 1;
          end
        end
        P_PID: begin
          if (smp && k == 9) begin
            if (!q2) begin m_err[2] = 1; nph = P_IDLE; v_ef_pid = 1; end
            else if (prot(b[5:0]) != b) begin m_err[3] = 1; nph = P_IDLE; end
            else begin
              pidm = b; m_pidv = 1; m_pid = b[5:0]; nph = P_RSP; t_pid = now;
            end
          end else if (!rb0 && fall_m) start_rx = 1;
        end
        P_RSP: begin
          if (rsp_valid) begin
            rspv_c = 1;
            len = int'(rsp_len); idx = 0;
            seed = (rsp_enh && pidm[5:2] != 4'hF) ? pidm : 8'h00;
            v_enh = rsp_enh && pidm[5:2] != 4'hF;
            v_classic_forced = rsp_enh && pidm[5:2] == 4'hF;
            v_late_dec = now - t_pid > 2 * longint'(bt);
            if (rsp_pub) begin
              int s;
              logic [7:0] byt;
              dat = rsp_data; nph = P_TX;
              s = int'(seed);
              rs_n = 0;
              for (int i = 0; i <= len + 1; i++) begin
                if (i <= len) begin
                  byt = rsp_data[8*i +: 8];
                  s = s + int'(byt); if (s > 255) s = s - 255;
                end else byt = ~8'(s);
                rs_stream[rs_n] = 0; rs_n++;
                for (int j = 0; j < 8; j++) begin rs_stream[rs_n] = byt[j]; rs_n++; end
                rs_stream[rs_n] = 1; rs_n++;
              end
            end else begin
              dat = '0; nph = P_RX;
              if (!rb0 && fall_m) start_rx = 1;
            end
          end else if (fall_m) begin nph = P_IDLE; v_ignored = 1; end
          else if ((now - t_pid - 1) / longint'(bt) == 126) begin nph = P_IDLE; v_abandoned = 1; end
        end
        P_RX: begin
          if (smp && k == 9) begin
            if (!q2) begin m_err[2] = 1; nph = P_IDLE; v_ef_rx = 1; end
            else if (idx == len + 1) begin
              int s;
              s = int'(seed);
              for (int i = 0; i <= len; i++) begin s = s + int'(dat[8*i +: 8]); if (s > 255) s = s - 255; end
              if (b == ~8'(s)) begin
                m_rxv = 1; m_rxid = pidm[5:0]; m_rxlen = 3'(len); m_rxdat = dat;
              end else m_err[1] = 1;
              nph = P_IDLE;
            end else begin
              dat[8*idx +: 8] = b; idx++;
            end
          end else begin
            if ((now - t_pid - 1) / longint'(bt) == longint'(14 * (len + 2))) begin
              m_err[0] = 1; nph = P_IDLE;
            end
            if (!rb0 && fall_m) start_rx = 1;
          end
        end
        P_TX: if (!pend0 && !tb) nph = P_IDLE;
        default: ;
      endcase
      if (start_rx) begin rb = 1; rbs = now; rbt = bt; rk = 0; end
      if (brk_now) begin
        nph = P_BRK; rb = 0;
      end

      // ---- transmitter
      if (!tb) begin
        md = 1;
        if (hdr_valid && hdr_ok_m) begin
          logic [7:0] pb;
          tb = 1; thdr = 1; t0 = now; tB = int'(cfg_bit); tn = 0;
          for (int i = 0; i < 13; i++) begin stream[tn] = 0; tn++; end
          stream[tn] = 1; tn++;
          for (int y = 0; y < 2; y++) begin
            pb = y == 0 ? 8'h55 : prot(hdr_id);
            stream[tn] = 0; tn++;
            for (int j = 0; j < 8; j++) begin stream[tn] = pb[j]; tn++; end
            stream[tn] = 1; tn++;
          end
          md = 0;
        end else if (pend0 && now - t_pid >= longint'(bt / 2) + 2) begin
          tb = 1; thdr = 0; t0 = now; tB = bt; tn = rs_n;
          for (int i = 0; i < rs_n; i++) stream[i] = rs_stream[i];
          pend = 0; md = 0;
          v_cmd_pub = now - t_hdr_end <= longint'(bt);   // right after our own header
        end
      end else begin
        longint o;
        int     j;
        o = now - t0 - 1;
        j = int'(o / longint'(tB));
        if (o % longint'(tB) == longint'(tB / 2) && q2 != stream[j]) begin
          m_err[5] = 1; tb = 0; md = 1;
          if (thdr && j < 13) v_eb_brk = 1;
          else if (thdr && j == 13) v_eb_del = 1;
          else if (thdr) v_eb_hdr_byte = 1;
          else v_eb_rsp = 1;
        end else if (o + 1 == longint'(tn) * longint'(tB)) begin
          tb = 0; md = 1;
          if (!thdr) m_txd_done = 1; else t_hdr_end = now;
        end else md = stream[int'((o + 1) / longint'(tB))];
      end
      // decision sets, a break clears, the transmitter start takes it
      if (rspv_c && rsp_pub) pend = 1;
      if (brk_now) pend = 0;
      if (pend0 && tb && !thdr && t0 == now) pend = 0;
      ph = nph;
      m_bt = bt;

      drun = q2 ? 0 : drun + 1;
      q3 = q2; q2 = q1; q1 = rxd;
      now++;
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_values, !rst_n, txd && hdr_ready && !rsp_ready && !pid_valid && !tx_done
                                   && !rx_valid && bit_time == 0
                                   && {err_bit, err_sync, err_parity, err_frame, err_chk, err_timeout} == 0)
  `SVA_INV(a_txd_model, txd == md)
  `SVA_INV(a_hdr_ready_model, hdr_ready == hdr_ok_m)
  `SVA_INV(a_rsp_ready_model, rsp_ready == (ph == P_RSP))
  `SVA_INV(a_pid_model, pid_valid == m_pidv)
  `SVA_IMP(a_pid_id_model, pid_valid, pid_id == m_pid)
  `SVA_INV(a_tx_done_model, tx_done == m_txd_done)
  `SVA_INV(a_rx_valid_model, rx_valid == m_rxv)
  `SVA_IMP(a_rx_frame_model, rx_valid, rx_id == m_rxid && rx_len == m_rxlen && rx_data == m_rxdat)
  `SVA_INV(a_errors_model, {err_bit, err_sync, err_parity, err_frame, err_chk, err_timeout} == m_err)
  `SVA_INV(a_bit_time_model, int'(bit_time) == m_bt)

  // ---------------- functional coverage ----------------
  logic       dec_q, dec_pub;
  logic [2:0] dec_len;
  always_ff @(posedge clk) begin
    dec_q <= rst_n && rsp_ready && rsp_valid; dec_pub <= rsp_pub; dec_len <= rsp_len;
  end
  covergroup cg_lin @(posedge clk);
    option.per_instance = 1;
    cp_pid: coverpoint pid_id iff (rst_n && pid_valid);
    cp_rx_len: coverpoint rx_len iff (rst_n && rx_valid);
    cp_pub_len: coverpoint dec_len iff (rst_n && dec_q && dec_pub);
    cp_sub_len: coverpoint dec_len iff (rst_n && dec_q && !dec_pub);
  endgroup
  cg_lin u_cg_lin = new;

  `FC(header_sent, hdr_valid && hdr_ready)
  `FC(response_sent, tx_done)
  `FC(response_received, rx_valid)
  `FC(commander_publishes, v_cmd_pub)
  `FC(frame_ignored, v_ignored)
  `FC(frame_abandoned_undecided, v_abandoned)
  `FC(late_decision, v_late_dec)
  `FC(enhanced_checksum, v_enh)
  `FC(classic_forced_for_id_60_63, v_classic_forced)
  `FC(autobaud_adjusted, v_ab_diff)
  `FC(autobaud_saturated, v_ab_sat)
  `FC(glitch_at_pid_start, v_glitch_pid)
  `FC(glitch_at_data_start, v_glitch_rx)
  `FC(sync_interval_short, v_es_short)
  `FC(sync_edge_missing, v_es_missing)
  `FC(sync_delimiter_too_long, v_es_delim)
  `FC(sync_bit7_recessive, v_es_bit7)
  `FC(sync_stop_dominant, v_es_stop)
  `FC(parity_error, err_parity)
  `FC(framing_error_pid, v_ef_pid)
  `FC(framing_error_data, v_ef_rx)
  `FC(checksum_error, err_chk)
  `FC(response_timeout, err_timeout)
  `FC(bit_error_break, v_eb_brk)
  `FC(bit_error_delimiter, v_eb_del)
  `FC(bit_error_header_byte, v_eb_hdr_byte)
  `FC(bit_error_response, v_eb_rsp)
  `FC_RST(reset_mid_frame, rst_n && ph != P_IDLE ##1 !rst_n)
endmodule

bind LIN_top LIN_sva u_sva (.*);
