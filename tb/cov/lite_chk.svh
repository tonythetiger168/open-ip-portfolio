// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// Shared pin-level model for the *_Lite line controllers (DDR4_Lite and its
// forks): one READ / WRITE / REFRESH in flight, 8-beat line bursts, MR file,
// sticky irq. Included inside <P>_sva after:
//   localparams NB (bank entries), NLINES (array lines), T_RCD, T_RP, T_RC,
//   T_RAS, T_RRD, T_WR, T_WTR, T_RFC, T_REFI, CL0, CWL0, BUSY_MAX, REF_LAT
//   functions bank_of(a) (entry of a host address), row_of(a), line_of(a),
//   idx_of(a) (array line), in_range(a)
//   pin copies q_cs_n, q_act_n, q_ras_n, q_cas_n, q_we_n, q_ba, q_addr,
//   q_dq, q_dqs, q_hready, q_hdone, q_hrdata, q_irq, q_tv, q_tc, q_ta
//   (taken at the falling edge) and pin_bank (entry the pins address);
//   q_dq_oe, q_dqs_oe: the DUT's dq / dqs output enables (tristate values
//   are not visible in a 2-state simulator, so the enables are checked)
// The model runs on the rising edge on the values held through the clock.
// LITE_PBREF (HBM-style): the auto refresh is per entry -- each tREFI the
// next entry in rotation falls due and is served by PRE (if open) + REF
// with addr[10] = 0 to that entry + tRFC_PB (localparam T_RFC_PB); the
// all-bank REF (addr[10] = 1) is a host REFRESH only; trace code 5 with
// the entry for a per-entry REF, 6 for an all-bank one.
//
// Checked: every pin command belongs to the host operation in flight or to
// a refresh that is due (or host-requested); ACT only to a closed bank,
// RD / WR only to the open row of the operation's bank, at most one each;
// tRCD, tRP, tRC, tRAS, tRRD, tWR (last WR beat -> PRE), tWTR (last WR
// beat -> RD), tRFC; REF only with every bank closed and tRP met; refresh
// served within REF_LAT of falling due; pin row / column / bank; write
// data on dq exactly CWL clocks after the WR (host beats in order), read
// data exactly CL clocks after the RD (array model), dqs differential and
// toggling each beat; read data to the host on the 8 clocks ending with
// hdone; hdone once per operation (next clock for MRW / MRR / NOP /
// rejected ones); MRR value; hready exactly when idle or taking write
// beats; operations finish within BUSY_MAX; irq rises two clocks after a
// rejected command and stays; trace with each ACT / RD / WR / PRE / REF.
`ifndef LITE_CL_OF
`define LITE_CL_OF (5 + mr_m[0][3:0])
`endif
`ifndef LITE_CWL_OF
`define LITE_CWL_OF (5 + mr_m[1][3:0])
`endif
// MR file write model (DDR4: MR0 bit 7 is a self-clearing DLL reset);
// LITE_NO_DLL drops the DLL-reset functional cover
`ifndef LITE_MRW
`define LITE_MRW(i, d) ((i) == 3'd0 ? {1'b0, d[6:0]} : d[7:0])
`endif
`ifndef LITE_EXTRA
`define LITE_EXTRA
`endif
// pin address of ACT / RD / WR for host address a, of a single-bank PRE
// (and a per-entry REF) to entry b
`ifndef LITE_ACT_ADDR
`define LITE_ACT_ADDR(a) 14'(row_of(a))
`endif
`ifndef LITE_RW_ADDR
`define LITE_RW_ADDR(a) {7'h0, 3'(line_of(a)), 4'h0}
`endif
`ifndef LITE_PRE_ADDR
`define LITE_PRE_ADDR(b) 14'h0
`endif
// beats per burst, and whether dq carries beat k of a 128-bit line
`ifndef LITE_BL
`define LITE_BL 8
`endif
`ifndef LITE_DQ_OK
`define LITE_DQ_OK(line, k) (q_dq === line[16*(k) +: 16])
`endif

  localparam logic [2:0] C_NOP = 0, C_ACT = 1, C_RD = 2, C_WR = 3, C_PRE = 4, C_PREA = 5,
                         C_REF = 6, C_BAD = 7;
  function automatic logic [2:0] pin_cmd(input logic cs_n_, act_n_, ras_n_, cas_n_, we_n_,
                                         input logic a10);
    if (cs_n_) return C_NOP;
    if (!act_n_) return C_ACT;
    case ({ras_n_, cas_n_, we_n_})
      3'b010: return a10 ? C_PREA : C_PRE;
      3'b101: return C_RD;
      3'b100: return C_WR;
      3'b001: return C_REF;
      default: return C_BAD;
    endcase
  endfunction

  longint n, t_lact, t_wend_any, t_ref, pend_since, t_refpin, err_n;
  longint t_act [NB], t_pre [NB], t_wend [NB];
`ifdef LITE_PBREF
  logic   pend_pb [NB];
  longint pb_since [NB], t_refpb [NB];
  int     rot_m;
  logic   pb_pre;                    // this PRE is a refresh PRE
  int     pre_row;                   // row the PRE closed
