// SPDX-License-Identifier: Apache-2.0
// SHA3-specific part of tb/SHA3_apb_tb.sv: cases of tb/SHA3_vec.hex (from
// Python's hashlib) run entirely through the registers: CTRL.mode and
// CMD.start, each message word through MSG0..MSG2, the digest or SHAKE
// stream read back from DIGEST0..DIGEST2 and compared, IRQ DONE after a
// digest. Also: a refused word and a reserved mode (IRQ ERR), MSG written
// while the core permutes (held, then MSG_OVF on one more write), an empty
// DIGEST read, STATUS.busy, and the interrupt pin, enabled and masked.
logic [63:0] sv [0:8191];
int          sp;

task automatic sh_put(input logic [63:0] w, input int nb, input bit last);
  poll(A_FLAGS, 32'h1 << FLAG_MSG_FULL, 0, 200);
  wr(A_MSG0, w[31:0]);
  wr(A_MSG1, w[63:32]);
  wr(A_MSG2, {27'd0, last, 4'(nb)});
endtask
task automatic sh_get(output logic [63:0] w, output bit last);
  poll(A_FLAGS, 32'h1 << FLAG_DIGEST_AVAIL, 32'h1 << FLAG_DIGEST_AVAIL, 200);
  rd(A_DIGEST0); w[31:0] = rdv;
  rd(A_DIGEST1); w[63:32] = rdv;
  rd(A_DIGEST2); last = rdv[0];
endtask
// the case at sv[sp]; sp moves past it
task automatic sh_case;
  logic [2:0]  m;
  logic [63:0] w;
  bit          l;
  int          nb, ow, nw;
  m  = sv[sp][58:56];
  ow = int'(sv[sp][55:40]);
  nb = int'(sv[sp][31:0]);
  nw = (nb + 7) / 8;
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CTRL, 32'(m));
  wr(A_CMD, 1);
  rd_exp(A_STATUS, 1);
  for (int i = 0; i < nw; i++) sh_put(sv[sp + 1 + i], (i == nw - 1) ? nb - 8 * i : 8, i == nw - 1);
  if (nw == 0) sh_put({$urandom, $urandom}, 0, 1);
  for (int i = 0; i < ow; i++) begin
    sh_get(w, l);
    if (w !== sv[sp + 1 + nw + i]) fail($sformatf("SHA3 mode %0d len %0d word %0d: %h, expected %h", m, nb, i, w, sv[sp + 1 + nw + i]));
    if (l !== (m < 3'd4 && i == ow - 1)) fail($sformatf("SHA3 mode %0d len %0d word %0d: last %b", m, nb, i, l));
  end
  if (m < 3'd4) begin
    cycles(2);
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_DONE]) fail("no DONE after the digest");
    rd_exp(A_STATUS, 0);
  end else begin
    // SHAKE keeps squeezing into DIGEST: stop the core (reserved mode), then
    // drop the word it left in the holding register
    wr(A_CTRL, 6); wr(A_CMD, 1);
    rd(A_FLAGS);
    if (rdv[FLAG_DIGEST_AVAIL]) rd(A_DIGEST2);
    rd_exp(A_FLAGS, 0);
  end
  sp = sp + 1 + nw + ow;
endtask

task automatic ip_func;
  logic [63:0] w;
  bit          l;
  if ($fopen("tb/SHA3_vec.hex", "r") != 0) $readmemh("tb/SHA3_vec.hex", sv);
  else if ($fopen("../tb/SHA3_vec.hex", "r") != 0) $readmemh("../tb/SHA3_vec.hex", sv);
  else $readmemh("../../../../tb/SHA3_vec.hex", sv);
  // the register tests may have left a word in MSG and started nothing:
  // a reserved-mode start wipes the core and drops it
  wr(A_CTRL, 7);
  wr(A_CMD, 1);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_ERR]) fail("reserved mode: no ERR");
  rd_exp(A_STATUS, 0);
  rd_exp(A_DIGEST2, 0);                              // empty: nothing popped
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, 32'h3);                           // DONE and ERR drive the pin
  // every function, then more cases (60 in all)
  sp = 0;
  for (int k = 0; k < 60 && sv[sp][63:56] != 8'hFF; k++) begin
    sh_case();
    if (k == 0 && irq !== 1'b1 && sv[0][58:56] < 3'd4) fail("irq pin low with DONE enabled");
  end
  // a refused word (short, not last) in the middle of a SHA3-256 message
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CTRL, 1); wr(A_CMD, 1);
  sh_put(64'h0123_4567_89AB_CDEF, 3, 0);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_ERR]) fail("refused word: no ERR");
  if (irq !== 1'b1) fail("irq pin low with ERR enabled");
  wr(A_IRQ_ENABLE, 0);
  cycles(1);
  if (irq !== 1'b0) fail("irq pin high with every interrupt masked");
  // the message then continues: "abc" is the FIPS 202 example message
  sh_put(64'h0000_0000_0063_6261, 3, 1);
  sh_get(w, l);
  if (w !== 64'hb225_e24f_a75d_983a) fail($sformatf("SHA3-256(abc) word 0 = %h", w));
  repeat (3) sh_get(w, l);
  if (!l) fail("SHA3-256(abc): no last on word 3");
  // MSG while the core permutes: a full SHA3-512 block, then two words
  // back to back; the second write lands while the first is held: MSG_OVF
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, IRQ_ALL);                         // the stream interrupts drive the pin too
  wr(A_CTRL, 3); wr(A_CMD, 1);
  repeat (8) sh_put({$urandom, $urandom}, 8, 0);
  wr(A_MSG0, $urandom); wr(A_MSG1, $urandom); wr(A_MSG2, 8);   // ninth word: the permutation starts
  wr(A_MSG0, $urandom); wr(A_MSG1, $urandom); wr(A_MSG2, 8);   // held in MSG
  wr(A_MSG2, 8);                                                // dropped
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_MSG_OVF]) fail("no MSG_OVF on a write while MSG is full");
  if (!rdv[IRQ_MSG_DONE]) fail("no MSG_DONE");
  // SHAKE128: two words of output, back-pressure through DIGEST, then wiped
  wr(A_CTRL, 4); wr(A_CMD, 1);
  sh_put({$urandom, $urandom}, 5, 1);
  cycles(40);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_DIGEST_AVAIL]) fail("no DIGEST_AVAIL");
  sh_get(w, l); sh_get(w, l);
  if (l) fail("SHAKE word with last set");
  wr(A_CTRL, 6); wr(A_CMD, 1);
  cycles(2);
  rd_exp(A_STATUS, 0);
  // drop the word the core left in DIGEST before the wipe
  rd(A_FLAGS);
  if (rdv[FLAG_DIGEST_AVAIL]) rd(A_DIGEST2);
  wr(A_IRQ_ENABLE, 0);
  wr(A_CTRL, 1);
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask
