// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for USB2_0_top (FS echo engine).
// Host BFM bit-bangs spec framing: SYNC, PID, payload, inverted CRC16
// (x^16+x^15+x^2+1, init 0xFFFF, LSB first), NRZI with a stuffed 0 after
// every six 1s counted from SYNC on, EOP = 2 bits SE0 + 1 bit J. The bus
// has the FS pull-up on D+ and a pull-down on D-.
// The host decoder checks every echo: SYNC, stuffing, PID check, CRC16
// residual, EOP shape, the 2..6.5-bit turnaround and the echoed payload.
// Error frames (bad SYNC, stuffing, PID, CRC, alignment, length, EOP) must
// set rx_err and produce no echo; the device must recover on the next frame.
`timescale 1ns/1ps
module USB2_0_tb;
  localparam int BIT  = 400;           // ns per bit at BAUD_DIV 20, clk 10 ns
  localparam int MAXB = 8;
  logic clk = 0, rst_n = 0;
  tri1 dp;                             // FS device pull-up
  tri0 dm;
  logic h_oe = 0, h_dp = 1, h_dm = 0;
  logic busy, irq;
  int   errors = 0;
  int   hbit = BIT;                    // host bit period (drift tests)
  int   sync_zeros = 7;                // SYNC length (zeros before the 1)

  USB2_0_top #(.BAUD_DIV(20), .MAXB(MAXB)) dut (
    .clk(clk), .rst_n(rst_n), .dp(dp), .dm(dm), .busy(busy), .rx_err(), .irq(irq));

  always #5 clk = ~clk;
  assign dp = h_oe ? h_dp : 1'bz;
  assign dm = h_oe ? h_dm : 1'bz;

  int irq_cnt = 0;
  always @(posedge clk) if (irq) irq_cnt++;

  function automatic logic [15:0] crc_u(input logic [15:0] c, input logic b);
    crc_u = (c >> 1) ^ ((c[0] ^ b) ? 16'hA001 : 16'h0000);
  endfunction

  logic [7:0] txp [0:15];
  logic [7:0] rxp [0:15];

  // ------------------------------------------------------------------
  // host transmitter
  //   mode 0 good          1 CRC corrupted    2 PID check broken
  //        3 stuff error   4 extra dribble bit (misaligned)
  //        5 SE0 inside SYNC  6 K right after the EOP SE0
  //        7 short SYNC (1 after two zeros)
  // ------------------------------------------------------------------
  logic hl;                            // current line level, 1 = J
  int   hones;
  bit   stuff_err_now;
  task automatic h_level(input logic j);
    begin h_oe = 1; h_dp = j; h_dm = ~j; #(hbit); end
  endtask
  task automatic h_raw(input logic b);   // NRZI, no stuffing
    begin if (!b) hl = ~hl; h_level(hl); end
  endtask
  task automatic h_send_bit(input logic b);
    begin
      h_raw(b);
      hones = b ? hones + 1 : 0;
      if (hones == 6) begin
        h_raw(stuff_err_now ? 1'b1 : 1'b0);
        hones = stuff_err_now ? 7 : 0;
        stuff_err_now = 0;
      end
    end
  endtask
  task automatic h_eop(input int se0_bits);
    begin
      h_oe = 1; h_dp = 0; h_dm = 0; #(hbit * se0_bits);
      hl = 1; h_level(1'b1);
      h_oe = 0;
    end
  endtask

  task automatic send(input logic [3:0] pid, input int len, input int mode);
    logic [15:0] c;
    logic [7:0]  pb;
    begin
      hl = 1; hones = 0; stuff_err_now = 0;
      if (mode == 5) begin
        for (int i = 0; i < 3; i++) h_send_bit(1'b0);
        h_eop(2);
      end else if (mode == 7) begin
        h_send_bit(1'b0); h_send_bit(1'b0); h_send_bit(1'b1);
        for (int i = 0; i < 8; i++) h_send_bit(i[0]);
        h_eop(2);
      end else begin
        for (int i = 0; i < sync_zeros; i++) h_send_bit(1'b0);
        h_send_bit(1'b1);
        pb = (mode == 2) ? {pid, pid} : {~pid, pid};
        for (int i = 0; i < 8; i++) h_send_bit(pb[i]);
        c = 16'hFFFF;
        for (int i = 0; i < len; i++)
          for (int j = 0; j < 8; j++) begin
            if (mode == 3 && i == 0 && j == 0) begin
              txp[0] = 8'hFF; stuff_err_now = 1;    // 7th 1 instead of the stuff 0
            end
            h_send_bit(txp[i][j]);
            c = crc_u(c, txp[i][j]);
          end
        c = ~c;
        if (mode == 1) c = c ^ 16'h0100;
        for (int i = 0; i < 16; i++) h_send_bit(c[i]);
        if (mode == 4) h_send_bit(1'b0);
        if (mode == 6) begin
          h_oe = 1; h_dp = 0; h_dm = 0; #(hbit);
          hl = 0; h_level(1'b0);
          for (int i = 0; i < 9; i++) h_level(1'b1);
          h_oe = 0;
        end else h_eop(2);
      end
    end
  endtask

  // ------------------------------------------------------------------
  // host receiver: decodes and checks one device frame
  // ------------------------------------------------------------------
  int  rlen, n_tail_stuff = 0;
  logic [3:0] rpid;
  task automatic recv_check(input logic [3:0] pid, input int len);
    logic prev, b, cur;
    logic [7:0] sh;
    logic [15:0] c;
    int n, ones, wt, se0n;
    bit last_stuff;
    realtime t_eop, t_k;
    begin
      t_eop = $realtime;
      wt = 0;
      while (!(dp === 1'b0 && dm === 1'b1) && wt < 20 * BIT) begin #1; wt++; end
      t_k = $realtime;
      if (wt >= 20 * BIT) begin errors++; $display("ERROR: no echo for pid %h len %0d", pid, len); end
      else begin
        // turnaround from the host's EOP end (SE0 -> J), one bit before
        // the host released the bus: 2 .. 6.5 bit times
        if (t_k - t_eop + BIT < 2.0 * BIT || t_k - t_eop + BIT > 6.5 * BIT) begin
          errors++; $display("ERROR: turnaround %0t ns out of range", t_k - t_eop + BIT);
        end
        #(BIT / 2);
        prev = 1'b1; n = 0; ones = 0; last_stuff = 0; sh = 0; c = 16'hFFFF; rpid = 0;
        for (int i = 0; i < 8; i++) begin           // SYNC 0000_0001
          cur = (dp === 1'b1);
          b = (cur == prev); prev = cur;
          if (b !== (i == 7)) begin errors++; $display("ERROR: echo SYNC bit %0d", i); end
          ones = b ? ones + 1 : 0;
          #(BIT);
        end
        while (!(dp === 1'b0 && dm === 1'b0)) begin
          if (dp === dm) begin errors++; $display("ERROR: SE1 on bus"); end
          cur = (dp === 1'b1);
          b = (cur == prev); prev = cur;
          if (ones == 6) begin
            if (b) begin errors++; $display("ERROR: echo missing stuff bit"); end
            ones = 0; last_stuff = 1;
          end else begin
            last_stuff = 0;
            ones = b ? ones + 1 : 0;
            sh = {b, sh[7:1]};
            if (n >= 8) c = crc_u(c, b);
            if (n % 8 == 7) begin
              if (n == 7) rpid = sh[3:0];
              if (n == 7 && sh[7:4] !== ~sh[3:0]) begin errors++; $display("ERROR: echo PID check"); end
              if (n >= 15 && (n / 8) - 1 < 16) rxp[(n / 8) - 1] = sh;
            end
            n++;
          end
          #(BIT);
        end
        if (last_stuff) n_tail_stuff++;
        se0n = 0;
        while (dp === 1'b0 && dm === 1'b0) begin se0n++; #(BIT); end
        if (se0n != 2) begin errors++; $display("ERROR: echo EOP SE0 %0d bits", se0n); end
        if (!(dp === 1'b1 && dm === 1'b0)) begin errors++; $display("ERROR: echo EOP not J"); end
        #(BIT);
        rlen = n / 8 - 3;
        if (n % 8 != 0) begin errors++; $display("ERROR: echo not byte aligned"); end
        if (c !== 16'hB001) begin errors++; $display("ERROR: echo CRC16 residual %h", c); end
        if (rpid !== pid) begin errors++; $display("ERROR: echo pid %h exp %h", rpid, pid); end
        if (rlen != len) begin errors++; $display("ERROR: echo len %0d exp %0d", rlen, len); end
        for (int i = 0; i < len && i < 16; i++)
          if (rxp[i] !== txp[i]) begin
            errors++; $display("ERROR: echo byte %0d %h exp %h", i, rxp[i], txp[i]);
          end
      end
    end
  endtask

  task automatic good(input logic [3:0] pid, input int len);
    int c0;
    begin
      c0 = irq_cnt;
      send(pid, len, 0);
      recv_check(pid, len);
      if (irq_cnt != c0 + 1) begin errors++; $display("ERROR: irq count %0d", irq_cnt - c0); end
      #(4 * BIT);
      if (busy !== 1'b0) begin errors++; $display("ERROR: busy after echo"); end
    end
  endtask

  task automatic bad(input logic [3:0] pid, input int len, input int mode);
    int c0;
    begin
      // rx_err is sticky: clear it with a reset so each case is checked
      @(negedge clk) rst_n = 0; repeat (3) @(negedge clk); rst_n = 1;
      #(2 * BIT);
      c0 = irq_cnt;
      send(pid, len, mode);
      #(30 * BIT);
      if (irq_cnt != c0) begin errors++; $display("ERROR: mode %0d frame echoed", mode); end
      if (dut.rx_err !== 1'b1) begin errors++; $display("ERROR: mode %0d rx_err not set", mode); end
      if (busy !== 1'b0) begin errors++; $display("ERROR: mode %0d busy stuck", mode); end
      good(4'h3, 2);                                // recovery
    end
  endtask

  initial begin
    for (int i = 0; i < 16; i++) txp[i] = 8'hA0 + 8'(i * 17);
    repeat (10) @(negedge clk);
    rst_n = 1;
    #(4 * BIT);
    if (busy !== 1'b0 || irq !== 1'b0 || dp !== 1'b1 || dm !== 1'b0) begin
      errors++; $display("ERROR: reset state");
    end

    // directed good frames: lengths 0..MAXB, every PID nibble
    good(4'h3, 4);
    good(4'hB, 0);
    good(4'hF, 1);
    for (int l = 0; l <= MAXB; l++) good(4'(l), l);
    for (int p = 0; p < 16; p++) good(4'(p), 1);
    // all-ones payload: stuff bits inside and across bytes
    for (int i = 0; i < MAXB; i++) txp[i] = 8'hFF;
    good(4'h3, MAXB);
    for (int i = 0; i < MAXB; i++) txp[i] = 8'h00;
    good(4'hC, MAXB);
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: rx_err after good frames"); end

    // host clock drift: the receiver re-centres on every transition
    for (int i = 0; i < MAXB; i++) txp[i] = 8'hFF;
    hbit = BIT + 4; good(4'h3, MAXB);
    hbit = BIT - 4; good(4'h3, MAXB);
    hbit = BIT;
    // longer SYNC (extra KJ pairs) and the shortest accepted one (5 zeros)
    sync_zeros = 11; good(4'h3, 1);
    sync_zeros = 5;  good(4'h3, 1);
    sync_zeros = 7;

    // error frames
    for (int i = 0; i < 16; i++) txp[i] = $urandom;
    bad(4'h3, 3, 1);                                // CRC
    bad(4'h3, 3, 2);                                // PID check
    bad(4'h3, 3, 3);                                // stuffing
    bad(4'h3, 3, 4);                                // misaligned
    bad(4'h3, 3, 5);                                // SE0 in SYNC
    bad(4'h3, 3, 6);                                // K after SE0
    bad(4'h3, 3, 7);                                // short SYNC
    bad(4'h3, MAXB + 1, 0);                         // too long
    // PID only, no CRC: too short
    begin
      @(negedge clk) rst_n = 0; repeat (3) @(negedge clk); rst_n = 1;
      #(2 * BIT);
      hl = 1; hones = 0; stuff_err_now = 0;
      for (int i = 0; i < 7; i++) h_send_bit(1'b0);
      h_send_bit(1'b1);
      for (int i = 0; i < 8; i++) h_send_bit(i < 4 ? 1'b1 : 1'b0);
      h_eop(2);
      #(30 * BIT);
      if (dut.rx_err !== 1'b1) begin errors++; $display("ERROR: short frame rx_err not set"); end
      good(4'h3, 2);
    end

    // reset in the middle of an echo: lines released, engine idle
    txp[0] = 8'h5A; txp[1] = 8'hA5;
    send(4'h3, 2, 0);
    #(8 * BIT);
    @(negedge clk) rst_n = 0;
    #(2 * BIT);
    if (dp !== 1'b1 || dm !== 1'b0 || busy !== 1'b0) begin
      errors++; $display("ERROR: reset during echo");
    end
    rst_n = 1;
    #(4 * BIT);
    good(4'h3, 2);

    // random traffic
    for (int t = 0; t < 120; t++) begin
      int l;
      l = $urandom_range(0, MAXB);
      for (int i = 0; i < l; i++) txp[i] = $urandom;
      good(4'($urandom), l);
    end
    if (n_tail_stuff == 0) begin errors++; $display("ERROR: no echo ended with a stuff bit"); end
    // every first payload byte value
    for (int v = 0; v < 256; v++) begin txp[0] = 8'(v); good(4'h3, 1); end

    if (errors == 0) $display("TEST PASSED: USB2.0");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // timeout guard in 1-us chunks: one long pending #delay is fragile with
  // the --timing scheduler
  initial begin
    repeat (80000) #1000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
