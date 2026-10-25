// SPDX-License-Identifier: Apache-2.0
// Shared APB tests of the line-level memory controllers (*_Lite), included
// by tb/apb/<P>_apb_func.svh after the IP part, which provides NLINES
// (array lines), NBANK (bank entries), function mk(b, row, line) (host
// address), function lidx(a) (array line of a host address), OOR (an
// address bit that must be 0) and task lite_extra (IP-specific tests).
// Register map: CMD = {hcmd, haddr, hwdata} (writing CMD2 sends a beat: the
// command, then the 8 data beats of a WRITE), RDATA = hrdata (MRR value),
// RLINE0..3 = rdline (the line of the last READ), IRQ DONE = hdone, ERR =
// the core's sticky error irq.
// Covered: line writes and reads checked against a scoreboard (every RLINE,
// RDATA, haddr and hwdata bit both ways), MRW / MRR, refresh, NOP, CMD held
// while the core is busy and dropped when full, every interrupt bit set,
// masked, enabled onto irq and cleared; ERR (held by the core until reset)
// last.
logic [127:0] l_sb [0:NLINES-1];
initial for (int i = 0; i < NLINES; i++) l_sb[i] = '0;     // the array starts zeroed
localparam logic [31:0] M_FULL = 32'h1 << FLAG_CMD_FULL;
localparam logic [31:0] M_DONE = 32'h1 << IRQ_DONE;

task automatic m_send(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
  poll(A_FLAGS, M_FULL, 0, 2000);
  wr(A_CMD0, {29'h0, c});
  wr(A_CMD1, a);
  wr(A_CMD2, {16'h0, d});
endtask
task automatic l_wait;
  poll(A_IRQ_STATUS, M_DONE, M_DONE, 4000);
  wr(A_IRQ_STATUS, M_DONE);
endtask
task automatic l_wrl_d(input logic [31:0] a, input logic [127:0] d);
  wr(A_IRQ_STATUS, M_DONE);
  m_send(3'd2, a, $urandom);
  for (int i = 0; i < 8; i++) wr(A_CMD2, {16'h0, d[16*i +: 16]});   // data beats
  l_wait();
  l_sb[lidx(a)] = d;
endtask
task automatic l_wrl(input logic [31:0] a);
  l_wrl_d(a, {$urandom, $urandom, $urandom, $urandom});
endtask
task automatic l_rdl(input logic [31:0] a);
  logic [127:0] e;
  wr(A_IRQ_STATUS, M_DONE);
  m_send(3'd1, a, $urandom);
  l_wait();
  e = l_sb[lidx(a)];
  rd_exp(A_RLINE0, e[31:0]); rd_exp(A_RLINE1, e[63:32]);
  rd_exp(A_RLINE2, e[95:64]); rd_exp(A_RLINE3, e[127:96]);
endtask
task automatic l_mrw(input int i, input logic [7:0] v);
  wr(A_IRQ_STATUS, M_DONE);
  m_send(3'd3, 32'(i), {8'($urandom), v}); l_wait();
endtask
task automatic l_mrr(input int i, input logic [7:0] v);
  wr(A_IRQ_STATUS, M_DONE);
  m_send(3'd4, 32'(i), $urandom); l_wait();
  rd_exp(A_RDATA, {24'h0, v});
endtask
task automatic l_imm(input logic [2:0] c, input logic [31:0] a);
  wr(A_IRQ_STATUS, M_DONE);
  m_send(c, a, $urandom); l_wait();
endtask
function automatic logic [31:0] l_addr;
  l_addr = mk($urandom_range(0, NBANK - 1), $urandom_range(0, 511), $urandom_range(0, 7));
endfunction

task automatic lite_func;
  logic [31:0] a;
  rd_exp(A_RLINE0, 0); rd_exp(A_RDATA, 0);
  // ---- lines: all ones, all zeros, random; hits, conflicts, every bank
  a = mk(0, 511, 7);
  l_wrl_d(a, '1); l_rdl(a); l_wrl_d(a, '0); l_rdl(a);
  l_wrl_d(a, {8{16'hA5C3}}); l_rdl(a);
  for (int b = 0; b < NBANK; b++) begin
    l_wrl(mk(b, 1, b % 8)); l_rdl(mk(b, 1, b % 8)); l_rdl(mk(b, 2, 0));
  end
  // ---- mode registers: every RDATA bit both ways
  l_mrw(7, 8'hFF); l_mrr(7, 8'hFF); l_mrw(7, 8'h00); l_mrr(7, 8'h00);
  // ---- refresh, NOP, addresses with every bit both ways
  l_imm(3'd5, 32'hFFFF_FFFF); l_imm(3'd0, 32'h0); l_imm(3'd0, 32'hFFFF_FFFF);
  for (int k = 0; k < 16; k++) begin
    a = l_addr();
    if (k % 2) l_wrl(a); else l_rdl(a);
  end
  lite_extra();
  // ---- CMD while busy: the next command waits in CMD (FULL), a further
  // write to CMD2 is dropped (CMD_OVF); interrupts masked
  wr(A_IRQ_STATUS, IRQ_ALL);
  a = mk(1 % NBANK, 3, 3);
  no_idle = 1;                         // exact timing: the core is still busy
  m_send(3'd1, a, 0);
  wr(A_CMD0, 32'd4); wr(A_CMD1, 32'd7); wr(A_CMD2, 32'h0);   // MRR 7: held
  rd(A_FLAGS);
  if (rdv !== M_FULL) fail("CMD not held while the core is busy");
  wr(A_CMD2, 32'h0);                   // full: dropped
  no_idle = 0;
  poll(A_FLAGS, M_FULL, 0, 2000);
  poll(A_IRQ_STATUS, M_DONE, M_DONE, 4000);
  cycles(4);
  rd_exp(A_RDATA, 32'h0);
  // ---- ERR (the core holds it until reset): a READ out of range
  m_send(3'd1, OOR | mk(0, 0, 0), 0);
  poll(A_IRQ_STATUS, IRQ_ALL, IRQ_ALL, 100);
  if (irq !== 1'b0) fail("irq with every interrupt masked");
  // ---- each interrupt alone onto irq, then cleared (ERR is set again)
  for (int i = 0; i < 4; i++) begin
    wr(A_IRQ_ENABLE, 32'h1 << i);
    if (irq !== 1'b1) fail($sformatf("irq bit %0d enabled: no irq", i));
    wr(A_IRQ_STATUS, 32'h1 << i);
    if (i != IRQ_ERR && irq !== 1'b0) fail($sformatf("irq bit %0d cleared: irq stays", i));
  end
  // ---- traffic with every interrupt enabled
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int k = 0; k < 12; k++) begin
    a = l_addr();
    if (k % 2) l_wrl(a); else l_rdl(a);
  end
  wr(A_IRQ_ENABLE, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask
