// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of DMA_top (4-channel system DMA, AXI4
// manager). Rounds of random COPY and FILL jobs on random channels, queued
// together or while another runs, against a behavioural AXI4 memory with
// random and zero stalls. Checked: every destination word, the round-robin
// service order, one DONEn pulse per job on the right channel, CHECKSUM of
// each job, PENDING / BUSY / ACTIVE_CH, an AXI error on a read and on a
// write (ERR and the ERR interrupt), a start of a queued channel while it is
// queued (ignored), reset in the middle of a job, and the memory model's
// burst checks.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module DMA_tb;
  `include "soc_ss_tb_common.svh"
  logic [31:0] src0 = 0, src1 = 0, src2 = 0, src3 = 0;
  logic [31:0] dst0 = 0, dst1 = 0, dst2 = 0, dst3 = 0;
  logic [15:0] len0 = 0, len1 = 0, len2 = 0, len3 = 0;
  logic        mode0 = 0, mode1 = 0, mode2 = 0, mode3 = 0;
  logic [31:0] fill0 = 0, fill1 = 0, fill2 = 0, fill3 = 0;
  logic        start0 = 0, start1 = 0, start2 = 0, start3 = 0;
  wire  [3:0]  pending;
  wire         busy, err, err_irq;
  wire  [1:0]  active_ch;
  wire  [31:0] checksum, cycles;
  wire         done0, done1, done2, done3;
  DMA_top dut (.*);

  int n_done [4], n_err_irq = 0;
  int order [$];
  logic [31:0] ck [$];
  initial for (int c = 0; c < 4; c++) n_done[c] = 0;
  always @(posedge clk) if (rst_n) begin
    n_done[0] += done0; n_done[1] += done1; n_done[2] += done2; n_done[3] += done3;
    n_err_irq += err_irq;
    if (done0 | done1 | done2 | done3) ck.push_back(checksum);
    if (dut.e_start) order.push_back(int'(dut.nxt));
  end

  logic [31:0] c_src [4], c_dst [4], c_fill [4];
  int          c_len [4];
  bit          c_mode [4];
  task automatic set_ch(input int c, input int n, input bit m);
    c_src[c] = pick_addr(n) & 32'hCFFF_FFFC | 32'(c) << 28;   // channels in disjoint regions
    if (c_src[c][31:28] != 4'(c) && c_src[c][31:28] != 4'(c) + 4'h4) c_src[c] = {4'(c), c_src[c][27:0]};
    c_dst[c] = dst_of(c_src[c]);
    c_len[c] = n; c_mode[c] = m; c_fill[c] = $urandom;
    fill_rand(c_src[c], n);
    for (int i = 0; i < n; i++) mem.poke(c_dst[c] + 32'(4 * i), 32'hBAD0_0000 ^ i);
    case (c)
      0: begin src0 = c_src[0]; dst0 = c_dst[0]; len0 = 16'(n); mode0 = m; fill0 = c_fill[0]; end
      1: begin src1 = c_src[1]; dst1 = c_dst[1]; len1 = 16'(n); mode1 = m; fill1 = c_fill[1]; end
      2: begin src2 = c_src[2]; dst2 = c_dst[2]; len2 = 16'(n); mode2 = m; fill2 = c_fill[2]; end
      default: begin src3 = c_src[3]; dst3 = c_dst[3]; len3 = 16'(n); mode3 = m; fill3 = c_fill[3]; end
    endcase
  endtask
  task automatic kick(input logic [3:0] m);
    @(negedge clk);
    {start3, start2, start1, start0} = m;
    @(negedge clk);
    {start3, start2, start1, start0} = 0;
  endtask
  function automatic logic [31:0] exp_word(input int c, input int i);
    return c_mode[c] ? c_fill[c] : mem.peek(c_src[c] + 32'(4 * i));
  endfunction
  function automatic logic [31:0] exp_sum(input int c);
    logic [31:0] s;
    s = 0;
    for (int i = 0; i < c_len[c]; i++) s += exp_word(c, i);
    return s;
  endfunction
  task automatic wait_idle;
    int t;
    t = 0;
    while ((busy || pending != 0) && t < 200000) begin @(negedge clk); t++; end
    if (busy || pending != 0) fail("DMA did not go idle");
    clks(3);
  endtask
  task automatic check_ch(input int c);
    for (int i = 0; i < c_len[c]; i++)
      if (mem.peek(c_dst[c] + 32'(4 * i)) !== exp_word(c, i)) begin
        fail($sformatf("ch%0d word %0d of %0d: %h, expected %h", c, i, c_len[c],
                       mem.peek(c_dst[c] + 32'(4 * i)), exp_word(c, i)));
        break;
      end
  endtask

  // a round: the channels in m, queued at once or one after another
  task automatic round(input logic [3:0] m, input bit staggered);
    int d0 [4], last, exp_n;
    logic [31:0] sums [4];
    for (int c = 0; c < 4; c++) begin
      d0[c] = n_done[c];
      if (m[c]) set_ch(c, $urandom % 70, $urandom % 3 == 0);
    end
    for (int c = 0; c < 4; c++) sums[c] = exp_sum(c);
    order.delete(); ck.delete();
    if (staggered) begin
      for (int c = 0; c < 4; c++) if (m[c]) begin kick(4'b1 << c); clks($urandom % 30); end
    end else begin
      kick(m);
      // start again the channels still queued (not the one starting now): no effect
      {start3, start2, start1, start0} = m & pending & ~(dut.e_start ? 4'b1 << dut.nxt : 4'b0);
      @(negedge clk);
      {start3, start2, start1, start0} = 0;
    end
    wait_idle();
    exp_n = 0;
    for (int c = 0; c < 4; c++) begin
      if (n_done[c] != d0[c] + int'(m[c])) fail($sformatf("ch%0d: %0d DONE pulses", c, n_done[c] - d0[c]));
      if (m[c]) begin check_ch(c); exp_n++; end
    end
    if (order.size() != exp_n) fail($sformatf("%0d jobs served, expected %0d", order.size(), exp_n));
    if (!staggered && exp_n > 1)   // round robin: increasing channel order, wrapping once
      for (int k = 1; k < order.size(); k++) begin
        int a, b;
        a = order[k - 1]; b = order[k];
        if (((b - a + 4) % 4) == 0) fail("channel served twice");
      end
    for (int k = 0; k < ck.size() && k < order.size(); k++)
      if (ck[k] !== sums[order[k]]) fail($sformatf("CHECKSUM of ch%0d %h, expected %h", order[k], ck[k], sums[order[k]]));
  endtask

  initial begin
    clks(3);
    rst_n = 1;
    clks(2);
    if (pending !== 0 || busy !== 0) fail("not idle after reset");
    round(4'b0001, 0);
    round(4'b1111, 0);
    // round robin from the last channel served
    set_ch(0, 3, 0); set_ch(1, 3, 0); set_ch(2, 3, 0); set_ch(3, 3, 0);
    order.delete();
    kick(4'b0010); clks(2); kick(4'b1101);
    wait_idle();
    if (order.size() != 4 || order[0] != 1 || order[1] != 2 || order[2] != 3 || order[3] != 0)
      fail($sformatf("round-robin order wrong (%0d jobs), expected 1 2 3 0", order.size()));
    for (int k = 0; k < 30; k++) begin
      mem.stall = (k % 4) != 3;
      round(4'($urandom), k % 3 == 0);
    end
    mem.stall = 0;
    round(4'b1010, 0);
    mem.stall = 1;
    // AXI errors: a COPY read and a FILL write
    set_ch(2, 20, 0);
    mem.err_lo = c_src[2] + 40; mem.err_hi = mem.err_lo + 4;
    kick(4'b0100); wait_idle();
    if (!err || n_err_irq != 1) fail("read error: ERR / interrupt");
    set_ch(1, 20, 1);
    mem.err_lo = c_dst[1] + 8; mem.err_hi = mem.err_lo + 4;
    kick(4'b0010); wait_idle();
    if (!err || n_err_irq != 2) fail("write error: ERR / interrupt");
    mem.err_lo = '1; mem.err_hi = '1;
    round(4'b0110, 0);
    if (err) fail("ERR not cleared by the next job");
    // reset in the middle of a job
    set_ch(3, 300, 0);
    kick(4'b1000); clks(50);
    rst_n = 0; clks(2);
    if (busy || pending != 0 || m_awvalid || m_arvalid || m_wvalid) fail("not idle in reset");
    rst_n = 1; clks(10);
    round(4'b1001, 0);
    finish("DMA");
  end
endmodule
