// SPDX-License-Identifier: Apache-2.0
// SD host: a bit-level model of the host's job (init CMD0 / CMD8 / ACMD41
// polling / CMD2 / CMD3 / CMD7, then rounds of CMD24 write + CMD17 read-back
// + CMD13) built from the bus. It runs its own sd_clk divider, decodes every
// card response and 4-bit data block with its own CRC7 / per-line CRC16,
// judges each one (framing, index, CRC, R7 contents, card-status and R6
// error bits, CRC status token, busy, timeouts, read-back compare), and
// predicts sd_clk, the host's CMD and DAT drivers (enable and value), every
// irq pulse, the captured CID / RCA / CCS and the round / match counters.
`include "cov_macros.svh"
module SD_sva #(parameter int SD_CLK_DIV = 4) (
  input logic         clk, rst_n, sd_clk, cmd, irq,
  input logic [3:0]   dat,
  input logic         cmd_oe_r, cmd_out_r, dat_oe_r,
  input logic [3:0]   dat_out_r,
  input logic [127:0] cid,
  input logic [15:0]  rca,
  input logic         ccs,
  input logic [7:0]   round, match_cnt
);
  `COV_CLOCKING(clk, !rst_n)

  function automatic logic [6:0] crc7(input logic [119:0] d, input int n);
    logic [6:0] c = 0;
    for (int i = 119; i >= 0; i--) if (i < n) c = {c[5:0], 1'b0} ^ ((d[i] ^ c[6]) ? 7'h09 : 7'h00);
    return c;
  endfunction
  function automatic logic [15:0] c16(input logic [15:0] c, input logic b);
    return {c[14:0], 1'b0} ^ ((c[15] ^ b) ? 16'h1021 : 16'h0);
  endfunction
  function automatic logic [47:0] frame(input logic [5:0] idx, input logic [31:0] arg);
    return {2'b01, idx, arg, crc7({80'h0, 2'b01, idx, arg}, 40), 1'b1};
  endfunction
  function automatic logic [255:0] blk(input logic [7:0] r);
    for (int i = 0; i < 8; i++)
      blk[255 - i * 32 -: 32] = 32'hA500_3C00 ^ {24'h0, r} ^ ({24'h0, 8'(i)} * 32'h0001_0101);
  endfunction

  // own sd_clk divider
  int   bd;
  logic m_sdclk;
  wire  tk = bd == SD_CLK_DIV - 1;

  // host activity
  localparam int TX = 0, GAP = 1, HUNT = 2, RSP = 3, IDLE = 4, WST = 5, WDAT = 6, WCRC = 7, WEND = 8,
                 TOKW = 9, TOK = 10, BUSY = 11, BGAP = 12, RHUNT = 13, RDAT = 14, RCRC = 15, REND = 16;
  int           ph, n, w, len;
  logic [5:0]   cc;
  logic [47:0]  fr;
  logic [135:0] rs;
  logic [255:0] db;
  logic [15:0]  crc [4], crx [4];
  logic [2:0]   tk3;
  logic         init, m_coe, m_co, m_doe, m_irq, m_ccs;
  logic [3:0]   m_do;
  logic [127:0] m_cid;
  logic [15:0]  m_rca;
  logic [7:0]   m_round, m_match;

  wire  [135:0] rn  = {rs[134:0], cmd};
  wire          r1f = !rn[46] && rn[45:40] == cc && rn[0] && crc7({80'h0, rn[47:8]}, 40) == rn[7:1];
  wire          r1e = (rn[39:8] & 32'hFDF9_8008) != 0;
  wire          r6e = (rn[23:8] & 16'hE008) != 0;
  wire          r7c = rn[19:16] == 4'h1 && rn[15:8] == 8'hAA;
  wire          r3f = !rn[46] && rn[45:40] == 6'h3F && rn[7:0] == 8'hFF;
  wire          r2f = !rn[134] && rn[133:128] == 6'h3F && crc7(rn[127:8], 120) == rn[7:1] && rn[0];
  wire  [31:0]  barg = m_ccs ? {30'h0, m_round[1:0]} : {25'h0, m_round[1:0], 5'h0};
  logic         rcrc_ok;
  always_comb begin
    rcrc_ok = 1;
    for (int k = 0; k < 4; k++) if (crx[k] != crc[k]) rcrc_ok = 0;
  end

  // coverage strobes
  logic v_poll, v_r3bad, v_r2bad, v_r1crc, v_r1idx, v_r1end, v_r1tx, v_stat, v_r6stat, v_r7v, v_r7p,
        v_rto, v_tokbad, v_tokto, v_busyto, v_busy, v_rdto, v_rcrc, v_rend, v_cmp, v_round;
  logic [5:0] v_where;    // which command an error hit

  task automatic issue(input logic [5:0] idx, input logic [31:0] arg, input int l);
    ph <= TX; n <= 0; fr <= frame(idx, arg); cc <= idx; len <= l; m_coe <= 1; w <= 0;
  endtask
  task automatic fail();
    m_irq <= 1;
    if (init) begin ph <= IDLE; w <= 0; end else issue(6'd0, 0, 0);
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bd <= 0; m_sdclk <= 0;
      init <= 0; m_coe <= 1; m_co <= 1; m_doe <= 0; m_do <= 4'hF; m_irq <= 0; m_ccs <= 0;
      m_cid <= 0; m_rca <= 0; m_round <= 0; m_match <= 0;
      ph <= TX; n <= 0; w <= 0; fr <= frame(6'd0, 0); cc <= 0; len <= 0;
      rs <= 0; db <= 0; tk3 <= 0;
      for (int k = 0; k < 4; k++) begin crc[k] <= 0; crx[k] <= 0; end
      {v_poll, v_r3bad, v_r2bad, v_r1crc, v_r1idx, v_r1end, v_r1tx, v_stat, v_r6stat, v_r7v, v_r7p,
       v_rto, v_tokbad, v_tokto, v_busyto, v_busy, v_rdto, v_rcrc, v_rend, v_cmp, v_round} <= '0;
      v_where <= 0;
    end else begin
      bd <= tk ? 0 : bd + 1;
      if (tk) m_sdclk <= 1; else if (bd == SD_CLK_DIV / 2 - 1) m_sdclk <= 0;
      {v_poll, v_r3bad, v_r2bad, v_r1crc, v_r1idx, v_r1end, v_r1tx, v_stat, v_r6stat, v_r7v, v_r7p,
       v_rto, v_tokbad, v_tokto, v_busyto, v_busy, v_rdto, v_rcrc, v_rend, v_cmp, v_round} <= '0;
      if (tk) begin
        m_irq <= 0;
        case (ph)
          TX: begin
            m_co <= fr[47 - n]; n <= n + 1;
            if (n == 47) begin ph <= GAP; w <= 0; end
          end
          GAP: begin
            m_coe <= 0; w <= w + 1;
            if (len == 0) begin if (w == 7) issue(6'd8, 32'h1AA, 48); end
            else if (w == 3) begin ph <= HUNT; w <= 0; end
          end
          HUNT:
            if (!cmd) begin ph <= RSP; n <= 1; rs <= 0; end
            else if (w == 63) begin fail(); v_rto <= 1; v_where <= cc; end
            else w <= w + 1;
          RSP: begin
            rs <= rn; n <= n + 1;
            if (n == len - 1) begin
              v_where <= cc;
              case (cc)
                6'd41:
                  if (!r3f) begin fail(); v_r3bad <= 1; end
                  else if (rn[39]) begin m_ccs <= rn[38]; issue(6'd2, 0, 136); end
                  else begin issue(6'd55, 0, 48); v_poll <= 1; end
                6'd2:
                  if (!r2f) begin fail(); v_r2bad <= 1; end
                  else begin m_cid <= rn[127:0]; issue(6'd3, 0, 48); end
                default: begin
                  v_r1crc <= crc7({80'h0, rn[47:8]}, 40) != rn[7:1]; v_r1idx <= rn[45:40] != cc;
                  v_r1end <= !rn[0]; v_r1tx <= rn[46];
                  if (!r1f) fail();
                  else if (cc == 6'd8) begin
                    if (!r7c) begin fail(); v_r7v <= rn[19:16] != 4'h1; v_r7p <= rn[15:8] != 8'hAA; end
                    else issue(6'd55, 0, 48);
                  end else if (cc == 6'd3) begin
                    if (r6e) begin fail(); v_r6stat <= 1; end
                    else begin m_rca <= rn[39:24]; issue(6'd7, {rn[39:24], 16'h0}, 48); end
                  end
                  else if (r1e) begin fail(); v_stat <= 1; end
                  else if (cc == 6'd55) issue(6'd41, 32'h40FF_8000, 48);
                  else if (cc == 6'd7) begin init <= 1; ph <= IDLE; w <= 0; end
                  else if (cc == 6'd24) begin
                    ph <= WST; m_doe <= 1; m_do <= 4'hF; db <= blk(m_round); n <= 0;
                    for (int k = 0; k < 4; k++) crc[k] <= 0;
                  end else if (cc == 6'd17) begin
                    ph <= RHUNT; w <= 0;
                    for (int k = 0; k < 4; k++) crc[k] <= 0;
                  end else begin
                    m_match <= m_match + 1; m_round <= m_round + 1; ph <= IDLE; w <= 0; v_round <= 1;
                  end
                end
              endcase
            end
          end
          IDLE: begin w <= w + 1; if (w == 7) issue(6'd24, barg, 48); end
          WST: begin m_do <= 4'h0; ph <= WDAT; end
          WDAT: begin
            m_do <= db[255 - 4 * n -: 4];
            for (int k = 0; k < 4; k++) crc[k] <= c16(crc[k], db[255 - 4 * n - (3 - k)]);
            n <= n + 1;
            if (n == 63) begin ph <= WCRC; n <= 0; end
          end
          WCRC: begin
            m_do <= {crc[3][15 - n], crc[2][15 - n], crc[1][15 - n], crc[0][15 - n]};
            n <= n + 1; if (n == 15) ph <= WEND;
          end
          WEND: begin m_do <= 4'hF; ph <= TOKW; w <= 0; end
          TOKW: begin
            m_doe <= 0;
            if (!dat[0]) begin ph <= TOK; n <= 1; end
            else if (w == 63) begin fail(); v_tokto <= 1; end
            else w <= w + 1;
          end
          TOK: begin
            tk3 <= {tk3[1:0], dat[0]}; n <= n + 1;
            if (n == 4) begin
              if ({tk3, dat[0]} == 4'b0101) begin ph <= BUSY; w <= 0; end
              else begin fail(); v_tokbad <= 1; end
            end
          end
          BUSY:
            if (dat[0]) begin ph <= BGAP; w <= 0; v_busy <= w > 0; end
            else if (w == 63) begin fail(); v_busyto <= 1; end
            else w <= w + 1;
          BGAP: begin w <= w + 1; if (w == 5) issue(6'd17, barg, 48); end
          RHUNT:
            if (dat == 4'h0) begin ph <= RDAT; n <= 0; end
            else if (w == 63) begin fail(); v_rdto <= 1; end
            else w <= w + 1;
          RDAT: begin
            db <= {db[251:0], dat};
            for (int k = 0; k < 4; k++) crc[k] <= c16(crc[k], dat[k]);
            n <= n + 1;
            if (n == 63) begin ph <= RCRC; n <= 0; end
          end
          RCRC: begin
            for (int k = 0; k < 4; k++) crx[k] <= {crx[k][14:0], dat[k]};
            n <= n + 1; if (n == 15) ph <= REND;
          end
          REND:
            if (dat != 4'hF || !rcrc_ok) begin fail(); v_rcrc <= !rcrc_ok; v_rend <= dat != 4'hF; end
            else if (db != blk(m_round)) begin fail(); v_cmp <= 1; end
            else issue(6'd13, {m_rca, 16'h0}, 48);
          default: ;
        endcase
      end
    end
  end

  `SVA_RST(a_reset_state, !rst_n, cmd_oe_r && cmd_out_r && !dat_oe_r && !irq && !sd_clk)
  `SVA_INV(a_sd_clk, sd_clk == m_sdclk)
  `SVA_INV(a_cmd_driver, cmd_oe_r == m_coe && (!m_coe || cmd_out_r == m_co))
  `SVA_INV(a_dat_driver, dat_oe_r == m_doe && (!m_doe || dat_out_r == m_do))
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_INV(a_card_identity, cid == m_cid && rca == m_rca && ccs == m_ccs)
  `SVA_INV(a_round_and_matches, round == m_round && match_cnt == m_match)

  `FC(acmd41_busy_poll, v_poll)
  `FC(r3_malformed, v_r3bad)
  `FC(r2_bad, v_r2bad)
  `FC(r1_crc_error, v_r1crc)
  `FC(r1_index_mismatch, v_r1idx)
  `FC(r1_end_bit_error, v_r1end)
  `FC(r1_transmission_bit_error, v_r1tx)
  `FC(r7_voltage_mismatch, v_r7v)
  `FC(r7_pattern_mismatch, v_r7p)
  `FC(r6_status_error, v_r6stat)
  `FC(r1_status_error_cmd55, v_stat && v_where == 55)
  `FC(r1_status_error_cmd7, v_stat && v_where == 7)
  `FC(r1_status_error_cmd24, v_stat && v_where == 24)
  `FC(r1_status_error_cmd17, v_stat && v_where == 17)
  `FC(r1_status_error_cmd13, v_stat && v_where == 13)
  `FC(response_timeout_init, v_rto && !init)
  `FC(response_timeout_cmd24, v_rto && v_where == 24)
  `FC(response_timeout_cmd17, v_rto && v_where == 17)
  `FC(response_timeout_cmd13, v_rto && v_where == 13)
  `FC(crc_status_negative, v_tokbad)
  `FC(crc_status_timeout, v_tokto)
  `FC(write_busy, v_busy)
  `FC(write_busy_timeout, v_busyto)
  `FC(read_data_timeout, v_rdto)
  `FC(read_crc16_error, v_rcrc)
  `FC(read_end_bit_error, v_rend)
  `FC(read_compare_mismatch, v_cmp)
  `FC(round_complete, v_round)
  `FC(round_byte_addressed, v_round && !m_ccs)
  `FC(round_counter_wraps, v_round && m_round == 8'h00)
  `FC_RST(reset_during_write_block, rst_n && ph == WDAT ##1 !rst_n)
  `FC_RST(reset_during_init, rst_n && !init && ph == RSP ##1 !rst_n)
endmodule

bind SD_top SD_sva #(.SD_CLK_DIV(SD_CLK_DIV)) u_sva (.*);
