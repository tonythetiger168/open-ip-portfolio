// IP part of I2S_Audio_apb_tb: serial loopback (sd_out -> sd_in) through the
// TX / RX registers in every format and depth, master and slave (TB clocks),
// a dropped slave bclk pulse (FSYNC_ERR), TX and RX overflow and underrun.
  bit loop_en = 1;
  assign sd_in = loop_en ? sd_out : 1'b0;

  // slave clocks: bclk = PCLK / 4, wclk from a TB frame position
  bit         slave_en = 0, drop_pulse = 0;
  logic [1:0] sdiv = 0;
  logic [5:0] sft = 0;
  logic       bclk_r = 0, wclk_r = 0;
  assign bclk_in = bclk_r;
  assign wclk_in = wclk_r;
  always @(negedge PCLK) if (slave_en) begin
    sdiv <= sdiv + 2'd1;
    if (sdiv == 2'd1 && !drop_pulse) bclk_r <= 1'b1;
    if (sdiv == 2'd3) begin
      bclk_r <= 1'b0;
      sft    <= sft + 6'd1;
      wclk_r <= sft[5] ^ (sft[4:0] == 5'h1F);       // next position's half
    end
  end

  function automatic logic [31:0] dmask(input logic [1:0] d);
    return (d == 0) ? 32'h0000_FFFF : (d == 1) ? 32'h00FF_FFFF : 32'hFFFF_FFFF;
  endfunction

  task automatic frames(input int n); cycles(n * 260); endtask

  task automatic cfg(input logic m, input logic [1:0] f, input logic [1:0] d);
    wr(A_CFG, {27'h0, d, f, m});
    frames(2);
  endtask

  task automatic tx_put(input logic [31:0] l, input logic [31:0] r);
    poll(A_FLAGS, 1 << FLAG_TX_FULL, 0, 200);
    wr(A_TX0, l); wr(A_TX1, r);
  endtask

  // one loopback pair: sent twice (the receive path is a frame behind), the
  // stale pair dropped, the next received pair compared under the depth mask
  task automatic loopback(input logic [31:0] l, input logic [31:0] r, input logic [1:0] d);
    logic [31:0] m, gl;
    m = dmask(d);
    tx_put(l, r);
    tx_put(l, r);
    poll(A_FLAGS, 1 << FLAG_TX_FULL, 0, 200);
    rd(A_RX1);                                          // drop a stale pair
    poll(A_FLAGS, 1 << FLAG_RX_AVAIL, 1 << FLAG_RX_AVAIL, 200);
    rd(A_RX0); gl = rdv;
    rd(A_RX1);
    if ((gl & m) !== (l & m) || (rdv & m) !== (r & m))
      fail($sformatf("loopback %h/%h got %h/%h (CFG %h)", l & m, r & m, gl & m, rdv & m, dut.r_CFG));
  endtask

  task automatic ip_func;
    logic [31:0] l, r;
    wr(A_IRQ_ENABLE, IRQ_ALL);
    // the registers before any frame: TX / RX read 0 (RX writes ignored)
    rd_exp(A_RX0, 0); rd_exp(A_RX1, 0);
    wr(A_RX0, 32'hFFFF_FFFF); wr(A_RX1, 32'hFFFF_FFFF);
    rd_exp(A_RX0, 0);
    // ---- master: 3 formats x 3 depths ----
    for (int f = 0; f < 3; f++)
      for (int d = 0; d < 4; d++) begin
        cfg(1, f[1:0], d[1:0]);
        loopback(0, dmask(d[1:0]), d[1:0]);
        loopback(dmask(d[1:0]), 0, d[1:0]);
        l = $urandom; r = $urandom;
        loopback(l, r, d[1:0]);
      end
    rd_exp(A_TX0, l); rd_exp(A_TX1, r);                 // TX reads back the last pair
    // ---- underrun: zeros ----
    frames(2);
    rd(A_RX1);
    poll(A_FLAGS, 1 << FLAG_RX_AVAIL, 1 << FLAG_RX_AVAIL, 200);
    rd_exp(A_RX0, 0); rd_exp(A_RX1, 0);
    // ---- TX written while full: dropped (TX_OVF) ----
    wr(A_IRQ_STATUS, IRQ_ALL);
    tx_put(32'h1111_1111, 32'h2222_2222);
    wr(A_TX0, 32'h3333_3333);
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_TX_OVF]) fail("TX_OVF");
    wr(A_IRQ_STATUS, IRQ_ALL);
    loopback(32'h1111_1111, 32'h2222_2222, 2);          // the held pair, not the dropped word
    // ---- RX not read: the next pair is dropped (RX_OVF) ----
    wr(A_IRQ_STATUS, IRQ_ALL);
    frames(3);
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_RX_OVF] || !rdv[IRQ_RX_AVAIL]) fail("RX_OVF");
    rd(A_RX1);
    wr(A_IRQ_STATUS, IRQ_ALL);
    // ---- slave mode ----
    @(negedge PCLK);
    sdiv = 0; sft = 0; bclk_r = 0; wclk_r = 0; slave_en = 1;
    cfg(0, 0, 1);
    frames(1);
    loopback(32'h00AB_CDEF, 32'h0000_0001, 1);
    cfg(0, 1, 1);
    loopback(32'h00FF_FFFF, 32'h0012_3456, 1);
    cfg(0, 2, 0);
    loopback(32'h0000_FFFF, 32'h0000_AAAA, 0);
    cfg(0, 0, 2);
    loopback($urandom, $urandom, 2);
    rd(A_IRQ_STATUS);
    if (rdv[IRQ_FSYNC_ERR]) fail("FSYNC_ERR in sync");
    // dropped bclk pulse: FSYNC_ERR, then re-synchronised
    @(negedge PCLK);
    drop_pulse = 1;
    cycles(5);
    drop_pulse = 0;
    frames(2);
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_FSYNC_ERR]) fail("no FSYNC_ERR on a dropped bclk");
    wr(A_IRQ_STATUS, IRQ_ALL);
    loopback(32'h0000_5A5A, 32'h0000_C3C3, 0);
    // masked
    wr(A_IRQ_ENABLE, 0);
    wr(A_IRQ_STATUS, IRQ_ALL);
    @(negedge PCLK);
    drop_pulse = 1;
    cycles(5);
    drop_pulse = 0;
    frames(2);
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_FSYNC_ERR]) fail("FSYNC_ERR masked");
    if (irq) fail("masked irqs drive the pin");
    // back to master with a pair pending into reset
    slave_en = 0;
    cfg(1, 0, 2);
    wr(A_IRQ_STATUS, IRQ_ALL);
    tx_put(32'h4444_4444, 32'h5555_5555);
    wr(A_TX1, 32'h6666_6666);                           // committing word while full: dropped
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_TX_OVF]) fail("TX_OVF masked");
    rd_exp(A_TX1, 32'h5555_5555);
    // RX right word read while empty: the last pair again, nothing popped
    no_idle = 1;
    rd(A_RX1); r = rdv;
    rd_exp(A_RX1, r);
    rd_exp(A_FLAGS, 1 << FLAG_TX_FULL);
    no_idle = 0;
    wr(A_IRQ_ENABLE, IRQ_ALL);
  endtask
