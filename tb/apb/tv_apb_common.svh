// SPDX-License-Identifier: Apache-2.0
// Shared part of the APB wrapper ip_func() of the TV SoC IPs, included at the
// top of tb/apb/<P>_apb_func.svh: an soc_ss_axi_mem subordinate on the AXI4
// manager pins m_* and register-level helpers.
`SOC_SS_AXI_MEM(mem, PCLK, PRESETN)

// write 1 to a CMD bit, then poll STATUS bit `bsy` low
task automatic tv_job(input logic [11:0] a_cmd, input int bit_n, input logic [11:0] a_st, input int bsy, input int max);
  wr(a_cmd, 32'(1) << bit_n);
  poll(a_st, 32'(1) << bsy, 32'h0, max);
endtask
// IRQ_STATUS bit b set, irq follows IRQ_ENABLE, W1C clears everything
task automatic tv_irq(input int b, input string what);
  rd(A_IRQ_STATUS);
  if (rdv[b] !== 1'b1) fail($sformatf("%s: IRQ_STATUS bit %0d not set (%h)", what, b, rdv));
  wr(A_IRQ_ENABLE, 32'(1) << b);
  cycles(1);
  if (irq !== 1'b1) fail({what, ": irq low with the interrupt pending and enabled"});
  wr(A_IRQ_ENABLE, 0);
  cycles(1);
  if (irq !== 1'b0) fail({what, ": irq high with the interrupt masked"});
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd_exp(A_IRQ_STATUS, 0);
endtask
// bit b of IRQ_STATUS clear
task automatic tv_no_irq(input int b, input string what);
  rd(A_IRQ_STATUS);
  if (rdv[b] !== 1'b0) fail($sformatf("%s: IRQ_STATUS bit %0d set", what, b));
endtask
