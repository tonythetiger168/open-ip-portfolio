// SPDX-License-Identifier: Apache-2.0
// Shared body of the memory-controller checkers (tb/cov/<P>_sva.sv), included
// inside the checker module after the IP part, which provides:
//   localparams NB (bank entries), NCELLS (storage words), CL, TRCD, TRP,
//     TRC, TRAS, TRFC, REF_MIN / REF_MAX (REF-to-REF bounds), BUSY_MAX
//   functions bank_of(a), row_of(a), col_of(a), cellof(a), lane(a)
//     (lane = the write word on the dq lanes of a's channel, read from q_dq)
//   q_pc / q_pa / q_dq: pin command code (P_*), pin address and dq,
//     captured at the falling edge like the host outputs below
//   optional hooks: `MEM_CHK_EXTRA (statements run every clock after the
//     shared model), `MEM_CHK_AP_OK / `MEM_CHK_AP_MUST (expressions: the
//     RD / WR in flight may / must close its bank with a PRE after the burst,
//     for closed-page policies)
//   `MEM_CHK_CKE_PD: cke may drop (power-down); the IP checks it itself
//   `MEM_CHK_HIT_REOPENS: a RD / WR page hit may still PRE / ACT its bank
//     (closed-page policies); otherwise a hit must go straight to the burst
//   `MEM_CHK_REF_PB: per-entry refresh. Each REF refreshes one bank entry,
//     ref_bank_of(k) for the k-th REF since reset (k mod REF_NB), which must
//     be closed (and tRP past its PRE) while the others may stay open; a PRE
//     with no host command, or after the host command's own work, is that
//     refresh's PRE of the same entry
//   `MEM_CHK_WMASK: bit mask of the write word a WR carries (narrow modes)
//   `MEM_CHK_RW_ANY_ROW: RD / WR address a column of whatever row the bank
//     has open (legacy contract), so only a closed bank is a miss
//   posted-write hooks: `MEM_CHK_DRAINING (expression: the pin commands now
//     serve a buffered write, `MEM_CHK_DRAIN_A / `MEM_CHK_DRAIN_D, not the
//     host command), `MEM_CHK_DRAIN_POP, `MEM_CHK_ON_ACCEPT, `MEM_CHK_ON_DONE
//     (statements), `MEM_CHK_WR_DONE (expression: a host WR is complete)
// The model runs on the rising edge on values held stable around it: host
// inputs (driven at the falling edge by the TB) are read directly, DUT
// outputs through copies taken at the falling edge, so the model never races
// the DUT's own registers.
//
// What is checked, independently of the RTL's FSM:
//   * every pin command against a per-bank page model (ACT only to a closed
//     bank, RD / WR only to the open page of the addressed bank, REF only
//     with every bank closed) and the JEDEC-style minimum spacings tRCD,
//     tRP, tRC, tRAS, tRFC, plus REF-to-REF bounds (no refresh starvation);
//   * every pin command belongs to the host command in flight (or to a
//     refresh), carries that command's row / column, and was announced by the
//     trace port one clock earlier with the host address;
//   * a WR drives the host's write word on the channel's dq lanes;
//   * hdone pulses exactly once per RD, exactly CL clocks after the RD
//     command, and hrdata then holds the word last written to that cell;
//   * hready returns only once the command's work is on the pins;
//   * optional write-side spacings, for cores whose WR completes once it is
//     on the pins: `MEM_CHK_WR2PRE (WR to PRE of its bank: write recovery),
//     `MEM_CHK_WR2RD (WR to any RD: write-to-read turnaround) and
//     `MEM_CHK_TCCD (RD / WR to RD / WR: data-bus burst spacing), in clocks
//     between the pin commands; 0 (the default) leaves a rule unchecked.
//   * `MEM_CHK_LINE: the core also takes line commands and has an MR file.
//     hcmd 5 RDL / 6 WRL move the 8 cells lcell(a, k) of a line in one BL8
//     burst: the IP part sets q_ln (the RD / WR on the pins is a line burst)
//     and q_dqs, and the checker has an rdline port. A WRL takes its 8 data
//     beats on the next 8 hvalid clocks (hready high), drives beat k on the
//     channel's dq lanes with dqs = {~s, s} toggling, k clocks after
//     CWL clocks from its WR; an RDL passes beat k to hrdata k clocks
//     after the word read point, pulses hdone with beat 7 and then holds
//     the line on rdline. hcmd 7 is MRW (haddr[3] = 0, hwdata[7:0] into
//     MR haddr[2:0]; MR0 bit 7 reads 0) / MRR (haddr[3] = 1: hdone in the
//     next clock, hrdata = {8'h0, MR}). CL = 5 + MR0[3:0], CWL =
//     5 + MR1[3:0]; the write-side rules become `MEM_CHK_WR2PRE_L(l) /
//     `MEM_CHK_WR2RD_L(l) (l = the WR was a line), expressions of m_cwl.
//     Optional: `MEM_CHK_MR_RESET (statements: other MR reset values, on
//     m_mrs[set][index]), `MEM_CHK_MRSET (expression: the MR set MRW / MRR
//     and CL / CWL use, for cores with frequency set points; default 0),
//     `MEM_CHK_CL_OF / `MEM_CHK_CWL_OF (CL / CWL from m_mrs[m_set], default
//     5 + MR0[3:0] / 5 + MR1[3:0]), `MEM_CHK_LMODE (expression latched with
//     each line command as op_lm, e.g. a signaling mode bit of m_mrs),
//     `MEM_CHK_LNB (beats of
//     the line burst, default 8; with fewer the core decodes the line at the
//     last beat: hrdata = word 7 and hdone then), `MEM_CHK_LW_OK(k) (write
//     beat k is right on the pins, default lane(op_a) === op_ld[k]).
`ifndef MEM_CHK_EXTRA
`define MEM_CHK_EXTRA
`endif
`ifndef MEM_CHK_AP_OK
`define MEM_CHK_AP_OK 1'b0
`endif
`ifndef MEM_CHK_AP_MUST
`define MEM_CHK_AP_MUST 1'b0
`endif
`ifndef MEM_CHK_DRAINING
`define MEM_CHK_DRAINING 1'b0
`define MEM_CHK_DRAIN_A 32'h0
`define MEM_CHK_DRAIN_D 16'h0
`define MEM_CHK_DRAIN_POP
`endif
`ifndef MEM_CHK_ON_ACCEPT
`define MEM_CHK_ON_ACCEPT
`endif
`ifndef MEM_CHK_ON_DONE
`define MEM_CHK_ON_DONE
`endif
`ifdef MEM_CHK_HIT_REOPENS
`define MEM_CHK_HIT_KEEP 1'b0
`else
`define MEM_CHK_HIT_KEEP 1'b1
`endif
`ifdef MEM_CHK_RW_ANY_ROW
`define MEM_CHK_RW_ROW_OK(b, r) 1'b1
`else
`define MEM_CHK_RW_ROW_OK(b, r) (row_m[b] == (r))
`endif
`ifdef MEM_CHK_REF_PB
`define MEM_CHK_PB 1'b1
`else
`define MEM_CHK_PB 1'b0
`endif
`ifndef MEM_CHK_WMASK
`define MEM_CHK_WMASK 16'hFFFF
`endif
`ifndef MEM_CHK_WR_DONE
`define MEM_CHK_WR_DONE s_rw
`endif
`ifndef MEM_CHK_WR2PRE
`define MEM_CHK_WR2PRE 0
`endif
`ifndef MEM_CHK_WR2RD
`define MEM_CHK_WR2RD 0
`endif
`ifndef MEM_CHK_TCCD
`define MEM_CHK_TCCD 0
`endif
`ifndef MEM_CHK_WR2PRE_L
`define MEM_CHK_WR2PRE_L(l) `MEM_CHK_WR2PRE
`endif
`ifndef MEM_CHK_WR2RD_L
`define MEM_CHK_WR2RD_L(l) `MEM_CHK_WR2RD
`endif
`ifdef MEM_CHK_LINE
`define MEM_CHK_CLV m_cl
`else
`define MEM_CHK_CLV CL
`endif
`ifndef MEM_CHK_MRSET
`define MEM_CHK_MRSET 0
`endif
`ifndef MEM_CHK_CL_OF
`define MEM_CHK_CL_OF (5 + m_mrs[m_set][0][3:0])
`endif
`ifndef MEM_CHK_CWL_OF
`define MEM_CHK_CWL_OF (5 + m_mrs[m_set][1][3:0])
`endif
`ifndef MEM_CHK_LMODE
`define MEM_CHK_LMODE 1'b0
`endif
`ifndef MEM_CHK_LNB
`define MEM_CHK_LNB 8
`endif
`ifndef MEM_CHK_LW_OK
`define MEM_CHK_LW_OK(k) (lane(op_a) === op_ld[k])
`endif
`ifndef MEM_CHK_LCELL
`define MEM_CHK_LCELL(a, k) ((cellof(a) & ~7) | (k))
`endif

  logic        q_hready, q_hdone, q_tv;
  logic [15:0] q_hrdata;
  logic [2:0]  q_tc;
  logic [31:0] q_ta;
  always @(negedge clk) begin
    q_hready <= hready; q_hdone <= hdone; q_hrdata <= hrdata;
    q_tv <= trace_valid; q_tc <= trace_cmd; q_ta <= trace_addr;
  end

  longint      n, t_ref, t_refend, t_rdpin;
  longint      t_act [0:NB-1], t_pre [0:NB-1], t_wrp [0:NB-1];
  longint      t_refb [0:NB-1];     // per-entry refresh: end of the entry's tRFC
  longint      t_wrlast, t_caslast;      // last WR / last RD or WR on the pins
  logic        open_m [0:NB-1];
  logic [13:0] row_m [0:NB-1];
  logic [15:0] arr [0:NCELLS-1];
  initial for (int i = 0; i < NCELLS; i++) arr[i] = '0;   // the DUT zeroes its array once
  logic        op_v, s_act, s_rw, s_pre, s_done, s_apre, op_hit, op_open;
  logic [2:0]  op_c;
  logic [31:0] op_a;
  logic [15:0] op_d;
  int          op_b, busy;
  logic        p_tv, p_done;
  logic [2:0]  p_tc;
  logic [31:0] p_ta;
  logic [15:0] p_wl;
  logic        m_chk;
  logic [15:0] m_exp;
  int          rb_m;                 // per-entry refresh: REFs since reset
  int          wrp_need [0:NB-1];    // write recovery of the bank's last WR
  int          wrrd_need;            // write-to-read turnaround of the last WR
  // line commands and the MR file (`MEM_CHK_LINE)
  logic        op_ln, op_mrr, op_lm;
  int          lnb;                  // beats of the line burst in flight
  logic [15:0] op_ld [0:7];          // WRL data beats
  int          m_fill;               // WRL data beats still to take
  logic [7:0]  m_mrs [0:1][0:7];      // MR sets (set 1: frequency set point 1)
  int          m_set;
  int          m_cl, m_cwl;
  logic        lw_v, lr_v, lw_done, m_s;
  longint      lw_t, lr_t;
  logic [15:0] le [0:7];
  logic        v_bl, v_lwdata, v_ldqs, v_lrdata, v_rdline, v_mrr;
  logic        e_rdl_hit, e_rdl_closed, e_rdl_conf, e_wrl_hit, e_wrl_closed, e_wrl_conf,
               e_mrw, e_mrr, e_cl_min, e_cl_max, e_cwl_min, e_cwl_max, e_fill_gap,
               e_ref_rdl, e_ref_wrl;
