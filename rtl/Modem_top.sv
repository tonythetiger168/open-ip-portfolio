// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Modem: cellular modem baseband data path of the phone SoC, a
// scrambler / descrambler with CRC (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Moves LEN words of a transport block from SRC to DST, XOR-ing each word
// with 32 bits of a scrambling sequence, and computes the block's CRC:
// - Sequence: a 32-bit Galois LFSR, polynomial x^32 + x^22 + x^2 + x + 1
// (mask 32'h8020_0003), loaded with SEED at the start of a job (SEED 0 is
// replaced by 1). Each step outputs bit 0, then shifts right and XORs the
// mask when that bit was 1; bit i of a word's key is the output of step i.
// Scrambling and descrambling are the same operation.
// - CRC is the CRC-32 (IEEE 802.3, reflected, init and final XOR
// 32'hFFFF_FFFF, bytes in little-endian order) of the input words when
// CRC_SEL is 0 (transmit: CRC of the payload) and of the output words when
// it is 1 (receive: CRC of the descrambled payload).
// - BYPASS 1: no scrambling (key 0), CRC only.
// - DONE interrupt when a job ends, ERR as well on an AXI error response.
// - CYCLES is the length of the last job in clocks; AXI ID = AXI_ID.
// ============================================================================
module Modem_top #(
  parameter logic [3:0] AXI_ID = 4'd6
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] src_addr,
  input  logic [31:0] dst_addr,
  input  logic [15:0] xfer_len,
  input  logic [31:0] seed,
  input  logic        crc_sel,
  input  logic        bypass,
  input  logic        start,
  output logic        busy,
  output logic        err,
  output logic [31:0] crc,
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
  logic [31:0] rs_data, ws_data, lfsr, lfsr_n, key, crc_q;
  logic        sel_q, byp_q;

  function automatic logic [31:0] crc32_word(input logic [31:0] c, input logic [31:0] d);
    for (int i = 0; i < 32; i++)
      c = (c[0] ^ d[i]) ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
    crc32_word = c;
  endfunction

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
    logic [31:0] s;
    s = lfsr;
    for (int i = 0; i < 32; i++) begin
      key[i] = s[0];
      s = s[0] ? ((s >> 1) ^ 32'h8020_0003) : (s >> 1);
    end
    lfsr_n = s;
  end
  assign ws_data  = rs_data ^ (byp_q ? 32'd0 : key);
  assign ws_valid = rs_valid;
  assign rs_ready = ws_ready;
  assign crc      = ~crc_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lfsr <= 32'd1; crc_q <= 32'hFFFF_FFFF; sel_q <= 1'b0; byp_q <= 1'b0;
    end else if (go) begin
      lfsr <= (seed == 0) ? 32'd1 : seed; crc_q <= 32'hFFFF_FFFF; sel_q <= crc_sel; byp_q <= bypass;
    end else if (rs_valid && rs_ready) begin
      lfsr  <= lfsr_n;
      crc_q <= crc32_word(crc_q, sel_q ? ws_data : rs_data);
    end
  end
  assign done    = e_done;
  assign err_irq = e_done && err;
endmodule
