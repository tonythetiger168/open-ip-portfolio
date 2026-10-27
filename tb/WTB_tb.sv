// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for WTB_top -- IEEE 802.4 style token-bus station.
// The bus is modelled with the station's own transmission looped back to
// its receiver (rx_bit = tx_en ? tx_bit : peer_bit); the TB plays the other
// stations on peer_bit and decodes every frame the station sends.
// Covered: register writes, TX FIFO push / overflow / push while full and
// popping; token pass with an empty FIFO; data frames up to MAX_FR per hold
// and the programmable hold window (zero, one or more frames); delivery to
// the RX FIFO for my_addr and broadcast with 0..16 byte payloads (zero
// padded), frames for other stations, own frames ignored; RX FIFO overflow
// and push while full and popping; bad CRC, bad ED, overlong LEN, noise
// before the delimiter; tokens for other stations; claim_token after the
// idle timeout with every outcome (window expiry, lower / higher address
// claim, token received, other traffic); my_addr change; reset mid-hold.
`timescale 1ns/1ps
module WTB_tb;
  localparam int MAX_FR = 4;

  logic clk = 0, rst_n = 0;
  logic        peer_bit = 1'b1;
  logic        rx_bit;
  logic        tx_bit, tx_en;
  logic [7:0]  my_addr = 8'h11;
  logic        cpu_we = 0, cpu_re = 0;
  logic [1:0]  cpu_addr = 0;
  logic [31:0] cpu_wdata = 0, cpu_rdata;
  logic [3:0]  fifo_count, rx_count;
  logic        token_held;
  logic        irq;

  int errors = 0;

  assign rx_bit = tx_en ? tx_bit : peer_bit;

  WTB_top dut (
    .clk(clk), .rst_n(rst_n),
    .rx_bit(rx_bit), .tx_bit(tx_bit), .tx_en(tx_en),
    .my_addr(my_addr),
    .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .cpu_re(cpu_re), .cpu_rdata(cpu_rdata),
    .fifo_count(fifo_count), .rx_count(rx_count),
    .token_held(token_held), .irq(irq)
  );

  always #5 clk = ~clk;

  task automatic check(input logic cond, input string msg);
    if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
  endtask

  function automatic logic [15:0] crc16_byte(input logic [15:0] crc,
                                             input logic [7:0]  data);
    logic [15:0] c;
    c = crc ^ {data, 8'h00};
    for (int i = 0; i < 8; i++)
      c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
    return c;
  endfunction

  // ------------------------------------------------------------------
  // monitor: decode every frame the station sends
  // ------------------------------------------------------------------
  logic [7:0]  mbuf [0:31];
  logic [7:0]  mon_fc [0:255], mon_da [0:255], mon_len [0:255];
  logic [31:0] mon_w [0:255];
  int          mon_cnt = 0, mon_rd = 0;
  int          mbits = 0;
  logic        irq_seen = 0;
  logic [7:0]  mcur;

  always @(posedge irq) irq_seen = 1;

  always @(negedge clk) begin
    logic [15:0] c;
    int n;
    if (!rst_n) mbits = 0;
    else if (tx_en) begin
      mcur = {mcur[6:0], tx_bit};
      mbits++;
      if (mbits % 8 == 0 && mbits <= 256) mbuf[mbits / 8 - 1] = mcur;
    end else begin
      check(tx_bit == 1'b1, "idle tx_bit is 1");
      if (mbits != 0) begin
        n = mbits / 8;
        check(mbits % 8 == 0, "whole bytes");
        check(n >= 10 && mbuf[0] == 8'h55 && mbuf[1] == 8'h55 && mbuf[2] == 8'hD5,
              "preamble and SD");
        check(n == 10 + mbuf[6] && mbuf[n-1] == 8'hD4, "length and ED");
        check(mbuf[5] == my_addr, "SA is my_addr");
        c = 16'hFFFF;
        for (int i = 3; i < n - 3; i++) c = crc16_byte(c, mbuf[i]);
        check(c == {mbuf[n-3], mbuf[n-2]}, "frame CRC");
        mon_fc[mon_cnt[7:0]]  = mbuf[3];
        mon_da[mon_cnt[7:0]]  = mbuf[4];
        mon_len[mon_cnt[7:0]] = mbuf[6];
        mon_w[mon_cnt[7:0]]   = {mbuf[7], mbuf[8], mbuf[9], mbuf[10]};
        mon_cnt++;
        mbits = 0;
      end
    end
  end

  // ------------------------------------------------------------------
  // expected TX words / RX words
  // ------------------------------------------------------------------
  logic [31:0] txq [0:255];
  int          txq_wr = 0, txq_rd = 0;
  logic [31:0] rxq [0:255];
  int          rxq_wr = 0, rxq_rd = 0;

  task automatic cpu_wr(input logic [1:0] a, input logic [31:0] d);
    @(negedge clk);
    cpu_we = 1; cpu_addr = a; cpu_wdata = d;
    @(negedge clk);
    cpu_we = 0; cpu_wdata = $urandom;
  endtask

  logic [31:0] wfix = 0;
  logic        wfix_en = 0;
  task automatic push_words(input int n);
    logic [31:0] w;
    for (int i = 0; i < n; i++) begin
      w = wfix_en ? wfix : $urandom;
      if (fifo_count != 8) begin txq[txq_wr[7:0]] = w; txq_wr++; end
      cpu_wr(2'd0, w);
    end
  endtask

  task automatic ctrl(input logic claim, input int win);
    cpu_wr(2'd3, {$urandom} & 32'hFE00_0000 | (win << 8) | {31'd0, claim});
  endtask

  // pop the RX FIFO, checking against the expected words when chk
  task automatic rx_pop(input int n, input logic chk);
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      if (chk) begin
        check(rx_count != 0, "rx word available");
        check(cpu_rdata == rxq[rxq_rd[7:0]], "rx word data");
      end
      rxq_rd++;
      cpu_re = 1;
      @(negedge clk);
      cpu_re = 0;
    end
  endtask

  task automatic rx_drain;
    while (rx_count != 0) begin
      @(negedge clk); cpu_re = 1; @(negedge clk); cpu_re = 0;
    end
    rxq_rd = rxq_wr;
  endtask

  // ------------------------------------------------------------------
  // peer stations on the bus
  // ------------------------------------------------------------------
  task automatic send_byte(input logic [7:0] b);
    for (int i = 7; i >= 0; i--) begin
      @(negedge clk);
      peer_bit = b[i];
    end
  endtask

  // mode: 0 good, 1 bad CRC, 2 bad ED, 3 bad CRC and ED
  logic [7:0] pl [0:15];
  int         pfix = -1;                 // forced payload byte (directed)
  task automatic send_frame(input logic [7:0] fc, da, sa, len, input int mode);
    logic [15:0] c;
    logic [31:0] w;
    int nb;
    nb = (len > 16) ? 0 : len;
    for (int i = 0; i < 16; i++) pl[i] = pfix >= 0 ? 8'(pfix) : 8'($urandom);
    c = 16'hFFFF;
    c = crc16_byte(c, fc);
    c = crc16_byte(c, da);
    c = crc16_byte(c, sa);
    c = crc16_byte(c, len);
    for (int i = 0; i < nb; i++) c = crc16_byte(c, pl[i]);
    if (mode[0]) c = c ^ (16'h1 << ($urandom % 16));
    send_byte(8'h55); send_byte(8'h55); send_byte(8'hD5);
    send_byte(fc); send_byte(da); send_byte(sa); send_byte(len);
    if (len <= 16) begin
      for (int i = 0; i < nb; i++) send_byte(pl[i]);
      send_byte(c[15:8]); send_byte(c[7:0]);
      send_byte(mode[1] ? 8'hD4 ^ (8'h1 << ($urandom % 8)) : 8'hD4);
      // expected delivery
      if (mode == 0 && fc == 8'h02 && (da == my_addr || da == 8'hFF) && sa != my_addr)
        for (int k = 0; k < (nb + 3) / 4; k++) begin
          w = 0;
          for (int j = 0; j < 4; j++) if (4 * k + j < nb) w[8 * (3 - j) +: 8] = pl[4 * k + j];
          rxq[rxq_wr[7:0]] = w; rxq_wr++;
        end
    end
    @(negedge clk); peer_bit = 1'b1;
    repeat (4) @(negedge clk);
  endtask

  task automatic noise(input int n);
    for (int i = 0; i < n; i++) begin @(negedge clk); peer_bit = $urandom; end
    @(negedge clk); peer_bit = 1'b1;
  endtask

  // wait until the station has sent n more frames (bounded)
  task automatic wait_frames(input int n, input string tag);
    int to;
    to = 0;
    while (mon_cnt < mon_rd + n && to < 20000) begin @(negedge clk); to++; end
    check(mon_cnt >= mon_rd + n, {tag, ": frames sent"});
  endtask

  task automatic expect_frame(input logic [7:0] fc, da, input string tag);
    wait_frames(1, tag);
    check(mon_fc[mon_rd[7:0]] == fc, {tag, ": FC"});
    check(mon_da[mon_rd[7:0]] == da, {tag, ": DA"});
    if (fc == 8'h02) begin
      check(mon_len[mon_rd[7:0]] == 4, {tag, ": data LEN"});
      check(mon_w[mon_rd[7:0]] == txq[txq_rd[7:0]], {tag, ": data word"});
      txq_rd++;
    end else check(mon_len[mon_rd[7:0]] == 0, {tag, ": LEN 0"});
    mon_rd++;
  endtask

  // give the station the token and check the hold: nd data frames, then
  // the token to ns
  task automatic token_round(input logic [7:0] ns, da, input int nd, input string tag);
    send_frame(8'h01, my_addr, 8'h05, 8'h00, 0);
    for (int i = 0; i < nd; i++) expect_frame(8'h02, da, tag);
    expect_frame(8'h01, ns, tag);
    repeat (4) @(negedge clk);
    check(!token_held, {tag, ": token released"});
  endtask

  task automatic do_reset;
    rst_n = 0; peer_bit = 1;
    cpu_we = 0; cpu_re = 0;
    repeat (3) @(negedge clk);
    check(!tx_en && tx_bit && !irq && !token_held && fifo_count == 0 && rx_count == 0,
          "reset outputs");
    rst_n = 1;
    mbits = 0; mon_rd = mon_cnt;
    txq_rd = txq_wr; rxq_rd = rxq_wr;
    repeat (2) @(negedge clk);
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [7:0] ns, da;
  int n;
  initial begin
    do_reset;

    // ---- configuration ----
    ns = 8'h22; da = 8'h33;
    cpu_wr(2'd1, {$urandom} & 32'hFFFF_FF00 | ns);
    cpu_wr(2'd2, {$urandom} & 32'hFFFF_FF00 | da);
    ctrl(0, 511);

    // ---- token with an empty FIFO: pass straight on ----
    irq_seen = 0;
    token_round(ns, da, 0, "empty pass");
    check(irq_seen, "token acquired irq");

    // ---- data frames ----
    push_words(3);
    check(fifo_count == 3, "fifo_count 3");
    token_round(ns, da, 3, "three frames");
    check(fifo_count == 0, "fifo drained");

    // ---- MAX_FR frames per hold ----
    push_words(8);
    check(fifo_count == 8, "fifo full");
    irq_seen = 0;
    push_words(1);                       // overflow write
    check(irq_seen && fifo_count == 8, "tx overflow irq");
    token_round(ns, da, MAX_FR, "max frames");
    check(fifo_count == 4, "4 left");
    ns = 8'hDD; da = 8'hCC;
    cpu_wr(2'd1, ns); cpu_wr(2'd2, da);
    token_round(ns, da, MAX_FR, "max frames 2");

    // ---- push while full and popping ----
    push_words(8);
    fork
      send_frame(8'h01, my_addr, 8'h05, 8'h00, 0);
      begin
        // push in the clock of the first pop, while the FIFO is full
        n = 0;
        while (n < 1000) begin
          @(negedge clk);
          if (dut.fifo_pop) begin           // pop on the next clock
            cpu_we = 1; cpu_addr = 0; cpu_wdata = $urandom;
            txq[txq_wr[7:0]] = cpu_wdata; txq_wr++;
            @(negedge clk); cpu_we = 0;
            n = 1000;
          end
          n++;
        end
      end
    join
    for (int i = 0; i < MAX_FR; i++) expect_frame(8'h02, da, "push while full");
    expect_frame(8'h01, ns, "push while full");
    check(fifo_count == 5, "fifo 5 after push+pop");

    // ---- hold window ----
    ctrl(0, 0);
    token_round(ns, da, 0, "window 0");
    ctrl(0, 150);
    token_round(ns, da, 2, "window 150");
    ctrl(0, 100);
    token_round(ns, da, 1, "window 100");
    ctrl(0, 300);
    push_words(4);
    token_round(ns, da, 3, "window 300");
    ctrl(0, 511);
    token_round(ns, da, 3, "rest");
    check(fifo_count == 0, "fifo empty");

    // ---- RX delivery ----
    for (int l = 0; l <= 16; l++) begin
      send_frame(8'h02, (l % 3 == 0) ? 8'hFF : my_addr, 8'(8'h20 + l), 8'(l), 0);
      repeat (6) @(negedge clk);
      rx_pop(rxq_wr - rxq_rd, 1);
    end
    check(rx_count == 0, "rx empty");
    // one-word broadcast and payload patterns (eight words: the RX FIFO
    // slots stay where the later sweeps expect them)
    for (int k = 0; k < 8; k++) begin
      pfix = k % 4 == 0 ? -1 : k % 4 == 1 ? 8'hFF : k % 4 == 2 ? 8'h55 : 8'hAA;
      send_frame(8'h02, k % 4 == 0 ? 8'hFF : my_addr, 8'h30, 8'd4, 0);
      repeat (6) @(negedge clk);
      rx_pop(rxq_wr - rxq_rd, 1);
    end
    pfix = -1;
    // transmit data patterns
    wfix_en = 1;
    wfix = 32'h5555_5555; push_words(1);
    wfix = 32'hAAAA_AAAA; push_words(1);
    wfix_en = 0;
    token_round(ns, da, 2, "tx patterns");
    // not for me / own frame / bad frames: nothing delivered
    send_frame(8'h02, 8'h44, 8'h05, 8'd8, 0);
    send_frame(8'h02, my_addr, my_addr, 8'd8, 0);
    irq_seen = 0;
    send_frame(8'h02, my_addr, 8'h05, 8'd8, 1);
    check(irq_seen, "bad CRC irq"); irq_seen = 0;
    send_frame(8'h02, my_addr, 8'h05, 8'd8, 2);
    check(irq_seen, "bad ED irq"); irq_seen = 0;
    send_frame(8'h02, my_addr, 8'h05, 8'd8, 3);
    check(irq_seen, "bad CRC+ED irq"); irq_seen = 0;
    send_frame(8'h02, my_addr, 8'h05, 8'd17, 0);
    check(irq_seen, "overlong irq"); irq_seen = 0;
    send_frame(8'hFF, my_addr, 8'h05, 8'hFF, 0);
    check(irq_seen, "overlong irq 2"); irq_seen = 0;
    noise(40);
    send_frame(8'h02, my_addr, 8'h05, 8'd4, 0);
    repeat (6) @(negedge clk);
    check(rx_count == 1, "only the good frame delivered");
    rx_pop(1, 1);
    // other frame types for other stations
    send_frame(8'h01, 8'h44, 8'h05, 8'd0, 0);
    send_frame(8'h03, my_addr, 8'h05, 8'd0, 0);
    send_frame(8'h01, my_addr, my_addr, 8'd0, 0);   // own token echo: ignored
    repeat (20) @(negedge clk);
    check(!token_held && mon_cnt == mon_rd, "no token taken");

    // ---- RX FIFO overflow ----
    for (int i = 0; i < 2; i++) send_frame(8'h02, my_addr, 8'h05, 8'd16, 0);
    repeat (6) @(negedge clk);
    check(rx_count == 8, "rx fifo full");
    irq_seen = 0;
    send_frame(8'h02, 8'hFF, 8'h05, 8'd16, 0);
    check(irq_seen && rx_count == 8, "rx overflow irq");
    rxq_wr = rxq_wr - 4;
    rx_pop(8, 1);
    // push while full and popping
    for (int i = 0; i < 2; i++) send_frame(8'h02, my_addr, 8'h05, 8'd16, 0);
    repeat (6) @(negedge clk);
    // the next frame's words arrive on the 4 clocks after its ED
    fork
      send_frame(8'h02, my_addr, 8'h05, 8'd16, 0);
      begin
        @(posedge dut.rx_done);
        @(negedge clk); @(negedge clk);
        cpu_re = 1; @(negedge clk); cpu_re = 0;
      end
    join
    repeat (6) @(negedge clk);
    check(rx_count == 8, "rx full again");
    rx_drain;

    // ---- soak: random words through both FIFOs ----
    for (int r = 0; r < 6; r++) begin
      wfix_en = (r < 2); wfix = (r == 0) ? '1 : '0;    // every bit both ways
      push_words(8);
      wfix_en = 0;
      token_round(ns, da, MAX_FR, "soak");
      token_round(ns, da, MAX_FR, "soak");
      for (int i = 0; i < 2; i++) send_frame(8'h02, my_addr, 8'h05, 8'd16, 0);
      repeat (6) @(negedge clk);
      rx_pop(8, 1);
    end

    // ---- my_addr change ----
    my_addr = 8'hEE;
    send_frame(8'h02, 8'hEE, 8'h05, 8'd4, 0);
    repeat (6) @(negedge clk);
    rx_pop(1, 1);
    push_words(1);
    token_round(ns, da, 1, "new address");
    my_addr = 8'h11;

    // ---- claim token ----
    // no contender: hold after the claim window, pass the token on
    ctrl(1, 511);
    expect_frame(8'h00, 8'hFF, "claim");
    wait (token_held);
    expect_frame(8'h01, ns, "claim won");
    // lower address claims: back off
    expect_frame(8'h00, 8'hFF, "claim 2");
    send_frame(8'h00, 8'hFF, 8'h03, 8'h00, 0);
    repeat (5) @(negedge clk);
    check(!token_held && dut.sstate == 0, "backed off");
    // token passed to us while claiming
    expect_frame(8'h00, 8'hFF, "claim 3");
    send_frame(8'h01, my_addr, 8'h40, 8'h00, 0);
    expect_frame(8'h01, ns, "token in claim");
    // other traffic ends the attempt
    expect_frame(8'h00, 8'hFF, "claim 4");
    send_frame(8'h02, 8'h44, 8'h05, 8'd2, 0);
    repeat (5) @(negedge clk);
    check(!token_held && dut.sstate == 0, "traffic ends claim");
    // higher address claim ignored, window expires
    expect_frame(8'h00, 8'hFF, "claim 5");
    send_frame(8'h00, 8'hFF, 8'hF0, 8'h00, 0);
    expect_frame(8'h01, ns, "claim won 2");
    ctrl(0, 511);
    repeat (400) @(negedge clk);
    check(mon_cnt == mon_rd, "no claim when disabled");

    // ---- reset mid-hold ----
    push_words(4);
    send_frame(8'h01, my_addr, 8'h05, 8'h00, 0);
    repeat (30) @(negedge clk);
    check(token_held, "holding");
    do_reset;
    check(!token_held, "reset drops token");

    repeat (20) @(negedge clk);
    if (errors == 0) $display("TEST PASSED: WTB");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
