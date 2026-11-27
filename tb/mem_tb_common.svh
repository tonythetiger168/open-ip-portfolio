// SPDX-License-Identifier: Apache-2.0
// Shared body of the memory-controller TBs (DDR / LPDDR / GDDR / HBM).
// Included inside <P>_tb after the IP's declarations, which provide:
//   localparams NCH, NBU (reachable bank entries), ROWW (row bits used),
//               REFI (refresh interval in clocks)
//   function mk(b, row, col)  host address of bank entry b / row / column
//   function cellof(a)          storage index a host address lands on
//   `REFCNT                   the refresh down-counter (for refresh-straddle
//                             tests, which need a refresh to fall due while
//                             a command is in flight)
//   task ip_extra             IP-specific tests (run before the final reset)
// and, for a controller that keeps no array of its own, the `MEM_DEV_*
// hooks of the DRAM device model tb/mem_dev.svh (included here).
// Host contract: hcmd 1=ACT 2=RD 3=WR 4=PRE, taken on hvalid && hready;
// hdone pulses once per RD and hrdata holds the word from the next clock.
// A scoreboard of every written cell checks every read.
// `MEM_LINE (cores with line commands and an MR file): hcmd 5 RDL / 6 WRL
// move the 8 cells `MEM_LCELL(a, k) of a line (a WRL takes 8 data beats on
// the following hvalid clocks), hcmd 7 MRW / MRR (haddr[3] = 1: read; MR
// index haddr[2:0]; `MEM_MR_RESET: statements setting tb_mr reset values
// other than CL / CWL); line_tests() runs after the word tests.

`ifndef VERILATOR
`ifdef MEM_SVA
  // the bound checker of the coverage flow, also run here: every pin, the
  // page / timing model and the read data (tb/cov/<P>_sva.sv)
`ifdef MEM_SVA_INTERNAL
  // internal command signals the checker reads (bound inside the DUT in the
  // coverage flow)
  `MEM_SVA u_sva (.*, .ras_n(dut.ras_n), .cas_n(dut.cas_n), .we_n(dut.we_n), .addr(dut.addr));
`else
  `MEM_SVA u_sva (.*);
