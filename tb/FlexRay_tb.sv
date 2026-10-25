// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for FlexRay_top v2.0
//  * Three nodes on one channel, each on its own clock (A 10 ns, B +0.1 %,
//    C -0.1 %): A is the coldstart node, B and C integrate on sync frames
//    and follow A through offset correction. A bus driver (BFM) sends
//    frames of its own in free slots, with faults on demand.
//  * Hosts queue random payloads; every non-null frame each node receives
//    is checked against what its sender queued, in order, together with ID,
//    length, cycle and flags; null frames must carry zeros. Error pulses are
//    counted per node and checked exactly.
//  * Three cluster configurations (bit time, TSS, slot length, action
//    point, slot count, NIT, payload lengths, slots, sync / coldstart roles,
//    channel B CRC, correction limit) chosen so that every configuration bit
//    takes both values.
//  * Faults: header and frame CRC, BSS / FES / TSS coding, wrong ID or cycle
//    count, glitches, a late sync frame beyond the correction limit, loss of
//    the time master (sync loss), sync frames with an invalid ID, long
//    frames (63, 64, 66, 127 words), reset in the middle of a frame, a
//    frame 10 / 11 HIGH bits after a coding error (channel idle), offset
//    correction exactly at the limit and one clock over it.
// ============================================================================
`timescale 1ns/1ps
module FlexRay_tb;
  logic clk_a = 0, clk_b = 0, clk_c = 0;
  always #5     clk_a = ~clk_a;
  always #5.005 clk_b = ~clk_b;
  always #4.995 clk_c = ~clk_c;
  logic rst_a = 0, rst_b = 0, rst_c = 0;

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction

  // cluster configuration
  logic [3:0] spc = 0, tss = 5;
  logic [9:0] slot_len = 420, nit = 993;
  logic [5:0] ap = 4, nslots = 6;
  logic [7:0] corr = 48;
  logic       chan_b = 0;

  logic bfm = 1;
  wire  a_txd, a_en, b_txd, b_en, c_txd, c_en;
  wire  bus = (a_en ? a_txd : 1'b1) & (b_en ? b_txd : 1'b1) & (c_en ? c_txd : 1'b1) & bfm;

  `define FR_NODE(X, CLK, RST) \
  logic [3:0]   X``_plen = 0; \
  logic [5:0]   X``_my = 0; \
  logic         X``_sync = 0, X``_cold = 0; \
  logic         X``_tx_valid = 0; \
  logic [127:0] X``_tx_data = 0; \
  wire          X``_tx_ready, X``_tx_done, X``_rx_valid, X``_rx_null, X``_rx_sync, X``_rx_startup; \
  wire  [5:0]   X``_rx_id;  \
  wire  [5:0]   X``_rx_cycle, X``_cycle, X``_slot; \
  wire  [6:0]   X``_rx_len; \
  wire  [127:0] X``_rx_data; \
  wire          X``_synced, X``_cycle_start; \
  wire          X``_e_cod, X``_e_hcrc, X``_e_fcrc, X``_e_slot, X``_e_sync; \
  FlexRay_top u_``X ( \
    .clk(CLK), .rst_n(RST), .rxd(bus), .txd(X``_txd), .tx_en(X``_en), \
    .cfg_spc(spc), .cfg_tss(tss), .cfg_slot(slot_len), .cfg_ap(ap), .cfg_nslots(nslots), \
    .cfg_nit(nit), .cfg_plen(X``_plen), .cfg_my_slot(X``_my), .cfg_sync(X``_sync), \
    .cfg_cold(X``_cold), .cfg_chan_b(chan_b), .cfg_corr(corr), \
    .tx_valid(X``_tx_valid), .tx_ready(X``_tx_ready), .tx_data(X``_tx_data), .tx_done(X``_tx_done), \
    .rx_valid(X``_rx_valid), .rx_id(X``_rx_id), .rx_cycle(X``_rx_cycle), .rx_len(X``_rx_len), \
    .rx_null(X``_rx_null), .rx_sync(X``_rx_sync), .rx_startup(X``_rx_startup), .rx_data(X``_rx_data), \
    .synced(X``_synced), .cycle(X``_cycle), .slot(X``_slot), .cycle_start(X``_cycle_start), \
    .err_coding(X``_e_cod), .err_hcrc(X``_e_hcrc), .err_fcrc(X``_e_fcrc), .err_slot(X``_e_slot), \
    .err_sync(X``_e_sync));

  `FR_NODE(a, clk_a, rst_a)
  `FR_NODE(b, clk_b, rst_b)
  `FR_NODE(c, clk_c, rst_c)

  // ---------------- protocol helpers ----------------
  function automatic logic [10:0] hcrc(input logic sy, input logic st, input logic [10:0] id,
                                       input logic [6:0] len);
    logic [19:0] d;
    logic [10:0] c;
    logic        fb;
    d = {sy, st, id, len};
    c = 11'h01A;
    for (int i = 19; i >= 0; i--) begin
      fb = d[i] ^ c[10];
      c  = {c[9:0], 1'b0};
      if (fb) c = c ^ 11'h385;
    end
    return c;
  endfunction
  function automatic logic [23:0] fcrc_bit(input logic [23:0] c, input logic b);
    logic fb;
    fb = b ^ c[23];
    c  = {c[22:0], 1'b0};
    if (fb) c = c ^ 24'h5D6DCB;
    return c;
  endfunction

  // ---------------- per node bookkeeping (0 A, 1 B, 2 C, 3 BFM) ----------------
  logic [127:0] sent [0:3][0:511];          // payloads in the order they were taken
  int           nsent [0:3];
  int           rptr [0:2][0:3];            // receiver, sender: next payload expected
  int           q_n [0:2];                  // payloads waiting to be queued
  logic [127:0] q_d [0:2];
  int           k_rx [0:2], k_null [0:2], k_tx [0:2];
  int           k_cod [0:2], k_hcrc [0:2], k_fcrc [0:2], k_slot [0:2], k_sync [0:2];
  int           slot_of [0:3];              // sender slots
  logic [3:0]   plen_of [0:3];
  logic         sync_of [0:3], cold_of [0:3];
  int           bfm_len;                    // BFM frame: payload words, data seed
  logic [7:0]   bfm_seed;
  bit           sb_on = 0;                  // scoreboard running

  function automatic int sender(input int sl);
    sender = -1;
    for (int i = 0; i < 4; i++) if (slot_of[i] == sl) sender = i;
  endfunction
  function automatic logic [127:0] trim(input logic [3:0] plen, input logic [127:0] d);
    for (int i = 0; i < 16; i++) if (i >= 2 * int'(plen)) d[8*i +: 8] = 8'h0;
    return d;
  endfunction

  `define FR_HOST(X, N, CLK) \
  always @(negedge CLK) begin \
    if (X``_tx_valid) X``_tx_valid = 0; \
    else if (X``_tx_ready && q_n[N] > 0) begin \
      X``_tx_data = q_d[N]; X``_tx_valid = 1; q_n[N]--; \
      sent[N][nsent[N]] = q_d[N]; nsent[N]++; \
    end \
    if (X``_tx_done) k_tx[N]++; \
    if (X``_e_cod) k_cod[N]++; \
    if (X``_e_hcrc) k_hcrc[N]++; \
    if (X``_e_fcrc) k_fcrc[N]++; \
    if (X``_e_slot) k_slot[N]++; \
    if (X``_e_sync) k_sync[N]++; \
    if (X``_rx_valid) begin : X``_rx \
      int s; \
      logic [127:0] e; \
      k_rx[N]++; \
      s = sender(X``_rx_id); \
      if (X``_rx_id != X``_slot && !(X``_slot == 0 && X``_rx_id == nslots)) \
        fail($sformatf("%s: frame id %0d in slot %0d", `"X`", X``_rx_id, X``_slot)); \
      if (X``_rx_null) begin \
        k_null[N]++; \
        if (X``_rx_data !== 0) fail($sformatf("%s: null frame from slot %0d with data", `"X`", X``_rx_id)); \
      end else if (s == 3) begin \
        e = 0; \
        for (int i = 0; i < 16; i++) if (i < 2 * bfm_len) e[8*i +: 8] = bfm_seed + 8'(i); \
        if (X``_rx_data !== e || int'(X``_rx_len) != bfm_len) \
          fail($sformatf("%s: BFM frame len %0d data %h", `"X`", X``_rx_len, X``_rx_data)); \
      end else if (s >= 0 && sb_on) begin \
        e = trim(plen_of[s], sent[s][rptr[N][s]]); \
        if (rptr[N][s] >= nsent[s]) fail($sformatf("%s: unexpected frame from node %0d", `"X`", s)); \
        else if (X``_rx_data !== e) \
          fail($sformatf("%s: from node %0d got %h, expected %h", `"X`", s, X``_rx_data, e)); \
        rptr[N][s]++; \
      end \
      if (s >= 0 && s < 3 && (X``_rx_len !== {3'd0, plen_of[s]} || X``_rx_sync !== sync_of[s] \
                              || X``_rx_startup !== (sync_of[s] & cold_of[s]))) \
        fail($sformatf("%s: header of node %0d: len %0d sync %0d startup %0d", `"X`", s, \
                       X``_rx_len, X``_rx_sync, X``_rx_startup)); \
      if (X``_rx_cycle !== X``_cycle) fail($sformatf("%s: cycle %0d in cycle %0d", `"X`", X``_rx_cycle, X``_cycle)); \
    end \
  end
  `FR_HOST(a, 0, clk_a)
  `FR_HOST(b, 1, clk_b)
  `FR_HOST(c, 2, clk_c)

  // counters snapshot: {rx, null, tx, cod, hcrc, fcrc, slot, sync} per node
  typedef struct packed { int rx, nul, tx, cod, hcrc, fcrc, slt, syn; } cnt_t;
  cnt_t s0 [0:2];
  function automatic cnt_t now_c(input int n);
    cnt_t c;
    c.rx = k_rx[n]; c.nul = k_null[n]; c.tx = k_tx[n]; c.cod = k_cod[n]; c.hcrc = k_hcrc[n];
    c.fcrc = k_fcrc[n]; c.slt = k_slot[n]; c.syn = k_sync[n];
    return c;
  endfunction
  task automatic snap; for (int n = 0; n < 3; n++) s0[n] = now_c(n); endtask
  // expected error deltas per node: E(cod, hcrc, fcrc, slot, sync)
  task automatic expect_err(input int n, input int cod, input int hc, input int fc, input int sl,
                            input int sy, input string what);
    cnt_t c, o;
    c = now_c(n); o = s0[n];
    if (c.cod - o.cod != cod || c.hcrc - o.hcrc != hc || c.fcrc - o.fcrc != fc
        || c.slt - o.slt != sl || c.syn - o.syn != sy)
      fail($sformatf("%s: node %0d errors cod %0d hcrc %0d fcrc %0d slot %0d sync %0d, expected %0d %0d %0d %0d %0d",
                     what, n, c.cod - o.cod, c.hcrc - o.hcrc, c.fcrc - o.fcrc,
                     c.slt - o.slt, c.syn - o.syn, cod, hc, fc, sl, sy));
  endtask
  task automatic expect_all(input int cod, input int hc, input int fc, input int sl, input int sy,
                            input string what);
    for (int n = 0; n < 3; n++) expect_err(n, cod, hc, fc, sl, sy, what);
  endtask
  task automatic expect_rx(input int n, input int rx, input string what);
    cnt_t o;
    o = s0[n];
    if (k_rx[n] - o.rx != rx) fail($sformatf("%s: node %0d received %0d frames, expected %0d",
                                             what, n, k_rx[n] - o.rx, rx));
  endtask

  // ---------------- schedule helpers (A's time base) ----------------
  function automatic real bt_ns;             // A's bit time
    return 80.0 * (real'(spc) + 1.0);
  endfunction
  task automatic at_cycle_start;            // the next cycle start of A
    @(negedge clk_a);
    while (!a_cycle_start) @(negedge clk_a);
  endtask
  task automatic cycles(input int n); repeat (n) at_cycle_start(); endtask
  // all nodes' scoreboard pointers to the present (no frame in flight)
  task automatic sb_start;
    for (int r = 0; r < 3; r++) for (int s = 0; s < 4; s++) rptr[r][s] = nsent[s];
    sb_on = 1;
  endtask
  // every payload taken by a sender reached every synced receiver
  task automatic sb_check(input string what);
    for (int r = 0; r < 3; r++)
      for (int s = 0; s < 3; s++)
        if (r != s && slot_of[s] != 0 && rptr[r][s] != nsent[s])
          fail($sformatf("%s: node %0d is at payload %0d of %0d from node %0d", what, r,
                         rptr[r][s], nsent[s], s));
  endtask
  // n cycles of traffic: each node queues a payload with probability 3/4
  task automatic traffic(input int n, input string what);
    snap();
    for (int k = 0; k < n; k++) begin
      for (int i = 0; i < 3; i++)
        if (slot_of[i] != 0 && $urandom % 4 != 0) begin
          q_d[i] = {$urandom, $urandom, $urandom, $urandom};
          q_n[i] = 1;
          if (k == 0) begin q_d[i] = i[0] ? {128{1'b1}} : 128'h0; q_n[i] = i == 0 ? 2 : 1; end
        end
      at_cycle_start();
    end
    at_cycle_start();                       // the last payloads go out
    sb_check(what);
    expect_all(0, 0, 0, 0, 0, what);
    if (!(a_synced && b_synced && c_synced)) fail($sformatf("%s: not all synced", what));
    #(20 * bt_ns());                          // every node is inside the new cycle
    if (a_cycle != b_cycle || a_cycle != c_cycle) fail($sformatf("%s: cycles %0d %0d %0d", what, a_cycle, b_cycle, c_cycle));
  endtask

  // ---------------- cluster configurations ----------------
  task automatic set_roles(input int sa, input int sb, input int sc_, input logic cold_b);
    a_my = sa; b_my = sb; c_my = sc_;
    a_cold = !cold_b; b_cold = cold_b; c_cold = 0;
    slot_of[0] = sa; slot_of[1] = sb; slot_of[2] = sc_;
    plen_of[0] = a_plen; plen_of[1] = b_plen; plen_of[2] = c_plen;
    sync_of[0] = a_sync; sync_of[1] = b_sync; sync_of[2] = c_sync;
    cold_of[0] = a_cold; cold_of[1] = b_cold; cold_of[2] = c_cold;
  endtask
  task automatic use_config(input int k);
    case (k)
      1: begin
        spc = 0; tss = 5; slot_len = 420; ap = 4; nslots = 6; nit = 1023; corr = 48; chan_b = 0;
        a_plen = 8; b_plen = 0; c_plen = 3; a_sync = 1; b_sync = 1; c_sync = 0;
        set_roles(1, 2, 4, 0);
      end
      2: begin
        spc = 15; tss = 15; slot_len = 520; ap = 30; nslots = 3; nit = 30; corr = 255; chan_b = 1;
        a_plen = 7; b_plen = 15; c_plen = 12; a_sync = 1; b_sync = 1; c_sync = 0;
        set_roles(1, 2, 0, 0);
      end
      default: begin
        // B (the time master) re-phases nobody: A drifts ~6 bits until slot 56
        spc = 0; tss = 5; slot_len = 120; ap = 12; nslots = 57; nit = 30; corr = 100; chan_b = 0;
        a_plen = 0; b_plen = 0; c_plen = 0; a_sync = 1; b_sync = 1; c_sync = 1;
        set_roles(56, 5, 57, 1);
      end
    endcase
    slot_of[3] = 0;
  endtask
  // reset everything into configuration k, wait until B and C are synced
  task automatic restart(input int k, input string what);
    int g;
    rst_a = 0; rst_b = 0; rst_c = 0; sb_on = 0;
    // limits and positions are combinational from the configuration:
    // sweep it while the nodes are held in reset
    for (int i = 0; i < 48; i++) begin
      {spc, tss} = $urandom; {slot_len, nit} = $urandom; {ap, nslots, corr} = $urandom;
      {a_plen, b_plen, c_plen, a_my, b_my, c_my} = {$urandom, $urandom};
      {a_sync, b_sync, c_sync, a_cold, b_cold, c_cold, chan_b} = $urandom;
      #(20);
    end
    use_config(k);
    #(100);
    rst_a = 1; rst_b = 1; rst_c = 1;
    g = 0;
    while (!(a_synced && b_synced && c_synced) && g < 6) begin at_cycle_start(); g++; end
    if (g >= 6) fail($sformatf("%s: no integration", what));
    at_cycle_start();
    sb_start();
  endtask

  // ---------------- BFM ----------------
  bit bfm_bits [0:4095];
  int bfm_nb;
  bit keep_bits [0:4095];
  int keep_nb;
  logic [7:0] lim0;
  int cb, cc, cl;
  // build a frame; faults: hc/fc flip a CRC bit, tss_x extra TSS bits,
  // bss_at (byte with a LOW first BSS bit, -1 none), fes1/fes2 inverted
  task automatic bfm_build(input logic [10:0] id, input int len, input logic [5:0] cyc,
                           input logic sy, input logic st, input logic nf,
                           input bit hc = 0, input bit fc = 0, input int tss_x = 0,
                           input int bss_at = -1, input bit fes1 = 0, input bit fes2 = 0);
    logic [39:0] h;
    logic [23:0] c;
    logic [7:0]  b;
    int          nbytes;
    bfm_len = len;
    h = {1'b0, 1'b0, nf, sy, st, id, 7'(len), hcrc(sy, st, id, 7'(len)) ^ {10'd0, hc}, cyc};
    nbytes = 5 + 2 * len + 3;
    bfm_nb = 0;
    for (int i = 0; i < int'(tss) + tss_x; i++) begin bfm_bits[bfm_nb] = 0; bfm_nb++; end
    bfm_bits[bfm_nb] = 1; bfm_nb++;                                   // FSS
    c = chan_b ? 24'hABCDEF : 24'hFEDCBA;
    for (int i = 0; i < nbytes; i++) begin
      if (i < 5) b = h[39 - 8 * i -: 8];
      else if (i < 5 + 2 * len) b = bfm_seed + 8'(i - 5);
      else begin
        if (i == 5 + 2 * len) c = c ^ {23'd0, fc};
        b = c[23 - 8 * (i - 5 - 2 * len) -: 8];
      end
      bfm_bits[bfm_nb] = (i == bss_at) ? 1'b0 : 1'b1; bfm_nb++;     // BSS
      bfm_bits[bfm_nb] = 0; bfm_nb++;
      for (int j = 7; j >= 0; j--) begin
        bfm_bits[bfm_nb] = b[j]; bfm_nb++;
        if (i < 5 + 2 * len) c = fcrc_bit(c, b[j]);
      end
    end
    bfm_bits[bfm_nb] = fes1; bfm_nb++;
    bfm_bits[bfm_nb] = !fes2; bfm_nb++;
  endtask
  // send the built frame at A's action point of slot sl, plus dly bit times
  task automatic bfm_send(input int sl, input real dly = 0);
    @(negedge clk_a);
    while (!(a_slot == sl && u_a.sc == 17'(int'(ap) * int'(8 * (spc + 1))))) @(negedge clk_a);
    @(posedge clk_a);                       // A's action point edge
    #(0.1 + dly * bt_ns());
    for (int i = 0; i < bfm_nb; i++) begin bfm = bfm_bits[i]; #(bt_ns()); end
    bfm = 1;
  endtask
  // a BFM frame in slot sl of the current cycle with the right ID and cycle
  task automatic bfm_frame(input int sl, input int len, input bit hc = 0, input bit fc = 0,
                           input int tss_x = 0, input int bss_at = -1, input bit fes1 = 0,
                           input bit fes2 = 0, input logic sy = 0, input real dly = 0,
                           input int id_x = 0, input int cyc_x = 0);
    @(negedge clk_a);
    while (a_slot != sl - 1) @(negedge clk_a);
    bfm_seed = $urandom;
    slot_of[3] = sl;
    bfm_build(11'(sl + id_x), len, a_cycle + 6'(cyc_x), sy, 0, 1, hc, fc, tss_x, bss_at, fes1, fes2);
    bfm_send(sl, dly);
  endtask

  // ---------------- scenarios ----------------
  initial begin
    for (int i = 0; i < 4; i++) begin nsent[i] = 0; end
    for (int i = 0; i < 3; i++) begin
      q_n[i] = 0; k_rx[i] = 0; k_null[i] = 0; k_tx[i] = 0; k_cod[i] = 0; k_hcrc[i] = 0;
      k_fcrc[i] = 0; k_slot[i] = 0; k_sync[i] = 0;
    end

    // 1. configuration 1: start-up, integration, traffic with drift
    $display("[%0t] section 1", $time);
    restart(1, "config 1");
    traffic(12, "config 1 traffic");

    // 2. BFM frames and faults in the free slots 3, 5, 6
    $display("[%0t] section 2", $time);
    snap(); bfm_frame(3, 8); at_cycle_start();
    expect_all(0, 0, 0, 0, 0, "BFM frame"); for (int n = 0; n < 3; n++) expect_rx(n, 1 + 2, "BFM frame");
    snap(); bfm_frame(3, 2, 1); at_cycle_start(); expect_all(0, 1, 0, 0, 0, "header CRC");
    snap(); bfm_frame(5, 2, 0, 1); at_cycle_start(); expect_all(0, 0, 1, 0, 0, "frame CRC");
    snap(); bfm_frame(3, 2, 0, 0, 0, 6); at_cycle_start(); expect_all(1, 0, 0, 0, 0, "BSS");
    snap(); bfm_frame(3, 2, 0, 0, 0, -1, 1); at_cycle_start(); expect_all(1, 0, 0, 0, 0, "FES1");
    snap(); bfm_frame(3, 2, 0, 0, 0, -1, 0, 1); at_cycle_start(); expect_all(1, 0, 0, 0, 0, "FES2");
    snap(); bfm_frame(3, 1, 0, 0, 2); at_cycle_start(); expect_all(1, 0, 0, 0, 0, "TSS too long");
    snap(); bfm_frame(3, 1, 0, 0, 1); at_cycle_start(); expect_all(0, 0, 0, 0, 0, "TSS one longer");
    for (int n = 0; n < 3; n++) expect_rx(n, 1 + 2, "TSS one longer");
    snap(); bfm_frame(3, 1, 0, 0, 0, -1, 0, 0, 0, 0, 2); at_cycle_start(); expect_all(0, 0, 0, 1, 0, "wrong ID");
    snap(); bfm_frame(3, 1, 0, 0, 0, -1, 0, 0, 0, 0, 0, 1); at_cycle_start(); expect_all(0, 0, 0, 1, 0, "wrong cycle");
    // glitches on the idle bus and between frames
    snap(); at_cycle_start(); #(940 * bt_ns()); bfm = 0; #(0.3 * bt_ns()); bfm = 1;
    #(20 * bt_ns()); bfm = 0; #(0.375 * bt_ns()); bfm = 1; at_cycle_start();   // 3 samples: through the vote, not to the strobe   // slot 3
    expect_all(0, 0, 0, 0, 0, "glitch");
    // a sync frame in slot 3 within the correction limit, then a late one
    snap(); bfm_frame(3, 0, 0, 0, 0, -1, 0, 0, 1, 2.0 / 8.0); at_cycle_start();
    expect_all(0, 0, 0, 0, 0, "sync frame in limit"); for (int n = 0; n < 3; n++) expect_rx(n, 1 + 2, "sync frame in limit");
    snap(); bfm_frame(3, 0, 0, 0, 0, -1, 0, 0, 1, 8.0); at_cycle_start();   // 64 clocks > 48
    expect_err(0, 0, 0, 0, 0, 0, "late sync frame"); expect_err(1, 0, 0, 0, 0, 1, "late sync frame");
    expect_err(2, 0, 0, 0, 0, 1, "late sync frame");
    cycles(2);
    if (!(b_synced && c_synced)) fail("no re-integration after a late sync frame");
    at_cycle_start(); sb_start();
    // long frames in the last slot, running into the NIT
    snap(); bfm_frame(6, 63); at_cycle_start(); bfm_frame(6, 64); at_cycle_start(); bfm_frame(6, 66); at_cycle_start();
    expect_all(0, 0, 0, 0, 0, "long frames"); for (int n = 0; n < 3; n++) expect_rx(n, 3 * 3, "long frames");
    // short payloads
    snap(); for (int l = 1; l < 8; l++) begin bfm_frame(3, l); at_cycle_start(); end
    expect_all(0, 0, 0, 0, 0, "short frames"); for (int n = 0; n < 3; n++) expect_rx(n, 7 * 3, "short frames");
    // channel idle takes 11 HIGH bits after a coding error: a frame 10 HIGH
    // bits after a broken one is not seen, one 11 bits after it is received
    for (int k = 0; k < 2; k++) begin
      snap();
      @(negedge clk_a); while (a_slot != 2) @(negedge clk_a);
      bfm_seed = $urandom; slot_of[3] = 3;
      bfm_build(11'd3, 0, a_cycle, 0, 0, 1);
      keep_nb = bfm_nb; for (int i = 0; i < keep_nb; i++) keep_bits[i] = bfm_bits[i];
      bfm_build(11'd3, 0, a_cycle, 0, 0, 1, 0, 0, 0, 2);          // LOW BSS in byte 2
      for (int i = 0; i < 9 + k; i++) begin bfm_bits[bfm_nb] = 1; bfm_nb++; end   // + FES2 HIGH
      for (int i = 0; i < keep_nb; i++) begin bfm_bits[bfm_nb] = keep_bits[i]; bfm_nb++; end
      bfm_send(3);
      at_cycle_start();
      expect_all(1, 0, 0, 0, 0, "channel idle after an error");
      for (int n = 0; n < 3; n++) expect_rx(n, 2 + k, "channel idle after an error");
    end
    // offset correction exactly at the limit (accepted), then one clock over
    // (sync lost): the limit is set to B's correction while B decides on
    // A's sync frame; C is checked against the limit it saw
    for (int k = 0; k < 2; k++) begin
      snap(); lim0 = corr; cb = -1; cc = -1;
      fork
        begin
          @(negedge clk_b); while (!(u_b.dst == 7 && u_b.strobe && u_b.slot_s == 1)) @(negedge clk_b);
          cb = int'(u_b.corr); corr = 8'(cb - k);
        end
        begin
          @(negedge clk_c); while (!(u_c.dst == 7 && u_c.strobe && u_c.slot_s == 1)) @(negedge clk_c);
          cc = int'(u_c.corr);
          @(posedge clk_c); cl = int'(corr);
        end
      join
      if (cb < 1 || cb > 255) fail($sformatf("correction limit test: B corrects %0d clocks", cb));
      #(bt_ns());
      corr = lim0;
      expect_err(0, 0, 0, 0, 0, 0, "correction at the limit");
      expect_err(1, 0, 0, 0, 0, k, "correction at the limit");
      expect_err(2, 0, 0, 0, 0, cc > cl ? 1 : 0, "correction at the limit");
      cycles(2);
      if (!(b_synced && c_synced)) fail("no re-integration after the correction limit test");
      at_cycle_start(); sb_start();
    end
    traffic(4, "after faults");

    // 3. loss of the time master: B loses sync at the end of the cycle; C
    //    either at a cycle end or earlier, when B's free-running frame needs a
    //    correction beyond the limit; frames while nobody is synced
    $display("[%0t] section 3", $time);
    snap();
    at_cycle_start(); rst_a = 0; sb_on = 0;
    while (b_synced) @(negedge clk_b);
    while (c_synced) @(negedge clk_c);
    #(bt_ns());                             // the hosts count the last pulses
    expect_err(1, 0, 0, 0, 0, 1, "master lost"); expect_err(2, 0, 0, 0, 0, 1, "master lost");
    #(20 * bt_ns());
    snap();
    bfm_seed = 8'h10; bfm_build(11'd3, 127, 6'd0, 0, 0, 1); #(0.1); for (int i = 0; i < bfm_nb; i++) begin bfm = bfm_bits[i]; #(bt_ns()); end
    bfm = 1; #(20 * bt_ns());
    bfm_build(11'd0, 1, 6'd0, 1, 0, 1); for (int i = 0; i < bfm_nb; i++) begin bfm = bfm_bits[i]; #(bt_ns()); end
    bfm = 1; #(20 * bt_ns());
    bfm_build(11'd7, 1, 6'd0, 1, 0, 1); for (int i = 0; i < bfm_nb; i++) begin bfm = bfm_bits[i]; #(bt_ns()); end
    bfm = 1; #(20 * bt_ns());
    expect_all(0, 0, 0, 0, 0, "unsynced frames"); for (int n = 0; n < 3; n++) expect_rx(n, 0, "unsynced frames");
    if (b_synced || c_synced) fail("integration on a frame that is not a valid sync frame");
    #(1400us);                              // silence: the edge counters saturate
    // a valid sync frame for slot 3 in cycle 63: B and C integrate and wrap to cycle 0
    snap();
    bfm_seed = 8'h20; bfm_build(11'd3, 1, 6'd63, 1, 0, 1); for (int i = 0; i < bfm_nb; i++) begin bfm = bfm_bits[i]; #(bt_ns()); end
    bfm = 1;
    #(bt_ns());
    if (!(b_synced && c_synced && b_cycle == 63 && c_cycle == 63)) fail("no integration on the BFM sync frame");
    while (!(b_synced && b_cycle == 0)) @(negedge clk_b);
    #(10 * bt_ns());
    expect_rx(1, 2, "integration at cycle 63"); expect_rx(2, 1, "integration at cycle 63");   // + the frame of C in slot 4
    rst_b = 0; rst_c = 0; #(100); rst_b = 1; rst_c = 1;
    rst_a = 1;
    cycles(3);
    if (!(b_synced && c_synced)) fail("no integration after the master restarted");
    at_cycle_start(); sb_start();
    traffic(3, "master back");

    // 4. reset of B in the middle of its frame
    $display("[%0t] section 4", $time);
    q_d[1] = {4{32'hB0B0_B0B0}}; q_n[1] = 1;
    snap();
    @(posedge b_en); #(60 * bt_ns()); rst_b = 0; #(2 * bt_ns()); rst_b = 1; sb_on = 0;
    at_cycle_start();
    expect_err(0, 1, 0, 0, 0, 0, "reset mid-frame"); expect_err(2, 1, 0, 0, 0, 0, "reset mid-frame");
    cycles(2);
    if (!b_synced) fail("B did not integrate after its reset");
    at_cycle_start(); sb_start();
    traffic(3, "after reset");

    // 5. configuration 2: long bit time, channel B, short NIT, C listens only
    $display("[%0t] section 5", $time);
    restart(2, "config 2");
    traffic(3, "config 2 traffic");
    // TSS limits at the longest TSS: 16 LOW bits are accepted, 17 are not
    snap(); bfm_frame(3, 2, 0, 0, 1); at_cycle_start(); expect_all(0, 0, 0, 0, 0, "C2 TSS one longer");
    expect_rx(0, 2, "C2 TSS one longer"); expect_rx(1, 2, "C2 TSS one longer"); expect_rx(2, 3, "C2 TSS one longer");
    snap(); bfm_frame(3, 2, 0, 0, 2); at_cycle_start(); expect_all(1, 0, 0, 0, 0, "C2 TSS too long");

    // 6. configuration 3: 57 slots, B is the time master, all sync nodes
    $display("[%0t] section 6", $time);
    restart(3, "config 3");
    traffic(3, "config 3 traffic");

    // 7. back to configuration 1
    $display("[%0t] section 7", $time);
    restart(1, "config 1 again");
    traffic(2, "config 1 again");

    for (int n = 0; n < 3; n++)
      $display("node %0d: rx %0d null %0d tx %0d cod %0d hcrc %0d fcrc %0d slot %0d sync %0d", n, k_rx[n],
               k_null[n], k_tx[n], k_cod[n], k_hcrc[n], k_fcrc[n], k_slot[n], k_sync[n]);
    if (errors == 0) $display("TEST PASSED: FlexRay");
    else $display("TEST FAILED: FlexRay (%0d errors)", errors);
    $finish;
  end

  initial begin
    #200ms;
    $display("TEST FAILED: FlexRay (timeout)");
    $finish;
  end
endmodule
