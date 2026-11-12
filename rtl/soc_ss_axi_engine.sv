// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// soc_ss_axi_engine: shared AXI4 manager data mover of the phone SoC
// subsystem IPs (DMA, CPU_Cluster, GPU, NPU, ISP, Video_Codec,
// Display_Controller, Audio_DSP, Modem, Sensor_Hub).
// ----------------------------------------------------------------------------
//  - One job: read LEN 32-bit words from SRC (when RD_EN) into the read
//    stream, and write LEN words taken from the write stream to DST (when
//    WR_EN). The IP between the two streams is the subsystem's datapath.
//  - AXI4 manager, 32-bit address and data, INCR bursts of up to 16 beats,
//    AxSIZE = 4 bytes, WSTRB = 4'hF. A burst never crosses a 4 KB boundary.
//    SRC and DST must be word aligned (bits 1:0 are ignored).
//  - A read burst is issued only when the read FIFO has room for all of it,
//    so RREADY is always 1. A write burst is issued only when the write FIFO
//    already holds all of its data, so WVALID never stalls once AW is sent.
//    Neither side ever holds a subordinate waiting on the other side.
//  - One read and one write burst outstanding at a time, ID = ID (param).
//  - Any RRESP / BRESP other than OKAY sets ERR (the job still completes).
//  - DONE pulses one clock when both sides have finished and the read FIFO
//    is empty. START is ignored while BUSY. CYCLES counts the clocks of the
//    current job (from START to DONE) and holds the count of the last one.
// ============================================================================
module soc_ss_axi_engine #(
  parameter logic [3:0] ID    = 4'd0,
  parameter logic [2:0] PROT  = 3'b000,
  parameter int         DEPTH = 32          // per-direction FIFO, >= 16
) (
  input  logic        clk,
  input  logic        rst_n,
  // job control
  input  logic        start,
  input  logic        rd_en,
  input  logic        wr_en,
  input  logic [31:0] src,
  input  logic [31:0] dst,
  input  logic [15:0] len,                  // 32-bit words
  output logic        busy,
  output logic        done,
  output logic        err,
  output logic [31:0] cycles,               // clocks of the current / last job
  // read stream (to the datapath)
  output logic        rs_valid,
  output logic [31:0] rs_data,
  input  logic        rs_ready,
  // write stream (from the datapath)
  input  logic        ws_valid,
  input  logic [31:0] ws_data,
  output logic        ws_ready,
  // AXI4 manager
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
  localparam int AW = $clog2(DEPTH);

  // burst length (beats) from an address and the words left
  function automatic logic [4:0] chunk(input logic [31:0] a, input logic [15:0] left);
    logic [10:0] to4k;
    logic [15:0] c;
    to4k = 11'd1024 - {1'b0, a[11:2]};
    c = (left < 16'd16) ? left : 16'd16;
    if ({5'd0, to4k} < c) c = {5'd0, to4k};
    chunk = c[4:0];
  endfunction

  // ---------------- job state ----------------
  logic        rd_q, wr_q;
  logic [31:0] raddr, waddr;
  logic [15:0] rleft, wleft, wtake;   // wtake: words still taken from the write stream
  typedef enum logic [1:0] {R_IDLE, R_AR, R_DATA} rst_e;
  typedef enum logic [1:0] {W_IDLE, W_AW, W_DATA, W_RESP} wst_e;
  rst_e rstate;
  wst_e wstate;
  logic [4:0] rbeats, wbeats, wcnt;

  wire [4:0] rchunk = chunk(raddr, rleft);
  wire [4:0] wchunk = chunk(waddr, wleft);
  wire rd_fin = (rleft == 0) && (rstate == R_IDLE);
  wire wr_fin = (wleft == 0) && (wstate == W_IDLE);

  // ---------------- FIFOs ----------------
  logic [31:0] rf_mem [DEPTH];
  logic [31:0] wf_mem [DEPTH];
  logic [AW-1:0] rf_wp, rf_rp, wf_wp, wf_rp;
  logic [AW:0]   rf_cnt, wf_cnt;
  logic rf_push, rf_pop, wf_push, wf_pop;

  assign rs_valid = (rf_cnt != 0);
  assign rs_data  = rf_mem[rf_rp];
  assign rf_pop   = rs_valid & rs_ready;
  assign ws_ready = busy & wr_q & (wtake != 0) & (wf_cnt != (AW+1)'(DEPTH));
  assign wf_push  = ws_valid & ws_ready;

  assign rf_push = (rstate == R_DATA) & m_rvalid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; done <= 1'b0; err <= 1'b0; cycles <= '0;
      rd_q <= 1'b0; wr_q <= 1'b0;
      raddr <= '0; waddr <= '0; rleft <= '0; wleft <= '0; wtake <= '0;
      rstate <= R_IDLE; wstate <= W_IDLE;
      rbeats <= '0; wbeats <= '0; wcnt <= '0;
    end else begin
      done <= 1'b0;
      if (start && !busy) begin
        busy  <= 1'b1;
        err   <= 1'b0;
        cycles <= '0;
        rd_q  <= rd_en;
        wr_q  <= wr_en;
        raddr <= {src[31:2], 2'b00};
        waddr <= {dst[31:2], 2'b00};
        rleft <= rd_en ? len : 16'd0;
        wleft <= wr_en ? len : 16'd0;
        wtake <= wr_en ? len : 16'd0;
      end else if (busy && rd_fin && wr_fin && rf_cnt == 0) begin
        busy <= 1'b0;
        done <= 1'b1;
      end
      if (wf_push) wtake <= wtake - 16'd1;
      if (busy) cycles <= cycles + 32'd1;
      // read side
      case (rstate)
        R_IDLE:
          if (busy && rleft != 0 && rf_cnt <= (AW+1)'(DEPTH - 16)) begin
            rbeats <= rchunk;
            rstate <= R_AR;
          end
        R_AR:
          if (m_arready) rstate <= R_DATA;
        R_DATA:
          if (m_rvalid) begin
            if (m_rresp != 2'b00) err <= 1'b1;
            if (m_rlast) begin
              raddr  <= raddr + {25'd0, rbeats, 2'b00};
              rleft  <= rleft - {11'd0, rbeats};
              rstate <= R_IDLE;
            end
          end
        default: rstate <= R_IDLE;
      endcase
      // write side
      case (wstate)
        W_IDLE:
          if (busy && wleft != 0 && wf_cnt >= (AW+1)'(wchunk)) begin
            wbeats <= wchunk;
            wcnt   <= '0;
            wstate <= W_AW;
          end
        W_AW:
          if (m_awready) wstate <= W_DATA;
        W_DATA:
          if (m_wready) begin
            wcnt <= wcnt + 5'd1;
            if (wcnt == wbeats - 5'd1) wstate <= W_RESP;
          end
        W_RESP:
          if (m_bvalid) begin
            if (m_bresp != 2'b00) err <= 1'b1;
            waddr  <= waddr + {25'd0, wbeats, 2'b00};
            wleft  <= wleft - {11'd0, wbeats};
            wstate <= W_IDLE;
          end
        default: wstate <= W_IDLE;
      endcase
    end
  end

  // ---------------- FIFO pointers ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rf_wp <= '0; rf_rp <= '0; rf_cnt <= '0;
      wf_wp <= '0; wf_rp <= '0; wf_cnt <= '0;
    end else begin
      if (rf_push) rf_wp <= rf_wp + 1'b1;
      if (rf_pop)  rf_rp <= rf_rp + 1'b1;
      rf_cnt <= rf_cnt + (AW+1)'(rf_push) - (AW+1)'(rf_pop);
      if (wf_push) wf_wp <= wf_wp + 1'b1;
      if (wf_pop)  wf_rp <= wf_rp + 1'b1;
      wf_cnt <= wf_cnt + (AW+1)'(wf_push) - (AW+1)'(wf_pop);
    end
  end
  always_ff @(posedge clk) begin
    if (rf_push) rf_mem[rf_wp] <= m_rdata;
    if (wf_push) wf_mem[wf_wp] <= ws_data;
  end

  // ---------------- AXI outputs ----------------
  assign m_awid    = ID;
  assign m_awaddr  = waddr;
  assign m_awlen   = {3'd0, wbeats - 5'd1};
  assign m_awsize  = 3'd2;
  assign m_awburst = 2'b01;
  assign m_awprot  = PROT;
  assign m_awvalid = (wstate == W_AW);
  assign m_wdata   = wf_mem[wf_rp];
  assign m_wstrb   = 4'hF;
  assign m_wlast   = (wstate == W_DATA) && (wcnt == wbeats - 5'd1);
  assign m_wvalid  = (wstate == W_DATA);
  assign wf_pop    = m_wvalid & m_wready;
  assign m_bready  = (wstate == W_RESP);
  assign m_arid    = ID;
  assign m_araddr  = raddr;
  assign m_arlen   = {3'd0, rbeats - 5'd1};
  assign m_arsize  = 3'd2;
  assign m_arburst = 2'b01;
  assign m_arprot  = PROT;
  assign m_arvalid = (rstate == R_AR);
  assign m_rready  = (rstate == R_DATA);

  wire unused = &{1'b0, m_bid, m_rid};
endmodule
