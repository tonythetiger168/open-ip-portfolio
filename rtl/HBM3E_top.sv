// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// HBM3E -- INDEPENDENT design IP #18/20.
// Architecture thesis: sideband SEC ECC. Every word is stored in the DRAM
// as a 21-bit SEC codeword (16 data + 5 Hamming check bits over positions
// 1..21, checks at 1,2,4,8,16): a write drives the data on dq and its 5
// check bits on the channel's ecc pins; a read takes data and check bits
// back from dq / ecc and decodes + corrects a single-bit error (syndrome =
// XOR of set-bit positions; syndrome!=0 flips that position back). Read
// data is always corrected before hrdata; the stored word is not scrubbed.
// SEC only: a double-bit error is not detected and may be miscorrected.
// The core holds no data: the DRAM drives the read word CL clocks after
// the RD command.
// 256 page entries ({ch haddr[10:8], pc/bank haddr[15:11]}), per-entry
// refresh rotating over all 256. Contract identical to DDR_top (hrdata
// carries corrected data; the TB flips bits stored in its DRAM device
// through a backdoor and its scoreboard therefore proves the correction).
// On top of the word commands (as DDR4_top):
//   * line commands: hcmd 5 RDL / 6 WRL move one 128-bit line (the 8
//     columns {haddr[7:3], k}) in one BL8 burst (addr[12] = 1 on the RD /
//     WR), every beat a SEC codeword: 16 data bits on the channel's dq and
//     its 5 check bits on ecc. A WRL takes its 8 data beats on hwdata in
//     the 8 hvalid clocks after the command and drives them CWL clocks
//     after the WR, dqs toggling every beat; an RDL takes the DRAM's 8
//     beats from CL clocks after the RD, corrects each and passes it to
//     hrdata in its clock, pulses hdone with the last and holds the
//     corrected line on rdline
//   * mode-register file MR0..MR7 (hcmd 7: haddr[3] = 0 MRW of hwdata[7:0],
//     1 MRR into hrdata[7:0] with an hdone pulse): CL = 5 + MR0[3:0],
//     CWL = 5 + MR1[3:0] (reset to the CL / CWL parameters); MR0 bit 7 is
//     a self-clearing DLL reset. Controller-side: the DRAM's own mode
//     registers are set to match outside this model
//   * command pins: cs_n (high = deselect), act_n (ACT: low, with ras_n /
//     cas_n / we_n = 0), ba = page entry {channel, pc/bank}
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
  output logic [127:0] rdline,          // corrected line of the last RDL
  output logic        hdone,
  output logic        ck_t, ck_c,
  output logic [16:0] addr,
  output logic        cs_n, act_n,
  output logic [7:0]  ba,
  output logic        ras_n, cas_n, we_n,
  inout  tri [NCH*16-1:0] dq,
  inout  tri [NCH*5-1:0]  ecc,           // SEC check bits, 5 per channel
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  localparam int CL=12, TRCD=10, TRP=10, TRC=34, TRAS=22, TRFC=130, TREFI=1560;
  // write timing: CAS write latency, data-bus clocks of one burst, write
  // recovery (end of the write burst to PRE) and write-to-read turnaround.
  // A WR is complete once it is on the pins; these fence what follows it.
  localparam int CWL=10, TBURST=4, TWR=10, TWTR=5;
  // CL / CWL come from the MR file; write recovery / turnaround count from
  // the WR: CWL + the burst (TBURST for a word, 8 beats for a line) + tWR /
  // tWTR.
  localparam int CHW = (NCH <= 2) ? 1 : $clog2(NCH);   // channel select: haddr[8 +: CHW]
  localparam int NB = 256;              // 8 ch x 32 pc/bank entries

  logic [13:0] open_row [0:NB-1];
  logic [NB-1:0] bank_open;
  logic [8:0] rp_t [0:NB-1], ras_t [0:NB-1], rc_t [0:NB-1];
  logic [8:0] timer;
  localparam int WTRW = 6;              // WR2RD <= 20 + 8 + 5
  logic [WTRW-1:0] wtr_t;              // WR-to-RD down-counter
  localparam int CCDW = $clog2(TBURST);
  logic [CCDW-1:0] ccd_t;              // CAS-to-CAS down-counter
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

  typedef enum logic [3:0] {D_IDLE, D_ACT, D_RCD, D_RD, D_CAS, D_WR, D_PRE,
                            D_FILL, D_LRD, D_LWR} d_t;
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
  // line operations and the MR file
  logic        line;                    // the command in flight is an RDL / WRL
  logic [2:0]  bcnt;                    // line beat
  logic [15:0] wbuf [0:7];              // WRL data beats
  logic        lw_oe, lw_s;             // line write burst on dq / ecc / dqs, strobe phase
  logic [15:0] lw_d;
  logic        mr_done;                 // MRR answered
  logic [7:0]  mr [0:7];
  wire  [4:0]  cl_now  = 5'd5 + {1'b0, mr[0][3:0]};
  wire  [4:0]  cwl_now = 5'd5 + {1'b0, mr[1][3:0]};
  wire  [3:0]  wr_bl   = line ? 4'd8 : 4'(TBURST);
  wire  [8:0]  wr2pre  = 9'(cwl_now) + 9'(wr_bl) + 9'(TWR);
  wire  [5:0]  wr2rd   = 6'(cwl_now) + 6'(wr_bl) + 6'(TWTR);
  wire  [7:0]  col_pin = line ? {cur_addr[7:3], 3'b000} : cur_addr[7:0];

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
  wire c_hit = bank_open[c_bank2] && (open_row[c_bank2] == cur_addr[31:18]);
  wire rd_ok = (wtr_t == 0) && (ccd_t == 0);   // a RD may go on the pins now
  wire wr_ok = (ccd_t == 0);                   // a WR may go on the pins now

  assign ck_t = clk;  assign ck_c = ~clk;  assign cke = rst_n;
  assign dqs  = lw_oe ? {~lw_s, lw_s} : 2'bzz;
  // a due refresh goes first; a WRL takes its data beats in D_FILL
  assign hready = (dstate == D_IDLE) && (ref_cnt != 0) || (dstate == D_FILL);
  assign hdone  = (dstate == D_CAS) && (timer == 0) && rd_pending && !line ||
                  (dstate == D_LRD) && (bcnt == 3'd7) || mr_done;
  assign trace_valid = (dstate == D_ACT && act_ok) || (dstate == D_RD && rd_ok) || (dstate == D_WR && wr_ok);
  assign trace_cmd   = (dstate == D_ACT) ? 3'd1 : (dstate == D_RD) ? 3'd2 : 3'd3;
  assign trace_addr  = cur_addr;
  // each channel owns dq[16*g +: 16] and ecc[5*g +: 5]; only the addressed
  // one drives a write: the data and the check bits of its codeword
  wire [20:0] wr_cw = ecc_enc(wr_data);
  wire [4:0]  wr_chk = {wr_cw[15], wr_cw[7], wr_cw[3], wr_cw[1], wr_cw[0]};
  wire [20:0] lw_cw  = ecc_enc(lw_d);   // line beat on the pins
  wire [4:0]  lw_chk = {lw_cw[15], lw_cw[7], lw_cw[3], lw_cw[1], lw_cw[0]};
  wire        w_word = (dstate == D_WR) && wr_ok && !line;
  for (genvar g = 0; g < NCH; g++) begin : g_dq
    assign dq[16*g +: 16] = (w_word && c_ch == g) ? wr_data : (lw_oe && c_ch == g) ? lw_d : 16'hzzzz;
    assign ecc[5*g +: 5]  = (w_word && c_ch == g) ? wr_chk  : (lw_oe && c_ch == g) ? lw_chk : 5'bzzzzz;
  end

  // ECC-corrected read word: the codeword rebuilt from the data and check
  // bits the DRAM drives on the channel's dq / ecc lanes
  wire [15:0] rd_d   = dq[16*c_ch +: 16];
  wire [4:0]  rd_c   = ecc[5*c_ch +: 5];
  logic [20:0] rd_cw;
  always_comb begin
    rd_cw = ecc_enc(rd_d);
    rd_cw[0] = rd_c[0]; rd_cw[1] = rd_c[1]; rd_cw[3] = rd_c[2]; rd_cw[7] = rd_c[3]; rd_cw[15] = rd_c[4];
  end
  wire [15:0] rd_dec = ecc_dec(rd_cw);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; wtr_t <= '0; ccd_t <= '0; ref_cnt <= TREFI[13:0];
      auto_act <= 1'b0; pre_done <= 1'b0; ref_req <= 1'b0;
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0;
      ref_walk <= 1'b0; auto_rd <= 1'b0; auto_wr <= 1'b0; pre_need <= 1'b0;
      cur_bank <= '0; act_bank <= '0; ref_bank <= '0;
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
      if (wtr_t != 0) wtr_t <= wtr_t - 1'b1;
      if (ccd_t != 0) ccd_t <= ccd_t - 1'b1;
      if (ref_cnt != 0) ref_cnt <= ref_cnt - 1'b1;
      for (int i = 0; i < NB; i++) begin
        if (rp_t[i]  != 0) rp_t[i]  <= rp_t[i]  - 1'b1;
        if (ras_t[i] != 0) ras_t[i] <= ras_t[i] - 1'b1;
        if (rc_t[i]  != 0) rc_t[i]  <= rc_t[i]  - 1'b1;
      end
      case (dstate)
        D_IDLE: begin
          if (hvalid && ref_cnt != 0) begin
            cur_addr <= haddr; wr_data <= hwdata; cur_bank <= a_bank;
            rd_pending <= (hcmd == 3'd2) || (hcmd == 3'd5); ref_walk <= 1'b0; auto_act <= 1'b0;
            auto_rd <= 1'b0; auto_wr <= 1'b0; pre_need <= bank_open[a_bank];
            line <= (hcmd == 3'd5) || (hcmd == 3'd6);
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
            if (bank_open[ref_bank]) begin
              bank_open[ref_bank] <= 1'b0; rp_t[ref_bank] <= 9'(TRP - 1);
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
              bank_open[ref_bank] <= 1'b0; rp_t[ref_bank] <= 9'(TRP - 1);
            end
            pre_need <= bank_open[ref_bank];  // PRE the entry only if it is open
            ref_bank <= ref_bank + 1'b1;
            dstate <= D_PRE;
          end else if (!pre_done) begin
            // PRE/PREA waits for tRAS, and tRP counts from the real issue
            if (!pre_need) pre_done <= 1'b1;   // bank already closed
            else if (pre_ok) begin
              cs_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0; addr[10] <= 1'b0;
              ba <= pre_tgt;
              rp_t[pre_tgt] <= 9'(TRP - 1);
              pre_done <= 1'b1;
            end
          end else begin
            if (ref_walk) begin                 // REF once tRP is met
              if (rp_ok) begin
                cs_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b1; ba <= ref_tgt;
                rp_t[ref_tgt] <= 9'(TRFC - 1);   // per-entry refresh: only this entry
                ref_walk <= 1'b0; dstate <= D_IDLE;   // waits tRFC (its next ACT / REF waits rp_t)
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
            cs_n <= 1'b0; act_n <= 1'b0; ras_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b0;
            ba <= act_bank;
            addr <= {3'b0, open_row[act_bank]};
            ras_t[act_bank] <= 9'(TRAS - 1); rc_t[act_bank] <= 9'(TRC - 1);
            timer <= 9'(TRCD - 2);
            dstate <= D_RCD;
            auto_act <= 1'b0;
          end
        end
        D_RCD: begin
          if (timer == 0) begin
            if (auto_rd)  begin auto_rd <= 1'b0; dstate <= D_RD; end
            else if (auto_wr)  begin auto_wr <= 1'b0; dstate <= D_WR; end
            else begin ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE; end
          end
        end
        D_RD: if (rd_ok) begin              // tWTR and tCCD met
          cs_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b1; ba <= cur_bank;
          addr <= {4'b0, line, 4'b0, col_pin};          // addr[12]: BL8 line burst
          ccd_t <= CCDW'(TBURST - 1);
          dstate <= D_CAS; timer <= 9'(cl_now);
        end
        D_WR: if (wr_ok) begin
          cs_n <= 1'b0; cas_n <= 1'b0; we_n <= 1'b0; ba <= cur_bank;
          addr <= {4'b0, line, 4'b0, col_pin};
          // a word is complete once on the pins: D_CAS exits next clock (no
          // CL wait); a WRL drives its burst CWL clocks later (D_LWR)
          ras_t[cur_bank] <= wr2pre - 9'd1;   // WR2PRE > tRAS - tRCD: never shorter than tRAS
          wtr_t <= wr2rd - 6'd1; ccd_t <= CCDW'(TBURST - 1);
          if (line) begin timer <= 9'(cwl_now); bcnt <= '0; dstate <= D_LWR; end
          else begin dstate <= D_CAS; timer <= '0; end
        end
        D_CAS: begin
          if (timer == 0) begin
            if (rd_pending) hrdata <= rd_dec;       // corrected
            if (line) begin                // RDL: beat 0, then 7 more in D_LRD
              rdline[15:0] <= rd_dec; bcnt <= 3'd1; dstate <= D_LRD;
            end else begin
              rd_pending <= 1'b0;
              ref_req <= (ref_cnt == 0); if (ref_cnt == 0) dstate <= D_PRE; else dstate <= D_IDLE;
            end
          end
        end
        D_LRD: begin                       // RDL beats 1..7, each corrected
          hrdata <= rd_dec;
          rdline[16*bcnt +: 16] <= rd_dec;
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
              auto_wr <= 1'b1; pre_need <= bank_open[cur_bank];
              if (bank_open[cur_bank]) dstate <= D_PRE; else dstate <= D_ACT;
            end else dstate <= D_WR;
          end
        end
        D_LWR: begin                       // WRL burst: beat k on dq / ecc in clock WR + CWL + k
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
