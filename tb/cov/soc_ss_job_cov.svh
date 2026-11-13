// SPDX-License-Identifier: Apache-2.0
// Shared part of the checkers of the SoC subsystem IPs built on
// soc_ss_axi_engine (one job at a time: START, BUSY, DONE, ERR, ERR_IRQ,
// XFER_LEN). Included inside the checker module, after `COV_CLOCKING. The
// engine itself is closed by its own run (units/soc_ss_axi_engine.mk); this
// part checks the IP's job-level pins and covers the job space. The checker
// connects to the IP's ports and to its internal stream signals (rs_*, ws_*:
// the engine's read and write streams) by name through the bind.
//
// Provides: go (a START that is taken: SOC_SS_GO, default START && !BUSY), dcls() (data class: zero, all ones,
// 0x55 / 0xAA, other), lcls() (length class), the assertions a_err_irq and
// a_busy_after_start, covergroup cg_soc_ss_job and the cover properties
// fc_back_to_back_jobs, fc_start_while_busy, fc_rs_stall (not for a
// write-only IP: `define SOC_SS_WRITE_ONLY), fc_ws_stall (not
// for a read-only IP: `define SOC_SS_READ_ONLY) and fc_reset_mid_job.
  wire s_start = start;      // (start is also a covergroup method name)
`ifndef SOC_SS_GO            // define it before the include when a START can be ignored
`define SOC_SS_GO (start && !busy)
`endif
  wire go = `SOC_SS_GO;
`undef SOC_SS_GO
  logic j_err_q;             // ERR of the job that just ended
  always_ff @(posedge clk) j_err_q <= err;

  function automatic logic [1:0] dcls(input logic [31:0] v);
    dcls = (v == 32'h0) ? 2'd0 : (v == 32'hFFFF_FFFF) ? 2'd1 :
           (v == 32'h5555_5555 || v == 32'hAAAA_AAAA) ? 2'd2 : 2'd3;
  endfunction
  function automatic logic [2:0] lcls(input logic [15:0] n);
    lcls = (n == 0) ? 3'd0 : (n == 1) ? 3'd1 : (n < 16) ? 3'd2 : (n == 16) ? 3'd3 :
           (n < 1024) ? 3'd4 : (n != 16'hFFFF) ? 3'd5 : 3'd6;
  endfunction

`ifndef SOC_SS_ERR_IRQ        // define it before the include when other errors raise ERR_IRQ too
`define SOC_SS_ERR_IRQ (done && err)
`endif
  `SVA_INV(a_err_irq, err_irq == `SOC_SS_ERR_IRQ)
`undef SOC_SS_ERR_IRQ
  `SVA_NXT(a_busy_after_start, go, busy)

  covergroup cg_soc_ss_job @(posedge clk);
    option.per_instance = 1;
    cp_len: coverpoint lcls(xfer_len) iff (rst_n && go)
      { bins zero = {0}; bins one = {1}; bins short_ = {2}; bins sixteen = {3};
        bins mid = {4}; bins long_ = {5}; bins max = {6}; }
    cp_start_busy: coverpoint busy iff (rst_n && s_start);
    cp_end: coverpoint err iff (rst_n && done);
  endgroup
  cg_soc_ss_job u_cg_soc_ss_job = new;

  `FC(back_to_back_jobs, done ##[1:8] go)
  `FC(start_while_busy, start && busy)
`ifndef SOC_SS_WRITE_ONLY  // define it before the include for an IP that never reads
  `FC(rs_stall, rs_valid && !rs_ready)
`endif
`ifndef SOC_SS_READ_ONLY   // define it before the include for an IP that never writes
  `FC(ws_stall, ws_valid && !ws_ready)
`endif
  `FC_RST(reset_mid_job, rst_n && busy ##1 !rst_n)
