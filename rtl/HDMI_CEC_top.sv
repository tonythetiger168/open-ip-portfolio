// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// HDMI_CEC: HDMI Consumer Electronics Control controller of the TV SoC
// (initiator and follower) with message DMA (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// The CEC line is open drain: cec_in is the bus level, cec_oe_low = 1 pulls
// it low. One tick is TICK_DIV + 1 clks; the nominal 0.05 ms tick gives the
// CEC timings in ticks: start bit 74 low / 90 period, data bit '0' 30 low,
// '1' 12 low, 48 period, sample point 21.
// Receiver (follower): accepts a start bit with 70..78 low and 86..94
// period, data bits with 8..34 low ('1' when shorter than 21) and 41..55
// period; anything else ends the message with RX_ERR (counted). A message
// is blocks of 10 bits: 8 data bits MSB first, EOM, ACK. When the header's
// destination (bits 3:0) is LA (not 15), the IP acknowledges every block by
// pulling the ACK bit low for 30 ticks. Messages to LA, broadcasts (15),
// or all messages with PROMISC, of 1..16 bytes, are written to the RX ring.
// - RX ring: RX_SLOTS slots of 32 bytes from RX_BASE; word 0 = {16'b0, 5'b0,
// broadcast, acked, 1'b0, 3'b0, len[4:0]}, words 1..4 the bytes (byte i in
// word 1 + i / 4, bits 8 * (i % 4) + 7 : 8 * (i % 4)), words 5..7 zero.
// RX_WR is the next slot, software consumes and writes RX_RD; a message
// that finds the ring full or the previous message not yet written is
// dropped (RX_OVF_CNT). RX pulses when a message is in memory.
// Transmitter (initiator): TX_START reads 5 words from TX_ADDR (word 0 bits
// 4:0 = length 1..16, words 1..4 the bytes as above), waits until the bus
// has been high for SFT ticks (and no message is being received), then
// sends the start bit and the blocks (EOM on the last, ACK sent as '1').
// - At the sample point of every '1' bit it sends, the bus must be high:
// otherwise, in the initiator address (first 4 bits), arbitration is lost;
// elsewhere it is a bit error. Both stop the message at once.
// - ACK: a directed message needs ACK low on every block, a broadcast needs
// it high; otherwise the message stops with NACK. No retransmission (the
// driver retries). TX_DONE pulses at the end with TX_STATUS {err, arb_lost,
// nack, ok}. Messages the IP sends itself are not received.
// - ERR pulses with RX / TX_DONE when the AXI access saw an error response.
// ============================================================================
module HDMI_CEC_top #(
  parameter logic [3:0] AXI_ID = 4'd7
) (
  input  logic        clk,
  input  logic        rst_n,
  // CEC line
  input  logic        cec_in,
  output logic        cec_oe_low,
  // configuration
  input  logic        enable,
  input  logic [15:0] tick_div,
  input  logic [3:0]  la,
  input  logic        promisc,
  input  logic [9:0]  sft,
  input  logic [31:0] rx_base,
  input  logic [7:0]  rx_slots,
  input  logic [7:0]  rx_rd,
  input  logic [31:0] tx_addr,
  input  logic        tx_start,
  // status
  output logic [7:0]  rx_wr,
  output logic [15:0] rx_cnt,
  output logic [15:0] rx_err_cnt,
  output logic [15:0] rx_ovf_cnt,
  output logic [3:0]  tx_status,
  output logic        tx_busy,
  output logic        rx,
  output logic        rx_err,
  output logic        tx_done,
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
  // ---------------- tick and bus ----------------
  logic [15:0] pre;
  logic        tick;
  logic [1:0]  sync;
  logic        bus, bus_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pre <= '0; tick <= 1'b0; sync <= 2'b11; bus_q <= 1'b1;
    end else begin
      sync <= {sync[0], cec_in};
      bus_q <= bus;
      tick <= 1'b0;
      if (pre >= tick_div) begin pre <= '0; tick <= 1'b1; end
      else pre <= pre + 16'd1;
    end
  end
  assign bus = sync[1];
  wire fall = bus_q && !bus;
  wire rise = !bus_q && bus;
  logic [9:0] t_low, t_per, t_idle;            // ticks since the last fall (low part / period), bus high
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin t_low <= '0; t_per <= '0; t_idle <= '0; end
    else begin
      if (fall) begin t_per <= '0; t_low <= '0; end
      else if (tick) begin
        if (t_per != 10'h3FF) t_per <= t_per + 10'd1;
        if (!bus && t_low != 10'h3FF) t_low <= t_low + 10'd1;
      end
      if (!bus) t_idle <= '0;
      else if (tick && t_idle != 10'h3FF) t_idle <= t_idle + 10'd1;
    end
  end
  function automatic logic in_r(input logic [9:0] x, input int lo, input int hi);
    in_r = {22'd0, x} >= lo && {22'd0, x} <= hi;
  endfunction

  // receiver state (used by the transmitter to find the bus free)
  typedef enum logic [2:0] {R_IDLE, R_SLOW, R_SHIGH, R_BLOW, R_BHIGH} rst_t;
  rst_t        rs;
  logic [7:0]  rbyte;
  logic [3:0]  rbit;
  logic [4:0]  rlen;
  logic [7:0]  rbuf [16];
  logic        r_for_us, r_bcast, r_last_eom, r_done, r_err, adrv;
  logic [9:0]  at;                              // ACK drive ticks
  wire         r_idle = (rs == R_IDLE);
  logic        t_fetch_done_q, t_fetch_err;

  // ---------------- transmitter ----------------
  typedef enum logic [2:0] {T_IDLE, T_FETCH, T_FREE, T_START, T_BIT, T_END} tst_t;
  tst_t        ts;
  logic [31:0] txw [5];
  logic [4:0]  tx_len, tblk;
  logic [3:0]  tbit;
  logic [9:0]  tt;                             // ticks into the current bit
  logic        tdrv, tx_res_ok, tx_res_nack, tx_res_arb, tx_res_err, tx_fin;
  logic        t_fetch_req, t_fetch_done;
  wire  [7:0]  tbyte   = txw[1 + tblk / 4][8 * (tblk % 4) +: 8];
  wire         tval    = (tbit < 4'd8) ? tbyte[7 - tbit] : (tbit == 4'd8) ? (tblk == tx_len - 5'd1) : 1'b1;
  wire         t_bcast = (txw[1][3:0] == 4'hF);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ts <= T_IDLE; tblk <= '0; tbit <= '0; tt <= '0; tdrv <= 1'b0; tx_len <= '0;
      tx_res_ok <= 1'b0; tx_res_nack <= 1'b0; tx_res_arb <= 1'b0; tx_res_err <= 1'b0; tx_fin <= 1'b0;
      t_fetch_req <= 1'b0; tx_status <= '0;
    end else begin
      tx_fin <= 1'b0;
      case (ts)
        T_IDLE: if (tx_start && enable) begin
          ts <= T_FETCH; t_fetch_req <= 1'b1;
          tx_res_ok <= 1'b0; tx_res_nack <= 1'b0; tx_res_arb <= 1'b0; tx_res_err <= 1'b0;
        end
        T_FETCH: if (t_fetch_done) begin
          t_fetch_req <= 1'b0;
          tx_len <= txw[0][4:0];
          if (txw[0][4:0] == 5'd0 || txw[0][4:0] > 5'd16 || t_fetch_err) begin
            ts <= T_END; tx_res_err <= 1'b1;
          end else ts <= T_FREE;
        end
        T_FREE: if (t_idle >= sft && r_idle && tick) begin
          ts <= T_START; tt <= '0; tdrv <= 1'b1;
        end
        T_START: if (tick) begin
          tt <= tt + 10'd1;
          if (tt + 10'd1 == 10'd74) tdrv <= 1'b0;
          if (tt + 10'd1 == 10'd90) begin ts <= T_BIT; tt <= '0; tblk <= '0; tbit <= '0; tdrv <= 1'b1; end
        end
        T_BIT: if (tick) begin
          tt <= tt + 10'd1;
          if (tt + 10'd1 == (tval ? 10'd12 : 10'd30)) tdrv <= 1'b0;
          if (tt + 10'd1 == 10'd21 && tval) begin
            if (tbit == 4'd9) begin
              if (bus == t_bcast) begin end                   // directed: low = ACK; broadcast: high = OK
              else begin ts <= T_END; tdrv <= 1'b0; tx_res_nack <= 1'b1; end
            end else if (!bus) begin
              ts <= T_END; tdrv <= 1'b0;
              if (tblk == 5'd0 && tbit < 4'd4) tx_res_arb <= 1'b1; else tx_res_err <= 1'b1;
            end
          end
          if (tt + 10'd1 == 10'd48) begin
            tt <= '0;
            if (tbit == 4'd9) begin
              tbit <= '0;
              if (tblk + 5'd1 == tx_len) begin ts <= T_END; tx_res_ok <= 1'b1; end
              else begin tblk <= tblk + 5'd1; tdrv <= 1'b1; end
            end else begin tbit <= tbit + 4'd1; tdrv <= 1'b1; end
          end
        end
        T_END: begin
          ts <= T_IDLE; tx_fin <= 1'b1; tdrv <= 1'b0;
          tx_status <= {tx_res_err, tx_res_arb, tx_res_nack, tx_res_ok};
        end
        default: ts <= T_IDLE;
      endcase
      if (!enable && ts != T_FETCH) begin ts <= T_IDLE; tdrv <= 1'b0; end
    end
  end
  wire t_active = (ts == T_START) || (ts == T_BIT);
  assign tx_busy = (ts != T_IDLE);

  // ---------------- receiver ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs <= R_IDLE; rbyte <= '0; rbit <= '0; rlen <= '0; r_for_us <= 1'b0; r_bcast <= 1'b0;
      r_last_eom <= 1'b0; r_done <= 1'b0; r_err <= 1'b0; adrv <= 1'b0; at <= '0;
    end else begin
      r_done <= 1'b0; r_err <= 1'b0;
      if (adrv && tick) begin
        at <= at + 10'd1;
        if (at + 10'd1 >= 10'd30) adrv <= 1'b0;
      end
      if (!enable || t_active) begin
        rs <= R_IDLE; adrv <= 1'b0;
      end else case (rs)
        R_IDLE:  if (fall) rs <= R_SLOW;
        R_SLOW:  if (rise) begin
                   if (in_r(t_low, 70, 78)) rs <= R_SHIGH; else rs <= R_IDLE;
                 end else if (t_low > 10'd78) rs <= R_IDLE;
        R_SHIGH: if (fall) begin
                   if (in_r(t_per, 86, 94)) begin rs <= R_BLOW; rbit <= '0; rlen <= '0; rbyte <= '0; end
                   else begin rs <= R_SLOW; r_err <= 1'b1; end
                 end else if (t_per > 10'd94) begin rs <= R_IDLE; r_err <= 1'b1; end
        R_BLOW:  begin
                   if (rise) begin
                     if (!in_r(t_low, 8, 34)) begin rs <= R_IDLE; r_err <= 1'b1; end
                     else begin
                       rs <= R_BHIGH;
                       if (rbit < 4'd8) rbyte <= {rbyte[6:0], t_low < 10'd21};
                       if (rbit == 4'd8) r_last_eom <= (t_low < 10'd21);
                       if (rbit == 4'd7 && rlen == 5'd0) begin
                         r_for_us <= ({rbyte[2:0], t_low < 10'd21} == la) && la != 4'hF;
                         r_bcast  <= ({rbyte[2:0], t_low < 10'd21} == 4'hF);
                       end
                       if (rbit == 4'd9) begin
                         if (rlen == 5'd16) begin rs <= R_IDLE; r_err <= 1'b1; end
                         else begin
                           rbuf[rlen[3:0]] <= rbyte;
                           rlen <= rlen + 5'd1;
                           if (r_last_eom) begin rs <= R_IDLE; r_done <= 1'b1; end
                         end
                       end
                     end
                   end else if (t_low > 10'd34) begin rs <= R_IDLE; r_err <= 1'b1; end
                 end
        R_BHIGH: if (fall) begin
                   if (!in_r(t_per, 41, 55)) begin rs <= R_SLOW; r_err <= 1'b1; end
                   else begin
                     rs <= R_BLOW;
                     rbit <= (rbit == 4'd9) ? 4'd0 : rbit + 4'd1;
                     // follower ACK: pull the ACK bit low for 30 ticks
                     if (rbit == 4'd8 && r_for_us) begin adrv <= 1'b1; at <= '0; end
                   end
                 end else if (t_per > 10'd55) begin rs <= R_IDLE; r_err <= 1'b1; end
        default: rs <= R_IDLE;
      endcase
    end
  end
  assign cec_oe_low = enable && (tdrv || adrv);

  // ---------------- RX message buffer and DMA ----------------
  logic        r_pend, r_acked, r_bc;
  logic [4:0]  r_len;
  logic [7:0]  rmsg [16];
  wire  [7:0]  ns_      = (rx_slots == 0) ? 8'd1 : rx_slots;
  wire  [7:0]  rx_next  = (rx_wr + 8'd1 >= ns_) ? 8'd0 : rx_wr + 8'd1;
  wire         keep     = r_done && (r_for_us || r_bcast || promisc);
  logic        e_start, e_busy, e_done, e_err, rs_valid, ws_ready, job_tx;
  logic [31:0] rs_data, e_cycles;
  logic [2:0]  wi, ri;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_pend <= 1'b0; r_acked <= 1'b0; r_bc <= 1'b0; r_len <= '0;
      rx_wr <= '0; rx_cnt <= '0; rx_err_cnt <= '0; rx_ovf_cnt <= '0;
    end else begin
      if (keep) begin
        if (r_pend || rx_next == rx_rd) begin
          if (rx_ovf_cnt != 16'hFFFF) rx_ovf_cnt <= rx_ovf_cnt + 16'd1;
        end else begin
          r_pend <= 1'b1; r_len <= rlen + 5'd0; r_acked <= r_for_us && !r_bcast; r_bc <= r_bcast;
          for (int i = 0; i < 16; i++) rmsg[i] <= rbuf[i];
        end
      end
      if (r_err && rx_err_cnt != 16'hFFFF) rx_err_cnt <= rx_err_cnt + 16'd1;
      if (e_done && !job_tx) begin
        r_pend <= 1'b0; rx_wr <= rx_next;
        if (rx_cnt != 16'hFFFF) rx_cnt <= rx_cnt + 16'd1;
      end
      if (!enable) begin
        if (!e_busy) begin r_pend <= 1'b0; rx_wr <= '0; end
      end
    end
  end
  // engine jobs: RX store (8 words) has priority over the TX fetch (5 words)
  wire want_rx = r_pend && !e_busy && !e_done;
  wire want_tx = t_fetch_req && !t_fetch_done_q && !e_busy && !e_done;
  assign e_start = want_rx || want_tx;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin job_tx <= 1'b0; wi <= '0; ri <= '0; t_fetch_done_q <= 1'b0; t_fetch_err <= 1'b0; end
    else begin
      if (e_start) begin job_tx <= !want_rx; wi <= '0; ri <= '0; end
      if (ws_ready) wi <= wi + 3'd1;
      if (rs_valid) begin txw[ri] <= rs_data; ri <= ri + 3'd1; end
      if (e_done && job_tx) begin t_fetch_done_q <= 1'b1; t_fetch_err <= e_err; end
      if (ts != T_FETCH) t_fetch_done_q <= 1'b0;
    end
  end
  assign t_fetch_done = t_fetch_done_q;
  logic [31:0] rword;
  always_comb begin
    case (wi)
      3'd0: rword = {16'b0, 5'b0, r_bc, r_acked, 1'b0, 3'b0, r_len};
      3'd1, 3'd2, 3'd3, 3'd4: rword = {rmsg[4 * (wi - 1) + 3], rmsg[4 * (wi - 1) + 2], rmsg[4 * (wi - 1) + 1], rmsg[4 * (wi - 1)]};
      default: rword = 32'h0;
    endcase
  end
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(!want_rx), .wr_en(want_rx),
    .src(tx_addr), .dst(rx_base + {19'b0, rx_wr, 5'b0}), .len(want_rx ? 16'd8 : 16'd5),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cycles),
    .rs_valid, .rs_data, .rs_ready(1'b1), .ws_valid(e_busy && !job_tx), .ws_data(rword), .ws_ready,
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
  assign rx      = e_done && !job_tx;
  assign rx_err  = r_err;
  assign tx_done = tx_fin;
  assign err_irq = (e_done && !job_tx && e_err) || (tx_fin && tx_res_err && t_fetch_err);
endmodule
