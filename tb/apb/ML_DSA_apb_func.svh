// SPDX-License-Identifier: Apache-2.0
// ML_DSA-specific part of tb/ML_DSA_apb_tb.sv: the first 12 cases of
// tb/ML_DSA_vec.hex (ML-DSA-44 KeyGen, Sign, Verify, Sign and Verify with
// external mu, six Verifies of modified signatures, a Sign with four
// attempts) run entirely through the
// registers: inputs written through DATA_IN, MLEN and the operation set in
// CTRL / MLEN / CMD, DONE polled in IRQ_STATUS, STATUS.fail and
// STATUS.tries compared, outputs read through DATA_OUT and compared. Also:
// a reserved op, parameter set and message length (ERR), START while busy,
// DATA_IN written while busy (held, then overflow), DATA_OUT empty while
// busy, the prefetch drained with hr_en cleared.
logic [31:0] mv [0:400000];
int          mvp = 0;

task automatic md_ctrl(input logic [1:0] o, input logic [1:0] p, input logic re, input logic e);
  wr(A_CTRL, {26'd0, e, re, p, o});
endtask

// drop a word DATA_OUT may hold (prefetched while hr_en was set)
task automatic md_drain;
  rd(A_FLAGS);
  if (rdv[FLAG_DATA_OUT_AVAIL]) rd(A_DATA_OUT);
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask

task automatic md_ptr(input logic [12:0] a);
  wr(A_PTR, {19'd0, a});
  wr(A_CMD, 32'h2);
endtask

task automatic md_load(input logic [12:0] a, input int n);
  md_ptr(a);
  for (int i = 0; i < n; i++) begin
    rd(A_FLAGS);
    while (rdv[FLAG_DATA_IN_FULL]) rd(A_FLAGS);
    wr(A_DATA_IN, mv[mvp + i]);
  end
  rd(A_FLAGS);
  while (rdv[FLAG_DATA_IN_FULL]) rd(A_FLAGS);
  mvp += n;
endtask

task automatic md_check(input logic [12:0] a, input int n, input logic [1:0] pad);
  int bad;
  logic [31:0] msk;
  bad = 0;
  md_ctrl(0, 0, 0, 0);
  md_drain();
  md_ptr(a);
  md_ctrl(0, 0, 1, 0);
  for (int i = 0; i < n; i++) begin
    poll(A_FLAGS, 32'h1 << FLAG_DATA_OUT_AVAIL, 32'h1 << FLAG_DATA_OUT_AVAIL, 20);
    rd(A_DATA_OUT);
    msk = i == n - 1 ? 32'hFFFF_FFFF >> (8 * pad) : 32'hFFFF_FFFF;
    if ((rdv & msk) !== mv[mvp + i]) begin
      if (bad < 3) fail($sformatf("DATA_OUT word %0d at %h: %h, expected %h", i, a + 13'(i), rdv, mv[mvp + i]));
      bad++;
    end
  end
  md_ctrl(0, 0, 0, 0);
  md_drain();
  mvp += n;
endtask

task automatic irq_chk(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask

task automatic md_run(input logic [1:0] o, input logic [1:0] p, input logic e, input logic [31:0] h2);
  md_ctrl(o, p, 0, e);
  wr(A_MLEN, {17'd0, h2[14:0]});
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CMD, 32'h1);
  rd(A_STATUS);
  if (!rdv[0]) fail("STATUS.busy not set after START");
  wr(A_CMD, 32'h1);                                   // START while busy: ignored
  poll(A_IRQ_STATUS, 32'h1 << IRQ_DONE, 32'h1 << IRQ_DONE, 400000);
  rd(A_STATUS);
  if (rdv[0]) fail("STATUS.busy after DONE");
  if (rdv[1] !== h2[31]) fail($sformatf("STATUS.fail %b, expected %b", rdv[1], h2[31]));
  if (o == 2'd1 && rdv[17:2] !== {1'b0, h2[30:16]}) fail($sformatf("STATUS.tries %0d, expected %0d", rdv[17:2], h2[30:16]));
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_ERR]) fail("ERR with a valid operation");
endtask

task automatic ip_func;
  int ncase;
  // the vectors, from the repository root, sim/ or the coverage build directory
  if ($fopen("tb/ML_DSA_vec.hex", "r") != 0) $readmemh("tb/ML_DSA_vec.hex", mv);
  else if ($fopen("../tb/ML_DSA_vec.hex", "r") != 0) $readmemh("../tb/ML_DSA_vec.hex", mv);
  else $readmemh("../../../../tb/ML_DSA_vec.hex", mv);
  poll(A_STATUS, 32'h1, 32'h0, 400000);              // the register tests may have started one
  md_ctrl(0, 0, 0, 0);
  md_drain();
  wr(A_IRQ_ENABLE, IRQ_ALL);                         // every interrupt drives the pin
  // reserved op, parameter set and message length
  md_ctrl(3, 0, 0, 0); wr(A_CMD, 32'h1);
  cycles(3);
  rd_exp(A_IRQ_STATUS, 32'h1 << IRQ_ERR);
  if (irq !== 1'b1) fail("irq pin low with ERR enabled");
  rd_exp(A_STATUS, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  if (irq !== 1'b0) fail("irq pin high after clearing");
  md_ctrl(0, 3, 0, 0); wr(A_CMD, 32'h1);
  cycles(3);
  rd_exp(A_IRQ_STATUS, 32'h1 << IRQ_ERR);
  wr(A_IRQ_STATUS, IRQ_ALL);
  md_ctrl(2, 0, 0, 0); wr(A_MLEN, 32'h4001); wr(A_CMD, 32'h1);
  cycles(3);
  rd_exp(A_IRQ_STATUS, 32'h1 << IRQ_ERR);
  wr(A_IRQ_STATUS, IRQ_ALL);
  for (ncase = 0; ncase < 12; ncase++) begin : b_case
    logic [31:0] h, h2;
    bit ran;
    h = mv[mvp]; h2 = mv[mvp + 1]; mvp += 2;
    if (h[31:24] !== 8'hA5) fail("bad vector header");
    ran = 0;
    for (int s = 0; s <= h[7:0]; s++) begin : b_seg
      logic [31:0] g;
      g = s < h[7:0] ? mv[mvp] : 32'h8000_0000;
      if (g[31] && !ran) begin md_run(h[17:16], h[9:8], h[23], h2); ran = 1; end
      if (s < h[7:0]) begin
        mvp++;
        if (g[31]) md_check(g[28:16], g[15:0], g[30:29]);
        else md_load(g[28:16], g[15:0]);
      end
    end
    $display("apb case %0d: op %0d pset %0d done", ncase, h[17:16], h[9:8]);
  end
  // DATA_IN while busy: the first word is held (not taken), the second
  // overflows (interrupt enabled: drives the pin, then cleared); DATA_OUT
  // stays empty with hr_en set
  md_ptr(13'h1FF0);
  md_ctrl(0, 0, 0, 0);
  md_drain();
  wr(A_CMD, 32'h1);
  md_ctrl(0, 0, 1, 0);
  rd(A_FLAGS);
  if (rdv[FLAG_DATA_OUT_AVAIL]) fail("DATA_OUT fetched while busy");
  rd(A_DATA_OUT);                                    // empty: reads 0, nothing popped
  wr(A_DATA_IN, 32'h1234_5678);
  wr(A_DATA_IN, 32'h9ABC_DEF0);
  rd(A_FLAGS);
  if (!rdv[FLAG_DATA_IN_FULL]) fail("DATA_IN not held while busy");
  irq_chk(IRQ_DATA_IN_OVF);
  if (irq !== 1'b1) fail("irq pin low with DATA_IN_OVF enabled");
  wr(A_IRQ_STATUS, 32'h1 << IRQ_DATA_IN_OVF);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_DATA_IN_OVF]) fail("DATA_IN_OVF not cleared");
  // masked: the interrupts set IRQ_STATUS without raising the pin, and stay
  // pending into the reset
  md_ctrl(0, 0, 0, 0);
  wr(A_IRQ_ENABLE, 0);
  poll(A_STATUS, 32'h1, 32'h0, 400000);
  md_ctrl(3, 0, 0, 0); wr(A_CMD, 32'h1);
  md_ctrl(0, 0, 0, 0); wr(A_CMD, 32'h1);
  wr(A_DATA_IN, 32'h1234_5678);
  wr(A_DATA_IN, 32'h9ABC_DEF0);
  poll(A_STATUS, 32'h1, 32'h0, 400000);
  cycles(5);
  rd(A_IRQ_STATUS);
  if (rdv[3:0] !== 4'hF) fail($sformatf("masked interrupts not all pending (%h)", rdv));
  if (irq !== 1'b0) fail("irq pin high with every interrupt masked");
endtask
