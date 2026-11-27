// SPDX-License-Identifier: Apache-2.0
// PAM3 line bursts of the GDDR7 DRAM model, next to tb/mem_dev.svh (which
// plays the words and the PAM2 lines; the TB keeps PAM3 lines out of its
// `MEM_DEV_RD / `MEM_DEV_WR). Included after mem_dev.svh. Needs `G7_RD /
// `G7_WR (a RD / WR on the command pins), `G7_CLK and `G7_CORE (the
// GDDR7_top instance: pam3, cl_now, cwl_now), the pins cs_n, act_n, ras_n,
// cas_n, we_n, addr, dq, dqx, dqs, cke and trace_addr, and MEM_LCELL.
`ifndef G7_CLK
`define G7_CLK clk
`endif
`ifndef G7_CORE
`define G7_CORE dut
`endif
  // ---- PAM3 line bursts (BL6): beat b = trits 16b..16b+15 of the line, pin j
  // carrying trit 16b + j as {dqx[j], dq[j]}; the device stores raw data
  // (dev_arr of tb/mem_dev.svh). Timing as the device's line bursts.
  function automatic logic [191:0] line_trits(input logic [31:0] a);
    logic [3:0] v;
    for (int i = 0; i < 32; i++) begin
      v = dev_arr[`MEM_LCELL(a, i / 4) % DEV_NCELL][4 * (i % 4) +: 4];
      line_trits[6*i +: 6] = {2'(v % 3), 2'((v % 9) / 3), 2'(v / 9)};
    end
  endfunction
  logic        p3_oe = 1'b0, p3_rv = 1'b0, p3_wv = 1'b0;
  int          p3_cnt, p3_k = 0, p3_ch = 0, p3_wcnt, p3_wk, p3_wch;
  logic [31:0] p3_wa, trace_q;
  logic [191:0] p3_t, p3_wt;
  logic [31:0] p3_sym;
  for (genvar g = 0; g < 2; g++) begin : g_p3
    for (genvar j = 0; j < 16; j++) begin : g_pin
      assign dq[16*g + j]  = (p3_oe && p3_ch == g) ? p3_sym[2*j]     : 1'bz;
      assign dqx[16*g + j] = (p3_oe && p3_ch == g) ? p3_sym[2*j + 1] : 1'bz;
    end
  end
  assign dqs = p3_oe ? {p3_k[0], ~p3_k[0]} : 2'bzz;   // s = beat[0], beat = p3_k - 1
  always @(posedge `G7_CLK) begin
    logic [3:0] v;
    if (p3_oe && p3_k == 6) p3_oe <= 1'b0;
    else if (p3_oe) begin p3_sym <= p3_t[32*p3_k +: 32]; p3_k <= p3_k + 1; end
    if (p3_rv) begin
      if (p3_cnt > 1) p3_cnt--;
      else begin p3_rv = 1'b0; p3_oe <= 1'b1; p3_sym <= p3_t[31:0]; p3_k <= 1; end
    end
    if (p3_wv && cke) begin
      if (p3_wcnt > 1) p3_wcnt--;
      else begin
        for (int j = 0; j < 16; j++) p3_wt[32*p3_wk + 2*j +: 2] = {dqx[16*p3_wch + j], dq[16*p3_wch + j]};
        p3_wk++;
        if (p3_wk == 6) begin
          p3_wv = 1'b0;
          for (int i = 0; i < 32; i++) begin
            v = 4'(9 * p3_wt[6*i +: 2] + 3 * p3_wt[6*i+2 +: 2] + p3_wt[6*i+4 +: 2]);
            dev_arr[`MEM_LCELL(p3_wa, i / 4) % DEV_NCELL][4 * (i % 4) +: 4] = v;
          end
        end
      end
    end
    if (cke !== 1'b1) begin p3_rv = 1'b0; p3_wv = 1'b0; end
    else if (addr[12] && `G7_CORE.pam3 && `G7_RD) begin
      p3_rv = 1'b1; p3_cnt = `G7_CORE.cl_now - 1; p3_ch = trace_q[8]; p3_t = line_trits(trace_q);
    end else if (addr[12] && `G7_CORE.pam3 && `G7_WR) begin
      p3_wv = 1'b1; p3_wcnt = `G7_CORE.cwl_now; p3_wk = 0; p3_wch = trace_q[8]; p3_wa = trace_q;
    end
    trace_q <= trace_addr;
  end
