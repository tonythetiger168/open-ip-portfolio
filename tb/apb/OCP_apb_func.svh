// SPDX-License-Identifier: Apache-2.0
// OCP-specific part of tb/OCP_apb_tb.sv. The TB is the OCP master: each
// request held until SCmdAccept, then the response phase awaited.
// Checked against a model of the memory: the accept latency, DVA / ERR
// two clocks after acceptance, SData (the word when the request was
// accepted), SThreadID, byte enables, posted writes (WR) not answered,
// unsupported commands answered ERR and doing nothing.
// Covered through the registers: ERR set by bad addresses, unsupported
// commands and posted writes to a bad address; masked, left pending into
// reset.
initial begin mcmd = 0; maddr = 0; mdata = 0; mbyteen = 0; mthreadid = 0; end
logic [31:0] mdl [0:255];
bit          use_fix = 0;
logic [31:0] wfix;
task automatic req(input logic [2:0] c, input logic [31:0] a, input bit full = 0);
  logic [31:0] d, e;
  logic [3:0]  be;
  logic [1:0]  th;
  bit bad;
  int w;
  @(negedge PCLK);
  d = use_fix ? wfix : $urandom; be = full ? 4'hF : 4'($urandom); th = $urandom;
  mcmd = c; maddr = a; mdata = d; mbyteen = be; mthreadid = th;
  w = 0;
  #1; while (!scmdaccept) begin @(negedge PCLK); #1; w++; end
  if (w != 1) fail($sformatf("SCmdAccept %0d clocks after the command", w));
  bad = a[31:10] != 0 || a[1:0] != 0;
  e = mdl[a[9:2]];
  if (!bad && (c == 3'd5 || c == 3'd1)) for (int k = 0; k < 4; k++) if (be[k]) mdl[a[9:2]][8*k +: 8] = d[8*k +: 8];
  @(negedge PCLK);
  mcmd = 0; maddr = $urandom; mdata = $urandom; mbyteen = $urandom; mthreadid = $urandom;
  #1;
  if (sresp !== 0) fail("a response one clock after acceptance");
  @(negedge PCLK); #1;
  if (c == 3'd1) begin
    if (sresp !== 0) fail("a posted write answered");
  end else begin
    if (sresp !== (bad || !(c == 3'd5 || c == 3'd2) ? 2'b11 : 2'b01)) fail($sformatf("SResp %b for MCmd %0d at %h", sresp, c, a));
    if (sthreadid !== th) fail($sformatf("SThreadID %0d, expected %0d", sthreadid, th));
    if (sdata !== e) fail($sformatf("SData %h, expected %h (MCmd %0d at %h)", sdata, e, c, a));
  end
  @(negedge PCLK); #1;
  if (sresp !== 0) fail("a response lasting more than one clock");
endtask
task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int i = 0; i < 256; i++) req(i % 2 ? 3'd5 : 3'd1, 32'(i * 4), 1);
  use_fix = 1;
  wfix = 32'hFFFF_FFFF; req(3'd5, 32'h204, 1); req(3'd2, 32'h204);
  wfix = 32'h0;         req(3'd5, 32'h204, 1); req(3'd2, 32'h204);
  use_fix = 0;
  for (int k = 0; k < 120; k++) begin : b_mix
    logic [2:0] c;
    c = $urandom % 3 == 0 ? 3'd1 : $urandom % 2 ? 3'd5 : 3'd2;
    req(c, 32'($urandom % 256) * 4);
  end
  rd_exp(A_IRQ_STATUS, 0);
  // ERR: out of range (every upper bit), misaligned, unsupported commands,
  // a posted write to a bad address
  req(3'd5, 32'hFFFF_FC00); irq_expect(IRQ_ERR);
  req(3'd2, 32'h0000_0402); irq_expect(IRQ_ERR);
  req(3'd1, 32'h0000_0101); irq_expect(IRQ_ERR);
  for (int c = 3; c < 8; c++) if (c != 5) begin req(3'(c), 32'h40); irq_expect(IRQ_ERR); end
  req(3'd2, 32'h40);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  req(3'd2, 32'h3);
  cycles(2);
  if (irq) fail("irq with ERR masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
endtask
