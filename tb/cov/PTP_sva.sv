// SPDX-License-Identifier: Apache-2.0
// IEEE 1588 timestamp unit: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * Clock model: its own {sec, ns, fraction} from the cfg / set / step pins
//    (64-bit signed arithmetic instead of the RTL's carry chains); t_sec,
//    t_ns, sec_tick, snap, pps, the target compare and the event capture
//    are checked against it on every clock.
//  * Stream model (one per direction): collects the bytes of a frame after
//    the SFD and, when the frame ends, parses the whole array at once
//    (EtherType / 802.1Q, IPv4 / IPv6 / UDP header fields, the FCS
//    recomputed and compared with the last four bytes, lengths, PTP header)
//    to decide whether it gets a timestamp, with which value, and why not.
//    A model FIFO checks *q_valid, the head entry and *q_ovf every clock.
`include "cov_macros.svh"
module PTP_sva_tsu #(
  parameter int DEPTH = 4,
  parameter bit TX = 0
) (
  input  logic        clk, rst_n, dv, er,
  input  logic [7:0]  d,
  input  logic [47:0] t_sec,
  input  logic [29:0] t_ns,
  input  logic [15:0] lat,
  input  logic        l2_en, ipv4_en, ipv6_en,
  input  logic        q_valid, q_pop,
  input  logic [3:0]  q_type,
  input  logic [7:0]  q_domain,
  input  logic [15:0] q_seq,
  input  logic [47:0] q_sec,
  input  logic [29:0] q_ns,
  input  logic        q_ovf,
  output bit          v_push,                 // an event message timestamped this clock
  output int          v_kind, v_type, v_ihl
);
  `COV_CLOCKING(clk, !rst_n)
  localparam longint GIGA = 1_000_000_000;
  // why a frame is not timestamped
  localparam int R_OK = 0, R_ET = 1, R_IP4VER = 2, R_IHL = 3, R_MF = 4, R_OFFHI = 5, R_OFFLO = 6,
                 R_PROTO = 7, R_PORT = 8, R_IP6VER = 9, R_IP6NH = 10, R_DIS = 11, R_ER = 12,
                 R_FCS = 13, R_RUNT = 14, R_SHORT = 15, R_TYPE = 16, R_VER = 17;
  localparam int M_IDLE = 0, M_PRE = 1, M_DATA = 2, M_SKIP = 3;

  int           mode;
  logic [7:0]   fb [0:4095];
  int           n;
  bit           bad;
  logic [47:0]  ssec;
  logic [29:0]  sns;
  logic [105:0] mq [0:DEPTH-1];
  int           mh, mt;
  bit           m_ovf;
  int           v_why;
  bit           v_end, v_vlan, v_jumbo, v_borrow, v_carry, v_full_pop, v_pop, v_cut_pre, v_skip, v_sfd_first;

  function automatic logic [7:0] by(input int i);
    return i < n ? fb[i] : 8'h00;
  endfunction
  function automatic logic [31:0] crc8(input logic [31:0] c, input logic [7:0] b);
    logic [31:0] x;
    x = c;
    for (int i = 0; i < 8; i++) x = (x >> 1) ^ ((x[0] ^ b[i]) ? 32'hEDB8_8320 : 32'h0);
    return x;
  endfunction

  wire [31:0] cnt = mt - mh;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mode <= M_IDLE; n <= 0; bad <= 0; ssec <= '0; sns <= '0; mh <= 0; mt <= 0; m_ovf <= 0;
      v_push = 0; v_pop = 0; v_end = 0; v_why = -1; v_kind = 0; v_type = 0; v_ihl = 0;
    end else begin
      int l3, l4, p0, et, why, kind, ihl;
      bit en, vl;
      logic [31:0] c;
      longint ns;
      logic [47:0] sec;
      v_push = 0; v_end = 0; v_why = -1; v_vlan = 0; v_jumbo = 0; v_borrow = 0; v_carry = 0;
      v_full_pop = 0; v_pop = 0; v_cut_pre = 0; v_skip = 0; v_sfd_first = 0;
      m_ovf <= 0;
      case (mode)
        M_IDLE, M_PRE:
          if (!dv) begin mode <= M_IDLE; v_cut_pre = mode == M_PRE; end
          else if (d == 8'hD5) begin
            mode <= M_DATA; n <= 0; bad <= 0; ssec <= t_sec; sns <= t_ns; v_sfd_first = mode == M_IDLE;
          end else if (d == 8'h55) mode <= M_PRE;
          else begin mode <= M_SKIP; v_skip = 1; end
        M_SKIP: if (!dv) mode <= M_IDLE;
        default:
          if (dv) begin
            if (n < 4096) fb[n] <= d;
            n <= n + 1;
            if (er) bad <= 1;
          end else begin
            // the frame is complete: parse it
            mode <= M_IDLE; v_end = 1;
            why = R_OK; kind = 0; ihl = 0; p0 = -1; vl = 0;
            l3 = 14; et = {by(12), by(13)};
            if (et == 16'h8100) begin vl = 1; l3 = 18; et = {by(16), by(17)}; end
            if (et == 16'h88F7) begin kind = 1; p0 = l3; end
            else if (et == 16'h0800) begin
              kind = 2; ihl = by(l3) & 15;
              if (by(l3) >> 4 != 4) why = R_IP4VER;
              else if (ihl < 5) why = R_IHL;
              else if (by(l3 + 6) & 8'h20) why = R_MF;
              else if (by(l3 + 6) & 8'h1F) why = R_OFFHI;
              else if (by(l3 + 7) != 0) why = R_OFFLO;
              else if (by(l3 + 9) != 17) why = R_PROTO;
              else begin
                l4 = l3 + 4 * ihl;
                if ({by(l4 + 2), by(l4 + 3)} == 16'd319) p0 = l4 + 8; else why = R_PORT;
              end
            end else if (et == 16'h86DD) begin
              kind = 3;
              if (by(l3) >> 4 != 6) why = R_IP6VER;
              else if (by(l3 + 6) != 17) why = R_IP6NH;
              else begin
                l4 = l3 + 40;
                if ({by(l4 + 2), by(l4 + 3)} == 16'd319) p0 = l4 + 8; else why = R_PORT;
              end
            end else why = R_ET;
            if (why == R_OK) begin
              en = kind == 1 ? l2_en : kind == 2 ? ipv4_en : ipv6_en;
              c = 32'hFFFF_FFFF;
              for (int i = 0; i < n - 4; i++) c = crc8(c, fb[i]);
              if (!en) why = R_DIS;
              else if (bad) why = R_ER;
              else if (n < 4 || ~c != {by(n - 1), by(n - 2), by(n - 3), by(n - 4)}) why = R_FCS;
              else if (n < 64) why = R_RUNT;
              else if (n < p0 + 38) why = R_SHORT;
              else if (by(p0) % 16 > 3) why = R_TYPE;
              else if (by(p0 + 1) % 16 != 2) why = R_VER;
            end
            v_why = why; v_vlan = vl;
            if (why == R_OK) begin
              // the timestamp: SFD time -/+ the latency
              ns = longint'(sns); sec = ssec;
              if (TX) begin
                ns = ns + longint'(lat);
                if (ns >= GIGA) begin ns = ns - GIGA; sec = sec + 48'd1; v_carry = 1; end
              end else begin
                ns = ns - longint'(lat);
                if (ns < 0) begin ns = ns + GIGA; sec = sec - 48'd1; v_borrow = 1; end
              end
              v_push = 1; v_kind = kind; v_type = by(p0) % 16; v_ihl = ihl; v_jumbo = n > 2047;
              if (cnt == DEPTH && !q_pop) m_ovf <= 1;
              else begin
                mq[mt % DEPTH] <= {4'(by(p0)), by(p0 + 4),
                                   by(p0 + 30), by(p0 + 31), sec, 30'(ns)};
                mt <= mt + 1;
                v_full_pop = cnt == DEPTH;
              end
            end
          end
      endcase
      if (q_pop && cnt != 0) begin mh <= mh + 1; v_pop = 1; end
    end
  end

  wire [105:0] head = mq[mh % DEPTH];
  `SVA_INV(a_fifo_valid_model, q_valid == (cnt != 0))
  `SVA_IMP(a_fifo_head_model, q_valid, {q_type, q_domain, q_seq, q_sec, q_ns} == head)
  `SVA_IMP(a_fifo_empty_zero, !q_valid, {q_type, q_domain, q_seq, q_sec, q_ns} == '0)
  `SVA_INV(a_ovf_model, q_ovf == m_ovf)
  `SVA_INV(a_fifo_bound, cnt <= DEPTH)
  `SVA_IMP(a_ts_ns_range, q_valid, q_ns < 30'd1_000_000_000 && q_type <= 4'd3)

  `FC(ts_l2, v_push && v_kind == 1)
  `FC(ts_ipv4, v_push && v_kind == 2)
  `FC(ts_ipv6, v_push && v_kind == 3)
  `FC(ts_vlan, v_push && v_vlan)
  `FC(ts_untagged, v_push && !v_vlan)
  `FC(ts_jumbo_frame, v_push && v_jumbo)
  `FC(ts_latency_crosses_a_second, v_borrow || v_carry)   // RX borrows, TX carries
  `FC(no_ts_other_ethertype, v_why == R_ET)
  `FC(no_ts_ipv4_version, v_why == R_IP4VER)
  `FC(no_ts_ipv4_ihl, v_why == R_IHL)
  `FC(no_ts_ipv4_more_fragments, v_why == R_MF)
  `FC(no_ts_ipv4_offset_high, v_why == R_OFFHI)
  `FC(no_ts_ipv4_offset_low, v_why == R_OFFLO)
  `FC(no_ts_not_udp, v_why == R_PROTO)
  `FC(no_ts_port, v_why == R_PORT)
  `FC(no_ts_ipv6_version, v_why == R_IP6VER)
  `FC(no_ts_ipv6_next_header, v_why == R_IP6NH)
  `FC(no_ts_transport_disabled, v_why == R_DIS)
  `FC(no_ts_er_byte, v_why == R_ER)
  `FC(no_ts_bad_fcs, v_why == R_FCS)
  `FC(no_ts_runt, v_why == R_RUNT)
  `FC(no_ts_cut_in_header, v_why == R_SHORT)
  `FC(no_ts_general_message, v_why == R_TYPE)
  `FC(no_ts_version, v_why == R_VER)
  `FC(fifo_full, cnt == DEPTH)
  `FC(fifo_overflow, q_ovf)
  `FC(push_into_full_with_pop, v_full_pop)
  `FC(pop_and_push, v_push && v_pop)   // same clock (both model flags of one edge)
  `FC(pop_when_empty, q_pop && cnt == 0)
  `FC(preamble_cut, v_cut_pre)
  `FC(no_sfd, v_skip)
  `FC(sfd_without_preamble, v_sfd_first)
  `FC_RST(reset_mid_frame, rst_n && mode == M_DATA ##1 !rst_n)
endmodule

module PTP_sva #(
  parameter int FIFO_DEPTH = 4
) (
  input logic        clk, rst_n,
  input logic [7:0]  cfg_inc_ns,
  input logic [31:0] cfg_inc_frac,
  input logic        time_set,
  input logic [47:0] set_sec,
  input logic [29:0] set_ns,
  input logic        time_step,
  input logic [31:0] step_ns,
  input logic        snap,
  input logic [47:0] t_sec,
  input logic [29:0] t_ns,
  input logic [47:0] snap_sec,
  input logic [29:0] snap_ns,
  input logic        pps_en,
  input logic [29:0] pps_width_ns,
  input logic        pps, sec_tick, target_arm, target_disarm,
  input logic [47:0] target_sec,
  input logic [29:0] target_ns,
  input logic        target_armed, target_hit, ext_evt, evt_valid,
  input logic [47:0] evt_sec,
  input logic [29:0] evt_ns,
  input logic        rx_dv, rx_er,
  input logic [7:0]  rxd,
  input logic        tx_en, tx_er,
  input logic [7:0]  txd,
  input logic [15:0] cfg_rx_lat_ns, cfg_tx_lat_ns,
  input logic        cfg_l2_en, cfg_ipv4_en, cfg_ipv6_en,
  input logic        rxq_valid, rxq_pop,
  input logic [3:0]  rxq_type,
  input logic [7:0]  rxq_domain,
  input logic [15:0] rxq_seq,
  input logic [47:0] rxq_sec,
  input logic [29:0] rxq_ns,
  input logic        rxq_ovf, txq_valid, txq_pop,
  input logic [3:0]  txq_type,
  input logic [7:0]  txq_domain,
  input logic [15:0] txq_seq,
  input logic [47:0] txq_sec,
  input logic [29:0] txq_ns,
  input logic        txq_ovf
);
  `COV_CLOCKING(clk, !rst_n)
  localparam longint GIGA = 1_000_000_000;

  // ---------------- clock, snap, pps, target, event ----------------
  logic [47:0] m_sec, m_snsec, m_esec;
  logic [29:0] m_ns, m_snns, m_ens;
  logic [31:0] m_frac;
  bit          m_tick, m_pps, m_arm, m_hit, e1, e2, e3, m_ev;
  bit          v_clamp, v_borrow, v_carry, v_step, v_wrap, v_frac_carry, v_arm_disarm, v_past, v_disarm;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_sec <= '0; m_ns <= '0; m_frac <= '0; m_tick <= 0; m_snsec <= '0; m_snns <= '0; m_pps <= 0;
      m_arm <= 0; m_hit <= 0; e1 <= 0; e2 <= 0; e3 <= 0; m_ev <= 0; m_esec <= '0; m_ens <= '0;
    end else begin
      longint ns;
      logic [47:0] s;
      logic [32:0] fs;
      bit tk;
      v_clamp = 0; v_borrow = 0; v_carry = 0; v_step = 0; v_wrap = 0; v_frac_carry = 0;
      v_arm_disarm = 0; v_past = 0; v_disarm = 0;
      fs = {1'b0, m_frac} + {1'b0, cfg_inc_frac};
      if (time_set) begin
        m_sec <= set_sec; m_ns <= set_ns > 30'd999_999_999 ? 30'd999_999_999 : set_ns; m_frac <= '0;
        m_tick <= 0; v_clamp = set_ns > 30'd999_999_999;
      end else begin
        ns = longint'(m_ns) + longint'(cfg_inc_ns) + longint'(fs[32]);
        s = m_sec; tk = 0; v_frac_carry = fs[32];
        if (ns >= GIGA) begin ns = ns - GIGA; s = s + 48'd1; tk = 1; v_wrap = m_sec == '1; end
        if (time_step) begin
          ns = ns + longint'($signed(step_ns)); tk = 0; v_step = 1;
          if (ns < 0) begin ns = ns + GIGA; s = s - 48'd1; v_borrow = 1; end
          else if (ns >= GIGA) begin ns = ns - GIGA; s = s + 48'd1; v_carry = 1; end
        end
        m_sec <= s; m_ns <= 30'(ns); m_frac <= fs[31:0]; m_tick <= tk;
      end
      if (snap) begin m_snsec <= m_sec; m_snns <= m_ns; end
      m_pps <= pps_en && m_ns < pps_width_ns;
      m_hit <= 0;
      if (target_arm) begin m_arm <= 1; v_arm_disarm = target_disarm; v_past = {m_sec, m_ns} >= {target_sec, target_ns}; end
      else if (target_disarm) begin m_arm <= 0; v_disarm = m_arm; end
      else if (m_arm && {m_sec, m_ns} >= {target_sec, target_ns}) begin m_arm <= 0; m_hit <= 1; end
      e1 <= ext_evt; e2 <= e1; e3 <= e2;
      m_ev <= e2 && !e3;
      if (e2 && !e3) begin m_esec <= m_sec; m_ens <= m_ns; end
    end
  end

  `SVA_RST(a_reset_values, !rst_n, t_sec == 0 && t_ns == 0 && !sec_tick && !pps && !target_armed && !target_hit
           && !evt_valid && !rxq_valid && !txq_valid && !rxq_ovf && !txq_ovf)
  `SVA_INV(a_clock_model, t_sec == m_sec && t_ns == m_ns && sec_tick == m_tick)
  `SVA_INV(a_ns_range, t_ns < 30'd1_000_000_000)
  `SVA_INV(a_snap_model, snap_sec == m_snsec && snap_ns == m_snns)
  `SVA_INV(a_pps_model, pps == m_pps)
  `SVA_INV(a_target_model, target_armed == m_arm && target_hit == m_hit)
  `SVA_INV(a_event_model, evt_valid == m_ev && evt_sec == m_esec && evt_ns == m_ens)
  `SVA_IMP(a_tick_once_per_second, sec_tick, t_ns < 30'd256)

  // ---------------- timestamp streams ----------------
  bit rx_push, tx_push;
  int rx_kind, rx_type, rx_ihl, tx_kind, tx_type, tx_ihl;
  PTP_sva_tsu #(.DEPTH(FIFO_DEPTH), .TX(0)) u_mrx (
    .clk, .rst_n, .dv(rx_dv), .er(rx_er), .d(rxd), .t_sec, .t_ns, .lat(cfg_rx_lat_ns),
    .l2_en(cfg_l2_en), .ipv4_en(cfg_ipv4_en), .ipv6_en(cfg_ipv6_en),
    .q_valid(rxq_valid), .q_pop(rxq_pop), .q_type(rxq_type), .q_domain(rxq_domain), .q_seq(rxq_seq),
    .q_sec(rxq_sec), .q_ns(rxq_ns), .q_ovf(rxq_ovf),
    .v_push(rx_push), .v_kind(rx_kind), .v_type(rx_type), .v_ihl(rx_ihl));
  PTP_sva_tsu #(.DEPTH(FIFO_DEPTH), .TX(1)) u_mtx (
    .clk, .rst_n, .dv(tx_en), .er(tx_er), .d(txd), .t_sec, .t_ns, .lat(cfg_tx_lat_ns),
    .l2_en(cfg_l2_en), .ipv4_en(cfg_ipv4_en), .ipv6_en(cfg_ipv6_en),
    .q_valid(txq_valid), .q_pop(txq_pop), .q_type(txq_type), .q_domain(txq_domain), .q_seq(txq_seq),
    .q_sec(txq_sec), .q_ns(txq_ns), .q_ovf(txq_ovf),
    .v_push(tx_push), .v_kind(tx_kind), .v_type(tx_type), .v_ihl(tx_ihl));

  // ---------------- functional coverage ----------------
  `FC(set_clamped, v_clamp)
  `FC(step_borrows_a_second, v_borrow)
  `FC(step_carries_a_second, v_carry)
  `FC(step_in_the_second, v_step && !v_borrow && !v_carry)
  `FC(fraction_carry, v_frac_carry)
  `FC(seconds_wrap, v_wrap)
  `FC(sec_tick, sec_tick)
  `FC(snap, snap)
  `FC(pps_pulse, pps)
  `FC(target_hit, target_hit)
  `FC(target_in_the_past, v_past)
  `FC(target_disarmed, v_disarm)
  `FC(target_arm_and_disarm, v_arm_disarm)
  `FC(external_event, evt_valid)
  `FC(both_streams_busy, rx_dv && tx_en)
  `FC(timestamps_on_both_streams, rx_push && tx_push)

  covergroup cg_ptp @(negedge clk);
    option.per_instance = 1;
    cp_rx_kind: coverpoint rx_kind iff (rx_push) { bins l2 = {1}; bins ipv4 = {2}; bins ipv6 = {3}; }
    cp_rx_type: coverpoint rx_type iff (rx_push) { bins sync = {0}; bins delay_req = {1}; bins pdelay_req = {2}; bins pdelay_resp = {3}; }
    x_rx: cross cp_rx_kind, cp_rx_type;
    cp_tx_kind: coverpoint tx_kind iff (tx_push) { bins l2 = {1}; bins ipv4 = {2}; bins ipv6 = {3}; }
    cp_tx_type: coverpoint tx_type iff (tx_push) { bins sync = {0}; bins delay_req = {1}; bins pdelay_req = {2}; bins pdelay_resp = {3}; }
    x_tx: cross cp_tx_kind, cp_tx_type;
    cp_rx_ihl: coverpoint rx_ihl iff (rx_push && rx_kind == 2) { bins min_ = {5}; bins mid = {[6:14]}; bins max_ = {15}; }
  endgroup
  cg_ptp u_cg_ptp = new;
endmodule

bind PTP_top PTP_sva #(.FIFO_DEPTH(FIFO_DEPTH)) u_sva (.*);
