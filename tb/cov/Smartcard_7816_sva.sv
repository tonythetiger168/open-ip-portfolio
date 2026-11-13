// SPDX-License-Identifier: Apache-2.0
// Smartcard_7816 (ISO 7816-3 card interface, RX ring and TX buffer DMA):
// concurrent SVA against a model of the card pins written from the header,
// + functional coverage. The model runs on its own card-clock tick (CLK
// rising edges), synchronises I/O and DET like the header says and checks:
// - power: VCC before RST, RST low for RST_CLKS card clocks, RST drops when
//   deactivated (command, card removed, ENABLE off), VCC drops last with CLK
//   stopped low; CLK half period CLK_DIV + 1 clocks; ACTIVE / POWERED / DET;
// - TX: an independent decoder of the core's I/O drive samples every
//   character mid-ETU (start bit, 8 data bits in the convention, even
//   parity), checks it against the next byte of the TX buffer read over AXI,
//   checks the line is released from 10 ETU to the end of the frame and that
//   the next start is 12 + GUARD ETU after this one (2 more after a parity
//   error the card signalled at 11.25 ETU), the repetitions (RETX_CNT), the
//   failure after 4 repetitions (TX_FAIL, PERR) and TX_DONE;
// - RX: an independent receiver of the card's characters (glitch rejection,
//   parity, T=0 error signalling from 10.5 to 12 ETU, T=1 flag), the 8-word
//   FIFO (OVF_CNT on a drop), the ring words written over AXI and their
//   address RING_BASE + 4 * WR_IDX, WR_IDX wrap at RING_WORDS, no write into
//   a full ring, RX_CNT / PERR_CNT;
// - the waiting time (TIMEOUT), ERR / ERR_IRQ after AXI error responses.
// The AXI engines are closed by their own run.
`include "cov_macros.svh"
module Smartcard_7816_sva (
  input logic        clk, rst_n,
  input logic        sc_vcc_en, sc_rst_n, sc_clk, sc_io_in, sc_io_oe_low, sc_det,
  input logic        enable, inverse, t1, activate, deactivate, tx_start,
  input logic [7:0]  clk_div, guard,
  input logic [15:0] etu, wt, rst_clks, ring_words, rd_idx, tx_len,
  input logic [31:0] ring_base, tx_addr,
  input logic        active, powered, tx_busy, tx_fail, err, present,
  input logic [15:0] wr_idx, rx_cnt, perr_cnt, retx_cnt, ovf_cnt,
  input logic        rx, tx_done, perr, det, timeout, err_irq,
  input logic [31:0] m_awaddr, m_wdata, m_araddr, m_rdata,
  input logic        m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready,
  input logic        m_arvalid, m_arready, m_rvalid, m_rready, m_rlast,
  input logic [7:0]  m_arlen,
  input logic [1:0]  m_bresp, m_rresp
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- time base, synchronisers ----------------
  logic        sck_q, oe_q;
  logic [1:0]  io_s, det_s;
  logic        io_q, pres_q;
  logic [15:0] hc, quiet;                          // clocks since the last CLK change
  logic        seen_edge, div_chg;
  logic [7:0]  cd_q;                              // CLK_DIV as the divider saw it last clock
  wire         m_ce   = sc_clk && !sck_q;          // a CLK rising edge happened
  wire  [15:0] etu_n  = (etu == 0) ? 16'd1 : etu;
  wire  [15:0] half   = etu_n >> 1;
  wire  [15:0] quart  = etu_n >> 2;
  wire         m_io   = io_s[1];
  wire  [15:0] rst_n_clks = (rst_clks == 0) ? 16'd1 : rst_clks;
  wire  [15:0] nw     = (ring_words == 0) ? 16'd1 : ring_words;
  wire  [15:0] m_wr_next = (32'(wr_idx) + 1 >= 32'(nw)) ? 16'd0 : wr_idx + 16'd1;
  wire         go_off = deactivate || !present || !enable;

  // ---------------- power ----------------
  logic        rstl;                               // VCC on, RST low, before RST high
  logic [15:0] nce;                                // card clocks since VCC on
  wire         rst_rise_now = rstl && !go_off && m_ce && 32'(nce) + 1 >= 32'(rst_n_clks);

  // ---------------- TX decoder ----------------
  logic [7:0]  tq [$];                             // bytes of the TX buffer, in order
  logic        d_on, d_nak, prev_nak;
  int unsigned d_m;                                // card clocks into the frame
  logic [9:0]  d_lvl;                              // line levels of frame bits 0..9
  int          tries, t_left;
  logic        t_fail_m, t_err_m;
  wire         d_start = tx_busy && active && !d_on && sc_io_oe_low && !oe_q;
  wire         d_run   = (d_on || d_start) && active;
  wire [31:0]  d_cur = d_start ? 0 : d_m;
  wire [31:0]  d_len = (12 + 32'(guard) + (d_nak && !d_start ? 2 : 0)) * 32'(etu_n);   // 2 ETU more when the card signalled an error
  wire [31:0]  d_k   = d_cur / 32'(etu_n);
  wire [31:0]  d_r   = d_cur % 32'(etu_n);
  wire         d_end   = d_run && m_ce && d_cur + 1 == d_len;
  wire         d_nak_end = d_end && d_nak;
  wire         t_failp_m = d_nak_end && tries == 4;
  // decoded byte and parity of the frame just ending
  logic [7:0]  d_byte;
  logic        d_par_ok;
  always_comb begin
    for (int i = 0; i < 8; i++) d_byte[i] = inverse ? !d_lvl[8 - i] : d_lvl[1 + i];
    d_par_ok = !d_lvl[0] && ((^d_byte) == (inverse ? !d_lvl[9] : d_lvl[9]));
  end

  // ---------------- RX receiver ----------------
  typedef enum logic [1:0] {R_IDLE, R_BITS, R_SIG} r_t;
  r_t          rs;
  logic [15:0] rc;
  logic [3:0]  rb;
  logic [8:0]  rsh;
  logic        r_done, r_bad, r_sig, r_glitch;
  logic [7:0]  r_data;
  logic [31:0] rq [$];                             // words in the FIFO, oldest first
  logic        b_err;                              // the RX job saw an error response
  logic [15:0] m_rxc, m_perr, m_ovf, m_retx;
  wire         r_en    = active && !tx_busy;
  wire         r_store = r_done && (!r_bad || t1);
  wire         r_drop  = r_store && rq.size() == 8;
  wire         b_err_now = b_err || (m_bvalid && m_bready && m_bresp != 2'b00);
  logic [7:0]  r_dec;
  logic        r_pbad;
  always_comb begin
    logic [8:0] b;
    b = {m_io, rsh[8:1]};
    for (int i = 0; i < 8; i++) r_dec[i] = inverse ? !b[7 - i] : b[i];
    r_pbad = (^r_dec) != (inverse ? !b[8] : b[8]);
  end

  // ---------------- waiting time ----------------
  logic [15:0] ec, wc;
  logic        etick, w_on;
  wire         w_fire = active && !tx_busy && rs == R_IDLE && wt != 0 && w_on && etick && 32'(wc) + 1 >= 32'(wt);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sck_q <= 0; oe_q <= 0; io_s <= 2'b11; det_s <= 0; io_q <= 1; pres_q <= 0; hc <= 0; quiet <= 0;
      seen_edge <= 0; div_chg <= 0; cd_q <= 0; rstl <= 0; nce <= 0;
      tq.delete(); d_on <= 0; d_nak <= 0; prev_nak <= 0; d_m <= 0; d_lvl <= 0; tries <= 0; t_left <= 0;
      t_fail_m <= 0; t_err_m <= 0;
      rs <= R_IDLE; rc <= 0; rb <= 0; rsh <= 0; r_done <= 0; r_bad <= 0; r_sig <= 0; r_glitch <= 0; r_data <= 0;
      rq.delete(); b_err <= 0; m_rxc <= 0; m_perr <= 0; m_ovf <= 0; m_retx <= 0;
      ec <= 0; wc <= 0; etick <= 0; w_on <= 0;
    end else begin
      sck_q <= sc_clk; oe_q <= sc_io_oe_low; io_s <= {io_s[0], sc_io_in}; det_s <= {det_s[0], sc_det};
      io_q <= m_io; pres_q <= present;
      // CLK timing
      cd_q <= clk_div;
      if (sc_clk != sck_q) begin hc <= 0; quiet <= 0; seen_edge <= 1; div_chg <= clk_div != cd_q; end
      else begin
        hc <= hc + 1;
        if (quiet != 16'hFFFF) quiet <= quiet + 1;
        if (clk_div != cd_q) div_chg <= 1;
      end
      if (!sc_vcc_en) seen_edge <= 0;
      // power
      if (!powered && activate && present && enable) begin rstl <= 1; nce <= 0; end
      else if (rstl) begin
        if (go_off || rst_rise_now) rstl <= 0;
        if (m_ce) nce <= nce + 1;
      end

      // ---- TX ----
      if ($rose(tx_busy)) begin
        tq.delete(); t_left <= tx_len; tries <= 0; prev_nak <= 0; t_fail_m <= 0; t_err_m <= 0;
      end
      if (m_rvalid && m_rready && tx_busy) begin
        for (int i = 0; i < 4; i++) tq.push_back(m_rdata[8 * i +: 8]);
        if (m_rresp != 2'b00) t_err_m <= 1;
      end
      if (tx_busy && $fell(active)) begin d_on <= 0; t_fail_m <= 1; end
      else if (d_run) begin
        d_on <= 1;
        if (d_start) begin d_nak <= 0; d_m <= 0; end
        if (m_ce) begin
          if (d_k <= 9 && d_r == 32'(half)) d_lvl[d_k] <= !sc_io_oe_low;
          if (d_k == 11 && d_r == 32'(quart) && !t1) d_nak <= !m_io;
          d_m <= d_cur + 1;
          if (d_end) begin
            d_on <= 0; prev_nak <= d_nak;
            if (d_nak) begin
              if (tries == 4) t_fail_m <= 1;
              else begin tries <= tries + 1; if (m_retx != 16'hFFFF) m_retx <= m_retx + 1; end
            end else begin
              tries <= 0; t_left <= t_left - 1;
              if (tq.size() != 0) void'(tq.pop_front());
            end
          end
        end
      end
      if (!tx_busy) d_on <= 0;

      // ---- RX ----
      r_done <= 0; r_glitch <= 0;
      if (!r_en) begin rs <= R_IDLE; r_sig <= 0; end
      else case (rs)
        R_IDLE: if (io_q && !m_io) begin rs <= R_BITS; rc <= 0; rb <= 0; end
        R_BITS: if (m_ce) begin
          if (rc == half) begin
            if (rb == 0) begin if (m_io) begin rs <= R_IDLE; r_glitch <= 1; end end
            else begin
              rsh <= {m_io, rsh[8:1]};
              if (rb == 9) begin r_done <= 1; r_data <= r_dec; r_bad <= r_pbad; end
            end
          end
          if (32'(rc) + 1 >= 32'(etu_n)) begin
            rc <= 0;
            if (rb == 9) begin rs <= (r_bad && !t1) ? R_SIG : R_IDLE; rb <= 0; end
            else rb <= rb + 1;
          end else rc <= rc + 1;
        end
        default: if (m_ce) begin
          if (rb == 0 && rc == half) r_sig <= 1;
          if (32'(rc) + 1 >= 32'(etu_n)) begin
            rc <= 0;
            if (rb == 1) begin rs <= R_IDLE; r_sig <= 0; rb <= 0; end
            else rb <= rb + 1;
          end else rc <= rc + 1;
        end
      endcase
      if (r_done && r_bad && m_perr != 16'hFFFF) m_perr <= m_perr + 1;
      if (r_drop && m_ovf != 16'hFFFF) m_ovf <= m_ovf + 1;
      if (r_store && !r_drop) rq.push_back({23'b0, r_bad, r_data});
      if (m_bvalid && m_bready && m_bresp != 2'b00) b_err <= 1;
      if (rx) begin
        if (rq.size() != 0) void'(rq.pop_front());
        if (m_rxc != 16'hFFFF) m_rxc <= m_rxc + 1;
        b_err <= 0;
      end
      if (r_store && !r_drop && rx) ;               // (push and pop in one clock: both above)

      // ---- waiting time ----
      etick <= 0;
      if (!sc_vcc_en) ec <= 0;
      else if (m_ce) begin
        if (32'(ec) + 1 >= 32'(etu_n)) begin ec <= 0; etick <= 1; end
        else ec <= ec + 1;
      end
      if (rst_rise_now || r_done || tx_done) begin wc <= 0; w_on <= 1; end
      else if (!active || rs != R_IDLE || tx_busy || wt == 0) begin wc <= 0; if (!active) w_on <= 0; end
      else if (w_on && etick) begin
        if (32'(wc) + 1 >= 32'(wt)) begin w_on <= 0; wc <= 0; end
        else wc <= wc + 1;
      end
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_idle, !rst_n, !sc_vcc_en && !sc_rst_n && !sc_clk && !sc_io_oe_low && !tx_busy && !m_awvalid
                                 && !m_arvalid && wr_idx == 0 && rx_cnt == 0 && perr_cnt == 0 && ovf_cnt == 0 && !err)
  // power sequence
  `SVA_NXT(a_power_up, !powered && activate && present && enable, powered && !sc_rst_n)
  `SVA_INV(a_status, active == sc_rst_n && powered == sc_vcc_en && present == det_s[1] && det == (present != pres_q))
  `SVA_INV(a_rst_needs_power, !sc_rst_n || sc_vcc_en)
  `SVA_INV(a_clk_needs_power, !sc_clk || sc_vcc_en)
  `SVA_IMP(a_rst_low_time, sc_rst_n && !$past(sc_rst_n), nce == rst_n_clks && $past(rstl))
  `SVA_NXT(a_deactivate, active && go_off, !sc_rst_n)
  `SVA_IMP(a_vcc_off_last, !sc_vcc_en && $past(sc_vcc_en), !sc_rst_n && !sc_clk && quiet >= 13)
  `SVA_IMP(a_clk_half_period, sc_clk != sck_q && seen_edge && !div_chg && sc_rst_n && $past(sc_rst_n), hc == 16'(cd_q))
  // TX
  `SVA_IMP(a_tx_line_idle, sc_io_oe_low, (tx_busy && active) || r_sig)
  `SVA_IMP(a_tx_guard_released, d_run && d_k >= 10, !sc_io_oe_low)
  `SVA_IMP(a_tx_char, d_end, d_par_ok && tq.size() != 0 && d_byte == tq[0])
  `SVA_INV(a_tx_retx_cnt, retx_cnt == m_retx)
  `SVA_IMP(a_tx_done, tx_done, tx_fail == t_fail_m && (t_fail_m || t_left == 0) && !d_on)
  `SVA_IMP(a_tx_read_addr, m_arvalid && m_arready, m_araddr[31:2] >= tx_addr[31:2]
                                                     && m_araddr[31:2] - tx_addr[31:2] + 32'(m_arlen) + 1 <= (32'(tx_len) + 3) / 4)
  // RX
  `SVA_IMP(a_rx_signal, !tx_busy && active, sc_io_oe_low == r_sig)
  `SVA_INV(a_rx_perr, perr == ((r_done && r_bad) || t_failp_m))
  `SVA_IMP(a_ring_word, m_wvalid && m_wready, rq.size() != 0 && m_wdata == rq[0])
  `SVA_IMP(a_ring_addr, m_awvalid, m_awaddr == ring_base + {14'd0, wr_idx, 2'b00} && m_wr_next != rd_idx)
  `SVA_NXT(a_wr_idx, rx, wr_idx == $past(m_wr_next) || !enable)
  `SVA_INV(a_rx_counters, rx_cnt == m_rxc && perr_cnt == m_perr && ovf_cnt == m_ovf)
  // waiting time and errors
  `SVA_INV(a_timeout, timeout == w_fire)
  `SVA_INV(a_err_irq, err_irq == ((rx && b_err_now) || (tx_done && t_err_m)))
  `SVA_IMP(a_err_sticky, err_irq, ##1 err)

  // ---------------- functional coverage ----------------
  covergroup cg_sc @(posedge clk);
    option.per_instance = 1;
    cp_tx_conv: coverpoint {inverse, t1} iff (rst_n && d_end);
    cp_rx_conv: coverpoint {inverse, t1} iff (rst_n && r_done);
    cp_tx_end: coverpoint (!d_nak ? 2'd0 : tries == 4 ? 2'd2 : 2'd1) iff (rst_n && d_end)
      { bins sent = {0}; bins repeated = {1}; bins failed = {2}; }
    cp_tries: coverpoint tries iff (rst_n && d_nak_end) { bins t[] = {[0:4]}; }
    cp_rx_end: coverpoint (!r_bad ? 2'd0 : t1 ? 2'd2 : 2'd1) iff (rst_n && r_done)
      { bins ok = {0}; bins signalled_t0 = {1}; bins flagged_t1 = {2}; }
    cp_rx_drop: coverpoint r_drop iff (rst_n && r_store);
    cp_etu: coverpoint etu iff (rst_n && (d_start || (rs == R_IDLE && r_en && io_q && !m_io)))
      { bins zero = {0}; bins one = {1}; bins short_ = {[2:31]}; bins big = {[32:16'hFFFE]}; bins max = {16'hFFFF}; }
    cp_guard: coverpoint guard iff (rst_n && d_start) { bins zero = {0}; bins mid = {[1:243]}; bins high = {[244:255]}; }
    cp_div: coverpoint clk_div iff (rst_n && m_ce && active) { bins zero = {0}; bins low = {[1:7]}; bins big = {[8:254]}; bins max = {255}; }
    cp_off: coverpoint {deactivate, !present, !enable} iff (rst_n && active && go_off)
      { bins command = {3'b100}; bins removed = {3'b010}; bins disabled = {3'b001}; }
  endgroup
  cg_sc u_cg_sc = new;

  `FC(rx_glitch_rejected, r_glitch)
  `FC(deactivate_during_rst_low, rstl && go_off)
  `FC(deactivate_while_loading, tx_busy && !d_on && $fell(active))
  `FC(card_removed_during_tx, tx_busy && $fell(present))
  `FC(ring_full_wait, rq.size() != 0 && m_wr_next == rd_idx && enable)
  `FC(fifo_full_drop, r_drop)
  `FC(rx_axi_error, rx && b_err_now)
  `FC(tx_axi_error, tx_done && t_err_m)
  `FC(ring_words_zero, rx && ring_words == 0)
  `FC(ring_wrap, rx && m_wr_next == 0 && ring_words > 1)
  `FC(waiting_time, timeout)
  `FC(rx_cnt_saturated, rx && rx_cnt == 16'hFFFF)
  `FC(long_rst, sc_rst_n && !$past(sc_rst_n) && rst_clks == 16'hFFFF)
  `FC_RST(reset_mid_activation, rst_n && powered && !active ##1 !rst_n)
endmodule

bind Smartcard_7816_top Smartcard_7816_sva u_sva (.*);
