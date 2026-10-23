// SPDX-License-Identifier: Apache-2.0
// GPIO-specific part of tb/GPIO_apb_tb.sv. A TB pin model drives each pin
// whose OE bit is clear (and floats it otherwise).
// Covered through the registers: OUT written and read back, driven on the
// pins with OE set, IN reading the external levels of input pins and the
// driven value of output pins, a partial write to OUT dropped with
// PSLVERR, HIGH while a pin is high (masked, raising irq, cleared).
logic [7:0] ext_v = 0;
for (genvar i = 0; i < 8; i++) begin : g_ext
  assign gpio[i] = dut.u_core.gpio_oe[i] ? 1'bz : ext_v[i];
end

task automatic ip_func;
  logic [7:0] o, e, v;
  // inputs low: no HIGH
  ext_v = 0;
  cycles(3);
  wr(A_IRQ_STATUS, IRQ_ALL);
  cycles(2);
  rd_exp(A_IRQ_STATUS, 0);
  rd_exp(A_IN, 0);
  // OUT and OE: every bit both ways
  wr(A_OUT, 32'hFF); rd_exp(A_OUT, 32'hFF);
  wr(A_OUT, 32'h00); rd_exp(A_OUT, 32'h00);
  apb(1, A_OUT, 32'h5A, 4'h1);                           // partial: dropped
  if (!rerr) fail("no PSLVERR on a partial write to OUT");
  rd_exp(A_OUT, 0);
  wr(A_IN, 32'hFF);                                      // read-only: ignored
  rd_exp(A_FLAGS, 0);                                    // no stream registers
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int k = 0; k < 40; k++) begin
    o = $urandom; e = $urandom; v = $urandom;
    if (k == 0) begin o = 8'hFF; e = 8'h00; v = 8'hFF; end
    if (k == 1) begin o = 8'h00; e = 8'hFF; v = 8'h00; end
    if (k == 2) begin o = 8'hFF; e = 8'hFF; v = 8'h00; end
    if (k == 3) begin o = 8'h00; e = 8'h00; v = 8'h00; end
    wr(A_OUT, o); wr(A_OE, e); ext_v = v;
    cycles(3);
    for (int i = 0; i < 8; i++)
      if (gpio[i] !== (e[i] ? o[i] : v[i])) fail($sformatf("pin %0d = %b", i, gpio[i]));
    rd_exp(A_IN, (e & o) | (~e & v));
    rd_exp(A_OUT, o);
    rd(A_IRQ_STATUS);
    if (rdv[IRQ_HIGH] != |((e & o) | (~e & v))) begin
      if (|((e & o) | (~e & v))) fail("HIGH not set with a pin high");
    end
    if (|((e & o) | (~e & v)) && !irq) fail("irq low with HIGH enabled");
    wr(A_IRQ_STATUS, IRQ_ALL);
  end
  // masked and left pending into reset
  wr(A_IRQ_ENABLE, 0);
  ext_v = 8'h01; wr(A_OE, 0);
  cycles(3);
  if (irq) fail("irq with HIGH masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_HIGH);
  ext_v = 0;
endtask
