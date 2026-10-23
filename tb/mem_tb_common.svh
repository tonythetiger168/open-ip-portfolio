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
// Host contract: hcmd 1=ACT 2=RD 3=WR 4=PRE, taken on hvalid && hready;
// hdone pulses once per RD and hrdata holds the word from the next clock.
// A scoreboard of every written cell checks every read.

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

  task automatic act(input logic [31:0] a); cmd(3'd1, a, $urandom); endtask
  task automatic pre(input logic [31:0] a); cmd(3'd4, a, $urandom); endtask
  task automatic idle(input int n); repeat (n) @(negedge clk); endtask
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
    // ---- unknown host codes are no-ops
    cmd(3'd0, $urandom, 0); cmd(3'd5, $urandom, 0); cmd(3'd6, $urandom, 0); cmd(3'd7, $urandom, 0);
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
    near_refresh(REFI / 2); act(a); near_refresh(3); wr(mk(0, 14'h6, 8'h21), 16'h5678); // WR row conflict
    near_refresh(1); idle(REFI / 50 + 400);       // refresh while idle
    rd(a); rd(mk(0, 14'h6, 8'h21));
    ip_extra();
    // ---- reset with a write in flight: the cell is unknown afterwards
    a = mk(0, 14'h7, 8'h77);
    cmd(3'd3, a, 16'hBEEF); sbv[cellof(a) % NCELL] = 1'b0;
    idle(3); rst_n = 0; idle(3); rst_n = 1; idle(3);
    wr(a, 16'hFEED); rd(a);
    random_traffic(100);
  endtask

  initial begin
    common_tests();
    quiesce(); idle(20);
    if (errors == 0) $display("TEST PASSED: %m (%0d reads, %0d writes)", n_rd, n_wr);
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