`ifdef MEM_CHK_LINE
  logic [127:0] q_rdline;
  always @(negedge clk) q_rdline <= rdline;
`else
  localparam logic q_ln = 1'b0;      // word bursts only
`endif
  // functional-coverage samples (set by the model, sampled at the falling edge)
  logic        c_acc, c_rdv;
  logic [2:0]  c_cmd, c_prev, c_last;
  logic [1:0]  c_col;
  logic [15:0] c_wd, c_rdd;

  // violations (checked one clock later by the assertions below)
  logic v_stray, v_closed, v_act_open, v_trcd, v_trp, v_trc, v_tras, v_trfc, v_ref_open,
        v_paddr, v_wdata, v_trace, v_hdone, v_lat, v_rdata, v_incomplete, v_stuck,
        v_ref_late, v_ref_early, v_bad_pin, v_reopen, v_wr2pre, v_wr2rd, v_ccd;
  // functional events
  logic e_rd_hit, e_rd_closed, e_rd_conf, e_wr_hit, e_wr_closed, e_wr_conf, e_act_closed,
        e_act_conf, e_act_same, e_pre_open, e_pre_closed, e_ref_idle, e_ref_act, e_ref_rd,
        e_ref_wr, e_ref_pre, e_ign_busy, e_unknown, e_col0, e_col255, e_b2b, e_prea, e_apre,
        e_refpb_others_open;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      n = 0; t_ref = 0; t_refend = 0; t_rdpin = 0; busy = 0;
      t_wrlast = -1000000; t_caslast = -1000000;
      op_v = 0; s_act = 0; s_rw = 0; s_pre = 0; s_done = 0; s_apre = 0; op_hit = 0; op_open = 0;
      p_tv = 0; p_done = 0; m_chk = 0; rb_m = 0;
      wrrd_need = 0; op_ln = 0; op_mrr = 0; op_lm = 0; lnb = 8; m_fill = 0; lw_v = 0; lr_v = 0; lw_done = 0; m_s = 0;
      for (int i = 0; i < 8; i++) begin m_mrs[0][i] = 0; m_mrs[1][i] = 0; end
      m_set = 0;
`ifdef MEM_CHK_LINE
      m_mrs[0][0] = 8'(CL - 5); m_mrs[0][1] = 8'(CWL - 5);
