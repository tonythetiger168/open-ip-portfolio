// SPDX-License-Identifier: Apache-2.0
// Audio_DSP-specific part of tb/Audio_DSP_apb_tb.sv. An soc_ss_axi_mem subordinate sits
// on the AXI4 manager pins m_*. Covered through the registers: unity gain (identity) at three placements, MUTE, x2 gain with clipping (PEAK, CLIPS), mono downmix, DONE / ERR on an AXI read error.
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
    for (int i = 0; i < 32; i++) mem.poke(s + 32'(4 * i), $urandom);
    set_job(s, d, 32);
    wr(A_GAIN, {16'd256, 16'd256}); wr(A_CTRL, 0); job_go(500); irq_check(0);
    for (int i = 0; i < 32; i++) e[i] = mem.peek(s + 32'(4 * i));
    expect_mem(d, 32, "unity gain");
    wr(A_CTRL, 2); job_go(500); irq_check(0);                         // MUTE
    for (int i = 0; i < 32; i++) e[i] = 0;
    expect_mem(d, 32, "mute");
    rd_exp(A_METER, 0);
  end
  // x2 on [20000, -100], downmix of [1000, 3000]
  s = place(0); d = s ^ 32'h4000_0000;
  mem.poke(s, {16'hFF9C, 16'd20000}); mem.poke(s + 4, {16'd3000, 16'd1000});
  set_job(s, d, 1); wr(A_GAIN, {16'd512, 16'd512}); wr(A_CTRL, 0); job_go(200); irq_check(0);
  if (mem.peek(d) !== {16'hFF38, 16'h7FFF}) fail($sformatf("x2: %h", mem.peek(d)));
  rd_exp(A_METER, {16'd1, 16'h7FFF});
  set_job(s + 4, d, 1); wr(A_GAIN, {16'd256, 16'd256}); wr(A_CTRL, 1); job_go(200); irq_check(0);
  if (mem.peek(d) !== {16'd2000, 16'd2000}) fail($sformatf("downmix: %h", mem.peek(d)));
  mem.err_lo = place(0) + 8; mem.err_hi = mem.err_lo + 4;
  set_job(place(0), place(0) ^ 32'h4000_0000, 6); wr(A_CTRL, 0);
  job_go(300); irq_check(1);
  mem.err_lo = '1; mem.err_hi = '1;
  if (mem.errors != 0) fail("AXI rule violations");
endtask
