// SPDX-License-Identifier: Apache-2.0
// CI_Plus_Host (DVB-CI / CI+ host: PC Card bus, CIS / COR, EN 50221 command
// interface, transport stream through the CAM): concurrent SVA against a
// model of the card pins written from the header, + functional coverage.
// - Power: VCC with RESET high for RST_CLKS clocks, READY after its
//   synchroniser, VCC and RESET off on power-off / removal / ENABLE off.
// - Bus cycles, decoded from the pins: CE# and REG# low with a stable
//   address (and write data) SETUP + 1 clocks before the strobe, the strobe
//   low STROBE + 1 clocks plus the WAIT# clocks (at most WAIT_MAX), CE# held
//   HOLD + 1 clocks after it, one strobe at a time, data driven only on
//   writes; BUS_TO / TO_CNT when WAIT# outlasts WAIT_MAX (the byte reads FF).
// - Data: every CIS byte (attribute reads at 0, 2, 4 ...) and every stored
//   RX byte (DATA reads after the size, up to RX_MAX) packed 4 per word must
//   be the next AXI write word; every DATA write of a TX must be the next
//   byte of the TX buffer read over AXI, with the size written to SIZE_LS /
//   SIZE_MS first; RX_LEN / RX_OVF from the size read.
// - Status: TX_CNT / RX_CNT / TO_CNT / TS_CNT, DET, IREQ, ERR_IRQ after an
//   AXI error response; the transport stream routed or bypassed.
// The AXI engine is closed by its own run.
`include "cov_macros.svh"
module CI_Plus_Host_sva (
  input logic        clk, rst_n,
  input logic        ci_vcc_en, ci_reset, ci_cd_n, ci_d_oe, ci_ce_n, ci_reg_n, ci_oe_n, ci_we_n,
  input logic        ci_iord_n, ci_iowr_n, ci_wait_n, ci_ireq_n,
  input logic [14:0] ci_a,
  input logic [7:0]  ci_d_o, ci_d_i,
  input logic [7:0]  ts_in_data, ts_out_data, ci_mo_data, ci_mi_data,
  input logic        ts_in_valid, ts_in_sop, ts_out_valid, ts_out_sop, ci_mo_val, ci_mo_strt, ci_mi_val, ci_mi_strt,
  input logic        enable, ts_route, poll, power_on, power_off, cis_read, cor_write, if_reset, tx_start, rx_arm,
  input logic [3:0]  setup, hold,
  input logic [7:0]  strobe,
  input logic [15:0] wait_max, rst_clks, cis_len, tx_len, rx_max,
  input logic        powered, ready, io_mode, busy, rx_full, rx_ovf, tx_fail, err, present,
  input logic [15:0] rx_len, tx_cnt, rx_cnt, ts_cnt, to_cnt,
  input logic        det, rdy, cfg, tx_done, rx, ireq, bus_to, err_irq,
  input logic [31:0] m_wdata, m_rdata,
  input logic        m_wvalid, m_wready, m_rvalid, m_rready, m_bvalid, m_bready, m_awvalid, m_arvalid,
  input logic [1:0]  m_bresp, m_rresp
);
  `COV_CLOCKING(clk, !rst_n)
  function automatic logic [15:0] sat(input logic [15:0] v); return v == 16'hFFFF ? v : v + 1; endfunction

  logic [1:0]  cd_s, wt_s, iq_s;
  logic        cd_q, iq_q;
  logic [15:0] rh;                                 // clocks RESET has been high
  logic [3:0]  strb_q;                             // {iowr, iord, we, oe} low, last clock
  logic        ce_q;
  logic [7:0]  d_i_q;                             // CI_D_I as the core samples it
  int          c_set, c_strb, c_hold, c_wait;      // clocks in the cycle phases
  logic        in_strb, after_strb;
  logic [14:0] c_a;
  logic [7:0]  c_d;
  logic [3:0]  c_kind;
  // data model
  logic [7:0]  wbq [$];                            // bytes for the AXI write stream
  logic [7:0]  tq [$];                             // TX buffer bytes read over AXI
  int          w_left;                             // bytes of the current write job
  logic [15:0] r_size, r_store, r_got;
  logic        rx_ph;                              // DATA reads belong to an RX message
  int          tx_dw;                              // DATA writes of the TX
  logic        tx_ph, j_err;
  logic [15:0] m_tx, m_rx, m_to, m_ts;
  wire  [3:0]  strb   = {!ci_iowr_n, !ci_iord_n, !ci_we_n, !ci_oe_n};
  wire         s_fall = strb != 0 && strb_q == 0;
  wire         s_rise = strb == 0 && strb_q != 0;
  wire  [7:0]  rd_byte = bus_to ? 8'hFF : d_i_q;
  wire         route  = ts_route && io_mode && ready;
  wire  [15:0] rst_n_clks = (rst_clks == 0) ? 16'd1 : rst_clks;
  wire         go_off = power_off || !present || !enable;
  // the next write word: up to 4 bytes of the job, zero padded
  logic [31:0] w_exp;
  logic        w_ok;
  always_comb begin
    int n;
    n = (w_left < 4) ? w_left : 4;
    w_exp = 0; w_ok = wbq.size() >= n && n > 0;
    for (int i = 0; i < 4; i++) if (i < n && i < wbq.size()) w_exp[8 * i +: 8] = wbq[i];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cd_s <= 2'b11; wt_s <= 2'b11; iq_s <= 2'b11; cd_q <= 1; iq_q <= 1; rh <= 0; strb_q <= 0; ce_q <= 1; d_i_q <= 0;
      c_set <= 0; c_strb <= 0; c_hold <= 0; c_wait <= 0; in_strb <= 0; after_strb <= 0; c_a <= 0; c_d <= 0; c_kind <= 0;
      wbq.delete(); tq.delete(); w_left <= 0; r_size <= 0; r_store <= 0; r_got <= 0; rx_ph <= 0; tx_dw <= 0;
      tx_ph <= 0; j_err <= 0; m_tx <= 0; m_rx <= 0; m_to <= 0; m_ts <= 0;
    end else begin
      cd_s <= {cd_s[0], ci_cd_n}; wt_s <= {wt_s[0], ci_wait_n}; iq_s <= {iq_s[0], ci_ireq_n};
      cd_q <= cd_s[1]; iq_q <= iq_s[1];
      rh <= ci_reset ? rh + 1 : 16'd0;
      strb_q <= strb; ce_q <= ci_ce_n; d_i_q <= ci_d_i;
      // bus cycle phases
      if (!ci_ce_n && ce_q) begin c_set <= 1; c_a <= ci_a; c_d <= ci_d_o; after_strb <= 0; end
      else if (!ci_ce_n && !in_strb && !after_strb && strb == 0) c_set <= c_set + 1;
      if (s_fall) begin in_strb <= 1; c_strb <= 1; c_wait <= 0; c_kind <= strb; end
      else if (in_strb && strb != 0) begin
        c_strb <= c_strb + 1;
        if (c_strb > 32'(strobe)) c_wait <= c_wait + 1;
      end
      if (s_rise) begin in_strb <= 0; after_strb <= 1; c_hold <= 1; end
      else if (after_strb && !ci_ce_n) c_hold <= c_hold + 1;
      if (!ready) begin in_strb <= 0; after_strb <= 0; w_left <= 0; wbq.delete(); end   // power lost: the job is flushed
      // a cycle ends: the byte moved
      if (s_rise && ready) begin
        case (c_kind)
          4'b0001: begin                           // attribute read: CIS
            // a CIS starts at address 0 (the address wraps every 16384
            // bytes of a longer CIS: no restart while bytes are due)
            if (c_a == 0 && w_left == 0) begin w_left <= cis_len; wbq.delete(); end
            wbq.push_back(rd_byte);
          end
          4'b0100: begin                           // I/O read
            if (c_a[1:0] == 2'd2) r_size[7:0] <= rd_byte;
            if (c_a[1:0] == 2'd3) begin
              logic [15:0] sz;
              sz = {rd_byte, r_size[7:0]};
              r_size <= sz; r_store <= (sz > rx_max) ? rx_max : sz; r_got <= 0; rx_ph <= 1;
              w_left <= (sz > rx_max) ? rx_max : sz; wbq.delete();
            end
            if (c_a[1:0] == 2'd0 && rx_ph) begin
              if (r_got < r_store) wbq.push_back(rd_byte);
              r_got <= r_got + 1;
            end
          end
          4'b1000: if (c_a[1:0] == 2'd0) begin     // I/O write to DATA: a TX byte
            if (tq.size() != 0) void'(tq.pop_front());
            tx_dw <= tx_dw + 1;
          end
          default: ;
        endcase
      end
      if (rx) rx_ph <= 0;
      // AXI streams
      if (m_wvalid && m_wready && ready) begin
        int n;
        n = (w_left < 4) ? w_left : 4;
        for (int i = 0; i < 4; i++) if (i < n && wbq.size() != 0) void'(wbq.pop_front());
        w_left <= w_left - n;
      end
      if (m_rvalid && m_rready) for (int i = 0; i < 4; i++) tq.push_back(m_rdata[8 * i +: 8]);
      if ((m_rvalid && m_rready && m_rresp != 0) || (m_bvalid && m_bready && m_bresp != 0)) j_err <= 1;
      if (cfg || tx_done || rx || (power_on && !powered)) j_err <= 0;   // (an aborted job ends without a pulse)
      if (tx_done) begin tq.delete(); tx_dw <= 0; if (!tx_fail) m_tx <= sat(m_tx); end
      if (rx) m_rx <= sat(m_rx);
      if (bus_to) m_to <= sat(m_to);
      if (route && ci_mi_val && ci_mi_strt) m_ts <= sat(m_ts);
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, !ci_vcc_en && !ci_reset && ci_ce_n && ci_oe_n && ci_we_n && ci_iord_n && ci_iowr_n
                                 && !ci_d_oe && !busy && !io_mode && tx_cnt == 0 && rx_cnt == 0 && !m_awvalid && !m_arvalid)
  // power
  `SVA_NXT(a_power_up, !powered && power_on && present && enable, ci_vcc_en && ci_reset)
  `SVA_IMP(a_reset_len, !ci_reset && $past(ci_reset) && ci_vcc_en, $past(rh) + 16'd1 == rst_n_clks)   // rh: clocks before the last
  `SVA_NXT(a_power_off, powered && go_off, !ci_vcc_en && !ci_reset)
  `SVA_INV(a_status, present == !cd_s[1] && det == (cd_s[1] != cd_q) && powered == ci_vcc_en && (!ready || ci_vcc_en))
  `SVA_IMP(a_ready, ready && !$past(ready), $past(rdy) && iq_s[1] && $past(rh) == 0)
  `SVA_INV(a_ireq, ireq == (io_mode && ready && iq_q && !iq_s[1]))
  // bus cycles
  `SVA_INV(a_one_strobe, $countones(strb) <= 1 && (strb == 0 || (!ci_ce_n && !ci_reg_n)))
  `SVA_IMP(a_setup, s_fall, c_set == 32'(setup) + 1 && ci_a == c_a)
  `SVA_IMP(a_strobe, s_rise && ready, c_strb == 32'(strobe) + 1 + c_wait && (wait_max == 0 || c_wait < 32'(wait_max)))
  `SVA_IMP(a_no_wait_no_stretch, s_rise && ready && c_wait == 0, c_strb == 32'(strobe) + 1)
  `SVA_IMP(a_hold, ci_ce_n && !ce_q && after_strb && ready, c_hold == 32'(hold) + 1)
  `SVA_IMP(a_stable, !ci_ce_n && !ce_q && ready, ci_a == $past(ci_a) && (!ci_d_oe || ci_d_o == $past(ci_d_o)))
  `SVA_INV(a_drive, !ci_d_oe || ci_ce_n || (ci_oe_n && ci_iord_n))
  `SVA_IMP(a_bus_to, bus_to, s_rise && wait_max != 0 && c_wait == 32'(wait_max) - 1)
  // data
  `SVA_IMP(a_write_word, m_wvalid && m_wready && ready, w_ok && m_wdata == w_exp)
  `SVA_IMP(a_tx_byte, s_rise && ready && c_kind == 4'b1000 && c_a[1:0] == 2'd0, tq.size() != 0 && c_d == tq[0])
  `SVA_IMP(a_tx_size, s_rise && ready && c_kind == 4'b1000 && c_a[1:1] == 1'b1, c_d == (c_a[0] ? tx_len[15:8] : tx_len[7:0]))
  `SVA_IMP(a_tx_done, tx_done && !tx_fail, tx_dw == tx_len)
  `SVA_IMP(a_rx, rx, rx_len == r_size && rx_ovf == (r_size > rx_max) && r_got == r_size && rx_full)
  // status
  // TX_CNT / RX_CNT count on the clock of TX_DONE / RX (the model a clock later)
  `SVA_INV(a_counters, $past(tx_cnt) == m_tx && $past(rx_cnt) == m_rx && to_cnt == m_to && ts_cnt == m_ts)
  `SVA_INV(a_err_irq, !err_irq || j_err)
  `SVA_IMP(a_err_end, (cfg || tx_done || rx) && j_err && $past(ready), ##1 err)
  // (not on the first clock after a reset: the outputs still hold their reset value)
  `SVA_INV(a_ts, !$past(rst_n) || ci_mo_val == ($past(route) && $past(ts_in_valid)) && ci_mo_data == ($past(route) ? $past(ts_in_data) : 8'h00)
                 && ts_out_valid == ($past(route) ? $past(ci_mi_val) : $past(ts_in_valid))
                 && ts_out_data == ($past(route) ? $past(ci_mi_data) : $past(ts_in_data)))

  covergroup cg_ci @(posedge clk);
    option.per_instance = 1;
    cp_cycle: coverpoint c_kind iff (rst_n && s_rise && ready)
      { bins attr_rd = {4'b0001}; bins attr_wr = {4'b0010}; bins io_rd = {4'b0100}; bins io_wr = {4'b1000}; }
    cp_io_addr: coverpoint c_a[1:0] iff (rst_n && s_rise && ready && c_kind[3:2] != 0);
    cp_waited: coverpoint (bus_to ? 2'd2 : c_wait == 0 ? 2'd0 : 2'd1) iff (rst_n && s_rise && ready)
      { bins none = {0}; bins waited = {1}; bins timed_out = {2}; }
    cp_setup: coverpoint setup iff (rst_n && s_fall) { bins zero = {0}; bins mid = {[1:14]}; bins max = {15}; }
    cp_hold: coverpoint hold iff (rst_n && s_fall) { bins zero = {0}; bins mid = {[1:14]}; bins max = {15}; }
    cp_strobe: coverpoint strobe iff (rst_n && s_fall) { bins zero = {0}; bins small_ = {[1:2]}; bins mid = {[3:254]}; bins max = {255}; }
    cp_rx_size: coverpoint (r_size > rx_max ? 2'd2 : rx_max == 0 ? 2'd0 : 2'd1) iff (rst_n && rx)
      { bins fits = {1}; bins over = {2}; }
    cp_rx_store: coverpoint (r_store == 0 ? 2'd0 : r_store == r_size ? 2'd1 : 2'd2) iff (rst_n && rx)
      { bins none = {0}; bins all_ = {1}; bins part = {2}; }
    cp_end: coverpoint {cfg, tx_done, rx} iff (rst_n && (cfg || tx_done || rx)) { bins cfg_ = {3'b100}; bins tx = {3'b010}; bins rx_ = {3'b001}; }
    cp_off: coverpoint {power_off, !present, !enable} iff (rst_n && powered && go_off)
      { bins command = {3'b100}; bins removed = {3'b010}; bins disabled = {3'b001}; }
  endgroup
  cg_ci u_cg_ci = new;

  `FC(tx_failed, tx_done && tx_fail)
  `FC(abort_during_cis, $fell(ready) && busy && w_left > 0)
  `FC(job_axi_error, err_irq)
  `FC(poll_without_data, s_rise && ready && c_kind == 4'b0100 && c_a[1:0] == 2'd1 && !rd_byte[7] && poll)
  `FC(ts_routed_packet, route && ci_mi_val && ci_mi_strt)
  `FC(command_while_busy, busy && (cis_read || cor_write || tx_start))
  `FC(counter_saturated, tx_done && tx_cnt == 16'hFFFF)
  `FC_RST(reset_mid_operation, rst_n && busy ##1 !rst_n)
endmodule

bind CI_Plus_Host_top CI_Plus_Host_sva u_sva (.*);
