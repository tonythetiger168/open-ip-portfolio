// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DDR4_Lite_top -- educational DDR4-style controller with a real
// micro-architecture (this is what the MEMCH family shells point at).
//
// What makes this a *real* DDR controller model (vs the 144-line single-bank
// MEMCORE educational slice):
//   * 4 independent banks with per-bank open-row tracking (open-page policy)
//   * full JEDEC-style command set on the PHY pins: ACT / RD / WR / PRE
//     (single & all-bank) / REF / MRS, DDR4 ACT_n encoding
//   * timing-fenced scheduling: tRCD, tRP, tRC, tRAS, tRRD, tWR, tWTR,
//     tRFC, average-refresh interval tREFI (all in clk cycles)
//   * BL8 x16 data path: front-end collects 8 AHB beats into a 128-bit
//     line, one DRAM burst per transaction, dq/dqs pin-level bursts
//   * refresh controller: tREFI countdown -> pending refresh, all-bank
//     PRE + REF + tRFC, refresh-overrun sticky error
//   * mode-register file MR0..MR7 (8-bit, JEDEC-style addressing; MR0 CL
//     field and MR1 CWL field are functional; MRW/MRR front-end commands)
//   * protocol-error sticky irq (bad command, out-of-range address, MR
//     index > 7, refresh overrun)
//
// Documented simplifications (an educational slice, not a production IP):
//   * SDR-style dqs (one rising edge per beat; no true DDR strobes)
//   * no DLL / read & write leveling / ZQ / DBI / ECC / bank groups / 2T
//     command / gear-down / CA parity
//   * refresh is served only when the command engine is idle
//   * memory array lives inside the model (controller + DRAM array combined)
//   * one command engine: a single transaction is in flight at a time
//
// Front-end (AHB-like, framework style):
//   hcmd: 0 = NOP | 1 = READ line | 2 = WRITE line | 3 = MRW (haddr[2:0]=MR
//   index, hwdata[7:0]=value) | 4 = MRR (hrdata[7:0]=value) | 5 = REFRESH
//   haddr byte address: [8:7]=bank  [18:9]=row  [6:4]=line  [3:0]=byte-in-line
//   (line = one BL8 x16 burst = 8 front-end beats).  haddr[31:19] must be 0.
//   Read data returns 8 beats on hrdata; hdone pulses on the last beat.
// ============================================================================
module DDR4_Lite_top #(
  parameter integer T_RCD  = 6,     // ACT  -> RD/WR
  parameter integer T_RP   = 6,     // PRE  -> ACT
  parameter integer T_RC   = 24,    // ACT  -> ACT (same bank)
  parameter integer T_RAS  = 16,    // ACT  -> PRE
  parameter integer T_RRD  = 3,     // ACT  -> ACT (different bank)
  parameter integer T_WR   = 8,     // end of WR burst -> PRE
  parameter integer T_WTR  = 4,     // end of RD burst -> WR issue
  parameter integer T_RFC  = 40,    // REF  -> next valid command
  parameter integer T_REFI = 3900,  // average refresh interval
  parameter integer CL     = 11,    // read latency   (MR0[3:0] overrides)
  parameter integer CWL    = 8,     // write latency  (MR1[3:0] overrides)
  parameter integer ROWS   = 512,   // rows per bank
  parameter integer TRAS_WARN = 1
)(
  input  logic        clk,
  input  logic        rst_n,
  // ---- front-end ----
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        irq,
  // ---- DRAM-facing pins (JEDEC-style subset) ----
  output logic        ck_t,
  output logic        ck_c,
  output logic        cke,
  output logic        cs_n,
  output logic        act_n,
  output logic        ras_n,
  output logic        cas_n,
  output logic        we_n,
  output logic [1:0]  ba,
  output logic [13:0] addr,
  inout  tri [15:0]   dq,
  inout  tri [1:0]    dqs,
  // ---- trace ----
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);

  localparam integer BANKS = 4;
  localparam integer LINES = 8;              // BL8 bursts per row segment
  localparam integer CW    = 16;             // dq width

  // ---------------- derived latencies (from MR0/MR1) ----------------
  // CL cycles = 5 + MR0[3:0] (JEDEC DDR4 CL step is coarser; educational
  // linear map keeps the register meaningful).  CWL = 5 + MR1[3:0].
  logic [7:0] mr [0:7];
  wire [4:0] cl_now  = 5'd5 + {1'b0, mr[0][3:0]};
  wire [4:0] cwl_now = 5'd5 + {1'b0, mr[1][3:0]};

  // ---------------- memory array (controller + DRAM model) ----------------
  // 4 banks x ROWS rows x LINES lines x 128 bits
  logic [127:0] mem [0:BANKS*ROWS*LINES-1];
  wire [31:0] mem_index = {bank_r, row_r, line_r} >> 0; // composed below
  // (index composed combinationally in ENG; placeholder wire not used)

  // ---------------- per-bank state ----------------
  logic [BANKS-1:0]       bank_open;
  logic [$clog2(ROWS)-1:0] bank_row [0:BANKS-1];

  // ---------------- timers ----------------
  logic [15:0] rp_cnt  [0:BANKS-1];
  logic [15:0] ras_cnt [0:BANKS-1];
  logic [15:0] rc_cnt  [0:BANKS-1];
  logic [15:0] wr_cnt  [0:BANKS-1];
  logic [15:0] rrd_cnt, wtr_cnt, rfc_cnt, refi_cnt;
  wire rp_done  [0:BANKS-1];
  wire ras_done [0:BANKS-1];
  wire rc_done  [0:BANKS-1];
  wire wr_done  [0:BANKS-1];
  genvar g;
  generate
    for (g = 0; g < BANKS; g = g + 1) begin : TZERO
      assign rp_done[g]  = (rp_cnt[g]  == 16'd0);
      assign ras_done[g] = (ras_cnt[g] == 16'd0);
      assign rc_done[g]  = (rc_cnt[g]  == 16'd0);
      assign wr_done[g]  = (wr_cnt[g]  == 16'd0);
    end
  endgenerate
  wire rrd_done = (rrd_cnt == 16'd0);
  wire wtr_done = (wtr_cnt == 16'd0);
  wire rfc_done = (rfc_cnt == 16'd0);

  // ---------------- refresh ----------------
  logic ref_pending;
  logic ref_overrun;

  // ---------------- front-end <-> engine handshake ----------------
  logic        req_valid, req_we, req_ref;
  logic        req_done;
  logic [31:0] req_addr;
  logic [3:0]  req_bank, req_line;      // bank & line of current request
  logic [31:0] req_row;                 // full row (checked < ROWS)

  // ---------------- front-end ----------------
  typedef enum logic [2:0] {FE_IDLE, FE_FILL, FE_WAIT_RD, FE_DRAIN, FE_WAIT_WR} fe_t;
  fe_t fe;
  logic [3:0]  fe_cnt;
  logic [15:0] wbuf [0:7];
  logic [15:0] rbuf [0:7];
  logic        rbuf_valid;
  logic [31:0] fe_addr;

  // ---------------- engine ----------------
  typedef enum logic [3:0] {
    ENG_IDLE, ENG_BANK_CHK, ENG_PRE, ENG_PRE_WAIT, ENG_ACT, ENG_TRCD,
    ENG_CL, ENG_RD_BURST, ENG_CWL, ENG_WR_BURST, ENG_WR_GAP,
    ENG_REF_PRE, ENG_REF_CMD, ENG_REF_WAIT, ENG_DONE
  } eng_t;
  eng_t eng;
  logic [3:0]  eng_bank, eng_line;
  logic [31:0] eng_row;
  logic        eng_we;
  logic [4:0]  lat_cnt, bcnt;
  logic [127:0] burst_reg;

  wire eng_addr_ok = (fe_addr[31:18] == 14'h0);

  // ---------------- dq / dqs ----------------
  logic        dq_oe, dqs_oe;
  logic [15:0] dq_out;
  logic        dqs_t;
  assign dq      = dq_oe  ? dq_out      : 16'hzzzz;
  assign dqs     = dqs_oe ? {~dqs_t, dqs_t} : 2'bzz;

  // ---------------- pins ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ck_t <= 1'b0; cke <= 1'b1;
      cs_n <= 1'b1; act_n <= 1'b1; ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
      ba <= 2'b00; addr <= 14'h0;
    end else begin
      ck_t <= 1'b1;                       // model clock (external pin)
      cke  <= 1'b1;
      // default: bus deselect every cycle; states override for 1 cycle
      cs_n <= 1'b1; act_n <= 1'b1; ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
      case (eng)
        ENG_PRE: begin                    // PRE (single bank; addr[10]=0)
          cs_n <= 1'b0; act_n <= 1'b1; ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0;
          ba <= eng_bank; addr <= 14'h0000;
        end
        ENG_ACT: begin                    // ACT (row on addr)
          cs_n <= 1'b0; act_n <= 1'b0; ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
          ba <= eng_bank; addr <= eng_row[13:0];
        end
        ENG_TRCD: if (lat_cnt == 5'd1) begin  // RD / WR command
          cs_n <= 1'b0; act_n <= 1'b1; ras_n <= 1'b1; cas_n <= 1'b0;
          we_n <= ~eng_we;
          ba <= eng_bank; addr <= {7'h0, eng_line, 4'h0};
        end
        ENG_REF_PRE: begin                // PREA (all banks)
          cs_n <= 1'b0; act_n <= 1'b1; ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0;
          ba <= 2'b00; addr <= 14'h0400;  // A10=1 -> precharge all
        end
        ENG_REF_CMD: begin                // REF
          cs_n <= 1'b0; act_n <= 1'b1; ras_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b1;
          ba <= 2'b00; addr <= 14'h0000;
        end
        default: ;
      endcase
    end
  end
  assign ck_c = ~ck_t;

  // ---------------- trace ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      trace_valid <= 1'b0; trace_cmd <= 3'd0; trace_addr <= 32'h0;
    end else begin
      trace_valid <= 1'b0;
      case (eng)
        ENG_ACT:     begin trace_valid <= 1'b1; trace_cmd <= 3'd0; trace_addr <= {eng_row[19:0], 12'h0}; end
        ENG_PRE:     begin trace_valid <= 1'b1; trace_cmd <= 3'd3; trace_addr <= {eng_row[19:0], 12'h0}; end
        ENG_REF_CMD: begin trace_valid <= 1'b1; trace_cmd <= 3'd4; trace_addr <= 32'h0; end
        ENG_TRCD: if (lat_cnt == 5'd1) begin
          trace_valid <= 1'b1; trace_cmd <= {2'b0, eng_we} + (eng_we ? 3'd1 : 3'd0) + (eng_we ? 3'd0 : 3'd1);
          trace_cmd <= eng_we ? 3'd2 : 3'd1;
          trace_addr <= {eng_row[19:0], 12'h0};
        end
        default: ;
      endcase
    end
  end

  // ========================================================================
  // Timers -- single owner (no multi-driver): loads come from the engine
  // via one-cycle load strobes; everything else free-runs down to zero.
  // ========================================================================
  logic [3:0]  ld_rp_v,  ld_ras_v, ld_rc_v, ld_wr_v;
  logic [15:0] ld_rp,    ld_ras,   ld_rc,   ld_wr;
  logic        ld_rrd_v, ld_wtr_v, ld_rfc_v, ref_ack;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < BANKS; i++) begin
        rp_cnt[i] <= 16'd0; ras_cnt[i] <= 16'd0;
        rc_cnt[i] <= 16'd0; wr_cnt[i] <= 16'd0;
      end
      rrd_cnt <= 16'd0; wtr_cnt <= 16'd0; rfc_cnt <= 16'd0;
      refi_cnt <= T_REFI[15:0];
      ref_pending <= 1'b0; ref_overrun <= 1'b0;
    end else begin
      for (int i = 0; i < BANKS; i++) begin
        if (ld_rp_v[i])       rp_cnt[i]  <= ld_rp;
        else if (rp_cnt[i]!=0) rp_cnt[i] <= rp_cnt[i] - 1;
        if (ld_ras_v[i])      ras_cnt[i] <= ld_ras;
        else if (ras_cnt[i]!=0) ras_cnt[i] <= ras_cnt[i] - 1;
        if (ld_rc_v[i])       rc_cnt[i]  <= ld_rc;
        else if (rc_cnt[i]!=0) rc_cnt[i] <= rc_cnt[i] - 1;
        if (ld_wr_v[i])       wr_cnt[i]  <= ld_wr;
        else if (wr_cnt[i]!=0) wr_cnt[i] <= wr_cnt[i] - 1;
      end
      if (ld_rrd_v)      rrd_cnt <= T_RRD[15:0];
      else if (rrd_cnt != 0) rrd_cnt <= rrd_cnt - 1;
      if (ld_wtr_v)      wtr_cnt <= T_WTR[15:0];
      else if (wtr_cnt != 0) wtr_cnt <= wtr_cnt - 1;
      if (ld_rfc_v)      rfc_cnt <= T_RFC[15:0];
      else if (rfc_cnt != 0) rfc_cnt <= rfc_cnt - 1;
      // refresh interval; overrun sticky if a second interval elapses
      // while a refresh is still waiting to be served
      if (refi_cnt != 0) refi_cnt <= refi_cnt - 1;
      else begin
        refi_cnt <= T_REFI[15:0];
        if (ref_pending) ref_overrun <= 1'b1;
        ref_pending <= 1'b1;
      end
      if (ref_ack) ref_pending <= 1'b0;
    end
  end

  // ========================================================================
  // Front-end
  // ========================================================================
  assign hready = (fe == FE_IDLE) || (fe == FE_FILL) || (fe == FE_DRAIN);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fe <= FE_IDLE; fe_cnt <= 4'd0;
      req_valid <= 1'b0; req_we <= 1'b0; req_ref <= 1'b0;
      req_addr <= 32'h0; fe_addr <= 32'h0;
      hrdata <= 16'h0; hdone <= 1'b0;
      rbuf_valid <= 1'b0;
      for (int i = 0; i < 8; i++) wbuf[i] <= 16'h0;
    end else begin
      hdone <= 1'b0;
      case (fe)
        FE_IDLE: begin
          if (hvalid) begin
            case (hcmd)
              3'd1: begin                       // READ line
                if (haddr[31:18] != 14'h0) begin
                  fe_err_pulse <= 1'b1; hdone <= 1'b1;   // out of range
                end else begin
                  fe_addr <= haddr;
                  req_addr <= haddr; req_we <= 1'b0; req_ref <= 1'b0;
                  req_valid <= 1'b1;
                  fe <= FE_WAIT_RD;
                end
              end
              3'd2: begin                       // WRITE line: collect 8 beats
                if (haddr[31:18] != 14'h0) begin
                  irq_reg <= 1'b1; hdone <= 1'b1;
                end else begin
                  fe_addr <= haddr; fe_cnt <= 4'd0;
                  fe <= FE_FILL;
                end
              end
              3'd3: begin                       // MRW (MR0 bit7 = instant DLL reset)
                mr[haddr[2:0]] <= (haddr[2:0] == 3'd0) ? {1'b0, hwdata[6:0]}
                                                       : hwdata[7:0];
                hdone <= 1'b1;
              end
              3'd4: begin                       // MRR
                hrdata <= {8'h00, mr[haddr[2:0]]};
                hdone <= 1'b1;
              end
              3'd5: begin                       // manual REFRESH
                req_we <= 1'b0; req_ref <= 1'b1; req_valid <= 1'b1;
                fe <= FE_WAIT_RD;
              end
              default: begin                    // NOP / illegal
                if (hcmd != 3'd0) irq_reg <= 1'b1;
                hdone <= 1'b1;
              end
            endcase
          end
        end
        FE_FILL: begin
          wbuf[fe_cnt[2:0]] <= hwdata;
          if (fe_cnt == 4'd7) begin
            req_addr <= fe_addr; req_we <= 1'b1; req_ref <= 1'b0;
            req_valid <= 1'b1;
            fe <= FE_WAIT_RD;
          end else fe_cnt <= fe_cnt + 1;
        end
        FE_WAIT_RD: begin
          if (req_done) begin
            req_valid <= 1'b0; req_ref <= 1'b0;
            if (!req_we && rbuf_valid) begin
              fe_cnt <= 4'd0; fe <= FE_DRAIN;   // read: return 8 beats
            end else begin
              hdone <= 1'b1; fe <= FE_IDLE;     // write / refresh done
            end
          end
        end
        FE_DRAIN: begin
          hrdata <= rbuf[fe_cnt[2:0]];
          if (fe_cnt == 4'd7) begin
            hdone <= 1'b1; rbuf_valid <= 1'b0; fe <= FE_IDLE;
          end else fe_cnt <= fe_cnt + 1;
        end
        default: fe <= FE_IDLE;
      endcase
    end
  end

  // rbuf is filled by the engine at the end of a read burst
  // (engine block assigns rbuf / rbuf_valid; single driver there)

  // ========================================================================
  // Command engine
  // ========================================================================
  wire [31:0] mem_idx = ((eng_bank * ROWS) + eng_row[31:0]) * LINES + eng_line;
  wire hit = bank_open[eng_bank] &&
             (bank_row[eng_bank] == eng_row[$clog2(ROWS)-1:0]);
  // refresh may only start when no bank is mid-write or inside tRAS
  wire ref_go = wr_done[0] && wr_done[1] && wr_done[2] && wr_done[3] &&
                ras_done[0] && ras_done[1] && ras_done[2] && ras_done[3];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      eng <= ENG_IDLE;
      eng_bank <= 4'd0; eng_line <= 4'd0; eng_row <= 32'h0; eng_we <= 1'b0;
      lat_cnt <= 5'd0; bcnt <= 5'd0;
      burst_reg <= 128'h0;
      req_done <= 1'b0;
      ld_rp_v <= 4'h0; ld_ras_v <= 4'h0; ld_rc_v <= 4'h0; ld_wr_v <= 4'h0;
      ld_rp <= 16'h0; ld_ras <= 16'h0; ld_rc <= 16'h0; ld_wr <= 16'h0;
      ld_rrd_v <= 1'b0; ld_wtr_v <= 1'b0; ld_rfc_v <= 1'b0; ref_ack <= 1'b0;
      dq_oe <= 1'b0; dqs_oe <= 1'b0; dq_out <= 16'h0; dqs_t <= 1'b0;
      for (int i = 0; i < BANKS; i++) begin
        bank_open[i] <= 1'b0; bank_row[i] <= '0;
      end
      for (int i = 0; i < 8; i++) rbuf[i] <= 16'h0;
      rbuf_valid <= 1'b0;
      irq_reg <= 1'b0;
    end else begin
      // default strobes low
      ld_rp_v <= 4'h0; ld_ras_v <= 4'h0; ld_rc_v <= 4'h0; ld_wr_v <= 4'h0;
      ld_rrd_v <= 1'b0; ld_wtr_v <= 1'b0; ld_rfc_v <= 1'b0;
      ref_ack <= 1'b0; req_done <= 1'b0;
      case (eng)
        // --------------------------------------------------------------
        ENG_IDLE: begin
          dq_oe <= 1'b0; dqs_oe <= 1'b0;
          if (req_valid && req_ref) begin
            eng <= ENG_REF_PRE;
          end else if (ref_pending) begin
            eng <= ENG_REF_PRE;
          end else if (req_valid) begin
            if (req_addr[31:18] != 14'h0) begin
              irq_reg <= 1'b1; req_done <= 1'b1;   // drop, report
            end else begin
              eng_bank <= {2'b0, req_addr[8:7]};
              eng_row  <= {22'h0, req_addr[17:9]};
              eng_line <= {1'b0, req_addr[6:4]};
              eng_we   <= req_we;
              eng <= ENG_BANK_CHK;
            end
          end
        end
        // --------------------------------------------------------------
        ENG_BANK_CHK: begin
          if (hit) begin
            // open-page hit: tWR must have drained; RD after RD needs no
            // gap here (engine is single-transaction); RD->WR needs tWTR
            if (wr_done[eng_bank] && (eng_we || wtr_done)) begin
              lat_cnt <= T_RCD[4:0];            // no ACT needed; go straight
              eng <= ENG_TRCD;
            end
          end else if (bank_open[eng_bank]) begin
            if (ras_done[eng_bank] && wr_done[eng_bank])
              eng <= ENG_PRE;
          end else begin
            if (rp_done[eng_bank] && rc_done[eng_bank] && rrd_done)
              eng <= ENG_ACT;
          end
        end
        // ---- PRE: pulse, then wait tRP ----
        ENG_PRE: begin
          bank_open[eng_bank] <= 1'b0;
          ld_rp_v[eng_bank] <= 1'b1; ld_rp <= T_RP[15:0];
          eng <= ENG_PRE_WAIT;
        end
        ENG_PRE_WAIT: if (rp_done[eng_bank]) eng <= ENG_ACT;
        // ---- ACT: pulse, then wait tRCD ----
        ENG_ACT: begin
          bank_open[eng_bank] <= 1'b1;
          bank_row[eng_bank] <= eng_row[$clog2(ROWS)-1:0];
          ld_ras_v[eng_bank] <= 1'b1; ld_ras <= T_RAS[15:0];
          ld_rc_v[eng_bank]  <= 1'b1; ld_rc  <= T_RC[15:0];
          ld_rrd_v <= 1'b1;
          lat_cnt <= T_RCD[4:0];
          eng <= ENG_TRCD;
        end
        // ---- tRCD elapse, then RD/WR command pulse ----
        ENG_TRCD: begin
          if (lat_cnt > 5'd1) lat_cnt <= lat_cnt - 1;
          else begin
            if (eng_we) begin
              lat_cnt <= cwl_now;               // CWL then write burst
              eng <= ENG_CWL;
            end else begin
              lat_cnt <= cl_now;                // CL then read burst
              eng <= ENG_CL;
            end
          end
        end
        // ---- read: wait CL, then drive 8 beats ----
        ENG_CL: begin
          if (lat_cnt > 5'd1) lat_cnt <= lat_cnt - 1;
          else begin
            burst_reg <= mem[mem_idx];
            bcnt <= 5'd0;
            eng <= ENG_RD_BURST;
          end
        end
        ENG_RD_BURST: begin
          dq_oe <= 1'b1; dqs_oe <= 1'b1; dqs_t <= ~dqs_t;
          dq_out <= burst_reg[16*bcnt +: 16];
          if (bcnt == 5'd7) begin
            for (int i = 0; i < 8; i++) rbuf[i] <= burst_reg[16*i +: 16];
            rbuf_valid <= 1'b1;
            dq_oe <= 1'b0; dqs_oe <= 1'b0;
            ld_wtr_v <= 1'b1;                   // tWTR before any WR
            req_done <= 1'b1;
            eng <= ENG_IDLE;
          end else bcnt <= bcnt + 1;
        end
        // ---- write: wait CWL, then drive 8 beats, commit ----
        ENG_CWL: begin
          if (lat_cnt > 5'd1) lat_cnt <= lat_cnt - 1;
          else begin
            bcnt <= 5'd0;
            eng <= ENG_WR_BURST;
          end
        end
        ENG_WR_BURST: begin
          dq_oe <= 1'b1; dqs_oe <= 1'b1; dqs_t <= ~dqs_t;
          dq_out <= wbuf[bcnt[2:0]];
          if (bcnt == 5'd7) begin
            mem[mem_idx] <= {wbuf[7], wbuf[6], wbuf[5], wbuf[4],
                             wbuf[3], wbuf[2], wbuf[1], wbuf[0]};
            dq_oe <= 1'b0; dqs_oe <= 1'b0;
            ld_wr_v[eng_bank] <= 1'b1; ld_wr <= T_WR[15:0];  // tWR
            req_done <= 1'b1;
            eng <= ENG_IDLE;
          end else bcnt <= bcnt + 1;
        end
        // ---- refresh: PREA (if any bank open), then REF + tRFC ----
        ENG_REF_PRE: begin
          if (ref_go) begin
            if (bank_open != 4'b0000) begin
              for (int i = 0; i < BANKS; i++) begin
                bank_open[i] <= 1'b0;
                ld_rp_v[i] <= 1'b1; ld_rp <= T_RP[15:0];
              end
              eng <= ENG_REF_WAITRP;              // pins: ENG_REF_PRE pulse
            end else begin
              eng <= ENG_REF_CMD;
            end
          end
        end
        ENG_REF_WAITRP: begin                     // tRP after PREA, then REF
          if (rp_done[0] && rp_done[1] && rp_done[2] && rp_done[3])
            eng <= ENG_REF_CMD;
        end
        ENG_REF_CMD: begin                        // 1-cycle REF pulse
          ld_rfc_v <= 1'b1;
          eng <= ENG_REF_WAIT;
        end
        ENG_REF_WAIT: begin
          if (rfc_done) begin
            ref_ack <= 1'b1;
            req_done <= 1'b1;
            eng <= ENG_IDLE;
          end
        end
        default: eng <= ENG_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------------
  // irq: sticky protocol-error / refresh-overrun indicator
  // ------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) irq <= 1'b0;
    else if (irq_reg || ref_overrun) irq <= 1'b1;
  end

endmodule
