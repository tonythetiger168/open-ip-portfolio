// SPDX-License-Identifier: Apache-2.0
// Avalon-MM burst slave: concurrent SVA against an independent transfer
// model (wait states, read bubbles, zero-data out-of-range beats, regfile
// shadow with byteenable merge) + functional coverage.
`include "cov_macros.svh"
module Avalon_MM_sva #(parameter int DW = 32, AW = 32) (
  input logic          clk, rst_n,
  input logic [AW-1:0] av_address,
  input logic          av_read, av_write,
  input logic [DW-1:0] av_writedata, av_readdata,
  input logic [3:0]    av_byteenable,
  input logic [7:0]    av_burstcount,
  input logic          av_readdatavalid, av_waitrequest, irq
);
  `COV_CLOCKING(clk, !rst_n)
  typedef enum logic [1:0] {M_IDLE, M_WRB, M_RDD} mst_t;
  function automatic logic valid_a(input logic [32:0] a); return a < 33'h400; endfunction
  function automatic logic slow_a(input logic [32:0] a); return a >= 33'h200 && a < 33'h400; endfunction
  wire        cmd   = av_read || av_write;
  wire [32:0] cmd_a = {1'b0, av_address};
  wire [4:0]  beats = (av_burstcount == 0) ? 5'd1 : (av_burstcount > 16) ? 5'd16 : av_burstcount[4:0];

  // ---------------- independent reference model ----------------
  logic [DW-1:0] shadow [0:255];      // regfile is not reset
  initial for (int i = 0; i < 256; i++) shadow[i] = '0;
  mst_t        m_st;
  logic [32:0] m_a;
  logic [4:0]  m_left;
  logic        m_ws, m_gap;
  wire cmd_acc  = m_st == M_IDLE && cmd && !av_waitrequest;
  wire beat_acc = m_st == M_WRB && av_write && !av_waitrequest;
  task automatic wr_word(input logic [32:0] a);
    if (valid_a(a))
      for (int b = 0; b < 4; b++)
        if (av_byteenable[b]) shadow[a[9:2]][8*b +: 8] <= av_writedata[8*b +: 8];
  endtask
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_st <= M_IDLE; m_a <= '0; m_left <= 0; m_ws <= 0; m_gap <= 0;
    end else begin
      m_ws <= (m_st != M_RDD) && av_waitrequest;
      case (m_st)
        M_IDLE: if (cmd_acc) begin
          if (av_write) begin
            wr_word(cmd_a);
            if (beats > 1) begin m_a <= cmd_a + 4; m_left <= beats - 1; m_st <= M_WRB; end
          end else begin
            m_a <= cmd_a; m_left <= beats; m_gap <= 0; m_st <= M_RDD;
          end
        end
        M_WRB: if (beat_acc) begin
          wr_word(m_a);
          m_a <= m_a + 4; m_left <= m_left - 1;
          if (m_left == 1) m_st <= M_IDLE;
        end
        M_RDD: if (slow_a(m_a) && !m_gap) m_gap <= 1;
          else begin
            m_gap <= 0; m_a <= m_a + 4; m_left <= m_left - 1;
            if (m_left == 1) m_st <= M_IDLE;
          end
        default: ;
      endcase
    end
  end
  wire rd_beat = m_st == M_RDD && !(slow_a(m_a) && !m_gap);
  wire err_evt = (cmd_acc && ((av_read && av_write) || av_burstcount > 16 ||
                              (av_write && !valid_a(cmd_a)))) ||
                 (beat_acc && !valid_a(m_a)) ||
                 (rd_beat && !valid_a(m_a));

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_quiet, !rst_n, !av_readdatavalid && !irq)
  `SVA_IMP(a_rdd_blocks, m_st == M_RDD, av_waitrequest)
  `SVA_IMP(a_fast_cmd_no_wait, m_st == M_IDLE && cmd && !slow_a(cmd_a), !av_waitrequest)
  `SVA_IMP(a_slow_cmd_waits, m_st == M_IDLE && cmd && slow_a(cmd_a) && !m_ws, av_waitrequest)
  `SVA_IMP(a_slow_cmd_one_wait, m_st == M_IDLE && cmd && m_ws, !av_waitrequest)
  `SVA_IMP(a_fast_beat_no_wait, m_st == M_WRB && av_write && !slow_a(m_a), !av_waitrequest)
  `SVA_IMP(a_slow_beat_waits, m_st == M_WRB && av_write && slow_a(m_a) && !m_ws, av_waitrequest)
  `SVA_IMP(a_slow_beat_one_wait, m_st == M_WRB && av_write && m_ws, !av_waitrequest)
  `SVA_IMP(a_wrb_idle_no_wait, m_st == M_WRB && !av_write, !av_waitrequest)
  `SVA_IMP(a_idle_no_wait, m_st == M_IDLE && !cmd, !av_waitrequest)
  `SVA_IMP(a_rdv_model, 1'b1, av_readdatavalid == rd_beat)
  `SVA_IMP(a_rdata_model, rd_beat, av_readdata == (valid_a(m_a) ? shadow[m_a[9:2]] : '0))
  `SVA_NXT(a_irq_sticky, irq, irq)
  `SVA_NXT(a_irq_on_error, err_evt, irq)
  `SVA_IMP(a_irq_cause, $rose(irq), $past(err_evt))

  // ---------------- functional coverage ----------------
  covergroup cg_cmd @(posedge clk);
    option.per_instance = 1;
    cp_dir: coverpoint {av_read, av_write} iff (rst_n && cmd_acc)
      { bins rd = {2'b10}; bins wr = {2'b01}; bins both = {2'b11}; }
    cp_region: coverpoint {!valid_a(cmd_a), slow_a(cmd_a)} iff (rst_n && cmd_acc && !(av_read && av_write))
      { bins fast = {2'b00}; bins slow = {2'b01}; bins oor = {2'b10}; }
    cp_rw: coverpoint av_write iff (rst_n && cmd_acc && !(av_read && av_write))
      { bins rd = {0}; bins wr = {1}; }
    cp_burst: coverpoint av_burstcount iff (rst_n && cmd_acc)
      { bins zero = {0}; bins one = {1}; bins mid = {[2:15]}; bins max16 = {16}; bins over = {[17:255]}; }
    cp_be: coverpoint av_byteenable iff (rst_n && ((cmd_acc && av_write) || beat_acc))
      { bins full = {4'hF}; bins partial = {[1:14]}; bins none = {0}; }
    x_region_rw: cross cp_region, cp_rw;
  endgroup
  cg_cmd u_cg_cmd = new;

  `FC(slow_write_beat_wait, m_st == M_WRB && av_waitrequest)
  `FC(write_beat_gap, m_st == M_WRB && !av_write)
  `FC(read_bubble, m_st == M_RDD && !av_readdatavalid)
  `FC(read_runs_out_of_range, rd_beat && !valid_a(m_a) && m_left != beats)
  `FC(write_beat_dropped, beat_acc && !valid_a(m_a))
  `FC(burst_wraps_4gb, m_st != M_IDLE && m_a[32])
  `FC(cmd_held_during_read, m_st == M_RDD && cmd)
  `FC(misaligned_cmd, cmd_acc && av_address[1:0] != 0)
  `FC_RST(reset_mid_write_burst, rst_n && m_st == M_WRB ##1 !rst_n)
endmodule

bind Avalon_MM_top Avalon_MM_sva #(.DW(DW), .AW(AW)) u_sva (.*);
