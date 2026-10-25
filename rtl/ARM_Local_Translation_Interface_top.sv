// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ARM_Local_Translation_Interface_top v2.0: the translation side of an
// AMBA LTI (Local Translation Interface) link: translation requests (LA),
// responses (LR) with context tags, completions (LC), link open / close,
// a small translation table, invalidation with synchronization
// ----------------------------------------------------------------------------
//  - Link: the manager raises lm_open_req; the unit answers lm_open_ack
//    and then grants RQ request credits (la_credit pulses, one per free
//    request slot). A request on LA takes a credit. When lm_open_req
//    falls the unit stops granting, answers what it holds, waits for
//    every context tag to come back, and drops lm_open_ack; credits the
//    manager still holds are void from then on.
//  - LA: la_id, la_va (VA[31:12]), la_sid / la_ssid / la_ssidv (StreamID,
//    SubstreamID), la_rw (bit 0 read, bit 1 write), la_instr, la_priv.
//    Requests are answered in order, one per clock at most.
//  - Translation: NE table entries {sid, ssid (or any substream when
//    ssidv is clear), VA page, PA page, R / W / X / U permissions, attr},
//    written on cfg_*; the lowest matching entry is used. A read needs R,
//    a write W, an instruction fetch X, an unprivileged access U.
//  - LR: lr_resp 0 OK with lr_pa, lr_attr and a context tag lr_ctag; 1
//    translation fault (no entry), 2 permission fault (ev_fault on
//    either; a fault carries no tag). An OK response waits while all NCT
//    tags are in use.
//  - LC: the manager returns a tag once the transaction using the
//    translation is done (lc_valid, lc_ctag).
//  - Invalidation: inv_valid / inv_ready with inv_all or inv_sid clears
//    the matching entries at once; inv_done pulses once every tag handed
//    out before (or with) it has come back, so no transaction still uses
//    an old translation. inv_ready is low while one waits.
//  - ev_proto: a request without a credit (dropped), a tag returned that
//    is not out (ignored).
//  Not implemented: the LTI virtual channels and their ordering, the full
//  LA / LR field set (memory attributes in, stage 2, PASID prefixes, ATS,
//  MPAM, hints), the TBU's walk of real page tables (the table is
//  programmed directly), LR flow control, the LM channel beyond
//  open / close. Field widths and encodings are ours; they have not been
//  checked against an LTI manager.
// ============================================================================
module ARM_Local_Translation_Interface_top #(
  parameter int NE  = 8,                // table entries
  parameter int RQ  = 4,                // request slots (credits), power of 2
  parameter int NCT = 8                 // context tags, power of 2
)(
  input  logic        clk,
  input  logic        rst_n,
  // link
  input  logic        lm_open_req,
  output logic        lm_open_ack,
  // LA: translation requests
  input  logic        la_valid,
  input  logic [3:0]  la_id,
  input  logic [19:0] la_va,
  input  logic [7:0]  la_sid,
  input  logic [7:0]  la_ssid,
  input  logic        la_ssidv,
  input  logic [1:0]  la_rw,
  input  logic        la_instr,
  input  logic        la_priv,
  output logic        la_credit,
  // LR: responses
  output logic        lr_valid,
  output logic [3:0]  lr_id,
  output logic [1:0]  lr_resp,
  output logic [19:0] lr_pa,
  output logic [7:0]  lr_attr,
  output logic [$clog2(NCT)-1:0] lr_ctag,
  // LC: completions
  input  logic        lc_valid,
  input  logic [$clog2(NCT)-1:0] lc_ctag,
  // table
  input  logic        cfg_we,
  input  logic [$clog2(NE)-1:0] cfg_idx,
  input  logic        cfg_v,
  input  logic [7:0]  cfg_sid,
  input  logic [7:0]  cfg_ssid,
  input  logic        cfg_ssidv,
  input  logic [19:0] cfg_va,
  input  logic [19:0] cfg_pa,
  input  logic [3:0]  cfg_perm,         // {U, X, W, R}
  input  logic [7:0]  cfg_attr,
  // invalidation
  input  logic        inv_valid,
  output logic        inv_ready,
  input  logic        inv_all,
  input  logic [7:0]  inv_sid,
  output logic        inv_done,
  // status and events
  output logic [$clog2(NCT):0] ctags_out,
  output logic        ev_fault,
  output logic        ev_proto
);
  localparam int EW = $clog2(NE);
  localparam int QW = $clog2(RQ);
  localparam int TW = $clog2(NCT);
  localparam int RW = 4 + 20 + 8 + 8 + 1 + 2 + 1 + 1;   // a request

  // ---------------- table ----------------
  logic [NE-1:0] e_v, e_ssidv;
  logic [7:0]    e_sid [0:NE-1], e_ssid [0:NE-1], e_attr [0:NE-1];
  logic [19:0]   e_va [0:NE-1], e_pa [0:NE-1];
  logic [3:0]    e_perm [0:NE-1];

  // ---------------- request slots ----------------
  logic [RW-1:0] rq [0:RQ-1];
  logic [QW:0]   rqw, rqr;
  logic [QW:0]   g;                     // credits out
  wire  [QW:0]   rq_n = rqw - rqr;
  wire  [RW-1:0] h = rq[rqr[QW-1:0]];
  wire           h_v = rq_n != '0;
  wire  [3:0]    h_id = h[RW-1 -: 4];
  wire  [19:0]   h_va = h[RW-5 -: 20];
  wire  [7:0]    h_sid = h[RW-25 -: 8];
  wire  [7:0]    h_ssid = h[RW-33 -: 8];
  wire           h_ssidv = h[4];
  wire  [1:0]    h_rw = h[3:2];
  wire           h_instr = h[1];
  wire           h_priv = h[0];

  // lookup of the head request
  logic          k_hit;
  logic [EW-1:0] k_i;
  always_comb begin
    k_hit = 1'b0; k_i = '0;
    for (int i = NE - 1; i >= 0; i--)
      if (e_v[i] && e_sid[i] == h_sid && e_va[i] == h_va && (!e_ssidv[i] || h_ssidv && e_ssid[i] == h_ssid)) begin
        k_hit = 1'b1; k_i = EW'(i);
      end
  end
  wire [3:0] k_p = e_perm[k_i];
  wire       k_perm = (!h_rw[0] || k_p[0]) && (!h_rw[1] || k_p[1]) && (!h_instr || k_p[2]) && (h_priv || k_p[3]);

  // ---------------- context tags ----------------
  logic [NCT-1:0] ct;                   // out
  logic [NCT-1:0] sync;                 // out when the waiting invalidation came
  logic           s_busy;
  logic [TW-1:0]  ct_free;
  always_comb begin
    ct_free = '0;
    for (int i = NCT - 1; i >= 0; i--) if (!ct[i]) ct_free = TW'(i);
  end
  wire ct_full = &ct;
  // the head request answered this clock
  wire go = h_v && !(k_hit && k_perm && ct_full);

  // ---------------- link ----------------
  typedef enum logic [1:0] {L_CLOSED, L_OPEN, L_CLOSING} l_t;
  l_t ls;
  assign lm_open_ack = ls != L_CLOSED;
  assign inv_ready = !s_busy;

  always_comb begin
    ctags_out = '0;
    for (int i = 0; i < NCT; i++) ctags_out = ctags_out + (TW + 1)'(ct[i]);
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      e_v <= '0; e_ssidv <= '0;
      for (int i = 0; i < NE; i++) begin
        e_sid[i] <= '0; e_ssid[i] <= '0; e_attr[i] <= '0; e_va[i] <= '0; e_pa[i] <= '0; e_perm[i] <= '0;
      end
      for (int i = 0; i < RQ; i++) rq[i] <= '0;
      rqw <= '0; rqr <= '0; g <= '0; la_credit <= 1'b0;
      ct <= '0; sync <= '0; s_busy <= 1'b0; ls <= L_CLOSED;
      lr_valid <= 1'b0; lr_id <= '0; lr_resp <= '0; lr_pa <= '0; lr_attr <= '0; lr_ctag <= '0;
      inv_done <= 1'b0; ev_fault <= 1'b0; ev_proto <= 1'b0;
    end else begin : b_main
      logic [QW:0]    gg;
      logic [NCT-1:0] c, newt;
      bit             push;
      gg = g; c = ct; newt = '0; push = 1'b0;
      lr_valid <= 1'b0; la_credit <= 1'b0; inv_done <= 1'b0; ev_fault <= 1'b0; ev_proto <= 1'b0;

      // ---- table writes, then invalidation (an invalidation wins)
      if (cfg_we) begin
        e_v[cfg_idx] <= cfg_v; e_ssidv[cfg_idx] <= cfg_ssidv;
        e_sid[cfg_idx] <= cfg_sid; e_ssid[cfg_idx] <= cfg_ssid; e_va[cfg_idx] <= cfg_va;
        e_pa[cfg_idx] <= cfg_pa; e_perm[cfg_idx] <= cfg_perm; e_attr[cfg_idx] <= cfg_attr;
      end
      // ---- LA
      if (la_valid) begin
        if (gg == '0) ev_proto <= 1'b1;
        else begin
          gg = gg - 1'b1; push = 1'b1;
          rq[rqw[QW-1:0]] <= {la_id, la_va, la_sid, la_ssid, la_ssidv, la_rw, la_instr, la_priv};
          rqw <= rqw + 1'b1;
        end
      end
      // ---- LR: the head request
      if (go) begin
        rqr <= rqr + 1'b1;
        lr_valid <= 1'b1; lr_id <= h_id;
        if (!k_hit) begin
          lr_resp <= 2'd1; lr_pa <= '0; lr_attr <= '0; lr_ctag <= '0; ev_fault <= 1'b1;
        end else if (!k_perm) begin
          lr_resp <= 2'd2; lr_pa <= '0; lr_attr <= '0; lr_ctag <= '0; ev_fault <= 1'b1;
        end else begin
          lr_resp <= 2'd0; lr_pa <= e_pa[k_i]; lr_attr <= e_attr[k_i]; lr_ctag <= ct_free;
          newt[ct_free] = 1'b1;
        end
      end
      // ---- LC
      if (lc_valid) begin
        if (!c[lc_ctag]) ev_proto <= 1'b1;
        else c[lc_ctag] = 1'b0;
      end
      c = c | newt;
      // ---- invalidation
      if (inv_valid && !s_busy) begin
        for (int i = 0; i < NE; i++)
          if (inv_all || e_sid[i] == inv_sid) e_v[i] <= 1'b0;
        if (c != '0) begin                                // tags out, with one handed out now
          s_busy <= 1'b1; sync <= c;
        end else inv_done <= 1'b1;
      end else if (s_busy) begin
        if ((sync & c) == '0) begin s_busy <= 1'b0; inv_done <= 1'b1; end
        sync <= sync & c;
      end
      // ---- link and credits
      case (ls)
        L_CLOSED: if (lm_open_req) ls <= L_OPEN;
        L_OPEN: begin
          if (32'(gg) + 32'(rq_n) + 32'(push) - 32'(go) < RQ) begin
            la_credit <= 1'b1;
            gg = gg + 1'b1;
          end
          if (!lm_open_req) ls <= L_CLOSING;
        end
        default:                                          // L_CLOSING
          if (rq_n == '0 && !push && c == '0) begin
            ls <= L_CLOSED; gg = '0;
          end
      endcase
      ct <= c; g <= gg;
    end
endmodule
