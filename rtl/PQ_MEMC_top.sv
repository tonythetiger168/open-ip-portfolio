// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// PQ_MEMC: picture-quality engine of the TV SoC: HDR tone mapping and MEMC
// frame blending over AXI4 (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Processing stages (rtl/pq/pq_stages.sv): pq_meta_decode (HDR10 / Dolby
// Vision metadata -> tone parameters), pq_eetf (2-segment tone curve + trim
// gain / offset, clamped) and pq_blend (out = prev * (256 - a) + cur * a >> 8).
// With PQ_EXT defined the private pq-pipeline-sv stages l0 / l1 / l2d are
// used instead (fetched at build time, rtl/pq/README.md). This wrapper adds
// the frame DMA, back-pressure and registers.
// - Pixels: one 32-bit word, {2'b00, R[9:0], G[9:0], B[9:0]}; a 10-bit code c
// enters the pipeline as the Q0.16 value {c, c[9:4]} and leaves as bits
// 15:6 of the result.
// - Frame job (START, ignored while busy): for each line k < V_ACTIVE, if
// MEMC_EN the previous-frame line PREV_ADDR + k * STRIDE is read into a line
// buffer, then the current line CUR_ADDR + k * STRIDE is read, processed
// and written to DST_ADDR + k * STRIDE (H_ACTIVE words each). MEMC_EN 0:
// prev = cur (tone mapping only). Both frames go through the tone curve
// (two l1 instances) before the blend.
// - MV_FRAC a (0..255) is the weight of the current frame (frame-rate
// conversion phase from the NPU's motion estimation; one value per job).
// - Tone mapping: META_LOAD loads the 128-bit metadata {META3..META0} with
// DISPLAY_PEAK into l0 (TONE_SLOPE / CONTENT_MAX show the result). TONE_EN
// 0 (or no metadata loaded yet): neutral EETF (no compression, trim 1.0).
// - H_ACTIVE above MAXW (the line buffer) or 0 ends the job at once with
// CFG_ERR. DONE pulses at the end of the job, ERR as well on an AXI error
// response. LINES and CYCLES report the last job. 8K60 (7680 x 4320) needs
// MAXW = 7680 and about 8 GB/s read + 4 GB/s write with MEMC on.
// ============================================================================
module PQ_MEMC_top #(
  parameter logic [3:0] AXI_ID = 4'd8,
  parameter int         MAXW   = 64
) (
  input  logic        clk,
  input  logic        rst_n,
  // configuration
  input  logic [31:0] cur_addr,
  input  logic [31:0] prev_addr,
  input  logic [31:0] dst_addr,
  input  logic [15:0] stride,
  input  logic [15:0] h_active,
  input  logic [15:0] v_active,
  input  logic        memc_en,
  input  logic [7:0]  mv_frac,
  input  logic        tone_en,
  input  logic [31:0] meta0,
  input  logic [31:0] meta1,
  input  logic [31:0] meta2,
  input  logic [31:0] meta3,
  input  logic [15:0] display_peak,
  input  logic        meta_load,
  input  logic        start,
  // status
  output logic        busy,
  output logic        err,
  output logic        cfg_err,
  output logic        params_ok,
  output logic [15:0] tone_slope,
  output logic [15:0] content_max,
  output logic [15:0] lines,
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
  // ---------------- tone parameters (l0) ----------------
  logic        pv;
  logic [15:0] l0_knee, l0_slope, l0_gain, l0_off;
`ifdef PQ_EXT
  l0_metadata_unit u_l0 (
    .clk, .rst_n,
    .meta_valid(meta_load), .meta({meta3, meta2, meta1, meta0}),
    .display_peak_nits(display_peak),
    .params_valid(pv),
    .tone_knee(l0_knee), .tone_slope(l0_slope), .trim_gain(l0_gain), .trim_offset(l0_off),
    .content_max_nits(content_max)
  );
`else
  pq_meta_decode u_l0 (
    .clk, .rst_n, .load(meta_load), .meta({meta3, meta2, meta1, meta0}), .peak_nits(display_peak),
    .valid(pv), .knee(l0_knee), .slope(l0_slope), .gain(l0_gain), .offset(l0_off), .cmax(content_max)
  );
`endif
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) params_ok <= 1'b0;
    else if (meta_load) params_ok <= 1'b0;
    else if (pv) params_ok <= 1'b1;
  assign tone_slope = l0_slope;
  wire        use_l0 = tone_en && params_ok;
  wire [15:0] knee   = use_l0 ? l0_knee  : 16'hFFFF;
  wire [15:0] slope  = use_l0 ? l0_slope : 16'hFFFF;
  wire [15:0] gain   = use_l0 ? l0_gain  : 16'd16384;
  wire [15:0] off    = use_l0 ? l0_off   : 16'd0;

  // ---------------- job control ----------------
  typedef enum logic [2:0] {IDLE, PREV, PREV_W, CUR, CUR_W, FIN} st_t;
  st_t         st;
  logic [15:0] ln;
  logic        e_start, e_busy, e_done, e_err, rs_valid, rs_ready, ws_ready, e_rd, e_wr;
  logic [31:0] rs_data, e_cycles, e_src;
  logic        err_q;
  wire         bad_cfg = (h_active == 0) || (h_active > 16'(MAXW));
  wire  [31:0] off_ln  = 32'(ln) * 32'(stride);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE; ln <= '0; lines <= '0; cycles <= '0; cfg_err <= 1'b0; err_q <= 1'b0;
    end else begin
      if (st != IDLE) cycles <= cycles + 32'd1;
      if (e_done && e_err) err_q <= 1'b1;
      case (st)
        IDLE: if (start) begin
          ln <= '0; lines <= '0; cycles <= '0; err_q <= 1'b0;
          cfg_err <= bad_cfg;
          if (bad_cfg || v_active == 0) st <= FIN;
          else if (memc_en) st <= PREV; else st <= CUR;
        end
        PREV:   st <= PREV_W;                                  // e_start fires here
        PREV_W: if (e_done) st <= CUR;
        CUR:    st <= CUR_W;
        CUR_W:  if (e_done) begin
          lines <= lines + 16'd1;
          ln <= ln + 16'd1;
          if (ln + 16'd1 >= v_active) st <= FIN;
          else if (memc_en) st <= PREV; else st <= CUR;
        end
        FIN: st <= IDLE;
        default: st <= IDLE;
      endcase
    end
  end
  assign e_start = (st == PREV || st == CUR) && !e_busy;
  assign e_rd    = 1'b1;
  assign e_wr    = (st == CUR);
  assign e_src   = (st == PREV) ? prev_addr + off_ln : cur_addr + off_ln;
  assign busy    = (st != IDLE);
  assign done    = (st == FIN);
  assign err     = err_q;
  assign err_irq = (st == FIN) && err_q;

  // ---------------- line buffer (previous frame) ----------------
  localparam int LW = $clog2(MAXW + 1);
  logic [31:0] lb [MAXW];
  logic [LW-1:0] wi, ri;                                     // line buffer write / read index
  logic        in_prev;                                      // the running job fills the line buffer
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin in_prev <= 1'b0; wi <= '0; end
    else begin
      if (e_start) begin in_prev <= (st == PREV); wi <= '0; end
      if (in_prev && rs_valid) wi <= wi + 1'b1;
    end
  end
  always_ff @(posedge clk) if (in_prev && rs_valid) lb[wi] <= rs_data;

  // ---------------- pipeline: l1 (4) + l2d (1) with credits ----------------
  function automatic logic [15:0] up(input logic [9:0] c); up = {c, c[9:4]}; endfunction
  logic        f_full, f_empty, f_pop;
  logic [31:0] f_rdata;
  logic [3:0]  f_count;
  logic [2:0]  inflight;
  wire         issue = !in_prev && rs_valid && (5'(f_count) + 5'(inflight) < 5'd8) && busy;
  assign rs_ready = in_prev ? 1'b1 : issue;
  wire  [31:0] cw    = rs_data;
  wire  [31:0] pw    = memc_en ? lb[ri] : rs_data;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ri <= '0;
    else if (e_start) ri <= '0;
    else if (issue) ri <= ri + 1'b1;
  end
  logic [7:0]  mv_d [4];
  always_ff @(posedge clk) begin
    mv_d[0] <= memc_en ? mv_frac : 8'd0;
    for (int i = 1; i < 4; i++) mv_d[i] <= mv_d[i-1];
  end
  logic        v1, s1, v1p, s1p, v2, s2;
  logic [47:0] p1, p1p, p2;
  wire  [47:0] cur_pix  = {up(cw[29:20]), up(cw[19:10]), up(cw[9:0])};
  wire  [47:0] prev_pix = {up(pw[29:20]), up(pw[19:10]), up(pw[9:0])};
  // the previous-frame pixel goes through the same tone curve, so both blend
  // inputs are in display light (MEMC_EN 0: the blend sees cur twice)
`ifdef PQ_EXT
  l1_tone_map_eetf u_l1 (
    .clk, .rst_n, .in_valid(issue), .in_sof(1'b0), .in_pix(cur_pix),
    .tone_knee(knee), .tone_slope(slope), .trim_gain(gain), .trim_offset(off),
    .out_valid(v1), .out_sof(s1), .out_pix(p1)
  );
  l1_tone_map_eetf u_l1p (
    .clk, .rst_n, .in_valid(issue), .in_sof(1'b0), .in_pix(prev_pix),
    .tone_knee(knee), .tone_slope(slope), .trim_gain(gain), .trim_offset(off),
    .out_valid(v1p), .out_sof(s1p), .out_pix(p1p)
  );
  l2d_memc_blend u_l2d (
    .clk, .rst_n, .in_valid(v1), .in_sof(1'b0),
    .in_cur(p1), .in_prev(p1p), .in_mvfrac(mv_d[3]),
    .out_valid(v2), .out_sof(s2), .out_pix(p2)
  );
`else
  assign s1 = 1'b0; assign s1p = 1'b0; assign s2 = 1'b0;
  pq_eetf u_l1 (
    .clk, .rst_n, .in_valid(issue), .in_pix(cur_pix),
    .knee, .slope, .gain, .offset(off), .out_valid(v1), .out_pix(p1)
  );
  pq_eetf u_l1p (
    .clk, .rst_n, .in_valid(issue), .in_pix(prev_pix),
    .knee, .slope, .gain, .offset(off), .out_valid(v1p), .out_pix(p1p)
  );
  pq_blend u_l2d (
    .clk, .rst_n, .in_valid(v1), .cur(p1), .prev(p1p), .a(mv_d[3]),
    .out_valid(v2), .out_pix(p2)
  );
`endif
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) inflight <= '0;
    else inflight <= inflight + 3'(issue) - 3'(v2);
  tv_fifo #(.W(32), .DEPTH(8)) u_out (
    .clk, .rst_n, .clr(1'b0), .push(v2), .wdata({2'b00, p2[47:38], p2[31:22], p2[15:6]}),
    .pop(f_pop), .rdata(f_rdata), .empty(f_empty), .full(f_full), .count(f_count)
  );
  assign f_pop = ws_ready && !f_empty;

  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(e_rd), .wr_en(e_wr),
    .src(e_src), .dst(dst_addr + off_ln), .len(h_active),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cycles),
    .rs_valid, .rs_data, .rs_ready, .ws_valid(!f_empty), .ws_data(f_rdata), .ws_ready,
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
