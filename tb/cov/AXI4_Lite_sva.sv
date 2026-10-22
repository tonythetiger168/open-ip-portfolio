// SPDX-License-Identifier: Apache-2.0
// AXI4-Lite slave: concurrent SVA (handshake rules, SLVERR decode, shadow
// memory with byte strobes) + functional coverage, bound into AXI4_Lite_top.
`include "cov_macros.svh"
module AXI4_Lite_sva #(parameter int DW = 32, AW = 32) (
  input logic            clk, rst_n,
  input logic [AW-1:0]   awaddr, araddr,
  input logic            awvalid, awready, wvalid, wready, bvalid, bready,
  input logic            arvalid, arready, rvalid, rready,
  input logic [DW-1:0]   wdata, rdata,
  input logic [DW/8-1:0] wstrb,
  input logic [1:0]      bresp, rresp,
  input logic            irq
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;
  wire aw_hs = awvalid && awready, w_hs = wvalid && wready, b_hs = bvalid && bready;
  wire ar_hs = arvalid && arready, r_hs = rvalid && rready;
  function automatic logic in_rng(input logic [AW-1:0] a);
    return (a[AW-1:10] == '0) && (a[1:0] == 2'b00);
  endfunction

  // reference model
  // shadow of the (un-reset) register file: survives rst_n like the RTL memory
  logic [DW-1:0] shadow [0:255];
  initial for (int i = 0; i < 256; i++) shadow[i] = '0;
  logic [AW-1:0] m_wa, m_ra;
  logic          m_wpend, m_bpend, m_rpend;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_wa <= '0; m_ra <= '0; m_wpend <= 0; m_bpend <= 0; m_rpend <= 0;
    end else begin
      if (aw_hs) begin m_wa <= awaddr; m_wpend <= 1; end
      if (w_hs) begin
        m_wpend <= 0; m_bpend <= 1;
        if (in_rng(m_wa))
          for (int b = 0; b < DW/8; b++)
            if (wstrb[b]) shadow[m_wa[9:2]][8*b +: 8] <= wdata[8*b +: 8];
      end
      if (b_hs) m_bpend <= 0;
      if (ar_hs) begin m_ra <= araddr; m_rpend <= 1; end
      if (r_hs) m_rpend <= 0;
    end
  end

  `SVA_RST(a_reset_quiet, !rst_n, !bvalid && !rvalid && !wready && !irq)
  `SVA_NXT(a_b_stable, bvalid && !bready, bvalid && $stable(bresp))
  `SVA_NXT(a_r_stable, rvalid && !rready, rvalid && $stable(rdata) && $stable(rresp))
  `SVA_IMP(a_aw_only_idle, awready, !m_wpend && !m_bpend)
  `SVA_IMP(a_w_after_aw, wready, m_wpend)
  `SVA_IMP(a_b_after_w, bvalid, m_bpend)
  `SVA_IMP(a_ar_only_idle, arready, !m_rpend)
  `SVA_IMP(a_bresp_model, bvalid, bresp == (in_rng(m_wa) ? OKAY : SLVERR))
  `SVA_IMP(a_rresp_model, rvalid, rresp == (in_rng(m_ra) ? OKAY : SLVERR))
  `SVA_IMP(a_rdata_model, rvalid, rdata == (in_rng(m_ra) ? shadow[m_ra[9:2]] : '0))
  `SVA_NXT(a_irq_sticky, irq, irq)
  `SVA_NXT(a_irq_on_err, (aw_hs && !in_rng(awaddr)) || (ar_hs && !in_rng(araddr)), irq)
  `SVA_IMP(a_irq_cause, $rose(irq), $past((aw_hs && !in_rng(awaddr)) || (ar_hs && !in_rng(araddr))))

  covergroup cg_xfer @(posedge clk);
    option.per_instance = 1;
    cp_waddr: coverpoint {awaddr[AW-1:10] != 0, awaddr[1:0] != 0} iff (rst_n && aw_hs)
      { bins ok = {2'b00}; bins misaligned = {2'b01}; bins oor = {2'b10}; }
    cp_raddr: coverpoint {araddr[AW-1:10] != 0, araddr[1:0] != 0} iff (rst_n && ar_hs)
      { bins ok = {2'b00}; bins misaligned = {2'b01}; bins oor = {2'b10}; }
    cp_strb: coverpoint wstrb iff (rst_n && w_hs)
      { bins none = {0}; bins full = {{(DW/8){1'b1}}}; bins partial = default; }
    cp_bresp: coverpoint bresp iff (rst_n && b_hs) { bins okay = {OKAY}; bins slverr = {SLVERR}; }
    cp_rresp: coverpoint rresp iff (rst_n && r_hs) { bins okay = {OKAY}; bins slverr = {SLVERR}; }
  endgroup
  cg_xfer u_cg_xfer = new;

  `FC(b_backpressure, bvalid && !bready)
  `FC(r_backpressure, rvalid && !rready)
  `FC(w_late, m_wpend && !wvalid)
  `FC(rw_concurrent, (m_wpend || m_bpend) && m_rpend)
  `FC(aw_ar_same_cycle, aw_hs && ar_hs)
endmodule

bind AXI4_Lite_top AXI4_Lite_sva #(.DW(DW), .AW(AW)) u_sva (.*);
