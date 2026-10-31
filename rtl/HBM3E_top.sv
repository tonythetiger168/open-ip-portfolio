// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// HBM3E -- INDEPENDENT design IP #18/20.
// Architecture thesis: on-die ECC. The array stores 21-bit SEC codewords
// (16 data + 5 Hamming check bits over positions 1..21, checks at 1,2,4,8,16);
// writes encode, reads decode+correct a single-bit error (syndrome = XOR of
// set-bit positions; syndrome!=0 flips that position back). Read data is
// always corrected before hrdata; the stored word is not scrubbed. SEC
// only: a double-bit error is not detected and may be miscorrected.
// 256 page entries ({ch haddr[10:8], pc/bank haddr[15:11]}), per-entry
// refresh rotating over all 256. Contract identical to DDR_top (hrdata
// carries corrected data; the TB flips stored bits through a backdoor and
// its scoreboard therefore proves the correction).
// ============================================================================
module HBM3E_top #(
  parameter int NCH = 8
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
  localparam int CL=12, TRCD=10, TRP=10, TRC=34, TRAS=22, TRFC=130, TREFI=1560;
  localparam int CHW = (NCH <= 2) ? 1 : $clog2(NCH);   // channel select: haddr[8 +: CHW]
  localparam int NB = 256;              // 8 ch x 32 pc/bank entries

  logic [20:0] mem [0:(1<<CHW)*256-1];   // NCH ch x 256 col
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
  logic [7:0]  ref_bank;             // next entry to refresh

  // ---- SEC encode: data bit i sits at position pos(i); check bits at
  // positions 1,2,4,8,16 (idx 0,1,3,7,15). Check j = parity of data bits
  // whose position number has bit j set.
  function automatic logic is_chk(input int p);
    is_chk = (p == 1) || (p == 2) || (p == 4) || (p == 8) || (p == 16);
  endfunction
  function automatic [20:0] ecc_enc(input [15:0] d);
    logic [20:0] cw;
    int di; logic [4:0] c;
    begin
      cw = 21'd0; di = 0;
      for (int p = 1; p <= 21; p++) begin
        if (!is_chk(p)) begin
          cw[p-1] = d[di];
          di = di + 1;
        end
      end
      c = 5'd0;
      for (int p = 1; p <= 21; p++) begin
        if (!is_chk(p) && cw[p-1]) begin
          for (int j = 0; j < 5; j++)
            if ((p >> j) & 1) c[j] = ~c[j];
        end
      end
      cw[0] = c[0]; cw[1] = c[1]; cw[3] = c[2]; cw[7] = c[3]; cw[15] = c[4];
      ecc_enc = cw;
    end
  endfunction
  function automatic [15:0] ecc_dec(input [20:0] cw);   // corrected data
    logic [20:0] f;
    logic [4:0]  s;
    int di;
    begin
      s = 5'd0;
      for (int p = 1; p <= 21; p++)
        if (cw[p-1]) begin
          for (int j = 0; j < 5; j++)
            if ((p >> j) & 1) s[j] = ~s[j];
        end
      f = cw;
      if (s != 0 && s <= 5'd21) f[s-1] = ~f[s-1];      // single-bit correct
      di = 0;
      for (int p = 1; p <= 21; p++) begin
        if (!is_chk(p)) begin ecc_dec[di] = f[p-1]; di = di + 1; end
      end
    end
  endfunction

  typedef enum logic [2:0] {D_IDLE, D_ACT, D_RCD, D_RD, D_CAS, D_WR, D_PRE} d_t;
  d_t dstate;
  logic [31:0] cur_addr;
  // channel of the incoming / current command (NCH==1 ignores haddr[8],
  // as the MEMCH wrapper on main did)
  wire [CHW-1:0] a_ch = (NCH == 1) ? '0 : haddr[8 +: CHW];
  wire [CHW-1:0] c_ch = (NCH == 1) ? '0 : cur_addr[8 +: CHW];
  logic [15:0] wr_data;
  logic [7:0]  cur_bank, act_bank;
  logic        rd_pending, ref_walk, auto_rd, auto_wr;
  logic        pre_need;             // the command's bank was open: PRE it
  logic        auto_act, pre_done, ref_req;

  wire [7:0] a_bank = {a_ch, haddr[15:11]};   // entry = {ch, pc/bank}
  wire [7:0] c_bank2 = {c_ch, cur_addr[15:11]};
  // per-bank timer-expired vectors: PRE waits tRAS, ACT waits tRP and tRC
  logic [NB-1:0] ras_z, rp_z;
  always_comb
    for (int i = 0; i < NB; i++) begin
      ras_z[i] = (ras_t[i] == 0); rp_z[i] = (rp_t[i] == 0);
    end
  wire [7:0] ref_prev = ref_bank - 1'b1;     // entry the running per-entry REF targets
  wire [7:0] ref_tgt  = ref_prev;
  wire [7:0] pre_tgt = ref_walk ? ref_tgt : cur_bank;
  wire pre_ok = ras_z[pre_tgt];
  wire rp_ok  = rp_z[pre_tgt];
  wire act_ok = rp_z[act_bank] && (rc_t[act_bank] == 0);
  wire a_hit = bank_open[a_bank] && (open_row[a_bank] == haddr[31:18]);

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

  // ECC-corrected read word for the current column (on-die ECC decode)
  wire [15:0] rd_dec = ecc_dec(mem[{c_ch, cur_addr[7:0]}]);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; ref_cnt <= TREFI[13:0];
      auto_act <= 1'b0; pre_done <= 1'b0; ref_req <= 1'b0;
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0;
      ref_walk <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0; pre_need <= 1'b0;
      cur_bank <= '0; act_bank <= '0; ref_bank <= '0;
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
                if (bank_open[a_bank]) begin bank_open[a_bank] <= 1'b0; rp_t[a_bank] <= TRP[8:0]; end
                dstate <= D_PRE;
              end
              default: ;
            endcase
          end else if (ref_cnt == 0) begin
            ref_walk <= 1'b1; ref_cnt <= TREFI[13:0];
            if (bank_open[ref_bank]) begin
              bank_open[ref_bank] <= 1'b0; rp_t[ref_bank] <= TRP[8:0];
            end
            pre_need <= bank_open[ref_bank];  // PRE the entry only if it is open
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
              bank_open[ref_bank] <= 1'b0; rp_t[ref_bank] <= TRP[8:0];
            end
            pre_need <= bank_open[ref_bank];  // PRE the entry only if it is open
            ref_bank <= ref_bank + 1'b1;
            dstate <= D_PRE;
          end else if (!pre_done) begin
            // PRE/PREA waits for tRAS, and tRP counts from the real issue
            if (!pre_need) pre_done <= 1'b1;   // bank already closed
            else if (pre_ok) begin
              ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0; addr[10] <= 1'b0;
              rp_t[pre_tgt] <= TRP[8:0];
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
          mem[{c_ch, cur_addr[7:0]}] <= ecc_enc(wr_data);     // on-die ECC encode
          dstate <= D_CAS; timer <= CL[8:0];
        end
        D_CAS: begin
          cas_n <= 1'b1; we_n <= 1'b1;
          if (timer == 0) begin
            if (rd_pending) hrdata <= rd_dec;       // corrected
            rd_pending <= 1'b0;
            begin ref_req <= (ref_cnt == 0); dstate <= (ref_cnt == 0) ? D_PRE : D_IDLE; end
          end
        end
        default: dstate <= D_IDLE;
      endcase
    end
  end
endmodule
