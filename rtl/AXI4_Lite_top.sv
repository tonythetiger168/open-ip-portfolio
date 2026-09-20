// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// AXI4-Lite protocol -- real AXI4-Lite slave IP: 5 channel handshakes,
// single-beat transfers only (no awlen/wlast), byte strobes, true
// valid/ready backpressure, SLVERR on out-of-range / misaligned access.
// 256x32 register file as the slave memory target.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module AXI4_Lite_top #(
  parameter int DW = 32,          // data width
  parameter int AW = 32           // address width
)(
  input  logic            clk,
  input  logic            rst_n,
  // ---- write address channel ----
  input  logic [AW-1:0]   awaddr,
  input  logic            awvalid,
  output logic            awready,
  // ---- write data channel ----
  input  logic [DW-1:0]   wdata,
  input  logic [DW/8-1:0] wstrb,
  input  logic            wvalid,
  output logic            wready,
  // ---- write response channel ----
  output logic [1:0]      bresp,
  output logic            bvalid,
  input  logic            bready,
  // ---- read address channel ----
  input  logic [AW-1:0]   araddr,
  input  logic            arvalid,
  output logic            arready,
  // ---- read data channel ----
  output logic [DW-1:0]   rdata,
  output logic [1:0]      rresp,
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

  // 256 x DW register file => valid byte range [0, 1024)
  (* ram_style = "block" *) logic [DW-1:0] mem [0:255];

  function automatic logic addr_in_range(input logic [AW-1:0] a);
    addr_in_range = (a[AW-1:10] == '0) && (a[1:0] == 2'b00);
  endfunction

  // ------------------------------------------------------------------
  // write path FSM (AW + W + B)
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  wstate_t wstate;

  logic [AW-1:0] waddr_q;
  logic [1:0]    werr_q;

  wire aw_accept = awvalid && awready;
  wire w_accept  = wvalid  && wready;
  wire b_accept  = bvalid  && bready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wstate  <= W_IDLE;
      waddr_q <= '0;
      werr_q  <= RESP_OKAY;
    end else begin
      case (wstate)
        W_IDLE: begin
          if (aw_accept) begin
            wstate  <= W_DATA;
            waddr_q <= awaddr;
            werr_q  <= addr_in_range(awaddr) ? RESP_OKAY : RESP_SLVERR;
          end
        end
        W_DATA: begin
          if (w_accept) begin
            if (werr_q == RESP_OKAY) begin
              for (int b = 0; b < DW/8; b++)
                if (wstrb[b])
                  mem[waddr_q[9:2]][8*b +: 8] <= wdata[8*b +: 8];
            end
            wstate <= W_RESP;
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
  logic [1:0]    rerr_q;

  wire ar_accept = arvalid && arready;
  wire r_accept  = rvalid  && rready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate  <= R_IDLE;
      raddr_q <= '0;
      rerr_q  <= RESP_OKAY;
    end else begin
      case (rstate)
        R_IDLE: begin
          if (ar_accept) begin
            rstate  <= R_DATA;
            raddr_q <= araddr;
            rerr_q  <= addr_in_range(araddr) ? RESP_OKAY : RESP_SLVERR;
          end
        end
        R_DATA: begin
          if (r_accept)
            rstate <= R_IDLE;
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
    else if ((aw_accept && !addr_in_range(awaddr)) ||
             (ar_accept && !addr_in_range(araddr)))
      irq <= 1'b1;
  end

  // ------------------------------------------------------------------
  // channel outputs
  // ------------------------------------------------------------------
  wire [DW-1:0] rdata_mux = addr_in_range(raddr_q) ? mem[raddr_q[9:2]]
                                                   : {DW{1'b0}};

  always_comb begin
    // write channels
    awready = (wstate == W_IDLE);
    wready  = (wstate == W_DATA);
    bvalid  = (wstate == W_RESP);
    bresp   = werr_q;
    // read channels
    arready = (rstate == R_IDLE);
    rvalid  = (rstate == R_DATA);
    rdata   = rdata_mux;
    rresp   = rerr_q;
  end

endmodule
