// SPDX-License-Identifier: Apache-2.0
// GPU-specific part of tb/GPU_apb_tb.sv. An soc_ss_axi_mem subordinate sits
// on the AXI4 manager pins m_*. Covered through the registers: COPY, FILL, BLEND (ALPHA 256 and 0) and INVERT at three buffer placements, PIXELS, CYCLES, DONE / ERR interrupts on an AXI read error, irq masking.
`SOC_SS_AXI_MEM(mem, PCLK, PRESETN)

// one job through the registers; ends when STATUS.busy is 0
task automatic job_go(input int max);
  wr(A_CMD, 32'h1);
  poll(A_STATUS, 32'h1, 32'h0, max);
endtask
// DONE (and ERR when e) set, irq follows IRQ_ENABLE, W1C clears
task automatic irq_check(input bit e);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_DONE] !== 1'b1) fail("DONE not set after a job");
  if (rdv[IRQ_ERR] !== e) fail($sformatf("ERR = %b, expected %b", rdv[IRQ_ERR], e));
  rd(A_STATUS);
  if (rdv[1] !== e) fail("STATUS.err");
  wr(A_IRQ_ENABLE, 32'(1) << IRQ_DONE);
  cycles(1);
  if (irq !== 1'b1) fail("irq low with DONE pending and enabled");
  wr(A_IRQ_STATUS, IRQ_ALL);
  cycles(1);
  if (irq !== 1'b0) fail("irq high after clearing IRQ_STATUS");
  wr(A_IRQ_ENABLE, 0);
  rd(A_CYCLES);
  if (rdv == 0) fail("CYCLES = 0 after a job");
endtask
task automatic set_job(input logic [31:0] s, input logic [31:0] d, input int n);
  wr(A_SRC_ADDR, s); wr(A_DST_ADDR, d); wr(A_LEN, 32'(n));
endtask
logic [31:0] e [64];   // expected words of the last job
task automatic expect_mem(input logic [31:0] d, input int n, input string what);
  for (int i = 0; i < n; i++)
    if (mem.peek(d + 32'(4 * i)) !== e[i]) begin
      fail($sformatf("%s word %0d: %h, expected %h", what, i, mem.peek(d + 32'(4 * i)), e[i]));
      break;
    end
endtask
// the three buffer placements every IP is run at: low memory, the top of the
// address space (every address bit toggles), across a 4 KB boundary
function automatic logic [31:0] place(input int k);
  return (k == 0) ? 32'h0000_0040 : (k == 1) ? 32'hBFFF_FF00 : 32'h8000_0FC0;
endfunction

task automatic ip_func;
  logic [31:0] s, d;
  for (int k = 0; k < 3; k++) begin
    s = place(k); d = s ^ 32'h4000_0000;
    for (int i = 0; i < 40; i++) mem.poke(s + 32'(4 * i), $urandom);
    for (int m = 0; m < 5; m++) begin
      set_job(s, d, 40);
      wr(A_COLOR, 32'hA5C3_0FF0 ^ 32'(m));
      // mode, alpha: COPY, FILL, BLEND alpha 256 (= src), BLEND alpha 0 (= COLOR), INVERT
      wr(A_CTRL, (m == 0) ? 0 : (m == 1) ? 1 : (m == 2) ? (2 | (256 << 2)) : (m == 3) ? 2 : 3);
      job_go(400);
      for (int i = 0; i < 40; i++) begin
        logic [31:0] x;
        x = mem.peek(s + 32'(4 * i));
        e[i] = (m == 0 || m == 2) ? x : (m == 1 || m == 3) ? (32'hA5C3_0FF0 ^ 32'(m)) : {x[31:24], ~x[23:0]};
      end
      expect_mem(d, 40, $sformatf("mode %0d", m));
      rd_exp(A_PIXELS, 40);
      irq_check(0);
    end
  end
  // AXI read error
  mem.err_lo = place(0) + 16; mem.err_hi = mem.err_lo + 4;
  set_job(place(0), place(0) ^ 32'h4000_0000, 10); wr(A_CTRL, 0);
  job_go(400);
  irq_check(1);
  mem.err_lo = '1; mem.err_hi = '1;
  if (mem.errors != 0) fail("AXI rule violations");
endtask
