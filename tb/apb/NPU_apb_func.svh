// SPDX-License-Identifier: Apache-2.0
// NPU-specific part of tb/NPU_apb_tb.sv. An soc_ss_axi_mem subordinate sits
// on the AXI4 manager pins m_*. Covered through the registers: the identity filter (W0 = 1) at three placements, a [1, 1, 1, 1] moving sum with bias, shift and ReLU on known data, SATURATIONS, DONE / ERR on an AXI read error.
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
    wr(A_WEIGHTS, 32'h0000_0001); wr(A_CTRL, 0);
    job_go(500); irq_check(0);
    for (int i = 0; i < 32; i++) e[i] = mem.peek(s + 32'(4 * i));
    expect_mem(d, 32, "identity");
    rd_exp(A_SATURATIONS, 0);
  end
  // x = 10, 20, 30, ... (int8); y[n] = relu(sum of the last 4 + bias) >>> 2
  s = place(0); d = s ^ 32'h4000_0000;
  for (int i = 0; i < 4; i++) mem.poke(s + 32'(4 * i), {8'(40 * i + 40), 8'(40 * i + 30), 8'(40 * i + 20), 8'(40 * i + 10)});
  set_job(s, d, 4);
  wr(A_WEIGHTS, 32'h0101_0101);
  wr(A_CTRL, (1 << 20) | (2 << 16) | 16'hFFF6);            // ReLU, shift 2, bias -10
  job_go(200); irq_check(0);
  begin
    int sat, xs [16];
    sat = 0;
    for (int n = 0; n < 16; n++) xs[n] = int'(signed'(8'(10 * n + 10)));
    for (int n = 0; n < 16; n++) begin
      int acc, y;
      acc = -10;
      for (int t = 0; t < 4; t++) if (n - t >= 0) acc += xs[n - t];
      if (acc < 0) acc = 0;
      y = acc >>> 2;
      if (y > 127) begin y = 127; sat++; end
      e[n / 4][8 * (n % 4) +: 8] = 8'(y);
    end
    expect_mem(d, 4, "moving sum");
    rd_exp(A_SATURATIONS, sat);
  end
  mem.err_lo = place(0) + 8; mem.err_hi = mem.err_lo + 4;
  set_job(place(0), place(0) ^ 32'h4000_0000, 6);
  job_go(300); irq_check(1);
  mem.err_lo = '1; mem.err_hi = '1;
  if (mem.errors != 0) fail("AXI rule violations");
endtask
