// SPDX-License-Identifier: Apache-2.0
// DDR4_JEDEC_AXI-specific part of tb/DDR4_JEDEC_AXI_apb_tb.sv. The wrapper's
// controller-to-PHY pins (p_*) go to the behavioural PHY and the DDR4 device
// model, as in the core TB (tb/DDR4_JEDEC_AXI_tb.sv, which has the detailed
// burst checks); PCLK is CK (10 ns here).
// - Waits for STATUS.init_done.
// - Byte model of a 32 KB window: address bits 29:14 (the row) all 0 or all
//   1, bits 13:0 free (column, bank group, bank), bits 31:30 free (the AXI
//   space above 1 GB aliases the device). A full-strobe pass writes the
//   window first, so every read byte is known.
// - 300 random bursts: INCR (1..256 beats), FIXED, WRAP (2..16), AxSIZE 0..2,
//   random strobes and IDs, no 4 KB crossing.
// - SLVERR: AxSIZE 3..7, first with ERR masked (latched, irq low), then
//   enabled (irq high), W1C; ERR left pending into the final reset.
// - Counters against the device model's command counts: N_ACT = ACTs,
//   N_REF = REFs, N_HIT = RDs + WRs - ACTs, plus at most one per REF (a
//   refresh between a request's ACT and its RD / WR makes it ACT twice).
// - Verilator only (about 10M clocks): 65540 rounds of a read, a one-byte
//   write to the same row and an AxSIZE error read, alternating the row of
//   one bank, so N_RD, N_WR, N_ERR, N_ACT and N_HIT all pass 65536 and wrap.
wire        ck_t, ck_c, reset_n, cke, odt, cs_n, act_n, ras_n, cas_n, we_n;
wire [1:0]  bg, ba;
wire [13:0] a;
wire [15:0] dq;
wire [1:0]  dqs_t, dqs_c, dm_n;
ddr4_phy_beh #(.NDEV(1), .CL(22), .CWL(16), .TCK_PS(10000)) phy (
  .clk(PCLK), .p_reset_n, .p_cke, .p_odt, .p_cs_n, .p_act_n, .p_ras_n, .p_cas_n, .p_we_n,
  .p_bg, .p_ba, .p_a, .p_wr, .p_wdata, .p_wbe, .p_rvalid, .p_rdata,
  .ck_t, .ck_c, .reset_n, .cke, .odt, .cs_n, .act_n, .ras_n_a16(ras_n), .cas_n_a15(cas_n),
  .we_n_a14(we_n), .bg, .ba, .a, .dq, .dqs_t, .dqs_c, .dm_n
);
ddr4_dev_model #(.TCK_PS(10000), .CL(22), .CWL(16)) dram (
  .ck_t, .ck_c, .reset_n, .cke, .odt, .cs_n, .act_n, .ras_n_a16(ras_n), .cas_n_a15(cas_n),
  .we_n_a14(we_n), .bg, .ba, .a, .dq, .dqs_t, .dqs_c, .dm_n
);

initial begin
  s_awid = 0; s_awaddr = 0; s_awlen = 0; s_awsize = 2; s_awburst = 1; s_awvalid = 0;
  s_wdata = 0; s_wstrb = 0; s_wlast = 0; s_wvalid = 0; s_bready = 0;
  s_arid = 0; s_araddr = 0; s_arlen = 0; s_arsize = 2; s_arburst = 1; s_arvalid = 0; s_rready = 0;
end
localparam int MB = 32768;                                   // distinct bytes of the window
logic [7:0] mdl [0:MB - 1];
int n_rd = 0, n_wr = 0, n_err = 0;
function automatic int midx(input logic [31:0] ad);
  midx = int'({ad[29], ad[13:0]});
endfunction
// a random address of the window
function automatic logic [31:0] waddr();
  logic [31:0] r;
  r = $urandom;
  waddr = {r[31:30], {16{r[29]}}, r[13:0]};
endfunction
function automatic logic [31:0] baddr(input logic [31:0] ad, input int sz, input int bt,
                                      input int len, input int n);
  logic [31:0] nb, al, wm, x;
  nb = 32'd1 << sz; al = ad & ~(nb - 1);
  if (bt == 0 || n == 0) baddr = ad;
  else if (bt == 1) baddr = al + 32'(n) * nb;
  else begin
    wm = 32'(len + 1) * nb - 1;
    x = al + 32'(n) * nb;
    baddr = (ad & ~wm) | (x & wm);
  end
