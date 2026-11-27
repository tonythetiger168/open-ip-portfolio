// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// LPDDR5X -- INDEPENDENT design IP #9/20.
// Architecture thesis: DVFS-era mobile controller. Two frequency-set-point
// latency files (FSP0: CL=22 / FSP1: CL=14); a write to the "FSP-OP"
// mailbox column (0xF1) switches the active file for all subsequent
// transactions (mid-flight bursts keep their latched latency). The
// mailbox write is a controller register write: no DRAM traffic, array
// and page state untouched. 8 banks, per-bank refresh rotation; commands
// reach the pins as framed beats on the 7-bit CA bus. Distinct from LPDDR4 (single frequency word)
// and LPDDR5 (ranks, no FSP). Self-contained; contract identical.
// The core holds no data: write words leave on dq, and the read word is
// taken from dq CL clocks after the RD command (the DRAM drives it).
// On top of the word commands:
//   * line commands: hcmd 5 RDL / 6 WRL move one 128-bit line (8 columns
//     {haddr[7:3], k}) in one BL8 burst (CA beat 0 bit 0 = 1 on the RD /
//     WR frame; 0 for a word); a WRL takes its 8 data beats on hwdata in
//     the 8 hvalid clocks after the command and drives them on dq CWL
//     clocks after the WR with dqs toggling every beat; an RDL takes the 8
//     beats the DRAM drives from CL clocks after the RD, passes each to
//     hrdata in its clock, pulses hdone with the last and holds the line
//     on rdline
//   * two mode-register sets, one per FSP (hcmd 7: haddr[3] = 0 MRW of
//     hwdata[7:0] to MR haddr[2:0] of the active set, 1 MRR into
//     hrdata[7:0] with an hdone pulse): CL = 10 + MR0[3:0], CWL = 5 +
//     MR1[3:0] of the active set, used by every RD / WR. Reset: FSP0 CL 22,
//     FSP1 CL 14, CWL 11 in both. MR0 bit 7 self-clears. The MR sets are
//     controller-side: the DRAM's own mode registers are set to match
//     outside this model. The FSP-OP mailbox (WR to column 0xF1) switches
//     the set, and with it CL / CWL
//   * WCK: wck_t / wck_c run (wck_t toggles every clock, starting low) from
//     the clock after the WR of a line through its last data beat, and rest
//     wck_t = 1 otherwise
// ============================================================================
module LPDDR5X_top #(
  parameter int NCH = 2
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic [127:0] rdline,          // line of the last RDL
  output logic        hdone,
  output logic        ck_t,
  output logic        ck_c,
  output logic [6:0]  ca,
  output logic        cs_n,
  output logic        wck_t,            // write clock: runs through a line write
  output logic        wck_c,
  inout  tri [NCH*16-1:0] dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  // internal DDR-style command bus; it reaches the pins as CA frames
  logic [16:0] addr;
  logic        ras_n, cas_n, we_n;
  logic [2:0]  ba;                    // bank of the command on the bus
  localparam int TRCD=14, TRP=14, TRC=46, TRAS=34, TRFC=140, TREFI=1560;
  // write timing: CAS write latency, data-bus clocks of one burst, write
  // recovery (end of the write burst to PRE) and write-to-read turnaround.
  // A WR is complete once it is on the pins; these fence what follows it.
  localparam int CWL=11, TBURST=8, TWR=14, TWTR=8;
  // CL / CWL come from the active MR set (cl_now / cwl_now). Write recovery
  // and write-to-read turnaround count from the WR: CWL + the burst (8
  // clocks, word or line) + tWR / tWTR.
  localparam int CHW = (NCH <= 2) ? 1 : $clog2(NCH);   // channel select: haddr[8 +: CHW]
  localparam int NB = 8;

  logic [13:0] open_row [0:NB-1];
  logic [NB-1:0] bank_open;
  logic [8:0] rp_t [0:NB-1], ras_t [0:NB-1], rc_t [0:NB-1];
  logic [8:0] timer;
  localparam int WTRW = 6;              // WR2RD <= 20 + 8 + 8
  logic [WTRW-1:0] wtr_t;              // WR-to-RD down-counter
  localparam int CCDW = $clog2(TBURST);
  logic [CCDW-1:0] ccd_t;              // CAS-to-CAS down-counter
  logic [13:0] ref_cnt;
  logic [2:0]  ref_bank;

  // FSP MR sets: FSP0 = high-performance, FSP1 = low-power
  logic fsp;
  logic [7:0]  mr [0:1][0:7];           // mr[fsp][index]
  wire  [4:0]  cl_now  = 5'd10 + {1'b0, mr[fsp][0][3:0]};
  wire  [4:0]  cwl_now = 5'd5 + {1'b0, mr[fsp][1][3:0]};
  wire  [8:0]  wr2pre  = 9'(cwl_now) + 9'(TBURST) + 9'(TWR);
  wire  [5:0]  wr2rd   = 6'(cwl_now) + 6'(TBURST) + 6'(TWTR);

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
  logic        pre_need;             // the command's bank was open: PRE it
  logic        auto_act, pre_done, ref_req;
  // line operations
  logic        line;                    // the command in flight is an RDL / WRL
  logic [2:0]  bcnt;                    // line beat
  logic [15:0] wbuf [0:7];              // WRL data beats
  logic        lw_oe, lw_s;             // line write burst on dq / dqs, strobe phase
  logic [15:0] lw_d;
  logic        mr_done;                 // MRR answered
  logic        wck_ph;                  // WCK phase while it runs
  wire  [7:0]  col_pin = line ? {cur_addr[7:3], 3'b000} : cur_addr[7:0];

  wire [2:0] a_bank = {a_ch, haddr[10:9]};
  wire [2:0] c_bank2 = {c_ch, cur_addr[10:9]};
  // per-bank timer-expired vectors: PRE waits tRAS, ACT waits tRP and tRC
  logic [NB-1:0] ras_z, rp_z;
  always_comb
    for (int i = 0; i < NB; i++) begin
      ras_z[i] = (ras_t[i] == 0); rp_z[i] = (rp_t[i] == 0);
    end
  wire [2:0] ref_prev = ref_bank - 1'b1;     // bank the running REFpb targets
  wire [2:0] ref_tgt  = ref_prev;
  wire [2:0] pre_tgt = ref_walk ? ref_tgt : cur_bank;
  wire pre_ok = ras_z[pre_tgt];
  wire rp_ok  = rp_z[pre_tgt];
  wire act_ok = rp_z[act_bank] && (rc_t[act_bank] == 0);
  wire rd_ok = (wtr_t == 0) && (ccd_t == 0);   // a RD may go on the pins now
  wire wr_ok = (ccd_t == 0);                   // a WR may go on the pins now
  wire a_hit = bank_open[a_bank] && (open_row[a_bank] == haddr[31:18]);
  wire c_hit = bank_open[cur_bank] && (open_row[cur_bank] == cur_addr[31:18]);

  assign ck_t = clk;  assign ck_c = ~clk;  assign cke = rst_n;
  assign dqs  = lw_oe ? {~lw_s, lw_s} : 2'bzz;
  assign wck_t = (dstate == D_LWR) ? wck_ph : 1'b1;
  assign wck_c = ~wck_t;
  // a due refresh goes first; a WRL takes its data beats in D_FILL
  assign hready = (dstate == D_IDLE) && (ref_cnt != 0) || (dstate == D_FILL);
  assign hdone  = (dstate == D_CAS) && (timer == 0) && rd_pending && !line ||
                  (dstate == D_LRD) && (bcnt == 3'd7) || mr_done;
  assign trace_valid = (dstate == D_ACT && act_ok) || (dstate == D_RD && rd_ok) || (dstate == D_WR && wr_ok);
  assign trace_cmd   = (dstate == D_ACT) ? 3'd1 : (dstate == D_RD) ? 3'd2 : 3'd3;
  assign trace_addr  = cur_addr;
  // each channel owns dq[16*g +: 16]; only the addressed one drives a write
  for (genvar g = 0; g < NCH; g++) begin : g_dq
    assign dq[16*g +: 16] = (dstate == D_WR && wr_ok && !line && c_ch == g) ? wr_data :
                            (lw_oe && c_ch == g) ? lw_d : 16'hzzzz;
  end

  // ---- CA bus. Each command goes out as a frame of 7-bit beats: beat 0
  // (cs_n low) = {code, bank, BL}, code 1 ACT, 2 RD, 3 WR, 4 PRE, 6 REF, BL
  // = 1 for the RD / WR of a line (BL8 line burst), else 0;
  // then the row (ACT, 2 beats) or column (RD / WR, 2 beats) follows
  // LSB first with cs_n high. PRE and REF are one beat (per-bank).
  wire [2:0] ca_code = ({ras_n, cas_n, we_n} == 3'b011) ? 3'd1 :
                       ({ras_n, cas_n, we_n} == 3'b101) ? 3'd2 :
                       ({ras_n, cas_n, we_n} == 3'b100) ? 3'd3 :
                       ({ras_n, cas_n, we_n} == 3'b010) ? 3'd4 :
                       ({ras_n, cas_n, we_n} == 3'b001) ? 3'd6 : 3'd0;
  logic [13:0] ca_sh;                  // payload still to send
  logic [1:0]  ca_left;               // payload beats still to send
  assign cs_n = (ca_code == 3'd0);
  wire   ca_bl = (ca_code == 3'd2 || ca_code == 3'd3) && addr[12];
  assign ca   = !cs_n ? {ca_code, ba, ca_bl} : (ca_left != 0) ? ca_sh[6:0] : '0;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin ca_sh <= '0; ca_left <= '0; end
    else if (!cs_n) begin
      ca_sh   <= (ca_code == 3'd1) ? addr[13:0] : {6'b0, addr[7:0]};
      ca_left <= (ca_code == 3'd1) ? 2'd2 : (ca_code == 3'd2 || ca_code == 3'd3) ? 2'd2 : '0;
    end else if (ca_left != 0) begin
      ca_sh <= ca_sh >> 7; ca_left <= ca_left - 1'b1;
    end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; wtr_t <= '0; ccd_t <= '0; ref_cnt <= TREFI[13:0];
      auto_act <= 1'b0; pre_done <= 1'b0; ref_req <= 1'b0;
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0;
      ref_walk <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0; pre_need <= 1'b0;
      cur_bank <= '0; act_bank <= '0; ref_bank <= '0; fsp <= 1'b0;
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1; addr <= '0; ba <= '0; hrdata <= '0;
      line <= 1'b0; bcnt <= '0; lw_oe <= 1'b0; lw_s <= 1'b0; lw_d <= '0; mr_done <= 1'b0;
      rdline <= '0; wck_ph <= 1'b0;
      for (int i = 0; i < 8; i++) begin wbuf[i] <= '0; mr[0][i] <= '0; mr[1][i] <= '0; end
      mr[0][0] <= 8'd12; mr[0][1] <= 8'(CWL - 5);    // FSP0: CL 22, CWL 11
      mr[1][0] <= 8'd4;  mr[1][1] <= 8'(CWL - 5);    // FSP1: CL 14, CWL 11
      for (int i = 0; i < NB; i++) begin
        open_row[i] <= '0; bank_open[i] <= 1'b0;
        rp_t[i] <= '0; ras_t[i] <= '0; rc_t[i] <= '0;
      end
    end else begin
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;   // commands are 1-cycle pulses
      mr_done <= 1'b0;
      wck_ph <= (dstate == D_LWR) ? ~wck_ph : 1'b0;
      if (dstate != D_PRE) pre_done <= 1'b0;
      if (timer != 0) timer <= timer - 1'b1;
      if (wtr_t != 0) wtr_t <= wtr_t - 1'b1;
      if (ccd_t != 0) ccd_t <= ccd_t - 1'b1;
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
            auto_rd <= 1'b0; auto_wr <= 1'b0; pre_need <= bank_open[a_bank];
            line <= (hcmd == 3'd5) || (hcmd == 3'd6);
            if (hcmd == 3'd3 && haddr[7:0] == 8'hF1)
              fsp <= hwdata[0];                  // FSP-OP mailbox: no DRAM traffic
            else case (hcmd)
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
              3'd7: begin                                      // MRW / MRR, active set
                if (haddr[3]) begin
                  hrdata <= {8'h00, mr[fsp][haddr[2:0]]}; mr_done <= 1'b1;
                end else
                  mr[fsp][haddr[2:0]] <= (haddr[2:0] == 3'd0) ? {1'b0, hwdata[6:0]} : hwdata[7:0];
              end
              3'd4: begin
                if (bank_open[a_bank]) begin bank_open[a_bank] <= 1'b0; dstate <= D_PRE; end
              end
              default: ;
            endcase
          end else if (ref_cnt == 0) begin
            ref_walk <= 1'b1; ref_cnt <= TREFI[13:0];
            if (bank_open[ref_bank]) begin
              bank_open[ref_bank] <= 1'b0; rp_t[ref_bank] <= 9'(TRP - 1);
            end
            pre_need <= bank_open[ref_bank];  // PRE the bank only if it is open
            ref_bank <= ref_bank + 1'b1;
            dstate <= D_PRE;
          end
        end
        D_PRE: begin
          if (ref_req) begin
            // refresh fell due while the host kept the FSM busy: start it
            // here, since taking it in D_IDLE would drop a command
            ref_req <= 1'b0; pre_done <= 1'b0;
            ref_walk <= 1'b1; ref_cnt <= TREFI[13:0];
            if (bank_open[ref_bank]) begin
              bank_open[ref_bank] <= 1'b0; rp_t[ref_bank] <= 9'(TRP - 1);
            end
            pre_need <= bank_open[ref_bank];  // PRE the bank only if it is open
            ref_bank <= ref_bank + 1'b1;
            dstate <= D_PRE;
          end else if (!pre_done) begin
            // PRE/PREA waits for tRAS, and tRP counts from the real issue
            if (!pre_need) pre_done <= 1'b1;   // bank already closed
            else if (pre_ok) begin
              ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0; addr[10] <= 1'b0; ba <= pre_tgt;
              rp_t[pre_tgt] <= 9'(TRP - 1);
              pre_done <= 1'b1;
            end
          end else begin
            if (ref_walk) begin                 // REF once tRP is met
              if (rp_ok) begin
                ras_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b1; ba <= ref_tgt;
                rp_t[ref_tgt] <= 9'(TRFC - 1);   // per-entry refresh: only this entry
                ref_walk <= 1'b0; dstate <= D_IDLE;   // waits tRFC (its next ACT / REF waits rp_t)
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
            ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b1; ba <= act_bank;
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
            if (auto_rd)  begin auto_rd <= 1'b0; dstate <= D_RD; end
            else if (auto_wr)  begin auto_wr <= 1'b0; dstate <= D_WR; end
            else begin ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE; end
          end
        end
        D_RD: if (rd_ok) begin              // tWTR and tCCD met
          cas_n <= 1'b0; we_n <= 1'b1; ba <= cur_bank;
          addr <= {4'b0, line, 4'b0, col_pin};          // addr[12]: CA BL bit
          ccd_t <= CCDW'(TBURST - 1);
          dstate <= D_CAS; timer <= 9'(cl_now);
        end
        D_WR: if (wr_ok) begin
          cas_n <= 1'b0; we_n <= 1'b0; ba <= cur_bank;
          addr <= {4'b0, line, 4'b0, col_pin};
          // complete once on the pins: D_CAS exits next clock (no CL wait);
          // a WRL drives its burst CWL clocks later (D_LWR)
          ras_t[cur_bank] <= wr2pre - 9'd1;   // WR2PRE > tRAS - tRCD: never shorter than tRAS
          wtr_t <= wr2rd - 6'd1; ccd_t <= CCDW'(TBURST - 1);
          if (line) begin timer <= 9'(cwl_now); bcnt <= '0; dstate <= D_LWR; end
          else begin dstate <= D_CAS; timer <= '0; end
        end
        D_CAS: begin
          cas_n <= 1'b1; we_n <= 1'b1;
          if (timer == 0) begin
            if (rd_pending) hrdata <= dq[16*c_ch +: 16];   // the device's read word
            if (line) begin                // RDL: beat 0, then 7 more in D_LRD
              rdline[15:0] <= dq[16*c_ch +: 16]; bcnt <= 3'd1; dstate <= D_LRD;
            end else begin
              rd_pending <= 1'b0;
              ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE;
            end
          end
        end
        D_LRD: begin                       // RDL beats 1..7, one per clock
          hrdata <= dq[16*c_ch +: 16];
          rdline[16*bcnt +: 16] <= dq[16*c_ch +: 16];
          bcnt <= bcnt + 3'd1;
          if (bcnt == 3'd7) begin
            rd_pending <= 1'b0;
            ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE;
          end
        end
        D_FILL: if (hvalid) begin          // WRL data beat bcnt
          wbuf[bcnt] <= hwdata;
          bcnt <= bcnt + 3'd1;
          if (bcnt == 3'd7) begin
            pre_need <= bank_open[cur_bank];
            if (!c_hit) begin
              act_bank <= cur_bank;
              open_row[cur_bank] <= cur_addr[31:18]; bank_open[cur_bank] <= 1'b1;
              auto_wr <= 1'b1;
              if (bank_open[cur_bank]) dstate <= D_PRE; else dstate <= D_ACT;
            end else dstate <= D_WR;
          end
        end
        D_LWR: begin                       // WRL burst: beat k on dq in clock WR + CWL + k
          if (!lw_oe) begin
            if (timer == 1) begin lw_oe <= 1'b1; lw_s <= ~lw_s; lw_d <= wbuf[0]; bcnt <= 3'd1; end
          end else if (bcnt != 3'd0) begin
            lw_s <= ~lw_s; lw_d <= wbuf[bcnt]; bcnt <= bcnt + 3'd1;
          end else begin                   // the 8th beat went out last clock
            lw_oe <= 1'b0;
            ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE;
          end
        end
        default: dstate <= D_IDLE;
      endcase
    end
  end
endmodule
