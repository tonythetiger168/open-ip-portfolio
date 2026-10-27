// SPDX-License-Identifier: Apache-2.0
// BLE link layer: a cycle-level reference model fed only by the pins (rxd,
// the host config port) predicts txd, tx_act and irq on every clock. It
// de-whitens and checks received packets (advertising and data channel),
// keeps its own link state (CONNECT_REQ parameters, channel hopping,
// SN / NESN, missed events, peripheral latency, supervision timeout) and
// builds every transmitted packet (ADV_IND, SCAN_RSP, empty data PDUs)
// bit by bit, including whitening and CRC24.
`include "cov_macros.svh"
module Bluetooth5_sva #(
  parameter int ADV_INTV = 1200
)(
  input logic       clk, rst_n, rxd, txd, tx_act, cfg_we, irq,
  input logic [4:0] cfg_addr,
  input logic [7:0] cfg_wdata
);
  `COV_CLOCKING(clk, !rst_n)

  localparam logic [31:0] AAA = 32'h8E89BED6;
  localparam logic [23:0] ACI = 24'h555555;

  function automatic logic [6:0] wn(input logic [6:0] l);
    wn = {l[5:0], l[6] ^ l[3]};
  endfunction
  function automatic logic [23:0] cb(input logic [23:0] c, input logic b);
    cb = (c[0] ^ b) ? ((c >> 1) ^ 24'h00065B) : (c >> 1);
  endfunction

  // ---------------- model state ----------------
  logic [7:0]  pay [0:15];
  logic        adv_en, scan_en;
  // link
  logic        conn;
  logic [31:0] caa;
  logic [23:0] cci;
  int          intv, lat, tmo, hop, ch, ctim, miss, atim;
  logic        rsn, tsn, seen, q_adv, q_scan, q_data, err;
  // receiver
  int          rph, bitn, bytn, plen;           // rph: 0 AA, 1 header, 2 payload, 3 CRC
  logic [31:0] sh;
  logic [6:0]  wl;
  logic [23:0] crc, rcrc;
  logic [7:0]  by, h0;
  logic [7:0]  rb [0:15];
  logic        r_done, r_ok, r_long;
  // transmitter
  int          kind, tby, tbi, tcb;             // kind: 0 ADV_IND, 1 SCAN_RSP, 2 data
  logic        tsend, m_act, m_txd, l_sn, l_nesn, g_adv, g_scan, g_data, m_irq;
  logic [23:0] tcrc;
  logic [6:0]  twl;

  // coverage events (1-clock pulses)
  logic v_adv, v_scan, v_conn, v_data, v_ka, v_new, v_retx, v_acked, v_nacked, v_bad_crc,
        v_bad_type, v_bad_llid, v_long, v_conn_len, v_timeout, v_wrap, v_hop_wrap, v_known,
        v_scan_off, v_rx_conn_bad_crc, v_lat_skip;

  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  logic c_pv, c_pc, c_new, c_ack, c_ev;
  int   c_ty, c_len, c_ch;

  function automatic logic [7:0] tbyte(input int k, input int i, input logic [31:0] a,
                                       input logic s, input logic n);
    if (i == 0)      tbyte = a[0] ? 8'h55 : 8'hAA;
    else if (i < 5)  tbyte = a[8 * (i - 1) +: 8];
    else if (i == 5) tbyte = (k == 2) ? {4'h0, s, n, 2'b01} : (k == 1) ? 8'h04 : 8'h00;
    else if (i == 6) tbyte = (k == 2) ? 8'd0 : 8'd16;
    else             tbyte = (k == 0) ? pay[i - 7] : 8'h53 + 8'(i - 7);
  endfunction

  always @(posedge clk or negedge rst_n) begin
    // snapshots of the values every section reads from another one
    logic        o_conn, o_act, o_qa, o_qs, o_qd, o_tsn, o_rsn, o_done, o_ok, o_long, o_ga,
                 o_gs, o_gd, o_err;
    logic [31:0] o_caa, a;
    logic [23:0] o_cci;
    int          o_ch, o_plen, n;
    logic [7:0]  o_h0, o_rb [0:15];
    logic        b, d;
    if (!rst_n) begin
      for (int i = 0; i < 16; i++) begin pay[i] = 8'hB0 + 8'(i); rb[i] = 0; end
      adv_en = 1; scan_en = 1;
      conn = 0; caa = 0; cci = 0; intv = 1500; lat = 0; tmo = 0; hop = 0; ch = 0;
      ctim = 0; miss = 0; atim = 0; rsn = 0; tsn = 0; seen = 0;
      q_adv = 0; q_scan = 0; q_data = 0; err = 0;
      rph = 0; bitn = 0; bytn = 0; plen = 0; sh = 0; wl = 0; crc = 0; rcrc = 0; by = 0; h0 = 0;
      r_done = 0; r_ok = 0; r_long = 0;
      kind = 0; tby = 0; tbi = 0; tcb = 0; tsend = 0; m_act = 0; m_txd = 0; l_sn = 0; l_nesn = 0;
      g_adv = 0; g_scan = 0; g_data = 0; m_irq = 0; tcrc = 0; twl = 0;
      {v_adv, v_scan, v_conn, v_data, v_ka, v_new, v_retx, v_acked, v_nacked, v_bad_crc,
       v_bad_type, v_bad_llid, v_long, v_conn_len, v_timeout, v_wrap, v_hop_wrap, v_known,
       v_scan_off, v_rx_conn_bad_crc, v_lat_skip} = '0;
    end else begin
      {v_adv, v_scan, v_conn, v_data, v_ka, v_new, v_retx, v_acked, v_nacked, v_bad_crc,
       v_bad_type, v_bad_llid, v_long, v_conn_len, v_timeout, v_wrap, v_hop_wrap, v_known,
       v_scan_off, v_rx_conn_bad_crc, v_lat_skip} = '0;
      o_conn = conn; o_act = m_act; o_qa = q_adv; o_qs = q_scan; o_qd = q_data;
      o_tsn = tsn; o_rsn = rsn; o_done = r_done; o_ok = r_ok; o_long = r_long;
      o_ga = g_adv; o_gs = g_scan; o_gd = g_data; o_err = err; o_caa = caa; o_cci = cci;
      o_ch = ch; o_plen = plen; o_h0 = h0;
      for (int i = 0; i < 16; i++) o_rb[i] = rb[i];

      // ---- irq ----
      m_irq = o_err;
      c_pv = 0; c_ev = 0;

      // ---- transmitter ----
      g_adv = 0; g_scan = 0; g_data = 0;
      if (!tsend) begin
        m_txd = 0; m_act = 0; tby = 0; tbi = 0; tcb = 0;
        if (o_qd) begin
          kind = 2; l_sn = o_tsn; l_nesn = o_rsn; tcrc = o_cci; twl = 7'(o_ch) | 7'h01;
          g_data = 1; tsend = 1;
        end else if (o_qs) begin
          kind = 1; tcrc = ACI; twl = 7'h25; g_scan = 1; tsend = 1;
        end else if (o_qa) begin
          kind = 0; tcrc = ACI; twl = 7'h25; g_adv = 1; tsend = 1;
        end
      end else begin
        m_act = 1;
        a = (kind == 2) ? o_caa : AAA;
        n = (kind == 2) ? 7 : 23;
        if (tby == n) b = tcrc[tcb];
        else begin by = tbyte(kind, tby, a, l_sn, l_nesn); b = by[tbi]; end
        if (tby >= 5) begin m_txd = b ^ twl[6]; twl = wn(twl); end
        else m_txd = b;
        if (tby == n) begin
          if (tcb == 23) tsend = 0;
          tcb++;
        end else begin
          if (tby >= 5) tcrc = cb(tcrc, b);
          if (tbi == 7) begin tbi = 0; tby++; end else tbi++;
        end
      end

      // ---- receiver (only while not transmitting) ----
      r_done = 0; r_long = 0;
      if (!o_act) begin
        sh = {rxd, sh[31:1]};
        d  = rxd ^ wl[6];
        case (rph)
          0: if (sh == (o_conn ? o_caa : AAA)) begin
               wl = o_conn ? (7'(o_ch) | 7'h01) : 7'h25;
               crc = o_conn ? o_cci : ACI;
               bitn = 0; bytn = 0; rph = 1;
             end
          1, 2: begin
            wl = wn(wl); crc = cb(crc, d);
            by = {d, by[7:1]};
            if (bitn == 7) begin
              bitn = 0;
              if (rph == 1 && bytn == 0) begin h0 = by; bytn = 1; end
              else if (rph == 1) begin
                bytn = 0; rcrc = 0;
                if (by > 16) begin r_long = 1; rph = 0; end
                else begin plen = by; rph = (by == 0) ? 3 : 2; end
              end else begin
                rb[bytn] = by;
                if (bytn == plen - 1) begin bytn = 0; rph = 3; end else bytn++;
              end
            end else bitn++;
          end
          default: begin
            wl = wn(wl);
            rcrc = {d, rcrc[23:1]};
            if (bitn == 23) begin
              r_done = 1; r_ok = (rcrc == crc); rph = 0; bitn = 0;
            end else bitn++;
          end
        endcase
      end

      // ---- link layer ----
      err = o_long;
      if (o_long) v_long = 1;
      if (o_ga) q_adv = 0;
      if (o_gs) q_scan = 0;
      if (o_gd) q_data = 0;
      if (o_ga) v_adv = 1;
      if (o_gs) v_scan = 1;
      if (!o_conn) begin
        if (atim >= ADV_INTV) begin atim = 0; if (adv_en) q_adv = 1; end
        else atim++;
      end else begin
        atim = 0;
        if (ctim >= intv) begin
          ctim = 0;
          if (ch + hop >= 37) v_hop_wrap = 1;
          ch = (ch + hop) % 37;
          c_ev = 1; c_ch = ch;
          if (seen) miss = 0;
          else if (tmo != 0 && ((miss + 1) & 16'hFFFF) >= tmo) begin
            conn = 0; q_data = 0; err = 1; v_timeout = 1;
          end else begin
            if (miss >= lat) begin q_data = 1; v_ka = 1; end
            else v_lat_skip = 1;
            miss = (miss + 1) & 16'hFFFF;
          end
          seen = 0;
        end else ctim++;
      end
      if (o_done && o_ok) begin
        c_pv = 1; c_pc = o_conn; c_ty = o_conn ? o_h0[1:0] : o_h0[3:0]; c_len = o_plen;
        c_new = o_h0[3] == o_rsn; c_ack = o_h0[2] != o_tsn;
      end
      if (o_done) begin
        if (!o_ok) begin
          err = 1; v_bad_crc = 1;
          if (o_conn) v_rx_conn_bad_crc = 1;
        end else if (!o_conn) begin
          case (o_h0[3:0])
            4'h3: if (scan_en) q_scan = 1; else v_scan_off = 1;
            4'h5: if (o_plen == 15) begin
              caa  = {o_rb[3], o_rb[2], o_rb[1], o_rb[0]};
              cci  = {o_rb[6], o_rb[5], o_rb[4]};
              intv = {o_rb[8], o_rb[7]};
              lat  = {o_rb[10], o_rb[9]};
              tmo  = {o_rb[12], o_rb[11]};
              hop  = o_rb[13][4:0];
              ch   = o_rb[14][5:0] % 37;
              if (o_rb[14][5:0] >= 37) v_wrap = 1;
              rsn = 0; tsn = 0; ctim = 0; miss = 0; seen = 0; q_adv = 0; q_scan = 0;
              conn = 1; v_conn = 1;
            end else begin err = 1; v_conn_len = 1; end
            4'h0, 4'h1, 4'h2, 4'h4, 4'h6: v_known = 1;
            default: begin err = 1; v_bad_type = 1; end
          endcase
        end else begin
          seen = 1;
          if (o_h0[1:0] == 2'b00) begin err = 1; v_bad_llid = 1; end
          else begin
            v_data = 1;
            if (o_h0[3] == o_rsn) begin rsn = ~o_rsn; v_new = 1; end else v_retx = 1;
            if (o_h0[2] != o_tsn) begin tsn = ~o_tsn; v_acked = 1; end else v_nacked = 1;
            q_data = 1;
          end
        end
      end

      // ---- host config (after the transmitter read the payload) ----
      if (cfg_we) begin
        if (cfg_addr < 16)       pay[cfg_addr[3:0]] = cfg_wdata;
        else if (cfg_addr == 16) adv_en  = cfg_wdata[0];
        else if (cfg_addr == 17) scan_en = cfg_wdata[0];
      end
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_outputs, !rst_n, !txd && !tx_act && !irq)
  `SVA_INV(a_txd, txd == m_txd)
  `SVA_INV(a_tx_act, tx_act == m_act)
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_IMP(a_txd_low_when_idle, !tx_act, !txd)
  `SVA_NXT(a_irq_on_timeout, v_timeout, irq)
  `SVA_NXT(a_irq_on_bad_crc, v_bad_crc, irq)

  // good packets by PDU type / LLID and length, SN / NESN outcomes, every
  // data channel a connection event lands on
  covergroup cg_ble @(negedge clk);
    option.per_instance = 1;
    cp_adv: coverpoint c_ty iff (rst_n && c_pv && !c_pc)
      { bins ind = {0}; bins direct = {1}; bins nonconn = {2}; bins scan_req = {3}; bins scan_rsp = {4};
        bins connect = {5}; bins scan_ind = {6}; bins reserved = {[7:15]}; }
    cp_llid: coverpoint c_ty iff (rst_n && c_pv && c_pc)
      { bins reserved = {0}; bins cont = {1}; bins start = {2}; bins ctrl = {3}; }
    cp_seq: coverpoint {c_new, c_ack} iff (rst_n && c_pv && c_pc && c_ty != 0)
      { bins retx_nack = {2'b00}; bins retx_ack = {2'b01}; bins new_nack = {2'b10}; bins new_ack = {2'b11}; }
    cp_dlen: coverpoint c_len iff (rst_n && c_pv && c_pc && c_ty != 0)
      { bins empty = {0}; bins some = {[1:15]}; bins max = {16}; }
    cp_ch: coverpoint c_ch iff (rst_n && c_ev) { bins c[] = {[0:36]}; }
  endgroup
  cg_ble u_cg_ble = new;

  // ---------------- functional coverage ----------------
  `FC(adv_ind_sent, v_adv)
  `FC(scan_rsp_sent, v_scan)
  `FC(scan_req_while_scan_disabled, v_scan_off)
  `FC(adv_disabled, !adv_en && !conn)
  `FC(known_adv_pdu_ignored, v_known)
  `FC(connection_established, v_conn)
  `FC(channel_index_wrap, v_wrap)
  `FC(hop_wraps_mod_37, v_hop_wrap)
  `FC(data_pdu_received, v_data)
  `FC(new_data_acked, v_new)
  `FC(retransmission_seen, v_retx)
  `FC(our_pdu_acked, v_acked)
  `FC(our_pdu_nacked, v_nacked)
  `FC(keepalive, v_ka)
  `FC(event_skipped_by_latency, v_lat_skip)
  `FC(supervision_timeout, v_timeout)
  `FC(bad_crc_advertising, v_bad_crc && !conn)
  `FC(bad_crc_connection, v_rx_conn_bad_crc)
  `FC(unknown_adv_type, v_bad_type)
  `FC(reserved_llid, v_bad_llid)
  `FC(oversize_length, v_long)
  `FC(connect_req_wrong_length, v_conn_len)
  `FC(preamble_55, tsend && tby == 0 && (kind == 2 ? caa[0] : AAA[0]))
  `FC_RST(reset_during_tx, rst_n && tx_act ##1 !rst_n)
endmodule

bind Bluetooth5_top Bluetooth5_sva #(.ADV_INTV(ADV_INTV)) u_sva (.*);
