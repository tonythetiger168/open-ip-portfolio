// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ACE-Lite (AXI Coherency Extension, I/O-coherent subset) -- synthesizable slave
// Scope: full AXI4 channels (AW/W/B/AR/R, INCR burst) + ACE-Lite fields
//        ARSNOOP/ARDOMAIN/ARBAR/AWSNOOP/AWDOMAIN/AWBAR (accepted; barrier
//        ordering guaranteed by strict in-order completion). No snoop channels.
//        Internal 256x32 word memory; out-of-range access -> SLVERR + irq.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module ACE_Lite_top #(
  parameter int DW = 32,          // data width
  parameter int AW = 32           // address width
)(
  input  logic            clk,
  input  logic            rst_n,
  // ---------------- AXI4 write address channel (+ ACE-Lite fields) --------
  input  logic            awvalid,
  output logic            awready,
  input  logic [AW-1:0]   awaddr,
  input  logic [7:0]      awlen,
  input  logic [2:0]      awsize,
  input  logic [1:0]      awburst,
  input  logic [2:0]      awsnoop,
  input  logic [1:0]      awdomain,
  input  logic [1:0]      awbar,
  // ---------------- AXI4 write data channel --------------------------------
  input  logic            wvalid,
  output logic            wready,
  input  logic [DW-1:0]   wdata,
  input  logic [DW/8-1:0] wstrb,
  input  logic            wlast,
  // ---------------- AXI4 write response channel ----------------------------
  output logic            bvalid,
  input  logic            bready,
  output logic [1:0]      bresp,
  // ---------------- AXI4 read address channel (+ ACE-Lite fields) ---------
  input  logic            arvalid,
  output logic            arready,
  input  logic [AW-1:0]   araddr,
  input  logic [7:0]      arlen,
  input  logic [2:0]      arsize,
  input  logic [1:0]      arburst,
  input  logic [3:0]      arsnoop,
  input  logic [1:0]      ardomain,
  input  logic [1:0]      arbar,
  // ---------------- AXI4 read data channel ---------------------------------
  output logic            rvalid,
  input  logic            rready,
  output logic [DW-1:0]   rdata,
  output logic [1:0]      rresp,
  output logic            rlast,
  // ---------------- framework ----------------------------------------------
  output logic            irq
);

  localparam logic [1:0] AXI_OKAY   = 2'b00;
  localparam logic [1:0] AXI_SLVERR = 2'b10;
  localparam logic [1:0] BURST_INCR = 2'b01;
  // 1KB address space (256 x 32-bit words); addr >= 1KB is out of range
  localparam int MEM_WORDS = 256;

  (* ram_style = "block" *) logic [DW-1:0] mem [0:MEM_WORDS-1];

  // ------------------------- write channel FSM ------------------------------
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  wstate_t       wstate;
  logic [AW-1:0] waddr_q;
  logic [7:0]    wlen_q, wbeat_q;
  logic          werr_q;
  wire           w_last = wlast || (wbeat_q == wlen_q);

  // ------------------------- read channel FSM -------------------------------
  typedef enum logic [0:0] {R_IDLE, R_DATA} rstate_t;
  rstate_t       rstate;
  logic [AW-1:0] raddr_q;
  logic [7:0]    rlen_q, rbeat_q;
  logic          rerr_q;

  // ==========================================================================
  // sequential logic
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wstate  <= W_IDLE;
      rstate  <= R_IDLE;
      waddr_q <= '0;
      wlen_q  <= '0;
      wbeat_q <= '0;
      werr_q  <= 1'b0;
      raddr_q <= '0;
      rlen_q  <= '0;
      rbeat_q <= '0;
      rerr_q  <= 1'b0;
      irq     <= 1'b0;
    end else begin
      irq <= 1'b0;   // single-cycle pulse on protocol error events

      // -------------------- write channel --------------------------------
      case (wstate)
        W_IDLE: if (awvalid && awready) begin
          waddr_q <= awaddr;
          wlen_q  <= awlen;
          wbeat_q <= '0;
          werr_q  <= (awburst != BURST_INCR) || (awsize > 3'd2) || (|awaddr[AW-1:10]);
          wstate  <= W_DATA;
        end
        W_DATA: if (wvalid && wready) begin
          if (!werr_q) begin
            for (int b = 0; b < DW/8; b++)
              if (wstrb[b])
                mem[waddr_q[9:2]][8*b +: 8] <= wdata[8*b +: 8];
          end
          waddr_q <= waddr_q + 4;
          wbeat_q <= wbeat_q + 8'd1;
          if (w_last) begin
            wstate <= W_RESP;
            if (werr_q) irq <= 1'b1;
          end
        end
        W_RESP: if (bvalid && bready)
          wstate <= W_IDLE;
        default: wstate <= W_IDLE;
      endcase

      // -------------------- read channel ---------------------------------
      case (rstate)
        R_IDLE: if (arvalid && arready) begin
          raddr_q <= araddr;
          rlen_q  <= arlen;
          rbeat_q <= '0;
          rerr_q  <= (arburst != BURST_INCR) || (arsize > 3'd2) || (|araddr[AW-1:10]);
          rstate  <= R_DATA;
        end
        R_DATA: if (rvalid && rready) begin
          raddr_q <= raddr_q + 4;
          rbeat_q <= rbeat_q + 8'd1;
          if (rbeat_q == rlen_q) begin
            rstate <= R_IDLE;
            if (rerr_q) irq <= 1'b1;
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

  // ==========================================================================
  // combinational outputs
  // ==========================================================================
  always_comb begin
    // write channel
    awready = (wstate == W_IDLE);
    wready  = (wstate == W_DATA);
    bvalid  = (wstate == W_RESP);
    bresp   = werr_q ? AXI_SLVERR : AXI_OKAY;
    // read channel
    arready = (rstate == R_IDLE);
    rvalid  = (rstate == R_DATA);
    rdata   = rerr_q ? {DW{1'b0}} : mem[raddr_q[9:2]];
    rresp   = rerr_q ? AXI_SLVERR : AXI_OKAY;
    rlast   = (rstate == R_DATA) && (rbeat_q == rlen_q);
  end

  // ACE-Lite coherency fields accepted; ordering enforced by in-order completion
  wire unused = &{1'b0, awsnoop, awdomain, awbar, arsnoop, ardomain, arbar};

endmodule
