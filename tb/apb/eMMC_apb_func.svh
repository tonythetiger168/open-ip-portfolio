// IP part of eMMC_apb_tb: the device model of the core TB (tb/apb/
// eMMC_apb_models.svh: checks every command frame, answers R3 / R2 / R1,
// stores CMD24 blocks, sends CMD17 blocks, one-shot faults on a chosen
// response or data phase). Initialisation with CMD1 busy polling, clean
// write / read-back rounds, response, CRC-status, busy and read faults, each
// latched in IRQ_STATUS.ERR (masked and on the irq pin) with the host
// recovering; emmc_rst_n and PRESETN restarts with init-phase faults.
  pullup pu_cmd (cmd);
  pullup pu_d0 (dat[0]), pu_d1 (dat[1]), pu_d2 (dat[2]), pu_d3 (dat[3]),
         pu_d4 (dat[4]), pu_d5 (dat[5]), pu_d6 (dat[6]), pu_d7 (dat[7]);
  initial emmc_rst_n = 0;                // held until ip_func
  // DAT[7:1] are unused in 1-bit mode: the TB wiggles them to show that
  logic up_oe = 0;
  assign dat[7:1] = up_oe ? 7'h00 : 7'hzz;
  emmc_card #(.BC(1)) card (.clk(PCLK), .cmd(cmd), .dat0(dat[0]));

  int irqs = 0;
  always @(posedge PCLK) if (dut.c_irq) irqs++;

  task automatic check(input bit c, input string m);
    if (!c) fail(m);
  endtask
  function automatic logic [255:0] pat(input logic [7:0] r);
    for (int i = 0; i < 8; i++)
      pat[255 - i * 32 -: 32] = 32'hA500_3C00 ^ {24'h0, r} ^ ({24'h0, 8'(i)} * 32'h0001_0101);
  endfunction

  task automatic wait_rounds(input int n, input string what);
    int t, m0;
    m0 = dut.u_core.match_cnt; t = 0;
    while (8'(dut.u_core.match_cnt - m0) < n && t < 3000 * n) begin @(posedge PCLK); t++; end
    check(8'(dut.u_core.match_cnt - m0) >= n, {what, ": rounds did not complete"});
  endtask
  task automatic wait_init(input string what);
    int t = 0;
    while (!dut.u_core.init_done && t < 20000) begin @(posedge PCLK); t++; end
    check(dut.u_core.init_done === 1'b1, {what, ": init did not complete"});
  endtask

  // one-shot fault: exactly one ERR pulse, latched; w1c clears; the pin
  // follows the enable
  bit en = 0;
  task automatic fault(input int f, input int idx, input string what);
    int i0, t;
    i0 = irqs; t = 0;
    card.fault = f; card.fault_cmd = idx;
    while (irqs == i0 && t < 8000) begin @(posedge PCLK); t++; end
    check(irqs == i0 + 1, {what, ": no irq"});
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
    if (irq !== en) fail({what, ": irq pin vs enable"});
    wr(A_IRQ_STATUS, 1 << IRQ_ERR);
    rd_exp(A_IRQ_STATUS, 0);
  endtask

  task automatic reset_dev(input bit sys);
    @(negedge PCLK);
    if (sys) PRESETN = 0; else emmc_rst_n = 0;
    card.kill();
    repeat (3) @(negedge PCLK);
    check(irq === 1'b0 && dut.u_core.init_done === 1'b0 && dut.u_core.match_cnt == 0, "reset state");
    PRESETN = 1; emmc_rst_n = 1;
    if (sys) begin
      cycles(1);
      check_reset_values();
      if (en) wr(A_IRQ_ENABLE, 1 << IRQ_ERR);
    end
  endtask

  task automatic ip_func;
    for (int b = 0; b < 4; b++) card.mem[b] = '1;
    card.busy_polls = 3;
    rd_exp(A_FLAGS, 0);
    emmc_rst_n = 1;

    // ---- init with CMD1 busy polling, clean rounds ----
    wait_init("first init");
    check(dut.u_core.cid == card.cid_val(), "CID");
    up_oe = 1;
    wait_rounds(5, "clean rounds (DAT[7:1] held low)");
    up_oe = 0;
    for (int b = 0; b < 4; b++) check(card.mem[b] == pat(8'(b == 0 ? 4 : b)), "device store contents");
    check(card.bad_frames == 0, "host command frame errors");
    rd_exp(A_IRQ_STATUS, 0);

    // ---- data-phase faults, masked ----
    fault(card.F_CRC7, 24, "R1 CRC7 (CMD24)");      wait_rounds(1, "after CRC7");
    fault(card.F_STAT, 17, "R1 status (CMD17)");    wait_rounds(1, "after status");
    fault(card.F_STAT, 24, "R1 status (CMD24)");    wait_rounds(1, "after status 24");
    fault(card.F_MUTE, 24, "no R1 (CMD24)");        wait_rounds(1, "after mute");
    fault(card.F_TOK, 24, "negative CRC status");   wait_rounds(1, "after token");
    // ---- on the irq pin ----
    wr(A_IRQ_ENABLE, 1 << IRQ_ERR); en = 1;
    fault(card.F_BUSYHOLD, 24, "busy timeout");     wait_rounds(1, "after busy hold");
    fault(card.F_RDCRC, 17, "read CRC16");          wait_rounds(1, "after read crc");
    fault(card.F_RDDATA, 17, "read compare");       wait_rounds(1, "after compare");
    fault(card.F_RDMUTE, 17, "no read data");       wait_rounds(1, "after read mute");

    // ---- init-phase faults after emmc_rst_n / PRESETN ----
    reset_dev(0);  fault(card.F_R3, 1, "R3 framing");   wait_init("after R3");
    reset_dev(1);  fault(card.F_R2, 2, "R2 CID CRC");   wait_init("after R2");
    en = 0; wr(A_IRQ_ENABLE, 0);
    reset_dev(0);  fault(card.F_MUTE, 1, "no R3");      wait_init("after no R3");
    // PRESETN in the middle of a write block
    wait (dut.u_core.state == 3'd4 && dut.u_core.dphase == 3'd1); repeat (40) @(posedge PCLK);
    reset_dev(1);  wait_init("after reset in a write");
    wait_rounds(2, "rounds after reset");
    check(card.bad_frames == 0, "host command frame errors");
    rd_exp(A_IRQ_STATUS, 0);

    // leave ERR pending (masked) for the final reset
    begin
      int i0;
      i0 = irqs;
      card.fault = card.F_CRC7; card.fault_cmd = 24;
      while (irqs == i0) @(posedge PCLK);
    end
    cycles(2);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
  endtask
