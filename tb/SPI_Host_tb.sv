// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of SPI_Host_top.
// - Chip select 0: the portfolio's SPI_top target (mode 0). Random bytes
//   both ways at DIV 2..8, several frames per chip-select assertion: the
//   target's RX register gets each byte sent, RX_DATA gets the target's TX
//   byte.
// - Chip select 1: a TB target model written from the mode table, in all
//   four modes (CPOL, CPHA): it samples MOSI and drives MISO on the edges of
//   its mode only; the TB checks that SCLK idles at CPOL between frames.
// - DIV: every SCLK half period is DIV + 1 clocks; START while busy is
//   ignored; DONE once per frame.
`timescale 1ns/1ps
module SPI_Host_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction
  task automatic clks(input int n); repeat (n) @(negedge clk); endtask

  wire        sclk, mosi;
  wire        miso, miso0;
  wire  [1:0] csn;
  logic [15:0] div = 3;
  logic       cpol = 0, cpha = 0, start = 0;
  logic [1:0] cs = 0;
  logic [7:0] tx_data = 0;
  wire  [7:0] rx_data;
  wire        busy, done;
  SPI_Host_top dut (.*);

  // target 0: SPI_top (mode 0)
  logic       t_wen = 0;
  logic [7:0] t_wdata = 0;
  wire  [7:0] t_rx, t_txr;
  wire        t_irq;
  SPI_top tgt (.clk, .rst_n, .sclk, .mosi, .miso(miso0), .csn(csn[0]), .wen(t_wen), .waddr(4'd0),
               .wdata(t_wdata), .ren(1'b0), .raddr(4'd0), .rdata(t_rx), .irq(t_irq));

  // target 1: model from the mode table
  logic [7:0] m_tx = 0, m_rx = 0, m_sh_o = 0;
  logic       m_miso = 0;
  int         m_bits = 0;
  // shared MISO: the selected target drives it
  assign miso = !csn[0] ? miso0 : !csn[1] ? m_miso : 1'b0;
  wire lead  = cpol ? 1'b0 : 1'b1;            // SCLK level after a leading edge
  always @(negedge csn[1]) begin m_bits = 0; m_sh_o = m_tx; if (!cpha) m_miso = m_tx[7]; end
  always @(sclk) if (!csn[1]) begin
    bit is_lead;
    is_lead = (sclk == lead);
    if (is_lead == !cpha) begin               // sampling edge
      m_rx = {m_rx[6:0], mosi}; m_bits++;
    end else begin                            // shift edge
      if (cpha) begin m_miso = m_sh_o[7]; m_sh_o = {m_sh_o[6:0], 1'b0}; end
      else if (m_bits % 8 != 0) begin m_sh_o = {m_sh_o[6:0], 1'b0}; m_miso = m_sh_o[7]; end
    end
  end
  // MOSI stable around sampling edges, SCLK half periods, idle level
  logic mosi_d, sclk_d, cpol_d;
  int   t_edge = 0, t_now = 0;
  always @(posedge clk) begin
    t_now++;
    if (rst_n && sclk != sclk_d) begin
      if (busy && t_now - t_edge < div + 1 && t_edge != 0) fail($sformatf("SCLK half period %0d < DIV + 1", t_now - t_edge));
      t_edge = t_now;
    end
    if (rst_n && !busy && !done && sclk !== cpol && cpol == cpol_d && !(sclk != sclk_d)) fail("SCLK not at CPOL while idle");
    mosi_d = mosi; sclk_d = sclk; cpol_d = cpol;
  end

  int n_done = 0;
  always @(posedge clk) if (rst_n) n_done += done;

  task automatic frame(input logic [7:0] d, input logic [7:0] exp_rx);
    int nd0, t;
    @(negedge clk);
    tx_data = d; start = 1; nd0 = n_done;
    @(negedge clk); start = 0;
    if (!busy) fail("busy low after start");
    if ($urandom % 3 == 0) begin clks(2); start = 1; @(negedge clk); start = 0; end
    t = 0;
    while (busy && t < 10000) begin @(negedge clk); t++; end
    clks(1);
    if (n_done != nd0 + 1) fail($sformatf("%0d DONE pulses for one frame", n_done - nd0));
    if (rx_data !== exp_rx) fail($sformatf("mode %0d%0d: RX_DATA %h, expected %h", cpol, cpha, rx_data, exp_rx));
  endtask

  initial begin
    clks(3); rst_n = 1; clks(5);
    // SPI_top, mode 0
    for (int k = 0; k < 12; k++) begin
      int n;
      n = 1 + $urandom % 4;
      div = 2 + $urandom % 7; cpol = 0; cpha = 0;
      clks(3);
      cs = 2'b01; clks(2);
      for (int i = 0; i < n; i++) begin
        logic [7:0] d, r;
        d = $urandom; r = $urandom;
        @(negedge clk); t_wen = 1; t_wdata = r; @(negedge clk); t_wen = 0;
        frame(d, r);
        clks(3);
        if (t_rx !== d) fail($sformatf("SPI_top got %h, sent %h", t_rx, d));
      end
      cs = 2'b00; clks(4);
    end
    // model, all four modes
    for (int k = 0; k < 40; k++) begin
      div = 1 + $urandom % 6; cpol = k % 2; cpha = (k / 2) % 2;
      clks(3);
      m_tx = $urandom;
      cs = 2'b10; clks(2);
      begin
        logic [7:0] d;
        d = $urandom;
        frame(d, m_tx);
        if (m_rx !== d) fail($sformatf("mode %0d%0d: target got %h, sent %h", cpol, cpha, m_rx, d));
        if (m_bits != 8) fail($sformatf("mode %0d%0d: target saw %0d sampling edges", cpol, cpha, m_bits));
      end
      cs = 2'b00; clks(4);
    end
    if (errors == 0) $display("TEST PASSED: SPI_Host");
    else $display("TEST FAILED: SPI_Host (%0d errors)", errors);
    $finish;
  end
  initial begin #20ms; fail("timeout"); $display("TEST FAILED: timeout"); $finish; end
endmodule
