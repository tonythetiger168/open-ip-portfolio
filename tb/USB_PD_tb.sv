// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for USB_PD_top -- USB-PD sink (UFP) controller.
// The TB plays the source (DFP): it drives BMC frames onto the CC wire and
// a monitor decodes every frame the sink sends (preamble, SOP, header,
// Request object, CRC-32, EOP all checked).
// Covered: negotiation picking the 9 V PDO, the 5 V fallback (one object,
// or a second object that is not 9 V), renegotiation from the contract,
// Reject, the MessageIDCounter advancing and wrapping, GoodCRC with the
// wrong id, GoodCRC timeout with retries and give-up, bad CRC / bad EOP /
// too many objects (no GoodCRC, irq until the next good message), other
// message types answered with GoodCRC, source GoodCRCs not answered,
// SOP with a single Sync-1, noise, HardReset (and an incomplete one) in
// every policy state, reset mid-negotiation.
`timescale 1ns/1ps
module USB_PD_tb;
  logic clk = 0, rst_n = 0;
  logic cc_rxd;                 // CC wire level into the DUT
  logic cc_txd, cc_tx_en;       // DUT BMC drive
  logic vbus_ok, irq;
  logic src_drv = 1'b0;         // source-side line driver
  logic line    = 1'b0;         // BMC encoder state (TB side)

  int errors = 0;

  // CC wire: sink owns it while transmitting, source otherwise
  assign cc_rxd = cc_tx_en ? cc_txd : src_drv;

  USB_PD_top dut (
    .clk(clk), .rst_n(rst_n),
    .cc_rxd(cc_rxd), .cc_txd(cc_txd), .cc_tx_en(cc_tx_en),
    .vbus_ok(vbus_ok), .irq(irq)
  );

  always #5 clk = ~clk;

  task automatic check(input logic cond, input string msg);
    if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
  endtask

  localparam logic [4:0] K_SYNC1 = 5'b11000;
  localparam logic [4:0] K_SYNC2 = 5'b10001;
  localparam logic [4:0] K_RST1  = 5'b00111;
  localparam logic [4:0] K_RST2  = 5'b11001;
  localparam logic [4:0] K_EOP   = 5'b01101;

  localparam logic [4:0] MT_GOODCRC = 5'h01;
  localparam logic [4:0] MT_ACCEPT  = 5'h03;
  localparam logic [4:0] MT_REJECT  = 5'h04;
  localparam logic [4:0] MT_PING    = 5'h05;
  localparam logic [4:0] MT_PSRDY   = 5'h06;
  localparam logic [4:0] MT_SRCCAP  = 5'h01;
  localparam logic [4:0] MT_REQUEST = 5'h02;

  function automatic logic [31:0] crc32_bit(input logic [31:0] c, input logic b);
    return (c >> 1) ^ ((c[0] ^ b) ? 32'hEDB8_8320 : 32'h0);
  endfunction

  // fixed-supply PDO: [19:10] = V / 50 mV, [9:0] = I / 10 mA, rest random
  function automatic logic [31:0] pdo(input int mv, input logic [9:0] cur);
    logic [31:0] r;
    r = $urandom;
    return {r[31:20], 10'(mv / 50), cur};
  endfunction

  // source header: powerrole / datarole / ext / specrev random
  function automatic logic [15:0] mk_hdr(input logic [4:0] mtype,
                                         input logic [2:0] msgid,
                                         input logic [2:0] nobj);
    logic [15:0] r;
    r = $urandom;
    return {r[15], nobj, msgid, r[8:5], mtype};
  endfunction

  // ------------------------------------------------------------------
  // source side BMC (drive on negedge)
  // ------------------------------------------------------------------
  task automatic bmc_bit(input logic b);
    if (b) line = ~line;
    src_drv = line;
    @(negedge clk);
  endtask

  task automatic send_sym(input logic [4:0] s);
    for (int i = 4; i >= 0; i--) bmc_bit(s[i]);
  endtask

  task automatic send_hrst(input int n_rst1);
    for (int i = 0; i < n_rst1; i++) send_sym(K_RST1);
    send_sym(K_RST2);
    repeat (4) @(negedge clk);
  endtask

  // full message; bad: 0 good, 1 CRC, 2 EOP
  task automatic send_msg(input logic [15:0] hdr, input logic [31:0] o0, o1,
                          input int bad, input int n_sync1 = 3);
    logic [31:0] crc;
    int nobj, k;
    crc  = 32'hFFFF_FFFF;
    nobj = hdr[14:12];
    for (int i = 0; i < 16; i++) bmc_bit(i[0]);
    for (int i = 0; i < n_sync1; i++) send_sym(K_SYNC1);
    send_sym(K_SYNC2);
    for (int i = 0; i < 16; i++) begin bmc_bit(hdr[i]); crc = crc32_bit(crc, hdr[i]); end
    if (nobj <= 2) begin
      for (int i = 0; i < 32 * nobj; i++) begin
        bmc_bit(i < 32 ? o0[i % 32] : o1[i % 32]);
        crc = crc32_bit(crc, i < 32 ? o0[i % 32] : o1[i % 32]);
      end
      crc = ~crc;
      if (bad == 1) begin k = $urandom % 32; crc[k] = !crc[k]; end
      for (int i = 0; i < 32; i++) bmc_bit(crc[i]);
      send_sym(bad == 2 ? K_SYNC1 : K_EOP);
    end
    repeat (2) @(negedge clk);
  endtask

  task automatic noise(input int n);
    for (int i = 0; i < n; i++) bmc_bit($urandom);
  endtask

  // ------------------------------------------------------------------
  // monitor: decode every sink frame
  // ------------------------------------------------------------------
  logic [15:0] mon_hdr [0:255];
  logic [31:0] mon_obj [0:255];
  int          mon_cnt = 0, mon_rd = 0;
  logic        mbits [0:199];
  int          mn = -1;
  logic        mref;

  always @(negedge clk) begin
    logic [31:0] crc, o;
    logic [15:0] h;
    logic [4:0]  k;
    int p, nobj;
    if (!rst_n) mn = -1;
    else if (cc_tx_en) begin
      if (mn < 0) begin mn = 0; check(cc_txd == 1'b1, "frame starts high"); end
      else if (mn < 200) begin mbits[mn] = cc_txd ^ mref; mn++; end
      mref = cc_txd;
    end else if (mn >= 0) begin
      p = 0;
      for (int i = 0; i < 16; i++) check(mbits[i] == i[0], "preamble");
      for (int s = 0; s < 4; s++) begin
        for (int i = 0; i < 5; i++) k[4 - i] = mbits[16 + 5 * s + i];
        check(k == (s == 3 ? K_SYNC2 : K_SYNC1), "SOP");
      end
      crc = 32'hFFFF_FFFF;
      for (int i = 0; i < 16; i++) begin h[i] = mbits[36 + i]; crc = crc32_bit(crc, h[i]); end
      nobj = h[14:12];
      o = 0;
      for (int i = 0; i < 32 * nobj; i++) begin o[i % 32] = mbits[52 + i]; crc = crc32_bit(crc, o[i % 32]); end
      p = 52 + 32 * nobj;
      for (int i = 0; i < 32; i++) crc = crc32_bit(crc, mbits[p + i]);
      check(crc == 32'hDEBB_20E3, "frame CRC");
      for (int i = 0; i < 5; i++) k[4 - i] = mbits[p + 32 + i];
      check(k == K_EOP, "EOP");
      check(mn == p + 37, "frame length");
      mon_hdr[mon_cnt[7:0]] = h;
      mon_obj[mon_cnt[7:0]] = o;
      mon_cnt++;
      mn = -1;
    end
  end

  task automatic wait_frame(input string tag);
    int to;
    to = 0;
    while (mon_cnt == mon_rd && to < 400) begin @(negedge clk); to++; end
    check(mon_cnt > mon_rd, {tag, ": sink frame"});
  endtask

  task automatic expect_gc(input logic [2:0] id, input string tag);
    logic [15:0] h;
    wait_frame(tag);
    h = mon_hdr[mon_rd[7:0]]; mon_rd++;
    check(h == {1'b0, 3'd0, id, 1'b0, 2'b10, 1'b0, MT_GOODCRC}, {tag, ": GoodCRC header"});
  endtask

  task automatic expect_req(input logic [2:0] id, input logic [2:0] pos,
                            input logic [9:0] cur, input string tag);
    logic [15:0] h;
    logic [31:0] o;
    wait_frame(tag);
    h = mon_hdr[mon_rd[7:0]]; o = mon_obj[mon_rd[7:0]]; mon_rd++;
    check(h == {1'b0, 3'd1, id, 1'b0, 2'b10, 1'b0, MT_REQUEST}, {tag, ": Request header"});
    check(o == {1'b0, pos, 8'h00, cur, cur}, {tag, ": Request object"});
  endtask

  task automatic no_frame(input int n, input string tag);
    repeat (n) @(negedge clk);
    check(mon_cnt == mon_rd, {tag, ": no sink frame"});
  endtask

  // ------------------------------------------------------------------
  // negotiation helpers
  // ------------------------------------------------------------------
  logic [2:0] sid = 0;          // source MessageID
  logic [2:0] kid = 0;          // expected sink MessageID

  // send Source_Capabilities; expect GoodCRC + Request
  task automatic caps(input int nobj, input int mv2, input logic [9:0] c0, c1,
                      input string tag);
    send_msg(mk_hdr(MT_SRCCAP, sid, 3'(nobj)), pdo(5000, c0), pdo(mv2, c1), 0);
    expect_gc(sid, tag); sid++;
    if (nobj == 2 && mv2 == 9000) expect_req(kid, 3'd2, c1, tag);
    else                          expect_req(kid, 3'd1, c0, tag);
  endtask

  task automatic ctrl_msg(input logic [4:0] mt, input string tag);
    send_msg(mk_hdr(mt, sid, 3'd0), 0, 0, 0);
    expect_gc(sid, tag); sid++;
  endtask

  task automatic src_goodcrc(input logic [2:0] id);
    send_msg(mk_hdr(MT_GOODCRC, id, 3'd0), 0, 0, 0);
  endtask

  task automatic negotiate(input int nobj, input int mv2, input string tag);
    caps(nobj, mv2, 10'($urandom), 10'($urandom), tag);
    src_goodcrc(kid); kid++;
    ctrl_msg(MT_ACCEPT, tag);
    check(!vbus_ok, {tag, ": no contract before PS_RDY"});
    ctrl_msg(MT_PSRDY, tag);
    repeat (2) @(negedge clk);
    check(vbus_ok && !irq, {tag, ": contract"});
  endtask

  task automatic do_reset;
    rst_n = 0;
    repeat (3) @(negedge clk);
    check(!cc_tx_en && cc_txd && !vbus_ok && !irq, "reset outputs");
    rst_n = 1;
    mon_rd = mon_cnt; kid = 0;
    repeat (3) @(negedge clk);
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  initial begin
    do_reset;

    // ---- basic negotiations ----
    negotiate(2, 9000, "9V");
    caps(1, 0, 10'h096, 0, "renegotiate 5V only");     // from the contract
    check(!vbus_ok, "contract dropped by new caps");
    src_goodcrc(kid); kid++;
    ctrl_msg(MT_ACCEPT, "5V accept");
    ctrl_msg(MT_PSRDY, "5V ps_rdy");
    check(vbus_ok, "5V contract");
    negotiate(2, 15000, "second PDO not 9V");
    negotiate(2, 9000, "9V again");

    // ---- other messages in the contract ----
    ctrl_msg(MT_PING, "ping");
    ctrl_msg(MT_ACCEPT, "stray accept");
    src_goodcrc(3'd5);                                   // not answered
    no_frame(150, "source GoodCRC");
    send_msg(mk_hdr(5'h1F, sid, 3'd2), $urandom, $urandom, 0);   // other data
    expect_gc(sid, "other data message"); sid++;
    check(vbus_ok && !irq, "contract kept");

    // ---- Reject ----
    caps(2, 9000, 10'h3FF, 10'h3FF, "caps for reject");
    src_goodcrc(kid); kid++;
    ctrl_msg(MT_REJECT, "reject");
    check(!vbus_ok, "no contract after reject");
    ctrl_msg(MT_PSRDY, "ps_rdy ignored");
    check(!vbus_ok, "ps_rdy without request ignored");
    negotiate(2, 9000, "after reject");

    // ---- GoodCRC with the wrong id, then the right one ----
    caps(2, 9000, 10'h155, 10'h2AA, "wrong id");
    src_goodcrc(kid + 3'd3);
    repeat (5) @(negedge clk);
    check(irq, "wrong GoodCRC id irq");
    src_goodcrc(kid); kid++;
    ctrl_msg(MT_ACCEPT, "after wrong id");
    check(!irq, "irq cleared by good message");
    ctrl_msg(MT_PSRDY, "after wrong id");
    check(vbus_ok, "contract after wrong id");

    // ---- GoodCRC timeout: two retries with the same id, then give up ----
    caps(1, 0, 10'h0F0, 0, "timeout");
    expect_req(kid, 3'd1, 10'h0F0, "retry 1");
    expect_req(kid, 3'd1, 10'h0F0, "retry 2");
    no_frame(260, "no third retry");
    check(irq && !vbus_ok, "give-up irq");
    // a retry acknowledged
    caps(1, 0, 10'h00F, 0, "timeout then ack");
    check(!irq, "irq cleared by caps");
    expect_req(kid, 3'd1, 10'h00F, "retry acked");
    src_goodcrc(kid); kid++;
    ctrl_msg(MT_ACCEPT, "retry acked");
    ctrl_msg(MT_PSRDY, "retry acked");
    check(vbus_ok, "contract after retry");

    // ---- broken frames: no GoodCRC, irq until the next good message ----
    send_msg(mk_hdr(MT_PING, sid, 3'd0), 0, 0, 1);
    no_frame(40, "bad CRC");
    check(irq, "bad CRC irq");
    ctrl_msg(MT_PING, "clears irq");
    check(!irq, "irq cleared");
    send_msg(mk_hdr(MT_PING, sid, 3'd0), 0, 0, 2);
    no_frame(40, "bad EOP");
    check(irq, "bad EOP irq");
    ctrl_msg(MT_PING, "clears irq 2");
    for (int n = 3; n < 8; n++) begin
      send_msg(mk_hdr(MT_SRCCAP, sid, 3'(n)), 0, 0, 0);
      noise(40);
      no_frame(40, "too many objects");
      check(irq, "too many objects irq");
    end
    ctrl_msg(MT_PING, "clears irq 3");

    // ---- framing variants ----
    send_msg(mk_hdr(MT_PING, sid, 3'd0), 0, 0, 0, 1);    // single Sync-1
    expect_gc(sid, "single sync1"); sid++;
    send_msg(mk_hdr(MT_PING, sid, 3'd0), 0, 0, 0, 5);    // extra Sync-1
    expect_gc(sid, "five sync1"); sid++;
    noise(100);
    send_sym(K_SYNC2); send_sym(K_RST2); send_sym(K_RST1); send_sym(K_SYNC1);
    send_msg(mk_hdr(MT_PING, sid, 3'd0), 0, 0, 0);
    expect_gc(sid, "after noise"); sid++;
    check(vbus_ok, "contract survives noise");

    // ---- HardReset in every policy state ----
    send_hrst(3);
    repeat (3) @(negedge clk);
    check(!vbus_ok && !irq, "hard reset from contract");
    kid = 0;
    send_hrst(1);                                        // in WAIT_CAPS
    caps(2, 9000, 10'h1C3, 10'h23C, "hrst in wait_gcrc");
    send_hrst(3);
    no_frame(300, "no retry after hard reset");
    caps(2, 9000, 10'h1C3, 10'h23C, "hrst in wait_accept");
    src_goodcrc(kid);
    repeat (5) @(negedge clk);
    send_hrst(2);
    kid = 0;
    caps(2, 9000, 10'h2E1, 10'h11E, "hrst in wait_psrdy");
    src_goodcrc(kid); kid++;
    ctrl_msg(MT_ACCEPT, "hrst in wait_psrdy");
    send_hrst(3);
    kid = 0;
    send_sym(K_RST1); send_sym(K_SYNC1); send_sym(K_RST2);   // incomplete
    repeat (4) @(negedge clk);
    send_msg(mk_hdr(MT_PING, sid, 3'd0), 0, 0, 1);
    check(irq, "irq before hard reset");
    send_hrst(3);
    check(!irq, "hard reset clears irq");

    // ---- MessageIDCounter wraps ----
    for (int i = 0; i < 9; i++) negotiate(2, (i % 2) ? 9000 : 50 * (181 + $urandom % 800), "wrap");
    negotiate(2, 50 * 179, "just below 9V");

    // ---- reset mid-negotiation ----
    caps(2, 9000, 10'h3C3, 10'h0C3, "reset mid");
    do_reset;
    check(!vbus_ok, "reset clears contract");
    negotiate(2, 9000, "after reset");

    repeat (20) @(negedge clk);
    if (errors == 0) $display("TEST PASSED: USB_PD");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
