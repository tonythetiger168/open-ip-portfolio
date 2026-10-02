// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// LPDDR5X_Lite_top -- educational LPDDR5X-flavoured controller.
// Fork of the DDR4_Lite micro-architecture with REAL LPDDR5X features:
//   * 8 banks (LPDDR5X geometry) with per-bank open-row tracking
//   * WCK (write clock) pins: toggle through the write path (CWL+BL8)
//   * per-bank refresh (PBREF): refresh one bank while the other 7 stay
//     open; the auto-refresh engine rotates one bank per tREFI interval
//   * DVFS: two frequency-set-point register files (FSP0/FSP1).  MRW writes
//     the current FSP; hcmd 7 (FSPW) switches the active set, changing CL/
//     CWL for subsequent transactions (mid-transaction switch is safe: the
//     latencies are latched per command)
//   * all-bank refresh (hcmd 5) kept alongside PBREF (hcmd 6, bank in
//     haddr[9:7]); shorter per-bank tRFC (T_RFC_PB)
//
// Documented abstractions: LPDDR's 2-cycle CA command bus is abstracted
// onto JEDEC-style pin names (act as a command-encoding subset); SDR dqs;
// DVFS modeled at the register/latency level only (no clock-frequency
// change); no WCK2CK sync training; array inside the model; single
// command engine.
//
// Front-end: hcmd 0 NOP | 1 RD | 2 WR | 3 MRW (haddr[2:0]=MR idx within
// current FSP, hwdata[7:0]=value) | 4 MRR | 5 REF (all-bank) | 6 PBREF
// (haddr[9:7]=bank) | 7 FSPW (hwdata[0]=FSP select).
// haddr: [9:7]=bank [18:10]=row [6:4]=line [3:0]=byte; [31:19] must be 0.
// ============================================================================
module LPDDR5X_Lite_top #(
  parameter integer T_RCD   = 6,
  parameter integer T_RP    = 6,
  parameter integer T_RC    = 24,
  parameter integer T_RAS   = 16,
  parameter integer T_RRD   = 3,
  parameter integer T_WR    = 8,
  parameter integer T_WTR   = 4,
  parameter integer T_RFC   = 40,   // all-bank refresh recovery
  parameter integer T_RFC_PB= 20,   // per-bank refresh recovery
  parameter integer T_REFI  = 3900, // per-bank average interval
  parameter integer CL      = 11,
  parameter integer CWL     = 8,
  parameter integer ROWS    = 512
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        irq,
  output logic        fsp,          // active frequency set point
  output logic        ck_t,
  output logic        ck_c,
  output logic        cke,
  output logic        wck_t,        // LPDDR write clock (write path)
  output logic        wck_c,
  output logic        cs_n,
  output logic        act_n,
  output logic        ras_n,
  output logic        cas_n,
  output logic        we_n,
  output logic [2:0]  ba,           // 8 banks
  output logic [13:0] addr,
  inout  tri [15:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        trace_valid,
  output logic [3:0]  trace_cmd,    // 0 ACT 1 RD 2 WR 3 PRE 4 REF 5 PBREF 6 REFA 7 FSPW
  output logic [31:0] trace_addr
);

  localparam integer BANKS = 8;
  localparam integer LINES = 8;

  // ---------------- FSP / mode registers ----------------
  logic [7:0] mr [0:1][0:7];        // mr[fsp][index]
  wire [4:0] cl_now  = 5'd5 + {1'b0, mr[fsp][0][3:0]};
  wire [4:0] cwl_now = 5'd5 + {1'b0, mr[fsp][1][3:0]};

  // ---------------- memory array ----------------
  logic [127:0] mem [0:BANKS*ROWS*LINES-1];

  // ---------------- per-bank state / timers ----------------
  logic [BANKS-1:0]        bank_open;
  logic [$clog2(ROWS)-1:0] bank_row [0:BANKS-1];
  logic [15:0] rp_cnt [0:BANKS-1], ras_cnt [0:BANKS-1],
               rc_cnt [0:BANKS-1], wr_cnt [0:BANKS-1];
  wire rp_done  [0:BANKS-1], ras_done [0:BANKS-1],
       rc_done  [0:BANKS-1], wr_done  [0:BANKS-1];
  genvar g;
  generate
    for (g = 0; g < BANKS; g = g + 1) begin : TZERO
      assign rp_done[g]  = (rp_cnt[g]  == 16'd0);
      assign ras_done[g] = (ras_cnt[g] == 16'd0);
      assign rc_done[g]  = (rc_cnt[g]  == 16'd0);
      assign wr_done[g]  = (wr_cnt[g]  == 16'd0);
    end
  endgenerate
  logic [15:0] rrd_cnt, wtr_cnt, rfc_cnt, refi_cnt;
  wire rrd_done = (rrd_cnt == 16'd0);
  wire wtr_done = (wtr_cnt == 16'd0);
  wire rfc_done = (rfc_cnt == 16'd0);

  // ---------------- refresh rotation ----------------
  logic [2:0] ref_rot;              // next bank for per-bank refresh
  logic [BANKS-1:0] pbref_pend;     // per-bank pending flags
  logic refa_pend;                  // all-bank pending
  logic ref_overrun;

  // ---------------- front-end <-> engine ----------------
  logic        req_valid, req_we, req_refall, req_pbref;
  logic [2:0]  req_pb_bank;
  logic        req_done;
  logic [31:0] req_addr;
  logic [3:0]  req_bank, req_line;
  logic [31:0] req_row;

  typedef enum logic [2:0] {FE_IDLE, FE_FILL, FE_WAIT, FE_DRAIN} fe_t;
  fe_t fe;
  logic [3:0]  fe_cnt;
  logic [15:0] wbuf [0:7];
  logic [15:0] rbuf [0:7];
  logic        rbuf_valid;
  logic [31:0] fe_addr;

  typedef enum logic [3:0] {
    ENG_IDLE, ENG_BANK_CHK, ENG_PRE, ENG_PRE_WAIT, ENG_ACT, ENG_TRCD,
    ENG_CL, ENG_RD_BURST, ENG_CWL, ENG_WR_BURST,
    ENG_RFB_CHK, ENG_RFB_PRE, ENG_RFB_PRE_WAIT, ENG_RFB_CMD, ENG_RFB_WAIT,
    ENG_RFA_CMD, ENG_RFA_WAIT
  } eng_t;
  eng_t eng;
  logic [3:0]  eng_bank, eng_line;
  logic [31:0] eng_row;
  logic        eng_we;
  logic [4:0]  lat_cnt, bcnt;
  logic [127:0] burst_reg;

  wire [31:0] mem_idx = ((eng_bank * ROWS) + eng_row[31:0]) * LINES + eng_line;
  wire hit = bank_open[eng_bank] &&
             (bank_row[eng_bank] == eng_row[$clog2(ROWS)-1:0]);

  logic        dq_oe, dqs_oe, wck_en;
  logic [15:0] dq_out;
  logic        dqs_t;
  assign dq  = dq_oe  ? dq_out      : 16'hzzzz;
  assign dqs = dqs_oe ? {~dqs_t, dqs_t} : 2'bzz;

  // ========================================================================
  // Timers (single owner; engine raises one-cycle load strobes)
  // ========================================================================
  logic [BANKS-1:0] ld_rp_v, ld_ras_v, ld_rc_v, ld_wr_v;
  logic [15:0] ld_rp, ld_ras, ld_rc, ld_wr;
  logic        ld_rrd_v, ld_wtr_v, ld_rfc_v;
  logic [15:0] ld_rfc;
  logic [2:0]  ld_rot;
  logic        ld_rot_v, pbref_ack;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < BANKS; i++) begin
        rp_cnt[i] <= 16'd0; ras_cnt[i] <= 16'd0;
        rc_cnt[i] <= 16'd0; wr_cnt[i] <= 16'd0;
        pbref_pend[i] <= 1'b0;
      end
      rrd_cnt <= 16'd0; wtr_cnt <= 16'd0; rfc_cnt <= 16'd0;
      refi_cnt <= T_REFI[15:0];
      ref_rot <= 3'd0; refa_pend <= 1'b0; ref_overrun <= 1'b0;
    end else begin
      for (int i = 0; i < BANKS; i++) begin
        if (ld_rp_v[i])        rp_cnt[i]  <= ld_rp;
        else if (rp_cnt[i]!=0) rp_cnt[i]  <= rp_cnt[i] - 1;
        if (ld_ras_v[i])       ras_cnt[i] <= ld_ras;
        else if (ras_cnt[i]!=0) ras_cnt[i] <= ras_cnt[i] - 1;
        if (ld_rc_v[i])        rc_cnt[i]  <= ld_rc;
        else if (rc_cnt[i]!=0) rc_cnt[i]  <= rc_cnt[i] - 1;
        if (ld_wr_v[i])        wr_cnt[i]  <= ld_wr;
        else if (wr_cnt[i]!=0) wr_cnt[i]  <= wr_cnt[i] - 1;
      end
      if (ld_rrd_v)      rrd_cnt <= T_RRD[15:0];
      else if (rrd_cnt != 0) rrd_cnt <= rrd_cnt - 1;
      if (ld_wtr_v)      wtr_cnt <= T_WTR[15:0];
      else if (wtr_cnt != 0) wtr_cnt <= wtr_cnt - 1;
      if (ld_rfc_v)      rfc_cnt <= ld_rfc;
      else if (rfc_cnt != 0) rfc_cnt <= rfc_cnt - 1;
      // per-bank refresh interval: rotate target bank each expiry
      if (refi_cnt != 0) refi_cnt <= refi_cnt - 1;
      else begin
        refi_cnt <= T_REFI[15:0];
        if (pbref_pend[ref_rot]) ref_overrun <= 1'b1;
        pbref_pend[ref_rot] <= 1'b1;
        if (ld_rot_v) ref_rot <= ld_rot;
        else          ref_rot <= ref_rot + 1;
      end
      if (pbref_ack) pbref_pend[eng_bank[2:0]] <= 1'b0;
    end
  end

  // ========================================================================
  // Front-end
  // ========================================================================
  assign hready = (fe == FE_IDLE) || (fe == FE_FILL) || (fe == FE_DRAIN);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fe <= FE_IDLE; fe_cnt <= 4'd0;
      req_valid <= 1'b0; req_we <= 1'b0;
      req_refall <= 1'b0; req_pbref <= 1'b0; req_pb_bank <= 3'd0;
      req_addr <= 32'h0; fe_addr <= 32'h0;
      hrdata <= 16'h0; hdone <= 1'b0;
      for (int i = 0; i < 8; i++) wbuf[i] <= 16'h0;
      fsp <= 1'b0; fe_err_pulse <= 1'b0;
      for (int s = 0; s < 2; s++)
        for (int i = 0; i < 8; i++) mr[s][i] <= 8'h00;
      mr[0][0] <= CL - 5; mr[0][1] <= CWL - 5;
    end else begin
      hdone <= 1'b0; fe_err_pulse <= 1'b0;
      case (fe)
        FE_IDLE: begin
          if (hvalid) begin
            case (hcmd)
              3'd1: begin
                if (haddr[31:19] != 13'h0) begin
                  fe_err_pulse <= 1'b1; hdone <= 1'b1;
                end else begin
                  fe_addr <= haddr; req_addr <= haddr;
                  req_we <= 1'b0; req_refall <= 1'b0; req_pbref <= 1'b0;
                  req_valid <= 1'b1; fe <= FE_WAIT;
                end
              end
              3'd2: begin
                if (haddr[31:19] != 13'h0) begin
                  fe_err_pulse <= 1'b1; hdone <= 1'b1;
                end else begin
                  fe_addr <= haddr; fe_cnt <= 4'd0; fe <= FE_FILL;
                end
              end
              3'd3: begin mr[fsp][haddr[2:0]] <= hwdata[7:0]; hdone <= 1'b1; end
              3'd4: begin hrdata <= {8'h00, mr[fsp][haddr[2:0]]}; hdone <= 1'b1; end
              3'd5: begin                          // all-bank refresh
                req_we <= 1'b0; req_refall <= 1'b1; req_pbref <= 1'b0;
                req_valid <= 1'b1; fe <= FE_WAIT;
              end
              3'd6: begin                          // per-bank refresh
                req_we <= 1'b0; req_refall <= 1'b0; req_pbref <= 1'b1;
                req_pb_bank <= haddr[9:7]; req_valid <= 1'b1; fe <= FE_WAIT;
              end
              3'd7: begin                          // FSP switch (DVFS)
                fsp <= hwdata[0]; hdone <= 1'b1;
              end
              default: begin
                if (hcmd != 3'd0) fe_err_pulse <= 1'b1;
                hdone <= 1'b1;
              end
            endcase
          end
        end
        FE_FILL: begin
          wbuf[fe_cnt[2:0]] <= hwdata;
          if (fe_cnt == 4'd7) begin
            req_addr <= fe_addr; req_we <= 1'b1;
            req_refall <= 1'b0; req_pbref <= 1'b0; req_valid <= 1'b1;
            fe <= FE_WAIT;
          end else fe_cnt <= fe_cnt + 1;
        end
        FE_WAIT: begin
          if (req_done) begin
            req_valid <= 1'b0; req_refall <= 1'b0; req_pbref <= 1'b0;
            if (!req_we && rbuf_valid) begin fe_cnt <= 4'd0; fe <= FE_DRAIN; end
            else begin hdone <= 1'b1; fe <= FE_IDLE; end
          end
        end
        FE_DRAIN: begin
          hrdata <= rbuf[fe_cnt[2:0]];
          if (fe_cnt == 4'd7) begin hdone <= 1'b1; fe <= FE_IDLE; end
          else fe_cnt <= fe_cnt + 1;
        end
        default: fe <= FE_IDLE;
      endcase
    end
  end

  // ========================================================================
  // Command engine
  // ========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      eng <= ENG_IDLE;
      eng_bank <= 4'd0; eng_line <= 4'd0; eng_row <= 32'h0; eng_we <= 1'b0;
      lat_cnt <= 5'd0; bcnt <= 5'd0; burst_reg <= 128'h0;
      req_done <= 1'b0;
      ld_rp_v <= '0; ld_ras_v <= '0; ld_rc_v <= '0; ld_wr_v <= '0;
      ld_rp <= 16'h0; ld_ras <= 16'h0; ld_rc <= 16'h0; ld_wr <= 16'h0;
      ld_rrd_v <= 1'b0; ld_wtr_v <= 1'b0; ld_rfc_v <= 1'b0; ld_rfc <= 16'h0;
      ld_rot_v <= 1'b0; pbref_ack <= 1'b0; eng_err_pulse <= 1'b0;
      dq_oe <= 1'b0; dqs_oe <= 1'b0; wck_en <= 1'b0;
      dq_out <= 16'h0; dqs_t <= 1'b0;
      for (int i = 0; i < BANKS; i++) begin
        bank_open[i] <= 1'b0; bank_row[i] <= '0;
      end
      for (int i = 0; i < 8; i++) rbuf[i] <= 16'h0;
      rbuf_valid <= 1'b0;
    end else begin
      ld_rp_v <= '0; ld_ras_v <= '0; ld_rc_v <= '0; ld_wr_v <= '0;
      ld_rrd_v <= 1'b0; ld_wtr_v <= 1'b0; ld_rfc_v <= 1'b0;
      ld_rot_v <= 1'b0; pbref_ack <= 1'b0; req_done <= 1'b0;
      case (eng)
        ENG_IDLE: begin
          dq_oe <= 1'b0; dqs_oe <= 1'b0; wck_en <= 1'b0;
          if (req_valid && req_refall) eng <= ENG_RFA_CMD;
          else if (req_valid && req_pbref) begin
            eng_bank <= {1'b0, req_pb_bank}; eng <= ENG_RFB_CHK;
          end
          else if (pbref_pend != 8'h00) begin
            // service the lowest pending per-bank refresh
            for (int i = 0; i < BANKS; i++)
              if (pbref_pend[i] && eng == ENG_IDLE) eng_bank <= i[3:0];
            eng <= ENG_RFB_CHK;
          end
          else if (req_valid) begin
            if (req_addr[31:19] != 13'h0) begin
              eng_err_pulse <= 1'b1; req_done <= 1'b1;
            end else begin
              if (!req_we) rbuf_valid <= 1'b0;
              eng_bank <= {1'b0, req_addr[9:7]};
              eng_row  <= {22'h0, req_addr[18:10]};
              eng_line <= {1'b0, req_addr[6:4]};
              eng_we   <= req_we;
              eng <= ENG_BANK_CHK;
            end
          end
        end
        ENG_BANK_CHK: begin
          if (hit) begin
            if (wr_done[eng_bank] && (eng_we || wtr_done)) begin
              lat_cnt <= 5'd1; eng <= ENG_TRCD;
            end
          end else if (bank_open[eng_bank]) begin
            if (ras_done[eng_bank] && wr_done[eng_bank]) eng <= ENG_PRE;
          end else begin
            if (rp_done[eng_bank] && rc_done[eng_bank] && rrd_done)
              eng <= ENG_ACT;
          end
        end
        ENG_PRE: begin
          bank_open[eng_bank] <= 1'b0;
          ld_rp_v[eng_bank] <= 1'b1; ld_rp <= T_RP[15:0];
          eng <= ENG_PRE_WAIT;
        end
        ENG_PRE_WAIT: if (rp_done[eng_bank]) eng <= ENG_ACT;
        ENG_ACT: begin
          bank_open[eng_bank] <= 1'b1;
          bank_row[eng_bank] <= eng_row[$clog2(ROWS)-1:0];
          ld_ras_v[eng_bank] <= 1'b1; ld_ras <= T_RAS[15:0];
          ld_rc_v[eng_bank]  <= 1'b1; ld_rc  <= T_RC[15:0];
          ld_rrd_v <= 1'b1;
          lat_cnt <= T_RCD[4:0];
          eng <= ENG_TRCD;
        end
        ENG_TRCD: begin
          if (lat_cnt > 5'd1) lat_cnt <= lat_cnt - 1;
          else begin
            if (eng_we) begin lat_cnt <= cwl_now; eng <= ENG_CWL; end
            else          begin lat_cnt <= cl_now;  eng <= ENG_CL;  end
          end
        end
        ENG_CL: begin
          if (lat_cnt > 5'd1) lat_cnt <= lat_cnt - 1;
          else begin burst_reg <= mem[mem_idx]; bcnt <= 5'd0; eng <= ENG_RD_BURST; end
        end
        ENG_RD_BURST: begin
          dq_oe <= 1'b1; dqs_oe <= 1'b1; dqs_t <= ~dqs_t;
          dq_out <= burst_reg[16*bcnt +: 16];
          if (bcnt == 5'd7) begin
            for (int i = 0; i < 8; i++) rbuf[i] <= burst_reg[16*i +: 16];
            rbuf_valid <= 1'b1;
            dq_oe <= 1'b0; dqs_oe <= 1'b0;
            ld_wtr_v <= 1'b1; req_done <= 1'b1; eng <= ENG_IDLE;
          end else bcnt <= bcnt + 1;
        end
        ENG_CWL: begin
          wck_en <= 1'b1;                     // WCK runs through the write path
          if (lat_cnt > 5'd1) lat_cnt <= lat_cnt - 1;
          else begin bcnt <= 5'd0; eng <= ENG_WR_BURST; end
        end
        ENG_WR_BURST: begin
          wck_en <= 1'b1;
          dq_oe <= 1'b1; dqs_oe <= 1'b1; dqs_t <= ~dqs_t;
          dq_out <= wbuf[bcnt[2:0]];
          if (bcnt == 5'd7) begin
            mem[mem_idx] <= {wbuf[7], wbuf[6], wbuf[5], wbuf[4],
                             wbuf[3], wbuf[2], wbuf[1], wbuf[0]};
            dq_oe <= 1'b0; dqs_oe <= 1'b0; wck_en <= 1'b0;
            ld_wr_v[eng_bank] <= 1'b1; ld_wr <= T_WR[15:0];
            req_done <= 1'b1; eng <= ENG_IDLE;
          end else bcnt <= bcnt + 1;
        end
        // ---- per-bank refresh ----
        ENG_RFB_CHK: begin
          if (wr_done[eng_bank] && ras_done[eng_bank]) begin
            if (bank_open[eng_bank]) eng <= ENG_RFB_PRE;
            else                     eng <= ENG_RFB_CMD;
          end
        end
        ENG_RFB_PRE: begin
          bank_open[eng_bank] <= 1'b0;
          ld_rp_v[eng_bank] <= 1'b1; ld_rp <= T_RP[15:0];
          eng <= ENG_RFB_PRE_WAIT;
        end
        ENG_RFB_PRE_WAIT: if (rp_done[eng_bank]) eng <= ENG_RFB_CMD;
        ENG_RFB_CMD: begin
          ld_rfc_v <= 1'b1; ld_rfc <= T_RFC_PB[15:0];
          eng <= ENG_RFB_WAIT;
        end
        ENG_RFB_WAIT: begin
          if (rfc_done) begin
            pbref_ack <= 1'b1;                 // clears pbref_pend[eng_bank]
            req_done <= 1'b1; eng <= ENG_IDLE;
          end
        end
        // ---- all-bank refresh ----
        ENG_RFA_CMD: begin
          for (int i = 0; i < BANKS; i++) begin
            bank_open[i] <= 1'b0;
            ld_rp_v[i] <= 1'b1; ld_rp <= T_RP[15:0];
          end
          ld_rfc_v <= 1'b1; ld_rfc <= T_RFC[15:0];
          eng <= ENG_RFA_WAIT;
        end
        ENG_RFA_WAIT: begin
          if (rfc_done && rp_done[0] && rp_done[1] && rp_done[2] &&
              rp_done[3] && rp_done[4] && rp_done[5] && rp_done[6] &&
              rp_done[7]) begin
            req_done <= 1'b1; eng <= ENG_IDLE;
          end
        end
        default: eng <= ENG_IDLE;
      endcase
    end
  end

  // ========================================================================
  // Pins / trace / WCK
  // ========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ck_t <= 1'b0; cke <= 1'b1; wck_t <= 1'b1;
      cs_n <= 1'b1; act_n <= 1'b1; ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
      ba <= 3'b000; addr <= 14'h0;
    end else begin
      ck_t <= 1'b1; cke <= 1'b1;
      cs_n <= 1'b1; act_n <= 1'b1; ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
      case (eng)
        ENG_PRE, ENG_RFB_PRE: begin
          cs_n <= 1'b0; ras_n <= 1'b0; we_n <= 1'b0;
          ba <= eng_bank[2:0]; addr <= 14'h0000;
        end
        ENG_ACT: begin
          cs_n <= 1'b0; act_n <= 1'b0;
          ba <= eng_bank[2:0]; addr <= eng_row[13:0];
        end
        ENG_TRCD: if (lat_cnt == 5'd1) begin
          cs_n <= 1'b0; cas_n <= 1'b0; we_n <= ~eng_we;
          ba <= eng_bank[2:0]; addr <= {7'h0, eng_line, 4'h0};
        end
        ENG_RFB_CMD: begin                       // PBREF: REF with bank select
          cs_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b0;
          ba <= eng_bank[2:0]; addr <= 14'h0000;
        end
        ENG_RFA_CMD: begin                       // all-bank REF
          cs_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b0;
          ba <= 3'b000; addr <= 14'h0400;        // A10=1
        end
        default: ;
      endcase
      // WCK toggles only while the write path is active
      if (wck_en) wck_t <= ~wck_t;
      else        wck_t <= 1'b1;
    end
  end
  assign ck_c  = ~ck_t;
  assign wck_c = ~wck_t;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      trace_valid <= 1'b0; trace_cmd <= 4'd0; trace_addr <= 32'h0;
    end else begin
      trace_valid <= 1'b0;
      case (eng)
        ENG_ACT:   begin trace_valid <= 1'b1; trace_cmd <= 4'd0; trace_addr <= {eng_row[19:0], 12'h0}; end
        ENG_PRE:   begin trace_valid <= 1'b1; trace_cmd <= 4'd3; trace_addr <= {eng_row[19:0], 12'h0}; end
        ENG_RFB_CMD: begin trace_valid <= 1'b1; trace_cmd <= 4'd5; trace_addr <= {29'h0, eng_bank[2:0]}; end
        ENG_RFA_CMD: begin trace_valid <= 1'b1; trace_cmd <= 4'd6; trace_addr <= 32'h0; end
        ENG_TRCD: if (lat_cnt == 5'd1) begin
          trace_valid <= 1'b1; trace_cmd <= eng_we ? 4'd2 : 4'd1;
          trace_addr <= {eng_row[19:0], 12'h0};
        end
        default: ;
      endcase
    end
  end

  // ========================================================================
  // Error aggregation (single driver)
  // ========================================================================
  logic fe_err_pulse, eng_err_pulse;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      irq <= 1'b0;
    end else begin
      if (fe_err_pulse || eng_err_pulse || ref_overrun) irq <= 1'b1;
    end
  end

endmodule
