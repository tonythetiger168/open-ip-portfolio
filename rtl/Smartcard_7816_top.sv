// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Smartcard_7816: ISO/IEC 7816-3 smartcard interface of the STB SoC
// (conditional-access card reader) with an RX ring and TX buffer DMA
// (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Card pins: sc_vcc_en (card power), sc_rst_n (RST), sc_clk (CLK), the
// open-drain I/O line (sc_io_in is the line level, sc_io_oe_low = 1 pulls
// it low) and sc_det (card present, high). sc_io_in and sc_det are
// synchronised with two flops.
// - Clock: CLK toggles every CLK_DIV + 1 clocks while the card is powered
// (card clock = clk / (2 * (CLK_DIV + 1))). One ETU is ETU card clocks (F / D,
// 372 after reset of the card; 0 counts as 1). Bits are sampled in the
// middle of the ETU.
// - Activation (CMD.activate, card present, ENABLE): VCC on, CLK running,
// RST low for RST_CLKS card clocks, then RST high: STATUS.active. The card
// answers with its ATR, received like any other character.
// - Deactivation (CMD.deactivate, card removed, or ENABLE off): RST low, CLK
// stopped low two card clocks later, VCC off 16 clocks after that. A TX in
// progress ends (STATUS.tx_fail, TX_DONE).
// - Character: start bit (low), 8 data bits, even parity, then the guard
// time. Direct convention (CTRL.inverse 0): LSB first, high = 1. Inverse
// convention: MSB first, low = 1 (the parity bit too).
// - RX (while no TX is running): a character is complete at its parity
// sample. T=0 (CTRL.t1 0): a parity error is signalled to the card by
// pulling I/O low from 10.5 to 12 ETU, the character is counted
// (PERR_CNT) and not stored (the card repeats it). T=1: no error signal;
// the character is stored with its parity error flag. Stored characters
// go through an 8-word FIFO to the RX ring, one word each,
// {23'b0, parity_err, data[7:0]}, at RING_BASE + 4 * WR_IDX; RING_WORDS
// words (at least 2); software consumes them and writes RD_IDX. While the
// ring is full (WR_IDX + 1 = RD_IDX mod RING_WORDS) characters wait in the
// FIFO; one that finds the FIFO full is dropped (OVF_CNT).
// - TX (CMD.tx_start, active, TX_LEN > 0): TX_LEN bytes are read from
// TX_ADDR (byte i in word i / 4, bits 8 * (i % 4) + 7 : 8 * (i % 4)) and
// sent start to start every 12 + GUARD ETU. T=0: the I/O line is sampled at
// 11.25 ETU; low means the card signalled a parity error and the character
// is sent again 2 ETU later than usual (RETX_CNT), up to 4 times, then the TX stops with
// STATUS.tx_fail (PERR interrupt). TX_DONE pulses at the end.
// - Waiting time: with WT != 0, WT ETUs after RST goes high, after the last
// character received or after a TX without a new start bit raise TIMEOUT
// (once until the next character).
// - Interrupts: RX (a character is in memory), TX_DONE, PERR (an RX parity
// error, or a TX that failed after 4 repetitions), DET (sc_det changed), TIMEOUT, ERR (with RX or
// TX_DONE when the AXI access saw an error response).
// ============================================================================
module Smartcard_7816_top #(
  parameter logic [3:0] AXI_ID = 4'd10
) (
  input  logic        clk,
  input  logic        rst_n,
  // card pins
  output logic        sc_vcc_en,
  output logic        sc_rst_n,
  output logic        sc_clk,
  input  logic        sc_io_in,
  output logic        sc_io_oe_low,
  input  logic        sc_det,
  // configuration
  input  logic        enable,
  input  logic        inverse,
  input  logic        t1,
  input  logic [7:0]  clk_div,
  input  logic [15:0] etu,
  input  logic [7:0]  guard,
  input  logic [15:0] wt,
  input  logic [15:0] rst_clks,
  input  logic [31:0] ring_base,
  input  logic [15:0] ring_words,
  input  logic [15:0] rd_idx,
  input  logic [31:0] tx_addr,
  input  logic [15:0] tx_len,
  input  logic        activate,
  input  logic        deactivate,
  input  logic        tx_start,
  // status
  output logic        active,
  output logic        powered,
  output logic        tx_busy,
  output logic        tx_fail,
  output logic        err,
  output logic        present,
  output logic [15:0] wr_idx,
  output logic [15:0] rx_cnt,
  output logic [15:0] perr_cnt,
  output logic [15:0] retx_cnt,
  output logic [15:0] ovf_cnt,
  output logic        rx,
  output logic        tx_done,
  output logic        perr,
  output logic        det,
  output logic        timeout,
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
  // ---------------- synchronisers ----------------
  logic [1:0] io_s, det_s;
  logic       io_q, det_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      io_s <= 2'b11; det_s <= 2'b00; io_q <= 1'b1; det_q <= 1'b0;
    end else begin
      io_s <= {io_s[0], sc_io_in}; det_s <= {det_s[0], sc_det};
      io_q <= io_s[1]; det_q <= det_s[1];
    end
  end
  wire io = io_s[1];
  assign present = det_s[1];
  assign det     = det_s[1] != det_q;

  // ---------------- card clock ----------------
  logic       clk_run;
  logic [7:0] dc;
  logic       ce;                                  // one clock per CLK rising edge
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dc <= '0; sc_clk <= 1'b0; ce <= 1'b0;
    end else begin
      ce <= 1'b0;
      if (!clk_run) begin
        dc <= '0; sc_clk <= 1'b0;
      end else if (dc >= clk_div) begin
        dc <= '0; sc_clk <= !sc_clk;
        if (!sc_clk) ce <= 1'b1;
      end else dc <= dc + 8'd1;
    end
  end
  wire [15:0] etu_n  = (etu == 16'd0) ? 16'd1 : etu;
  wire [15:0] half   = etu_n >> 1;
  wire [15:0] quart  = etu_n >> 2;

  // ---------------- power sequence ----------------
  typedef enum logic [1:0] {P_OFF, P_RSTL, P_ON, P_DEACT} pst_t;
  pst_t        pst;
  logic [15:0] pc;
  logic        go_off;
  assign go_off = deactivate || !present || !enable;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pst <= P_OFF; pc <= '0; sc_vcc_en <= 1'b0; sc_rst_n <= 1'b0; clk_run <= 1'b0;
    end else begin
      case (pst)
        P_OFF: if (activate && present && enable) begin
          pst <= P_RSTL; pc <= '0; sc_vcc_en <= 1'b1; clk_run <= 1'b1; sc_rst_n <= 1'b0;
        end
        P_RSTL: if (go_off) begin
          pst <= P_DEACT; pc <= '0;
        end else if (ce) begin
          if (pc + 16'd1 >= rst_clks) begin pst <= P_ON; sc_rst_n <= 1'b1; end
          pc <= pc + 16'd1;
        end
        P_ON: if (go_off) begin
          pst <= P_DEACT; pc <= '0; sc_rst_n <= 1'b0;
        end
        default: begin                             // P_DEACT
          sc_rst_n <= 1'b0;
          if (clk_run) begin
            if (ce) begin
              if (pc == 16'd1) begin clk_run <= 1'b0; pc <= '0; end
              else pc <= pc + 16'd1;
            end
          end else if (pc == 16'd15) begin
            sc_vcc_en <= 1'b0; pst <= P_OFF; pc <= '0;
          end else pc <= pc + 16'd1;
        end
      endcase
    end
  end
  assign active  = (pst == P_ON);
  assign powered = sc_vcc_en;

  // ---------------- free-running ETU tick (waiting time) ----------------
  logic [15:0] ec;
  logic        etick;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ec <= '0; etick <= 1'b0; end
    else begin
      etick <= 1'b0;
      if (!clk_run) ec <= '0;
      else if (ce) begin
        if (ec + 16'd1 >= etu_n) begin ec <= '0; etick <= 1'b1; end
        else ec <= ec + 16'd1;
      end
    end
  end

  // ---------------- receiver ----------------
  typedef enum logic [1:0] {R_IDLE, R_BITS, R_SIG} rst_t;
  rst_t        rs;
  logic [15:0] rc;                                 // card clocks in the bit
  logic [3:0]  rb;                                 // bit index: 0 start, 1..8 data, 9 parity
  logic [8:0]  rsh;                                // data bits and parity in line order
  logic        r_done, r_bad, r_sig;
  logic [7:0]  r_data;
  logic        t_idle;
  wire         r_en = active && t_idle;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs <= R_IDLE; rc <= '0; rb <= '0; rsh <= '0; r_done <= 1'b0; r_bad <= 1'b0; r_sig <= 1'b0; r_data <= '0;
    end else begin
      r_done <= 1'b0;
      if (!r_en) begin
        rs <= R_IDLE; r_sig <= 1'b0;
      end else case (rs)
        R_IDLE: if (io_q && !io) begin             // falling edge: start bit
          rs <= R_BITS; rc <= '0; rb <= '0;
        end
        R_BITS: if (ce) begin
          if (rc == half) begin
            if (rb == 4'd0) begin
              if (io) rs <= R_IDLE;                // glitch, not a start bit
            end else begin
              rsh <= {io, rsh[8:1]};
              if (rb == 4'd9) begin
                r_done <= 1'b1;
                r_data <= dec_d_next(rsh, io);
                r_bad  <= par_bad(rsh, io);
              end
            end
          end
          if (rc + 16'd1 >= etu_n) begin
            rc <= '0;
            if (rb == 4'd9) begin                  // 10 ETU: end of the parity bit
              if (r_bad && !t1) rs <= R_SIG; else rs <= R_IDLE;
              rb <= '0;
            end else rb <= rb + 4'd1;
          end else rc <= rc + 16'd1;
        end
        default: if (ce) begin                     // R_SIG: low from 10.5 to 12 ETU
          if (rb == 4'd0 && rc == half) r_sig <= 1'b1;
          if (rc + 16'd1 >= etu_n) begin
            rc <= '0;
            if (rb == 4'd1) begin rs <= R_IDLE; r_sig <= 1'b0; rb <= '0; end
            else rb <= rb + 4'd1;
          end else rc <= rc + 16'd1;
        end
      endcase
    end
  end
  // the byte and its parity check, with the last (parity) bit p arriving now
  function automatic logic [7:0] dec_d_next(input logic [8:0] sh, input logic p);
    logic [8:0] b;
    logic [7:0] d;
    b = {p, sh[8:1]};
    for (int i = 0; i < 8; i++) d[i] = inverse ? !b[7 - i] : b[i];
    dec_d_next = d;
  endfunction
  function automatic logic par_bad(input logic [8:0] sh, input logic p);
    logic [8:0] b;
    logic [7:0] d;
    logic       pv;
    b = {p, sh[8:1]};
    for (int i = 0; i < 8; i++) d[i] = inverse ? !b[7 - i] : b[i];
    pv = inverse ? !b[8] : b[8];
    par_bad = (^d) != pv;
  endfunction
  wire rx_store = r_done && (!r_bad || t1);
  wire rx_perr  = r_done && r_bad;

  // waiting time
  logic [15:0] wc;
  logic        w_on;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin wc <= '0; w_on <= 1'b0; end
    else begin
      if ((pst == P_RSTL && ce && pc + 16'd1 >= rst_clks) || r_done || tx_done) begin
        wc <= '0; w_on <= 1'b1;
      end else if (!active || rs != R_IDLE || !t_idle || wt == 16'd0) begin
        wc <= '0; if (!active) w_on <= 1'b0;
      end else if (w_on && etick) begin
        if (wc + 16'd1 >= wt) begin w_on <= 1'b0; wc <= '0; end
        else wc <= wc + 16'd1;
      end
    end
  end
  assign timeout = active && t_idle && rs == R_IDLE && wt != 16'd0 && w_on && etick && (wc + 16'd1 >= wt);

  // ---------------- transmitter ----------------
  typedef enum logic [2:0] {T_IDLE, T_LOAD, T_CHAR, T_FLUSH, T_END} tst_t;
  tst_t        ts;
  logic [15:0] t_left, tc;
  logic [7:0]  tb;                                 // ETU index in the character frame
  logic [1:0]  bi;                                 // byte of the word
  logic [2:0]  tries;
  logic [31:0] tw;
  logic        t_nak, t_fail_q, t_err;
  logic        te_start, te_busy, te_done, te_err, t_rs_valid, t_rs_ready;
  logic [31:0] t_rs_data, te_cycles;
  wire  [7:0]  tbyte = tw[8 * bi +: 8];
  wire         tpar  = ^tbyte;
  // line level of frame bit k (0 start, 1..8 data, 9 parity)
  logic        t_lvl;
  always_comb begin
    if (tb == 8'd0) t_lvl = 1'b0;
    else if (tb <= 8'd8) t_lvl = inverse ? !tbyte[8 - tb[3:0]] : tbyte[tb[3:0] - 4'd1];
    else if (tb == 8'd9) t_lvl = inverse ? !tpar : tpar;
    else t_lvl = 1'b1;
  end
  assign t_idle = (ts == T_IDLE);
  assign tx_busy = !t_idle;
  wire [15:0] t_words = (tx_len + 16'd3) >> 2;
  // ETU start to start: 12 + GUARD, 2 more before a repetition
  wire [8:0]  t_frame = 9'd12 + {1'b0, guard} + (t_nak ? 9'd2 : 9'd0);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ts <= T_IDLE; t_left <= '0; tc <= '0; tb <= '0; bi <= '0; tries <= '0; tw <= '0;
      t_nak <= 1'b0; t_fail_q <= 1'b0; t_err <= 1'b0; te_start <= 1'b0; tx_done <= 1'b0;
    end else begin
      te_start <= 1'b0; tx_done <= 1'b0;
      if (te_done && te_err) t_err <= 1'b1;
      case (ts)
        T_IDLE: if (tx_start && active && tx_len != 16'd0 && rs == R_IDLE) begin
          ts <= T_LOAD; te_start <= 1'b1; t_left <= tx_len; bi <= '0; t_fail_q <= 1'b0; t_err <= 1'b0;
        end
        T_LOAD: if (!active) begin
          t_fail_q <= 1'b1; ts <= T_FLUSH;
        end
        else if (t_rs_valid) begin
          tw <= t_rs_data; ts <= T_CHAR; tc <= '0; tb <= '0; tries <= '0; t_nak <= 1'b0;
        end
        T_CHAR: if (!active) begin
          t_fail_q <= 1'b1; ts <= T_FLUSH;
        end else if (ce) begin
          if (tb == 8'd11 && tc == quart && !t1 && !io) t_nak <= 1'b1;
          if (tc + 16'd1 >= etu_n) begin
            tc <= '0;
            if ({1'b0, tb} + 9'd1 >= t_frame) begin       // end of the frame
              tb <= '0;
              if (t_nak) begin
                t_nak <= 1'b0;
                if (tries == 3'd4) begin t_fail_q <= 1'b1; ts <= T_FLUSH; end
                else tries <= tries + 3'd1;            // same byte again
              end else begin
                tries <= '0;
                if (t_left == 16'd1) ts <= T_FLUSH;    // last byte sent
                else begin
                  t_left <= t_left - 16'd1; bi <= bi + 2'd1;
                  if (bi == 2'd3) ts <= T_LOAD;
                end
              end
            end else tb <= tb + 8'd1;
          end else tc <= tc + 16'd1;
        end
        T_FLUSH: if (!te_busy || te_done) ts <= T_END;   // the rest of the words drained
        default: begin                                   // T_END
          ts <= T_IDLE; tx_done <= 1'b1;
        end
      endcase
    end
  end
  // a word is consumed when its last byte is sent (or while flushing)
  assign t_rs_ready = (ts == T_FLUSH) ||
                      (ts == T_CHAR && ce && tc + 16'd1 >= etu_n && {1'b0, tb} + 9'd1 >= t_frame && !t_nak
                       && (bi == 2'd3 || t_left == 16'd1));
  assign tx_fail = t_fail_q;
  wire t_retx = ts == T_CHAR && ce && tc + 16'd1 >= etu_n && {1'b0, tb} + 9'd1 >= t_frame && t_nak && tries != 3'd4;
  wire t_failp = ts == T_CHAR && active && ce && tc + 16'd1 >= etu_n && {1'b0, tb} + 9'd1 >= t_frame && t_nak && tries == 3'd4;

  assign sc_io_oe_low = (ts == T_CHAR && active && !t_lvl) || r_sig;

  // ---------------- RX FIFO and ring DMA ----------------
  logic        f_pop, f_empty, f_full;
  logic [31:0] f_rdata;
  logic        re_start, re_busy, re_done, re_err, r_rs_valid, r_ws_ready;
  logic [31:0] r_rs_data, re_cycles;
  wire  [15:0] nw      = (ring_words == 0) ? 16'd1 : ring_words;
  wire  [15:0] wr_next = (wr_idx + 16'd1 >= nw) ? 16'd0 : wr_idx + 16'd1;
  assign re_start = !f_empty && !re_busy && !re_done && (wr_next != rd_idx) && enable;
  assign f_pop    = re_done;
  tv_fifo #(.W(32), .DEPTH(8)) u_fifo (
    .clk, .rst_n, .clr(1'b0), .push(rx_store && !f_full), .wdata({23'b0, r_bad, r_data}),
    .pop(f_pop), .rdata(f_rdata), .empty(f_empty), .full(f_full), .count()
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_idx <= '0; rx_cnt <= '0; perr_cnt <= '0; retx_cnt <= '0; ovf_cnt <= '0; err <= 1'b0;
    end else begin
      if (rx_store && f_full && ovf_cnt != 16'hFFFF) ovf_cnt <= ovf_cnt + 16'd1;
      if (rx_perr && perr_cnt != 16'hFFFF) perr_cnt <= perr_cnt + 16'd1;
      if (t_retx && retx_cnt != 16'hFFFF) retx_cnt <= retx_cnt + 16'd1;
      if (re_done) begin
        wr_idx <= wr_next;
        if (rx_cnt != 16'hFFFF) rx_cnt <= rx_cnt + 16'd1;
      end
      if ((re_done && re_err) || (te_done && te_err)) err <= 1'b1;
      if (activate && pst == P_OFF) err <= 1'b0;
      if (!enable && !re_busy && f_empty) wr_idx <= '0;
    end
  end
  assign rx      = re_done;
  assign perr    = rx_perr || t_failp;
  assign err_irq = (re_done && re_err) || (tx_done && t_err);

  // RX engine: write channel only
  soc_ss_axi_engine #(.ID(AXI_ID)) u_rx_eng (
    .clk, .rst_n,
    .start(re_start), .rd_en(1'b0), .wr_en(1'b1),
    .src(32'h0), .dst(ring_base + {wr_idx, 2'b00}), .len(16'd1),
    .busy(re_busy), .done(re_done), .err(re_err), .cycles(re_cycles),
    .rs_valid(r_rs_valid), .rs_data(r_rs_data), .rs_ready(1'b1),
    .ws_valid(re_busy), .ws_data(f_rdata), .ws_ready(r_ws_ready),
    .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
    .m_awburst(m_awburst), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready),
    .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
    .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
    .m_arid(), .m_araddr(), .m_arlen(), .m_arsize(), .m_arburst(), .m_arprot(), .m_arvalid(),
    .m_arready(1'b0), .m_rid(4'd0), .m_rdata(32'd0), .m_rresp(2'd0), .m_rlast(1'b0), .m_rvalid(1'b0),
    .m_rready()
  );
  // TX engine: read channel only
  soc_ss_axi_engine #(.ID(AXI_ID)) u_tx_eng (
    .clk, .rst_n,
    .start(te_start), .rd_en(1'b1), .wr_en(1'b0),
    .src(tx_addr), .dst(32'h0), .len(t_words),
    .busy(te_busy), .done(te_done), .err(te_err), .cycles(te_cycles),
    .rs_valid(t_rs_valid), .rs_data(t_rs_data), .rs_ready(t_rs_ready),
    .ws_valid(1'b0), .ws_data(32'h0), .ws_ready(),
    .m_awid(), .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(), .m_awprot(), .m_awvalid(),
    .m_awready(1'b0), .m_wdata(), .m_wstrb(), .m_wlast(), .m_wvalid(), .m_wready(1'b0),
    .m_bid(4'd0), .m_bresp(2'd0), .m_bvalid(1'b0), .m_bready(),
    .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
    .m_arburst(m_arburst), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready),
    .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid),
    .m_rready(m_rready)
  );
endmodule
