// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DDR7 (projected) -- INDEPENDENT design IP #5/20.
// Architecture thesis: posted-write architecture. Writes land in a 4-deep
// write-back merge buffer (same-address writes combine in place; a full
// buffer evicts its oldest entry to the array); reads flush the whole
// buffer to the array first (drain rides D_CAS with rd_pending=0, so no
// hdone is produced during the flush -- contract preserved), then proceed.
// Read-during-write-buffering costs the drain latency; sustained writes
// never stall. Contrast with the write-through DDR4/DDR5/DDR6 designs.
// Self-contained; contract identical to DDR_top.
// ============================================================================
module DDR7_top #(
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
  localparam int CL=30, TRCD=18, TRP=18, TRC=68, TRAS=44, TRFC=290, TREFI=9360;
  localparam int NB = 4, WBN = 4;

  logic [15:0] mem [0:511];   // 2ch x 256col
  logic [13:0] open_row [0:NB-1];
  logic [NB-1:0] bank_open;
  logic [8:0] rp_t [0:NB-1], ras_t [0:NB-1], rc_t [0:NB-1];
  logic [8:0] timer;
  logic [13:0] ref_cnt;

  // write-back merge buffer
  logic        wb_v [0:WBN-1];
  logic [8:0]  wb_a [0:WBN-1];   // {ch, col}
  logic [15:0] wb_d [0:WBN-1];
  logic [2:0]  wb_n;               // occupancy
  logic [2:0]  fb_i;               // flush index
  logic        flush;              // D_CAS is draining the WB

  typedef enum logic [2:0] {D_IDLE, D_ACT, D_RCD, D_RD, D_CAS, D_WR, D_PRE} d_t;
  d_t dstate;
  logic [31:0] cur_addr;
  logic [15:0] wr_data;
  logic [1:0]  cur_bank, act_bank;
  logic        rd_pending, ref_walk, auto_rd, auto_wr;

  wire [1:0] a_bank = {haddr[8], haddr[10:9]};
  wire [1:0] c_bank2 = {cur_addr[8], cur_addr[10:9]};
  wire a_hit = bank_open[a_bank] && (open_row[a_bank] == haddr[31:18]);

  assign ck_t = clk;  assign ck_c = ~clk;  assign cke = rst_n;
  assign dqs  = 2'bzz;
  assign hready = (dstate == D_IDLE);
  assign hdone  = (dstate == D_CAS) && (timer == 0) && rd_pending && !flush;
  assign trace_valid = (dstate == D_ACT) || (dstate == D_RD) || (dstate == D_WR);
  assign trace_cmd   = (dstate == D_ACT) ? 3'd1 : (dstate == D_RD) ? 3'd2 : 3'd3;
  assign trace_addr  = cur_addr;
  assign dq = (dstate == D_WR) ? {16'hzzzz, wr_data} : 32'hzzzz_zzzz;

  // WB helpers (search / push / evict-oldest) inline in the FSM below
  function automatic int wb_find(input [8:0] a);
    int f; begin f = -1;
      for (int i = 0; i < WBN; i++) if (wb_v[i] && wb_a[i] == a) f = i;
      wb_find = f; end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; ref_cnt <= TREFI[13:0];
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0;
      ref_walk <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0; flush <= 1'b0;
      fb_i <= '0; wb_n <= '0;
      cur_bank <= '0; act_bank <= '0;
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1; addr <= '0; hrdata <= '0;
      for (int i = 0; i < NB; i++) begin
        open_row[i] <= '0; bank_open[i] <= 1'b0;
        rp_t[i] <= '0; ras_t[i] <= '0; rc_t[i] <= '0;
      end
      for (int i = 0; i < 512; i++) mem[i] <= 16'h0;
      for (int i = 0; i < WBN; i++) begin wb_v[i] <= 1'b0; wb_a[i] <= '0; wb_d[i] <= '0; end
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
            auto_rd <= 1'b0; auto_wr <= 1'b0; flush <= 1'b0;
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
              3'd2: begin                       // RD: flush WB first
                if (wb_n != 0) begin
                  flush <= 1'b1; fb_i <= '0;
                  dstate <= D_CAS;
                end else if (!a_hit) begin
                  if (bank_open[a_bank]) begin
                    bank_open[a_bank] <= 1'b0; rp_t[a_bank] <= TRP[8:0];
                  end
                  act_bank <= a_bank;
                  open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                  auto_rd <= 1'b1;
                  dstate <= D_PRE;
                end else dstate <= D_RD;
              end
              3'd3: begin                       // WR: merge / push / evict
                automatic int f = wb_find({haddr[8], haddr[7:0]});
                if (f >= 0) begin
                  wb_d[f] <= hwdata;            // merge in place
                end else if (wb_n < WBN) begin
                  wb_v[wb_n] <= 1'b1; wb_a[wb_n] <= {haddr[8], haddr[7:0]}; wb_d[wb_n] <= hwdata;
                  wb_n <= wb_n + 1'b1;
                end else begin
                  mem[wb_a[0]] <= wb_d[0];      // evict oldest
                  for (int i = 0; i < WBN-1; i++) begin
                    wb_v[i] <= wb_v[i+1]; wb_a[i] <= wb_a[i+1]; wb_d[i] <= wb_d[i+1];
                  end
                  wb_v[WBN-1] <= 1'b1; wb_a[WBN-1] <= {haddr[8], haddr[7:0]};
                  wb_d[WBN-1] <= hwdata;
                end
              end
              3'd4: begin
                bank_open[a_bank] <= 1'b0; rp_t[a_bank] <= TRP[8:0];
                dstate <= D_PRE;
              end
              default: ;
            endcase
          end else if (ref_cnt == 0) begin
            // refresh must not lose posted writes: flush WB into the array
            ref_walk <= 1'b1; ref_cnt <= TREFI[13:0];
            if (wb_n != 0) begin flush <= 1'b1; fb_i <= '0; dstate <= D_CAS; end
            else begin
              for (int i = 0; i < NB; i++) begin
                bank_open[i] <= 1'b0; rp_t[i] <= TRP[8:0];
              end
              dstate <= D_PRE;
            end
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
          timer <= TRCD[8:0];
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
          dstate <= D_CAS; timer <= CL[8:0];
        end
        D_WR: begin                     // drain-time array write (unused on
          cas_n <= 1'b0; we_n <= 1'b0;  // the posted path; kept for symmetry)
          addr <= {9'b0, cur_addr[7:0]};
          mem[{cur_addr[8], cur_addr[7:0]}] <= wr_data;
          dstate <= D_CAS; timer <= CL[8:0];
        end
        D_CAS: begin
          cas_n <= 1'b1; we_n <= 1'b1;
          if (flush) begin
            mem[wb_a[fb_i]] <= wb_d[fb_i];      // drain one entry per cycle
            wb_v[fb_i] <= 1'b0;
            if (fb_i == wb_n - 1) begin
              flush <= 1'b0; wb_n <= '0; fb_i <= '0;
              if (ref_walk) begin
                for (int i = 0; i < NB; i++) begin
                  bank_open[i] <= 1'b0; rp_t[i] <= TRP[8:0];
                end
                dstate <= D_PRE;                 // continue refresh
              end
              else dstate <= D_RD;               // flushed: serve the read
            end else fb_i <= fb_i + 1'b1;
          end else if (timer == 0) begin
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
