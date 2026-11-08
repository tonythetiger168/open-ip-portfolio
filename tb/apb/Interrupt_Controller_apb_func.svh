// SPDX-License-Identifier: Apache-2.0
// Interrupt_Controller-specific part of tb/Interrupt_Controller_apb_tb.sv.
// An soc_ss_axi_mem subordinate sits on m_*, the TB drives irq_src.
// Covered through the registers: PENDING and CLAIM for every source alone
// and for random source / ENABLE / SW_SET sets, cpu_irq and the CPU
// interrupt, the event log at the top of the address space (records, ring
// wrap, LOG_WP in STATE), LOG_ERR on an AXI error, LOG_EN 0.
`SOC_SS_AXI_MEM(mem, PCLK, PRESETN)
initial irq_src = 0;
bit storm = 0;   // 1: every source toggles at each negedge
always @(negedge PCLK) if (storm) irq_src <= ~irq_src;

// LOG_ERR driving irq, then LOG_WP through a full 16-bit wrap: all 32
// sources toggling every other clock keep the record writer busy
task automatic cov_tail;
  logic [31:0] w0;
  bit hi;
  rd(A_FLAGS);
  mem.err_lo = 32'hFFFF_FFF0; mem.err_hi = 32'hFFFF_FFFF;
  wr(A_LOG_BASE, 32'hFFFF_FFF0); wr(A_LOG_CTRL, (3 << 1) | 1); wr(A_ENABLE, 32'hFFFF_FFFF);
  wr(A_IRQ_STATUS, IRQ_ALL);
  irq_src = 32'h0000_0010; cycles(40); irq_src = 0;
  rd(A_IRQ_STATUS); if (!rdv[IRQ_LOG_ERR]) fail("LOG_ERR not set");
  wr(A_IRQ_ENABLE, 32'(1) << IRQ_LOG_ERR); cycles(1);
  if (irq !== 1) fail("irq low with LOG_ERR enabled");
  wr(A_IRQ_STATUS, IRQ_ALL); wr(A_IRQ_ENABLE, 0);
  mem.err_lo = '1; mem.err_hi = '1;
  mem.stall = 0;
  wr(A_LOG_BASE, 32'h0000_8000); wr(A_LOG_CTRL, (16'hFFFF << 1) | 1);
  hi = 0;
  storm = 1;
  forever begin
    rd(A_STATE);
    if (rdv[15]) hi = 1;
    if (hi && !rdv[15]) break;
    cycles(500);
  end
  storm = 0;
  @(negedge PCLK); irq_src = 0;
  mem.stall = 1;
  wr(A_LOG_CTRL, 0); wr(A_ENABLE, 0);
  cycles(40);
  irq_src = 32'h0000_0100; wr(A_ENABLE, 32'hFFFF_FFFF);
  cycles(2);
  wr(A_IRQ_ENABLE, IRQ_ALL);   // CPU left pending and enabled into the final reset
endtask
task automatic ip_func;
  logic [31:0] p;
  wr(A_ENABLE, 32'hFFFF_FFFF);
  for (int i = 0; i < 32; i++) begin
    irq_src = 32'(1) << i;
    cycles(2);
    rd_exp(A_PENDING, 32'(1) << i);
    rd_exp(A_CLAIM, 32'h8000_0000 | 32'(i));
    if (cpu_irq !== 1) fail("cpu_irq low");
  end
  irq_src = 0;
  for (int k = 0; k < 20; k++) begin
    logic [31:0] s, en, sw, c;
    s = $urandom; en = $urandom; sw = (k % 3 == 0) ? $urandom : 0;
    if (k == 0) begin s = 0; sw = 0; end
    irq_src = s; wr(A_ENABLE, en); wr(A_SW_SET, sw);
    cycles(2);
    p = (s | sw) & en;
    rd_exp(A_PENDING, p);
    c = 0;
    for (int i = 31; i >= 0; i--) if (p[i]) c = 32'h8000_0000 | 32'(i);
    rd_exp(A_CLAIM, c);
    rd(A_STATE); if (rdv[16] !== |p) fail("STATE.cpu_irq");
    if (cpu_irq !== |p) fail("cpu_irq pin");
  end
  irq_src = 0; wr(A_SW_SET, 0); wr(A_ENABLE, 32'hFFFF_FFFF);
  cycles(2);
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd_exp(A_IRQ_STATUS, 0);
  // CPU interrupt
  irq_src = 32'h0000_0100; cycles(2);
  rd(A_IRQ_STATUS); if (!rdv[IRQ_CPU]) fail("CPU interrupt not set");
  wr(A_IRQ_ENABLE, 32'(1) << IRQ_CPU); cycles(1);
  if (irq !== 1) fail("irq low");
  irq_src = 0; cycles(2);
  wr(A_IRQ_STATUS, IRQ_ALL); wr(A_IRQ_ENABLE, 0);
  cycles(1);
  if (irq !== 0) fail("irq high");
  // event log at the top of memory, ring of 3
  wr(A_LOG_BASE, 32'hFFFF_FFF0);
  wr(A_LOG_CTRL, (3 << 1) | 1);
  rd(A_STATE); p = rdv & 32'hFFFF;
  for (int k = 0; k < 5; k++) begin
    irq_src = 32'(1) << (5 * k + 1);
    poll(A_STATE, 32'hFFFF, (p + 32'(k + 1)) & 32'hFFFF, 100);
    if ((mem.peek(32'hFFFF_FFF0 + 32'(4 * ((p + k) % 3))) & 32'hFF) !== 32'(5 * k + 1)) fail($sformatf("log record %0d", k));
    irq_src = 0;
    cycles(2);
  end
  // AXI error on a record
  rd(A_STATE); p = rdv & 32'hFFFF;
  mem.err_lo = 32'hFFFF_FFF0; mem.err_hi = 32'hFFFF_FFFC;
  wr(A_IRQ_STATUS, IRQ_ALL);
  irq_src = 32'h8000_0000;
  poll(A_STATE, 32'hFFFF, (p + 1) & 32'hFFFF, 100);
  rd(A_IRQ_STATUS); if (!rdv[IRQ_LOG_ERR]) fail("LOG_ERR not set");
  mem.err_lo = '1; mem.err_hi = '1;
  irq_src = 0;
  // LOG_EN 0: no records
  wr(A_LOG_CTRL, 3 << 1);
  irq_src = 32'h0000_0003; cycles(30);
  rd_exp(A_STATE, ((p + 1) & 32'hFFFF) | (1 << 16));
  irq_src = 0;
  wr(A_ENABLE, 0); wr(A_LOG_CTRL, 0);
  cycles(2);
  wr(A_IRQ_STATUS, IRQ_ALL);
  cov_tail();
  if (mem.errors != 0) fail("AXI rule violations");
endtask
