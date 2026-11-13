// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DDR4_JEDEC_AXI_top: AXI4 subordinate DDR4 memory controller (JEDEC pins)
// ----------------------------------------------------------------------------
// AXI4 front end + ddr4_jedec_ctrl. Unlike DDR4_AXI (whose core keeps its own
// small array), the storage is the DDR4 device on the pins: a vendor model
// (Micron ddr4_model) or tb/ddr4_dev_model behind a PHY (tb/ddr4_phy_beh in
// simulation).
//  - AXI4: 32-bit data, IDW-bit ID, INCR / FIXED / WRAP, 1..256 beats,
//    AxSIZE 0..2. One write burst and one read burst in service at a time
//    (AW and AR independent). SLVERR for AxSIZE > 2 (no DRAM access) and for
//    a WLAST on the wrong beat (the burst sends nothing more: its buffered
//    block is dropped; blocks it already sent stay written).
//  - Beats are gathered into DRAM bursts (BL8 x 16*NDEV bits = BB bytes):
//    a write burst is issued when the next beat leaves the BB-byte block or
//    after the last beat; WSTRB becomes DM_n (no read-modify-write). Reads
//    issue one DRAM burst per BB-byte block and keep up to 4 in flight.
//  - The host port takes a read or a write burst per grant; a request keeps
//    the grant until the controller accepts it (or a write error withdraws
//    it), then the other side gets the next turn.
// ============================================================================
module DDR4_JEDEC_AXI_top #(
  parameter int NDEV     = 1,
  parameter int IDW      = 4,
  parameter int ROWB     = 16,
  parameter int COLB     = 10,
  parameter int BGB      = 1,
  parameter int BAB      = 2,
  parameter int CL       = 22,
  parameter int CWL      = 16,
  parameter int T_RCD    = 22,
  parameter int T_RP     = 22,
  parameter int T_RAS    = 52,
  parameter int T_RC     = 74,
  parameter int T_RRD_S  = 9,
  parameter int T_RRD_L  = 11,
  parameter int T_FAW    = 48,
  parameter int T_CCD_S  = 4,
  parameter int T_CCD_L  = 8,
  parameter int T_WTR_S  = 4,
  parameter int T_WTR_L  = 12,
  parameter int T_WR     = 24,
  parameter int T_RTP    = 12,
  parameter int T_RFC    = 560,
  parameter int T_REFI   = 12480,
  parameter int T_MRD    = 8,
  parameter int T_MOD    = 24,
  parameter int T_ZQINIT = 1024,
  parameter int T_XPR    = 576,
  parameter int T_RESET  = 64,
  parameter int T_CKE    = 64,
  localparam int DQW     = 16 * NDEV,
  localparam int BB      = DQW
)(
  input  logic               clk,
  input  logic               rst_n,
  // AXI4 subordinate
  input  logic [IDW-1:0]     s_awid,
  input  logic [31:0]        s_awaddr,
  input  logic [7:0]         s_awlen,
  input  logic [2:0]         s_awsize,
  input  logic [1:0]         s_awburst,
  input  logic               s_awvalid,
  output logic               s_awready,
  input  logic [31:0]        s_wdata,
  input  logic [3:0]         s_wstrb,
  input  logic               s_wlast,
  input  logic               s_wvalid,
  output logic               s_wready,
  output logic [IDW-1:0]     s_bid,
  output logic [1:0]         s_bresp,
  output logic               s_bvalid,
  input  logic               s_bready,
  input  logic [IDW-1:0]     s_arid,
  input  logic [31:0]        s_araddr,
  input  logic [7:0]         s_arlen,
  input  logic [2:0]         s_arsize,
  input  logic [1:0]         s_arburst,
  input  logic               s_arvalid,
  output logic               s_arready,
  output logic [IDW-1:0]     s_rid,
  output logic [31:0]        s_rdata,
  output logic [1:0]         s_rresp,
  output logic               s_rlast,
  output logic               s_rvalid,
  input  logic               s_rready,
  // controller to PHY
  output logic               p_reset_n,
  output logic               p_cke,
  output logic               p_odt,
  output logic               p_cs_n,
  output logic               p_act_n,
  output logic               p_ras_n,
  output logic               p_cas_n,
  output logic               p_we_n,
  output logic [1:0]         p_bg,
  output logic [1:0]         p_ba,
  output logic [13:0]        p_a,
  output logic               p_wr,
  output logic [8*DQW-1:0]   p_wdata,
  output logic [BB-1:0]      p_wbe,
  input  logic               p_rvalid,
  input  logic [8*DQW-1:0]   p_rdata,
  // status
  output logic               init_done,
  output logic [15:0]        n_rd,
  output logic [15:0]        n_wr,
  output logic [15:0]        n_err,
  output logic [15:0]        n_act,
  output logic [15:0]        n_hit,
  output logic [15:0]        n_ref,
  output logic               err_irq
);
  localparam int OFF = $clog2(BB);
  localparam int NW  = BB / 4;                // 32-bit words per DRAM burst
  localparam int WB  = $clog2(NW);           // NW >= 4 (BB >= 16)
  localparam int RAW = OFF + COLB - 3 + BGB + BAB + ROWB;   // DRAM byte address bits; above them the
                                                            // 4 GB AXI space aliases the device

  function automatic logic [31:0] next_addr(input logic [31:0] a, input logic [2:0] sz,
                                            input logic [7:0] len, input logic [1:0] bt);
    logic [31:0] inc, al, wmask;
    inc = 32'd1 << sz;
    al  = a & ~(inc - 1);
    case (bt)
      2'b00:   next_addr = a;                                         // FIXED
      2'b10: begin                                                    // WRAP
        wmask     = ({24'd0, len} + 32'd1) * inc - 1;
        next_addr = (a & ~wmask) | ((al + inc) & wmask);
      end
      default: next_addr = al + inc;                                  // INCR
    endcase
  endfunction
  function automatic logic [WB-1:0] word_of(input logic [31:0] a);
    word_of = a[OFF-1:2];
  endfunction

  // ======================= write side =======================
  logic           w_busy, w_err, w_resp;
  logic [IDW-1:0] w_id;
  logic [31:0]    w_addr;
  logic [2:0]     w_size;
  logic [1:0]     w_burst;
  logic [7:0]     w_len, w_cnt;
  logic           w_done;                  // all beats received
  logic           c_valid;                 // chunk buffer holds data
  logic [31:0]    c_addr;
  logic [BB*8-1:0] c_data;
  logic [BB-1:0]  c_be;
  logic           wq;                      // write burst request to the host port

  wire  w_other = c_valid && (w_addr[31:OFF] != c_addr[31:OFF]);
  // a beat can be merged unless the chunk holds another block or is flushing
  assign s_wready = w_busy && !w_done && !w_other && !(wq && c_valid);
  // an erroring burst sends nothing more: its buffered block is dropped
  assign wq       = c_valid && !w_err && (w_other || w_done);
  wire  w_beat    = s_wvalid && s_wready;
  assign s_awready = !w_busy && !w_resp;
  assign s_bvalid  = w_resp;
  assign s_bid     = w_id;
  assign s_bresp   = w_err ? 2'b10 : 2'b00;

  // ======================= read side =======================
  logic           r_busy, r_err;
  logic [IDW-1:0] r_id;
  logic [2:0]     r_size;
  logic [1:0]     r_burst;
  logic [7:0]     r_len;
  logic [31:0]    ri_addr;                 // issue walker
  logic [8:0]     ri_cnt;                  // beats walked
  logic           ri_have;                 // a block was issued
  logic [31:0]    ri_last;                 // its address
  logic [31:0]    ro_addr;                 // output walker
  logic [7:0]     ro_cnt;
  logic [2:0]     r_out;                   // issued, not yet popped
  logic [BB*8-1:0] rf [4];
  logic [1:0]     rf_w, rf_r;
  logic [2:0]     rf_n;

  wire ri_more = r_busy && !r_err && ri_cnt <= {1'b0, r_len};
  wire ri_new  = !ri_have || ri_addr[31:OFF] != ri_last[31:OFF];
  wire rq      = ri_more && ri_new && r_out < 3'd4;
  assign s_arready = !r_busy;

  // output: the head block covers ro_addr when rf_n > 0
  wire ro_last_in_blk = (ro_cnt == r_len) ||
                        (next_addr(ro_addr, r_size, r_len, r_burst) >> OFF) != (ro_addr >> OFF);
  logic [BB*8-1:0] rf_head;
  assign rf_head  = rf[rf_r];
  assign s_rvalid = r_busy && (r_err || rf_n != 0);
  assign s_rid    = r_id;
  assign s_rresp  = r_err ? 2'b10 : 2'b00;
  assign s_rlast  = ro_cnt == r_len;
  assign s_rdata  = r_err ? 32'h0 : rf_head[word_of(ro_addr)*32 +: 32];
  wire r_beat = s_rvalid && s_rready;
  wire r_pop  = r_beat && !r_err && ro_last_in_blk;

  // ======================= host port arbitration =======================
  logic        u_valid, u_ready, u_write;
  logic [RAW-OFF-1:0] u_addr;               // DRAM burst number
  logic        lock_q, lock_w, prio_w;
  // the grant stays with the side that asked until the controller takes the
  // request, unless that side withdrew it (a write burst that errored)
  wire         lock_on = lock_q && (lock_w && wq || !lock_w && rq);
  wire         sel_w = lock_on && lock_w || !lock_on && wq && (!rq || prio_w);
  assign u_valid = wq || rq;
  assign u_write = sel_w;
  assign u_addr  = sel_w ? c_addr[RAW-1:OFF] : ri_addr[RAW-1:OFF];
  wire   u_acc   = u_valid && u_ready;
  wire   w_acc   = u_acc && sel_w;
  wire   r_acc   = u_acc && !sel_w;

  logic            u_rvalid;
  logic [BB*8-1:0] u_rdata;

  ddr4_jedec_ctrl #(
    .NDEV(NDEV), .ROWB(ROWB), .COLB(COLB), .BGB(BGB), .BAB(BAB),
    .CL(CL), .CWL(CWL), .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS), .T_RC(T_RC),
    .T_RRD_S(T_RRD_S), .T_RRD_L(T_RRD_L), .T_FAW(T_FAW), .T_CCD_S(T_CCD_S), .T_CCD_L(T_CCD_L),
    .T_WTR_S(T_WTR_S), .T_WTR_L(T_WTR_L), .T_WR(T_WR), .T_RTP(T_RTP), .T_RFC(T_RFC),
    .T_REFI(T_REFI), .T_MRD(T_MRD), .T_MOD(T_MOD), .T_ZQINIT(T_ZQINIT), .T_XPR(T_XPR),
    .T_RESET(T_RESET), .T_CKE(T_CKE)
  ) u_ctrl (
    .clk, .rst_n,
    .u_valid, .u_ready, .u_write, .u_addr, .u_wdata(c_data), .u_wbe(c_be),
    .u_rvalid, .u_rdata,
    .p_reset_n, .p_cke, .p_odt, .p_cs_n, .p_act_n, .p_ras_n, .p_cas_n, .p_we_n,
    .p_bg, .p_ba, .p_a, .p_wr, .p_wdata, .p_wbe, .p_rvalid, .p_rdata,
    .init_done, .n_act, .n_hit, .n_ref
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_busy <= 1'b0; w_err <= 1'b0; w_resp <= 1'b0; w_done <= 1'b0;
      w_id <= '0; w_addr <= '0; w_size <= '0; w_burst <= '0; w_len <= '0; w_cnt <= '0;
      c_valid <= 1'b0; c_addr <= '0; c_data <= '0; c_be <= '0;
      r_busy <= 1'b0; r_err <= 1'b0; r_id <= '0; r_size <= '0; r_burst <= '0; r_len <= '0;
      ri_addr <= '0; ri_cnt <= '0; ri_have <= 1'b0; ri_last <= '0;
      ro_addr <= '0; ro_cnt <= '0; r_out <= '0;
      rf_w <= '0; rf_r <= '0; rf_n <= '0;
      for (int i = 0; i < 4; i++) rf[i] <= '0;
      lock_q <= 1'b0; lock_w <= 1'b0; prio_w <= 1'b0;
      n_rd <= '0; n_wr <= '0; n_err <= '0; err_irq <= 1'b0;
    end else begin
      err_irq <= 1'b0;
      // ---------------- arbitration lock ----------------
      if (u_acc) begin
        lock_q <= 1'b0;
        prio_w <= !sel_w;
      end else if (u_valid) begin
        lock_q <= 1'b1;
        lock_w <= sel_w;
      end

      // ---------------- write ----------------
      if (s_awvalid && s_awready) begin
        w_busy  <= 1'b1;
        w_done  <= 1'b0;
        w_id    <= s_awid;
        w_addr  <= s_awaddr;
        w_size  <= s_awsize;
        w_burst <= s_awburst;
        w_len   <= s_awlen;
        w_cnt   <= '0;
        w_err   <= s_awsize > 3'd2;
      end
      if (w_acc) begin
        c_valid <= 1'b0;
        c_be    <= '0;
      end
      if (w_beat) begin
        if (!w_err && s_wlast != (w_cnt == w_len)) w_err <= 1'b1;
        if (!w_err && !(s_wlast != (w_cnt == w_len))) begin
          // merge the beat into the block (the buffer is free or same block)
          for (int k = 0; k < NW; k++)
            if (WB'(k) == word_of(w_addr))
              for (int b = 0; b < 4; b++)
                if (s_wstrb[b]) begin
                  c_data[(k*4+b)*8 +: 8] <= s_wdata[b*8 +: 8];
                  c_be[k*4+b]            <= 1'b1;
                end
          c_valid <= 1'b1;
          c_addr  <= w_addr;
        end
        w_addr <= next_addr(w_addr, w_size, w_len, w_burst);
        w_cnt  <= w_cnt + 1'b1;
        if (s_wlast) w_done <= 1'b1;
      end
      if (w_busy && w_done && !c_valid && !w_resp) begin
        w_resp <= 1'b1;
      end
      if (s_bvalid && s_bready) begin
        w_resp <= 1'b0;
        w_busy <= 1'b0;
        w_done <= 1'b0;
        n_wr   <= n_wr + 1'b1;
        if (w_err) begin n_err <= n_err + 1'b1; err_irq <= 1'b1; end
      end
      // an erroring burst drops its buffered block
      if (w_busy && w_err && c_valid && !w_acc) begin
        c_valid <= 1'b0;
        c_be    <= '0;
      end

      // ---------------- read ----------------
      if (s_arvalid && s_arready) begin
        r_busy  <= 1'b1;
        r_id    <= s_arid;
        r_size  <= s_arsize;
        r_burst <= s_arburst;
        r_len   <= s_arlen;
        r_err   <= s_arsize > 3'd2;
        ri_addr <= s_araddr;
        ri_cnt  <= '0;
        ri_have <= 1'b0;
        ro_addr <= s_araddr;
        ro_cnt  <= '0;
      end
      // issue walker: one beat per cycle, stalls on a new block until granted
      if (ri_more && (!ri_new || r_acc)) begin
        if (ri_new) begin
          ri_have <= 1'b1;
          ri_last <= ri_addr;
        end
        ri_addr <= next_addr(ri_addr, r_size, r_len, r_burst);
        ri_cnt  <= ri_cnt + 1'b1;
      end
      r_out <= r_out + (r_acc ? 3'd1 : 3'd0) - (r_pop ? 3'd1 : 3'd0);
      if (u_rvalid) begin
        rf[rf_w] <= u_rdata;
        rf_w     <= rf_w + 1'b1;
      end
      rf_n <= rf_n + (u_rvalid ? 3'd1 : 3'd0) - (r_pop ? 3'd1 : 3'd0);
      if (r_pop) rf_r <= rf_r + 1'b1;
      if (r_beat) begin
        ro_addr <= next_addr(ro_addr, r_size, r_len, r_burst);
        ro_cnt  <= ro_cnt + 1'b1;
        if (s_rlast) begin
          r_busy <= 1'b0;
          n_rd   <= n_rd + 1'b1;
          if (r_err) begin n_err <= n_err + 1'b1; err_irq <= 1'b1; end
        end
      end
    end
  end
endmodule
