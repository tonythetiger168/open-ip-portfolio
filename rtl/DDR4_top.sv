// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DDR4 -- INDEPENDENT design IP #2/20.
// Architecture thesis: the classic 4-bank open-page controller, in-order
// single engine. Banks indexed by {ch, haddr[10:9]}; per-bank open-row with
// miss-detect (auto PRE+ACT); all-bank refresh; AL=0; fixed BL. This is the
// family baseline every other IP differentiates from.
// External contract: the DDR (legacy) word commands -- see DDR_top header,
// except that the core holds no data: write words leave on dq, and the read
// word is taken from dq CL clocks after the RD command (the DRAM drives it).
// On top of the word commands (each a BC4 burst-chop access, A12 = 0):
//   * line commands: hcmd 5 RDL / 6 WRL move one 128-bit line (8 columns
//     {haddr[7:3], k}) in one BL8 burst (A12 = BC_n = 1); a WRL takes its 8
//     data beats on hwdata in the 8 hvalid clocks after the command, drives
//     them on dq CWL clocks after the WR with dqs toggling every beat; an RDL
//     takes the 8 beats the DRAM drives from CL clocks after the RD, passes
//     each to hrdata in its clock, pulses hdone with the last and holds the
//     line on rdline
//   * mode-register file MR0..MR7 (hcmd 7: haddr[3] = 0 MRW of hwdata[7:0],
//     1 MRR into hrdata[7:0] with an hdone pulse): CL = 5 + MR0[3:0],
//     CWL = 5 + MR1[3:0] (reset to the CL / CWL parameters), used by every
//     RD / WR; MR0 bit 7 is a self-clearing DLL reset. The MR file is
//     controller-side: the DRAM's own mode registers are set to match by
//     initialization outside this model
//   * DDR4 command pins: cs_n (high = deselect), act_n (ACT: low, with
//     ras_n / cas_n / we_n carrying row bits A16..A14 = 0), ba = bank
// ============================================================================
module DDR4_top #(
  parameter int NCH = 1
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
  output logic [16:0] addr,
  output logic        cs_n,
  output logic        act_n,
  output logic [1:0]  ba,
  output logic        ras_n,
  output logic        cas_n,
  output logic        we_n,
  inout  tri [NCH*16-1:0] dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  localparam int CL=15, TRCD=14, TRP=14, TRC=45, TRAS=32, TRFC=160, TREFI=6240;
  // write timing: CAS write latency, write recovery (end of the write burst
  // to PRE), write-to-read turnaround and CAS-to-CAS spacing (a BL8 burst
  // holds the data bus 4 clocks)
  localparam int CWL=11, TWR=16, TWTR=8, TCCD=4;
  // CL / CWL come from the MR file (cl_now / cwl_now). Write recovery and
  // write-to-read turnaround count from the WR command: CWL + the burst
  // (BC4 = 4 clocks of BL8 timing, a BL8 line = 8 SDR beats) + tWR / tWTR.
  localparam int CHW = (NCH <= 2) ? 1 : $clog2(NCH);   // channel select: haddr[8 +: CHW]
  localparam int NB = 4 * NCH;          // 4 banks per channel

  logic [13:0] open_row [0:NB-1];
  logic [NB-1:0] bank_open;
  logic [8:0] rp_t [0:NB-1], ras_t [0:NB-1], rc_t [0:NB-1];
  logic [8:0] timer;
  localparam int WTRW = 6, CCDW = $clog2(TCCD);   // WR2RD <= 20 + 8 + 8
  logic [WTRW-1:0] wtr_t;              // WR-to-RD down-counter
  logic [CCDW-1:0] ccd_t;              // CAS-to-CAS down-counter
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
  logic        rd_pending, ref_walk;
  logic        auto_act, pre_done, ref_req;
  logic        auto_rd, auto_wr;
  // line operations and the MR file
  logic        line;                    // the command in flight is an RDL / WRL
  logic [2:0]  bcnt;                    // line beat
  logic [15:0] wbuf [0:7];              // WRL data beats
  logic        lw_oe, lw_s;             // line write burst on dq / dqs, strobe phase
  logic [15:0] lw_d;
  logic        mr_done;                 // MRR answered
  logic [7:0]  mr [0:7];
  wire  [4:0]  cl_now  = 5'd5 + {1'b0, mr[0][3:0]};
  wire  [4:0]  cwl_now = 5'd5 + {1'b0, mr[1][3:0]};
  wire  [5:0]  wr_bl   = line ? 6'd8 : 6'd4;
  wire  [8:0]  wr2pre  = 9'(cwl_now) + 9'(wr_bl) + 9'(TWR);
  wire  [5:0]  wr2rd   = 6'(cwl_now) + wr_bl + 6'(TWTR);
  wire  [7:0]  col_pin = line ? {cur_addr[7:3], 3'b000} : cur_addr[7:0];

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
  wire rd_ok = (wtr_t == 0) && (ccd_t == 0);   // a RD may go on the pins now
  wire wr_ok = (ccd_t == 0);                   // a WR may go on the pins now

  assign ck_t = clk;  assign ck_c = ~clk;  assign cke = rst_n;
  assign dqs  = lw_oe ? {~lw_s, lw_s} : 2'bzz;
  // a due refresh goes first; a WRL takes its data beats in D_FILL
  assign hready = (dstate == D_IDLE) && (ref_cnt != 0) || (dstate == D_FILL);
  assign hdone  = (dstate == D_CAS) && (timer == 0) && rd_pending && !line ||
                  (dstate == D_LRD) && (bcnt == 3'd7) || mr_done;
  assign trace_valid = (dstate == D_ACT && act_ok) || (dstate == D_RD && rd_ok) ||
                       (dstate == D_WR && wr_ok);
  assign trace_cmd   = (dstate == D_ACT) ? 3'd1 : (dstate == D_RD) ? 3'd2 : 3'd3;
  assign trace_addr  = cur_addr;
  // each channel owns dq[16*g +: 16]; only the addressed one drives a write
  for (genvar g = 0; g < NCH; g++) begin : g_dq
    assign dq[16*g +: 16] = (dstate == D_WR && wr_ok && !line && c_ch == g) ? wr_data :
                            (lw_oe && c_ch == g) ? lw_d : 16'hzzzz;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; ref_cnt <= TREFI[13:0];
      auto_act <= 1'b0; pre_done <= 1'b0; ref_req <= 1'b0;
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0;
      ref_walk <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0;
      cur_bank <= '0; act_bank <= '0; wtr_t <= '0; ccd_t <= '0;
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1; addr <= '0; hrdata <= '0;
      cs_n <= 1'b1; act_n <= 1'b1; ba <= '0;
      line <= 1'b0; bcnt <= '0; lw_oe <= 1'b0; lw_s <= 1'b0; lw_d <= '0; mr_done <= 1'b0;
      rdline <= '0;
      for (int i = 0; i < 8; i++) begin wbuf[i] <= '0; mr[i] <= '0; end
      mr[0] <= 8'(CL - 5); mr[1] <= 8'(CWL - 5);
      for (int i = 0; i < NB; i++) begin
        open_row[i] <= '0; bank_open[i] <= 1'b0;
        rp_t[i] <= '0; ras_t[i] <= '0; rc_t[i] <= '0;
      end
    end else begin
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;   // commands are 1-cycle pulses
      cs_n <= 1'b1; act_n <= 1'b1; mr_done <= 1'b0;
      if (dstate != D_PRE) pre_done <= 1'b0;
      if (timer != 0) timer <= timer - 1'b1;
      if (ref_cnt != 0) ref_cnt <= ref_cnt - 1'b1;
      if (wtr_t != 0) wtr_t <= wtr_t - 1'b1;
      if (ccd_t != 0) ccd_t <= ccd_t - 1'b1;
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
            line <= (hcmd == 3'd5) || (hcmd == 3'd6);
            case (hcmd)
              3'd1: begin
                act_bank <= a_bank;
                if (a_hit) ;                     // page already open: nothing to do
                else if (bank_open[a_bank] && (open_row[a_bank] != haddr[31:18])) begin
                  rp_t[a_bank] <= TRP[8:0];      // conflict: PRE, then ACT the new row
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
              bank_open[i] <= 1'b0; rp_t[i] <= TRP[8:0];
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
              bank_open[i] <= 1'b0; rp_t[i] <= TRP[8:0];
            end
            dstate <= D_PRE;
          end else if (!pre_done) begin
            // PRE/PREA waits for tRAS, and tRP counts from the real issue
            // (only an open bank or a refresh gets here: a closed one goes
            // straight to D_ACT)
            if (pre_ok) begin
              cs_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0; addr[10] <= ref_walk;
              ba <= ref_walk ? 2'b00 : pre_tgt[1:0];
              // timers load (spacing - 1): the command that waits on a
              // timer goes on the pins at the edge it reads zero
              if (ref_walk) for (int i = 0; i < NB; i++) rp_t[i] <= 9'(TRP - 1);
              else rp_t[pre_tgt] <= 9'(TRP - 1);
              pre_done <= 1'b1;
            end
          end else begin
            if (ref_walk) begin                 // REF once tRP is met
              if (rp_ok) begin
                cs_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b1; ba <= 2'b00;
                timer <= 9'(TRFC - 3); dstate <= D_RCD;   // first pin command 3 edges after it reads 0
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
            // ACT_n low: RAS_n / CAS_n / WE_n are row bits A16..A14 (0)
            cs_n <= 1'b0; act_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b0;
            ba <= act_bank[1:0];
            addr <= {3'b0, open_row[act_bank]};
            ras_t[act_bank] <= 9'(TRAS - 1); rc_t[act_bank] <= 9'(TRC - 1);
            timer <= 9'(TRCD - 2);          // D_RD / D_WR follow one edge after it reads 0
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
          cs_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b1; ba <= cur_bank[1:0];
          addr <= {4'b0, line, 4'b0, col_pin};          // A12 = BC_n: BL8 line, BC4 word
          ccd_t <= CCDW'(TCCD - 1);
          dstate <= D_CAS; timer <= 9'(cl_now);
        end
        D_WR: if (wr_ok) begin
          // a write is complete once it is on the pins: no CAS-latency wait.
          // Its bank may not be precharged before write recovery, and no RD
          // may follow before the write-to-read turnaround.
          // A WRL then drives its burst CWL clocks later (D_LWR).
          cs_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b0; ba <= cur_bank[1:0];
          addr <= {4'b0, line, 4'b0, col_pin};
          // (WR2PRE > tRAS - tRCD: never shorter than what tRAS still holds)
          ras_t[c_bank2] <= wr2pre - 9'd1;
          wtr_t <= wr2rd - 6'd1; ccd_t <= CCDW'(TCCD - 1);
          if (line) begin timer <= 9'(cwl_now); bcnt <= '0; dstate <= D_LWR; end
          else begin ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE; end
        end
        D_CAS: begin
          cas_n <= 1'b1; we_n <= 1'b1;
          if (timer == 0) begin
            hrdata <= dq[16*c_ch +: 16];   // only a RD waits here: the device's read word
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
