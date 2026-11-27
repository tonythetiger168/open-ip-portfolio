// SPDX-License-Identifier: Apache-2.0
// Behavioural DRAM device for the line-level controller TBs (*_Lite). The
// controllers keep no array: a WRITE's 8-beat burst goes out on dq CWL
// clocks after the WR command, and a READ's burst is driven by the DRAM on
// dq (with dqs) from CL clocks after the RD command. This block plays that
// DRAM from the pins: it decodes ACT / RD / WR on cs_n, act_n, ras_n, cas_n,
// we_n, keeps the open row of each bank from ACT (row on addr[8:0]) and
// takes the line from addr[6:4] of RD / WR.
//
// Included inside a TB module after the DUT pins are declared. Optional:
//   `LDEV_CLK   clock (default clk)
//   `LDEV_ON    device powered and clocked (default cke): low drops the
//               bursts in flight, the array keeps its data
//   `LDEV_CORE  the core instance (default dut): CL and CWL are taken from
//               its cl_now / cwl_now at each RD / WR. The controllers' MR
//               files are controller-side only and put no MRS on the pins,
//               so this stands for the device's mode registers set to match.
//   `LDEV_BANK  bank entry of the command on the pins (default ba)
//   localparam NBANK  bank entries
//   `LDEV_PAM3  GDDR7-style PAM3 bursts: with the pam3 pin high at the
//               command, a burst is BL6 of 16 2-bit symbols per beat (nibble
//               v = 9 t0 + 3 t1 + t2, symbol k of the line at bits 2k of the
//               192-bit symbol vector, 32 bits a beat); otherwise BL8 on
//               dq[15:0] with dq[31:16] high-Z
// The array starts zeroed.
`ifndef LDEV_CLK
`define LDEV_CLK clk
`endif
`ifndef LDEV_ON
`define LDEV_ON cke
`endif
`ifndef LDEV_CORE
`define LDEV_CORE dut
`endif
`ifndef LDEV_BANK
`define LDEV_BANK ba
`endif

  localparam int LDEV_DQW = $bits(dq);
  logic [127:0]        ldev_arr [NBANK*512*8];    // {bank, row, line} -> line
  int                  ldev_row [NBANK];          // open row of each bank
  initial begin
    for (int i = 0; i < NBANK * 512 * 8; i++) ldev_arr[i] = '0;
    for (int i = 0; i < NBANK; i++) ldev_row[i] = 0;
  end
  longint              ldev_now = 0;               // index of the clock that just ended
  bit                  ldev_rv = 0, ldev_wv = 0;   // read / write burst in flight
  bit                  ldev_rm, ldev_wm;           // their mode (PAM3)
  longint              ldev_rt0, ldev_wt0;         // clock of beat 0
  int                  ldev_widx;
  logic [127:0]        ldev_rline;
  logic [LDEV_DQW-1:0] ldev_wb [8];
  logic                ldev_oe = 1'b0, ldev_s = 1'b0;
  logic [LDEV_DQW-1:0] ldev_q = '0;
  assign dq  = ldev_oe ? ldev_q : {LDEV_DQW{1'bz}};
  assign dqs = ldev_oe ? {~ldev_s, ldev_s} : 2'bzz;

  function automatic int ldev_bl(input bit m);
`ifdef LDEV_PAM3
    return m ? 6 : 8;
`else
    return 8;
`endif
  endfunction
  function automatic logic [LDEV_DQW-1:0] ldev_beat(input logic [127:0] l, input int k, input bit m);
`ifdef LDEV_PAM3
    logic [191:0] t;
    for (int n = 0; n < 32; n++) begin
      int v;
      v = int'(l[4*n +: 4]);
      t[6*n +: 6] = {2'(v / 9), 2'((v / 3) % 3), 2'(v % 3)};
    end
    return m ? t[32*k +: 32] : {16'hzzzz, l[16*k +: 16]};
`else
    return l[16*k +: 16];
`endif
  endfunction
  function automatic logic [127:0] ldev_line(input bit m);
    logic [127:0] l;
`ifdef LDEV_PAM3
    if (m) begin
      logic [191:0] t;
      for (int k = 0; k < 6; k++) t[32*k +: 32] = ldev_wb[k];
      for (int n = 0; n < 32; n++)
        l[4*n +: 4] = 4'(9 * t[6*n+4 +: 2] + 3 * t[6*n+2 +: 2] + t[6*n +: 2]);
      return l;
    end
`endif
    for (int k = 0; k < 8; k++) l[16*k +: 16] = ldev_wb[k][15:0];
    return l;
  endfunction

  always @(posedge `LDEV_CLK) begin
    int b, k, idx;
    bit m;
    ldev_now++;
    if (`LDEV_ON !== 1'b1) begin
      ldev_rv = 0; ldev_wv = 0; ldev_oe <= 1'b0;
    end else begin
      // write burst: beat k on dq in clock wt0 + k
      if (ldev_wv && ldev_now >= ldev_wt0) begin
        k = int'(ldev_now - ldev_wt0);
        ldev_wb[k] = dq;
        if (k == ldev_bl(ldev_wm) - 1) begin
          ldev_arr[ldev_widx] = ldev_line(ldev_wm); ldev_wv = 0;
        end
      end
      // command on the pins in the clock that just ended
      if (cs_n === 1'b0) begin
        b = int'(`LDEV_BANK) % NBANK;
        idx = (b * 512 + ldev_row[b]) * 8 + int'(addr[6:4]);
`ifdef LDEV_PAM3
        m = pam3;
`else
        m = 0;
`endif
        if (act_n === 1'b0) ldev_row[b] = int'(addr[8:0]);
        else if ({ras_n, cas_n, we_n} === 3'b101) begin         // RD
          ldev_rv = 1; ldev_rm = m; ldev_rt0 = ldev_now + `LDEV_CORE.cl_now;
          ldev_rline = ldev_arr[idx];
        end else if ({ras_n, cas_n, we_n} === 3'b100) begin    // WR
          ldev_wv = 1; ldev_wm = m; ldev_wt0 = ldev_now + `LDEV_CORE.cwl_now; ldev_widx = idx;
        end
      end
      // read burst: beat k on dq (and a dqs edge) in clock rt0 + k
      if (ldev_rv && ldev_now + 1 >= ldev_rt0) begin
        k = int'(ldev_now + 1 - ldev_rt0);
        ldev_oe <= 1'b1; ldev_q <= ldev_beat(ldev_rline, k, ldev_rm); ldev_s <= k[0];
        if (k == ldev_bl(ldev_rm) - 1) ldev_rv = 0;
      end else ldev_oe <= 1'b0;
    end
  end
