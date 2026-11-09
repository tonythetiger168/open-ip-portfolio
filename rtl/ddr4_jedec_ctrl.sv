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
//  - Address map (byte address A): A[OFF-1:0] byte in the burst,
//    then column[COLB-1:3], BG, BA, row. Bank groups next to the column bits
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
  parameter int AW       = 32,
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
  localparam int NG      = 1 << BGB
)(
  input  logic                 clk,       // = CK
  input  logic                 rst_n,
  // host port
  input  logic                 u_valid,
  output logic                 u_ready,
  input  logic                 u_write,
  input  logic [AW-1:0]        u_addr,
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
  localparam int OFF = $clog2(BB);
  localparam int CHB = COLB - 3;           // column bits above the burst

  // ---------------- mode register codes (JESD79-4 tables) ----------------
  function automatic logic [3:0] cl_code(input int c);
    case (c)
      9: cl_code = 4'd0;   10: cl_code = 4'd1;  11: cl_code = 4'd2;  12: cl_code = 4'd3;
      13: cl_code = 4'd4;  14: cl_code = 4'd5;  15: cl_code = 4'd6;  16: cl_code = 4'd7;
      18: cl_code = 4'd8;  20: cl_code = 4'd9;  22: cl_code = 4'd10; 24: cl_code = 4'd11;
      23: cl_code = 4'd12; 17: cl_code = 4'd13; 19: cl_code = 4'd14; 21: cl_code = 4'd15;
      default: cl_code = 4'd10;
    endcase
  endfunction
  function automatic logic [3:0] wr_code(input int w);
    case (w)
      10: wr_code = 4'd0; 12: wr_code = 4'd1; 14: wr_code = 4'd2; 16: wr_code = 4'd3;
      18: wr_code = 4'd4; 20: wr_code = 4'd5; 24: wr_code = 4'd6; 22: wr_code = 4'd7;
      26: wr_code = 4'd8;
      default: wr_code = 4'd6;
    endcase
  endfunction
  function automatic logic [2:0] cwl_code(input int c);
    case (c)
      9: cwl_code = 3'd0;  10: cwl_code = 3'd1; 11: cwl_code = 3'd2; 12: cwl_code = 3'd3;
      14: cwl_code = 3'd4; 16: cwl_code = 3'd5; 18: cwl_code = 3'd6; 20: cwl_code = 3'd7;
      default: cwl_code = 3'd5;
    endcase
  endfunction
  // tWR rounded up to a legal MR0 value
  function automatic int wr_mr(input int w);
    if (w <= 10) wr_mr = 10; else if (w <= 12) wr_mr = 12; else if (w <= 14) wr_mr = 14;
    else if (w <= 16) wr_mr = 16; else if (w <= 18) wr_mr = 18; else if (w <= 20) wr_mr = 20;
    else if (w <= 22) wr_mr = 22; else if (w <= 24) wr_mr = 24; else wr_mr = 26;
  endfunction
  localparam logic [3:0]  CLC  = cl_code(CL);
  localparam logic [3:0]  WRC  = wr_code(wr_mr(T_WR));
  localparam logic [2:0]  CWLC = cwl_code(CWL);
  // MR0: BL8, CL, DLL reset, WR / RTP
  localparam logic [13:0] MR0 = {WRC[3], 1'b0, WRC[2:0], 1'b1, 1'b0, CLC[3:1], 1'b0, CLC[0], 2'b00};
  localparam logic [13:0] MR1 = 14'h0001;                     // DLL enable, RZQ/7, no RTT_NOM, AL 0
  localparam logic [13:0] MR2 = {8'h00, CWLC, 3'b000};        // CWL, 1 tCK write preamble (MR4)
  localparam logic [13:0] MR5 = 14'h0400;                     // A10: data mask (DM_n) enable
  localparam logic [13:0] MR6 = {1'b0, 3'(T_CCD_L - 4), 10'h000};
  localparam int T_RTW = CL + 4 + 2 - CWL;                    // RD to WR (BL8, 1 tCK preambles)
  localparam int T_WRD = CWL + 4;                              // WR to end of write data

  // ---------------- time base ----------------
  logic [31:0] now;
  function automatic logic due(input logic [31:0] t, input logic [31:0] n);
    due = $signed(n - t) >= 0;
  endfunction

  // ---------------- request decode ----------------
  logic [CHB-1:0]  r_col;
  logic [BGB-1:0]  r_bg;
  logic [BAB-1:0]  r_ba;
  logic [ROWB-1:0] r_row;
  assign r_col = u_addr[OFF +: CHB];
  assign r_bg  = u_addr[OFF + CHB +: BGB];
  assign r_ba  = u_addr[OFF + CHB + BGB +: BAB];
  assign r_row = u_addr[OFF + CHB + BGB + BAB +: ROWB];
  wire [BGB+BAB-1:0] r_bank = {r_bg, r_ba};

  // ---------------- bank state and timers ----------------
  logic [NB-1:0]   open_q;
  logic [ROWB-1:0] row_q   [NB];
  logic [31:0]     act_ok  [NB];      // tRP after PRE, tRC after ACT, tRFC after REF
  logic [31:0]     rw_ok   [NB];      // tRCD
  logic [31:0]     pre_ok  [NB];      // tRAS, tRTP, tWR
  logic [31:0]     act_g   [NG];      // tRRD_L
  logic [31:0]     cas_g   [NG];      // tCCD_L
  logic [31:0]     rd_g    [NG];      // tWTR_L
  logic [31:0]     act_s, cas_s, rd_s, wr_s;
  logic [31:0]     faw [4];
  logic [1:0]      faw_p;
  logic            miss_q;            // the request in service needed PRE / ACT

  // ---------------- init / refresh sequencer ----------------
  typedef enum logic [3:0] {
    I_RESET, I_CKE, I_XPR, I_MRS, I_MOD, I_ZQ, I_ZQW, RUN, R_PREA, R_REF
  } st_e;
  st_e         st;
  logic [31:0] wait_t;
  logic [2:0]  mrs_i;
  logic [31:0] ref_t;                   // next refresh due
  logic        ref_due;
  assign ref_due = due(ref_t, now);

  // MRS order MR3 MR6 MR5 MR4 MR2 MR1 MR0
  logic [2:0]  mrs_n;
  logic [13:0] mrs_v;
  always_comb begin
    case (mrs_i)
      3'd0: begin mrs_n = 3'd3; mrs_v = 14'h0000; end
      3'd1: begin mrs_n = 3'd6; mrs_v = MR6;     end
      3'd2: begin mrs_n = 3'd5; mrs_v = MR5;     end
      3'd3: begin mrs_n = 3'd4; mrs_v = 14'h0000; end
      3'd4: begin mrs_n = 3'd2; mrs_v = MR2;     end
      3'd5: begin mrs_n = 3'd1; mrs_v = MR1;     end
      default: begin mrs_n = 3'd0; mrs_v = MR0;  end
    endcase
  end

  // ---------------- scheduling decision (combinational) ----------------
  logic hit, can_cas, can_pre, can_act, any_open, all_pre_ok, all_act_ok;
  always_comb begin
    hit     = open_q[r_bank] && row_q[r_bank] == r_row;
    can_cas = due(rw_ok[r_bank], now) && due(cas_g[r_bg], now) && due(cas_s, now) &&
              (u_write ? due(wr_s, now) : (due(rd_g[r_bg], now) && due(rd_s, now)));
    can_pre = due(pre_ok[r_bank], now);
    can_act = due(act_ok[r_bank], now) && due(act_g[r_bg], now) && due(act_s, now) &&
              due(faw[faw_p] + 32'(T_FAW), now);
    any_open   = |open_q;
    all_pre_ok = 1'b1;
    all_act_ok = 1'b1;
    for (int b = 0; b < NB; b++) begin
      if (open_q[b] && !due(pre_ok[b], now)) all_pre_ok = 1'b0;
      if (!due(act_ok[b], now)) all_act_ok = 1'b0;
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

  logic [1:0] bg2, ba2;
  always_comb begin
    bg2 = '0; ba2 = '0;
    bg2[BGB-1:0] = r_bg;
    ba2[BAB-1:0] = r_ba;
  end
  logic [ROWB-1:0] rowx;
  assign rowx = r_row;
  logic [13:0] col_a;
  always_comb begin
    col_a = '0;
    col_a[COLB-1:3] = r_col;
    col_a[12]       = 1'b1;              // BC_n = 1: BL8
  end
  // ACT carries row[16:14] on RAS_n / CAS_n / WE_n
  logic [16:0] row17;
  always_comb begin
    row17 = '0;
    row17[ROWB-1:0] = rowx;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      now       <= '0;
      st        <= I_RESET;
      wait_t    <= 32'(T_RESET);
      mrs_i     <= '0;
      ref_t     <= 32'hFFFF_FFFF;
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
      act_s     <= '0; cas_s <= '0; rd_s <= '0; wr_s <= '0;
      faw_p     <= '0;
      miss_q    <= 1'b0;
      n_act     <= '0; n_hit <= '0; n_ref <= '0;
      for (int b = 0; b < NB; b++) begin
        row_q[b] <= '0; act_ok[b] <= '0; rw_ok[b] <= '0; pre_ok[b] <= '0;
      end
      for (int g = 0; g < NG; g++) begin
        act_g[g] <= '0; cas_g[g] <= '0; rd_g[g] <= '0;
      end
      for (int i = 0; i < 4; i++) faw[i] <= '0;
    end else begin
      now     <= now + 1'b1;
      // default: deselect
      p_cs_n  <= 1'b1;
      p_act_n <= 1'b1;
      p_ras_n <= 1'b1;
      p_cas_n <= 1'b1;
      p_we_n  <= 1'b1;
      p_wr    <= 1'b0;
      case (st)
        I_RESET: if (due(wait_t, now)) begin
          p_reset_n <= 1'b1;
          wait_t    <= now + 32'(T_CKE);
          st        <= I_CKE;
        end
        I_CKE: if (due(wait_t, now)) begin
          p_cke  <= 1'b1;
          wait_t <= now + 32'(T_XPR);
          st     <= I_XPR;
        end
        I_XPR: if (due(wait_t, now)) st <= I_MRS;
        I_MRS: if (due(wait_t, now)) begin
          // MRS: RAS_n CAS_n WE_n = 0 0 0; BG0 BA1 BA0 = MR number
          cmd(1'b1, 1'b0, 1'b0, 1'b0, {1'b0, mrs_n[2]}, mrs_n[1:0], mrs_v);
          if (mrs_i == 3'd6) begin
            wait_t <= now + 32'(T_MOD);
            st     <= I_ZQ;
          end else begin
            mrs_i  <= mrs_i + 1'b1;
            wait_t <= now + 32'(T_MRD);
          end
        end
        I_ZQ: if (due(wait_t, now)) begin
          // ZQCL: RAS_n CAS_n WE_n = 1 1 0, A10 = 1
          cmd(1'b1, 1'b1, 1'b1, 1'b0, 2'b00, 2'b00, 14'h0400);
          wait_t <= now + 32'(T_ZQINIT);
          st     <= I_ZQW;
        end
        I_ZQW: if (due(wait_t, now)) begin
          init_done <= 1'b1;
          ref_t     <= now + 32'(T_REFI);
          st        <= RUN;
        end
        RUN: begin
          if (ref_due) begin
            st <= any_open ? R_PREA : R_REF;
          end else if (do_cas) begin
            // RD: 1 0 1, WR: 1 0 0 (with ACT_n high)
            cmd(1'b1, 1'b1, 1'b0, !u_write, bg2, ba2, col_a);
            if (!miss_q) n_hit <= n_hit + 1'b1;
            miss_q <= 1'b0;
            cas_g[r_bg] <= now + 32'(T_CCD_L);
            cas_s       <= now + 32'(T_CCD_S);
            if (u_write) begin
              p_wr    <= 1'b1;
              p_wdata <= u_wdata;
              p_wbe   <= u_wbe;
              rd_g[r_bg] <= now + 32'(T_WRD + T_WTR_L);
              rd_s       <= now + 32'(T_WRD + T_WTR_S);
              if (!due(now + 32'(T_WRD + T_WR), pre_ok[r_bank]))
                pre_ok[r_bank] <= now + 32'(T_WRD + T_WR);
            end else begin
              wr_s <= now + 32'(T_RTW);
              if (!due(now + 32'(T_RTP), pre_ok[r_bank]))
                pre_ok[r_bank] <= now + 32'(T_RTP);
            end
          end else if (do_pre) begin
            // PRE (single bank): 0 1 0, A10 = 0
            cmd(1'b1, 1'b0, 1'b1, 1'b0, bg2, ba2, 14'h0000);
            open_q[r_bank] <= 1'b0;
            miss_q         <= 1'b1;
            if (!due(now + 32'(T_RP), act_ok[r_bank])) act_ok[r_bank] <= now + 32'(T_RP);
          end else if (do_act) begin
            cmd(1'b0, row17[16], row17[15], row17[14], bg2, ba2, row17[13:0]);
            n_act          <= n_act + 1'b1;
            miss_q         <= 1'b1;             // the CAS that follows is not a hit
            open_q[r_bank] <= 1'b1;
            row_q[r_bank]  <= r_row;
            rw_ok[r_bank]  <= now + 32'(T_RCD);
            pre_ok[r_bank] <= now + 32'(T_RAS);
            act_ok[r_bank] <= now + 32'(T_RC);
            act_g[r_bg]    <= now + 32'(T_RRD_L);
            act_s          <= now + 32'(T_RRD_S);
            faw[faw_p]     <= now;
            faw_p          <= faw_p + 1'b1;
          end
        end
        R_PREA: if (all_pre_ok) begin
          cmd(1'b1, 1'b0, 1'b1, 1'b0, 2'b00, 2'b00, 14'h0400);   // PREA: A10 = 1
          open_q <= '0;
          for (int b = 0; b < NB; b++)
            if (!due(now + 32'(T_RP), act_ok[b])) act_ok[b] <= now + 32'(T_RP);
          st <= R_REF;
        end
        R_REF: if (all_act_ok) begin
          cmd(1'b1, 1'b0, 1'b0, 1'b1, 2'b00, 2'b00, 14'h0000);   // REF: 0 0 1
          n_ref <= n_ref + 1'b1;
          for (int b = 0; b < NB; b++) act_ok[b] <= now + 32'(T_RFC);
          ref_t <= ref_t + 32'(T_REFI);
          st    <= RUN;
        end
        default: st <= I_RESET;
      endcase
    end
  end

  assign u_rvalid = p_rvalid;
  assign u_rdata  = p_rdata;
endmodule
