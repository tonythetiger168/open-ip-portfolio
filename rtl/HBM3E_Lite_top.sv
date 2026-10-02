// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// HBM3E_Lite_top -- educational HBM3E-flavoured controller.
// Fork of the DDR4_Lite micro-architecture with REAL HBM organization:
//   * 8 pseudo-channels x 4 banks (32 independent open-row trackers);
//     address bits [13:11] select the pseudo-channel -- each PC has its
//     own bank state, timers and refresh domain
//   * per-bank refresh everywhere: the auto-refresh engine walks the
//     32 (pc,bank) entries round-robin, refreshing ONE entry per tREFI
//     interval without touching the other 31
//   * all-bank refresh (hcmd 5) sweeps every entry with PREA + REF + tRFC
//   * HBM has no DLL (unlike DDR4) -- no DLL-reset semantics anywhere;
//     mode register file kept for CL/CWL and refresh-related settings
//
// Documented abstractions: TSV/stack organization, 3D connectivity and
// lane repair are not controller-visible and are not modeled; the PHY
// pins remain a JEDEC-style command subset per pseudo-channel (ba carries
// {pc, bank} on addr[13:11]); SDR dqs; array inside the model; single
// command engine shared across pseudo-channels (one transaction in
// flight -- pseudo-channel interleaving happens at the front-end level).
//
// Front-end: hcmd 0 NOP | 1 RD | 2 WR | 3 MRW (haddr[2:0], hwdata[7:0])
// | 4 MRR | 5 REF (all entries).  haddr: [13:11]=pc [8:7]=bank
// [18:9]=row [6:4]=line [3:0]=byte; [31:19] must be 0.
// ============================================================================
module HBM3E_Lite_top #(
  parameter integer T_RCD  = 6,
  parameter integer T_RP   = 6,
  parameter integer T_RC   = 24,
  parameter integer T_RAS  = 16,
  parameter integer T_RRD  = 3,
  parameter integer T_WR   = 8,
  parameter integer T_WTR  = 4,
  parameter integer T_RFC  = 40,    // all-entry refresh recovery
  parameter integer T_RFC_PB = 20,  // per-bank refresh recovery
  parameter integer T_REFI = 1560,  // per-bank average interval (32 banks)
  parameter integer CL     = 11,
  parameter integer CWL    = 8,
  parameter integer ROWS   = 512
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
  output logic [2:0]  pc_act,       // active pseudo-channel (trace/debug)
  output logic        ck_t,
  output logic        ck_c,
  output logic        cke,
  output logic        cs_n,
  output logic        act_n,
  output logic        ras_n,
  output logic        cas_n,
  output logic        we_n,
  output logic [1:0]  ba,
  output logic [13:0] addr,         // [13:11]=pc
  inout  tri [15:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        trace_valid,
  output logic [3:0]  trace_cmd,
  output logic [31:0] trace_addr
);

  localparam integer PCS   = 8;
  localparam integer BANKS = 4;
  localparam integer ENTS  = PCS*BANKS;   // 32 entries
  localparam integer LINES = 8;

  // ---------------- mode registers (no DLL in HBM) ----------------
  logic [7:0] mr [0:7];
  wire [4:0] cl_now  = 5'd5 + {1'b0, mr[0][3:0]};
  wire [4:0] cwl_now = 5'd5 + {1'b0, mr[1][3:0]};

  // ---------------- memory array ----------------
  logic [127:0] mem [0:ENTS*ROWS*LINES-1];

  // ---------------- per-entry state / timers ----------------
  logic [ENTS-1:0]         ent_open;
  logic [$clog2(ROWS)-1:0] ent_row [0:ENTS-1];
  logic [15:0] rp_cnt [0:ENTS-1], ras_cnt [0:ENTS-1],
               rc_cnt [0:ENTS-1], wr_cnt [0:ENTS-1];
  wire rp_done  [0:ENTS-1], ras_done [0:ENTS-1],
       rc_done  [0:ENTS-1], wr_done  [0:ENTS-1];
  genvar g;
  generate
    for (g = 0; g < ENTS; g = g + 1) begin : TZERO
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

  // ---------------- per-bank refresh rotation over 32 entries ----------------
  logic [4:0]  ref_rot;
  logic [ENTS-1:0] pbref_pend;
  logic        refa_pend, ref_overrun;

  // ---------------- front-end <-> engine ----------------
  logic        req_valid, req_we, req_refall;
  logic        req_done;
  logic [31:0] req_addr;
  logic [5:0]  req_ent, req_line;      // entry = {pc, bank}
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
  logic [5:0]  eng_ent, eng_line;
  logic [31:0] eng_row;
  logic        eng_we;
  logic [4:0]  lat_cnt, bcnt;
  logic [127:0] burst_reg;

  wire [31:0] mem_idx = ((eng_ent * ROWS) + eng_row[31:0]) * LINES + eng_line;
  wire hit = ent_open[eng_ent] &&
             (ent_row[eng_ent] == eng_row[$clog2(ROWS)-1:0]);

  logic        dq_oe, dqs_oe;
  logic [15:0] dq_out;
  logic        dqs_t;
  assign dq  = dq_oe  ? dq_out      : 16'hzzzz;
  assign dqs = dqs_oe ? {~dqs_t, dqs_t} : 2'bzz;

  // ========================================================================
  // Timers (single owner)
  // ========================================================================
  logic [ENTS-1:0] ld_rp_v, ld_ras_v, ld_rc_v, ld_wr_v;
  logic [15:0] ld_rp, ld_ras, ld_rc, ld_wr;
  logic        ld_rrd_v, ld_wtr_v, ld_rfc_v;
  logic [15:0] ld_rfc;
  logic        pbref_ack;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < ENTS; i++) begin
        rp_cnt[i] <= 16'd0; ras_cnt[i] <= 16'd0;
        rc_cnt[i] <= 16'd0; wr_cnt[i] <= 16'd0;
        pbref_pend[i] <= 1'b0;
      end
      rrd_cnt <= 16'd0; wtr_cnt <= 16'd0; rfc_cnt <= 16'd0;
      refi_cnt <= T_REFI[15:0];
      ref_rot <= 5'd0; refa_pend <= 1'b0; ref_overrun <= 1'b0;
    end else begin
      for (int i = 0; i < ENTS; i++) begin
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
      if (refi_cnt != 0) refi_cnt <= refi_cnt - 1;
      else begin
        refi_cnt <= T_REFI[15:0];
        if (pbref_pend[ref_rot]) ref_overrun <= 1'b1;
        pbref_pend[ref_rot] <= 1'b1;
        ref_rot <= ref_rot + 1;
      end
      if (pbref_ack) pbref_pend[eng_ent] <= 1'b0;
    end
  end

  // ========================================================================
  // Front-end
  // ========================================================================
  assign hready = (fe == FE_IDLE) || (fe == FE_FILL) || (fe == FE_DRAIN);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fe <= FE_IDLE; fe_cnt <= 4'd0;
      req_valid <= 1'b0; req_we <= 1'b0; req_refall <= 1'b0;
      req_addr <= 32'h0; fe_addr <= 32'h0;
      hrdata <= 16'h0; hdone <= 1'b0;
      for (int i = 0; i < 8; i++) wbuf[i] <= 16'h0;
      fe_err_pulse <= 1'b0;
      for (int i = 0; i < 8; i++) mr[i] <= 8'h00;
      mr[0] <= CL - 5; mr[1] <= CWL - 5;
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
                  req_we <= 1'b0; req_refall <= 1'b0;
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
              3'd3: begin mr[haddr[2:0]] <= hwdata[7:0]; hdone <= 1'b1; end
              3'd4: begin hrdata <= {8'h00, mr[haddr[2:0]]}; hdone <= 1'b1; end
              3'd5: begin
                req_we <= 1'b0; req_refall <= 1'b1; req_valid <= 1'b1;
                fe <= FE_WAIT;
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
            req_addr <= fe_addr; req_we <= 1'b0 + 1'b1;
            req_refall <= 1'b0; req_valid <= 1'b1; fe <= FE_WAIT;
          end else fe_cnt <= fe_cnt + 1;
        end
        FE_WAIT: begin
          if (req_done) begin
            req_valid <= 1'b0; req_refall <= 1'b0;
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
  // Command engine (single engine shared across pseudo-channels)
  // ========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      eng <= ENG_IDLE;
      eng_ent <= 6'd0; eng_line <= 6'd0; eng_row <= 32'h0; eng_we <= 1'b0;
      lat_cnt <= 5'd0; bcnt <= 5'd0; burst_reg <= 128'h0;
      req_done <= 1'b0;
      ld_rp_v <= '0; ld_ras_v <= '0; ld_rc_v <= '0; ld_wr_v <= '0;
      ld_rp <= 16'h0; ld_ras <= 16'h0; ld_rc <= 16'h0; ld_wr <= 16'h0;
      ld_rrd_v <= 1'b0; ld_wtr_v <= 1'b0; ld_rfc_v <= 1'b0; ld_rfc <= 16'h0;
      pbref_ack <= 1'b0; eng_err_pulse <= 1'b0;
      dq_oe <= 1'b0; dqs_oe <= 1'b0; dq_out <= 16'h0; dqs_t <= 1'b0;
      for (int i = 0; i < ENTS; i++) begin
        ent_open[i] <= 1'b0; ent_row[i] <= '0;
      end
      for (int i = 0; i < 8; i++) rbuf[i] <= 16'h0;
      rbuf_valid <= 1'b0;
    end else begin
      ld_rp_v <= '0; ld_ras_v <= '0; ld_rc_v <= '0; ld_wr_v <= '0;
      ld_rrd_v <= 1'b0; ld_wtr_v <= 1'b0; ld_rfc_v <= 1'b0;
      pbref_ack <= 1'b0; req_done <= 1'b0; eng_err_pulse <= 1'b0;
      case (eng)
        ENG_IDLE: begin
          dq_oe <= 1'b0; dqs_oe <= 1'b0;
          if (req_valid && req_refall) eng <= ENG_RFA_CMD;
          else if (pbref_pend != 32'h0) begin
            for (int i = 0; i < ENTS; i++)
              if (pbref_pend[i] && eng == ENG_IDLE) eng_ent <= i[5:0];
            eng <= ENG_RFB_CHK;
          end
          else if (req_valid) begin
            if (req_addr[31:22] != 10'h0 || req_addr[16] != 1'b0) begin
              eng_err_pulse <= 1'b1; req_done <= 1'b1;
            end else begin
              if (!req_we) rbuf_valid <= 1'b0;
              eng_ent  <= {req_addr[21:19], req_addr[18:17]};
              eng_row  <= {23'h0, req_addr[15:7]};
              eng_line <= {3'b0, req_addr[6:4]};
              eng_we   <= req_we;
              eng <= ENG_BANK_CHK;
            end
          end
        end
        ENG_BANK_CHK: begin
          if (hit) begin
            if (wr_done[eng_ent] && (eng_we || wtr_done)) begin
              lat_cnt <= 5'd1; eng <= ENG_TRCD;
            end
          end else if (ent_open[eng_ent]) begin
            if (ras_done[eng_ent] && wr_done[eng_ent]) eng <= ENG_PRE;
          end else begin
            if (rp_done[eng_ent] && rc_done[eng_ent] && rrd_done)
              eng <= ENG_ACT;
          end
        end
        ENG_PRE: begin
          ent_open[eng_ent] <= 1'b0;
          ld_rp_v[eng_ent] <= 1'b1; ld_rp <= T_RP[15:0];
          eng <= ENG_PRE_WAIT;
        end
        ENG_PRE_WAIT: if (rp_done[eng_ent]) eng <= ENG_ACT;
        ENG_ACT: begin
          ent_open[eng_ent] <= 1'b1;
          ent_row[eng_ent] <= eng_row[$clog2(ROWS)-1:0];
          ld_ras_v[eng_ent] <= 1'b1; ld_ras <= T_RAS[15:0];
          ld_rc_v[eng_ent]  <= 1'b1; ld_rc  <= T_RC[15:0];
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
          if (lat_cnt > 5'd1) lat_cnt <= lat_cnt - 1;
          else begin bcnt <= 5'd0; eng <= ENG_WR_BURST; end
        end
        ENG_WR_BURST: begin
          dq_oe <= 1'b1; dqs_oe <= 1'b1; dqs_t <= ~dqs_t;
          dq_out <= wbuf[bcnt[2:0]];
          if (bcnt == 5'd7) begin
            mem[mem_idx] <= {wbuf[7], wbuf[6], wbuf[5], wbuf[4],
                             wbuf[3], wbuf[2], wbuf[1], wbuf[0]};
            dq_oe <= 1'b0; dqs_oe <= 1'b0;
            ld_wr_v[eng_ent] <= 1'b1; ld_wr <= T_WR[15:0];
            req_done <= 1'b1; eng <= ENG_IDLE;
          end else bcnt <= bcnt + 1;
        end
        // ---- per-entry refresh (one of 32 per tREFI) ----
        ENG_RFB_CHK: begin
          if (wr_done[eng_ent] && ras_done[eng_ent]) begin
            if (ent_open[eng_ent]) eng <= ENG_RFB_PRE;
            else                   eng <= ENG_RFB_CMD;
          end
        end
        ENG_RFB_PRE: begin
          ent_open[eng_ent] <= 1'b0;
          ld_rp_v[eng_ent] <= 1'b1; ld_rp <= T_RP[15:0];
          eng <= ENG_RFB_PRE_WAIT;
        end
        ENG_RFB_PRE_WAIT: if (rp_done[eng_ent]) eng <= ENG_RFB_CMD;
        ENG_RFB_CMD: begin
          ld_rfc_v <= 1'b1; ld_rfc <= T_RFC_PB[15:0];
          eng <= ENG_RFB_WAIT;
        end
        ENG_RFB_WAIT: begin
          if (rfc_done) begin
            pbref_ack <= 1'b1; req_done <= 1'b1; eng <= ENG_IDLE;
          end
        end
        // ---- all-entry refresh ----
        ENG_RFA_CMD: begin
          for (int i = 0; i < ENTS; i++) begin
            ent_open[i] <= 1'b0;
            ld_rp_v[i] <= 1'b1; ld_rp <= T_RP[15:0];
          end
          ld_rfc_v <= 1'b1; ld_rfc <= T_RFC[15:0];
          eng <= ENG_RFA_WAIT;
        end
        ENG_RFA_WAIT: begin
          if (rfc_done && (&{rp_done[31],rp_done[30],rp_done[29],rp_done[28],
              rp_done[27],rp_done[26],rp_done[25],rp_done[24],rp_done[23],
              rp_done[22],rp_done[21],rp_done[20],rp_done[19],rp_done[18],
              rp_done[17],rp_done[16],rp_done[15],rp_done[14],rp_done[13],
              rp_done[12],rp_done[11],rp_done[10],rp_done[9],rp_done[8],
              rp_done[7],rp_done[6],rp_done[5],rp_done[4],rp_done[3],
              rp_done[2],rp_done[1],rp_done[0]})) begin
            req_done <= 1'b1; eng <= ENG_IDLE;
          end
        end
        default: eng <= ENG_IDLE;
      endcase
    end
  end

  // ========================================================================
  // Pins / trace
  // ========================================================================
  assign pc_act = eng_ent[5:3];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ck_t <= 1'b0; cke <= 1'b1;
      cs_n <= 1'b1; act_n <= 1'b1; ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
      ba <= 2'b00; addr <= 14'h0;
    end else begin
      ck_t <= 1'b1; cke <= 1'b1;
      cs_n <= 1'b1; act_n <= 1'b1; ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
      case (eng)
        ENG_PRE, ENG_RFB_PRE: begin
          cs_n <= 1'b0; ras_n <= 1'b0; we_n <= 1'b0;
          ba <= eng_ent[1:0]; addr <= {eng_ent[5:3], 11'h000};
        end
        ENG_ACT: begin
          cs_n <= 1'b0; act_n <= 1'b0;
          ba <= eng_ent[1:0]; addr <= eng_row[13:0];
        end
        ENG_TRCD: if (lat_cnt == 5'd1) begin
          cs_n <= 1'b0; cas_n <= 1'b0; we_n <= ~eng_we;
          ba <= eng_ent[1:0]; addr <= {eng_ent[5:3], 3'b000, eng_line, 4'h0};
        end
        ENG_RFB_CMD: begin
          cs_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b0;   // per-bank REF
          ba <= eng_ent[1:0]; addr <= {eng_ent[5:3], 11'h000};
        end
        ENG_RFA_CMD: begin
          cs_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b0;   // all-bank REF
          ba <= 2'b00; addr <= 14'h0400;                 // A10=1
        end
        default: ;
      endcase
    end
  end
  assign ck_c = ~ck_t;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      trace_valid <= 1'b0; trace_cmd <= 4'd0; trace_addr <= 32'h0;
    end else begin
      trace_valid <= 1'b0;
      case (eng)
        ENG_ACT:     begin trace_valid <= 1'b1; trace_cmd <= 4'd0; trace_addr <= {eng_row[19:0], 12'h0}; end
        ENG_PRE:     begin trace_valid <= 1'b1; trace_cmd <= 4'd3; trace_addr <= {eng_row[19:0], 12'h0}; end
        ENG_RFB_CMD: begin trace_valid <= 1'b1; trace_cmd <= 4'd5; trace_addr <= {26'h0, eng_ent}; end
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
