// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Interrupt_Controller: 32-source interrupt controller of the phone SoC with
// an in-memory event log (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Collects the level interrupts of the subsystems and peripherals
// (irq_src[31:0], active high) and drives one CPU interrupt:
// - PENDING = (irq_src | SW_SET) & ENABLE; cpu_irq = |PENDING.
// - CLAIM gives the highest-priority pending source, the lowest-numbered
// one: {valid (bit 31), id (bits 4:0)}. A source is acknowledged at the
// device (its level falls) or, for SW_SET bits, by clearing the bit.
// - Event log: with LOG_EN set, each source that becomes pending is written
// as one 32-bit record {timestamp[23:0], 3'b000, id[4:0]} into a ring of
// LOG_WORDS words at LOG_BASE (record n at LOG_BASE + 4 * (n mod
// LOG_WORDS)); the timestamp is a free-running clock counter taken when the
// record is written. LOG_WP counts records written. Sources that become
// pending again before their record is written are merged.
// - Interrupt CPU follows cpu_irq; LOG_ERR is set when a record write got
// an AXI error response. AXI ID = AXI_ID, single-beat writes.
// ============================================================================
module Interrupt_Controller_top #(
  parameter logic [3:0] AXI_ID = 4'd10
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] irq_src,
  input  logic [31:0] enable,
  input  logic [31:0] sw_set,
  input  logic        log_en,
  input  logic [31:0] log_base,
  input  logic [15:0] log_words,
  output logic [31:0] pending,
  output logic [31:0] claim,
  output logic [15:0] log_wp,
  output logic        cpu_irq,
  output logic        log_err,
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
  logic [31:0] rs_data, ws_data, e_cycles;
  logic [31:0] pend_q, tolog;
  logic [23:0] ts;
  logic [15:0] slot;
  logic [4:0]  lid;
  logic        lvalid;

  assign pending = (irq_src | sw_set) & enable;
  assign cpu_irq = |pending;
  always_comb begin
    claim = '0;
    for (int i = 31; i >= 0; i--) if (pending[i]) claim = {1'b1, 26'd0, 5'(i)};
  end
  // lowest-numbered source waiting for its log record
  always_comb begin
    lid = '0; lvalid = 1'b0;
    for (int i = 31; i >= 0; i--) if (tolog[i]) begin lid = 5'(i); lvalid = 1'b1; end
  end
  wire go = log_en && lvalid && !e_busy && !e_done && log_words != 0;   // not in the DONE clock: slot moves on
  logic [4:0] lid_q;

  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(go), .rd_en(1'b0), .wr_en(1'b1),
    .src(32'd0), .dst(log_base + {14'd0, slot, 2'b00}), .len(16'd1),
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
  assign ws_data  = {ts, 3'b000, lid_q};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend_q <= '0; tolog <= '0; ts <= '0; slot <= '0; log_wp <= '0; lid_q <= '0;
    end else begin
      ts     <= ts + 24'd1;
      pend_q <= pending;
      tolog  <= log_en ? ((tolog & ~(go ? (32'd1 << lid) : 32'd0)) | (pending & ~pend_q)) : 32'd0;
      if (go) lid_q <= lid;
      if (e_done) begin
        log_wp <= log_wp + 16'd1;
        slot   <= (slot + 16'd1 >= log_words) ? 16'd0 : slot + 16'd1;
      end
    end
  end
  assign log_err = e_done && e_err;
  wire unused = &{1'b0, rs_valid, rs_data, e_cycles};
endmodule
