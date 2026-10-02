// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// LPDDR4 -- INDEPENDENT design IP #7/20.
// Architecture thesis: mobile 8-bank organization with PER-BANK refresh
// (each tREFI walks one bank round-robin; the other seven keep their open
// rows) and a frequency-word register (MRW to MR7 selects timing set A/B:
// CL 15/22, TRCD 15/14 -- an LPDDR4-style frequency-set switch performed
// without an FSP opcode). Self-contained; contract identical to DDR_top.
// ============================================================================
module LPDDR4_top #(
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
  inout  tri [31:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  localparam int TRP=14, TRC=38, TRAS=28, TRFC=130, TREFI=1560;
  localparam int NB = 8;

  logic [15:0] mem [0:511];   // 2ch x 256col
  logic [13:0] open_row [0:NB-1];
  logic [NB-1:0] bank_open;
  logic [8:0] rp_t [0:NB-1], ras_t [0:NB-1], rc_t [0:NB-1];
  logic [8:0] timer;
  logic [13:0] ref_cnt;
  logic [2:0]  ref_bank;

  // frequency-word register (MR7): 0 = set A (low), 1 = set B (high)
  logic fset;
  wire [8:0] CL   = fset ? 9'd22 : 9'd15;
  wire [8:0] TRCD = fset ? 9'd14 : 9'd15;

  typedef enum logic [2:0] {D_IDLE, D_ACT, D_RCD, D_RD, D_CAS, D_WR, D_PRE} d_t;
  d_t dstate;
  logic [31:0] cur_addr;
  logic [15:0] wr_data;
  logic [2:0]  cur_bank, act_bank;
  logic        rd_pending, ref_walk, auto_rd, auto_wr;

  wire [2:0] a_bank = {haddr[8], haddr[10:9]};
  wire [2:0] c_bank2 = {cur_addr[8], cur_addr[10:9]};
  wire a_hit = bank_open[a_bank] && (open_row[a_bank] == haddr[31:18]);

  assign ck_t = clk;  assign ck_c = ~clk;  assign cke = rst_n;
  assign dqs  = 2'bzz;
  assign hready = (dstate == D_IDLE);
  assign hdone  = (dstate == D_CAS) && (timer == 0) && rd_pending;
  assign trace_valid = (dstate == D_ACT) || (dstate == D_RD) || (dstate == D_WR);
  assign trace_cmd   = (dstate == D_ACT) ? 3'd1 : (dstate == D_RD) ? 3'd2 : 3'd3;
  assign trace_addr  = cur_addr;
  assign dq = (dstate == D_WR) ? {16'hzzzz, wr_data} : 32'hzzzz_zzzz;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; ref_cnt <= TREFI[13:0];
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0;
      ref_walk <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0;
      cur_bank <= '0; act_bank <= '0; ref_bank <= '0; fset <= 1'b0;
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1; addr <= '0; hrdata <= '0;
      for (int i = 0; i < NB; i++) begin
        open_row[i] <= '0; bank_open[i] <= 1'b0;
        rp_t[i] <= '0; ras_t[i] <= '0; rc_t[i] <= '0;
      end
      for (int i = 0; i < 512; i++) mem[i] <= 16'h0;
    end else begin
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
            rd_pending <= (hcmd == 3'd2); ref_walk <= 1'b0;
            auto_rd <= 1'b0; auto_wr <= 1'b0;
            case (hcmd)
              3'd1: begin
                act_bank <= a_bank;
                if (bank_open[a_bank] && (open_row[a_bank] != haddr[31:18])) begin
                  bank_open[a_bank] <= 1'b0; rp_t[a_bank] <= TRP[8:0];
                  dstate <= D_PRE;
                end else begin
                  open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                  dstate <= D_ACT;
                end
              end
              // MRW/MRR are not part of the hcmd space here; the
              // frequency-word is switched via a write to column 0xF0
              // (documented test-hook, decoded below in RD/WR path).
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
            // frequency-word test-hook: WR to column 0xF0 toggles set
            if (hcmd == 3'd3 && haddr[7:0] == 8'hF0) begin
              fset <= hwdata[0];
              dstate <= D_IDLE;               // consumes no DRAM sequence
            end
          end else if (ref_cnt == 0) begin
            // per-bank refresh: close ONLY the rotating target bank
            ref_walk <= 1'b1; ref_cnt <= TREFI[13:0];
            if (bank_open[ref_bank]) begin
              bank_open[ref_bank] <= 1'b0; rp_t[ref_bank] <= TRP[8:0];
            end
            ref_bank <= ref_bank + 1'b1;
            dstate <= D_PRE;
          end
        end
        D_PRE: begin
          ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0;
          if (ref_walk) begin timer <= TRFC[8:0]; dstate <= D_RCD; end
          else if (auto_rd || auto_wr) begin
            if (rp_t[act_bank] == 0) dstate <= D_ACT;
          end
          else dstate <= D_IDLE;
        end
        D_ACT: begin
          ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b1;
          addr <= {3'b0, open_row[act_bank]};
          ras_t[act_bank] <= TRAS[8:0]; rc_t[act_bank] <= TRC[8:0];
          timer <= TRCD;
          dstate <= D_RCD;
        end
        D_RCD: begin
          ras_n <= 1'b1;
          if (timer == 0) begin
            if (ref_walk)      begin ref_walk <= 1'b0; dstate <= D_IDLE; end
            else if (auto_rd)  begin auto_rd <= 1'b0; dstate <= D_RD; end
            else if (auto_wr)  begin auto_wr <= 1'b0; dstate <= D_WR; end
            else dstate <= D_IDLE;
          end
        end
        D_RD: begin
          cas_n <= 1'b0; we_n <= 1'b1;
          addr <= {9'b0, cur_addr[7:0]};
          dstate <= D_CAS; timer <= CL;
        end
        D_WR: begin
          cas_n <= 1'b0; we_n <= 1'b0;
          addr <= {9'b0, cur_addr[7:0]};
          if (cur_addr[7:0] != 8'hF0) mem[{cur_addr[8], cur_addr[7:0]}] <= wr_data;
          dstate <= D_CAS; timer <= CL;
        end
        D_CAS: begin
          cas_n <= 1'b1; we_n <= 1'b1;
          if (timer == 0) begin
            if (rd_pending) hrdata <= mem[{cur_addr[8], cur_addr[7:0]}];
            rd_pending <= 1'b0;
            dstate <= D_IDLE;
          end
        end
        default: dstate <= D_IDLE;
      endcase
    end
  end
endmodule
