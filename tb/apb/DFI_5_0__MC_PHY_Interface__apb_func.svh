// SPDX-License-Identifier: Apache-2.0
// IP part of DFI_5_0__MC_PHY_Interface__apb_tb: the MC model of the core TB
// (commands, a per-cycle schedule issuing dfi_wrdata_en / dfi_rddata_en at
// tphy_wrlat / trddata_en, a shadow array checking every read beat). Init
// and low-power handshakes against STATUS, array traffic with byte masks,
// and the fault classes in IRQ_STATUS.ERR (sticky until PRESETN; masked and
// on the irq pin).
  localparam int T_PHY_WRLAT = 4;
  localparam int T_RDDATA_EN = 3;
  localparam int T_PHY_RDLAT = 5;
  localparam logic [2:0] ACT = 3'b011, RD = 3'b101, WR = 3'b100, PRE = 3'b010,
                         REF = 3'b001, MRS = 3'b000, NOP = 3'b111;
  initial begin
    dfi_address = 0; dfi_bank = 0; dfi_ras_n = 1; dfi_cas_n = 1; dfi_we_n = 1; dfi_cs_n = 1;
    dfi_cke = 1; dfi_odt = 0; dfi_init_start = 0; dfi_lp_ctrl = 0;
    for (int i = 0; i < 64; i++) begin
      s_we[i] = 0; s_re[i] = 0; s_wx[i] = 0; s_rx[i] = 0; s_wd[i] = 0; s_wm[i] = 0;
      s_wa[i] = 0; s_ra[i] = 0;
    end
    for (int i = 0; i < 256; i++) begin mem_m[i] = 'x; exp_a[i] = 0; exp_d[i] = 0; end
    for (int b = 0; b < 8; b++) begin open_m[b] = 0; row_m[b] = 0; end
  end

  // ------------------------------------------------------------------
  // per-cycle beat schedule (slot = cycle number mod 64)
  // ------------------------------------------------------------------
  int          cyc = 0;
  always @(posedge PCLK) cyc++;
  bit          s_we [0:63];
  bit          s_re [0:63];
  bit          s_wx [0:63];     // beat is on time: apply to / read from the shadow
  bit          s_rx [0:63];
  logic [31:0] s_wd [0:63];
  logic [3:0]  s_wm [0:63];
  logic [7:0]  s_wa [0:63];
  logic [7:0]  s_ra [0:63];

  // ------------------------------------------------------------------
  // MC-side model: bank table, shadow array, expected read beats
  // ------------------------------------------------------------------
  bit          open_m [0:7];
  logic [1:0]  row_m  [0:7];
  logic [31:0] mem_m  [0:255];
  logic [7:0]  exp_a  [0:255];
  logic [31:0] exp_d  [0:255];
  int          exp_wr = 0, exp_rd = 0;

  always @(negedge PCLK) begin
    int s;
    s = cyc % 64;
    dfi_wrdata_en   = s_we[s];
    dfi_rddata_en   = s_re[s];
    dfi_wrdata      = s_we[s] ? s_wd[s] : $urandom;     // data is don't-care without enable
    dfi_wrdata_mask = s_we[s] ? s_wm[s] : 4'($urandom);
    if (s_rx[s]) begin                                  // read before the same-cycle write
      exp_a[exp_wr % 256] = s_ra[s]; exp_d[exp_wr % 256] = mem_m[s_ra[s]]; exp_wr++;
    end
    if (s_wx[s])
      for (int i = 0; i < 4; i++) if (!s_wm[s][i]) mem_m[s_wa[s]][8*i +: 8] = s_wd[s][8*i +: 8];
    s_we[s] = 0; s_re[s] = 0; s_wx[s] = 0; s_rx[s] = 0;
  end

  function automatic logic [7:0] waddr(input logic [2:0] b, input logic [2:0] col);
    waddr = {b, row_m[b], col};
  endfunction

  // drive one command for one cycle (then NOP / DES)
  task automatic cmd(input logic [2:0] c, input logic [2:0] b = 0, input logic [16:0] a = 0,
                     input bit des_after = 0);
    @(negedge PCLK);
    {dfi_ras_n, dfi_cas_n, dfi_we_n} = c;
    dfi_cs_n = 0; dfi_bank = b; dfi_address = a;
    @(negedge PCLK);
    {dfi_ras_n, dfi_cas_n, dfi_we_n} = des_after ? 3'($urandom) : NOP;
    dfi_cs_n = des_after;
    dfi_bank = $urandom; dfi_address = $urandom;
  endtask

  // the same, but returns right after driving (back-to-back issue)
  task automatic cmd_now(input logic [2:0] c, input logic [2:0] b, input logic [16:0] a);
    @(negedge PCLK);
    {dfi_ras_n, dfi_cas_n, dfi_we_n} = c;
    dfi_cs_n = 0; dfi_bank = b; dfi_address = a;
  endtask
  task automatic nop;
    @(negedge PCLK);
    {dfi_ras_n, dfi_cas_n, dfi_we_n} = NOP; dfi_cs_n = 0;
    dfi_bank = $urandom; dfi_address = $urandom;
  endtask

  task automatic act(input logic [2:0] b, input logic [16:0] row);
    cmd(ACT, b, row);
    open_m[b] = 1; row_m[b] = row[1:0];
  endtask

  // schedule the beats of a WR / RD issued at the negedge of this cycle
  task automatic sched_wr(input logic [7:0] a, input logic [31:0] d, input logic [3:0] m,
                          input int dly = T_PHY_WRLAT, input bit beat = 1);
    int s;
    s = (cyc + dly) % 64;
    if (beat) begin s_we[s] = 1; s_wd[s] = d; s_wm[s] = m; s_wa[s] = a; end
    if (beat && dly == T_PHY_WRLAT) s_wx[s] = 1;
  endtask
  task automatic sched_rd(input logic [7:0] a, input int dly = T_RDDATA_EN, input bit beat = 1);
    int s;
    s = (cyc + dly) % 64;
    if (beat) begin s_re[s] = 1; s_ra[s] = a; end
    if (beat && dly == T_RDDATA_EN) s_rx[s] = 1;
  endtask

  task automatic dwr(input logic [2:0] b, input logic [2:0] col, input logic [31:0] d,
                    input logic [3:0] m = 0);
    cmd_now(WR, b, {$urandom, col});
    sched_wr(waddr(b, col), d, m);
  endtask
  task automatic drd(input logic [2:0] b, input logic [2:0] col);
    cmd_now(RD, b, {$urandom, col});
    sched_rd(waddr(b, col));
  endtask

  // read data check
  always @(posedge PCLK) if (PRESETN && dfi_rddata_valid) begin
    if (exp_rd >= exp_wr) fail("unexpected read beat");
    else begin
      if (dfi_rddata !== exp_d[exp_rd % 256])
        fail($sformatf("read %0d addr %h: %h exp %h", exp_rd, exp_a[exp_rd % 256], dfi_rddata,
                       exp_d[exp_rd % 256]));
      exp_rd++;
    end
  end
  always @(posedge PCLK) if (PRESETN && !dfi_rddata_valid && dfi_rddata !== 0) fail("rddata not gated");

  task automatic drain;
    repeat (T_PHY_WRLAT + T_RDDATA_EN + T_PHY_RDLAT + 3) nop();
    if (exp_rd != exp_wr) fail($sformatf("%0d read beats missing", exp_wr - exp_rd));
  endtask

  // ------------------------------------------------------------------
  // init / low power / reset
  // ------------------------------------------------------------------
  task automatic init;
    int t;
    @(negedge PCLK); dfi_init_start = 1;
    t = 0;
    while (!dfi_init_complete && t < 100) begin @(negedge PCLK); t++; end
    if (t != 33) fail($sformatf("init took %0d cycles", t));
    repeat ($urandom % 4) @(negedge PCLK);
    if (!dfi_init_complete) fail("init_complete dropped while init_start held");
    dfi_init_start = 0;
    @(negedge PCLK);
    if (dfi_init_complete) fail("init_complete held after release");
    for (int b = 0; b < 8; b++) open_m[b] = 0;
  endtask

  task automatic lp_enter;
    @(negedge PCLK); dfi_lp_ctrl = 1;
    repeat (2) begin @(negedge PCLK); if (dfi_lp_ctrl_ack) fail("lp ack early"); end
    @(negedge PCLK);
    if (!dfi_lp_ctrl_ack) fail("lp ack");
  endtask
  task automatic lp_exit;
    @(negedge PCLK); dfi_lp_ctrl = 0;
    repeat (2) begin @(negedge PCLK); if (!dfi_lp_ctrl_ack) fail("lp ack dropped early"); end
    @(negedge PCLK);
    if (dfi_lp_ctrl_ack) fail("lp ack release");
  endtask

  task automatic hard_reset;
    drain();
    @(negedge PCLK); PRESETN = 0;
    repeat (2) @(negedge PCLK);
    if (dut.c_irq || dfi_init_complete || dfi_lp_ctrl_ack || dfi_rddata_valid) fail("reset state");
    PRESETN = 1;
    for (int b = 0; b < 8; b++) open_m[b] = 0;
    exp_rd = exp_wr;
    check_reset_values();
    rd_exp(A_IRQ_STATUS, 0);
  endtask

  task automatic expect_irq(input bit e, input string m);
    nop(); nop();
    if (dut.c_irq !== e) fail($sformatf("%s: dut.c_irq %b exp %b", m, dut.c_irq, e));
  endtask


  // ERR set and held (sticky in the core)
  task automatic err_held(input bit en, input string m);
    nop(); nop();
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
    wr(A_IRQ_STATUS, 1 << IRQ_ERR);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
    if (irq !== en) fail({m, ": irq pin vs enable"});
  endtask

  task automatic ip_func;
    rd_exp(A_FLAGS, 0);
    rd_exp(A_STATUS, 0);
    // ---- init handshake seen in STATUS ----
    @(negedge PCLK); dfi_init_start = 1;
    repeat (20) @(negedge PCLK);
    rd_exp(A_STATUS, 0);
    while (!dfi_init_complete) @(negedge PCLK);
    rd_exp(A_STATUS, 1);
    dfi_init_start = 0;
    @(negedge PCLK);
    rd_exp(A_STATUS, 0);
    for (int b = 0; b < 8; b++) open_m[b] = 0;

    // ---- traffic: fill banks, byte masks, read back ----
    for (int b = 0; b < 8; b++) begin
      act(b[2:0], {$urandom, 2'(b % 4)});
      for (int c = 0; c < 8; c++) dwr(b[2:0], 3'(c), $urandom, 4'($urandom));
      for (int c = 0; c < 8; c++) drd(b[2:0], 3'(c));
      drain();
    end
    cmd(PRE, 0, 17'h0_0400);
    for (int b = 0; b < 8; b++) open_m[b] = 0;
    cmd(REF); cmd(MRS, 0, $urandom);
    // pass-through cke / odt both ways
    @(negedge PCLK); dfi_cke = 0; dfi_odt = 1;
    repeat (2) @(negedge PCLK); dfi_cke = 1; dfi_odt = 0;
    repeat (2) @(negedge PCLK);
    rd_exp(A_IRQ_STATUS, 0);

    // ---- low power handshake in STATUS ----
    @(negedge PCLK); dfi_lp_ctrl = 1;
    repeat (4) @(negedge PCLK);
    rd_exp(A_STATUS, 2);
    if (!dfi_lp_ctrl_ack) fail("lp ack pin");
    dfi_lp_ctrl = 0;
    repeat (4) @(negedge PCLK);
    rd_exp(A_STATUS, 0);

    // ---- faults: masked, then on the irq pin ----
    cmd(WR, 4, 0); err_held(0, "WR to a closed bank");
    hard_reset(); init();
    wr(A_IRQ_ENABLE, 1 << IRQ_ERR);
    act(2, 1); cmd(ACT, 2, 3); err_held(1, "ACT to an open bank");
    hard_reset(); init(); act(7, 2);
    wr(A_IRQ_ENABLE, 1 << IRQ_ERR);
    cmd_now(RD, 7, 3); sched_rd(waddr(7, 3), T_RDDATA_EN + 1);
    drain(); err_held(1, "late rddata_en");
    hard_reset(); init();
    act(1, 0); dwr(1, 2, 32'hCAFE_F00D); nop(); drd(1, 2); drain();
    rd_exp(A_IRQ_STATUS, 0);

    // ---- PRESETN with a read beat in flight ----
    act(0, 0); dwr(0, 0, $urandom); drd(0, 0);
    do @(posedge PCLK); while (!dfi_rddata_en);
    @(negedge PCLK); PRESETN = 0; repeat (2) @(negedge PCLK); PRESETN = 1;
    exp_rd = exp_wr;
    for (int i = 0; i < 64; i++) begin s_we[i] = 0; s_re[i] = 0; s_wx[i] = 0; s_rx[i] = 0; end
    repeat (5) @(negedge PCLK);
    check_reset_values();
    rd_exp(A_STATUS, 0);
    // leave ERR pending (masked) for the final reset
    cmd(RD, 1, 3);
    nop(); nop();
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
  endtask
