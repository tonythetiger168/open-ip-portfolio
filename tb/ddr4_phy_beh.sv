// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ddr4_phy_beh: behavioural (simulation-only) DDR4 PHY for ddr4_jedec_ctrl
// ----------------------------------------------------------------------------
//  - Command pins: the controller's registered outputs are launched on the
//    falling edge of CK, so the device samples them centred on the next
//    rising edge (one CK of PHY latency on every command).
//  - Writes: write preamble 1 tCK, BL8 on DQS_t/DQS_c from CWL tCK after the
//    device sees WRITE; DQ / DM_n change a quarter clock before each DQS
//    edge (centre aligned). DM_n low masks a byte (MR5 A10 = 1).
//  - Reads: the PHY is "trained": it samples DQ a quarter clock after each
//    nominal DQS edge, CL tCK after the device sees READ, and returns the
//    burst on P_RVALID / P_RDATA at the next rising CK edge, in order.
//  - Timing uses absolute times in ps (TCK_PS), so `timescale 1ps/1ps.
// ============================================================================
`timescale 1ps/1ps
module ddr4_phy_beh #(
  parameter int NDEV   = 1,
  parameter int CL     = 22,
  parameter int CWL    = 16,
  parameter int TCK_PS = 625,
  localparam int DQW   = 16 * NDEV,
  localparam int NBY   = DQW / 8
)(
  input  logic               clk,
  // from the controller
  input  logic               p_reset_n,
  input  logic               p_cke,
  input  logic               p_odt,
  input  logic               p_cs_n,
  input  logic               p_act_n,
  input  logic               p_ras_n,
  input  logic               p_cas_n,
  input  logic               p_we_n,
  input  logic [1:0]         p_bg,
  input  logic [1:0]         p_ba,
  input  logic [13:0]        p_a,
  input  logic               p_wr,
  input  logic [8*DQW-1:0]   p_wdata,
  input  logic [8*NBY-1:0]   p_wbe,      // byte enables of the burst, beat n in [n*NBY +: NBY]
  output logic               p_rvalid,
  output logic [8*DQW-1:0]   p_rdata,
  // DDR4 pins
  output logic               ck_t,
  output logic               ck_c,
  output logic               reset_n,
  output logic               cke,
  output logic               odt,
  output logic               cs_n,
  output logic               act_n,
  output logic               ras_n_a16,
  output logic               cas_n_a15,
  output logic               we_n_a14,
  output logic [1:0]         bg,
  output logic [1:0]         ba,
  output logic [13:0]        a,
  inout  wire  [DQW-1:0]     dq,
  inout  wire  [NBY-1:0]     dqs_t,
  inout  wire  [NBY-1:0]     dqs_c,
  inout  wire  [NBY-1:0]     dm_n
);
  localparam longint T  = TCK_PS;
  localparam longint T2 = TCK_PS / 2;
  localparam longint T4 = TCK_PS / 4;

  assign ck_t = clk;
  assign ck_c = ~clk;

  // ---------------- command launch on the falling edge ----------------
  initial begin
    reset_n = 1'b0; cke = 1'b0; odt = 1'b0; cs_n = 1'b1; act_n = 1'b1;
    ras_n_a16 = 1'b1; cas_n_a15 = 1'b1; we_n_a14 = 1'b1; bg = '0; ba = '0; a = '0;
  end
  always @(negedge clk) begin
    reset_n   <= p_reset_n;
    cke       <= p_cke;
    odt       <= p_odt;
    cs_n      <= p_cs_n;
    act_n     <= p_act_n;
    ras_n_a16 <= p_ras_n;
    cas_n_a15 <= p_cas_n;
    we_n_a14  <= p_we_n;
    bg        <= p_bg;
    ba        <= p_ba;
    a         <= p_a;
  end

  // ---------------- write path ----------------
  logic [DQW-1:0] dq_o;
  logic [NBY-1:0] dm_o;
  logic           dqs_o;
  int             wr_act;                   // write bursts driving the bus
  assign dq    = wr_act > 0 ? dq_o : 'z;
  assign dm_n  = wr_act > 0 ? dm_o : 'z;
  assign dqs_t = wr_act > 0 ? {NBY{dqs_o}}  : 'z;
  assign dqs_c = wr_act > 0 ? {NBY{~dqs_o}} : 'z;
  initial begin
    wr_act = 0; dq_o = '0; dm_o = '1; dqs_o = 1'b0;
  end

  task automatic wr_burst(input longint t0, input logic [8*DQW-1:0] d, input logic [8*NBY-1:0] be);
    longint e0 = t0 + CWL * T;              // first DQS rising edge
    #(e0 - T - $time);                      // preamble: DQS_t low for 1 tCK
    wr_act = wr_act + 1;
    dqs_o  = 1'b0;
    for (int n = 0; n < 8; n++) begin
      #(e0 + n * T2 - T4 - $time);
      dq_o = d[n*DQW +: DQW];
      dm_o = be[n*NBY +: NBY];             // DM_n low masks the byte
      #(e0 + n * T2 - $time);
      dqs_o = (n % 2) == 0;
    end
    #(e0 + 4 * T - $time);                  // half-clock postamble after the last edge
    wr_act = wr_act - 1;
  endtask

  // ---------------- read path ----------------
  logic                 rv_q;
  logic [8*DQW-1:0]     rd_q;
  initial begin rv_q = 1'b0; rd_q = '0; end
  task automatic rd_burst(input longint t0);
    logic [8*DQW-1:0] d;
    longint e0 = t0 + CL * T;
    for (int n = 0; n < 8; n++) begin
      #(e0 + n * T2 + T4 - $time);
      d[n*DQW +: DQW] = dq;
    end
    @(posedge clk);
    rd_q <= d;
    rv_q <= 1'b1;
    @(posedge clk);
    rv_q <= 1'b0;
  endtask
  assign p_rvalid = rv_q;
  assign p_rdata  = rd_q;

  // the controller's outputs are stable on the falling edge; the device sees
  // the command on the next rising edge (t0)
  logic [8*DQW-1:0] wd_s;
  logic [8*NBY-1:0] wbe_s;
  longint           t0_s;
  always @(negedge clk) begin
    t0_s = $time + T2;
    if (p_wr) begin
      wd_s  = p_wdata;
      wbe_s = p_wbe;
      fork wr_burst(t0_s, wd_s, wbe_s); join_none
    end
    if (!p_cs_n && p_act_n && p_ras_n && !p_cas_n && p_we_n)
      fork rd_burst(t0_s); join_none
  end
endmodule
