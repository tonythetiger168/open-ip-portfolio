// SPDX-License-Identifier: Apache-2.0
// Timer_WDT-specific part of tb/Timer_WDT_apb_tb.sv. An soc_ss_axi_mem
// subordinate sits on m_*. Covered through the registers: COUNT with a
// prescaler, periodic TIMER interrupts and timestamp records at the top of
// the address space (TS_WP, ring wrap, record values rising by PERIOD + 1),
// TS_ERR on an AXI error, the watchdog: kicks through CMD hold it off, BARK,
// the bite on wdt_reset (pin and WDT_STATE), cleared by a kick.
`SOC_SS_AXI_MEM(mem, PCLK, PRESETN)

task automatic ip_func;
  logic [31:0] c0, c1, r0, r1;
  wr(A_CTRL, 3);                                   // prescale 3: a tick every 4 clocks
  rd(A_COUNT); c0 = rdv;
  cycles(80);
  rd(A_COUNT); c1 = rdv;
  if (c1 - c0 < 19 || c1 - c0 > 23) fail($sformatf("COUNT advanced %0d in 80+ clocks", c1 - c0));
  // timer and records: ring of 4 words at the top of memory
  wr(A_TS_BASE, 32'hFFFF_FFF0); wr(A_TS_WORDS, 4); wr(A_PERIOD, 29);
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CTRL, (1 << 17) | (1 << 16) | 0);           // prescale 0, timer, records
  poll(A_TS_STATE, 32'hFFFF, 6, 400);
  wr(A_CTRL, 0);
  cycles(10);
  rd(A_IRQ_STATUS); if (!rdv[IRQ_TIMER]) fail("TIMER not set");
  wr(A_IRQ_ENABLE, 32'(1) << IRQ_TIMER); cycles(1);
  if (irq !== 1) fail("irq low with TIMER enabled");
  wr(A_IRQ_STATUS, IRQ_ALL); wr(A_IRQ_ENABLE, 0);
  rd(A_TS_STATE); if (rdv[31:16] !== 0) fail("TS_MISSED with a 30-tick period");
  // records 2..5 are in the ring, 30 ticks apart
  for (int r = 2; r < 5; r++) begin
    r0 = mem.peek(32'hFFFF_FFF0 + 32'(4 * (r % 4)));
    r1 = mem.peek(32'hFFFF_FFF0 + 32'(4 * ((r + 1) % 4)));
    if (r1 - r0 !== 30) fail($sformatf("records %0d, %0d: %0d and %0d", r, r + 1, r0, r1));
  end
  // AXI error on a record
  mem.err_lo = 32'hFFFF_FFF0; mem.err_hi = 32'hFFFF_FFFF;
  wr(A_CTRL, (1 << 17) | (1 << 16));
  cycles(80);
  wr(A_CTRL, 0);
  cycles(30);
  rd(A_IRQ_STATUS); if (!rdv[IRQ_TS_ERR]) fail("TS_ERR not set");
  mem.err_lo = '1; mem.err_hi = '1;
  wr(A_IRQ_STATUS, IRQ_ALL);
  // watchdog: load 20 ticks of 2 clocks, kick every ~25 clocks
  wr(A_WDT_LOAD, 20);
  wr(A_CTRL, (1 << 18) | 1);
  for (int k = 0; k < 6; k++) begin cycles(15); wr(A_CMD, 1); end
  rd(A_IRQ_STATUS); if (rdv[IRQ_BARK]) fail("BARK although kicked");
  rd(A_WDT_COUNT); if (rdv > 20) fail("WDT_COUNT above WDT_LOAD");
  cycles(50);
  rd(A_IRQ_STATUS); if (!rdv[IRQ_BARK]) fail("no BARK");
  rd_exp(A_WDT_STATE, 0);
  cycles(50);
  rd_exp(A_WDT_STATE, 1);
  if (wdt_reset !== 1) fail("wdt_reset pin low after the bite");
  wr(A_CMD, 1);
  rd_exp(A_WDT_STATE, 0);
  if (wdt_reset !== 0) fail("wdt_reset not cleared by a kick");
  wr(A_CTRL, 0);
  cycles(2);
  wr(A_IRQ_STATUS, IRQ_ALL);
  if (mem.errors != 0) fail("AXI rule violations");
endtask
