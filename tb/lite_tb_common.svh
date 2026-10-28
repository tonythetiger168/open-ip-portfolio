// SPDX-License-Identifier: Apache-2.0
// Shared host tests for the *_Lite line controllers. The including TB
// declares the DUT signals, instantiates the DUT, and defines:
//   localparam int T_REFI, NBANK, NLINES (array lines), CL0, CWL0
//   function mk(bank, row, line) -> host address; function lidx(a) -> line
//   index into the scoreboard; task ip_extra (IP-specific tests)
// Read data: the 8 hrdata values of the 8 clocks ending with hdone.

`ifndef TB_OOR
`define TB_OOR 32'h0004_0000             // lowest address bit that must be 0
`endif
`ifdef TB_NO_BAD_CMD
`define TB_NREJ 2                        // rejection classes: high address, OOR, bad code
`else
`define TB_NREJ 3
`endif
  logic [15:0] sb [NLINES*8];            // expected words, by line*8+beat
  initial for (int i = 0; i < NLINES * 8; i++) sb[i] = '0;   // the DUT zeroes its array
  int n_rd = 0, n_wr = 0, errors = 0;
  logic [15:0] hist [8];
  always @(negedge clk) begin
    for (int i = 7; i > 0; i--) hist[i] <= hist[i-1];
    hist[0] <= hrdata;
  end

  task automatic fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endtask

  // present one command; it is taken at the first rising edge with hready
  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    hvalid <= 1'b1; hcmd <= c; haddr <= a; hwdata <= d;
    @(posedge clk);
    while (hready !== 1'b1) @(posedge clk);
    @(negedge clk);
    hvalid <= 1'b0; hcmd <= 3'd0; haddr <= $urandom; hwdata <= $urandom;
  endtask
  task automatic wait_done;
    int k;
    k = 0;
    while (hdone !== 1'b1 && k < 2000) begin @(negedge clk); k++; end
    if (k == 2000) fail("no hdone");
  endtask

  // pk: 0 all-zero line, 1 all-ones, 2 alternating 5555 / AAAA, else random
  task automatic wrl(input logic [31:0] a, input bit gaps = 0, input int pk = -1);
    logic [15:0] w [8];
    for (int i = 0; i < 8; i++)
      w[i] = (pk == 0) ? 16'h0000 : (pk == 1) ? 16'hFFFF :
             (pk == 2) ? (i[0] ? 16'hAAAA : 16'h5555) : 16'($urandom);
    cmd(3'd2, a, $urandom);
    for (int i = 0; i < 8; i++) begin
      if (gaps && $urandom_range(0, 2) == 0) begin
        hvalid <= 1'b0; hwdata <= $urandom; @(negedge clk);
      end
      hvalid <= 1'b1; hwdata <= w[i]; hcmd <= 3'($urandom);
      @(negedge clk);
    end
    hvalid <= 1'b0;
    wait_done();
    for (int i = 0; i < 8; i++) sb[lidx(a) * 8 + i] = w[i];
    n_wr++;
    @(negedge clk);
  endtask
  task automatic rdl(input logic [31:0] a);
    cmd(3'd1, a, $urandom);
    wait_done();
    @(posedge clk); #1;
    for (int i = 0; i < 8; i++)
      if (hist[7 - i] !== sb[lidx(a) * 8 + i])
        fail($sformatf("RD %h beat %0d: got %h exp %h", a, i, hist[7 - i], sb[lidx(a) * 8 + i]));
    n_rd++;
    @(negedge clk);
  endtask
  task automatic mrw(input int idx, input logic [7:0] v);
    cmd(3'd3, 32'(idx), {8'($urandom), v}); wait_done(); @(negedge clk);
  endtask
  task automatic mrr(input int idx, input logic [7:0] exp);
    cmd(3'd4, 32'(idx), $urandom); wait_done();
    if (hrdata[7:0] !== exp) fail($sformatf("MRR %0d: got %h exp %h", idx, hrdata[7:0], exp));
    @(negedge clk);
  endtask
  task automatic refh; cmd(3'd5, $urandom, $urandom); wait_done(); @(negedge clk); endtask
  task automatic imm(input logic [2:0] c, input logic [31:0] a);
    cmd(c, a, $urandom); wait_done(); @(negedge clk);
  endtask
  task automatic idle(input int k); repeat (k) @(negedge clk); endtask
  function automatic logic [31:0] rnd_addr;
    rnd_addr = mk($urandom_range(0, NBANK - 1), $urandom_range(0, 3), $urandom_range(0, 7));
  endfunction

  initial begin
    logic [31:0] a;
    hvalid = 0; hcmd = 0; haddr = 0; hwdata = 0;
    repeat (3) @(negedge clk); rst_n = 1;
    @(negedge clk);
    // ---- each rejection on its own sets the sticky irq (reset in between;
    // nothing has been written yet, so the array is still all zero)
    for (int r = 0; r < `TB_NREJ; r++) begin
      if (irq !== 1'b0) fail($sformatf("irq set before rejection %0d", r));
      case (r)
        0: imm(3'd1, 32'h8000_0000 | mk(1, 1, 1));
        1: imm(3'd2, `TB_OOR | mk(1, 1, 1));
        default: imm(3'd6, 0);
      endcase
      idle(2);
      if (irq !== 1'b1) fail($sformatf("irq not set by rejection %0d", r));
      rst_n = 0; idle(3); rst_n = 1; idle(2);
    end
    imm(3'd0, $urandom); idle(2);
    if (irq !== 1'b0) fail("irq set by a NOP");
    // ---- every bank: write, read back (closed bank, then hits)
    for (int b = 0; b < NBANK; b++) begin
      wrl(mk(b, 1, 0)); rdl(mk(b, 1, 0)); wrl(mk(b, 1, 7), 1); rdl(mk(b, 1, 7));
    end
    // ---- row conflicts: read then write another row of the same bank
    for (int b = 0; b < NBANK; b++) begin
      rdl(mk(b, 2, 3)); wrl(mk(b, 3, 3)); rdl(mk(b, 2, 3)); rdl(mk(b, 3, 3));
    end
    // ---- mode registers: read the reset values, change CL / CWL, the
    // MR0 DLL-reset bit, the other registers
    mrr(0, 8'(CL0 - 5)); mrr(1, 8'(CWL0 - 5));
`ifdef TB_NO_DLL
    mrw(0, 8'h0F); mrr(0, 8'h0F);          // CL 20
`else
    mrw(0, 8'h8F); mrr(0, 8'h0F);          // CL 20; bit 7 self-clears
`endif
    mrw(1, 8'h00);                          // CWL 5
    for (int k = 0; k < 12; k++) begin
      a = rnd_addr();
      if ($urandom_range(0, 1)) wrl(a); else rdl(a);
    end
    for (int i = 2; i < 8; i++) begin mrw(i, 8'(8'h11 * i)); mrr(i, 8'(8'h11 * i)); end
    mrw(0, 8'h00); mrw(1, 8'h0A);          // CL 5, CWL 15
    for (int k = 0; k < 12; k++) begin
      a = rnd_addr();
      if ($urandom_range(0, 1)) wrl(a, 1); else rdl(a);
    end
    mrw(0, 8'(CL0 - 5)); mrw(1, 8'(CWL0 - 5));
    // ---- host refresh with banks open, then with every bank closed
    rdl(mk(0, 1, 1)); refh(); refh();
    // ---- rejected commands: out-of-range addresses, illegal codes; NOP
    imm(3'd0, $urandom);
    imm(3'd1, 32'h8000_0000 | mk(1, 1, 1)); imm(3'd2, `TB_OOR | mk(1, 1, 1));
`ifndef TB_NO_BAD_CMD
    imm(3'd6, 0); imm(3'd7, 0);
`endif
    // ---- commands presented while busy are not taken
    cmd(3'd1, mk(2, 1, 0), 0);
    hvalid <= 1'b1; hcmd <= 3'd4; haddr <= 0;
    wait_done(); hvalid <= 1'b0; @(posedge clk); #1;
    @(negedge clk);
    // ---- back-to-back: the next command in the hdone clock
    cmd(3'd1, mk(3, 1, 0), 0);
    while (hdone !== 1'b1) @(negedge clk);
    cmd(3'd1, mk(3, 1, 7), 0); wait_done(); @(negedge clk);
    ip_extra();
    // ---- data classes: zero / ones / alternating lines written and read
    for (int pk = 0; pk < 3; pk++) begin wrl(mk(0, 5, pk), 0, pk); rdl(mk(0, 5, pk)); end
    // ---- random traffic across refreshes
    for (int k = 0; k < 400; k++) begin
      a = rnd_addr();
      case ($urandom_range(0, 9))
        0: refh();
        1, 2, 3, 4: rdl(a);
        default: wrl(a, $urandom_range(0, 3) == 0);
      endcase
      if ($urandom_range(0, 15) == 0) idle($urandom_range(1, T_REFI));
    end
    // ---- reset with a read in flight
    cmd(3'd1, mk(1, 2, 2), 0);
    idle(9);
    rst_n = 0; idle(3); rst_n = 1; idle(2);
    mrr(0, 8'(CL0 - 5));
    rdl(mk(1, 2, 2));
    // a full refresh rotation of traffic-free time raises no irq
    idle(T_REFI * NBANK + 200);
    if (irq !== 1'b0) fail("irq set with no rejected command since reset");
    if (errors == 0 && n_rd > 0)
      $display("TEST PASSED: %m (%0d reads, %0d writes)", n_rd, n_wr);
    else $display("TEST FAILED: %m (%0d errors)", errors);
    $finish;
  end
