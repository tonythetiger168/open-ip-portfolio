// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Video_Codec_8K: 8K video decoder traffic shape of the TV SoC (AXI4 manager,
// APB4 registers)
// ----------------------------------------------------------------------------
// Reproduces the DRAM access pattern of an HEVC / AV1 style decoder, CTU by
// CTU in raster order, without the pixel arithmetic, so the interconnect,
// memory controller and QoS settings can be tested with the codec's real
// traffic mix (see docs/ip/Video_Codec_8K.md for the 8K60 numbers). The
// pixel codec itself is c1p-codec; this block stands in for it in the SoC
// regressions. Per CTU:
// 1. Bitstream: BS_WORDS words read in order from BS_ADDR on (the read
// pointer runs on over the whole picture).
// 2. Motion compensation: for each PU (2^PU_LOG2 square) and each reference
// r < N_REFS (REF0_ADDR, REF1_ADDR), a 2D block of (PU + 7) rows by (PU + 7)
// luma pixels (8-tap interpolation) at the PU position plus a motion vector
// (dx, dy); each block row is one read job of the words that cover it.
// dx and dy are random in [-2^MV_LOG2, 2^MV_LOG2 - 1] from a xorshift32
// generator seeded with SEED (one step per block: dx from bits 15:0, dy from
// bits 31:16). The block origin (x + dx - 3, y + dy - 3) is clamped to the
// picture: 0 <= bx <= W - PU - 7, the same for y.
// 3. Reconstruction: the CTU's luma (2^CTU_LOG2 rows of 2^CTU_LOG2 bytes) at
// RECON_ADDR and its 4:2:0 interleaved chroma (half the rows, same width)
// at CHROMA_ADDR are written, one job per row; each written word is its
// byte address XOR SEED, so the frame can be checked.
// - Pixels are 8-bit, 4 per word; STRIDE is the line pitch in bytes of all
// planes. W = PIC_W_CTU << CTU_LOG2 pixels, H likewise.
// - CTU_GAP shapes the rate: a CTU takes at least CTU_GAP clocks (start to
// start); a CTU that takes longer counts in LATE_CNT (a real-time miss at
// that rate). 0: back to back.
// - CTU_LIMIT stops the job after that many CTUs (0: the whole picture), so
// an 8K geometry can be sampled in simulation.
// - CFG_ERR (job ends at once): CTU_LOG2 outside 4..6, PU_LOG2 outside
// 3..CTU_LOG2, N_REFS above 2, PIC_W_CTU or PIC_H_CTU 0.
// - RD_WORDS, WR_WORDS, RD_SUM (32-bit sum of every word read), CTUS, CYCLES
// report the last job. DONE pulses at the end, ERR as well on an AXI error.
// ============================================================================
module Video_Codec_8K_top #(
  parameter logic [3:0] AXI_ID = 4'd9
) (
  input  logic        clk,
  input  logic        rst_n,
  // configuration
  input  logic [31:0] bs_addr,
  input  logic [31:0] ref0_addr,
  input  logic [31:0] ref1_addr,
  input  logic [31:0] recon_addr,
  input  logic [31:0] chroma_addr,
  input  logic [15:0] stride,
  input  logic [7:0]  pic_w_ctu,
  input  logic [7:0]  pic_h_ctu,
  input  logic [2:0]  ctu_log2,
  input  logic [2:0]  pu_log2,
  input  logic [1:0]  n_refs,
  input  logic [2:0]  mv_log2,
  input  logic [7:0]  bs_words,
  input  logic [15:0] ctu_gap,
  input  logic [15:0] ctu_limit,
  input  logic [31:0] seed,
  input  logic        start,
  // status
  output logic        busy,
  output logic        err,
  output logic        cfg_err,
  output logic [15:0] ctus,
  output logic [15:0] late_cnt,
  output logic [31:0] rd_words,
  output logic [31:0] wr_words,
  output logic [31:0] rd_sum,
  output logic [31:0] cycles,
  output logic        done,
  output logic        late,
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
  typedef enum logic [2:0] {IDLE, BS, MC, LUMA, CHROMA, GAP, FIN} st_t;
  st_t         st;
  logic [1:0]  ph;                                  // 0 set up the job, 1 start it, 2 wait for DONE
  logic [7:0]  cx, cy;
  logic [6:0]  pux, puy;                            // PU index in the CTU
  logic [1:0]  r;                                   // reference
  logic [6:0]  row;
  logic [31:0] bs_ptr, lfsr, j_src, j_dst;
  logic [15:0] j_len, t_ctu;
  logic        j_rd, j_wr;
  logic signed [17:0] bx, by;                       // clamped block origin
  logic        e_start, e_busy, e_done, e_err, rs_valid, rs_ready, ws_ready;
  logic [31:0] rs_data, e_cycles;
  logic [15:0] wcnt;
  logic        err_q;

  wire  [7:0]  ctu_px = 8'd1 << ctu_log2;           // 16 .. 64
  wire  [7:0]  pu_px  = 8'd1 << pu_log2;            // 8 .. 64
  wire  [6:0]  n_pu   = 7'(ctu_px >> pu_log2);      // PUs per CTU side
  wire  [16:0] pic_w  = 17'(pic_w_ctu) << ctu_log2;
  wire  [16:0] pic_h  = 17'(pic_h_ctu) << ctu_log2;
  wire         bad_cfg = ctu_log2 < 4 || ctu_log2 > 6 || pu_log2 < 3 || pu_log2 > ctu_log2 ||
                         n_refs > 2 || pic_w_ctu == 0 || pic_h_ctu == 0;
  wire         last_ctu = (cx + 8'd1 == pic_w_ctu && cy + 8'd1 == pic_h_ctu) ||
                          (ctu_limit != 0 && ctus + 16'd1 >= ctu_limit);

  // first step of a CTU
  function automatic st_t ctu_first;
    if (bs_words != 0) ctu_first = BS;
    else if (n_refs != 0) ctu_first = MC;
    else ctu_first = LUMA;
  endfunction
  // xorshift32, one step per reference block
  function automatic logic [31:0] xs32(input logic [31:0] x);
    logic [31:0] y;
    y = x ^ (x << 13); y = y ^ (y >> 17); xs32 = y ^ (y << 5);
  endfunction
  // motion vector of the next block and the clamped block origin
  logic [31:0]        lfsr_n;
  logic signed [17:0] mvx, mvy, ox, oy, mx, my;
  always_comb begin
    lfsr_n = xs32(lfsr);
    mvx = 18'(signed'(lfsr_n[15:0]) >>> (5'd15 - 5'(mv_log2)));   // top MV_LOG2 + 1 bits, signed
    mvy = 18'(signed'(lfsr_n[31:16]) >>> (5'd15 - 5'(mv_log2)));
    ox  = 18'(({10'd0, cx} << ctu_log2) + ({11'd0, pux} << pu_log2)) + mvx - 18'sd3;
    oy  = 18'(({10'd0, cy} << ctu_log2) + ({11'd0, puy} << pu_log2)) + mvy - 18'sd3;
    mx  = 18'(pic_w) - 18'(pu_px) - 18'sd7;
    my  = 18'(pic_h) - 18'(pu_px) - 18'sd7;
    ox  = (ox > mx) ? mx : ox;  ox = (ox < 0) ? 18'sd0 : ox;
    oy  = (oy > my) ? my : oy;  oy = (oy < 0) ? 18'sd0 : oy;
  end
  wire [6:0]  blk_rows  = 7'(pu_px) + 7'd7;
  wire [15:0] ctu_words = 16'(ctu_px >> 2);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE; ph <= '0; cx <= '0; cy <= '0; pux <= '0; puy <= '0; r <= '0; row <= '0;
      bs_ptr <= '0; lfsr <= 32'h1; j_src <= '0; j_dst <= '0; j_len <= '0; j_rd <= 1'b0; j_wr <= 1'b0;
      bx <= '0; by <= '0; t_ctu <= '0; err_q <= 1'b0; cfg_err <= 1'b0;
      ctus <= '0; late_cnt <= '0; cycles <= '0; late <= 1'b0;
    end else begin
      late <= 1'b0;
      if (st != IDLE) cycles <= cycles + 32'd1;
      if (st != IDLE && t_ctu != 16'hFFFF) t_ctu <= t_ctu + 16'd1;
      if (e_done && e_err) err_q <= 1'b1;
      if (st == BS || st == MC || st == LUMA || st == CHROMA) begin
        if (ph == 2'd1 && !e_busy) ph <= 2'd2;
        if (ph == 2'd2 && e_done) ph <= 2'd0;
      end
      case (st)
        IDLE: if (start) begin
          cfg_err <= bad_cfg; err_q <= 1'b0;
          ctus <= '0; late_cnt <= '0; cycles <= '0; t_ctu <= '0;
          cx <= '0; cy <= '0; pux <= '0; puy <= '0; r <= '0; row <= '0; ph <= '0;
          bs_ptr <= bs_addr; lfsr <= (seed == 0) ? 32'h1 : seed;
          if (bad_cfg) st <= FIN;
          else st <= ctu_first();
        end
        BS: begin
          if (ph == 2'd0) begin
            j_src <= bs_ptr; j_len <= 16'(bs_words); j_rd <= 1'b1; j_wr <= 1'b0; ph <= 2'd1;
          end else if (ph == 2'd2 && e_done) begin
            bs_ptr <= bs_ptr + (32'(bs_words) << 2);
            if (n_refs != 0) st <= MC; else st <= LUMA;
          end
        end
        MC: begin
          if (ph == 2'd0) begin : mc_setup
            logic signed [17:0] ex, ey;
            ex = bx; ey = by;
            if (row == 0) begin                       // new block: next motion vector
              lfsr <= lfsr_n; ex = ox; ey = oy; bx <= ox; by <= oy;
            end
            j_src <= (r == 0 ? ref0_addr : ref1_addr) + 32'(ey + 18'(row)) * 32'(stride)
                     + (32'(16'(ex >>> 2)) << 2);
            j_len <= 16'((ex + 18'(pu_px) + 18'sd6) >>> 2) - 16'(ex >>> 2) + 16'd1;
            j_rd <= 1'b1; j_wr <= 1'b0; ph <= 2'd1;
          end else if (ph == 2'd2 && e_done) begin
            if (row + 7'd1 < blk_rows) row <= row + 7'd1;
            else begin
              row <= '0;
              if (2'(r + 2'd1) < n_refs) r <= r + 2'd1;
              else begin
                r <= '0;
                if (pux + 7'd1 < n_pu) pux <= pux + 7'd1;
                else begin
                  pux <= '0;
                  if (puy + 7'd1 < n_pu) puy <= puy + 7'd1;
                  else begin puy <= '0; st <= LUMA; end
                end
              end
            end
          end
        end
        LUMA, CHROMA: begin
          if (ph == 2'd0) begin
            j_dst <= (st == LUMA)
                     ? recon_addr  + 32'((17'(cy) << ctu_log2) + 17'(row)) * 32'(stride) + (32'(cx) << ctu_log2)
                     : chroma_addr + 32'((17'(cy) << (ctu_log2 - 3'd1)) + 17'(row)) * 32'(stride) + (32'(cx) << ctu_log2);
            j_len <= ctu_words; j_rd <= 1'b0; j_wr <= 1'b1; ph <= 2'd1;
          end else if (ph == 2'd2 && e_done) begin
            if (st == LUMA && 8'(row) + 8'd1 < ctu_px) row <= row + 7'd1;
            else if (st == CHROMA && 8'(row) + 8'd1 < (ctu_px >> 1)) row <= row + 7'd1;
            else begin
              row <= '0;
              if (st == LUMA) st <= CHROMA; else st <= GAP;
            end
          end
        end
        GAP: if (t_ctu + 16'd1 >= ctu_gap) begin       // this CTU has used its slot
          if (ctu_gap != 0 && t_ctu + 16'd1 > ctu_gap) begin late_cnt <= late_cnt + 16'd1; late <= 1'b1; end
          ctus <= ctus + 16'd1;
          t_ctu <= '0;
          if (last_ctu) st <= FIN;
          else begin
            if (cx + 8'd1 < pic_w_ctu) cx <= cx + 8'd1;
            else begin cx <= '0; cy <= cy + 8'd1; end
            st <= ctu_first();
          end
        end
        FIN: st <= IDLE;
        default: st <= IDLE;
      endcase
    end
  end
  assign e_start = (ph == 2'd1) && !e_busy && (st == BS || st == MC || st == LUMA || st == CHROMA);
  assign busy    = (st != IDLE);
  assign done    = (st == FIN);
  assign err     = err_q;
  assign err_irq = (st == FIN) && err_q;

  // read data is counted and summed; write data is address ^ SEED
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rd_words <= '0; wr_words <= '0; rd_sum <= '0; wcnt <= '0; end
    else begin
      if (st == IDLE && start) begin rd_words <= '0; wr_words <= '0; rd_sum <= '0; end
      if (rs_valid) begin rd_words <= rd_words + 32'd1; rd_sum <= rd_sum + rs_data; end
      if (e_start) wcnt <= '0;
      else if (ws_ready) begin wcnt <= wcnt + 16'd1; wr_words <= wr_words + 32'd1; end
    end
  end
  assign rs_ready = 1'b1;

  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(j_rd), .wr_en(j_wr),
    .src(j_src), .dst(j_dst), .len(j_len),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cycles),
    .rs_valid, .rs_data, .rs_ready, .ws_valid(1'b1), .ws_data((j_dst + (32'(wcnt) << 2)) ^ seed), .ws_ready,
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
endmodule
