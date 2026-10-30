// SPDX-License-Identifier: Apache-2.0
// OBI-specific part of tb/OBI_apb_tb.sv. The TB is the OBI manager: each
// request is held until gnt, the response waited for (rready high or
// randomly low) and checked against a model of the memory (byte enables,
// out-of-range and protection errors, AMOADD, LR / SC).
// Covered through the registers: DEC, PROT, ATOP and PAR, each raised on
// its own, cleared with a write-1, raised while masked, and DEC left
// pending into reset.
logic par_inj = 0;
initial begin
  req = 0; addr = 0; we = 0; be = 0; wdata = 0; aid = 0; prot = 3'b111; atop = 0; rready = 1;
end
always @(req or rready or par_inj) if (!par_inj) begin reqpar = ~req; rreadypar = ~rready; end
logic [31:0] mdl [0:255];
initial for (int i = 0; i < 256; i++) mdl[i] = 0;
bit          rsv_v = 0;
logic [7:0]  rsv_a;

task automatic obi(input logic w, input logic [31:0] a, input logic [3:0] b, input logic [31:0] d,
                   input logic [5:0] at = 0, input logic [2:0] pr = 3'b111);
  logic [31:0] e;
  logic [3:0]  id;
  bit          eb;
  int          n;
  logic [7:0]  i;
  i = a[9:2];
  eb = a[31:10] != 0 || (a[9:0] >= 10'h300 && pr[2:1] != 2'b11) ||
       (at != 0 && at != 6'h20 && at != 6'h22 && at != 6'h23) ||
       (at == 6'h22 && w) || ((at == 6'h20 || at == 6'h23) && !w);
  e = 0;
  if (!eb) begin
    if (at == 6'h22) begin e = mdl[i]; rsv_v = 1; rsv_a = i; end
    else if (at == 6'h23) begin e = {31'h0, !(rsv_v && rsv_a == i)}; if (rsv_v && rsv_a == i) mdl[i] = d; rsv_v = 0; end
    else if (at == 6'h20) begin e = mdl[i]; mdl[i] = mdl[i] + d; if (rsv_a == i) rsv_v = 0; end
    else if (w) begin for (int k = 0; k < 4; k++) if (b[k]) mdl[i][8*k +: 8] = d[8*k +: 8]; if (rsv_a == i) rsv_v = 0; end
    else e = mdl[i];
  end
  @(negedge PCLK);
  id = $urandom;
  req = 1; we = w; addr = a; be = b; wdata = d; aid = id; atop = at; prot = pr;
  #1; n = 0;
  while (!gnt && n < 20) begin @(negedge PCLK); #1; n++; end
  if (!gnt) fail("no gnt");
  @(negedge PCLK);
  req = 0; addr = $urandom; wdata = $urandom; be = $urandom; aid = $urandom; atop = $urandom; prot = $urandom; we = $urandom;
  rready = $urandom_range(1);
  #1; n = 0;
  while (!(rvalid && rready) && n < 20) begin @(negedge PCLK); rready = $urandom_range(1); #1; n++; end
  if (rdata !== e || err !== eb || rid !== id)
    fail($sformatf("OBI response %h err=%b rid=%h, expected %h %b %h", rdata, err, rid, e, eb, id));
  @(negedge PCLK);
  rready = 1;
endtask

task automatic irq_case(input int bitn);
  rd_exp(A_IRQ_STATUS, 32'(1) << bitn);
  if (!irq) fail("irq low with a status bit set");
  wr(A_IRQ_STATUS, 32'(1) << bitn);
  rd_exp(A_IRQ_STATUS, 0);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // every data bit both ways, then random words read back
  obi(1, 32'h10, 4'hF, 32'hFFFF_FFFF); obi(0, 32'h10, 4'hF, 0);
  obi(1, 32'h10, 4'hF, 32'h0);         obi(0, 32'h10, 4'hF, 0);
  for (int k = 0; k < 24; k++) begin
    logic [31:0] a;
    a = {22'h0, 8'($urandom), 2'b00};
    obi(1, a, $urandom, $urandom, 0, 3'b111);
    obi(0, a, 4'hF, 0, 0, 3'b11 << 1 | 3'($urandom_range(1)));
  end
  rd_exp(A_IRQ_STATUS, 0);
  // AMOADD and LR / SC
  obi(1, 32'h80, 4'hF, 32'h7FFF_FFFF, 6'h20);
  obi(0, 32'h80, 4'hF, 0, 6'h22);
  obi(1, 32'h80, 4'hF, 32'h1234_5678, 6'h23);
  obi(1, 32'h80, 4'hF, 32'h1234_5678, 6'h23);
  obi(0, 32'h80, 4'hF, 0);
  rd_exp(A_IRQ_STATUS, 0);
  // each error on its own
  obi(0, 32'hFFFF_FC00, 4'hF, 0);                 irq_case(IRQ_DEC);
  obi(1, 32'h0000_0400, 4'hF, 32'h1);             irq_case(IRQ_DEC);
  obi(1, 32'h300, 4'hF, 32'h1, 0, 3'b001);        irq_case(IRQ_PROT);
  obi(1, 32'h300, 4'hF, 32'h1, 6'h3F);            irq_case(IRQ_ATOP);
  obi(1, 32'h300, 4'hF, 32'h1, 6'h1F);            irq_case(IRQ_ATOP);
  @(negedge PCLK); par_inj = 1; reqpar = req;
  @(negedge PCLK); par_inj = 0;
  cycles(2);                                      irq_case(IRQ_PAR);
  // masked: pending, irq low; then left pending into reset
  wr(A_IRQ_ENABLE, 0);
  obi(0, 32'h8000_0000, 4'hF, 0);
  obi(1, 32'h300, 4'hF, 32'h1, 0, 3'b001);
  obi(1, 32'h300, 4'hF, 32'h1, 6'h3F);
  @(negedge PCLK); par_inj = 1; reqpar = req;
  @(negedge PCLK); par_inj = 0;
  cycles(2);
  if (irq) fail("irq with every source masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_STATUS, IRQ_ALL ^ (32'(1) << IRQ_DEC));
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_DEC);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low after unmasking DEC");
endtask
