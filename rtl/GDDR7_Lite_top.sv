// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// GDDR7_Lite_top -- educational GDDR7-flavoured controller.
// Built on the DDR4_Lite micro-architecture with GDDR7 features:
//   * dual independent channels (2 ch x 4 banks = 8 entries, each with its
//     own open-row state and timers); the channel travels on addr[11] of
//     ACT / RD / WR / PRE
//   * PAM3 signaling mode (MR2[0]): the data interface is a symbol bus --
//     16 physical pins x 2-bit ternary lanes. A PAM3 burst is BL6: 6 beats
//     x 16 trits = 96 trits = 32 nibbles = 128 data bits (nibble v -> trits
//     {t0, t1, t2} with v = 9*t0 + 3*t1 + t2; 16 of the 27 trit triples are
//     used). PAM2 mode keeps BL8 on the low 16 lanes, the upper 16 Hi-Z.
//   * the array holds raw data in both modes: a write is encoded onto the
//     symbol bus and decoded on the DRAM side, a read is encoded by the
//     DRAM side and decoded for the host, so a round trip in PAM3 proves
//     both coders, and a line reads back the same after a mode switch
//   * the burst length follows the mode latched with each command
//   * timing-fenced scheduling as DDR4_Lite: tRCD, tRP, tRC, tRAS, tRRD,
//     tWR, tWTR, tRFC, tREFI; data exactly CL / CWL clocks after RD / WR;
//     all-bank refresh is PREA (when a bank is open) + REF + tRFC
//   * MR file MR0..MR7 (MR0[3:0] CL, MR1[3:0] CWL, MR2[0] PAM3), sticky
//     irq on rejected commands and refresh overrun
// Documented abstractions: PAM3 here is a digital symbol-level model (one
// 2-bit lane per pin), not analog levels; no equalization, no CK/WCK ratio,
// no per-channel CK/WCK; SDR dqs; array inside the model; one command
// engine for both channels (one transaction in flight).
// Front-end: hcmd 0 NOP | 1 READ line | 2 WRITE line | 3 MRW (haddr[2:0],
// hwdata[7:0]) | 4 MRR | 5 REFRESH (all banks, both channels).
// haddr: [9]=channel [8:7]=bank [18:10]=row [6:4]=line [3:0]=byte;
// [31:19] must be 0. Handshake and data beats as DDR4_Lite: a command is
// taken on hvalid && hready; a WRITE takes 8 beats on hvalid clocks; read
// data is on hrdata in the 8 clocks ending with hdone.
// ============================================================================
module GDDR7_Lite_top #(
  parameter integer T_RCD  = 6,     // ACT  -> RD/WR
  parameter integer T_RP   = 6,     // PRE  -> ACT
  parameter integer T_RC   = 24,    // ACT  -> ACT (same bank)
  parameter integer T_RAS  = 16,    // ACT  -> PRE
  parameter integer T_RRD  = 3,     // ACT  -> ACT (different bank)
  parameter integer T_WR   = 8,     // end of WR burst -> PRE
  parameter integer T_WTR  = 4,     // end of WR burst -> RD issue
  parameter integer T_RFC  = 40,    // REF  -> next valid command
  parameter integer T_REFI = 3900,  // average refresh interval
  parameter integer CL     = 11,    // read latency   (MR0[3:0] overrides)
  parameter integer CWL    = 8      // write latency  (MR1[3:0] overrides)
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
  output logic        pam3,         // active signaling mode (MR2[0])
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
  inout  tri [31:0]   dq,           // 16 pins x 2-bit symbol lanes
  inout  tri [1:0]    dqs,
  // ---- trace ----
  output logic        trace_valid,
  output logic [3:0]  trace_cmd,
  output logic [31:0] trace_addr
);

  localparam integer BANKS = 8;              // 2 channels x 4 banks
  localparam integer ROWS  = 512;            // row field haddr[18:10]
  localparam integer LINES = 8;              // BL8 bursts per row segment
  localparam integer CW    = 16;             // dq width

  // ---------------- derived latencies (from MR0/MR1) ----------------
  // CL cycles = 5 + MR0[3:0] (JEDEC DDR4 CL step is coarser; educational
  // linear map keeps the register meaningful).  CWL = 5 + MR1[3:0].
  logic [7:0] mr [0:7];
  wire [4:0] cl_now  = 5'd5 + {1'b0, mr[0][3:0]};
  wire [4:0] cwl_now = 5'd5 + {1'b0, mr[1][3:0]};
  assign pam3 = mr[2][0];

  // ---------------- memory array (controller + DRAM model) ----------------
  // 8 entries x ROWS rows x LINES lines x 128 bits (raw data, both modes)
  logic [127:0] mem [0:BANKS*ROWS*LINES-1];
  // a DRAM keeps its data through rst_n; zero it once for deterministic
  // simulation
  initial for (int i = 0; i < BANKS*ROWS*LINES; i++) mem[i] = '0;

  // ---------------- per-bank state ----------------
  logic [BANKS-1:0]       bank_open;
  logic [$clog2(ROWS)-1:0] bank_row [0:BANKS-1];

  // ---------------- timers ----------------
  // each counter is as wide as its own parameter
  localparam integer RPW  = $clog2(T_RP + 1),  RASW = $clog2(T_RAS + 1),
                     RCW  = $clog2(T_RC + 1),  WRW  = $clog2(T_WR + 1),
                     RRDW = $clog2(T_RRD + 1), WTRW = $clog2(T_WTR + 1),
                     RFCW = $clog2(T_RFC + 1), REFIW = $clog2(T_REFI + 1);
  logic [RPW-1:0]  rp_cnt  [0:BANKS-1];
  logic [RASW-1:0] ras_cnt [0:BANKS-1];
  logic [RCW-1:0]  rc_cnt  [0:BANKS-1];
  logic [WRW-1:0]  wr_cnt  [0:BANKS-1];
  logic [RRDW-1:0] rrd_cnt;
  logic [WTRW-1:0] wtr_cnt;
  logic [RFCW-1:0] rfc_cnt;
  logic [REFIW-1:0] refi_cnt;
  // timer load strobes (engine -> timer block, one cycle); each loads its
  // timing parameter
  logic [BANKS-1:0] ld_rp_v,  ld_ras_v, ld_rc_v, ld_wr_v;
  logic        ld_rrd_v, ld_wtr_v, ld_rfc_v, ref_ack;
  wire [BANKS-1:0] rp_done, ras_done, rc_done, wr_done;
  genvar g;
  generate
    for (g = 0; g < BANKS; g = g + 1) begin : TZERO
      // a load strobe in flight means the timer is about to be armed:
      // treat it as not-done, or the engine sees a stale zero for a cycle
      assign rp_done[g]  = (rp_cnt[g] == '0) && !ld_rp_v[g];
      assign ras_done[g] = (ras_cnt[g] == '0) && !ld_ras_v[g];
      assign rc_done[g]  = (rc_cnt[g] == '0) && !ld_rc_v[g];
      assign wr_done[g]  = (wr_cnt[g] == '0) && !ld_wr_v[g];
    end
  endgenerate
  wire rrd_done = (rrd_cnt == '0) && !ld_rrd_v;
  wire wtr_done = (wtr_cnt == '0) && !ld_wtr_v;
  wire rfc_done = (rfc_cnt == '0) && !ld_rfc_v;

  // ---------------- refresh ----------------
  logic ref_pending;
  logic ref_overrun;

  // ---------------- front-end <-> engine handshake ----------------
  logic        req_valid, req_we, req_ref;
  logic        req_done;
  logic [18:0] req_addr;               // in-range host address

  // ---------------- front-end ----------------
  typedef enum logic [1:0] {FE_IDLE, FE_FILL, FE_WAIT, FE_DRAIN} fe_t;
  fe_t fe;
  logic [2:0]  fe_cnt;
  logic [15:0] wbuf [0:7];
  logic [15:0] rbuf [0:7];
  logic        rbuf_valid;
  logic        rbuf_take;              // FE -> engine: rbuf consumed
  logic        fe_err;                 // 1-cycle protocol-error pulse
  logic [18:0] fe_addr;

  // ---------------- engine ----------------
  typedef enum logic [3:0] {
    ENG_IDLE, ENG_BANK_CHK, ENG_PRE, ENG_PRE_WAIT, ENG_ACT, ENG_TRCD,
    ENG_CL, ENG_RD_BURST, ENG_CWL, ENG_WR_BURST,
    ENG_REF_PRE, ENG_REF_WAITRP, ENG_REF_CMD, ENG_REF_WAIT
  } eng_t;
  eng_t eng;
  logic [2:0]  eng_bank;                // {channel, bank}
  logic [2:0]  eng_line;
  logic [8:0]  eng_row;                 // haddr[18:10] (ROWS = 512)
  logic        eng_we;
  logic        eng_pam3;                // signaling mode latched per command
  logic        eng_ref_req;            // refresh was a host REFRESH command
  logic [4:0]  lat_cnt;
  logic [2:0]  bcnt;
  logic [127:0] burst_reg;
  logic [191:0] trit_reg;               // the line as 96 trits (PAM3)

  // ---------------- dq / dqs ----------------
  logic        dq_oe, dqs_oe;
  logic        dq_hi_oe;               // upper 16 lanes carry symbols (PAM3)
  logic [31:0] dq_out;
  logic        dqs_t;
  assign dq[15:0]  = dq_oe    ? dq_out[15:0]  : 16'hzzzz;
  assign dq[31:16] = dq_hi_oe ? dq_out[31:16] : 16'hzzzz;
  assign dqs     = dqs_oe ? {~dqs_t, dqs_t} : 2'bzz;

  // ---------------- pins ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs_n <= 1'b1; act_n <= 1'b1; ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
      ba <= 2'b00; addr <= 14'h0;
    end else begin
      // default: bus deselect every cycle; states override for 1 cycle
      cs_n <= 1'b1; act_n <= 1'b1; ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
      case (eng)
        ENG_PRE: begin                    // PRE (single bank; addr[10]=0)
          cs_n <= 1'b0; act_n <= 1'b1; ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0;
          ba <= eng_bank[1:0]; addr <= {2'b00, eng_bank[2], 11'h000};
        end
        ENG_ACT: begin                    // ACT (row on addr)
          cs_n <= 1'b0; act_n <= 1'b0; ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
          ba <= eng_bank[1:0]; addr <= {2'b00, eng_bank[2], 2'b00, eng_row};
        end
        ENG_TRCD: if (lat_cnt == 5'd1 && (eng_we || wtr_done)) begin  // RD / WR command
          cs_n <= 1'b0; act_n <= 1'b1; ras_n <= 1'b1; cas_n <= 1'b0;
          we_n <= ~eng_we;
          ba <= eng_bank[1:0]; addr <= {2'b00, eng_bank[2], 4'b0000, eng_line, 4'h0};
        end
        ENG_REF_PRE: if (ref_go && bank_open != '0) begin  // PREA (all banks)
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
  assign ck_t = clk;  assign ck_c = ~clk;  assign cke = rst_n;

  // ---------------- trace ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      trace_valid <= 1'b0; trace_cmd <= 4'd0; trace_addr <= 32'h0;
    end else begin
      trace_valid <= 1'b0;
      case (eng)
        ENG_ACT:     begin trace_valid <= 1'b1; trace_cmd <= 4'd0; trace_addr <= {11'h0, eng_row, 12'h0}; end
        ENG_PRE:     begin trace_valid <= 1'b1; trace_cmd <= 4'd3; trace_addr <= {11'h0, eng_row, 12'h0}; end
        ENG_REF_CMD: begin trace_valid <= 1'b1; trace_cmd <= 4'd4; trace_addr <= 32'h0; end
        ENG_TRCD: if (lat_cnt == 5'd1 && (eng_we || wtr_done)) begin
          trace_valid <= 1'b1; trace_cmd <= eng_we ? 4'd2 : 4'd1;
          trace_addr <= {11'h0, eng_row, 12'h0};
        end
        default: ;
      endcase
    end
  end

  // ========================================================================
  // Timers -- single owner (no multi-driver): loads come from the engine
  // via one-cycle load strobes; everything else free-runs down to zero.
  // ========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < BANKS; i++) begin
        rp_cnt[i] <= '0; ras_cnt[i] <= '0;
        rc_cnt[i] <= '0; wr_cnt[i] <= '0;
      end
      rrd_cnt <= '0; wtr_cnt <= '0; rfc_cnt <= '0;
      refi_cnt <= REFIW'(T_REFI);
      ref_pending <= 1'b0; ref_overrun <= 1'b0;
    end else begin
      for (int i = 0; i < BANKS; i++) begin
        if (ld_rp_v[i])       rp_cnt[i]  <= RPW'(T_RP);
        else if (rp_cnt[i]!=0) rp_cnt[i] <= rp_cnt[i] - 1;
        if (ld_ras_v[i])      ras_cnt[i] <= RASW'(T_RAS);
        else if (ras_cnt[i]!=0) ras_cnt[i] <= ras_cnt[i] - 1;
        if (ld_rc_v[i])       rc_cnt[i]  <= RCW'(T_RC);
        else if (rc_cnt[i]!=0) rc_cnt[i] <= rc_cnt[i] - 1;
        if (ld_wr_v[i])       wr_cnt[i]  <= WRW'(T_WR);
        else if (wr_cnt[i]!=0) wr_cnt[i] <= wr_cnt[i] - 1;
      end
      if (ld_rrd_v)      rrd_cnt <= RRDW'(T_RRD);
      else if (rrd_cnt != 0) rrd_cnt <= rrd_cnt - 1;
      if (ld_wtr_v)      wtr_cnt <= WTRW'(T_WTR);
      else if (wtr_cnt != 0) wtr_cnt <= wtr_cnt - 1;
      if (ld_rfc_v)      rfc_cnt <= RFCW'(T_RFC);
      else if (rfc_cnt != 0) rfc_cnt <= rfc_cnt - 1;
      // refresh interval; overrun sticky if a second interval elapses
      // while a refresh is still waiting to be served. The REF going out
      // serves the pending one (an interval ending in that same clock
      // starts the next).
      if (ref_ack) ref_pending <= 1'b0;
      if (refi_cnt != 0) refi_cnt <= refi_cnt - 1;
      else begin
        refi_cnt <= REFIW'(T_REFI);
        if (ref_pending && !ref_ack) ref_overrun <= 1'b1;
        ref_pending <= 1'b1;
      end
    end
  end

  // ========================================================================
  // Front-end
  // ========================================================================
  assign hready = (fe == FE_IDLE) || (fe == FE_FILL);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fe <= FE_IDLE; fe_cnt <= '0;
      req_valid <= 1'b0; req_we <= 1'b0; req_ref <= 1'b0;
      req_addr <= '0; fe_addr <= '0;
      hrdata <= 16'h0; hdone <= 1'b0;
      rbuf_take <= 1'b0; fe_err <= 1'b0;
      for (int i = 0; i < 8; i++) wbuf[i] <= 16'h0;
      for (int i = 0; i < 8; i++) mr[i] <= 8'h0;
      mr[0] <= 8'(CL - 5); mr[1] <= 8'(CWL - 5);   // CL / CWL fields
    end else begin
      hdone <= 1'b0; rbuf_take <= 1'b0; fe_err <= 1'b0;
      case (fe)
        FE_IDLE: begin
          if (hvalid) begin
            case (hcmd)
              3'd1: begin                       // READ line
                if (haddr[31:19] != 13'h0) begin
                  fe_err <= 1'b1; hdone <= 1'b1;         // out of range
                end else begin
                  fe_addr <= haddr[18:0];
                  req_addr <= haddr[18:0]; req_we <= 1'b0; req_ref <= 1'b0;
                  req_valid <= 1'b1;
                  fe <= FE_WAIT;
                end
              end
              3'd2: begin                       // WRITE line: collect 8 beats
                if (haddr[31:19] != 13'h0) begin
                  fe_err <= 1'b1; hdone <= 1'b1;
                end else begin
                  fe_addr <= haddr[18:0]; fe_cnt <= '0;
                  fe <= FE_FILL;
                end
              end
              3'd3: begin                       // MRW
                mr[haddr[2:0]] <= hwdata[7:0];
                hdone <= 1'b1;
              end
              3'd4: begin                       // MRR
                hrdata <= {8'h00, mr[haddr[2:0]]};
                hdone <= 1'b1;
              end
              3'd5: begin                       // manual REFRESH
                req_we <= 1'b0; req_ref <= 1'b1; req_valid <= 1'b1;
                fe <= FE_WAIT;
              end
              default: begin                    // NOP / illegal
                if (hcmd != 3'd0) fe_err <= 1'b1;
                hdone <= 1'b1;
              end
            endcase
          end
        end
        FE_FILL: if (hvalid) begin           // one data beat per hvalid clock
          wbuf[fe_cnt] <= hwdata;
          if (fe_cnt == 3'd7) begin
            req_addr <= fe_addr; req_we <= 1'b1; req_ref <= 1'b0;
            req_valid <= 1'b1;
            fe <= FE_WAIT;
          end else fe_cnt <= fe_cnt + 1;
        end
        FE_WAIT: begin
          if (req_done) begin
            req_valid <= 1'b0; req_ref <= 1'b0;
            if (!req_we && rbuf_valid) begin
              fe_cnt <= '0; fe <= FE_DRAIN;   // read: return 8 beats
            end else begin
              hdone <= 1'b1; fe <= FE_IDLE;     // write / refresh done
            end
          end
        end
        FE_DRAIN: begin
          hrdata <= rbuf[fe_cnt];
          if (fe_cnt == 3'd7) begin
            hdone <= 1'b1; rbuf_take <= 1'b1; fe <= FE_IDLE;
          end else fe_cnt <= fe_cnt + 1;
        end
      endcase
    end
  end

  // rbuf is filled by the engine at the end of a read burst; the engine is
  // the single driver of rbuf / rbuf_valid and clears it on rbuf_take

  // ========================================================================
  // PAM3 nibble <-> trit coding (a 16-entry table: '/' and '%' by 9 and 3
  // would elaborate as 32-bit dividers, 32 of them per coder)
  // ========================================================================
  function automatic [5:0] enc_nibble(input [3:0] v);
    case (v)
      4'd0:  enc_nibble = {2'd0, 2'd0, 2'd0};
      4'd1:  enc_nibble = {2'd0, 2'd0, 2'd1};
      4'd2:  enc_nibble = {2'd0, 2'd0, 2'd2};
      4'd3:  enc_nibble = {2'd0, 2'd1, 2'd0};
      4'd4:  enc_nibble = {2'd0, 2'd1, 2'd1};
      4'd5:  enc_nibble = {2'd0, 2'd1, 2'd2};
      4'd6:  enc_nibble = {2'd0, 2'd2, 2'd0};
      4'd7:  enc_nibble = {2'd0, 2'd2, 2'd1};
      4'd8:  enc_nibble = {2'd0, 2'd2, 2'd2};
      4'd9:  enc_nibble = {2'd1, 2'd0, 2'd0};
      4'd10: enc_nibble = {2'd1, 2'd0, 2'd1};
      4'd11: enc_nibble = {2'd1, 2'd0, 2'd2};
      4'd12: enc_nibble = {2'd1, 2'd1, 2'd0};
      4'd13: enc_nibble = {2'd1, 2'd1, 2'd1};
      4'd14: enc_nibble = {2'd1, 2'd1, 2'd2};
      default: enc_nibble = {2'd1, 2'd2, 2'd0};   // 15
    endcase
  endfunction
  // 9*t0 + 3*t1 + t2; the encoder only produces values 0..15
  function automatic [3:0] dec_nibble(input [5:0] t);
    dec_nibble = 4'({t[5:4], 3'b000} + {3'b000, t[5:4]} + {2'b00, t[3:2], 1'b0} +
                    {3'b000, t[3:2]} + {3'b000, t[1:0]});
  endfunction
  function automatic [191:0] pack_trits(input [127:0] d);
    for (int k = 0; k < 32; k++) pack_trits[6*k +: 6] = enc_nibble(d[4*k +: 4]);
  endfunction
  function automatic [127:0] unpack_data(input [191:0] t);
    for (int k = 0; k < 32; k++) unpack_data[4*k +: 4] = dec_nibble(t[6*k +: 6]);
  endfunction
  wire [127:0] trit_dec = unpack_data(trit_reg);   // the symbol bus, decoded
  wire [127:0] wline = {wbuf[7], wbuf[6], wbuf[5], wbuf[4], wbuf[3], wbuf[2], wbuf[1], wbuf[0]};

  // ========================================================================
  // Command engine
  // ========================================================================
  localparam integer MAW = $clog2(BANKS * ROWS * LINES);
  wire [MAW-1:0] mem_idx = {eng_bank, eng_row, eng_line};

  // Array write port, kept out of the async-reset engine process so the
  // array infers as a memory (SRAM macro) instead of 128-bit registers;
  // the engine posts one write per burst, applied on the next edge.
  logic           mem_we;
  logic [MAW-1:0] mem_wa;
  logic [127:0]   mem_wd;
  always_ff @(posedge clk) if (mem_we) mem[mem_wa] <= mem_wd;
  wire hit = bank_open[eng_bank] &&
             (bank_row[eng_bank] == eng_row);
  // refresh may only start when no bank is mid-write or inside tRAS
  wire ref_go = (&wr_done) && (&ras_done);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      eng <= ENG_IDLE;
      mem_we <= 1'b0; mem_wa <= '0; mem_wd <= '0;
      eng_bank <= '0; eng_line <= '0; eng_row <= '0; eng_we <= 1'b0; eng_pam3 <= 1'b0;
      eng_ref_req <= 1'b0;
      lat_cnt <= 5'd0; bcnt <= '0;
      burst_reg <= 128'h0; trit_reg <= '0;
      req_done <= 1'b0;
      ld_rp_v <= '0; ld_ras_v <= '0; ld_rc_v <= '0; ld_wr_v <= '0;
      ld_rrd_v <= 1'b0; ld_wtr_v <= 1'b0; ld_rfc_v <= 1'b0; ref_ack <= 1'b0;
      dq_oe <= 1'b0; dq_hi_oe <= 1'b0; dqs_oe <= 1'b0; dq_out <= '0; dqs_t <= 1'b0;
      for (int i = 0; i < BANKS; i++) begin
        bank_open[i] <= 1'b0; bank_row[i] <= '0;
      end
      for (int i = 0; i < 8; i++) rbuf[i] <= 16'h0;
      rbuf_valid <= 1'b0;
    end else begin
      // default strobes low
      ld_rp_v <= '0; ld_ras_v <= '0; ld_rc_v <= '0; ld_wr_v <= '0;
      ld_rrd_v <= 1'b0; ld_wtr_v <= 1'b0; ld_rfc_v <= 1'b0;
      ref_ack <= 1'b0; req_done <= 1'b0;
      mem_we <= 1'b0;
      if (rbuf_take) rbuf_valid <= 1'b0;
      case (eng)
        // --------------------------------------------------------------
        ENG_IDLE: begin
          dq_oe <= 1'b0; dq_hi_oe <= 1'b0; dqs_oe <= 1'b0;
          // req_valid is still high in the cycle req_done pulses (the FE
          // drops it one cycle later): ignore it then, or the engine
          // relaunches the request it just finished
          if (req_valid && req_ref && !req_done) begin
            eng_ref_req <= 1'b1;
            eng <= ENG_REF_PRE;
          end else if (ref_pending) begin
            eng_ref_req <= 1'b0;
            eng <= ENG_REF_PRE;
          end else if (req_valid && !req_done) begin
            // the front-end already rejected out-of-range addresses
            eng_bank <= req_addr[9:7];
            eng_row  <= req_addr[18:10];
            eng_line <= req_addr[6:4];
            eng_we   <= req_we;
            eng_pam3 <= pam3;                   // mode latched per command
            eng <= ENG_BANK_CHK;
          end
        end
        // --------------------------------------------------------------
        ENG_BANK_CHK: begin
          if (hit) begin
            // open-page hit: no ACT, the RD / WR goes out next clock (an RD
            // still waits out tWTR there)
            lat_cnt <= 5'd1;
            eng <= ENG_TRCD;
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
          ld_rp_v[eng_bank] <= 1'b1;
          eng <= ENG_PRE_WAIT;
        end
        ENG_PRE_WAIT: if (rp_done[eng_bank] && rc_done[eng_bank] && rrd_done) eng <= ENG_ACT;
        // ---- ACT: pulse, then wait tRCD ----
        ENG_ACT: begin
          bank_open[eng_bank] <= 1'b1;
          bank_row[eng_bank] <= eng_row;
          ld_ras_v[eng_bank] <= 1'b1;
          ld_rc_v[eng_bank]  <= 1'b1;
          ld_rrd_v <= 1'b1;
          lat_cnt <= T_RCD[4:0];
          eng <= ENG_TRCD;
        end
        // ---- tRCD elapse, then RD/WR command pulse ----
        ENG_TRCD: begin
          if (lat_cnt > 5'd1) lat_cnt <= lat_cnt - 1;
          else if (eng_we) begin
            lat_cnt <= cwl_now - 5'd1;          // data CWL clocks after the WR
            eng <= ENG_CWL;
          end else if (wtr_done) begin          // tWTR: WR burst end -> RD
            lat_cnt <= cl_now - 5'd1;           // data CL clocks after the RD
            eng <= ENG_CL;
          end
        end
        // ---- read: wait CL, then drive the burst (BL8, or BL6 in PAM3) ----
        ENG_CL: begin
          if (lat_cnt > 5'd1) lat_cnt <= lat_cnt - 1;
          else begin
            burst_reg <= mem[mem_idx];
            trit_reg  <= pack_trits(mem[mem_idx]);   // DRAM side encodes
            bcnt <= '0;
            eng <= ENG_RD_BURST;
          end
        end
        ENG_RD_BURST: begin
          dq_oe <= 1'b1; dq_hi_oe <= eng_pam3; dqs_oe <= 1'b1; dqs_t <= ~dqs_t;
          dq_out <= eng_pam3 ? trit_reg[32*bcnt +: 32] : {16'h0, burst_reg[16*bcnt +: 16]};
          if (bcnt == {1'b1, !eng_pam3, 1'b1}) begin   // last beat: 5 (BL6) or 7 (BL8)
            // PAM3: the host gets what the symbol bus carried, decoded
            for (int i = 0; i < 8; i++)
              rbuf[i] <= eng_pam3 ? trit_dec[16*i +: 16] : burst_reg[16*i +: 16];
            rbuf_valid <= 1'b1;
            req_done <= 1'b1;
            eng <= ENG_IDLE;
          end else bcnt <= bcnt + 1;
        end
        // ---- write: wait CWL, then drive the burst, commit ----
        ENG_CWL: begin
          if (lat_cnt > 5'd1) lat_cnt <= lat_cnt - 1;
          else begin
            bcnt <= '0;
            trit_reg <= pack_trits(wline);      // controller side encodes
            eng <= ENG_WR_BURST;
          end
        end
        ENG_WR_BURST: begin
          dq_oe <= 1'b1; dq_hi_oe <= eng_pam3; dqs_oe <= 1'b1; dqs_t <= ~dqs_t;
          dq_out <= eng_pam3 ? trit_reg[32*bcnt +: 32] : {16'h0, wbuf[bcnt]};
          if (bcnt == {1'b1, !eng_pam3, 1'b1}) begin
            // PAM3: the DRAM side stores what the symbol bus carried, decoded
            mem_we <= 1'b1; mem_wa <= mem_idx;
            mem_wd <= eng_pam3 ? trit_dec : wline;
            ld_wr_v[eng_bank] <= 1'b1;  // tWR
            ld_wtr_v <= 1'b1;                   // tWTR before the next RD
            req_done <= 1'b1;
            eng <= ENG_IDLE;
          end else bcnt <= bcnt + 1;
        end
        // ---- refresh: PREA (if any bank open), then REF + tRFC ----
        ENG_REF_PRE: begin
          if (ref_go) begin
            if (bank_open != '0) begin
              for (int i = 0; i < BANKS; i++) begin
                bank_open[i] <= 1'b0;
                ld_rp_v[i] <= 1'b1;
              end
              eng <= ENG_REF_WAITRP;              // pins: ENG_REF_PRE pulse
            end else begin
              eng <= ENG_REF_CMD;
            end
          end
        end
        ENG_REF_WAITRP: begin                     // tRP after PREA, then REF
          if (&rp_done)
            eng <= ENG_REF_CMD;
        end
        ENG_REF_CMD: begin                        // 1-cycle REF pulse
          ld_rfc_v <= 1'b1;
          ref_ack <= 1'b1;                        // this REF serves the pending one
          eng <= ENG_REF_WAIT;
        end
        ENG_REF_WAIT: begin
          if (rfc_done) begin
            // only a host REFRESH completes a front-end request; an
            // auto refresh must not ack the read/write still waiting
            req_done <= eng_ref_req;
            eng_ref_req <= 1'b0;
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
    else if (fe_err || ref_overrun) irq <= 1'b1;
  end

endmodule
