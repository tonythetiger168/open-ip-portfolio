// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// SAS initiator: a cycle-level model fed only by rx_p predicts tx_p / tx_n
// and irq on every clock, plus the register file and the verified /
// mismatching read-back counters. OOB: burst-run detector and the
// COMRESET / COMINIT exchange. Receiver: SOF hunted in a continuous 32-bit
// window, then the frame collected as a dword list and judged at its CRC
// and EOF dwords. Transmitter: each frame built as a dword list at its
// start (header, payload, CRC32, EOF) and shifted out MSB first between
// ALIGN primitives. Sequencer: write, read request, read-back compare,
// timeouts, xorshift data.
`include "cov_macros.svh"
module SAS_sva #(parameter int BIT_CLKS = 1) (
  input logic        clk, rst_n, rx_p, tx_p, tx_n, irq, phy_ready,
  input logic [7:0]  ok_cnt, mm_cnt
);
  `COV_CLOCKING(clk, !rst_n)

  localparam logic [31:0] ALIGN = 32'h7B4A4ABC, SOF = 32'hA5A50001, EOF = 32'hA5A50002;
  localparam int TMO = 512 * BIT_CLKS;
  localparam int CRB = 0, CRI = 1, CIB = 2, CII = 3, DONE = 4;
  localparam int SINIT = 0, SWR = 1, SWW = 2, SRD = 3, SRW = 4, SGAP = 5;

  function automatic logic [31:0] crc_dw(input logic [31:0] crc, input logic [31:0] dw);
    for (int b = 3; b >= 0; b--)
      for (int i = 0; i < 8; i++)
        crc = (crc[0] ^ dw[b * 8 + i]) ? (crc >> 1) ^ 32'hEDB88320 : (crc >> 1);
    return crc;
  endfunction
  function automatic logic [31:0] xs(input logic [31:0] x);
    x = x ^ (x << 13); x = x ^ (x >> 17); return x ^ (x << 5);
  endfunction

  // OOB
  int          ob, ocnt, brun;
  logic        det, crs, cis, m_phy;
  // bit timing
  int          bd;
  // transmitter
  logic [31:0] tq [6];
  int          tn, ti, tb;            // dwords in the frame, dword index, bit
  logic        t_frame, m_ack, rpend;
  logic [31:0] t_cur;
  // receiver
  logic [31:0] w;
  logic        r_on;
  int          rb, rn, rlen;
  logic [31:0] rd [0:18];
  logic        rcrc_ok;
  logic [31:0] regs [16];
  // events
  logic        p_crc, p_pro, p_tmo, p_wr, p_rsp, p_rq;
  logic [31:0] e_val, q_data;
  logic [7:0]  e_from, q_dst;
  logic [3:0]  q_src;
  // sequencer
  int          sq, tmo, gap;
  logic [3:0]  sa;
  logic [31:0] sd;
  logic [7:0]  m_ok, m_mm;
  logic        m_irq, m_tx;
  // coverage
  logic v_oob_retry_cr, v_oob_retry_ci, v_wr, v_rq, v_rs_ok, v_mm_val, v_mm_src, v_tmo_wr, v_tmo_rd,
        v_crc, v_eof, v_len, v_nopay, v_badreg_wr, v_badreg_rd, v_type, v_emptyrsp, v_len16,
        v_pending;

  always @(posedge clk or negedge rst_n) begin
    logic        pend0, tick, o_det, o_ack, o_rq, o_pcrc, o_ppro, o_ptmo, o_wr, o_rsp, o_phy, req, rd_k;
    logic [31:0] o_val, o_qdata, c, h, dw;
    logic [7:0]  o_from, o_qdst;
    logic [3:0]  o_qsrc;
    int          o_sq, o_tmo;
    if (!rst_n) begin
      ob = CRB; ocnt = 0; brun = 0; det = 0; crs = 0; cis = 0; m_phy = 0; bd = 0;
      tn = 0; ti = 0; tb = 0; t_frame = 0; m_ack = 0; rpend = 0; t_cur = ALIGN;
      w = 0; r_on = 0; rb = 0; rn = 0; rlen = 0; rcrc_ok = 0;
      for (int i = 0; i < 16; i++) regs[i] = 0;
      {p_crc, p_pro, p_tmo, p_wr, p_rsp, p_rq} = '0;
      e_val = 0; e_from = 0; q_data = 0; q_dst = 0; q_src = 0;
      sq = SINIT; tmo = 0; gap = 0; sa = 0; sd = 32'h5A5A_C3C3; m_ok = 0; m_mm = 0; m_irq = 0;
      m_tx = 1;
      {v_oob_retry_cr, v_oob_retry_ci, v_wr, v_rq, v_rs_ok, v_mm_val, v_mm_src, v_tmo_wr, v_tmo_rd,
       v_crc, v_eof, v_len, v_nopay, v_badreg_wr, v_badreg_rd, v_type, v_emptyrsp, v_len16,
       v_pending} = '0;
    end else begin
      {v_oob_retry_cr, v_oob_retry_ci, v_wr, v_rq, v_rs_ok, v_mm_val, v_mm_src, v_tmo_wr, v_tmo_rd,
       v_crc, v_eof, v_len, v_nopay, v_badreg_wr, v_badreg_rd, v_type, v_emptyrsp, v_len16,
       v_pending} = '0;
      o_det = det; o_ack = m_ack; o_rq = p_rq; o_pcrc = p_crc; o_ppro = p_pro; o_ptmo = p_tmo;
      o_wr = p_wr; o_rsp = p_rsp; o_val = e_val; o_from = e_from; o_qdata = q_data; o_qdst = q_dst;
      o_qsrc = q_src; o_sq = sq; o_tmo = tmo; o_phy = m_phy;
      tick = BIT_CLKS <= 1 || bd == BIT_CLKS - 1;
      bd = tick ? 0 : bd + 1;
      m_irq = o_pcrc || o_ppro || o_ptmo;

      // ---------------- OOB ----------------
      det = !rx_p && brun == 64;
      if (!rx_p) brun = 0; else if (brun != 64) brun++;
      case (ob)
        CRB, CIB: begin
          if (ocnt == 105) begin ocnt = 0; if (ob == CRB) begin crs = 0; ob = CRI; end else begin cis = 0; ob = CII; end end
          else ocnt++;
        end
        CRI, CII: begin
          if (o_det) begin if (ob == CRI) crs = 1; else cis = 1; end
          if (ocnt == 317) begin
            ocnt = 0;
            if (ob == CRI) begin
              if (crs || o_det) ob = CIB; else begin ob = CRB; v_oob_retry_cr = 1; end
            end else begin
              if (cis || o_det) begin ob = DONE; m_phy = 1; end else begin ob = CIB; v_oob_retry_ci = 1; end
            end
          end else ocnt++;
        end
        default: ;
      endcase

      // ---------------- sequencer ----------------
      p_tmo = 0;
      case (o_sq)
        SINIT: if (o_phy) begin gap = (gap + 1) % 64; if (gap == 0) sq = SWR; end
        SWR:   if (o_ack) begin tmo = 0; sq = SWW; end
        SWW: begin
          tmo++;
          if (o_wr) sq = SRD;
          else if (o_tmo == TMO) begin p_tmo = 1; sq = SRD; v_tmo_wr = 1; end
        end
        SRD:   if (o_ack) begin tmo = 0; sq = SRW; end
        SRW: begin
          tmo++;
          if (o_rsp || o_tmo == TMO) begin
            if (!o_rsp) begin p_tmo = 1; v_tmo_rd = 1; end
            else if (o_val == sd && o_from == {4'h0, sa}) begin m_ok++; v_rs_ok = 1; end
            else begin m_mm++; if (o_val != sd) v_mm_val = 1; else v_mm_src = 1; end
            sd = xs(sd); sa++; gap = 0; sq = SGAP;
          end
        end
        default: begin gap++; if (gap == 32) sq = SWR; end
      endcase

      // ---------------- transmitter (old request / pending state) ----------------
      req = (o_sq == SWR || o_sq == SRD);
      rd_k = (o_sq == SRD);
      m_ack = 0;
      if (!o_phy) begin
        t_frame = 0; tb = 0; t_cur = ALIGN;
      end else begin
        pend0 = rpend;
        if (o_rq) rpend = 1;
        if (tick) begin
          tb++;
          if (tb == 32) begin
            tb = 0;
            if (t_frame && ti < tn - 1) begin ti++; t_cur = tq[ti]; end
            else if (t_frame) begin t_frame = 0; t_cur = ALIGN; end   // EOF sent
            else if (rpend) begin
              v_pending = pend0;
              rpend = 0;
              h = {8'd1, 8'h83, o_qdst, 4'h0, o_qsrc};
              tq[0] = SOF; tq[1] = h; tq[2] = o_qdata;
              c = crc_dw(crc_dw(32'hFFFF_FFFF, h), o_qdata);
              tq[3] = ~c; tq[4] = EOF; tn = 5; ti = 0; t_frame = 1; t_cur = SOF;
            end else if (req && !o_ack) begin
              m_ack = 1;
              h = rd_k ? {8'd0, 8'h02, 4'h0, sa, 8'h01} : {8'd1, 8'h01, 4'h0, sa, 8'h01};
              tq[0] = SOF; tq[1] = h;
              c = crc_dw(32'hFFFF_FFFF, h);
              if (rd_k) begin tq[2] = ~c; tq[3] = EOF; tn = 4; end
              else begin c = crc_dw(c, sd); tq[2] = sd; tq[3] = ~c; tq[4] = EOF; tn = 5; end
              ti = 0; t_frame = 1; t_cur = SOF;
            end else begin
              t_frame = 0; t_cur = ALIGN;
            end
          end
        end
      end
      m_tx = m_phy ? t_cur[31 - tb] : (ob == CRB || ob == CIB);

      // ---------------- receiver ----------------
      {p_crc, p_pro, p_wr, p_rsp, p_rq} = '0;
      if (!o_phy) begin w = 0; r_on = 0; end
      else if (tick) begin
        w = {w[30:0], rx_p};
        if (!r_on) begin
          if (w == SOF) begin r_on = 1; rb = 0; rn = 0; end
        end else if (++rb == 32) begin
          rb = 0; rd[rn] = w; rn++;
          if (rn == 1) begin
            rlen = w[31:24];
            if (rlen > 16) begin p_pro = 1; r_on = 0; v_len = 1; end
          end else if (rn == rlen + 2) begin
            c = 32'hFFFF_FFFF;
            for (int i = 0; i <= rlen; i++) c = crc_dw(c, rd[i]);
            rcrc_ok = w == ~c;
            if (!rcrc_ok) begin p_crc = 1; v_crc = 1; end
          end else if (rn == rlen + 3) begin
            r_on = 0;
            if (rcrc_ok) begin
              if (w != EOF) begin p_pro = 1; v_eof = 1; end
              else case (rd[0][23:16])
                8'h01:
                  if (rlen != 0 && rd[0][15:8] < 16) begin
                    regs[rd[0][11:8]] = rd[1]; p_wr = 1; v_wr = 1; if (rlen == 16) v_len16 = 1;
                  end else begin p_pro = 1; if (rlen == 0) v_nopay = 1; else v_badreg_wr = 1; end
                8'h02:
                  if (rd[0][15:8] < 16) begin
                    p_rq = 1; v_rq = 1; q_dst = rd[0][7:0]; q_src = rd[0][11:8]; q_data = regs[rd[0][11:8]];
                  end else begin p_pro = 1; v_badreg_rd = 1; end
                8'h83:
                  if (rlen != 0) begin p_rsp = 1; e_val = rd[1]; e_from = rd[0][7:0]; end
                  else begin p_pro = 1; v_emptyrsp = 1; end
                default: begin p_pro = 1; v_type = 1; end
              endcase
            end
          end
        end
      end
    end
  end

  wire m_line = rst_n && m_tx;

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_line, !rst_n, !tx_p && tx_n && !irq && !phy_ready)
  `SVA_INV(a_tx_p, tx_p == m_line)
  `SVA_INV(a_tx_n, tx_n == !tx_p)
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_INV(a_phy_ready, phy_ready == m_phy)
  `SVA_INV(a_counters, ok_cnt == m_ok && mm_cnt == m_mm)

  // ---------------- functional coverage ----------------
  `FC(oob_cominit_missed_after_comreset, v_oob_retry_cr)
  `FC(oob_cominit_missed_after_cominit, v_oob_retry_ci)
  `FC(write_applied, v_wr)
  `FC(write_16_dwords, v_len16)
  `FC(read_request_served, v_rq)
  `FC(read_back_verified, v_rs_ok)
  `FC(read_back_wrong_value, v_mm_val)
  `FC(read_back_wrong_source, v_mm_src)
  `FC(write_timeout, v_tmo_wr)
  `FC(read_timeout, v_tmo_rd)
  `FC(crc_error, v_crc)
  `FC(bad_eof, v_eof)
  `FC(oversize_length, v_len)
  `FC(write_without_payload, v_nopay)
  `FC(write_bad_register, v_badreg_wr)
  `FC(read_bad_register, v_badreg_rd)
  `FC(unknown_type, v_type)
  `FC(empty_read_response, v_emptyrsp)
  `FC(response_waited_for_frame_end, v_pending)
  `FC(verified_counter_wraps, v_rs_ok && m_ok == 8'h00)
  `FC_RST(reset_mid_frame, rst_n && t_frame ##1 !rst_n)
endmodule

bind SAS_top SAS_sva #(.BIT_CLKS(BIT_CLKS)) u_sva (.*);
