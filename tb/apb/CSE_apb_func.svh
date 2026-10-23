// SPDX-License-Identifier: Apache-2.0
// CSE-specific part of tb/CSE_apb_tb.sv: AES-128 through the registers.
// Checked: FIPS-197 C.1, the AESAVS all-zero vector, SP800-38A F.1.1 and
// all ones, both ways; random keys and blocks round-tripped; STATUS.busy
// for the whole operation; START and KEY writes while busy refused (the
// result unchanged), a KEY write with partial strobes refused.
// Covered through the registers: DONE and PROTOCOL, masked, raising irq
// and cleared.
task automatic set_key(input logic [127:0] k);
  for (int i = 0; i < 4; i++) wr(A_KEY0 + 12'(4 * i), k[127 - 32 * i -: 32]);
endtask
task automatic set_din(input logic [127:0] d);
  for (int i = 0; i < 4; i++) wr(A_DIN0 + 12'(4 * i), d[32 * i +: 32]);
endtask
task automatic get_dout(output logic [127:0] d);
  for (int i = 0; i < 4; i++) begin rd(A_DOUT0 + 12'(4 * i)); d[32 * i +: 32] = rdv; end
endtask
task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
// one block: busy seen through STATUS until DONE
task automatic op(input bit enc, input logic [127:0] d, output logic [127:0] r);
  int k;
  set_din(d);
  wr(A_CTRL, enc);
  wr(A_CMD, 1);
  rd_exp(A_STATUS, 1);
  k = 0;
  rd(A_STATUS);
  while (rdv[0] && k < 30) begin rd(A_STATUS); k++; end
  if (rdv[0]) fail("busy stuck");
  irq_expect(IRQ_DONE);
  get_dout(r);
endtask
task automatic kat(input logic [127:0] k, input logic [127:0] p, input logic [127:0] c);
  logic [127:0] r;
  set_key(k);
  op(1, p, r);
  if (r !== c) fail($sformatf("encrypt %h = %h, expected %h", p, r, c));
  op(0, c, r);
  if (r !== p) fail($sformatf("decrypt %h = %h, expected %h", c, r, p));
endtask

task automatic ip_func;
  logic [127:0] k, p, c, r;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rd_exp(A_FLAGS, 0);
  for (int i = 0; i < 4; i++) rd_exp(A_KEY0 + 12'(4 * i), 0);    // write only
  for (int i = 0; i < 4; i++) rd_exp(A_DOUT0 + 12'(4 * i), 0);
  rd_exp(A_CTRL, 1);
  wr(A_CMD, 0);                                                 // no start
  cycles(3);
  rd_exp(A_STATUS, 0);
  kat(128'h000102030405060708090a0b0c0d0e0f, 128'h00112233445566778899aabbccddeeff,
      128'h69c4e0d86a7b0430d8cdb78070b4c55a);
  kat(128'h0, 128'h0, 128'h66e94bd4ef8a2c3b884cfa59ca342b2e);
  kat(128'h2b7e151628aed2a6abf7158809cf4f3c, 128'h6bc1bee22e409f96e93d7e117393172a,
      128'h3ad77bb40d7a3660a89ecaf32466ef97);
  kat('1, '1, 128'hbcbf217cb280cf30b2517052193ab979);
  for (int t = 0; t < 8; t++) begin
    k = {$urandom, $urandom, $urandom, $urandom};
    p = {$urandom, $urandom, $urandom, $urandom};
    set_key(k);
    op(1, p, c);
    op(0, c, r);
    if (r !== p) fail("random round trip");
  end
  // refused while busy: START and a KEY write; the result is unchanged
  set_key(128'h000102030405060708090a0b0c0d0e0f);
  apb(1, A_KEY1, 32'h1234_5678, 4'h7);
  if (!rerr) fail("no PSLVERR on a partial-strobe KEY write");
  set_din(128'h00112233445566778899aabbccddeeff);
  wr(A_CTRL, 1);
  wr(A_CMD, 1);
  wr(A_KEY2, 32'hDEAD_BEEF);
  irq_expect(IRQ_PROTOCOL);
  wr(A_CMD, 1);
  irq_expect(IRQ_PROTOCOL);
  irq_expect(IRQ_DONE);
  get_dout(r);
  if (r !== 128'h69c4e0d86a7b0430d8cdb78070b4c55a) fail($sformatf("result %h after refused commands", r));
  op(1, 128'h00112233445566778899aabbccddeeff, r);              // the key is unchanged
  if (r !== 128'h69c4e0d86a7b0430d8cdb78070b4c55a) fail("KEY write while busy changed the key");
  rd_exp(A_IRQ_STATUS, 0);
  // masked: left pending into reset
  wr(A_IRQ_ENABLE, 0);
  wr(A_CMD, 1);
  wr(A_CMD, 1);
  cycles(30);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CMD, 1);                                                 // reset while busy
  cycles(4);
endtask
