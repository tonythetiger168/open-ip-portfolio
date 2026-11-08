// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of Audio_DSP_top (phone SoC subsystem, AXI4 manager).
// Random jobs of 0 to 600 words at random buffers (low memory, the top of the
// address space, across 4 KB boundaries) against a behavioural AXI4 memory
// with random and zero stalls; every output word and result register is
// compared with a reference model of the datapath (Q8.8 gain with saturation, mono downmix, mute, peak and clip meters). Also: START while
// busy is ignored, AXI error responses on a read and on a write set ERR and
// the ERR interrupt, DONE pulses once per job. The memory model checks every
// burst (size, INCR, WLAST, 4 KB, at most 16 beats).
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module Audio_DSP_tb;
  `include "soc_ss_tb_common.svh"
  logic [31:0] src_addr = 0, dst_addr = 0;
  logic [15:0] xfer_len = 0;
  logic        start = 0;
  wire         busy, err, done, err_irq;
  wire  [31:0] cycles;
  logic [15:0] gain_l = 256, gain_r = 256;
  logic        mix = 0, mute = 0;
  wire  [15:0] peak, clips;
  int          exp_pk, exp_cl;
  Audio_DSP_top dut (.*);

  int n_done = 0, n_err_irq = 0;
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; end

  logic [31:0] expw [];
  function automatic void model(input logic [31:0] s, input int n);
    expw = new[n];
    exp_pk = 0; exp_cl = 0;
    for (int i = 0; i < n; i++) begin
      logic [31:0] x;
      int in [2], g [2], m;
      longint p;
 int y;
      logic [31:0] o;
      x = mem.peek(s + 32'(4 * i));
      m = (int'(signed'(x[15:0])) + int'(signed'(x[31:16]))) >>> 1;
      in[0] = mix ? m : int'(signed'(x[15:0]));
      in[1] = mix ? m : int'(signed'(x[31:16]));
      g[0] = int'(signed'(gain_l)); g[1] = int'(signed'(gain_r));
      for (int c = 0; c < 2; c++) begin
        p = (longint'(in[c]) * longint'(g[c])) >>> 8;
        if (mute) y = 0;
        else if (p > 32767) begin y = 32767; exp_cl++; end
        else if (p < -32768) begin y = -32768; exp_cl++; end
        else y = int'(p);
        o[16*c +: 16] = 16'(y);
        if ((y < 0 ? -y : y) > exp_pk) exp_pk = (y < 0 ? -y : y);
      end
      expw[i] = o;
    end
  endfunction

  // one job of n words; inject: 1 = read error, 2 = write error at word n/2
  task automatic run(input int n, input int inject, input bit restart);
    logic [31:0] s, d;
    int t, nd0, ne0, nbad;
    bit rd, wr;
    s = pick_addr(n); d = dst_of(s);
    fill_rand(s, n);
    for (int i = 0; i < n; i++) mem.poke(d + 32'(4 * i), 32'hBAD0_0000 ^ i);
    @(negedge clk);
    src_addr = s; dst_addr = d; xfer_len = 16'(n);
    gain_l = ($urandom % 3 == 0) ? 16'd256 : 16'($urandom); gain_r = ($urandom % 3 == 0) ? 16'd256 : 16'($urandom);
    mix = $urandom; mute = ($urandom % 8 == 0);
    rd = 1; wr = 1;
    if (inject == 1 && !rd) inject = 2;
    if (inject == 2 && !wr) inject = 1;
    model(s, n);
    if (inject != 0 && n != 0) begin
      mem.err_lo = (inject == 1 ? s : d) + 32'(4 * (n / 2));
      mem.err_hi = mem.err_lo + 4;
    end
    nd0 = n_done; ne0 = n_err_irq;
    start = 1;
    @(negedge clk);
    start = 0;
    if (!busy && n != 0) fail("busy low after start");
    if (restart) begin
      clks(2);
      start = 1;
      @(negedge clk);
      start = 0;
    end
    t = 0;
    while (busy && t < 100000) begin @(negedge clk); t++; end
    if (busy) fail($sformatf("job of %0d words timed out (rstate %0d wstate %0d)", n, dut.u_eng.rstate, dut.u_eng.wstate));
    clks(2);
    if (n_done != nd0 + 1) fail($sformatf("%0d DONE pulses for one job", n_done - nd0));
    if (err !== (inject != 0 && n != 0)) fail($sformatf("ERR = %b, inject %0d", err, inject));
    if (n_err_irq != ne0 + (inject != 0 && n != 0 ? 1 : 0)) fail("ERR interrupt count");
    if (cycles == 0 && n != 0) fail("CYCLES = 0");
    mem.err_lo = '1; mem.err_hi = '1;
    if (inject != 0) return;
    nbad = 0;
    if (wr)
      for (int i = 0; i < n; i++)
        if (mem.peek(d + 32'(4 * i)) !== expw[i]) begin
          if (nbad++ < 5) fail($sformatf("word %0d of %0d at %h: %h, expected %h", i, n, d + 32'(4 * i),
                                         mem.peek(d + 32'(4 * i)), expw[i]));
        end
    if (!wr && mem.peek(d) !== 32'hBAD0_0000 && n != 0) fail("read-only job wrote the destination");
    if (peak !== 16'(exp_pk)) fail($sformatf("PEAK %0d, expected %0d", peak, exp_pk));
    if (clips !== 16'(exp_cl)) fail($sformatf("CLIPS %0d, expected %0d", clips, exp_cl));
  endtask

  initial begin
    clks(3);
    rst_n = 1;
    clks(2);
    run(0, 0, 0);
    run(1, 0, 0);
    run(16, 0, 0);
    run(17, 0, 1);
    for (int k = 0; k < 40; k++) begin
      mem.stall = (k % 4) != 3;
      run(1 + $urandom % 80, 0, k % 7 == 0);
    end
    mem.stall = 1;
    run(600, 0, 0);
    mem.stall = 0;
    run(300, 0, 0);
    mem.stall = 1;
    for (int k = 0; k < 6; k++) run(5 + $urandom % 40, 1 + k % 2, 0);
    run(33, 0, 0);
    // reset in the middle of a job: the core and the bus go idle
    @(negedge clk);
    src_addr = 32'h0000_2000; dst_addr = 32'h4000_2000; xfer_len = 200;
    start = 1; @(negedge clk); start = 0;
    clks(40);
    rst_n = 0; clks(2);
    if (busy || m_awvalid || m_arvalid || m_wvalid) fail("not idle in reset");
    rst_n = 1; clks(10);
    run(20, 0, 0);
    finish("Audio_DSP");
  end
endmodule