`endif
  int     lact_b;                    // bank of the last ACT
  logic   open_m [NB];
  int     row_m [NB];
  logic [127:0] arr [NLINES];
  initial for (int i = 0; i < NLINES; i++) arr[i] = '0;   // the DUT zeroes its array once
  logic [7:0] mr_m [8];
  int     refi_m;
  logic   pend_m, irq_m;
  // host operation in flight
  logic   op_v, filling, s_act, s_pre, s_rw, s_data, s_ref, op_hit, op_open;
  logic [2:0] op_k;
  logic [31:0] op_a;
  int     op_b, fill, busy;
  logic [15:0] wb [8];
  // immediate completions
  longint imm_at;
  logic   imm_mrr;
  logic [7:0] imm_val;
  // the burst on dq
  logic   bst_v, bst_rd;
  longint bst_t0;
  logic [127:0] bst_line;
  int     bst_idx, bst_b, bst_bl;
  logic   p_dqs;
  logic [15:0] hr_hist [8];

  logic v_stray, v_act_open, v_closed, v_rw_twice, v_trcd, v_trp, v_trc, v_tras, v_trrd,
        v_twr, v_twtr, v_trfc, v_ref_open, v_ref_undue, v_ref_late, v_paddr, v_wdata,
        v_rdata_dq, v_dqs, v_rdata, v_hdone, v_mrr, v_hready, v_stuck, v_irq, v_trace,
        v_bad_pin, v_oe, exp_oe;
  logic e_rd_hit, e_rd_closed, e_rd_conf, e_wr_hit, e_wr_closed, e_wr_conf, e_href,
        e_href_prea, e_aref_prea, e_aref_closed, e_ref_mid_op, e_mrw, e_mrr, e_mr0_dll,
        e_rd_cl_mr, e_wr_cwl_mr, e_oor_rd, e_oor_wr, e_bad_cmd, e_nop, e_fill_gap,
        e_ign_busy, e_b2b, e_trc_tight, e_twtr_tight, e_twr_tight;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      n = 0; t_lact = -1000000; t_wend_any = -1000000; t_ref = -1000000; t_refpin = 0;
      pend_since = 0; err_n = -1; lact_b = -1;
      for (int b = 0; b < NB; b++) begin
        open_m[b] = 0; row_m[b] = 0; t_act[b] = -1000000; t_pre[b] = -1000000;
        t_wend[b] = -1000000;
`ifdef LITE_PBREF
        pend_pb[b] = 0; pb_since[b] = 0; t_refpb[b] = -1000000;
`endif
      end
`ifdef LITE_PBREF
      rot_m = 0;
