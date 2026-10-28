// SPDX-License-Identifier: Apache-2.0
// Ethernet_RS_FEC-specific part of tb/Ethernet_RS_FEC_apb_tb.sv: cases of
// tb/Ethernet_RS_FEC_vec.hex run entirely through the registers. Each
// message goes in through ENC_IN, beat by beat, and the codeword read back
// from ENC_OUT must be the reference codeword; the received word goes in
// through DEC_IN and DEC_OUT must give the reference output and bad flag,
// with CORR / UNCORR and STATUS.st_nsym. Also: correction and indication
// bypass from CTRL, realignment on both inputs (ERESYNC / DRESYNC), ENC_IN
// and DEC_IN held while the output side is full and then overflowing,
// empty reads, interrupts on the pin and masked, pending into the reset.
logic [9:0] fv [0:60000];

// one 320-bit beat through an input stream (11 words: data, then first)
task automatic fec_put(input logic [11:0] base, input int ffull, input logic [319:0] d, input bit f);
  poll(A_FLAGS, 32'h1 << ffull, 0, 200);
  for (int k = 0; k < 10; k++) wr(base + 12'(4 * k), d[32*k +: 32]);
  wr(base + 12'd40, {31'd0, f});
endtask
// one beat out of an output stream; reading word 10 pops it
task automatic fec_get(input logic [11:0] base, input int favail, output logic [319:0] d,
                       output logic [1:0] fb);
  poll(A_FLAGS, 32'h1 << favail, 32'h1 << favail, 400);
  for (int k = 0; k < 10; k++) begin rd(base + 12'(4 * k)); d[32*k +: 32] = rdv; end
  rd(base + 12'd40); fb = rdv[1:0];
endtask

task automatic fec_enc(input logic [5439:0] m, input logic [5439:0] cw, input string what);
  logic [319:0] d;
  logic [1:0]   fb;
  for (int b = 0; b < 17; b++) begin
    fec_put(A_ENC_IN0, FLAG_ENC_IN_FULL, m[320*b +: 320], b == 0);
    fec_get(A_ENC_OUT0, FLAG_ENC_OUT_AVAIL, d, fb);
    if (d !== cw[320*b +: 320] || fb[0] !== (b == 0))
      fail($sformatf("%s: ENC_OUT beat %0d mismatch", what, b));
  end
endtask

task automatic fec_dec(input logic [5439:0] rx, input logic [5439:0] ex, input bit bad, input string what);
  logic [319:0] d;
  logic [1:0]   fb;
  for (int b = 0; b < 17; b++) fec_put(A_DEC_IN0, FLAG_DEC_IN_FULL, rx[320*b +: 320], b == 0);
  for (int b = 0; b < 17; b++) begin
    fec_get(A_DEC_OUT0, FLAG_DEC_OUT_AVAIL, d, fb);
    if (d !== ex[320*b +: 320]) fail($sformatf("%s: DEC_OUT beat %0d data mismatch", what, b));
    if (fb !== {bad, b == 0}) fail($sformatf("%s: DEC_OUT beat %0d first / bad %b", what, b, fb));
  end
endtask

// case n of the vector file: message, codeword, received word, expected output
task automatic fec_case(input int n, output logic [5439:0] m, output logic [5439:0] cw,
                        output logic [5439:0] rx, output logic [5439:0] ex, output logic [9:0] h);
  int p;
  p = 2147 * n;
  h = fv[p];
  m = '0;
  for (int i = 0; i < 514; i++) m[10*i +: 10] = fv[p + 1 + i];
  for (int i = 0; i < 544; i++) begin
    cw[10*i +: 10] = fv[p + 515 + i];
    rx[10*i +: 10] = fv[p + 1059 + i];
    ex[10*i +: 10] = fv[p + 1603 + i];
  end
endtask

task automatic irq_exp(input logic [31:0] e, input string what);
  rd(A_IRQ_STATUS);
  if ((rdv & 32'hF) !== e) fail($sformatf("%s: IRQ_STATUS %h, expected %h", what, rdv & 32'hF, e));
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask

task automatic ip_func;
  logic [5439:0] m, cw, rx, ex;
  logic [9:0]    h;
  logic [319:0]  d;
  logic [1:0]    fb;
  // the vectors, from the repository root, sim/ or the coverage build directory
  if ($fopen("tb/Ethernet_RS_FEC_vec.hex", "r") != 0) $readmemh("tb/Ethernet_RS_FEC_vec.hex", fv);
  else if ($fopen("../tb/Ethernet_RS_FEC_vec.hex", "r") != 0) $readmemh("../tb/Ethernet_RS_FEC_vec.hex", fv);
  else $readmemh("../../../../tb/Ethernet_RS_FEC_vec.hex", fv);
  wr(A_CTRL, 0);
  // drop what the register tests may have left in the streams
  rd(A_FLAGS);
  if (rdv[FLAG_ENC_OUT_AVAIL]) rd(A_ENC_OUT10);
  if (rdv[FLAG_DEC_OUT_AVAIL]) rd(A_DEC_OUT10);
  cycles(100);
  rd(A_FLAGS);
  while (rdv[FLAG_ENC_OUT_AVAIL] || rdv[FLAG_DEC_OUT_AVAIL]) begin
    if (rdv[FLAG_ENC_OUT_AVAIL]) rd(A_ENC_OUT10);
    if (rdv[FLAG_DEC_OUT_AVAIL]) rd(A_DEC_OUT10);
    cycles(100);
    rd(A_FLAGS);
  end
  rd_exp(A_ENC_OUT10, 0);                            // empty: nothing popped
  rd_exp(A_DEC_OUT10, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, 32'hF);                           // the core's interrupts drive the pin
  // realignment on both inputs: 3 beats, then a new codeword (clean, case 0)
  fec_case(0, m, cw, rx, ex, h);
  for (int b = 0; b < 3; b++) begin
    fec_put(A_ENC_IN0, FLAG_ENC_IN_FULL, m[320*b +: 320], b == 0);
    fec_get(A_ENC_OUT0, FLAG_ENC_OUT_AVAIL, d, fb);
    fec_put(A_DEC_IN0, FLAG_DEC_IN_FULL, rx[320*b +: 320], b == 0);
  end
  fec_enc(m, cw, "case 0 after realignment");
  irq_exp(32'h1 << IRQ_ERESYNC, "encoder realignment");
  fec_dec(rx, ex, 0, "case 0 after realignment");
  cycles(5);
  irq_exp(32'h1 << IRQ_DRESYNC, "decoder realignment");
  // a correctable case (15 errors), an uncorrectable one (16 errors)
  fec_case(4, m, cw, rx, ex, h);
  fec_enc(m, cw, "case 4");
  fec_dec(rx, ex, h[4], "case 4");
  if (irq !== 1'b1) fail("irq pin low with CORR enabled");
  irq_exp(32'h1 << IRQ_CORR, "case 4");
  if (irq !== 1'b0) fail("irq pin high after clearing");
  rd_exp(A_STATUS, {28'd0, h[3:0]});
  fec_case(16, m, cw, rx, ex, h);
  fec_enc(m, cw, "case 16");
  fec_dec(rx, ex, h[4], "case 16");
  irq_exp(32'h1 << IRQ_UNCORR, "case 16");
  rd_exp(A_STATUS, 0);
  // indication bypass: not marked, UNCORR still raised
  wr(A_CTRL, 32'h2);
  fec_dec(rx, ex, 0, "case 16, indication bypassed");
  irq_exp(32'h1 << IRQ_UNCORR, "case 16, indication bypassed");
  // correction bypass: case 4 passes uncorrected and is reported bad
  wr(A_CTRL, 32'h1);
  fec_case(4, m, cw, rx, ex, h);
  fec_dec(rx, rx, 1, "case 4, correction bypassed");
  irq_exp(32'h1 << IRQ_UNCORR, "case 4, correction bypassed");
  wr(A_CTRL, 0);
  // ENC_IN held while ENC_OUT and the encoder are full, then an overflow
  fec_case(2, m, cw, rx, ex, h);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int b = 0; b < 3; b++) begin
    for (int k = 0; k < 10; k++) wr(A_ENC_IN0 + 12'(4 * k), m[320*b +: 320] >> (32 * k));
    wr(A_ENC_IN10, {31'd0, b == 0});
  end
  rd(A_FLAGS);
  if (!rdv[FLAG_ENC_IN_FULL]) fail("ENC_IN not held with ENC_OUT full");
  for (int k = 0; k < 10; k++) wr(A_ENC_IN0 + 12'(4 * k), 0);
  wr(A_ENC_IN10, 0);                                 // dropped
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_ENC_IN_OVF]) fail("ENC_IN_OVF not set");
  wr(A_IRQ_STATUS, IRQ_ALL);
  for (int b = 0; b < 3; b++) begin
    fec_get(A_ENC_OUT0, FLAG_ENC_OUT_AVAIL, d, fb);
    if (d !== cw[320*b +: 320]) fail($sformatf("held ENC_OUT beat %0d mismatch", b));
  end
  wr(A_IRQ_STATUS, IRQ_ALL);
  // DEC_IN held while DEC_OUT and the decoder are full, then an overflow;
  // the held beat starts the next codeword once DEC_OUT is read
  for (int b = 0; b < 17; b++) fec_put(A_DEC_IN0, FLAG_DEC_IN_FULL, rx[320*b +: 320], b == 0);
  cycles(60);
  for (int k = 0; k < 10; k++) wr(A_DEC_IN0 + 12'(4 * k), rx[32*k +: 32]);
  wr(A_DEC_IN10, 1);
  rd(A_FLAGS);
  if (!rdv[FLAG_DEC_IN_FULL]) fail("DEC_IN not held with DEC_OUT full");
  if (irq !== 1'b1) fail("irq pin low with DEC_OUT_AVAIL enabled");
  wr(A_DEC_IN10, 0);                                 // dropped
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_DEC_IN_OVF]) fail("DEC_IN_OVF not set");
  wr(A_IRQ_STATUS, 32'h1 << IRQ_DEC_IN_OVF);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_DEC_IN_OVF]) fail("DEC_IN_OVF not cleared");
  for (int r = 0; r < 2; r++) begin
    for (int b = 0; b < 17; b++) begin
      fec_get(A_DEC_OUT0, FLAG_DEC_OUT_AVAIL, d, fb);
      if (d !== ex[320*b +: 320] || fb !== {1'b0, b == 0}) fail($sformatf("held DEC_OUT %0d beat %0d mismatch", r, b));
    end
    if (r == 0) for (int b = 1; b < 17; b++) fec_put(A_DEC_IN0, FLAG_DEC_IN_FULL, rx[320*b +: 320], 0);
  end
  wr(A_IRQ_STATUS, IRQ_ALL);
  // masked: the core's interrupts set IRQ_STATUS without the pin, and stay
  // pending into the reset (the encoder realigns, the decoder corrects)
  wr(A_IRQ_ENABLE, 0);
  fec_case(2, m, cw, rx, ex, h);
  fec_enc(m, cw, "case 2");
  fec_dec(rx, ex, 0, "case 2");
  fec_case(16, m, cw, rx, ex, h);
  fec_dec(rx, ex, 1, "case 16 masked");
  for (int b = 0; b < 2; b++) begin
    fec_put(A_DEC_IN0, FLAG_DEC_IN_FULL, rx[320*b +: 320], 1);
  end
  // and both inputs overflow (masked): ENC_OUT and DEC_OUT left full
  for (int b = 0; b < 4; b++) begin
    for (int k = 0; k < 10; k++) wr(A_ENC_IN0 + 12'(4 * k), m[320*b +: 320] >> (32 * k));
    wr(A_ENC_IN10, {31'd0, b == 0});
  end
  for (int b = 1; b < 17; b++) fec_put(A_DEC_IN0, FLAG_DEC_IN_FULL, rx[320*b +: 320], 0);
  cycles(60);
  wr(A_DEC_IN10, 1);
  wr(A_DEC_IN10, 1);
  cycles(5);
  rd(A_IRQ_STATUS);
  if ((rdv & 32'hF) !== 32'hF || !rdv[IRQ_ENC_IN_OVF] || !rdv[IRQ_DEC_IN_OVF])
    fail($sformatf("masked interrupts not all pending (%h)", rdv));
  if (irq !== 1'b0) fail("irq pin high with every interrupt masked");
endtask
