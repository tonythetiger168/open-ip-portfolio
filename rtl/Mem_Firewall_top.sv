// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Mem_Firewall: DRAM access firewall of the TV SoC (secure video path),
// placed between an initiator and the memory: AXI4 subordinate in (s_*),
// AXI4 manager out (m_*), APB4 registers
// ----------------------------------------------------------------------------
// - Four regions n = 0..3: RGNn_BASE, RGNn_LIMIT (byte addresses, the region
// is BASE..LIMIT inclusive) and RGNn_ATTR {secure_only, write, read, en}.
// - A burst covers addr .. addr + (AxLEN + 1) * 2^AxSIZE - 1 (INCR; FIXED
// covers one beat; WRAP its aligned container). It is allowed when one
// enabled region contains all of it, grants the access (read / write) and,
// for a secure_only region, AxPROT[1] = 0 (secure access).
// - An allowed burst passes through unchanged (one read and one write burst
// in flight at a time; W and R / B flow straight through). A denied burst
// never reaches m_*: a write takes all its W beats and answers DECERR on B,
// a read answers AxLEN + 1 beats of zero data with DECERR and RLAST.
// - The first denied burst is recorded: FAULT {id[3:0], ns, perm, write,
// valid} and FAULT_ADDR; FAULT pulses on every denied burst, DENIED_CNT
// counts them (saturating). CMD.fault_clr empties the record.
// - ENABLE 0: everything passes (no checks).
// ============================================================================
module Mem_Firewall_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        enable,
  input  logic [31:0] rgn0_base,
  input  logic [31:0] rgn0_limit,
  input  logic [3:0]  rgn0_attr,
  input  logic [31:0] rgn1_base,
  input  logic [31:0] rgn1_limit,
  input  logic [3:0]  rgn1_attr,
  input  logic [31:0] rgn2_base,
  input  logic [31:0] rgn2_limit,
  input  logic [3:0]  rgn2_attr,
  input  logic [31:0] rgn3_base,
  input  logic [31:0] rgn3_limit,
  input  logic [3:0]  rgn3_attr,
  input  logic        fault_clr,
  output logic [7:0]  fault_info,
  output logic [31:0] fault_addr,
  output logic [15:0] denied_cnt,
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
  // ---------------- region check ----------------
  function automatic logic [31:0] last_byte(input logic [31:0] a, input logic [7:0] l,
                                            input logic [2:0] sz, input logic [1:0] bu);
    logic [31:0] n;
    n = (32'(l) + 32'd1) << sz;
    case (bu)
      2'b00:   last_byte = a + (32'd1 << sz) - 32'd1;           // FIXED
      2'b10:   last_byte = (a & ~(n - 32'd1)) + n - 32'd1;      // WRAP container
      default: last_byte = a + n - 32'd1;                       // INCR
    endcase
  endfunction
  function automatic logic [31:0] first_byte(input logic [31:0] a, input logic [7:0] l,
                                             input logic [2:0] sz, input logic [1:0] bu);
    logic [31:0] n;
    n = (32'(l) + 32'd1) << sz;
    first_byte = (bu == 2'b10) ? (a & ~(n - 32'd1)) : a;
  endfunction
  logic [31:0] base [4], limit [4];
  logic [3:0]  attr [4];
  always_comb begin
    base[0] = rgn0_base; limit[0] = rgn0_limit; attr[0] = rgn0_attr;
    base[1] = rgn1_base; limit[1] = rgn1_limit; attr[1] = rgn1_attr;
    base[2] = rgn2_base; limit[2] = rgn2_limit; attr[2] = rgn2_attr;
    base[3] = rgn3_base; limit[3] = rgn3_limit; attr[3] = rgn3_attr;
  end
  function automatic logic allowed(input logic [31:0] a, input logic [7:0] l, input logic [2:0] sz,
                                   input logic [1:0] bu, input logic [2:0] prot, input logic wr);
    logic ok;
    logic [31:0] f, e;
    f = first_byte(a, l, sz, bu);
    e = last_byte(a, l, sz, bu);
    ok = 1'b0;
    for (int i = 0; i < 4; i++)
      if (attr[i][0] && f >= base[i] && e <= limit[i] && e >= f && (wr ? attr[i][2] : attr[i][1])
          && (!attr[i][3] || !prot[1])) ok = 1'b1;
    allowed = ok;
  endfunction

  // ---------------- write path ----------------
  typedef enum logic [1:0] {W_IDLE, W_FWD, W_DATA, W_DENY} wst_t;
  wst_t        ws;
  logic [3:0]  aw_id;
  logic [31:0] aw_addr;
  logic [7:0]  aw_len;
  logic [2:0]  aw_size, aw_prot;
  logic [1:0]  aw_burst;
  logic        aw_sent, deny_b;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ws <= W_IDLE; aw_id <= '0; aw_addr <= '0; aw_len <= '0; aw_size <= '0; aw_prot <= '0; aw_burst <= '0;
      aw_sent <= 1'b0; deny_b <= 1'b0;
    end else begin
      case (ws)
        W_IDLE: if (s_awvalid) begin
          aw_id <= s_awid; aw_addr <= s_awaddr; aw_len <= s_awlen; aw_size <= s_awsize;
          aw_burst <= s_awburst; aw_prot <= s_awprot; aw_sent <= 1'b0;
          if (!enable || allowed(s_awaddr, s_awlen, s_awsize, s_awburst, s_awprot, 1'b1)) ws <= W_FWD;
          else ws <= W_DENY;
        end
        W_FWD: begin                                     // AW out, W passes through
          if (m_awvalid && m_awready) aw_sent <= 1'b1;
          if (s_bvalid && s_bready) ws <= W_IDLE;
        end
        W_DENY: begin
          if (s_wvalid && s_wready && s_wlast) deny_b <= 1'b1;
          if (s_bvalid && s_bready) begin deny_b <= 1'b0; ws <= W_IDLE; end
        end
        default: ws <= W_IDLE;
      endcase
    end
  end
  assign s_awready = (ws == W_IDLE);
  assign m_awid = aw_id; assign m_awaddr = aw_addr; assign m_awlen = aw_len; assign m_awsize = aw_size;
  assign m_awburst = aw_burst; assign m_awprot = aw_prot;
  assign m_awvalid = (ws == W_FWD) && !aw_sent;
  assign m_wdata   = s_wdata;
  assign m_wstrb   = s_wstrb;
  assign m_wlast   = s_wlast;
  assign m_wvalid  = (ws == W_FWD) && s_wvalid;
  assign s_wready  = ((ws == W_FWD) && m_wready) || ((ws == W_DENY) && !deny_b);
  assign s_bid     = (ws == W_DENY) ? aw_id : m_bid;
  assign s_bresp   = (ws == W_DENY) ? 2'b11 : m_bresp;
  assign s_bvalid  = ((ws == W_FWD) && m_bvalid) || ((ws == W_DENY) && deny_b);
  assign m_bready  = (ws == W_FWD) && s_bready;

  // ---------------- read path ----------------
  typedef enum logic [1:0] {R_IDLE, R_FWD, R_DENY} rst_t;
  rst_t        rs;
  logic [3:0]  ar_id;
  logic [31:0] ar_addr;
  logic [7:0]  ar_len, r_cnt;
  logic [2:0]  ar_size, ar_prot;
  logic [1:0]  ar_burst;
  logic        ar_sent;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs <= R_IDLE; ar_id <= '0; ar_addr <= '0; ar_len <= '0; ar_size <= '0; ar_prot <= '0; ar_burst <= '0;
      ar_sent <= 1'b0; r_cnt <= '0;
    end else begin
      case (rs)
        R_IDLE: if (s_arvalid) begin
          ar_id <= s_arid; ar_addr <= s_araddr; ar_len <= s_arlen; ar_size <= s_arsize;
          ar_burst <= s_arburst; ar_prot <= s_arprot; ar_sent <= 1'b0; r_cnt <= '0;
          if (!enable || allowed(s_araddr, s_arlen, s_arsize, s_arburst, s_arprot, 1'b0)) rs <= R_FWD;
          else rs <= R_DENY;
        end
        R_FWD: begin
          if (m_arvalid && m_arready) ar_sent <= 1'b1;
          if (s_rvalid && s_rready && s_rlast) rs <= R_IDLE;
        end
        R_DENY: if (s_rvalid && s_rready) begin
          r_cnt <= r_cnt + 8'd1;
          if (r_cnt == ar_len) rs <= R_IDLE;
        end
        default: rs <= R_IDLE;
      endcase
    end
  end
  assign s_arready = (rs == R_IDLE);
  assign m_arid = ar_id; assign m_araddr = ar_addr; assign m_arlen = ar_len; assign m_arsize = ar_size;
  assign m_arburst = ar_burst; assign m_arprot = ar_prot;
  assign m_arvalid = (rs == R_FWD) && !ar_sent;
  assign s_rid     = (rs == R_DENY) ? ar_id : m_rid;
  assign s_rdata   = (rs == R_DENY) ? 32'h0 : m_rdata;
  assign s_rresp   = (rs == R_DENY) ? 2'b11 : m_rresp;
  assign s_rlast   = (rs == R_DENY) ? (r_cnt == ar_len) : m_rlast;
  assign s_rvalid  = ((rs == R_FWD) && m_rvalid) || (rs == R_DENY);
  assign m_rready  = (rs == R_FWD) && s_rready;

  // ---------------- fault record ----------------
  wire w_den = (ws == W_IDLE) && s_awvalid && enable && !allowed(s_awaddr, s_awlen, s_awsize, s_awburst, s_awprot, 1'b1);
  wire r_den = (rs == R_IDLE) && s_arvalid && enable && !allowed(s_araddr, s_arlen, s_arsize, s_arburst, s_arprot, 1'b0);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fault_info <= '0; fault_addr <= '0; denied_cnt <= '0;
    end else begin
      if (fault_clr) fault_info <= '0;
      if (w_den || r_den) begin
        if (denied_cnt != 16'hFFFF) denied_cnt <= denied_cnt + ((w_den && r_den) ? 16'd2 : 16'd1);
        if (!fault_info[0] || fault_clr) begin
          // a simultaneous read and write fault records the write
          fault_info <= w_den ? {s_awid, s_awprot[1], 1'b1, 1'b1, 1'b1} : {s_arid, s_arprot[1], 1'b1, 1'b0, 1'b1};
          fault_addr <= w_den ? s_awaddr : s_araddr;
        end
      end
    end
  end
  assign fault = w_den || r_den;
endmodule
