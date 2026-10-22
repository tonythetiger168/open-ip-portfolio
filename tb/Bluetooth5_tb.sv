// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for Bluetooth5_top -- a BLE central / scanner
// model on the 1 bit/clk baseband.
// Covered: advertising (ADV_IND payload from the host register file, adv_en
// off), SCAN_REQ / SCAN_RSP (scan_en off), every advertising PDU type
// (ignored or irq), bad CRC, oversize length, CONNECT_REQ of the wrong
// length, connection setup (access address, CRC init, interval, channel
// selection with and without the mod-37 wrap, hopping), SN / NESN
// acknowledgement in all four combinations, reserved LLID, missed events
// with peripheral latency (keepalive), supervision timeout back to
// advertising, timer / counter wrap, reset during a transmission.
`timescale 1ns/1ps
module Bluetooth5_tb;

  localparam int ADV_INTV = 600;
  localparam logic [31:0] ADV_AA   = 32'h8E89BED6;
  localparam logic [23:0] ADV_CRCI = 24'h555555;
  localparam logic [6:0]  ADV_SEED = 7'h25;

  logic       clk = 0, rst_n = 0;
  logic       rxd = 0;
  logic       txd, tx_act, irq;
  logic       cfg_we = 0;
  logic [4:0] cfg_addr = 0;
  logic [7:0] cfg_wdata = 0;

  Bluetooth5_top #(.ADV_INTV(ADV_INTV)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd), .tx_act(tx_act),
    .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .irq(irq)
  );

  always #5 clk = ~clk;

  int errors = 0;
  task automatic check(input logic cond, input string msg);
    if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
  endtask

  // ---------------------------------------------------------------
  // reference whitening / CRC24
  // ---------------------------------------------------------------
  function automatic logic [6:0] wnext(input logic [6:0] l);
    wnext = {l[5:0], l[6] ^ l[3]};
  endfunction
  function automatic logic [23:0] cbit(input logic [23:0] c, input logic b);
    cbit = (c[0] ^ b) ? ((c >> 1) ^ 24'h00065B) : (c >> 1);
  endfunction
  function automatic logic [6:0] dseed(input int ch);
    dseed = 7'(ch) | 7'h01;
  endfunction

  // ---------------------------------------------------------------
  // irq counter, TX packet capture
  // ---------------------------------------------------------------
  int irq_cnt = 0;
  always @(posedge clk) if (irq) irq_cnt++;

  logic       cap [0:511];
  int         cap_n = 0;
  logic       pkt [0:511];
  int         pkt_n = 0, pkt_cnt = 0;
  always @(negedge clk) begin
    if (tx_act) begin
      cap[cap_n] = txd;
      cap_n++;
    end else if (cap_n > 0) begin
      for (int i = 0; i < cap_n; i++) pkt[i] = cap[i];
      pkt_n = cap_n;
      cap_n = 0;
      pkt_cnt++;
    end
  end

  // decoded last packet
  logic       d_ok;
  logic [7:0] d_hdr, d_len;
  logic [7:0] d_pay [0:15];

  task automatic decode(input logic [31:0] aa, input logic [23:0] ci, input logic [6:0] seed);
    logic [6:0]  l;
    logic [23:0] c;
    logic [7:0]  by;
    logic        b;
    int          k, nb;
    d_ok = 1;
    by = aa[0] ? 8'h55 : 8'hAA;
    for (int j = 0; j < 8; j++) if (pkt[j] !== by[j]) d_ok = 0;
    for (int j = 0; j < 32; j++) if (pkt[8 + j] !== aa[j]) d_ok = 0;
    l = seed; c = ci; k = 40;
    for (int i = 0; i < 18; i++) begin           // header, len, up to 16 payload bytes
      if (i < 2 || i < 2 + d_len) begin
        for (int j = 0; j < 8; j++) begin
          b = pkt[k] ^ l[6]; l = wnext(l); c = cbit(c, b); by[j] = b; k++;
        end
        if (i == 0) d_hdr = by;
        else if (i == 1) begin d_len = by; if (by > 16) d_ok = 0; end
        else d_pay[i - 2] = by;
      end
      if (i == 0) d_len = 8'd0;
    end
    for (int j = 0; j < 24; j++) begin
      b = pkt[k] ^ l[6]; l = wnext(l); k++;
      if (b !== c[j]) d_ok = 0;
    end
    nb = k;
    if (pkt_n != nb) d_ok = 0;
  endtask

  // wait for the next TX packet to start within tmo clocks, then for its
  // end (got = 0 when none starts)
  task automatic next_pkt(input int tmo, output logic got);
    int c0;
    c0 = pkt_cnt; got = 0;
    for (int t = 0; t < tmo && !got; t++) begin
      @(negedge clk);
      if (tx_act || pkt_cnt != c0) got = 1;
    end
    if (got) while (pkt_cnt == c0) @(negedge clk);
  endtask

  task automatic wait_tx_idle;
    while (tx_act) @(negedge clk);
    @(negedge clk);
  endtask

  // ---------------------------------------------------------------
  // central / scanner transmitter (1 bit per clock)
  // ---------------------------------------------------------------
  logic [7:0] tpay [0:15];

  task automatic send_bit(input logic b);
    @(negedge clk) rxd = b;
  endtask

  // npay payload bytes from tpay; len_f is the length field sent
  task automatic c_send(input logic [31:0] aa, input logic [23:0] ci, input logic [6:0] seed,
                        input logic [7:0] hdr, input logic [7:0] len_f, input int npay,
                        input logic bad_crc);
    logic [6:0]  l;
    logic [23:0] c;
    logic [7:0]  by;
    logic        b;
    by = aa[0] ? 8'h55 : 8'hAA;
    for (int j = 0; j < 8; j++) send_bit(by[j]);
    for (int j = 0; j < 32; j++) send_bit(aa[j]);
    l = seed; c = ci;
    for (int i = 0; i < 2 + npay; i++) begin
      by = (i == 0) ? hdr : (i == 1) ? len_f : tpay[i - 2];
      for (int j = 0; j < 8; j++) begin
        b = by[j]; c = cbit(c, b); send_bit(b ^ l[6]); l = wnext(l);
      end
    end
    if (bad_crc) c[5] = ~c[5];
    for (int j = 0; j < 24; j++) begin send_bit(c[j] ^ l[6]); l = wnext(l); end
    @(negedge clk) rxd = 0;
  endtask

  task automatic cfg_write(input logic [4:0] a, input logic [7:0] d);
    @(negedge clk); cfg_we = 1; cfg_addr = a; cfg_wdata = d;
    @(negedge clk); cfg_we = 0;
  endtask

  // ---------------------------------------------------------------
  // advertising helpers
  // ---------------------------------------------------------------
  logic [7:0] adv_model [0:15];

  // wait for the next ADV_IND and check it
  task automatic expect_adv;
    logic got;
    next_pkt(3 * ADV_INTV, got);
    check(got, "ADV_IND expected");
    decode(ADV_AA, ADV_CRCI, ADV_SEED);
    check(d_ok && d_hdr == 8'h00 && d_len == 8'd16, "ADV_IND format");
    for (int i = 0; i < 16; i++) check(d_pay[i] == adv_model[i], "ADV_IND payload");
  endtask

  // send an advertising-channel PDU right after the next ADV_IND
  task automatic adv_pdu(input logic [7:0] hdr, input logic [7:0] len_f, input int npay,
                         input logic bad_crc);
    expect_adv;
    @(negedge clk);
    c_send(ADV_AA, ADV_CRCI, ADV_SEED, hdr, len_f, npay, bad_crc);
  endtask

  task automatic expect_irq(input int c0, input int n, input string msg);
    repeat (4) @(negedge clk);
    check(irq_cnt == c0 + n, msg);
  endtask

  // ---------------------------------------------------------------
  // connection helpers (central side model of the peripheral)
  // ---------------------------------------------------------------
  logic [31:0] caa;
  logic [23:0] cci;
  int          c_intv, c_lat, c_tmo, c_hop, dch;
  logic        p_rx_sn, p_tx_sn;      // peripheral model: NESN / SN
  int          missed, bnd0;
  int          bnd_cnt = 0;
  always @(posedge clk)
    if (dut.ll_state == 1'b1 && dut.conn_timer >= dut.conn_interval) bnd_cnt++;

  task automatic wait_bnd;
    int b0;
    b0 = bnd_cnt;
    while (bnd_cnt == b0) @(negedge clk);
  endtask

  // CONNECT_REQ after the next ADV_IND
  task automatic connect(input logic [31:0] aa, input logic [23:0] ci, input logic [15:0] intv,
                         input logic [15:0] lat, input logic [15:0] tmo, input logic [7:0] hop,
                         input logic [7:0] ch);
    {tpay[3], tpay[2], tpay[1], tpay[0]} = aa;
    {tpay[6], tpay[5], tpay[4]} = ci;
    {tpay[8], tpay[7]} = intv;
    {tpay[10], tpay[9]} = lat;
    {tpay[12], tpay[11]} = tmo;
    tpay[13] = hop;
    tpay[14] = ch;
    adv_pdu(8'h05, 8'd15, 15, 0);
    caa = aa; cci = ci; c_intv = intv; c_lat = lat; c_tmo = tmo; c_hop = hop[4:0];
    dch = ch[5:0] % 37;
    p_rx_sn = 0; p_tx_sn = 0; missed = 0; bnd0 = bnd_cnt;
    @(negedge clk); @(negedge clk);
    check(dut.ll_state == 1'b1, "connected");
  endtask

  // check a received empty data PDU against the model
  task automatic check_empty(input string msg);
    decode(caa, cci, dseed(dch));
    check(d_ok && d_len == 0 && d_hdr == {4'h0, p_tx_sn, p_rx_sn, 2'b01}, msg);
    if (!(d_ok && d_len == 0 && d_hdr == {4'h0, p_tx_sn, p_rx_sn, 2'b01}))
      $display("  got ok=%b len=%0d hdr=%h n=%0d exp hdr=%h", d_ok, d_len, d_hdr, pkt_n, {4'h0, p_tx_sn, p_rx_sn, 2'b01});
  endtask

  // one connection event: central PDU (llid, sn, nesn, npay random bytes)
  // and the peripheral's empty-PDU answer
  task automatic event_tx(input logic [1:0] llid, input logic sn, input logic nesn, input int npay,
                          input logic bad_crc);
    logic got;
    int   c0;
    for (int i = 0; i < npay; i++) tpay[i] = $urandom;
    c0 = irq_cnt;
    c_send(caa, cci, dseed(dch), {4'h0, sn, nesn, llid}, 8'(npay), npay, bad_crc);
    if (bad_crc || llid == 2'b00) begin
      next_pkt(30, got);
      check(!got, "no answer to a bad PDU");
      check(irq_cnt == c0 + 1, "irq on a bad data PDU");
      if (!bad_crc) missed = 0;
      else missed++;
    end else begin
      if (sn == p_rx_sn) p_rx_sn = ~p_rx_sn;
      if (nesn != p_tx_sn) p_tx_sn = ~p_tx_sn;
      next_pkt(30, got);
      check(got, "data PDU acknowledged");
      check_empty("empty PDU answer");
      missed = 0;
    end
  endtask

  // advance to the next connection event; expect a keepalive when the
  // event just ended was missed and more than c_lat events were missed
  task automatic next_event(input logic was_missed);
    logic got;
    int   m0;
    m0 = missed;
    if (was_missed) missed++;
    wait_bnd;
    dch = (dch + c_hop) % 37;
    if (was_missed && m0 >= c_lat) begin
      next_pkt(120, got);
      check(got, "keepalive");
      check_empty("keepalive format");
    end else begin
      repeat (3) @(negedge clk);
      check(!tx_act, "no keepalive within latency");
    end
  endtask

  // ---------------------------------------------------------------
  // stimulus
  // ---------------------------------------------------------------
  logic got;
  int   c0;

  initial begin
    for (int i = 0; i < 16; i++) adv_model[i] = 8'hB0 + 8'(i);
    repeat (3) @(negedge clk);
    check(!tx_act && !txd && !irq, "reset outputs");
    rst_n = 1;

    // ---- advertising with the reset payload, then a new payload ----
    expect_adv;
    for (int i = 0; i < 16; i++) begin
      adv_model[i] = (i == 0) ? 8'hFF : (i == 1) ? 8'h00 : 8'($urandom);
      cfg_write(5'(i), adv_model[i]);
    end
    cfg_write(5'd18, 8'hFF);                    // unmapped addresses
    cfg_write(5'd31, 8'h5A);
    expect_adv; expect_adv;
    for (int p = 0; p < 3; p++) begin           // all ones, all zeros, random
      for (int i = 0; i < 16; i++) begin
        adv_model[i] = (p == 0) ? 8'hFF : (p == 1) ? 8'h00 : 8'($urandom);
        cfg_write(5'(i), adv_model[i]);
      end
      expect_adv;
    end

    // ---- adv_en off / on ----
    cfg_write(5'd16, 8'h00);
    next_pkt(3 * ADV_INTV, got); check(!got, "adv_en off");
    cfg_write(5'd16, 8'h01);
    expect_adv;

    // ---- SCAN_REQ / SCAN_RSP ----
    for (int i = 0; i < 12; i++) tpay[i] = $urandom;
    adv_pdu(8'h03, 8'd12, 12, 0);
    next_pkt(60, got); check(got, "SCAN_RSP");
    decode(ADV_AA, ADV_CRCI, ADV_SEED);
    check(d_ok && d_hdr == 8'h04 && d_len == 8'd16, "SCAN_RSP format");
    for (int i = 0; i < 16; i++) check(d_pay[i] == 8'h53 + 8'(i), "SCAN_RSP payload");
    cfg_write(5'd17, 8'h00);
    c0 = irq_cnt;
    adv_pdu(8'h03, 8'd12, 12, 0);
    next_pkt(60, got); check(!got, "scan_en off");
    check(irq_cnt == c0, "no irq for a disabled SCAN_REQ");
    cfg_write(5'd17, 8'h01);

    // ---- other advertising PDU types: ignored or irq ----
    for (int t = 0; t < 16; t++) begin
      if (t != 3 && t != 5) begin
        c0 = irq_cnt;
        for (int i = 0; i < 6; i++) tpay[i] = $urandom;
        adv_pdu(8'(t) | 8'hF0, 8'd6, 6, 0);
        expect_irq(c0, (t > 6) ? 1 : 0, "advertising PDU type");
        next_pkt(40, got); check(!got, "no answer to an advertising PDU");
      end
    end

    // ---- bad CRC, empty / oversize length, wrong CONNECT_REQ length ----
    c0 = irq_cnt; adv_pdu(8'h03, 8'd12, 12, 1); expect_irq(c0, 1, "bad CRC irq");
    next_pkt(40, got); check(!got, "no SCAN_RSP for a bad CRC");
    c0 = irq_cnt; adv_pdu(8'h02, 8'd0, 0, 0);  expect_irq(c0, 0, "empty PDU");
    c0 = irq_cnt; adv_pdu(8'h02, 8'd17, 4, 0); expect_irq(c0, 1, "len 17 irq");
    c0 = irq_cnt; adv_pdu(8'h02, 8'd255, 4, 0); expect_irq(c0, 1, "len 255 irq");
    for (int i = 0; i < 16; i++) tpay[i] = $urandom;
    c0 = irq_cnt; adv_pdu(8'h05, 8'd14, 14, 0); expect_irq(c0, 1, "CONNECT_REQ len 14");
    tpay[15] = 8'hFF;
    c0 = irq_cnt; adv_pdu(8'h05, 8'd16, 16, 0); expect_irq(c0, 1, "CONNECT_REQ len 16");
    tpay[15] = 8'h00;
    c0 = irq_cnt; adv_pdu(8'h02, 8'd16, 16, 0); expect_irq(c0, 0, "ADV_NONCONN_IND len 16");
    check(dut.ll_state == 1'b0, "still advertising");

    // ---- connection 1: interval 400, latency 0, no timeout, hop 7, ch 9 ----
    connect(32'hC1C2C3C4, 24'h123456, 16'd400, 16'd0, 16'd0, 8'h07, 8'd9);
    // silent central for a while: only keepalives on the connection AA
    c0 = pkt_cnt;
    repeat (2 * ADV_INTV) @(negedge clk);
    check(pkt_cnt > c0, "keepalives while the central is silent");
    for (int j = 0; j < 32; j++) check(pkt[8 + j] === caa[j], "no advertising while connected");
    // resync to an event boundary (channel = chan + hop * events, mod 37),
    // then talk in every event, sweeping the SN / NESN combinations
    wait_bnd;
    dch = (9 + 7 * (bnd_cnt - bnd0)) % 37;
    next_pkt(10, got);                               // keepalive of the missed event
    missed = 0;
    for (int e = 0; e < 40; e++) begin
      logic sn, nesn;
      sn = $urandom; nesn = $urandom;
      if (e < 4) begin sn = e[0]; nesn = e[1]; end
      event_tx(2'(1 + (e % 3)), sn, nesn, (e % 17), 0);
      next_event(0);
    end
    event_tx(2'b00, 0, 0, 2, 0);  next_event(0);   // reserved LLID (counts as traffic)
    event_tx(2'b01, 0, 0, 2, 1);  next_event(1);   // bad CRC: missed, latency 0 -> keepalive
    event_tx(2'b10, p_rx_sn, ~p_tx_sn, 3, 0);
    c0 = irq_cnt;
    c_send(caa, cci, dseed(dch), 8'h01, 8'd20, 0, 0); // oversize data PDU
    expect_irq(c0, 1, "data len 20 irq");
    next_pkt(10, got); check(!got, "oversize PDU not acknowledged");
    next_event(0);
    for (int e = 0; e < 4; e++) next_event(1);       // silent central: keepalive each event
    event_tx(2'b01, p_rx_sn, p_tx_sn, 0, 0);
    next_event(0);

    // ---- reset back to advertising ----
    rst_n = 0; repeat (3) @(negedge clk); rst_n = 1;
    for (int i = 0; i < 16; i++) adv_model[i] = 8'hB0 + 8'(i);

    // ---- connection 2: latency 2, timeout 6, channel 37 (wraps to 0), hop 31 ----
    connect(32'h3E3D3C3B, 24'hEDCBA9, 16'd300, 16'd2, 16'd6, 8'hFF, 8'd37);
    event_tx(2'b01, 0, 0, 1, 0);
    next_event(0);
    for (int e = 0; e < 4; e++) next_event(1);       // 1, 2 within latency; 3, 4 keepalive
    event_tx(2'b11, p_rx_sn, ~p_tx_sn, 2, 0);
    next_event(0);
    // six silent events -> supervision timeout
    c0 = irq_cnt;
    for (int e = 0; e < 5; e++) next_event(1);
    wait_bnd;
    expect_irq(c0, 1, "supervision timeout irq");
    check(dut.ll_state == 1'b0, "timeout -> advertising");
    expect_adv;

    // ---- connection 3: all-ones fields, timer wrap ----
    connect(32'hFFFF_FFFE, 24'hFFFFFF, 16'hFFFF, 16'hFFFF, 16'hFFFF, 8'hFF, 8'hFF);
    repeat (65600) @(negedge clk);
    rst_n = 0; repeat (3) @(negedge clk); rst_n = 1;

    // ---- connection 4: interval 0 (an event every clock), miss counter wrap ----
    connect(32'h1234_5679, 24'h000000, 16'd0, 16'hFFFF, 16'd0, 8'h00, 8'd40);
    repeat (40000) @(negedge clk);
    c_send(caa, cci, dseed(dch), 8'h01, 8'd0, 0, 0);
    p_rx_sn = 1;
    next_pkt(30, got); check(got, "answer at interval 0");
    check_empty("answer at interval 0");
    repeat (20) @(negedge clk);
    check(dut.miss < 16'd150, "miss counter cleared");

    // ---- connection 5: interval shorter than a keepalive; the timeout
    //      drops the keepalive request still pending ----
    rst_n = 0; repeat (3) @(negedge clk); rst_n = 1;
    connect(32'h5555_AAAB, 24'h0F0F0F, 16'd20, 16'd0, 16'd3, 8'h01, 8'd1);
    c0 = irq_cnt;
    while (dut.ll_state == 1'b1) @(negedge clk);
    expect_irq(c0, 1, "timeout with a keepalive pending");
    wait_tx_idle;
    expect_adv;

    // ---- reset during a transmission ----
    rst_n = 0; repeat (3) @(negedge clk); rst_n = 1;
    expect_adv;
    repeat (100) @(negedge clk);
    while (!tx_act) @(negedge clk);
    repeat (50) @(negedge clk);
    rst_n = 0; @(negedge clk);
    check(!tx_act && !txd, "reset mid-TX");
    repeat (2) @(negedge clk); rst_n = 1;
    expect_adv;

    if (errors == 0) $display("TEST PASSED: Bluetooth5");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
