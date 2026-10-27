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
//   * hready returns only once the command's work is on the pins.
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

  logic        q_hready, q_hdone, q_tv;
  logic [15:0] q_hrdata;
  logic [2:0]  q_tc;
  logic [31:0] q_ta;
  always @(negedge clk) begin
    q_hready <= hready; q_hdone <= hdone; q_hrdata <= hrdata;
    q_tv <= trace_valid; q_tc <= trace_cmd; q_ta <= trace_addr;
  end

  longint      n, t_ref, t_refend, t_rdpin;
  longint      t_act [0:NB-1], t_pre [0:NB-1];
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
  // functional-coverage samples (set by the model, sampled at the falling edge)
  logic        c_acc, c_rdv;
  logic [2:0]  c_cmd, c_prev, c_last;
  logic [1:0]  c_col;
  logic [15:0] c_wd, c_rdd;

  // violations (checked one clock later by the assertions below)
  logic v_stray, v_closed, v_act_open, v_trcd, v_trp, v_trc, v_tras, v_trfc, v_ref_open,
        v_paddr, v_wdata, v_trace, v_hdone, v_lat, v_rdata, v_incomplete, v_stuck,
        v_ref_late, v_ref_early, v_bad_pin, v_reopen;
  // functional events
  logic e_rd_hit, e_rd_closed, e_rd_conf, e_wr_hit, e_wr_closed, e_wr_conf, e_act_closed,
        e_act_conf, e_act_same, e_pre_open, e_pre_closed, e_ref_idle, e_ref_act, e_ref_rd,
        e_ref_wr, e_ref_pre, e_ign_busy, e_unknown, e_col0, e_col255, e_b2b, e_prea, e_apre,
        e_refpb_others_open;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      n = 0; t_ref = 0; t_refend = 0; t_rdpin = 0; busy = 0;
      op_v = 0; s_act = 0; s_rw = 0; s_pre = 0; s_done = 0; s_apre = 0; op_hit = 0; op_open = 0;
      p_tv = 0; p_done = 0; m_chk = 0; rb_m = 0;
      c_acc = 0; c_rdv = 0; c_cmd = 0; c_prev = 0; c_last = 0; c_col = 0; c_wd = 0; c_rdd = 0;
      for (int b = 0; b < NB; b++) begin
        open_m[b] = 0; row_m[b] = 0; t_act[b] = -1000000; t_pre[b] = -1000000;
      end
      {v_stray, v_closed, v_act_open, v_trcd, v_trp, v_trc, v_tras, v_trfc, v_ref_open,
       v_paddr, v_wdata, v_trace, v_hdone, v_lat, v_rdata, v_incomplete, v_stuck,
       v_ref_late, v_ref_early, v_bad_pin, v_reopen} = '0;
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
       v_ref_late, v_ref_early, v_bad_pin, v_reopen} = '0;
      {e_rd_hit, e_rd_closed, e_rd_conf, e_wr_hit, e_wr_closed, e_wr_conf, e_act_closed,
       e_act_conf, e_act_same, e_pre_open, e_pre_closed, e_ref_idle, e_ref_act, e_ref_rd,
       e_ref_wr, e_ref_pre, e_ign_busy, e_unknown, e_col0, e_col255, e_b2b, e_prea, e_apre,
       e_refpb_others_open} = '0;
      // ---- read data registered by the previous hdone
      c_acc = 0; c_rdv = m_chk; c_rdd = q_hrdata;
      if (m_chk) v_rdata = q_hrdata !== m_exp;
      m_chk = 0;
      // ---- pin command
      drn = op_v && (`MEM_CHK_DRAINING);
      // the host command has done its own pin work (what is left is refresh)
      // (an RD / WR that must auto-precharge is not done before its PRE)
      wd = !op_v || (op_c == 3'd2 ? s_done && !((`MEM_CHK_AP_MUST) && !s_apre) :
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
      if (is_cmd && n < t_refend) v_trfc = 1;
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
            arr[cellof(ta)] = `MEM_CHK_DRAIN_D;
            `MEM_CHK_DRAIN_POP
          end
        end else begin
          if (!op_v || op_c != ((q_pc == P_RD) ? 3'd2 : 3'd3) || s_rw) v_stray = 1;
          else begin
            if (!open_m[b] || !`MEM_CHK_RW_ROW_OK(b, row_of(op_a))) v_closed = 1;
            if (n - t_act[b] < TRCD) v_trcd = 1;
            if (!pin_col_ok(q_pa, col_of(op_a))) v_paddr = 1;
            s_rw = 1;
            if (q_pc == P_WR) begin
              if ((p_wl & `MEM_CHK_WMASK) !== (op_d & `MEM_CHK_WMASK)) v_wdata = 1;
              arr[cellof(op_a)] = (arr[cellof(op_a)] & ~`MEM_CHK_WMASK) | (op_d & `MEM_CHK_WMASK);
            end else t_rdpin = n;
          end
        end
        P_PRE: if (`MEM_CHK_PB && wd && !drn) begin   // per-entry refresh PRE
          if (open_m[tb] && n - t_act[tb] < TRAS) v_tras = 1;
          open_m[tb] = 0; t_pre[tb] = n; rpre = 1;
        end else begin
          if (!op_v || !drn && (s_apre || s_rw && !(`MEM_CHK_AP_OK))) v_stray = 1;
          else begin
            if (open_m[b] && n - t_act[b] < TRAS) v_tras = 1;
            open_m[b] = 0; t_pre[b] = n;
            if (!drn) s_pre = 1;
            if (!drn && s_rw) begin s_apre = 1; e_apre = 1; end
          end
        end
        P_PREA: begin
          e_prea = 1;
          for (int i = 0; i < NB; i++) begin
            if (open_m[i] && n - t_act[i] < TRAS) v_tras = 1;
            open_m[i] = 0; t_pre[i] = n;
          end
        end
        P_REF: begin
          if (`MEM_CHK_PB) begin
            if (open_m[tb]) v_ref_open = 1;
            if (n - t_pre[tb] < TRP) v_trp = 1;
            for (int i = 0; i < NB; i++) if (i != tb && open_m[i]) e_refpb_others_open = 1;
            rb_m = rb_m + 1;
          end else
          for (int i = 0; i < NB; i++) begin
            if (open_m[i]) v_ref_open = 1;
            if (n - t_pre[i] < TRP) v_trp = 1;
          end
          if (t_ref != 0 && n - t_ref < REF_MIN) v_ref_early = 1;
          t_ref = n; t_refend = n + TRFC;
          e_ref_idle = !op_v;
          e_ref_act = op_v && op_c == 3'd1; e_ref_rd = op_v && op_c == 3'd2;
          e_ref_wr = op_v && op_c == 3'd3; e_ref_pre = op_v && op_c == 3'd4;
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
        if (!op_v || op_c != 3'd2 || !s_rw || s_done) v_hdone = 1;
        else begin
          if (n - t_rdpin != CL) v_lat = 1;
          m_chk = 1; m_exp = arr[cellof(op_a)]; s_done = 1;
        end
      end
      `MEM_CHK_EXTRA
      // ---- hready back: the command must be complete
      done_now = 0;
      if (op_v && q_hready) begin
        case (op_c)
          3'd1: if (!s_act && !op_hit) v_incomplete = 1;
          3'd2: if (!s_done || (`MEM_CHK_AP_MUST) && !s_apre) v_incomplete = 1;
          3'd3: if (!(`MEM_CHK_WR_DONE) || (`MEM_CHK_AP_MUST) && !s_apre) v_incomplete = 1;
          default: if (!s_pre && op_open) v_incomplete = 1;
        endcase
        `MEM_CHK_ON_DONE
        op_v = 0; done_now = 1;
      end
      busy = q_hready ? 0 : busy + 1;
      if (busy > BUSY_MAX) v_stuck = 1;
      e_ign_busy = hvalid && !q_hready;
      // ---- host command taken
      if (hvalid && q_hready) begin
        if (hcmd >= 3'd1 && hcmd <= 3'd4) begin
          op_v = 1; op_c = hcmd; op_a = haddr; op_d = hwdata; op_b = bank_of(haddr);
          s_act = 0; s_rw = 0; s_pre = 0; s_done = 0; s_apre = 0;
          op_open = open_m[op_b];
          op_hit = open_m[op_b] && row_m[op_b] == row_of(haddr);
`ifdef MEM_CHK_RW_ANY_ROW
          if (hcmd == 3'd2 || hcmd == 3'd3) op_hit = open_m[op_b];
`endif
          e_b2b = done_now;
          c_acc = 1; c_cmd = hcmd; c_prev = c_last; c_last = hcmd; c_wd = hwdata;
          c_col = col_of(haddr) == 8'h00 ? 2'd0 : col_of(haddr) == 8'hFF ? 2'd1 : 2'd2;
          e_col0 = col_of(haddr) == 8'h00; e_col255 = col_of(haddr) == 8'hFF;
          `MEM_CHK_ON_ACCEPT
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
`ifndef MEM_CHK_CKE_PD
  `SVA_INV(a_cke_out_of_reset, cke)
`endif
  `SVA_RST(a_reset_pins, !rst_n, !cke && !hdone && !trace_valid && q_pc == P_NOP)

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
  `FC_RST(reset_with_command_in_flight, rst_n && !hready ##1 !rst_n)
