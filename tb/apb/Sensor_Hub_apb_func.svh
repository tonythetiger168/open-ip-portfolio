// SPDX-License-Identifier: Apache-2.0
// Sensor_Hub-specific part of tb/Sensor_Hub_apb_tb.sv. An soc_ss_axi_mem subordinate sits
// on the AXI4 manager pins m_*. Covered through the registers: batches at three placements with averaging of 1 and 4 samples, packing, LAST_AVG, DROPS = 0, the WAKE interrupt above THRESHOLD (and none below or with WAKE_EN 0), DONE / ERR on an AXI write error.
`SOC_SS_AXI_MEM(mem, PCLK, PRESETN)
int panel_pct = 75;   // Display panel model: ready percentage

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
  wr(A_IRQ_ENABLE, e ? 32'(1) << IRQ_ERR : 32'(1) << IRQ_DONE);
  cycles(1);
  if (irq !== 1'b1) fail("irq low with DONE / ERR pending and enabled");
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
// coverage tail: odd lengths at word offsets that toggle address bits 2..6
// and 30, an AXI error response on each direction the IP uses, a
// 65535-word job (every LEN and count bit), and an interrupt left pending
// into the reset that ends the TB
task automatic cov_tail(input int maxpoll);
  rd_exp(A_FLAGS, 0);
  sq.delete();
  for (int i = 0; i < 140000; i++) sq.push_back(16'(i));
  wr(A_CTRL, 0);
  for (int k = 0; k < 4; k++) begin
    wr(A_DST_ADDR, (k % 2) ? 32'h0000_0054 : 32'h4000_0054);
    wr(A_LEN, (k < 2) ? 7 : 1);
    job_go(400);
  end
  mem.err_lo = 32'h0000_0054; mem.err_hi = 32'h0000_0060;   // write error (BRESP SLVERR)
  wr(A_DST_ADDR, 32'h0000_0054); wr(A_LEN, 3);
  job_go(400); irq_check(1);
  mem.err_lo = '1; mem.err_hi = '1;
  wr(A_DST_ADDR, 32'h2000_0000);
  mem.stall = 0;
  wr(A_LEN, 32'hFFFF);
  job_go(maxpoll);
  mem.stall = 1;
  // write path blocked: every word after the FIFO fills is dropped (DROPS saturates)
  sq.delete(); for (int i = 0; i < 140000; i++) sq.push_back(16'(i));
  wr(A_LEN, 100); mem.aw_hold = 1;
  wr(A_CMD, 1);
  while (dut.u_core.drops != 16'hFFFF) cycles(100);
  mem.aw_hold = 0;
  poll(A_STATUS, 1, 0, 2000);
  rd(A_SAMPLE); if (rdv[31:16] !== 16'hFFFF) fail("DROPS did not saturate");
  wr(A_IRQ_ENABLE, IRQ_ALL);   // DONE left pending and enabled into the final reset
endtask


logic [15:0] sq [$];
initial begin sns_valid = 0; sns_data = 0; end
always @(posedge PCLK) begin
  if (PRESETN && sns_valid && dut.u_core.take) void'(sq.pop_front());
  #1;
  sns_valid = (sq.size() != 0) && ($urandom % 2 == 0);
  sns_data  = sns_valid ? sq[0] : 16'($urandom);
end
task automatic ip_func;
  logic [31:0] d;
  for (int k = 0; k < 3; k++) begin
    d = place(k);
    sq.delete();
    for (int i = 0; i < 2 * 16 * (k == 1 ? 4 : 1); i++) sq.push_back(16'(16'h0100 * k + i));
    wr(A_DST_ADDR, d); wr(A_LEN, 16);
    wr(A_CTRL, (32'h7FFF << 4) | (k == 1 ? 2 : 0) | 8);          // wake above 0x7FFF: never
    job_go(2000); irq_check(0);
    for (int w = 0; w < 16; w++) begin
      logic [15:0] a [2];
      for (int h = 0; h < 2; h++) begin
        int n, sum;
        n = (k == 1) ? 4 : 1; sum = 0;
        for (int j = 0; j < n; j++) sum += 16'h0100 * k + (2 * w + h) * n + j;
        a[h] = 16'(sum / n);
      end
      e[w] = {a[1], a[0]};
    end
    expect_mem(d, 16, "batch");
    rd(A_SAMPLE);
    if (rdv[31:16] !== 0) fail("DROPS");
    if (rdv[15:0] !== e[15][31:16]) fail("LAST_AVG");
    rd(A_IRQ_STATUS); if (rdv[IRQ_WAKE]) fail("WAKE below the threshold");
  end
  // wake-up: one sample above THRESHOLD
  sq.delete();
  for (int i = 0; i < 8; i++) sq.push_back(i == 5 ? 16'h9000 : 16'h0010);
  wr(A_LEN, 4); wr(A_CTRL, (32'h8000 << 4) | 8);
  job_go(800);
  rd(A_IRQ_STATUS); if (!rdv[IRQ_WAKE]) fail("no WAKE above the threshold");
  wr(A_IRQ_ENABLE, 32'(1) << IRQ_WAKE); cycles(1);
  if (irq !== 1) fail("irq low with WAKE enabled");
  irq_check(0);
  mem.err_lo = place(0) + 4; mem.err_hi = mem.err_lo + 4;
  sq.delete(); for (int i = 0; i < 8; i++) sq.push_back(16'(i));
  wr(A_DST_ADDR, place(0)); wr(A_LEN, 4); wr(A_CTRL, 0);
  job_go(800); irq_check(1);
  mem.err_lo = '1; mem.err_hi = '1;
  cov_tail(200000);
  if (mem.errors != 0) fail("AXI rule violations");
endtask
