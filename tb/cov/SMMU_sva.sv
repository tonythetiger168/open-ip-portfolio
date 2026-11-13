// SPDX-License-Identifier: Apache-2.0
// SMMU (IOMMU, AXI4 subordinate in, AXI4 manager out): concurrent SVA against
// an independent transaction-level model, fed by the upstream and downstream
// handshakes and the configuration pins, + functional coverage.
// The model keeps its own 4-entry round-robin TLB (filled from the walk read
// data it sees on m_*, emptied by tlb_inv), decides hit / miss / bypass /
// fault for each accepted burst, and from that predicts every downstream
// request (walk reads at PT_BASE + 4 * VPN with PTW_ID, translated or bypassed
// bursts with every attribute forwarded), the pass-through of the data and
// response channels, the fault path (SLVERR, zero data, every W beat taken,
// FAULT_ADDR / FAULT_INFO, the FAULT pulse), BUSY, the read / write
// arbitration and the saturating HITS / MISSES counters.
`include "cov_macros.svh"
module SMMU_sva #(parameter logic [3:0] PTW_ID = 4'hF) (
  input logic        clk, rst_n, enable, tlb_inv, busy, fault,
  input logic [31:0] pt_base, fault_addr,
  input logic [3:0]  fault_info,
  input logic [15:0] hits, misses,
  input logic [3:0]  s_awid, s_arid, s_bid, s_rid, s_wstrb,
  input logic [31:0] s_awaddr, s_araddr, s_wdata, s_rdata,
  input logic [7:0]  s_awlen, s_arlen,
  input logic [2:0]  s_awsize, s_arsize, s_awprot, s_arprot,
  input logic [1:0]  s_awburst, s_arburst, s_bresp, s_rresp,
  input logic        s_awvalid, s_awready, s_wlast, s_wvalid, s_wready, s_bvalid, s_bready,
  input logic        s_arvalid, s_arready, s_rlast, s_rvalid, s_rready,
  input logic [3:0]  m_awid, m_arid, m_bid, m_rid, m_wstrb,
  input logic [31:0] m_awaddr, m_araddr, m_wdata, m_rdata,
  input logic [7:0]  m_awlen, m_arlen,
  input logic [2:0]  m_awsize, m_arsize, m_awprot, m_arprot,
  input logic [1:0]  m_awburst, m_arburst, m_bresp, m_rresp,
  input logic        m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready,
  input logic        m_arvalid, m_arready, m_rlast, m_rvalid, m_rready
);
  `COV_CLOCKING(clk, !rst_n)
  typedef enum logic [3:0] {P_IDLE, P_LK, P_WALK_AR, P_WALK_R, P_FWD, P_FWD_R, P_FWD_W, P_FWD_B,
                            P_FAULT, P_FAULT_R, P_FAULT_W, P_FAULT_B} ph_e;
  ph_e         ph;
  logic        r_wr, r_walked, m_last_wr;
  logic [31:0] r_va, r_pa;
  logic [7:0]  r_len, r_beat;
  logic [3:0]  r_id, r_info;
  logic [2:0]  r_size, r_prot;
  logic [1:0]  r_burst;
  logic [19:0] mt_vpn [4], mt_ppn [4];
  logic [3:0]  mt_v, mt_w;
  logic [1:0]  mt_rr;
  logic [15:0] m_hits, m_misses;

  logic        mt_hit, mt_hw;
  logic [19:0] mt_hppn;
  always_comb begin
    mt_hit = 0; mt_hw = 0; mt_hppn = 0;
    for (int i = 0; i < 4; i++)
      if (mt_v[i] && mt_vpn[i] == r_va[31:12]) begin mt_hit = 1; mt_hw = mt_w[i]; mt_hppn = mt_ppn[i]; end
  end
  wire ar_hs = s_arvalid && s_arready;
  wire aw_hs = s_awvalid && s_awready;
  // lookup outcome (in P_LK)
  wire lk_byp   = !enable;
  wire lk_hit   = enable && mt_hit && !tlb_inv;
  wire lk_wfault = lk_hit && r_wr && !mt_hw;
  wire walk_rx  = ph == P_WALK_R && m_rvalid;
  wire walk_ok  = walk_rx && m_rresp == 2'b00 && m_rdata[0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= P_IDLE; r_wr <= 0; r_walked <= 0; m_last_wr <= 0; r_va <= 0; r_pa <= 0; r_len <= 0; r_beat <= 0;
      r_id <= 0; r_info <= 0; r_size <= 0; r_prot <= 0; r_burst <= 0;
      mt_v <= 0; mt_w <= 0; mt_rr <= 0; m_hits <= 0; m_misses <= 0;
      for (int i = 0; i < 4; i++) begin mt_vpn[i] <= 0; mt_ppn[i] <= 0; end
    end else begin
      if (tlb_inv) mt_v <= 0;
      case (ph)
        P_IDLE: begin
          r_walked <= 0; r_beat <= 0;
          if (ar_hs) begin
            r_wr <= 0; m_last_wr <= 0; ph <= P_LK;
            r_va <= s_araddr; r_len <= s_arlen; r_id <= s_arid; r_size <= s_arsize; r_prot <= s_arprot; r_burst <= s_arburst;
          end else if (aw_hs) begin
            r_wr <= 1; m_last_wr <= 1; ph <= P_LK;
            r_va <= s_awaddr; r_len <= s_awlen; r_id <= s_awid; r_size <= s_awsize; r_prot <= s_awprot; r_burst <= s_awburst;
          end
        end
        P_LK:
          if (lk_byp) begin r_pa <= r_va; ph <= P_FWD; end
          else if (lk_hit) begin
            if (!r_walked && m_hits != 16'hFFFF) m_hits <= m_hits + 1;
            if (lk_wfault) begin r_info <= 4'b0110; ph <= P_FAULT; end
            else begin r_pa <= {mt_hppn, r_va[11:0]}; ph <= P_FWD; end
          end else begin
            if (m_misses != 16'hFFFF) m_misses <= m_misses + 1;
            ph <= P_WALK_AR;
          end
        P_WALK_AR: if (m_arready) ph <= P_WALK_R;
        P_WALK_R:
          if (m_rvalid) begin
            if (m_rresp != 2'b00) begin r_info <= {1'b1, r_wr, 2'b00}; ph <= P_FAULT; end
            else if (!m_rdata[0]) begin r_info <= {1'b0, r_wr, 2'b01}; ph <= P_FAULT; end
            else begin
              mt_vpn[mt_rr] <= r_va[31:12]; mt_ppn[mt_rr] <= m_rdata[31:12]; mt_w[mt_rr] <= m_rdata[1];
              mt_v[mt_rr] <= 1; mt_rr <= mt_rr + 1; r_walked <= 1; ph <= P_LK;
            end
          end
        P_FWD:
          if (r_wr && m_awready) ph <= P_FWD_W;
          else if (!r_wr && m_arready) ph <= P_FWD_R;
        P_FWD_R: if (m_rvalid && s_rready && m_rlast) ph <= P_IDLE;
        P_FWD_W: if (s_wvalid && m_wready && s_wlast) ph <= P_FWD_B;
        P_FWD_B: if (m_bvalid && s_bready) ph <= P_IDLE;
        P_FAULT: ph <= r_wr ? P_FAULT_W : P_FAULT_R;
        P_FAULT_R:
          if (s_rready) begin r_beat <= r_beat + 1; if (r_beat == r_len) ph <= P_IDLE; end
        P_FAULT_W: if (s_wvalid && s_wlast) ph <= P_FAULT_B;
        P_FAULT_B: if (s_bready) ph <= P_IDLE;
        default: ph <= P_IDLE;
      endcase
    end
  end

  wire [31:0] walk_addr = pt_base + {10'd0, r_va[31:12], 2'b00};
  wire        fwd_r = ph == P_FWD_R, fwd_w = ph == P_FWD_W, fwd_b = ph == P_FWD_B;

  `SVA_RST(a_reset_idle, !rst_n, !busy && !fault && hits == 0 && misses == 0 && !m_arvalid && !m_awvalid
                                 && !m_wvalid && !s_rvalid && !s_bvalid && !s_arready && !s_awready)
  `SVA_INV(a_busy, busy == (ph != P_IDLE) && fault == (ph == P_FAULT))
  `SVA_INV(a_accept, s_arready == (ph == P_IDLE && s_arvalid && (!s_awvalid || m_last_wr))
                  && s_awready == (ph == P_IDLE && s_awvalid && !(s_arvalid && (!s_awvalid || m_last_wr))))
  `SVA_INV(a_counters, hits == m_hits && misses == m_misses)
  // downstream requests
  `SVA_INV(a_ar_valid, m_arvalid == (ph == P_WALK_AR || (ph == P_FWD && !r_wr)))
  `SVA_INV(a_aw_valid, m_awvalid == (ph == P_FWD && r_wr))
  `SVA_IMP(a_walk_req, ph == P_WALK_AR, m_araddr == walk_addr && m_arlen == 0 && m_arid == PTW_ID
                                        && m_arsize == 3'd2 && m_arburst == 2'b01 && m_arprot == 3'b010)
  `SVA_IMP(a_fwd_ar, ph == P_FWD && !r_wr, m_araddr == r_pa && m_arlen == r_len && m_arid == r_id
                                           && m_arsize == r_size && m_arburst == r_burst && m_arprot == r_prot)
  `SVA_IMP(a_fwd_aw, ph == P_FWD && r_wr, m_awaddr == r_pa && m_awlen == r_len && m_awid == r_id
                                          && m_awsize == r_size && m_awburst == r_burst && m_awprot == r_prot)
  `SVA_IMP(a_bypass_pa, ph == P_LK && lk_byp, ##1 r_pa == r_va)
  // walk read data: always taken
  `SVA_INV(a_walk_rready, (ph == P_WALK_R) -> m_rready)
  // data and response channels
  `SVA_INV(a_r_pass, fwd_r == (fwd_r && s_rvalid == m_rvalid && m_rready == s_rready && s_rdata == m_rdata
                                && s_rresp == m_rresp && s_rlast == m_rlast && s_rid == m_rid))
  `SVA_INV(a_r_idle, (ph != P_FWD_R && ph != P_WALK_R) -> !m_rready)
  `SVA_INV(a_w_pass, fwd_w == (fwd_w && m_wvalid == s_wvalid && s_wready == m_wready && m_wdata == s_wdata
                                && m_wstrb == s_wstrb && m_wlast == s_wlast))
  `SVA_INV(a_w_idle, !fwd_w -> (!m_wvalid && s_wready == (ph == P_FAULT_W)))
  `SVA_INV(a_b_pass, fwd_b == (fwd_b && s_bvalid == m_bvalid && m_bready == s_bready && s_bresp == m_bresp
                                && s_bid == m_bid))
  `SVA_INV(a_b_idle, !fwd_b -> (!m_bready && s_bvalid == (ph == P_FAULT_B)))
  `SVA_INV(a_r_upstream, (ph != P_FWD_R) -> (s_rvalid == (ph == P_FAULT_R)))
  // fault path
  `SVA_NXT(a_fault_regs, ph == P_FAULT, fault_addr == r_va && fault_info == r_info)
  `SVA_IMP(a_fault_r, ph == P_FAULT_R, s_rdata == 0 && s_rresp == 2'b10 && s_rid == r_id && s_rlast == (r_beat == r_len))
  `SVA_IMP(a_fault_b, ph == P_FAULT_B, s_bresp == 2'b10 && s_bid == r_id)
  `SVA_IMP(a_fault_regs_hold, ph != P_FAULT && $past(ph) != P_FAULT && !$past(!rst_n),
           $stable(fault_addr) && $stable(fault_info))

  // ---------------------------------------------------------------- coverage
  function automatic logic [2:0] lc(input logic [7:0] l);
    lc = (l == 0) ? 3'd0 : (l < 15) ? 3'd1 : (l == 15) ? 3'd2 : (l < 255) ? 3'd3 : 3'd4;
  endfunction
  covergroup cg_smmu @(posedge clk);
    option.per_instance = 1;
    cp_lookup: coverpoint {r_wr, lk_byp, lk_hit, r_walked} iff (rst_n && ph == P_LK)
      { bins rd_bypass = {4'b0100}; bins wr_bypass = {4'b1100};
        bins rd_miss = {4'b0000}; bins wr_miss = {4'b1000};
        bins rd_hit = {4'b0010}; bins wr_hit = {4'b1010};
        bins rd_hit_after_walk = {4'b0011}; bins wr_hit_after_walk = {4'b1011}; }
    cp_fault: coverpoint r_info iff (rst_n && ph == P_FAULT)
      { bins rd_invalid = {4'b0001}; bins wr_invalid = {4'b0101}; bins wr_readonly = {4'b0110};
        bins rd_walk_err = {4'b1000}; bins wr_walk_err = {4'b1100}; }
    cp_walk_resp: coverpoint m_rresp iff (rst_n && walk_rx);
    cp_fill: coverpoint mt_rr iff (rst_n && walk_ok);
    cp_len: coverpoint lc(r_len) iff (rst_n && ph == P_LK)
      { bins one = {0}; bins short_ = {1}; bins sixteen = {2}; bins long_ = {3}; bins max = {4}; }
    cp_rresp: coverpoint m_rresp iff (rst_n && fwd_r && m_rvalid && s_rready);
    cp_bresp: coverpoint m_bresp iff (rst_n && fwd_b && m_bvalid && s_bready);
    cp_size: coverpoint r_size iff (rst_n && ph == P_FWD) { bins byte_ = {0}; bins half = {1}; bins word = {2}; }
    cp_burst: coverpoint r_burst iff (rst_n && ph == P_FWD) { bins fixed = {0}; bins incr = {1}; bins wrap = {2}; }
    cp_unaligned: coverpoint r_va[1:0] iff (rst_n && ph == P_FWD);
  endgroup
  cg_smmu u_cg_smmu = new;

  `FC(read_and_write_waiting_rd_first, ph == P_IDLE && s_arvalid && s_awvalid && !m_last_wr)
  `FC(read_and_write_waiting_wr_first, ph == P_IDLE && s_arvalid && s_awvalid && m_last_wr)
  `FC(inv_at_lookup_hit, ph == P_LK && enable && mt_hit && tlb_inv)
  `FC(inv_during_walk, ph == P_WALK_R && m_rvalid && tlb_inv)
  `FC(fill_evicts_valid_entry, walk_ok && mt_v[mt_rr])
  `FC(hits_saturated, ph == P_LK && lk_hit && !r_walked && m_hits == 16'hFFFF)
  `FC(misses_saturated, ph == P_LK && !lk_byp && !lk_hit && m_misses == 16'hFFFF)
  `FC(walk_ar_stall, ph == P_WALK_AR && !m_arready)
  `FC(fwd_ar_stall, ph == P_FWD && !r_wr && !m_arready)
  `FC(fwd_aw_stall, ph == P_FWD && r_wr && !m_awready)
  `FC(fwd_r_upstream_stall, fwd_r && m_rvalid && !s_rready)
  `FC(fwd_w_downstream_stall, fwd_w && s_wvalid && !m_wready)
  `FC(fwd_b_upstream_stall, fwd_b && m_bvalid && !s_bready)
  `FC(fault_r_stall, ph == P_FAULT_R && !s_rready)
  `FC(fault_w_gap, ph == P_FAULT_W && !s_wvalid)
  `FC(fault_b_stall, ph == P_FAULT_B && !s_bready)
  `FC(enable_dropped_while_busy, ph != P_IDLE && $fell(enable))
  `FC_RST(reset_mid_read, rst_n && fwd_r ##1 !rst_n)
  `FC_RST(reset_mid_write, rst_n && fwd_w ##1 !rst_n)
  `FC_RST(reset_mid_walk, rst_n && ph == P_WALK_R ##1 !rst_n)
endmodule

bind SMMU_top SMMU_sva #(.PTW_ID(PTW_ID)) u_sva (.*);
