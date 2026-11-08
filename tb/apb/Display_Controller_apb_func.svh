// SPDX-License-Identifier: Apache-2.0
// Display_Controller-specific part of tb/Display_Controller_apb_tb.sv. An soc_ss_axi_mem subordinate sits
// on the AXI4 manager pins m_*. Covered through the registers: scan-out of frames at three placements to a panel model with random ready, pixel order, hsync every LINE_WORDS pixels and vsync on the last, FRAME_CRC (and the CRC-32 check value of 12345678), UNDERRUNS = 0 with a slow panel, DONE / ERR on an AXI read error.
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
  panel_pct = 100;   // the panel always ready: underruns with a stalling memory
  for (int k = 0; k < 4; k++) begin
    wr(A_SRC_ADDR, (k % 2) ? 32'h4000_0054 : 32'h0000_0054);
    wr(A_LEN, (k < 2) ? 7 : 1);
    job_go(400);
  end
  wr(A_SRC_ADDR, 32'h1000_0000);
  wr(A_LEN, 32'hFFFF);
  job_go(maxpoll);
  mem.stall = 1;
  rd(A_UNDERRUNS); if (rdv == 0) fail("no UNDERRUNS with an always-ready panel and a stalling memory");
  wr(A_IRQ_ENABLE, IRQ_ALL);   // DONE left pending and enabled into the final reset
endtask


logic [31:0] got [$];
int          lw, nf;
initial pix_ready = 0;
assign lw = int'(dut.u_core.line_words);
assign nf = int'(dut.u_core.xfer_len);
always @(posedge PCLK) begin
  if (dut.u_core.go) got.delete();
  if (PRESETN && pix_valid && pix_ready) begin
    got.push_back(pix_data);
    if (pix_vsync !== (got.size() == nf)) fail("vsync");
    if (pix_hsync !== (lw == 0 || got.size() % lw == 0 || got.size() == nf)) fail("hsync");
  end
  #1 pix_ready = ($urandom % 100) < panel_pct;
end
task automatic ip_func;
  logic [31:0] s;
  for (int k = 0; k < 3; k++) begin
    s = place(k);
    for (int i = 0; i < 30; i++) mem.poke(s + 32'(4 * i), $urandom);
    wr(A_SRC_ADDR, s); wr(A_LEN, 30); wr(A_LINE, 7 + k);
    job_go(600); irq_check(0);
    if (got.size() != 30) fail($sformatf("%0d pixels sent", got.size()));
    else for (int i = 0; i < 30; i++) if (got[i] !== mem.peek(s + 32'(4 * i))) begin fail($sformatf("pixel %0d", i)); break; end
  end
  s = place(0);
  mem.poke(s, 32'h3433_3231); mem.poke(s + 4, 32'h3837_3635);
  wr(A_SRC_ADDR, s); wr(A_LEN, 2); wr(A_LINE, 0);
  job_go(200); irq_check(0);
  rd_exp(A_FRAME_CRC, 32'h9AE0_DAAF);
  mem.err_lo = place(0) + 8; mem.err_hi = mem.err_lo + 4;
  wr(A_LEN, 6);
  job_go(300); irq_check(1);
  mem.err_lo = '1; mem.err_hi = '1;
  cov_tail(200000);
  if (mem.errors != 0) fail("AXI rule violations");
endtask