`endif
`endif
`endif
`ifdef MEM_DEV_RD
  `include "mem_dev.svh"
`endif
`ifndef MEM_LCELL
`define MEM_LCELL(a, k) ((cellof(a) & ~7) | (k))
`endif
  localparam int NCELL = 1 << 16;
  logic [15:0] sb [0:NCELL-1];        // expected array contents
  logic        sbv [0:NCELL-1];       // cell has a known value
  int n_rd = 0, n_wr = 0;
  function automatic logic [15:0] pat(input int i);
    case (i)
      0: pat = 16'hFFFF; 1: pat = 16'h0000; 2: pat = 16'hAAAA;
      3: pat = 16'h5555; 4: pat = 16'hFF00; default: pat = 16'h00FF;
    endcase
  endfunction

  task automatic fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endtask

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    while (hready !== 1'b1) @(negedge clk);
    hcmd = c; haddr = a; hwdata = d; hvalid = 1'b1;
    @(negedge clk);
    hvalid = 1'b0; hcmd = $urandom; haddr = $urandom; hwdata = $urandom;
  endtask

  task automatic wr(input logic [31:0] a, input logic [15:0] d);
    int c;
    c = cellof(a);
    cmd(3'd3, a, d);
    sb[c] = d; sbv[c] = 1'b1; n_wr++;
  endtask

  task automatic rd(input logic [31:0] a);
    int k, c;
    c = cellof(a);
    cmd(3'd2, a, $urandom);
    k = 0;
    while (hdone !== 1'b1 && k < 4000) begin @(negedge clk); k++; end
    if (k == 4000) fail($sformatf("RD %h: no hdone", a));
    @(negedge clk);
    if (sbv[c] && hrdata !== sb[c])
      fail($sformatf("RD %h cell %0d: got %h exp %h", a, c, hrdata, sb[c]));
    n_rd++;
  endtask

`ifdef MEM_LINE
  logic [15:0] lw_buf [0:7];          // the line the next wrl() writes
  logic [7:0]  tb_mr [0:7];           // expected MR file
  int n_rdl = 0, n_wrl = 0;
  task automatic wrl(input logic [31:0] a, input int gap);
    cmd(3'd6, a, $urandom);
    for (int k = 0; k < 8; k++) begin
      if (gap == k + 1) begin hvalid = 1'b0; @(negedge clk); end   // a clock with no beat
      if (hready !== 1'b1) fail($sformatf("WRL %h: hready low on data beat %0d", a, k));
      hvalid = 1'b1; hwdata = lw_buf[k];
      @(negedge clk);
    end
    hvalid = 1'b0; hcmd = $urandom; hwdata = $urandom;
    for (int k = 0; k < 8; k++) begin
      sb[`MEM_LCELL(a, k) % NCELL] = lw_buf[k]; sbv[`MEM_LCELL(a, k) % NCELL] = 1'b1;
    end
    n_wrl++;
  endtask
  task automatic rdl(input logic [31:0] a);
    int k, c;
    logic [127:0] e;
    cmd(3'd5, a, $urandom);
    k = 0;
    while (hdone !== 1'b1 && k < 4000) begin @(negedge clk); k++; end
    if (k == 4000) fail($sformatf("RDL %h: no hdone", a));
    @(negedge clk);
    for (int j = 0; j < 8; j++) begin
      c = `MEM_LCELL(a, j) % NCELL;
      e[16*j +: 16] = sbv[c] ? sb[c] : rdline[16*j +: 16];
    end
    if (rdline !== e) fail($sformatf("RDL %h: rdline %h exp %h", a, rdline, e));
    if (hrdata !== e[127:112]) fail($sformatf("RDL %h: last beat %h exp %h", a, hrdata, e[127:112]));
    n_rdl++;
  endtask
  task automatic mrw(input int i, input logic [7:0] v);
    cmd(3'd7, {28'h0, 1'b0, 3'(i)}, {8'h00, v});
    tb_mr[i] = (i == 0) ? {1'b0, v[6:0]} : v;
  endtask
  task automatic mrr(input int i);
    int k;
    cmd(3'd7, {28'h0, 1'b1, 3'(i)}, $urandom);
    k = 0;
    while (hdone !== 1'b1 && k < 10) begin @(negedge clk); k++; end
    if (k == 10) fail($sformatf("MRR %0d: no hdone", i));
    @(negedge clk);
    if (hrdata !== {8'h00, tb_mr[i]}) fail($sformatf("MRR %0d: got %h exp %h", i, hrdata, tb_mr[i]));
  endtask
  task automatic rnd_line;
    for (int k = 0; k < 8; k++) lw_buf[k] = $urandom;
  endtask
  task automatic line_tests;
    logic [31:0] a;
    int cls [3], cwls [3];
    logic [7:0] keep [0:7];
    // ---- every bit of every mode register both ways, read back, then the
    // values from before
    for (int i = 0; i < 8; i++) begin
      keep[i] = tb_mr[i];
      mrw(i, 8'hFF); mrr(i); mrw(i, 8'h00); mrr(i); mrw(i, 8'hA5); mrr(i);
      mrw(i, keep[i]); mrr(i);
    end
    // ---- line bursts on every bank entry: closed bank, page hit, row conflict
    for (int b = 0; b < NBU; b++) begin
      pre(mk(b, 14'h0, 8'h00));
      rnd_line(); wrl(mk(b, 14'h21, 8'h40), 0);          // WRL, bank closed
      rdl(mk(b, 14'h21, 8'h47));                          // RDL hit (low bits ignored)
      rnd_line(); wrl(mk(b, 14'h21, 8'h48), 0);          // WRL hit
      rnd_line(); wrl(mk(b, 14'h22, 8'h50), 0);          // WRL row conflict
      rdl(mk(b, 14'h21, 8'h48));                          // RDL row conflict
      pre(mk(b, 14'h0, 8'h00));
      rdl(mk(b, 14'h22, 8'h50));                          // RDL, bank closed
      rd(mk(b, 14'h22, 8'h53)); rd(mk(b, 14'h21, 8'h4F)); // words of the lines
      wr(mk(b, 14'h21, 8'h4A), 16'h1357); rdl(mk(b, 14'h21, 8'h48));
    end
    // ---- data patterns on every beat, columns 0 and 255
    for (int i = 0; i < 6; i++) begin
      for (int k = 0; k < 8; k++) lw_buf[k] = (k % 2) ? ~pat(i) : pat(i);
      a = mk(0, 14'h0, (i % 2) ? 8'hF8 : 8'h00);
      wrl(a, 0); rdl(a);
    end
    // ---- WRL data beats with a gap
    for (int g = 1; g <= 8; g += 7) begin rnd_line(); wrl(mk(1 % NBU, 14'h3, 8'h18), g); rdl(mk(1 % NBU, 14'h3, 8'h18)); end
    // ---- CL / CWL at their ends and at reset value, word and line traffic
    cls[0] = 0; cls[1] = 15; cls[2] = CL - 5; cwls[0] = 0; cwls[1] = 15; cwls[2] = CWL - 5;
    for (int i = 0; i < 3; i++)
      for (int j = 0; j < 3; j++) begin
        mrw(0, 8'(cls[i])); mrw(1, 8'(cwls[j]));
        a = mk((i + j) % NBU, 14'(i * 3 + j), 8'h80);
        wr(a, 16'(i * 16 + j)); rd(a);
        rnd_line(); wrl(a, 0); rdl(a);
        wr(a + 1, ~16'(i * 16 + j)); rdl(a);               // word into the line
        rnd_line(); wrl(a, 0); rd(a + 2);                  // a word of the line right behind its WRL
        pre(a); rnd_line(); wrl(a, 0); pre(a); rdl(a);     // PRE right behind a WRL
      end
    mrw(0, 8'(CL - 5)); mrw(1, 8'(CWL - 5)); mrr(0); mrr(1);
    // ---- refresh falling due during line commands and a WRL's data beats
    a = mk(0, 14'h3, 8'h30);
    near_refresh(3); rdl(a);
    near_refresh(3); rnd_line(); wrl(a, 0);
    near_refresh(REFI / 2); act(a); near_refresh(3); rdl(a);
    near_refresh(REFI / 2); act(a); near_refresh(3); rnd_line(); wrl(a, 0);
    near_refresh(6); rnd_line(); wrl(a, 0); rdl(a);
    // ---- random word and line traffic
    for (int t = 0; t < 200; t++) begin
      a = rnd_addr();
      case ($urandom_range(0, 5))
        0: begin rnd_line(); wrl(a, $urandom_range(0, 1) ? $urandom_range(1, 8) : 0); end
        1: rdl(a);
        2: wr(a, $urandom);
        3: rd(a);
        4: act(a);
        default: pre(a);
      endcase
    end
  endtask
`endif

  task automatic act(input logic [31:0] a); cmd(3'd1, a, $urandom); endtask
  task automatic pre(input logic [31:0] a); cmd(3'd4, a, $urandom); endtask
  // idle clocks; once the controller has been idle 40 clocks (any write data
  // long gone), dq must float: a controller drives dq only for write data
  // (Icarus only: Verilator is 2-state and reads an undriven dq as 0)
  task automatic idle(input int n);
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
`ifndef VERILATOR
      if (i >= 40 && hready === 1'b1 && dq !== 'z) fail($sformatf("dq driven while idle: %h", dq));
`endif
    end
  endtask
  task automatic quiesce; while (hready !== 1'b1) @(negedge clk); endtask

  function automatic logic [13:0] rrow;
    rrow = $urandom;
    if (ROWW < 14) rrow = rrow & ((14'd1 << ROWW) - 1);
  endfunction
  function automatic logic [31:0] rnd_addr;
    rnd_addr = mk($urandom_range(0, NBU - 1), rrow(), $urandom);
  endfunction

  // wait until the refresh counter is k clocks from due, so that a command
  // issued now is still in flight when the refresh falls due (k = REFI / 2
  // parks mid-interval, so a setup command cannot meet a refresh)
  task automatic near_refresh(input int k);
    quiesce();
    while (`REFCNT != k) @(negedge clk);
  endtask

  task automatic random_traffic(input int n);
    int r;
    logic [31:0] a;
    for (int t = 0; t < n; t++) begin
      r = $urandom_range(0, 19);
      a = rnd_addr();
      if ($urandom_range(0, 9) < 2) a[7:0] = $urandom_range(0, 1) ? 8'hFF : 8'h00;
      if (r < 8) wr(a, $urandom);
      else if (r < 14) rd(a);
      else if (r < 17) act(a);
      else pre(a);
    end
  endtask

  task automatic common_tests;
    logic [31:0] a;
    for (int i = 0; i < NCELL; i++) begin sb[i] = 16'h0; sbv[i] = 1'b1; end  // array starts zeroed
    hvalid = 0; hcmd = 0; haddr = 0; hwdata = 0;
    rst_n = 0; idle(5); rst_n = 1; idle(5);
    // ---- first commands out of reset: row 0 of every bank entry, which
    // reset leaves closed (a RD must ACT first)
    for (int b = 0; b < NBU; b++) rd(mk(b, 14'h0, 8'h01));
    // ---- every bank entry: open, write, read hits, rows of all-ones / all-zeros
    for (int b = 0; b < NBU; b++) begin
      act(mk(b, '1, 8'h00));
      wr(mk(b, '1, 8'h11), 16'hA5A5 ^ 16'(b));
      rd(mk(b, '1, 8'h11));                 // hit
      wr(mk(b, 14'h0, 8'h12), 16'h5A5A);     // conflict write
      rd(mk(b, 14'h0, 8'h12));              // hit on the new row
      act(mk(b, '1, 8'h00));                // ACT conflict
      act(mk(b, '1, 8'h00));                // ACT to the open row
      pre(mk(b, '1, 8'h00));                // PRE open bank
      pre(mk(b, '1, 8'h00));                // PRE closed bank
      rd(mk(b, 14'h0, 8'h11));              // miss on a closed bank
    end
    // ---- data patterns: every hrdata / dq bit both ways
    for (int i = 0; i < 6; i++) begin
      a = mk(0, 14'h0, 8'h5A);
      wr(a, pat(i)); rd(a);
    end
    for (int c = 0; c < 256; c += 85) begin
      wr(mk(NBU - 1, rrow(), c[7:0]), ~16'(c)); rd(mk(NBU - 1, rrow(), c[7:0]));
    end
    // ---- back-to-back page-hit writes, then reads of the same words
    // (write-side spacing: CAS-to-CAS, write-to-read, write recovery)
    act(mk(0, 14'h0, 8'h00));               // the row open first: every write is a page hit
    for (int i = 0; i < 8; i++) wr(mk(0, 14'h0, 8'(8'h40 + i)), 16'hC000 ^ 16'(i * 16'h0111));
    for (int i = 0; i < 8; i++) rd(mk(0, 14'h0, 8'(8'h40 + i)));
    wr(mk(0, 14'h0, 8'h48), 16'h7E57); pre(mk(0, 14'h0, 0));   // PRE right behind a WR
    wr(mk(0, 14'h1, 8'h49), 16'h8E57); wr(mk(0, 14'h2, 8'h4A), 16'h9E57);   // WR row conflicts
    rd(mk(0, 14'h2, 8'h4A));
    // ---- unknown host codes are no-ops
`ifdef MEM_LINE
    cmd(3'd0, $urandom, 0);
`else
    cmd(3'd0, $urandom, 0); cmd(3'd5, $urandom, 0); cmd(3'd6, $urandom, 0); cmd(3'd7, $urandom, 0);
`endif
    // ---- hvalid while busy is ignored
    act(mk(0, 14'h155, 0));
    act(mk(0, 14'h2AA, 0));
    for (int i = 0; i < 6 && hready !== 1'b1; i++) begin
      hcmd = 3'd2; haddr = mk(1 % NBU, 14'h0, 8'h33); hvalid = 1; @(negedge clk);
    end
    hvalid = 0;
    // ---- random mix
    random_traffic(600);
    // ---- refresh falling due during each command, and while idle
    a = mk(0, 14'h3, 8'h21);
    wr(a, 16'h1234);
    near_refresh(3); rd(a);                       // RD to a closed bank
    near_refresh(3); wr(a, 16'h4321);             // WR to a closed bank
    near_refresh(REFI / 2); act(a); near_refresh(3); rd(a);               // RD page hit
    near_refresh(3); act(mk(0, 14'h4, 0));        // ACT to a closed bank
    near_refresh(REFI / 2); act(a); near_refresh(3); act(mk(0, 14'h5, 0)); // ACT row conflict
    near_refresh(REFI / 2); act(a); near_refresh(3); pre(a);              // PRE of an open bank
    for (int k = 1; k <= 2; k++) begin                                    // ... a refresh due right behind it
      near_refresh(REFI / 2); act(a); near_refresh(k); pre(a);
    end
    near_refresh(REFI / 2); act(a); near_refresh(3); wr(mk(0, 14'h6, 8'h21), 16'h5678); // WR row conflict
    near_refresh(1); idle(REFI / 50 + 400);       // refresh while idle
    rd(mk(0, 14'h6, 8'h21)); rd(a);               // the row open before it first
    // every bank open, then an idle refresh: the same rows afterwards each need
    // a new ACT (the checker flags a RD / WR to a bank the refresh closed)
    for (int b = 0; b < NBU; b++) act(mk(b, 14'h9, 8'h00));
    near_refresh(1); idle(REFI / 50 + 400);
    for (int b = 0; b < NBU; b++) begin
      if (b % 2) rd(mk(b, 14'h9, 8'h23)); else wr(mk(b, 14'h9, 8'h23), 16'h0F0F ^ 16'(b));
    end
`ifdef MEM_LINE
    for (int i = 0; i < 8; i++) tb_mr[i] = 8'h00;
    tb_mr[0] = 8'(CL - 5); tb_mr[1] = 8'(CWL - 5);
`ifdef MEM_MR_RESET
    `MEM_MR_RESET
`endif
    line_tests();
`endif
    ip_extra();
    // ---- a stream of no-op host commands must not hold off a refresh
    near_refresh(20);
    for (int i = 0; i < 800; i++) cmd(3'd0, $urandom, 0);
    // ---- reset with a read in flight (and a write just before it, which
    // may or may not have reached the array)
    a = mk(0, 14'h7, 8'h77);
    cmd(3'd3, a, 16'hBEEF); sbv[cellof(a) % NCELL] = 1'b0;
    cmd(3'd2, mk(NBU - 1, 14'h8, 8'h78), 0);
    idle(3); rst_n = 0; idle(3); rst_n = 1; idle(3);
    wr(a, 16'hFEED); rd(a);
    random_traffic(100);
  endtask

`ifdef MEM_PERF
  `include "perf/mem_perf.svh"
`else
  initial begin
    common_tests();
    quiesce(); idle(20);
`ifndef VERILATOR
`ifdef MEM_SVA
    errors += u_sva.sva_n_fail;
`endif
`endif
`ifdef MEM_LINE
    if (errors == 0) $display("TEST PASSED: %m (%0d reads, %0d writes, %0d line reads, %0d line writes)",
                              n_rd, n_wr, n_rdl, n_wrl);
`else
    if (errors == 0) $display("TEST PASSED: %m (%0d reads, %0d writes)", n_rd, n_wr);
`endif
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
`endif
