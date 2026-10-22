// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Ethernet_AVB_TSN_top v2.0: TSN egress transmission selection for one
// port with 4 traffic classes: IEEE 802.1Qbv time-aware gates, 802.1Qav
// credit-based shapers, strict priority, a PTP time counter and egress
// timestamps
// ----------------------------------------------------------------------------
//  - Line: one byte per clk. A frame of L bytes occupies the line for
//    L + 20 clocks (preamble + SFD 8, inter-frame gap 12). The MAC is told
//    which frame to send (tx_start, tx_tc, tx_len, tx_ts); the queues show
//    their head frame (q_valid[c], q_len[c]) and get q_pop[c] when it is
//    taken.
//  - Time: {time_ns, 16-bit fraction} advances by {cfg_inc_ns,
//    cfg_inc_frac} every clk; time_set loads time_set_ns (fraction 0);
//    time_adj adds the signed time_adj_ns. tx_ts = time_ns in the clock
//    the frame is selected.
//  - Gate control list (802.1Qbv): entries 0..gcl_last of {gates[3:0],
//    interval ns}, written through gcl_we / gcl_waddr (write while
//    gcl_en = 0). With gcl_en the schedule starts in the first clock with
//    time_ns >= gcl_base and then runs in elapsed time (cfg_inc_ns per
//    clk; time_set / time_adj do not move it): entry k lasts its interval,
//    the last entry lasts until the cycle ends, a cycle lasts gcl_cycle ns
//    (entries beyond it are cut). Gate changes and cycle starts happen in
//    the first clock at or after their time; the remainder is carried.
//    Without gcl_en, and before the schedule starts, every gate is open.
//    Intervals and the cycle must be at least cfg_inc_ns.
//  - Guard band: while the schedule runs, a frame of class c starts only
//    if gate c stays open for its whole line time (L + 20) * cfg_inc_ns,
//    counted from now to the next close of gate c or the end of the cycle,
//    whichever is first (a frame never crosses a cycle boundary).
//  - Credit-based shaper (802.1Qav), per class with cbs_en[c]: credit
//    (20-bit signed, saturating, units 1/256 byte) changes every clock by
//    cbs_idle[c] - 256 while class c transmits; by cbs_idle[c] while a
//    frame waits and the gate is open; it is held while a frame waits
//    behind a closed gate; with no frame queued, a positive credit drops
//    to 0 and a negative one rises by cbs_idle[c] up to 0. A class is
//    eligible only with credit >= 0. Without cbs_en[c] the credit is 0.
//  - Selection: when the line is free, the highest class with a frame
//    that passes its gate, guard band and shaper starts.
//  Not implemented: frame preemption (802.1Qbu), per-stream filtering,
//  gate-list switching at a config change time, hold/release, PTP message
//  handling (timestamps only), more than 4 classes.
// ============================================================================
module Ethernet_AVB_TSN_top (
  input  logic        clk,
  input  logic        rst_n,
  // time
  input  logic [7:0]  cfg_inc_ns,
  input  logic [15:0] cfg_inc_frac,
  input  logic        time_set,
  input  logic [63:0] time_set_ns,
  input  logic        time_adj,
  input  logic [31:0] time_adj_ns,
  output logic [63:0] time_ns,
  // gate control list
  input  logic        gcl_en,
  input  logic [63:0] gcl_base,
  input  logic [23:0] gcl_cycle,
  input  logic [2:0]  gcl_last,
  input  logic        gcl_we,
  input  logic [2:0]  gcl_waddr,
  input  logic [3:0]  gcl_wgates,
  input  logic [23:0] gcl_wivl,
  // credit-based shapers
  input  logic [3:0]  cbs_en,
  input  logic [35:0] cbs_idle,      // class c: [9c+8:9c], 0..256 (/256 of the line rate)
  // queues
  input  logic [3:0]  q_valid,
  input  logic [43:0] q_len,         // class c: [11c+10:11c], frame bytes
  output logic [3:0]  q_pop,
  // transmission
  output logic        tx_start,
  output logic [1:0]  tx_tc,
  output logic [10:0] tx_len,
  output logic [63:0] tx_ts,
  output logic        tx_busy,
  // status
  output logic        gcl_running,
  output logic [2:0]  gcl_entry,
  output logic [3:0]  gate_state,
  output logic        cycle_start,
  output logic [79:0] cbs_credit     // class c: [20c+19:20c]
);
  // ---------------- time ----------------
  logic [15:0] t_frac;
  wire  [16:0] frac_sum = {1'b0, t_frac} + {1'b0, cfg_inc_frac};
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin time_ns <= '0; t_frac <= '0; end
    else if (time_set) begin time_ns <= time_set_ns; t_frac <= '0; end
    else begin
      t_frac  <= frac_sum[15:0];
      time_ns <= time_ns + {56'd0, cfg_inc_ns} + {63'd0, frac_sum[16]}
                 + (time_adj ? {{32{time_adj_ns[31]}}, time_adj_ns} : 64'd0);
    end

  // ---------------- gate control list ----------------
  logic [3:0]  g_gates [0:7];
  logic [23:0] g_ivl   [0:7];
  logic [23:0] cyc_el, ent_el;          // ns into the cycle / the entry
  logic        ent_done;                // the last entry's interval is over
  wire  [24:0] cyc_nx = {1'b0, cyc_el} + {17'd0, cfg_inc_ns};
  wire  [24:0] ent_nx = {1'b0, ent_el} + {17'd0, cfg_inc_ns};
  wire  [23:0] ivl_cur = g_ivl[gcl_entry];
  assign gate_state = gcl_running ? g_gates[gcl_entry] : 4'hF;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int k = 0; k < 8; k++) begin g_gates[k] <= '0; g_ivl[k] <= '0; end
    end else if (gcl_we) begin
      g_gates[gcl_waddr] <= gcl_wgates; g_ivl[gcl_waddr] <= gcl_wivl;
    end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      gcl_running <= 1'b0; gcl_entry <= '0; cyc_el <= '0; ent_el <= '0; ent_done <= 1'b0;
      cycle_start <= 1'b0;
    end else begin
      cycle_start <= 1'b0;
      if (!gcl_en) gcl_running <= 1'b0;
      else if (!gcl_running) begin
        if (time_ns >= gcl_base) begin
          gcl_running <= 1'b1; gcl_entry <= '0; cyc_el <= '0; ent_el <= '0; ent_done <= 1'b0;
          cycle_start <= 1'b1;
        end
      end else if (cyc_nx >= {1'b0, gcl_cycle}) begin
        cyc_el <= 24'(cyc_nx - {1'b0, gcl_cycle});
        ent_el <= 24'(cyc_nx - {1'b0, gcl_cycle});
        gcl_entry <= '0; ent_done <= 1'b0; cycle_start <= 1'b1;
      end else begin
        cyc_el <= cyc_nx[23:0];
        if (!ent_done) begin
          if (ent_nx >= {1'b0, ivl_cur}) begin
            if (gcl_entry == gcl_last) ent_done <= 1'b1;
            else begin gcl_entry <= gcl_entry + 3'd1; ent_el <= 24'(ent_nx - {1'b0, ivl_cur}); end
          end else ent_el <= ent_nx[23:0];
        end
      end
    end

  // time until gate c closes (or the cycle ends), ns
  wire [23:0] cyc_rem = gcl_cycle - cyc_el;
  logic [23:0] ttc [0:3];
  always_comb begin
    for (int c = 0; c < 4; c++) begin : b_ttc
      logic        open;
      logic [26:0] t;
      open = 1'b1; t = '0;
      for (int k = 0; k < 8; k++)
        if (open && k >= {29'd0, gcl_entry} && k <= {29'd0, gcl_last}) begin
          if (!g_gates[k][c]) open = 1'b0;
          else if (k == {29'd0, gcl_entry}) t = {3'd0, g_ivl[k] - ent_el};
          else t = t + {3'd0, g_ivl[k]};
        end
      // open through the last entry: open until the cycle ends
      ttc[c] = (open || t >= {3'd0, cyc_rem}) ? cyc_rem : t[23:0];
    end
  end

  // ---------------- shapers and selection ----------------
  logic signed [19:0] credit [0:3];
  logic [11:0] busy_cnt;
  logic [3:0]  elig;
  always_comb begin
    for (int c = 0; c < 4; c++) begin : b_elig
      logic [19:0] ft;                    // line time, ns
      ft = ({9'd0, q_len[11*c +: 11]} + 20'd20) * {12'd0, cfg_inc_ns};
      elig[c] = q_valid[c] && gate_state[c] && (!gcl_running || ttc[c] >= {4'd0, ft})
                && (!cbs_en[c] || !credit[c][19]);
    end
  end
  always_comb begin
    for (int c = 0; c < 4; c++) cbs_credit[20*c +: 20] = credit[c];
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int c = 0; c < 4; c++) credit[c] <= '0;
      busy_cnt <= '0; tx_busy <= 1'b0; tx_start <= 1'b0; tx_tc <= '0; tx_len <= '0; tx_ts <= '0;
      q_pop <= '0;
    end else begin
      tx_start <= 1'b0; q_pop <= '0;
      // shapers
      for (int c = 0; c < 4; c++) begin : b_cbs
        logic signed [21:0] n;
        logic [8:0] idle;
        idle = cbs_idle[9*c +: 9];
        n = {{2{credit[c][19]}}, credit[c]};
        if (tx_busy && tx_tc == 2'(c)) n = n + 22'(idle) - 22'd256;
        else if (q_valid[c] && gate_state[c]) n = n + 22'(idle);
        else if (!q_valid[c]) begin
          if (!n[21] && n != 0) n = '0;
          else if (n[21]) begin n = n + 22'(idle); if (!n[21]) n = '0; end
        end
        if (!cbs_en[c]) credit[c] <= '0;
        else if (n > 22'sd524287) credit[c] <= 20'sd524287;
        else if (n < -22'sd524288) credit[c] <= -20'sd524288;
        else credit[c] <= n[19:0];
      end
      // line
      // the next frame may be selected in the frame's last line clock
      if (tx_busy && busy_cnt != 12'd1) busy_cnt <= busy_cnt - 12'd1;
      else if (!(|elig)) tx_busy <= 1'b0;
      else begin : b_sel
        logic [1:0] w;
        w = elig[3] ? 2'd3 : elig[2] ? 2'd2 : elig[1] ? 2'd1 : 2'd0;
        tx_start <= 1'b1; tx_tc <= w; tx_len <= q_len[11*w +: 11]; tx_ts <= time_ns;
        q_pop[w] <= 1'b1; tx_busy <= 1'b1; busy_cnt <= {1'b0, q_len[11*w +: 11]} + 12'd20;
      end
    end
endmodule
