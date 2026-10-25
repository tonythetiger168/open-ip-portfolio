// SPDX-License-Identifier: Apache-2.0
// FC_top testbench: two ports A and B cross-connected. The TB can take over
// A's receive line with an injector (its own 8b/10b encoder: ordered sets,
// frames with any ending, bad CRC, bad characters, raw bits) and can flip a
// bit on the line into B.
//  - host drivers send frames through tx_* (start / end delimiters, an
//    underrun at a chosen byte), and every frame sent pushes what the far
//    end must deliver (zero fill, status); frames the injector sends push
//    the same, computed from the bytes and the ending
//  - receive monitors compare rx_* and rx_frag with those queues
//  - credit: back-to-back traffic at every cfg_credit, a peer that returns
//    no R_RDY, R_RDYs nobody owed, credit_used and owed R_RDYs saturating
//  - long and over-long frames, receive byte counter saturation, resets
//    mid-frame
// The bound checker (tb/cov/FC_sva.sv) checks every output of both ports on
// every clock.
`timescale 1ns/1ps
module FC_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  // ---------------- ports: index 0 = A, 1 = B ----------------
  logic [1:0]       tx_valid = 0, tx_last = 0, tx_sofi = 0, tx_eoft = 0;
  logic [1:0][7:0]  tx_data = 0;
  logic [1:0][3:0]  cfg_credit = 0;
  wire  [1:0]       tx_ready, tx_done, tx_underrun, rx_valid, rx_last, rx_frag, rx_sync, err_code, err_word;
  wire  [1:0][3:0]  credit_used;
  wire  [1:0][7:0]  rx_data;
  wire  [1:0][4:0]  rx_stat;
  wire              a_tx, b_tx;
  logic             inj = 0, ij_bit = 0, flip = 0;
  wire              a_rx = inj ? ij_bit : b_tx;
  wire              b_rx = a_tx ^ flip;

  FC_top u_a (.clk(clk), .rst_n(rst_n), .tx_p(a_tx), .rx_p(a_rx), .cfg_credit(cfg_credit[0]),
    .tx_valid(tx_valid[0]), .tx_ready(tx_ready[0]), .tx_data(tx_data[0]), .tx_last(tx_last[0]),
    .tx_sofi(tx_sofi[0]), .tx_eoft(tx_eoft[0]), .tx_done(tx_done[0]), .tx_underrun(tx_underrun[0]),
    .credit_used(credit_used[0]), .rx_valid(rx_valid[0]), .rx_data(rx_data[0]), .rx_last(rx_last[0]),
    .rx_stat(rx_stat[0]), .rx_frag(rx_frag[0]), .rx_sync(rx_sync[0]), .err_code(err_code[0]), .err_word(err_word[0]));
  FC_top u_b (.clk(clk), .rst_n(rst_n), .tx_p(b_tx), .rx_p(b_rx), .cfg_credit(cfg_credit[1]),
    .tx_valid(tx_valid[1]), .tx_ready(tx_ready[1]), .tx_data(tx_data[1]), .tx_last(tx_last[1]),
    .tx_sofi(tx_sofi[1]), .tx_eoft(tx_eoft[1]), .tx_done(tx_done[1]), .tx_underrun(tx_underrun[1]),
    .credit_used(credit_used[1]), .rx_valid(rx_valid[1]), .rx_data(rx_data[1]), .rx_last(rx_last[1]),
    .rx_stat(rx_stat[1]), .rx_frag(rx_frag[1]), .rx_sync(rx_sync[1]), .err_code(err_code[1]), .err_word(err_word[1]));

  function automatic logic [31:0] crc_b(input logic [31:0] c, input logic [7:0] d);
    for (int i = 0; i < 8; i++) c = (c[0] ^ d[i]) ? (c >> 1) ^ 32'hEDB88320 : c >> 1;
    return c;
  endfunction

  // ---------------- expected receive queues ----------------
  // {frag, wild, last, stat[4:0], data}: wild takes any bytes up to a last
  // (or a fragment); frag expects rx_frag
  logic [15:0] q0 [$];
  logic [15:0] q1 [$];
  bit   [1:0]  chk = 2'b11;
  task automatic qpush(input int p, input logic [15:0] e);
    if (p == 0) q0.push_back(e); else q1.push_back(e);
  endtask
  function automatic int qsize(input int p);
    return p == 0 ? q0.size() : q1.size();
  endfunction
  function automatic logic [15:0] qfront(input int p);
    return p == 0 ? q0[0] : q1[0];
  endfunction
  task automatic qpop(input int p);
    if (p == 0) void'(q0.pop_front()); else void'(q1.pop_front());
  endtask
  // n bytes from fb[], ended as a frame with the given status bits; the last
  // 4 bytes are the CRC and are not delivered
  logic [7:0] fb [0:8191];
  task automatic push_frame(input int p, input int n, input bit sofi, input bit eoft, input bit abt);
    logic [31:0] c;
    c = '1;
    for (int i = 0; i < n; i++) c = crc_b(c, fb[i]);
    if (n < 5) qpush(p, 16'h8000);
    else for (int i = 0; i < n - 4; i++)
      qpush(p, {2'b00, i == n - 5, i == n - 5 ? {sofi, eoft, abt, n < 28 || n > 2140, c != 32'hDEBB20E3} : 5'd0, fb[i]});
  endtask

  // ---------------- receive monitors ----------------
  task automatic mon(input int p);
    logic [15:0] e;
    if (rx_frag[p]) begin
      if (!chk[p]) ;
      else if (qsize(p) == 0) fail($sformatf("port %0d: fragment with nothing expected", p));
      else begin
        e = qfront(p);
        if (!e[15] && !e[14]) fail($sformatf("port %0d: fragment, expected %h", p, e));
        qpop(p);
      end
    end
    if (rx_valid[p] && chk[p]) begin
      if (qsize(p) == 0) fail($sformatf("port %0d: rx %h with nothing expected", p, rx_data[p]));
      else begin
        e = qfront(p);
        if (e[14]) begin if (rx_last[p]) qpop(p); end
        else begin
          if (e[15] || rx_data[p] !== e[7:0] || rx_last[p] !== e[13] || (e[13] && rx_stat[p] !== e[12:8]))
            fail($sformatf("port %0d: rx %b %h %h, expected %h", p, rx_last[p], rx_stat[p], rx_data[p], e));
          qpop(p);
        end
      end
    end
  endtask
  always @(negedge clk) if (rst_n) begin mon(0); mon(1); end

  // ---------------- host drivers ----------------
  // per port: {underrun marker, sofi, eoft, last, data}; a frame with an
  // underrun ends with the marker instead of a last byte
  logic [11:0] h0 [$];
  logic [11:0] h1 [$];
  logic [1:0]  took = 0;
  function automatic int hsize(input int p);
    return p == 0 ? h0.size() : h1.size();
  endfunction
  task automatic hpush(input int p, input logic [11:0] e);
    if (p == 0) h0.push_back(e); else h1.push_back(e);
  endtask
  always @(posedge clk) took <= tx_valid & tx_ready;
  always @(negedge clk)
    for (int p = 0; p < 2; p++) begin : b_drv
      logic [11:0] e;
      if (!rst_n) begin if (p == 0) h0.delete(); else h1.delete(); end
      if ((took[p] || tx_underrun[p]) && hsize(p) != 0) begin if (p == 0) void'(h0.pop_front()); else void'(h1.pop_front()); end
      e = hsize(p) == 0 ? 12'h800 : p == 0 ? h0[0] : h1[0];
      tx_valid[p] = !e[11];
      {tx_sofi[p], tx_eoft[p], tx_last[p], tx_data[p]} = e[10:0];
    end
  task automatic idle_wait(input int p);
    while (hsize(p) != 0) @(negedge clk);
  endtask
  // port p sends n random bytes; ur: underrun at that byte
  task automatic send(input int p, input int n, input bit sofi, input bit eoft, input int ur = -1);
    int t;
    for (int i = 0; i < n; i++) fb[i] = $urandom;
    if (ur >= 0) begin
      for (int i = 0; i < ur; i++) hpush(p, {1'b0, sofi, eoft, 1'b0, fb[i]});
      hpush(p, 12'h800);
      qpush(1 - p, 16'h4000);
    end else begin
      for (int i = 0; i < n; i++) hpush(p, {1'b0, sofi, eoft, i == n - 1, fb[i]});
      t = n < 24 ? 24 : (n + 3) / 4 * 4;
      for (int i = n; i < t; i++) fb[i] = 8'h00;
      begin : b_crc
        logic [31:0] c;
        c = '1;
        for (int i = 0; i < t; i++) c = crc_b(c, fb[i]);
        c = ~c;
        for (int i = 0; i < 4; i++) fb[t + i] = c[8 * i +: 8];
      end
      push_frame(1 - p, t + 4, sofi, eoft, 0);
    end
  endtask

  // ---------------- injector (A's receive line) ----------------
  function automatic logic [11:0] c6(input int x);
    case (x)
      0: return 12'o4730;  1: return 12'o3542;  2: return 12'o5522;  3: return 12'o6161;
      4: return 12'o6512;  5: return 12'o5151;  6: return 12'o3131;  7: return 12'o7007;
      8: return 12'o7106;  9: return 12'o4545;  10: return 12'o2525; 11: return 12'o6464;
      12: return 12'o1515; 13: return 12'o5454; 14: return 12'o3434; 15: return 12'o2750;
      16: return 12'o3344; 17: return 12'o4343; 18: return 12'o2323; 19: return 12'o6262;
      20: return 12'o1313; 21: return 12'o5252; 22: return 12'o3232; 23: return 12'o7205;
      24: return 12'o6314; 25: return 12'o4646; 26: return 12'o2626; 27: return 12'o6611;
      28: return 12'o1616; 29: return 12'o5621; 30: return 12'o3641; 31: return 12'o5324;
      default: return 12'o1760;
    endcase
  endfunction
  function automatic logic [7:0] c4(input int y);
    case (y)
      0: return 8'hB4; 1: return 8'h99; 2: return 8'h55; 3: return 8'hC3; 4: return 8'hD2;
      5: return 8'hAA; 6: return 8'h66; 7: return 8'hE1; 8: return 8'h78;
      9: return 8'hB4; 10: return 8'h69; 11: return 8'hA5; 12: return 8'hC3; 13: return 8'hD2;
      14: return 8'h5A; 15: return 8'h96; default: return 8'h78;
    endcase
  endfunction
  function automatic int n1(input logic [5:0] v);
    n1 = 0;
    for (int i = 0; i < 6; i++) n1 += v[i];
  endfunction
  function automatic logic [10:0] code(input logic [7:0] d, input bit k, input bit rd);
    int x, y, y4;
    logic [11:0] p6;
    logic [7:0]  p4;
    logic [5:0]  s6;
    logic [3:0]  s4;
    x = d[4:0]; y = d[7:5];
    p6 = c6(k && x == 28 ? 32 : x);
    s6 = rd ? p6[5:0] : p6[11:6];
    if (n1(s6) != 3) rd = !rd;
    if (k && x == 28) y4 = 9 + y;
    else if (y == 7 && (k || (!rd && (x == 17 || x == 18 || x == 20)) || (rd && (x == 11 || x == 13 || x == 14)))) y4 = 8;
    else y4 = y;
    p4 = c4(y4);
    s4 = rd ? p4[3:0] : p4[7:4];
    if (n1({2'b0, s4}) != 2) rd = !rd;
    return {rd, s6, s4};
  endfunction

  localparam logic [23:0] IDLE = 24'h95B5B5, RRDY = 24'h954A4A, SOFI = 24'hB55656, SOFN = 24'hB53636;
  bit ij_rd = 0;
  task automatic ij_raw(input logic [9:0] b);
    for (int i = 9; i >= 0; i--) begin @(negedge clk); ij_bit = b[i]; end
  endtask
  task automatic ij_char(input bit k, input logic [7:0] d);
    logic [10:0] c;
    c = code(d, k, ij_rd);
    ij_rd = c[10];
    ij_raw(c[9:0]);
  endtask
  task automatic ij_os(input logic [23:0] o);
    ij_char(1, 8'hBC); ij_char(0, o[23:16]); ij_char(0, o[15:8]); ij_char(0, o[7:0]);
  endtask
  task automatic ij_idles(input int n);
    for (int i = 0; i < n; i++) ij_os(IDLE);
  endtask
  // an EOF: ty 8'hD5 (EOFn), 8'h75 (EOFt), 8'hF5 (EOFa); wrong: the other
  // first character than the running disparity asks for
  task automatic ij_eof(input logic [7:0] ty, input bit wrong = 0);
    logic [7:0] x;
    x = (ij_rd ^ wrong) ? 8'hB5 : 8'h95;
    ij_os({x, ty, ty});
  endtask
  // a frame of fb[0 .. n-1] plus its CRC (bad: one bit off); ends with
  // ending: 0 EOFn, 1 EOFt, 2 EOFa, 3 IDLE, 4 SOFn, 5 R_RDY, 6 an unknown set
  task automatic ij_frame(input int n, input bit sofi, input int ending, input bit bad = 0, input bit exp = 1);
    logic [31:0] c;
    c = '1;
    for (int i = 0; i < n; i++) c = crc_b(c, fb[i]);
    c = ~c ^ (bad ? 32'h0001_0000 : 32'h0);
    for (int i = 0; i < 4; i++) fb[n + i] = c[8 * i +: 8];
    if (exp) push_frame(0, n + 4, sofi, ending == 1, ending >= 2);
    ij_os(sofi ? SOFI : SOFN);
    for (int i = 0; i < n + 4; i++) ij_char(0, fb[i]);
    case (ending)
      0: ij_eof(8'hD5);
      1: ij_eof(8'h75);
      2: ij_eof(8'hF5);
      3: ij_os(IDLE);
      4: ij_os(SOFN);
      5: ij_os(RRDY);
      7: ;
      default: ij_os({8'($urandom), 8'($urandom), 8'h12});
    endcase
  endtask
  task automatic ij_crc(input int n);
    logic [31:0] c;
    c = '1;
    for (int i = 0; i < n; i++) c = crc_b(c, fb[i]);
    c = ~c;
    for (int i = 0; i < 4; i++) fb[n + i] = c[8 * i +: 8];
  endtask
  task automatic rnd_fb(input int n);
    for (int i = 0; i < n; i++) fb[i] = $urandom;
  endtask
  // take over A's line, align and sync
  task automatic ij_start;
    @(negedge clk);
    inj = 1; ij_rd = 0;
    ij_raw(10'($urandom));
    ij_idles(4);
    if (!rx_sync[0]) fail("A not in sync on the injector");
  endtask

  // ---------------- helpers ----------------
  bit hit_cu = 0, hit_rp = 0;
  always @(posedge clk) begin
    if (u_a.sof_tx && u_a.rr_rx && u_a.credit_used != 4'd0) hit_cu <= 1;
    if (u_a.f_end && u_a.sym_end && u_a.send_rr) hit_rp <= 1;
  end
  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask
  task automatic drain;
    idle_wait(0); idle_wait(1);
    wait_clk(1200);
    if (chk[0] && q0.size() != 0) fail($sformatf("port A: %0d bytes still expected", q0.size()));
    if (chk[1] && q1.size() != 0) fail($sformatf("port B: %0d bytes still expected", q1.size()));
  endtask
  task automatic do_reset;
    @(negedge clk);
    rst_n = 0;
    wait_clk(3);
    q0.delete(); q1.delete();
    inj = 0; flip = 0;
    rst_n = 1;
    wait_clk(400);
    if (!rx_sync[0] || !rx_sync[1]) fail("no sync after reset");
  endtask
  task automatic both_random(input int frames, input int maxn);
    for (int f = 0; f < frames; f++) begin
      send(0, 1 + $urandom % maxn, $urandom, $urandom);
      send(1, 1 + $urandom % maxn, $urandom, $urandom);
    end
  endtask

  initial begin
    wait_clk(3);
    rst_n = 1;
    wait_clk(400);
    if (!rx_sync[0] || !rx_sync[1]) fail("no sync after reset");

    // ---- frames both ways: lengths across the fill rules, no credit check
    for (int n = 1; n <= 32; n++) begin send(0, n, n[0], n[1]); send(1, 33 - n, n[1], n[0]); end
    both_random(10, 300);
    drain();
    // ---- every credit setting, back-to-back traffic
    for (int c = 1; c < 16; c++) begin
      cfg_credit[0] = c; cfg_credit[1] = 16 - c;
      both_random(3, c < 3 ? 400 : 60);
    end
    drain();
    cfg_credit = {4'd1, 4'd1};
    both_random(6, 200);
    drain();
    // ---- underruns at every position in a word
    for (int k = 1; k < 13; k++) begin send(0, 40, 0, 0, k); send(1, 40, 1, 1, k + 3); end
    send(0, 100, 1, 0);
    drain();
    // ---- the longest frame, an over-long one
    send(0, 2136, 1, 1);
    send(1, 2200, 0, 0);
    drain();
    // ---- a bit flipped on the line into B, mid-frame
    for (int k = 0; k < 6; k++) begin
      send(0, 200, 0, 0);
      q1.delete(); qpush(1, 16'h4000);
      while (!(u_a.ts == 3'd2 && u_a.tn > 5'd12)) @(negedge clk);
      wait_clk($urandom % 300);
      flip = 1; @(negedge clk); flip = 0;
      idle_wait(0);
      wait_clk(800);
      if (q1.size() != 0) begin
        if (q1[0] == 16'h4000) fail("B delivered nothing after a line error");
        q1.delete();
      end
    end
    send(0, 64, 0, 0);
    drain();

    // ---- injector on A's receive line
    cfg_credit[0] = 4'd0; cfg_credit[1] = 4'd2;
    ij_start();
    // good frames, both EOF first characters; an EOF outside a frame with
    // the other first character
    for (int i = 0; i < 6; i++) begin
      rnd_fb(64); ij_frame(24 + 4 * (i % 3), i[0], i % 2);
      ij_idles(2);
      rnd_fb(64); ij_frame(64, 1, 0); ij_eof(8'hD5, 1);
      ij_idles(2);
    end
    // CRC error, short, over-long, every abort
    rnd_fb(64); ij_frame(64, 0, 0, 1);
    rnd_fb(8); ij_frame(8, 1, 1);
    rnd_fb(2200); ij_frame(2200, 0, 0);
    for (int e = 2; e < 7; e++) begin
      rnd_fb(32); ij_frame(32, e[0], e);
      if (e == 4) push_frame(0, 0, 0, 0, 1);            // the SOFn that ended it, then IDLE
      ij_idles(1);
    end
    // fragments: SOF EOF, SOF one data word EOFt
    ij_os(SOFN); ij_eof(8'hD5); push_frame(0, 0, 0, 0, 0);
    ij_os(SOFN); ij_char(0, 8'h11); ij_char(0, 8'h22); ij_char(0, 8'h33); ij_char(0, 8'h44);
    ij_eof(8'h75); push_frame(0, 4, 0, 1, 0);
    // a data word and unknown ordered sets outside a frame
    ij_char(0, 8'h5A); ij_char(0, 8'hA5); ij_char(0, 8'h00); ij_char(0, 8'hFF);
    for (int i = 0; i < 8; i++) ij_os({8'($urandom), 8'($urandom), 8'h12});
    ij_idles(2);
    // the receive byte counter saturates
    rnd_fb(4100); ij_frame(4100, 1, 1);
    ij_idles(2);
    // bad characters in a frame (A drops alignment, then resyncs)
    for (int t = 0; t < 5; t++) begin
      rnd_fb(40);
      push_frame(0, 9 + t, 1, 0, 1);
      ij_os(SOFI);
      for (int i = 0; i < 9 + t; i++) ij_char(0, fb[i]);
      case (t)
        0: ij_raw(10'b1111111111);                       // code violation
        1: ij_raw(10'(code(8'h00, 0, !ij_rd)));          // disparity error
        2: ij_char(1, 8'hBC);                            // K28.5 inside a word
        3: ij_char(1, 8'h3C);                            // K28.1 starting a word
        default: ij_char(1, 8'hFD);                      // K29.7 inside a word
      endcase
      ij_idles(4);
    end
    // EOFa outside a frame; 27 and 2141 bytes (cut by the next K28.5 out
    // of place); an EOFt whose last character has the wrong disparity
    ij_eof(8'hF5);
    for (int i = 0; i < 2; i++) begin : b_odd
      int n;
      n = i == 0 ? 23 : 2137;
      rnd_fb(n);
      ij_crc(n);
      push_frame(0, n + 4, 1, 0, 1);
      ij_frame(n, 1, 0, 0, 0);
      ij_idles(4);
    end
    rnd_fb(36);
    ij_crc(36);
    push_frame(0, 40, 0, 0, 1);
    ij_frame(36, 0, 7, 0, 0);
    ij_char(1, 8'hBC); ij_char(0, ij_rd ? 8'hB5 : 8'h95); ij_char(0, 8'h75); ij_raw(10'(code(8'h75, 0, !ij_rd)));
    ij_idles(4);
    // a code error outside a frame, a fragment cut by a code error
    ij_raw(10'b0000000000);
    ij_idles(4);
    push_frame(0, 2, 0, 0, 1); ij_os(SOFN); ij_char(0, 8'h01); ij_char(0, 8'h02); ij_raw(10'b1111100000);
    ij_idles(4);
    if (q0.size() != 0) fail($sformatf("port A: %0d bytes still expected", q0.size()));

    // ---- credit against the injector: A waits, R_RDYs return it, extra R_RDYs
    cfg_credit[0] = 4'd2;
    for (int i = 0; i < 4; i++) send(0, 30, 0, 0);
    while (credit_used[0] != 4'd2) ij_idles(1);
    ij_idles(20);
    if (credit_used[0] != 4'd2) fail("A went past its credit");
    ij_raw(10'b0000000000);                              // lose alignment
    ij_os(IDLE); ij_os(RRDY); ij_idles(1);               // R_RDY before sync: ignored
    ij_idles(1);
    if (credit_used[0] != 4'd2) fail("an R_RDY before sync returned credit");
    for (int i = 0; i < 6; i++) ij_os(RRDY);
    while (hsize(0) != 0) ij_idles(1);
    ij_idles(20);
    for (int i = 0; i < 4; i++) ij_os(RRDY);
    ij_idles(2);
    if (credit_used[0] != 4'd0) fail($sformatf("credit_used %0d after the R_RDYs", credit_used[0]));
    // cfg_credit 0: credit_used saturates
    cfg_credit[0] = 4'd0;
    for (int i = 0; i < 18; i++) send(0, 4, 0, 0);
    while (hsize(0) != 0) ij_idles(1);
    ij_idles(10);
    if (credit_used[0] != 4'd15) fail("credit_used did not saturate");
    // an R_RDY received as a SOF goes out, a frame ending as an R_RDY goes
    // out: try every phase between the injector's words and A's
    for (int d = 0; d < 40 && !(hit_cu && hit_rp); d++) begin
      repeat (d + 1) begin @(negedge clk); ij_bit = 0; end
      ij_idles(4);
      for (int i = 0; i < 12; i++) send(0, 4, 0, 0);       // credit_used up
      while (hsize(0) != 0) ij_idles(1);
      send(0, 4, 0, 0);
      ij_idles(4);
      for (int i = 0; i < 10; i++) ij_os(RRDY);            // one of them as the SOF goes out
      ij_idles(12);
      send(0, 40, 0, 0);                                   // owed R_RDYs pile up meanwhile
      while (u_a.ts != 3'd2) ij_idles(1);
      for (int i = 0; i < 10; i++) begin ij_os(SOFN); ij_eof(8'hD5); push_frame(0, 0, 0, 0, 0); end
      ij_idles(8);
    end
    if (!(hit_cu && hit_rp)) fail($sformatf("no phase lined up the credit events (%b %b)", hit_cu, hit_rp));
    for (int i = 0; i < 16; i++) ij_os(RRDY);
    // owed R_RDYs saturate: short frames into A while it sends a long one
    send(0, 1200, 0, 0);
    while (u_a.ts != 3'd2) ij_idles(1);
    for (int i = 0; i < 20; i++) begin ij_os(SOFN); ij_eof(8'hD5); push_frame(0, 0, 0, 0, 0); end
    send(0, 8, 0, 0);
    while (hsize(0) != 0) ij_idles(1);
    ij_idles(60);
    if (q0.size() != 0) fail($sformatf("port A: %0d bytes still expected", q0.size()));
    drain();

    // ---- back to B, reset in a frame
    do_reset();
    cfg_credit = {4'd3, 4'd5};
    both_random(4, 100);
    idle_wait(0);
    send(0, 400, 0, 0);
    while (u_a.ts != 3'd2) @(negedge clk);
    wait_clk(500);
    do_reset();
    both_random(4, 100);
    drain();

    if (errors == 0) $display("TEST PASSED: FC");
    else $display("TEST FAILED: FC (%0d errors)", errors);
    $finish;
  end

  initial begin
    #50ms;
    $display("TEST FAILED: FC (timeout)");
    $finish;
  end
endmodule
