// SPDX-License-Identifier: Apache-2.0
// CPU_Cluster (cache-line traffic generator on soc_ss_axi_engine):
// concurrent SVA against an independent model of the pattern generator, the
// CHECK comparator (MISMATCHES, FIRST_FAIL, the MISMATCH interrupt) and the
// stream steering of the three modes, fed by the configuration pins and the
// engine's read stream, + functional coverage. The engine is closed by its
// own run.
`include "cov_macros.svh"
module CPU_Cluster_sva (
  input logic        clk, rst_n, start, busy, done, err, err_irq, mis_irq,
  input logic [15:0] xfer_len, mismatches, first_fail,
  input logic [1:0]  mode,
  input logic [31:0] seed,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  `include "soc_ss_job_cov.svh"

  logic [1:0]  m_mode;
  logic [15:0] m_ri, m_wi, m_mis, m_ff;
  wire  [31:0] m_pat_w = seed ^ {~m_wi, m_wi};
  wire  [31:0] m_pat_r = seed ^ {~m_ri, m_ri};
  wire         m_rhs = rs_valid && rs_ready;
  wire         m_bad = m_mode == 2'd1 && m_rhs && rs_data != m_pat_r;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_mode <= 0; m_ri <= 0; m_wi <= 0; m_mis <= 0; m_ff <= 0; end
    else if (go) begin m_mode <= mode; m_ri <= 0; m_wi <= 0; m_mis <= 0; m_ff <= 0; end
    else begin
      if (ws_valid && ws_ready) m_wi <= m_wi + 1;
      if (m_rhs) m_ri <= m_ri + 1;
      if (m_bad) begin
        if (m_mis == 0) m_ff <= m_ri;
        if (m_mis != 16'hFFFF) m_mis <= m_mis + 1;
      end
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, mismatches == 0 && first_fail == 0 && !mis_irq && !err_irq)
  `SVA_INV(a_ws_valid, ws_valid == (m_mode == 2'd0 ? busy : m_mode == 2'd1 ? 1'b0 : rs_valid))
  `SVA_IMP(a_ws_data, ws_valid, ws_data == (m_mode == 2'd0 ? m_pat_w : rs_data))
  `SVA_INV(a_rs_ready, rs_ready == (m_mode == 2'd1 ? 1'b1 : ws_ready))
  `SVA_INV(a_mismatches, mismatches == m_mis && first_fail == m_ff)
  `SVA_INV(a_mis_irq, mis_irq == (done && m_mode == 2'd1 && m_mis != 0))

  covergroup cg_cpu @(posedge clk);
    option.per_instance = 1;
    cp_mode: coverpoint mode iff (rst_n && go);
    cp_len: coverpoint lcls(xfer_len) iff (rst_n && go)
      { bins zero = {0}; bins one = {1}; bins short_ = {2}; bins sixteen = {3}; bins mid = {4}; }
    x_mode_len: cross cp_mode, cp_len;
    cp_seed: coverpoint dcls(seed) iff (rst_n && go)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    // CHECK results: clean, one bad word, several, the first word bad
    cp_check_end: coverpoint (m_mis == 0 ? 2'd0 : m_mis == 1 ? 2'd1 : 2'd2) iff (rst_n && done && m_mode == 2'd1)
      { bins clean = {0}; bins one_bad = {1}; bins several = {2}; }
    cp_first_at0: coverpoint (m_ff == 0) iff (rst_n && done && m_mode == 2'd1 && m_mis != 0);
    cp_copy_data: coverpoint dcls(rs_data) iff (rst_n && m_rhs && m_mode[1])
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_cpu u_cg_cpu = new;

  `FC(mismatch_saturated, m_bad && m_mis == 16'hFFFE)
  `FC(write_pattern_stall, m_mode == 2'd0 && ws_valid && !ws_ready)
endmodule

bind CPU_Cluster_top CPU_Cluster_sva u_sva (.*);
