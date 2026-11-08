// SPDX-License-Identifier: Apache-2.0
// IP part of USB3_apb_tb: the host-side link partner of the core TB (LFPS
// training, DPH / DPP bulk OUT, ACK / NRDY / LBAD transaction packets, bulk
// IN with retransmission, a shadow of the bulk buffer checking every IN
// payload). STATUS.LINK_UP against the pin through training and warm resets;
// every error class sets IRQ_STATUS.ERR (sticky in the core until PRESETN),
// masked and on the irq pin; PRESETN in U0.
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
  initial begin rx_p = SYM_IDLE; rx_n = ~SYM_IDLE; end

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
  // symbol driver (host -> device), one symbol per PCLK
  // ------------------------------------------------------------------
  task automatic sym(input logic [7:0] s);
    @(negedge PCLK); rx_p = s; rx_n = ~s;
  endtask
  task automatic bad_sym(input logic [7:0] s);        // invalid: rx_n != ~rx_p
    @(negedge PCLK); rx_p = s; rx_n = s;
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
    while (tx_p !== s && t < to) begin @(negedge PCLK); t++; end
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
      @(negedge PCLK); s1 = tx_p;
      @(negedge PCLK); s2 = tx_p;
      @(negedge PCLK); c5 = tx_p;
      @(negedge PCLK);
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
      @(negedge PCLK); s1 = tx_p;
      @(negedge PCLK); s2 = tx_p;
      @(negedge PCLK); c5 = tx_p;
      if (s1 !== {4'h0, TYPE_DATA}) fail("IN DPH type");
      if (s2 !== {es, eb, 3'b000}) fail($sformatf("IN DPH seq/blk %h exp %0d/%0d", s2, es, eb));
      if (c5 !== {3'b000, crc5_16({s2, s1})}) fail("IN DPH CRC5");
      @(negedge PCLK);
      if (tx_p !== SYM_DPP) fail("IN DPP start");
      c = 32'hFFFF_FFFF;
      for (int i = 0; i < 16; i++) begin
        w = 0;
        for (int j = 0; j < 4; j++) begin
          @(negedge PCLK); x = tx_p;
          c = crc32_b(c, x);
          w[8*j +: 8] = x;
        end
        if (w !== mem_m[{eb, 4'(i)}]) fail($sformatf("IN blk %0d dword %0d: %h exp %h",
                                                     eb, i, w, mem_m[{eb, 4'(i)}]));
      end
      cr = 0;
      for (int j = 0; j < 4; j++) begin @(negedge PCLK); cr[8*j +: 8] = tx_p; end
      if (cr !== ~c) fail("IN CRC32");
      @(negedge PCLK);
      if (tx_p !== SYM_END) fail("IN END");
    end
  endtask

  task automatic expect_quiet(input int n, input string m);
    bit q;
    q = 1;
    repeat (n) begin @(negedge PCLK); if (tx_p !== SYM_IDLE) q = 0; end
    if (!q) fail({m, ": unexpected device traffic"});
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
    @(negedge PCLK); PRESETN = 0;
    rx_p = SYM_IDLE; rx_n = ~SYM_IDLE;
    repeat (3) @(negedge PCLK);
    if (tx_p !== SYM_IDLE || link_up || irq) fail("reset state");
    PRESETN = 1;
    vblk_m = 0;
    check_reset_values();
    rd_exp(A_IRQ_STATUS, 0); rd_exp(A_STATUS, 0);
  endtask

  task automatic warm_reset;
    repeat (32) sym(SYM_LFPS);
    @(negedge PCLK);
    if (link_up) fail("warm reset: link still up");
    idle(4);
  endtask


  // ERR is sticky in the core: the w1c cannot clear it, the pin follows the enable
  task automatic err_held(input bit en, input string m);
    idle(2);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
    wr(A_IRQ_STATUS, 1 << IRQ_ERR);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
    if (irq !== en) fail({m, ": irq pin vs enable"});
  endtask

  bit got;
  task automatic ip_func;
    for (int i = 0; i < 64; i++) mem_m[i] = 0;
    for (int i = 0; i < 16; i++) dbuf[i] = 0;
    vblk_m = 0; oseq = 0; iseq = 0;
    rd_exp(A_FLAGS, 0);
    rd_exp(A_STATUS, 0);

    // ---------------- training
    repeat (3) begin repeat (5) sym(SYM_LFPS); idle(10); end
    if (link_up) fail("link up on short bursts");
    rd_exp(A_STATUS, 0);
    train(24);
    rd_exp(A_STATUS, 1);
    rd_exp(A_IRQ_STATUS, 0);

    // ---------------- basic OUT / IN
    out_good(0, 0);
    send_tp(TP_ACK, 3, 0, 1, 1); idle(1);
    expect_tp(TP_NRDY, 3, 0, 1, "IN of unwritten block");
    idle(2);
    in_good(0);
    out_good(1); out_good(2); out_good(3);
    in_good(3); in_good(1); in_good(2);
    // IN retransmission on LBAD
    in_req(2); idle(1);
    recv_dpp(iseq, 2);
    send_tp(TP_LBAD, 0, 0, 2, 0);
    recv_dpp(iseq, 2);
    send_tp(TP_ACK, iseq, 0, 2, 0);
    iseq++; idle(2);
    rd_exp(A_IRQ_STATUS, 0);

    // ---------------- warm reset: link drops, data kept
    warm_reset();
    rd_exp(A_STATUS, 0);
    train();
    rd_exp(A_STATUS, 1);
    in_good(2);

    // ---------------- OUT error, masked: LBAD, then retransmission
    fill(1);
    send_dph(TYPE_DATA, oseq, 1); send_dpp(1);
    expect_tp(TP_LBAD, oseq, 0, 1, "bad CRC32");
    err_held(0, "bad CRC32");
    send_dph(TYPE_DATA, oseq, 1); send_dpp();
    expect_tp(TP_ACK, oseq, 0, 1, "OUT retransmission");
    commit(1); oseq++;
    in_good(1);
    wr(A_IRQ_ENABLE, 1 << IRQ_ERR);
    err_held(1, "bad CRC32, enabled");

    // ---------------- each further error class after a PRESETN
    hard_reset(); train();
    send_tp(TP_ACK, 0, 0, 0, 1, 1);                 // bad TP CRC5
    expect_quiet(10, "bad TP CRC5");
    err_held(0, "bad TP CRC5");
    hard_reset(); train();
    wr(A_IRQ_ENABLE, 1 << IRQ_ERR);
    sym(SYM_DPH); sym(8'h01); bad_sym(8'h55);       // decode error in a header
    err_held(1, "decode error");
    hard_reset(); train();
    out_good(2);
    in_req(2); idle(1);
    recv_dpp(iseq, 2);
    for (int r = 0; r < 3; r++) begin
      send_tp(TP_LBAD, 0, 0, 2, 0);
      recv_dpp(iseq, 2);
    end
    send_tp(TP_LBAD, 0, 0, 2, 0);
    expect_quiet(40, "give-up");
    err_held(0, "give-up");
    in_good(2);

    // ---------------- PRESETN in U0, retrain; leave ERR pending (masked)
    @(negedge PCLK); PRESETN = 0;
    repeat (3) @(negedge PCLK);
    if (link_up || irq || tx_p !== SYM_IDLE) fail("PRESETN in U0");
    PRESETN = 1;
    repeat (2) @(negedge PCLK);
    rd_exp(A_STATUS, 0);
    train();
    fill(1); send_dph(TYPE_DATA, oseq, 0); send_dpp(2); // bad END
    err_held(0, "DPP bad END");
  endtask
