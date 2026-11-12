// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// HDMI_RX_DMA: HDMI 2.1 receiver video path of the TV SoC with a frame
// capture DMA (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Link abstraction (the same as the portfolio's HDMI VIP): one 10-bit TMDS
// character per channel per clk on tmds_ch0 / ch1 / ch2 (blue / green / red);
// the PHY, clock recovery and character alignment are outside this IP.
// - Control period: the four TMDS control tokens on ch0 carry {VSYNC, HSYNC}
// (10'h354 = 00, 10'h0AB = 01, 10'h154 = 10, 10'h2AB = 11).
// - Video period: any other character. The two-character video guard band
// (ch0 = ch2 = 10'h2CC, ch1 = 10'h133) right after a control period is
// skipped; every following character is TMDS-decoded to 8 bits per channel,
// giving one pixel {8'h00, R, G, B} (one 32-bit word).
// - Data islands (TERC4 packets) are not decoded: the source must send video
// and control periods only (DVI / HDMI video mode).
// Frame capture (one frame per ARM command):
// - ARM waits for the next VSYNC rising edge, then captures V_ACTIVE lines
// (video periods). Line k is written to FB_ADDR + k * STRIDE as H_ACTIVE
// words: one engine job per line, bursts of up to 16 beats.
// - A line with fewer than H_ACTIVE pixels is padded with zeros and a longer
// one is cut; both set LEN_ERR. A pixel that finds the line FIFO full is
// dropped (the line is padded) and sets OVF.
// - DONE pulses when the last line is in memory; ERR as well when an AXI
// error response was seen. LINES counts the lines captured, CYCLES the
// clocks from the start of the frame to DONE.
// - hpd follows HPD_EN (hot-plug detect towards the source).
// ============================================================================
module HDMI_RX_DMA_top #(
  parameter logic [3:0] AXI_ID     = 4'd2,
  parameter int         FIFO_DEPTH = 64
) (
  input  logic        clk,
  input  logic        rst_n,
  // TMDS characters (one per channel per clk) and hot-plug detect
  input  logic [9:0]  tmds_ch0,
  input  logic [9:0]  tmds_ch1,
  input  logic [9:0]  tmds_ch2,
  output logic        hpd,
  // configuration
  input  logic        hpd_en,
  input  logic [31:0] fb_addr,
  input  logic [15:0] stride,
  input  logic [15:0] h_active,
  input  logic [15:0] v_active,
  input  logic        arm,
  // status
  output logic        busy,
  output logic        err,
  output logic        ovf,
  output logic        len_err,
  output logic        vsync,
  output logic        hsync,
  output logic [15:0] lines,
  output logic [31:0] cycles,
  output logic        done,
  output logic        err_irq,
  output logic        ovf_irq,
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
  // ---------------- TMDS decode ----------------
  function automatic logic [7:0] tmds_dec(input logic [9:0] q);
    logic [7:0] d, x;
    x = q[9] ? ~q[7:0] : q[7:0];
    d[0] = x[0];
    for (int i = 1; i < 8; i++) d[i] = q[8] ? (x[i] ^ x[i-1]) : ~(x[i] ^ x[i-1]);
    tmds_dec = d;
  endfunction
  logic is_ctl, is_gb;
  logic [1:0] ctl;
  always_comb begin
    is_ctl = 1'b1; ctl = 2'b00;
    case (tmds_ch0)
      10'h354: ctl = 2'b00;
      10'h0AB: ctl = 2'b01;
      10'h154: ctl = 2'b10;
      10'h2AB: ctl = 2'b11;
      default: is_ctl = 1'b0;
    endcase
  end
  assign is_gb = (tmds_ch0 == 10'h2CC) && (tmds_ch1 == 10'h133) && (tmds_ch2 == 10'h2CC);

  logic        prev_ctl, vs_q;
  logic [1:0]  gb_left;                        // guard-band characters still allowed
  wire         vid    = !is_ctl && !(is_gb && gb_left != 0);
  wire  [31:0] pix    = {8'h00, tmds_dec(tmds_ch2), tmds_dec(tmds_ch1), tmds_dec(tmds_ch0)};
  wire         vs_rise = is_ctl && ctl[1] && !vs_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_ctl <= 1'b1; vs_q <= 1'b0; gb_left <= 2'd0; vsync <= 1'b0; hsync <= 1'b0;
    end else begin
      prev_ctl <= is_ctl;
      if (is_ctl) begin
        vs_q <= ctl[1]; vsync <= ctl[1]; hsync <= ctl[0];
        gb_left <= 2'd2;
      end else if (is_gb && gb_left != 0) gb_left <= gb_left - 2'd1;
      else gb_left <= 2'd0;
    end
  end

  // ---------------- capture control ----------------
  typedef enum logic [1:0] {IDLE, WAIT_VS, CAPT, DRAIN} st_t;
  st_t         st;
  logic [15:0] pushed, lines_seen, lines_started;
  logic        in_line, pad;
  logic        f_push, f_pop, f_full, f_empty;
  logic [31:0] f_wdata, f_rdata;
  logic        e_start, e_busy, e_done, e_err, rs_valid, rs_ready, ws_ready;
  logic [31:0] rs_data, e_cycles;

  wire capt      = (st == CAPT);
  wire pix_in    = capt && vid && !pad && (lines_seen < v_active || in_line);
  wire line_beg  = pix_in && !in_line;
  wire want      = pix_in && ((line_beg ? 16'd0 : pushed) < h_active);
  assign f_push  = (want && !f_full) || (pad && !f_full);
  assign f_wdata = pad ? 32'h0 : pix;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE; pushed <= '0; lines_seen <= '0; lines_started <= '0; in_line <= 1'b0; pad <= 1'b0;
      ovf <= 1'b0; len_err <= 1'b0; cycles <= '0; lines <= '0;
    end else begin
      case (st)
        IDLE: if (arm) begin
          st <= WAIT_VS; ovf <= 1'b0; len_err <= 1'b0; lines <= '0;
          lines_seen <= '0; lines_started <= '0; in_line <= 1'b0; pad <= 1'b0;
        end
        WAIT_VS: if (vs_rise) begin
          if (v_active == 0) st <= DRAIN; else st <= CAPT;
          cycles <= '0;
        end
        default: ;
      endcase
      if (st == CAPT || st == DRAIN) cycles <= cycles + 32'd1;
      if (capt) begin
        if (line_beg) begin
          in_line <= 1'b1; lines_seen <= lines_seen + 16'd1;
          pushed  <= 16'(f_push);
          if (h_active == 0) len_err <= 1'b1;
        end else if (pad) begin
          if (f_push) pushed <= pushed + 16'd1;
          if (f_push && pushed + 16'd1 >= h_active) begin
            pad <= 1'b0;
            if (lines_seen >= v_active) st <= DRAIN;
          end
        end else if (in_line && vid) begin
          if (f_push) pushed <= pushed + 16'd1;
          if (pushed >= h_active) len_err <= 1'b1;   // longer line: cut
        end else if (in_line && !vid) begin         // end of the video period
          in_line <= 1'b0;
          if (pushed < h_active) begin
            pad <= 1'b1; len_err <= 1'b1;
          end else if (lines_seen >= v_active) st <= DRAIN;
        end
        if (want && f_full) ovf <= 1'b1;
        if (vid && pad) ovf <= 1'b1;                // next line while padding
      end
      // H_ACTIVE = 0: lines are counted, nothing is written
      if (e_start || (line_beg && h_active == 0)) lines_started <= lines_started + 16'd1;
      if (e_done || (line_beg && h_active == 0)) lines <= lines + 16'd1;
      if (st == DRAIN && !e_busy && !e_start && lines_started == lines_seen) st <= IDLE;
    end
  end
  // a line job starts once its first pixel is in and the engine is idle
  assign e_start = (st == CAPT || st == DRAIN) && !e_busy && !e_done && (lines_started != lines_seen)
                   && h_active != 0;

  tv_fifo #(.W(32), .DEPTH(FIFO_DEPTH)) u_fifo (
    .clk, .rst_n, .clr(st == IDLE && arm), .push(f_push), .wdata(f_wdata),
    .pop(f_pop), .rdata(f_rdata), .empty(f_empty), .full(f_full), .count()
  );
  assign f_pop = !f_empty && ws_ready;

  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(1'b0), .wr_en(1'b1),
    .src(32'h0), .dst(fb_addr + 32'(lines_started) * 32'(stride)), .len(h_active),
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
  assign rs_ready = 1'b1;

  // ERR is sticky over the frame (the engine's own flag clears per job)
  logic err_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) err_q <= 1'b0;
    else if (st == IDLE && arm) err_q <= 1'b0;
    else if (e_done && e_err) err_q <= 1'b1;
  end
  // (ERR in STATUS also shows an error of the line job that just ended)
  wire frame_end = (st == DRAIN) && !e_busy && !e_start && (lines_started == lines_seen);
  assign err     = err_q | (e_done & e_err);
  assign busy    = (st != IDLE);
  assign done    = frame_end;
  assign err_irq = frame_end && (err_q || (e_done && e_err));
  assign ovf_irq = capt && ((want && f_full) || (vid && pad));
  assign hpd     = hpd_en;
endmodule
