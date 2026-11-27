// SPDX-License-Identifier: Apache-2.0
// Behavioural DRAM device for the memory-controller TBs (DDR / LPDDR / GDDR /
// HBM). The controllers keep no array of their own: a WR puts the word on
// dq, and a RD takes the word the device drives on dq CL clocks after the RD
// command. This block plays that device from the pins.
//
// Included inside a TB module after the DUT pins are declared. Needs:
//   localparam NCH            channels; channel g owns dq[W*g +: W]
//   function cellof(a)        storage word of host address a (the same
//                             mapping the scoreboard uses)
//   `MEM_DEV_RD, `MEM_DEV_WR  expressions on the command pins: a RD / WR
//                             command is on the pins this clock
// Optional:
//   `MEM_DEV_CLK   clock (default clk)
//   `MEM_DEV_ON    device powered and clocked (default cke): low drops the
//                  reads in flight, the array keeps its data
//   `MEM_DEV_CL    read latency in clocks (default CL)
//   `MEM_DEV_CH(a) channel of host address a (default 0)
//   `MEM_DEV_W     word width per channel (default 16)
//   `MEM_DEV_WMASK bits of the word a WR stores (narrow modes; default all)
//   `MEM_DEV_BEATS / `MEM_DEV_BEAT(w, k)  a read word sent over BEATS
//                  clocks, the last one in the clock where the controller
//                  takes it; beat k drives `MEM_DEV_BEAT(w, k) on the lanes
//                  (default 1 beat of w itself)
//   `MEM_DEV_X / `MEM_DEV_XW  a second lane group stored with the word
//                  (e.g. ECC check bits): channel g owns X[XW*g +: XW]; the
//                  device keeps {x, dq} per cell (dev_arr[c][W +: XW] = x)
//   `MEM_DEV_DQ    the dq net (default dq), `MEM_DEV_TA the trace address
//                  (default trace_addr)
//   `MEM_DEV_LINE  expression on the command pins: the RD / WR on the pins
//                  is a BL8 line burst (default never). A line moves the 8
//                  cells `MEM_DEV_LCELL(a, k), k = 0..7 (default cellof(a)
//                  with its low 3 bits = k): a line RD drives beat k so the
//                  controller samples it k clocks after the point where it
//                  samples a word; a line WR's beat k is on dq in clock
//                  WR + `MEM_DEV_CWL + k
//   `MEM_DEV_DQS   the dqs net: driven {~s, s} with the beats of a line RD,
//                  s = k[0] (default: not driven)
// Address: the controllers have no bank / channel pins, so, as the checkers
// in tb/cov do, the device takes the word's host address from the trace port,
// which carries it in the clock before the command. Write data is on dq in
// that same clock (the clock before the WR command).
// Timing: a RD seen at clock edge E is answered with the word on the
// channel's dq lanes from edge E + CL - 1 to edge E + CL, where the
// controller samples it (a BEATS-beat burst starts BEATS - 1 clocks earlier).
`ifndef MEM_DEV_CLK
`define MEM_DEV_CLK clk
`endif
`ifndef MEM_DEV_ON
`define MEM_DEV_ON cke
`endif
`ifndef MEM_DEV_CL
`define MEM_DEV_CL CL
`endif
`ifndef MEM_DEV_CH
`define MEM_DEV_CH(a) 0
`endif
`ifndef MEM_DEV_W
`define MEM_DEV_W 16
`endif
`ifndef MEM_DEV_WMASK
`define MEM_DEV_WMASK {`MEM_DEV_W{1'b1}}
`endif
`ifndef MEM_DEV_BEATS
`define MEM_DEV_BEATS 1
`endif
`ifndef MEM_DEV_BEAT
`define MEM_DEV_BEAT(w, k) (w)
`endif
`ifndef MEM_DEV_DQ
`define MEM_DEV_DQ dq
`endif
`ifndef MEM_DEV_TA
`define MEM_DEV_TA trace_addr
`endif
`ifndef MEM_DEV_LINE
`define MEM_DEV_LINE 1'b0
`endif
`ifndef MEM_DEV_CWL
`define MEM_DEV_CWL 1                  // (used by line bursts only)
`endif
`ifndef MEM_DEV_LCELL
`define MEM_DEV_LCELL(a, k) ((cellof(a) & ~7) | (k))
`endif

`ifdef MEM_DEV_X
  localparam int DEV_XW = `MEM_DEV_XW;
`else
  localparam int DEV_XW = 0;
`endif
  localparam int DEV_NCELL = 1 << 16, DEV_NQ = 8, DEV_SW = `MEM_DEV_W + DEV_XW;
  logic [DEV_SW-1:0]         dev_arr [0:DEV_NCELL-1];
  logic [NCH*`MEM_DEV_W-1:0] dev_dq_q;            // dq in the previous clock
  logic [31:0]               dev_ta_q;            // trace address in the previous clock
  logic                      dev_oe = 1'b0;
  int                        dev_bk = 0;          // beats of the burst left after this one
  logic [DEV_SW-1:0]         dev_word = '0;
  int                        dev_lane = 0;
  bit                        dev_v   [DEV_NQ];    // reads in flight
  int                        dev_cnt [DEV_NQ];
  int                        dev_rl  [DEV_NQ];
  logic [DEV_SW-1:0]         dev_rw  [DEV_NQ];
  // line bursts: the read line in flight / on dq, the write line being taken
  bit                        dev_isl = 1'b0;      // the burst on dq is a line
  bit                        dev_ql  [DEV_NQ];
  logic [DEV_SW-1:0]         dev_qlw [DEV_NQ][8];
  logic [DEV_SW-1:0]         dev_lw  [8];
  bit                        dev_wv = 1'b0;       // line WR taking its beats
  int                        dev_wcnt, dev_wk, dev_wch;
  logic [31:0]               dev_wa;
  initial begin
    for (int i = 0; i < DEV_NCELL; i++) dev_arr[i] = '0;
    for (int i = 0; i < DEV_NQ; i++) dev_v[i] = 1'b0;
  end

  for (genvar g = 0; g < NCH; g++) begin : g_dev_dq
    assign `MEM_DEV_DQ[`MEM_DEV_W*g +: `MEM_DEV_W] = (dev_oe && dev_lane == g) ?
      (dev_isl ? dev_lw[7 - dev_bk][`MEM_DEV_W-1:0] :
       `MEM_DEV_BEAT(dev_word[`MEM_DEV_W-1:0], `MEM_DEV_BEATS - 1 - dev_bk)) : {`MEM_DEV_W{1'bz}};
`ifdef MEM_DEV_X
    assign `MEM_DEV_X[DEV_XW*g +: DEV_XW] = (dev_oe && dev_lane == g) ?
      (dev_isl ? dev_lw[7 - dev_bk][`MEM_DEV_W +: DEV_XW] : dev_word[`MEM_DEV_W +: DEV_XW]) : {DEV_XW{1'bz}};
`endif
  end
`ifdef MEM_DEV_DQS
  assign `MEM_DEV_DQS = (dev_oe && dev_isl) ? {dev_bk[0], ~dev_bk[0]} : 2'bzz;   // s = (7 - bk)[0]
`endif
`ifdef MEM_DEV_X
  logic [NCH*DEV_XW-1:0] dev_x_q;                 // X lanes in the previous clock
  always @(posedge `MEM_DEV_CLK) dev_x_q <= `MEM_DEV_X;
`endif

  always @(posedge `MEM_DEV_CLK) begin
    int c, ch, k;
    bit ln;
    if (dev_oe && dev_bk > 0) dev_bk <= dev_bk - 1;   // next beat of the burst
    else dev_oe <= 1'b0;
    for (int i = 0; i < DEV_NQ; i++)
      if (dev_v[i]) begin
        if (dev_cnt[i] == 0) begin
          dev_oe <= 1'b1; dev_word <= dev_rw[i]; dev_lane <= dev_rl[i]; dev_v[i] = 1'b0;
          dev_isl <= dev_ql[i]; for (int j = 0; j < 8; j++) dev_lw[j] <= dev_qlw[i][j];
          dev_bk <= dev_ql[i] ? 7 : `MEM_DEV_BEATS - 1;
        end else dev_cnt[i]--;
      end
    // line WR: beat k is on dq in clock WR + CWL + k
    if (dev_wv && `MEM_DEV_ON === 1'b1) begin
      if (dev_wcnt > 1) dev_wcnt--;
      else begin
        c = `MEM_DEV_LCELL(dev_wa, dev_wk) % DEV_NCELL;
        dev_arr[c][`MEM_DEV_W-1:0] = `MEM_DEV_DQ[`MEM_DEV_W*dev_wch +: `MEM_DEV_W];
`ifdef MEM_DEV_X
        dev_arr[c][`MEM_DEV_W +: DEV_XW] = `MEM_DEV_X[DEV_XW*dev_wch +: DEV_XW];
`endif
        dev_wk++;
        if (dev_wk == 8) dev_wv = 1'b0;
      end
    end
    if (`MEM_DEV_ON !== 1'b1) begin
      for (int i = 0; i < DEV_NQ; i++) dev_v[i] = 1'b0;
      dev_wv = 1'b0;
    end else begin
      c  = cellof(dev_ta_q) % DEV_NCELL;
      ch = `MEM_DEV_CH(dev_ta_q);
      ln = `MEM_DEV_LINE;
      if (`MEM_DEV_WR && ln) begin
        dev_wv = 1'b1; dev_wcnt = `MEM_DEV_CWL; dev_wk = 0; dev_wch = ch; dev_wa = dev_ta_q;
      end else if (`MEM_DEV_WR) begin
        dev_arr[c][`MEM_DEV_W-1:0] = (dev_arr[c][`MEM_DEV_W-1:0] & ~(`MEM_DEV_WMASK)) |
                                     (dev_dq_q[`MEM_DEV_W*ch +: `MEM_DEV_W] & (`MEM_DEV_WMASK));
`ifdef MEM_DEV_X
        dev_arr[c][`MEM_DEV_W +: DEV_XW] = dev_x_q[DEV_XW*ch +: DEV_XW];
`endif
      end
      if (`MEM_DEV_RD) begin
        k = 0;
        while (k < DEV_NQ && dev_v[k]) k++;
        if (k < DEV_NQ) begin
          dev_ql[k] = ln;
          for (int j = 0; j < 8; j++) dev_qlw[k][j] = dev_arr[`MEM_DEV_LCELL(dev_ta_q, j) % DEV_NCELL];
        end
        if (`MEM_DEV_CL - (ln ? 1 : `MEM_DEV_BEATS) <= 0) begin
          dev_oe <= 1'b1; dev_word <= dev_arr[c]; dev_lane <= ch;
          dev_isl <= ln; if (k < DEV_NQ) for (int j = 0; j < 8; j++) dev_lw[j] <= dev_qlw[k][j];
          dev_bk <= ln ? 7 : `MEM_DEV_BEATS - 1;
        end else if (k < DEV_NQ) begin
          dev_v[k] = 1'b1; dev_cnt[k] = `MEM_DEV_CL - (ln ? 1 : `MEM_DEV_BEATS) - 1; dev_rl[k] = ch; dev_rw[k] = dev_arr[c];
        end
      end
    end
    dev_dq_q <= `MEM_DEV_DQ;
    dev_ta_q <= `MEM_DEV_TA;
  end
