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
//   `MEM_DEV_DQ    the dq net (default dq), `MEM_DEV_TA the trace address
//                  (default trace_addr)
// Address: the controllers have no bank / channel pins, so, as the checkers
// in tb/cov do, the device takes the word's host address from the trace port,
// which carries it in the clock before the command. Write data is on dq in
// that same clock (the clock before the WR command).
// Timing: a RD seen at clock edge E is answered with the word on the
// channel's dq lanes from edge E + CL - 1 to edge E + CL, where the
// controller samples it.
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
`ifndef MEM_DEV_DQ
`define MEM_DEV_DQ dq
`endif
`ifndef MEM_DEV_TA
`define MEM_DEV_TA trace_addr
`endif

  localparam int DEV_NCELL = 1 << 16, DEV_NQ = 8;
  logic [`MEM_DEV_W-1:0]     dev_arr [0:DEV_NCELL-1];
  logic [NCH*`MEM_DEV_W-1:0] dev_dq_q;            // dq in the previous clock
  logic [31:0]               dev_ta_q;            // trace address in the previous clock
  logic                      dev_oe = 1'b0;
  logic [`MEM_DEV_W-1:0]     dev_word = '0;
  int                        dev_lane = 0;
  bit                        dev_v   [DEV_NQ];    // reads in flight
  int                        dev_cnt [DEV_NQ];
  int                        dev_rl  [DEV_NQ];
  logic [`MEM_DEV_W-1:0]     dev_rw  [DEV_NQ];
  initial begin
    for (int i = 0; i < DEV_NCELL; i++) dev_arr[i] = '0;
    for (int i = 0; i < DEV_NQ; i++) dev_v[i] = 1'b0;
  end

  for (genvar g = 0; g < NCH; g++) begin : g_dev_dq
    assign `MEM_DEV_DQ[`MEM_DEV_W*g +: `MEM_DEV_W] = (dev_oe && dev_lane == g) ? dev_word : {`MEM_DEV_W{1'bz}};
  end

  always @(posedge `MEM_DEV_CLK) begin
    int c, ch, k;
    dev_oe <= 1'b0;
    for (int i = 0; i < DEV_NQ; i++)
      if (dev_v[i]) begin
        if (dev_cnt[i] == 0) begin
          dev_oe <= 1'b1; dev_word <= dev_rw[i]; dev_lane <= dev_rl[i]; dev_v[i] = 1'b0;
        end else dev_cnt[i]--;
      end
    if (`MEM_DEV_ON !== 1'b1) begin
      for (int i = 0; i < DEV_NQ; i++) dev_v[i] = 1'b0;
    end else begin
      c  = cellof(dev_ta_q) % DEV_NCELL;
      ch = `MEM_DEV_CH(dev_ta_q);
      if (`MEM_DEV_WR) dev_arr[c] = dev_dq_q[`MEM_DEV_W*ch +: `MEM_DEV_W];
      if (`MEM_DEV_RD) begin
        if (`MEM_DEV_CL <= 1) begin
          dev_oe <= 1'b1; dev_word <= dev_arr[c]; dev_lane <= ch;
        end else begin
          k = 0;
          while (k < DEV_NQ && dev_v[k]) k++;
          if (k < DEV_NQ) begin
            dev_v[k] = 1'b1; dev_cnt[k] = `MEM_DEV_CL - 2; dev_rl[k] = ch; dev_rw[k] = dev_arr[c];
          end
        end
      end
    end
    dev_dq_q <= `MEM_DEV_DQ;
    dev_ta_q <= `MEM_DEV_TA;
  end
