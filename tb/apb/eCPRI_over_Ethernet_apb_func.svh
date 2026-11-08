// SPDX-License-Identifier: Apache-2.0
// IP part of eCPRI_over_Ethernet_apb_tb: the Ethernet peer of the core TB
// (64-byte frames with FCS byte-streamed in; a monitor checking length and
// FCS of every DUT frame) with the CPU port driven through the APB words:
// configuration, IQ data with gap tracking and overflow, remote memory,
// remote reset, events and fault injection, TX queue pressure, the address
// filter and every error class; ERRORS mirrored in IRQ_STATUS.ERR (masked and
// on the irq pin); PRESETN while receiving and transmitting.
  localparam logic [47:0] OWN  = 48'h1122_3344_5566;
  localparam logic [47:0] PEER = 48'hAABB_CCDD_EEFF;
  localparam logic [47:0] BC   = 48'hFFFF_FFFF_FFFF;
  initial begin rx_d = 0; rx_dv = 0; end

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic [7:0] d);
    c = c ^ {24'h0, d};
    for (int i = 0; i < 8; i++) c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
    crc32 = c;
  endfunction


  // cpu port: the core registers through APB (word a at A_DMAC_LO + 4a)
  function automatic logic [11:0] ca(input logic [3:0] a);
    return A_DMAC_LO + 12'(4 * a);
  endfunction
  task automatic cpu_wr(input logic [3:0] a, input logic [31:0] d);
    wr(ca(a), d);
  endtask
  task automatic cpu_rd(input logic [3:0] a, output logic [31:0] d);
    rd(ca(a)); d = rdv;
  endtask
  task automatic expect_rd(input logic [3:0] a, input logic [31:0] e, input string s);
    rd(ca(a));
    if (rdv !== e) fail($sformatf("%s: reg%0d = %h exp %h", s, a, rdv, e));
  endtask
  task automatic iq_pop(output logic [31:0] d);
    rd(A_IQ); d = rdv;
  endtask

  // ------------------------------------------------------------------
  // frame builder / driver
  // ------------------------------------------------------------------
  logic [7:0]  pb [0:39];                  // eCPRI payload
  logic [7:0]  fr [0:255];
  logic [47:0] sa = PEER;                  // source MAC used by mk()

  // build a frame of len bytes (FCS included); bad_fcs flips one FCS bit
  task automatic mk(input logic [47:0] da, input logic [15:0] et, input logic [7:0] h0,
                    input logic [7:0] mt, input logic [15:0] ps, input int len,
                    input bit bad_fcs);
    logic [31:0] c;
    for (int i = 0; i < 256; i++) fr[i] = 8'h00;
    {fr[0], fr[1], fr[2], fr[3], fr[4], fr[5]}   = da;
    {fr[6], fr[7], fr[8], fr[9], fr[10], fr[11]} = sa;
    {fr[12], fr[13]} = et;
    fr[14] = h0; fr[15] = mt; {fr[16], fr[17]} = ps;
    for (int i = 0; i < 40; i++) fr[18 + i] = pb[i];
    for (int i = 58; i < len - 4; i++) fr[i] = 8'($urandom);
    c = 32'hFFFF_FFFF;
    for (int i = 0; i < len - 4; i++) c = crc32(c, fr[i]);
    c = ~c ^ (bad_fcs ? 32'h0000_0100 : 32'h0);
    {fr[len-1], fr[len-2], fr[len-3], fr[len-4]} = c;
  endtask

  task automatic drive(input int len, input int gap = 2);
    for (int i = 0; i < len; i++) begin
      @(negedge PCLK); rx_dv = 1; rx_d = fr[i];
    end
    @(negedge PCLK); rx_dv = 0; rx_d = 8'($urandom);
    repeat (gap) @(negedge PCLK);
  endtask

  task automatic send(input logic [7:0] mt, input logic [15:0] ps, input int gap = 2);
    mk(OWN, 16'hAEFE, 8'h10, mt, ps, 64, 0);
    drive(64, gap);
  endtask

  task automatic rnd_pay;
    for (int i = 0; i < 40; i++) pb[i] = 8'($urandom);
  endtask

  // ------------------------------------------------------------------
  // TX monitor: every frame is 64 bytes with a good FCS
  // ------------------------------------------------------------------
  logic [7:0] cap [0:63], cb [0:127];
  int         ncap = 0, cn = 0;
  logic       en_q = 0;
  always @(posedge PCLK) begin
    logic [31:0] c;
    if (!PRESETN) begin
      cn = 0; en_q = 0;
    end else begin
      if (tx_en) begin
        if (cn < 128) cb[cn] = tx_d;
        cn++;
      end else if (en_q) begin
        c = 32'hFFFF_FFFF;
        for (int i = 0; i < 64; i++) c = crc32(c, cb[i]);
        if (cn != 64)                 fail($sformatf("tx frame length %0d", cn));
        else if (c != 32'hDEBB20E3)   fail("tx frame FCS");
        for (int i = 0; i < 64; i++) cap[i] = cb[i];
        ncap++; cn = 0;
      end
      en_q = tx_en;
    end
  end

  task automatic wait_tx(input int n0, input string s);
    int t = 0;
    while (ncap == n0 && t < 400) begin @(negedge PCLK); t++; end
    if (ncap == n0) fail({"no tx frame: ", s});
  endtask

  // check the captured frame header + payload bytes
  task automatic chk_tx(input logic [7:0] mt, input logic [7:0] len, input logic [95:0] p,
                        input string s);
    if ({cap[0], cap[1], cap[2], cap[3], cap[4], cap[5]} !== PEER ||
        {cap[6], cap[7], cap[8], cap[9], cap[10], cap[11]} !== OWN ||
        {cap[12], cap[13], cap[14], cap[15], cap[16], cap[17]} !== {16'hAEFE, 8'h10, mt, 8'h00, len})
      fail({"tx header: ", s});
    for (int i = 0; i < 42; i++)
      if (cap[18 + i] !== ((i < 12) ? p[95 - 8 * i -: 8] : 8'h00))
        fail($sformatf("%s: tx payload[%0d] = %h exp %h", s, i, cap[18+i],
                       (i < 12) ? p[95 - 8 * i -: 8] : 8'h00));
  endtask

  task automatic no_tx(input int cyc, input string s);
    int n0 = ncap;
    repeat (cyc) @(negedge PCLK);
    if (ncap != n0 || tx_en) fail({"unexpected tx frame: ", s});
  endtask

  // ERRORS flags as expected; ERR held in IRQ_STATUS until they are cleared
  bit err_en = 0;
  task automatic expect_irq(input logic [4:0] bits, input string s);
    expect_rd(4'd8, {27'h0, bits}, s);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
    if (irq !== err_en) fail({s, ": irq pin vs enable"});
    wr(A_IRQ_STATUS, 1 << IRQ_ERR);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);               // still held by the flags
    cpu_wr(4'd8, 32'h1F);
    wr(A_IRQ_STATUS, 1 << IRQ_ERR);
    rd_exp(A_IRQ_STATUS, 0);
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [31:0] d, iqref [0:31], memref [0:63], v;
  logic [95:0] e;                         // expected 12 payload bytes, byte 0 first
  logic [7:0]  okc, errc;
  int          n0, nw, wp;

  // IQ frame with nw words; pc/seq given; data recorded in iqref
  task automatic send_iq(input logic [15:0] pc_, input logic [15:0] sq_, input int nw_,
                         input int mode = 0);
    {pb[0], pb[1], pb[2], pb[3]} = {pc_, sq_};
    for (int w = 0; w < 8; w++) begin
      v = (mode == 1) ? 32'hFFFF_FFFF : (mode == 2) ? 32'h0 : $urandom;
      {pb[4+4*w], pb[5+4*w], pb[6+4*w], pb[7+4*w]} = v;
    end
    send(8'd0, 16'(4 + 4 * nw_));
  endtask

  task automatic mem_wr(input logic [7:0] a, input logic [31:0] dat);
    rnd_pay();
    {pb[0], pb[1], pb[2], pb[3], pb[4]} = {24'h0, a, 8'h01};
    {pb[5], pb[6], pb[7], pb[8]} = dat;
    send(8'd4, 16'd9);
  endtask

  task automatic mem_rd(input logic [7:0] a, input logic [31:0] exp_d);
    rnd_pay();
    {pb[0], pb[1], pb[2], pb[3], pb[4]} = {24'h0, a, 8'h00};
    n0 = ncap;
    send(8'd4, 16'd5);
    wait_tx(n0, "mem read response");
    e = {8'(0), 8'(0), 8'(0), 8'(a), 8'(2), 8'(exp_d[31:24]), 8'(exp_d[23:16]), 8'(exp_d[15:8]), 8'(exp_d[7:0]), 8'(0), 8'(0), 8'(0)};
    chk_tx(8'd4, 8'd9, e, "mem read response");
  endtask

  task automatic evt(input logic [7:0] id, input logic [7:0] ty, input logic [7:0] sq_,
                     input logic [7:0] nf, input logic [15:0] ps = 16'hFFFF);
    rnd_pay();
    {pb[0], pb[1], pb[2], pb[3]} = {id, ty, sq_, nf};
    send(8'd6, (ps == 16'hFFFF) ? 16'(4 + 8 * nf) : ps);
  endtask

  task automatic inject(input logic [20:0] f);
    cpu_wr(4'd7, {11'h0, f});
  endtask

  task automatic ip_func;
    for (int i = 0; i < 40; i++) pb[i] = 0;
    // ---------------- reset values
    expect_rd(4'd0, 32'hCCDD_EEFF, "reset dmac lo");
    expect_rd(4'd1, 32'h0000_AABB, "reset dmac hi");
    expect_rd(4'd2, 32'h3344_5566, "reset smac lo");
    expect_rd(4'd3, 32'h0000_1122, "reset smac hi");
    expect_rd(4'd5, 32'h0, "reset status");
    expect_rd(4'd8, 32'h0, "reset irq");
    expect_rd(4'd12, 32'h0, "reset tx status");
    if (irq || tx_en || reset_op) fail("outputs after reset");
    rd_exp(A_FLAGS, 0);
    wr(A_IQ, $urandom); wr(A_COUNTS, $urandom); wr(A_TX_STATUS, $urandom);   // read-only: ignored
    wr(A_IQ_LAST, $urandom); wr(A_RX_SMAC_LO, $urandom); wr(A_RX_SMAC_HI, $urandom);
    expect_rd(4'd6, 0, "IQ_LAST"); expect_rd(4'd10, 0, "RX_SMAC_LO"); expect_rd(4'd11, 0, "RX_SMAC_HI");
    apb(1, A_ERRORS, 32'h1F, 4'h1);
    if (!rerr) fail("no PSLVERR on a partial core write");

    // ---------------- configuration registers (all bits both ways)
    for (int r = 0; r < 4; r++) begin
      v = (r == 0) ? 32'hFFFF_FFFF : (r == 1) ? 32'h0 : $urandom;
      for (int a = 0; a < 4; a++) cpu_wr(4'(a), v);
      expect_rd(4'd0, v, "dmac lo");
      expect_rd(4'd1, {16'h0, v[15:0]}, "dmac hi");
      expect_rd(4'd2, v, "smac lo");
      expect_rd(4'd3, {16'h0, v[15:0]}, "smac hi");
    end
    cpu_wr(4'd0, PEER[31:0]); cpu_wr(4'd1, {16'h0, PEER[47:32]});
    cpu_wr(4'd2, OWN[31:0]);  cpu_wr(4'd3, {16'h0, OWN[47:32]});

    // ---------------- IQ data
    send_iq(16'h1234, 16'h0001, 3);
    for (int w = 0; w < 3; w++) begin
      iq_pop(d);
      if (d !== {pb[4+4*w], pb[5+4*w], pb[6+4*w], pb[7+4*w]}) fail($sformatf("iq word %0d", w));
    end
    expect_rd(4'd6, {16'h1234, 16'h0001}, "last pc/seq");
    send_iq(16'h1234, 16'h0002, 0);                  // in sequence, no IQ bytes
    send_iq(16'h1234, 16'h0007, 8);                  // gap
    send_iq(16'h5678, 16'h0000, 1);                  // other pc_id: no gap
    expect_rd(4'd5, {8'd0, 8'd4, 8'd1, 2'd0, 6'd9}, "iq status");
    repeat (9) iq_pop(d);
    iq_pop(d);                                       // empty pop is ignored
    // fill rounds: all ones / all zeros / random through every buffer entry
    for (int r = 0; r < 5; r++) begin
      for (int f = 0; f < 4; f++) send_iq(16'h5678, 16'(r * 4 + f + 1), 8, r % 3 + 1);
      expect_rd(4'd5, {8'd0, 8'(8 + r * 4), 8'd1, 2'd0, 6'd32}, "iq full");
      for (int w = 0; w < 32; w++) iq_pop(d);
    end
    // overflow: 32 words held, then 5 more frames' worth
    for (int f = 0; f < 4; f++) send_iq(16'h0BAD, 16'(f), 8);
    send_iq(16'h0BAD, 16'd4, 8);
    expect_irq(5'b01000, "iq overflow");
    expect_rd(4'd5, {8'd0, 8'd29, 8'd1, 2'd0, 6'd32}, "iq overflow status");
    repeat (32) iq_pop(d);
    send_iq(16'h0C00, 16'd0, 2);
    send_iq(16'h0C00, 16'd1, 4);
    expect_rd(4'd5, {8'd0, 8'd31, 8'd1, 2'd0, 6'd6}, "iq after overflow");
    repeat (6) iq_pop(d);
    // seq gaps until the gap counter wraps; pc/seq values random
    for (int i = 0; i < 258; i++) begin
      send_iq(16'h0D00, 16'(2 * i), 0, 0);
    end
    send_iq(16'hFFFF, 16'hFFFF, 0);
    send_iq(16'h0000, 16'h0000, 0);
    for (int i = 0; i < 4; i++) send_iq(16'($urandom), 16'($urandom), 0);
    expect_rd(4'd5, {8'd0, 8'(31 + 264), 8'(1 + 257), 2'd0, 6'd0}, "gap counter wrap");

    // ---------------- remote memory
    for (int r = 0; r < 3; r++)
      for (int a = 0; a < 64; a++) begin
        memref[a] = (r == 0) ? 32'hFFFF_FFFF : (r == 1) ? 32'h0 : $urandom;
        mem_wr(8'(a * 4), memref[a]);
      end
    for (int a = 0; a < 64; a += 9) mem_rd(8'(a * 4), memref[a]);
    mem_rd(8'd252, memref[63]);
    // malformed: address >= 256, misaligned, read with 9 bytes, write with 5,
    // unknown rw
    okc = 0;
    rnd_pay(); {pb[0], pb[1], pb[2], pb[3], pb[4]} = {32'h0000_0100, 8'h00}; send(8'd4, 16'd5);
    expect_irq(5'b00100, "mem addr high");
    rnd_pay(); {pb[0], pb[1], pb[2], pb[3], pb[4]} = {32'h8000_0000, 8'h01}; send(8'd4, 16'd9);
    rnd_pay(); {pb[0], pb[1], pb[2], pb[3], pb[4]} = {32'h0000_0042, 8'h00}; send(8'd4, 16'd5);
    expect_irq(5'b00100, "mem addr misaligned");
    rnd_pay(); {pb[0], pb[1], pb[2], pb[3], pb[4]} = {32'h0000_0040, 8'h00}; send(8'd4, 16'd9);
    rnd_pay(); {pb[0], pb[1], pb[2], pb[3], pb[4]} = {32'h0000_0040, 8'h01}; send(8'd4, 16'd5);
    rnd_pay(); {pb[0], pb[1], pb[2], pb[3], pb[4]} = {32'h0000_0040, 8'h02}; send(8'd4, 16'd9);
    expect_irq(5'b00100, "mem bad rw/size");
    no_tx(80, "malformed memory requests");
    mem_rd(8'h40, memref[16]);

    // ---------------- remote reset
    rnd_pay(); {pb[0], pb[1], pb[2]} = {16'hBEEF, 8'h01};
    n0 = ncap; send(8'd5, 16'd3);
    if (reset_op !== 16'hBEEF) fail("reset_op");
    wait_tx(n0, "reset response");
    e = {8'(8'hBE), 8'(8'hEF), 8'(2), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0)};
    chk_tx(8'd5, 8'd3, e, "reset response");
    expect_rd(4'd9, 32'h0000_BEEF, "reset_op reg");
    cpu_wr(4'd9, 32'h0); expect_rd(4'd9, 32'h0000_BEEF, "reset_op kept");
    cpu_wr(4'd9, 32'h1); expect_rd(4'd9, 32'h0, "reset_op cleared");
    for (int r = 0; r < 3; r++) begin               // vendor bytes, all id bits
      rnd_pay(); pb[2] = 8'h01;
      {pb[0], pb[1]} = (r == 0) ? 16'hFFFF : (r == 1) ? 16'h0 : 16'h5AA5;
      send(8'd5, 16'd3 + 16'(r * 12));
      if (reset_op !== {pb[0], pb[1]}) fail("reset_op vendor");
    end
    rnd_pay(); {pb[0], pb[1], pb[2]} = {16'h1357, 8'h01};
    send(8'd5, 16'd3);
    if (reset_op !== 16'h1357) fail("reset_op");
    rnd_pay(); {pb[0], pb[1], pb[2]} = {16'h2468, 8'h02}; send(8'd5, 16'd3);
    rnd_pay(); pb[2] = 8'h01; send(8'd5, 16'd2);
    expect_irq(5'b00100, "reset malformed");
    if (reset_op !== 16'h1357) fail("reset_op after malformed");
    repeat (300) @(negedge PCLK);

    // ---------------- events
    n0 = ncap; evt(8'h3C, 8'd0, 8'h11, 8'd1);     // fault indication -> ack
    wait_tx(n0, "fault ack");
    e = {8'(8'h3C), 8'(1), 8'(8'h11), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0)};
    chk_tx(8'd6, 8'd4, e, "fault ack");
    n0 = ncap; evt(8'hC3, 8'd3, 8'hEE, 8'd0);     // sync request -> sync ack
    wait_tx(n0, "sync ack");
    e = {8'(8'hC3), 8'(4), 8'(8'hEE), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0), 8'(0)};
    chk_tx(8'd6, 8'd4, e, "sync ack");
    evt(8'h01, 8'd2, 8'h22, 8'd4);                 // notification: recorded
    expect_rd(4'd7, {8'h0, 8'h22, 5'h0, 3'd2, 8'h01}, "event record");
    evt(8'hFE, 8'd5, 8'hDD, 8'd2);
    evt(8'h7F, 8'd4, 8'h80, 8'd3);
    no_tx(100, "recorded events");
    expect_rd(4'd7, {8'h0, 8'h80, 5'h0, 3'd4, 8'h7F}, "event record 2");
    evt(8'h00, 8'd6, 8'h00, 8'd0);                 // bad type
    evt(8'h00, 8'd0, 8'h00, 8'd5, 16'd40);        // 5 elements
    evt(8'h00, 8'd0, 8'h00, 8'd1, 16'd4);         // size mismatch
    expect_irq(5'b00100, "event malformed");
    no_tx(80, "malformed events");
    // fault injection -> indication frame -> matching ack clears ack_wait
    n0 = ncap; inject({1'b1, 12'hABC, 8'h5A});
    wait_tx(n0, "fault indication");
    e = {8'(8'h5A), 8'(0), 8'(8'h00), 8'(1), 8'(8'hFF), 8'(8'hFF), 8'(8'h1A), 8'(8'hBC), 8'(0), 8'(0), 8'(0), 8'(0)};
    chk_tx(8'd6, 8'd12, e, "fault indication");
    expect_rd(4'd12, {14'h0, 1'b1, 1'b0, 8'd1, 5'h0, 3'd0}, "ack_wait set");
    evt(8'h5A, 8'd1, 8'h01, 8'd0);                 // wrong seq: no match
    expect_rd(4'd12, {14'h0, 1'b1, 1'b0, 8'd1, 5'h0, 3'd0}, "ack_wait kept");
    evt(8'h5B, 8'd1, 8'h00, 8'd0);                 // wrong id
    evt(8'h5A, 8'd1, 8'h00, 8'd0);                 // match
    expect_rd(4'd12, {14'h0, 1'b0, 1'b0, 8'd1, 5'h0, 3'd0}, "ack_wait cleared");
    evt(8'h5A, 8'd1, 8'h00, 8'd0);                 // repeated ack: no effect
    // random injections until the sequence number wraps
    for (int i = 0; i < 256; i++) begin
      inject(21'($urandom));
      repeat (70) @(negedge PCLK);
    end
    repeat (100) @(negedge PCLK);
    expect_rd(4'd12, {14'h0, 1'b1, 1'b0, 8'd1, 5'h0, 3'd0}, "tx seq wrap");
    inject(21'h1FFFFF); inject(21'h0);
    repeat (200) @(negedge PCLK);

    // ---------------- TX queue pressure
    // back-to-back injections: queue fills, one waits, the next is dropped
    for (int i = 0; i < 7; i++) inject(21'(i));
    expect_irq(5'b01000, "injection while pending");
    repeat (500) @(negedge PCLK);
    // a read response while the queue is full is lost
    for (int i = 0; i < 6; i++) inject(21'(i));
    rnd_pay(); {pb[0], pb[1], pb[2], pb[3], pb[4]} = {32'h0, 8'h00}; send(8'd4, 16'd5);
    expect_irq(5'b01000, "response lost");
    repeat (500) @(negedge PCLK);
    // response and pending injection in the same cycle: response first
    for (int i = 0; i < 3; i++) begin
      rnd_pay(); {pb[0], pb[1], pb[2], pb[3], pb[4]} = {32'h8, 8'h00};
      fork
        send(8'd4, 16'd5);
        begin repeat (62) @(negedge PCLK); apb_now(1, A_EVENT, 32'h3, 4'hF); end
      join
      repeat (300) @(negedge PCLK);
    end
    // mixed responses and injections through every queue slot
    for (int i = 0; i < 48; i++) begin
      rnd_pay(); {pb[0], pb[1], pb[2], pb[3], pb[4]} = {32'(($urandom % 64) * 4), 8'h00};
      if (i % 3 != 2) inject(21'($urandom));
      send(8'd4, 16'd5, 1 + $urandom % 40);
    end
    repeat (600) @(negedge PCLK);
    // injection loaded while the previous one is being pushed
    no_idle = 1; inject(21'h4); inject(21'h5); no_idle = 0;
    repeat (400) @(negedge PCLK);
    cpu_wr(4'd8, 32'h1F);

    // ---------------- receive filter and error classes
    cpu_rd(4'd5, d); okc = d[23:16]; errc = d[31:24];
    sa = 48'($urandom) << 16 | 48'($urandom);
    rnd_pay(); {pb[0], pb[1], pb[2]} = {16'h4242, 8'h01};
    mk(BC, 16'hAEFE, 8'h10, 8'd5, 16'd3, 64, 0); drive(64);      // broadcast: taken
    if (reset_op !== 16'h4242) fail("broadcast frame");
    expect_rd(4'd10, sa[31:0], "rx smac lo");
    expect_rd(4'd11, {16'h0, sa[47:32]}, "rx smac hi");
    for (int r = 0; r < 3; r++) begin                            // all source MAC bits
      sa = (r == 0) ? 48'hFFFF_FFFF_FFFF : (r == 1) ? 48'h0 : {16'($urandom), 32'($urandom)};
      mk(BC, 16'hAEFE, 8'h10, 8'd5, 16'd3, 64, 0); drive(64);
    end
    sa = PEER;
    for (int b = 0; b < 6; b++) begin                            // other DMACs: dropped
      mk(OWN ^ (48'h1 << (8 * b)), 16'hAEFE, 8'h10, 8'd5, 16'd3, 64, 0); drive(64);
      mk(BC ^ (48'h80 << (8 * b)), 16'hAEFE, 8'h10, 8'd5, 16'd3, 64, 0); drive(64);
    end
    mk(OWN, 16'h0800, 8'h10, 8'd5, 16'd3, 64, 0); drive(64);    // other ethertypes
    mk(OWN, 16'hAEFF, 8'h10, 8'd5, 16'd3, 64, 0); drive(64);
    mk(OWN, 16'h5101, 8'h10, 8'd5, 16'd3, 64, 0); drive(64);
    mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 13, 0); drive(13);    // runts
    mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 4, 0);  drive(4);
    expect_rd(4'd8, 32'h0, "filtered frames: no irq");
    expect_rd(4'd5, {errc, 8'(okc + 4), 8'd2, 2'd0, 6'd0}, "filtered frames: counters");
    if (reset_op !== 16'h4242) fail("filtered frames acted on");
    mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 64, 1); drive(64);    // bad FCS
    mk(OWN, 16'hAEFE, 8'h11, 8'd5, 16'd3, 64, 1); drive(64);    // bad FCS beats concat
    expect_irq(5'b00001, "bad fcs");
    mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 60, 0); drive(60);    // short
    expect_irq(5'b00100, "short frame");
    mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 65, 0); drive(65);    // long
    mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 200, 0); drive(200);
    expect_irq(5'b00100, "long frame");
    for (int r = 0; r < 4; r++) begin                            // payload_size > 40
      mk(OWN, 16'hAEFE, 8'h10, 8'd0,
         (r == 0) ? 16'd41 : (r == 1) ? 16'hFFFF : 16'($urandom) | 16'h0040, 64, 0);
      drive(64);
    end
    expect_irq(5'b00100, "payload size");
    mk(OWN, 16'hAEFE, 8'h20, 8'd5, 16'd3, 64, 0); drive(64);    // revision 2
    mk(OWN, 16'hAEFE, 8'h00, 8'd5, 16'd3, 64, 0); drive(64);    // revision 0
    expect_irq(5'b00100, "revision");
    mk(OWN, 16'hAEFE, 8'h11, 8'd5, 16'd3, 64, 0); drive(64);    // concatenated
    expect_irq(5'b10000, "concatenation");
    for (int r = 0; r < 12; r++) begin                           // unknown msgtypes
      v[7:0] = (r < 3) ? 8'(r + 1) : (r == 3) ? 8'hFF : (r == 4) ? 8'd7 : 8'($urandom) | 8'h08;
      mk(OWN, 16'hAEFE, 8'h1E, v[7:0], 16'd3, 64, 0); drive(64);
    end
    expect_irq(5'b00010, "msgtype");
    no_tx(40, "error frames");
    // ERR on the irq pin
    wr(A_IRQ_ENABLE, 1 << IRQ_ERR); err_en = 1;
    mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 64, 1); drive(64);
    expect_irq(5'b00001, "bad fcs, enabled");
    // per-bit irq clear
    mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 64, 1); drive(64);
    mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 60, 0); drive(60);
    mk(OWN, 16'hAEFE, 8'h11, 8'd5, 16'd3, 64, 0); drive(64);
    mk(OWN, 16'hAEFE, 8'h10, 8'd9, 16'd3, 64, 0); drive(64);
    for (int i = 0; i < 7; i++) inject(21'(i));
    repeat (600) @(negedge PCLK);
    for (int b = 0; b < 5; b++) begin
      expect_rd(4'd8, 32'h1F >> b << b, "irq per-bit clear");
      if (irq !== 1'b1) fail("irq pin with ERRORS set");
      cpu_wr(4'd8, 32'h1 << b);
    end
    wr(A_IRQ_STATUS, 1 << IRQ_ERR);
    rd_exp(A_IRQ_STATUS, 0);
    if (irq) fail("irq after clear");
    wr(A_IRQ_ENABLE, 0); err_en = 0;
    // error counter wrap
    for (int i = 0; i < 260; i++) begin
      mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 64, 1); drive(64, 1);
    end
    cpu_wr(4'd8, 32'h1F);

    // ---------------- reset while receiving and while transmitting
    inject(21'h7);
    repeat (20) @(negedge PCLK);
    mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 64, 0);
    for (int i = 0; i < 30; i++) begin @(negedge PCLK); rx_dv = 1; rx_d = fr[i]; end
    PRESETN = 0;
    @(negedge PCLK); rx_dv = 0;
    repeat (2) @(negedge PCLK);
    PRESETN = 1;
    repeat (2) @(negedge PCLK);
    check_reset_values();
    rd_exp(A_IRQ_STATUS, 0);
    expect_rd(4'd5, 32'h0, "status after reset");
    expect_rd(4'd12, 32'h0, "tx status after reset");
    rnd_pay(); {pb[0], pb[1], pb[2]} = {16'h9999, 8'h01};
    n0 = ncap; send(8'd5, 16'd3);
    wait_tx(n0, "after reset");
    repeat (80) @(negedge PCLK);

    // leave ERR pending (masked) for the final reset
    mk(OWN, 16'hAEFE, 8'h10, 8'd5, 16'd3, 64, 1); drive(64);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
  endtask
