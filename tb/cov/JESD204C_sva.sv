// SPDX-License-Identifier: Apache-2.0
// JESD204C link layer: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * Transmitter: 66-clock blocks from reset, 32 blocks a multiblock. At
//    each block start the model takes the payload, runs its own scrambler
//    and CRC over the 64 bits and builds the line bits; the header bits
//    come from a field table of the sync header stream (CRC of the
//    previous multiblock, command sampled at the multiblock start, EoEMB
//    from its extended multiblock count).
//  * Receiver: own bit slide / test / lock / window counters, its own
//    descrambler, payload, CRC and sync header history, multiblock and
//    extended multiblock alignment.
// Every output is compared on every clock.
`include "cov_macros.svh"
module JESD204C_sva (
  input logic        clk, rst_n, tx_p, rx_p,
  input logic [3:0]  cfg_e,
  input logic        tx_valid, tx_ready,
  input logic [63:0] tx_data,
  input logic [6:0]  tx_cmd,
  input logic        tx_mb_start, tx_underrun,
  input logic        rx_valid,
  input logic [63:0] rx_data,
  input logic        rx_mb_start, rx_emb_start, rx_mb_valid,
  input logic [6:0]  rx_cmd,
  input logic        rx_crc_err, sh_lock, emb_lock, err_sh, err_emb
);
  `COV_CLOCKING(clk, !rst_n)

  // field of sync header stream bit j: 0..11 CRC bit 11-k, 12..18 command
  // bit 6-k, 19 EoEMB, 20 zero, 21 pilot one
  function automatic int field(input int j);
    int crc_at [12] = '{0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14};
    int cmd_at [7] = '{16, 17, 18, 20, 21, 22, 24};
    for (int k = 0; k < 12; k++) if (crc_at[k] == j) return k;
    for (int k = 0; k < 7; k++) if (cmd_at[k] == j) return 12 + k;
    if (j == 25) return 19;
    if (j >= 27 && j <= 30) return 20;
    return 21;
  endfunction
  function automatic bit sbit(input int j, input logic [11:0] c, input logic [6:0] m, input bit eo);
    int f;
    f = field(j);
    if (f < 12) return c[11 - f];
    if (f < 19) return m[6 - (f - 12)];
    if (f == 19) return eo;
    return f == 21;
  endfunction
  function automatic logic [11:0] crc_b(input logic [11:0] c, input bit b);
    bit fb;
    fb = c[11] ^ b;
    c = c << 1;
    if (fb) c = c ^ 12'h80F;
    return c;
  endfunction

  // ---------------- transmitter model ----------------
  int          t_k, t_j, t_e, t_chk;          // t_chk: the block bit on tx_p now
  bit          t_scr [0:57];
  logic [65:0] t_line;                  // bits of the block, [0] first
  logic [11:0] t_crc, t_crc_s;
  logic [6:0]  t_cmd;
  bit          m_ready, m_mbs, m_ur;
  // ---------------- receiver model ----------------
  bit          r_q, r_h0;
  int          r_k, r_st, r_vc, r_wc, r_ic, r_es, r_j, r_e;  // r_st: 0 hunt, 1 test, 2 lock; r_es: 0 init, 1 multiblock, 2 locked
  bit          r_scr [0:57];
  logic [63:0] r_pay;
  logic [11:0] r_crc, r_crcp;
  logic [31:0] r_sh;
  bit          m_rv, m_rms, m_res, m_mbv, m_ce, m_esh, m_eemb;
  logic [63:0] m_rd;
  logic [6:0]  m_cmd;
  // coverage
  bit v_ur, v_e0, v_e15, v_slide, v_test_fail, v_lock, v_unlock, v_win_reset, v_mb_aln, v_emb_lock;
  bit v_eomb_missing, v_eomb_moved, v_eoemb_extra, v_eoemb_missing, v_crc_ok, v_crc_err, v_cmd, v_lost_emb;

  assign m_ready = t_k == 0 && tx_valid;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_k = 0; t_j = 0; t_e = 0; t_chk = -1; t_line = 0; t_crc = 0; t_crc_s = 0; t_cmd = 0; m_mbs = 0; m_ur = 0;
      for (int i = 0; i < 58; i++) begin t_scr[i] = 0; r_scr[i] = 0; end
      r_q = 0; r_h0 = 0; r_k = 0; r_st = 0; r_vc = 0; r_wc = 0; r_ic = 0; r_es = 0; r_j = 0; r_e = 0;
      r_pay = 0; r_crc = 0; r_crcp = 0; r_sh = 0;
      {m_rv, m_rms, m_res, m_mbv, m_ce, m_esh, m_eemb} = '0; m_rd = 0; m_cmd = 0;
    end else begin : b_step
      bit b;
      m_mbs = 0; m_ur = 0;
      // ---- transmitter
      if (t_k == 0) begin : b_load
        logic [63:0] p;
        p = tx_valid ? tx_data : 64'd0;
        if (!tx_valid) begin m_ur = 1; v_ur = 1; end
        if (t_j == 0) begin t_cmd = tx_cmd; m_mbs = 1; if (tx_cmd != 0) v_cmd = 1; end
        t_line[0] = !sbit(t_j, t_crc_s, t_cmd, t_e >= int'(cfg_e));
        for (int i = 0; i < 64; i++) begin : b_bit
          bit s;
          s = p[i] ^ t_scr[38] ^ t_scr[57];
          for (int k = 57; k > 0; k--) t_scr[k] = t_scr[k - 1];
          t_scr[0] = s;
          t_line[2 + i] = s;
          t_crc = crc_b(t_crc, p[i]);
        end
      end
      if (t_k == 1) t_line[1] = sbit(t_j, t_crc_s, t_cmd, t_e >= int'(cfg_e));
      if (t_k == 65) begin
        if (t_j == 31) begin
          t_crc_s = t_crc; t_crc = 0;
          if (cfg_e == 0) v_e0 = 1;
          if (cfg_e == 15) v_e15 = 1;
          t_e = t_e >= int'(cfg_e) ? 0 : t_e + 1;
        end
        t_j = (t_j + 1) % 32;
      end
      t_chk = t_k;
      t_k = (t_k + 1) % 66;

      // ---- receiver
      {m_rv, m_mbv, m_esh, m_eemb} = '0;
      b = r_q;
      if (r_k == 0) begin r_h0 = b; r_k = 1; end
      else if (r_k == 1) begin : b_hdr
        bit ok;
        ok = r_h0 != b;
        r_sh = {r_sh[30:0], b};
        r_k = 2;
        case (r_st)
          0: if (ok) begin r_st = 1; r_vc = 1; end
             else begin r_h0 = b; r_k = 1; v_slide = 1; end
          1: if (!ok) begin r_st = 0; r_h0 = b; r_k = 1; v_test_fail = 1; end
             else begin
               r_vc++;
               if (r_vc == 64) begin r_st = 2; r_wc = 0; r_ic = 0; v_lock = 1; end
             end
          default: begin
            if (!ok) m_esh = 1;
            if (!ok && r_ic == 15) begin r_st = 0; v_unlock = 1; end
            if (r_wc == 63) begin if (r_ic > 0) v_win_reset = 1; r_ic = 0; end
            else r_ic += !ok;
            r_wc = (r_wc + 1) % 64;
          end
        endcase
      end else begin : b_pay
        bit d;
        int st_before;
        d = b ^ r_scr[38] ^ r_scr[57];
        for (int k = 57; k > 0; k--) r_scr[k] = r_scr[k - 1];
        r_scr[0] = b;
        r_pay[r_k - 2] = d;
        r_crc = crc_b(r_crc, d);
        if (r_k == 65) begin : b_blk
          bit eomb;
          eomb = r_sh[4:0] == 5'b00001;
          if (r_es == 2) begin m_rv = 1; m_rd = r_pay; m_rms = r_j == 0; m_res = r_j == 0 && r_e == 0; end
          if (r_st != 2) begin
            if (r_es == 2) v_lost_emb = 1;
            r_es = 0; r_j = (r_j + 1) % 32;
          end else if (r_es == 0) begin
            r_j = (r_j + 1) % 32;
            if (eomb) begin r_es = 1; r_j = 0; r_crc = 0; v_mb_aln = 1; end
          end else if (r_j == 31) begin
            r_j = 0;
            if (!eomb) begin m_eemb = 1; r_es = 0; v_eomb_missing = 1; end
            else begin : b_mb
              logic [11:0] c;
              logic [6:0]  m;
              bit          eo;
              for (int j = 0; j < 32; j++) begin
                int f;
                f = field(j);
                if (f < 12) c[11 - f] = r_sh[31 - j];
                else if (f < 19) m[6 - (f - 12)] = r_sh[31 - j];
                else if (f == 19) eo = r_sh[31 - j];
              end
              if (r_es == 2) begin
                m_mbv = 1; m_cmd = m; m_ce = c != r_crcp;
                if (c != r_crcp) v_crc_err = 1; else v_crc_ok = 1;
                if (eo != (r_e == int'(cfg_e))) begin
                  m_eemb = 1; r_es = 1;
                  if (eo) v_eoemb_extra = 1; else v_eoemb_missing = 1;
                end
                r_e = eo ? 0 : (r_e + 1) % 16;
              end else if (eo) begin r_es = 2; r_e = 0; v_emb_lock = 1; end
              r_crcp = r_crc; r_crc = 0;
            end
          end else begin
            r_j++;
            if (eomb) begin m_eemb = 1; r_es = 1; r_j = 0; r_crc = 0; v_eomb_moved = 1; end
          end
        end
        r_k = r_k == 65 ? 0 : r_k + 1;
      end
      r_q = rx_p;
    end
  end

  // ---------------- assertions ----------------
  `SVA_IMP(a_tx_bit, t_chk >= 0, tx_p == t_line[t_chk])
  `SVA_INV(a_tx_ready, tx_ready == m_ready)
  `SVA_INV(a_tx_events, tx_mb_start == m_mbs && tx_underrun == m_ur)
  `SVA_INV(a_lock, sh_lock == (r_st == 2) && emb_lock == (r_es == 2))
  `SVA_INV(a_errors, err_sh == m_esh && err_emb == m_eemb)
  `SVA_INV(a_rx_valid, rx_valid == m_rv && rx_mb_valid == m_mbv)
  `SVA_IMP(a_rx_data, m_rv, rx_data == m_rd && rx_mb_start == m_rms && rx_emb_start == m_res)
  `SVA_IMP(a_rx_mb, m_mbv, rx_cmd == m_cmd && rx_crc_err == m_ce)
  `SVA_RST(a_reset, 1'b1, !tx_p && !sh_lock && !emb_lock && !rx_valid && !rx_mb_valid && !err_sh && !err_emb)

  // ---------------- functional coverage ----------------
  `FC(tx_underrun, v_ur)
  `FC(tx_command, v_cmd)
  `FC(emb_of_1, v_e0)
  `FC(emb_of_16, v_e15)
  `FC(sh_slide, v_slide)
  `FC(sh_test_fails, v_test_fail)
  `FC(sh_lock, v_lock)
  `FC(sh_unlock, v_unlock)
  `FC(sh_window_reset, v_win_reset)
  `FC(mb_aligned, v_mb_aln)
  `FC(emb_locked, v_emb_lock)
  `FC(eomb_missing, v_eomb_missing)
  `FC(eomb_misplaced, v_eomb_moved)
  `FC(eoemb_unexpected, v_eoemb_extra)
  `FC(eoemb_missing, v_eoemb_missing)
  `FC(crc_ok, v_crc_ok)
  `FC(crc_error, v_crc_err)
  `FC(emb_lost_with_sh, v_lost_emb)
  `FC(rx_emb_start, rx_valid && rx_emb_start)
  `FC(rx_command, rx_mb_valid && rx_cmd != 7'd0)
  `FC_RST(reset_while_locked, rst_n && emb_lock ##1 !rst_n)
endmodule

bind JESD204C_top JESD204C_sva u_sva (.*);
