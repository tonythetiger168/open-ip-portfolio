// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for USB3_top -- SystemVerilog
// Host-side link partner: LFPS training (short / invalid / long bursts),
// DPH/DPP bulk OUT transfers, ACK/NRDY/LBAD transaction packets, bulk IN with
// retransmission (LBAD, ACK timeout, give-up), sequence wrap, symbol decode
// errors, warm reset (between packets, during an IN transfer, while the
// device transmits) and reset in U0. A shadow of the bulk buffer checks every
// IN payload. Under Verilator the bound checker (tb/cov/USB3_sva.sv) predicts
// tx_p, link_up and irq on every clock.
// IP design verification v1.1 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module USB3_tb;

  localparam logic [7:0] SYM_IDLE = 8'h00;
  localparam logic [7:0] SYM_LFPS = 8'hAA;
  localparam logic [7:0] SYM_DPH  = 8'hBC;
  localparam logic [7:0] SYM_TP   = 8'h4B;
  localparam logic [7:0] SYM_DPP  = 8'h5A;
  localparam logic [7:0] SYM_END  = 8'h3C;

  localparam logic [3:0] TYPE_DATA = 4'h1;
  localparam logic [3:0] TP_ACK    = 4'hA;
  localparam logic [3:0] TP_NRDY   = 4'h5;
  localparam logic [3:0] TP_LBAD   = 4'hB;

  logic       clk = 0, rst_n = 0;
  logic [7:0] rx_p = SYM_IDLE, rx_n = ~SYM_IDLE;
  logic [7:0] tx_p, tx_n;
  logic       link_up, irq;

  int errors = 0;

  USB3_top dut (.clk(clk), .rst_n(rst_n), .rx_p(rx_p), .rx_n(rx_n),
                .tx_p(tx_p), .tx_n(tx_n), .link_up(link_up), .irq(irq));

  always #5 clk = ~clk;

  task automatic fail(input string m);
    errors++;
    $display("ERROR @%0t: %s", $time, m);
  endtask

  // ------------------------------------------------------------------
  // host model state
  // ------------------------------------------------------------------
  logic [31:0] dbuf  [0:15];      // payload of the next OUT packet
  logic [31:0] mem_m [0:63];      // shadow of the device bulk buffer
  logic [3:0]  vblk_m;            // blocks written
  logic [2:0]  oseq, iseq;        // next OUT / IN sequence numbers

  function automatic logic [4:0] crc5_16(input logic [15:0] d);
    logic [4:0] c;
    logic       fb;
    c = 5'h1F;
    for (int i = 0; i < 16; i++) begin
      fb = d[i] ^ c[0];
      c  = {fb, c[4], c[3] ^ fb, c[2], c[1]};
    end
    crc5_16 = ~c;
  endfunction

  function automatic logic [31:0] crc32_b(input logic [31:0] c_in, input logic [7:0] d);
    logic [31:0] c;
    logic        fb;
    c = c_in;
    for (int i = 0; i < 8; i++) begin
      fb = d[i] ^ c[0];
      c  = c >> 1;
      if (fb) c = c ^ 32'hEDB8_8320;
    end
    crc32_b = c;
  endfunction

  // ------------------------------------------------------------------
  // symbol driver (host -> device), one symbol per clk
  // ------------------------------------------------------------------
  task automatic sym(input logic [7:0] s);
    @(negedge clk); rx_p = s; rx_n = ~s;
  endtask
  task automatic bad_sym(input logic [7:0] s);        // invalid: rx_n != ~rx_p
    @(negedge clk); rx_p = s; rx_n = s;
  endtask
  task automatic idle(input int n);
    repeat (n) sym(SYM_IDLE);
  endtask

  // ------------------------------------------------------------------
  // packets
  // ------------------------------------------------------------------
  // hi: reserved upper header bits (ignored by the device)
  task automatic send_dph(input logic [3:0] typ, input logic [2:0] seq, input logic [1:0] blk,
                          input logic [3:0] hi = 4'h0, input logic [2:0] lo = 3'b000,
                          input logic bad_crc = 0);
    logic [7:0] s1, s2;
    s1 = {hi, typ};
    s2 = {seq, blk, lo};
    sym(SYM_DPH); sym(s1); sym(s2);
    sym({3'b000, crc5_16({s2, s1})} ^ (bad_crc ? 8'h01 : 8'h00));
  endtask

  // err: 0 good, 1 bad CRC32, 2 bad END
  task automatic send_dpp(input int err = 0);
    logic [31:0] c, f;
    logic [7:0]  b;
    sym(SYM_DPP);
    c = 32'hFFFF_FFFF;
    for (int i = 0; i < 16; i++)
      for (int j = 0; j < 4; j++) begin
        b = dbuf[i][8*j +: 8];
        sym(b);
        c = crc32_b(c, b);
      end
    f = ~c;
    if (err == 1) f = f ^ 32'h0000_0100;
    sym(f[7:0]); sym(f[15:8]); sym(f[23:16]); sym(f[31:24]);
    sym((err == 2) ? 8'h00 : SYM_END);
  endtask

  // err: 0 good, 1 bad CRC5, 2 bad END
  task automatic send_tp(input logic [3:0] typ, input logic [2:0] seq, input logic rtry,
                         input logic [1:0] blk, input logic in_req, input int err = 0,
                         input logic [3:0] hi = 4'h0, input logic b0 = 1'b0);
    logic [7:0] s1, s2;
    s1 = {hi, typ};
    s2 = {seq, rtry, blk, in_req, b0};
    sym(SYM_TP); sym(s1); sym(s2);
    sym({3'b000, crc5_16({s2, s1})} ^ ((err == 1) ? 8'h04 : 8'h00));
    sym((err == 2) ? 8'hFF : SYM_END);
  endtask

  // ------------------------------------------------------------------
  // receivers (device -> host)
  // ------------------------------------------------------------------
  task automatic wait_sym(input logic [7:0] s, input int to, output bit got);
    int t;
    t = 0;
    while (tx_p !== s && t < to) begin @(negedge clk); t++; end
    got = (tx_p === s);
  endtask

  task automatic recv_tp(output logic [3:0] typ, output logic [2:0] seq,
                         output logic rtry, output logic [1:0] blk);
    logic [7:0] s1, s2, c5;
    bit got;
    typ = 0; seq = 0; rtry = 0; blk = 0;
    wait_sym(SYM_TP, 200, got);
    if (!got) fail("timeout waiting for transaction packet");
    else begin
      @(negedge clk); s1 = tx_p;
      @(negedge clk); s2 = tx_p;
      @(negedge clk); c5 = tx_p;
      @(negedge clk);
      if (c5 !== {3'b000, crc5_16({s2, s1})}) fail("TP CRC5");
      if (tx_p !== SYM_END) fail("TP END");
      if (s1[7:4] !== 4'h0 || s2[1:0] !== 2'b00) fail("TP reserved bits");
      typ = s1[3:0]; seq = s2[7:5]; rtry = s2[4]; blk = s2[3:2];
    end
  endtask

  task automatic expect_tp(input logic [3:0] et, input logic [2:0] es, input logic ert,
                           input logic [1:0] eb, input string m);
    logic [3:0] t; logic [2:0] s; logic r; logic [1:0] b;
    recv_tp(t, s, r, b);
    if (t !== et || s !== es || r !== ert || b !== eb)
      fail($sformatf("%s: TP type %h seq %0d rtry %b blk %0d, exp %h %0d %b %0d",
                     m, t, s, r, b, et, es, ert, eb));
  endtask

  // one device IN data packet, payload compared against the shadow buffer
  task automatic recv_dpp(input logic [2:0] es, input logic [1:0] eb);
    logic [7:0]  s1, s2, c5, x;
    logic [31:0] c, w, cr;
    bit got;
    wait_sym(SYM_DPH, 400, got);
    if (!got) fail("timeout waiting for IN DPH");
    else begin
      @(negedge clk); s1 = tx_p;
      @(negedge clk); s2 = tx_p;
      @(negedge clk); c5 = tx_p;
      if (s1 !== {4'h0, TYPE_DATA}) fail("IN DPH type");
      if (s2 !== {es, eb, 3'b000}) fail($sformatf("IN DPH seq/blk %h exp %0d/%0d", s2, es, eb));
      if (c5 !== {3'b000, crc5_16({s2, s1})}) fail("IN DPH CRC5");
      @(negedge clk);
      if (tx_p !== SYM_DPP) fail("IN DPP start");
      c = 32'hFFFF_FFFF;
      for (int i = 0; i < 16; i++) begin
        w = 0;
        for (int j = 0; j < 4; j++) begin
          @(negedge clk); x = tx_p;
          c = crc32_b(c, x);
          w[8*j +: 8] = x;
        end
        if (w !== mem_m[{eb, 4'(i)}]) fail($sformatf("IN blk %0d dword %0d: %h exp %h",
                                                     eb, i, w, mem_m[{eb, 4'(i)}]));
      end
      cr = 0;
      for (int j = 0; j < 4; j++) begin @(negedge clk); cr[8*j +: 8] = tx_p; end
      if (cr !== ~c) fail("IN CRC32");
      @(negedge clk);
      if (tx_p !== SYM_END) fail("IN END");
    end
  endtask

  task automatic expect_quiet(input int n, input string m);
    bit q;
    q = 1;
    repeat (n) begin @(negedge clk); if (tx_p !== SYM_IDLE) q = 0; end
    if (!q) fail({m, ": unexpected device traffic"});
  endtask

  task automatic expect_irq(input bit e, input string m);
    if (irq !== e) fail($sformatf("%s: irq %b exp %b", m, irq, e));
  endtask

  // ------------------------------------------------------------------
  // transactions
  // ------------------------------------------------------------------
  task automatic fill(input bit rnd, input logic [31:0] base = 0);
    for (int i = 0; i < 16; i++) dbuf[i] = rnd ? $urandom : base + i;
  endtask

  task automatic commit(input logic [1:0] blk);
    for (int i = 0; i < 16; i++) mem_m[{blk, 4'(i)}] = dbuf[i];
    vblk_m[blk] = 1;
  endtask

  // in-order OUT, ACKed and committed
  task automatic out_good(input logic [1:0] blk, input bit rnd = 1);
    fill(rnd, {14'd0, blk, 16'h0});
    send_dph(TYPE_DATA, oseq, blk, 4'($urandom), 3'($urandom));
    send_dpp();
    expect_tp(TP_ACK, oseq, 0, blk, "OUT in order");
    commit(blk);
    oseq++;
    idle(2);
  endtask

  task automatic in_req(input logic [1:0] blk);
    send_tp(TP_ACK, 3'($urandom), 0, blk, 1, 0, 4'($urandom), 1'($urandom));
  endtask

  // IN of a written block, completed by the host ACK
  task automatic in_good(input logic [1:0] blk);
    in_req(blk); idle(1);
    recv_dpp(iseq, blk);
    send_tp(TP_ACK, iseq, 0, blk, 0);
    iseq++;
    idle(2);
  endtask

  // link training: n host bursts of len LFPS symbols, gap idle between
  task automatic train(input int len = 16, input int n = 40, input int gap = 16);
    int k;
    k = 0;
    while (!link_up && k < n) begin
      repeat (len) sym(SYM_LFPS);
      idle(gap);
      k++;
    end
    if (!link_up) fail("link training");
    idle(4);
    oseq = 0; iseq = 0;
  endtask

  task automatic hard_reset;
    @(negedge clk); rst_n = 0;
    rx_p = SYM_IDLE; rx_n = ~SYM_IDLE;
    repeat (3) @(negedge clk);
    if (tx_p !== SYM_IDLE || link_up || irq) fail("reset state");
    rst_n = 1;
    vblk_m = 0;
  endtask

  task automatic warm_reset;
    repeat (32) sym(SYM_LFPS);
    @(negedge clk);
    if (link_up) fail("warm reset: link still up");
    idle(4);
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  bit got;
  initial begin
    for (int i = 0; i < 64; i++) mem_m[i] = 0;
    for (int i = 0; i < 16; i++) dbuf[i] = 0;
    vblk_m = 0; oseq = 0; iseq = 0;
    repeat (4) @(negedge clk);
    if (tx_p !== SYM_IDLE || link_up || irq) fail("reset state");
    rst_n = 1;

    // ---------------- training: LFPS during RXDET, invalid LFPS, short
    // bursts, a packet before U0, then long bursts
    repeat (20) sym(SYM_LFPS);
    idle(14);
    repeat (12) bad_sym(SYM_LFPS);
    idle(2);
    repeat (3) begin repeat (5) sym(SYM_LFPS); idle(10); end
    send_tp(TP_ACK, 0, 0, 0, 1);                    // not yet in U0: ignored
    expect_irq(0, "packet before U0");
    if (link_up) fail("link up on short bursts");
    train(24);
    expect_irq(0, "training");

    // ---------------- basic OUT / IN
    out_good(0, 0);
    send_tp(TP_ACK, 3, 0, 1, 1); idle(1);
    expect_tp(TP_NRDY, 3, 0, 1, "IN of unwritten block");
    idle(2);
    in_good(0);
    out_good(1); out_good(2); out_good(3);
    in_good(3); in_good(1); in_good(2);
    expect_irq(0, "error-free traffic");

    // ---------------- host TPs the device ignores
    send_tp(TP_ACK, 5, 0, 0, 0);                    // ACK without IN transfer
    send_tp(TP_LBAD, 5, 0, 0, 0);                   // LBAD without IN transfer
    send_tp(TP_NRDY, 1, 1, 2, 0, 0, 4'hF, 1);       // NRDY from host
    send_tp(4'h3, 2, 0, 3, 1);                      // unknown TP type
    send_dph(4'hE, 1, 1, 4'hC, 3'b101);             // unsupported DPH types
    send_dph(4'h0, 2, 0, 4'h3, 3'b010);
    send_dph(4'h9, 3, 2, 4'h0, 3'b000);             // differs from DATA only in bit 3
    idle(4);
    bad_sym(8'h12); bad_sym(8'h00);                 // invalid symbols between packets
    sym(SYM_LFPS); sym(SYM_IDLE);
    expect_quiet(20, "ignored packets");
    expect_irq(0, "ignored packets");

    // ---------------- IN retransmission: LBAD, wrong-seq ACK, host NRDY,
    // ACK timeout, busy request
    in_req(2); idle(1);
    recv_dpp(iseq, 2);
    send_tp(TP_ACK, iseq + 3'd1, 0, 2, 0);          // wrong sequence: ignored
    send_tp(TP_LBAD, 0, 0, 2, 0);
    recv_dpp(iseq, 2);
    send_tp(TP_NRDY, iseq, 0, 2, 0);                // host not ready: watchdog resends
    recv_dpp(iseq, 2);                              // after the ACK timeout
    send_tp(TP_ACK, iseq, 0, 2, 0);
    iseq++; idle(2);
    // busy: second IN request while the first is in flight -> NRDY after the DPP
    in_req(1);
    fork
      begin idle(1); send_tp(TP_ACK, 6, 0, 3, 1); end
      begin recv_dpp(iseq, 1); expect_tp(TP_NRDY, 6, 0, 3, "IN busy"); end
    join
    send_tp(TP_ACK, iseq, 0, 1, 0);
    iseq++; idle(2);
    // OUT while an IN DPP is being transmitted: its ACK waits for the DPP
    in_req(0);
    fork
      begin idle(1); fill(1); send_dph(TYPE_DATA, oseq, 2); send_dpp(); end
      begin recv_dpp(iseq, 0); expect_tp(TP_ACK, oseq, 0, 2, "OUT during IN"); end
    join
    commit(2); oseq++;
    send_tp(TP_ACK, iseq, 0, 0, 0);
    iseq++; idle(2);
    // OUT response and IN request pending together: response goes first
    fill(1);
    send_dph(TYPE_DATA, oseq, 3); send_dpp();
    fork
      in_req(3);
      expect_tp(TP_ACK, oseq, 0, 3, "OUT before IN");
    join
    commit(3); oseq++;
    recv_dpp(iseq, 3);
    send_tp(TP_ACK, iseq, 0, 3, 0);
    iseq++; idle(2);
    // ACK timeout and an OUT response falling due on the same clock: the
    // response goes first, then the retransmission
    in_req(0); idle(1);
    recv_dpp(iseq, 0);
    idle(182);
    fill(0, 32'h0102_0000);
    send_dph(TYPE_DATA, oseq, 1); send_dpp();
    expect_tp(TP_ACK, oseq, 0, 1, "OUT at ACK timeout");
    commit(1); oseq++;
    recv_dpp(iseq, 0);
    send_tp(TP_ACK, iseq, 0, 0, 0);
    iseq++; idle(2);
    expect_irq(0, "retransmission");

    // ---------------- OUT errors
    fill(1);
    send_dph(TYPE_DATA, oseq, 1); send_dpp(1);      // bad CRC32 -> LBAD
    expect_tp(TP_LBAD, oseq, 0, 1, "bad CRC32");
    expect_irq(1, "bad CRC32");
    send_dph(TYPE_DATA, oseq, 1); send_dpp();       // host retransmits
    expect_tp(TP_ACK, oseq, 0, 1, "OUT retransmission");
    commit(1); oseq++;
    fill(1);                                        // duplicate: retry ACK, no rewrite
    send_dph(TYPE_DATA, oseq - 3'd1, 1); send_dpp();
    expect_tp(TP_ACK, oseq - 3'd1, 1, 1, "duplicate");
    send_dph(TYPE_DATA, oseq + 3'd3, 0); send_dpp(); // out of order -> NRDY
    expect_tp(TP_NRDY, oseq + 3'd3, 0, 0, "out of order");
    in_good(1); in_good(0);
    // every OUT outcome and an IN busy request on every bank
    for (int b = 0; b < 4; b++) begin
      fill(1);
      send_dph(TYPE_DATA, oseq, 2'(b)); send_dpp(1);
      expect_tp(TP_LBAD, oseq, 0, 2'(b), "bad CRC32 per bank");
      send_dph(TYPE_DATA, oseq, 2'(b)); send_dpp();
      expect_tp(TP_ACK, oseq, 0, 2'(b), "retransmission per bank");
      commit(2'(b)); oseq++;
      fill(1);
      send_dph(TYPE_DATA, oseq - 3'd1, 2'(b)); send_dpp();
      expect_tp(TP_ACK, oseq - 3'd1, 1, 2'(b), "duplicate per bank");
      send_dph(TYPE_DATA, oseq + 3'd3, 2'(b)); send_dpp();
      expect_tp(TP_NRDY, oseq + 3'd3, 0, 2'(b), "out of order per bank");
      idle(2);
      in_req(1);
      fork
        begin idle(1); send_tp(TP_ACK, 6, 0, 2'(b), 1); end
        begin recv_dpp(iseq, 1); expect_tp(TP_NRDY, 6, 0, 2'(b), "IN busy per bank"); end
      join
      send_tp(TP_ACK, iseq, 0, 1, 0);
      iseq++; idle(2);
    end
    // an IN acknowledged on the fourth attempt
    in_req(2); idle(1);
    for (int k = 0; k < 3; k++) begin recv_dpp(iseq, 2); send_tp(TP_LBAD, 0, 0, 2, 0); end
    recv_dpp(iseq, 2); send_tp(TP_ACK, iseq, 0, 2, 0);
    iseq++; idle(2);

    hard_reset(); train();
    // IN requests for every block before any is written
    for (int b = 0; b < 4; b++) begin
      send_tp(TP_ACK, 3, 0, 2'(b), 1); idle(1);
      expect_tp(TP_NRDY, 3, 0, 2'(b), "IN of an unwritten block after reset");
      idle(2);
    end
    out_good(0);
    send_dph(TYPE_DATA, oseq, 0, 0, 0, 1);          // bad header CRC5
    idle(4); expect_irq(1, "bad DPH CRC5");
    hard_reset(); train();
    send_dph(TYPE_DATA, oseq, 0); sym(SYM_IDLE);    // DPP start missing
    idle(4); expect_irq(1, "missing DPP");
    hard_reset(); train();
    fill(1); send_dph(TYPE_DATA, oseq, 0); send_dpp(2); // bad END
    idle(4); expect_irq(1, "DPP bad END");
    expect_quiet(10, "DPP bad END");
    hard_reset(); train();
    send_tp(TP_ACK, 0, 0, 0, 1, 1);                 // bad TP CRC5
    idle(4); expect_irq(1, "bad TP CRC5");
    expect_quiet(10, "bad TP CRC5");
    hard_reset(); train();
    send_tp(TP_ACK, 0, 0, 0, 1, 2);                 // bad TP END
    idle(4); expect_irq(1, "bad TP END");
    hard_reset(); train();
    sym(SYM_DPH); sym(8'h01); bad_sym(8'h55);       // decode error in a header
    idle(4); expect_irq(1, "decode error");
    hard_reset(); train();
    fill(1); send_dph(TYPE_DATA, 0, 0); sym(SYM_DPP);
    for (int i = 0; i < 10; i++) sym(8'(i));
    bad_sym(8'h77);                                  // decode error in a payload
    idle(4);
    sym(SYM_TP); bad_sym(8'h0A);                     // and in a TP
    idle(4); expect_irq(1, "decode error in payload");
    out_good(1); in_good(1);                        // device recovered

    // ---------------- give-up after four attempts
    hard_reset(); train();
    out_good(2);
    in_req(2); idle(1);
    recv_dpp(iseq, 2);
    for (int r = 0; r < 3; r++) begin
      send_tp(TP_LBAD, 0, 0, 2, 0);
      recv_dpp(iseq, 2);
    end
    send_tp(TP_LBAD, 0, 0, 2, 0);
    idle(4); expect_irq(1, "give-up");
    expect_quiet(40, "give-up");
    in_good(2);                                     // same sequence number again

    // ---------------- sequence wrap
    for (int i = 0; i < 10; i++) out_good(2'(i));
    for (int i = 0; i < 10; i++) in_good(2'(i));

    // ---------------- warm reset
    hard_reset(); train();
    out_good(0); out_good(1); in_good(0);
    repeat (20) sym(SYM_LFPS);                      // too short: no warm reset
    idle(2);
    if (!link_up) fail("20 LFPS symbols dropped the link");
    for (int i = 0; i < 16; i++) dbuf[i] = 32'hAAAA_AAAA;   // LFPS-like payload
    send_dph(TYPE_DATA, oseq, 2); send_dpp();
    expect_tp(TP_ACK, oseq, 0, 2, "AA payload");
    commit(2); oseq++;
    if (!link_up) fail("AA payload dropped the link");
    warm_reset();
    train();
    in_good(2);                                     // data kept, IN sequence restarted
    out_good(3);                                    // OUT sequence restarted
    in_req(3); idle(1);                             // warm reset while waiting for ACK
    recv_dpp(iseq, 3);
    warm_reset();
    train();
    expect_quiet(300, "after warm reset");          // transfer abandoned
    in_req(1); idle(1);                             // warm reset while transmitting
    wait_sym(SYM_DPH, 50, got);
    if (!got) fail("IN DPH before warm reset");
    warm_reset();
    train();
    in_good(1);
    expect_irq(0, "warm resets");

    // ---------------- random traffic
    for (int n = 0; n < 40; n++) begin
      case ($urandom % 4)
        0, 1: out_good(2'($urandom));
        default: begin : rnd_in
          int b;
          b = $urandom % 4;
          if (vblk_m[b]) in_good(2'(b));
          else out_good(2'(b));
        end
      endcase
    end

    // ---------------- fast host: U0 still waits for the device's two bursts
    hard_reset();
    idle(34);
    repeat (2) begin repeat (8) sym(SYM_LFPS); sym(SYM_IDLE); end
    idle(10);
    if (link_up) fail("U0 before the device sent two bursts");
    train(8, 40, 1);
    out_good(0); in_good(0);

    // ---------------- reset in U0
    @(negedge clk); rst_n = 0;
    repeat (3) @(negedge clk);
    if (link_up || irq || tx_p !== SYM_IDLE) fail("reset in U0");
    rst_n = 1;
    repeat (10) @(negedge clk);

    if (errors == 0) $display("TEST PASSED: USB3");
    else $display("TEST FAILED: USB3 (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("TEST FAILED: USB3 (timeout)");
    $finish;
  end

endmodule
