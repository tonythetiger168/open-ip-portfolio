// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// TCON_VbyOne: timing controller / panel link transmitter of the TV SoC: a
// frame fetch DMA (AXI4 manager) feeding a V-by-One HS style multi-lane link
// (APB4 registers)
// ----------------------------------------------------------------------------
// Link abstraction: LANES byte lanes, 8b/10b and serialisation outside the
// IP. vbo_lane_d[8l+7:8l] / vbo_lane_k[l] is the symbol of lane l (k = 1: control
// symbol); a new symbol is presented every SYM_DIV clocks (vbo_sym marks the
// first clock of each symbol; SYM_DIV 0 counts as 1).
// - Handshake: while the panel's vbo_htpdn_n is high (no panel) or its
// vbo_lockn_n is high (CDR not locked), every lane sends the CDR training
// symbol D10.2 (8'h4A, k = 0). Locked and idle, the lanes send K28.5
// (8'hBC, k = 1).
// - Pixels: 4-byte mode, one pixel word per lane per 4 symbols, byte j of
// the word (bits 8j+7:8j) in symbol j. Pixel p of a line goes to lane
// p % LANES; a line is sent in groups of LANES pixels (the last group of a
// line whose H_ACTIVE is not a multiple of LANES is padded with zero
// words).
// - Each line is preceded by one control symbol on all lanes: K28.2 (8'h5C)
// before the first line of a frame, K28.0 (8'h1C) before the others, and
// followed by HBLANK idle symbols (at least 1).
// - Frame: START (when not busy) fetches V_ACTIVE lines of H_ACTIVE words,
// line k from FB_ADDR + k * STRIDE (one engine job per line, prefetching
// through a FIFO), and sends them once the link is locked. A line starts
// only when the FIFO holds the whole line or is half full; if a group is
// not ready in time the lanes send idle symbols inside the line and
// UNDERRUN is set. Losing lock during a frame sets LOCK_LOST (the frame
// goes on). DONE pulses after the last symbol of the frame; ERR as well
// when an AXI error response was seen.
// ============================================================================
module TCON_VbyOne_top #(
  parameter logic [3:0] AXI_ID     = 4'd4,
  parameter int         LANES      = 8,
  parameter int         FIFO_DEPTH = 64          // power of two, >= LANES
) (
  input  logic                   clk,
  input  logic                   rst_n,
  // V-by-One HS lanes and panel handshake
  output logic [8*LANES-1:0]     vbo_lane_d,
  output logic [LANES-1:0]       vbo_lane_k,
  output logic                   vbo_sym,
  input  logic                   vbo_htpdn_n,
  input  logic                   vbo_lockn_n,
  // configuration
  input  logic [31:0]            fb_addr,
  input  logic [15:0]            stride,
  input  logic [15:0]            h_active,
  input  logic [15:0]            v_active,
  input  logic [7:0]             hblank,
  input  logic [3:0]             sym_div,
  input  logic                   start,
  // status
  output logic                   busy,
  output logic                   err,
  output logic                   underrun,
  output logic                   lock_lost,
  output logic                   locked,
  output logic [15:0]            lines,
  output logic [31:0]            cycles,
  output logic                   done,
  output logic                   err_irq,
  output logic                   lock_irq,
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
  localparam int FA = $clog2(FIFO_DEPTH);
  localparam logic [7:0] D10_2 = 8'h4A, K28_5 = 8'hBC, K28_0 = 8'h1C, K28_2 = 8'h5C;

  // ---------------- symbol clock ----------------
  logic [3:0] div_cnt;
  wire        sym = (div_cnt == 4'd0);
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) div_cnt <= '0;
    else div_cnt <= (div_cnt + 4'd1 >= ((sym_div == 0) ? 4'd1 : sym_div)) ? 4'd0 : div_cnt + 4'd1;
  assign vbo_sym = sym;
  assign locked  = !vbo_htpdn_n && !vbo_lockn_n;

  // ---------------- fetch ----------------
  logic        run, e_start, e_busy, e_done, e_err, rs_valid, rs_ready, ws_ready;
  logic [31:0] rs_data, e_cycles;
  logic [15:0] fetched;                          // line jobs started
  logic        f_pop, f_empty, f_full;
  logic [31:0] f_rdata;
  logic [FA:0] f_count;
  assign e_start  = run && !e_busy && !e_done && fetched < v_active && h_active != 0;
  assign rs_ready = !f_full;
  tv_fifo #(.W(32), .DEPTH(FIFO_DEPTH)) u_fifo (
    .clk, .rst_n, .clr(start && !busy), .push(rs_valid && rs_ready), .wdata(rs_data),
    .pop(f_pop), .rdata(f_rdata), .empty(f_empty), .full(f_full), .count(f_count)
  );
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(1'b1), .wr_en(1'b0),
    .src(fb_addr + 32'(fetched) * 32'(stride)), .dst(32'h0), .len(h_active),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cycles),
    .rs_valid, .rs_data, .rs_ready, .ws_valid(1'b0), .ws_data(32'h0), .ws_ready,
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

  // ---------------- group loader: LANES words into the next group ----------------
  logic [32*LANES-1:0] nxt;                     // word l at bits 32l+31:32l
  logic [$clog2(LANES+1)-1:0] nl;                // words in nxt
  logic        nxt_rdy;                          // nxt complete
  logic [15:0] loaded;                           // words of the current line loaded
  logic [15:0] want_ln;                          // line the loader works on
  wire  [15:0] remain  = h_active - loaded;
  wire  [15:0] gsize   = (remain > 16'(LANES)) ? 16'(LANES) : remain;
  assign f_pop = run && !nxt_rdy && !f_empty && (16'(nl) < gsize) && want_ln < v_active;

  // ---------------- transmitter ----------------
  typedef enum logic [2:0] {T_IDLE, T_WAIT, T_MARK, T_PIX, T_BLANK, T_END} ts_t;
  ts_t         ts;
  logic [1:0]  bsel;                             // byte of the group being sent
  logic [15:0] sent, line;                       // pixels sent of this line, line number
  logic [7:0]  bl;
  logic        take;                             // move nxt into grp at this symbol
  logic        sent_err;
  wire  [15:0] need    = (h_active > 16'(FIFO_DEPTH / 2)) ? 16'(FIFO_DEPTH / 2) : h_active;
  wire         in_frame = (ts == T_MARK) || (ts == T_PIX) || (ts == T_BLANK) || (ts == T_WAIT && line != 0);
  wire         line_ok = (16'(f_count) + 16'(nl) >= need);   // words of this line in the FIFO and the group register

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      nxt <= '0; nl <= '0; nxt_rdy <= 1'b0; loaded <= '0; want_ln <= '0;
    end else if (start && !busy) begin
      nl <= '0; nxt_rdy <= 1'b0; loaded <= '0; want_ln <= '0;
    end else begin
      if (f_pop) begin
        nxt[32*nl +: 32] <= f_rdata;
        nl <= nl + 1'b1;
        if (16'(nl) + 16'd1 == gsize) nxt_rdy <= 1'b1;
      end
      if (take) begin
        nxt_rdy <= 1'b0; nl <= '0;
        if (loaded + gsize >= h_active) begin loaded <= '0; want_ln <= want_ln + 16'd1; end
        else loaded <= loaded + gsize;
      end
    end
  end

  // nxt -> grp at the first symbol of each group (the bytes 1..3 come from grp);
  // the lanes past the end of a partial group carry zero words
  assign take = sym && ts == T_PIX && bsel == 2'd0 && nxt_rdy;
  logic [8*LANES-1:0] pix_sym;
  for (genvar l = 0; l < LANES; l++) begin : g_lane
    logic [31:0] grp;
    wire  [31:0] w = (l < gsize) ? nxt[32*l +: 32] : 32'h0;
    assign pix_sym[8*l +: 8] = (bsel == 2'd0) ? w[7:0] : grp[8*bsel +: 8];
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) grp <= '0;
      else if (take) grp <= w;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ts <= T_IDLE; run <= 1'b0; fetched <= '0; bsel <= '0; sent <= '0; line <= '0; bl <= '0;
      vbo_lane_d <= {LANES{D10_2}}; vbo_lane_k <= '0;
      underrun <= 1'b0; lock_lost <= 1'b0; err <= 1'b0; lines <= '0; cycles <= '0; sent_err <= 1'b0;
    end else begin
      if (e_start) fetched <= fetched + 16'd1;
      if (e_done && e_err) err <= 1'b1;
      if (run) cycles <= cycles + 32'd1;
      if (in_frame && !locked) lock_lost <= 1'b1;
      if (ts == T_IDLE) begin
        if (start) begin
          run <= 1'b1; ts <= T_WAIT; fetched <= '0; line <= '0; lines <= '0; cycles <= '0;
          underrun <= 1'b0; lock_lost <= 1'b0; err <= 1'b0;
        end
      end
      if (sym) begin
        // default symbols: training when not locked, idle otherwise
        vbo_lane_d <= locked ? {LANES{K28_5}} : {LANES{D10_2}};
        vbo_lane_k <= locked ? '1 : '0;
        case (ts)
          T_WAIT: if (locked) begin
            if (line >= v_active || h_active == 0) ts <= T_END;
            else if (line_ok) begin
              ts <= T_MARK;
            end
          end
          T_MARK: begin
            vbo_lane_d <= {LANES{(line == 0) ? K28_2 : K28_0}};
            vbo_lane_k <= '1;
            sent <= '0; bsel <= '0;
            ts <= T_PIX;
          end
          T_PIX: begin
            if (bsel == 2'd0 && !nxt_rdy) begin
              underrun <= 1'b1;                    // idle symbol inside the line
            end else begin
              vbo_lane_d <= pix_sym;
              vbo_lane_k <= '0;
              bsel <= bsel + 2'd1;
              if (bsel == 2'd3) begin
                if (sent + 16'(LANES) >= h_active) begin
                  ts <= T_BLANK; bl <= (hblank == 0) ? 8'd1 : hblank;
                  line <= line + 16'd1; lines <= lines + 16'd1;
                end
                sent <= sent + 16'(LANES);
              end
            end
          end
          T_BLANK: begin
            bl <= bl - 8'd1;
            if (bl == 8'd1) begin
              if (line >= v_active) ts <= T_END; else ts <= T_WAIT;
            end
          end
          default: ;
        endcase
      end
      if (ts == T_END && !e_busy && !e_start) begin
        ts <= T_IDLE; run <= 1'b0;
      end
    end
  end
  wire frame_end = (ts == T_END) && !e_busy && !e_start;
  assign busy     = (ts != T_IDLE);
  assign done     = frame_end;
  assign err_irq  = frame_end && (err || (e_done && e_err));
  assign lock_irq = in_frame && !locked && !lock_lost;
endmodule
