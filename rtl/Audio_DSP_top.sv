// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Audio_DSP: audio DSP of the phone SoC, a stereo PCM gain and mixing stage
// (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Processes LEN stereo frames of 16-bit signed PCM (one frame per 32-bit
// word: left in bits 15:0, right in bits 31:16) from SRC to DST:
// y = sat16((x * GAIN) >>> 8), GAIN signed Q8.8 per channel (256 = 0 dB).
// - MIX 1: the mono downmix (L + R) / 2 is computed first and sent to both
// channels (for a mono speaker path).
// - MUTE 1: every output sample is 0 (the job still runs, at full rate).
// - PEAK is the largest |y| of the last job (a level meter), CLIPS the
// number of output samples that saturated.
// - DONE interrupt when a job ends, ERR as well on an AXI error response.
// - CYCLES is the length of the last job in clocks; AXI ID = AXI_ID.
// ============================================================================
module Audio_DSP_top #(
  parameter logic [3:0] AXI_ID = 4'd8
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] src_addr,
  input  logic [31:0] dst_addr,
  input  logic [15:0] xfer_len,
  input  logic [15:0] gain_l,
  input  logic [15:0] gain_r,
  input  logic        mix,
  input  logic        mute,
  input  logic        start,
  output logic        busy,
  output logic        err,
  output logic [15:0] peak,
  output logic [15:0] clips,
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
  logic [15:0] pk;
  logic [1:0]  nclip;

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

  always_comb begin
    logic signed [15:0] in [2];
    logic signed [16:0] m;
    logic signed [31:0] p;
    logic signed [15:0] y;
    logic        [15:0] ay;
    m = 17'(signed'(rs_data[15:0])) + 17'(signed'(rs_data[31:16]));
    in[0] = mix ? m[16:1] : rs_data[15:0];
    in[1] = mix ? m[16:1] : rs_data[31:16];
    pk = '0; nclip = '0;
    for (int c = 0; c < 2; c++) begin
      p = (32'(in[c]) * 32'(signed'(c == 0 ? gain_l : gain_r))) >>> 8;
      if (mute)                   y = '0;
      else if (p > 32'sd32767)    begin y = 16'sd32767;  nclip = nclip + 2'd1; end
      else if (p < -32'sd32768)   begin y = -16'sd32768; nclip = nclip + 2'd1; end
      else                        y = p[15:0];
      ws_data[16*c +: 16] = y;
      ay = y[15] ? (~y + 16'd1) : y;
      if (ay > pk) pk = ay;
    end
  end
  assign ws_valid = rs_valid;
  assign rs_ready = ws_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      peak <= '0; clips <= '0;
    end else if (go) begin
      peak <= '0; clips <= '0;
    end else if (rs_valid && rs_ready) begin
      if (pk > peak) peak <= pk;
      clips <= (clips > 16'hFFFD) ? 16'hFFFF : clips + 16'(nclip);
    end
  end
  assign done    = e_done;
  assign err_irq = e_done && err;
endmodule