endfunction
function automatic logic [3:0] lanes(input logic [31:0] ad, input int sz);
  logic [3:0] m;
  m = (sz == 0) ? 4'b0001 : (sz == 1) ? 4'b0011 : 4'b1111;
  lanes = m << (ad[1:0] & ~2'((1 << sz) - 1));
endfunction
task automatic wburst(input logic [31:0] ad, input int len, input int sz, input int bt,
                      input logic [3:0] fixed_st, output logic [1:0] resp);
  logic [3:0] id;
  id = $urandom;
  @(negedge PCLK);
  s_awid = id; s_awaddr = ad; s_awlen = 8'(len); s_awsize = 3'(sz); s_awburst = 2'(bt); s_awvalid = 1;
  @(posedge PCLK); while (!s_awready) @(posedge PCLK);
  @(negedge PCLK); s_awvalid = 0;
  for (int n = 0; n <= len; n++) begin
    logic [31:0] ba_, d;
    logic [3:0]  st;
    ba_ = baddr(ad, sz, bt, len, n); d = $urandom;
    st = 4'($urandom) & lanes(ba_, sz);
    if ($urandom % 3 == 0 || sz == 0) st = lanes(ba_, sz);
    if (fixed_st != 0) st = fixed_st & lanes(ba_, sz);
    s_wdata = d; s_wstrb = st; s_wlast = (n == len); s_wvalid = 1;
    @(posedge PCLK); while (!s_wready) @(posedge PCLK);
    if (sz <= 2)
      for (int b = 0; b < 4; b++)
        if (st[b]) mdl[midx({ba_[31:2], 2'(b)})] = d[8 * b +: 8];
    @(negedge PCLK);
  end
  s_wvalid = 0; s_wlast = 0; s_bready = 1;
  @(posedge PCLK); while (!s_bvalid) @(posedge PCLK);
  resp = s_bresp;
  if (s_bid !== id) fail("BID mismatch");
  n_wr++; if (resp == 2'b10) n_err++;            // every burst counts, errors too
  @(negedge PCLK); s_bready = 0;
endtask
task automatic rburst(input logic [31:0] ad, input int len, input int sz, input int bt,
                      input bit chk, output logic [1:0] resp);
  logic [3:0] id;
  id = $urandom;
  @(negedge PCLK);
  s_arid = id; s_araddr = ad; s_arlen = 8'(len); s_arsize = 3'(sz); s_arburst = 2'(bt); s_arvalid = 1;
  @(posedge PCLK); while (!s_arready) @(posedge PCLK);
  @(negedge PCLK); s_arvalid = 0; s_rready = 1;
  for (int n = 0; n <= len; n++) begin
    logic [31:0] ba_;
    logic [3:0]  ln;
    @(posedge PCLK); while (!s_rvalid) @(posedge PCLK);
    ba_ = baddr(ad, sz, bt, len, n); ln = lanes(ba_, sz);
    if (s_rid !== id) fail("RID mismatch");
    if (s_rlast !== (n == len)) fail($sformatf("RLAST on beat %0d of %0d", n, len + 1));
    resp = s_rresp;
    if (chk && sz <= 2) for (int b = 0; b < 4; b++)
      if (ln[b] && s_rdata[8 * b +: 8] !== mdl[midx({ba_[31:2], 2'(b)})])
        fail($sformatf("read %h byte %0d: %h, expected %h", ba_, b, s_rdata[8 * b +: 8], mdl[midx({ba_[31:2], 2'(b)})]));
    @(negedge PCLK);
  end
  s_rready = 0;
  n_rd++; if (resp == 2'b10) n_err++;
endtask
task automatic rnd_burst(input bit wr_it);
  int sz, bt, len;
  logic [31:0] ad;
  logic [1:0]  r;
  sz = $urandom % 3; bt = $urandom % 3;
  len = (bt == 2) ? (2 << ($urandom % 4)) - 1 : ($urandom % 4 == 0) ? $urandom % 256 : $urandom % 16;
  ad = waddr() & ~((32'd1 << sz) - 1);
  if (bt == 1 && 32'(ad[11:0]) + 32'((len + 1) << sz) > 32'd4096) ad[11:0] = 12'h0;
  if (wr_it) wburst(ad, len, sz, bt, 4'h0, r); else rburst(ad, len, sz, bt, 1, r);
  if (r != 2'b00) fail($sformatf("%s burst response %0d", wr_it ? "write" : "read", r));
endtask
// the device model's counts: N_ACT, N_REF, N_HIT
task automatic check_dram_counters;
  repeat (100) @(negedge PCLK);                          // let a refresh in progress finish
  rd_exp(A_N_ACT, 32'(dram.n_cmd[0] & 16'hFFFF));
  rd_exp(A_N_REF, 32'(dram.n_cmd[4] & 16'hFFFF));
  // a refresh between a request's ACT and its RD / WR makes it ACT twice
  rd(A_N_HIT);
  if (((rdv - (dram.n_cmd[1] + dram.n_cmd[2] - dram.n_cmd[0])) & 16'hFFFF) > dram.n_cmd[4])
    fail($sformatf("N_HIT %0d, RD + WR - ACT %0d, REF %0d", rdv, dram.n_cmd[1] + dram.n_cmd[2] - dram.n_cmd[0],
                   dram.n_cmd[4]));
endtask
task automatic ip_func;
  logic [1:0] r;
  poll(A_STATUS, 32'h1, 32'h1, 1000);
  if (dram.n_cmd[5] != 7) fail("expected 7 MRS during init");
  for (int i = 0; i < MB; i += 64) begin                 // full-strobe pass: every byte known
    logic [31:0] ad;
    ad = {2'($urandom), {16{i[14]}}, 14'(i)};
    wburst(ad, 15, 2, 1, 4'hF, r);
  end
  for (int k = 0; k < 300; k++) rnd_burst($urandom % 2);
  rd_exp(A_N_RD, 32'(n_rd & 16'hFFFF)); rd_exp(A_N_WR, 32'(n_wr & 16'hFFFF)); rd_exp(A_N_ERR, 0);
  rd_exp(A_FLAGS, 0);
  check_dram_counters();
  // AxSIZE above 2: SLVERR; ERR masked first, then enabled
  wburst(32'h0, 0, 7, 1, 4'h0, r);
  if (r != 2'b10) fail("no SLVERR on an AxSIZE 7 write");
  rd_exp(A_IRQ_STATUS, 32'h1);
  if (irq !== 1'b0) fail("irq high with ERR masked");
  wr(A_IRQ_STATUS, 32'h1);
  wr(A_IRQ_ENABLE, 32'h1);
  rburst(32'h0, 1, 3, 1, 0, r);
  if (r != 2'b10) fail("no SLVERR on an AxSIZE 3 read");
  rd_exp(A_IRQ_STATUS, 32'h1);
  if (irq !== 1'b1) fail("irq low with ERR pending and enabled");
  wr(A_IRQ_STATUS, 32'h1); rd_exp(A_IRQ_STATUS, 0);
  if (irq !== 1'b0) fail("irq still high after W1C");
  rburst(32'h4, 0, 2, 1, 1, r);                         // the erroring write changed nothing
  rd_exp(A_N_ERR, 32'(n_err));
`ifdef VERILATOR
  for (int k = 0; k < 65540; k++) begin
    logic [31:0] ad;
    ad = {2'($urandom), {16{k[0]}}, 2'b01, 12'(4 * ($urandom % 1024))};  // bank 1, the row alternates
    rburst(ad, 0, 2, 1, 1, r);
    wburst(ad + 32'($urandom % 4), 0, 0, 1, 4'h0, r);   // one byte, same row: a page hit
    rburst(ad, 0, 3 + $urandom % 5, 1, 0, r);              // AxSIZE 3..7: SLVERR
  end
  rd_exp(A_N_RD, 32'(n_rd & 16'hFFFF)); rd_exp(A_N_WR, 32'(n_wr & 16'hFFFF));
  rd_exp(A_N_ERR, 32'(n_err & 16'hFFFF));
`endif
  check_dram_counters();
  if (dram.ERRORS != 0) fail($sformatf("device model saw %0d violations", dram.ERRORS));
  rburst(32'h0, 0, 3, 1, 0, r);                          // ERR left pending into the final reset
endtask
