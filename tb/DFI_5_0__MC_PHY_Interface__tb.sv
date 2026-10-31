// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for DFI_5_0__MC_PHY_Interface__top -- MC model
// The TB plays the DFI MC: init handshake, low-power handshake, ACT / RD /
// WR / PRE / REF / MRS commands with dfi_wrdata_en issued tphy_wrlat after
// each WR and dfi_rddata_en trddata_en after each RD (from a per-cycle beat
// schedule, so commands can be issued back to back), byte masks, and a
// shadow array that checks every dfi_rddata_valid beat.
// Faults (each followed by a reset, irq is sticky): commands before init,
// in low power and with cke low; ACT to an open bank; RD / WR to a closed
// bank; REF / MRS with a bank open; missing and unexpected
// dfi_wrdata_en / dfi_rddata_en beats.
// Under Verilator the bound checker (tb/cov/DFI_5_0__MC_PHY_Interface__sva.sv)
// predicts every output on every clock.
// IP design verification v1.1 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module DFI_5_0__MC_PHY_Interface__tb;

  localparam int T_PHY_WRLAT = 4;
  localparam int T_RDDATA_EN = 3;
  localparam int T_PHY_RDLAT = 5;

  localparam logic [2:0] ACT = 3'b011, RD = 3'b101, WR = 3'b100, PRE = 3'b010,
                         REF = 3'b001, MRS = 3'b000, NOP = 3'b111;

  logic clk = 0, rst_n = 0;
  logic [16:0] dfi_address = 0;
  logic [2:0]  dfi_bank = 0;
  logic        dfi_ras_n = 1, dfi_cas_n = 1, dfi_we_n = 1, dfi_cs_n = 1;
  logic        dfi_cke = 1, dfi_odt = 0;
  logic        dfi_wrdata_en = 0;
  logic [31:0] dfi_wrdata = 0;
  logic [3:0]  dfi_wrdata_mask = 0;
  logic        dfi_rddata_en = 0;
  wire         dfi_rddata_valid;
  wire  [31:0] dfi_rddata;
  logic        dfi_init_start = 0;
  wire         dfi_init_complete;
  logic        dfi_lp_ctrl = 0;
  wire         dfi_lp_ctrl_ack;
  wire         irq;

  DFI_5_0__MC_PHY_Interface__top #(.T_PHY_WRLAT(T_PHY_WRLAT), .T_RDDATA_EN(T_RDDATA_EN),
                                   .T_PHY_RDLAT(T_PHY_RDLAT)) dut (
    .clk(clk), .rst_n(rst_n),
    .dfi_address(dfi_address), .dfi_bank(dfi_bank),
    .dfi_ras_n(dfi_ras_n), .dfi_cas_n(dfi_cas_n), .dfi_we_n(dfi_we_n),
    .dfi_cs_n(dfi_cs_n), .dfi_cke(dfi_cke), .dfi_odt(dfi_odt),
    .dfi_wrdata_en(dfi_wrdata_en), .dfi_wrdata(dfi_wrdata),
    .dfi_wrdata_mask(dfi_wrdata_mask),
    .dfi_rddata_en(dfi_rddata_en),
    .dfi_rddata_valid(dfi_rddata_valid), .dfi_rddata(dfi_rddata),
    .dfi_init_start(dfi_init_start), .dfi_init_complete(dfi_init_complete),
    .dfi_lp_ctrl(dfi_lp_ctrl), .dfi_lp_ctrl_ack(dfi_lp_ctrl_ack),
    .irq(irq)
  );

  always #5 clk = ~clk;

  int errors = 0;
  task automatic fail(input string m);
    errors++;
    $display("ERROR @%0t: %s", $time, m);
  endtask

  // ------------------------------------------------------------------
  // per-cycle beat schedule (slot = cycle number mod 64)
  // ------------------------------------------------------------------
  int          cyc = 0;
  always @(posedge clk) cyc++;
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

  always @(negedge clk) begin
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
    @(negedge clk);
    {dfi_ras_n, dfi_cas_n, dfi_we_n} = c;
    dfi_cs_n = 0; dfi_bank = b; dfi_address = a;
    @(negedge clk);
    {dfi_ras_n, dfi_cas_n, dfi_we_n} = des_after ? 3'($urandom) : NOP;
    dfi_cs_n = des_after;
    dfi_bank = $urandom; dfi_address = $urandom;
  endtask

  // the same, but returns right after driving (back-to-back issue)
  task automatic cmd_now(input logic [2:0] c, input logic [2:0] b, input logic [16:0] a);
    @(negedge clk);
    {dfi_ras_n, dfi_cas_n, dfi_we_n} = c;
    dfi_cs_n = 0; dfi_bank = b; dfi_address = a;
  endtask
  task automatic nop;
    @(negedge clk);
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

  task automatic wr(input logic [2:0] b, input logic [2:0] col, input logic [31:0] d,
                    input logic [3:0] m = 0);
    cmd_now(WR, b, {$urandom, col});
    sched_wr(waddr(b, col), d, m);
  endtask
  task automatic rd(input logic [2:0] b, input logic [2:0] col);
    cmd_now(RD, b, {$urandom, col});
    sched_rd(waddr(b, col));
  endtask

  // read data check
  always @(posedge clk) if (rst_n && dfi_rddata_valid) begin
    if (exp_rd >= exp_wr) fail("unexpected read beat");
    else begin
      if (dfi_rddata !== exp_d[exp_rd % 256])
        fail($sformatf("read %0d addr %h: %h exp %h", exp_rd, exp_a[exp_rd % 256], dfi_rddata,
                       exp_d[exp_rd % 256]));
      exp_rd++;
    end
  end
  always @(posedge clk) if (rst_n && !dfi_rddata_valid && dfi_rddata !== 0) fail("rddata not gated");

  task automatic drain;
    repeat (T_PHY_WRLAT + T_RDDATA_EN + T_PHY_RDLAT + 3) nop();
    if (exp_rd != exp_wr) fail($sformatf("%0d read beats missing", exp_wr - exp_rd));
  endtask

  // ------------------------------------------------------------------
  // init / low power / reset
  // ------------------------------------------------------------------
  task automatic init;
    int t;
    @(negedge clk); dfi_init_start = 1;
    t = 0;
    while (!dfi_init_complete && t < 100) begin @(negedge clk); t++; end
    if (t != 33) fail($sformatf("init took %0d cycles", t));
    repeat ($urandom % 4) @(negedge clk);
    if (!dfi_init_complete) fail("init_complete dropped while init_start held");
    dfi_init_start = 0;
    @(negedge clk);
    if (dfi_init_complete) fail("init_complete held after release");
    for (int b = 0; b < 8; b++) open_m[b] = 0;
  endtask

  task automatic lp_enter;
    @(negedge clk); dfi_lp_ctrl = 1;
    repeat (2) begin @(negedge clk); if (dfi_lp_ctrl_ack) fail("lp ack early"); end
    @(negedge clk);
    if (!dfi_lp_ctrl_ack) fail("lp ack");
  endtask
  task automatic lp_exit;
    @(negedge clk); dfi_lp_ctrl = 0;
    repeat (2) begin @(negedge clk); if (!dfi_lp_ctrl_ack) fail("lp ack dropped early"); end
    @(negedge clk);
    if (dfi_lp_ctrl_ack) fail("lp ack release");
  endtask

  task automatic hard_reset;
    drain();
    @(negedge clk); rst_n = 0;
    repeat (2) @(negedge clk);
    if (irq || dfi_init_complete || dfi_lp_ctrl_ack || dfi_rddata_valid) fail("reset state");
    rst_n = 1;
    for (int b = 0; b < 8; b++) open_m[b] = 0;
    exp_rd = exp_wr;
  endtask

  task automatic expect_irq(input bit e, input string m);
    nop(); nop();
    if (irq !== e) fail($sformatf("%s: irq %b exp %b", m, irq, e));
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  initial begin
    for (int i = 0; i < 64; i++) begin
      s_we[i] = 0; s_re[i] = 0; s_wx[i] = 0; s_rx[i] = 0; s_wd[i] = 0; s_wm[i] = 0;
      s_wa[i] = 0; s_ra[i] = 0;
    end
    for (int i = 0; i < 256; i++) begin mem_m[i] = 'x; exp_a[i] = 0; exp_d[i] = 0; end
    for (int b = 0; b < 8; b++) begin open_m[b] = 0; row_m[b] = 0; end
    repeat (3) @(negedge clk);
    if (irq || dfi_init_complete || dfi_lp_ctrl_ack || dfi_rddata_valid || dfi_rddata)
      fail("reset state");
    rst_n = 1;

    // ---------------- commands before init
    cmd(NOP); cmd(NOP, 0, 0, 1);                    // NOP and deselect are fine
    expect_irq(0, "NOP / DES before init");
    cmd(RD, 1, 3);
    expect_irq(1, "RD before init");

    // ---------------- init, fill the whole array, read it back
    hard_reset();
    init();
    for (int b = 0; b < 8; b++) begin
      for (int r = 0; r < 4; r++) begin
        act(b[2:0], {$urandom, 2'(r)});
        for (int c = 0; c < 8; c++) wr(b[2:0], 3'(c), $urandom);
        for (int c = 0; c < 8; c++) rd(b[2:0], 3'(c));
        drain();
        cmd(PRE, b[2:0], 17'h0);
        open_m[b] = 0;
      end
    end
    expect_irq(0, "array fill");

    // ---------------- byte masks, read-after-write in flight
    act(3, 17'h1_F002);
    for (int m = 0; m < 16; m++) begin
      wr(3, 3'(m % 8), $urandom, 4'(m));
      rd(3, 3'(m % 8));
    end
    drain();
    // all 8 banks open, PRE single, REF and MRS only with all closed
    for (int b = 0; b < 8; b++) if (!open_m[b]) act(b[2:0], $urandom);
    cmd(PRE, 5, 17'h0); open_m[5] = 0;
    act(5, 17'h3);
    cmd(PRE, 0, 17'h0_0400);                        // A10: all banks
    for (int b = 0; b < 8; b++) open_m[b] = 0;
    cmd(PRE, 2, 17'h0);                             // PRE to a closed bank is fine
    cmd(REF); cmd(MRS, 0, $urandom);
    expect_irq(0, "precharge / refresh / mode register");

    // ---------------- low power, cke low, odt
    lp_enter();
    nop();
    lp_exit();
    dfi_odt = 1;
    act(6, 17'h2);
    @(negedge clk); dfi_cke = 0; nop(); nop(); @(negedge clk); dfi_cke = 1;
    wr(6, 1, 32'hCAFE_F00D); nop(); rd(6, 1); drain();
    dfi_odt = 0;
    expect_irq(0, "low power / cke");

    // ---------------- random traffic: back-to-back commands on open banks
    for (int b = 0; b < 8; b++) if (!open_m[b]) act(b[2:0], $urandom);
    for (int n = 0; n < 600; n++) begin
      int b;
      b = $urandom % 8;
      case ($urandom % 4)
        0: wr(b[2:0], 3'($urandom), $urandom, ($urandom % 3 == 0) ? 4'($urandom) : 4'h0);
        1: rd(b[2:0], 3'($urandom));
        2: nop();
        default: begin
          drain();
          cmd(PRE, b[2:0], 17'h0); open_m[b] = 0;
          act(b[2:0], $urandom);
        end
      endcase
    end
    drain();
    expect_irq(0, "random traffic");

    // ---------------- re-init with banks open closes them
    init();
    cmd(RD, 6, 0);
    expect_irq(1, "RD after re-init (banks closed)");

    // ---------------- faults (irq is sticky: reset after each)
    hard_reset(); init();                          // re-init revokes the ready state
    @(negedge clk); dfi_init_start = 1; repeat (4) @(negedge clk);
    cmd(REF); expect_irq(1, "REF while re-initialising");
    dfi_init_start = 0;
    hard_reset(); init(); lp_enter(); cmd(WR, 0, 0); expect_irq(1, "WR in low power");
    lp_exit();
    hard_reset(); init(); lp_enter(); lp_exit(); act(0, 0);
    @(negedge clk); dfi_lp_ctrl = 1; @(negedge clk); dfi_lp_ctrl = 0;   // short request
    cmd(PRE, 0, 0); expect_irq(1, "PRE while the low-power request is pending");
    repeat (4) nop();
    hard_reset(); init(); @(negedge clk); dfi_cke = 0; cmd(ACT, 1, 0); dfi_cke = 1;
    expect_irq(1, "ACT with cke low");
    hard_reset(); init(); act(2, 1); cmd(ACT, 2, 3); expect_irq(1, "ACT to an open bank");
    hard_reset(); init(); cmd(WR, 4, 0); expect_irq(1, "WR to a closed bank");
    hard_reset(); init(); act(1, 0); cmd(REF); expect_irq(1, "REF with a bank open");
    hard_reset(); init(); act(1, 0); cmd(MRS); expect_irq(1, "MRS with a bank open");
    // missing / early / unexpected beats: the beat is dropped
    hard_reset(); init(); act(7, 2);
    cmd_now(WR, 7, 0); sched_wr(waddr(7, 0), 32'h1111_1111, 0, T_PHY_WRLAT, 0);
    drain(); expect_irq(1, "missing wrdata_en");
    hard_reset(); init(); act(7, 2);
    cmd_now(WR, 7, 1); sched_wr(waddr(7, 1), 32'h2222_2222, 0, T_PHY_WRLAT - 1);
    drain(); expect_irq(1, "early wrdata_en");
    hard_reset(); init(); act(7, 2);
    cmd_now(RD, 7, 2); sched_rd(waddr(7, 2), T_RDDATA_EN, 0);
    drain(); expect_irq(1, "missing rddata_en");
    hard_reset(); init(); act(7, 2);
    cmd_now(RD, 7, 3); sched_rd(waddr(7, 3), T_RDDATA_EN + 1);
    drain(); expect_irq(1, "late rddata_en");
    hard_reset(); init();
    cmd_now(MRS, 0, 0); sched_wr(0, 32'h3333_3333, 4'h0, 2); sched_rd(0, 5);
    drain(); expect_irq(1, "beats without commands");

    // ---------------- data patterns written and read back
    hard_reset(); init(); act(3, 1);
    for (int k = 0; k < 3; k++) wr(3, 3'(k), k == 0 ? 32'hFFFF_FFFF : k == 1 ? 32'h5555_5555 : 32'hAAAA_AAAA);
    drain();
    for (int k = 0; k < 3; k++) rd(3, 3'(k));
    drain(); expect_irq(0, "data patterns");

    // ---------------- re-init during init, reset in the middle of traffic
    hard_reset();
    @(negedge clk); dfi_init_start = 1; repeat (5) @(negedge clk); dfi_init_start = 0;
    begin : short_start                            // sequence runs on, complete pulses once
      int n;
      n = 0;
      repeat (40) begin @(negedge clk); if (dfi_init_complete) n++; end
      if (n != 1) fail($sformatf("short init_start: init_complete high %0d cycles", n));
    end
    act(0, 0); wr(0, 0, $urandom); rd(0, 0);
    do @(posedge clk); while (!dfi_rddata_en);     // reset with the read beat in flight
    @(negedge clk); rst_n = 0; repeat (2) @(negedge clk); rst_n = 1;
    exp_rd = exp_wr;
    for (int i = 0; i < 64; i++) begin s_we[i] = 0; s_re[i] = 0; s_wx[i] = 0; s_rx[i] = 0; end
    repeat (20) @(negedge clk);

    if (errors == 0) $display("TEST PASSED: DFI_5_0__MC_PHY_Interface_");
    else $display("TEST FAILED: DFI_5_0__MC_PHY_Interface_ (%0d errors)", errors);
    $finish;
  end

  initial begin
    #5ms;
    $display("TEST FAILED: DFI_5_0__MC_PHY_Interface_ (timeout)");
    $finish;
  end

endmodule
