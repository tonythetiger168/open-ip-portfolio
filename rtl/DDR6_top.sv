// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DDR6 (projected) -- INDEPENDENT design IP #4/20.
// Architecture thesis: closed-page (auto-precharge) policy. Every RD/WR
// burst closes its bank immediately afterwards (D_CAS -> D_PRE -> D_IDLE),
// so tRP is paid on every access instead of on misses; row conflicts never
// happen by construction. Worst-case-latency-friendly; contrast with the
// open-page DDR4/DDR5 designs. Self-contained; contract identical.
// ============================================================================
module DDR6_top #(
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
  localparam int CL=26, TRCD=16, TRP=16, TRC=60, TRAS=40, TRFC=260, TREFI=9360;
  localparam int NB = 4;

  logic [15:0] mem [0:511];   // 2ch x 256col
  logic [13:0] open_row [0:NB-1];
  logic [NB-1:0] bank_open;
  logic [8:0] rp_t [0:NB-1], ras_t [0:NB-1], rc_t [0:NB-1];
  logic [8:0] timer;
  logic [13:0] ref_cnt;

  typedef enum logic [2:0] {D_IDLE, D_ACT, D_RCD, D_RD, D_CAS, D_WR, D_PRE} d_t;
  d_t dstate;
  logic [31:0] cur_addr;
  logic [15:0] wr_data;
  logic [1:0]  cur_bank, act_bank;
  logic        rd_pending, ref_walk, auto_rw;

  wire [1:0] a_bank = {haddr[8], haddr[10:9]};
  wire [1:0] c_bank2 = {cur_addr[8], cur_addr[10:9]};

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
      ref_walk <= 1'b0; auto_rw <= 1'b0;
      cur_bank <= '0; act_bank <= '0;
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
            rd_pending <= (hcmd == 3'd2); ref_walk <= 1'b0; auto_rw <= 1'b0;
            case (hcmd)
              3'd1: begin
                act_bank <= a_bank;
                if (bank_open[a_bank]) begin
                  bank_open[a_bank] <= 1'b0; rp_t[a_bank] <= TRP[8:0];
                  dstate <= D_PRE;
                end else begin
                  open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                  dstate <= D_ACT;
                end
              end
              3'd2, 3'd3: begin     // closed page: (re)open for every burst
                if (bank_open[a_bank]) begin
                  bank_open[a_bank] <= 1'b0; rp_t[a_bank] <= TRP[8:0];
                  act_bank <= a_bank; auto_rw <= 1'b1;
                  dstate <= D_PRE;
                end else begin
                  open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                  act_bank <= a_bank; auto_rw <= 1'b1;
                  dstate <= D_ACT;
                end
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
          ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0;
          if (ref_walk) begin timer <= TRFC[8:0]; dstate <= D_RCD; end
          else if (auto_rw) begin
            if (rp_t[act_bank] == 0) begin
              open_row[act_bank] <= cur_addr[31:18];  // (re)open current row
              bank_open[act_bank] <= 1'b1;
              dstate <= D_ACT;
            end
          end
          else dstate <= D_IDLE;
        end
        D_ACT: begin
          ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b1;
          addr <= {3'b0, open_row[act_bank]};
          ras_t[act_bank] <= TRAS[8:0]; rc_t[act_bank] <= TRC[8:0];
          timer <= TRCD[8:0];
          dstate <= D_RCD;
        end
        D_RCD: begin
          ras_n <= 1'b1;
          if (timer == 0) begin
            if (ref_walk) begin ref_walk <= 1'b0; dstate <= D_IDLE; end
            else if (auto_rw) begin
              auto_rw <= 1'b0;
              dstate <= rd_pending ? D_RD : D_WR;
            end
            else dstate <= D_IDLE;
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
          mem[{cur_addr[8], cur_addr[7:0]}] <= wr_data;
          dstate <= D_CAS; timer <= CL[8:0];
        end
        D_CAS: begin
          cas_n <= 1'b1; we_n <= 1'b1;
          if (timer == 0) begin
            if (rd_pending) hrdata <= mem[{cur_addr[8], cur_addr[7:0]}];
            rd_pending <= 1'b0;
            bank_open[cur_bank] <= 1'b0; rp_t[cur_bank] <= TRP[8:0]; // auto-close
            dstate <= D_PRE;
          end
        end
        default: dstate <= D_IDLE;
      endcase
    end
  end
endmodule
