// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DDR5 -- INDEPENDENT design IP #3/20.
// Architecture thesis: bank-group era. 8 banks (2 channels x 4) split into
// two bank groups (group = bank[2]); ACT-to-ACT timing is group-aware:
// same group tRRD_L=8, different group tRRD_S=4 (separate down-counters).
// Same-page hits behave like DDR4; the differentiation is the ACT
// arbitration network. Self-contained; contract identical to DDR_top.
// An ACT-only host command completes as soon as the ACT is on the pins
// (tRCD is held per bank and enforced at the RD / WR), so back-to-back ACTs
// to different banks are spaced by tRRD alone: tRRD_L after an ACT in the
// same group, tRRD_S after one in the other group.
// ============================================================================
module DDR5_top #(
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
  output logic        hdone,
  output logic        ck_t,
  output logic        ck_c,
  output logic [16:0] addr,
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
  localparam int CL=22, TRCD=14, TRP=14, TRC=52, TRAS=36, TRFC=230, TREFI=9360;
  // write timing: CAS write latency, data-bus clocks of one burst, write
  // recovery (end of the write burst to PRE) and write-to-read turnaround.
  // A WR is complete once it is on the pins; these fence what follows it.
  localparam int CWL=20, TBURST=8, TWR=16, TWTR=8;
  localparam int WR2PRE = CWL + TBURST + TWR;   // WR to PRE, same bank
  localparam int WR2RD  = CWL + TBURST + TWTR;  // WR to RD, any bank
  localparam int CHW = (NCH <= 2) ? 1 : $clog2(NCH);   // channel select: haddr[8 +: CHW]
  localparam int TRRD_L=8, TRRD_S=4;
  localparam int NB = 8;

  logic [15:0] mem [0:(1<<CHW)*256-1];   // NCH ch x 256 col
  // array contents are not cleared by rst_n (a DRAM keeps its data);
  // zero them once for deterministic simulation
  // sim-only clear; yosys (SYNTHESIS) would unroll it into one assignment per
  // line, which takes minutes and GBs for no netlist change
