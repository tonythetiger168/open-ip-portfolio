// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Crypto_DMA: AES-GCM engine with an AXI4 DMA (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// The unchanged AES_GCM_top core (AES-128 / AES-256, 96-bit IV) streaming a
// message from memory to memory.
// - Source buffer at SRC_ADDR: the AAD (AAD_LEN bytes) padded with zeros to
//   a 16-byte boundary, then the text (TXT_LEN bytes). Bytes are in address
//   order: byte 0 of a block is the byte at the lowest address (bits 7:0 of
//   the first word).
// - The output text (ciphertext, or plaintext when decrypting) is written
//   to DST_ADDR, TXT_LEN bytes rounded up to 16 with zero padding.
// - Encrypt: TAG holds the tag when the job ends. Decrypt: TAG_OK says
//   whether TAG_IN (first TAG_LEN bytes) matched. The plaintext is written
//   before the tag is checked: software uses it only when TAG_OK is 1.
// - Two soc_ss_axi_engine instances share the AXI4 manager port: one reads
//   (AR / R channels), one writes (AW / W / B), so the read and the write
//   lengths can differ. Both use ID AXI_ID.
// - DONE interrupt when the job ends (both transfers and the tag); ERR as
//   well when it saw an AXI error response (STATUS.err) or a core error
//   (STATUS.gcm_err with the core's ERR_CODE).
// - AXI bursts of up to 16 beats, never across 4 KB.
// ============================================================================
module Crypto_DMA_top #(
  parameter logic [3:0] AXI_ID = 4'd9
) (
  input  logic         clk,
  input  logic         rst_n,
  // message
  input  logic         key256,
  input  logic         decrypt,
  input  logic         key_sel,
  input  logic [3:0]   tag_len,
  input  logic [255:0] key,
  input  logic [95:0]  iv,
  input  logic [127:0] tag_in,
  input  logic [255:0] sl_key,
  input  logic         sl_valid,
  // job
  input  logic [31:0]  src_addr,
  input  logic [31:0]  dst_addr,
  input  logic [15:0]  aad_len,
  input  logic [15:0]  txt_len,
  input  logic         start,
  output logic         busy,
  output logic         err,
  output logic         gcm_err,
  output logic [2:0]   err_code,
  output logic         tag_ok,
  output logic [127:0] tag,
  output logic [31:0]  cycles,
  output logic         done,
  output logic         err_irq,
  // AXI4 manager (m_*): 32-bit address and data, 4-bit ID
  output logic [3:0]   m_awid,
  output logic [31:0]  m_awaddr,
  output logic [7:0]   m_awlen,
  output logic [2:0]   m_awsize,
  output logic [1:0]   m_awburst,
  output logic [2:0]   m_awprot,
  output logic         m_awvalid,
  input  logic         m_awready,
  output logic [31:0]  m_wdata,
  output logic [3:0]   m_wstrb,
  output logic         m_wlast,
  output logic         m_wvalid,
  input  logic         m_wready,
  input  logic [3:0]   m_bid,
  input  logic [1:0]   m_bresp,
  input  logic         m_bvalid,
  output logic         m_bready,
  output logic [3:0]   m_arid,
  output logic [31:0]  m_araddr,
  output logic [7:0]   m_arlen,
  output logic [2:0]   m_arsize,
  output logic [1:0]   m_arburst,
  output logic [2:0]   m_arprot,
  output logic         m_arvalid,
  input  logic         m_arready,
  input  logic [3:0]   m_rid,
  input  logic [31:0]  m_rdata,
  input  logic [1:0]   m_rresp,
  input  logic         m_rlast,
  input  logic         m_rvalid,
  output logic         m_rready
);
  // ---------------------------------------------------------------- sizes
  // 13 bits: 65535 bytes is 4096 blocks
  wire [12:0] nab = {1'b0, aad_len[15:4]} + {12'd0, aad_len[3:0] != 4'd0};   // AAD blocks
  wire [12:0] ntb = {1'b0, txt_len[15:4]} + {12'd0, txt_len[3:0] != 4'd0};   // text blocks
  wire [13:0] nbl = {1'b0, nab} + {1'b0, ntb};

  logic        go;
  logic        rs_valid, rs_ready, ws_valid, ws_ready;
  logic [31:0] rs_data, ws_data;
  logic        r_busy, r_done, r_err, w_busy, w_done, w_err;
  logic [31:0] r_cyc, w_cyc;
  logic [3:0]  r_awid, w_arid;
  logic [31:0] r_awaddr, r_wdata, w_araddr;
  logic [7:0]  r_awlen, w_arlen;
  logic [2:0]  r_awsize, r_awprot, w_arsize, w_arprot;
  logic [1:0]  r_awburst, w_arburst;
  logic [3:0]  r_wstrb;
  logic        r_awvalid, r_wlast, r_wvalid, r_bready, w_arvalid, w_rready;
  logic [31:0] w_rs_data;
  logic        w_rs_valid, r_ws_ready;

  soc_ss_axi_engine #(.ID(AXI_ID)) u_rd (
    .clk, .rst_n,
    .start(go && nbl != 14'd0), .rd_en(1'b1), .wr_en(1'b0),
    .src(src_addr), .dst(32'd0), .len({nbl, 2'b00}),
    .busy(r_busy), .done(r_done), .err(r_err), .cycles(r_cyc),
    .rs_valid, .rs_data, .rs_ready, .ws_valid(1'b0), .ws_data(32'd0), .ws_ready(r_ws_ready),
    .m_awid(r_awid), .m_awaddr(r_awaddr), .m_awlen(r_awlen), .m_awsize(r_awsize),
    .m_awburst(r_awburst), .m_awprot(r_awprot), .m_awvalid(r_awvalid), .m_awready(1'b0),
    .m_wdata(r_wdata), .m_wstrb(r_wstrb), .m_wlast(r_wlast), .m_wvalid(r_wvalid), .m_wready(1'b0),
    .m_bid(4'd0), .m_bresp(2'd0), .m_bvalid(1'b0), .m_bready(r_bready),
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
  );
  soc_ss_axi_engine #(.ID(AXI_ID)) u_wr (
    .clk, .rst_n,
    .start(go && ntb != 13'd0), .rd_en(1'b0), .wr_en(1'b1),
    .src(32'd0), .dst(dst_addr), .len({1'b0, ntb, 2'b00}),
    .busy(w_busy), .done(w_done), .err(w_err), .cycles(w_cyc),
    .rs_valid(w_rs_valid), .rs_data(w_rs_data), .rs_ready(1'b0), .ws_valid, .ws_data, .ws_ready,
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid(w_arid), .m_araddr(w_araddr), .m_arlen(w_arlen), .m_arsize(w_arsize),
    .m_arburst(w_arburst), .m_arprot(w_arprot), .m_arvalid(w_arvalid), .m_arready(1'b0),
    .m_rid(4'd0), .m_rdata(32'd0), .m_rresp(2'd0), .m_rlast(1'b0), .m_rvalid(1'b0), .m_rready(w_rready)
  );

  // ---------------------------------------------------------------- core
  logic         in_valid, in_ready, in_aad, in_last;
  logic [127:0] in_data, out_data;
  logic [4:0]   in_bytes, out_bytes;
  logic         out_valid, out_ready, out_last;
  logic         c_busy, c_done, c_err;
  logic [2:0]   c_code;

  AES_GCM_top #(.LEN_W(20)) u_gcm (
    .clk, .rst_n, .key256, .decrypt, .key_sel, .tag_len, .key, .iv, .tag_in, .sl_key, .sl_valid,
    .start(go), .clr(1'b0), .busy(c_busy),
    .in_valid, .in_ready, .in_data, .in_bytes, .in_aad, .in_last,
    .out_valid, .out_ready, .out_data, .out_bytes, .out_last,
    .done(c_done), .tag, .tag_ok, .err(c_err), .err_code(c_code)
  );

  // byte b of a word (address order) to and from a big-endian block
  function automatic logic [31:0] bswap(input logic [31:0] w);
    bswap = {w[7:0], w[15:8], w[23:16], w[31:24]};
  endfunction

  // ---------------------------------------------------------- input blocks
  logic [127:0] ib;
  logic [1:0]   iw;               // words of the block collected
  logic         ib_full;
  logic [13:0]  bi;               // block index of ib
  logic         term;             // the empty closing block is due (no text)
  logic         run;
  logic         drop;           // after a core error: drain the read, pad the write
  assign rs_ready = run && (drop || !ib_full);
  wire          last_aad = (bi == {1'b0, nab} - 14'd1);
  wire [3:0]    arem = aad_len[3:0];
  wire [3:0]    trem = txt_len[3:0];
  always_comb begin
    in_valid = 1'b0; in_data = ib; in_aad = 1'b0; in_last = 1'b0; in_bytes = 5'd16;
    if (drop) begin
      in_valid = 1'b0;
    end else if (term) begin
      in_valid = 1'b1; in_data = '0; in_bytes = 5'd0; in_last = 1'b1;
    end else if (ib_full) begin
      in_valid = 1'b1;
      if (bi < {1'b0, nab}) begin
        in_aad = 1'b1;
        if (last_aad && arem != 4'd0) in_bytes = {1'b0, arem};
      end else begin
        in_last = (bi == nbl - 14'd1);
        if (in_last && trem != 4'd0) in_bytes = {1'b0, trem};
      end
    end
  end

  // --------------------------------------------------------- output blocks
  logic [127:0] ob;
  logic [1:0]   ow;
  logic         ob_full;
  assign out_ready = !ob_full;
  assign ws_valid  = ob_full || drop;
  assign ws_data   = drop ? 32'd0 : bswap(ob[127:96]);

  // ----------------------------------------------------------------- job
  logic g_seen, r_seen, w_seen, ax_err, fin;
  assign go   = start && !busy;
  assign busy = run;
  assign fin  = run && g_seen && r_seen && w_seen && !r_busy && !w_busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run <= 1'b0; ib <= '0; iw <= '0; ib_full <= 1'b0; bi <= '0; term <= 1'b0;
      ob <= '0; ow <= '0; ob_full <= 1'b0;
      g_seen <= 1'b0; r_seen <= 1'b0; w_seen <= 1'b0; ax_err <= 1'b0; drop <= 1'b0;
      gcm_err <= 1'b0; err_code <= '0; cycles <= '0;
    end else if (go) begin
      run <= 1'b1; iw <= '0; ib_full <= 1'b0; bi <= '0; term <= (ntb == 13'd0) && (nab == 13'd0);
      ow <= '0; ob_full <= 1'b0;
      g_seen <= 1'b0; r_seen <= (nbl == 14'd0); w_seen <= (ntb == 13'd0);
      ax_err <= 1'b0; gcm_err <= 1'b0; err_code <= '0; cycles <= '0; drop <= 1'b0;
    end else if (run) begin
      cycles <= cycles + 32'd1;
      // collect words into a block
      if (rs_valid && rs_ready && !drop) begin
        ib <= {ib[95:0], bswap(rs_data)};
        iw <= iw + 2'd1;
        if (iw == 2'd3) ib_full <= 1'b1;
      end
      if (in_valid && in_ready) begin
        if (term) term <= 1'b0;
        else begin
          ib_full <= 1'b0; bi <= bi + 14'd1;
          // AAD only: the closing empty block follows the last AAD block
          if (ntb == 13'd0 && last_aad) term <= 1'b1;
        end
      end
      // split output blocks into words
      if (drop) ob_full <= 1'b0;
      else if (out_valid && out_ready) begin ob <= out_data; ob_full <= 1'b1; ow <= '0; end
      else if (ws_valid && ws_ready) begin
        ob <= {ob[95:0], 32'd0}; ow <= ow + 2'd1;
        if (ow == 2'd3) ob_full <= 1'b0;
      end
      if (c_done) g_seen <= 1'b1;
      if (c_err) begin g_seen <= 1'b1; gcm_err <= 1'b1; err_code <= c_code; drop <= 1'b1; end
      if (r_done) begin r_seen <= 1'b1; if (r_err) ax_err <= 1'b1; end
      if (w_done) begin w_seen <= 1'b1; if (w_err) ax_err <= 1'b1; end
      if (fin) run <= 1'b0;
    end
  end
  assign err     = ax_err;
  assign done    = fin;
  assign err_irq = fin && (ax_err || gcm_err);
  wire _unused = &{1'b0, c_busy, out_bytes, out_last, r_cyc, w_cyc, r_awid, r_awaddr, r_awlen,
                   r_awsize, r_awburst, r_awprot, r_awvalid, r_wdata, r_wstrb, r_wlast, r_wvalid,
                   r_bready, r_ws_ready, w_arid, w_araddr, w_arlen, w_arsize, w_arburst, w_arprot,
                   w_arvalid, w_rready, w_rs_valid, w_rs_data};
endmodule
