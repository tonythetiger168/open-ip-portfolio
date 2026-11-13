// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of Display_Controller_top (phone SoC subsystem, AXI4 manager).
// Random jobs of 0 to 600 words at random buffers (low memory, the top of the
// address space, across 4 KB boundaries) against a behavioural AXI4 memory
// with random and zero stalls; every output word and result register is
// compared with a reference model of the datapath (scan-out order, hsync / vsync, CRC-32, underrun count with a stalling panel). Also: START while
// busy is ignored, AXI error responses on a read and on a write set ERR and
// the ERR interrupt, DONE pulses once per job. The memory model checks every
// burst (size, INCR, WLAST, 4 KB, at most 16 beats).
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module Display_Controller_tb;
  `include "soc_ss_tb_common.svh"
  logic [31:0] src_addr = 0, dst_addr = 0;   // dst_addr: unused (no writes)
  logic [15:0] xfer_len = 0;
  logic        start = 0;
  wire         busy, err, done, err_irq;
  wire  [31:0] cycles;
  logic [15:0] line_words = 0;
  logic        pix_ready = 0;
  wire         pix_valid, pix_hsync, pix_vsync;
  wire  [31:0] pix_data;
  wire  [31:0] frame_crc;
  wire  [15:0] underruns;
  logic [31:0] exp_crc;
  int          exp_under, pix_n, ready_pct = 100;
  logic [31:0] got [$];
  // panel model: ready with probability ready_pct; collects pixels, checks syncs
  always @(posedge clk) begin
    if (rst_n && pix_valid && pix_ready) begin
      got.push_back(pix_data);
      if (pix_vsync !== (got.size() == xfer_len)) fail($sformatf("vsync %b at pixel %0d", pix_vsync, got.size()));
      if (pix_hsync !== (line_words == 0 || got.size() % line_words == 0 || got.size() == xfer_len))
        fail($sformatf("hsync %b at pixel %0d", pix_hsync, got.size()));
    end
    if (rst_n && busy && pix_ready && !pix_valid && got.size() < xfer_len) exp_under++;
    #1 pix_ready = ($urandom % 100) < ready_pct;
  end
  bit starve = 0;      // 1: the panel is always ready
  int lw_force = -1;   // >= 0: LINE_WORDS of the next frames
  int short_lens[5] = '{0, 1, 7, 16, 40};
  int lw_cls[4] = '{0, 1, 5, 20};
  Display_Controller_top dut (.*);

  int n_done = 0, n_err_irq = 0;
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; end

  logic [31:0] expw [];
  function automatic logic [31:0] crc32(input logic [31:0] c, input logic [31:0] d);
    for (int b = 0; b < 4; b++) begin
      c ^= 32'(d[8*b +: 8]);
      for (int k = 0; k < 8; k++) c = c[0] ? (c >> 1) ^ 32'hEDB8_8320 : c >> 1;
    end
    return c;
  endfunction
  function automatic void model(input logic [31:0] s, input int n);
    logic [31:0] c;
    expw = new[n];
    c = 32'hFFFF_FFFF;
    for (int i = 0; i < n; i++) begin expw[i] = mem.peek(s + 32'(4 * i)); c = crc32(c, expw[i]); end
    exp_crc = ~c;
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
    src_addr = s | 32'($urandom % 4); dst_addr = d | 32'($urandom % 4); xfer_len = 16'(n);   // address bits 1:0 are ignored
    case ($urandom % 4)
      0: line_words = 16'd0;                  // one line: hsync on the last pixel only
      1: line_words = 16'd1;
      2: line_words = 16'(2 + $urandom % 14);
      default: line_words = 16'(16 + $urandom % 40);
    endcase
    if (lw_force >= 0) line_words = 16'(lw_force);
    ready_pct = (starve || $urandom % 2) ? 100 : 30 + $urandom % 70;
    got.delete(); exp_under = 0;
    rd = 1; wr = 0;
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
    while (busy && t < 2000000) begin @(negedge clk); t++; end
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
    if (got.size() != n) fail($sformatf("%0d pixels sent, expected %0d", got.size(), n));
    else for (int i = 0; i < n; i++) if (got[i] !== expw[i]) begin fail($sformatf("pixel %0d: %h, expected %h", i, got[i], expw[i])); break; end
    if (frame_crc !== exp_crc) fail($sformatf("FRAME_CRC %h, expected %h", frame_crc, exp_crc));
    if (underruns !== 16'(exp_under > 65535 ? 65535 : exp_under)) fail($sformatf("UNDERRUNS %0d, expected %0d", underruns, exp_under));   // saturating count
    if (n == 2 && mem.peek(s) == 32'h3433_3231 && mem.peek(s + 4) == 32'h3837_3635 && frame_crc !== 32'h9AE0_DAAF)
      fail("CRC-32 check value");
  endtask

  initial begin
    clks(3);
    rst_n = 1;
    clks(2);
    mem.rand_id = 1;   // the core ignores BID / RID
    run(0, 0, 0);
    run(1, 0, 0);
    run(16, 0, 0);
    run(17, 0, 1);
    // every line length class at the short frame lengths
    foreach (lw_cls[j]) begin
      lw_force = lw_cls[j];
      foreach (short_lens[i]) run(short_lens[i], 0, 0);
    end
    lw_force = -1;
    for (int k = 0; k < 40; k++) begin
      mem.stall = (k % 4) != 3;
      run(1 + $urandom % 80, 0, k % 7 == 0);
    end
    mem.stall = 1;
    // the write path blocked for a while: the write FIFO fills up and the
    // datapath stalls the read stream
    fork begin clks(30); mem.aw_hold = 1; clks(150); mem.aw_hold = 0; end join_none
    run(600, 0, 0);
    mem.stall = 0;
    run(300, 0, 0);
    mem.stall = 1;
    for (int k = 0; k < 6; k++) begin   // read / write side x EXOKAY, SLVERR, DECERR
      mem.err_resp = 2'(1 + k % 3);
      run(5 + $urandom % 40, 1 + k % 2, 0);
    end
    mem.err_resp = 2'b10;
    // long jobs: the upper bits of the length and of the counters
    mem.stall = 0;
    run(1500, 0, 0);
    lw_force = 65535;   // one line: the column count climbs to 65534
    run(65535, 0, 0);
    lw_force = -1;
    // the read path blocked for 70000 clocks with the panel ready: UNDERRUNS
    // saturates at 16'hFFFF
    fork begin clks(5); mem.ar_hold = 1; clks(70000); mem.ar_hold = 0; end join_none
    starve = 1;
    run(64, 0, 0);
    starve = 0;
    mem.stall = 1;
    run(33, 0, 0);
    // reset in the middle of a job: the core and the bus go idle
    @(negedge clk);
    got.delete(); line_words = 0;   // no stale pixels from the previous job
    src_addr = 32'h0000_2000; dst_addr = 32'h4000_2000; xfer_len = 200;
    got.delete();   // the panel model counts this job's pixels from 0
    start = 1; @(negedge clk); start = 0;
    clks(40);
    rst_n = 0; clks(2);
    if (busy || m_awvalid || m_arvalid || m_wvalid) fail("not idle in reset");
    rst_n = 1; clks(10);
    run(20, 0, 0);
    finish("Display_Controller");
  end
endmodule
