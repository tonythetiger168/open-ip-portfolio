// IP part of SD_apb_tb: the card model (tb/apb/SD_apb_models.svh, the core
// TB's) answers the host; ERR is checked through the registers for clean
// rounds, round faults and init-phase faults, each followed by recovery.
  pullup (cmd);
  pullup (dat[0]); pullup (dat[1]); pullup (dat[2]); pullup (dat[3]);
  sd_card card (.sd_clk(sd_clk), .cmd(cmd), .dat(dat));

  task automatic wait_rounds(input int n, input string what);
    int t;
    logic [7:0] m0;
    m0 = dut.u_core.match_cnt; t = 0;
    while (8'(dut.u_core.match_cnt - m0) < n && t < 3000 * n) begin @(posedge sd_clk); t++; end
    if (8'(dut.u_core.match_cnt - m0) < n) fail({what, ": rounds did not complete"});
  endtask

  task automatic wait_init(input string what);
    int t;
    t = 0;
    while (!dut.u_core.init_done && t < 20000) begin @(posedge sd_clk); t++; end
    if (dut.u_core.init_done !== 1'b1) fail({what, ": init did not complete"});
  endtask

  // arm a one-shot card fault on command idx; ERR must follow, then clear
  task automatic fault(input int f, input int idx, input string what);
    int t;
    card.fault = f; card.fault_cmd = idx;
    t = 0;
    while (!dut.irq_status[IRQ_ERR] && t < 8000) begin @(posedge sd_clk); t++; end
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_ERR]) fail({"ERR: ", what});
    wr(A_IRQ_STATUS, IRQ_ALL);
  endtask

  task automatic err_none(input string what);
    rd(A_IRQ_STATUS);
    if (rdv[IRQ_ERR]) fail({"ERR without a fault: ", what});
  endtask

  task automatic reset_host;
    PRESETN = 0;
    card.kill();
    cycles(6);
    PRESETN = 1;
    cycles(2);
    wr(A_IRQ_ENABLE, IRQ_ALL);
  endtask

  task automatic ip_func;
    for (int b = 0; b < 4; b++) card.mem[b] = '1;
    card.busy_polls = 3;
    rd_exp(A_FLAGS, 0);
    wait_init("first init");
    wait_rounds(4, "clean rounds");
    err_none("clean rounds");
    // round faults (masked first)
    fault(card.F_CRC7, 24, "R1 CRC7 (CMD24)");
    if (irq) fail("masked ERR drives the pin");
    wait_rounds(1, "after CRC7");
    wr(A_IRQ_ENABLE, IRQ_ALL);
    card.fault = card.F_STAT; card.fault_cmd = 17;
    while (!irq) @(posedge sd_clk);
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_ERR]) fail("ERR: R1 status");
    wr(A_IRQ_STATUS, IRQ_ALL);
    if (irq) fail("irq after clear");
    wait_rounds(1, "after status");
    fault(card.F_MUTE, 13, "no R1 (CMD13)");          wait_rounds(1, "after mute");
    fault(card.F_TOK, 24, "negative CRC status");     wait_rounds(1, "after token");
    fault(card.F_BUSYHOLD, 24, "busy timeout");       wait_rounds(1, "after busy hold");
    fault(card.F_RDCRC, 17, "read CRC16");            wait_rounds(1, "after read crc");
    fault(card.F_RDDATA, 17, "read compare");         wait_rounds(1, "after compare");
    wait_rounds(2, "clean again");
    err_none("clean again");
    // init-phase faults: the host restarts with CMD0
    reset_host(); fault(card.F_R7P, 8, "R7 pattern");  wait_init("after R7 pattern");
    reset_host(); fault(card.F_R3, 41, "R3 framing");  wait_init("after R3");
    reset_host(); fault(card.F_R2, 2, "R2 CID CRC");   wait_init("after R2");
    wait_rounds(2, "after init faults");
    err_none("after init faults");
    // standard capacity card
    card.ccs = 0; card.rca = ~card.rca; card.cid_base = ~card.cid_base;
    reset_host(); wait_init("standard capacity");
    wait_rounds(3, "byte addressed rounds");
    err_none("standard capacity");
    if (card.bad_frames != 0 || card.bad_args != 0) fail("host command frames / arguments");
    // an error left pending into reset
    card.fault = card.F_CRC7; card.fault_cmd = 13;
    while (!dut.irq_status[IRQ_ERR]) @(posedge sd_clk);
  endtask
