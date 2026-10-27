// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DDR7 (projected) -- INDEPENDENT design IP #5/20.
// Architecture thesis: posted-write architecture. A host WR completes as
// soon as it lands in a 4-deep write-back merge buffer (a WR to a buffered
// cell {ch, col} merges in place); nothing reaches the pins until a drain.
// A drain issues the buffered write as a real DRAM WR (PRE / ACT first on a
// page miss), oldest entry first: a WR into a full buffer drains the oldest
// entry, then posts; a RD drains the whole buffer, then reads, so every
// read sees every earlier write. Drains are not host commands: they carry
// no hdone, and the trace port shows the drained entry's address.
// Contrast with the write-through DDR4/DDR5/DDR6 designs.
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
  inout  tri [NCH*16-1:0] dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  localparam int CL=30, TRCD=18, TRP=18, TRC=68, TRAS=44, TRFC=290, TREFI=9360;
  localparam int WBN = 4;
  localparam int CHW = (NCH <= 2) ? 1 : $clog2(NCH);   // channel select: haddr[8 +: CHW]
  localparam int NB = 4 * NCH;          // 4 banks per channel

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
  logic [8:0] timer;
  logic [13:0] ref_cnt;

  typedef enum logic [2:0] {D_IDLE, D_ACT, D_RCD, D_RD, D_CAS, D_WR, D_PRE, D_DRN} d_t;
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

  // write-back merge buffer, oldest entry at index 0
  logic        wb_v [0:WBN-1];
  logic [31:0] wb_a [0:WBN-1];       // full host address (page and cell)
  logic [15:0] wb_d [0:WBN-1];
  logic [2:0]  wb_n;                 // occupancy
  // host command parked while the buffer drains (D_DRN dispatches)
  logic        h_pend, h_rd, evicted, draining;
  logic [31:0] h_addr;
  logic [15:0] h_data;
  // buffered entry holding the incoming cell, if any
  logic        wb_hit;
  logic [1:0]  wb_f;
  always @* begin
    wb_hit = 1'b0; wb_f = '0;
    for (int i = 0; i < WBN; i++)
      if (wb_v[i] && wb_a[i][8:0] == {haddr[8], haddr[7:0]}) begin wb_hit = 1'b1; wb_f = 2'(i); end
  end
  // D_DRN dispatch source: the buffer head while draining, else the parked RD
  wire         x_wb   = (wb_n != 0) && (h_rd || !evicted);
  wire [31:0]  x_addr = x_wb ? wb_a[0] : h_addr;
  wire [15:0]  x_data = x_wb ? wb_d[0] : h_data;
  wire [CHW-1:0] x_ch = (NCH == 1) ? '0 : x_addr[8 +: CHW];
  wire [2:0]   x_bank = {x_ch, x_addr[10:9]};
  wire         x_hit  = bank_open[x_bank] && (open_row[x_bank] == x_addr[31:18]);

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

  assign ck_t = clk;  assign ck_c = ~clk;  assign cke = rst_n;
  assign dqs  = 2'bzz;
  assign hready = (dstate == D_IDLE) && (ref_cnt != 0);   // a due refresh goes first
  assign hdone  = (dstate == D_CAS) && (timer == 0) && rd_pending;
  assign trace_valid = (dstate == D_ACT && act_ok) || (dstate == D_RD) || (dstate == D_WR);
  assign trace_cmd   = (dstate == D_ACT) ? 3'd1 : (dstate == D_RD) ? 3'd2 : 3'd3;
  assign trace_addr  = cur_addr;
  // each channel owns dq[16*g +: 16]; only the addressed one drives a write
  for (genvar g = 0; g < NCH; g++) begin : g_dq
    assign dq[16*g +: 16] = (dstate == D_WR && c_ch == g) ? wr_data : 16'hzzzz;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; ref_cnt <= TREFI[13:0];
      auto_act <= 1'b0; pre_done <= 1'b0; ref_req <= 1'b0;
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0;
      ref_walk <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0; pre_need <= 1'b0;
      cur_bank <= '0; act_bank <= '0;
      wb_n <= '0; h_pend <= 1'b0; h_rd <= 1'b0; evicted <= 1'b0; draining <= 1'b0;
      h_addr <= '0; h_data <= '0;
      for (int i = 0; i < WBN; i++) begin wb_v[i] <= 1'b0; wb_a[i] <= '0; wb_d[i] <= '0; end
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
          if (hvalid && ref_cnt != 0) begin
            cur_addr <= haddr; wr_data <= hwdata; cur_bank <= a_bank;
            rd_pending <= (hcmd == 3'd2); ref_walk <= 1'b0; auto_act <= 1'b0;
            auto_rd <= 1'b0; auto_wr <= 1'b0; pre_need <= bank_open[a_bank];
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
              3'd2, 3'd3: if (hcmd == 3'd3 && wb_hit) begin
                wb_a[wb_f] <= haddr; wb_d[wb_f] <= hwdata;   // merge in place
              end else if (hcmd == 3'd3 && wb_n < WBN) begin
                wb_v[wb_n[1:0]] <= 1'b1; wb_a[wb_n[1:0]] <= haddr; wb_d[wb_n[1:0]] <= hwdata;
                wb_n <= wb_n + 1'b1;                          // posted
              end else if (wb_n != 0) begin
                // full buffer (WR) or a RD behind posted writes: drain first
                h_pend <= 1'b1; h_rd <= (hcmd == 3'd2); evicted <= 1'b0;
                h_addr <= haddr; h_data <= hwdata; rd_pending <= 1'b0;
                dstate <= D_DRN;
              end else begin                                // RD, buffer empty
                if (!a_hit) begin
                  if (bank_open[a_bank]) begin
                    bank_open[a_bank] <= 1'b0; rp_t[a_bank] <= TRP[8:0];
                  end
                  act_bank <= a_bank;
                  open_row[a_bank] <= haddr[31:18]; bank_open[a_bank] <= 1'b1;
                  auto_rd <= 1'b1;
                  dstate <= D_PRE;
                end else dstate <= D_RD;
              end
              3'd4: begin
                if (bank_open[a_bank]) begin bank_open[a_bank] <= 1'b0; rp_t[a_bank] <= TRP[8:0]; end
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
            if (!ref_walk && !pre_need) pre_done <= 1'b1;   // bank already closed
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
            if (ref_walk)      begin ref_walk <= 1'b0; dstate <= h_pend ? D_DRN : D_IDLE; end
            else if (auto_rd)  begin auto_rd <= 1'b0; dstate <= D_RD; end
            else if (auto_wr)  begin auto_wr <= 1'b0; dstate <= D_WR; end
            else begin ref_req <= (ref_cnt == 0); dstate <= (ref_cnt == 0) ? D_PRE : D_IDLE; end
          end
        end
        D_DRN: begin                        // dispatch a drain or the parked host command
          if (!h_rd && evicted) begin       // WR into a full buffer: oldest is out, post it
            wb_v[wb_n[1:0]] <= 1'b1; wb_a[wb_n[1:0]] <= h_addr; wb_d[wb_n[1:0]] <= h_data;
            wb_n <= wb_n + 1'b1; h_pend <= 1'b0;
            dstate <= D_IDLE;                 // a due refresh is taken there
          end else begin
            cur_addr <= x_addr; wr_data <= x_data; cur_bank <= x_bank; act_bank <= x_bank;
            draining <= x_wb; rd_pending <= !x_wb; pre_need <= bank_open[x_bank];
            auto_act <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0;
            if (x_hit) dstate <= x_wb ? D_WR : D_RD;
            else begin
              if (bank_open[x_bank]) begin bank_open[x_bank] <= 1'b0; rp_t[x_bank] <= TRP[8:0]; end
              open_row[x_bank] <= x_addr[31:18]; bank_open[x_bank] <= 1'b1;
              auto_rd <= !x_wb; auto_wr <= x_wb;
              dstate <= D_PRE;
            end
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
            if (draining) begin             // drained entry is in the array: pop it
              for (int i = 0; i < WBN - 1; i++) begin
                wb_v[i] <= wb_v[i+1]; wb_a[i] <= wb_a[i+1]; wb_d[i] <= wb_d[i+1];
              end
              wb_v[WBN-1] <= 1'b0;
              wb_n <= wb_n - 1'b1; draining <= 1'b0; evicted <= 1'b1;
              ref_req <= (ref_cnt == 0); dstate <= (ref_cnt == 0) ? D_PRE : D_DRN;
            end else begin
              h_pend <= 1'b0;
              ref_req <= (ref_cnt == 0); dstate <= (ref_cnt == 0) ? D_PRE : D_IDLE;
            end
          end
        end
      endcase
    end
  end
endmodule
