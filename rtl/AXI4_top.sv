// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// AXI4 protocol -- real AXI4 slave IP: 5 independent channel handshakes,
// INCR/FIXED bursts (len 1..16), byte strobes, true valid/ready backpressure,
// SLVERR on out-of-range / misaligned / WRAP, DECERR on unsupported ID/size/
// burst/len. 256x32 register file as the slave memory target.
// Simplifications: single outstanding transaction per direction, ID==0 only,
// awsize <= log2(DW/8), WRAP treated as error.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module AXI4_top #(
  parameter int DW = 32,          // data width
  parameter int AW = 32           // address width
)(
  input  logic            clk,
  input  logic            rst_n,
  // ---- write address channel ----
  input  logic [3:0]      awid,
  input  logic [AW-1:0]   awaddr,
  input  logic [7:0]      awlen,
  input  logic [2:0]      awsize,
  input  logic [1:0]      awburst,
  input  logic            awvalid,
  output logic            awready,
  // ---- write data channel ----
  input  logic [DW-1:0]   wdata,
  input  logic [DW/8-1:0] wstrb,
  input  logic            wlast,
  input  logic            wvalid,
  output logic            wready,
  // ---- write response channel ----
  output logic [3:0]      bid,
  output logic [1:0]      bresp,
  output logic            bvalid,
  input  logic            bready,
  // ---- read address channel ----
  input  logic [3:0]      arid,
  input  logic [AW-1:0]   araddr,
  input  logic [7:0]      arlen,
  input  logic [2:0]      arsize,
  input  logic [1:0]      arburst,
  input  logic            arvalid,
  output logic            arready,
  // ---- read data channel ----
  output logic [3:0]      rid,
  output logic [DW-1:0]   rdata,
  output logic [1:0]      rresp,
  output logic            rlast,
  output logic            rvalid,
  input  logic            rready,
  // ---- protocol error event (sticky until reset) ----
  output logic            irq
);

  // ------------------------------------------------------------------
  // constants
  // ------------------------------------------------------------------
  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;
  localparam logic [1:0] RESP_DECERR = 2'b11;
  localparam logic [1:0] BURST_FIXED = 2'b00;
  localparam logic [1:0] BURST_INCR  = 2'b01;
  localparam logic [1:0] BURST_WRAP  = 2'b10;

  // 256 x DW register file => valid byte range [0, 1024)
  (* ram_style = "block" *) logic [DW-1:0] mem [0:255];

  // ------------------------------------------------------------------
  // helpers
  // ------------------------------------------------------------------
  function automatic logic addr_in_range(input logic [AW-1:0] a);
    addr_in_range = (a[AW-1:10] == '0) && (a[1:0] == 2'b00);
  endfunction

  // address-channel error decode (shared shape for AW and AR)
  function automatic logic decerr(input logic [3:0] id, input logic [2:0] size,
                                  input logic [1:0] burst, input logic [7:0] len);
    decerr = (id != 4'h0) || (size > 3'd2) || (burst == 2'b11) ||
             (len[7:4] != 4'h0);
  endfunction

  function automatic logic slverr_addr(input logic [AW-1:0] a, input logic [1:0] burst);
    slverr_addr = !addr_in_range(a) || (burst == BURST_WRAP);
  endfunction

  // ------------------------------------------------------------------
  // write path FSM (AW + W + B)
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  wstate_t wstate;

  logic [AW-1:0] waddr_q;
  logic [7:0]    wlen_q, wbeat_q;
  logic [1:0]    wburst_q;
  logic [3:0]    wid_q;
  logic [1:0]    werr_q;   // sticky response code for the burst

  wire aw_accept = awvalid && awready;
  wire w_accept  = wvalid  && wready;
  wire b_accept  = bvalid  && bready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wstate   <= W_IDLE;
      waddr_q  <= '0;
      wlen_q   <= 8'd0;
      wbeat_q  <= 8'd0;
      wburst_q <= BURST_INCR;
      wid_q    <= 4'h0;
      werr_q   <= RESP_OKAY;
    end else begin
      case (wstate)
        W_IDLE: begin
          if (aw_accept) begin
            wstate   <= W_DATA;
            waddr_q  <= awaddr;
            wlen_q   <= awlen;
            wbeat_q  <= 8'd0;
            wburst_q <= awburst;
            wid_q    <= awid;
            werr_q   <= decerr(awid, awsize, awburst, awlen) ? RESP_DECERR :
                        slverr_addr(awaddr, awburst)         ? RESP_SLVERR :
                                                               RESP_OKAY;
          end
        end
        W_DATA: begin
          if (w_accept) begin
            // write data beat (only while burst is still error-free)
            if (werr_q == RESP_OKAY) begin
              if (addr_in_range(waddr_q)) begin
                for (int b = 0; b < DW/8; b++)
                  if (wstrb[b])
                    mem[waddr_q[9:2]][8*b +: 8] <= wdata[8*b +: 8];
              end else begin
                werr_q <= RESP_SLVERR;   // burst ran out of range
              end
            end
            // burst end detection + wlast protocol check
            if (wlast || (wbeat_q == wlen_q)) begin
              wstate <= W_RESP;
              if ((wlast != (wbeat_q == wlen_q)) &&
                  (werr_q == RESP_OKAY) && addr_in_range(waddr_q))
                werr_q <= RESP_SLVERR;   // early or missing wlast
            end else begin
              wbeat_q <= wbeat_q + 8'd1;
              if (wburst_q == BURST_INCR)
                waddr_q <= waddr_q + 32'd4;
            end
          end
        end
        W_RESP: begin
          if (b_accept)
            wstate <= W_IDLE;
        end
        default: wstate <= W_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // read path FSM (AR + R), independent of the write path
  // ------------------------------------------------------------------
  typedef enum logic [0:0] {R_IDLE, R_DATA} rstate_t;
  rstate_t rstate;

  logic [AW-1:0] raddr_q;
  logic [7:0]    rlen_q, rbeat_q;
  logic [1:0]    rburst_q;
  logic [3:0]    rid_q;
  logic [1:0]    rerr_q;

  wire ar_accept = arvalid && arready;
  wire r_accept  = rvalid  && rready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate   <= R_IDLE;
      raddr_q  <= '0;
      rlen_q   <= 8'd0;
      rbeat_q  <= 8'd0;
      rburst_q <= BURST_INCR;
      rid_q    <= 4'h0;
      rerr_q   <= RESP_OKAY;
    end else begin
      case (rstate)
        R_IDLE: begin
          if (ar_accept) begin
            rstate   <= R_DATA;
            raddr_q  <= araddr;
            rlen_q   <= arlen;
            rbeat_q  <= 8'd0;
            rburst_q <= arburst;
            rid_q    <= arid;
            rerr_q   <= decerr(arid, arsize, arburst, arlen) ? RESP_DECERR :
                        slverr_addr(araddr, arburst)         ? RESP_SLVERR :
                                                               RESP_OKAY;
          end
        end
        R_DATA: begin
          if (r_accept) begin
            if (rbeat_q == rlen_q) begin
              rstate <= R_IDLE;
            end else begin
              rbeat_q <= rbeat_q + 8'd1;
              if (rburst_q == BURST_INCR)
                raddr_q <= raddr_q + 32'd4;
            end
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // irq: sticky protocol-error event flag
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      irq <= 1'b0;
    else if ((aw_accept && (decerr(awid, awsize, awburst, awlen) ||
                            slverr_addr(awaddr, awburst))) ||
             (w_accept  && (!addr_in_range(waddr_q) ||
                            (wlast != (wbeat_q == wlen_q)))) ||
             (ar_accept && (decerr(arid, arsize, arburst, arlen) ||
                            slverr_addr(araddr, arburst))) ||
             (r_accept  && (rresp != RESP_OKAY)))
      irq <= 1'b1;
  end

  // ------------------------------------------------------------------
  // channel outputs
  // ------------------------------------------------------------------
  // asynchronous read-data mux (word select kept out of always_comb to
  // avoid simulator sensitivity-list limitations)
  wire [DW-1:0] rdata_mux = addr_in_range(raddr_q) ? mem[raddr_q[9:2]]
                                                   : {DW{1'b0}};

  always_comb begin
    // write channels
    awready = (wstate == W_IDLE);
    wready  = (wstate == W_DATA);
    bvalid  = (wstate == W_RESP);
    bid     = wid_q;
    bresp   = werr_q;
    // read channels
    arready = (rstate == R_IDLE);
    rvalid  = (rstate == R_DATA);
    rid     = rid_q;
    rlast   = (rstate == R_DATA) && (rbeat_q == rlen_q);
    rdata   = rdata_mux;
    rresp   = rerr_q;
    if ((rstate == R_DATA) && (rerr_q == RESP_OKAY) && !addr_in_range(raddr_q))
      rresp = RESP_SLVERR;   // burst ran out of range mid-way
  end

endmodule
