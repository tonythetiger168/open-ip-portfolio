// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ACE (AXI Coherency Extension) -- synthesizable ACE cached-master/slave model
// Scope: AXI4 main channels (AW/W/B/AR/R, INCR burst) + ACE snoop channels
//        (AC/CR/CD) with an internal 64-line cache model (valid/dirty/tag/data).
//        Dirty-hit snoops return data on CD; MakeUnique/CleanInvalid invalidate.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module ACE_top #(
  parameter int DW = 32,          // data width
  parameter int AW = 32           // address width
)(
  input  logic            clk,
  input  logic            rst_n,
  // ---------------- AXI4 write address channel (+ ACE fields) -------------
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
  // ---------------- AXI4 read address channel (+ ACE fields) ---------------
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
  // ---------------- ACE snoop address channel ------------------------------
  input  logic            acvalid,
  output logic            acready,
  input  logic [AW-1:0]   acaddr,
  input  logic [3:0]      acsnoop,
  // ---------------- ACE snoop response channel -----------------------------
  output logic            crvalid,
  input  logic            crready,
  output logic [4:0]      crresp,
  // ---------------- ACE snoop data channel ---------------------------------
  output logic            cdvalid,
  input  logic            cdready,
  output logic [DW-1:0]   cddata,
  output logic            cdlast,
  // ---------------- framework ----------------------------------------------
  output logic            irq
);

  // ------------------------- constants --------------------------------------
  localparam int    LINES    = 64;                 // cache lines
  localparam logic [1:0] AXI_OKAY   = 2'b00;
  localparam logic [1:0] AXI_SLVERR = 2'b10;
  localparam logic [1:0] BURST_INCR = 2'b01;
  // ACSNOOP encodings (documented subset)
  localparam logic [3:0] SNP_READSHARED   = 4'b0000;
  localparam logic [3:0] SNP_READCLEAN    = 4'b0001;
  localparam logic [3:0] SNP_MAKEUNIQUE   = 4'b0111;
  localparam logic [3:0] SNP_CLEANINVALID = 4'b1000;

  // ------------------------- cache model ------------------------------------
  // 64 direct-mapped lines, one DW word per line.
  // index = addr[7:2], tag = addr[AW-1:8]; addr >= 64KB is out of range.
  logic [63:0]      line_valid;
  logic [63:0]      line_dirty;
  logic [AW-1:8]    line_tag  [0:LINES-1];
  logic [DW-1:0]    line_data [0:LINES-1];

  // ------------------------- write channel FSM ------------------------------
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  wstate_t       wstate;
  logic [AW-1:0] waddr_q;
  logic [7:0]    wlen_q, wbeat_q;
  logic          werr_q;

  wire [5:0]     widx   = waddr_q[7:2];
  wire           w_last = wlast || (wbeat_q == wlen_q);

  // ------------------------- read channel FSM -------------------------------
  typedef enum logic [0:0] {R_IDLE, R_DATA} rstate_t;
  rstate_t       rstate;
  logic [AW-1:0] raddr_q;
  logic [7:0]    rlen_q, rbeat_q;
  logic          rerr_q;

  wire [5:0]     ridx = raddr_q[7:2];
  wire           rhit = line_valid[ridx] && (line_tag[ridx] == raddr_q[AW-1:8]);

  // ------------------------- snoop channel FSM ------------------------------
  typedef enum logic [1:0] {S_IDLE, S_CR, S_CD} sstate_t;
  sstate_t       sstate;
  logic [AW-1:0] acaddr_q;
  logic [3:0]    acsnoop_q;
  logic          snp_xfer_q;    // DataTransfer
  logic          snp_shared_q;  // IsShared
  logic          snp_dirty_q;   // PassDirty

  wire [5:0]     aidx = acaddr_q[7:2];
  wire           ac_hit_w = line_valid[acaddr[7:2]] && (line_tag[acaddr[7:2]] == acaddr[AW-1:8]);

  // ==========================================================================
  // sequential logic
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      line_valid  <= '0;
      line_dirty  <= '0;
      wstate      <= W_IDLE;
      rstate      <= R_IDLE;
      sstate      <= S_IDLE;
      waddr_q     <= '0;
      wlen_q      <= '0;
      wbeat_q     <= '0;
      werr_q      <= 1'b0;
      raddr_q     <= '0;
      rlen_q      <= '0;
      rbeat_q     <= '0;
      rerr_q      <= 1'b0;
      acaddr_q    <= '0;
      acsnoop_q   <= '0;
      snp_xfer_q  <= 1'b0;
      snp_shared_q<= 1'b0;
      snp_dirty_q <= 1'b0;
      irq         <= 1'b0;
    end else begin
      irq <= 1'b0;   // default: single-cycle pulse

      // -------------------- write channel --------------------------------
      case (wstate)
        W_IDLE: if (awvalid && awready) begin
          waddr_q <= awaddr;
          wlen_q  <= awlen;
          wbeat_q <= '0;
          werr_q  <= (awburst != BURST_INCR) || (awsize > 3'd2) || (|awaddr[AW-1:16]);
          wstate  <= W_DATA;
        end
        W_DATA: if (wvalid && wready) begin
          if (!werr_q) begin
            line_valid[widx]      <= 1'b1;
            line_dirty[widx]      <= 1'b1;
            line_tag[widx]        <= waddr_q[AW-1:8];
            for (int b = 0; b < DW/8; b++)
              if (wstrb[b])
                line_data[widx][8*b +: 8] <= wdata[8*b +: 8];
          end
          waddr_q <= waddr_q + 4;
          wbeat_q <= wbeat_q + 8'd1;
          if (w_last) begin
            wstate <= W_RESP;
            if (werr_q) irq <= 1'b1;
          end
        end
        W_RESP: if (bvalid && bready) begin
          wstate <= W_IDLE;
        end
        default: wstate <= W_IDLE;
      endcase

      // -------------------- read channel ---------------------------------
      case (rstate)
        R_IDLE: if (arvalid && arready) begin
          raddr_q <= araddr;
          rlen_q  <= arlen;
          rbeat_q <= '0;
          rerr_q  <= (arburst != BURST_INCR) || (arsize > 3'd2) || (|araddr[AW-1:16]);
          rstate  <= R_DATA;
        end
        R_DATA: if (rvalid && rready) begin
          raddr_q <= raddr_q + 32'd4;
          rbeat_q <= rbeat_q + 8'd1;
          if (rbeat_q == rlen_q) begin
            rstate <= R_IDLE;
            if (rerr_q) irq <= 1'b1;
          end
        end
        default: rstate <= R_IDLE;
      endcase

      // -------------------- snoop channel --------------------------------
      case (sstate)
        S_IDLE: if (acvalid && acready) begin
          acaddr_q  <= acaddr;
          acsnoop_q <= acsnoop;
          snp_xfer_q   <= 1'b0;
          snp_shared_q <= 1'b0;
          snp_dirty_q  <= 1'b0;
          case (acsnoop)
            SNP_READSHARED, SNP_READCLEAN: if (ac_hit_w) begin
              snp_xfer_q   <= 1'b1;
              snp_shared_q <= 1'b1;
              snp_dirty_q  <= line_dirty[acaddr[7:2]];
              line_dirty[acaddr[7:2]] <= 1'b0;   // dirty responsibility passed on
            end
            SNP_MAKEUNIQUE: begin
              line_valid[acaddr[7:2]] <= 1'b0;   // invalidate, no data transfer
              line_dirty[acaddr[7:2]] <= 1'b0;
            end
            SNP_CLEANINVALID: if (ac_hit_w) begin
              if (line_dirty[acaddr[7:2]]) begin
                snp_xfer_q  <= 1'b1;
                snp_dirty_q <= 1'b1;
              end
              line_valid[acaddr[7:2]] <= 1'b0;
              line_dirty[acaddr[7:2]] <= 1'b0;
            end
            default: ; // unsupported snoop: plain miss response
          endcase
          sstate <= S_CR;
        end
        S_CR: if (crvalid && crready)
          sstate <= snp_xfer_q ? S_CD : S_IDLE;
        S_CD: if (cdvalid && cdready)
          sstate <= S_IDLE;
        default: sstate <= S_IDLE;
      endcase
    end
  end

  // ==========================================================================
  // combinational outputs
  // ==========================================================================
  always_comb begin
    // write channel
    awready = (wstate == W_IDLE) && (sstate == S_IDLE);
    wready  = (wstate == W_DATA);
    bvalid  = (wstate == W_RESP);
    bresp   = werr_q ? AXI_SLVERR : AXI_OKAY;
    // read channel
    arready = (rstate == R_IDLE);
    rvalid  = (rstate == R_DATA);
    rdata   = rhit ? line_data[ridx] : {DW{1'b0}};
    rresp   = rerr_q ? AXI_SLVERR : AXI_OKAY;
    rlast   = (rstate == R_DATA) && (rbeat_q == rlen_q);
    // snoop channel: only accept AC when the write datapath is idle
    acready = (sstate == S_IDLE) && (wstate == W_IDLE);
    crvalid = (sstate == S_CR);
    crresp  = {1'b0 /*WasUnique*/, snp_shared_q, snp_dirty_q,
               1'b0 /*Error*/, snp_xfer_q /*DataTransfer*/};
    cdvalid = (sstate == S_CD);
    cddata  = line_data[aidx];
    cdlast  = (sstate == S_CD);   // single-beat line transfer
  end

  // ACE fields accepted but not functionally used in this simplified model
  wire unused = &{1'b0, awsnoop, awdomain, awbar, arsnoop, ardomain, arbar, acsnoop_q};

endmodule
