// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ddr_axi_slv: AXI4 subordinate front end of the portfolio memory controllers
// (DDR4_top, LPDDR4_top and the other cores with the shared DDR host contract)
// ----------------------------------------------------------------------------
//  - AXI4 subordinate, 32-bit data, 4-bit ID, INCR / FIXED / WRAP bursts of
//    1..256 beats, AxSIZE 0..2 (narrow transfers use WSTRB / the byte lanes of
//    the address). One transaction at a time; when AR and AW are both pending
//    the two take turns.
//  - Each 32-bit word is two 16-bit host operations: low halfword first.
//    Halfword h = addr[31:1] maps onto the host address as
//    haddr = {h[24:11], 7'b0, h[10:0]}: column h[7:0], channel h[8], bank
//    h[10:9], row h[24:11]. Storage is the core's (it aliases above it).
//  - Writes: a halfword with both strobes set is one WR; with no strobe it is
//    skipped; with one strobe it is a read-modify-write (RD, merge, WR).
//  - Read data of a halfword is taken the clock after HDONE (the core
//    registers HRDATA on the HDONE edge).
//  - BRESP / RRESP SLVERR: AxSIZE > 2, or (writes) WLAST on the wrong beat.
//    An erroring write consumes its beats up to WLAST and writes nothing
//    more after the error is seen.
//  - Counters: N_RD / N_WR count completed bursts, N_RMW read-modify-writes,
//    N_ERR SLVERR responses; ERR_IRQ pulses with each of them.
// ============================================================================
module ddr_axi_slv (
  input  logic        clk,
  input  logic        rst_n,
  // AXI4 subordinate
  input  logic [3:0]  s_awid,
  input  logic [31:0] s_awaddr,
  input  logic [7:0]  s_awlen,
  input  logic [2:0]  s_awsize,
  input  logic [1:0]  s_awburst,
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
  input  logic        s_arvalid,
  output logic        s_arready,
  output logic [3:0]  s_rid,
  output logic [31:0] s_rdata,
  output logic [1:0]  s_rresp,
  output logic        s_rlast,
  output logic        s_rvalid,
  input  logic        s_rready,
  // host port of the memory controller core
  output logic        hvalid,
  input  logic        hready,
  output logic [2:0]  hcmd,
  output logic [31:0] haddr,
  output logic [15:0] hwdata,
  input  logic [15:0] hrdata,
  input  logic        hdone,
  // statistics
  output logic [15:0] n_rd,
  output logic [15:0] n_wr,
  output logic [15:0] n_rmw,
  output logic [15:0] n_err,
  output logic        err_irq          // one clock per SLVERR response
);
  localparam logic [2:0] C_RD = 3'd2, C_WR = 3'd3;

  typedef enum logic [3:0] {
    S_IDLE, S_R_ISS, S_R_WAIT, S_R_CAP, S_R_BEAT,
    S_W_DATA, S_W_HALF, S_W_ISS, S_W_RWAIT, S_W_RCAP, S_W_DRAIN, S_W_RESP
  } st_t;
  st_t st;

  logic [3:0]  id_q;
  logic [31:0] addr_q;            // current beat address
  logic [7:0]  len_q, beat_q;
  logic [2:0]  size_q;
  logic [1:0]  burst_q;
  logic        half_q;            // 0 low halfword, 1 high
  logic        bad_q;             // SLVERR for this transaction
  logic        last_pref;         // AR got the last turn
  logic [31:0] wd_q;
  logic [3:0]  ws_q;
  logic [15:0] rmw_q;             // halfword read back for a merge
  logic        rmw_wr;            // the WR of a read-modify-write is pending
  logic        wl_q;              // WLAST of the current beat

  wire [30:0] hw_idx = {addr_q[31:2], half_q};
  wire [31:0] map_addr = {hw_idx[24:11], 7'b0, hw_idx[10:0]};

  // next beat address (AXI4 A3.4.1); FIXED keeps the address, WRAP (len 1,
  // 3, 7 or 15) wraps inside the (len + 1) * size window
  logic [31:0] inc, nxt, wmask, addr_nx;
  always_comb begin
    inc   = 32'd1 << size_q;
    nxt   = (addr_q & ~(inc - 32'd1)) + inc;
    wmask = ((32'(len_q) + 32'd1) << size_q) - 32'd1;
    case (burst_q)
      2'b00:   addr_nx = addr_q;
      2'b10:   addr_nx = (addr_q & ~wmask) | (nxt & wmask);
      default: addr_nx = nxt;
    endcase
  end

  wire [1:0] hstrb = half_q ? ws_q[3:2] : ws_q[1:0];
  wire [15:0] hdat = half_q ? wd_q[31:16] : wd_q[15:0];
  wire [15:0] merged = {hstrb[1] ? hdat[15:8] : rmw_q[15:8], hstrb[0] ? hdat[7:0] : rmw_q[7:0]};

  assign s_awready = (st == S_IDLE) && s_awvalid && !(s_arvalid && !last_pref);
  assign s_arready = (st == S_IDLE) && s_arvalid && !(s_awvalid && last_pref);
  assign s_wready  = (st == S_W_DATA);
  assign s_bvalid  = (st == S_W_RESP);
  assign s_rvalid  = (st == S_R_BEAT);
  assign s_bid = id_q;  assign s_rid = id_q;
  assign s_bresp = bad_q ? 2'b10 : 2'b00;
  assign s_rresp = bad_q ? 2'b10 : 2'b00;
  assign s_rlast = (beat_q == len_q);
  assign err_irq = bad_q && ((st == S_W_RESP && s_bready) || (st == S_R_BEAT && s_rready && beat_q == len_q));

  assign hvalid = (st == S_R_ISS) || (st == S_W_ISS);
  assign hcmd   = (st == S_R_ISS || (st == S_W_ISS && hstrb != 2'b11 && !rmw_wr)) ? C_RD : C_WR;
  assign haddr  = map_addr;
  assign hwdata = (hstrb == 2'b11) ? hdat : merged;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; id_q <= '0; addr_q <= '0; len_q <= '0; beat_q <= '0; size_q <= '0;
      burst_q <= '0; half_q <= 1'b0; bad_q <= 1'b0; last_pref <= 1'b0;
      wd_q <= '0; ws_q <= '0; wl_q <= 1'b0; rmw_q <= '0; rmw_wr <= 1'b0; s_rdata <= '0;
      n_rd <= '0; n_wr <= '0; n_rmw <= '0; n_err <= '0;
    end else begin
      case (st)
        S_IDLE: begin
          if (s_arvalid && s_arready) begin
            id_q <= s_arid; addr_q <= s_araddr; len_q <= s_arlen; size_q <= s_arsize;
            burst_q <= s_arburst; beat_q <= '0; half_q <= 1'b0; last_pref <= 1'b1;
            bad_q <= (s_arsize > 3'd2);
            if (s_arsize > 3'd2) st <= S_R_BEAT; else st <= S_R_ISS;
          end else if (s_awvalid && s_awready) begin
            id_q <= s_awid; addr_q <= s_awaddr; len_q <= s_awlen; size_q <= s_awsize;
            burst_q <= s_awburst; beat_q <= '0; half_q <= 1'b0; last_pref <= 1'b0;
            bad_q <= (s_awsize > 3'd2);
            st <= S_W_DATA;
          end
        end
        // ---------------------------------------------------------- read
        S_R_ISS:  if (hready) st <= S_R_WAIT;
        S_R_WAIT: if (hdone) st <= S_R_CAP;
        S_R_CAP: begin
          if (half_q) begin s_rdata[31:16] <= hrdata; st <= S_R_BEAT; end
          else begin s_rdata[15:0] <= hrdata; half_q <= 1'b1; st <= S_R_ISS; end
        end
        S_R_BEAT: if (s_rready) begin
          half_q <= 1'b0;
          if (beat_q == len_q) begin
            n_rd <= n_rd + 16'd1; if (bad_q) n_err <= n_err + 16'd1;
            st <= S_IDLE;
          end else begin
            beat_q <= beat_q + 8'd1;
            addr_q <= addr_nx;
            if (bad_q) st <= S_R_BEAT; else st <= S_R_ISS;
          end
        end
        // ---------------------------------------------------------- write
        S_W_DATA: if (s_wvalid) begin
          wd_q <= s_wdata; ws_q <= s_wstrb; wl_q <= s_wlast; half_q <= 1'b0; rmw_wr <= 1'b0;
          if (s_wlast != (beat_q == len_q)) bad_q <= 1'b1;
          // after an error the remaining beats are only consumed
          if (bad_q || (s_wlast != (beat_q == len_q))) st <= S_W_DRAIN;
          else st <= S_W_HALF;
        end
        S_W_HALF: begin                         // pick what this halfword needs
          if (hstrb == 2'b00) begin
            if (half_q) st <= S_W_DRAIN; else half_q <= 1'b1;
          end else st <= S_W_ISS;
        end
        S_W_ISS: if (hready) begin
          if (hcmd == C_RD) begin st <= S_W_RWAIT; n_rmw <= n_rmw + 16'd1; end
          else begin
            rmw_wr <= 1'b0;
            if (half_q) st <= S_W_DRAIN; else begin half_q <= 1'b1; st <= S_W_HALF; end
          end
        end
        S_W_RWAIT: if (hdone) st <= S_W_RCAP;
        S_W_RCAP: begin rmw_q <= hrdata; rmw_wr <= 1'b1; st <= S_W_ISS; end
        S_W_DRAIN: begin                        // end of a beat
          if (bad_q ? wl_q : (beat_q == len_q)) begin
            if (hready) st <= S_W_RESP;         // last WR has left the host port
          end else begin
            beat_q <= beat_q + 8'd1;
            addr_q <= addr_nx;
            st <= S_W_DATA;
          end
        end
        S_W_RESP: if (s_bready) begin
          n_wr <= n_wr + 16'd1; if (bad_q) n_err <= n_err + 16'd1;
          st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
