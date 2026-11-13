// SPDX-License-Identifier: Apache-2.0
// DMA (4-channel system DMA on soc_ss_axi_engine): concurrent SVA against an
// independent model of the channel queue (START bits, round-robin choice
// from the last channel served), the job launched on the engine (the chosen
// channel's SRC / DST / LEN / MODE), the COPY / FILL datapath, CHECKSUM and
// the per-channel DONE pulses, fed by the channel pins and the engine's read
// stream, + functional coverage. The engine is closed by its own run.
`include "cov_macros.svh"
module DMA_sva (
  input logic         clk, rst_n,
  input logic [31:0]  src0, src1, src2, src3, dst0, dst1, dst2, dst3, fill0, fill1, fill2, fill3,
  input logic [15:0]  len0, len1, len2, len3,
  input logic         mode0, mode1, mode2, mode3, start0, start1, start2, start3,
  input logic [3:0]   pending,
  input logic         busy, err, err_irq, done0, done1, done2, done3,
  input logic [1:0]   active_ch,
  input logic [31:0]  checksum,
  input logic         e_start, e_done,
  input logic         rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0]  rs_data, ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  wire [3:0]  st = {start3, start2, start1, start0};
  wire [3:0]  md = {mode3, mode2, mode1, mode0};
  wire [31:0] sv [4] = '{src0, src1, src2, src3};
  wire [31:0] dv [4] = '{dst0, dst1, dst2, dst3};
  wire [31:0] fv [4] = '{fill0, fill1, fill2, fill3};
  wire [15:0] lv [4] = '{len0, len1, len2, len3};
  wire [3:0]  dn = {done3, done2, done1, done0};

  logic [3:0]  m_pend;
  logic [1:0]  m_ch;
  logic        m_run;
  logic [31:0] m_sum;
  logic [1:0]  m_nxt;
  always_comb begin
    m_nxt = m_ch;
    for (int k = 4; k >= 1; k--) if (m_pend[2'(m_ch + 2'(k))]) m_nxt = 2'(m_ch + 2'(k));
  end
  wire m_go = !m_run && m_pend != 0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_pend <= 0; m_ch <= 3; m_run <= 0; m_sum <= 0; end
    else begin
      if (m_go) begin m_ch <= m_nxt; m_run <= 1; m_sum <= 0; end
      else if (e_done) m_run <= 0;
      if (ws_valid && ws_ready) m_sum <= m_sum + ws_data;
      m_pend <= (m_pend | st) & ~(m_go ? 4'b1 << m_nxt : 4'b0);
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, pending == 0 && !busy && active_ch == 2'd3 && checksum == 0 && dn == 0)
  `SVA_INV(a_queue, pending == m_pend && busy == m_run && active_ch == m_ch && checksum == m_sum)
  `SVA_INV(a_engine_start, e_start == m_go)
  `SVA_IMP(a_engine_job, m_go, u_eng.src == sv[m_nxt] && u_eng.dst == dv[m_nxt] && u_eng.len == lv[m_nxt]
                               && u_eng.rd_en == !md[m_nxt] && u_eng.wr_en)
  `SVA_INV(a_ws_valid, ws_valid == (md[m_ch] ? m_run : rs_valid))
  `SVA_IMP(a_ws_data, ws_valid, ws_data == (md[m_ch] ? fv[m_ch] : rs_data))
  `SVA_INV(a_rs_ready, rs_ready == ws_ready)
  `SVA_INV(a_done, dn == (e_done ? 4'b1 << m_ch : 4'b0) && err_irq == (e_done && err))

  covergroup cg_dma @(posedge clk);
    option.per_instance = 1;
    cp_launch: coverpoint m_nxt iff (rst_n && m_go);
    cp_mode: coverpoint md[m_nxt] iff (rst_n && m_go);
    x_ch_mode: cross cp_launch, cp_mode;
    cp_queue: coverpoint m_pend iff (rst_n && m_go) { bins q[] = {[1:15]}; }
    cp_from: coverpoint m_ch iff (rst_n && m_go);
    x_from_to: cross cp_from, cp_launch;
    cp_len: coverpoint (lv[m_nxt] == 0 ? 2'd0 : lv[m_nxt] < 16 ? 2'd1 : lv[m_nxt] < 1024 ? 2'd2 : 2'd3) iff (rst_n && m_go)
      { bins zero = {0}; bins short_ = {1}; bins mid = {2}; bins long_ = {3}; }
    cp_end: coverpoint err iff (rst_n && e_done);
    cp_restart_queued: coverpoint (st & m_pend) != 0 iff (rst_n && st != 0);
  endgroup
  cg_dma u_cg_dma = new;

  `FC(start_while_running, m_run && st != 0)
  `FC(start_same_channel_at_launch, m_go && st[m_nxt])
  `FC(back_to_back_jobs, e_done ##1 m_go)
  `FC(fill_stall, m_run && md[m_ch] && !ws_ready)
  `FC(copy_stall, m_run && !md[m_ch] && rs_valid && !rs_ready)
  `FC_RST(reset_mid_job, rst_n && m_run ##1 !rst_n)
endmodule

bind DMA_top DMA_sva u_sva (.*);
