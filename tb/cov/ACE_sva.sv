// SPDX-License-Identifier: Apache-2.0
// ACE cached master/slave model: concurrent SVA against an independent
// reference cache (valid/dirty/tag/data per line) + functional coverage of
// the AXI4 channels and the AC/CR/CD snoop channels.
`include "cov_macros.svh"
module ACE_sva #(parameter int DW = 32, AW = 32) (
  input logic            clk, rst_n,
  input logic            awvalid, awready, wvalid, wready, wlast, bvalid, bready,
  input logic            arvalid, arready, rvalid, rready, rlast,
  input logic            acvalid, acready, crvalid, crready, cdvalid, cdready, cdlast,
  input logic [AW-1:0]   awaddr, araddr, acaddr,
  input logic [7:0]      awlen, arlen,
  input logic [2:0]      awsize, arsize, awsnoop,
  input logic [1:0]      awburst, arburst, bresp, rresp,
  input logic [3:0]      arsnoop, acsnoop,
  input logic [DW-1:0]   wdata, rdata, cddata,
  input logic [DW/8-1:0] wstrb,
  input logic [4:0]      crresp,
  input logic            irq
);
  `COV_CLOCKING(clk, !rst_n)
  wire aw_hs = awvalid && awready, w_hs = wvalid && wready, b_hs = bvalid && bready;
  wire ar_hs = arvalid && arready, r_hs = rvalid && rready;
  wire ac_hs = acvalid && acready, cr_hs = crvalid && crready, cd_hs = cdvalid && cdready;
  function automatic logic bad(input logic [1:0] bu, input logic [2:0] sz, input logic [AW-1:0] a);
    return (bu != 2'b01) || (sz > 3'd2) || (|a[AW-1:16]);
  endfunction

  // ---------------- reference cache model ----------------
  logic [63:0]   c_v, c_d;
  logic [AW-1:8] c_tag [0:63];
  logic [DW-1:0] c_dat [0:63];
  initial for (int i = 0; i < 64; i++) begin c_tag[i] = '0; c_dat[i] = '0; end
  logic [AW-1:0] m_wa, m_ra, m_aa;
  logic [7:0]    m_wlen, m_wbeat, m_rlen, m_rbeat;
  logic          m_werr, m_rerr, m_wbusy, m_rbusy, m_sbusy, m_cdpend;
  logic [4:0]    m_crresp;
  wire  [5:0]    awi = acaddr[7:2];
  wire           ac_hit = c_v[awi] && c_tag[awi] == acaddr[AW-1:8];
  wire  [5:0]    ri = m_ra[7:2];
  wire           r_hit = c_v[ri] && c_tag[ri] == m_ra[AW-1:8];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c_v <= '0; c_d <= '0; m_wbusy <= 0; m_rbusy <= 0; m_sbusy <= 0; m_cdpend <= 0;
      m_wa <= '0; m_ra <= '0; m_aa <= '0; m_wlen <= 0; m_wbeat <= 0; m_rlen <= 0; m_rbeat <= 0;
      m_werr <= 0; m_rerr <= 0; m_crresp <= '0;
    end else begin
      if (aw_hs) begin
        m_wbusy <= 1; m_wa <= awaddr; m_wlen <= awlen; m_wbeat <= 0;
        m_werr <= bad(awburst, awsize, awaddr);
      end else if (w_hs) begin
        if (!m_werr) begin
          c_v[m_wa[7:2]] <= 1; c_d[m_wa[7:2]] <= 1; c_tag[m_wa[7:2]] <= m_wa[AW-1:8];
          for (int b = 0; b < DW/8; b++)
            if (wstrb[b]) c_dat[m_wa[7:2]][8*b +: 8] <= wdata[8*b +: 8];
        end
        m_wa <= m_wa + 4; m_wbeat <= m_wbeat + 1;
      end
      if (b_hs) m_wbusy <= 0;
      if (ar_hs) begin
        m_rbusy <= 1; m_ra <= araddr; m_rlen <= arlen; m_rbeat <= 0;
        m_rerr <= bad(arburst, arsize, araddr);
      end else if (r_hs) begin
        m_ra <= m_ra + 4; m_rbeat <= m_rbeat + 1;
        if (m_rbeat == m_rlen) m_rbusy <= 0;
      end
      if (ac_hs) begin
        m_sbusy <= 1; m_aa <= acaddr; m_crresp <= '0; m_cdpend <= 0;
        case (acsnoop)
          4'b0000, 4'b0001: if (ac_hit) begin           // ReadShared / ReadClean
            m_crresp <= {c_d[awi], 1'b1, c_d[awi], 1'b0, 1'b1}; m_cdpend <= 1; c_d[awi] <= 0;
          end
          4'b0111: begin c_v[awi] <= 0; c_d[awi] <= 0; end // MakeUnique
          4'b1000: if (ac_hit) begin                     // CleanInvalid
            if (c_d[awi]) begin m_crresp <= 5'b10101; m_cdpend <= 1; end
            c_v[awi] <= 0; c_d[awi] <= 0;
          end
          default: ;
        endcase
      end
      if (cr_hs && !m_cdpend) m_sbusy <= 0;
      if (cd_hs) begin m_sbusy <= 0; m_cdpend <= 0; end
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_quiet, !rst_n, !bvalid && !rvalid && !crvalid && !cdvalid && !irq)
  `SVA_NXT(a_b_stable,  bvalid && !bready,  bvalid && $stable(bresp))
  `SVA_NXT(a_r_stable,  rvalid && !rready,  rvalid && $stable(rdata) && $stable(rresp) && $stable(rlast))
  `SVA_NXT(a_cr_stable, crvalid && !crready, crvalid && $stable(crresp))
  `SVA_NXT(a_cd_stable, cdvalid && !cdready, cdvalid && $stable(cddata))
  `SVA_IMP(a_ac_blocked_by_write, acready, !m_wbusy && !m_sbusy)
  `SVA_IMP(a_aw_blocked_by_snoop, awready, !m_sbusy && !m_wbusy)
  `SVA_IMP(a_bresp_model, bvalid, bresp == (m_werr ? 2'b10 : 2'b00))
  `SVA_IMP(a_rresp_model, rvalid, rresp == (m_rerr ? 2'b10 : 2'b00) && rlast == (m_rbeat == m_rlen))
  `SVA_IMP(a_rdata_model, rvalid, rdata == (r_hit ? c_dat[ri] : '0))
  `SVA_IMP(a_crresp_model, crvalid, crresp == m_crresp)
  `SVA_IMP(a_cd_only_on_transfer, cdvalid, m_cdpend && cdlast)
  `SVA_IMP(a_cddata_model, cdvalid, cddata == c_dat[m_aa[7:2]])
  `SVA_NXT(a_irq_on_werr, w_hs && m_werr && (wlast || m_wbeat == m_wlen), irq)
  `SVA_NXT(a_irq_on_rerr, r_hs && m_rerr && m_rbeat == m_rlen, irq)
  `SVA_NXT(a_irq_pulse, irq, !irq || $past(irq) == 1'b0)

  // ---------------- functional coverage ----------------
  covergroup cg_snoop @(posedge clk);
    option.per_instance = 1;
    cp_type: coverpoint acsnoop iff (rst_n && ac_hs)
      { bins read_shared = {4'b0000}; bins read_clean = {4'b0001};
        bins make_unique = {4'b0111}; bins clean_inv = {4'b1000}; bins other = default; }
    cp_state: coverpoint {ac_hit, c_d[awi]} iff (rst_n && ac_hs)
      { bins miss = {2'b00, 2'b01}; bins clean_hit = {2'b10}; bins dirty_hit = {2'b11}; }
    x_type_state: cross cp_type, cp_state;
  endgroup
  covergroup cg_axi @(posedge clk);
    option.per_instance = 1;
    cp_aw_kind: coverpoint {awburst != 2'b01, awsize > 3'd2, |awaddr[AW-1:16]} iff (rst_n && aw_hs)
      { bins ok = {3'b000}; bins bad_burst = {3'b100}; bins bad_size = {3'b010}; bins oor = {3'b001}; }
    cp_ar_kind: coverpoint {arburst != 2'b01, arsize > 3'd2, |araddr[AW-1:16]} iff (rst_n && ar_hs)
      { bins ok = {3'b000}; bins bad_burst = {3'b100}; bins bad_size = {3'b010}; bins oor = {3'b001}; }
    cp_awlen: coverpoint awlen iff (rst_n && aw_hs) { bins single = {0}; bins burst = {[1:255]}; }
    cp_rhit: coverpoint r_hit iff (rst_n && r_hs && !m_rerr) { bins miss = {0}; bins hit = {1}; }
    cp_strb: coverpoint wstrb iff (rst_n && w_hs)
      { bins full = {{(DW/8){1'b1}}}; bins partial = default; }
  endgroup
  cg_snoop u_cg_snoop = new;
  cg_axi   u_cg_axi   = new;

  `FC(cr_backpressure, crvalid && !crready)
  `FC(cd_backpressure, cdvalid && !cdready)
  `FC(b_backpressure, bvalid && !bready)
  `FC(r_backpressure, rvalid && !rready)
  `FC(snoop_blocked_by_write, acvalid && !acready && m_wbusy)
  `FC(write_blocked_by_snoop, awvalid && !awready && m_sbusy)
  `FC(read_during_snoop, r_hs && m_sbusy)
  `FC(early_wlast, w_hs && wlast && m_wbeat != m_wlen)
endmodule

bind ACE_top ACE_sva #(.DW(DW), .AW(AW)) u_sva (.*);
