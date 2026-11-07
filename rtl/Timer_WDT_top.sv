// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Timer_WDT: system timer and watchdog of the phone SoC, with timestamp
// records in memory (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// A prescaler makes one tick every PRESCALE + 1 clocks; COUNT is a free-
// running 32-bit tick counter.
// - Timer: with TMR_EN set, the TIMER interrupt fires every PERIOD + 1
// ticks (periodic, auto-reload; lowering PERIOD below the current count
// ends the current period at the next tick). With TS_EN also set, each timer event
// writes COUNT at that tick as one 32-bit record into a ring of TS_WORDS
// words at TS_BASE (record n at TS_BASE + 4 * (n mod TS_WORDS)); TS_WP
// counts records written. An event while the previous record is still
// being written is not recorded (TS_MISSED counts it).
// - Watchdog: with WDT_EN set, a down-counter loaded with WDT_LOAD counts
// ticks; CMD.kick reloads it. When it reaches 0 the BARK interrupt fires and
// it reloads; if it reaches 0 again without a kick, wdt_reset goes high
// (the BITE: a reset request to the power manager) and stays high until a
// kick or WDT_EN = 0.
// - TS_ERR is set when a record write got an AXI error response.
// - AXI ID = AXI_ID, single-beat writes.
// ============================================================================
module Timer_WDT_top #(
  parameter logic [3:0] AXI_ID = 4'd11
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] prescale,
  input  logic        tmr_en,
  input  logic [31:0] period,
  input  logic        ts_en,
  input  logic [31:0] ts_base,
  input  logic [15:0] ts_words,
  input  logic        wdt_en,
  input  logic [31:0] wdt_load,
  input  logic        kick,
  output logic [31:0] count,
  output logic [15:0] ts_wp,
  output logic [15:0] ts_missed,
  output logic [31:0] wdt_count,
  output logic        wdt_reset,
  output logic        tmr_irq,
  output logic        bark,
  output logic        ts_err,
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
  logic        rs_valid, rs_ready, ws_valid, ws_ready, e_done, e_busy, e_err;
  logic [31:0] rs_data, ws_data, e_cycles, tcnt, rec;
  logic [15:0] pre, slot;
  logic        barked;

  wire tick = (pre >= prescale);
  assign tmr_irq = tmr_en && tick && tcnt >= period;
  assign bark    = wdt_en && tick && wdt_count == 0 && !barked && !kick;
  wire   go      = tmr_irq && ts_en && ts_words != 0 && !e_busy && !e_done;   // not in the DONE clock: slot moves on

  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(go), .rd_en(1'b0), .wr_en(1'b1),
    .src(32'd0), .dst(ts_base + {14'd0, slot, 2'b00}), .len(16'd1),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cycles),
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
  assign rs_ready = 1'b0;
  assign ws_valid = e_busy;
  assign ws_data  = rec;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pre <= '0; count <= '0; tcnt <= '0; rec <= '0; slot <= '0; ts_wp <= '0; ts_missed <= '0;
      wdt_count <= '0; barked <= 1'b0; wdt_reset <= 1'b0;
    end else begin
      pre <= tick ? 16'd0 : pre + 16'd1;
      if (tick) count <= count + 32'd1;
      // timer
      if (!tmr_en) tcnt <= '0;
      else if (tick) tcnt <= (tcnt >= period) ? 32'd0 : tcnt + 32'd1;
      if (go) rec <= count;
      if (tmr_irq && ts_en && ts_words != 0 && (e_busy || e_done) && ts_missed != 16'hFFFF) ts_missed <= ts_missed + 16'd1;
      if (e_done) begin
        ts_wp <= ts_wp + 16'd1;
        slot  <= (slot + 16'd1 >= ts_words) ? 16'd0 : slot + 16'd1;
      end
      // watchdog
      if (!wdt_en) begin
        wdt_count <= wdt_load; barked <= 1'b0; wdt_reset <= 1'b0;
      end else if (kick) begin
        wdt_count <= wdt_load; barked <= 1'b0; wdt_reset <= 1'b0;
      end else if (tick) begin
        if (wdt_count == 0) begin
          wdt_count <= wdt_load;
          if (barked) wdt_reset <= 1'b1;
          barked <= 1'b1;
        end else begin
          wdt_count <= wdt_count - 32'd1;
        end
      end
    end
  end
  assign ts_err = e_done && e_err;
  wire unused = &{1'b0, rs_valid, rs_data, e_cycles};
endmodule
