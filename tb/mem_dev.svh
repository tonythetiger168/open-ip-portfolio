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
  initial begin
    for (int i = 0; i < DEV_NCELL; i++) dev_arr[i] = '0;
    for (int i = 0; i < DEV_NQ; i++) dev_v[i] = 1'b0;
  end

  for (genvar g = 0; g < NCH; g++) begin : g_dev_dq
    assign `MEM_DEV_DQ[`MEM_DEV_W*g +: `MEM_DEV_W] = (dev_oe && dev_lane == g) ?
      `MEM_DEV_BEAT(dev_word[`MEM_DEV_W-1:0], `MEM_DEV_BEATS - 1 - dev_bk) : {`MEM_DEV_W{1'bz}};
`ifdef MEM_DEV_X
    assign `MEM_DEV_X[DEV_XW*g +: DEV_XW] = (dev_oe && dev_lane == g) ? dev_word[`MEM_DEV_W +: DEV_XW] : {DEV_XW{1'bz}};
`endif
  end
`ifdef MEM_DEV_X
  logic [NCH*DEV_XW-1:0] dev_x_q;                 // X lanes in the previous clock
  always @(posedge `MEM_DEV_CLK) dev_x_q <= `MEM_DEV_X;
`endif

  always @(posedge `MEM_DEV_CLK) begin
    int c, ch, k;
    if (dev_oe && dev_bk > 0) dev_bk <= dev_bk - 1;   // next beat of the burst
    else dev_oe <= 1'b0;
    for (int i = 0; i < DEV_NQ; i++)
      if (dev_v[i]) begin
        if (dev_cnt[i] == 0) begin
          dev_oe <= 1'b1; dev_word <= dev_rw[i]; dev_lane <= dev_rl[i]; dev_v[i] = 1'b0;
          dev_bk <= `MEM_DEV_BEATS - 1;
        end else dev_cnt[i]--;
      end
    if (`MEM_DEV_ON !== 1'b1) begin
      for (int i = 0; i < DEV_NQ; i++) dev_v[i] = 1'b0;
    end else begin
      c  = cellof(dev_ta_q) % DEV_NCELL;
      ch = `MEM_DEV_CH(dev_ta_q);
      if (`MEM_DEV_WR) begin
        dev_arr[c][`MEM_DEV_W-1:0] = (dev_arr[c][`MEM_DEV_W-1:0] & ~(`MEM_DEV_WMASK)) |
                                     (dev_dq_q[`MEM_DEV_W*ch +: `MEM_DEV_W] & (`MEM_DEV_WMASK));
`ifdef MEM_DEV_X
        dev_arr[c][`MEM_DEV_W +: DEV_XW] = dev_x_q[DEV_XW*ch +: DEV_XW];
`endif
      end
      if (`MEM_DEV_RD) begin
        if (`MEM_DEV_CL - `MEM_DEV_BEATS <= 0) begin
          dev_oe <= 1'b1; dev_word <= dev_arr[c]; dev_lane <= ch; dev_bk <= `MEM_DEV_BEATS - 1;
        end else begin
          k = 0;
          while (k < DEV_NQ && dev_v[k]) k++;
          if (k < DEV_NQ) begin
            dev_v[k] = 1'b1; dev_cnt[k] = `MEM_DEV_CL - `MEM_DEV_BEATS - 1; dev_rl[k] = ch; dev_rw[k] = dev_arr[c];
          end
        end
      end
    end
    dev_dq_q <= `MEM_DEV_DQ;
    dev_ta_q <= `MEM_DEV_TA;
  end
