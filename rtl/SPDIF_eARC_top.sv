// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SPDIF_eARC: IEC 60958 audio receiver of the TV SoC (S/PDIF input and the
// HDMI eARC data channel, which carries the same biphase-mark coded
// subframes) with an audio ring DMA (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Input spdif_in is the biphase-mark line, oversampled by clk (two-flop
// synchroniser). UI_CLKS is the length of one UI (half a bit cell) in clks,
// at least 4. Intervals between line transitions are classed as 1, 2 or 3
// UI (thresholds 1.5 / 2.5 / 3.5 UI); anything longer, or a 3-UI interval
// inside the data, is a coding error.
// - Preambles (by interval sequence): B = 3,1,1,3 (channel A, block start),
// M = 3,3,1,1 (channel A), W = 3,2,1,2 (channel B). Then 28 data slots,
// '1' = two 1-UI intervals, '0' = one 2-UI interval: slots 4..27 are the
// 24-bit sample (LSB first), then V, U, C, P (even parity over 4..31).
// - Lock: LOCKED after 4 good subframes in a row; a coding error drops it;
// when it was locked, the error counts in CODE_ERR_CNT and raises LOCK_LOST.
// - Channel status: the C bits of channel A in frames 0..31 of a block (from
// B) are collected into CS0 (frame 0 in bit 0); CS pulses when a new CS0
// is complete.
// - Samples (locked only) are written as words {chan_b, block_start, V, U, C,
// parity_err, 2'b00, sample[23:0]} through a 64-word FIFO to the ring at
// RING_BASE: chunks of 16 words (one engine job each) to RING_BASE + 4 *
// WR_IDX; RING_WORDS (a multiple of 16, at least 32) words; software
// consumes them and writes RD_IDX; a chunk is written only when 16 words
// are free (WR_IDX + 16 must not reach RD_IDX). A sample that finds the FIFO
// full is dropped (OVF_CNT). CHUNK pulses when a chunk is in memory, ERR
// as well on an AXI error response. PERR_CNT counts parity errors,
// SAMPLES the subframes received.
// - Not implemented: the eARC common-mode (discovery / heartbeat) channel and
// eARC ECC; the IEC 61937 compressed-audio payload passes through as data.
// ============================================================================
module SPDIF_eARC_top #(
  parameter logic [3:0] AXI_ID = 4'd6
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        spdif_in,
  // configuration
  input  logic        enable,
  input  logic [7:0]  ui_clks,
  input  logic [31:0] ring_base,
  input  logic [15:0] ring_words,
  input  logic [15:0] rd_idx,
  // status
  output logic        locked,
  output logic [31:0] cs0,
  output logic [15:0] wr_idx,
  output logic [31:0] samples,
  output logic [15:0] perr_cnt,
  output logic [15:0] code_err_cnt,
  output logic [15:0] ovf_cnt,
  output logic        err,
  output logic        chunk,
  output logic        lock_lost,
  output logic        cs,
  output logic        err_irq,
  // AXI4 manager (m_*): 32-bit address and data, 4-bit ID
  output logic [3:0]  m_awid,
  output logic [31:0] m_awaddr,
  output logic [7:0]  m_awlen,
  output logic [2:0]  m_awsize,
  output logic [1:0]  m_awburst,
  output logic [2:0]  m_awprot,
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  output logic        m_wlast,
  output logic        m_wvalid,
  input  logic        m_wready,
  input  logic [3:0]  m_bid,
  input  logic [1:0]  m_bresp,
  input  logic        m_bvalid,
  output logic        m_bready,
  output logic [3:0]  m_arid,
  output logic [31:0] m_araddr,
  output logic [7:0]  m_arlen,
  output logic [2:0]  m_arsize,
  output logic [1:0]  m_arburst,
  output logic [2:0]  m_arprot,
  output logic        m_arvalid,
  input  logic        m_arready,
  input  logic [3:0]  m_rid,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,
  input  logic        m_rlast,
  input  logic        m_rvalid,
  output logic        m_rready
);
  // ---------------- interval measurement ----------------
  logic [2:0] sync;
  logic [9:0] cnt;
  logic       ev;                               // an interval ended
  logic [1:0] iv;                               // its class: 1, 2, 3 UI (0 = error)
  wire  [9:0] u   = {2'b0, ui_clks};
  wire  [9:0] t1  = u + (u >> 1), t2 = (u << 1) + (u >> 1), t3 = (u << 1) + u + (u >> 1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync <= '0; cnt <= '0; ev <= 1'b0; iv <= '0;
    end else begin
      sync <= {sync[1:0], spdif_in};
      ev <= 1'b0;
      if (!enable) cnt <= '0;
      else if (sync[2] != sync[1]) begin
        ev <= 1'b1;
        iv <= (cnt + 10'd1 < t1) ? 2'd1 : (cnt + 10'd1 < t2) ? 2'd2 : (cnt + 10'd1 < t3) ? 2'd3 : 2'd0;
        cnt <= '0;
      end else if (cnt != 10'h3FF) cnt <= cnt + 10'd1;
    end
  end
  wire stuck = enable && cnt == t3 + u;          // no transition for too long

  // ---------------- subframe decoder ----------------
  typedef enum logic [1:0] {HUNT, PRE, DATA} st_t;
  st_t        st;
  logic [7:0] pre;                              // preamble intervals, 2 bits each
  logic [3:0] pre_ui;
  logic [4:0] nb;                               // data bits received
  logic       half;                             // first 1-UI half of a '1' seen
  logic [27:0] bits;
  logic [2:0] good_run;
  logic [1:0] ptype;                            // 0 B, 1 M, 2 W
  logic       sf;                               // a subframe ended (pulse)
  logic       cerr;                             // coding error (pulse)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= HUNT; pre <= '0; pre_ui <= '0; nb <= '0; half <= 1'b0; bits <= '0; good_run <= '0;
      ptype <= '0; sf <= 1'b0; cerr <= 1'b0; locked <= 1'b0;
    end else begin
      sf <= 1'b0; cerr <= 1'b0;
      if (!enable) begin
        st <= HUNT; locked <= 1'b0; good_run <= '0;
      end else if (stuck || (ev && iv == 2'd0)) begin
        cerr <= locked;
        st <= HUNT; locked <= 1'b0; good_run <= '0;
      end else if (ev) begin
        case (st)
          HUNT: if (iv == 2'd3) begin st <= PRE; pre <= {6'b0, 2'd3}; pre_ui <= 4'd3; end
          PRE: begin
            pre <= {pre[5:0], iv};
            pre_ui <= pre_ui + {2'b0, iv};
            if (pre_ui + {2'b0, iv} == 4'd8) begin
              case ({pre[5:0], iv})
                {2'd3, 2'd1, 2'd1, 2'd3}: begin ptype <= 2'd0; st <= DATA; end
                {2'd3, 2'd3, 2'd1, 2'd1}: begin ptype <= 2'd1; st <= DATA; end
                {2'd3, 2'd2, 2'd1, 2'd2}: begin ptype <= 2'd2; st <= DATA; end
                default: begin st <= HUNT; cerr <= locked; locked <= 1'b0; good_run <= '0; end
              endcase
              nb <= '0; half <= 1'b0;
            end else if (pre_ui + {2'b0, iv} > 4'd8) begin
              st <= HUNT; cerr <= locked; locked <= 1'b0; good_run <= '0;
            end
          end
          DATA: begin
            if (iv == 2'd3 || (half && iv == 2'd2)) begin
              st <= HUNT; cerr <= locked; locked <= 1'b0; good_run <= '0;
            end else if (iv == 2'd2 || half) begin
              bits <= {(iv == 2'd1), bits[27:1]};   // slot 4 ends in bits[0]
              half <= 1'b0;
              nb <= nb + 5'd1;
              if (nb == 5'd27) begin
                st <= PRE; pre <= '0; pre_ui <= '0;
                sf <= 1'b1;
                if (good_run != 3'd4) good_run <= good_run + 3'd1;
                if (good_run >= 3'd3) locked <= 1'b1;
              end
            end else half <= 1'b1;
          end
          default: st <= HUNT;
        endcase
      end
    end
  end
  // the last data bit enters bits at the same clock sf rises: use the next value
  logic [27:0] sbits;
  logic [1:0]  sptype;
  logic        sfq;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin sfq <= 1'b0; sptype <= '0; end
    else begin sfq <= sf && locked; sptype <= ptype; end
  end
  assign sbits = bits;
  wire        perr = ^sbits;
  wire [31:0] word = {sptype == 2'd2, sptype == 2'd0, sbits[24], sbits[25], sbits[26], perr, 2'b00, sbits[23:0]};

  // channel status of channel A, frames 0..31 (counted from a B preamble on
  // every decoded subframe; unknown until the first B)
  logic [31:0] cs_acc;
  logic [7:0]  csf;                             // frame number of the next channel A subframe
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin cs_acc <= '0; cs0 <= '0; csf <= 8'hFF; end
    else if (!enable || st == HUNT) csf <= 8'hFF;
    else if (sf && ptype != 2'd2) begin
      if (ptype == 2'd0) begin cs_acc <= {31'b0, bits[26]}; csf <= 8'd1; end
      else if (csf != 8'hFF) begin
        if (csf < 8'd32) cs_acc[csf[4:0]] <= bits[26];
        if (csf == 8'd31) cs0 <= {bits[26], cs_acc[30:0]};
        csf <= (csf == 8'd191) ? 8'hFF : csf + 8'd1;
      end
    end
  end
  assign cs = sf && ptype == 2'd1 && csf == 8'd31;

  // ---------------- FIFO and ring DMA ----------------
  logic        f_pop, f_empty, f_full;
  logic [31:0] f_rdata;
  logic [6:0]  f_count;
  logic        e_start, e_busy, e_done, e_err, rs_valid, ws_ready;
  logic [31:0] rs_data, e_cycles;
  wire  [15:0] nw    = (ring_words < 16'd32) ? 16'd32 : {ring_words[15:4], 4'b0};
  wire  [15:0] used  = (wr_idx >= rd_idx) ? wr_idx - rd_idx : wr_idx + nw - rd_idx;
  wire         room  = (nw - used) > 16'd16;
  assign e_start = f_count >= 7'd16 && !e_busy && !e_done && room;
  assign f_pop   = ws_ready && !f_empty;
  tv_fifo #(.W(32), .DEPTH(64)) u_fifo (
    .clk, .rst_n, .clr(!enable && !e_busy), .push(sfq), .wdata(word),
    .pop(f_pop), .rdata(f_rdata), .empty(f_empty), .full(f_full), .count(f_count)
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_idx <= '0; samples <= '0; perr_cnt <= '0; code_err_cnt <= '0; ovf_cnt <= '0; err <= 1'b0;
    end else begin
      if (sfq) begin
        samples <= samples + 32'd1;
        if (perr && perr_cnt != 16'hFFFF) perr_cnt <= perr_cnt + 16'd1;
        if (f_full && ovf_cnt != 16'hFFFF) ovf_cnt <= ovf_cnt + 16'd1;
      end
      if (cerr && code_err_cnt != 16'hFFFF) code_err_cnt <= code_err_cnt + 16'd1;
      if (e_done) begin
        wr_idx <= (wr_idx + 16'd16 >= nw) ? 16'd0 : wr_idx + 16'd16;
        if (e_err) err <= 1'b1;
      end
      if (!enable && !e_busy) begin wr_idx <= '0; err <= 1'b0; end
    end
  end
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(1'b0), .wr_en(1'b1),
    .src(32'h0), .dst(ring_base + {wr_idx, 2'b00}), .len(16'd16),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cycles),
    .rs_valid, .rs_data, .rs_ready(1'b1), .ws_valid(!f_empty), .ws_data(f_rdata), .ws_ready,
    .m_awid(m_awid),
    .m_awaddr(m_awaddr),
    .m_awlen(m_awlen),
    .m_awsize(m_awsize),
    .m_awburst(m_awburst),
    .m_awprot(m_awprot),
    .m_awvalid(m_awvalid),
    .m_awready(m_awready),
    .m_wdata(m_wdata),
    .m_wstrb(m_wstrb),
    .m_wlast(m_wlast),
    .m_wvalid(m_wvalid),
    .m_wready(m_wready),
    .m_bid(m_bid),
    .m_bresp(m_bresp),
    .m_bvalid(m_bvalid),
    .m_bready(m_bready),
    .m_arid(m_arid),
    .m_araddr(m_araddr),
    .m_arlen(m_arlen),
    .m_arsize(m_arsize),
    .m_arburst(m_arburst),
    .m_arprot(m_arprot),
    .m_arvalid(m_arvalid),
    .m_arready(m_arready),
    .m_rid(m_rid),
    .m_rdata(m_rdata),
    .m_rresp(m_rresp),
    .m_rlast(m_rlast),
    .m_rvalid(m_rvalid),
    .m_rready(m_rready)
  );
  assign chunk     = e_done;
  assign err_irq   = e_done && e_err;
  assign lock_lost = cerr;                      // cerr only fires when lock is lost
endmodule
