// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// ^ TB-internal coverage points are never collected (run_cov scores only
// the RTL); per-statement counters on this TB's AES functions blow up the
// C++ build. Comment-only for iverilog.
// ============================================================================
// Self-checking testbench for HDCP_2_3_Content_Protection_top -- the TB plays
// the HDCP receiver: it answers AKE / pairing / locality / SKE messages,
// computes ks, E_km, H', L' and the AES-128-CTR keystream with its own
// AES-128 (anchored by the FIPS-197 known-answer vector) and decrypts the
// pixel stream.
// Covered: full authentication without and with a repeater, every failure
// (pairing ack, locality value, locality timeout and the last allowed
// clock, unexpected message type in each wait state, message timeouts and
// the last allowed clock), CTRL.start ignored while busy and restarting a
// session from AUTH, irq clear (and an error in the same clock), the
// register window (km / ks bytes, all registers), pixel backpressure,
// keystream exhaustion after 65536 words, reset mid-authentication.
// ============================================================================
`timescale 1ns/1ps
module HDCP_2_3_Content_Protection_tb;

  localparam int MSG_TO = 255;

  logic         clk = 1'b0, rst_n = 1'b0;
  logic         reg_we = 1'b0;
  logic [2:0]   reg_addr = 3'h0;
  logic [7:0]   reg_wdata = 8'h0, reg_rdata;
  logic         txm_valid, txm_ready = 1'b0;
  logic [3:0]   txm_type;
  logic [127:0] txm_data;
  logic         rxm_valid = 1'b0, rxm_ready;
  logic [3:0]   rxm_type = 4'h0;
  logic [127:0] rxm_data = 128'h0;
  logic         pix_valid = 1'b0, pix_ready;
  logic [31:0]  pix_data = 32'h0;
  logic         enc_valid, enc_ready = 1'b1;
  logic [31:0]  enc_data;
  logic         irq;
  int           errors = 0;

  HDCP_2_3_Content_Protection_top #(.MSG_TIMEOUT(MSG_TO)) dut (
    .clk(clk), .rst_n(rst_n),
    .reg_we(reg_we), .reg_addr(reg_addr),
    .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
    .txm_valid(txm_valid), .txm_ready(txm_ready),
    .txm_type(txm_type), .txm_data(txm_data),
    .rxm_valid(rxm_valid), .rxm_ready(rxm_ready),
    .rxm_type(rxm_type), .rxm_data(rxm_data),
    .pix_valid(pix_valid), .pix_ready(pix_ready), .pix_data(pix_data),
    .enc_valid(enc_valid), .enc_ready(enc_ready), .enc_data(enc_data),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // ====================================================================
  // TB-side AES-128 (FIPS-197) encrypt -- independent reference used to
  // derive ks / E_km / H' / CTR keystream on the receiver side.
  // ====================================================================
  // AES S-box as one packed constant (entry x at bits [8x+7:8x]); a
  // 256-arm case inside a function is rejected by Verilator 5.052 (IMPURE)
  localparam logic [2047:0] SBOX_V = {
    256'h16bb54b00f2d99416842e6bf0d89a18cdf2855cee9871e9b948ed9691198f8e1,
    256'h9e1dc186b95735610ef6034866b53e708a8bbd4b1f74dde8c6b4a61c2e2578ba,
    256'h08ae7a65eaf4566ca94ed58d6d37c8e779e4959162acd3c25c2406490a3a32e0,
    256'hdb0b5ede14b8ee4688902a22dc4f816073195d643d7ea7c41744975fec130ccd,
    256'hd2f3ff1021dab6bcf5389d928f40a351a89f3c507f02f94585334d43fbaaefd0,
    256'hcf584c4a39becb6a5bb1fc20ed00d153842fe329b3d63b52a05a6e1b1a2c8309,
    256'h75b227ebe28012079a059618c323c7041531d871f1e5a534ccf73f362693fdb7,
    256'hc072a49cafa2d4adf04759fa7dc982ca76abd7fe2b670130c56f6bf27b777c63
  };
  function automatic logic [7:0] sbox(input logic [7:0] x);
    return SBOX_V[8*x +: 8];
  endfunction

  function automatic logic [7:0] xtime(input logic [7:0] a);
    xtime = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
  endfunction
  function automatic logic [7:0] mul2(input logic [7:0] a); mul2 = xtime(a); endfunction
  function automatic logic [7:0] mul3(input logic [7:0] a); mul3 = xtime(a) ^ a; endfunction

  function automatic logic [127:0] sub_bytes(input logic [127:0] s);
    for (int i = 0; i < 16; i++) sub_bytes[127-8*i -: 8] = sbox(s[127-8*i -: 8]);
  endfunction

  function automatic logic [127:0] shift_rows(input logic [127:0] s);
    logic [7:0] b [0:15];
    begin
      for (int i = 0; i < 16; i++) b[i] = s[127-8*i -: 8];
      shift_rows = {b[0], b[5], b[10], b[15], b[4], b[9], b[14], b[3],
                    b[8], b[13], b[2], b[7], b[12], b[1], b[6], b[11]};
    end
  endfunction

  function automatic logic [31:0] mix_col(input logic [31:0] c);
    logic [7:0] b0, b1, b2, b3;
    begin
      b0 = c[31:24]; b1 = c[23:16]; b2 = c[15:8]; b3 = c[7:0];
      mix_col = {mul2(b0) ^ mul3(b1) ^ b2 ^ b3,
                 b0 ^ mul2(b1) ^ mul3(b2) ^ b3,
                 b0 ^ b1 ^ mul2(b2) ^ mul3(b3),
                 mul3(b0) ^ b1 ^ b2 ^ mul2(b3)};
    end
  endfunction
  function automatic logic [127:0] mix_columns(input logic [127:0] s);
    mix_columns = {mix_col(s[127:96]), mix_col(s[95:64]),
                   mix_col(s[63:32]), mix_col(s[31:0])};
  endfunction

  function automatic logic [7:0] rcon(input logic [3:0] r);
    case (r)
      4'd1: rcon = 8'h01; 4'd2: rcon = 8'h02; 4'd3: rcon = 8'h04;
      4'd4: rcon = 8'h08; 4'd5: rcon = 8'h10; 4'd6: rcon = 8'h20;
      4'd7: rcon = 8'h40; 4'd8: rcon = 8'h80; 4'd9: rcon = 8'h1b;
      default: rcon = 8'h36;
    endcase
  endfunction

  function automatic logic [127:0] key_next(input logic [127:0] k,
                                            input logic [3:0] r);
    logic [31:0] w0, w1, w2, w3, t;
    begin
      w0 = k[127:96]; w1 = k[95:64]; w2 = k[63:32]; w3 = k[31:0];
      t  = {sbox(w3[23:16]), sbox(w3[15:8]), sbox(w3[7:0]), sbox(w3[31:24])}
           ^ {rcon(r), 24'h0};
      w0 = w0 ^ t;
      w1 = w1 ^ w0;
      w2 = w2 ^ w1;
      w3 = w3 ^ w2;
      key_next = {w0, w1, w2, w3};
    end
  endfunction

  function automatic logic [127:0] aes128_enc(input logic [127:0] key,
                                              input logic [127:0] pt);
    logic [127:0] rk, s;
    begin
      rk = key;
      s  = pt ^ rk;
      for (int r = 1; r <= 9; r++) begin
        rk = key_next(rk, r[3:0]);
        s  = mix_columns(shift_rows(sub_bytes(s))) ^ rk;
      end
      rk = key_next(rk, 4'd10);
      aes128_enc = shift_rows(sub_bytes(s)) ^ rk;
    end
  endfunction

  // ------------------------------------------------------------------
  // helpers
  // ------------------------------------------------------------------
  task automatic chk(input logic cond, input string msg);
    if (!cond) begin errors++; $display("ERROR: %s (t=%0t)", msg, $time); end
  endtask

  task automatic reg_write(input logic [2:0] a, input logic [7:0] d);
    @(negedge clk);
    reg_addr = a; reg_wdata = d; reg_we = 1'b1;
    @(negedge clk);
    reg_we = 1'b0;
  endtask

  task automatic reg_read(input logic [2:0] a, output logic [7:0] d);
    @(negedge clk);
    reg_addr = a;
    #1 d = reg_rdata;
  endtask

  // wait for a TX message, check its type, accept it after dly clocks
  // messages taken at the handshake (for tx_expect with ready held high)
  logic [127:0] tx_cap;
  logic [3:0]   tx_cap_t;
  int           tx_hs = 0;
  always @(posedge clk) if (txm_valid && txm_ready) begin
    tx_cap <= txm_data; tx_cap_t <= txm_type; tx_hs <= tx_hs + 1;
  end
  bit tx_direct = 0;          // tx_expect: ready already high when the message appears
  task automatic tx_expect(input logic [3:0] mtype, input int dly, output logic [127:0] data);
    int n, h0;
    n = 0;
    if (tx_direct) begin
      h0 = tx_hs;
      txm_ready = 1'b1;
      while (tx_hs == h0 && n < 100) begin @(negedge clk); n++; end
      txm_ready = 1'b0;
      chk(tx_hs != h0 && tx_cap_t == mtype, $sformatf("TX message type %0d (direct)", mtype));
      data = tx_cap;
    end else begin
      @(negedge clk);
      while (!txm_valid && n < 100) begin @(negedge clk); n++; end
      chk(txm_valid && txm_type == mtype, $sformatf("TX message type %0d", mtype));
      data = txm_data;
      repeat (dly) begin @(negedge clk); chk(txm_valid && txm_data == data, "TX message held"); end
      txm_ready = 1'b1;
      @(negedge clk);
      txm_ready = 1'b0;
    end
  endtask

  // send an RX message after dly clocks (accepted in the clock it is valid)
  task automatic rx_send(input logic [3:0] mtype, input logic [127:0] data, input int dly);
    repeat (dly) @(negedge clk);
    chk(rxm_ready, "receiver channel ready");
    rxm_type = mtype; rxm_data = data; rxm_valid = 1'b1;
    @(negedge clk);
    rxm_valid = 1'b0; rxm_data = $urandom;
  endtask

  task automatic state_is(input logic [3:0] st, input string msg);
    logic [7:0] r;
    reg_read(3'd6, r);
    chk(r == {4'h0, st}, msg);
  endtask

  // ------------------------------------------------------------------
  // receiver side of one authentication
  // ------------------------------------------------------------------
  localparam logic [3:0] MT_AKE_INIT = 4'd2, MT_AKE_CERT = 4'd3, MT_AKE_EKM = 4'd4,
                         MT_PAIR_ACK = 4'd7, MT_LC_INIT = 4'd9, MT_LC_RESP = 4'd10,
                         MT_SKE = 4'd11, MT_RPT_ACK = 4'd12;
  localparam logic [3:0] S_IDLE = 0, S_AKE_INIT = 1, S_AKE_CERT = 2, S_PAIR_TX = 3, S_PAIR_RX = 4,
                         S_LC_TX = 5, S_LC_WAIT = 6, S_SKE_TX = 7, S_RPT_WAIT = 8, S_AUTH = 9;

  logic [127:0] km, ks;
  logic [63:0]  rtx;
  logic [15:0]  ctr;
  int           irqs = 0;
  always @(posedge clk) if (irq) irqs++;

  task automatic set_km(input logic [127:0] k);
    for (int i = 0; i < 16; i++) begin
      reg_write(3'd4, 8'(i));
      reg_write(3'd5, k[8*i +: 8]);
    end
    km = k;
  endtask

  task automatic start;
    reg_write(3'd0, 8'h01);
  endtask

  // fail: 0 none, 1 pairing ack, 2 locality value, 3 locality timeout,
  //       4 bad type in AKE_CERT, 5 bad type in PAIR_RX, 6 bad type in LC_WAIT,
  //       7 bad type in RPT_WAIT, 8 timeout AKE_CERT, 9 timeout PAIR_RX,
  //       10 timeout RPT_WAIT
  // late: answer at the last clock the DUT still accepts
  task automatic auth(input logic rpt, input int fail, input logic late);
    logic [127:0] d, hpad;
    logic [31:0]  hrx;
    logic [63:0]  l;
    logic [7:0]   r;
    int           e0;
    e0 = errors;
    start;
    tx_expect(MT_AKE_INIT, $urandom_range(0, 3), d);
    chk(d[127:64] == 64'h0, "AKE_Init upper half");
    rtx = d[63:0];
    ks  = aes128_enc(km, {rtx, rtx});
    hrx = $urandom;
    hpad = {hrx, hrx, hrx, hrx};
    if (fail == 4) begin rx_send(MT_PAIR_ACK, 128'h0, 2); return_fail(4'b1000, "bad type in AKE_CERT"); end
    else if (fail == 8) begin
      repeat (MSG_TO + 1) @(negedge clk);
      state_is(S_IDLE, "AKE_CERT timeout"); return_fail(4'b0, "AKE_CERT timeout");
    end else begin
      rx_send(MT_AKE_CERT, {$urandom, hrx, $urandom, 31'($urandom), rpt}, late ? MSG_TO : 1);
      tx_expect(MT_AKE_EKM, $urandom_range(0, 3), d);
      chk(d == aes128_enc(hpad, km), "E_km");
      if (fail == 5) begin rx_send(MT_LC_RESP, 128'h0, 1); return_fail(4'b1000, "bad type in PAIR_RX"); end
      else if (fail == 9) begin
        repeat (MSG_TO + 1) @(negedge clk);
        state_is(S_IDLE, "PAIR_RX timeout"); return_fail(4'b0, "PAIR_RX timeout");
      end else begin
        d = aes128_enc(km, hpad);
        rx_send(MT_PAIR_ACK, {$urandom, $urandom, $urandom, d[31:0] ^ ((fail == 1) ? 32'h8000_0000 : 32'h0)},
                late ? MSG_TO : 1);
        if (fail == 1) return_fail(4'b0010, "pairing ack mismatch");
        else begin
          tx_expect(MT_LC_INIT, $urandom_range(0, 3), d);
          chk(d[127:64] == 64'h0, "LC_Init upper half");
          l = d[63:0];
          if (fail == 6) begin rx_send(MT_RPT_ACK, 128'h0, 1); return_fail(4'b1000, "bad type in LC_WAIT"); end
          else if (fail == 3) begin
            repeat (21) @(negedge clk);
            state_is(S_IDLE, "locality timeout"); return_fail(4'b0001, "locality timeout");
          end else begin
            rx_send(MT_LC_RESP, {$urandom, $urandom, l ^ ks[63:0] ^ ((fail == 2) ? 64'h1 : 64'h0)},
                    late ? 20 : 1);
            if (fail == 2) return_fail(4'b0100, "locality mismatch");
            else begin
              tx_expect(MT_SKE, $urandom_range(0, 3), d);
              chk(d == (ks ^ km), "SKE Eks");
              if (rpt) begin
                if (fail == 7) begin rx_send(MT_SKE, 128'h0, 1); return_fail(4'b1000, "bad type in RPT_WAIT"); end
                else if (fail == 10) begin
                  repeat (MSG_TO + 1) @(negedge clk);
                  state_is(S_IDLE, "RPT_WAIT timeout"); return_fail(4'b0, "RPT_WAIT timeout");
                end else rx_send(MT_RPT_ACK, {$urandom, $urandom, $urandom, $urandom}, late ? MSG_TO : 1);
              end
              if (fail == 0 || (fail >= 7 && !rpt)) begin
                state_is(S_AUTH, "authenticated");
                reg_read(3'd1, r);
                chk(r == {2'b00, 1'b0, rpt, 1'b0, 3'b111}, "STATUS authenticated");
                ctr = 0;
              end
            end
          end
        end
      end
    end
  endtask

  // after a failure: state IDLE, fail flag, error bits (timeouts: bit4)
  task automatic return_fail(input logic [3:0] bits, input string msg);
    logic [7:0] r;
    @(negedge clk);
    state_is(S_IDLE, {msg, ": back to IDLE"});
    reg_read(3'd3, r);
    chk(r == ((bits == 0) ? 8'h10 : {4'h0, bits}), {msg, ": ERR flags"});
    reg_read(3'd1, r);
    chk(r[3] && irq, {msg, ": fail + irq"});
    reg_write(3'd0, 8'h04);
    chk(!irq, {msg, ": irq cleared"});
  endtask

  // stream n pixel words, random gaps and enc_ready backpressure; every
  // check_every-th word decrypted and compared
  task automatic stream(input int n, input int check_every);
    logic [31:0] p [$];
    logic [15:0] c [$];
    logic [127:0] k;
    int sent, got;
    sent = 0; got = 0;
    fork
      begin
        while (sent < n) begin
          @(negedge clk);
          pix_valid = ($urandom_range(0, 7) != 0);
          pix_data = ($urandom_range(0, 15) == 0) ? 32'h0 :
                     ($urandom_range(0, 15) == 0) ? 32'hFFFF_FFFF : 32'($urandom);
          #1;
          if (pix_valid && pix_ready) begin p.push_back(pix_data); c.push_back(ctr); ctr++; sent++; end
        end
        @(negedge clk); pix_valid = 0;
      end
      begin
        while (got < n) begin
          @(negedge clk);
          enc_ready = (n < 1000) ? ($urandom_range(0, 3) != 0) : 1'b1;
          #1;
          if (enc_valid && enc_ready) begin
            if (check_every == 1 || got % check_every == 0 || got > n - 4) begin
              k = aes128_enc(ks, {rtx, 48'h0, c[0]});
              chk(enc_data == (p[0] ^ k[127:96]), "pixel decrypts");
            end
            void'(p.pop_front()); void'(c.pop_front());
            got++;
          end
        end
        @(negedge clk); enc_ready = 1;
      end
    join
  endtask

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  logic [7:0] r;
  logic [127:0] kat;

  initial begin
    // anchor the TB AES on the FIPS-197 vector
    kat = aes128_enc(128'h000102030405060708090a0b0c0d0e0f, 128'h00112233445566778899aabbccddeeff);
    chk(kat == 128'h69c4e0d86a7b0430d8cdb78070b4c55a, "TB AES FIPS-197 vector");

    repeat (3) @(negedge clk);
    chk(!irq && !txm_valid && !rxm_ready && !pix_ready && !enc_valid, "reset outputs");
    rst_n = 1;

    // ---- register window ----
    reg_read(3'd2, r); chk(r == 8'h23, "version");
    reg_read(3'd0, r); chk(r == 8'h00, "CTRL reads 0");
    reg_read(3'd1, r); chk(r == 8'h00, "STATUS idle");
    set_km({128{1'b1}});
    for (int i = 0; i < 16; i++) begin reg_write(3'd4, 8'(i)); reg_read(3'd5, r); chk(r == 8'hFF, "km byte"); end
    reg_read(3'd4, r); chk(r == 8'h0F, "KMIDX");
    set_km(128'h0);
    set_km(128'h2b7e1516_28aed2a6_abf71588_09cf4f3c);
    reg_write(3'd0, 8'h00);                          // CTRL with no action
    for (int a = 1; a < 8; a++) if (a != 4 && a != 5) reg_write(3'(a), 8'hFF);  // read-only
    reg_read(3'd2, r); chk(r == 8'h23, "version is read-only");
    reg_read(3'd3, r); chk(r == 8'h00, "ERR is read-only");

    // ---- full authentication, no repeater; pixels ----
    auth(0, 0, 0);
    for (int i = 0; i < 16; i++) begin reg_write(3'd4, 8'(i)); reg_read(3'd7, r); chk(r == ks[8*i +: 8], "ks byte"); end
    stream(300, 1);
    // CTRL.start while authenticated: a new session with a new rtx
    reg_write(3'd0, 8'h00);
    auth(1, 0, 0);                                   // repeater
    stream(50, 1);
    // ---- start ignored while busy ----
    start;
    @(negedge clk);
    start;                                           // in AKE_INIT: ignored
    state_is(S_AKE_INIT, "start ignored while busy");
    tx_expect(MT_AKE_INIT, 0, kat);
    rx_send(MT_AKE_CERT, 128'h0, 2);
    start;                                           // in PAIR_TX: ignored
    state_is(S_PAIR_TX, "start ignored in PAIR_TX");
    rst_n = 0; @(negedge clk);                       // reset mid-authentication
    chk(!irq && !txm_valid && !rxm_ready, "reset mid-auth");
    rst_n = 1;
    set_km(128'hffeeddcc_bbaa9988_77665544_33221100);

    // ---- answers at the last allowed clock ----
    auth(1, 0, 1);
    stream(20, 1);

    // ---- more sessions (fresh nonces) ----
    repeat (4) auth($urandom_range(0, 1), 0, 0);

    // ---- every failure ----
    auth(0, 1, 0);
    auth(0, 2, 0);
    auth(0, 3, 0);
    auth(1, 4, 0);
    auth(1, 5, 0);
    auth(1, 6, 0);
    auth(1, 7, 0);
    auth(0, 8, 0);
    auth(0, 9, 0);
    auth(1, 10, 0);
    // error in the same clock as an irq clear: the error wins
    auth(0, 0, 0);
    start;
    tx_expect(MT_AKE_INIT, 0, kat);
    repeat (MSG_TO - 1) @(negedge clk);
    reg_write(3'd0, 8'h04);                          // lands with the timeout
    reg_read(3'd3, r); chk(r == 8'h10, "error set wins over clear");
    reg_write(3'd0, 8'h04);

    // ---- keystream exhaustion ----
    auth(0, 0, 0);
    stream(65536, 4096);
    @(negedge clk);
    chk(!pix_ready && irq, "keystream exhausted");
    reg_read(3'd3, r); chk(r == 8'h20, "ERR exhausted");
    reg_read(3'd1, r); chk(r[5], "STATUS exhausted");
    pix_valid = 1; repeat (5) @(negedge clk); pix_valid = 0;
    chk(!enc_valid, "no more pixels");
    auth(0, 0, 0);                                   // a new session re-keys
    chk(!irq, "new session clears the error");
    stream(10, 1);

    // every transmitter message taken in the clock it appears (ready held
    // high), for a plain receiver and a repeater
    tx_direct = 1;
    auth(0, 0, 0);
    auth(1, 0, 0);
    tx_direct = 0;

    if (errors == 0) $display("TEST PASSED: HDCP_2_3_Content_Protection");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #50000000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
