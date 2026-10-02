// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// LPDDR (legacy, LPDDR3-class) -- INDEPENDENT design IP #6/20.
// Architecture thesis: low-power first. 2 banks (channel-as-bank), and a
// power-down mode entered after 32 idle cycles: the FSM camps in D_PRE
// (no trace, hready=0) until a command arrives -- exit latency is one
// wake cycle. All-bank refresh with long tREFI. Slow legacy timings.
// Self-contained; contract identical to DDR_top.
// ============================================================================
module LPDDR_top #(
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
  localparam int CL=8, TRCD=8, TRP=8, TRFC=90, TREFI=3900, PD_CNT=32;
  localparam int NB = 2;

  logic [15:0] mem [0:511];   // 2ch x 256col
  logic [13:0] open_row [0:NB-1];
  logic [NB-1:0] bank_open;
  logic [8:0] timer;
  logic [13:0] ref_cnt;
  logic [5:0] idle_cnt;
  logic       power_dn;

  typedef enum logic [2:0] {D_IDLE, D_ACT, D_RCD, D_RD, D_CAS, D_WR, D_PRE} d_t;
  d_t dstate;
  logic [31:0] cur_addr;
  logic [15:0] wr_data;
  logic        rd_pending, ref_walk;

  wire [0:0] a_bank = haddr[8:8];
  wire [0:0] c_bank = cur_addr[8:8];
  wire hit = bank_open[a_bank] && (open_row[a_bank] == haddr[31:18]);

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
      idle_cnt <= '0; power_dn <= 1'b0;
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0; ref_walk <= 1'b0;
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1; addr <= '0; hrdata <= '0;
      for (int i = 0; i < NB; i++) begin open_row[i] <= '0; bank_open[i] <= 1'b0; end
      for (int i = 0; i < 512; i++) mem[i] <= 16'h0;
    end else begin
      if (timer != 0) timer <= timer - 1'b1;
      if (ref_cnt != 0) ref_cnt <= ref_cnt - 1'b1;
      case (dstate)
        D_IDLE: begin
          ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
          if (hvalid) begin
            idle_cnt <= '0; power_dn <= 1'b0;
            cur_addr <= haddr; wr_data <= hwdata;
            rd_pending <= (hcmd == 3'd2); ref_walk <= 1'b0;
            case (hcmd)
              3'd1: begin
                open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                dstate <= D_ACT;
              end
              3'd2, 3'd3: begin
                if (!hit) begin
                  open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                  timer <= TRCD[8:0]; dstate <= D_RCD;
                end else dstate <= (hcmd == 3'd2) ? D_RD : D_WR;
              end
              3'd4: begin bank_open[a_bank] <= 1'b0; dstate <= D_PRE; end
              default: ;
            endcase
          end else if (ref_cnt == 0) begin
            ref_walk <= 1'b1; ref_cnt <= TREFI[13:0];
            for (int i = 0; i < NB; i++) bank_open[i] <= 1'b0;
            idle_cnt <= '0;
            dstate <= D_PRE;
          end else if (idle_cnt == PD_CNT-1) begin
            power_dn <= 1'b1;             // enter power-down (camp in D_PRE)
            timer <= 9'd4;                // wake latency
            idle_cnt <= '0;
            dstate <= D_PRE;
          end else idle_cnt <= idle_cnt + 1'b1;
        end
        D_PRE: begin
          ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0;
          if (ref_walk) begin timer <= TRFC[8:0]; dstate <= D_RCD; end
          else if (power_dn && timer == 0) begin
            power_dn <= 1'b0;             // timed wake: hready returns
            dstate <= D_IDLE;
          end
        end
        D_ACT: begin
          ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b1;
          addr <= {3'b0, open_row[a_bank]};
          timer <= TRCD[8:0];
          dstate <= D_RCD;
        end
        D_RCD: begin
          ras_n <= 1'b1;
          if (timer == 0) begin ref_walk <= 1'b0; dstate <= D_IDLE; end
        end
        D_RD: begin
          cas_n <= 1'b0; we_n <= 1'b1;
          addr <= {9'b0, cur_addr[7:0]};
          dstate <= D_CAS; timer <= CL[8:0];
        end
        D_WR: begin
          cas_n <= 1'b0; we_n <= 1'b0;
          addr <= {9'b0, cur_addr[7:0]};
          mem[{cur_addr[8], cur_addr[7:0]}] <= wr_data;
          dstate <= D_CAS; timer <= CL[8:0];
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
