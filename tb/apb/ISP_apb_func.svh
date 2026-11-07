// SPDX-License-Identifier: Apache-2.0
// ISP-specific part of tb/ISP_apb_tb.sv. An soc_ss_axi_mem subordinate sits
// on the AXI4 manager pins m_*. Covered through the registers: test-pattern frames (gain 1.0, black level 0) at three placements and STAT_SUM, black level and gain on known pixels, a frame from the sensor stream sns_* with gaps, DONE / ERR on an AXI write error.
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

logic [31:0] sq [$];
initial begin sns_valid = 0; sns_data = 0; end
always @(posedge PCLK) begin
  if (sns_valid && sns_ready) void'(sq.pop_front());
  #1;
  sns_valid = (sq.size() != 0) && ($urandom % 3 != 0);
  sns_data  = sns_valid ? sq[0] : 32'($urandom);
end
task automatic ip_func;
  logic [31:0] d, sum;
  for (int k = 0; k < 3; k++) begin
    d = place(k);
    wr(A_DST_ADDR, d); wr(A_LEN, 24); wr(A_LINE, 6);
    wr(A_CTRL, (16 << 17) | (32'(k * 85) << 1));                 // gain 1.0, black 0, seed
    job_go(400); irq_check(0);
    sum = 0;
    for (int i = 0; i < 24; i++) begin
      for (int b = 0; b < 4; b++) e[i][8*b +: 8] = 8'(4 * (i % 6) + b + i / 6) ^ 8'(k * 85);
      for (int b = 0; b < 4; b++) sum += 32'(e[i][8*b +: 8]);
    end
    expect_mem(d, 24, "test pattern");
    rd_exp(A_STAT_SUM, sum);
  end
  // sensor stream: pixels 0x10, 0x30, 0x90, 0xF0 with black 0x20 and gain 2.0
  sq.delete();
  for (int i = 0; i < 20; i++) sq.push_back(32'hF090_3010);
  wr(A_DST_ADDR, place(0)); wr(A_LEN, 20);
  wr(A_CTRL, (32 << 17) | (32'h20 << 9) | 1);
  job_go(600); irq_check(0);
  for (int i = 0; i < 20; i++) e[i] = 32'hFFE0_2000;
  expect_mem(place(0), 20, "sensor frame");
  if (sq.size() != 0) fail("sensor words not taken");
  mem.err_lo = place(0) + 8; mem.err_hi = mem.err_lo + 4;
  wr(A_LEN, 8); wr(A_CTRL, 16 << 17);
  job_go(300); irq_check(1);
  mem.err_lo = '1; mem.err_hi = '1;
  if (mem.errors != 0) fail("AXI rule violations");
endtask
