// SPDX-License-Identifier: Apache-2.0
// APB-specific part of tb/APB_apb_tb.sv. The TB is the requester on the
// IP's own APB port (psel / penable / ..., lower case; the register port
// is PSEL / PENABLE / ...): setup, then access until pready.
// Checked: read data against a model of the memory, the wait state of
// the slow region, PSLVERR (and that the write is dropped), PRDATA 0
// outside a read access, a cycle with psel and penable but no setup.
// Covered through the registers: ERR set by reads and writes to the
// reserved region, masked and left pending into reset.
initial begin psel = 0; penable = 0; paddr = 0; pwrite = 0; pwdata = 0; end
logic [31:0] mdl [0:255];
initial for (int i = 0; i < 256; i++) mdl[i] = 0;
task automatic xfer(input logic [31:0] a, input bit w, input logic [31:0] d);
  int wt;
  bit err;
  @(negedge PCLK);
  psel = 1; penable = 0; paddr = a; pwrite = w; pwdata = w ? d : $urandom;
  #1;
  if (pready || pslverr || prdata !== 0) fail("pready, pslverr or prdata in the setup phase");
  @(negedge PCLK);
  penable = 1;
  err = a[11];
  wt = 0;
  #1;
  while (!pready) begin
    if (pslverr) fail("pslverr without pready");
    @(negedge PCLK); #1; wt++;
  end
  if (pslverr !== err) fail($sformatf("pslverr %b (address %h)", pslverr, a));
  if (wt != (!a[11] && a[10] ? 1 : 0)) fail($sformatf("%0d wait cycles at %h", wt, a));
  if (!w && prdata !== (err ? 32'h0 : mdl[a[9:2]])) fail($sformatf("read %h = %h, expected %h", a, prdata, err ? 32'h0 : mdl[a[9:2]]));
  if (w && prdata !== 0) fail("prdata driven in a write");
  if (w && !err) mdl[a[9:2]] = d;
  @(negedge PCLK);
  psel = 0; penable = 0; paddr = $urandom; pwrite = $urandom; pwdata = $urandom;
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
  // every data bit both ways, both regions
  xfer(32'h0000_0004, 1, 32'hFFFF_FFFF);
  xfer(32'hFFFF_F004, 0, 0);
  xfer(32'h0000_0404, 1, 32'h0);
  xfer(32'h0000_0004, 0, 0);
  for (int k = 0; k < 60; k++)
    xfer({20'($urandom), 2'($urandom % 2), 8'($urandom % 16), 2'($urandom)}, $urandom, $urandom);
  for (int i = 0; i < 16; i++) xfer({20'($urandom), 2'($urandom % 2), 8'(i), 2'b00}, 0, 0);
  // psel and penable together with no setup phase: no transfer
  @(negedge PCLK);
  psel = 1; penable = 1; paddr = 32'h804; pwrite = 1;
  @(negedge PCLK); #1;
  if (pready || pslverr) fail("a transfer without a setup phase");
  psel = 0; penable = 0;
  rd_exp(A_IRQ_STATUS, 0);
  // PSLVERR: a write (nothing written) and a read
  xfer(32'h0000_0804, 1, 32'hDEAD_BEEF);
  irq_expect(IRQ_ERR);
  xfer(32'h0000_0C04, 0, 0);
  irq_expect(IRQ_ERR);
  xfer(32'h0000_0004, 0, 0);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  xfer(32'h0000_0FFC, 1, 32'h1);
  cycles(2);
  if (irq) fail("irq with ERR masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
endtask