`endif
      for (int i = 0; i < 8; i++) mr_m[i] = 0;
      mr_m[0] = 8'(CL0 - 5); mr_m[1] = 8'(CWL0 - 5);
      refi_m = T_REFI; pend_m = 0; irq_m = 0;
      op_v = 0; filling = 0; fill = 0; busy = 0; imm_at = -1; imm_mrr = 0;
      bst_v = 0; p_dqs = 0;
      {v_stray, v_act_open, v_closed, v_rw_twice, v_trcd, v_trp, v_trc, v_tras, v_trrd,
       v_twr, v_twtr, v_trfc, v_ref_open, v_ref_undue, v_ref_late, v_paddr, v_wdata,
       v_rdata_dq, v_dqs, v_rdata, v_hdone, v_mrr, v_hready, v_stuck, v_irq, v_trace,
       v_bad_pin, v_oe, exp_oe} = '0;
      {e_rd_hit, e_rd_closed, e_rd_conf, e_wr_hit, e_wr_closed, e_wr_conf, e_href,
       e_href_prea, e_aref_prea, e_aref_closed, e_ref_mid_op, e_mrw, e_mrr, e_mr0_dll,
       e_rd_cl_mr, e_wr_cwl_mr, e_oor_rd, e_oor_wr, e_bad_cmd, e_nop, e_fill_gap,
       e_ign_busy, e_b2b, e_trc_tight, e_twtr_tight, e_twr_tight} = '0;
    end else begin : step
      logic [2:0] pc;
      logic       done_now, any_open;
      int         b;
      {v_stray, v_act_open, v_closed, v_rw_twice, v_trcd, v_trp, v_trc, v_tras, v_trrd,
       v_twr, v_twtr, v_trfc, v_ref_open, v_ref_undue, v_ref_late, v_paddr, v_wdata,
       v_rdata_dq, v_dqs, v_rdata, v_hdone, v_mrr, v_hready, v_stuck, v_irq, v_trace,
       v_bad_pin, v_oe, exp_oe} = '0;
      {e_rd_hit, e_rd_closed, e_rd_conf, e_wr_hit, e_wr_closed, e_wr_conf, e_href,
       e_href_prea, e_aref_prea, e_aref_closed, e_ref_mid_op, e_mrw, e_mrr, e_mr0_dll,
       e_rd_cl_mr, e_wr_cwl_mr, e_oor_rd, e_oor_wr, e_bad_cmd, e_nop, e_fill_gap,
       e_ign_busy, e_b2b, e_trc_tight, e_twtr_tight, e_twr_tight} = '0;
      n = n + 1;
      for (int i = 7; i > 0; i--) hr_hist[i] = hr_hist[i-1];
      hr_hist[0] = q_hrdata;
      // ---- burst on dq: the drivers are on exactly for the burst beats
      exp_oe = bst_v && n >= bst_t0;
      if (q_dq_oe !== exp_oe || q_dqs_oe !== exp_oe) v_oe = 1;
      if (bst_v && n >= bst_t0) begin
        int k;
        k = int'(n - bst_t0);
        if (!(`LITE_DQ_OK(bst_line, k))) begin
          if (bst_rd) v_rdata_dq = 1; else v_wdata = 1;
        end
        if (q_dqs[1] !== ~q_dqs[0] || (k > 0 && q_dqs[0] === p_dqs)) v_dqs = 1;
        p_dqs = q_dqs[0];
        if (k == bst_bl - 1) begin
          bst_v = 0; s_data = 1;
          if (!bst_rd) begin
            arr[bst_idx] = bst_line;
            t_wend[bst_b] = n; t_wend_any = n;
          end
        end
      end
      // ---- pin command
      pc = pin_cmd(q_cs_n, q_act_n, q_ras_n, q_cas_n, q_we_n, q_addr[10]);
      b = pin_bank;
      any_open = 0;
      for (int i = 0; i < NB; i++) if (open_m[i]) any_open = 1;
      if (pc != C_NOP && n - t_ref < T_RFC) v_trfc = 1;
      v_bad_pin = pc == C_BAD;
      case (pc)
        C_ACT: begin
          if (!op_v || filling || !(op_k == 3'd1 || op_k == 3'd2) || s_act || b != op_b) v_stray = 1;
          if (open_m[b]) v_act_open = 1;
          if (n - t_pre[b] < T_RP) v_trp = 1;
          if (n - t_act[b] < T_RC) v_trc = 1;
          if (n - t_lact < T_RRD) v_trrd = 1;
          e_trc_tight = n - t_act[b] <= T_RC + 3;
          if (op_v && q_addr != `LITE_ACT_ADDR(op_a)) v_paddr = 1;
          open_m[b] = 1; row_m[b] = row_of(op_a); t_act[b] = n; t_lact = n; s_act = 1;
          lact_b = b;
        end
        C_PRE: begin
`ifdef LITE_PBREF
          // a refresh PRE closes the open entry that is due
          pb_pre = pend_pb[b] && open_m[b] &&
                   !(op_v && !filling && (op_k == 3'd1 || op_k == 3'd2) && !s_pre && b == op_b &&
                     row_m[b] != row_of(op_a));
          pre_row = row_m[b];
          if (!pb_pre)
`endif
          if (!op_v || filling || !(op_k == 3'd1 || op_k == 3'd2) || s_pre || b != op_b ||
              !open_m[b] || row_m[b] == row_of(op_a)) v_stray = 1;
          if (n - t_act[b] < T_RAS) v_tras = 1;
          if (n - t_wend[b] < T_WR) v_twr = 1;
          e_twr_tight = n - t_wend[b] <= T_WR + 3;
          if (q_addr != `LITE_PRE_ADDR(b)) v_paddr = 1;
          open_m[b] = 0; t_pre[b] = n;
`ifdef LITE_PBREF
          if (!pb_pre)
`endif
          s_pre = 1;
        end
        C_PREA: begin
          if (!(pend_m || op_v && op_k == 3'd5 && !s_ref) || !any_open) v_stray = 1;
`ifdef LITE_PBREF
          if (!(op_v && op_k == 3'd5)) v_stray = 1;
`endif
          for (int i = 0; i < NB; i++) if (open_m[i]) begin
            if (n - t_act[i] < T_RAS) v_tras = 1;
            if (n - t_wend[i] < T_WR) v_twr = 1;
            open_m[i] = 0; t_pre[i] = n;
          end
          if (q_addr != 14'h0400 || q_ba != 0) v_paddr = 1;
          if (op_v && op_k == 3'd5) e_href_prea = 1; else e_aref_prea = 1;
        end
        C_RD, C_WR: begin
          if (!op_v || filling || op_k != ((pc == C_RD) ? 3'd1 : 3'd2) || b != op_b) v_stray = 1;
          if (s_rw || bst_v) v_rw_twice = 1;
          if (!open_m[b] || row_m[b] != row_of(op_a)) v_closed = 1;
          if (n - t_act[b] < T_RCD) v_trcd = 1;
          if (pc == C_RD && n - t_wend_any < T_WTR) v_twtr = 1;
          e_twtr_tight = pc == C_RD && n - t_wend_any <= T_WTR + 2;
          if (q_addr != `LITE_RW_ADDR(op_a)) v_paddr = 1;
          s_rw = 1;
          bst_v = 1; bst_rd = pc == C_RD; bst_b = b; bst_idx = idx_of(op_a);
          bst_t0 = n + ((pc == C_RD) ? `LITE_CL_OF : `LITE_CWL_OF);
          bst_line = (pc == C_RD) ? arr[bst_idx] :
                     {wb[7], wb[6], wb[5], wb[4], wb[3], wb[2], wb[1], wb[0]};
          bst_bl = `LITE_BL;
          e_rd_cl_mr = pc == C_RD && `LITE_CL_OF != CL0;
          e_wr_cwl_mr = pc == C_WR && `LITE_CWL_OF != CWL0;
        end
`ifdef LITE_PBREF
        C_REF: if (!q_addr[10]) begin
          // per-entry REF: the entry is due, closed, past tRP
          if (!pend_pb[b]) v_ref_undue = 1;
          if (open_m[b]) v_ref_open = 1;
          if (n - t_pre[b] < T_RP) v_trp = 1;
          if (q_addr != `LITE_PRE_ADDR(b)) v_paddr = 1;
          e_aref_prea = n - t_pre[b] <= T_RP + 2;
          e_aref_closed = !e_aref_prea;
          e_ref_mid_op = op_v && op_k != 3'd5;
          pend_pb[b] = 0; t_refpb[b] = n;
        end else begin
          if (any_open) v_ref_open = 1;
          for (int i = 0; i < NB; i++) if (n - t_pre[i] < T_RP) v_trp = 1;
          if (q_addr != 14'h0400 || q_ba != 0) v_paddr = 1;
          if (op_v && op_k == 3'd5 && !s_ref) begin
            s_ref = 1; t_refpin = n; e_href = 1;
          end else v_ref_undue = 1;
          t_ref = n;
        end
`else
        C_REF: begin
          if (any_open) v_ref_open = 1;
          for (int i = 0; i < NB; i++) if (n - t_pre[i] < T_RP) v_trp = 1;
          // a host REFRESH is served by the next REF; one that comes in
          // while a due refresh is already under way gets a REF of its own
          if (op_v && op_k == 3'd5) begin
            s_ref = 1; t_refpin = n; e_href = 1;
          end else if (!pend_m) v_ref_undue = 1;
          else begin
            e_aref_closed = !e_aref_prea && n - t_pre[0] > T_RP + 2 && n - t_pre[1] > T_RP + 2;
            e_ref_mid_op = op_v;
          end
          pend_m = 0; t_ref = n;
        end
`endif
        default: ;
      endcase
`ifdef LITE_PBREF
      // tRFC_PB: the refreshed entry takes no ACT / REF until it is over
      if ((pc == C_ACT || pc == C_REF && !q_addr[10]) && n - t_refpb[b] < T_RFC_PB &&
          !(pc == C_REF && t_refpb[b] == n)) v_trfc = 1;
`endif
      `LITE_EXTRA
      // ---- refresh interval (the DUT's tREFI countdown; a REF in this
      // clock served the previous one)
`ifdef LITE_PBREF
      if (refi_m != 0) refi_m = refi_m - 1;
      else begin
        refi_m = T_REFI;
        if (!pend_pb[rot_m]) pb_since[rot_m] = n;
        pend_pb[rot_m] = 1;
        rot_m = (rot_m + 1) % NB;
      end
      for (int i = 0; i < NB; i++) if (pend_pb[i] && n - pb_since[i] > REF_LAT) v_ref_late = 1;
`else
      if (refi_m != 0) refi_m = refi_m - 1;
      else begin
        refi_m = T_REFI;
        if (!pend_m) pend_since = n;
        pend_m = 1;
      end
      if (pend_m && n - pend_since > REF_LAT) v_ref_late = 1;
`endif
      // ---- trace: with each ACT / RD / WR / PRE / REF
      if (q_tv !== (pc == C_ACT || pc == C_RD || pc == C_WR || pc == C_PRE || pc == C_REF))
        v_trace = 1;
      else if (q_tv) begin
`ifdef LITE_PBREF
        if (q_tc !== ((pc == C_ACT) ? 3'd0 : (pc == C_RD) ? 3'd1 : (pc == C_WR) ? 3'd2 :
                      (pc == C_PRE) ? 3'd3 : q_addr[10] ? 3'd6 : 3'd5)) v_trace = 1;
        if (q_ta !== ((pc == C_REF) ? (q_addr[10] ? 32'h0 : 32'(b)) :
                      (pc == C_PRE && pb_pre) ? {11'h0, 9'(pre_row), 12'h0} :
                      {11'h0, 9'(row_of(op_a)), 12'h0})) v_trace = 1;
`else
        if (q_tc !== ((pc == C_ACT) ? 3'd0 : (pc == C_RD) ? 3'd1 : (pc == C_WR) ? 3'd2 :
                      (pc == C_PRE) ? 3'd3 : 3'd4)) v_trace = 1;
        if (q_ta !== ((pc == C_REF) ? 32'h0 : {11'h0, 9'(row_of(op_a)), 12'h0})) v_trace = 1;
`endif
      end
      // ---- completion
      done_now = 0;
      if (q_hdone) begin
        if (imm_at == n) begin
          if (imm_mrr && q_hrdata !== {8'h0, imm_val}) v_mrr = 1;
          imm_at = -1;
        end else if (op_v && !filling) begin
          case (op_k)
            3'd1: begin
              if (!s_data) v_hdone = 1;
              for (int i = 0; i < 8; i++)
                if (hr_hist[7 - i] !== bst_line[16*i +: 16]) v_rdata = 1;
            end
            3'd2: if (!s_data) v_hdone = 1;
            default: if (!s_ref || n - t_refpin < T_RFC) v_hdone = 1;
          endcase
          op_v = 0; done_now = 1;
        end else v_hdone = 1;
      end else if (imm_at == n) v_hdone = 1;
      // ---- hready: idle, or taking write beats
      if (q_hready !== (!op_v || filling)) v_hready = 1;
      busy = (op_v && !filling) ? busy + 1 : 0;
      if (busy > BUSY_MAX) v_stuck = 1;
      // ---- irq: two clocks after a rejected command, sticky
      if (err_n >= 0 && n - err_n >= 2) irq_m = 1;
      if (q_irq !== irq_m) v_irq = 1;
      // ---- host command taken
      e_ign_busy = hvalid && !q_hready;
      e_fill_gap = filling && !hvalid;
      if (hvalid && q_hready) begin
        if (filling) begin
          wb[fill] = hwdata; fill = fill + 1;
          if (fill == 8) filling = 0;
        end else begin
          e_b2b = done_now;
          case (hcmd)
            3'd1, 3'd2: if (!in_range(haddr)) begin
              imm_at = n + 1; imm_mrr = 0;
              e_oor_rd = hcmd == 3'd1; e_oor_wr = hcmd == 3'd2;
            end else begin
              op_v = 1; op_k = hcmd; op_a = haddr; op_b = bank_of(haddr);
              s_act = 0; s_pre = 0; s_rw = 0; s_data = 0; s_ref = 0;
              op_open = open_m[op_b];
              op_hit = open_m[op_b] && row_m[op_b] == row_of(haddr);
              filling = hcmd == 3'd2; fill = 0;
              e_rd_hit = hcmd == 3'd1 && op_hit; e_rd_closed = hcmd == 3'd1 && !op_open;
              e_rd_conf = hcmd == 3'd1 && op_open && !op_hit;
              e_wr_hit = hcmd == 3'd2 && op_hit; e_wr_closed = hcmd == 3'd2 && !op_open;
              e_wr_conf = hcmd == 3'd2 && op_open && !op_hit;
            end
            3'd3: begin
              mr_m[haddr[2:0]] = `LITE_MRW(haddr[2:0], hwdata);
              e_mrw = 1; e_mr0_dll = haddr[2:0] == 3'd0 && hwdata[7];
              imm_at = n + 1; imm_mrr = 0;
            end
            3'd4: begin
              imm_at = n + 1; imm_mrr = 1; imm_val = mr_m[haddr[2:0]]; e_mrr = 1;
            end
            3'd5: begin
              op_v = 1; op_k = 3'd5; op_a = haddr; op_b = 0;
              s_act = 0; s_pre = 0; s_rw = 0; s_data = 0; s_ref = 0;
            end
            3'd0: begin imm_at = n + 1; imm_mrr = 0; e_nop = 1; end
            default: begin imm_at = n + 1; imm_mrr = 0; e_bad_cmd = 1; end
          endcase
          if ((hcmd >= 3'd6 || (hcmd == 3'd1 || hcmd == 3'd2) && !in_range(haddr)) && err_n < 0)
            err_n = n;
        end
      end
    end
  end

  `SVA_INV(a_cmd_belongs_to_op_or_refresh, !v_stray)
  `SVA_INV(a_act_to_closed_bank, !v_act_open)
  `SVA_INV(a_rw_to_open_row, !v_closed)
  `SVA_INV(a_one_rw_per_op, !v_rw_twice)
  `SVA_INV(a_trcd, !v_trcd)
  `SVA_INV(a_trp, !v_trp)
  `SVA_INV(a_trc, !v_trc)
  `SVA_INV(a_tras, !v_tras)
  `SVA_INV(a_trrd, !v_trrd)
  `SVA_INV(a_twr, !v_twr)
  `SVA_INV(a_twtr, !v_twtr)
  `SVA_INV(a_trfc, !v_trfc)
  `SVA_INV(a_ref_all_closed, !v_ref_open)
  `SVA_INV(a_ref_only_when_due, !v_ref_undue)
  `SVA_INV(a_refresh_not_starved, !v_ref_late)
  `SVA_INV(a_pin_address, !v_paddr)
  `SVA_INV(a_write_data_on_dq, !v_wdata)
  `SVA_INV(a_read_data_on_dq, !v_rdata_dq)
  `SVA_INV(a_dqs_toggles, !v_dqs)
  `SVA_INV(a_read_data_to_host, !v_rdata)
  `SVA_INV(a_hdone_once_per_op, !v_hdone)
  `SVA_INV(a_mrr_value, !v_mrr)
  `SVA_INV(a_hready_idle_or_fill, !v_hready)
  `SVA_INV(a_op_completes, !v_stuck)
  `SVA_INV(a_irq_on_reject, !v_irq)
  `SVA_INV(a_trace_with_cmd, !v_trace)
  `SVA_INV(a_no_bad_pin_cmd, !v_bad_pin)
  `SVA_INV(a_dq_driven_only_in_burst, !v_oe)

  `FC(read_hit, e_rd_hit)
  `FC(read_closed_bank, e_rd_closed)
  `FC(read_row_conflict, e_rd_conf)
  `FC(write_hit, e_wr_hit)
  `FC(write_closed_bank, e_wr_closed)
  `FC(write_row_conflict, e_wr_conf)
  `FC(host_refresh, e_href)
  `FC(host_refresh_with_prea, e_href_prea)
  `FC(auto_refresh_with_prea, e_aref_prea)
  `FC(auto_refresh_banks_closed, e_aref_closed)
  `FC(auto_refresh_while_op_waits, e_ref_mid_op)
  `FC(mode_register_write, e_mrw)
  `FC(mode_register_read, e_mrr)
`ifndef LITE_NO_DLL
  `FC(mr0_dll_reset_bit, e_mr0_dll)
`endif
  `FC(read_with_programmed_cl, e_rd_cl_mr)
  `FC(write_with_programmed_cwl, e_wr_cwl_mr)
  `FC(out_of_range_read, e_oor_rd)
  `FC(out_of_range_write, e_oor_wr)
  `FC(illegal_command, e_bad_cmd)
  `FC(nop_command, e_nop)
  `FC(write_beat_gap, e_fill_gap)
  `FC(command_while_busy_ignored, e_ign_busy)
  `FC(back_to_back_ops, e_b2b)
  `FC(act_at_trc, e_trc_tight)
  `FC(read_at_twtr, e_twtr_tight)
  `FC(pre_at_twr, e_twr_tight)
