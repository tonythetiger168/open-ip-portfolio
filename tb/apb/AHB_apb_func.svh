// SPDX-License-Identifier: Apache-2.0
// AHB-specific part of tb/AHB_apb_tb.sv. The TB is the AHB-Lite manager:
// one transfer at a time (address phase, then the data phase until
// hreadyout), HREADY following hreadyout unless the TB holds it low.
// Checked: read data against a model of the memory, the wait state of
// the slow region, the two-cycle ERROR response (and that it writes
// nothing), transfers not taken (HSEL low, IDLE / BUSY, HREADY low).
// Covered through the registers: ERR set by reads and writes to the
// reserved region, masked and left pending into reset.
logic hold = 0;
always @* hready = hold ? 1'b0 : hreadyout;
initial begin hsel = 0; htrans = 0; haddr = 0; hwrite = 0; hsize = 3'd2; hwdata = 0; end
logic [31:0] mdl [0:255];
initial for (int i = 0; i < 256; i++) mdl[i] = 0;
// one transfer; tr = 2 (NONSEQ) or 3 (SEQ); region from a[11:10]
task automatic xfer(input logic [31:0] a, input bit w, input logic [31:0] d, input logic [1:0] tr = 2'b10);
  int wt;
  bit err;
  @(negedge PCLK);
  hsel = 1; htrans = tr; haddr = a; hwrite = w; hsize = $urandom;
  hwdata = $urandom;
  @(negedge PCLK);
  hsel = $urandom; htrans = $urandom % 2; haddr = $urandom; hwrite = $urandom; hsize = $urandom;
  hwdata = d;
  err = a[11];
  wt = 0;
  #1;
  while (!hreadyout) begin
    if (hresp !== err) fail($sformatf("hresp %b in a wait cycle (address %h)", hresp, a));
    @(negedge PCLK); #1; wt++;
  end
  if (hresp !== err) fail($sformatf("hresp %b at completion (address %h)", hresp, a));
  if (wt != (a[11] || a[10] ? 1 : 0)) fail($sformatf("%0d wait cycles at %h", wt, a));
  if (!w && hrdata !== (err ? 32'h0 : mdl[a[9:2]])) fail($sformatf("read %h = %h, expected %h", a, hrdata, err ? 32'h0 : mdl[a[9:2]]));
  if (w && !err) mdl[a[9:2]] = d;
  @(negedge PCLK);
  hsel = 0; htrans = 0;
endtask
// an address phase that must not start a transfer
task automatic no_xfer(input bit sel, input logic [1:0] tr, input bit hld);
  @(negedge PCLK);
  hsel = sel; htrans = tr; haddr = {$urandom} | 32'h800; hwrite = $urandom; hold = hld;
  @(negedge PCLK);
  hsel = 0; htrans = 0; hold = 0;
  #1;
  if (!hreadyout || hresp) fail("a transfer started without HSEL, NONSEQ / SEQ and HREADY");
  @(negedge PCLK);
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
  // every data bit both ways, both regions, NONSEQ and SEQ
  xfer(32'h0000_0004, 1, 32'hFFFF_FFFF);
  xfer(32'hFFFF_F004, 0, 0, 2'b11);
  xfer(32'h0000_0404, 1, 32'h0);
  xfer(32'h0000_0004, 0, 0);
  // random traffic, any upper address bits
  for (int k = 0; k < 60; k++)
    xfer({20'($urandom), 2'($urandom % 2), 8'($urandom % 16), 2'($urandom)}, $urandom, $urandom, 2'b10 | 2'($urandom));
  for (int i = 0; i < 16; i++) xfer({20'($urandom), 2'b00, 8'(i), 2'b00}, 0, 0);
  rd_exp(A_IRQ_STATUS, 0);
  // not taken: HSEL low, IDLE, BUSY, HREADY held low
  no_xfer(0, 2'b10, 0);
  no_xfer(1, 2'b00, 0);
  no_xfer(1, 2'b01, 0);
  no_xfer(1, 2'b10, 1);
  no_xfer(1, 2'b11, 1);
  rd_exp(A_IRQ_STATUS, 0);
  // ERROR: a write (nothing written) and a read
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
