// SPDX-License-Identifier: Apache-2.0
// USB2_0-specific part of tb/USB2_0_apb_tb.sv. The TB is the host, with
// the bus BFM of tb/USB2_0_tb.sv (FS pull-up on D+, pull-down on D-): it
// sends frames bit by bit and decodes and checks every echo (SYNC,
// stuffing, PID check, CRC16 residual, EOP, turnaround, payload).
// Covered through the registers: ECHO per good frame, STATUS.busy while a
// frame is received and echoed, STATUS.rx_err after each kind of bad frame
// (no echo; cleared by a reset), ECHO masked and left pending into reset.
localparam int BIT = 400;                                // ns per bit at BAUD_DIV 20
localparam int MAXB = 8;
pullup (dp);
pulldown (dm);
logic h_oe = 0, h_dp = 1, h_dm = 0;
int   hbit = BIT;
int   sync_zeros = 7;
assign dp = h_oe ? h_dp : 1'bz;
assign dm = h_oe ? h_dm : 1'bz;
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
    if (wt >= 20 * BIT) fail($sformatf("no echo for pid %h len %0d", pid, len));
    else begin
      // turnaround from the host's EOP end (SE0 -> J), one bit before
      // the host released the bus: 2 .. 6.5 bit times
      if (t_k - t_eop + BIT < 2.0 * BIT || t_k - t_eop + BIT > 6.5 * BIT) begin
        fail($sformatf("turnaround %0t ns out of range", t_k - t_eop + BIT));
      end
      #(BIT / 2);
      prev = 1'b1; n = 0; ones = 0; last_stuff = 0; sh = 0; c = 16'hFFFF; rpid = 0;
      for (int i = 0; i < 8; i++) begin           // SYNC 0000_0001
        cur = (dp === 1'b1);
        b = (cur == prev); prev = cur;
        if (b !== (i == 7)) fail($sformatf("echo SYNC bit %0d", i));
        ones = b ? ones + 1 : 0;
        #(BIT);
      end
      while (!(dp === 1'b0 && dm === 1'b0)) begin
        if (dp === dm) fail($sformatf("SE1 on bus"));
        cur = (dp === 1'b1);
        b = (cur == prev); prev = cur;
        if (ones == 6) begin
          if (b) fail($sformatf("echo missing stuff bit"));
          ones = 0; last_stuff = 1;
        end else begin
          last_stuff = 0;
          ones = b ? ones + 1 : 0;
          sh = {b, sh[7:1]};
          if (n >= 8) c = crc_u(c, b);
          if (n % 8 == 7) begin
            if (n == 7) rpid = sh[3:0];
            if (n == 7 && sh[7:4] !== ~sh[3:0]) fail($sformatf("echo PID check"));
            if (n >= 15 && (n / 8) - 1 < 16) rxp[(n / 8) - 1] = sh;
          end
          n++;
        end
        #(BIT);
      end
      if (last_stuff) n_tail_stuff++;
      se0n = 0;
      while (dp === 1'b0 && dm === 1'b0) begin se0n++; #(BIT); end
      if (se0n != 2) fail($sformatf("echo EOP SE0 %0d bits", se0n));
      if (!(dp === 1'b1 && dm === 1'b0)) fail($sformatf("echo EOP not J"));
      #(BIT);
      rlen = n / 8 - 3;
      if (n % 8 != 0) fail($sformatf("echo not byte aligned"));
      if (c !== 16'hB001) fail($sformatf("echo CRC16 residual %h", c));
      if (rpid !== pid) fail($sformatf("echo pid %h exp %h", rpid, pid));
      if (rlen != len) fail($sformatf("echo len %0d exp %0d", rlen, len));
      for (int i = 0; i < len && i < 16; i++)
        if (rxp[i] !== txp[i]) fail($sformatf("echo byte %0d %h exp %h", i, rxp[i], txp[i]));
    end
  end
endtask

task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
// a good frame: echoed, ECHO set, busy while it lasts
task automatic good(input logic [3:0] pid, input int len);
  fork
    send(pid, len, 0);
    begin #(BIT * 8); rd_exp(A_STATUS, 1); end
  join
  recv_check(pid, len);
  #(4 * BIT);
  rd_exp(A_STATUS, 0);
  irq_expect(IRQ_ECHO);
endtask
// a bad frame: no echo, rx_err set; recovery; a reset clears rx_err
task automatic bad_frame(input int len, input int mode);
  send(4'h3, len, mode);
  #(30 * BIT);
  rd_exp(A_IRQ_STATUS, 0);
  rd_exp(A_STATUS, 2);
  txp[0] = 8'h11; txp[1] = 8'h22;
  send(4'h3, 2, 0); recv_check(4'h3, 2); #(4 * BIT);
  rd_exp(A_STATUS, 2);
  PRESETN = 0; cycles(3); PRESETN = 1; cycles(3);
  rd_exp(A_STATUS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  rd_exp(A_STATUS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int i = 0; i < 16; i++) txp[i] = 8'hA0 + 8'(i * 17);
  for (int l = 0; l <= MAXB; l++) good(4'(l), l);
  for (int i = 0; i < MAXB; i++) txp[i] = 8'hFF;
  good(4'h3, MAXB);
  for (int i = 0; i < MAXB; i++) txp[i] = 8'h00;
  good(4'hC, MAXB);
  for (int t = 0; t < 10; t++) begin : b_rnd
    int l;
    l = $urandom_range(0, MAXB);
    for (int i = 0; i < l; i++) txp[i] = $urandom;
    good(4'($urandom), l);
  end
  for (int i = 0; i < 16; i++) txp[i] = $urandom;
  for (int m = 1; m <= 7; m++) bad_frame(3, m);
  bad_frame(MAXB + 1, 0);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  send(4'h3, 1, 0); recv_check(4'h3, 1);
  cycles(2);
  if (irq) fail("irq with ECHO masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ECHO);
endtask
