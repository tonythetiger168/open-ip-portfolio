// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// QSPI_XIP: quad-SPI NOR flash controller with execute-in-place (AXI4
// subordinate read window, APB4 registers for flash commands)
// ----------------------------------------------------------------------------
// The flash-host role that the QSPI_top target does not cover (boot flash).
// - XIP: an AXI4 read of the window reads the flash at addr[23:0] with
//   QUAD (0x6B, quad output fast read: command and address on IO0, 8 dummy
//   clocks, data on IO3..0) or, with QUAD = 0, 0x0B (fast read, single).
//   Bytes are little-endian in a word (flash byte A in bits 8 * A[1:0] + 7 :
//   8 * A[1:0]). INCR, FIXED and WRAP bursts of any length, AxSIZE 0..2: each
//   beat returns the word holding its address. The read stays open after a
//   burst: a burst that starts at the next word of the stream continues it
//   without a new command; any other address closes chip select and starts
//   a new read. SCLK stops while R is held off, so RREADY low never loses
//   data. AXI writes get SLVERR.
// - Command port (PC_*): one flash command in single-bit mode: the command
//   byte, optionally a 24-bit address, PC_NWR (0..4) data bytes from
//   PC_WDATA (byte 0 first), PC_NRD (0..4) bytes into PC_RDATA (byte 0 in
//   bits 7:0). Used for 0x05 read status, 0x06 write enable, 0x02 page
//   program, 0x20 sector erase, 0x9F ID and so on. A command closes the XIP
//   stream; it waits for an XIP burst in progress, and XIP waits for it.
// - SPI mode 0. Half an SCLK period is DIV + 1 clocks. IO2 / IO3 (WP#,
//   HOLD#) are driven high outside the quad data phase.
// - Counters: XIP_CMDS (read commands issued), XIP_BEATS.
// ============================================================================
module QSPI_XIP_top (
  input  logic        clk,
  input  logic        rst_n,
  // flash pins
  output logic        sclk,
  output logic        csn,
  inout  tri   [3:0]  io,
  // configuration
  input  logic [7:0]  div,
  input  logic        quad,
  // command port
  input  logic [7:0]  pc_cmd,
  input  logic        pc_has_addr,
  input  logic [23:0] pc_addr,
  input  logic [2:0]  pc_nwr,
  input  logic [2:0]  pc_nrd,
  input  logic [31:0] pc_wdata,
  input  logic        pc_start,
  output logic [31:0] pc_rdata,
  output logic        pc_busy,
  output logic        pc_done,
  output logic [15:0] xip_cmds,
  output logic [15:0] xip_beats,
  // AXI4 subordinate (s_*): XIP read window
  input  logic [3:0]  s_awid,
  input  logic [31:0] s_awaddr,
  input  logic [7:0]  s_awlen,
  input  logic [2:0]  s_awsize,
  input  logic [1:0]  s_awburst,
  input  logic        s_awvalid,
  output logic        s_awready,
  input  logic [31:0] s_wdata,
  input  logic [3:0]  s_wstrb,
  input  logic        s_wlast,
  input  logic        s_wvalid,
  output logic        s_wready,
  output logic [3:0]  s_bid,
  output logic [1:0]  s_bresp,
  output logic        s_bvalid,
  input  logic        s_bready,
  input  logic [3:0]  s_arid,
  input  logic [31:0] s_araddr,
  input  logic [7:0]  s_arlen,
  input  logic [2:0]  s_arsize,
  input  logic [1:0]  s_arburst,
  input  logic        s_arvalid,
  output logic        s_arready,
  output logic [3:0]  s_rid,
  output logic [31:0] s_rdata,
  output logic [1:0]  s_rresp,
  output logic        s_rlast,
  output logic        s_rvalid,
  input  logic        s_rready
);
  // ------------------------------------------------------------ command port
  logic        pc_run;
  logic [2:0]  pc_got;
  logic        xip_act;                 // an XIP burst is in progress
  logic        s_open;                  // the XIP read stream is open (CS low, in P_RD)
  logic        x_go;                    // XIP wants a new read command
  logic [23:0] x_addr;
  logic        x_more;
  logic        x_hold;
  logic        x_stop;
  // PC_WDATA byte 0 goes out first
  wire  [31:0] j_wdata_bs = {pc_wdata[7:0], pc_wdata[15:8], pc_wdata[23:16], pc_wdata[31:24]};
  logic [2:0]  pc_nrd_q;
  logic        pc_job;                  // the engine is running the command

  // ------------------------------------------------------------ SPI engine
  typedef enum logic [2:0] {P_IDLE, P_CMD, P_ADDR, P_DUMMY, P_WR, P_RD, P_GAP} ph_t;
  ph_t         ph;
  logic [7:0]  cnt;                     // clocks left in this half period
  logic [5:0]  nb;                      // bits (or quad clocks) left in this phase
  logic [31:0] osh;                     // output shift (MSB first)
  logic [7:0]  ish;                     // input byte being assembled
  logic [2:0]  ibit;                    // input bits / nibbles of the byte so far
  logic        q_rd;                    // the read phase is quad
  logic        has_a, more;             // job has an address; read wants more bytes
  logic [2:0]  nwr;
  logic [7:0]  cmd_q;
  logic [23:0] addr_q;
  logic [7:0]  dmy;                     // dummy clocks of the job
  logic        rb_valid;                // a read byte is complete (one clock)
  logic [7:0]  rb_data;
  logic        hold;                    // consumer full: stop SCLK at the byte boundary
  logic        go;                      // start a job (from IDLE)
  logic        stop;                    // end the read phase (from P_RD, at a byte boundary)
  logic [3:0]  io_o, io_oe;
  assign io[0] = io_oe[0] ? io_o[0] : 1'bz;
  assign io[1] = io_oe[1] ? io_o[1] : 1'bz;
  assign io[2] = io_oe[2] ? io_o[2] : 1'bz;
  assign io[3] = io_oe[3] ? io_o[3] : 1'bz;
  always_comb begin
    io_o = {2'b11, 1'b0, osh[31]}; io_oe = 4'b1101;
    if (ph == P_RD && q_rd) io_oe = 4'b0000;
    if (ph == P_DUMMY && q_rd) io_oe = 4'b0000;        // the flash may turn IO3..0 around
    if (csn) io_oe = 4'b1100;
  end
  wire tick = (cnt == 8'd0);
  wire byte_edge = (ibit == 3'd0);      // no partial input byte

  // job request (muxed between XIP and the command port)
  logic        j_go, j_has_addr, j_quad;
  logic [7:0]  j_cmd, j_dmy;
  logic [23:0] j_addr;
  logic [2:0]  j_nwr;
  logic [31:0] j_wdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= P_IDLE; cnt <= '0; nb <= '0; osh <= '0; ish <= '0; ibit <= '0; q_rd <= 1'b0;
      has_a <= 1'b0; nwr <= '0; cmd_q <= '0; addr_q <= '0; dmy <= '0; sclk <= 1'b0; csn <= 1'b1;
      rb_valid <= 1'b0; rb_data <= '0;
    end else begin
      rb_valid <= 1'b0;
      if (ph != P_IDLE && !tick) cnt <= cnt - 8'd1;
      case (ph)
        P_IDLE: begin
          sclk <= 1'b0;
          if (j_go) begin
            csn <= 1'b0; cnt <= div; ph <= P_CMD; nb <= 6'd8;
            osh <= {j_cmd, 24'd0}; has_a <= j_has_addr; addr_q <= j_addr; q_rd <= j_quad;
            dmy <= j_dmy; nwr <= j_nwr; cmd_q <= j_cmd; ibit <= '0;
          end
        end
        P_GAP: if (tick) begin ph <= P_IDLE; cnt <= div; end   // CS high time
        default: if (tick && !(ph == P_RD && hold && !stop && byte_edge && !sclk)) begin
          cnt <= div;
          if (ph == P_RD && stop && byte_edge && !sclk) begin
            csn <= 1'b1; ph <= P_GAP;
          end else if (!sclk) begin                         // rising edge: sample
            sclk <= 1'b1;
            if (ph == P_RD) begin
              if (q_rd) begin
                ish <= {ish[3:0], io};
                if (ibit == 3'd1) begin rb_valid <= 1'b1; rb_data <= {ish[3:0], io}; ibit <= '0; end
                else ibit <= ibit + 3'd1;
              end else begin
                ish <= {ish[6:0], io[1]};
                if (ibit == 3'd7) begin rb_valid <= 1'b1; rb_data <= {ish[6:0], io[1]}; ibit <= '0; end
                else ibit <= ibit + 3'd1;
              end
            end
          end else begin                                    // falling edge: next output
            sclk <= 1'b0;
            if (ph != P_RD) begin
              osh <= {osh[30:0], 1'b0};
              nb <= nb - 6'd1;
              if (nb == 6'd1) begin
                // next phase
                if (ph == P_CMD && has_a) begin ph <= P_ADDR; osh <= {addr_q, 8'd0}; nb <= 6'd24; end
                else if ((ph == P_CMD || ph == P_ADDR) && dmy != 8'd0) begin ph <= P_DUMMY; nb <= dmy[5:0]; end
                else if ((ph == P_CMD || ph == P_ADDR || ph == P_DUMMY) && nwr != 3'd0) begin
                  ph <= P_WR; osh <= j_wdata_bs; nb <= {nwr, 3'b000};
                end
                else if (more) begin ph <= P_RD; ibit <= '0; end
                else begin csn <= 1'b1; ph <= P_GAP; end
              end
            end
          end
        end
      endcase
    end
  end

  wire         pc_req = pc_run && ph == P_IDLE && !xip_act && !s_open;
  always_comb begin
    j_go = 1'b0; j_cmd = 8'h0B; j_has_addr = 1'b1; j_addr = x_addr; j_dmy = 8'd8; j_nwr = 3'd0;
    j_quad = 1'b0; j_wdata = pc_wdata;
    if (pc_req) begin
      j_go = 1'b1; j_cmd = pc_cmd; j_has_addr = pc_has_addr; j_addr = pc_addr; j_dmy = 8'd0;
      j_nwr = pc_nwr;
    end else if (x_go && ph == P_IDLE) begin
      j_go = 1'b1; j_cmd = quad ? 8'h6B : 8'h0B; j_quad = quad;
    end
    more = pc_job ? (pc_got < pc_nrd_q) : x_more;
    hold = pc_job ? 1'b0 : x_hold;
    stop = pc_job ? (pc_got >= pc_nrd_q) : x_stop;
  end
  assign pc_busy = pc_run;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_run <= 1'b0; pc_got <= '0; pc_nrd_q <= '0; pc_job <= 1'b0; pc_rdata <= '0; pc_done <= 1'b0;
    end else begin
      pc_done <= 1'b0;
      if (pc_start && !pc_run) begin
        pc_run <= 1'b1; pc_got <= '0; pc_nrd_q <= (pc_nrd > 3'd4) ? 3'd4 : pc_nrd; pc_rdata <= '0;
      end
      if (pc_req) pc_job <= 1'b1;
      if (pc_job && rb_valid) begin
        pc_rdata[8 * pc_got[1:0] +: 8] <= rb_data; pc_got <= pc_got + 3'd1;
      end
      if (pc_job && ph == P_GAP && tick) begin pc_job <= 1'b0; pc_run <= 1'b0; pc_done <= 1'b1; end
    end
  end

  // ------------------------------------------------------------ XIP (AXI)
  typedef enum logic [2:0] {X_IDLE, X_OPEN, X_FILL, X_BEAT, X_CLOSE, X_SHUT} xs_t;
  xs_t         xs;
  logic [3:0]  id_q;
  logic [31:0] a_q;                     // beat address
  logic [7:0]  len_q, beat_q;
  logic [2:0]  size_q;
  logic [1:0]  burst_q;
  logic [31:0] wbuf;                    // word being assembled from the stream
  logic [1:0]  wb_n;                    // bytes in wbuf
  logic [21:0] s_next;                  // next word address of the open stream
  logic [31:0] w_last;                  // last word read, and its address
  logic [21:0] w_last_a;
  logic        w_last_v;
  logic        last_pref;

  // next beat address (AXI4 A3.4.1)
  logic [31:0] inc, nxt, wmask, a_nx;
  always_comb begin
    inc   = 32'd1 << size_q;
    nxt   = (a_q & ~(inc - 32'd1)) + inc;
    wmask = ((32'(len_q) + 32'd1) << size_q) - 32'd1;
    case (burst_q)
      2'b00:   a_nx = a_q;
      2'b10:   a_nx = (a_q & ~wmask) | (nxt & wmask);
      default: a_nx = nxt;
    endcase
  end

  wire [21:0] wa = a_q[23:2];
  assign xip_act = (xs != X_IDLE) && (xs != X_SHUT);
  assign x_more  = 1'b1;
  assign x_hold  = (xs != X_FILL);                // pause at a word boundary
  assign x_stop  = (xs == X_CLOSE) || (xs == X_SHUT);
  assign x_addr  = {wa, 2'b00};
  assign x_go    = (xs == X_OPEN);
  assign s_arready = (xs == X_IDLE) && !pc_run && s_arvalid;
  assign s_rvalid  = (xs == X_BEAT);
  assign s_rid     = id_q;
  assign s_rresp   = 2'b00;
  assign s_rlast   = (beat_q == len_q);
  assign s_rdata   = w_last;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      xs <= X_IDLE; id_q <= '0; a_q <= '0; len_q <= '0; beat_q <= '0; size_q <= '0; burst_q <= '0;
      wbuf <= '0; wb_n <= '0; s_open <= 1'b0; s_next <= '0; w_last <= '0; w_last_a <= '0;
      w_last_v <= 1'b0; xip_cmds <= '0; xip_beats <= '0;
    end else begin
      if (rb_valid && !pc_job) begin
        wbuf[8 * wb_n +: 8] <= rb_data; wb_n <= wb_n + 2'd1;
        if (wb_n == 2'd3) begin
          w_last <= {rb_data, wbuf[23:0]}; w_last_a <= s_next; w_last_v <= 1'b1;
          s_next <= s_next + 22'd1;
        end
      end
      if (pc_req) begin s_open <= 1'b0; w_last_v <= 1'b0; end
      case (xs)
        X_IDLE: if (s_arready) begin
          id_q <= s_arid; a_q <= s_araddr; len_q <= s_arlen; size_q <= s_arsize;
          burst_q <= s_arburst; beat_q <= '0;
          if (w_last_v && w_last_a == s_araddr[23:2]) xs <= X_BEAT;            // word at hand
          else if (s_open && s_next == s_araddr[23:2]) xs <= X_FILL;             // continue
          else if (s_open) xs <= X_CLOSE;
          else xs <= X_OPEN;
        end else if (pc_run && s_open) xs <= X_SHUT;        // a command needs the bus
        X_SHUT: if (ph == P_IDLE) begin s_open <= 1'b0; xs <= X_IDLE; end
        X_CLOSE: if (ph == P_IDLE) begin s_open <= 1'b0; xs <= X_OPEN; end
        X_OPEN: if (ph == P_IDLE) begin                                        // j_go now
          s_open <= 1'b1; s_next <= wa; wb_n <= '0; w_last_v <= 1'b0;
          xip_cmds <= xip_cmds + 16'd1; xs <= X_FILL;
        end
        X_FILL: if (rb_valid && wb_n == 2'd3) xs <= X_BEAT;
        X_BEAT: if (s_rready) begin
          xip_beats <= xip_beats + 16'd1;
          if (beat_q == len_q) xs <= X_IDLE;
          else begin
            beat_q <= beat_q + 8'd1; a_q <= a_nx;
            if (a_nx[23:2] == w_last_a) xs <= X_BEAT;                     // same word
            else if (a_nx[23:2] == s_next) xs <= X_FILL;
            else xs <= X_CLOSE;
          end
        end
        default: xs <= X_IDLE;
      endcase
    end
  end

  // AXI writes: consumed, SLVERR
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} ws_t;
  ws_t wst;
  logic [3:0] bid_q;
  assign s_awready = (wst == W_IDLE) && s_awvalid;
  assign s_wready  = (wst == W_DATA);
  assign s_bvalid  = (wst == W_RESP);
  assign s_bid     = bid_q;
  assign s_bresp   = 2'b10;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin wst <= W_IDLE; bid_q <= '0; end
    else case (wst)
      W_IDLE: if (s_awvalid) begin bid_q <= s_awid; wst <= W_DATA; end
      W_DATA: if (s_wvalid && s_wlast) wst <= W_RESP;
      W_RESP: if (s_bready) wst <= W_IDLE;
      default: wst <= W_IDLE;
    endcase
  end
  wire _unused = &{1'b0, s_awaddr, s_awlen, s_awsize, s_awburst, s_wdata, s_wstrb, cmd_q,
                   j_wdata, last_pref, wbuf[31:24]};
endmodule
