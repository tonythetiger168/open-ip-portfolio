// SPDX-License-Identifier: Apache-2.0
// DMA-specific part of tb/DMA_apb_tb.sv. An soc_ss_axi_mem subordinate sits
// on the AXI4 manager pins m_*. Covered through the registers: COPY and FILL
// on every channel, all four channels queued with one CMD write (served in
// round-robin order, one DONEn each), CHECKSUM, STATUS (PENDING, BUSY,
// ACTIVE_CH, ERR), buffers in low memory, at the top of the address space
// and across 4 KB, DONEn / ERR interrupts and irq masking, an AXI error.
`SOC_SS_AXI_MEM(mem, PCLK, PRESETN)

logic [31:0] base [4];
function automatic logic [11:0] a_ch(input int c, input int r);   // r: 0 SRC, 1 DST, 2 LEN, 3 FILL
  return 12'(12'h014 + 16 * c + 4 * r);
endfunction
task automatic ip_func;
  logic [31:0] sum;
  if (A_SRC1 !== a_ch(1, 0) || A_FILL3 !== a_ch(3, 3)) fail("channel register layout");
  base[0] = 32'h0000_0040; base[1] = 32'hBFFF_FF00; base[2] = 32'h8000_0FC0; base[3] = 32'h0123_4560;
  // one channel at a time: COPY then FILL
  for (int c = 0; c < 4; c++) begin
    for (int i = 0; i < 24; i++) mem.poke(base[c] + 32'(4 * i), $urandom);
    wr(a_ch(c, 0), base[c]); wr(a_ch(c, 1), base[c] ^ 32'h4000_0000); wr(a_ch(c, 2), 24);
    wr(a_ch(c, 3), 32'hF111_0000 | 32'(c));
    for (int m = 0; m < 2; m++) begin
      wr(A_MODE, 32'(m) << c);
      wr(A_CMD, 32'(1) << c);
      poll(A_STATUS, 32'h1F, 32'h0, 600);
      sum = 0;
      for (int i = 0; i < 24; i++) begin
        logic [31:0] x;
        x = m ? (32'hF111_0000 | 32'(c)) : mem.peek(base[c] + 32'(4 * i));
        sum += x;
        if (mem.peek((base[c] ^ 32'h4000_0000) + 32'(4 * i)) !== x) begin fail($sformatf("ch%0d mode %0d word %0d", c, m, i)); break; end
      end
      rd_exp(A_CHECKSUM, sum);
      rd(A_STATUS);
      if (rdv[6:5] !== 2'(c)) fail("STATUS.active_ch");
      rd_exp(A_IRQ_STATUS, 32'(1) << c);
      wr(A_IRQ_ENABLE, 32'(1) << c); cycles(1);
      if (irq !== 1) fail("irq low with DONEn enabled");
      wr(A_IRQ_STATUS, IRQ_ALL); cycles(1);
      if (irq !== 0) fail("irq high after clearing");
      wr(A_IRQ_ENABLE, 0);
    end
  end
  // all four queued at once: four DONEn, every buffer copied
  wr(A_MODE, 0);
  for (int c = 0; c < 4; c++) for (int i = 0; i < 24; i++) mem.poke(base[c] + 32'(4 * i), $urandom);
  wr(A_CMD, 32'hF);
  rd(A_STATUS);
  if (rdv[3:0] == 0 && rdv[4] == 0) fail("nothing pending or busy after CMD");
  poll(A_STATUS, 32'h1F, 32'h0, 2000);
  rd_exp(A_IRQ_STATUS, 32'hF);
  for (int c = 0; c < 4; c++)
    for (int i = 0; i < 24; i++)
      if (mem.peek((base[c] ^ 32'h4000_0000) + 32'(4 * i)) !== mem.peek(base[c] + 32'(4 * i))) begin fail($sformatf("queued ch%0d", c)); break; end
  wr(A_IRQ_STATUS, IRQ_ALL);
  // AXI read error on channel 2
  mem.err_lo = base[2] + 8; mem.err_hi = mem.err_lo + 4;
  wr(A_CMD, 32'h4);
  poll(A_STATUS, 32'h1F, 32'h0, 600);
  rd(A_STATUS); if (!rdv[7]) fail("STATUS.err");
  rd_exp(A_IRQ_STATUS, (32'(1) << IRQ_ERR) | 32'h4);
  wr(A_IRQ_STATUS, IRQ_ALL);
  mem.err_lo = '1; mem.err_hi = '1;
  rd(A_CYCLES); if (rdv == 0) fail("CYCLES");
  if (mem.errors != 0) fail("AXI rule violations");
endtask
