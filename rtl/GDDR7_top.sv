// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// GDDR7 -- INDEPENDENT design IP #14/20.
// Architecture thesis: PAM3 signaling. Read data returns from the DRAM on
// the channel's dq lanes as 12 ternary symbols, 3 per nibble (v = 9*t0 +
// 3*t1 + t2, so 16 of the 27 symbol triples are legal), over two beats: the
// clock before hdone carries nibbles 0-1, the hdone clock nibbles 2-3; the
// controller captures both beats and decodes them into hrdata. A symbol is a
// 2-bit level code on a pin pair (00 / 01 / 10 = levels 0 / 1 / 2; 11 never
// appears), on dq[11:0]; dq[15:12] stay Hi-Z. Writes stay NRZ on
// dq[ch*16 +: 16]. 4 banks per channel ({ch,haddr[10:9]}), all-bank
// refresh, CL=18. Word commands as DDR_top. The core holds no data:
// write words leave on dq, read words come back from the DRAM.
// On top of the word commands (as DDR4_top):
//   * line commands: hcmd 5 RDL / 6 WRL move one 128-bit line (the 8
//     columns {haddr[7:3], k}) in one burst (addr[12] = 1 on the RD / WR).
//     PAM2 (MR2[0] = 0): BL8 of 16-bit NRZ beats on the channel's dq. PAM3
//     (MR2[0] = 1): BL6, each of the channel's 16 dq pins carrying one
//     ternary symbol per beat as the level code {dqx[p], dq[p]} (00 / 01 /
//     10): the line's 32 nibbles as 96 trits (nibble k = trits 3k..3k+2,
//     v = 9*t0 + 3*t1 + t2), beat b = trits 16b..16b+15. A WRL takes its
//     8 data beats on hwdata in the 8 hvalid clocks after the command and
//     drives the burst CWL clocks after the WR, dqs toggling every beat; an
//     RDL takes the DRAM's burst from CL clocks after the RD: PAM2 passes
//     each beat to hrdata in its clock and pulses hdone with the last, PAM3
//     decodes the line with the last beat (hrdata = word 7, hdone then);
//     rdline holds the line
//   * mode-register file MR0..MR7 (hcmd 7: haddr[3] = 0 MRW of hwdata[7:0],
//     1 MRR into hrdata[7:0] with an hdone pulse): CL = 5 + MR0[3:0],
//     CWL = 5 + MR1[3:0], MR2[0] = PAM3 (reset 1: word reads in PAM3 as
//     above; MR2[0] = 0 sends a read word NRZ in the second beat), pin pam3;
//     MR0 bit 7 is a self-clearing DLL reset. Controller-side: the DRAM's
//     own mode registers are set to match outside this model
//   * command pins: cs_n (high = deselect), act_n (ACT: low, with ras_n /
//     cas_n / we_n = 0), ba = bank entry {channel, bank}
// ============================================================================
module GDDR7_top #(
  parameter int NCH = 2
)(
  input  logic        clk, rst_n, hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic [127:0] rdline,          // line of the last RDL
  output logic        hdone,
  output logic        pam3,             // line signaling mode (MR2[0])
  output logic        ck_t, ck_c,
  output logic [16:0] addr,
  output logic        cs_n, act_n,
  output logic [2:0]  ba,
  output logic        ras_n, cas_n, we_n,
  inout  tri [NCH*16-1:0] dq,
  inout  tri [NCH*16-1:0] dqx,          // PAM3 lines: upper level bit of each dq pin
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  localparam int CL=18, TRCD=15, TRP=15, TRC=46, TRAS=32, TRFC=150, TREFI=3900;
  // write timing: CAS write latency, data-bus clocks of one burst, write
  // recovery (end of the write burst to PRE) and write-to-read turnaround.
  // A WR is complete once it is on the pins; these fence what follows it.
  localparam int CWL=7, TBURST=2, TWR=15, TWTR=7;
  // CL / CWL come from the MR file; write recovery / turnaround count from
  // the WR: CWL + the burst (TBURST for a word, 8 / 6 beats for a PAM2 /
  // PAM3 line) + tWR / tWTR.
  localparam int CHW = (NCH <= 2) ? 1 : $clog2(NCH);   // channel select: haddr[8 +: CHW]
  localparam int NB = 8;

  logic [13:0] open_row [0:NB-1];
  logic [NB-1:0] bank_open;
  logic [8:0] rp_t [0:NB-1], ras_t [0:NB-1], rc_t [0:NB-1];
  logic [8:0] timer;
  localparam int WTRW = 6;              // WR2RD <= 20 + 8 + 7
  logic [WTRW-1:0] wtr_t;              // WR-to-RD down-counter
  logic [13:0] ref_cnt;

  typedef enum logic [3:0] {D_IDLE, D_ACT, D_RCD, D_RD, D_CAS, D_WR, D_PRE,
                            D_FILL, D_LRD, D_LWR} d_t;
  d_t dstate;
  logic [31:0] cur_addr;
  // channel of the incoming / current command (NCH==1 ignores haddr[8],
  // as the MEMCH wrapper on main did)
  wire [CHW-1:0] a_ch = (NCH == 1) ? '0 : haddr[8 +: CHW];
  wire [CHW-1:0] c_ch = (NCH == 1) ? '0 : cur_addr[8 +: CHW];
  logic [15:0] wr_data;
  logic [2:0]  cur_bank, act_bank;
  logic        rd_pending, ref_walk, auto_rd, auto_wr;
  logic        auto_act, pre_done, ref_req;
  // line operations and the MR file
  logic        line, lpam3;             // an RDL / WRL in flight, its signaling mode
  logic [2:0]  bcnt;                    // line beat
  logic [15:0] wbuf [0:7];              // WRL data beats
  logic        lw_oe, lw_s;             // line write burst on dq / dqs, strobe phase
  logic [31:0] lw_d;                    // {dqx, dq} of the beat
  logic [159:0] rsym;                   // PAM3 RDL: symbols of beats 0..4
  logic        mr_done;                 // MRR answered
  logic [7:0]  mr [0:7];
  wire  [4:0]  cl_now  = 5'd5 + {1'b0, mr[0][3:0]};
  wire  [4:0]  cwl_now = 5'd5 + {1'b0, mr[1][3:0]};
  assign pam3 = mr[2][0];
  wire  [3:0]  wr_bl   = !line ? 4'(TBURST) : lpam3 ? 4'd6 : 4'd8;
  wire  [8:0]  wr2pre  = 9'(cwl_now) + 9'(wr_bl) + 9'(TWR);
  wire  [5:0]  wr2rd   = 6'(cwl_now) + 6'(wr_bl) + 6'(TWTR);
  wire  [7:0]  col_pin = line ? {cur_addr[7:3], 3'b000} : cur_addr[7:0];
  wire  [2:0]  lastb   = lpam3 ? 3'd5 : 3'd7;   // last beat of the line burst

  wire [2:0] a_bank = {a_ch, haddr[10:9]};
  wire [2:0] c_bank2 = {c_ch, cur_addr[10:9]};
  // per-bank timer-expired vectors: PRE waits tRAS, ACT waits tRP and tRC
  logic [NB-1:0] ras_z, rp_z;
  always_comb
    for (int i = 0; i < NB; i++) begin
      ras_z[i] = (ras_t[i] == 0); rp_z[i] = (rp_t[i] == 0);
    end
  wire [2:0] pre_tgt = ref_walk ? cur_bank : cur_bank;
  wire pre_ok = ref_walk ? &ras_z : ras_z[pre_tgt];
  wire rp_ok  = ref_walk ? &rp_z  : rp_z[pre_tgt];
  wire act_ok = rp_z[act_bank] && (rc_t[act_bank] == 0);
  wire a_hit = bank_open[a_bank] && (open_row[a_bank] == haddr[31:18]);
  wire c_hit = bank_open[c_bank2] && (open_row[c_bank2] == cur_addr[31:18]);
  // a RD may go on the pins once tWTR is met. tCCD = TBURST = 2 never binds:
  // the single engine spaces two CAS commands by 3 clocks or more (the
  // checker still checks it).
  wire rd_ok = (wtr_t == 0);

  // PAM3: 12 symbols (4 nibbles x 3, 2-bit level codes) -> 16-bit word,
  // nibble n = 9*t0 + 3*t1 + t2 from symbols [6n +: 2], [6n+2 +: 2], [6n+4 +: 2]
  function automatic [15:0] dec_pam3(input [23:0] t);
    logic [15:0] w;
    begin
      for (int n = 0; n < 4; n++)
        w[4*n +: 4] = 4'(5'd9 * t[6*n +: 2] + 5'd3 * t[6*n+2 +: 2] + t[6*n+4 +: 2]);
      dec_pam3 = w;
    end
  endfunction

  // PAM3 line <-> symbols: nibble k = trits t0, t1, t2 at [6k +: 2], [6k+2 +: 2],
  // [6k+4 +: 2] (as the word reads)
  function automatic [5:0] enc_nib(input [3:0] v);    // {t2, t1, t0}: t0 in the low bits
    case (v)
      4'd0:  enc_nib = 6'b00_00_00;  4'd1:  enc_nib = 6'b01_00_00;
      4'd2:  enc_nib = 6'b10_00_00;  4'd3:  enc_nib = 6'b00_01_00;
      4'd4:  enc_nib = 6'b01_01_00;  4'd5:  enc_nib = 6'b10_01_00;
      4'd6:  enc_nib = 6'b00_10_00;  4'd7:  enc_nib = 6'b01_10_00;
      4'd8:  enc_nib = 6'b10_10_00;  4'd9:  enc_nib = 6'b00_00_01;
      4'd10: enc_nib = 6'b01_00_01;  4'd11: enc_nib = 6'b10_00_01;
      4'd12: enc_nib = 6'b00_01_01;  4'd13: enc_nib = 6'b01_01_01;
      4'd14: enc_nib = 6'b10_01_01;  default: enc_nib = 6'b00_10_01;   // 15
    endcase
  endfunction
  function automatic [191:0] pack_line(input [127:0] d);
    for (int k = 0; k < 32; k++) pack_line[6*k +: 6] = enc_nib(d[4*k +: 4]);
  endfunction
  function automatic [127:0] unpack_line(input [191:0] t);
    for (int k = 0; k < 32; k++)
      unpack_line[4*k +: 4] = 4'(5'd9 * t[6*k +: 2] + 5'd3 * t[6*k+2 +: 2] + t[6*k+4 +: 2]);
  endfunction
  // beat b of a PAM3 line: symbol j = trit 16b + j on pin j as {dqx[j], dq[j]}
  function automatic [31:0] sym_pins(input [31:0] t);   // 16 2-bit codes -> {dqx, dq}
    for (int j = 0; j < 16; j++) begin sym_pins[16 + j] = t[2*j+1]; sym_pins[j] = t[2*j]; end
  endfunction
  function automatic [31:0] pins_sym(input [15:0] x, input [15:0] d);
    for (int j = 0; j < 16; j++) pins_sym[2*j +: 2] = {x[j], d[j]};
  endfunction
  wire [127:0] wline = {wbuf[7], wbuf[6], wbuf[5], wbuf[4], wbuf[3], wbuf[2], wbuf[1], wbuf[0]};
  wire [191:0] wsym  = pack_line(wline);
  wire [31:0]  r_sym = pins_sym(dqx[16*c_ch +: 16], dq[16*c_ch +: 16]);
  wire [127:0] rdec  = unpack_line({r_sym, rsym});

  wire rd_phase = (dstate == D_CAS) && (timer == 0) && rd_pending && !line;   // beat 1
  wire rd_beat0 = (dstate == D_CAS) && (timer == 1) && rd_pending && !line;
  logic [11:0] rd_b0;                 // symbols of beat 0 (nibbles 0-1)
  assign ck_t = clk;  assign ck_c = ~clk;  assign cke = rst_n;
  assign dqs  = lw_oe ? {~lw_s, lw_s} : 2'bzz;
  // a due refresh goes first; a WRL takes its data beats in D_FILL
  assign hready = (dstate == D_IDLE) && (ref_cnt != 0) || (dstate == D_FILL);
  assign hdone  = rd_phase || (dstate == D_LRD) && (bcnt == lastb) || mr_done;
  assign trace_valid = (dstate == D_ACT && act_ok) || (dstate == D_RD && rd_ok) || (dstate == D_WR);
  assign trace_cmd   = (dstate == D_ACT) ? 3'd1 : (dstate == D_RD) ? 3'd2 : 3'd3;
  assign trace_addr  = cur_addr;
  // each channel owns dq[16*g +: 16]; only the addressed one drives
  for (genvar g = 0; g < NCH; g++) begin : g_dq
    assign dq[16*g +: 16]  = (c_ch == g && dstate == D_WR && !line) ? wr_data :
                             (c_ch == g && lw_oe) ? lw_d[15:0] : 16'hzzzz;
    assign dqx[16*g +: 16] = (c_ch == g && lw_oe && lpam3) ? lw_d[31:16] : 16'hzzzz;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; wtr_t <= '0; ref_cnt <= TREFI[13:0];
      auto_act <= 1'b0; pre_done <= 1'b0; ref_req <= 1'b0;
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0; rd_b0 <= '0;
      ref_walk <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0;
      cur_bank <= '0; act_bank <= '0;
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1; addr <= '0; hrdata <= '0;
      cs_n <= 1'b1; act_n <= 1'b1; ba <= '0;
      line <= 1'b0; lpam3 <= 1'b0; bcnt <= '0; lw_oe <= 1'b0; lw_s <= 1'b0; lw_d <= '0;
      mr_done <= 1'b0; rdline <= '0; rsym <= '0;
      for (int i = 0; i < 8; i++) begin wbuf[i] <= '0; mr[i] <= '0; end
      mr[0] <= 8'(CL - 5); mr[1] <= 8'(CWL - 5); mr[2] <= 8'h01;
      for (int i = 0; i < NB; i++) begin
        open_row[i] <= '0; bank_open[i] <= 1'b0;
        rp_t[i] <= '0; ras_t[i] <= '0; rc_t[i] <= '0;
      end
    end else begin
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;   // commands are 1-cycle pulses
      cs_n <= 1'b1; act_n <= 1'b1; mr_done <= 1'b0;
      if (dstate != D_PRE) pre_done <= 1'b0;
      if (timer != 0) timer <= timer - 1'b1;
      if (wtr_t != 0) wtr_t <= wtr_t - 1'b1;
      if (ref_cnt != 0) ref_cnt <= ref_cnt - 1'b1;
      for (int i = 0; i < NB; i++) begin
        if (rp_t[i]  != 0) rp_t[i]  <= rp_t[i]  - 1'b1;
        if (ras_t[i] != 0) ras_t[i] <= ras_t[i] - 1'b1;
        if (rc_t[i]  != 0) rc_t[i]  <= rc_t[i]  - 1'b1;
      end
      case (dstate)
        D_IDLE: begin
          ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
          if (hvalid && ref_cnt != 0) begin
            cur_addr <= haddr; wr_data <= hwdata; cur_bank <= a_bank;
            rd_pending <= (hcmd == 3'd2) || (hcmd == 3'd5); ref_walk <= 1'b0; auto_act <= 1'b0;
            auto_rd <= 1'b0; auto_wr <= 1'b0;
            line <= (hcmd == 3'd5) || (hcmd == 3'd6); lpam3 <= pam3;
            case (hcmd)
              3'd1: begin
                act_bank <= a_bank;
                if (a_hit) ;                     // page already open: nothing to do
                else if (bank_open[a_bank] && (open_row[a_bank] != haddr[31:18])) begin
                  rp_t[a_bank] <= 9'(TRP - 1);      // conflict: PRE, then ACT the new row
                  open_row[a_bank] <= haddr[31:18]; auto_act <= 1'b1;
                  dstate <= D_PRE;
                end else begin
                  open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                  dstate <= D_ACT;
                end
              end
              3'd2, 3'd3, 3'd5: begin
                if (!a_hit) begin
                  act_bank <= a_bank;
                  open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                  auto_rd <= (hcmd != 3'd3); auto_wr <= (hcmd == 3'd3);
                  // a closed bank needs no PRE: straight to its ACT
                  if (bank_open[a_bank]) dstate <= D_PRE; else dstate <= D_ACT;
                end else if (hcmd == 3'd3) dstate <= D_WR; else dstate <= D_RD;
              end
              3'd6: begin bcnt <= '0; dstate <= D_FILL; end   // WRL: its 8 data beats first
              3'd7: begin                                      // MRW / MRR
                if (haddr[3]) begin
                  hrdata <= {8'h00, mr[haddr[2:0]]}; mr_done <= 1'b1;
                end else
                  mr[haddr[2:0]] <= (haddr[2:0] == 3'd0) ? {1'b0, hwdata[6:0]} : hwdata[7:0];
              end
              3'd4: begin
                if (bank_open[a_bank]) begin bank_open[a_bank] <= 1'b0; dstate <= D_PRE; end
              end
              default: ;
            endcase
          end else if (ref_cnt == 0) begin
            ref_walk <= 1'b1; ref_cnt <= TREFI[13:0];
            for (int i = 0; i < NB; i++) begin
              bank_open[i] <= 1'b0; rp_t[i] <= 9'(TRP - 1);
            end
            dstate <= D_PRE;
          end
        end
        D_PRE: begin
          if (ref_req) begin
            // refresh fell due while the host kept the FSM busy: start it
            // here, since taking it in D_IDLE would drop a command
            ref_req <= 1'b0; pre_done <= 1'b0;
            ref_walk <= 1'b1; ref_cnt <= TREFI[13:0];
            for (int i = 0; i < NB; i++) begin
              bank_open[i] <= 1'b0; rp_t[i] <= 9'(TRP - 1);
            end
            dstate <= D_PRE;
          end else if (!pre_done) begin
            // PRE/PREA waits for tRAS, and tRP counts from the real issue
            // (only an open bank or a refresh gets here: a closed one goes
            // straight to D_ACT)
            if (pre_ok) begin
              cs_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0; addr[10] <= ref_walk;
              ba <= ref_walk ? 3'b000 : pre_tgt;
              if (ref_walk) for (int i = 0; i < NB; i++) rp_t[i] <= 9'(TRP - 1);
              else rp_t[pre_tgt] <= 9'(TRP - 1);
              pre_done <= 1'b1;
            end
          end else begin
            if (ref_walk) begin                 // REF once tRP is met
              if (rp_ok) begin
                cs_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b1; ba <= 3'b000;
                timer <= 9'(TRFC - 3); dstate <= D_RCD;
              end
            end
            else if (auto_rd || auto_wr || auto_act) dstate <= D_ACT;   // D_ACT waits tRP
            else begin                      // plain PRE: tRP is enforced at the next ACT
              ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE;
            end
          end
        end
        D_ACT: begin
          if (act_ok) begin                 // tRP and tRC met for this bank
            cs_n <= 1'b0; act_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b0;
            ba <= act_bank;
            addr <= {3'b0, open_row[act_bank]};
            ras_t[act_bank] <= 9'(TRAS - 1); rc_t[act_bank] <= 9'(TRC - 1);
            timer <= 9'(TRCD - 2);
            dstate <= D_RCD;
            auto_act <= 1'b0;
          end
        end
        D_RCD: begin
          ras_n <= 1'b1;
          if (timer == 0) begin
            if (ref_walk)      begin ref_walk <= 1'b0; dstate <= D_IDLE; end
            else if (auto_rd)  begin auto_rd <= 1'b0; dstate <= D_RD; end
            else if (auto_wr)  begin auto_wr <= 1'b0; dstate <= D_WR; end
            else begin ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE; end
          end
        end
        D_RD: if (rd_ok) begin              // tWTR and tCCD met
          cs_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b1; ba <= cur_bank;
          addr <= {4'b0, line, 4'b0, col_pin};          // addr[12]: line burst
          dstate <= D_CAS; timer <= 9'(cl_now);
        end
        D_WR: begin
          cs_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b0; ba <= cur_bank;
          addr <= {4'b0, line, 4'b0, col_pin};
          // a word is complete once on the pins: D_CAS exits next clock (no
          // CL wait); a WRL drives its burst CWL clocks later (D_LWR)
          ras_t[cur_bank] <= wr2pre - 9'd1;   // WR2PRE > tRAS - tRCD: never shorter than tRAS
          wtr_t <= wr2rd - 6'd1;
          if (line) begin timer <= 9'(cwl_now); bcnt <= '0; dstate <= D_LWR; end
          else begin dstate <= D_CAS; timer <= '0; end
        end
        D_CAS: begin
          cas_n <= 1'b1; we_n <= 1'b1;
          if (rd_beat0) rd_b0 <= dq[16*c_ch +: 12];
          if (timer == 0) begin
            if (line) begin                // RDL: beat 0, then the rest in D_LRD
              if (!lpam3) begin hrdata <= dq[16*c_ch +: 16]; rdline[15:0] <= dq[16*c_ch +: 16]; end
              else rsym[31:0] <= r_sym;
              bcnt <= 3'd1; dstate <= D_LRD;
            end else begin
              if (rd_pending) hrdata <= pam3 ? dec_pam3({dq[16*c_ch +: 12], rd_b0}) : dq[16*c_ch +: 16];
              rd_pending <= 1'b0;
              ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE;
            end
          end
        end
        D_LRD: begin                       // RDL beats 1..7 (PAM2) / 1..5 (PAM3)
          bcnt <= bcnt + 3'd1;
          if (!lpam3) begin
            hrdata <= dq[16*c_ch +: 16];
            rdline[16*bcnt +: 16] <= dq[16*c_ch +: 16];
          end else if (bcnt != 3'd5) rsym[32*bcnt +: 32] <= r_sym;
          if (bcnt == lastb) begin
            if (lpam3) begin rdline <= rdec; hrdata <= rdec[127:112]; end
            rd_pending <= 1'b0;
            ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE;
          end
        end
        D_FILL: if (hvalid) begin          // WRL data beat bcnt
          wbuf[bcnt] <= hwdata;
          bcnt <= bcnt + 3'd1;
          if (bcnt == 3'd7) begin
            if (!c_hit) begin
              act_bank <= cur_bank;
              open_row[cur_bank] <= cur_addr[31:18]; bank_open[cur_bank] <= 1'b1;
              auto_wr <= 1'b1;
              if (bank_open[cur_bank]) dstate <= D_PRE; else dstate <= D_ACT;
            end else dstate <= D_WR;
          end
        end
        D_LWR: begin                       // WRL burst: beat k on the pins in clock WR + CWL + k
          if (!lw_oe) begin
            if (timer == 1) begin
              lw_oe <= 1'b1; lw_s <= ~lw_s; bcnt <= 3'd1;
              lw_d <= lpam3 ? sym_pins(wsym[31:0]) : {16'h0, wbuf[0]};
            end
          end else if (bcnt != 3'd0 && bcnt <= lastb) begin
            lw_s <= ~lw_s; bcnt <= bcnt + 3'd1;
            lw_d <= lpam3 ? sym_pins(wsym[32*bcnt +: 32]) : {16'h0, wbuf[bcnt]};
          end else begin                   // the last beat went out last clock
            lw_oe <= 1'b0;
            ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE;
          end
        end
        default: dstate <= D_IDLE;
      endcase
    end
  end
endmodule
