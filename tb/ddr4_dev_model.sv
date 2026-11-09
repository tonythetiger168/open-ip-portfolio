// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ddr4_dev_model: behavioural x16 DDR4 SDRAM device with JEDEC timing checks
// ----------------------------------------------------------------------------
// The portfolio's own stand-in for a vendor model (Micron ddr4_model): same
// pins, and the same command and timing rules the controller must obey.
//  - Commands on the rising edge of CK_t with CS_n low: ACT, RD, WR, PRE,
//    PREA, REF, MRS, ZQCL/ZQCS; DES / NOP otherwise. BL8 only (MR0 A1:0=0,
//    A12 = BC_n high).
//  - Power-up: RESET_n low, CKE high, tXPR before the first command; MRS
//    MR0 / MR2 set CL / CWL (and are checked against the CL / CWL params,
//    the controller must program the same latencies).
//  - Checks, in nCK: tRCD, tRP, tRAS, tRC, tRRD_S/L, tFAW, tCCD_S/L,
//    tWTR_S/L, tWR, tRTP, tRFC, tMRD, tMOD, tXPR, tREFI (a refresh more than
//    9 x tREFI late is an error), state (ACT to an open bank, RD / WR to a
//    closed bank, a command before init, REF with an open bank).
//    Every violation prints "DDR4_MODEL ERROR" and counts in ERRORS.
//  - Data: writes are sampled at each DQS edge (DM_n low masks the byte);
//    reads drive DQ / DQS edge aligned with a 1 tCK preamble.
//    A word never written reads as init_word(bank,row,col) so a reference
//    model can predict it.
// ============================================================================
`timescale 1ps/1ps
module ddr4_dev_model #(
  parameter int TCK_PS  = 625,
  parameter int CL      = 22,
  parameter int CWL     = 16,
  parameter int T_RCD   = 22,
  parameter int T_RP    = 22,
  parameter int T_RAS   = 52,
  parameter int T_RC    = 74,
  parameter int T_RRD_S = 9,
  parameter int T_RRD_L = 11,
  parameter int T_FAW   = 48,
  parameter int T_CCD_S = 4,
  parameter int T_CCD_L = 8,
  parameter int T_WTR_S = 4,
  parameter int T_WTR_L = 12,
  parameter int T_WR    = 24,
  parameter int T_RTP   = 12,
  parameter int T_RFC   = 560,
  parameter int T_REFI  = 12480,
  parameter int T_MRD   = 8,
  parameter int T_MOD   = 24,
  parameter int T_XPR   = 576,
  parameter int ROWB    = 16,
  parameter int COLB    = 10,
  parameter int BGB     = 1,
  parameter int BAB     = 2,
  parameter bit VERBOSE = 0,
  parameter bit DATA    = 1,       // 0: commands and timing only (no DQ)
  parameter bit QUIET   = 0        // 1: count violations without printing them
)(
  input  logic        ck_t,
  input  logic        ck_c,
  input  logic        reset_n,
  input  logic        cke,
  input  logic        odt,
  input  logic        cs_n,
  input  logic        act_n,
  input  logic        ras_n_a16,
  input  logic        cas_n_a15,
  input  logic        we_n_a14,
  input  logic [1:0]  bg,
  input  logic [1:0]  ba,
  input  logic [13:0] a,
  inout  wire  [15:0] dq,
  inout  wire  [1:0]  dqs_t,
  inout  wire  [1:0]  dqs_c,
  inout  wire  [1:0]  dm_n
);
  localparam int NB = 1 << (BGB + BAB);
  localparam int NG = 1 << BGB;
  localparam longint T  = TCK_PS;
  localparam longint T2 = TCK_PS / 2;
  localparam longint T4 = TCK_PS / 4;
  localparam longint NEVER = -(64'sd1 << 40);

  int unsigned ERRORS;
  int unsigned n_cmd [8];                  // ACT RD WR PRE REF MRS ZQ other
  longint      nck;                        // CK count since reset release
  bit          cke_seen;
  longint      cke_at;
  bit          in_init;

  // ---------------- state ----------------
  bit              open_b [NB];
  logic [ROWB-1:0] row_b  [NB];
  longint          t_act  [NB];
  longint          t_pre  [NB];
  longint          t_rd   [NB];
  longint          t_wr   [NB];
  longint          t_act_g [NG];
  longint          t_cas_g [NG];
  longint          t_wre_g [NG];           // end of write data, per group
  longint          t_act_any, t_cas_any, t_wre_any, t_rd_any;
  longint          t_ref, t_mrs, t_last_ref;
  longint          faw [4];
  int              faw_p;
  logic [13:0]     mr [8];
  logic [15:0]     mem [longint];

  function automatic logic [15:0] init_word(input int bank, input int row, input int col);
    logic [31:0] h;
    h = {bank[3:0], row[15:0], col[11:0]};
    init_word = h[15:0] ^ h[31:16] ^ 16'hA55A;
  endfunction

  task automatic err(input string m);
    ERRORS++;
    if (!QUIET) $display("%0t DDR4_MODEL ERROR %m: %s", $time, m);
  endtask

  task automatic chk(input longint since, input int need, input string what);
    if (since != NEVER && nck - since < need)
      err($sformatf("%s violated: %0d nCK < %0d", what, nck - since, need));
  endtask

  function automatic int cl_of(input logic [13:0] m0);
    logic [3:0] c;
    c = {m0[6:4], m0[2]};
    case (c)
      0: cl_of = 9;   1: cl_of = 10;  2: cl_of = 11;  3: cl_of = 12;
      4: cl_of = 13;  5: cl_of = 14;  6: cl_of = 15;  7: cl_of = 16;
      8: cl_of = 18;  9: cl_of = 20;  10: cl_of = 22; 11: cl_of = 24;
      12: cl_of = 23; 13: cl_of = 17; 14: cl_of = 19; default: cl_of = 21;
    endcase
  endfunction
  function automatic int cwl_of(input logic [13:0] m2);
    case (m2[5:3])
      0: cwl_of = 9;  1: cwl_of = 10; 2: cwl_of = 11; 3: cwl_of = 12;
      4: cwl_of = 14; 5: cwl_of = 16; 6: cwl_of = 18; default: cwl_of = 20;
    endcase
  endfunction

  task automatic reset_state();
    for (int b = 0; b < NB; b++) begin
      open_b[b] = 0; row_b[b] = '0;
      t_act[b] = NEVER; t_pre[b] = NEVER; t_rd[b] = NEVER; t_wr[b] = NEVER;
    end
    for (int g = 0; g < NG; g++) begin
      t_act_g[g] = NEVER; t_cas_g[g] = NEVER; t_wre_g[g] = NEVER;
    end
    t_act_any = NEVER; t_cas_any = NEVER; t_wre_any = NEVER; t_rd_any = NEVER;
    t_ref = NEVER; t_mrs = NEVER; t_last_ref = NEVER;
    for (int i = 0; i < 4; i++) faw[i] = NEVER;
    faw_p = 0;
    for (int i = 0; i < 8; i++) mr[i] = '0;
    in_init = 1;
  endtask

  initial begin
    ERRORS = 0; nck = 0; cke_seen = 0; cke_at = NEVER;
    for (int i = 0; i < 8; i++) n_cmd[i] = 0;
    reset_state();
  end

  // ---------------- data bus drivers ----------------
  logic [15:0] dq_o;
  logic        dqs_o;
  int          rd_act;
  assign dq    = rd_act > 0 ? dq_o : 'z;
  assign dqs_t = rd_act > 0 ? {2{dqs_o}}  : 'z;
  assign dqs_c = rd_act > 0 ? {2{~dqs_o}} : 'z;
  initial begin rd_act = 0; dq_o = '0; dqs_o = 1'b0; end

  function automatic longint key(input int bank, input logic [ROWB-1:0] row, input int col);
    key = (longint'(bank) << 40) | (longint'(row) << 16) | longint'(col);
  endfunction

  task automatic rd_burst(input longint t0, input int bank, input logic [ROWB-1:0] row, input int col, input int cl);
    longint e0 = t0 + cl * T;
    #(e0 - T - $time);
    rd_act = rd_act + 1;
    dqs_o  = 1'b0;
    for (int n = 0; n < 8; n++) begin
      longint k = key(bank, row, col + n);
      #(e0 + n * T2 - $time);
      dq_o  = mem.exists(k) ? mem[k] : init_word(bank, row, col + n);
      dqs_o = (n % 2) == 0;
    end
    #(e0 + 4 * T - $time);
    rd_act = rd_act - 1;
  endtask

  task automatic wr_burst(input longint t0, input int bank, input logic [ROWB-1:0] row, input int col, input int cwl);
    longint e0 = t0 + cwl * T;
    for (int n = 0; n < 8; n++) begin
      longint k = key(bank, row, col + n);
      logic [15:0] d, o;
      logic [1:0]  m;
      // the PHY centres DQ on the DQS edge: sample just after the edge
      #(e0 + n * T2 + T4 / 2 - $time);
      if (dqs_t[0] !== ((n % 2) == 0) || dqs_t[1] !== ((n % 2) == 0))
        err($sformatf("write beat %0d: DQS_t not toggling as expected", n));
      d = dq; m = dm_n;
      o = mem.exists(k) ? mem[k] : init_word(bank, row, col + n);
      if (m[0]) o[7:0]  = d[7:0];
      if (m[1]) o[15:8] = d[15:8];
      mem[k] = o;
    end
  endtask

  // ---------------- command decode ----------------
  int          g, bk, col, n;
  logic [16:0] row17;
  longint      t0;
  always @(posedge ck_t) begin
    if (!reset_n) begin
      nck = 0;
      cke_seen = 0;
      reset_state();
    end else begin
      nck++;
      if (cke && !cke_seen) begin cke_seen = 1; cke_at = nck; end
      if (!cs_n) begin
        g     = int'(bg) & (NG - 1);
        bk    = ((int'(bg) & (NG - 1)) << BAB) | (int'(ba) & ((1 << BAB) - 1));
        row17 = {ras_n_a16, cas_n_a15, we_n_a14, a};
        col   = int'(a[COLB-1:0]) & ~7;
        t0    = $time;
        if (!cke_seen) err("command with CKE low");
        else chk(cke_at, T_XPR, "tXPR");
        if (!act_n) begin
          // ---- ACT ----
          n_cmd[0]++;
          if (in_init) err("ACT before MRS / ZQ init");
          if (open_b[bk]) err($sformatf("ACT to open bank %0d", bk));
          chk(t_act[bk], T_RC, "tRC");
          chk(t_pre[bk], T_RP, "tRP");
          chk(t_act_g[g], T_RRD_L, "tRRD_L");
          chk(t_act_any, T_RRD_S, "tRRD_S");
          chk(faw[faw_p], T_FAW, "tFAW");
          chk(t_ref, T_RFC, "tRFC");
          chk(t_mrs, T_MOD, "tMOD");
          open_b[bk] = 1; row_b[bk] = row17[ROWB-1:0];
          t_act[bk] = nck; t_act_g[g] = nck; t_act_any = nck;
          faw[faw_p] = nck; faw_p = (faw_p + 1) % 4;
          if (VERBOSE) $display("%0t DDR4 ACT bank %0d row %0h", $time, bk, row17[ROWB-1:0]);
        end else begin
          case ({ras_n_a16, cas_n_a15, we_n_a14})
            3'b101: begin // ---- RD ----
              n_cmd[1]++;
              if (!open_b[bk]) err($sformatf("RD to closed bank %0d", bk));
              if (a[12] !== 1'b1) err("RD with BC4 (only BL8 modelled)");
              if (a[10]) err("RD with auto-precharge (not modelled)");
              chk(t_act[bk], T_RCD, "tRCD (RD)");
              chk(t_cas_g[g], T_CCD_L, "tCCD_L");
              chk(t_cas_any, T_CCD_S, "tCCD_S");
              chk(t_wre_g[g], T_WTR_L, "tWTR_L");
              chk(t_wre_any, T_WTR_S, "tWTR_S");
              t_cas_g[g] = nck; t_cas_any = nck; t_rd[bk] = nck; t_rd_any = nck;
              if (DATA) fork rd_burst(t0, bk, row_b[bk], col, cl_of(mr[0])); join_none
            end
            3'b100: begin // ---- WR ----
              n_cmd[2]++;
              if (!open_b[bk]) err($sformatf("WR to closed bank %0d", bk));
              if (a[12] !== 1'b1) err("WR with BC4 (only BL8 modelled)");
              if (a[10]) err("WR with auto-precharge (not modelled)");
              chk(t_act[bk], T_RCD, "tRCD (WR)");
              chk(t_cas_g[g], T_CCD_L, "tCCD_L");
              chk(t_cas_any, T_CCD_S, "tCCD_S");
              if (t_rd_any != NEVER && nck - t_rd_any < cl_of(mr[0]) + 4 + 2 - cwl_of(mr[2]))
                err("read to write turnaround violated");
              t_cas_g[g] = nck; t_cas_any = nck; t_wr[bk] = nck;
              t_wre_g[g] = nck + cwl_of(mr[2]) + 4; t_wre_any = t_wre_g[g];
              if (DATA) fork wr_burst(t0, bk, row_b[bk], col, cwl_of(mr[2])); join_none
            end
            3'b010: begin // ---- PRE / PREA ----
              n_cmd[3]++;
              for (int b = 0; b < NB; b++) begin
                if (a[10] || b == bk) begin
                  if (open_b[b]) begin
                    chk(t_act[b], T_RAS, "tRAS");
                    chk(t_rd[b], T_RTP, "tRTP");
                    if (t_wr[b] != NEVER && nck - t_wr[b] < cwl_of(mr[2]) + 4 + T_WR)
                      err($sformatf("tWR violated on bank %0d", b));
                    t_pre[b] = nck;
                  end
                  open_b[b] = 0;
                end
              end
            end
            3'b001: begin // ---- REF ----
              n_cmd[4]++;
              for (int b = 0; b < NB; b++) begin
                if (open_b[b]) err($sformatf("REF with bank %0d open", b));
                chk(t_pre[b], T_RP, "tRP (REF)");
              end
              chk(t_ref, T_RFC, "tRFC (REF to REF)");
              if (t_last_ref != NEVER && nck - t_last_ref > 9 * T_REFI)
                err("refresh postponed more than 8 x tREFI");
              t_ref = nck; t_last_ref = nck;
            end
            3'b000: begin // ---- MRS ----
              n = {bg[0], ba};
              n_cmd[5]++;
              for (int b = 0; b < NB; b++) if (open_b[b]) err("MRS with a bank open");
              chk(t_mrs, T_MRD, "tMRD");
              mr[n] = a;
              t_mrs = nck;
              if (n == 0) begin
                if (cl_of(a) != CL) err($sformatf("MR0 CL %0d, expected %0d", cl_of(a), CL));
                if (a[1:0] != 2'b00) err("MR0 burst length is not BL8");
              end
              if (n == 2 && cwl_of(a) != CWL) err($sformatf("MR2 CWL %0d, expected %0d", cwl_of(a), CWL));
            end
            3'b110: begin // ---- ZQCL / ZQCS ----
              n_cmd[6]++;
              chk(t_mrs, T_MOD, "tMOD (ZQ)");
              if (a[10]) in_init = 0;          // ZQCL ends the init sequence
            end
            default: n_cmd[7]++;               // NOP
          endcase
        end
      end
      if (!in_init && t_last_ref == NEVER) t_last_ref = nck;
    end
  end
endmodule
