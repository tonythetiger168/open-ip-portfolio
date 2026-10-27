// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// SATA host: a cycle-level model fed only by the pins predicts tx_p, tx_n
// and irq on every clock. OOB patterns are modelled as a position in the
// gap/burst schedule, the OOB receiver as a run-length classifier, the link
// as dword streams with a frame collector (judged at EOF) and a frame sender
// walking SOF / FIS / CRC / EOF, and the transport as the command script
// IDENTIFY, then WRITE + READ per LBA with the xorshift32 data stream.
`include "cov_macros.svh"
module SATA_sva (
  input logic clk, rst_n, rx_p, rx_n, tx_p, tx_n, irq
);
  `COV_CLOCKING(clk, !rst_n)

  localparam logic [31:0] ALIGN = 32'h7B4A_4ABC, SYNC = 32'hB5B5_957C, XRDY = 32'h5757_B57C,
                          RRDY = 32'h4A4A_957C, RIP = 32'h5555_B57C, ROK = 32'h3535_B57C,
                          RERR = 32'h5656_B57C, SOF = 32'h3737_B57C, EOF = 32'hD5D5_B57C,
                          WTRM = 32'h5858_B57C;
  // link phases
  localparam int COMRESET = 0, WAIT_INIT = 1, COMWAKE = 2, WAIT_WAKE = 3, ALIGNING = 4, READY = 5;
  // receive / send sides
  localparam int RI = 0, RR = 1, RD = 2, RS = 3;
  localparam int SI = 0, SX = 1, SS = 2, SD = 3, SC = 4, SE = 5, SW = 6;
  // command script
  localparam int C_START = 0, C_ID = 1, C_IDD = 2, C_IDS = 3, C_FILL = 4, C_WR = 5, C_WRA = 6,
                 C_WRD = 7, C_WRS = 8, C_RD = 9, C_RDD = 10, C_RDS = 11;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic [31:0] d);
    for (int k = 0; k < 32; k++) c = (c >> 1) ^ ((c[0] ^ d[k]) ? 32'hEDB8_8320 : 32'h0);
    crc32 = c;
  endfunction
  function automatic logic [31:0] xsh(input logic [31:0] x);
    x = x ^ (x << 13); x = x ^ (x >> 17); xsh = x ^ (x << 5);
  endfunction
  function automatic bit prim(input logic [31:0] d);
    prim = d == SYNC || d == XRDY || d == RRDY || d == RIP || d == ROK || d == RERR || d == WTRM;
  endfunction

  wire sig = rx_p ^ rx_n;

  // ---------------- OOB receiver
  logic s_q, b_ok, cls_w, d_init, d_wake;
  int   run, ngap;
  // ---------------- link
  int   ph, pos, tmr;
  logic a1, e_link;
  // ---------------- dword streams
  int          tb, rb;
  logic [31:0] tsr, rsr;
  logic        locked;
  wire         dw_on = ph == ALIGNING || ph == READY;
  wire  [31:0] rw = {rx_p, rsr[31:1]};
  wire         rv = dw_on && sig && (locked ? rb == 31 : rw == ALIGN);
  wire         rq = ph == READY && rv && rw != ALIGN;              // a link dword
  wire         tbd = ph == READY && tb == 31;
  // ---------------- link layer
  int          rs, ss, rto, sto, rcnt, sidx, retry;
  logic        ovf, good, fv, s_ok_p, s_fail_p, e_rx, e_tx;
  logic [31:0] rcrc, rcrc_p, rlast, scrc;
  logic [31:0] fis [0:8];
  wire         x_in = rq && rw == XRDY && rs == RI && (ss == SI || ss == SX);
  // ---------------- transport
  int          cs, k, lba, maxl, ct, cmd;
  logic        req, dat, e_cmd;
  logic [31:0] xs;
  logic [31:0] wd [0:7];

  // coverage events
  logic v_init, v_wake, v_short, v_mixed, v_odd_gap, v_retry_init, v_retry_wake, v_retry_align,
        v_slip, v_loss, v_illegal, v_rr_to, v_withdraw, v_crc, v_ovf, v_abort, v_rs_to,
        v_collide, v_resend, v_give_up, v_x_to, v_w_to, v_garbage_w, v_unsol, v_id_retry,
        v_wr_ok, v_rd_ok, v_mismatch, v_st_err, v_ct_to, v_wrong, v_wrap;

  function automatic logic [31:0] fis_word(input int i);
    if (dat) fis_word = (i == 0) ? 32'h0000_0046 : wd[i - 1];
    else case (i)
      0: fis_word = {8'h00, (cmd == 0) ? 8'hEC : (cmd == 1) ? 8'h35 : 8'h25, 8'h80, 8'h27};
      1: fis_word = {8'h40, 18'd0, 6'(lba)};
      3: fis_word = 32'h1;
      default: fis_word = 32'h0;
    endcase
  endfunction
  function automatic logic [31:0] next_dw();
    case (ss)
      SX: next_dw = XRDY;
      SS: next_dw = SOF;
      SD: next_dw = fis_word(sidx);
      SC: next_dw = ~scrc;
      SE: next_dw = EOF;
      SW: next_dw = WTRM;
      default: next_dw = (rs == RR) ? RRDY : (rs == RD) ? RIP : (rs == RS) ? (good ? ROK : RERR) : SYNC;
    endcase
  endfunction

  // OOB receiver: classify each gap between two 12..20 clk bursts
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_q <= 0; run <= 0; b_ok <= 0; cls_w <= 0; ngap <= 0; d_init <= 0; d_wake <= 0;
    end else begin
      d_init <= 0; d_wake <= 0;
      {v_short, v_mixed, v_odd_gap} <= '0;
      s_q <= sig;
      if (sig == s_q) run <= (run == 63) ? 63 : run + 1;
      else begin
        run <= 1;
        if (s_q) begin
          b_ok <= run >= 12 && run <= 20;
          if (!(run >= 12 && run <= 20)) begin ngap <= 0; v_short <= run < 12; end
        end else if (b_ok && ((run >= 40 && run <= 56) || (run >= 12 && run <= 20))) begin
          if (ngap > 0 && cls_w == (run <= 20)) begin
            if (ngap == 2) begin
              ngap <= 0;
              if (run <= 20) d_wake <= 1; else d_init <= 1;
            end else ngap <= ngap + 1;
          end else begin
            v_mixed <= ngap > 0;
            cls_w <= run <= 20; ngap <= 1;
          end
        end else begin
          ngap <= 0;
          v_odd_gap <= b_ok && run > 20 && run < 40;
        end
      end
    end
  end

  // link phases
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= COMRESET; pos <= 0; tmr <= 0; a1 <= 0; e_link <= 0;
    end else begin
      e_link <= 0;
      {v_init, v_wake, v_retry_init, v_retry_wake, v_retry_align, v_loss} <= '0;
      case (ph)
        COMRESET, COMWAKE: begin
          pos <= pos + 1;
          if (pos == 4 * ((ph == COMRESET) ? 64 : 32) - 1) begin
            ph <= (ph == COMRESET) ? WAIT_INIT : WAIT_WAKE; pos <= 0; tmr <= 0;
          end
        end
        WAIT_INIT: begin
          tmr <= tmr + 1;
          if (d_init) begin ph <= COMWAKE; v_init <= 1; end
          else if (tmr == 1023) begin ph <= COMRESET; v_retry_init <= 1; end
        end
        WAIT_WAKE: begin
          tmr <= tmr + 1;
          if (d_wake) begin ph <= ALIGNING; tmr <= 0; a1 <= 0; v_wake <= 1; end
          else if (tmr == 1023) begin ph <= COMRESET; v_retry_wake <= 1; end
        end
        ALIGNING: begin
          tmr <= tmr + 1;
          if (rv) a1 <= rw == ALIGN;
          if (rv && rw == ALIGN && a1) ph <= READY;
          else if (tmr == 1023) begin ph <= COMRESET; v_retry_align <= 1; end
        end
        default: if (!sig) begin ph <= COMRESET; e_link <= 1; v_loss <= 1; end
      endcase
    end
  end

  // dword streams
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || !dw_on) begin
      tb <= 0; tsr <= ALIGN; rb <= 0; rsr <= 0; locked <= 0;
      v_slip <= 0;
    end else begin
      tb <= (tb + 1) % 32;
      tsr <= (tb == 31) ? ((ph == READY) ? next_dw() : ALIGN) : tsr >> 1;
      rsr <= rw;
      v_slip <= !locked && rw != ALIGN && sig;
      if (!locked) begin
        if (rw == ALIGN) begin locked <= 1; rb <= 0; end
      end else rb <= (rb + 1) % 32;
    end
  end

  // link layer: frame collector
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs <= RI; rto <= 0; rcnt <= 0; ovf <= 0; good <= 0; fv <= 0; e_rx <= 0;
      rcrc <= 0; rcrc_p <= 0; rlast <= 0;
      for (int i = 0; i < 9; i++) fis[i] <= 0;
    end else begin
      fv <= 0; e_rx <= 0;
      {v_illegal, v_rr_to, v_withdraw, v_crc, v_ovf, v_abort, v_rs_to, v_collide} <= '0;
      if (ph != READY) rs <= RI;
      else if (rq)
        case (rs)
          RI: if (x_in) begin
                rs <= RR; rto <= 0; v_collide <= ss == SX;
              end else if (!prim(rw)) begin e_rx <= 1; v_illegal <= 1; end
          RR: begin
            rto <= rto + 1;
            if (rw == SOF) begin rs <= RD; rcnt <= 0; ovf <= 0; rcrc <= 32'hFFFF_FFFF; end
            else if (rw == SYNC) begin rs <= RI; v_withdraw <= 1; end
            else if (rto == 63) begin rs <= RI; e_rx <= 1; v_rr_to <= 1; end
          end
          RD: begin
            if (rw == EOF) begin
              rs <= RS; rto <= 0;
              good <= !ovf && rcnt >= 2 && rlast == ~rcrc_p;
              if (!ovf && rcnt >= 2 && rlast == ~rcrc_p) fv <= 1;
              else begin e_rx <= 1; v_crc <= !ovf; v_ovf <= ovf; end
            end else if (rw == SYNC) begin rs <= RI; e_rx <= 1; v_abort <= 1; end
            else begin
              if (rcnt == 10) ovf <= 1; else rcnt <= rcnt + 1;
              if (rcnt < 9) fis[rcnt] <= rw;
              rlast <= rw; rcrc_p <= rcrc; rcrc <= crc32(rcrc, rw);
            end
          end
          default: begin
            rto <= rto + 1;
            if (rw == SYNC) rs <= RI;
            else if (rto == 63) begin rs <= RI; e_rx <= 1; v_rs_to <= 1; end
          end
        endcase
    end
  end

  // link layer: frame sender
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ss <= SI; sto <= 0; sidx <= 0; scrc <= 0; retry <= 0; s_ok_p <= 0; s_fail_p <= 0; e_tx <= 0;
    end else begin
      s_ok_p <= 0; s_fail_p <= 0; e_tx <= 0;
      {v_resend, v_give_up, v_x_to, v_w_to, v_garbage_w} <= '0;
      if (ph != READY) begin ss <= SI; retry <= 0; end
      else case (ss)
        SI: if (tbd && req && !s_ok_p && !s_fail_p && rs == RI && !x_in) begin ss <= SX; sto <= 0; end
        SX:
          if (x_in) ss <= SI;
          else if (rq && rw == RRDY) ss <= SS;
          else if (tbd) begin
            sto <= sto + 1;
            if (sto == 63) begin ss <= SI; s_fail_p <= 1; e_tx <= 1; retry <= 0; v_x_to <= 1; end
          end
        SS: if (tbd) begin ss <= SD; sidx <= 0; scrc <= 32'hFFFF_FFFF; end
        SD: if (tbd) begin
          scrc <= crc32(scrc, fis_word(sidx));
          sidx <= sidx + 1;
          if (sidx == (dat ? 8 : 4)) ss <= SC;
        end
        SC: if (tbd) ss <= SE;
        SE: if (tbd) begin ss <= SW; sto <= 0; end
        default:
          if (rq && rw == ROK) begin ss <= SI; s_ok_p <= 1; retry <= 0; end
          else if (rq && rw == RERR) begin
            ss <= SI;
            if (retry == 2) begin s_fail_p <= 1; e_tx <= 1; retry <= 0; v_give_up <= 1; end
            else begin retry <= retry + 1; v_resend <= 1; end
          end else begin
            v_garbage_w <= rq && !prim(rw);
            if (tbd) begin
              sto <= sto + 1;
              if (sto == 63) begin ss <= SI; s_fail_p <= 1; e_tx <= 1; retry <= 0; v_w_to <= 1; end
            end
          end
      endcase
    end
  end

  // transport: command script
  wire [7:0] ft    = fis[0][7:0];
  wire       f_d2h = ft == 8'h34 && rcnt == 6;
  wire       f_dat = ft == 8'h46 && rcnt == 10;
  wire       f_act = ft == 8'h39 && rcnt == 2;
  wire       st_ok = !fis[0][16] && fis[0][31:24] == 0;
  wire       due   = fv || ct == 4095;
  wire       waits = cs == C_IDD || cs == C_IDS || cs == C_WRA || cs == C_WRS || cs == C_RDD ||
                     cs == C_RDS;
  logic      bad;
  always_comb begin
    bad = 0;
    for (int i = 0; i < 8; i++) if (fis[i + 1] != wd[i]) bad = 1;
  end

  task automatic advance;
    cs <= C_FILL; k <= 0; lba <= (lba == maxl) ? 0 : lba + 1;
    v_wrap <= lba == maxl;
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs <= C_START; k <= 0; lba <= 0; maxl <= 0; ct <= 0; cmd <= 0; req <= 0; dat <= 0;
      e_cmd <= 0; xs <= 32'h2545_F491;
      for (int i = 0; i < 8; i++) wd[i] <= 0;
    end else begin
      e_cmd <= 0;
      {v_unsol, v_id_retry, v_wr_ok, v_rd_ok, v_mismatch, v_st_err, v_ct_to, v_wrong, v_wrap} <= '0;
      if (s_ok_p || s_fail_p) req <= 0;
      ct <= (ct + 1) % 4096;
      if (ph != READY) begin cs <= C_START; req <= 0; end
      else begin
        if (fv && !waits) begin e_cmd <= 1; v_unsol <= 1; end
        if (due && waits) begin
          v_ct_to <= !fv;
          v_st_err <= fv && f_d2h && !st_ok;
          v_wrong <= fv && !f_d2h && !f_dat && !f_act;
        end
        case (cs)
          C_START: begin cs <= C_ID; cmd <= 0; dat <= 0; req <= 1; end
          C_ID: if (s_ok_p) begin cs <= C_IDD; ct <= 0; end
                else if (s_fail_p) req <= 1;
          C_IDD: if (due) begin
            if (fv && f_dat) begin cs <= C_IDS; ct <= 0; maxl <= fis[1][5:0]; end
            else begin cs <= C_ID; req <= 1; e_cmd <= 1; v_id_retry <= 1; end
          end
          C_IDS: if (due) begin
            if (fv && f_d2h && st_ok) begin cs <= C_FILL; lba <= 0; k <= 0; end
            else begin cs <= C_ID; req <= 1; e_cmd <= 1; v_id_retry <= 1; end
          end
          C_FILL: begin
            wd[k] <= xs; xs <= xsh(xs); k <= k + 1;
            if (k == 7) begin cs <= C_WR; cmd <= 1; dat <= 0; req <= 1; end
          end
          C_WR, C_WRD, C_RD:
            if (s_ok_p) begin cs <= cs + 1; ct <= 0; end
            else if (s_fail_p) advance();
          C_WRA: if (due) begin
            if (fv && f_act) begin cs <= C_WRD; dat <= 1; req <= 1; end
            else begin advance(); e_cmd <= 1; end
          end
          C_WRS: if (due) begin
            if (fv && f_d2h && st_ok) begin cs <= C_RD; cmd <= 2; dat <= 0; req <= 1; v_wr_ok <= 1; end
            else begin advance(); e_cmd <= 1; end
          end
          C_RDD: if (due) begin
            if (fv && f_dat) begin
              cs <= C_RDS; ct <= 0;
              if (bad) begin e_cmd <= 1; v_mismatch <= 1; end
            end else begin advance(); e_cmd <= 1; end
          end
          default: if (due) begin
            advance();
            if (!(fv && f_d2h && st_ok)) e_cmd <= 1; else v_rd_ok <= 1;
          end
        endcase
      end
    end
  end

  // predicted line: OOB bursts, then the dword stream
  wire [6:0] per   = (ph == COMRESET) ? 7'd64 : 7'd32;
  wire [6:0] off   = 7'(pos % per);
  wire       burst = (ph == COMRESET || ph == COMWAKE) && off >= per - 16;
  wire       m_on  = burst || dw_on;
  wire       m_bit = burst ? off[0] : tsr[0];

  // covergroup: frames sent (kind x outcome, attempt), frames received
  // (type, length, verdict), the LBA walk
  int c_sk, c_so, c_sr, c_rt, c_rl, c_rg, c_lb;
  always @(posedge clk) begin
    c_sk = -1; c_rt = -1; c_lb = -1; c_sr = -1;
    if (rst_n && ph == READY && ss == SW && rq && rw == ROK) c_sr = retry;
    if (rst_n && ph == READY && (s_ok_p || s_fail_p)) begin
      c_sk = dat ? 3 : cmd; c_so = s_ok_p;
    end
    if (rst_n && ph == READY && rq && rs == RD && rw == EOF) begin
      c_rt = ft == 8'h34 ? 0 : ft == 8'h46 ? 1 : ft == 8'h39 ? 2 : 3;
      c_rl = ovf ? 11 : rcnt;
      c_rg = !ovf && rcnt >= 2 && rlast == ~rcrc_p;
    end
    if (rst_n && v_wrap) c_lb = 2;
    else if (rst_n && v_wr_ok) c_lb = lba == 0 ? 0 : 1;
  end
  covergroup cg_sata @(negedge clk);
    cp_skind: coverpoint c_sk iff (c_sk >= 0) { bins identify = {0}; bins wr_cmd = {1}; bins rd_cmd = {2}; bins wr_data = {3}; }
    cp_sok: coverpoint c_so iff (c_sk >= 0) { bins fail = {0}; bins ok = {1}; }
    x_send: cross cp_skind, cp_sok;
    cp_try: coverpoint c_sr iff (c_sr >= 0) { bins first = {0}; bins second = {1}; bins third = {2}; }
    cp_rtype: coverpoint c_rt iff (c_rt >= 0) { bins d2h = {0}; bins data = {1}; bins dma_act = {2}; bins other = {3}; }
    cp_rlen: coverpoint c_rl iff (c_rt >= 0) { bins act = {2}; bins mid = {[3:5]}; bins d2h = {6};
                                               bins data = {10}; bins over = {11}; }
    cp_rgood: coverpoint c_rg iff (c_rt >= 0) { bins bad = {0}; bins good = {1}; }
    cp_lba: coverpoint c_lb iff (c_lb >= 0) { bins first = {0}; bins middle = {1}; bins wrap = {2}; }
  endgroup
  cg_sata u_cg_sata = new();

  `SVA_RST(a_reset_outputs, !rst_n, !tx_p && !tx_n && !irq)
  `SVA_INV(a_tx_p, tx_p == (m_on && m_bit))
  `SVA_INV(a_tx_n, tx_n == (m_on && !m_bit))
  `SVA_INV(a_irq, irq == (e_link || e_rx || e_tx || e_cmd))
  `SVA_IMP(a_idle_is_both_low, !tx_p && !tx_n, !m_on)

  `FC(cominit_detected, v_init)
  `FC(comwake_detected, v_wake)
  `FC(oob_burst_too_short, v_short)
  `FC(oob_gap_classes_mixed, v_mixed)
  `FC(oob_gap_neither_class, v_odd_gap)
  `FC(no_cominit_retry, v_retry_init)
  `FC(no_comwake_retry, v_retry_wake)
  `FC(no_align_retry, v_retry_align)
  `FC(align_hunt_slip, v_slip)
  `FC(link_loss, v_loss)
  `FC(illegal_primitive, v_illegal)
  `FC(rx_xrdy_without_sof_timeout, v_rr_to)
  `FC(rx_xrdy_withdrawn, v_withdraw)
  `FC(rx_crc_error, v_crc)
  `FC(rx_frame_too_long, v_ovf)
  `FC(rx_frame_aborted, v_abort)
  `FC(rx_no_sync_after_status, v_rs_to)
  `FC(xrdy_collision, v_collide)
  `FC(tx_resend_on_rerr, v_resend)
  `FC(tx_give_up_after_rerr, v_give_up)
  `FC(tx_no_rrdy_timeout, v_x_to)
  `FC(tx_no_status_timeout, v_w_to)
  `FC(tx_garbage_while_waiting, v_garbage_w)
  `FC(unsolicited_fis, v_unsol)
  `FC(identify_retry, v_id_retry)
  `FC(write_complete, v_wr_ok)
  `FC(read_complete, v_rd_ok)
  `FC(read_data_mismatch, v_mismatch)
  `FC(status_error, v_st_err)
  `FC(command_timeout, v_ct_to)
  `FC(unexpected_fis, v_wrong)
  `FC(lba_wrap, v_wrap)
  `FC_RST(reset_while_ready, rst_n && ph == READY ##1 !rst_n)
endmodule

bind SATA_top SATA_sva u_sva (.clk, .rst_n, .rx_p, .rx_n, .tx_p, .tx_n, .irq);
