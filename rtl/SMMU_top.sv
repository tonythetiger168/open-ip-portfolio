// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SMMU: IOMMU / system MMU of the phone SoC, placed between a multimedia
// master and the interconnect (AXI4 subordinate in, AXI4 manager out, APB4
// registers)
// ----------------------------------------------------------------------------
// Translates the 32-bit virtual address of every burst from the upstream
// master (s_*) into a physical address on the downstream port (m_*), with
// 4 KB pages and a single-level page table in memory.
// - Page table: PT_BASE + 4 * VA[31:12] holds the entry of a page:
// bit 0 VALID, bit 1 WRITABLE, bits 31:12 the physical page number;
// PA = {PTE[31:12], VA[11:0]}. Bursts never cross 4 KB, so one
// translation covers a whole burst.
// - TLB: 4 fully associative entries, filled in round-robin order by the
// hardware table walker (a single-beat read on m_*, ID = PTW_ID). Writing
// CMD.tlb_inv empties it (do this after changing the table).
// - A burst whose page is not VALID, whose walk read got an error response,
// or that writes a page that is not WRITABLE, is not forwarded: it ends with
// SLVERR on the upstream port (all W beats are taken first), FAULT_ADDR
// records its virtual address, FAULT_INFO {walk_err, write, not_writable,
// not_valid} the cause, and the FAULT interrupt is set.
// - ENABLE 0: bypass, PA = VA, no walks and no faults.
// - One burst is handled at a time; reads and writes alternate when both
// wait. HITS and MISSES count TLB lookups (saturating).
// ============================================================================
module SMMU_top #(
  parameter logic [3:0] PTW_ID = 4'hF
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        enable,
  input  logic [31:0] pt_base,
  input  logic        tlb_inv,
  output logic [31:0] fault_addr,
  output logic [3:0]  fault_info,
  output logic [15:0] hits,
  output logic [15:0] misses,
  output logic        busy,
  output logic        fault,
  // AXI4 subordinate (s_*): 32-bit address and data, 4-bit ID
  input  logic [3:0]  s_awid,
  input  logic [31:0] s_awaddr,
  input  logic [7:0]  s_awlen,
  input  logic [2:0]  s_awsize,
  input  logic [1:0]  s_awburst,
  input  logic [2:0]  s_awprot,
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
  input  logic [2:0]  s_arprot,
  input  logic        s_arvalid,
  output logic        s_arready,
  output logic [3:0]  s_rid,
  output logic [31:0] s_rdata,
  output logic [1:0]  s_rresp,
  output logic        s_rlast,
  output logic        s_rvalid,
  input  logic        s_rready,
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
  typedef enum logic [3:0] {S_IDLE, S_LOOKUP, S_PTW_AR, S_PTW_R, S_ISSUE, S_RDATA, S_WDATA, S_WRESP,
                            S_FAULT, S_FAULT_R, S_FAULT_B} st_e;
  st_e st;

  // captured request
  logic        is_wr, last_wr, walked;
  logic [31:0] va, pa;
  logic [7:0]  len;
  logic [3:0]  id;
  logic [2:0]  size, prot;
  logic [1:0]  burst;
  logic [7:0]  beat;
  logic [3:0]  finfo;

  // TLB
  logic [19:0] t_vpn [4];
  logic [19:0] t_ppn [4];
  logic [3:0]  t_v, t_w;
  logic [1:0]  t_rr;
  logic        hit, hit_w;
  logic [19:0] hit_ppn;
  always_comb begin
    hit = 1'b0; hit_w = 1'b0; hit_ppn = '0;
    for (int i = 0; i < 4; i++)
      if (t_v[i] && t_vpn[i] == va[31:12]) begin hit = 1'b1; hit_w = t_w[i]; hit_ppn = t_ppn[i]; end
  end

  wire pick_rd = s_arvalid && (!s_awvalid || last_wr);
  wire pick_wr = s_awvalid && !pick_rd;
  assign s_arready = (st == S_IDLE) && pick_rd;
  assign s_awready = (st == S_IDLE) && pick_wr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; is_wr <= 1'b0; last_wr <= 1'b0; walked <= 1'b0;
      va <= '0; pa <= '0; len <= '0; id <= '0; size <= '0; prot <= '0; burst <= '0; beat <= '0;
      finfo <= '0; fault_addr <= '0; fault_info <= '0; hits <= '0; misses <= '0;
      t_v <= '0; t_w <= '0; t_rr <= '0;
      for (int i = 0; i < 4; i++) begin t_vpn[i] <= '0; t_ppn[i] <= '0; end
    end else begin
      if (tlb_inv) t_v <= '0;
      case (st)
        S_IDLE: begin
          walked <= 1'b0; beat <= '0;
          if (pick_rd) begin
            is_wr <= 1'b0; last_wr <= 1'b0;
            va <= s_araddr; len <= s_arlen; id <= s_arid; size <= s_arsize; prot <= s_arprot; burst <= s_arburst;
            st <= S_LOOKUP;
          end else if (pick_wr) begin
            is_wr <= 1'b1; last_wr <= 1'b1;
            va <= s_awaddr; len <= s_awlen; id <= s_awid; size <= s_awsize; prot <= s_awprot; burst <= s_awburst;
            st <= S_LOOKUP;
          end
        end
        S_LOOKUP:
          if (!enable) begin
            pa <= va; st <= S_ISSUE;
          end else if (hit && !tlb_inv) begin
            if (!walked && hits != 16'hFFFF) hits <= hits + 16'd1;
            if (is_wr && !hit_w) begin
              finfo <= 4'b0110; st <= S_FAULT;
            end else begin
              pa <= {hit_ppn, va[11:0]}; st <= S_ISSUE;
            end
          end else begin
            if (misses != 16'hFFFF) misses <= misses + 16'd1;
            st <= S_PTW_AR;
          end
        S_PTW_AR:
          if (m_arready) st <= S_PTW_R;
        S_PTW_R:
          if (m_rvalid) begin
            if (m_rresp != 2'b00) begin
              finfo <= {1'b1, is_wr, 2'b00}; st <= S_FAULT;
            end else if (!m_rdata[0]) begin
              finfo <= {1'b0, is_wr, 2'b01}; st <= S_FAULT;
            end else begin
              t_vpn[t_rr] <= va[31:12]; t_ppn[t_rr] <= m_rdata[31:12];
              t_w[t_rr] <= m_rdata[1]; t_v[t_rr] <= 1'b1; t_rr <= t_rr + 2'd1;
              walked <= 1'b1; st <= S_LOOKUP;
            end
          end
        S_ISSUE:
          if (is_wr && m_awready) st <= S_WDATA;
          else if (!is_wr && m_arready) st <= S_RDATA;
        S_RDATA:
          if (m_rvalid && s_rready && m_rlast) st <= S_IDLE;
        S_WDATA:
          if (s_wvalid && m_wready && s_wlast) st <= S_WRESP;
        S_WRESP:
          if (m_bvalid && s_bready) st <= S_IDLE;
        // fault: record it, then end the burst with SLVERR
        S_FAULT: begin
          fault_addr <= va; fault_info <= finfo;
          if (is_wr) st <= S_FAULT_B;
          else st <= S_FAULT_R;
        end
        S_FAULT_R:
          if (s_rready) begin
            beat <= beat + 8'd1;
            if (beat == len) st <= S_IDLE;
          end
        S_FAULT_B:   // take the W beats, then the error response
          if (beat == 8'hFF) begin
            if (s_bready) st <= S_IDLE;
          end else if (s_wvalid && s_wlast) beat <= 8'hFF;
        default: st <= S_IDLE;
      endcase
    end
  end
  assign fault = (st == S_FAULT);
  assign busy  = (st != S_IDLE);

  // downstream manager port
  wire walk = (st == S_PTW_AR) || (st == S_PTW_R);
  assign m_arvalid = (st == S_PTW_AR) || (st == S_ISSUE && !is_wr);
  assign m_araddr  = walk ? (pt_base + {10'd0, va[31:12], 2'b00}) : pa;
  assign m_arlen   = walk ? 8'd0 : len;
  assign m_arsize  = walk ? 3'd2 : size;
  assign m_arburst = walk ? 2'b01 : burst;
  assign m_arprot  = walk ? 3'b010 : prot;      // walks: non-secure data
  assign m_arid    = walk ? PTW_ID : id;
  assign m_rready  = (st == S_PTW_R) || (st == S_RDATA && s_rready);
  assign m_awvalid = (st == S_ISSUE && is_wr);
  assign m_awaddr  = pa;
  assign m_awlen   = len;
  assign m_awsize  = size;
  assign m_awburst = burst;
  assign m_awprot  = prot;
  assign m_awid    = id;
  assign m_wvalid  = (st == S_WDATA) && s_wvalid;
  assign m_wdata   = s_wdata;
  assign m_wstrb   = s_wstrb;
  assign m_wlast   = s_wlast;
  assign m_bready  = (st == S_WRESP) && s_bready;

  // upstream subordinate port
  wire fr = (st == S_FAULT_R);
  wire fb = (st == S_FAULT_B) && beat == 8'hFF;
  assign s_rvalid = (st == S_RDATA && m_rvalid) || fr;
  assign s_rdata  = fr ? 32'd0 : m_rdata;
  assign s_rresp  = fr ? 2'b10 : m_rresp;
  assign s_rlast  = fr ? (beat == len) : m_rlast;
  assign s_rid    = fr ? id : m_rid;
  assign s_wready = (st == S_WDATA && m_wready) || (st == S_FAULT_B && beat != 8'hFF);
  assign s_bvalid = (st == S_WRESP && m_bvalid) || fb;
  assign s_bresp  = fb ? 2'b10 : m_bresp;
  assign s_bid    = fb ? id : m_bid;
endmodule
