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
  inout  tri [NCH*16-1:0] dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  localparam int CL=30, TRCD=18, TRP=18, TRC=68, TRAS=44, TRFC=290, TREFI=9360;
  localparam int CHW = (NCH <= 2) ? 1 : $clog2(NCH);   // channel select: haddr[8 +: CHW]
  localparam int NB = 8, WBN = 4;

  logic [15:0] mem [0:(1<<CHW)*256-1];   // NCH ch x 256 col
  // array contents are not cleared by rst_n (a DRAM keeps its data);
  // zero them once for deterministic simulation
  initial for (int i = 0; i <= (1<<CHW)*256-1; i++) mem[i] = '0;
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

  assign ck_t = clk;  assign ck_c = ~clk;  assign cke = rst_n;
  assign dqs  = 2'bzz;
  assign hready = (dstate == D_IDLE);
  assign hdone  = (dstate == D_CAS) && (timer == 0) && rd_pending && !flush;
  assign trace_valid = (dstate == D_ACT && act_ok) || (dstate == D_RD) || (dstate == D_WR);
  assign trace_cmd   = (dstate == D_ACT) ? 3'd1 : (dstate == D_RD) ? 3'd2 : 3'd3;
  assign trace_addr  = cur_addr;
  // each channel owns dq[16*g +: 16]; only the addressed one drives a write
  for (genvar g = 0; g < NCH; g++) begin : g_dq
    assign dq[16*g +: 16] = (dstate == D_WR && c_ch == g) ? wr_data : 16'hzzzz;
  end

  // WB helpers (search / push / evict-oldest) inline in the FSM below
  // write-buffer hit index for the incoming host address (-1 = miss)
  int wb_f;
  always @* begin
    wb_f = -1;
    for (int i = 0; i < WBN; i++)
      if (wb_v[i] && wb_a[i] == {a_ch, haddr[7:0]}) wb_f = i;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; ref_cnt <= TREFI[13:0];
      auto_act <= 1'b0; pre_done <= 1'b0; ref_req <= 1'b0;
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0;
      ref_walk <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0; flush <= 1'b0;
      fb_i <= '0; wb_n <= '0;
      cur_bank <= '0; act_bank <= '0;
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1; addr <= '0; hrdata <= '0;
      for (int i = 0; i < NB; i++) begin
        open_row[i] <= '0; bank_open[i] <= 1'b0;
        rp_t[i] <= '0; ras_t[i] <= '0; rc_t[i] <= '0;
      end
      for (int i = 0; i < WBN; i++) begin wb_v[i] <= 1'b0; wb_a[i] <= '0; wb_d[i] <= '0; end
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
            auto_rd <= 1'b0; auto_wr <= 1'b0; flush <= 1'b0;
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
              3'd2: begin                       // RD: flush WB first
                if (wb_n != 0) begin
                  flush <= 1'b1; fb_i <= '0;
                  dstate <= D_PRE;
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
                if (wb_f >= 0) begin
                  wb_d[wb_f[1:0]] <= hwdata;            // merge in place
                end else if (wb_n < WBN) begin
                  wb_v[wb_n] <= 1'b1; wb_a[wb_n] <= {a_ch, haddr[7:0]}; wb_d[wb_n] <= hwdata;
                  wb_n <= wb_n + 1'b1;
                end else begin
                  mem[wb_a[0]] <= wb_d[0];      // evict oldest
                  for (int i = 0; i < WBN-1; i++) begin
                    wb_v[i] <= wb_v[i+1]; wb_a[i] <= wb_a[i+1]; wb_d[i] <= wb_d[i+1];
                  end
                  wb_v[WBN-1] <= 1'b1; wb_a[WBN-1] <= {a_ch, haddr[7:0]};
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
            if (wb_n != 0) begin flush <= 1'b1; fb_i <= '0; dstate <= D_PRE; end
            else begin
              for (int i = 0; i < NB; i++) begin
                bank_open[i] <= 1'b0; rp_t[i] <= TRP[8:0];
              end
              dstate <= D_PRE;
            end
          end
        end
        D_PRE: begin
          if (ref_req) begin
            // refresh fell due while the host kept the FSM busy: start it
            // here, since taking it in D_IDLE would drop a command
            ref_req <= 1'b0; pre_done <= 1'b0;
            // refresh must not lose posted writes: flush WB into the array
            ref_walk <= 1'b1; ref_cnt <= TREFI[13:0];
            if (wb_n != 0) begin flush <= 1'b1; fb_i <= '0; dstate <= D_PRE; end
            else begin
              for (int i = 0; i < NB; i++) begin
                bank_open[i] <= 1'b0; rp_t[i] <= TRP[8:0];
              end
              dstate <= D_PRE;
            end
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
            // WB drain runs here rather than in D_CAS: entering D_CAS with
            // rd_pending=1 and timer=0 let hdone glitch high for a delta
            // before flush settled, and a level-sensitive host saw a stale
            // hrdata.
            if (flush) begin
              mem[wb_a[fb_i[1:0]]] <= wb_d[fb_i[1:0]];   // drain one entry per cycle
              wb_v[fb_i[1:0]] <= 1'b0;
              if (fb_i == wb_n - 1'b1) begin
                flush <= 1'b0; wb_n <= '0; fb_i <= '0;
                if (ref_walk) begin
                  for (int i = 0; i < NB; i++) begin
                    bank_open[i] <= 1'b0; rp_t[i] <= TRP[8:0];
                  end                              // stay in D_PRE: continue refresh
                end
                else dstate <= D_RD;               // flushed: serve the read
              end else fb_i <= fb_i + 1'b1;
            end
            else if (ref_walk) begin                 // REF once tRP is met
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
        D_WR: begin                     // drain-time array write (unused on
          cas_n <= 1'b0; we_n <= 1'b0;  // the posted path; kept for symmetry)
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
