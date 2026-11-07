// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DMA: 4-channel system DMA of the phone SoC (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Each channel has its own SRC, DST, LEN (32-bit words) and MODE; writing
// its START bit queues it. Queued channels are served one job at a time in
// round-robin order by the shared AXI4 data mover (rtl/soc_ss_axi_engine.sv).
// - MODE 0 COPY: read LEN words at SRC and write them to DST.
// - MODE 1 FILL: write LEN copies of the channel's FILL word to DST (no reads).
// - A channel's DONE interrupt is set when its job ends; ERR as well when the
// job saw an AXI error response (SLVERR / DECERR).
// - CHECKSUM is the 32-bit sum of the words written by the last job;
// CYCLES its length in clocks; STATUS shows the queued and active channels.
// - AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.
// ============================================================================
module DMA_top #(
  parameter logic [3:0] AXI_ID = 4'd7
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] src0, src1, src2, src3,
  input  logic [31:0] dst0, dst1, dst2, dst3,
  input  logic [15:0] len0, len1, len2, len3,
  input  logic        mode0, mode1, mode2, mode3,
  input  logic [31:0] fill0, fill1, fill2, fill3,
  input  logic        start0, start1, start2, start3,
  output logic [3:0]  pending,
  output logic        busy,
  output logic [1:0]  active_ch,
  output logic        err,
  output logic [31:0] checksum,
  output logic [31:0] cycles,
  output logic        done0, done1, done2, done3,
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
  // channel registers side by side: channel c is bits [W*c +: W]
  logic [127:0] src, dst, fill;
  logic [63:0]  len;
  logic [3:0]   mode, start;
  assign src  = {src3, src2, src1, src0};
  assign dst  = {dst3, dst2, dst1, dst0};
  assign fill = {fill3, fill2, fill1, fill0};
  assign len  = {len3, len2, len1, len0};
  assign mode  = {mode3, mode2, mode1, mode0};
  assign start = {start3, start2, start1, start0};

  logic        e_start, e_busy, e_done;
  logic        rs_valid, rs_ready, ws_valid, ws_ready;
  logic [31:0] rs_data, ws_data;
  logic [1:0]  ch, nxt;
  logic        run;

  // round robin: the first pending channel after the last one served
  always_comb begin
    logic [1:0] c;
    nxt = ch;
    for (int k = 4; k >= 1; k--) begin
      c = ch + k[1:0];          // 2-bit wrap: ch+1, ch+2, ch+3, ch
      if (pending[c]) nxt = c;
    end
  end
  assign e_start = !run && (pending != 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending <= '0; ch <= 2'd3; run <= 1'b0; checksum <= '0;
    end else begin
      if (e_start) begin
        ch <= nxt; run <= 1'b1; checksum <= '0;
      end else if (e_done) begin
        run <= 1'b0;
      end
      if (ws_valid && ws_ready) checksum <= checksum + ws_data;
      pending <= (pending | start) & ~(e_start ? (4'b1 << nxt) : 4'b0);
    end
  end
  assign busy      = run;
  assign active_ch = ch;

  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(!mode[nxt]), .wr_en(1'b1),
    .src(src[32*nxt +: 32]), .dst(dst[32*nxt +: 32]), .len(len[16*nxt +: 16]),
    .busy(e_busy), .done(e_done), .err, .cycles,
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
  // datapath: COPY passes the read stream through, FILL repeats the fill word
  wire fill_m = mode[ch];
  assign ws_valid = fill_m ? run : rs_valid;
  assign ws_data  = fill_m ? fill[32*ch +: 32] : rs_data;
  assign rs_ready = ws_ready;

  assign done0 = e_done && ch == 2'd0;
  assign done1 = e_done && ch == 2'd1;
  assign done2 = e_done && ch == 2'd2;
  assign done3 = e_done && ch == 2'd3;
  assign err_irq = e_done && err;
  wire unused = e_busy;
endmodule
