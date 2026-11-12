// SPDX-License-Identifier: Apache-2.0
// Shared part of the core testbenches of the phone SoC subsystem IPs, included
// inside the TB module: clock and reset, error counting, the AXI4 manager
// wires of the core and an soc_ss_axi_mem subordinate on them, address and
// data helpers. Each TB names its own DUT and reference model.
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction
  task automatic clks(input int n); repeat (n) @(negedge clk); endtask

  `SOC_SS_AXI_WIRES
  `SOC_SS_AXI_MEM(mem, clk, rst_n)

  // a word-aligned buffer of n words: low memory, the top of the address
  // space, straddling a 4 KB boundary, or anywhere; dst_of() gives a disjoint
  // buffer (bit 30 flipped) so source and destination never overlap
  function automatic logic [31:0] pick_addr(input int n);
    logic [31:0] a;
    case ($urandom % 4)
      0: a = 32'h0000_0000 + 32'(($urandom % 64) * 4);
      1: a = 32'hFFFF_FFFC - 32'(n * 4) - 32'(($urandom % 16) * 4);
      2: a = 32'h8000_1000 + 32'(($urandom % 16) * 4096) - 32'((1 + $urandom % 24) * 4);
      default: a = $urandom & 32'h3FFF_FFFC;
    endcase
    return a;
  endfunction
  function automatic logic [31:0] dst_of(input logic [31:0] src);
    return src ^ 32'h4000_0000;
  endfunction
  function automatic void fill_rand(input logic [31:0] a, input int n);
    for (int i = 0; i < n; i++) mem.poke(a + 32'(4 * i), $urandom);
  endfunction
  // AXI rules the memory model checks, plus no burst left open at the end
  task automatic finish(input string name);
    clks(5);
    errors += mem.errors;
    if (m_awvalid || m_arvalid || m_wvalid) fail("AXI request still open at the end");
    if (mem.max_awlen > 15 || mem.max_arlen > 15) fail("burst longer than 16 beats");
    $display("%s: %0d write bursts (%0d beats), %0d read bursts (%0d beats)", name,
             mem.n_wr_bursts, mem.n_wr_beats, mem.n_rd_bursts, mem.n_rd_beats);
    if (errors == 0) $display("TEST PASSED: %s", name);
    else $display("TEST FAILED: %s (%0d errors)", name, errors);
    $finish;
  endtask
