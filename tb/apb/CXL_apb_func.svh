// SPDX-License-Identifier: Apache-2.0
// CXL-specific part of tb/CXL_apb_tb.sv. The host sends M2S Req and RwD
// messages through REQ0/REQ1 and RWD0..RWD3 and reads S2M NDR and DRS
// messages from NDR and DRS0..DRS2, one transaction at a time against a
// reference memory (data, meta state, poison), so every response field is
// predicted.
// Covered through the registers: full and partial writes, reads, MemInv
// with each meta state (Cmp, Cmp-S, Cmp-E), poison set, read and cleared,
// out of range, dropped opcodes, reserved fields (each event interrupt),
// a stall with the responses unread that fills the Req FIFO and takes
// DevLoad through every grade, writes to full REQ and RWD (overflow),
// random traffic, every stream event and interrupt bit.
localparam int LINES = 16;

logic [511:0] rm [0:LINES-1];
logic [1:0]   rmt [0:LINES-1];
bit           rps [0:LINES-1];
logic [15:0]  base = 0;
logic [15:0]  ntag = 16'h0100;

function automatic logic [15:0] addr_of(input int off);
  return base + 16'(off);
endfunction
function automatic bit in_range(input int off);
  return off >= 0 && off < LINES;
endfunction
// the meta field the core acts on
function automatic logic [1:0] eff_mf(input logic [1:0] mf, input logic [2:0] snp);
  return mf == 2'b01 || mf == 2'b10 || snp[2] ? 2'b11 : mf;
endfunction

