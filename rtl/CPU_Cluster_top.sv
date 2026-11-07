// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CPU_Cluster: CPU cluster memory-traffic model of the phone SoC (AXI4
// manager, APB4 registers)
// ----------------------------------------------------------------------------
// Stands in for the application cluster's L3 port: each job moves LEN
// 32-bit words in cache-line sized bursts (16 beats = 64 bytes) and checks
// what it reads, so a SoC test can load the memory system the way cache
// fills and write-backs do and prove the data came back intact.
// - MODE 0 WRITE: write pattern(i) to word i of DST (cache-line write-backs).
// - MODE 1 CHECK: read word i of SRC and compare with pattern(i); MISMATCHES
// counts the differences and FIRST_FAIL holds the index of the first one.
// - MODE 2 COPY: read SRC and write it to DST (memcpy); MODE 3 is COPY too.
// - pattern(i) = SEED ^ {~i[15:0], i[15:0]}: every word of a job differs.
// - DONE interrupt when a job ends, ERR as well on an AXI error response,
// MISMATCH as well when a CHECK job found a difference.
// - CYCLES is the length of the last job in clocks; AXI ID = AXI_ID.
// ============================================================================
module CPU_Cluster_top #(
  parameter logic [3:0] AXI_ID = 4'd0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] src_addr,
  input  logic [31:0] dst_addr,
  input  logic [15:0] xfer_len,
  input  logic [1:0]  mode,
  input  logic [31:0] seed,
  input  logic        start,
  output logic        busy,
  output logic        err,
  output logic [15:0] mismatches,
  output logic [15:0] first_fail,
  output logic [31:0] cycles,
  output logic        done,
  output logic        err_irq,
  output logic        mis_irq,
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
  logic        rs_valid, rs_ready, ws_valid, ws_ready, e_done;
  logic [31:0] rs_data, ws_data;
  logic [1:0]  mode_q;
  logic [15:0] ridx, widx;

  function automatic logic [31:0] pattern(input logic [31:0] s, input logic [15:0] i);
    pattern = s ^ {~i, i};
  endfunction

  wire go = start && !busy;
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(go), .rd_en(mode != 2'd0), .wr_en(mode != 2'd1),
    .src(src_addr), .dst(dst_addr), .len(xfer_len),
    .busy, .done(e_done), .err, .cycles,
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

  // WRITE: generated pattern; COPY: read data; CHECK: reads are consumed here
  // (MODE 3 is COPY as well)
  assign ws_valid = (mode_q == 2'd0) ? busy : (mode_q == 2'd1) ? 1'b0 : rs_valid;
  assign ws_data  = (mode_q == 2'd0) ? pattern(seed, widx) : rs_data;
  assign rs_ready = (mode_q == 2'd1) ? 1'b1 : ws_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mode_q <= '0; ridx <= '0; widx <= '0; mismatches <= '0; first_fail <= '0;
    end else if (go) begin
      mode_q <= mode; ridx <= '0; widx <= '0; mismatches <= '0; first_fail <= '0;
    end else begin
      if (ws_valid && ws_ready) widx <= widx + 16'd1;
      if (rs_valid && rs_ready) begin
        ridx <= ridx + 16'd1;
        if (mode_q == 2'd1 && rs_data != pattern(seed, ridx)) begin
          if (mismatches == 0) first_fail <= ridx;
          if (mismatches != 16'hFFFF) mismatches <= mismatches + 16'd1;
        end
      end
    end
  end
  assign done    = e_done;
  assign err_irq = e_done && err;
  assign mis_irq = e_done && mode_q == 2'd1 && mismatches != 0;
endmodule
