// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Sensor_Hub: always-on sensor hub of the phone SoC, a sample decimator and
// batching writer (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Collects 16-bit samples from a sensor interface (for example an I2C / I3C
// or SPI controller reading an accelerometer), averages each group of
// 2^AVG_LOG2 samples (AVG_LOG2 = 0..7, unsigned, truncating), packs two
// averages per 32-bit word (the first in bits 15:0) and batches LEN words
// into memory at DST, so the application processor can sleep until a batch
// is complete.
// - Samples arrive on sns_valid / sns_data (no back-pressure); samples are
// taken only while a job still needs words. When a packed word cannot be queued because
// the write FIFO is full it is dropped and DROPS counts it.
// - WAKE interrupt when an average is greater than THRESHOLD and WAKE_EN is
// set (a motion / gesture wake-up), at most once per job.
// - DONE interrupt when the batch is written, ERR as well on an AXI error
// response. LAST_AVG is the latest average, CYCLES the batch length.
// - AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.
// ============================================================================
module Sensor_Hub_top #(
  parameter logic [3:0] AXI_ID = 4'd9
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] dst_addr,
  input  logic [15:0] xfer_len,
  input  logic [2:0]  avg_log2,
  input  logic [15:0] threshold,
  input  logic        wake_en,
  input  logic        start,
  output logic        busy,
  output logic        err,
  output logic [15:0] last_avg,
  output logic [15:0] drops,
  output logic [31:0] cycles,
  output logic        done,
  output logic        err_irq,
  output logic        wake,
  // sensor sample input
  input  logic        sns_valid,
  input  logic [15:0] sns_data,
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
  logic        rs_valid, rs_ready, ws_valid, ws_ready, e_done;
  logic [31:0] rs_data, ws_data;
  logic [22:0] acc;
  logic [7:0]  cnt;
  logic [2:0]  k;
  logic [15:0] lo;
  logic        half, woke;
  logic [15:0] avg;
  logic        avg_ok;
  logic [15:0] nwords, len_q;     // words queued in this job, batch length

  wire go = start && !busy;
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(go), .rd_en(1'b0), .wr_en(1'b1),
    .src(32'd0), .dst(dst_addr), .len(xfer_len),
    .busy, .done(e_done), .err, .cycles,
    .rs_valid, .rs_data, .rs_ready, .ws_valid, .ws_data, .ws_ready,
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
  assign rs_ready = 1'b0;

  // one average per 2^k samples
  wire        take  = busy && sns_valid && nwords != len_q;
  wire [22:0] acc_n = acc + 23'(sns_data);
  assign avg_ok = take && (cnt == 8'((9'd1 << k) - 9'd1));
  assign avg    = 16'(acc_n >> k);
  assign ws_valid = avg_ok && half;
  assign ws_data  = {avg, lo};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc <= '0; cnt <= '0; k <= '0; lo <= '0; half <= 1'b0; woke <= 1'b0;
      last_avg <= '0; drops <= '0; nwords <= '0; len_q <= '0;
    end else if (go) begin
      acc <= '0; cnt <= '0; k <= avg_log2; lo <= '0; half <= 1'b0; woke <= 1'b0;
      drops <= '0; nwords <= '0; len_q <= xfer_len;
    end else if (take) begin
      if (avg_ok) begin
        acc <= '0; cnt <= '0; last_avg <= avg;
        half <= ~half;
        if (!half) lo <= avg;
        else if (ws_ready) nwords <= nwords + 16'd1;
        else if (!ws_ready && drops != 16'hFFFF) drops <= drops + 16'd1;
        if (wake) woke <= 1'b1;
      end else begin
        acc <= acc_n; cnt <= cnt + 8'd1;
      end
    end
  end
  assign wake    = avg_ok && wake_en && !woke && avg > threshold;
  assign done    = e_done;
  assign err_irq = e_done && err;
  wire unused = &{1'b0, rs_valid, rs_data};
endmodule
