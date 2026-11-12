// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of I2S_DMA_top (I2S_top + AXI4 DMA).
// An I2S master model (BCLK = 8 clocks, 16-bit slots, Philips timing) sends
// a random stereo sample on SDIN every frame and decodes SDOUT. Jobs of TX,
// RX and TX + RX of 1 to 70 frames run against the behavioural AXI4 memory;
// each job starts just after a frame start, so word k of a TX job must play
// in frame F+1+k and RX word k must hold frame F+1+k (F: the frame running at
// START). With AXI reads or writes held off for 40 frames the TB checks the
// underrun / overrun behaviour: TX repeats the previous frame, RX keeps the
// newest frame, and TX_UNDERRUN / RX_OVERRUN count exactly the frames
// repeated / lost. Also: an AXI error response sets ERR and the ERR
// interrupt, DONE pulses once per job, FRAMES. A latency line per job
// ("LAT I2S_DMA axi R|W <cycles>", first request to last response, from
// the memory side) feeds the regression suite's lat_db.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module I2S_DMA_tb;
  `include "soc_ss_tb_common.svh"
  logic        bclk = 0, lrck = 0, sdin = 0;
  wire         sdout;
  logic [31:0] src_addr = 0, dst_addr = 0;
  logic [15:0] xfer_len = 0;
  logic        tx_en = 0, rx_en = 0, start = 0;
  wire         busy, err, done, err_irq;
  wire  [15:0] frames, tx_underrun, rx_overrun;
  wire  [31:0] cycles;
  I2S_DMA_top dut (.*);

  int n_done = 0, n_err_irq = 0;
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; end

  // ---------------------------------------------------------------- master
  localparam int NF = 8192;
  logic [31:0] rx_smp [NF];               // {right, left} sent in frame f
  logic [31:0] tx_got [NF];               // {right, left} decoded from frame f
  int          fall_n = 0;                // falls so far; frame f starts at fall 32f
  logic [15:0] shreg;
  initial for (int f = 0; f < NF; f++) rx_smp[f] = $urandom;
  initial begin
    @(posedge rst_n);
    forever begin
      repeat (4) @(posedge clk); #1 bclk = 1;
      // the bit driven at the last fall is sampled at this rise
      if (fall_n >= 1) begin
        int s, b;
        s = (fall_n - 1) / 16; b = 15 - (fall_n - 1) % 16;
        if (s / 2 < NF) begin
          if (s % 2) tx_got[s / 2][16 + b] = sdout; else tx_got[s / 2][b] = sdout;
        end
      end
      repeat (4) @(posedge clk); #1 bclk = 0;
      fall_n++;
      if (fall_n % 16 == 0) lrck = (fall_n / 16) % 2;
      begin
        int s, b;
        s = (fall_n - 1) / 16; b = 15 - (fall_n - 1) % 16;
        if (s / 2 < NF) sdin = (s % 2) ? rx_smp[s / 2][16 + b] : rx_smp[s / 2][b];
      end
    end
  end
  function automatic int cur_frame; return fall_n / 32; endfunction
  task automatic wait_frame(input int f); while (fall_n < 32 * f) @(negedge clk); endtask

  // --------------------------------------------------------- AXI latency
  int t_ar = -1, t_aw = -1, lat_r_max = 0, lat_w_max = 0;
  always @(posedge clk) if (rst_n) begin
    if (m_arvalid && m_arready && t_ar < 0) t_ar = $time / 10;
    if (m_rvalid && m_rready && m_rlast && t_ar >= 0) begin
      $display("LAT I2S_DMA axi R %0d", $time / 10 - t_ar);
      if ($time / 10 - t_ar > lat_r_max) lat_r_max = $time / 10 - t_ar;
      t_ar = -1;
    end
    if (m_awvalid && m_awready && t_aw < 0) t_aw = $time / 10;
    if (m_bvalid && m_bready && t_aw >= 0) begin
      $display("LAT I2S_DMA axi W %0d", $time / 10 - t_aw);
      if ($time / 10 - t_aw > lat_w_max) lat_w_max = $time / 10 - t_aw;
      t_aw = -1;
    end
  end

  // hold: 1 = AR, 2 = AW off for 40 frames from the job start
  task automatic run(input int n, input bit tx, input bit rx, input int hold, input int inject);
    logic [31:0] s, d;
    int f0, nd0, ne0, t, i, rep, lost;
    logic [31:0] prev;
    s = pick_addr(n); d = dst_of(s);
    fill_rand(s, n);
    for (int k = 0; k < n; k++) mem.poke(d + 32'(4 * k), 32'hBAD0_0000 ^ k);
    if (inject == 1) begin mem.err_lo = s + 32'(4 * (n / 2)); mem.err_hi = mem.err_lo + 4; end
    if (inject == 2) begin mem.err_lo = d + 32'(4 * (n / 2)); mem.err_hi = mem.err_lo + 4; end
    // start two BCLK periods after the start of frame f0 (F in the header)
    f0 = cur_frame() + 1;
    while (fall_n != 32 * f0 + 2) @(negedge clk);
    src_addr = s; dst_addr = d; xfer_len = 16'(n); tx_en = tx; rx_en = rx;
    nd0 = n_done; ne0 = n_err_irq;
    start = 1; @(negedge clk); start = 0;
    // the memory model only answers a request it sees, so hiding ARVALID /
    // AWVALID from it holds the channel off
    if (hold == 1) force m_arvalid = 1'b0;
    if (hold == 2) force m_awvalid = 1'b0;
    if (hold != 0) begin wait_frame(f0 + 40); release m_arvalid; release m_awvalid; end
    t = 0;
    while (busy && t < 2000000) begin @(negedge clk); t++; end
    if (busy) fail("job timed out");
    // let the last TX frames play out
    wait_frame(cur_frame() + 3);
    clks(2);
    if (n_done != nd0 + 1) fail($sformatf("%0d DONE pulses for one job", n_done - nd0));
    if (err !== (inject != 0)) fail($sformatf("ERR = %b, inject %0d", err, inject));
    if (n_err_irq != ne0 + (inject != 0)) fail("ERR interrupt count");
    mem.err_lo = '1; mem.err_hi = '1;
    if (inject != 0) return;
    if (frames !== 16'(n)) fail($sformatf("FRAMES %0d, expected %0d", frames, n));
    // TX: frames from F+1 play word 0, 1, ... in order; a frame that is not
    // the next word repeats the previous frame (an underrun)
    if (tx) begin
      i = 0; rep = 0; prev = tx_got[f0];
      for (int f = f0 + 1; i < n && f < cur_frame() - 1; f++) begin
        if (tx_got[f] === mem.peek(s + 32'(4 * i))) i++;
        else if (tx_got[f] === prev) rep++;
        else begin fail($sformatf("TX frame %0d: %h, expected word %0d %h", f, tx_got[f], i, mem.peek(s + 32'(4 * i)))); break; end
        prev = tx_got[f];
      end
      if (i != n) fail($sformatf("TX played %0d of %0d words", i, n));
      if (rep != tx_underrun) fail($sformatf("TX repeated %0d frames, TX_UNDERRUN %0d", rep, tx_underrun));
      if (hold == 1 && rep == 0) fail("no underrun with AXI reads held off");
      if (hold != 1 && rep != 0) fail($sformatf("%0d underruns without a hold", rep));
    end
    // RX: word k holds a frame after word k-1's, the first at F+1 or later
    if (rx) begin
      int f;
      f = f0 + 1; lost = 0;
      for (int k = 0; k < n; k++) begin
        logic [31:0] w;
        w = mem.peek(d + 32'(4 * k));
        while (f < NF && rx_smp[f] !== w && f < cur_frame()) begin f++; lost++; end
        if (rx_smp[f] !== w) begin fail($sformatf("RX word %0d %h is no later frame", k, w)); break; end
        f++;
      end
      if (lost != rx_overrun) fail($sformatf("RX lost %0d frames, RX_OVERRUN %0d", lost, rx_overrun));
      if (hold == 2 && lost == 0) fail("no overrun with AXI writes held off");
      if (hold != 2 && lost != 0) fail($sformatf("%0d frames lost without a hold", lost));
    end
    if (!rx && mem.peek(d) !== 32'hBAD0_0000) fail("TX-only job wrote the destination");
  endtask

  initial begin
    clks(3);
    rst_n = 1;
    clks(2);
    run(1, 1, 0, 0, 0);
    run(1, 0, 1, 0, 0);
    run(16, 1, 1, 0, 0);
    for (int k = 0; k < 12; k++) begin
      mem.stall = (k % 4) != 3;
      run(1 + $urandom % 70, 1, 0, 0, 0);
      run(1 + $urandom % 70, 0, 1, 0, 0);
      run(1 + $urandom % 70, 1, 1, 0, 0);
    end
    mem.stall = 1;
    run(60, 1, 0, 1, 0);      // underrun
    run(60, 0, 1, 2, 0);      // overrun
    run(70, 1, 1, 2, 0);
    run(20, 1, 0, 0, 1);      // AXI errors
    run(20, 0, 1, 0, 2);
    run(8, 1, 1, 0, 0);
    $display("max AXI latency: R %0d W %0d cycles", lat_r_max, lat_w_max);
    finish("I2S_DMA");
  end
  initial begin #200ms; fail("timeout"); $display("TEST FAILED: timeout"); $finish; end
endmodule
