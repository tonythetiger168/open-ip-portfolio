// SPDX-License-Identifier: Apache-2.0
// ML_KEM-specific part of tb/ML_KEM_apb_tb.sv: the first cases of
// tb/ML_KEM_vec.hex (ML-KEM-512 KeyGen, Encaps, Decaps and Decaps of a
// modified ciphertext, then ML-KEM-1024 KeyGen) run entirely through the
// registers: inputs written through DATA_IN, the operation started from
// CTRL / CMD, DONE polled in IRQ_STATUS, outputs read through DATA_OUT and
// compared. Also: a reserved op and parameter set (ERR), START while busy,
// DATA_IN written while busy (held, then overflow), DATA_OUT empty while
// busy, the prefetch drained with hr_en cleared.
logic [31:0] mv [0:200000];
int          mvp = 0;

task automatic mk_ctrl(input logic [1:0] o, input logic [1:0] p, input logic re);
  wr(A_CTRL, {27'd0, re, p, o});
endtask

// drop a word DATA_OUT may hold (prefetched while hr_en was set)
task automatic mk_drain;
  rd(A_FLAGS);
  if (rdv[FLAG_DATA_OUT_AVAIL]) rd(A_DATA_OUT);
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask

task automatic mk_ptr(input logic [10:0] a);
  wr(A_PTR, {21'd0, a});
  wr(A_CMD, 32'h2);
endtask

task automatic mk_load(input logic [10:0] a, input int n);
  mk_ptr(a);
  for (int i = 0; i < n; i++) begin
    rd(A_FLAGS);
    while (rdv[FLAG_DATA_IN_FULL]) rd(A_FLAGS);
    wr(A_DATA_IN, mv[mvp + i]);
  end
  rd(A_FLAGS);
  while (rdv[FLAG_DATA_IN_FULL]) rd(A_FLAGS);
  mvp += n;
endtask

task automatic mk_check(input logic [1:0] o, input logic [1:0] p, input logic [10:0] a, input int n);
  int bad;
  bad = 0;
  mk_ctrl(o, p, 0);
  mk_drain();
  mk_ptr(a);
  mk_ctrl(o, p, 1);
  for (int i = 0; i < n; i++) begin
    poll(A_FLAGS, 32'h1 << FLAG_DATA_OUT_AVAIL, 32'h1 << FLAG_DATA_OUT_AVAIL, 20);
    rd(A_DATA_OUT);
    if (rdv !== mv[mvp + i]) begin
      if (bad < 3) fail($sformatf("DATA_OUT word %0d at %h: %h, expected %h", i, a + 11'(i), rdv, mv[mvp + i]));
      bad++;
    end
  end
  mk_ctrl(o, p, 0);
  mk_drain();
  mvp += n;
endtask

task automatic irq_chk(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask

task automatic mk_run(input logic [1:0] o, input logic [1:0] p);
  mk_ctrl(o, p, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CMD, 32'h1);
  rd(A_STATUS);
  if (!rdv[0]) fail("STATUS.busy not set after START");
  wr(A_CMD, 32'h1);                                   // START while busy: ignored
  poll(A_IRQ_STATUS, 32'h1 << IRQ_DONE, 32'h1 << IRQ_DONE, 40000);
  rd(A_STATUS);
  if (rdv[0]) fail("STATUS.busy after DONE");
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_ERR]) fail("ERR with a valid operation");
endtask

task automatic ip_func;
  int ncase;
  // the vectors, from the repository root, sim/ or the coverage build directory
  if ($fopen("tb/ML_KEM_vec.hex", "r") != 0) $readmemh("tb/ML_KEM_vec.hex", mv);
  else if ($fopen("../tb/ML_KEM_vec.hex", "r") != 0) $readmemh("../tb/ML_KEM_vec.hex", mv);
  else $readmemh("../../../../tb/ML_KEM_vec.hex", mv);
  poll(A_STATUS, 32'h1, 32'h0, 40000);               // the register tests may have started one
  mk_ctrl(0, 0, 0);
  mk_drain();
  wr(A_IRQ_ENABLE, IRQ_ALL);                         // every interrupt drives the pin
  // reserved op and parameter set
  mk_ctrl(3, 0, 0); wr(A_CMD, 32'h1);
  cycles(3);
  rd_exp(A_IRQ_STATUS, 32'h1 << IRQ_ERR);
  if (irq !== 1'b1) fail("irq pin low with ERR enabled");
  rd_exp(A_STATUS, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  if (irq !== 1'b0) fail("irq pin high after clearing");
  mk_ctrl(0, 3, 0); wr(A_CMD, 32'h1);
  cycles(3);
  rd_exp(A_IRQ_STATUS, 32'h1 << IRQ_ERR);
  wr(A_IRQ_STATUS, IRQ_ALL);
  for (ncase = 0; ncase < 5; ncase++) begin : b_case
    logic [31:0] h;
    bit ran;
    h = mv[mvp]; mvp++;
    if (h[31:24] !== 8'hA5) fail("bad vector header");
    // case 4: skip ahead to the first ML-KEM-1024 KeyGen
    if (ncase == 4) begin
      while (!(h[17:16] == 2'd0 && h[9:8] == 2'd2)) begin
        for (int s = 0; s < h[7:0]; s++) mvp += 1 + mv[mvp][15:0];
        h = mv[mvp]; mvp++;
      end
    end
    ran = 0;
    for (int s = 0; s < h[7:0]; s++) begin : b_seg
      logic [31:0] g;
      g = mv[mvp]; mvp++;
      if (g[31]) begin
        if (!ran) begin mk_run(h[17:16], h[9:8]); ran = 1; end
        mk_check(h[17:16], h[9:8], g[26:16], g[15:0]);
      end else mk_load(g[26:16], g[15:0]);
    end
    $display("apb case %0d: op %0d pset %0d done", ncase, h[17:16], h[9:8]);
  end
  // DATA_IN while busy: the first word is held (not taken), the second
  // overflows (interrupt enabled: drives the pin, then cleared); DATA_OUT
  // stays empty with hr_en set
  mk_ptr(11'h7F0);
  mk_ctrl(0, 0, 0);
  mk_drain();
  wr(A_CMD, 32'h1);
  mk_ctrl(0, 0, 1);
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
  mk_ctrl(0, 0, 0);
  wr(A_IRQ_ENABLE, 0);
  poll(A_STATUS, 32'h1, 32'h0, 40000);
  mk_ctrl(3, 0, 0); wr(A_CMD, 32'h1);
  mk_ctrl(0, 0, 0); wr(A_CMD, 32'h1);
  wr(A_DATA_IN, 32'h1234_5678);
  wr(A_DATA_IN, 32'h9ABC_DEF0);
  poll(A_STATUS, 32'h1, 32'h0, 40000);
  cycles(5);
  rd(A_IRQ_STATUS);
  if (rdv[3:0] !== 4'hF) fail($sformatf("masked interrupts not all pending (%h)", rdv));
  if (irq !== 1'b0) fail("irq pin high with every interrupt masked");
endtask
