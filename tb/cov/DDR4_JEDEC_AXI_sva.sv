// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// DDR4_JEDEC_AXI checker: an independent model of both ports of the IP.
//  * AXI4 side: burst walkers (FIXED / INCR / WRAP), response and ID
//    prediction (SLVERR for AxSIZE > 2 and for a WLAST on the wrong beat),
//    handshake rules, a byte shadow memory of completed writes that checks
//    every read byte whose last write finished (B) before the read's AR, and
//    the status counters and error pulse.
//  * DDR4 command pins (1:1 with CK, read as the controller drives them):
//    command decode, a per-bank page model and every JESD79-4 spacing the
//    controller must keep (tRCD, tRP, tRAS, tRC, tRRD_S/L, tFAW, tCCD_S/L,
//    tWTR_S/L, read-to-write, tWR, tRTP, tRFC, tMRD, tMOD, tXPR, tZQinit),
//    the power-up order, the mode register values and the refresh interval.
// The model runs on the rising edge: AXI inputs (driven at the falling edge
// by the testbench) are read directly, DUT outputs through copies taken at
// the falling edge. Assertions use sampled values.
`include "cov_macros.svh"
module DDR4_JEDEC_AXI_sva #(
  parameter int NDEV = 1, IDW = 4, ROWB = 16, COLB = 10, BGB = 1, BAB = 2,
  parameter int CL = 22, CWL = 16,
  parameter int T_RCD = 22, T_RP = 22, T_RAS = 52, T_RC = 74, T_RRD_S = 9, T_RRD_L = 11,
  parameter int T_FAW = 48, T_CCD_S = 4, T_CCD_L = 8, T_WTR_S = 4, T_WTR_L = 12,
  parameter int T_WR = 24, T_RTP = 12, T_RFC = 560, T_REFI = 12480, T_MRD = 8, T_MOD = 24,
  parameter int T_ZQINIT = 1024, T_XPR = 576, T_RESET = 64, T_CKE = 64
) (
  input logic           clk, rst_n,
  input logic [IDW-1:0] s_awid, s_arid, s_bid, s_rid,
  input logic [31:0]    s_awaddr, s_araddr, s_wdata, s_rdata,
  input logic [7:0]     s_awlen, s_arlen,
  input logic [2:0]     s_awsize, s_arsize,
  input logic [1:0]     s_awburst, s_arburst, s_bresp, s_rresp,
  input logic [3:0]     s_wstrb,
  input logic           s_awvalid, s_awready, s_wvalid, s_wready, s_wlast, s_bvalid, s_bready,
  input logic           s_arvalid, s_arready, s_rvalid, s_rready, s_rlast,
  input logic           p_reset_n, p_cke, p_odt, p_cs_n, p_act_n, p_ras_n, p_cas_n, p_we_n, p_wr,
  input logic [1:0]     p_bg, p_ba,
  input logic [13:0]    p_a,
  input logic           init_done, err_irq,
  input logic [15:0]    n_rd, n_wr, n_err, n_act, n_hit, n_ref,
  input logic [2:0]     rf_n
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB    = 1 << (BGB + BAB);
  localparam int BB    = 16 * NDEV;                 // bytes per DRAM burst
  localparam int RAW   = $clog2(BB) + COLB - 3 + BGB + BAB + ROWB;
  localparam int T_WRD = CWL + 4;
  localparam int T_RTW = CL + 6 - CWL;
  localparam longint NEVER = -(64'sd1 << 40);
  localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;
  localparam logic [1:0] FIXED = 2'b00, INCR = 2'b01, WRAP = 2'b10;
  // the longest a REF can trail its due time: PREA waits out tRAS / tWR / tRTP,
  // then tRP, then REF waits out tRC / tRFC of the last ACT
  localparam int REF_LAG = (T_RAS > T_WRD + T_WR ? T_RAS : T_WRD + T_WR) + T_RP + T_RC + 4;

  longint cyc;
  always @(posedge clk) cyc <= rst_n ? cyc + 1 : 0;

  // ======================= AXI4 =======================
  wire aw_hs = s_awvalid && s_awready, w_hs = s_wvalid && s_wready, b_hs = s_bvalid && s_bready;
  wire ar_hs = s_arvalid && s_arready, r_hs = s_rvalid && s_rready;

  function automatic logic [31:0] nxt(input logic [31:0] a, input logic [2:0] sz,
                                      input logic [7:0] len, input logic [1:0] bt);
    logic [31:0] inc, wm;
    inc = 32'd1 << sz;
    if (bt == FIXED) return a;
    if (bt == WRAP) begin
      wm = (32'(len) + 1) * inc - 1;
      return (a & ~wm) | (((a & ~(inc - 1)) + inc) & wm);
    end
    return (a & ~(inc - 1)) + inc;
  endfunction
  function automatic int unsigned mem_of(input logic [31:0] a);   // device byte (aliases above RAW)
    return int'(a & ((32'd1 << RAW) - 1));
  endfunction

  // copies of DUT outputs taken at the falling edge
  logic          q_bvalid, q_rvalid, q_rlast, q_wready, q_awready, q_arready;
  logic [1:0]    q_bresp;
  logic          q_cs_n, q_act_n, q_ras_n, q_cas_n, q_we_n, q_reset_n, q_cke;
  logic [1:0]    q_bg, q_ba;
  logic [13:0]   q_a;
  always @(negedge clk) begin
    q_bvalid <= s_bvalid; q_rvalid <= s_rvalid; q_rlast <= s_rlast; q_wready <= s_wready;
    q_awready <= s_awready; q_arready <= s_arready; q_bresp <= s_bresp;
    q_cs_n <= p_cs_n; q_act_n <= p_act_n; q_ras_n <= p_ras_n; q_cas_n <= p_cas_n; q_we_n <= p_we_n;
    q_bg <= p_bg; q_ba <= p_ba; q_a <= p_a; q_reset_n <= p_reset_n; q_cke <= p_cke;
  end
  wire qb_hs = q_bvalid && s_bready, qr_hs = q_rvalid && s_rready, qw_hs = s_wvalid && q_wready;
  wire qaw_hs = s_awvalid && q_awready, qar_hs = s_arvalid && q_arready;

  // write burst model
  logic           m_wbusy, m_wdone, m_werr;
  logic [IDW-1:0] m_wid;
  logic [31:0]    m_wa;
  logic [2:0]     m_wsz;
  logic [7:0]     m_wlen, m_wbeat;
  logic [1:0]     m_wbu;
  logic           m_wlate;                 // no WLAST on the last beat
  // read burst model
  logic           m_rbusy, m_rerr;
  logic [IDW-1:0] m_rid;
  logic [31:0]    m_ra;
  logic [2:0]     m_rsz;
  logic [7:0]     m_rlen, m_rbeat;
  logic [1:0]     m_rbu;
  longint         m_rt0;                    // AR handshake cycle
  // shadow memory: byte value, cycle its write burst completed (B), or
  // pending / unknown
  byte unsigned   sh_v [int unsigned];
  longint         sh_b [int unsigned];      // B cycle; NEVER - 1: pending; 0: unknown
  int unsigned    wb_a [$];                 // bytes the burst in flight wrote
  // counters
  logic [15:0]    c_rd, c_wr, c_err;
  logic           irq_exp;

  wire [3:0] w_lanes = 4'((32'd1 << (32'd1 << m_wsz)) - 1) << (m_wa[1:0] & ~2'((32'd1 << m_wsz) - 1));
  wire [3:0] r_lanes = 4'((32'd1 << (32'd1 << m_rsz)) - 1) << (m_ra[1:0] & ~2'((32'd1 << m_rsz) - 1));
  wire       w_last_exp = m_wbeat == m_wlen;
  wire       w_last_bad = s_wlast != w_last_exp;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_wbusy <= 0; m_wdone <= 0; m_werr <= 0; m_wid <= '0; m_wa <= '0; m_wsz <= '0;
      m_wlen <= '0; m_wbeat <= '0; m_wbu <= '0; m_wlate <= 0;
      m_rbusy <= 0; m_rerr <= 0; m_rid <= '0; m_ra <= '0; m_rsz <= '0;
      m_rlen <= '0; m_rbeat <= '0; m_rbu <= '0; m_rt0 <= 0;
      c_rd <= '0; c_wr <= '0; c_err <= '0; irq_exp <= 0;
      wb_a.delete();
    end else begin
      irq_exp <= 0;
      if (qaw_hs) begin
        m_wbusy <= 1; m_wdone <= 0; m_wid <= s_awid; m_wa <= s_awaddr; m_wsz <= s_awsize;
        m_wlen <= s_awlen; m_wbeat <= '0; m_wbu <= s_awburst; m_werr <= s_awsize > 3'd2;
        m_wlate <= 0;
      end
      if (qw_hs) begin
        if (!m_werr && !w_last_bad) begin
          for (int b = 0; b < 4; b++)
            if (s_wstrb[b] && w_lanes[b]) begin
              int unsigned k;
              k = mem_of({m_wa[31:2], 2'(b)});
              sh_v[k] = s_wdata[8*b +: 8];
              sh_b[k] = NEVER - 1;
              wb_a.push_back(k);
            end
        end
        if (!m_werr && w_last_bad) begin
          // blocks already sent may or may not have reached the device
          m_werr <= 1;
          foreach (wb_a[i]) sh_b[wb_a[i]] = 0;
          if (!s_wlast) m_wlate <= 1;
        end
        m_wa    <= nxt(m_wa, m_wsz, m_wlen, m_wbu);
        m_wbeat <= m_wbeat + 1'b1;
        if (s_wlast) m_wdone <= 1;
      end
      if (qb_hs) begin
        if (q_bresp == OKAY) foreach (wb_a[i]) sh_b[wb_a[i]] = cyc;
        wb_a.delete();
        m_wbusy <= 0; m_wdone <= 0;
        c_wr <= c_wr + 1'b1;
        if (m_werr) begin c_err <= c_err + 1'b1; irq_exp <= 1; end
      end
      if (qar_hs) begin
        m_rbusy <= 1; m_rid <= s_arid; m_ra <= s_araddr; m_rsz <= s_arsize; m_rlen <= s_arlen;
        m_rbeat <= '0; m_rbu <= s_arburst; m_rerr <= s_arsize > 3'd2; m_rt0 <= cyc;
      end
      if (qr_hs) begin
        m_ra    <= nxt(m_ra, m_rsz, m_rlen, m_rbu);
        m_rbeat <= m_rbeat + 1'b1;
        if (q_rlast) begin
          m_rbusy <= 0;
          c_rd <= c_rd + 1'b1;
          if (m_rerr) begin c_err <= c_err + 1'b1; irq_exp <= 1; end
        end
      end
    end
  end

  // read byte check: the byte's last write completed before this read's AR
  function automatic logic rbyte_ok(input int b);
    int unsigned k;
    k = mem_of({m_ra[31:2], 2'(b)});
    if (!sh_b.exists(k)) return 1'b1;             // never written: device init pattern
    if (sh_b[k] <= 0 || sh_b[k] >= m_rt0) return 1'b1;   // unknown, pending or racing
    return s_rdata[8*b +: 8] == sh_v[k];
  endfunction
  function automatic logic rdata_ok();
    for (int b = 0; b < 4; b++) if (r_lanes[b] && !rbyte_ok(b)) return 1'b0;
    return 1'b1;
  endfunction
  // a read beat that has at least one byte the shadow can check
  function automatic logic rdata_known();
    for (int b = 0; b < 4; b++)
      if (r_lanes[b]) begin
        int unsigned k;
        k = mem_of({m_ra[31:2], 2'(b)});
        if (sh_b.exists(k) && sh_b[k] > 0 && sh_b[k] < m_rt0) return 1'b1;
      end
    return 1'b0;
  endfunction

  // ---------------- AXI assertions ----------------
  `SVA_RST(a_reset_quiet, !rst_n, !s_bvalid && !s_rvalid && !s_wready && p_cs_n && !p_reset_n &&
           !p_cke && !init_done && !p_wr && n_rd == 0 && n_wr == 0 && n_err == 0 && n_act == 0 &&
           n_hit == 0 && n_ref == 0 && !err_irq)
  `SVA_IMP(a_aw_only_idle, s_awready, !m_wbusy)
  `SVA_IMP(a_ar_only_idle, s_arready, !m_rbusy)
  `SVA_IMP(a_wready_in_burst, s_wready, m_wbusy && !m_wdone)
  `SVA_IMP(a_bvalid_after_last, s_bvalid, m_wbusy && m_wdone)
  `SVA_IMP(a_rvalid_in_burst, s_rvalid, m_rbusy)
  `SVA_NXT(a_b_stable, s_bvalid && !s_bready, s_bvalid && $stable(s_bresp) && $stable(s_bid))
  `SVA_NXT(a_r_stable, s_rvalid && !s_rready,
           s_rvalid && $stable(s_rdata) && $stable(s_rresp) && $stable(s_rlast) && $stable(s_rid))
  `SVA_IMP(a_bresp_ok, s_bvalid && !m_werr, s_bresp == OKAY && s_bid == m_wid)
  `SVA_IMP(a_bresp_err, s_bvalid && m_werr, s_bresp == SLVERR && s_bid == m_wid)
  `SVA_IMP(a_rresp_ok, s_rvalid && !m_rerr, s_rresp == OKAY && s_rid == m_rid)
  `SVA_IMP(a_rresp_err, s_rvalid && m_rerr, s_rresp == SLVERR && s_rid == m_rid && s_rdata == '0)
  `SVA_IMP(a_rlast, s_rvalid, s_rlast == (m_rbeat == m_rlen))
  `SVA_IMP(a_rdata, s_rvalid && !m_rerr && rdata_known(), rdata_ok())
  `SVA_INV(a_counters, n_rd == c_rd && n_wr == c_wr && n_err == c_err)
  `SVA_INV(a_irq, err_irq == irq_exp)
  `SVA_INV(a_rfifo_depth, rf_n <= 3'd4)

  // ======================= DDR4 command pins =======================
  typedef enum logic [3:0] {
    C_NOP, C_ACT, C_RD, C_WR, C_PRE, C_PREA, C_REF, C_MRS, C_ZQCL, C_BAD
  } cmd_e;
  function automatic cmd_e dec(input logic cs_n, act_n, ras_n, cas_n, we_n, input logic [13:0] a);
    if (cs_n)   return C_NOP;
    if (!act_n) return C_ACT;
    case ({ras_n, cas_n, we_n})
      3'b111: return C_NOP;
      3'b101: return C_RD;
      3'b100: return C_WR;
      3'b010: return a[10] ? C_PREA : C_PRE;
      3'b001: return C_REF;
      3'b000: return C_MRS;
      3'b110: return a[10] ? C_ZQCL : C_BAD;    // ZQCS is never used
      default: return C_BAD;
    endcase
  endfunction
  // assertions and covergroups: the pins themselves (sampled)
  cmd_e cmd;
  assign cmd = dec(p_cs_n, p_act_n, p_ras_n, p_cas_n, p_we_n, p_a);
  wire [BGB+BAB-1:0] bk   = {p_bg[BGB-1:0], p_ba[BAB-1:0]};
  wire [BGB-1:0]     grp  = p_bg[BGB-1:0];
  wire [16:0]        arow = {p_ras_n, p_cas_n, p_we_n, p_a};
  // the model: falling-edge copies of the same pins
  cmd_e qcmd;
  assign qcmd = dec(q_cs_n, q_act_n, q_ras_n, q_cas_n, q_we_n, q_a);
  wire [BGB+BAB-1:0] qbk  = {q_bg[BGB-1:0], q_ba[BAB-1:0]};
  wire [BGB-1:0]     qgrp = q_bg[BGB-1:0];
  wire [16:0]        qrow = {q_ras_n, q_cas_n, q_we_n, q_a};

  // page and timing model
  logic [NB-1:0]   d_open;
  logic [16:0]     d_row  [NB];
  longint          t_act  [NB], t_pre [NB], t_rd [NB], t_wr [NB];
  longint          t_actg [1 << BGB], t_casg [1 << BGB], t_wrg [1 << BGB];
  longint          t_acta, t_casa, t_wra, t_rda, t_ref, t_mrs, t_zq, t_cke, t_rsth, t_prea;
  longint          t_faw  [4];
  logic [1:0]      faw_p;
  logic [2:0]      mrs_k;                  // MRS commands since reset
  logic            zq_done;
  logic [15:0]     c_act, c_ref, c_hit;
  logic            miss;
  logic            pre_since, act_since;   // PRE / ACT since the last RD / WR
  longint          t_rst;                  // first clock out of reset
  logic            reset_n_q, cke_q;
  // MR numbers in the required order MR3 MR6 MR5 MR4 MR2 MR1 MR0
  function automatic logic [2:0] mr_exp(input logic [2:0] k);
    case (k) 0: return 3; 1: return 6; 2: return 5; 3: return 4; 4: return 2; 5: return 1;
      default: return 0; endcase
  endfunction
  // JESD79-4 decodes
  function automatic int cl_dec(input logic [13:0] a);
    case ({a[12], a[6:4], a[2]})
      0: return 9;   1: return 10;  2: return 11;  3: return 12;  4: return 13;  5: return 14;
      6: return 15;  7: return 16;  8: return 18;  9: return 20;  10: return 22; 11: return 24;
      12: return 23; 13: return 17; 14: return 19; 15: return 21; default: return 0;
    endcase
  endfunction
  function automatic int wr_dec(input logic [13:0] a);
    case ({a[13], a[11:9]})
      0: return 10; 1: return 12; 2: return 14; 3: return 16; 4: return 18; 5: return 20;
      6: return 24; 7: return 22; 8: return 26; default: return 0;
    endcase
  endfunction
  function automatic int cwl_dec(input logic [13:0] a);
    case (a[5:3])
      0: return 9; 1: return 10; 2: return 11; 3: return 12; 4: return 14; 5: return 16;
      6: return 18; default: return 20;
    endcase
  endfunction
  function automatic logic mr_ok(input logic [2:0] n, input logic [13:0] a);
    case (n)
      0: return cl_dec(a) == CL && a[1:0] == 2'b00 && a[8] && wr_dec(a) >= T_WR;   // BL8, DLL reset
      1: return a[0];                                                         // DLL enable
      2: return cwl_dec(a) == CWL;
      5: return a[10];                                                        // DM_n enable
      6: return int'(a[12:10]) == T_CCD_L - 4;
      default: return 1'b1;
    endcase
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      d_open <= '0;
      for (int b = 0; b < NB; b++) begin
        d_row[b] <= '0; t_act[b] <= NEVER; t_pre[b] <= NEVER; t_rd[b] <= NEVER; t_wr[b] <= NEVER;
      end
      for (int g = 0; g < (1 << BGB); g++) begin
        t_actg[g] <= NEVER; t_casg[g] <= NEVER; t_wrg[g] <= NEVER;
      end
      t_acta <= NEVER; t_casa <= NEVER; t_wra <= NEVER; t_rda <= NEVER; t_ref <= NEVER;
      t_mrs <= NEVER; t_zq <= NEVER; t_cke <= NEVER; t_rsth <= NEVER; t_prea <= NEVER;
      for (int i = 0; i < 4; i++) t_faw[i] <= NEVER;
      faw_p <= 0; mrs_k <= 0; zq_done <= 0; c_act <= 0; c_ref <= 0; c_hit <= 0; miss <= 0;
      pre_since <= 0; act_since <= 0;
      t_rst <= -1; reset_n_q <= 0; cke_q <= 0;
    end else begin
      if (t_rst < 0) t_rst <= cyc;
      reset_n_q <= q_reset_n; cke_q <= q_cke;
      if (q_reset_n && !reset_n_q) t_rsth <= cyc;
      if (q_cke && !cke_q) t_cke <= cyc;
      case (qcmd)
        C_ACT: begin
          d_open[qbk] <= 1; d_row[qbk] <= qrow; t_act[qbk] <= cyc; t_actg[qgrp] <= cyc;
          t_acta <= cyc; t_faw[faw_p] <= cyc; faw_p <= faw_p + 1'b1;
          c_act <= c_act + 1'b1; miss <= 1; act_since <= 1;
        end
        C_RD, C_WR: begin
          if (!miss) c_hit <= c_hit + 1'b1;
          miss <= 0; pre_since <= 0; act_since <= 0;
          t_casg[qgrp] <= cyc; t_casa <= cyc;
          if (qcmd == C_RD) begin t_rd[qbk] <= cyc; t_rda <= cyc; end
          else begin t_wr[qbk] <= cyc; t_wrg[qgrp] <= cyc; t_wra <= cyc; end
        end
        C_PRE: begin d_open[qbk] <= 0; t_pre[qbk] <= cyc; miss <= 1; pre_since <= 1; end
        C_PREA: begin
          d_open <= '0; t_prea <= cyc;
          for (int b = 0; b < NB; b++) t_pre[b] <= cyc;
        end
        C_REF: begin t_ref <= cyc; c_ref <= c_ref + 1'b1; end
        C_MRS: begin t_mrs <= cyc; mrs_k <= mrs_k + 1'b1; end
        C_ZQCL: begin t_zq <= cyc; zq_done <= 1; end
        default: ;
      endcase
    end
  end

  function automatic logic gap(input longint t, input int n);
    return cyc - t >= n;
  endfunction
  function automatic logic prea_ok();       // every open bank has met tRAS, tRTP and tWR
    for (int b = 0; b < NB; b++)
      if (d_open[b] && !(gap(t_act[b], T_RAS) && gap(t_rd[b], T_RTP) && gap(t_wr[b], T_WRD + T_WR)))
        return 1'b0;
    return 1'b1;
  endfunction
  function automatic logic ref_ok();        // every bank closed, tRP and tRC met
    for (int b = 0; b < NB; b++)
      if (d_open[b] || !gap(t_pre[b], T_RP) || !gap(t_act[b], T_RC)) return 1'b0;
    return 1'b1;
  endfunction

  wire is_act = cmd == C_ACT, is_rd = cmd == C_RD, is_wr = cmd == C_WR, is_cas = is_rd || is_wr;
  wire is_pre = cmd == C_PRE, is_prea = cmd == C_PREA, is_ref = cmd == C_REF;
  wire is_mrs = cmd == C_MRS, is_zq = cmd == C_ZQCL;

  // ---------------- power-up and init ----------------
  `SVA_IMP(a_tinit1, $rose(p_reset_n), cyc - t_rst >= T_RESET - 1)
  `SVA_IMP(a_tinit3, $rose(p_cke), p_reset_n && gap(t_rsth, T_CKE))
  `SVA_IMP(a_cke_stays, p_cke, p_reset_n)
  `SVA_IMP(a_cmd_needs_cke, !p_cs_n, p_cke && p_reset_n)
  `SVA_IMP(a_txpr, is_mrs && mrs_k == 0, gap(t_cke, T_XPR))
  `SVA_IMP(a_mrs_order, is_mrs, !zq_done && mrs_k < 7 && {p_bg[0], p_ba} == mr_exp(mrs_k) &&
           mr_ok({p_bg[0], p_ba}, p_a) && p_bg[1] == 1'b0)
  `SVA_IMP(a_tmrd, is_mrs && mrs_k != 0, gap(t_mrs, T_MRD))
  `SVA_IMP(a_tmod, is_zq, mrs_k == 7 && gap(t_mrs, T_MOD) && !zq_done)
  `SVA_IMP(a_tzqinit, $rose(init_done), zq_done && gap(t_zq, T_ZQINIT))
  `SVA_IMP(a_run_after_init, is_act || is_cas || is_pre || is_prea || is_ref, init_done)
  `SVA_INV(a_odt_off, !p_odt)
  `SVA_IMP(a_legal_cmd, !p_cs_n, cmd != C_BAD)

  // ---------------- page model ----------------
  `SVA_IMP(a_act_closed, is_act, !d_open[bk])
  `SVA_IMP(a_cas_open, is_cas, d_open[bk] && p_a[12] && p_a[2:0] == 3'b000)
  `SVA_IMP(a_pre_open, is_pre, d_open[bk])
  `SVA_IMP(a_ref_closed, is_ref, ref_ok())
  `SVA_IMP(a_wr_data, p_wr, is_wr)
  `SVA_IMP(a_wr_has_data, is_wr, p_wr)

  // ---------------- JESD79-4 spacings ----------------
  `SVA_IMP(a_trcd, is_cas, gap(t_act[bk], T_RCD))
  `SVA_IMP(a_trp, is_act, gap(t_pre[bk], T_RP))
  `SVA_IMP(a_trc, is_act, gap(t_act[bk], T_RC))
  `SVA_IMP(a_trfc, is_act, gap(t_ref, T_RFC))
  `SVA_IMP(a_trrd_l, is_act, gap(t_actg[grp], T_RRD_L))
  `SVA_IMP(a_trrd_s, is_act, gap(t_acta, T_RRD_S))
  `SVA_IMP(a_tfaw, is_act, gap(t_faw[faw_p], T_FAW))
  `SVA_IMP(a_tras, is_pre, gap(t_act[bk], T_RAS))
  `SVA_IMP(a_trtp, is_pre, gap(t_rd[bk], T_RTP))
  `SVA_IMP(a_twr, is_pre, gap(t_wr[bk], T_WRD + T_WR))
  `SVA_IMP(a_prea, is_prea, prea_ok())
  `SVA_IMP(a_tccd_l, is_cas, gap(t_casg[grp], T_CCD_L))
  `SVA_IMP(a_tccd_s, is_cas, gap(t_casa, T_CCD_S))
  `SVA_IMP(a_twtr_l, is_rd, gap(t_wrg[grp], T_WRD + T_WTR_L))
  `SVA_IMP(a_twtr_s, is_rd, gap(t_wra, T_WRD + T_WTR_S))
  `SVA_IMP(a_trtw, is_wr, gap(t_rda, T_RTW))
  `SVA_IMP(a_trfc_ref, is_ref, gap(t_ref, T_RFC))
  // refresh: REF to REF within tREFI plus the PREA / tRP / tRC lag either way
  `SVA_IMP(a_refi, is_ref && t_ref != NEVER, cyc - t_ref <= T_REFI + REF_LAG && cyc - t_ref >= T_REFI - REF_LAG)
  `SVA_IMP(a_ref_starve, init_done && t_ref != NEVER, cyc - t_ref <= T_REFI + REF_LAG)
  // the controller counts a command when it drives it; the model one clock later
  `SVA_INV(a_dram_counters, n_act == c_act + 16'(is_act) && n_ref == c_ref + 16'(is_ref) &&
           n_hit == c_hit + 16'(is_cas && !miss))

  // ======================= functional coverage =======================
  function automatic logic [1:0] dcls(input logic [31:0] v);
    return (v == '0) ? 2'd0 : (v == '1) ? 2'd1 : (v == 32'h5555_5555 || v == 32'hAAAA_AAAA) ? 2'd2 : 2'd3;
  endfunction
  covergroup cg_aw @(posedge clk);
    cp_burst: coverpoint s_awburst iff (rst_n && aw_hs && s_awsize <= 2)
      { bins fixed = {FIXED}; bins incr = {INCR}; bins wrap = {WRAP}; }
    cp_size: coverpoint s_awsize iff (rst_n && aw_hs)
      { bins b1 = {0}; bins b2 = {1}; bins b4 = {2}; bins b8 = {3}; bins too_big = {[4:7]}; }
    cp_lsize: coverpoint s_awsize iff (rst_n && aw_hs && s_awsize <= 2) { bins b1 = {0}; bins b2 = {1}; bins b4 = {2}; }
    x_burst_size: cross cp_burst, cp_lsize;
    cp_incr_len: coverpoint s_awlen iff (rst_n && aw_hs && s_awburst == INCR)
      { bins one = {0}; bins short = {[1:14]}; bins sixteen = {15}; bins long = {[16:254]}; bins max = {255}; }
    cp_wrap_len: coverpoint s_awlen iff (rst_n && aw_hs && s_awburst == WRAP)
      { bins w2 = {1}; bins w4 = {3}; bins w8 = {7}; bins w16 = {15}; }
    cp_fixed_len: coverpoint s_awlen iff (rst_n && aw_hs && s_awburst == FIXED)
      { bins one = {0}; bins multi = {[1:15]}; }
    cp_unaligned: coverpoint (s_awaddr[1:0] != 0) iff (rst_n && aw_hs) { bins aligned = {0}; bins unaligned = {1}; }
    cp_alias: coverpoint (s_awaddr[31:RAW] != 0) iff (rst_n && aw_hs) { bins in_device = {0}; bins aliased = {1}; }
  endgroup
  covergroup cg_ar @(posedge clk);
    cp_burst: coverpoint s_arburst iff (rst_n && ar_hs && s_arsize <= 2)
      { bins fixed = {FIXED}; bins incr = {INCR}; bins wrap = {WRAP}; }
    cp_size: coverpoint s_arsize iff (rst_n && ar_hs)
      { bins b1 = {0}; bins b2 = {1}; bins b4 = {2}; bins b8 = {3}; bins too_big = {[4:7]}; }
    cp_lsize: coverpoint s_arsize iff (rst_n && ar_hs && s_arsize <= 2) { bins b1 = {0}; bins b2 = {1}; bins b4 = {2}; }
    x_burst_size: cross cp_burst, cp_lsize;
    cp_incr_len: coverpoint s_arlen iff (rst_n && ar_hs && s_arburst == INCR)
      { bins one = {0}; bins short = {[1:14]}; bins sixteen = {15}; bins long = {[16:254]}; bins max = {255}; }
    cp_wrap_len: coverpoint s_arlen iff (rst_n && ar_hs && s_arburst == WRAP)
      { bins w2 = {1}; bins w4 = {3}; bins w8 = {7}; bins w16 = {15}; }
    cp_fixed_len: coverpoint s_arlen iff (rst_n && ar_hs && s_arburst == FIXED)
      { bins one = {0}; bins multi = {[1:15]}; }
    cp_unaligned: coverpoint (s_araddr[1:0] != 0) iff (rst_n && ar_hs) { bins aligned = {0}; bins unaligned = {1}; }
    cp_alias: coverpoint (s_araddr[31:RAW] != 0) iff (rst_n && ar_hs) { bins in_device = {0}; bins aliased = {1}; }
  endgroup
  covergroup cg_data @(posedge clk);
    cp_strb: coverpoint s_wstrb iff (rst_n && w_hs && !m_werr)
      { bins none = {0}; bins full = {4'hF}; bins b0 = {1}; bins b1 = {2}; bins b2 = {4}; bins b3 = {8};
        bins lo_half = {3}; bins hi_half = {4'hC}; bins other = default; }
    cp_wdata: coverpoint dcls(s_wdata) iff (rst_n && w_hs && !m_werr && s_wstrb == 4'hF)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls(s_rdata) iff (rst_n && r_hs && !m_rerr && m_rsz == 2)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rfifo: coverpoint rf_n iff (rst_n && r_hs && !m_rerr)
      { bins d1 = {1}; bins d2 = {2}; bins d3 = {3}; bins d4 = {4}; }
  endgroup
  covergroup cg_resp @(posedge clk);
    cp_b: coverpoint s_bresp iff (rst_n && b_hs) { bins okay = {OKAY}; bins slverr = {SLVERR}; }
    cp_r: coverpoint s_rresp iff (rst_n && r_hs && s_rlast) { bins okay = {OKAY}; bins slverr = {SLVERR}; }
    // why a write burst failed
    cp_werr: coverpoint {m_wsz > 3'd2, m_wlate} iff (rst_n && b_hs && m_werr)
      { bins size = {2'b10}; bins wlast_early = {2'b00}; bins wlast_missing = {2'b01}; }
  endgroup
  covergroup cg_dram @(posedge clk);
    cp_cmd: coverpoint cmd iff (rst_n)
      { bins nop = {C_NOP}; bins act = {C_ACT}; bins rd = {C_RD}; bins wr = {C_WR}; bins pre = {C_PRE};
        bins prea = {C_PREA}; bins ref_ = {C_REF}; bins mrs = {C_MRS}; bins zqcl = {C_ZQCL}; }
    // page outcome of each RD / WR: hit, closed bank (ACT), row conflict (PRE + ACT)
    cp_page: coverpoint {act_since, pre_since}
      iff (rst_n && is_cas) { bins hit = {2'b00}; bins closed = {2'b10}; bins conflict = {2'b11}; }
    cp_dir: coverpoint is_wr iff (rst_n && is_cas) { bins rd = {0}; bins wr = {1}; }
    x_page_dir: cross cp_page, cp_dir;
    cp_bank: coverpoint bk iff (rst_n && is_cas);
    x_bank_dir: cross cp_bank, cp_dir;
    // CAS after CAS: same or other bank group, and the direction change
    cp_cas_grp: coverpoint (t_casg[grp] == t_casa) iff (rst_n && is_cas && t_casa != NEVER)
      { bins other_group = {0}; bins same_group = {1}; }
    cp_turn: coverpoint {t_wra > t_rda, is_wr} iff (rst_n && is_cas && t_wra != NEVER && t_rda != NEVER)
      { bins rd_rd = {2'b00}; bins rd_wr = {2'b01}; bins wr_rd = {2'b10}; bins wr_wr = {2'b11}; }
    x_turn_grp: cross cp_turn, cp_cas_grp;
    cp_ref: coverpoint (t_prea > t_ref) iff (rst_n && is_ref && t_ref != NEVER)
      { bins banks_closed = {0}; bins after_prea = {1}; }
    cp_row: coverpoint arow[ROWB-1:0] iff (rst_n && is_act)
      { bins zero = {0}; bins ones = {{ROWB{1'b1}}}; bins other = default; }
    cp_col: coverpoint p_a[COLB-1:3] iff (rst_n && is_cas)
      { bins first = {0}; bins last = {{(COLB-3){1'b1}}}; bins other = default; }
  endgroup
  cg_aw u_cg_aw = new; cg_ar u_cg_ar = new; cg_data u_cg_data = new; cg_resp u_cg_resp = new;
  cg_dram u_cg_dram = new;

  `FC(b_backpressure, s_bvalid && !s_bready)
  `FC(r_backpressure, s_rvalid && !s_rready)
  `FC(aw_ar_same_cycle, aw_hs && ar_hs)
  `FC(read_during_write, m_wbusy && m_rbusy && r_hs)
  `FC(wrap_wraps, w_hs && m_wbu == WRAP && nxt(m_wa, m_wsz, m_wlen, m_wbu) < m_wa)
  `FC(read_racing_write, r_hs && m_wbusy && !m_rerr)
  `FC(ref_during_traffic, is_ref && (m_wbusy || m_rbusy))
  `FC(read_after_write_same_row, is_rd && t_wr[bk] > t_act[bk])
  `FC(data_known_read, r_hs && !m_rerr && rdata_known())
  `FC_RST(reset_in_run, !rst_n && $past(init_done))
endmodule

bind DDR4_JEDEC_AXI_top DDR4_JEDEC_AXI_sva #(
  .NDEV(NDEV), .IDW(IDW), .ROWB(ROWB), .COLB(COLB), .BGB(BGB), .BAB(BAB), .CL(CL), .CWL(CWL),
  .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS), .T_RC(T_RC), .T_RRD_S(T_RRD_S), .T_RRD_L(T_RRD_L),
  .T_FAW(T_FAW), .T_CCD_S(T_CCD_S), .T_CCD_L(T_CCD_L), .T_WTR_S(T_WTR_S), .T_WTR_L(T_WTR_L),
  .T_WR(T_WR), .T_RTP(T_RTP), .T_RFC(T_RFC), .T_REFI(T_REFI), .T_MRD(T_MRD), .T_MOD(T_MOD),
  .T_ZQINIT(T_ZQINIT), .T_XPR(T_XPR), .T_RESET(T_RESET), .T_CKE(T_CKE)
) u_sva (.*);
