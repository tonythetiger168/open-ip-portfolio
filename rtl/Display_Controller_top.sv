// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Display_Controller: display processor (DPU) scan-out of the phone SoC
// (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Fetches a frame of LEN RGBA8888 pixels (one per 32-bit word) at SRC with
// long streaming reads and sends it to the panel interface (for example a
// DSI or DPI transmitter) as a pixel stream:
// - pix_valid / pix_data / pix_ready, one pixel per beat; pix_hsync marks
// the last pixel of each line of LINE_WORDS pixels, pix_vsync the last
// pixel of the frame.
// - FRAME_CRC is the CRC-32 (IEEE 802.3, bytes in little-endian order) of
// the pixels sent, the usual display self-test signature.
// - UNDERRUNS counts clocks in which the panel was ready while the frame was
// not finished and no pixel was available (a starved display FIFO).
// - DONE interrupt when the last pixel is sent, ERR as well on an AXI error
// response. CYCLES is the length of the last frame in clocks.
// - AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.
// ============================================================================
module Display_Controller_top #(
  parameter logic [3:0] AXI_ID = 4'd4
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] src_addr,
  input  logic [15:0] xfer_len,
  input  logic [15:0] line_words,
  input  logic        start,
  output logic        busy,
  output logic        err,
  output logic [31:0] frame_crc,
  output logic [15:0] underruns,
  output logic [31:0] cycles,
  output logic        done,
  output logic        err_irq,
  // pixel stream to the panel interface
  output logic        pix_valid,
  output logic [31:0] pix_data,
  output logic        pix_hsync,
  output logic        pix_vsync,
  input  logic        pix_ready,
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
  logic [31:0] rs_data, ws_data, crc;
  logic [15:0] x, left;

  function automatic logic [31:0] crc32_word(input logic [31:0] c, input logic [31:0] d);
    for (int i = 0; i < 32; i++)
      c = (c[0] ^ d[i]) ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
    crc32_word = c;
  endfunction

  wire go = start && !busy;
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(go), .rd_en(1'b1), .wr_en(1'b0),
    .src(src_addr), .dst(32'd0), .len(xfer_len),
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
  assign ws_valid = 1'b0;
  assign ws_data  = '0;

  assign pix_valid = rs_valid;
  assign pix_data  = rs_data;
  assign rs_ready  = pix_ready;
  assign pix_hsync = rs_valid && (line_words == 0 || x + 16'd1 >= line_words || left == 16'd1);
  assign pix_vsync = rs_valid && left == 16'd1;
  assign frame_crc = ~crc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      crc <= 32'hFFFF_FFFF; x <= '0; left <= '0; underruns <= '0;
    end else if (go) begin
      crc <= 32'hFFFF_FFFF; x <= '0; left <= xfer_len; underruns <= '0;
    end else begin
      if (rs_valid && rs_ready) begin
        crc  <= crc32_word(crc, rs_data);
        left <= left - 16'd1;
        x    <= (line_words == 0 || x + 16'd1 >= line_words) ? 16'd0 : x + 16'd1;
      end else if (busy && pix_ready && !rs_valid && left != 0 && underruns != 16'hFFFF) begin
        underruns <= underruns + 16'd1;
      end
    end
  end
  assign done    = e_done;
  assign err_irq = e_done && err;
  wire unused = &{1'b0, ws_ready};
endmodule
