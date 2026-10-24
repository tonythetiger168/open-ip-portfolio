// SPDX-License-Identifier: Apache-2.0
// DSI host: a cycle-level model fed only by the pins (command port, payload
// RAM port, rx_bit) predicts every output on every clock: the serial lane
// (tx_bit / tx_valid / tx_oe) byte by byte for each packet of a command
// (SoT, DI, data / WC, ECC, payload, CRC-16 and the two idle gap clocks),
// the BTA trigger, the turn-around wait with its timeout, the response
// receiver (SoT check, header, ECC syndrome and single-bit correction found
// by searching the parity columns), cmd_busy, irq, bta_done / bta_data and
// pkt_cnt. Payload bytes are taken from the model RAM when the command is
// accepted (the RAM is not rewritten while a command is in flight).
`include "cov_macros.svh"
module DSI_sva #(
  parameter int BTA_TO = 512
)(
  input logic        clk, rst_n, irq, tx_bit, tx_valid, tx_oe, rx_bit,
  input logic        cmd_valid, cmd_busy, pl_we, bta_done,
  input logic [2:0]  cmd_op,
  input logic [5:0]  cmd_dt,
  input logic [7:0]  cmd_dcs, pl_wdata,
  input logic [15:0] cmd_len, cmd_len2, pkt_cnt,
  input logic [4:0]  pl_addr,
  input logic [23:0] bta_data
);
  `COV_CLOCKING(clk, !rst_n)

  function automatic logic [5:0] ecc(input logic [23:0] d);
    // parity i covers the data bits whose (index-dependent) column has bit i set
    logic [5:0] p;
    p = 6'h0;
    for (int k = 0; k < 24; k++) if (d[k]) p ^= colm(k);
    ecc = p;
  endfunction
  // MIPI header ECC column of data bit k
  function automatic logic [5:0] colm(input int k);
    logic [5:0] t [0:23];
    t = '{6'h07, 6'h0B, 6'h0D, 6'h0E, 6'h13, 6'h15, 6'h16, 6'h19, 6'h1A, 6'h1C, 6'h23, 6'h25,
          6'h26, 6'h29, 6'h2A, 6'h2C, 6'h31, 6'h32, 6'h34, 6'h38, 6'h1F, 6'h2F, 6'h37, 6'h3B};
    colm = t[k];
  endfunction
  function automatic logic [15:0] crc16(input logic [15:0] c, input logic [7:0] d);
    logic [15:0] v;
    v = c;
    for (int k = 0; k < 8; k++)
      v = (v[0] ^ d[k]) ? (v >> 1) ^ 16'h8408 : (v >> 1);
    crc16 = v;
  endfunction

  // ---------------- model state ----------------
  localparam int M_IDLE = 0, M_TX = 1, M_WAIT = 2, M_RX = 3;
  int          mode, np, pi, bi, bt, gp, to, rbits, rby;
  logic [7:0]  ram [0:31];
  logic [7:0]  snap [0:31];
  logic [5:0]  p_dt [0:3];
  logic [15:0] p_d [0:3];
  logic        p_long [0:3], p_zero [0:3], rd, trig;
  logic [15:0] crc, m_cnt;
  logic [7:0]  cur, rsh;
  logic [7:0]  rhdr [0:3];
  logic        m_bit, m_valid, m_oe, m_busy, m_irq, m_done;
  logic [23:0] m_data;
  // coverage events
  logic v_rej_op, v_rej_len, v_rej_px, v_ignored, v_spkt, v_s0, v_s1, v_long0, v_long32, v_vline,
        v_rd, v_clean, v_corr_d, v_corr_p, v_uncorr, v_badsot, v_timeout, v_ackerr, v_ackok,
        v_wrap, v_hbp_big;

  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  logic c_bv, c_cv;
  int   c_op;
  logic [7:0] c_b;

  function automatic int plen(input int p);   // bytes in packet p incl. SoT, ECC, CRC
    plen = p_long[p] ? 5 + p_d[p] + 2 : 5;
  endfunction
  function automatic logic [7:0] pbyte(input int p, input int j, input logic [15:0] c);
    if (j == 0)      pbyte = 8'hB8;
    else if (j == 1) pbyte = {2'b00, p_dt[p]};
    else if (j == 2) pbyte = p_d[p][7:0];
    else if (j == 3) pbyte = p_d[p][15:8];
    else if (j == 4) pbyte = {2'b00, ecc({p_d[p], 2'b00, p_dt[p]})};
    else if (!p_long[p] || j < 5) pbyte = 8'h00;
    else if (j < 5 + p_d[p]) pbyte = p_zero[p] ? 8'h00 : snap[j - 5];
    else if (j == 5 + p_d[p]) pbyte = c[7:0];
    else             pbyte = c[15:8];
  endfunction

  always @(posedge clk or negedge rst_n) begin
    logic [23:0] h, fx;
    logic [5:0]  syn;
    int          k;
    if (!rst_n) begin
      mode = M_IDLE; np = 0; pi = 0; bi = 0; bt = 0; gp = 0; to = 0; rbits = 0; rby = 0;
      rd = 0; trig = 0; crc = 16'hFFFF; m_cnt = 0; cur = 0; rsh = 0;
      m_bit = 1; m_valid = 0; m_oe = 1; m_busy = 0; m_irq = 0; m_done = 0; m_data = 0;
      {v_rej_op, v_rej_len, v_rej_px, v_ignored, v_spkt, v_s0, v_s1, v_long0, v_long32, v_vline,
       v_rd, v_clean, v_corr_d, v_corr_p, v_uncorr, v_badsot, v_timeout, v_ackerr, v_ackok,
       v_wrap, v_hbp_big} = '0;
    end else begin
      {v_rej_op, v_rej_len, v_rej_px, v_ignored, v_spkt, v_s0, v_s1, v_long0, v_long32, v_vline,
       v_rd, v_clean, v_corr_d, v_corr_p, v_uncorr, v_badsot, v_timeout, v_ackerr, v_ackok,
       v_wrap, v_hbp_big} = '0;
      m_irq = 0; m_done = 0;
      c_bv = 0; c_cv = 0;
      if (cmd_valid && mode != M_IDLE) v_ignored = 1;
      case (mode)
        M_IDLE: begin
          m_valid = 0; m_oe = 1; m_bit = 1;
          if (cmd_valid) begin
            if (cmd_op > 5) begin m_irq = 1; v_rej_op = 1; end
            else if ((cmd_op == 3 || cmd_op == 4) && cmd_len > 32) begin m_irq = 1; v_rej_len = 1; end
            else if (cmd_op == 4 && cmd_len % 3 != 0) begin m_irq = 1; v_rej_px = 1; end
            else begin
              for (int i = 0; i < 32; i++) snap[i] = ram[i];
              for (int i = 0; i < 4; i++) begin p_long[i] = 0; p_zero[i] = 0; p_d[i] = 0; end
              rd = (cmd_op == 5); np = 1;
              c_cv = 1; c_op = cmd_op;
              case (cmd_op)
                0: begin p_dt[0] = cmd_dt; p_d[0] = cmd_len; v_spkt = 1; end
                1: begin p_dt[0] = 6'h05; p_d[0] = {8'h00, cmd_dcs}; v_s0 = 1; end
                2: begin p_dt[0] = 6'h15; p_d[0] = {ram[0], cmd_dcs}; v_s1 = 1; end
                3: begin
                  p_dt[0] = 6'h39; p_d[0] = cmd_len; p_long[0] = 1;
                  v_long0 = (cmd_len == 0); v_long32 = (cmd_len == 32);
                end
                4: begin
                  np = 4; v_vline = 1; v_hbp_big = (cmd_len2 > 1000);
                  p_dt[0] = 6'h21; p_dt[1] = 6'h31;
                  p_dt[2] = 6'h19; p_d[2] = cmd_len2; p_long[2] = 1; p_zero[2] = 1;
                  p_dt[3] = 6'h3E; p_d[3] = cmd_len;  p_long[3] = 1;
                end
                default: begin p_dt[0] = 6'h06; p_d[0] = {8'h00, cmd_dcs}; v_rd = 1; end
              endcase
              mode = M_TX; pi = 0; bi = 0; bt = 0; gp = 0; trig = 0; crc = 16'hFFFF;
              cur = 8'hB8; m_busy = 1;
            end
          end
        end
        M_TX: begin
          if (gp > 0) begin                         // inter-packet idle clocks
            m_valid = 0; m_bit = 1;
            if (gp == 2) begin
              gp = 0;
              if (pi + 1 < np) begin pi++; bi = 0; bt = 0; crc = 16'hFFFF; cur = 8'hB8; end
              else if (rd) begin trig = 1; bt = 0; cur = 8'h84; end
              else begin mode = M_IDLE; m_busy = 0; end
            end else gp++;
          end else begin
            m_valid = 1; m_bit = cur[bt];
            if (bt == 7) begin
              bt = 0;
              if (trig) begin mode = M_WAIT; to = 0; end
              else begin
                if (bi >= 5 && bi < 5 + p_d[pi] && p_long[pi]) begin
                  crc = crc16(crc, cur);
                  if (!p_zero[pi] && bi > 5) begin c_bv = 1; c_b = cur; end
                end
                bi++;
                if (bi == plen(pi)) begin gp = 1; m_cnt++; if (m_cnt == 0) v_wrap = 1; end
                else cur = pbyte(pi, bi, crc);
              end
            end else bt++;
          end
        end
        M_WAIT: begin
          m_valid = 0; m_oe = 0;
          if (!rx_bit) begin mode = M_RX; rsh = 8'h00; rbits = 1; rby = 0; end
          else if (to == BTA_TO) begin
            m_irq = 1; mode = M_IDLE; m_oe = 1; m_busy = 0; v_timeout = 1;
          end else to++;
        end
        default: begin                              // M_RX
          rsh[rbits] = rx_bit;
          if (rbits == 7) begin
            rbits = 0;
            if (rby == 0 && rsh != 8'hB8) begin
              m_irq = 1; mode = M_IDLE; m_oe = 1; m_busy = 0; v_badsot = 1;
            end else if (rby < 4) begin
              rhdr[rby] = rsh; rby++;
            end else begin
              mode = M_IDLE; m_oe = 1; m_busy = 0;
              h = {rhdr[3], rhdr[2], rhdr[1]};
              syn = rsh[5:0] ^ ecc(h);
              k = -1;
              for (int j = 0; j < 24; j++) if (syn == colm(j)) k = j;
              for (int j = 0; j < 6; j++) if (syn == 6'(1 << j)) k = 24 + j;
              if (syn == 0 || k >= 0) begin
                fx = (k >= 0 && k < 24) ? h ^ (24'h1 << k) : h;
                m_data = fx; m_done = 1;
                if (syn == 0) v_clean = 1; else if (k < 24) v_corr_d = 1; else v_corr_p = 1;
                if (fx[7:0] == 8'h02) begin
                  if (fx[23:8] != 0) begin m_irq = 1; v_ackerr = 1; end
                  else v_ackok = 1;
                end
              end else begin m_irq = 1; v_uncorr = 1; end
            end
          end else rbits++;
        end
      endcase
      if (pl_we) ram[pl_addr] = pl_wdata;
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_outputs, !rst_n,
           !tx_valid && tx_oe && tx_bit && !cmd_busy && !irq && !bta_done && pkt_cnt == 0 &&
           bta_data == 0)
  `SVA_INV(a_tx_bit, tx_bit == m_bit)
  `SVA_INV(a_tx_valid, tx_valid == m_valid)
  `SVA_INV(a_tx_oe, tx_oe == m_oe)
  `SVA_INV(a_cmd_busy, cmd_busy == m_busy)
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_INV(a_bta_done, bta_done == m_done)
  `SVA_INV(a_bta_data, bta_data == m_data)
  `SVA_INV(a_pkt_cnt, pkt_cnt == m_cnt)
  `SVA_IMP(a_valid_only_when_owned, tx_valid, tx_oe)
  `SVA_NXT(a_rejected_command_stays_idle, !cmd_busy && cmd_valid && cmd_op > 3'd5, !cmd_busy && irq)

  function automatic int dcls(input logic [15:0] v, input int w);
    logic [15:0] m;
    m = w == 8 ? 16'h00FF : 16'hFFFF;
    v &= m;
    return v == 0 ? 0 : v == m ? 1 : (v == (16'h5555 & m) || v == (16'hAAAA & m)) ? 2 : 3;
  endfunction
  // commands taken, long-packet payload bytes (after the DCS byte), read
  // responses by data type and data
  covergroup cg_dsi @(negedge clk);
    option.per_instance = 1;
    cp_op: coverpoint c_op iff (rst_n && c_cv)
      { bins spkt = {0}; bins dcs_s0 = {1}; bins dcs_s1 = {2}; bins dcs_long = {3}; bins vline = {4}; bins dcs_read = {5}; }
    cp_pay: coverpoint dcls({8'h00, c_b}, 8) iff (rst_n && c_bv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rsp: coverpoint bta_data[7:0] iff (rst_n && bta_done)
      { bins ack_err = {8'h02}; bins read1 = {8'h21}; bins read2 = {8'h22};
        bins other = {[8'h00:8'h01], [8'h03:8'h20], [8'h23:8'hFF]}; }
    cp_rdata: coverpoint dcls(bta_data[23:8], 16) iff (rst_n && bta_done && (bta_data[7:0] == 8'h21 || bta_data[7:0] == 8'h22))
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_dsi u_cg_dsi = new;

  // ---------------- functional coverage ----------------
  `FC(raw_short_packet, v_spkt)
  `FC(dcs_short_write_0, v_s0)
  `FC(dcs_short_write_1, v_s1)
  `FC(dcs_long_write_empty, v_long0)
  `FC(dcs_long_write_full_ram, v_long32)
  `FC(video_line, v_vline)
  `FC(video_line_long_blanking, v_hbp_big)
  `FC(dcs_read, v_rd)
  `FC(rejected_invalid_op, v_rej_op)
  `FC(rejected_payload_too_long, v_rej_len)
  `FC(rejected_partial_pixel, v_rej_px)
  `FC(command_while_busy_ignored, v_ignored)
  `FC(bta_clean_response, v_clean)
  `FC(bta_data_bit_corrected, v_corr_d)
  `FC(bta_parity_bit_corrected, v_corr_p)
  `FC(bta_uncorrectable, v_uncorr)
  `FC(bta_bad_sot, v_badsot)
  `FC(bta_timeout, v_timeout)
  `FC(bta_ack_error_report, v_ackerr)
  `FC(bta_ack_no_error, v_ackok)
  `FC(bta_answer_near_timeout, mode == M_WAIT && to > BTA_TO - 8 && !rx_bit)
  `FC(pkt_cnt_wrap, v_wrap)
  `FC_RST(reset_mid_packet, rst_n && tx_valid ##1 !rst_n)
  `FC_RST(reset_mid_bta, rst_n && !tx_oe ##1 !rst_n)
endmodule

bind DSI_top DSI_sva #(.BTA_TO(BTA_TO)) u_sva (.*);
