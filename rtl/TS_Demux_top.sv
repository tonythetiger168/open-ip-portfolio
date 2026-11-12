// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// TS_Demux: MPEG-2 transport stream PID filter and packet DMA of the TV SoC
// (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Input: a parallel TSI port, one byte per clk with ts_valid; ts_sync marks
// the first byte of each 188-byte packet; ts_err (TEI from the demodulator)
// marks a corrupted packet.
// - A packet starts at ts_valid && ts_sync. It is dropped (DROP_CNT, DROP
// interrupt) when the sync byte is not 8'h47, ts_err is seen on any of its
// bytes, its transport_error_indicator bit is 1, or the next sync arrives
// before 188 bytes. Bytes outside a packet are ignored.
// - Four PID filters (PIDn, PID_EN bit n). A good packet whose PID matches
// an enabled filter is written to the ring in memory; the others are
// discarded silently. The lowest matching filter wins.
// - Ring: RING_PKTS slots of 192 bytes from RING_BASE. Slot words 0..46 hold
// the 188 bytes (byte i in word i / 4, bits 8 * (i % 4) + 7 : 8 * (i % 4)),
// word 47 is the descriptor {cc_err, tei(0), pusi, filter[1:0], 7'b0,
// cc[3:0], 3'b0, pid[12:0]}. WR_IDX is the next slot the IP writes; software
// consumes slots and writes RD_IDX (RING_PKTS must be at least 2; 0 counts
// as 1, a ring that is always full). When the ring is full (WR_IDX + 1 =
// RD_IDX modulo RING_PKTS) a matching packet is dropped and counted in
// OVF_CNT; so is one that finds both packet buffers still waiting for DMA.
// - Continuity counter: per filter, a packet carrying payload whose CC is not
// the previous CC + 1 sets cc_err in its descriptor, counts in CC_ERR_CNT
// and raises CC_ERR. The first packet after ENABLE has no previous CC.
// - PKT pulses for every packet written; ERR when an AXI error response was
// seen while writing it (ERR in STATUS is sticky until ENABLE goes low).
// - Two packet buffers (ping-pong): one fills while the other is written out
// as one 48-word engine job (bursts of up to 16 beats).
// ============================================================================
module TS_Demux_top #(
  parameter logic [3:0] AXI_ID = 4'd3
) (
  input  logic        clk,
  input  logic        rst_n,
  // TSI
  input  logic        ts_valid,
  input  logic        ts_sync,
  input  logic [7:0]  ts_data,
  input  logic        ts_err,
  // configuration
  input  logic        enable,
  input  logic [3:0]  pid_en,
  input  logic [12:0] pid0,
  input  logic [12:0] pid1,
  input  logic [12:0] pid2,
  input  logic [12:0] pid3,
  input  logic [31:0] ring_base,
  input  logic [15:0] ring_pkts,
  input  logic [15:0] rd_idx,
  // status
  output logic [15:0] wr_idx,
  output logic [15:0] pkt_cnt,
  output logic [15:0] drop_cnt,
  output logic [15:0] cc_err_cnt,
  output logic [15:0] ovf_cnt,
  output logic        busy,
  output logic        err,
  output logic        pkt,
  output logic        drop,
  output logic        cc_err,
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
  // ---------------- packet reception ----------------
  logic [31:0] buf_w [2][48];
  logic [1:0]  full;                        // buffer waiting for / in DMA
  logic        cur;                         // buffer being filled
  logic [7:0]  bcnt;                        // bytes received of the current packet
  logic        rx, bad, own;                // in a packet, packet bad, buffer owned
  logic [31:0] asm_w;
  logic [7:0]  b1, b2;
  logic        afc_pl;
  logic [3:0]  cc_v;
  logic [3:0]  last_cc [4];
  logic [3:0]  cc_seen;

  logic [12:0] pid_v;
  logic [3:0]  hit;
  logic [1:0]  fsel;
  always_comb begin
    pid_v = {b1[4:0], b2};
    hit   = pid_en & {pid_v == pid3, pid_v == pid2, pid_v == pid1, pid_v == pid0};
    fsel  = hit[0] ? 2'd0 : hit[1] ? 2'd1 : hit[2] ? 2'd2 : 2'd3;
  end
  wire [15:0] npk      = (ring_pkts == 0) ? 16'd1 : ring_pkts;
  wire [15:0] wr_next  = (wr_idx + 16'd1 >= npk) ? 16'd0 : wr_idx + 16'd1;
  wire        in_b     = enable && ts_valid;
  wire        start_b  = in_b && ts_sync;
  wire        last_b   = in_b && !ts_sync && rx && bcnt == 8'd187;
  wire        good     = last_b && !bad && !ts_err;
  wire        match    = |hit;
  wire        cc_bad   = afc_pl && cc_seen[fsel] && (cc_v != last_cc[fsel] + 4'd1);
  // the slot of this packet: WR_IDX plus the packets already queued for DMA
  logic [15:0] q_idx;
  logic [1:0]  queued;
  always_comb begin
    q_idx = wr_idx;
    for (int i = 0; i < 2; i++) if (i < queued) q_idx = (q_idx + 16'd1 >= npk) ? 16'd0 : q_idx + 16'd1;
  end
  wire [15:0] q_next   = (q_idx + 16'd1 >= npk) ? 16'd0 : q_idx + 16'd1;
  wire        no_room  = (q_next == rd_idx) || !own;
  wire        accept   = good && match && !no_room;
  wire        dropped  = (start_b && rx) || (last_b && !good);

  always_ff @(posedge clk) begin
    if (in_b && own && (start_b || rx)) begin
      if ((start_b ? 8'd0 : bcnt) % 4 == 3) buf_w[cur][(start_b ? 8'd0 : bcnt) / 4] <= {ts_data, asm_w[31:8]};
    end
    if (accept) buf_w[cur][47] <= {cc_bad, 1'b0, b1[6], fsel, 7'b0, cc_v, 3'b0, pid_v};
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx <= 1'b0; bad <= 1'b0; own <= 1'b0; bcnt <= '0; asm_w <= '0; b1 <= '0; b2 <= '0;
      afc_pl <= 1'b0; cc_v <= '0; cc_seen <= '0; cur <= 1'b0;
      for (int i = 0; i < 4; i++) last_cc[i] <= '0;
      drop_cnt <= '0; cc_err_cnt <= '0; ovf_cnt <= '0;
    end else if (!enable) begin
      rx <= 1'b0; cc_seen <= '0;
      if (!full[0] && !full[1]) cur <= 1'b0;
    end else begin
      if (in_b) begin
        asm_w <= {ts_data, asm_w[31:8]};
        if (start_b) begin
          rx <= 1'b1; bcnt <= 8'd1;
          bad <= (ts_data != 8'h47) || ts_err;
          own <= !full[cur];
        end else if (rx) begin
          bcnt <= bcnt + 8'd1;
          if (ts_err) bad <= 1'b1;
          if (bcnt == 8'd1) begin b1 <= ts_data; if (ts_data[7]) bad <= 1'b1; end
          if (bcnt == 8'd2) b2 <= ts_data;
          if (bcnt == 8'd3) begin afc_pl <= ts_data[4]; cc_v <= ts_data[3:0]; end
          if (last_b) rx <= 1'b0;
        end
      end
      if (dropped && drop_cnt != 16'hFFFF) drop_cnt <= drop_cnt + 16'd1;
      if (good && match) begin
        if (no_room) begin
          if (ovf_cnt != 16'hFFFF) ovf_cnt <= ovf_cnt + 16'd1;
        end else begin
          cur <= ~cur;
          if (afc_pl) begin last_cc[fsel] <= cc_v; cc_seen[fsel] <= 1'b1; end
          if (cc_bad && cc_err_cnt != 16'hFFFF) cc_err_cnt <= cc_err_cnt + 16'd1;
        end
      end
    end
  end
  assign drop   = enable && dropped;
  assign cc_err = enable && accept && cc_bad;

  // ---------------- DMA of full buffers ----------------
  logic        dsel, e_start, e_busy, e_done, e_err, ws_ready, rs_valid;
  logic [31:0] rs_data, e_cycles;
  logic [5:0]  rd_w;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      full <= '0; dsel <= 1'b0; rd_w <= '0; wr_idx <= '0; queued <= '0; err <= 1'b0; pkt_cnt <= '0;
    end else begin
      if (accept) full[cur] <= 1'b1;
      if (e_start) rd_w <= '0;
      else if (ws_ready) rd_w <= rd_w + 6'd1;
      if (e_done) begin
        full[dsel] <= 1'b0; dsel <= ~dsel;
        wr_idx <= wr_next;
        if (e_err) err <= 1'b1;
        if (pkt_cnt != 16'hFFFF) pkt_cnt <= pkt_cnt + 16'd1;
      end
      queued <= queued + 2'(accept) - 2'(e_done);
      if (!enable && !e_busy) begin
        err <= 1'b0;
        if (!full[0] && !full[1]) begin wr_idx <= '0; dsel <= 1'b0; end
      end
    end
  end
  assign e_start = full[dsel] && !e_busy && !e_done;
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(1'b0), .wr_en(1'b1),
    .src(32'h0), .dst(ring_base + 32'(wr_idx) * 32'd192), .len(16'd48),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cycles),
    .rs_valid, .rs_data, .rs_ready(1'b1),
    .ws_valid(e_busy), .ws_data(buf_w[dsel][rd_w]), .ws_ready,
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
  assign pkt     = e_done;
  assign err_irq = e_done && e_err;
  assign busy    = e_busy || (|full);
endmodule
