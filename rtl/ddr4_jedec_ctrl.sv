// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ddr4_jedec_ctrl: JEDEC DDR4 (JESD79-4) command scheduler for x16 devices
// ----------------------------------------------------------------------------
//  - Drives real DDR4 command pins (RESET_n, CKE, CS_n, ACT_n, RAS_n/A16,
//    CAS_n/A15, WE_n/A14, BG, BA, A[13:0], ODT) at 1:1 with CK, so a vendor
//    device model (Micron ddr4_model) or the portfolio's ddr4_dev_model can
//    sit on the pins behind a PHY.
//  - Power-up and init per JESD79-4 3.3: RESET_n low, CKE low, CKE high,
//    tXPR, MRS MR3 MR6 MR5 MR4 MR2 MR1 MR0 (tMRD apart, tMOD after MR0),
//    ZQCL, tZQinit. INIT_DONE then rises.
//  - Open-page policy, one row per bank. Per-bank tRCD, tRP, tRAS, tRC,
//    tRTP, tWR; bank-group tRRD_S/L, tCCD_S/L, tWTR_S/L; tFAW over the last
//    four ACTs; read-to-write turnaround; all-bank REF every tREFI (PREA
//    first when a bank is open), tRFC.
//  - Host port: one burst (BL8 = BB bytes) per request, in order. Writes
//    carry data and byte enables (DM_n masks the unenabled bytes, so there
//    is no read-modify-write); reads return data in request order on
//    U_RVALID. Several reads may be in flight (the PHY keeps the order).
//  - PHY port: the command pins plus P_WR (the WRITE was issued this cycle,
//    P_WDATA / P_WBE is its burst, beat n in [n*DQW +: DQW]) and P_RVALID /
//    P_RDATA from the PHY. The PHY applies CWL / CL itself.
//  - Address map: the host port carries the burst number (byte address /
//    BB); from its bottom bit: column[COLB-1:3], BG, BA, row. Bank groups next to the column bits
//    spread a linear stream over the groups (tCCD_S instead of tCCD_L).
//  - All timings are in CK cycles (parameters). Defaults: DDR4-3200AA
//    (22-22-22), 8 Gb x16 (2 BG x 4 BA, 64K rows, 1K columns).
// ============================================================================
module ddr4_jedec_ctrl #(
  parameter int NDEV     = 1,      // x16 devices side by side (data width 16*NDEV)
  parameter int ROWB     = 16,
  parameter int COLB     = 10,
  parameter int BGB      = 1,      // x16: 2 bank groups
  parameter int BAB      = 2,
  // CAS latencies (programmed into MR0 / MR2)
  parameter int CL       = 22,
  parameter int CWL      = 16,
  // core timings in nCK
  parameter int T_RCD    = 22,
  parameter int T_RP     = 22,
  parameter int T_RAS    = 52,
  parameter int T_RC     = 74,
  parameter int T_RRD_S  = 9,
  parameter int T_RRD_L  = 11,
  parameter int T_FAW    = 48,
  parameter int T_CCD_S  = 4,
  parameter int T_CCD_L  = 8,
  parameter int T_WTR_S  = 4,
  parameter int T_WTR_L  = 12,
  parameter int T_WR     = 24,
  parameter int T_RTP    = 12,
  parameter int T_RFC    = 560,
  parameter int T_REFI   = 12480,
  parameter int T_MRD    = 8,
  parameter int T_MOD    = 24,
  parameter int T_ZQINIT = 1024,
  parameter int T_XPR    = 576,
  // power-up waits (shorten for simulation)
  parameter int T_RESET  = 64,     // RESET_n low (tPW_RESET / tINIT1)
  parameter int T_CKE    = 64,     // RESET_n high to CKE high (tINIT3)
  localparam int DQW     = 16 * NDEV,
  localparam int BB      = DQW,    // BL8 * DQW / 8 bytes
  localparam int NB      = 1 << (BGB + BAB),
  localparam int NG      = 1 << BGB,
  localparam int UAW     = COLB - 3 + BGB + BAB + ROWB
)(
  input  logic                 clk,       // = CK
  input  logic                 rst_n,
  // host port
  input  logic                 u_valid,
  output logic                 u_ready,
  input  logic                 u_write,
  input  logic [UAW-1:0]       u_addr,    // DRAM burst number: byte address / BB
  input  logic [BB*8-1:0]      u_wdata,
  input  logic [BB-1:0]        u_wbe,
  output logic                 u_rvalid,
  output logic [BB*8-1:0]      u_rdata,
  // DDR4 command pins (to the PHY)
  output logic                 p_reset_n,
  output logic                 p_cke,
  output logic                 p_odt,
  output logic                 p_cs_n,
  output logic                 p_act_n,
  output logic                 p_ras_n,   // A16
  output logic                 p_cas_n,   // A15
  output logic                 p_we_n,    // A14
  output logic [1:0]           p_bg,
  output logic [1:0]           p_ba,
  output logic [13:0]          p_a,
  output logic                 p_wr,
  output logic [8*DQW-1:0]     p_wdata,
  output logic [BB-1:0]        p_wbe,
  input  logic                 p_rvalid,
  input  logic [8*DQW-1:0]     p_rdata,
  // status
  output logic                 init_done,
  output logic [15:0]          n_act,
  output logic [15:0]          n_hit,     // RD / WR to an already open row
  output logic [15:0]          n_ref
);
  localparam int CHB = COLB - 3;           // column bits above the burst

  // ---------------- mode register codes (JESD79-4 tables) ----------------
  // packed lookup tables (constant expressions, so no logic and no runtime code)
  // CL 9..24 -> MR0 A12, A6:A4, A2
  localparam logic [63:0] CL_TAB  = {4'd11, 4'd12, 4'd10, 4'd15, 4'd9, 4'd14, 4'd8, 4'd13,
                                     4'd7,  4'd6,  4'd5,  4'd4,  4'd3, 4'd2,  4'd1, 4'd0};
  // tWR rounded up to a legal MR0 value 10, 12, .. 26 -> MR0 A13, A11:A9
  localparam int          WR_MR   = T_WR <= 10 ? 10 : T_WR <= 26 ? T_WR + (T_WR & 1) : 26;
  localparam logic [35:0] WR_TAB  = {4'd8, 4'd6, 4'd7, 4'd5, 4'd4, 4'd3, 4'd2, 4'd1, 4'd0};
  // CWL 9..20 -> MR2 A5:A3 (13, 15, 17, 19 are not legal)
  localparam logic [35:0] CWL_TAB = {3'd7, 3'd0, 3'd6, 3'd0, 3'd5, 3'd0, 3'd4, 3'd0,
                                     3'd3, 3'd2, 3'd1, 3'd0};
  localparam logic [3:0]  CLC  = CL_TAB[(CL - 9) * 4 +: 4];
  localparam logic [3:0]  WRC  = WR_TAB[(WR_MR - 10) / 2 * 4 +: 4];
  localparam logic [2:0]  CWLC = CWL_TAB[(CWL - 9) * 3 +: 3];
  // MR0: BL8, CL, DLL reset, WR / RTP
  localparam logic [13:0] MR0 = {WRC[3], 1'b0, WRC[2:0], 1'b1, 1'b0, CLC[3:1], 1'b0, CLC[0], 2'b00};
  localparam logic [13:0] MR1 = 14'h0001;                     // DLL enable, RZQ/7, no RTT_NOM, AL 0
  localparam logic [13:0] MR2 = {8'h00, CWLC, 3'b000};        // CWL, 1 tCK write preamble (MR4)
  localparam logic [13:0] MR5 = 14'h0400;                     // A10: data mask (DM_n) enable
  localparam logic [13:0] MR6 = {1'b0, 3'(T_CCD_L - 4), 10'h000};
  // MRS order MR3 MR6 MR5 MR4 MR2 MR1 MR0: value and MR number of step i
  localparam logic [97:0] MRS_V = {MR0, MR1, MR2, 14'h0000, MR5, MR6, 14'h0000};
  localparam logic [20:0] MRS_N = {3'd0, 3'd1, 3'd2, 3'd4, 3'd5, 3'd6, 3'd3};
  localparam int T_RTW = CL + 4 + 2 - CWL;                    // RD to WR (BL8, 1 tCK preambles)
  localparam int T_WRD = CWL + 4;                              // WR to end of write data

  // parameter checks (elaboration time)
  if (CL < 9 || CL > 24) begin : g_bad_cl
    $error("ddr4_jedec_ctrl: CL %0d is not a DDR4 CAS latency (9..24)", CL);
  end
  if (CWL < 9 || CWL > 20 || (CWL > 12 && CWL % 2 == 1)) begin : g_bad_cwl
    $error("ddr4_jedec_ctrl: CWL %0d is not a DDR4 CAS write latency", CWL);
  end
  if (T_CCD_L < 4 || T_CCD_L > 8) begin : g_bad_ccd
    $error("ddr4_jedec_ctrl: tCCD_L %0d is outside MR6 (4..8)", T_CCD_L);
  end
  // a WRITE always ends its bank's tRAS window: write recovery from the
  // earliest WRITE (tRCD after ACT) reaches past tRAS. True for every DDR4
  // speed bin; lets a WRITE load the bank's precharge timer unconditionally.
  if (T_WRD + T_WR < T_RAS - T_RCD) begin : g_bad_twr
    $error("ddr4_jedec_ctrl: CWL + 4 + tWR (%0d) < tRAS - tRCD (%0d)", T_WRD + T_WR, T_RAS - T_RCD);
  end

  // ---------------- timers ----------------
  // Every timing constraint is a down counter: a command loads T - 1 and the
  // counter falls by one per CK, so the constraint is met (counter 0) T CKs
  // after the command. Each counter is just wide enough for its largest load.
  localparam int M_ACT  = (T_RFC > T_RC ? T_RFC : T_RC) > T_RP ? (T_RFC > T_RC ? T_RFC : T_RC) : T_RP;
  localparam int M_PRE  = (T_RAS > T_WRD + T_WR ? T_RAS : T_WRD + T_WR) > T_RTP ?
                          (T_RAS > T_WRD + T_WR ? T_RAS : T_WRD + T_WR) : T_RTP;
  localparam int M_W1   = T_RESET > T_CKE - 1 ? T_RESET : T_CKE - 1;   // reset loads T_RESET itself
  localparam int M_W2   = T_XPR > T_ZQINIT ? T_XPR - 1 : T_ZQINIT - 1;
  localparam int M_W3   = T_MRD > T_MOD ? T_MRD - 1 : T_MOD - 1;
  localparam int M_WAIT = (M_W1 > M_W2 ? M_W1 : M_W2) > M_W3 ? (M_W1 > M_W2 ? M_W1 : M_W2) : M_W3;
  localparam int W_ACT  = $clog2(M_ACT > 1 ? M_ACT : 2);
  localparam int W_RCD  = $clog2(T_RCD > 1 ? T_RCD : 2);
  localparam int W_PRE  = $clog2(M_PRE > 1 ? M_PRE : 2);
  localparam int W_RRDL = $clog2(T_RRD_L > 1 ? T_RRD_L : 2);
  localparam int W_RRDS = $clog2(T_RRD_S > 1 ? T_RRD_S : 2);
  localparam int W_CCDL = $clog2(T_CCD_L > 1 ? T_CCD_L : 2);
  localparam int W_CCDS = $clog2(T_CCD_S > 1 ? T_CCD_S : 2);
  localparam int W_WTRL = $clog2(T_WRD + T_WTR_L);
  localparam int W_WTRS = $clog2(T_WRD + T_WTR_S);
  localparam int W_RTW  = $clog2(T_RTW > 1 ? T_RTW : 2);
  localparam int W_FAW  = $clog2(T_FAW > 1 ? T_FAW : 2);
  localparam int W_WAIT = $clog2(M_WAIT + 1);
  localparam int W_REFI = $clog2(T_REFI > 1 ? T_REFI : 2);

  // ---------------- request decode ----------------
  logic [CHB-1:0]  r_col;
  logic [BGB-1:0]  r_bg;
  logic [BAB-1:0]  r_ba;
  logic [ROWB-1:0] r_row;
  assign r_col = u_addr[0 +: CHB];
  assign r_bg  = u_addr[CHB +: BGB];
  assign r_ba  = u_addr[CHB + BGB +: BAB];
  assign r_row = u_addr[CHB + BGB + BAB +: ROWB];
  wire [BGB+BAB-1:0] r_bank = {r_bg, r_ba};

  // ---------------- bank state and timers ----------------
  logic [NB-1:0]     open_q;
  logic [ROWB-1:0]   row_q   [NB];
  logic [W_ACT-1:0]  act_c   [NB];      // tRP after PRE, tRC after ACT, tRFC after REF
  logic [W_RCD-1:0]  rw_c    [NB];      // tRCD
  logic [W_PRE-1:0]  pre_c   [NB];      // tRAS, tRTP, tWR
  logic [W_RRDL-1:0] actg_c  [NG];      // tRRD_L
  logic [W_CCDL-1:0] casg_c  [NG];      // tCCD_L
  logic [W_WTRL-1:0] rdg_c   [NG];      // tWTR_L
  logic [W_RRDS-1:0] acts_c;            // tRRD_S
  logic [W_CCDS-1:0] cass_c;            // tCCD_S
  logic [W_WTRS-1:0] rds_c;             // tWTR_S
  logic [W_RTW-1:0]  wrs_c;             // read to write
  logic [W_FAW-1:0]  faw_c [4];         // tFAW, one per ACT of the last four
  logic [1:0]        faw_p;
  logic              miss_q;            // the request in service needed PRE / ACT

  // ---------------- init / refresh sequencer ----------------
  typedef enum logic [3:0] {
    I_RESET, I_CKE, I_XPR, I_MRS, I_ZQ, I_ZQW, RUN, R_PREA, R_REF
  } st_e;
  st_e               st;
  logic [W_WAIT-1:0] wait_c;
  logic [2:0]        mrs_i;
  logic [W_REFI-1:0] ref_c;             // CKs to the next refresh
  wire               wait_ok = wait_c == '0;
  wire               ref_due = ref_c == '0;

  // ---------------- scheduling decision (combinational) ----------------
  logic hit, can_cas, can_pre, can_act, any_open, all_pre_ok, all_act_ok;
  always_comb begin
    hit     = open_q[r_bank] && row_q[r_bank] == r_row;
    can_cas = rw_c[r_bank] == '0 && casg_c[r_bg] == '0 && cass_c == '0 &&
              (u_write ? wrs_c == '0 : (rdg_c[r_bg] == '0 && rds_c == '0));
    can_pre = pre_c[r_bank] == '0;
    can_act = act_c[r_bank] == '0 && actg_c[r_bg] == '0 && acts_c == '0 && faw_c[faw_p] == '0;
    any_open   = |open_q;
    all_pre_ok = 1'b1;
    all_act_ok = 1'b1;
    for (int b = 0; b < NB; b++) begin
      if (open_q[b] && pre_c[b] != '0) all_pre_ok = 1'b0;
      if (act_c[b] != '0) all_act_ok = 1'b0;
    end
  end

  // a host request is served this cycle when it is a page hit and the CAS
  // timings allow it; misses first PRE / ACT (u_ready stays low)
  wire run_req = st == RUN && !ref_due && u_valid;
  wire do_cas  = run_req && hit && can_cas;
  wire do_pre  = run_req && !hit && open_q[r_bank] && can_pre;
  wire do_act  = run_req && !open_q[r_bank] && can_act;
  assign u_ready = do_cas;

  // ---------------- command pin helper ----------------
  task automatic cmd(input logic act, input logic ras, input logic cas, input logic we,
                     input logic [1:0] bg, input logic [1:0] ba, input logic [13:0] a);
    p_cs_n  <= 1'b0;
    p_act_n <= act;
    p_ras_n <= ras;
    p_cas_n <= cas;
    p_we_n  <= we;
    p_bg    <= bg;
    p_ba    <= ba;
    p_a     <= a;
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st        <= I_RESET;
      wait_c    <= W_WAIT'(T_RESET);
      mrs_i     <= '0;
      ref_c     <= '0;
      p_reset_n <= 1'b0;
      p_cke     <= 1'b0;
      p_odt     <= 1'b0;
      p_cs_n    <= 1'b1;
      p_act_n   <= 1'b1;
      p_ras_n   <= 1'b1;
      p_cas_n   <= 1'b1;
      p_we_n    <= 1'b1;
      p_bg      <= '0;
      p_ba      <= '0;
      p_a       <= '0;
      p_wr      <= 1'b0;
      p_wdata   <= '0;
      p_wbe     <= '0;
      init_done <= 1'b0;
      open_q    <= '0;
      acts_c    <= '0; cass_c <= '0; rds_c <= '0; wrs_c <= '0;
      faw_p     <= '0;
      miss_q    <= 1'b0;
      n_act     <= '0; n_hit <= '0; n_ref <= '0;
      for (int b = 0; b < NB; b++) begin
        row_q[b] <= '0; act_c[b] <= '0; rw_c[b] <= '0; pre_c[b] <= '0;
      end
      for (int g = 0; g < NG; g++) begin
        actg_c[g] <= '0; casg_c[g] <= '0; rdg_c[g] <= '0;
      end
      for (int i = 0; i < 4; i++) faw_c[i] <= '0;
    end else begin
      // timers count down to 0 and stay there
      if (!wait_ok) wait_c <= wait_c - 1'b1;
      if (!ref_due) ref_c  <= ref_c - 1'b1;
      if (acts_c != '0) acts_c <= acts_c - 1'b1;
      if (cass_c != '0) cass_c <= cass_c - 1'b1;
      if (rds_c  != '0) rds_c  <= rds_c  - 1'b1;
      if (wrs_c  != '0) wrs_c  <= wrs_c  - 1'b1;
      for (int b = 0; b < NB; b++) begin
        if (act_c[b] != '0) act_c[b] <= act_c[b] - 1'b1;
        if (rw_c[b]  != '0) rw_c[b]  <= rw_c[b]  - 1'b1;
        if (pre_c[b] != '0) pre_c[b] <= pre_c[b] - 1'b1;
      end
      for (int g = 0; g < NG; g++) begin
        if (actg_c[g] != '0) actg_c[g] <= actg_c[g] - 1'b1;
        if (casg_c[g] != '0) casg_c[g] <= casg_c[g] - 1'b1;
        if (rdg_c[g]  != '0) rdg_c[g]  <= rdg_c[g]  - 1'b1;
      end
      for (int i = 0; i < 4; i++)
        if (faw_c[i] != '0) faw_c[i] <= faw_c[i] - 1'b1;
      // default: deselect
      p_cs_n  <= 1'b1;
      p_act_n <= 1'b1;
      p_ras_n <= 1'b1;
      p_cas_n <= 1'b1;
      p_we_n  <= 1'b1;
      p_wr    <= 1'b0;
      case (st)
        I_RESET: if (wait_ok) begin
          p_reset_n <= 1'b1;
          wait_c    <= W_WAIT'(T_CKE - 1);
          st        <= I_CKE;
        end
        I_CKE: if (wait_ok) begin
          p_cke  <= 1'b1;
          wait_c <= W_WAIT'(T_XPR - 1);
          st     <= I_XPR;
        end
        I_XPR: if (wait_ok) st <= I_MRS;
        I_MRS: if (wait_ok) begin
          // MRS: RAS_n CAS_n WE_n = 0 0 0; BG0 BA1 BA0 = MR number
          cmd(1'b1, 1'b0, 1'b0, 1'b0, {1'b0, MRS_N[mrs_i * 3 + 2]}, MRS_N[mrs_i * 3 +: 2],
              MRS_V[mrs_i * 14 +: 14]);
          if (mrs_i == 3'd6) begin
            mrs_i  <= '0;
            wait_c <= W_WAIT'(T_MOD - 1);
            st     <= I_ZQ;
          end else begin
            mrs_i  <= mrs_i + 1'b1;
            wait_c <= W_WAIT'(T_MRD - 1);
          end
        end
        I_ZQ: if (wait_ok) begin
          // ZQCL: RAS_n CAS_n WE_n = 1 1 0, A10 = 1
          cmd(1'b1, 1'b1, 1'b1, 1'b0, 2'b00, 2'b00, 14'h0400);
          wait_c <= W_WAIT'(T_ZQINIT - 1);
          st     <= I_ZQW;
        end
        I_ZQW: if (wait_ok) begin
          init_done <= 1'b1;
          ref_c     <= W_REFI'(T_REFI - 1);
          st        <= RUN;
        end
        RUN: begin
          if (ref_due) begin
            // the next refresh is due tREFI after this one was
            ref_c <= W_REFI'(T_REFI - 1);
            if (any_open) st <= R_PREA;    // no ?: of enum literals: iverilog 13 wants a cast
            else          st <= R_REF;
          end else if (do_cas) begin
            // RD: 1 0 1, WR: 1 0 0 (with ACT_n high); A12 = BC_n = 1: BL8
            cmd(1'b1, 1'b1, 1'b0, !u_write, 2'(r_bg), 2'(r_ba), 14'h1000 | (14'(r_col) << 3));
            if (!miss_q) n_hit <= n_hit + 1'b1;
            miss_q <= 1'b0;
            casg_c[r_bg] <= W_CCDL'(T_CCD_L - 1);
            cass_c       <= W_CCDS'(T_CCD_S - 1);
            if (u_write) begin
              p_wr    <= 1'b1;
              p_wdata <= u_wdata;
              p_wbe   <= u_wbe;
              rdg_c[r_bg]    <= W_WTRL'(T_WRD + T_WTR_L - 1);
              rds_c          <= W_WTRS'(T_WRD + T_WTR_S - 1);
              pre_c[r_bank]  <= W_PRE'(T_WRD + T_WR - 1);   // >= what is left of tRAS (g_bad_twr)
            end else begin
              wrs_c <= W_RTW'(T_RTW - 1);
              if ({1'b0, pre_c[r_bank]} < (W_PRE + 1)'(T_RTP)) pre_c[r_bank] <= W_PRE'(T_RTP - 1);
            end
          end else if (do_pre) begin
            // PRE (single bank): 0 1 0, A10 = 0
            cmd(1'b1, 1'b0, 1'b1, 1'b0, 2'(r_bg), 2'(r_ba), 14'h0000);
            open_q[r_bank] <= 1'b0;
            miss_q         <= 1'b1;
            if ({1'b0, act_c[r_bank]} < (W_ACT + 1)'(T_RP)) act_c[r_bank] <= W_ACT'(T_RP - 1);
          end else if (do_act) begin
            // ACT carries row[16:14] on RAS_n / CAS_n / WE_n
            cmd(1'b0, 1'((17'(r_row)) >> 16), 1'((17'(r_row)) >> 15), 1'((17'(r_row)) >> 14),
                2'(r_bg), 2'(r_ba), 14'(r_row));
            n_act          <= n_act + 1'b1;
            miss_q         <= 1'b1;             // the CAS that follows is not a hit
            open_q[r_bank] <= 1'b1;
            row_q[r_bank]  <= r_row;
            rw_c[r_bank]   <= W_RCD'(T_RCD - 1);
            pre_c[r_bank]  <= W_PRE'(T_RAS - 1);
            act_c[r_bank]  <= W_ACT'(T_RC - 1);
            actg_c[r_bg]   <= W_RRDL'(T_RRD_L - 1);
            acts_c         <= W_RRDS'(T_RRD_S - 1);
            faw_c[faw_p]   <= W_FAW'(T_FAW - 1);
            faw_p          <= faw_p + 1'b1;
          end
        end
        R_PREA: if (all_pre_ok) begin
          cmd(1'b1, 1'b0, 1'b1, 1'b0, 2'b00, 2'b00, 14'h0400);   // PREA: A10 = 1
          open_q <= '0;
          for (int b = 0; b < NB; b++)
            if ({1'b0, act_c[b]} < (W_ACT + 1)'(T_RP)) act_c[b] <= W_ACT'(T_RP - 1);
          st <= R_REF;
        end
        R_REF: if (all_act_ok) begin
          cmd(1'b1, 1'b0, 1'b0, 1'b1, 2'b00, 2'b00, 14'h0000);   // REF: 0 0 1
          n_ref <= n_ref + 1'b1;
          for (int b = 0; b < NB; b++) act_c[b] <= W_ACT'(T_RFC - 1);
          st <= RUN;
        end
      endcase
    end
  end

  assign u_rvalid = p_rvalid;
  assign u_rdata  = p_rdata;
endmodule
