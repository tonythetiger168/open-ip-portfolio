// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of IR_Receiver_top (TV SoC, AXI4 manager).
// An IR receiver model drives ir_in (active low) with NEC and RC5 frames
// whose every mark and space is randomly stretched or shortened by up to
// 15 %; each expected code word is checked against the ring in the AXI4
// memory model when its CODE interrupt fires. Covers: NEC standard and
// extended addresses, NEC repeat frames (also before any code), a bad
// inverted command byte, timings out of tolerance, truncated frames, RC5
// with both S2 values and the toggle bit, ring full (codes wait), code FIFO
// full (OVF_CNT), AXI write errors, ENABLE off, reset.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module IR_Receiver_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  logic        ir_in = 1;
  logic        enable = 0, mode = 0;
  logic [15:0] tick_div = 3;
  logic [31:0] ring_base = 32'h0040_0000;
  logic [15:0] ring_words = 5, rd_idx = 0;
  wire  [31:0] last;
  wire  [15:0] wr_idx, code_cnt, rx_err_cnt, ovf_cnt;
  wire         err, code, rx_err, err_irq;
  IR_Receiver_top dut (.*);

  // ---------------- checker ----------------
  logic [31:0] expq [$];
  int          m_idx = 0, n_code = 0, n_rx_err = 0, n_err_irq = 0, exp_err = 0, exp_ovf = 0;
  bit          auto_consume = 1;
  always @(posedge clk) if (rst_n) begin
    n_rx_err += rx_err; n_err_irq += err_irq;
    if (code) begin
      logic [31:0] e;
      n_code++;
      if (expq.size() == 0) fail("CODE without an expected code");
      else begin
        e = expq.pop_front();
        if (!err_irq && mem.peek(ring_base + 32'(4 * m_idx)) !== e)
          fail($sformatf("ring word %0d: %h, expected %h", m_idx, mem.peek(ring_base + 32'(4 * m_idx)), e));
      end
      m_idx = (m_idx + 1) % ring_words;
      if (auto_consume) rd_idx <= 16'(m_idx);
    end
  end

  // ---------------- IR source ----------------
  int jit = 15;
  task automatic hold(input bit m, input int ticks);
    int n;
    n = ticks * (tick_div + 1);
    n = n + (n * (int'($urandom % (2 * jit + 1)) - jit)) / 100;
    ir_in = !m;
    repeat (n) @(negedge clk);
  endtask
  task automatic gap; hold(0, 400 + $urandom % 200); endtask
  logic [31:0] last_code;
  bit          have_code = 0;
  task automatic nec(input logic [7:0] a, input logic [7:0] ah, input logic [7:0] c, input bit bad_inv);
    logic [31:0] d;
    d = {bad_inv ? c : ~c, c, ah, a};
    hold(1, 256); hold(0, 128);
    for (int i = 0; i < 32; i++) begin hold(1, 16); hold(0, d[i] ? 48 : 16); end
    if (enable && !mode) begin                     // expected before the code can arrive
      if (bad_inv) exp_err++;
      else begin last_code = {2'd0, 1'b0, 1'b0, 4'b0, ah, a, c}; have_code = 1; expq.push_back(last_code); end
    end
    hold(1, 16);
    gap();
  endtask
  task automatic nec_repeat;
    hold(1, 256); hold(0, 64);
    if (enable && !mode) begin
      if (!have_code) exp_err++;
      else expq.push_back({last_code[31:30], 1'b1, last_code[28:0]});
    end
    hold(1, 16);
    gap();
  endtask
  task automatic rc5(input bit s2, input bit t, input logic [4:0] a, input logic [5:0] c);
    logic [13:0] b;
    b = {1'b1, s2, t, a, c};
    // half-bit levels (1 = mark); the first half of S1 merges with the idle space
    if (enable && mode) expq.push_back({2'd1, 1'b0, t, 4'b0, 8'h00, 3'b0, a, 1'b0, ~s2, c});
    for (int k = 0; k < 14; k++) begin
      if (k != 0) hold(!b[13-k], 25);
      hold(b[13-k], 25);
    end
    gap(); gap();
  endtask

  task automatic drain(input string what);
    int t;
    t = 0;
    while (expq.size() != 0 && t < 20000) begin @(negedge clk); t++; end
    clks(10);
    if (expq.size() != 0) fail($sformatf("%s: %0d codes not written", what, expq.size()));
    if (n_rx_err != exp_err || rx_err_cnt !== 16'(exp_err)) fail($sformatf("%s: RX_ERR %0d/%0d, expected %0d", what, n_rx_err, rx_err_cnt, exp_err));
    if (code_cnt !== 16'(n_code)) fail($sformatf("%s: CODE_CNT %0d, CODE pulses %0d", what, code_cnt, n_code));
    if (ovf_cnt !== 16'(exp_ovf)) fail($sformatf("%s: OVF_CNT %0d, expected %0d", what, ovf_cnt, exp_ovf));
    if (wr_idx !== 16'(m_idx)) fail($sformatf("%s: WR_IDX %0d, expected %0d", what, wr_idx, m_idx));
  endtask

  initial begin
    lat_master = "ir";
    clks(3);
    rst_n = 1;
    clks(2);
    // disabled: ignored
    nec(8'h12, 8'hED, 8'h40, 0);
    if (mem.n_wr_bursts != 0 || code_cnt != 0) fail("decoded while disabled");
    enable = 1; mode = 0; clks(2);
    // NEC repeat before any code
    nec_repeat();
    drain("repeat first");
    // NEC codes and repeats
    for (int k = 0; k < 14; k++) begin
      logic [7:0] a;
      mem.stall = k % 3 != 2;
      a = $urandom;
      nec(a, (k % 2) ? ~a : 8'($urandom), $urandom, 0);
      if (k % 4 == 1) nec_repeat();
    end
    drain("NEC");
    // bad inverted command, out-of-tolerance timing, a truncated frame
    nec(8'h01, 8'hFE, 8'h22, 1);
    jit = 0;
    hold(1, 256); hold(0, 128); hold(1, 16); hold(0, 30); gap();   // 30 ticks: neither 16 nor 48
    exp_err++;
    hold(1, 256); hold(0, 128); for (int i = 0; i < 10; i++) begin hold(1, 16); hold(0, 16); end
    gap(); exp_err++;                                               // ends by the idle timeout
    hold(1, 256); hold(0, 90); gap(); exp_err++;                   // leader space neither 8T nor 4T
    jit = 15;
    drain("NEC errors");
    // RC5
    mode = 1; clks(2);
    for (int k = 0; k < 14; k++) rc5($urandom, k % 2, $urandom, $urandom);
    rc5(1, 0, 5'h1F, 6'h3F); rc5(0, 1, 5'h00, 6'h00);
    drain("RC5");
    // RC5 with a bad half-bit length
    jit = 0;
    hold(1, 25); hold(0, 25); hold(1, 37); gap(); gap(); exp_err++;
    jit = 15;
    drain("RC5 errors");
    // ring full: codes wait in the FIFO, then the FIFO overflows
    mode = 0; auto_consume = 0; clks(2);
    for (int k = 0; k < 14; k++) nec(8'(k), ~8'(k), 8'(k), 0);
    // ring (5) holds 4, FIFO 8 more, the rest are dropped
    clks(100);
    exp_ovf = 0;
    if (ovf_cnt == 0) fail("no OVF with the ring and FIFO full");
    exp_ovf = ovf_cnt;
    repeat (ovf_cnt) void'(expq.pop_back());
    auto_consume = 1; rd_idx = 16'(m_idx);
    drain("ring full");
    // AXI write error
    begin
      int ne0;
      ne0 = n_err_irq;
      mem.err_lo = ring_base + 32'(4 * m_idx); mem.err_hi = mem.err_lo + 4;
      nec(8'hA5, 8'h5A, 8'h11, 0);
      drain("axi error");
      if (n_err_irq != ne0 + 1 || !err) fail("ERR after an AXI error response");
      mem.err_lo = '1; mem.err_hi = '1;
    end
    // disable clears WR_IDX / ERR and the repeat history
    enable = 0; clks(3);
    if (wr_idx != 0 || err) fail("ENABLE 0 does not clear WR_IDX / ERR");
    m_idx = 0; rd_idx = 0; have_code = 0;
    enable = 1; clks(2);
    nec_repeat();
    nec(8'h33, 8'hCC, 8'h99, 0);
    drain("re-enable");
    // reset in the middle of a frame
    fork
      nec(8'h01, 8'hFE, 8'h02, 0);
      begin clks(1500); rst_n = 0; end
    join
    expq.delete();
    if (m_awvalid || m_wvalid) fail("not idle in reset");
    rst_n = 1; m_idx = 0; rd_idx = 0; n_code = 0; n_rx_err = 0; exp_err = 0; exp_ovf = 0; have_code = 0;
    clks(3);
    nec(8'h44, 8'hBB, 8'h55, 0);
    drain("after reset");
    lat_summary();
    finish("IR_Receiver");
  end
endmodule