`ifdef MEM_CHK_MR_RESET
      `MEM_CHK_MR_RESET
`endif
`endif
      {v_bl, v_lwdata, v_ldqs, v_lrdata, v_rdline, v_mrr} = '0;
      {e_rdl_hit, e_rdl_closed, e_rdl_conf, e_wrl_hit, e_wrl_closed, e_wrl_conf,
       e_mrw, e_mrr, e_cl_min, e_cl_max, e_cwl_min, e_cwl_max, e_fill_gap, e_ref_rdl, e_ref_wrl} = '0;
      c_acc = 0; c_rdv = 0; c_cmd = 0; c_prev = 0; c_last = 0; c_col = 0; c_wd = 0; c_rdd = 0;
      for (int b = 0; b < NB; b++) begin
        open_m[b] = 0; row_m[b] = 0; t_act[b] = -1000000; t_pre[b] = -1000000;
        t_wrp[b] = -1000000; t_refb[b] = -1000000; wrp_need[b] = 0;
      end
      {v_stray, v_closed, v_act_open, v_trcd, v_trp, v_trc, v_tras, v_trfc, v_ref_open,
       v_paddr, v_wdata, v_trace, v_hdone, v_lat, v_rdata, v_incomplete, v_stuck,
       v_ref_late, v_ref_early, v_bad_pin, v_reopen, v_wr2pre, v_wr2rd, v_ccd} = '0;
      {e_rd_hit, e_rd_closed, e_rd_conf, e_wr_hit, e_wr_closed, e_wr_conf, e_act_closed,
       e_act_conf, e_act_same, e_pre_open, e_pre_closed, e_ref_idle, e_ref_act, e_ref_rd,
       e_ref_wr, e_ref_pre, e_ign_busy, e_unknown, e_col0, e_col255, e_b2b, e_prea, e_apre,
       e_refpb_others_open} = '0;
    end else begin : step
      logic is_cmd, done_now, drn, wd, rpre;
      logic [31:0] ta;
      int b, tb;
      {v_stray, v_closed, v_act_open, v_trcd, v_trp, v_trc, v_tras, v_trfc, v_ref_open,
       v_paddr, v_wdata, v_trace, v_hdone, v_lat, v_rdata, v_incomplete, v_stuck,
       v_ref_late, v_ref_early, v_bad_pin, v_reopen, v_wr2pre, v_wr2rd, v_ccd} = '0;
      {e_rd_hit, e_rd_closed, e_rd_conf, e_wr_hit, e_wr_closed, e_wr_conf, e_act_closed,
       e_act_conf, e_act_same, e_pre_open, e_pre_closed, e_ref_idle, e_ref_act, e_ref_rd,
       e_ref_wr, e_ref_pre, e_ign_busy, e_unknown, e_col0, e_col255, e_b2b, e_prea, e_apre,
       e_refpb_others_open} = '0;
      {v_bl, v_lwdata, v_ldqs, v_lrdata, v_rdline, v_mrr} = '0;
      {e_rdl_hit, e_rdl_closed, e_rdl_conf, e_wrl_hit, e_wrl_closed, e_wrl_conf,
       e_mrw, e_mrr, e_cl_min, e_cl_max, e_cwl_min, e_cwl_max, e_fill_gap, e_ref_rdl, e_ref_wrl} = '0;
      m_set = `MEM_CHK_MRSET;
      m_cl = `MEM_CHK_CL_OF; m_cwl = `MEM_CHK_CWL_OF;
`ifdef MEM_CHK_LINE
      // ---- line bursts: write beats on dq / dqs, read beats on hrdata, rdline
      lnb = `MEM_CHK_LNB;
      if (lw_v && n >= lw_t && n < lw_t + lnb) begin
        if (!(`MEM_CHK_LW_OK(n - lw_t))) v_lwdata = 1;
        if (q_dqs !== {~q_dqs[0], q_dqs[0]} || n > lw_t && q_dqs[0] === m_s) v_ldqs = 1;
        m_s = q_dqs[0];
        if (n == lw_t + lnb - 1) begin lw_v = 0; lw_done = 1; end
      end
      if (lr_v && n >= lr_t && n < lr_t + lnb) begin
        if ((lnb == 8 || n == lr_t + lnb - 1) && q_hrdata !== le[lnb == 8 ? n - lr_t : 7]) v_lrdata = 1;
        if (n == lr_t + lnb - 1) begin
          lr_v = 0;
          if (q_rdline !== {le[7], le[6], le[5], le[4], le[3], le[2], le[1], le[0]}) v_rdline = 1;
        end
      end