`ifndef SYNTHESIS
  initial for (int i = 0; i <= (1<<CHW)*256-1; i++) mem[i] = '0;
`endif
  logic [13:0] open_row [0:NB-1];
  logic [NB-1:0] bank_open;
  logic [8:0] rp_t [0:NB-1], ras_t [0:NB-1], rc_t [0:NB-1];
  logic [8:0] rrd_l, rrd_s;          // group-aware ACT spacing
  logic       last_grp;              // group of the last ACT
  logic [3:0] rcd_t [0:NB-1];        // per-bank tRCD before RD / WR
  logic [8:0] timer;
  logic [6:0] wtr_t, ccd_t;            // WR-to-RD and CAS-to-CAS down-counters
  logic [13:0] ref_cnt;

  typedef enum logic [2:0] {D_IDLE, D_ACT, D_RFC, D_RD, D_CAS, D_WR, D_PRE} d_t;
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
  logic        pre_need;             // the command's bank was open: PRE it

  wire [2:0] a_bank = {a_ch, haddr[11:10]};
  wire [2:0] c_bank2 = {c_ch, cur_addr[11:10]};
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
  wire rd_ok = (wtr_t == 0) && (ccd_t == 0);   // a RD may go on the pins now
  wire wr_ok = (ccd_t == 0);                   // a WR may go on the pins now
  wire act_grp_ok = (act_bank[2] == last_grp) ? (rrd_l == 0) : (rrd_s == 0);
  wire rcd_ok = (rcd_t[cur_bank] == 0);

  assign ck_t = clk;  assign ck_c = ~clk;  assign cke = rst_n;
  assign dqs  = 2'bzz;
  assign hready = (dstate == D_IDLE) && (ref_cnt != 0);   // a due refresh goes first
  assign hdone  = (dstate == D_CAS) && (timer == 0) && rd_pending;
  assign trace_valid = (dstate == D_ACT && act_ok && act_grp_ok) ||
                       ((dstate == D_RD && rd_ok || dstate == D_WR && wr_ok) && rcd_ok);
  assign trace_cmd   = (dstate == D_ACT) ? 3'd1 : (dstate == D_RD) ? 3'd2 : 3'd3;
  assign trace_addr  = cur_addr;
  // each channel owns dq[16*g +: 16]; only the addressed one drives a write
  for (genvar g = 0; g < NCH; g++) begin : g_dq
    assign dq[16*g +: 16] = (dstate == D_WR && wr_ok && rcd_ok && c_ch == g) ? wr_data : 16'hzzzz;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; wtr_t <= '0; ccd_t <= '0; ref_cnt <= TREFI[13:0];
      auto_act <= 1'b0; pre_done <= 1'b0; ref_req <= 1'b0;
      rrd_l <= '0; rrd_s <= '0; last_grp <= 1'b0; pre_need <= 1'b0;
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0;
      ref_walk <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0;
      cur_bank <= '0; act_bank <= '0;
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1; addr <= '0; hrdata <= '0;
      for (int i = 0; i < NB; i++) begin
        open_row[i] <= '0; bank_open[i] <= 1'b0;
        rp_t[i] <= '0; ras_t[i] <= '0; rc_t[i] <= '0; rcd_t[i] <= '0;
      end
    end else begin
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;   // commands are 1-cycle pulses
      if (dstate != D_PRE) pre_done <= 1'b0;
      if (timer != 0) timer <= timer - 1'b1;
      if (wtr_t != 0) wtr_t <= wtr_t - 1'b1;
      if (ccd_t != 0) ccd_t <= ccd_t - 1'b1;
      if (ref_cnt != 0) ref_cnt <= ref_cnt - 1'b1;
      if (rrd_l != 0) rrd_l <= rrd_l - 1'b1;
      if (rrd_s != 0) rrd_s <= rrd_s - 1'b1;
      for (int i = 0; i < NB; i++) begin
        if (rp_t[i]  != 0) rp_t[i]  <= rp_t[i]  - 1'b1;
        if (ras_t[i] != 0) ras_t[i] <= ras_t[i] - 1'b1;
        if (rc_t[i]  != 0) rc_t[i]  <= rc_t[i]  - 1'b1;
        if (rcd_t[i] != 0) rcd_t[i] <= rcd_t[i] - 1'b1;
      end
      case (dstate)
        D_IDLE: begin
          ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
          if (hvalid && ref_cnt != 0) begin
            cur_addr <= haddr; wr_data <= hwdata; cur_bank <= a_bank;
            rd_pending <= (hcmd == 3'd2); ref_walk <= 1'b0; auto_act <= 1'b0;
            auto_rd <= 1'b0; auto_wr <= 1'b0; pre_need <= bank_open[a_bank];
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
              3'd2, 3'd3: begin
                if (!a_hit) begin
                  act_bank <= a_bank;
                  open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                  auto_rd <= (hcmd == 3'd2); auto_wr <= (hcmd == 3'd3);
                  // a closed bank needs no PRE: straight to its ACT
                  if (bank_open[a_bank]) dstate <= D_PRE; else dstate <= D_ACT;
                end else if (hcmd == 3'd2) dstate <= D_RD; else dstate <= D_WR;
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
            if (!ref_walk && !pre_need) pre_done <= 1'b1;   // bank already closed
            else if (pre_ok) begin
              ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0; addr[10] <= ref_walk;
              if (ref_walk) for (int i = 0; i < NB; i++) rp_t[i] <= 9'(TRP - 1);
              else rp_t[pre_tgt] <= 9'(TRP - 1);
              pre_done <= 1'b1;
            end
          end else begin
            if (ref_walk) begin                 // REF once tRP is met
              if (rp_ok) begin
                ras_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b1;
                timer <= 9'(TRFC - 3); dstate <= D_RFC;   // first pin command 3 edges after it reads 0
              end
            end
            else if (auto_rd || auto_wr || auto_act) dstate <= D_ACT;   // D_ACT waits tRP
            else begin                      // plain PRE: tRP is enforced at the next ACT
              ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE;
            end
          end
        end
        D_ACT: begin
          if (act_ok && act_grp_ok) begin   // tRP, tRC and group-aware tRRD met
            ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b1;
            addr <= {3'b0, open_row[act_bank]};
            ras_t[act_bank] <= 9'(TRAS - 1); rc_t[act_bank] <= 9'(TRC - 1);
            rcd_t[act_bank] <= 4'(TRCD - 1);
            rrd_l <= 9'(TRRD_L - 1); rrd_s <= 9'(TRRD_S - 1); last_grp <= act_bank[2];
            auto_act <= 1'b0;
            if (auto_rd) dstate <= D_RD;     // the RD / WR waits out tRCD itself
            else if (auto_wr) dstate <= D_WR;
            else begin ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE; end
            auto_rd <= 1'b0; auto_wr <= 1'b0;
          end
        end
        D_RFC: begin
          ras_n <= 1'b1;
          if (timer == 0) begin
            ref_walk <= 1'b0; dstate <= D_IDLE;   // tRFC done
          end
        end
        D_RD: if (rcd_ok && rd_ok) begin
          cas_n <= 1'b0; we_n <= 1'b1;
          addr <= {9'b0, cur_addr[7:0]};
          ccd_t <= 7'(TBURST - 1);
          dstate <= D_CAS; timer <= CL[8:0];
        end
        D_WR: if (rcd_ok && wr_ok) begin
          cas_n <= 1'b0; we_n <= 1'b0;
          addr <= {9'b0, cur_addr[7:0]};
          mem[{c_ch, cur_addr[7:0]}] <= wr_data;
          // complete once on the pins: D_CAS exits next clock (no CL wait)
          if (ras_t[cur_bank] < 9'(WR2PRE - 1)) ras_t[cur_bank] <= 9'(WR2PRE - 1);
          wtr_t <= 7'(WR2RD - 1); ccd_t <= 7'(TBURST - 1);
          dstate <= D_CAS; timer <= '0;
        end
        D_CAS: begin
          cas_n <= 1'b1; we_n <= 1'b1;
          if (timer == 0) begin
            if (rd_pending) hrdata <= mem[{c_ch, cur_addr[7:0]}];
            rd_pending <= 1'b0;
            begin ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE; end
          end
        end
        default: dstate <= D_IDLE;
      endcase
    end
  end
endmodule
