// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for LIN_top v2.0
//  * Commander M (10 ns clock, nominal bit time) and responder S (10.8 ns
//    clock, auto-baud) on one wired-AND bus, plus a bus driver (BFM) with
//    its own bit time for faulty or off-rate headers and responses.
//  * Each node has a host model: on pid_valid it looks up its role for the
//    ID (ignore / publish / subscribe, length, checksum model, data) and
//    answers through rsp_valid after a programmable delay.
//  * Every frame is checked per node: headers seen, frames received (ID,
//    length, data), responses sent and each error kind, as exact counts.
//  * Sections: all 64 IDs both ways, ignore and late decisions, timeouts,
//    checksum / framing / parity / sync errors, bit errors in header and
//    response, glitches, short dominant pulses, off-rate headers with
//    auto-baud, a break in the middle of a response, reset mid-frame.
// ============================================================================
`timescale 1ns/1ps
module LIN_tb;
  int  NB = 64;                            // nominal clocks per bit (both nodes' cfg_bit)
  real TB = 640.0;                         // M's bit time in ns

  logic clk_m = 0, clk_s = 0, rst_m = 0, rst_s = 0;
  always #5 clk_m = ~clk_m;
  always #5.4 clk_s = ~clk_s;              // S runs 8 % slow

  logic bfm = 1;
  wire  m_txd, s_txd;
  wire  bus = m_txd & s_txd & bfm;

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction

  // ---------------- the two nodes ----------------
  `define LIN_NODE(X, CLK, RST) \
  logic        X``_ab = 0, X``_stuck = 0; \
  logic        X``_hdr_valid = 0; \
  logic [5:0]  X``_hdr_id = 0; \
  wire         X``_hdr_ready, X``_pid_valid, X``_rsp_ready, X``_tx_done, X``_rx_valid; \
  wire  [5:0]  X``_pid_id, X``_rx_id; \
  logic        X``_rsp_valid = 0, X``_rsp_pub = 0, X``_rsp_enh = 0; \
  logic [2:0]  X``_rsp_len = 0; \
  logic [63:0] X``_rsp_data = 0; \
  wire  [2:0]  X``_rx_len; \
  wire  [63:0] X``_rx_data; \
  wire         X``_err_bit, X``_err_sync, X``_err_parity, X``_err_frame, X``_err_chk, X``_err_timeout; \
  wire  [15:0] X``_bit_time; \
  LIN_top u_``X ( \
    .clk(CLK), .rst_n(RST), .rxd(bus | X``_stuck), .txd(X``_txd), .cfg_bit(16'(NB)), .cfg_autobaud(X``_ab), \
    .hdr_valid(X``_hdr_valid), .hdr_ready(X``_hdr_ready), .hdr_id(X``_hdr_id), \
    .pid_valid(X``_pid_valid), .pid_id(X``_pid_id), .rsp_ready(X``_rsp_ready), \
    .rsp_valid(X``_rsp_valid), .rsp_pub(X``_rsp_pub), .rsp_len(X``_rsp_len), \
    .rsp_enh(X``_rsp_enh), .rsp_data(X``_rsp_data), .tx_done(X``_tx_done), \
    .rx_valid(X``_rx_valid), .rx_id(X``_rx_id), .rx_len(X``_rx_len), .rx_data(X``_rx_data), \
    .err_bit(X``_err_bit), .err_sync(X``_err_sync), .err_parity(X``_err_parity), \
    .err_frame(X``_err_frame), .err_chk(X``_err_chk), .err_timeout(X``_err_timeout), \
    .bit_time(X``_bit_time));

  `LIN_NODE(m, clk_m, rst_m)
  `LIN_NODE(s, clk_s, rst_s)

  // ---------------- protocol helpers ----------------
  function automatic logic [7:0] pid_of(input logic [5:0] id);
    return {~(id[1] ^ id[3] ^ id[4] ^ id[5]), id[0] ^ id[1] ^ id[2] ^ id[4], id};
  endfunction
  function automatic logic [7:0] csum(input logic [5:0] id, input logic enh, input logic [2:0] len,
                                      input logic [63:0] d);
    int s;
    s = (enh && id < 60) ? int'(pid_of(id)) : 0;
    for (int i = 0; i <= int'(len); i++) begin
      s = s + int'(d[8*i +: 8]);
      if (s > 255) s = s - 255;
    end
    return ~8'(s);
  endfunction
  function automatic logic [63:0] trim(input logic [2:0] len, input logic [63:0] d);
    for (int i = 0; i < 8; i++) if (i > int'(len)) d[8*i +: 8] = 8'h0;
    return d;
  endfunction

  // ---------------- event counters ----------------
  typedef struct packed {
    int pid, rx, tx, ebit, esync, epar, efrm, echk, eto;
  } cnt_t;
  cnt_t m_c, s_c;
  logic [5:0]  m_last_pid, s_last_pid;
  logic [5:0]  m_last_id, s_last_id;
  logic [2:0]  m_last_len, s_last_len;
  logic [63:0] m_last_data, s_last_data;
  `define LIN_COUNT(X, CLK) \
  always @(negedge CLK) begin \
    if (X``_pid_valid) begin X``_c.pid++; X``_last_pid = X``_pid_id; end \
    if (X``_rx_valid) begin X``_c.rx++; X``_last_id = X``_rx_id; X``_last_len = X``_rx_len; X``_last_data = X``_rx_data; end \
    if (X``_tx_done) X``_c.tx++; \
    if (X``_err_bit) X``_c.ebit++; \
    if (X``_err_sync) X``_c.esync++; \
    if (X``_err_parity) X``_c.epar++; \
    if (X``_err_frame) X``_c.efrm++; \
    if (X``_err_chk) X``_c.echk++; \
    if (X``_err_timeout) X``_c.eto++; \
  end
  `LIN_COUNT(m, clk_m)
  `LIN_COUNT(s, clk_s)

  function automatic string cs(input cnt_t c);
    return $sformatf("pid %0d rx %0d tx %0d bit %0d sync %0d par %0d frm %0d chk %0d to %0d",
                     c.pid, c.rx, c.tx, c.ebit, c.esync, c.epar, c.efrm, c.echk, c.eto);
  endfunction
  function automatic cnt_t diff(input cnt_t a, input cnt_t b);
    cnt_t d;
    d.pid = a.pid - b.pid; d.rx = a.rx - b.rx; d.tx = a.tx - b.tx; d.ebit = a.ebit - b.ebit;
    d.esync = a.esync - b.esync; d.epar = a.epar - b.epar; d.efrm = a.efrm - b.efrm;
    d.echk = a.echk - b.echk; d.eto = a.eto - b.eto;
    return d;
  endfunction
  // expected counts: E(pid, rx, tx, ebit, esync, epar, efrm, echk, eto)
  function automatic cnt_t E(input int pid, input int rx, input int tx, input int ebit,
                             input int esync, input int epar, input int efrm,
                             input int echk, input int eto);
    cnt_t c;
    c.pid = pid; c.rx = rx; c.tx = tx; c.ebit = ebit; c.esync = esync; c.epar = epar;
    c.efrm = efrm; c.echk = echk; c.eto = eto;
    return c;
  endfunction

  // ---------------- host models ----------------
  localparam int IGN = 0, PUB = 1, SUB = 2;
  typedef struct packed {
    int          role;
    int          dly;                       // clocks from pid_valid to rsp_valid
    logic [2:0]  len;
    logic        enh;
    logic [63:0] data;
  } plan_t;
  plan_t m_plan, s_plan;
  `define LIN_HOST(X, CLK) \
  always @(negedge CLK) if (X``_pid_valid && X``_plan.role != IGN) begin : X``_host \
    repeat (X``_plan.dly) @(negedge CLK); \
    X``_rsp_pub = X``_plan.role == PUB; X``_rsp_len = X``_plan.len; \
    X``_rsp_enh = X``_plan.enh; X``_rsp_data = X``_plan.data; X``_rsp_valid = 1; \
    @(negedge CLK); \
    X``_rsp_valid = 0; X``_rsp_data = {$urandom, $urandom}; \
  end
  `LIN_HOST(m, clk_m)
  `LIN_HOST(s, clk_s)

  // ---------------- BFM ----------------
  real bt_b = TB;                           // BFM bit time
  task automatic b_bits(input logic v, input real n);
    bfm = v; #(n * bt_b);
  endtask
  task automatic b_byte(input logic [7:0] b, input logic stop = 1);
    b_bits(0, 1);
    for (int i = 0; i < 8; i++) b_bits(b[i], 1);
    b_bits(stop, 1);
    bfm = 1;
  endtask
  // break of brk bits of the nominal bit time (both nodes must see >= 11 bits)
  task automatic b_header(input logic [7:0] pid, input logic [7:0] sync = 8'h55, input real brk = 13);
    bfm = 0; #(brk * TB);
    b_bits(1, 1);
    b_byte(sync);
    b_byte(pid);
  endtask
  task automatic b_resp(input logic [2:0] len, input logic [63:0] d, input logic [7:0] chk);
    for (int i = 0; i <= int'(len); i++) b_byte(d[8*i +: 8]);
    b_byte(chk);
  endtask

  // ---------------- frame control ----------------
  task automatic quiet(input int nbits);    // bus recessive for nbits of M's bit time
    int r;
    r = 0;
    while (r < nbits * NB) begin @(negedge clk_m); r = bus ? r + 1 : 0; end
  endtask
  // clocks each node has spent undecided in a response slot
  int m_und = 0, s_und = 0;
  always @(negedge clk_m) m_und = u_m.fst == 4 ? m_und + 1 : 0;
  always @(negedge clk_s) s_und = u_s.fst == 4 ? s_und + 1 : 0;
  task automatic settle;                     // both nodes done (or ignoring), bus quiet
    int g;
    g = 0;
    while (!((u_m.fst == 0 || m_und > 400) && (u_s.fst == 0 || s_und > 400) && u_m.tst == 0 && u_s.tst == 0)
           && g < 400 * NB) begin
      @(negedge clk_m); g++;
    end
    if (g >= 400 * NB) fail("nodes not idle");
    quiet(3);
  endtask
  task automatic header(input logic [5:0] id);
    @(negedge clk_m);
    m_hdr_id = id; m_hdr_valid = 1;
    @(posedge clk_m);
    while (!m_hdr_ready) @(posedge clk_m);
    @(negedge clk_m) m_hdr_valid = 0; m_hdr_id = $urandom;
  endtask

  cnt_t m0, s0;
  task automatic snap; m0 = m_c; s0 = s_c; endtask
  task automatic expect_cnt(input cnt_t em, input cnt_t es, input string what);
    cnt_t dm, ds;
    dm = diff(m_c, m0); ds = diff(s_c, s0);
    if (dm !== em) fail($sformatf("%s: M %s, expected %s", what, cs(dm), cs(em)));
    if (ds !== es) fail($sformatf("%s: S %s, expected %s", what, cs(ds), cs(es)));
  endtask
  task automatic expect_rx(input bit is_m, input logic [5:0] id, input logic [2:0] len,
                           input logic [63:0] d, input string what);
    logic [5:0] gi; logic [2:0] gl; logic [63:0] gd;
    gi = is_m ? m_last_id : s_last_id; gl = is_m ? m_last_len : s_last_len;
    gd = is_m ? m_last_data : s_last_data;
    if (gi !== id || gl !== len || gd !== trim(len, d))
      fail($sformatf("%s: %s got id %0d len %0d data %h, expected %0d %0d %h", what, is_m ? "M" : "S",
                     gi, gl, gd, id, len, trim(len, d)));
  endtask

  function automatic plan_t P(input int role, input int dly = 2, input logic [2:0] len = 0,
                              input logic enh = 0, input logic [63:0] data = 0);
    plan_t p;
    p.role = role; p.dly = dly; p.len = len; p.enh = enh; p.data = data;
    return p;
  endfunction

  // one commander-scheduled frame: M sends the header, roles from the plans
  task automatic frame(input logic [5:0] id, input plan_t pm, input plan_t ps, input string what);
    bit sub_m, sub_s, pub;
    m_plan = pm; s_plan = ps;
    snap();
    header(id);
    settle();
    pub = pm.role == PUB || ps.role == PUB;
    sub_m = pm.role == SUB && ps.role == PUB;
    sub_s = ps.role == SUB && pm.role == PUB;
    expect_cnt(E(1, sub_m, pm.role == PUB, 0, 0, 0, 0, 0, pm.role == SUB && !pub),
               E(1, sub_s, ps.role == PUB, 0, 0, 0, 0, 0, ps.role == SUB && !pub), what);
    if (m_last_pid !== id || s_last_pid !== id) fail($sformatf("%s: pid %0d/%0d, expected %0d", what, m_last_pid, s_last_pid, id));
    if (sub_m) expect_rx(1, id, ps.len, ps.data, what);
    if (sub_s) expect_rx(0, id, pm.len, pm.data, what);
  endtask

  // ---------------- scenarios ----------------
  initial begin
    plan_t pm, ps;
    logic [63:0] d;
    logic [2:0]  l;
    logic        en;
    m_plan = P(IGN); s_plan = P(IGN);
    m_ab = 0; s_ab = 1;
    repeat (4) @(negedge clk_m);
    rst_m = 1; rst_s = 1;
    quiet(4);

    // 1. every ID both ways, random lengths, checksum models and data
    $display("[%0t] section 1", $time);
    for (int i = 0; i < 128; i++) begin
      d = {$urandom, $urandom}; l = $urandom; en = $urandom;
      if (i < 4) begin d = i[0] ? 64'hFFFF_FFFF_FFFF_FFFF : 64'h0; l = 7; end
      if (i[0]) frame(i / 2, P(PUB, $urandom % 200, l, en, d), P(SUB, $urandom % 4, l, en), $sformatf("M->S id %0d", i / 2));
      else      frame(i / 2, P(SUB, $urandom % 4, l, en), P(PUB, $urandom % 200, l, en, d), $sformatf("S->M id %0d", i / 2));
    end

    // 2. nobody answers; one publisher and nobody listening; late subscriber
    $display("[%0t] section 2", $time);
    frame(6'h11, P(IGN), P(IGN), "nobody");
    #(126 * TB);                                     // no role taken: the slot is given up
    if (u_m.fst != 0 || u_s.fst != 0 || !m_hdr_ready || m_rsp_ready || s_rsp_ready) fail("undecided frame not dropped");
    frame(6'h12, P(PUB, 5, 3, 1, 64'h1234), P(IGN), "unheard publisher");
    frame(6'h13, P(IGN), P(PUB, 5, 3, 1, 64'h5678), "unheard responder");
    m_plan = P(PUB, 1, 1, 0, 64'hABCD); s_plan = P(SUB, 120, 1, 0);   // decides after the start bit
    snap(); header(6'h14); settle();
    expect_cnt(E(1, 0, 1, 0, 0, 0, 0, 0, 0), E(1, 0, 0, 0, 0, 0, 0, 0, 0), "late subscriber");

    // 3. subscriber timeouts: no publisher, a short response, a slow one
    $display("[%0t] section 3", $time);
    frame(6'h15, P(SUB, 1, 2, 1), P(IGN), "M times out");
    frame(6'h16, P(IGN), P(SUB, 1, 7, 1), "S times out");
    m_plan = P(SUB, 1, 3, 1); s_plan = P(SUB, 1, 3, 1);
    snap(); header(6'h17);
    @(posedge m_rsp_ready); @(negedge m_rsp_ready); #(2 * TB);
    b_byte(8'h01); b_byte(8'h02);                    // 2 of 4 bytes
    settle();
    expect_cnt(E(1, 0, 0, 0, 0, 0, 0, 0, 1), E(1, 0, 0, 0, 0, 0, 0, 0, 1), "short response");
    snap(); header(6'h18);
    @(negedge m_rsp_ready); #(2 * TB);
    for (int i = 0; i < 4; i++) begin b_byte(8'h10 + i); #(3 * TB); end   // gaps: too slow
    settle();
    expect_cnt(E(1, 0, 0, 0, 0, 0, 0, 0, 1), E(1, 0, 0, 0, 0, 0, 0, 0, 1), "slow response");

    // 4. response errors from the BFM: checksum, checksum model, framing, glitch
    $display("[%0t] section 4", $time);
    m_plan = P(SUB, 1, 2, 1); s_plan = P(SUB, 1, 2, 1);
    snap(); header(6'h21); @(negedge m_rsp_ready); #(TB);
    b_resp(2, 64'h030201, csum(6'h21, 1, 2, 64'h030201) ^ 8'h01);
    settle();
    expect_cnt(E(1, 0, 0, 0, 0, 0, 0, 1, 0), E(1, 0, 0, 0, 0, 0, 0, 1, 0), "bad checksum");
    snap(); header(6'h25); @(negedge m_rsp_ready); #(TB);
    b_resp(2, 64'h332211, ~csum(6'h25, 1, 2, 64'h332211));       // sum not inverted
    settle();
    expect_cnt(E(1, 0, 0, 0, 0, 0, 0, 1, 0), E(1, 0, 0, 0, 0, 0, 0, 1, 0), "checksum not inverted");
    m_plan = P(SUB, 1, 2, 0); s_plan = P(SUB, 1, 2, 1);           // M expects classic
    snap(); header(6'h22); @(negedge m_rsp_ready); #(TB);
    b_resp(2, 64'h0A0B0C, csum(6'h22, 1, 2, 64'h0A0B0C));
    settle();
    expect_cnt(E(1, 0, 0, 0, 0, 0, 0, 1, 0), E(1, 1, 0, 0, 0, 0, 0, 0, 0), "enhanced vs classic");
    expect_rx(0, 6'h22, 2, 64'h0A0B0C, "enhanced");
    m_plan = P(SUB, 1, 1, 1); s_plan = P(SUB, 1, 1, 1);           // ID 60: classic always
    snap(); header(6'd60); @(negedge m_rsp_ready); #(TB);
    b_resp(1, 64'h3C3C, csum(6'd60, 0, 1, 64'h3C3C));
    settle();
    expect_cnt(E(1, 1, 0, 0, 0, 0, 0, 0, 0), E(1, 1, 0, 0, 0, 0, 0, 0, 0), "diagnostic classic");
    snap(); header(6'h23); @(negedge m_rsp_ready); #(TB);
    b_byte(8'h55); b_byte(8'hAA, 0);                               // stop bit dominant
    settle();
    expect_cnt(E(1, 0, 0, 0, 0, 0, 1, 0, 0), E(1, 0, 0, 0, 0, 0, 1, 0, 0), "response framing");
    m_plan = P(SUB, 1, 0, 1); s_plan = P(SUB, 1, 0, 1);
    snap(); header(6'h24); @(negedge m_rsp_ready); #(TB);
    b_bits(0, 0.25); b_bits(1, 1);                                 // start-bit glitch
    b_resp(0, 64'h99, csum(6'h24, 1, 0, 64'h99));
    settle();
    expect_cnt(E(1, 1, 0, 0, 0, 0, 0, 0, 0), E(1, 1, 0, 0, 0, 0, 0, 0, 0), "glitch");

    // 5. bit errors: in the delimiter, in the sync byte, in a response
    $display("[%0t] section 5", $time);
    m_plan = P(IGN); s_plan = P(IGN);
    snap(); fork header(6'h30); begin #(13.3 * TB); b_bits(0, 0.6); bfm = 1; end join
    settle();
    expect_cnt(E(0, 0, 0, 1, 1, 0, 0, 0, 0), E(0, 0, 0, 0, 1, 0, 0, 0, 0), "delimiter bit error");
    snap(); fork header(6'h31); begin #(15.2 * TB); b_bits(0, 1); bfm = 1; end join
    settle();
    expect_cnt(E(0, 0, 0, 1, 1, 0, 0, 0, 0), E(0, 0, 0, 0, 1, 0, 0, 0, 0), "sync bit error");
    // M's stop bit of the first data byte forced dominant
    m_plan = P(PUB, 1, 1, 1, 64'hF0F0); s_plan = P(SUB, 1, 1, 1);
    snap(); fork header(6'h33); begin @(negedge m_rsp_ready); @(negedge m_txd); #(9.2 * TB); b_bits(0, 0.6); bfm = 1; end join
    settle();
    expect_cnt(E(1, 0, 0, 1, 0, 0, 0, 0, 0), E(1, 0, 0, 0, 0, 0, 1, 0, 0), "response bit error");

    // M's receive path stuck recessive (transceiver fault): its break reads back wrong
    snap(); m_stuck = 1; header(6'h34); settle(); m_stuck = 0;
    expect_cnt(E(0, 0, 0, 1, 0, 0, 0, 0, 0), E(0, 0, 0, 0, 0, 0, 0, 0, 0), "break bit error");

    // 6. header errors from the BFM: sync value and timing, parity, PID framing
    $display("[%0t] section 6", $time);
    m_ab = 1;
    m_plan = P(IGN); s_plan = P(IGN);
    snap(); b_header(pid_of(6'h01), 8'h54); settle();
    expect_cnt(E(0, 0, 0, 0, 1, 0, 0, 0, 0), E(0, 0, 0, 0, 1, 0, 0, 0, 0), "sync 0x54");
    bt_b = 0.7 * TB; snap(); b_header(pid_of(6'h02)); bt_b = TB; settle();
    expect_cnt(E(0, 0, 0, 0, 1, 0, 0, 0, 0), E(0, 0, 0, 0, 1, 0, 0, 0, 0), "sync too fast");
    bt_b = 1.45 * TB; snap(); b_header(pid_of(6'h03)); bt_b = TB; settle();
    expect_cnt(E(0, 0, 0, 0, 1, 0, 0, 0, 0), E(0, 0, 0, 0, 1, 0, 0, 0, 0), "sync too slow");
    snap(); b_bits(0, 13); b_bits(1, 1);                           // bit 7 back high early
    b_bits(0, 1); for (int i = 0; i < 7; i++) b_bits(~i[0], 1); b_bits(0, 0.2); b_bits(1, 1.8);
    settle();
    expect_cnt(E(0, 0, 0, 0, 1, 0, 0, 0, 0), E(0, 0, 0, 0, 1, 0, 0, 0, 0), "sync bit 7");
    snap(); b_bits(0, 13); b_bits(1, 1); b_byte(8'h55, 0); settle();
    expect_cnt(E(0, 0, 0, 0, 1, 0, 0, 0, 0), E(0, 0, 0, 0, 1, 0, 0, 0, 0), "sync stop bit");
    snap(); b_header(pid_of(6'h05) ^ 8'h80); settle();
    expect_cnt(E(0, 0, 0, 0, 0, 1, 0, 0, 0), E(0, 0, 0, 0, 0, 1, 0, 0, 0), "parity P1");
    snap(); b_header(pid_of(6'h06) ^ 8'h40); settle();
    expect_cnt(E(0, 0, 0, 0, 0, 1, 0, 0, 0), E(0, 0, 0, 0, 0, 1, 0, 0, 0), "parity P0");
    snap(); b_bits(0, 13); b_bits(1, 1); b_byte(8'h55); b_byte(pid_of(6'h07), 0); settle();
    expect_cnt(E(0, 0, 0, 0, 0, 0, 1, 0, 0), E(0, 0, 0, 0, 0, 0, 1, 0, 0), "PID framing");
    // no PID: a glitch is ignored, the next break ends the PID byte with a
    // framing error and its header goes through
    snap(); b_bits(0, 13); b_bits(1, 1); b_byte(8'h55); quiet(4);
    b_bits(0, 0.2); bfm = 1; quiet(4);
    b_header(pid_of(6'h09)); settle();
    expect_cnt(E(1, 0, 0, 0, 0, 0, 1, 0, 0), E(1, 0, 0, 0, 0, 0, 1, 0, 0), "PID missing");

    // 7. off-rate headers and responses (auto-baud), short dominant pulse
    $display("[%0t] section 7", $time);
    for (int k = 0; k < 4; k++) begin
      bt_b = (k == 0 ? 0.85 : k == 1 ? 1.2 : k == 2 ? 0.84 : 1.22) * TB;   // both nodes' windows
      d = {$urandom, $urandom}; l = $urandom;
      m_plan = P(SUB, 1, l, 1); s_plan = P(SUB, 1, l, 1);
      snap(); b_header(pid_of(6'h08 + k)); #(bt_b); b_resp(l, d, csum(6'h08 + k, 1, l, d)); bt_b = TB;
      settle();
      expect_cnt(E(1, 1, 0, 0, 0, 0, 0, 0, 0), E(1, 1, 0, 0, 0, 0, 0, 0, 0), $sformatf("auto-baud %0d", k));
      expect_rx(1, 6'h08 + k, l, d, "auto-baud"); expect_rx(0, 6'h08 + k, l, d, "auto-baud");
    end
    // an 11.5-bit break right after a slow sync: M's PID receiver (1.22x bit
    // time) is still busy when the break is detected and must be dropped; S
    // does not see a break (10.6 of its bits) and reads 0x00: parity error
    m_plan = P(IGN); s_plan = P(IGN);
    bt_b = 1.22 * TB; snap(); b_bits(0, 13); b_bits(1, 1); b_byte(8'h55); bt_b = TB;
    b_bits(0, 11.5); b_bits(1, 1); b_byte(8'h55); b_byte(pid_of(6'h0F)); settle();
    expect_cnt(E(1, 0, 0, 0, 0, 0, 0, 0, 0), E(0, 0, 0, 0, 0, 1, 0, 0, 0), "short break after slow sync");
    m_ab = 0;
    snap(); b_bits(0, 10.6); bfm = 1; quiet(4);
    expect_cnt(E(0, 0, 0, 0, 0, 0, 0, 0, 0), E(0, 0, 0, 0, 0, 0, 0, 0, 0), "short dominant");
    snap(); b_bits(0, 0.3); bfm = 1; quiet(4);
    expect_cnt(E(0, 0, 0, 0, 0, 0, 0, 0, 0), E(0, 0, 0, 0, 0, 0, 0, 0, 0), "glitch in idle");

    // 8. a new break in the middle of a response
    $display("[%0t] section 8", $time);
    m_plan = P(SUB, 1, 7, 1); s_plan = P(PUB, 1, 7, 1, 64'h0102_0304_0506_0708);
    snap(); fork header(6'h3A); begin @(negedge m_rsp_ready); #(25 * TB); m_plan = P(IGN); s_plan = P(IGN); b_header(pid_of(6'h3B)); end join
    settle();
    expect_cnt(E(2, 0, 0, 0, 0, 0, 1, 0, 0), E(2, 0, 0, 1, 0, 0, 0, 0, 0), "break mid-response");

    // 9. M's own response read by S at M's nominal rate, with M auto-baud
    $display("[%0t] section 9", $time);
    m_ab = 1;
    for (int i = 0; i < 6; i++) begin
      d = {$urandom, $urandom}; l = $urandom;
      frame($urandom, P(PUB, $urandom % 100, l, 1, d), P(SUB, 0, l, 1), "M auto-baud");
    end
    m_ab = 0;

    // 10. reset in the middle of frames
    $display("[%0t] section 10", $time);
    m_plan = P(PUB, 1, 7, 1, 64'h1111_2222_3333_4444); s_plan = P(SUB, 1, 7, 1);
    header(6'h20); @(negedge m_rsp_ready); #(30 * TB);
    rst_s = 0; #(3 * TB); rst_s = 1;
    settle();
    header(6'h21); #(20 * TB);
    rst_m = 0; rst_s = 0; #(100); rst_m = 1; rst_s = 1;
    m_plan = P(IGN); s_plan = P(IGN);
    quiet(16);
    frame(6'h22, P(PUB, 3, 2, 1, 64'hABCDEF), P(SUB, 1, 2, 1), "after reset");

    // 11. bit-time range: the shortest bit time, then the longest
    $display("[%0t] section 11", $time);
    NB = 16; TB = 160.0; bt_b = TB; quiet(8);
    for (int i = 0; i < 8; i++) begin
      d = {$urandom, $urandom}; l = i;
      if (i[0]) frame(6'h30 + i, P(PUB, 2, l, 1, d), P(SUB, 0, l, 1), "16-clock bit M->S");
      else      frame(6'h30 + i, P(SUB, 0, l, 1), P(PUB, 2, l, 1, d), "16-clock bit S->M");
    end
    NB = 65535; TB = 655350.0; bt_b = TB; quiet(2);
    frame(6'h2A, P(PUB, 2, 0, 1, 64'hA5), P(SUB, 0, 0, 1), "65535-clock bit");
    // delimiter longer than 14 bits
    snap(); b_bits(0, 13); b_bits(1, 15); settle();
    expect_cnt(E(0, 0, 0, 0, 1, 0, 0, 0, 0), E(0, 0, 0, 0, 1, 0, 0, 0, 0), "delimiter too long");
    // a header 1 % slow: M's auto-baud measurement saturates at 65535
    m_ab = 1; m_plan = P(SUB, 0, 0, 1); s_plan = P(SUB, 0, 0, 1);
    bt_b = 1.01 * TB; snap(); b_header(pid_of(6'h2B)); #(bt_b); b_resp(0, 64'h5A, csum(6'h2B, 1, 0, 64'h5A));
    bt_b = TB; settle();
    expect_cnt(E(1, 1, 0, 0, 0, 0, 0, 0, 0), E(1, 1, 0, 0, 0, 0, 0, 0, 0), "saturated auto-baud");
    if (m_bit_time !== 16'hFFFF) fail($sformatf("M bit time %0d, expected 65535", m_bit_time));
    m_ab = 0;
    // the sync and break limits are combinational from cfg_bit: sweep it while idle
    for (int i = 0; i < 64; i++) begin NB = 16 + $urandom % 65520; #(100); end
    NB = 64; TB = 640.0; bt_b = TB; quiet(4);
    frame(6'h2C, P(SUB, 0, 1, 1), P(PUB, 2, 1, 1, 64'h1234), "back to 64");
    // data patterns both ways
    frame(6'h10, P(PUB, 2, 7, 0, 64'h0), P(SUB, 2, 7, 0), "M->S zero");
    frame(6'h11, P(PUB, 2, 7, 1, {16{4'hA}}), P(SUB, 2, 7, 1), "M->S alt");
    frame(6'h12, P(SUB, 2, 7, 0), P(PUB, 2, 7, 0, {64{1'b1}}), "S->M ones");
    frame(6'h13, P(SUB, 2, 7, 1), P(PUB, 2, 7, 1, {16{4'h5}}), "S->M alt");

    $display("M %s", cs(m_c));
    $display("S %s", cs(s_c));
    if (errors == 0) $display("TEST PASSED: LIN");
    else $display("TEST FAILED: LIN (%0d errors)", errors);
    $finish;
  end

  initial begin
    #600ms;
    $display("TEST FAILED: LIN (timeout)");
    $finish;
  end
endmodule
