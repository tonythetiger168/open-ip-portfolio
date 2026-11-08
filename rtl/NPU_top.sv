// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// NPU: neural processing unit of the phone SoC, an int8 1-D convolution
// engine (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Streams LEN words of int8 activations from SRC (four per word, byte 0
// first) through a 4-tap convolution and writes LEN words of int8 results to
// DST, one result per input sample:
// acc[n] = BIAS + W0*x[n] + W1*x[n-1] + W2*x[n-2] + W3*x[n-3]
// y[n]   = sat8((RELU ? max(acc, 0) : acc) >>> SHIFT)
// - Samples before the first one of a job are 0 (zero padding).
// - Weights are signed 8-bit, BIAS signed 16-bit, SHIFT 0..15 (arithmetic).
// - SATURATIONS counts results clipped to -128 / 127 in the last job.
// - DONE interrupt when a job ends, ERR as well on an AXI error response.
// - CYCLES is the length of the last job in clocks; AXI ID = AXI_ID.
// ============================================================================
module NPU_top #(
  parameter logic [3:0] AXI_ID = 4'd2
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] src_addr,
  input  logic [31:0] dst_addr,
  input  logic [15:0] xfer_len,
  input  logic [7:0]  w0,
  input  logic [7:0]  w1,
  input  logic [7:0]  w2,
  input  logic [7:0]  w3,
  input  logic [15:0] bias,
  input  logic [3:0]  shift,
  input  logic        relu,
  input  logic        start,
  output logic        busy,
  output logic        err,
  output logic [15:0] saturations,
  output logic [31:0] cycles,
  output logic        done,
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
  logic        rs_valid, rs_ready, ws_valid, ws_ready, e_done;
  logic [31:0] rs_data, ws_data;
  logic [23:0] hist;                 // bytes 3, 2, 1 of the previous word (x[n-1], x[n-2], x[n-3] of the next word)
  logic [2:0]  nsat;

  wire go = start && !busy;
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(go), .rd_en(1'b1), .wr_en(1'b1),
    .src(src_addr), .dst(dst_addr), .len(xfer_len),
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

  // x[0..6]: the current word's 4 samples (x[3..6]) after the 3 earlier ones
  logic signed [7:0] x [7];
  always_comb begin
    x[0] = hist[7:0]; x[1] = hist[15:8]; x[2] = hist[23:16];
    for (int b = 0; b < 4; b++) x[3 + b] = rs_data[8*b +: 8];
  end
  always_comb begin
    nsat = '0;
    for (int b = 0; b < 4; b++) begin
      logic signed [19:0] acc;
      logic signed [19:0] sh;
      acc = 20'(signed'(bias)) + 20'(signed'(w0)) * 20'(x[3 + b]) + 20'(signed'(w1)) * 20'(x[2 + b])
          + 20'(signed'(w2)) * 20'(x[1 + b]) + 20'(signed'(w3)) * 20'(x[b]);
      if (relu && acc < 0) acc = '0;
      sh = acc >>> shift;
      if (sh > 20'sd127)       begin ws_data[8*b +: 8] = 8'h7F; nsat = nsat + 3'd1; end
      else if (sh < -20'sd128) begin ws_data[8*b +: 8] = 8'h80; nsat = nsat + 3'd1; end
      else                     ws_data[8*b +: 8] = sh[7:0];
    end
  end
  assign ws_valid = rs_valid;
  assign rs_ready = ws_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hist <= '0; saturations <= '0;
    end else if (go) begin
      hist <= '0; saturations <= '0;
    end else if (rs_valid && rs_ready) begin
      hist <= rs_data[31:8];          // samples 1, 2, 3 of this word
      saturations <= (saturations > 16'hFFFB) ? 16'hFFFF : saturations + 16'(nsat);
    end
  end
  assign done    = e_done;
  assign err_irq = e_done && err;
endmodule
