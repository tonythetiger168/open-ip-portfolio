// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// GDDR7 -- INDEPENDENT design IP #14/20.
// Architecture thesis: PAM3 signaling. During the read data phase the low
// 12 dq pins carry the word as 4 ternary symbols (v = 9*t0+3*t1+t2 per
// nibble, 16 of 27 combos legal); dq[15:12] Hi-Z; writes stay NRZ on
// dq[ch*16 +: 16]. 4 banks ({ch,haddr[10:9]}), all-bank refresh, CL=18.
// Contract identical to DDR_top (dq is not sampled by the TBs).
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
  output logic        hdone,
  output logic        ck_t, ck_c,
  output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,
  inout  tri [NCH*16-1:0] dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  localparam int CL=18, TRCD=15, TRP=15, TRC=46, TRAS=32, TRFC=150, TREFI=3900;
  localparam int CHW = (NCH <= 2) ? 1 : $clog2(NCH);   // channel select: haddr[8 +: CHW]
  localparam int NB = 8;

  logic [15:0] mem [0:(1<<CHW)*256-1];   // NCH ch x 256 col
  // array contents are not cleared by rst_n (a DRAM keeps its data);
  // zero them once for deterministic simulation
  initial for (int i = 0; i <= (1<<CHW)*256-1; i++) mem[i] = '0;
  logic [13:0] open_row [0:NB-1];
  logic [NB-1:0] bank_open;
  logic [8:0] rp_t [0:NB-1], ras_t [0:NB-1], rc_t [0:NB-1];
  logic [8:0] timer;
  logic [13:0] ref_cnt;

  typedef enum logic [2:0] {D_IDLE, D_ACT, D_RCD, D_RD, D_CAS, D_WR, D_PRE} d_t;
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

  // PAM3: 16-bit word -> 12 trits (4 nibbles x 3)
  function automatic [11:0] enc_pam3(input [15:0] w);
    logic [11:0] t; int v, r;
    begin
      t = 12'd0;
      for (int n = 0; n < 4; n++) begin
        v = w[4*n +: 4]; r = v % 9;
        t[3*n] = v / 9; t[3*n+1] = r / 3; t[3*n+2] = r % 3;
      end
      enc_pam3 = t;
    end
  endfunction

  wire rd_phase = (dstate == D_CAS) && (timer == 0) && rd_pending;
  assign ck_t = clk;  assign ck_c = ~clk;  assign cke = rst_n;
  assign dqs  = 2'bzz;
  assign hready = (dstate == D_IDLE);
  assign hdone  = rd_phase;
  assign trace_valid = (dstate == D_ACT && act_ok) || (dstate == D_RD) || (dstate == D_WR);
  assign trace_cmd   = (dstate == D_ACT) ? 3'd1 : (dstate == D_RD) ? 3'd2 : 3'd3;
  assign trace_addr  = cur_addr;
  // each channel owns dq[16*g +: 16]; only the addressed one drives
  for (genvar g = 0; g < NCH; g++) begin : g_dq
    assign dq[16*g +: 16] = (c_ch != g)         ? 16'hzzzz :
                            (dstate == D_WR)    ? wr_data :
                            rd_phase            ? {4'hz, enc_pam3(mem[{c_ch, cur_addr[7:0]}])}
                                                : 16'hzzzz;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; ref_cnt <= TREFI[13:0];
      auto_act <= 1'b0; pre_done <= 1'b0; ref_req <= 1'b0;
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0;
      ref_walk <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0;
      cur_bank <= '0; act_bank <= '0;
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1; addr <= '0; hrdata <= '0;
      for (int i = 0; i < NB; i++) begin
        open_row[i] <= '0; bank_open[i] <= 1'b0;
        rp_t[i] <= '0; ras_t[i] <= '0; rc_t[i] <= '0;
      end
    end else begin
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;   // commands are 1-cycle pulses
      if (dstate != D_PRE) pre_done <= 1'b0;
      if (timer != 0) timer <= timer - 1'b1;
      if (ref_cnt != 0) ref_cnt <= ref_cnt - 1'b1;
      for (int i = 0; i < NB; i++) begin
        if (rp_t[i]  != 0) rp_t[i]  <= rp_t[i]  - 1'b1;
        if (ras_t[i] != 0) ras_t[i] <= ras_t[i] - 1'b1;
        if (rc_t[i]  != 0) rc_t[i]  <= rc_t[i]  - 1'b1;
      end
      case (dstate)
        D_IDLE: begin
          ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
          if (hvalid) begin
            cur_addr <= haddr; wr_data <= hwdata; cur_bank <= a_bank;
            rd_pending <= (hcmd == 3'd2); ref_walk <= 1'b0; auto_act <= 1'b0;
            auto_rd <= 1'b0; auto_wr <= 1'b0;
            case (hcmd)
              3'd1: begin
                act_bank <= a_bank;
                if (bank_open[a_bank] && (open_row[a_bank] != haddr[31:18])) begin
                  rp_t[a_bank] <= TRP[8:0];      // conflict: PRE, then ACT the new row
                  open_row[a_bank] <= haddr[31:18]; auto_act <= 1'b1;
                  dstate <= D_PRE;
                end else begin
                  open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                  dstate <= D_ACT;
                end
              end
              3'd2, 3'd3: begin
                if (!a_hit) begin
                  if (bank_open[a_bank]) begin
                    bank_open[a_bank] <= 1'b0; rp_t[a_bank] <= TRP[8:0];
                  end
                  act_bank <= a_bank;
                  open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                  auto_rd <= (hcmd == 3'd2); auto_wr <= (hcmd == 3'd3);
                  dstate <= D_PRE;
                end else dstate <= (hcmd == 3'd2) ? D_RD : D_WR;
              end
              3'd4: begin
                bank_open[a_bank] <= 1'b0; rp_t[a_bank] <= TRP[8:0];
                dstate <= D_PRE;
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
            if (!ref_walk && rp_z[cur_bank]) pre_done <= 1'b1;   // bank already closed
            else if (pre_ok) begin
              ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0; addr[10] <= ref_walk;
              if (ref_walk) for (int i = 0; i < NB; i++) rp_t[i] <= TRP[8:0];
              else rp_t[pre_tgt] <= TRP[8:0];
              pre_done <= 1'b1;
            end
          end else begin
            if (ref_walk) begin                 // REF once tRP is met
              if (rp_ok) begin
                ras_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b1;
                timer <= TRFC[8:0]; dstate <= D_RCD;
              end
            end
            else if (auto_rd || auto_wr || auto_act) begin
              if (rp_t[act_bank] == 0) dstate <= D_ACT;
            end
            else if (rp_ok) begin           // plain PRE: hold hready low through tRP
              ref_req <= (ref_cnt == 0); dstate <= (ref_cnt == 0) ? D_PRE : D_IDLE;
            end
          end
        end
        D_ACT: begin
          if (act_ok) begin                 // tRP and tRC met for this bank
            ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b1;
            addr <= {3'b0, open_row[act_bank]};
            ras_t[act_bank] <= TRAS[8:0]; rc_t[act_bank] <= TRC[8:0];
            timer <= TRCD[8:0];
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
            else begin ref_req <= (ref_cnt == 0); dstate <= (ref_cnt == 0) ? D_PRE : D_IDLE; end
          end
        end
        D_RD: begin
          cas_n <= 1'b0; we_n <= 1'b1;
          addr <= {9'b0, cur_addr[7:0]};
          dstate <= D_CAS; timer <= CL[8:0];
        end
        D_WR: begin
          cas_n <= 1'b0; we_n <= 1'b0;
          addr <= {9'b0, cur_addr[7:0]};
          mem[{c_ch, cur_addr[7:0]}] <= wr_data;
          dstate <= D_CAS; timer <= CL[8:0];
        end
        D_CAS: begin
          cas_n <= 1'b1; we_n <= 1'b1;
          if (timer == 0) begin
            if (rd_pending) hrdata <= mem[{c_ch, cur_addr[7:0]}];
            rd_pending <= 1'b0;
            begin ref_req <= (ref_cnt == 0); dstate <= (ref_cnt == 0) ? D_PRE : D_IDLE; end
          end
        end
        default: dstate <= D_IDLE;
      endcase
    end
  end
endmodule
