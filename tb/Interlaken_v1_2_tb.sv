// SPDX-License-Identifier: Apache-2.0
// Interlaken_v1_2_top testbench: two lane ends A and B cross-connected. The
// line A -> B runs through a TB channel with a variable bit delay (bits or
// whole words added or dropped) and bit flips aimed at chosen bits of
// chosen words.
//  - host drivers send packets of random length, channel and last-word
//    byte count, with gaps between words, and random flow control; each
//    records the words its end takes
//  - receive scoreboards: from the first packet start after a lock, every
//    word must be the next one sent (data, SOP, EOP, byte count, channel)
//    and no word may carry rx_err unless the channel corrupted something
//  - alignment: slides at many bit offsets, invalid framing below and at
//    the unlock threshold, sync and scrambler state words hit in a row,
//    word shifts; protocol errors from flips of the framing bits, SOP,
//    EOP and control bits of protocol words
// The bound checker (tb/cov/Interlaken_v1_2_sva.sv) checks every output of
// both ends on every clock.
`timescale 1ns/1ps
module Interlaken_v1_2_tb;
  localparam int MF = 64, BMAX = 8, WCLK = 67, MCLK = MF * WCLK;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  // ---------------- ends: index 0 = A, 1 = B ----------------
  logic [1:0]       tx_valid = 0, tx_sop = 0, tx_eop = 0;
  logic [1:0][63:0] tx_data = 0;
  logic [1:0][2:0]  tx_bytes = 0;
  logic [1:0][7:0]  tx_chan = 0;
  logic [1:0][15:0] tx_fc = 0;
  wire  [1:0]       tx_ready, rx_valid, rx_sop, rx_eop, rx_err, word_lock, sync_lock;
  wire  [1:0]       err_word, err_sync, err_scr, err_crc32, err_crc24, err_proto;
  wire  [1:0][63:0] rx_data;
  wire  [1:0][2:0]  rx_bytes;
  wire  [1:0][7:0]  rx_chan;
  wire  [1:0][15:0] rx_fc;
  wire  [1:0][1:0]  peer_status;
  wire              a_tx, b_tx;
  // channel A -> B
  logic [1023:0]    dl = 0;
  int               dly = 0;
  logic             flip = 0;
  always @(posedge clk) dl <= {dl[1022:0], a_tx};
  wire              b_rx = dl[dly] ^ flip;

  Interlaken_v1_2_top #(.MF(MF), .BMAX(BMAX), .SEED(58'h155_5555_0000_FFFF)) u_a (
    .clk(clk), .rst_n(rst_n), .tx_p(a_tx), .rx_p(b_tx),
    .tx_valid(tx_valid[0]), .tx_ready(tx_ready[0]), .tx_data(tx_data[0]), .tx_sop(tx_sop[0]), .tx_eop(tx_eop[0]),
    .tx_bytes(tx_bytes[0]), .tx_chan(tx_chan[0]), .tx_fc(tx_fc[0]),
    .rx_valid(rx_valid[0]), .rx_data(rx_data[0]), .rx_sop(rx_sop[0]), .rx_eop(rx_eop[0]), .rx_bytes(rx_bytes[0]),
    .rx_chan(rx_chan[0]), .rx_err(rx_err[0]), .rx_fc(rx_fc[0]), .word_lock(word_lock[0]), .sync_lock(sync_lock[0]),
    .peer_status(peer_status[0]), .err_word(err_word[0]), .err_sync(err_sync[0]), .err_scr(err_scr[0]),
    .err_crc32(err_crc32[0]), .err_crc24(err_crc24[0]), .err_proto(err_proto[0]));
  Interlaken_v1_2_top #(.MF(MF), .BMAX(BMAX), .SEED(58'h3AB_CDEF_0123_4567)) u_b (
    .clk(clk), .rst_n(rst_n), .tx_p(b_tx), .rx_p(b_rx),
    .tx_valid(tx_valid[1]), .tx_ready(tx_ready[1]), .tx_data(tx_data[1]), .tx_sop(tx_sop[1]), .tx_eop(tx_eop[1]),
    .tx_bytes(tx_bytes[1]), .tx_chan(tx_chan[1]), .tx_fc(tx_fc[1]),
    .rx_valid(rx_valid[1]), .rx_data(rx_data[1]), .rx_sop(rx_sop[1]), .rx_eop(rx_eop[1]), .rx_bytes(rx_bytes[1]),
    .rx_chan(rx_chan[1]), .rx_err(rx_err[1]), .rx_fc(rx_fc[1]), .word_lock(word_lock[1]), .sync_lock(sync_lock[1]),
    .peer_status(peer_status[1]), .err_word(err_word[1]), .err_sync(err_sync[1]), .err_scr(err_scr[1]),
    .err_crc32(err_crc32[1]), .err_crc24(err_crc24[1]), .err_proto(err_proto[1]));

  // ---------------- host drivers ----------------
  // a word offered stays offered until taken; between words a gap of a
  // random number of clocks may follow
  int   gap_pct = 0;                    // chance of a gap (up to 6 words) after a word
  int   gw [0:1];                       // clocks of gap left
  int   len_max = 4;                    // packet length 1..len_max words
  bit   hold = 0;                       // A offers nothing new
  bit   fc_hold = 0;                    // flow control held still
  int   left [0:1];                     // words left in the packet
  bit   tk [0:1];
  // what each end took: {chan, bytes, eop, sop, data}
  logic [76:0] sent0 [$];
  logic [76:0] sent1 [$];
  initial for (int p = 0; p < 2; p++) begin left[p] = 0; tk[p] = 0; gw[p] = 0; end
  // a word is taken on a posedge with tx_valid and tx_ready (sampled
  // there, before the core moves on)
  always @(posedge clk)
    for (int p = 0; p < 2; p++)
      if (rst_n && tx_valid[p] && tx_ready[p]) begin : b_take
        logic [76:0] w;
        w = {tx_chan[p], tx_eop[p] ? tx_bytes[p] : 3'd0, tx_eop[p], tx_sop[p], tx_data[p]};
        if (p == 0) begin sent0.push_back(w); if (sent0.size() > 4000) void'(sent0.pop_front()); end
        else begin sent1.push_back(w); if (sent1.size() > 4000) void'(sent1.pop_front()); end
        tk[p] = 1;
      end
  always @(negedge clk)
    for (int p = 0; p < 2; p++) begin
      if (!rst_n) begin
        tx_valid[p] = 0; tk[p] = 0; left[p] = 0;
      end else begin
        if (tk[p]) begin
          tx_valid[p] = 0; tk[p] = 0;
          gw[p] = ($urandom % 100) < gap_pct ? $urandom % (6 * WCLK) : 0;
        end
        if (gw[p] > 0) gw[p]--;
        else if (!tx_valid[p] && !(p == 0 && hold)) begin
          tx_sop[p] = left[p] == 0;
          if (left[p] == 0) begin
            left[p] = 1 + $urandom % len_max;
            tx_chan[p] = $urandom;
            tx_bytes[p] = $urandom;
          end
          left[p]--;
          tx_eop[p] = left[p] == 0;
          tx_data[p] = {$urandom, $urandom};
          tx_valid[p] = 1;
        end
        if (!fc_hold && $urandom % 500 == 0) tx_fc[p] = $urandom;
      end
    end

  // ---------------- receive scoreboards ----------------
  // end p receives what end 1-p sent
  bit [1:0] synced = 0, dirty = 0;
  int       nrx [0:1], npkt [0:1];
  initial for (int p = 0; p < 2; p++) begin nrx[p] = 0; npkt[p] = 0; end
  function automatic int ssize(input int p);
    return p == 0 ? sent0.size() : sent1.size();
  endfunction
  function automatic logic [76:0] sfront(input int p);
    return p == 0 ? sent0[0] : sent1[0];
  endfunction
  task automatic spop(input int p);
    if (p == 0) void'(sent0.pop_front()); else void'(sent1.pop_front());
  endtask
  always @(negedge clk)
    for (int p = 0; p < 2; p++) begin
      if (!rst_n || !sync_lock[p] && !rx_valid[p]) synced[p] = 0;
      if (rx_valid[p]) begin : b_rx
        logic [76:0] got, e;
        got = {rx_chan[p], rx_bytes[p], rx_eop[p], rx_sop[p], rx_data[p]};
        if (rx_err[p] && !dirty[p]) fail($sformatf("end %0d: rx_err on a clean line", p));
        if (!synced[p] && rx_sop[p] && !rx_err[p]) begin
          // the first packet start after a lock: find it among those sent
          while (ssize(1 - p) != 0 && sfront(1 - p) !== got) spop(1 - p);
          if (ssize(1 - p) != 0) synced[p] = 1;
          else if (!dirty[p]) fail($sformatf("end %0d: first word %h was never sent", p, rx_data[p]));
        end
        if (synced[p] && ssize(1 - p) == 0) begin
          if (!dirty[p]) fail($sformatf("end %0d: word %h was never sent", p, got));
          synced[p] = 0;
        end
        if (synced[p]) begin
          e = sfront(1 - p);
          spop(1 - p);
          if (got !== e) begin
            if (!dirty[p]) fail($sformatf("end %0d: word %h, expected %h", p, got, e));
            synced[p] = 0;
          end else begin
            nrx[p]++;
            if (rx_eop[p]) npkt[p]++;
          end
        end
      end
    end

  // ---------------- helpers ----------------
  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask
  task automatic wait_lock(input int p, input int n_mf = 12);
    int t;
    t = 0;
    while (!sync_lock[p] && t < n_mf * MCLK) begin @(negedge clk); t++; end
    if (!sync_lock[p]) fail($sformatf("end %0d: no lock", p));
  endtask
  // B's line: dirty while the channel misbehaves, clean once relocked and
  // two whole metaframes are through
  task automatic clean_b;
    wait_lock(1);
    wait_clk(2 * MCLK);
    dirty[1] = 0;
  endtask
  // B loses the lock after a change of the line
  task automatic lost_b;
    int t;
    t = 0;
    while (sync_lock[1] && t < 6 * MCLK) begin @(negedge clk); t++; end
    if (sync_lock[1]) fail("B kept the lock");
  endtask
  function automatic bit b_prot;
    return u_b.rpos > 2 && u_b.rpos != MF - 1;
  endfunction
  // flip n line bits into B from word bit idx (1 = framing bit 65, 66 - k =
  // payload bit k) of the next word for which cond holds
  task automatic flip_bits(input int idx, input int n);
    flip = 1; wait_clk(n); flip = 0;
  endtask
  task automatic at_bit(input int idx);
    while (u_b.rc != 7'(idx - 1)) @(negedge clk);
  endtask
  task automatic flip_pos(input int pos, input int idx, input int n = 1);
    at_bit(idx);
    while (pos >= 0 ? u_b.rpos != pos : !b_prot()) begin @(negedge clk); at_bit(idx); end
    flip_bits(idx, n);
  endtask
  task automatic do_reset;
    @(negedge clk);
    rst_n = 0;
    wait_clk(3);
    rst_n = 1;
  endtask

  initial begin
    wait_clk(3);
    rst_n = 1;
    // ---- lock both ends; traffic: short packets, gaps, long packets
    wait_lock(0); wait_lock(1);
    wait_clk(2 * MCLK);
    if (peer_status[0] !== 2'b11 || peer_status[1] !== 2'b11)
      fail($sformatf("peer status %b %b after lock", peer_status[0], peer_status[1]));
    gap_pct = 30;
    wait_clk(3 * MCLK);
    len_max = 40; gap_pct = 0;
    wait_clk(3 * MCLK);
    gap_pct = 95; len_max = 3;
    wait_clk(3 * MCLK);
    gap_pct = 10; len_max = 12;
    wait_clk(2 * MCLK);
    // flow control: held still, it arrives at the other end
    fc_hold = 1; tx_fc[0] = 16'hA5C3; tx_fc[1] = 16'h3C5A;
    wait_clk(MCLK);
    if (rx_fc[1] !== 16'hA5C3 || rx_fc[0] !== 16'h3C5A) fail($sformatf("flow control %h %h", rx_fc[1], rx_fc[0]));
    fc_hold = 0;
    if (npkt[0] == 0 || npkt[1] == 0) fail("no packets through");

    // ---- payload flips in protocol words, skip and diagnostic words: CRC
    // errors, the lock holds
    dirty[1] = 1;
    for (int i = 0; i < 12; i++) begin
      flip_pos(i % 4 == 0 ? (i % 8 == 0 ? 2 : MF - 1) : -1, 4 + $urandom % 62);
      wait_clk(MCLK / 3);
    end
    if (!sync_lock[1]) fail("lock lost over payload errors");
    wait_clk(2 * MCLK);
    dirty[1] = 0;

    // ---- protocol errors; A idle first
    dirty[1] = 1;
    hold = 1;
    wait_clk(2 * MCLK);
    flip_pos(-1, 1, 2);                         // idle control -> data word outside a burst
    wait_clk(3 * WCLK);
    flip_pos(-1, 66 - 60);                      // EOP in an idle control word
    wait_clk(3 * WCLK);
    flip_pos(-1, 66 - 63);                      // bit 63: a framing layer word
    wait_clk(3 * WCLK);
    flip_pos(-1, 1);                            // invalid framing
    wait_clk(3 * WCLK);
    hold = 0;
    // SOP flipped in control words inside long packets and between packets
    len_max = 30; gap_pct = 0;
    for (int i = 0; i < 16; i++) begin
      at_bit(5);
      while (!(u_b.rf1 && !u_b.rf0 && b_prot() && (i < 8 ? u_b.r_inpkt && u_b.rh_v : !u_b.r_inpkt)))
        begin @(negedge clk); at_bit(5); end
      flip_bits(5, 1);
      wait_clk(5 * WCLK);
      if (i == 7) begin len_max = 1; gap_pct = 60; end
    end
    if (!sync_lock[1]) fail("lock lost over protocol errors");
    gap_pct = 10; len_max = 12;
    wait_clk(2 * MCLK);
    dirty[1] = 0;

    // ---- framing errors: a few per window (counter reset), then 16 in a row
    dirty[1] = 1;
    for (int w = 0; w < 3; w++)
      for (int i = 0; i < 5; i++) begin
        flip_pos(-1, 2);
        wait_clk(WCLK * (2 + $urandom % 10));
      end
    if (!word_lock[1]) fail("word lock lost below the error threshold");
    while (!(u_b.rc == 7'd0 && u_b.wcnt == 6'd0)) @(negedge clk);
    for (int i = 0; i < 16; i++) begin
      at_bit(2);
      if (i == 15 && !word_lock[1]) fail("unlocked before the 16th framing error");
      flip_bits(2, 1);
    end
    wait_clk(200);
    if (word_lock[1]) fail("still locked after 16 framing errors");
    clean_b();

    // ---- sync words hit: 3 in a row keep the lock, 4 drop it; while
    // testing one drops the test
    dirty[1] = 1;
    for (int i = 0; i < 3; i++) flip_pos(0, 30);
    wait_clk(2 * MCLK);
    if (!sync_lock[1]) fail("lock lost after 3 sync words");
    for (int i = 0; i < 4; i++) flip_pos(0, 30);
    wait_clk(WCLK);
    if (sync_lock[1]) fail("still locked after 4 sync words");
    while (u_b.ms != 2'd1) @(negedge clk);
    flip_pos(0, 30);
    clean_b();
    // ---- scrambler state words hit: 2 in a row keep the lock, 3 drop it
    dirty[1] = 1;
    flip_pos(1, 40);                            // the state field
    flip_pos(1, 1, 2);                          // the framing bits: a data word
    wait_clk(2 * MCLK);
    if (!sync_lock[1]) fail("lock lost after 2 scrambler state words");
    for (int i = 0; i < 3; i++) flip_pos(1, 40);
    wait_clk(WCLK);
    if (sync_lock[1]) fail("still locked after 3 scrambler state words");
    clean_b();

    // ---- the line slides by bits and by whole words
    len_max = 30; gap_pct = 0;
    for (int s = 1; s < 67; s += 9) begin
      dirty[1] = 1;
      dly = (dly + s) % 800;
      lost_b();
      clean_b();
    end
    // whole words: the word lock holds, the scrambler state words are out
    // of place
    for (int i = 0; i < 3; i++) begin
      dirty[1] = 1;
      dly = dly + WCLK * (1 + i) < 1024 ? dly + WCLK * (1 + i) : dly - WCLK * (1 + i);
      lost_b();
      if (!word_lock[1]) fail("word lock lost over a word shift");
      clean_b();
    end
    len_max = 12; gap_pct = 10;
    wait_clk(3 * MCLK);
    if (nrx[1] < 100) fail("too few clean words through");

    // ---- reset while locked
    do_reset();
    dirty = 0;
    wait_lock(0); wait_lock(1);
    wait_clk(3 * MCLK);

    if (errors == 0) $display("TEST PASSED: Interlaken_v1_2");
    else $display("TEST FAILED: Interlaken_v1_2 (%0d errors)", errors);
    $finish;
  end

  initial begin
    #150ms;
    $display("TEST FAILED: Interlaken_v1_2 (timeout)");
    $finish;
  end
endmodule
