// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench of DDR4_JEDEC_AXI_top + ddr4_phy_beh + ddr4_dev_model
// ----------------------------------------------------------------------------
//  - Init: waits for INIT_DONE (RESET_n, CKE, MRS, ZQCL seen by the device).
//  - Directed: aligned / unaligned INCR, narrow (AxSIZE 0 / 1) with sparse
//    strobes, WRAP 4/8/16, FIXED, a 256-beat INCR, row misses in one bank,
//    bank-group ping-pong.
//  - Random: NRAND write and read bursts on concurrent AW / AR threads over
//    a few rows per bank (hits, misses, conflicts), checked against a byte
//    reference model; unwritten bytes predicted from ddr4_dev_model.init_word.
//  - Data classes (zeros, ones, 0x55 / 0xAA), the top row and last column of
//    every bank, and the AXI space above 1 GB, which aliases the device.
//  - Negative: AxSIZE 3..7 read and write -> SLVERR, no DRAM access;
//    WLAST one beat early or missing -> SLVERR. A second device model with a
//    tighter tRCD must flag tRCD errors (the checker works). 1024 more short
//    error bursts each way run the status counters past 1024.
//  - B / R backpressure in the random phase, with long R stalls that fill
//    the read FIFO. An idle stretch makes a refresh come due with every bank
//    closed. Last, a reset while running: the IP must power the device up
//    again and carry traffic.
//  - The short tREFI here makes refreshes (and PREA) happen during traffic.
//  - The device model must end with ERRORS == 0.
//  - Prints per-burst latency in the SoC TB's LAT format
//    ("LAT <master> <slave> <R|W> <cycles>"): AR/AW handshake to last R / B.
// ============================================================================
`timescale 1ps/1ps
module DDR4_JEDEC_AXI_tb;
  localparam int TCK   = 628;               // DDR4-3200 class (tCK 0.628 ns)
  localparam int NDEV  = 1;
  localparam int DQW   = 16 * NDEV;
  localparam int BB    = DQW;
  localparam int CL    = 22, CWL = 16;
  localparam int T_REFI = 3000;
  localparam int NRAND = 400;

  logic clk = 1'b0, rst_n = 1'b0;
  always #(TCK / 2) clk = ~clk;

  // AXI
  logic [3:0]  awid, bid, arid, rid;
  logic [31:0] awaddr, wdata, araddr, rdata;
  logic [7:0]  awlen, arlen;
  logic [2:0]  awsize, arsize;
  logic [1:0]  awburst, arburst, bresp, rresp;
  logic [3:0]  wstrb;
  logic awvalid = 0, awready, wvalid = 0, wready, wlast, bvalid, bready = 1;
  logic arvalid = 0, arready, rvalid, rready = 1, rlast;
  // controller <-> PHY
  logic p_reset_n, p_cke, p_odt, p_cs_n, p_act_n, p_ras_n, p_cas_n, p_we_n, p_wr, p_rvalid;
  logic [1:0] p_bg, p_ba;
  logic [13:0] p_a;
  logic [8*DQW-1:0] p_wdata, p_rdata;
  logic [BB-1:0] p_wbe;
  logic init_done, err_irq;
  logic [15:0] n_rd, n_wr, n_err, n_act, n_hit, n_ref;
  // pins
  wire ck_t, ck_c, reset_n, cke, odt, cs_n, act_n, ras_n, cas_n, we_n;
  wire [1:0] bg, ba;
  wire [13:0] a;
  wire [DQW-1:0] dq;
  wire [DQW/8-1:0] dqs_t, dqs_c, dm_n;

  DDR4_JEDEC_AXI_top #(.NDEV(NDEV), .CL(CL), .CWL(CWL), .T_REFI(T_REFI),
                       .T_RESET(16), .T_CKE(16), .T_XPR(576), .T_ZQINIT(1024)) dut (
    .clk, .rst_n,
    .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize), .s_awburst(awburst),
    .s_awvalid(awvalid), .s_awready(awready),
    .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast), .s_wvalid(wvalid), .s_wready(wready),
    .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
    .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize), .s_arburst(arburst),
    .s_arvalid(arvalid), .s_arready(arready),
    .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast), .s_rvalid(rvalid), .s_rready(rready),
    .p_reset_n, .p_cke, .p_odt, .p_cs_n, .p_act_n, .p_ras_n, .p_cas_n, .p_we_n,
    .p_bg, .p_ba, .p_a, .p_wr, .p_wdata, .p_wbe, .p_rvalid, .p_rdata,
    .init_done, .n_rd, .n_wr, .n_err, .n_act, .n_hit, .n_ref, .err_irq
  );

  ddr4_phy_beh #(.NDEV(NDEV), .CL(CL), .CWL(CWL), .TCK_PS(TCK)) phy (
    .clk, .p_reset_n, .p_cke, .p_odt, .p_cs_n, .p_act_n, .p_ras_n, .p_cas_n, .p_we_n,
    .p_bg, .p_ba, .p_a, .p_wr, .p_wdata, .p_wbe, .p_rvalid, .p_rdata,
    .ck_t, .ck_c, .reset_n, .cke, .odt, .cs_n, .act_n, .ras_n_a16(ras_n), .cas_n_a15(cas_n),
    .we_n_a14(we_n), .bg, .ba, .a, .dq, .dqs_t, .dqs_c, .dm_n
  );

  ddr4_dev_model #(.TCK_PS(TCK), .CL(CL), .CWL(CWL), .T_REFI(T_REFI)) dram (
    .ck_t, .ck_c, .reset_n, .cke, .odt, .cs_n, .act_n, .ras_n_a16(ras_n), .cas_n_a15(cas_n),
    .we_n_a14(we_n), .bg, .ba, .a, .dq(dq[15:0]), .dqs_t(dqs_t[1:0]), .dqs_c(dqs_c[1:0]), .dm_n(dm_n[1:0])
  );
  // negative check of the checker: this one believes tRCD is 4 nCK longer
  ddr4_dev_model #(.TCK_PS(TCK), .CL(CL), .CWL(CWL), .T_REFI(T_REFI), .T_RCD(26), .DATA(0), .QUIET(1)) strict (
    .ck_t, .ck_c, .reset_n, .cke, .odt, .cs_n, .act_n, .ras_n_a16(ras_n), .cas_n_a15(cas_n),
    .we_n_a14(we_n), .bg, .ba, .a, .dq(), .dqs_t(), .dqs_c(), .dm_n()
  );

  longint cyc = 0;                       // CK cycle count (latency, reference timestamps)
  always @(posedge clk) cyc++;

  // ---------------- reference model ----------------
  // byte reference model: open-addressing hash (iverilog has no associative arrays)
  localparam int RN = 1 << 19;
  int unsigned  r_key [RN];
  byte unsigned r_val [RN];
  bit           r_use [RN];
  longint       r_time [RN];             // cycle of the B that made the byte visible
  // AXI orders nothing between a read and a concurrent write: a read skips the
  // bytes of the write burst in flight while it runs and bytes whose write
  // completed after its AR handshake
  bit           wf_act = 0;
  int unsigned  wf_lo, wf_hi;
  // the 1 GB device decodes address bits 29:0; the AXI space above aliases it
  localparam int unsigned AMASK = 32'h3FFF_FFFF;
  function automatic int r_slot(input int unsigned a);
    int i;
    int unsigned ad;
    ad = a & AMASK;
    i = int'(ad * 32'h9E37_79B1) & (RN - 1);
    while (r_use[i] && r_key[i] != ad) i = (i + 1) & (RN - 1);
    r_slot = i;
  endfunction
  task automatic ref_wr(input int unsigned ad, input byte unsigned v);
    int i;
    i = r_slot(ad);
    r_use[i] = 1'b1; r_key[i] = ad & AMASK; r_val[i] = v; r_time[i] = cyc;
  endtask
  function automatic bit ambiguous(input int unsigned ad, input longint t_ar,
                                   input bit amb, input int unsigned lo, input int unsigned hi);
    int i;
    i = r_slot(ad);
    ambiguous = (amb && ad >= lo && ad <= hi) || (r_use[i] && r_time[i] >= t_ar);
  endfunction
  int errors = 0;

  function automatic byte unsigned predict(input int unsigned ad);
    int off, colhi, bgv, bav, row, beat, lane, dev, col, bank;
    logic [15:0] w;
    int i;
    i = r_slot(ad);
    if (r_use[i]) return r_val[i];
    off   = ad % BB;
    colhi = (ad / BB) % 128;
    bgv   = (ad / (BB * 128)) % 2;
    bav   = (ad / (BB * 256)) % 4;
    row   = (ad / (BB * 1024)) % 65536;
    beat  = off / (DQW / 8);
    lane  = off % (DQW / 8);
    dev   = lane / 2;
    col   = colhi * 8 + beat;
    bank  = bgv * 4 + bav;
    w     = dram.init_word(bank, row, col);
    return (lane % 2) ? w[15:8] : w[7:0];
  endfunction

  function automatic int unsigned nxt(input int unsigned ad, input int sz, input int len, input int bt);
    int unsigned inc = 1 << sz, al = ad & ~(inc - 1), wm;
    if (bt == 0) return ad;
    if (bt == 2) begin
      wm = (len + 1) * inc - 1;
      return (ad & ~wm) | ((al + inc) & wm);
    end
    return al + inc;
  endfunction

  // ---------------- latency log ----------------
  int lat_n[2], lat_sum[2], lat_min[2], lat_max[2];
  task automatic lat(input int rw, input int c);
    $display("LAT axi ddr4 %s %0d", rw ? "W" : "R", c);
    lat_n[rw]++; lat_sum[rw] += c;
    if (lat_n[rw] == 1 || c < lat_min[rw]) lat_min[rw] = c;
    if (c > lat_max[rw]) lat_max[rw] = c;
  endtask

  // ---------------- AXI master tasks ----------------
  bit wbusy = 0, rbusy = 0;               // one AW thread / one AR thread at a time
  bit bp_en = 0;                          // random B / R backpressure

  // bad_last: 0 WLAST on the last beat, 1 one beat early, 2 missing (one beat late)
  // pat: -1 random data and strobes, 0 zeros, 1 ones, 2 0x55.. / 0xAA.. (full strobes)
  task automatic axi_write(input int unsigned ad, input int len, input int sz, input int bt,
                           input int bad_last = 0, input bit expect_err = 0, input int pat = -1);
    int unsigned x = ad;
    longint t0;
    int unsigned  sh_a [1024];
    byte unsigned sh_d [1024];
    int           sh_n = 0;
    while (wbusy) @(negedge clk);
    wbusy = 1;
    // byte span the burst can touch (a WRAP stays in its aligned window)
    wf_lo = (bt == 2) ? (ad & ~(((len + 1) << sz) - 1)) : (ad & ~32'h3);
    wf_hi = (bt == 2) ? wf_lo + ((len + 1) << sz) - 1 : (ad & ~32'h3) + ((len + 1) << sz) + 3;
    wf_act = 1;
    // drive on the falling edge, look at READY there too: a handshake then
    // happens on the next rising edge (no race with the DUT's flops)
    @(negedge clk);
    awid = 4'(ad); awaddr = ad; awlen = 8'(len); awsize = 3'(sz); awburst = 2'(bt); awvalid = 1;
    while (!awready) @(negedge clk);
    @(posedge clk);
    t0 = cyc;
    @(negedge clk);
    awvalid = 0;
    for (int i = 0; i <= (bad_last == 1 ? len - 1 : bad_last == 2 ? len + 1 : len); i++) begin
      logic [31:0] d;
      logic [3:0]  s;
      int unsigned base;
      d = $urandom; s = 0; base = x & ~32'h3;
      if (pat == 0) d = 32'h0;
      if (pat == 1) d = 32'hFFFF_FFFF;
      if (pat == 2) d = i[0] ? 32'hAAAA_AAAA : 32'h5555_5555;
      for (int b = 0; b < 4; b++)
        if ((base + b) >= (x & ~((1 << sz) - 1)) && (base + b) < (x & ~((1 << sz) - 1)) + (1 << sz))
          s[b] = pat >= 0 || $urandom_range(0, 3) != 0;
      wdata = d; wstrb = s; wvalid = 1;
      wlast = bad_last == 1 ? (i == len - 1) : bad_last == 2 ? (i == len + 1) : (i == len);
      if (sz <= 2 && !expect_err)
        for (int b = 0; b < 4; b++) if (s[b]) begin sh_a[sh_n] = base + b; sh_d[sh_n] = d[8*b +: 8]; sh_n++; end
      while (!wready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      wvalid = 0; wlast = 0;
      x = nxt(x, sz, len, bt);
    end
    bready = bp_en ? $urandom_range(0, 1) : 1'b1;
    while (!(bvalid && bready)) begin
      @(negedge clk);
      bready = bp_en ? $urandom_range(0, 1) : 1'b1;
    end
    if (bresp != (expect_err ? 2'b10 : 2'b00)) begin
      errors++; $display("ERROR: write @%h BRESP %0d", ad, bresp);
    end
    if (bid != 4'(ad)) begin errors++; $display("ERROR: BID"); end
    @(posedge clk);
    if (!expect_err) begin
      for (int k = 0; k < sh_n; k++) ref_wr(sh_a[k], sh_d[k]);
      lat(1, int'(cyc - t0));
    end
    wf_act = 0;
    wbusy = 0;
  endtask

  task automatic axi_read(input int unsigned ad, input int len, input int sz, input int bt,
                          input bit expect_err = 0);
    int unsigned x = ad;
    longint t0;
    int i = 0, hold;
    bit last, amb;
    int unsigned alo, ahi;
    while (rbusy) @(negedge clk);
    rbusy = 1;
    @(negedge clk);
    arid = 4'(ad >> 4); araddr = ad; arlen = 8'(len); arsize = 3'(sz); arburst = 2'(bt); arvalid = 1;
    while (!arready) @(negedge clk);
    @(posedge clk);
    t0 = cyc;
    @(negedge clk);
    arvalid = 0;
    amb = 0; alo = 32'hFFFF_FFFF; ahi = 0;
    last = 0;
    // backpressure: random R ready, and now and then a long stall that fills the read FIFO
    hold = (bp_en && $urandom_range(0, 3) == 0) ? 80 : 0;
    while (!last) begin
      rready = hold > 0 ? 1'b0 : bp_en ? $urandom_range(0, 1) : 1'b1;
      while (!(rvalid && rready)) begin
        if (wf_act) begin amb = 1; if (wf_lo < alo) alo = wf_lo; if (wf_hi > ahi) ahi = wf_hi; end
        @(negedge clk);
        if (hold > 0) hold--;
        rready = hold > 0 ? 1'b0 : bp_en ? $urandom_range(0, 1) : 1'b1;
      end
      if (wf_act) begin amb = 1; if (wf_lo < alo) alo = wf_lo; if (wf_hi > ahi) ahi = wf_hi; end
      if (rresp != (expect_err ? 2'b10 : 2'b00)) begin
        errors++; $display("ERROR: read @%h beat %0d RRESP %0d", ad, i, rresp);
      end
      if (rid != 4'(ad >> 4)) begin errors++; $display("ERROR: RID"); end
      if (rlast != (i == len)) begin errors++; $display("ERROR: RLAST beat %0d of %0d", i, len); end
      if (!expect_err) begin
        int unsigned base, lo;
        base = x & ~32'h3; lo = x & ~((1 << sz) - 1);
        for (int b = 0; b < 4; b++)
          if (base + b >= lo && base + b < lo + (1 << sz) && !ambiguous(base + b, t0, amb, alo, ahi) &&
              rdata[8*b +: 8] !== predict(base + b)) begin
            errors++;
            $display("ERROR: read @%h byte %h: got %h exp %h", ad, base + b, rdata[8*b +: 8], predict(base + b));
          end
      end
      x = nxt(x, sz, len, bt);
      last = rlast;
      @(posedge clk);
      if (!last) begin
        @(negedge clk);
        i++;
      end
    end
    if (!expect_err) lat(0, int'(cyc - t0));
    rbusy = 0;
  endtask

  // ---------------- test ----------------
  function automatic int unsigned raddr();
    // a few rows per bank (0, 1, 7, 300) so random traffic hits, misses and conflicts
    int unsigned r, bk, c;
    case ($urandom_range(0, 3)) 0: r = 0; 1: r = 1; 2: r = 7; default: r = 300; endcase
    bk = $urandom_range(0, 7); c = $urandom_range(0, 127);
    return (r * 1024 + bk * 128 + c) * BB + $urandom_range(0, BB - 1);
  endfunction

  task automatic rand_writes();
    int sz, len, bt;
    for (int k = 0; k < NRAND; k++) begin
      sz = $urandom_range(0, 2); len = $urandom_range(0, 15); bt = $urandom_range(0, 2);
      if (bt == 2) len = (1 << $urandom_range(1, 4)) - 1;
      axi_write(raddr() & ~((1 << sz) - 1), len, sz, bt == 0 ? 1 : bt);
    end
  endtask
  task automatic rand_reads();
    int sz, len, bt;
    for (int k = 0; k < NRAND; k++) begin
      sz = $urandom_range(0, 2); len = $urandom_range(0, 15); bt = $urandom_range(1, 2);
      if (bt == 2) len = (1 << $urandom_range(1, 4)) - 1;
      axi_read(raddr() & ~((1 << sz) - 1), len, sz, bt);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1;
    wait (init_done);
    $display("init done at %0t, %0d MRS seen", $time, dram.n_cmd[5]);
    if (dram.n_cmd[5] != 7) begin errors++; $display("ERROR: expected 7 MRS"); end

    // directed
    axi_write(32'h0000_0000, 3, 2, 1); axi_read(32'h0000_0000, 3, 2, 1);
    axi_write(32'h0000_0106, 9, 1, 1); axi_read(32'h0000_0100, 7, 2, 1);
    axi_write(32'h0000_0233, 12, 0, 1); axi_read(32'h0000_0230, 5, 2, 1);
    axi_read(32'h0000_0233, 12, 0, 1);
    axi_write(32'h0000_0418, 3, 2, 2); axi_read(32'h0000_0410, 3, 2, 2);
    axi_write(32'h0000_0538, 7, 2, 2); axi_read(32'h0000_0524, 15, 2, 2);
    axi_write(32'h0000_0604, 3, 2, 0); axi_read(32'h0000_0604, 2, 2, 0);
    axi_write(32'h0001_0000, 255, 2, 1); axi_read(32'h0001_0000, 255, 2, 1);
    axi_write(32'h0002_0004, 40, 2, 1); axi_read(32'h0002_0004, 40, 2, 1);
    // FIXED: one beat, and narrow (bytes and halfwords) on one address
    axi_write(32'h0000_0700, 0, 2, 0); axi_read(32'h0000_0700, 0, 2, 0);
    axi_write(32'h0000_0743, 3, 0, 0); axi_read(32'h0000_0743, 3, 0, 0);
    axi_write(32'h0000_0786, 3, 1, 0); axi_read(32'h0000_0786, 3, 1, 0);
    // row misses in one bank (bank 0, rows 0, 1, 2)
    for (int r = 0; r < 3; r++) begin
      axi_write(r * 1024 * BB + 32'h40, 1, 2, 1);
      axi_read (r * 1024 * BB + 32'h40, 1, 2, 1);
    end
    // data classes: zeros, ones, alternating 0x55 / 0xAA (full strobes)
    for (int p = 0; p < 3; p++) begin
      axi_write(32'h0000_1000 + p * 32'h40, 7, 2, 1, 0, 0, p);
      axi_read (32'h0000_1000 + p * 32'h40, 7, 2, 1);
    end
    // every bank: the top row and the last column (all address bits 1), then row 0
    for (int bk = 0; bk < 8; bk++) begin
      axi_write(((65535 * 1024 + bk * 128 + 127) * BB) + BB - 1, 0, 0, 1);
      axi_read (((65535 * 1024 + bk * 128 + 127) * BB) + BB - 1, 0, 0, 1);
      axi_write((bk * 128) * BB, 0, 2, 1);
      axi_read ((bk * 128) * BB, 0, 2, 1);
    end
    // the AXI space above 1 GB aliases the device
    axi_write(32'hFFFF_FFF0, 3, 2, 1);
    axi_read (32'h3FFF_FFF0, 3, 2, 1);
    axi_read (32'hBFFF_FFF0, 3, 2, 1);
    axi_read (32'hFFFF_FFF0, 3, 2, 1);
    axi_read (32'h7FFF_FFF0, 3, 2, 1);
    axi_write(32'h4000_2000, 3, 2, 1);
    axi_read (32'h0000_2000, 3, 2, 1);

    // negative: AxSIZE 3..7 (no DRAM access), WLAST one beat early, WLAST missing
    for (int sz = 3; sz < 8; sz++) begin
      axi_write(32'h0000_0800, 1, sz, 1, 0, 1);
      axi_read (32'h0000_0800, 1, sz, 1, 1);
    end
    axi_write(32'h0000_0900, 3, 2, 1, 1, 1);
    axi_read (32'h0000_0900, 3, 2, 1);          // nothing was written there
    axi_write(32'h0000_0A00, 3, 2, 1, 2, 1);

    // random, concurrent AW and AR, with B / R backpressure
    bp_en = 1;
    fork
      rand_writes();
      rand_reads();
    join
    // read back everything written so far after the random phase settles
    for (int k = 0; k < 64; k++) axi_read(raddr() & ~32'h3, 15, 2, 1);
    bp_en = 0;
    // many short error bursts: the status counters run past 1024
    for (int k = 0; k < 1024; k++) begin
      axi_write(32'h0000_0800, 0, 3 + k % 5, 1, 0, 1);
      axi_read (32'h0000_0800, 0, 3 + k % 5, 1, 1);
    end
    // idle for over two tREFI: a refresh comes due with every bank closed
    repeat (5 * T_REFI / 2) @(posedge clk);

    repeat (200) @(posedge clk);
    $display("ctrl: n_rd %0d n_wr %0d n_err %0d n_act %0d n_hit %0d n_ref %0d",
             n_rd, n_wr, n_err, n_act, n_hit, n_ref);
    $display("dram: ACT %0d RD %0d WR %0d PRE %0d REF %0d ERRORS %0d",
             dram.n_cmd[0], dram.n_cmd[1], dram.n_cmd[2], dram.n_cmd[3], dram.n_cmd[4], dram.ERRORS);
    for (int rw = 0; rw < 2; rw++)
      $display("latency %s: n %0d min %0d avg %0d max %0d cycles", rw ? "W" : "R",
               lat_n[rw], lat_min[rw], lat_sum[rw] / (lat_n[rw] ? lat_n[rw] : 1), lat_max[rw]);
    if (strict.ERRORS == 0) begin errors++; $display("ERROR: strict model missed the tRCD violation"); end
    else $display("negative check: strict model flagged %0d errors (expected)", strict.ERRORS);
    if (n_err != 12 + 2048) begin errors++; $display("ERROR: n_err %0d, expected %0d", n_err, 12 + 2048); end
    if (n_ref == 0) begin errors++; $display("ERROR: no refresh"); end
    if (dram.n_cmd[4] != n_ref) begin errors++; $display("ERROR: REF count mismatch"); end
    if (n_hit == 0 || n_act == 0) begin errors++; $display("ERROR: no page hits or no ACT"); end

    // reset while running: the controller must power the device up again
    @(negedge clk);
    rst_n = 0;
    repeat (4) @(negedge clk);
    if (init_done || n_rd != 0 || n_ref != 0) begin errors++; $display("ERROR: reset did not clear the IP"); end
    rst_n = 1;
    wait (init_done);
    $display("init done again at %0t, %0d MRS seen in all", $time, dram.n_cmd[5]);
    if (dram.n_cmd[5] != 14) begin errors++; $display("ERROR: expected 7 more MRS"); end
    axi_write(32'h0000_3000, 7, 2, 1);
    axi_read (32'h0000_3000, 7, 2, 1);
    repeat (100) @(posedge clk);
    if (dram.ERRORS != 0) begin errors++; $display("ERROR: device model saw %0d violations", dram.ERRORS); end
    if (errors == 0) $display("TEST PASSED: DDR4_JEDEC_AXI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #(64'd400_000_000);
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end
endmodule
