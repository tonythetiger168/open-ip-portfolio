// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// IR_Receiver: consumer infrared remote decoder of the TV SoC (NEC and RC5)
// with a code ring DMA (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Input ir_in is the demodulated output of the IR receiver module: low while
// a carrier burst (mark) is present, high otherwise (space). It is
// synchronised with two flops.
// - Time base: one tick every TICK_DIV + 1 clks. Nominal timings in ticks
// (one tick = 562.5 us / 16 = 35.16 us for the real protocols):
// NEC: unit T = 16 ticks; leader 16T mark + 8T space; repeat 16T mark + 4T
// space + 1T mark; bit = 1T mark + 1T space (0) or 3T space (1), 32 bits
// LSB first {~cmd, cmd, addr_hi, addr}, then a 1T stop mark.
// RC5: half bit H = 25 ticks (889 us); 14 Manchester bits MSB first
// {S1 = 1, S2, toggle, addr[4:0], cmd[5:0]}, 1 = space then mark.
// Every mark / space must be within +-25 % of its nominal length (H and 2H
// for RC5), otherwise the frame is discarded and RX_ERR counts it.
// - MODE selects the protocol (0 NEC, 1 RC5).
// - Code word: {proto[1:0] (0 NEC, 1 RC5), repeat, toggle, 4'b0, addr_hi[7:0],
// addr[7:0], cmd[7:0]}. NEC: addr / addr_hi are bytes 0 / 1 (extended NEC
// addresses accepted), cmd byte 2; byte 3 must be ~cmd. A NEC repeat frame
// repeats the last code with repeat = 1 (none before a first code: RX_ERR).
// RC5: addr = {3'b0, A[4:0]}, cmd = {1'b0, ~S2, C[5:0]} (RC5X command 6).
// - Ring DMA: each code is written as one word at RING_BASE + 4 * WR_IDX;
// RING_WORDS words (at least 2), software consumes them and writes RD_IDX.
// While the ring is full (WR_IDX + 1 = RD_IDX mod RING_WORDS) codes wait in
// an 8-entry FIFO; a code that finds that FIFO full is dropped and counted
// in OVF_CNT. CODE pulses when a code
// is in memory, ERR as well on an AXI error response. LAST holds the last
// decoded code.
// ============================================================================
module IR_Receiver_top #(
  parameter logic [3:0] AXI_ID = 4'd5
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        ir_in,
  // configuration
  input  logic        enable,
  input  logic        mode,
  input  logic [15:0] tick_div,
  input  logic [31:0] ring_base,
  input  logic [15:0] ring_words,
  input  logic [15:0] rd_idx,
  // status
  output logic [31:0] last,
  output logic [15:0] wr_idx,
  output logic [15:0] code_cnt,
  output logic [15:0] rx_err_cnt,
  output logic [15:0] ovf_cnt,
  output logic        err,
  output logic        code,
  output logic        rx_err,
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
  // ---------------- input sync, tick, run lengths ----------------
  logic [1:0]  sync;
  logic        lvl;                              // 1 = mark (carrier)
  logic [15:0] pre;
  logic        tick;
  logic [9:0]  run;                              // ticks of the current run (saturating)
  logic        run_end;                          // a run of level ~lvl and length run ended
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync <= 2'b11; pre <= '0; tick <= 1'b0;
    end else begin
      sync <= {sync[0], ir_in};
      tick <= 1'b0;
      if (pre >= tick_div) begin pre <= '0; tick <= 1'b1; end
      else pre <= pre + 16'd1;
    end
  end
  wire mark = ~sync[1];
  logic [9:0] ended_len;
  logic       ended_lvl;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lvl <= 1'b0; run <= '0; run_end <= 1'b0; ended_len <= '0; ended_lvl <= 1'b0;
    end else begin
      run_end <= 1'b0;
      if (!enable) begin
        lvl <= mark; run <= '0;
      end else if (mark != lvl) begin
        run_end <= 1'b1; ended_len <= run; ended_lvl <= lvl;
        lvl <= mark; run <= '0;
      end else if (tick && run != 10'h3FF) run <= run + 10'd1;
    end
  end
  function automatic logic near(input logic [9:0] x, input int nom);
    near = ({22'd0, x} >= nom - nom / 4) && ({22'd0, x} <= nom + nom / 4);
  endfunction

  // ---------------- NEC ----------------
  typedef enum logic [2:0] {N_IDLE, N_LS, N_RPT, N_BM, N_BS, N_STOP} nst_t;
  nst_t        ns;
  logic [31:0] nd;
  logic [5:0]  nbits;
  logic        n_emit, n_err, n_rpt;
  // ---------------- RC5 ----------------
  logic [27:0] hb;                               // half-bit levels, hb[0] = first mark
  logic [4:0]  nh;
  logic        r_on, r_skip, r_emit, r_err;
  logic [13:0] rbits;
  logic        have_last;

  // idle: a space longer than the longest legal one ends a frame
  wire idle_to = !lvl && tick && (run == (mode ? 10'd80 : 10'd200));

  always_comb begin
    rbits = '0;
    rbits[13] = 1'b1;
    for (int k = 1; k < 14; k++) rbits[13-k] = hb[2*k];   // second half of bit k = its value
  end
  logic rc5_ok;
  always_comb begin
    rc5_ok = 1'b1;
    for (int k = 1; k < 14; k++) if (hb[2*k-1] == hb[2*k]) rc5_ok = 1'b0;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ns <= N_IDLE; nd <= '0; nbits <= '0; n_emit <= 1'b0; n_err <= 1'b0; n_rpt <= 1'b0;
      hb <= '0; nh <= '0; r_on <= 1'b0; r_skip <= 1'b0; r_emit <= 1'b0; r_err <= 1'b0;
    end else begin
      n_emit <= 1'b0; n_err <= 1'b0; r_emit <= 1'b0; r_err <= 1'b0;
      if (!enable || mode) ns <= N_IDLE;
      else if (run_end) begin
        case (ns)
          N_IDLE: if (ended_lvl && near(ended_len, 256)) ns <= N_LS;
          N_LS:   if (!ended_lvl && near(ended_len, 128)) begin ns <= N_BM; nbits <= '0; end
                  else if (!ended_lvl && near(ended_len, 64)) ns <= N_RPT;
                  else begin ns <= N_IDLE; n_err <= 1'b1; end
          N_RPT:  begin
                    ns <= N_IDLE;
                    if (ended_lvl && near(ended_len, 16)) begin n_emit <= 1'b1; n_rpt <= 1'b1; end
                    else n_err <= 1'b1;
                  end
          N_BM:   if (ended_lvl && near(ended_len, 16)) begin
                    if (nbits == 6'd32) ns <= N_IDLE; else ns <= N_BS;
                  end
                  else begin ns <= N_IDLE; n_err <= 1'b1; end
          N_BS:   begin
                    if (!ended_lvl && (near(ended_len, 16) || near(ended_len, 48))) begin
                      nd <= {near(ended_len, 48), nd[31:1]};
                      nbits <= nbits + 6'd1;
                      ns <= N_BM;
                    end else begin ns <= N_IDLE; n_err <= 1'b1; end
                  end
          default: ns <= N_IDLE;
        endcase
        // the stop mark after 32 bits
        if (ns == N_BM && nbits == 6'd32 && ended_lvl && near(ended_len, 16)) begin
          if (nd[31:24] == ~nd[23:16]) begin n_emit <= 1'b1; n_rpt <= 1'b0; end
          else n_err <= 1'b1;
        end
      end else if (idle_to && ns != N_IDLE) begin
        ns <= N_IDLE; n_err <= 1'b1;
      end
      // RC5: collect half bits
      if (!enable || !mode) begin
        r_on <= 1'b0;
      end else if (!r_on) begin
        if (mark && !lvl) begin r_on <= 1'b1; r_skip <= 1'b1; hb <= '0; nh <= '0; end   // first mark: 2nd half of S1
      end else if (run_end && r_skip) begin
        r_skip <= 1'b0;                           // the idle space before the frame
      end else if (run_end) begin
        if (near(ended_len, 25) || near(ended_len, 50)) begin
          for (int i = 0; i < 28; i++) begin
            if (i == nh) hb[i] <= ended_lvl;
            if (near(ended_len, 50) && i == nh + 1) hb[i] <= ended_lvl;
          end
          nh <= nh + (near(ended_len, 50) ? 5'd2 : 5'd1);
          if (nh + (near(ended_len, 50) ? 5'd2 : 5'd1) > 5'd27) begin r_on <= 1'b0; r_err <= 1'b1; end
        end else begin
          r_on <= 1'b0; r_err <= 1'b1;
        end
      end else if (idle_to) begin                 // the rest are spaces
        r_on <= 1'b0;
        if (nh >= 5'd26) r_emit <= 1'b1; else r_err <= 1'b1;
      end
    end
  end
  // RC5 frame check at r_emit (spaces after nh are already 0 in hb)
  wire        rc5_good = rc5_ok;
  wire [31:0] nec_code = {2'd0, n_rpt, 1'b0, 4'b0, nd[15:8], nd[7:0], nd[23:16]};
  wire [31:0] rc5_code = {2'd1, 1'b0, rbits[11], 4'b0, 8'h00, 3'b0, rbits[10:6], 1'b0, ~rbits[12], rbits[5:0]};
  wire        got      = (n_emit && (!n_rpt || have_last)) || (r_emit && rc5_good);
  wire [31:0] got_code = r_emit ? rc5_code : (n_rpt ? {last[31:30], 1'b1, last[28:0]} : nec_code);
  assign rx_err = enable && (n_err || r_err || (r_emit && !rc5_good) || (n_emit && n_rpt && !have_last));

  // ---------------- code FIFO and ring DMA ----------------
  logic        f_push, f_pop, f_empty, f_full;
  logic [31:0] f_rdata;
  logic        e_start, e_busy, e_done, e_err, rs_valid, ws_ready;
  logic [31:0] rs_data, e_cycles;
  wire  [15:0] nw      = (ring_words == 0) ? 16'd1 : ring_words;
  wire  [15:0] wr_next = (wr_idx + 16'd1 >= nw) ? 16'd0 : wr_idx + 16'd1;
  assign f_push  = got && !f_full;
  assign e_start = !f_empty && !e_busy && !e_done && (wr_next != rd_idx) && enable;
  assign f_pop   = e_done;
  tv_fifo #(.W(32), .DEPTH(8)) u_fifo (
    .clk, .rst_n, .clr(1'b0), .push(f_push), .wdata(got_code),
    .pop(f_pop), .rdata(f_rdata), .empty(f_empty), .full(f_full), .count()
  );
  // a code that finds the ring full waits in the FIFO; one that finds the
  // FIFO full is dropped
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last <= '0; have_last <= 1'b0; wr_idx <= '0; code_cnt <= '0; rx_err_cnt <= '0; ovf_cnt <= '0; err <= 1'b0;
    end else begin
      if (got) begin last <= got_code; if (!r_emit) have_last <= 1'b1; end
      if (got && f_full && ovf_cnt != 16'hFFFF) ovf_cnt <= ovf_cnt + 16'd1;
      if (rx_err && rx_err_cnt != 16'hFFFF) rx_err_cnt <= rx_err_cnt + 16'd1;
      if (e_done) begin
        wr_idx <= wr_next;
        if (code_cnt != 16'hFFFF) code_cnt <= code_cnt + 16'd1;
        if (e_err) err <= 1'b1;
      end
      if (!enable && !e_busy && f_empty) begin wr_idx <= '0; err <= 1'b0; have_last <= 1'b0; end
    end
  end
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(1'b0), .wr_en(1'b1),
    .src(32'h0), .dst(ring_base + {wr_idx, 2'b00}), .len(16'd1),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cycles),
    .rs_valid, .rs_data, .rs_ready(1'b1), .ws_valid(e_busy), .ws_data(f_rdata), .ws_ready,
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
  assign code    = e_done;
  assign err_irq = e_done && e_err;
endmodule
