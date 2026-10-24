// SPDX-License-Identifier: Apache-2.0
// eMMC host: a bit-level model of the host's job (init CMD0 / CMD1 polling
// / CMD2 / CMD3, then rounds of CMD24 write + CMD17 read-back) built from
// the bus. It decodes every card response and data block on CMD / DAT0 with
// its own CRC7 / CRC16, judges each one (framing, index, CRC, card-status
// error bits, CRC status token, busy, timeouts, read-back compare), and
// predicts the host's CMD and DAT0 drivers (enable and value) on every
// clock, every irq pulse, the captured CID and the round / match counters.
`include "cov_macros.svh"
module eMMC_sva #(parameter int BIT_CLKS = 1) (
  input logic         emmc_clk, rst_n, emmc_rst_n, cmd, irq,
  input logic [7:0]   dat,
  input logic         cmd_oe_r, cmd_out_r, dat0_oe_r, dat0_out_r,
  input logic [127:0] cid,
  input logic [7:0]   round, match_cnt
);
  wire srst = !(rst_n && emmc_rst_n);
  `COV_CLOCKING(emmc_clk, srst)

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

  int bd;
  wire tk = BIT_CLKS <= 1 || bd == BIT_CLKS - 1;

  // host activity
  localparam int TX = 0, GAP = 1, HUNT = 2, RSP = 3, IDLE = 4, WST = 5, WDAT = 6, WCRC = 7, WEND = 8,
                 TOKW = 9, TOK = 10, BUSY = 11, BGAP = 12, RHUNT = 13, RDAT = 14, RCRC = 15, REND = 16;
  int           ph, n, w, len;
  logic [5:0]   cc;
  logic [47:0]  fr;
  logic [135:0] rs;
  logic [255:0] db;
  logic [15:0]  crc, crx;
  logic [2:0]   tk3;
  logic         init, m_coe, m_co, m_doe, m_do, m_irq;
  logic [127:0] m_cid;
  logic [7:0]   m_round, m_match;
  int           polls;

  wire  [135:0] rn  = {rs[134:0], cmd};
  wire          r1f = !rn[46] && rn[45:40] == cc && rn[0] && crc7({80'h0, rn[47:8]}, 40) == rn[7:1];
  wire          r1e = (rn[39:8] & 32'hFDF9_8080) != 0;
  wire          r3f = !rn[46] && rn[45:40] == 6'h3F && rn[7:0] == 8'hFF;
  wire          r2f = !rn[134] && rn[133:128] == 6'h3F && crc7(rn[127:8], 120) == rn[7:1] && rn[0];

  // coverage strobes
  logic v_poll, v_r3bad, v_r2bad, v_r1crc, v_r1idx, v_r1end, v_r1st, v_stat, v_rto, v_tokbad, v_tokto,
        v_busyto, v_busy, v_rdto, v_rcrc, v_rend, v_cmp, v_round, v_r1tx;
  logic [5:0] v_where;    // which command an error hit
  // registered copies for the covergroup: R1 outcome per command, block
  // address of each CMD24 / CMD17
  logic       c_r1, c_iv;
  logic [1:0] c_cc;
  logic [2:0] c_k, c_ia;
  function automatic logic [1:0] ccode(input logic [5:0] c);
    return c == 6'd3 ? 2'd0 : (c == 6'd24 ? 2'd1 : 2'd2);
  endfunction

  task automatic issue(input logic [5:0] idx, input logic [31:0] arg, input int l);
    ph <= TX; n <= 0; fr <= frame(idx, arg); cc <= idx; len <= l; m_coe <= 1; w <= 0;
  endtask
  task automatic fail();
    m_irq <= 1;
    if (init) begin ph <= IDLE; w <= 0; end else begin issue(6'd0, 0, 0); polls <= 0; end
  endtask

  always_ff @(posedge emmc_clk or posedge srst) begin
    if (srst) begin
      bd <= 0; init <= 0; m_coe <= 1; m_co <= 1; m_doe <= 0; m_do <= 1; m_irq <= 0;
      m_cid <= 0; m_round <= 0; m_match <= 0; polls <= 0;
      ph <= TX; n <= 0; w <= 0; fr <= frame(6'd0, 0); cc <= 0; len <= 0;
      rs <= 0; db <= 0; crc <= 0; crx <= 0; tk3 <= 0;
      {v_poll, v_r3bad, v_r2bad, v_r1crc, v_r1idx, v_r1end, v_r1st, v_stat, v_rto, v_tokbad, v_tokto,
       v_busyto, v_busy, v_rdto, v_rcrc, v_rend, v_cmp, v_round, v_r1tx} <= '0;
      v_where <= 0;
      {c_r1, c_iv} <= '0; c_cc <= 0; c_k <= 0; c_ia <= 0;
    end else begin
      {c_r1, c_iv} <= '0;
      bd <= tk ? 0 : bd + 1;
      {v_poll, v_r3bad, v_r2bad, v_r1crc, v_r1idx, v_r1end, v_r1st, v_stat, v_rto, v_tokbad, v_tokto,
       v_busyto, v_busy, v_rdto, v_rcrc, v_rend, v_cmp, v_round, v_r1tx} <= '0;
      if (tk) begin
        m_irq <= 0;
        case (ph)
          TX: begin
            m_co <= fr[47 - n]; n <= n + 1;
            if (n == 47) begin ph <= GAP; w <= 0; end
          end
          GAP: begin
            m_coe <= 0; w <= w + 1;
            if (len == 0) begin if (w == 7) issue(6'd1, 32'h40FF_8080, 48); end
            else if (w == 3) begin ph <= HUNT; w <= 0; end
          end
          HUNT:
            if (!cmd) begin ph <= RSP; n <= 1; rs <= 0; end
            else if (w == 63) begin
              fail(); v_rto <= 1; v_where <= cc;
              c_r1 <= cc == 6'd3 || cc == 6'd24 || cc == 6'd17; c_cc <= ccode(cc); c_k <= 6;
            end
            else w <= w + 1;
          RSP: begin
            rs <= rn; n <= n + 1;
            if (n == len - 1) begin
              case (cc)
                6'd1:
                  if (!r3f) begin fail(); v_r3bad <= 1; end
                  else if (rn[39]) issue(6'd2, 0, 136);
                  else begin issue(6'd1, 32'h40FF_8080, 48); v_poll <= 1; end
                6'd2:
                  if (!r2f) begin fail(); v_r2bad <= 1; end
                  else begin m_cid <= rn[127:0]; issue(6'd3, 32'h0001_0000, 48); end
                default: begin
                  v_r1crc <= crc7({80'h0, rn[47:8]}, 40) != rn[7:1]; v_r1idx <= rn[45:40] != cc;
                  v_r1end <= !rn[0]; v_r1tx <= rn[46]; v_where <= cc;
                  c_r1 <= 1; c_cc <= ccode(cc);
                  c_k <= rn[46] ? 1 : (!rn[0] ? 2 : (rn[45:40] != cc ? 3 : (crc7({80'h0, rn[47:8]}, 40) != rn[7:1] ? 4 : (r1e ? 5 : 0))));
                  if (!r1f) fail();
                  else if (r1e) begin fail(); v_stat <= 1; end
                  else if (cc == 6'd3) begin init <= 1; ph <= IDLE; w <= 0; end
                  else if (cc == 6'd24) begin ph <= WST; m_doe <= 1; db <= blk(m_round); crc <= 0; n <= 0; end
                  else begin ph <= RHUNT; w <= 0; crc <= 0; crx <= 0; end
                end
              endcase
            end
          end
          IDLE: begin
            w <= w + 1;
            if (w == 7) begin issue(6'd24, {30'h0, m_round[1:0]}, 48); c_iv <= 1; c_ia <= {1'b0, m_round[1:0]}; end
          end
          WST: begin m_do <= 0; ph <= WDAT; end
          WDAT: begin
            m_do <= db[255 - n]; crc <= c16(crc, db[255 - n]); n <= n + 1;
            if (n == 255) begin ph <= WCRC; n <= 0; end
          end
          WCRC: begin m_do <= crc[15 - n]; n <= n + 1; if (n == 15) ph <= WEND; end
          WEND: begin m_do <= 1; ph <= TOKW; w <= 0; end
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
          BGAP: begin
            w <= w + 1;
            if (w == 5) begin issue(6'd17, {30'h0, m_round[1:0]}, 48); c_iv <= 1; c_ia <= {1'b1, m_round[1:0]}; end
          end
          RHUNT:
            if (!dat[0]) begin ph <= RDAT; n <= 0; end
            else if (w == 63) begin fail(); v_rdto <= 1; end
            else w <= w + 1;
          RDAT: begin
            db <= {db[254:0], dat[0]}; crc <= c16(crc, dat[0]); n <= n + 1;
            if (n == 255) begin ph <= RCRC; n <= 0; end
          end
          RCRC: begin crx <= {crx[14:0], dat[0]}; n <= n + 1; if (n == 15) ph <= REND; end
          REND:
            if (!dat[0] || crx != crc) begin fail(); v_rcrc <= crx != crc; v_rend <= !dat[0]; end
            else if (db != blk(m_round)) begin fail(); v_cmp <= 1; end
            else begin m_match <= m_match + 1; m_round <= m_round + 1; ph <= IDLE; w <= 0; v_round <= 1; end
          default: ;
        endcase
      end
    end
  end

  `SVA_RST(a_reset_state, srst, cmd_oe_r && cmd_out_r && !dat0_oe_r && !irq)
  `SVA_INV(a_cmd_driver, cmd_oe_r == m_coe && (!m_coe || cmd_out_r == m_co))
  `SVA_INV(a_dat0_driver, dat0_oe_r == m_doe && (!m_doe || dat0_out_r == m_do))
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_INV(a_cid, cid == m_cid)
  `SVA_INV(a_round_and_matches, round == m_round && match_cnt == m_match)

  // R1 outcome (OK, transmission bit, end bit, index, CRC7, card status,
  // no response) x command (CMD3, CMD24, CMD17); block address of every
  // CMD24 and CMD17
  covergroup cg_emmc @(negedge emmc_clk);
    option.per_instance = 1;
    cp_cmd: coverpoint c_cc iff (!srst && c_r1) { bins cmd3 = {0}; bins cmd24 = {1}; bins cmd17 = {2}; }
    cp_r1: coverpoint c_k iff (!srst && c_r1)
      { bins ok = {0}; bins tx_bit = {1}; bins end_bit = {2}; bins index = {3}; bins crc7 = {4}; bins status = {5}; bins none = {6}; }
    x_r1: cross cp_cmd, cp_r1;
    cp_blk: coverpoint c_ia iff (!srst && c_iv) { bins wr[] = {[0:3]}; bins rd[] = {[4:7]}; }
  endgroup
  cg_emmc u_cg_emmc = new;

  `FC(cmd1_busy_poll, v_poll)
  `FC(r3_malformed, v_r3bad)
  `FC(r2_bad, v_r2bad)
  `FC(r1_crc_error, v_r1crc)
  `FC(r1_index_mismatch, v_r1idx)
  `FC(r1_end_bit_error, v_r1end)
  `FC(r1_transmission_bit_error, v_r1tx)
  `FC(r1_status_error_cmd3, v_stat && v_where == 3)
  `FC(r1_status_error_cmd24, v_stat && v_where == 24)
  `FC(r1_status_error_cmd17, v_stat && v_where == 17)
  `FC(response_timeout_init, v_rto && !init)
  `FC(response_timeout_cmd24, v_rto && v_where == 24)
  `FC(response_timeout_cmd17, v_rto && v_where == 17)
  `FC(crc_status_negative, v_tokbad)
  `FC(crc_status_timeout, v_tokto)
  `FC(write_busy, v_busy)
  `FC(write_busy_timeout, v_busyto)
  `FC(read_data_timeout, v_rdto)
  `FC(read_crc16_error, v_rcrc)
  `FC(read_end_bit_error, v_rend)
  `FC(read_compare_mismatch, v_cmp)
  `FC(round_complete, v_round)
  `FC(round_counter_wraps, v_round && m_round == 8'h00)
  `FC_RST(reset_during_write_block, !srst && ph == WDAT ##1 srst)
  `FC_RST(reset_during_init, !srst && !init && ph == RSP ##1 srst)
endmodule

bind eMMC_top eMMC_sva #(.BIT_CLKS(BIT_CLKS)) u_sva (.*);