`endif
      // ---- read data registered by the previous hdone
      c_acc = 0; c_rdv = m_chk; c_rdd = q_hrdata;
      if (m_chk && op_mrr) v_mrr = q_hrdata !== m_exp;
      else if (m_chk) v_rdata = q_hrdata !== m_exp;
      m_chk = 0;
      // ---- pin command
      drn = op_v && (`MEM_CHK_DRAINING);
      // the host command has done its own pin work (what is left is refresh)
      // (an RD / WR that must auto-precharge is not done before its PRE)
      wd = !op_v || op_c == 3'd7 || (op_c == 3'd2 ? s_done && !((`MEM_CHK_AP_MUST) && !s_apre) :
                     op_c == 3'd3 ? (`MEM_CHK_WR_DONE) && !((`MEM_CHK_AP_MUST) && !s_apre) :
                     op_c == 3'd1 ? (s_act || op_hit) : (s_pre || !op_open));
      rpre = 0;
      tb = 0;
`ifdef MEM_CHK_REF_PB
      tb = ref_bank_of(rb_m % REF_NB);
`endif
      ta = drn ? `MEM_CHK_DRAIN_A : op_a;
      b = bank_of(ta);
      is_cmd = q_pc != P_NOP;
`ifdef MEM_CHK_REF_PB
      // per-entry refresh: only the refreshed entry is busy for tRFC (an ACT
      // or the next REF to it); the other entries keep working
      if ((q_pc == P_ACT && n < t_refb[b]) || (q_pc == P_REF && n < t_refb[tb])) v_trfc = 1;
`else
      if (is_cmd && n < t_refend) v_trfc = 1;
`endif
      // a RD / WR page hit goes straight to its burst
      if ((q_pc == P_ACT || q_pc == P_PRE) && op_v && !drn && op_hit && !s_rw &&
          (op_c == 3'd2 || op_c == 3'd3) && `MEM_CHK_HIT_KEEP) v_reopen = 1;
      v_bad_pin = q_pc == P_BAD;
      // trace announces ACT / RD / WR one clock ahead, with the host address
      if ((q_pc == P_ACT || q_pc == P_RD || q_pc == P_WR) != p_tv) v_trace = 1;
      if (p_tv && (p_tc != ((q_pc == P_ACT) ? 3'd1 : (q_pc == P_RD) ? 3'd2 : 3'd3) ||
                   !op_v || p_ta != ta)) v_trace = 1;
      case (q_pc)
        P_ACT: begin
          if (!op_v || op_c == 3'd4 && !drn) v_stray = 1;
          else begin
            if (open_m[b]) v_act_open = 1;
            if (n - t_pre[b] < TRP) v_trp = 1;
            if (n - t_act[b] < TRC) v_trc = 1;
            if (!pin_row_ok(q_pa, row_of(ta))) v_paddr = 1;
            open_m[b] = 1; row_m[b] = row_of(ta); t_act[b] = n;
            if (!drn) s_act = 1;
          end
        end
        P_RD, P_WR: if (drn) begin
          if (q_pc != P_WR) v_stray = 1;
          else begin
            if (!open_m[b] || row_m[b] != row_of(ta)) v_closed = 1;
            if (n - t_act[b] < TRCD) v_trcd = 1;
            if (!pin_col_ok(q_pa, col_of(ta))) v_paddr = 1;
            if (p_wl !== `MEM_CHK_DRAIN_D) v_wdata = 1;
            if (n - t_caslast < `MEM_CHK_TCCD) v_ccd = 1;
            t_wrp[b] = n; t_wrlast = n; t_caslast = n;
            wrp_need[b] = `MEM_CHK_WR2PRE_L(1'b0); wrrd_need = `MEM_CHK_WR2RD_L(1'b0);
            arr[cellof(ta)] = `MEM_CHK_DRAIN_D;
            `MEM_CHK_DRAIN_POP
          end
        end else begin
          if (!op_v || op_c != ((q_pc == P_RD) ? 3'd2 : 3'd3) || s_rw) v_stray = 1;
          else begin
            if (!open_m[b] || !`MEM_CHK_RW_ROW_OK(b, row_of(op_a))) v_closed = 1;
            if (n - t_act[b] < TRCD) v_trcd = 1;
            if (!pin_col_ok(q_pa, op_ln ? col_of(op_a) & ~7 : col_of(op_a))) v_paddr = 1;
            if (q_ln !== op_ln) v_bl = 1;
            s_rw = 1;
            if (n - t_caslast < `MEM_CHK_TCCD) v_ccd = 1;
            if (q_pc == P_RD && n - t_wrlast < wrrd_need) v_wr2rd = 1;
            t_caslast = n;
            if (q_pc == P_WR) begin
              t_wrp[b] = n; t_wrlast = n;
              wrp_need[b] = `MEM_CHK_WR2PRE_L(op_ln); wrrd_need = `MEM_CHK_WR2RD_L(op_ln);
              if (op_ln) begin
                lw_v = 1; lw_t = n + m_cwl; lw_done = 0;
                for (int k = 0; k < 8; k++) arr[`MEM_CHK_LCELL(op_a, k) % NCELLS] = op_ld[k];
              end else begin
                if ((p_wl & `MEM_CHK_WMASK) !== (op_d & `MEM_CHK_WMASK)) v_wdata = 1;
                arr[cellof(op_a)] = (arr[cellof(op_a)] & ~`MEM_CHK_WMASK) | (op_d & `MEM_CHK_WMASK);
              end
            end else begin
              t_rdpin = n;
              if (op_ln) begin
                lr_v = 1; lr_t = n + m_cl + 1;
                for (int k = 0; k < 8; k++) le[k] = arr[`MEM_CHK_LCELL(op_a, k) % NCELLS];
              end
            end
          end
        end
        P_PRE: if (`MEM_CHK_PB && wd && !drn) begin   // per-entry refresh PRE
          if (open_m[tb] && n - t_act[tb] < TRAS) v_tras = 1;
          if (n - t_wrp[tb] < wrp_need[tb]) v_wr2pre = 1;
          open_m[tb] = 0; t_pre[tb] = n; rpre = 1;
        end else begin
          if (!op_v || !drn && (s_apre || s_rw && !(`MEM_CHK_AP_OK))) v_stray = 1;
          else begin
            if (open_m[b] && n - t_act[b] < TRAS) v_tras = 1;
            if (n - t_wrp[b] < wrp_need[b]) v_wr2pre = 1;
            open_m[b] = 0; t_pre[b] = n;
            if (!drn) s_pre = 1;
            if (!drn && s_rw) begin s_apre = 1; e_apre = 1; end
          end
        end
        P_PREA: begin
          e_prea = 1;
          for (int i = 0; i < NB; i++) begin
            if (open_m[i] && n - t_act[i] < TRAS) v_tras = 1;
            if (n - t_wrp[i] < wrp_need[i]) v_wr2pre = 1;
            open_m[i] = 0; t_pre[i] = n;
          end
        end
        P_REF: begin
          if (`MEM_CHK_PB) begin
            if (open_m[tb]) v_ref_open = 1;
            if (n - t_pre[tb] < TRP) v_trp = 1;
            for (int i = 0; i < NB; i++) if (i != tb && open_m[i]) e_refpb_others_open = 1;
            rb_m = rb_m + 1; t_refb[tb] = n + TRFC;
          end else
          for (int i = 0; i < NB; i++) begin
            if (open_m[i]) v_ref_open = 1;
            if (n - t_pre[i] < TRP) v_trp = 1;
          end
          if (t_ref != 0 && n - t_ref < REF_MIN) v_ref_early = 1;
          t_ref = n; t_refend = n + TRFC;
          e_ref_idle = !op_v;
          e_ref_act = op_v && op_c == 3'd1; e_ref_rd = op_v && op_c == 3'd2;
          e_ref_wr = op_v && op_c == 3'd3 && !op_ln; e_ref_pre = op_v && op_c == 3'd4;
          e_ref_rd = e_ref_rd && !op_ln;
          e_ref_rdl = op_v && op_c == 3'd2 && op_ln; e_ref_wrl = op_v && op_c == 3'd3 && op_ln;
        end
        default: ;
      endcase
      // a drain or a refresh may move the page under the host command
      if (drn && is_cmd || q_pc == P_PREA || rpre) begin
        op_hit = open_m[op_b] && row_m[op_b] == row_of(op_a);
`ifdef MEM_CHK_RW_ANY_ROW
        if (op_c == 3'd2 || op_c == 3'd3) op_hit = open_m[op_b];
`endif
      end
      if (n - t_ref > REF_MAX) v_ref_late = 1;
      // ---- hdone: once per RD, CL clocks after the RD command
      if (q_hdone) begin
        if (op_v && op_c == 3'd7 && op_mrr && !s_done) begin
          m_chk = 1; m_exp = {8'h00, m_mrs[m_set][op_a[2:0]]}; s_done = 1;
        end else if (!op_v || op_c != 3'd2 || !s_rw || s_done) v_hdone = 1;
        else begin
          if (n - t_rdpin != (op_ln ? `MEM_CHK_CLV + lnb - 1 : `MEM_CHK_CLV)) v_lat = 1;
          if (!op_ln) begin m_chk = 1; m_exp = arr[cellof(op_a)]; end
          s_done = 1;
        end
      end
      `MEM_CHK_EXTRA
      // ---- hready back: the command must be complete
      done_now = 0;
      if (op_v && q_hready && m_fill == 0) begin
        case (op_c)
          3'd1: if (!s_act && !op_hit) v_incomplete = 1;
          3'd2: if (!s_done || (`MEM_CHK_AP_MUST) && !s_apre) v_incomplete = 1;
          3'd3: if (!(`MEM_CHK_WR_DONE) || (`MEM_CHK_AP_MUST) && !s_apre || op_ln && !lw_done)
                  v_incomplete = 1;
          3'd7: if (op_mrr && !s_done) v_incomplete = 1;
          default: if (!s_pre && op_open) v_incomplete = 1;
        endcase
        `MEM_CHK_ON_DONE
        op_v = 0; done_now = 1;
      end
      busy = q_hready ? 0 : busy + 1;
      if (busy > BUSY_MAX) v_stuck = 1;
      e_ign_busy = hvalid && !q_hready;
      // ---- WRL data beats
      if (m_fill > 0 && q_hready) begin
        if (hvalid) begin op_ld[8 - m_fill] = hwdata; m_fill = m_fill - 1; end
        else e_fill_gap = 1;
      end else
      // ---- host command taken
      if (hvalid && q_hready) begin
`ifdef MEM_CHK_LINE
        if (hcmd == 3'd7) begin
          op_v = 1; op_c = 3'd7; op_a = haddr; op_d = hwdata; op_mrr = haddr[3]; op_ln = 0;
          s_act = 0; s_rw = 0; s_pre = 0; s_done = 0; s_apre = 0; op_open = 0; op_hit = 0;
          e_b2b = done_now;
          if (haddr[3]) e_mrr = 1;
          else begin
            e_mrw = 1;
            m_mrs[m_set][haddr[2:0]] = (haddr[2:0] == 3'd0) ? {1'b0, hwdata[6:0]} : hwdata[7:0];
            if (haddr[2:0] == 3'd0) begin e_cl_min = hwdata[3:0] == 4'h0; e_cl_max = hwdata[3:0] == 4'hF; end
            if (haddr[2:0] == 3'd1) begin e_cwl_min = hwdata[3:0] == 4'h0; e_cwl_max = hwdata[3:0] == 4'hF; end
          end
        end else
`endif
        if (hcmd >= 3'd1 && hcmd <= 3'd4
`ifdef MEM_CHK_LINE
            || hcmd == 3'd5 || hcmd == 3'd6
`endif
           ) begin
          op_v = 1; op_c = hcmd; op_a = haddr; op_d = hwdata; op_b = bank_of(haddr);
          op_ln = 0; op_mrr = 0;
          if (hcmd == 3'd5 || hcmd == 3'd6) begin
            op_ln = 1; op_c = hcmd - 3'd3;            // the RD / WR rules, on a line
            op_lm = `MEM_CHK_LMODE;
            if (hcmd == 3'd6) m_fill = 8;
          end
          s_act = 0; s_rw = 0; s_pre = 0; s_done = 0; s_apre = 0;
          op_open = open_m[op_b];
          op_hit = open_m[op_b] && row_m[op_b] == row_of(haddr);
`ifdef MEM_CHK_RW_ANY_ROW
          if (hcmd == 3'd2 || hcmd == 3'd3) op_hit = open_m[op_b];
`endif
          e_b2b = done_now;
          c_acc = !op_ln; c_cmd = op_c; if (!op_ln) begin c_prev = c_last; c_last = op_c; end c_wd = hwdata;
          c_col = col_of(haddr) == 8'h00 ? 2'd0 : col_of(haddr) == 8'hFF ? 2'd1 : 2'd2;
          e_col0 = col_of(haddr) == 8'h00; e_col255 = col_of(haddr) == 8'hFF;
          `MEM_CHK_ON_ACCEPT
          if (op_ln) begin
            if (op_c == 3'd2) begin e_rdl_hit = op_hit; e_rdl_closed = !op_open; e_rdl_conf = op_open && !op_hit; end
            else begin e_wrl_hit = op_hit; e_wrl_closed = !op_open; e_wrl_conf = op_open && !op_hit; end
          end else
          case (hcmd)
            3'd1: begin e_act_same = op_hit; e_act_closed = !op_open; e_act_conf = op_open && !op_hit; end
            3'd2: begin e_rd_hit = op_hit; e_rd_closed = !op_open; e_rd_conf = op_open && !op_hit; end
            3'd3: begin e_wr_hit = op_hit; e_wr_closed = !op_open; e_wr_conf = op_open && !op_hit; end
            default: begin e_pre_open = op_open; e_pre_closed = !op_open; end
          endcase
        end else e_unknown = 1;
      end
      p_done = done_now;
      p_tv = q_tv; p_tc = q_tc; p_ta = q_ta; p_wl = lane(q_ta);
      n = n + 1;
    end
  end

  `SVA_INV(a_cmd_belongs_to_host_op, !v_stray)
  `SVA_INV(a_rw_to_open_page, !v_closed)
  `SVA_INV(a_page_hit_needs_no_pre_act, !v_reopen)
  `SVA_INV(a_act_to_closed_bank, !v_act_open)
  `SVA_INV(a_trcd, !v_trcd)
  `SVA_INV(a_trp, !v_trp)
  `SVA_INV(a_trc, !v_trc)
  `SVA_INV(a_tras, !v_tras)
  `SVA_INV(a_wr_recovery, !v_wr2pre)
  `SVA_INV(a_wr_to_rd, !v_wr2rd)
  `SVA_INV(a_cas_to_cas, !v_ccd)
  `SVA_INV(a_trfc, !v_trfc)
  `SVA_INV(a_ref_all_closed, !v_ref_open)
  `SVA_INV(a_pin_address, !v_paddr)
  `SVA_INV(a_write_data_on_dq, !v_wdata)
  `SVA_INV(a_trace_announces_cmd, !v_trace)
  `SVA_INV(a_hdone_once_per_read, !v_hdone)
  `SVA_INV(a_read_latency_cl, !v_lat)
  `SVA_INV(a_read_data, !v_rdata)
  `SVA_INV(a_hready_after_completion, !v_incomplete)
  `SVA_INV(a_no_stall, !v_stuck)
  `SVA_INV(a_refresh_not_starved, !v_ref_late)
  `SVA_INV(a_refresh_not_early, !v_ref_early)
  `SVA_INV(a_legal_pin_code, !v_bad_pin)
`ifdef MEM_CHK_LINE
  `SVA_INV(a_burst_length_matches_command, !v_bl)
  `SVA_INV(a_line_write_beats_on_dq, !v_lwdata)
  `SVA_INV(a_line_write_dqs_toggles, !v_ldqs)
  `SVA_INV(a_line_read_beats_on_hrdata, !v_lrdata)
  `SVA_INV(a_rdline_holds_line, !v_rdline)
  `SVA_INV(a_mrr_value, !v_mrr)
`endif
`ifndef MEM_CHK_CKE_PD
  `SVA_INV(a_cke_out_of_reset, cke)
`endif
  `SVA_RST(a_reset_pins, !rst_n, !cke && !hdone && !trace_valid && q_pc == P_NOP)

`ifdef VERILATOR
  // host command pairs (previous accepted command x this one; c_prev = 0
  // is the first command after reset), RD / WR column classes, write and
  // read data classes
  function automatic logic [1:0] mdcls(input logic [15:0] v);
    mdcls = (v == 16'h0000) ? 2'd0 : (v == 16'hFFFF) ? 2'd1 :
            (v == 16'h5555 || v == 16'hAAAA) ? 2'd2 : 2'd3;
  endfunction
  covergroup cg_mem_ops @(negedge clk);
    option.per_instance = 1;
    cp_cmd: coverpoint c_cmd iff (rst_n && c_acc)
      { bins act = {1}; bins rd = {2}; bins wr = {3}; bins pre = {4}; }
    cp_prev: coverpoint c_prev iff (rst_n && c_acc)
      { bins act = {1}; bins rd = {2}; bins wr = {3}; bins pre = {4}; }
    x_pair: cross cp_prev, cp_cmd;
    cp_rw: coverpoint c_cmd iff (rst_n && c_acc && (c_cmd == 3'd2 || c_cmd == 3'd3))
      { bins rd = {2}; bins wr = {3}; }
    cp_col: coverpoint c_col iff (rst_n && c_acc && (c_cmd == 3'd2 || c_cmd == 3'd3))
      { bins col0 = {0}; bins col255 = {1}; bins other = {2}; }
    x_rw_col: cross cp_rw, cp_col;
    cp_wdata: coverpoint mdcls(c_wd) iff (rst_n && c_acc && c_cmd == 3'd3)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint mdcls(c_rdd) iff (rst_n && c_rdv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_mem_ops u_cg_mem_ops = new;
`endif

  `FC(rd_page_hit, e_rd_hit)
  `FC(rd_bank_closed, e_rd_closed)
  `FC(wr_page_hit, e_wr_hit)
  `FC(wr_bank_closed, e_wr_closed)
`ifndef MEM_CHK_RW_ANY_ROW
  `FC(rd_row_conflict, e_rd_conf)
  `FC(wr_row_conflict, e_wr_conf)
`endif
  `FC(act_bank_closed, e_act_closed)
  `FC(act_row_conflict, e_act_conf)
  `FC(act_row_already_open, e_act_same)
  `FC(pre_bank_open, e_pre_open)
  `FC(pre_bank_closed, e_pre_closed)
`ifdef MEM_CHK_REF_PB
  `FC(per_entry_refresh_with_other_pages_open, e_refpb_others_open)
`else
  `FC(precharge_all, e_prea)
`endif
  `FC(refresh_while_idle, e_ref_idle)
  `FC(refresh_due_during_act, e_ref_act)
  `FC(refresh_due_during_rd, e_ref_rd)
  `FC(refresh_due_during_wr, e_ref_wr)
  `FC(refresh_due_during_pre, e_ref_pre)
  `FC(hvalid_while_busy_ignored, e_ign_busy)
  `FC(unknown_hcmd, e_unknown)
  `FC(column_0, e_col0)
  `FC(column_255, e_col255)
  `FC(back_to_back_commands, e_b2b)
`ifdef MEM_CHK_LINE
  `FC(line_read_page_hit, e_rdl_hit)
  `FC(line_read_bank_closed, e_rdl_closed)
  `FC(line_read_row_conflict, e_rdl_conf)
  `FC(line_write_page_hit, e_wrl_hit)
  `FC(line_write_bank_closed, e_wrl_closed)
  `FC(line_write_row_conflict, e_wrl_conf)
  `FC(line_write_data_gap, e_fill_gap)
  `FC(refresh_due_during_line_read, e_ref_rdl)
  `FC(refresh_due_during_line_write, e_ref_wrl)
  `FC(mode_register_write, e_mrw)
  `FC(mode_register_read, e_mrr)
  `FC(cl_min, e_cl_min)
  `FC(cl_max, e_cl_max)
  `FC(cwl_min, e_cwl_min)
  `FC(cwl_max, e_cwl_max)
`endif
  `FC_RST(reset_with_command_in_flight, rst_n && !hready ##1 !rst_n)
