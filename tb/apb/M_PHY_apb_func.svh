// IP part of M_PHY_apb_tb: the TB loops the serial line back (or injects
// words) and runs bursts through the TX / RX registers, every byte compared:
// all D-codes and K-codes at G1 and G2, an unsupported K-code, HIBERN8 enter
// and wake, invalid codes and disparity errors (ERROR), RX overflow.
  localparam logic [9:0] K28P_RDN = 10'b0011111010;
  localparam logic [9:0] K28P_RDP = 10'b1100000101;
  localparam logic [9:0] D00_RDN  = 10'b1001110100;
  logic inj = 0, i_p = 0, i_n = 1;
  assign rx_dif_p = inj ? i_p : tx_dif_p;
  assign rx_dif_n = inj ? i_n : tx_dif_n;

  logic [8:0] sent [0:63];

  task automatic wait_quiet;
    int c;
    c = 0;
    while ((dut.u_core.tstate != 0 || dut.u_core.buf_valid || dut.u_core.gap_cnt != 0 ||
            dut.c_rx_locked || dut.c_tx_valid) && c < 20000) begin @(posedge PCLK); c++; end
    cycles(4);
  endtask

  // one burst of n words (sent[0] is the comma): TX fed and RX drained in
  // one loop over the same bus, each byte compared
  task automatic burst(input int n);
    int si, got, g;
    logic [31:0] f;
    sent[0] = {1'b1, 8'hBC};
    si = 0; got = 0; g = 0;
    no_idle = 1;
    while (got < n && g < 4000) begin
      rd(A_FLAGS); f = rdv;
      if (f[FLAG_RX_AVAIL]) begin
        rd(A_RX);
        if (rdv !== {23'h0, sent[got]}) fail($sformatf("word %0d got %h exp %h", got, rdv, sent[got]));
        got++;
      end
      if (si < n && !f[FLAG_TX_FULL]) begin wr(A_TX, {$urandom, sent[si]} & 32'hFFFF_F1FF | {23'h0, sent[si]}); si++; end
      g++;
    end
    no_idle = 0;
    if (got != n) fail($sformatf("burst: %0d of %0d words back", got, n));
    wait_quiet();
    rd_exp(A_FLAGS, 0);
  endtask

  task automatic inj_word(input logic [9:0] w);
    for (int i = 9; i >= 0; i--) begin
      @(negedge PCLK); i_p = w[i]; i_n = ~w[i];
      if (dut.c_gear) @(negedge PCLK);
    end
  endtask
  task automatic inj_idle(input int n);
    repeat (n) begin @(negedge PCLK); i_p = 0; i_n = 1; end
  endtask
  task automatic err_is(input bit v, input string m);
    rd(A_IRQ_STATUS);
    if (rdv[IRQ_ERROR] !== v) fail({"ERROR bit: ", m});
    if (v) begin
      wr(A_CMD, 4);                                     // irq_clear
      wr(A_IRQ_STATUS, IRQ_ALL);
      rd(A_IRQ_STATUS);
      if (rdv[IRQ_ERROR]) fail({"ERROR cleared: ", m});
    end
  endtask

  task automatic ip_func;
    rd_exp(A_STATUS, 0);
    rd_exp(A_CFG, 0);
    rd_exp(A_CMD, 0);
    wr(A_STATUS, 32'h7); rd_exp(A_STATUS, 0);
    rd_exp(A_RX, 0); wr(A_RX, 32'h1FF); rd_exp(A_RX, 0);
    // ---- every D-code at G2 and G1, K-codes ----
    for (int g = 1; g >= 0; g--) begin
      wr(A_CFG, g);
      for (int b = 0; b < 256; b += 32) begin
        for (int i = 0; i < 32; i++) sent[i + 1] = {1'b0, 8'(b + i)};
        burst(33);
      end
    end
    sent[1] = {1'b1, 8'h1C}; sent[2] = {1'b1, 8'h3C}; sent[3] = {1'b1, 8'h5C};
    sent[4] = {1'b1, 8'h7C}; sent[5] = {1'b1, 8'h9C}; sent[6] = {1'b1, 8'hBC};
    sent[7] = {1'b1, 8'hDC}; sent[8] = {1'b1, 8'hFC}; sent[9] = {1'b1, 8'hF7};
    sent[10] = {1'b1, 8'hFB}; sent[11] = {1'b1, 8'hFD}; sent[12] = {1'b1, 8'hFE};
    burst(13);
    rd(A_TX);
    if (rdv[8:0] !== 9'h1FE) fail("TX reads back the last byte");
    for (int t = 0; t < 10; t++) begin
      wr(A_CFG, $urandom_range(0, 1));
      for (int i = 1; i < 20; i++) sent[i] = {1'b0, 8'($urandom)};
      burst(20);
    end
    wr(A_CFG, 0);
    rd(A_IRQ_STATUS);
    if (rdv !== ((1 << IRQ_TX_DONE) | (1 << IRQ_RX_AVAIL))) fail($sformatf("IRQ_STATUS after bursts %h", rdv));
    wr(A_IRQ_STATUS, IRQ_ALL);
    err_is(0, "clean bursts");
    // ---- unsupported K-code: dropped, ERROR (masked) ----
    wr(A_TX, 9'h1BC); wr(A_TX, 9'h105); wr(A_TX, 9'h021);
    cycles(40);
    rd(A_RX); rd(A_RX);
    wait_quiet();
    if (irq) fail("masked ERROR drives the pin");
    err_is(1, "unsupported K-code");
    rd(A_RX);
    // ---- RX not read: overflow ----
    wr(A_IRQ_STATUS, IRQ_ALL);
    wr(A_IRQ_ENABLE, IRQ_ALL);
    wr(A_TX, 9'h1BC); wr(A_TX, 9'h011); wr(A_TX, 9'h022);
    wait_quiet();
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_RX_OVF]) fail("RX_OVF");
    if (!irq) fail("irq pin");
    rd_exp(A_RX, 9'h1BC);                               // the first byte was kept
    // TX written while full
    wr(A_CMD, 1);                                       // HIBERN8: TX held
    cycles(6);
    rd_exp(A_STATUS, 3'b101);
    wr(A_TX, 9'h033); wr(A_TX, 9'h044);
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_TX_OVF]) fail("TX_OVF");
    wr(A_IRQ_STATUS, IRQ_ALL);
    wr(A_IRQ_ENABLE, 0);
    wr(A_TX, 9'h055);                                   // masked overflows
    rd(A_IRQ_STATUS);
    if (rdv !== (1 << IRQ_TX_OVF)) fail("TX_OVF masked");
    if (irq) fail("masked irqs drive the pin");
    wr(A_IRQ_STATUS, IRQ_ALL);
    rd_exp(A_TX, 9'h033);
    // wake: the held byte goes out (no comma: not received), the line idles
    wr(A_CMD, 2);
    cycles(12);
    rd_exp(A_STATUS, 0);
    wait_quiet();
    sent[1] = 9'h0A5; sent[2] = 9'h05A; sent[3] = 9'h1FE;
    rd(A_RX);
    wr(A_IRQ_STATUS, IRQ_ALL);
    err_is(0, "after wake");
    burst(4);
    // ---- injected line: errors, DIF-Z ----
    inj = 1;
    inj_idle(12);
    inj_word(K28P_RDN); inj_word(10'b1111100000);
    inj_idle(12);
    rd(A_RX); rd(A_RX);
    err_is(1, "invalid code");
    inj_word(K28P_RDN); inj_word(D00_RDN);
    inj_idle(12);
    rd(A_RX); rd(A_RX);
    err_is(1, "disparity error");
    wr(A_IRQ_ENABLE, IRQ_ALL);
    inj_word(K28P_RDN);
    @(negedge PCLK); i_p = 0; i_n = 0;
    cycles(6);
    rd(A_STATUS);
    if (rdv[2:1] !== 2'b10) fail("DIF-Z seen as hibernation");
    inj_idle(4);
    rd_exp(A_STATUS, 0);
    // RX popped in the clock the next byte is captured, at every offset
    for (int o = 0; o < 12; o++) begin
      fork
        begin inj_idle(12); inj_word(K28P_RDN); repeat (3) inj_word(10'b0110001011); inj_idle(12); end
        begin
          @(posedge PCLK); while (!dut.c_rx_valid) @(posedge PCLK);
          repeat (o) @(negedge PCLK);
          @(negedge PCLK);
          apb_now(0, A_RX, 0, 0);
        end
      join
      rd(A_RX); rd(A_RX);
    end
    // RX overflow, masked
    wr(A_IRQ_ENABLE, 0);
    wr(A_IRQ_STATUS, IRQ_ALL);
    inj_word(K28P_RDN); repeat (3) inj_word(10'b0110001011); inj_idle(12);
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_RX_OVF] || irq) fail("RX_OVF masked");
    rd_exp(A_RX, 9'h1BC);
    wr(A_IRQ_STATUS, IRQ_ALL);
    err_is(0, "clean injected bursts");
    wr(A_IRQ_ENABLE, IRQ_ALL);
    // an error left pending into reset; RX full too
    inj_word(K28P_RDN); inj_word(10'b1111111111);
    inj_idle(12);
    inj = 0;
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_ERROR] || !irq) fail("ERROR pending");
  endtask
