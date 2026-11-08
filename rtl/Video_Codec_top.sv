// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Video_Codec: video codec of the phone SoC, a lossless DPCM intra coder
// (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Reads LEN words of 8-bit samples (four per word, byte 0 first) at SRC and
// writes LEN words to DST. The predictor of each sample is the one before it
// (128 for the first sample of a job, and of each line when LINE_WORDS is not
// 0), modulo 256:
// - MODE 0 ENCODE: out = x - pred (the residual).
// - MODE 1 DECODE: out = in + pred, pred = the decoded sample; a DECODE of an
// ENCODE output gives the original frame back exactly.
// - ZEROS counts the zero residuals of the last job (ENCODE: in the output,
// DECODE: in the input): a measure of how well the frame compresses.
// - CHECKSUM is the 32-bit sum of the reconstructed frame words (ENCODE: the
// input, DECODE: the output), so encode and decode of one frame match.
// - DONE interrupt when a job ends, ERR as well on an AXI error response.
// - CYCLES is the length of the last job in clocks; AXI ID = AXI_ID.
// ============================================================================
module Video_Codec_top #(
  parameter logic [3:0] AXI_ID = 4'd5
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] src_addr,
  input  logic [31:0] dst_addr,
  input  logic [15:0] xfer_len,
  input  logic        mode,
  input  logic [15:0] line_words,
  input  logic        start,
  output logic        busy,
  output logic        err,
  output logic [15:0] zeros,
  output logic [31:0] checksum,
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
  logic [31:0] rs_data, ws_data, recon;
  logic        mode_q;
  logic [7:0]  pred_q;
  logic [15:0] x;
  logic [2:0]  nz;

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

  wire line_start = (x == 16'd0);
  always_comb begin
    logic [7:0] p;
    p  = line_start ? 8'd128 : pred_q;
    nz = '0;
    for (int b = 0; b < 4; b++) begin
      if (mode_q) begin
        ws_data[8*b +: 8] = rs_data[8*b +: 8] + p;
        recon[8*b +: 8]   = ws_data[8*b +: 8];
        if (rs_data[8*b +: 8] == 8'd0) nz = nz + 3'd1;
      end else begin
        ws_data[8*b +: 8] = rs_data[8*b +: 8] - p;
        recon[8*b +: 8]   = rs_data[8*b +: 8];
        if (ws_data[8*b +: 8] == 8'd0) nz = nz + 3'd1;
      end
      p = recon[8*b +: 8];
    end
  end
  assign ws_valid = rs_valid;
  assign rs_ready = ws_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mode_q <= 1'b0; pred_q <= 8'd128; x <= '0; zeros <= '0; checksum <= '0;
    end else if (go) begin
      mode_q <= mode; pred_q <= 8'd128; x <= '0; zeros <= '0; checksum <= '0;
    end else if (rs_valid && rs_ready) begin
      pred_q   <= recon[31:24];
      zeros    <= (zeros > 16'hFFFB) ? 16'hFFFF : zeros + 16'(nz);
      checksum <= checksum + recon;
      x <= (line_words != 0 && x + 16'd1 >= line_words) ? 16'd0 : x + 16'd1;
    end
  end
  assign done    = e_done;
  assign err_irq = e_done && err;
endmodule