// ---------------- messages ----------------
task automatic w_req(input logic [3:0] op, input logic [1:0] mf, input logic [1:0] mv, input logic [2:0] snp,
                     input logic [15:0] a, input logic [15:0] tag);
  while (dut.full_REQ) @(negedge PCLK);
  wr(A_REQ0, {tag, a});
  wr(A_REQ1, {21'd0, snp, mv, mf, op});
endtask
// RwD beats from beat s on (beat 0 carries the header)
task automatic w_rwd(input logic [3:0] op, input logic [1:0] mf, input logic [1:0] mv, input logic [2:0] snp,
                     input bit po, input logic [15:0] a, input logic [15:0] tag, input logic [511:0] d,
                     input logic [63:0] be, input int s = 0);
  for (int b = s; b < 8; b++) begin
    while (dut.full_RWD) @(negedge PCLK);
    if (b == 0) wr(A_RWD0, {tag, a});
    wr(A_RWD1, d[64 * b +: 32]);
    wr(A_RWD2, d[64 * b + 32 +: 32]);
    wr(A_RWD3, {12'd0, po, snp, mv, mf, op, be[8 * b +: 8]});
  end
endtask
task automatic g_ndr(input logic [15:0] tag, input logic [1:0] op, input logic [1:0] mv, input int dl = 0);
  poll(A_FLAGS, 1 << FLAG_NDR_AVAIL, 1 << FLAG_NDR_AVAIL, 2000);
  rd(A_NDR);
  if (rdv[21:0] !== {2'(dl), mv, op, tag})
    fail($sformatf("NDR %h, expected tag %h opcode %0d meta %b devload %0d", rdv, tag, op, mv, dl));
endtask
task automatic g_drs(input logic [15:0] tag, input logic [1:0] mv, input bit po, input logic [511:0] d,
                     input int dl = 0);
  logic [63:0] x;
  for (int b = 0; b < 8; b++) begin
    poll(A_FLAGS, 1 << FLAG_DRS_AVAIL, 1 << FLAG_DRS_AVAIL, 2000);
    rd(A_DRS0); x[31:0] = rdv;
    rd(A_DRS1); x[63:32] = rdv;
    if (x !== d[64 * b +: 64]) fail($sformatf("DRS beat %0d: %h, expected %h", b, x, d[64 * b +: 64]));
    rd(A_DRS2);
    if (rdv[21:0] !== {b == 7, po, 2'(dl), mv, tag})
      fail($sformatf("DRS beat %0d: %h, expected tag %h meta %b poison %0d devload %0d", b, rdv, tag, mv, po, dl));
  end
endtask

// ---------------- transactions against the reference ----------------
task automatic t_write(input logic [3:0] op, input logic [1:0] mf, input logic [1:0] mv, input logic [2:0] snp,
                       input bit po, input int off, input logic [511:0] d, input logic [63:0] be);
  logic [1:0] old;
  ntag++;
  w_rwd(op, mf, mv, snp, po, addr_of(off), ntag, d, be);
  if (op == 4'd1 || op == 4'd2) begin
    old = in_range(off) ? rmt[off] : 2'b00;
    if (in_range(off)) begin
      for (int k = 0; k < 64; k++) if (op == 4'd1 || be[k]) rm[off][8 * k +: 8] = d[8 * k +: 8];
      rps[off] = po || op == 4'd2 && rps[off];
      if (eff_mf(mf, snp) == 2'b00) rmt[off] = mv;
    end
    g_ndr(ntag, 2'd0, old);
  end
endtask
task automatic t_req(input logic [3:0] op, input logic [1:0] mf, input logic [1:0] mv, input logic [2:0] snp,
                     input int off);
  logic [1:0] old, emf;
  bit         in;
  ntag++;
  in = in_range(off);
  old = in ? rmt[off] : 2'b00;
  emf = eff_mf(mf, snp);
  w_req(op, mf, mv, snp, addr_of(off), ntag);
  case (op)
    4'd1, 4'd2: begin
      g_drs(ntag, old, !in || rps[off], in ? rm[off] : 512'd0);
      if (in && op == 4'd1 && emf == 2'b00) rmt[off] = mv;
    end
    4'd0, 4'd9, 4'd10: begin
      g_ndr(ntag, op != 4'd10 && emf == 2'b00 ? (mv == 2'b11 ? 2'd1 : mv == 2'b10 ? 2'd2 : 2'd0) : 2'd0, old);
      if (in && emf == 2'b00) rmt[off] = mv;
    end
    default: cycles(5);                            // no response
  endcase
endtask
function automatic logic [511:0] rnd_line();
  logic [511:0] d;
  for (int i = 0; i < 16; i++) d[32 * i +: 32] = $urandom;
  return d;
endfunction

task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask

task automatic ip_func;
  logic [511:0] d;
  logic [15:0]  t0;
  for (int l = 0; l < LINES; l++) begin rm[l] = '0; rmt[l] = 2'b00; rps[l] = 0; end
  wr(A_IRQ_ENABLE, 0);
  base = 16'h1230;
  wr(A_CTRL, {16'd0, base});
  // reset memory, full writes (meta Shared), read back
  t_req(4'd1, 2'b11, 2'b00, 3'd0, 3);
  for (int l = 0; l < 4; l++) t_write(4'd1, 2'b00, 2'b11, 3'd0, 0, l, rnd_line(), '1);
  for (int l = 0; l < 4; l++) t_req(4'd2, 2'b11, 2'b00, 3'd1, l);
  irq_expect(IRQ_RWD_DONE);
  irq_expect(IRQ_REQ_DONE);
  irq_expect(IRQ_NDR_AVAIL);
  irq_expect(IRQ_DRS_AVAIL);
  // MemRd with Meta0-State, MemInv to each state, MemClnEvct
  t_req(4'd1, 2'b00, 2'b10, 3'd0, 0);
  t_req(4'd0, 2'b00, 2'b11, 3'd2, 0);
  t_req(4'd0, 2'b00, 2'b10, 3'd2, 1);
  t_req(4'd9, 2'b00, 2'b00, 3'd0, 2);
  t_req(4'd10, 2'b00, 2'b10, 3'd0, 3);
  t_req(4'd8, 2'b00, 2'b10, 3'd0, 3);
  // partial writes, poison set by a partial write, read, cleared by a full one
  t_write(4'd2, 2'b11, 2'b00, 3'd0, 0, 1, rnd_line(), {32'h0F0F_00FF, 32'h8001_7E00});
  t_write(4'd2, 2'b11, 2'b00, 3'd0, 1, 2, rnd_line(), 64'h00FF_0000_0000_FF00);
  t_req(4'd1, 2'b11, 2'b00, 3'd0, 2);
  irq_expect(IRQ_POISON_RD);
  t_write(4'd1, 2'b11, 2'b00, 3'd0, 0, 2, rnd_line(), '0);
  t_req(4'd1, 2'b11, 2'b00, 3'd0, 2);
  // errors: out of range, dropped opcodes, reserved fields
  t_req(4'd1, 2'b00, 2'b11, 3'd0, -1);
  t_write(4'd1, 2'b00, 2'b11, 3'd0, 0, LINES, rnd_line(), '1);
  irq_expect(IRQ_ERR_RANGE);
  t_req(4'd3, 2'b00, 2'b11, 3'd0, 0);
  t_write(4'd4, 2'b00, 2'b11, 3'd0, 0, 0, rnd_line(), '1);
  irq_expect(IRQ_ERR_OPCODE);
  t_req(4'd0, 2'b01, 2'b11, 3'd0, 1);
  t_req(4'd0, 2'b00, 2'b11, 3'd5, 1);
  irq_expect(IRQ_ERR_PROTO);

  // a stall: the responses are not read, the Req FIFO fills; DevLoad on
  // the way out: Light, Light (held in the core), then Severe, Severe,
  // Moderate, Optimal, Light
  t0 = ntag + 1;
  for (int i = 0; i < 7; i++) begin ntag++; w_req(4'd10, 2'b11, 2'b00, 3'd0, addr_of(i), ntag); end
  cycles(5);
  wr(A_REQ1, 32'h7FF);                          // REQ full: dropped
  irq_expect(IRQ_REQ_OVF);
  rd(A_FLAGS);
  if (rdv[3:0] !== 4'b0101) fail($sformatf("FLAGS %h in the Req stall", rdv));
  for (int i = 0; i < 7; i++)
    g_ndr(t0 + 16'(i), 2'd0, rmt[i], i < 2 ? 0 : i < 4 ? 3 : i == 4 ? 2 : i == 5 ? 1 : 0);
  // the same for reads (DRS); the first holds the core's DRS until all its
  // beats are read: Light, then Severe, Severe, Moderate, Optimal, Light
  t0 = ntag + 1;
  for (int i = 0; i < 6; i++) begin ntag++; w_req(4'd2, 2'b11, 2'b00, 3'd0, addr_of(i), ntag); end
  cycles(5);
  for (int i = 0; i < 6; i++)
    g_drs(t0 + 16'(i), rmt[i], rps[i], rm[i], i == 0 ? 0 : i < 3 ? 3 : i == 3 ? 2 : i == 4 ? 1 : 0);
  // a write stall: two completions unread, a MemWr waits in the core, the
  // next message's first beat waits in RWD, RWD written again: dropped
  ntag++; w_req(4'd0, 2'b11, 2'b00, 3'd0, addr_of(5), ntag);
  ntag++; w_req(4'd0, 2'b11, 2'b00, 3'd0, addr_of(6), ntag);
  d = rnd_line();
  ntag++; w_rwd(4'd1, 2'b11, 2'b00, 3'd0, 0, addr_of(7), ntag, d, '1);
  ntag++;
  wr(A_RWD0, {ntag, addr_of(8)});
  wr(A_RWD1, d[31:0]);
  wr(A_RWD2, d[63:32]);
  wr(A_RWD3, {12'd0, 1'b0, 3'd0, 2'b00, 2'b11, 4'd1, 8'hFF});
  cycles(5);
  wr(A_RWD3, 32'hFFFFF);
  irq_expect(IRQ_RWD_OVF);
  rd(A_FLAGS);
  if (rdv[3:0] !== 4'b0110) fail($sformatf("FLAGS %h in the RwD stall", rdv));
  g_ndr(ntag - 3, 2'd0, rmt[5]);
  g_ndr(ntag - 2, 2'd0, rmt[6]);
  g_ndr(ntag - 1, 2'd0, rmt[7]);
  rm[7] = d;
  rps[7] = 0;
  w_rwd(4'd1, 2'b11, 2'b00, 3'd0, 0, addr_of(8), ntag, d, '1, 1);
  g_ndr(ntag, 2'd0, rmt[8]);
  rm[8] = d;
  rps[8] = 0;
  t_req(4'd1, 2'b11, 2'b00, 3'd0, 7);
  t_req(4'd1, 2'b11, 2'b00, 3'd0, 8);
  // reading empty registers
  rd(A_NDR);
  rd(A_DRS2);

  // random traffic, the base moved
  base = 16'hEDCF;
  wr(A_CTRL, {16'd0, base});
  for (int i = 0; i < 60; i++) begin : b_rnd
    int off, r;
    logic [1:0] mf;
    logic [2:0] snp;
    r = $urandom % 100;
    off = $urandom % 100 < 10 ? 16 + $urandom % 1000 : $urandom % LINES;
    mf = $urandom % 2 ? 2'b00 : 2'b11;
    snp = $urandom % 4;
    if (r < 40) t_write($urandom % 2 ? 4'd1 : 4'd2, mf, $urandom, snp, $urandom % 5 == 0, off, rnd_line(),
                        {$urandom, $urandom});
    else if (r < 75) t_req($urandom % 2 ? 4'd1 : 4'd2, mf, $urandom, snp, off);
    else t_req($urandom % 3 == 0 ? 4'd0 : $urandom % 2 ? 4'd9 : 4'd10, mf, $urandom, snp, off);
  end
  ntag = 16'hFF7F;                              // tags with the high bits set
  t_write(4'd1, 2'b11, 2'b00, 3'd4, 0, 5, rnd_line(), '1);   // reserved SnpType
  t_write(4'd12, 2'b00, 2'b00, 3'd0, 0, 5, rnd_line(), '1);  // dropped
  t_req(4'd7, 2'b11, 2'b00, 3'd0, 4);                        // dropped
  t_req(4'd1, 2'b11, 2'b00, 3'd0, 5);
  base = 16'h0000;
  wr(A_CTRL, 0);

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[9:0] != 10'h3FF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 10; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[9:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  if (irq) fail("irq high with nothing pending");
  // NDR_AVAIL drives the pin
  wr(A_IRQ_ENABLE, 1 << IRQ_NDR_AVAIL);
  t_req(4'd0, 2'b11, 2'b00, 3'd0, 0);
  if (!irq) fail("irq low with NDR_AVAIL pending");
  wr(A_IRQ_ENABLE, 0);
endtask
