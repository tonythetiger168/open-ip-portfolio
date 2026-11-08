// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// PTP_top v1.0: IEEE 1588-2019 (PTPv2) hardware clock and timestamp unit
// for one Ethernet port
// ----------------------------------------------------------------------------
//  - PTP hardware clock: {t_sec (48 bits), t_ns (0..999,999,999), a 32-bit
//    fraction of a ns} advances by {cfg_inc_ns, cfg_inc_frac} every clk
//    (the rate: 8 ns per clk at 125 MHz is inc_ns = 8, inc_frac = 0; a
//    servo trims inc_frac). time_set loads {set_sec, set_ns} with a zero
//    fraction (set_ns above 999,999,999 loads 999,999,999); time_step adds
//    the signed step_ns (|step_ns| < 10^9) on top of that clock's
//    increment. snap copies the time into snap_sec / snap_ns (a consistent
//    read of both halves).
//  - pps is high while pps_en and t_ns < pps_width_ns (one pulse at the
//    start of every second). sec_tick pulses when the increment carries
//    into the seconds.
//  - Target time: target_arm arms a compare; target_hit pulses in the
//    first clock with time >= {target_sec, target_ns} and disarms (an
//    armed time in the past hits in the next clock). target_disarm cancels.
//  - External event: ext_evt (asynchronous) goes through two flops; on a
//    rising edge evt_valid pulses and evt_sec / evt_ns hold the time of the
//    clock the synchronised edge is seen (2 to 3 clocks after the pin
//    edge; a later event overwrites them).
//  - Timestamp units for the receive and the transmit GMII byte streams
//    (one byte per clk with rx_dv / tx_en, er marks an errored byte; the
//    streams are only observed). A frame starts with optional preamble
//    bytes 0x55 and the SFD 0xD5; the time of the SFD clock is the frame's
//    timestamp, minus cfg_rx_lat_ns (receive) or plus cfg_tx_lat_ns
//    (transmit), the PHY latencies to the timestamp point on the line.
//    The frame is parsed for a PTP event message (messageType 0..3: Sync,
//    Delay_Req, Pdelay_Req, Pdelay_Resp; versionPTP 2):
//      * Ethernet II with an optional 802.1Q tag (TPID 0x8100);
//      * EtherType 0x88F7 (layer 2, cfg_l2_en);
//      * IPv4 (0x0800, cfg_ipv4_en): version 4, IHL >= 5, not a fragment,
//        protocol 17 (UDP), destination port 319;
//      * IPv6 (0x86DD, cfg_ipv6_en): next header 17 (no extension
//        headers), destination port 319.
//    A frame without er bytes, with a good FCS, at least 64 bytes long
//    and long enough for the whole 34-byte PTP header pushes {messageType,
//    domainNumber, sequenceId, timestamp} into that direction's FIFO
//    (FIFO_DEPTH entries); a full FIFO drops it (rxq_ovf / txq_ovf)
//    unless the head is popped in the same clock.
//    The head entry is shown while *q_valid; *q_pop removes it.
//  Not implemented: one-step timestamping (no frame is changed), PTP
//  general messages (no timestamp needed), more than one VLAN tag, IPv6
//  extension headers, the BMCA and the servo (software).
// ============================================================================
module PTP_top #(
  parameter int FIFO_DEPTH = 4             // entries per FIFO (power of 2, >= 2)
) (
  input  logic        clk,
  input  logic        rst_n,
  // clock
  input  logic [7:0]  cfg_inc_ns,
  input  logic [31:0] cfg_inc_frac,
  input  logic        time_set,
  input  logic [47:0] set_sec,
  input  logic [29:0] set_ns,
  input  logic        time_step,
  input  logic [31:0] step_ns,
  input  logic        snap,
  output logic [47:0] t_sec,
  output logic [29:0] t_ns,
  output logic [47:0] snap_sec,
  output logic [29:0] snap_ns,
  // pulse per second, target time
  input  logic        pps_en,
  input  logic [29:0] pps_width_ns,
  output logic        pps,
  output logic        sec_tick,
  input  logic        target_arm,
  input  logic        target_disarm,
  input  logic [47:0] target_sec,
  input  logic [29:0] target_ns,
  output logic        target_armed,
  output logic        target_hit,
  // external event
  input  logic        ext_evt,
  output logic        evt_valid,
  output logic [47:0] evt_sec,
  output logic [29:0] evt_ns,
  // MAC streams (observed)
  input  logic        rx_dv,
  input  logic        rx_er,
  input  logic [7:0]  rxd,
  input  logic        tx_en,
  input  logic        tx_er,
  input  logic [7:0]  txd,
  input  logic [15:0] cfg_rx_lat_ns,
  input  logic [15:0] cfg_tx_lat_ns,
  input  logic        cfg_l2_en,
  input  logic        cfg_ipv4_en,
  input  logic        cfg_ipv6_en,
  // receive timestamps
  output logic        rxq_valid,
  input  logic        rxq_pop,
  output logic [3:0]  rxq_type,
  output logic [7:0]  rxq_domain,
  output logic [15:0] rxq_seq,
  output logic [47:0] rxq_sec,
  output logic [29:0] rxq_ns,
  output logic        rxq_ovf,
  // transmit timestamps
  output logic        txq_valid,
  input  logic        txq_pop,
  output logic [3:0]  txq_type,
  output logic [7:0]  txq_domain,
  output logic [15:0] txq_seq,
  output logic [47:0] txq_sec,
  output logic [29:0] txq_ns,
  output logic        txq_ovf
);
  localparam logic [29:0] NS_MAX = 30'd999_999_999;
  localparam logic [30:0] GIGA   = 31'd1_000_000_000;

  // ---------------- hardware clock ----------------
  logic [31:0] t_frac;
  logic [32:0] frac_sum;
  logic [30:0] ns_inc;            // t_ns + increment, before the wrap
  logic [47:0] sec_inc;
  logic [29:0] ns_a;              // after the increment
  logic [31:0] ns_st;             // after the step, signed, before the wrap
  always_comb begin
    frac_sum = {1'b0, t_frac} + {1'b0, cfg_inc_frac};
    ns_inc   = {1'b0, t_ns} + {23'd0, cfg_inc_ns} + {30'd0, frac_sum[32]};
    sec_inc  = t_sec + {47'd0, ns_inc >= GIGA};
    ns_a     = ns_inc >= GIGA ? 30'(ns_inc - GIGA) : ns_inc[29:0];
    ns_st    = {2'b00, ns_a} + step_ns;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_sec <= '0; t_ns <= '0; t_frac <= '0; sec_tick <= 1'b0;
    end else begin
      sec_tick <= 1'b0;
      if (time_set) begin
        t_sec <= set_sec; t_ns <= set_ns > NS_MAX ? NS_MAX : set_ns; t_frac <= '0;
      end else begin
        t_frac <= frac_sum[31:0];
        if (time_step) begin
          if (ns_st[31]) begin                                  // negative: borrow a second
            t_ns <= 30'(ns_st + 32'(GIGA)); t_sec <= sec_inc - 48'd1;
          end else if (ns_st >= 32'(GIGA)) begin
            t_ns <= 30'(ns_st - 32'(GIGA)); t_sec <= sec_inc + 48'd1;
          end else begin
            t_ns <= ns_st[29:0]; t_sec <= sec_inc;
          end
        end else begin
          t_ns <= ns_a; t_sec <= sec_inc;
          sec_tick <= ns_inc >= GIGA;
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      snap_sec <= '0; snap_ns <= '0; pps <= 1'b0; target_armed <= 1'b0; target_hit <= 1'b0;
    end else begin
      if (snap) begin snap_sec <= t_sec; snap_ns <= t_ns; end
      pps <= pps_en && t_ns < pps_width_ns;
      target_hit <= 1'b0;
      if (target_arm) target_armed <= 1'b1;
      else if (target_disarm) target_armed <= 1'b0;
      else if (target_armed && (t_sec > target_sec || (t_sec == target_sec && t_ns >= target_ns))) begin
        target_armed <= 1'b0; target_hit <= 1'b1;
      end
    end
  end

  // ---------------- external event ----------------
  logic ev_s1, ev_s2, ev_s3;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ev_s1 <= 1'b0; ev_s2 <= 1'b0; ev_s3 <= 1'b0; evt_valid <= 1'b0; evt_sec <= '0; evt_ns <= '0;
    end else begin
      ev_s1 <= ext_evt; ev_s2 <= ev_s1; ev_s3 <= ev_s2;
      evt_valid <= ev_s2 && !ev_s3;
      if (ev_s2 && !ev_s3) begin evt_sec <= t_sec; evt_ns <= t_ns; end
    end
  end

  // ---------------- timestamp units ----------------
  PTP_tsu #(.FIFO_DEPTH(FIFO_DEPTH), .TX(0)) u_rx (
    .clk(clk), .rst_n(rst_n), .dv(rx_dv), .er(rx_er), .d(rxd), .t_sec(t_sec), .t_ns(t_ns),
    .lat(cfg_rx_lat_ns), .l2_en(cfg_l2_en), .ipv4_en(cfg_ipv4_en), .ipv6_en(cfg_ipv6_en),
    .q_valid(rxq_valid), .q_pop(rxq_pop), .q_type(rxq_type), .q_domain(rxq_domain),
    .q_seq(rxq_seq), .q_sec(rxq_sec), .q_ns(rxq_ns), .q_ovf(rxq_ovf));
  PTP_tsu #(.FIFO_DEPTH(FIFO_DEPTH), .TX(1)) u_tx (
    .clk(clk), .rst_n(rst_n), .dv(tx_en), .er(tx_er), .d(txd), .t_sec(t_sec), .t_ns(t_ns),
    .lat(cfg_tx_lat_ns), .l2_en(cfg_l2_en), .ipv4_en(cfg_ipv4_en), .ipv6_en(cfg_ipv6_en),
    .q_valid(txq_valid), .q_pop(txq_pop), .q_type(txq_type), .q_domain(txq_domain),
    .q_seq(txq_seq), .q_sec(txq_sec), .q_ns(txq_ns), .q_ovf(txq_ovf));
endmodule

// One direction: frame parser, FCS check and timestamp FIFO.
module PTP_tsu #(
  parameter int FIFO_DEPTH = 4,
  parameter bit TX = 0,                    // 1: the latency is added, 0: subtracted
  localparam int AW = $clog2(FIFO_DEPTH)
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        dv,
  input  logic        er,
  input  logic [7:0]  d,
  input  logic [47:0] t_sec,
  input  logic [29:0] t_ns,
  input  logic [15:0] lat,
  input  logic        l2_en,
  input  logic        ipv4_en,
  input  logic        ipv6_en,
  output logic        q_valid,
  input  logic        q_pop,
  output logic [3:0]  q_type,
  output logic [7:0]  q_domain,
  output logic [15:0] q_seq,
  output logic [47:0] q_sec,
  output logic [29:0] q_ns,
  output logic        q_ovf
);
  typedef enum logic [1:0] {P_IDLE, P_PRE, P_DATA, P_SKIP} pst_t;
  typedef enum logic [1:0] {K_NONE, K_L2, K_IPV4, K_IPV6} kind_t;
  pst_t        st;
  kind_t       kind;
  logic [10:0] idx;               // byte index from the destination address (saturates)
  logic [31:0] crc;
  logic        bad;               // an er byte
  logic [15:0] et;                // EtherType / TPID as it arrives
  logic [7:0]  l3;                // first byte of the IP header
  logic [7:0]  l4;                // first byte of the UDP header
  logic [7:0]  p0;                // first byte of the PTP header
  logic        p_known;           // a PTP header starts at p0
  logic [3:0]  m_type, m_ver;
  logic [7:0]  m_dom;
  logic [15:0] m_seq;
  logic [47:0] s_sec;             // SFD time
  logic [29:0] s_ns;

  function automatic logic [31:0] crc8(input logic [31:0] c, input logic [7:0] b);
    logic [31:0] x;
    x = c ^ {24'd0, b};
    for (int i = 0; i < 8; i++) x = {1'b0, x[31:1]} ^ (x[0] ? 32'hEDB8_8320 : 32'h0);
    crc8 = x;
  endfunction

  wire [10:0] i_l3 = {3'b0, l3};
  wire [10:0] i_l4 = {3'b0, l4};
  wire [10:0] i_p0 = {3'b0, p0};
  wire [10:0] nbytes = idx;                 // bytes received when dv drops
  wire        en_ok  = (kind == K_L2 && l2_en) || (kind == K_IPV4 && ipv4_en) || (kind == K_IPV6 && ipv6_en);
  wire        event_ok = p_known && en_ok && !bad && crc == 32'hDEBB_20E3 && nbytes >= 11'd64
                         && nbytes >= i_p0 + 11'd38 && m_type <= 4'd3 && m_ver == 4'd2;

  // timestamp with the latency
  logic [47:0] ts_sec;
  logic [29:0] ts_ns;
  always_comb begin
    if (TX) begin
      ts_ns  = s_ns + {14'd0, lat};
      ts_sec = s_sec;
      if ({1'b0, s_ns} + {15'd0, lat} > 31'd999_999_999) begin
        ts_ns  = 30'({1'b0, s_ns} + {15'd0, lat} - 31'd1_000_000_000);
        ts_sec = s_sec + 48'd1;
      end
    end else begin
      ts_ns  = s_ns - {14'd0, lat};
      ts_sec = s_sec;
      if (s_ns < {14'd0, lat}) begin
        ts_ns  = 30'({1'b0, s_ns} + 31'd1_000_000_000 - {15'd0, lat});
        ts_sec = s_sec - 48'd1;
      end
    end
  end

  // ---------------- FIFO ----------------
  logic [105:0] mem [0:FIFO_DEPTH-1];
  logic [AW:0]  wp, rp;
  wire          full  = (wp - rp) == (AW+1)'(FIFO_DEPTH) && !q_pop;   // a pop makes room
  wire          push  = st == P_DATA && !dv && event_ok;
  assign q_valid = wp != rp;
  assign {q_type, q_domain, q_seq, q_sec, q_ns} = q_valid ? mem[rp[AW-1:0]] : 106'd0;
  always_ff @(posedge clk) if (push && !full) mem[wp[AW-1:0]] <= {m_type, m_dom, m_seq, ts_sec, ts_ns};
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp <= '0; rp <= '0; q_ovf <= 1'b0;
    end else begin
      q_ovf <= push && full;
      if (push && !full) wp <= wp + 1'b1;
      if (q_pop && q_valid) rp <= rp + 1'b1;
    end
  end

  // ---------------- parser ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= P_IDLE; kind <= K_NONE; idx <= '0; crc <= '1; bad <= 1'b0; et <= '0;
      l3 <= 8'd14; l4 <= '0; p0 <= '0; p_known <= 1'b0;
      m_type <= '0; m_ver <= '0; m_dom <= '0; m_seq <= '0; s_sec <= '0; s_ns <= '0;
    end else begin
      case (st)
        P_IDLE, P_PRE:
          if (!dv) st <= P_IDLE;
          else if (d == 8'hD5) begin
            st <= P_DATA; s_sec <= t_sec; s_ns <= t_ns;
            idx <= '0; crc <= '1; bad <= 1'b0; kind <= K_NONE; l3 <= 8'd14; p_known <= 1'b0;
          end else if (d == 8'h55) st <= P_PRE;
          else st <= P_SKIP;
        P_SKIP: if (!dv) st <= P_IDLE;
        default: begin                                         // P_DATA
          if (!dv) st <= P_IDLE;
          else begin
            crc <= crc8(crc, d);
            if (er) bad <= 1'b1;
            if (idx != 11'h7FF) idx <= idx + 11'd1;
            et <= {et[7:0], d};
            // EtherType, after an optional 802.1Q tag
            if (idx == 11'd13 && {et[7:0], d} == 16'h8100) l3 <= 8'd18;
            if (idx == i_l3 - 11'd1) begin
              if ({et[7:0], d} == 16'h88F7) begin kind <= K_L2; p0 <= l3; p_known <= 1'b1; end
              else if ({et[7:0], d} == 16'h0800) kind <= K_IPV4;
              else if ({et[7:0], d} == 16'h86DD) begin kind <= K_IPV6; l4 <= l3 + 8'd40; end
            end
            // IPv4: version / IHL, not a fragment, UDP
            if (kind == K_IPV4) begin
              if (idx == i_l3) begin
                if (d[7:4] != 4'd4 || d[3:0] < 4'd5) kind <= K_NONE;
                l4 <= l3 + {2'b0, d[3:0], 2'b00};
              end
              if (idx == i_l3 + 11'd6 && (d[5] || d[4:0] != 5'd0)) kind <= K_NONE;   // MF, offset
              if (idx == i_l3 + 11'd7 && d != 8'd0) kind <= K_NONE;
              if (idx == i_l3 + 11'd9 && d != 8'd17) kind <= K_NONE;
            end
            // IPv6: version, next header UDP
            if (kind == K_IPV6) begin
              if (idx == i_l3 && d[7:4] != 4'd6) kind <= K_NONE;
              if (idx == i_l3 + 11'd6 && d != 8'd17) kind <= K_NONE;
            end
            // UDP destination port 319
            if ((kind == K_IPV4 || kind == K_IPV6) && idx == i_l4 + 11'd3 && idx > i_l3) begin
              if ({et[7:0], d} == 16'd319) begin p0 <= l4 + 8'd8; p_known <= 1'b1; end
            end
            // PTP header
            if (p_known) begin
              if (idx == i_p0) m_type <= d[3:0];
              if (idx == i_p0 + 11'd1) m_ver <= d[3:0];
              if (idx == i_p0 + 11'd4) m_dom <= d;
              if (idx == i_p0 + 11'd30) m_seq[15:8] <= d;
              if (idx == i_p0 + 11'd31) m_seq[7:0] <= d;
            end
          end
        end
      endcase
    end
  end
endmodule
