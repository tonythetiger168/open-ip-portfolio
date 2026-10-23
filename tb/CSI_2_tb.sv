// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for CSI_2_top (MIPI CSI-2 RX, packet layer)
// The TB is the camera transmitter: each HS burst is a random number of
// HS-zero bits, the B8 sync, one or more packets (each after its own sync
// byte), then an EoT trailer. ECC and CRC-16 are computed here from the
// spec equations. A scoreboard predicts frame/line counters, irq, the error
// flags, last DT/WC and the content of the readable line buffer.
// Covered: FS/FE/generic shorts, long packets WC 0..520 (past the line
// buffer), every single-bit header and ECC-byte error (corrected), double
// errors (dropped), CRC errors (line kept from before), bursts that end
// inside a packet at every stage, several packets per burst, trailers that
// must not start a packet, sync found at any bit offset, reset mid-packet.
// ============================================================================
`timescale 1ns/1ps
module CSI_2_tb;
  localparam int LB = 512;
  logic        clk = 0, rst_n = 0;
  logic        rx_bit = 0, rx_valid = 0;
  logic        irq, frame_active;
  logic [15:0] frame_cnt, line_cnt, last_wc, lb_len;
  logic [7:0]  last_dt;
  logic [3:0]  err_flags;
  logic [8:0]  lb_addr = 0;
  logic [7:0]  lb_rdata;
  int errors = 0;

  CSI_2_top #(.LINE_BYTES(LB)) dut (
    .clk(clk), .rst_n(rst_n), .rx_bit(rx_bit), .rx_valid(rx_valid),
    .irq(irq), .frame_active(frame_active), .frame_cnt(frame_cnt), .line_cnt(line_cnt),
    .last_dt(last_dt), .last_wc(last_wc), .err_flags(err_flags), .lb_len(lb_len),
    .lb_addr(lb_addr), .lb_rdata(lb_rdata));
  always #5 clk = ~clk;

  function automatic logic [5:0] ecc24(input logic [23:0] d);
    ecc24[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
    ecc24[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
    ecc24[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
    ecc24[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
    ecc24[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
    ecc24[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
  endfunction
  function automatic logic [15:0] crc16(input logic [15:0] c, input logic [7:0] d);
    logic [15:0] v;
    v = c ^ {8'h00, d};
    for (int k = 0; k < 8; k++) v = v[0] ? (v >> 1) ^ 16'h8408 : (v >> 1);
    return v;
  endfunction

  // ---------------- burst builder ----------------
  logic [7:0] bb [0:2047];             // bytes of the burst after the first sync
  int         nb;
  logic [7:0] pay [0:1023];
  task automatic add(input logic [7:0] b); begin bb[nb] = b; nb++; end endtask
  // corrupt: 0 none, hdr_x / ecc_x XOR masks, bad_crc
  task automatic add_short(input logic [5:0] dt, input logic [1:0] vc, input logic [15:0] d,
                           input logic [23:0] hx, input logic [7:0] ex);
    logic [23:0] h;
    begin
      h = {d, vc, dt};
      add(h[7:0] ^ hx[7:0]); add(h[15:8] ^ hx[15:8]); add(h[23:16] ^ hx[23:16]);
      add({2'b00, ecc24(h)} ^ ex);
    end
  endtask
  task automatic add_long(input logic [5:0] dt, input logic [1:0] vc, input int wc,
                          input logic [23:0] hx, input logic [7:0] ex, input bit bad_crc);
    logic [15:0] c;
    begin
      add_short(dt, vc, 16'(wc), hx, ex);
      c = 16'hFFFF;
      for (int i = 0; i < wc; i++) begin add(pay[i]); c = crc16(c, pay[i]); end
      if (bad_crc) c = c ^ 16'h0040;
      add(c[7:0]); add(c[15:8]);
    end
  endtask

  // send: lead HS-zero bits, B8, bytes [0:nb-1] (cut after cut_bits bits
  // if >= 0), then trailer bits (inverse of the last bit), then LP
  task automatic send(input int lead, input int cut_bits, input int trail);
    int sent;
    logic last;
    begin
      sent = 0; last = 0;
      for (int i = 0; i < lead; i++) begin @(negedge clk); rx_valid = 1; rx_bit = 0; end
      for (int i = 0; i < 8; i++) begin @(negedge clk); rx_valid = 1; rx_bit = 8'hB8 >> i; end
      for (int k = 0; k < nb; k++)
        for (int i = 0; i < 8; i++)
          if (cut_bits < 0 || sent < cut_bits) begin
            @(negedge clk); rx_valid = 1; rx_bit = bb[k][i]; last = rx_bit; sent++;
          end
      for (int i = 0; i < trail; i++) begin @(negedge clk); rx_bit = ~last; end
      @(negedge clk); rx_valid = 0; rx_bit = 0;
      repeat (4) @(negedge clk);
      nb = 0;
    end
  endtask

  // ---------------- scoreboard ----------------
  int   e_fc = 0, e_lc = 0, e_len = 0;
  logic e_irq = 0, e_act = 0;
  logic [3:0]  e_err = 0;
  logic [7:0]  e_dt = 0;
  logic [15:0] e_wc = 0;
  logic [7:0]  e_line [0:LB-1];

  task automatic sb_short(input logic [5:0] dt, input logic [1:0] vc, input logic [15:0] d, input bit corr);
    begin
      e_dt = {vc, dt}; e_wc = d; e_irq = 0;
      if (dt == 6'h00) begin e_fc++; e_lc = 0; e_act = 1; e_err = {corr, 3'b000}; end
      else begin if (dt == 6'h01) e_act = 0; if (corr) e_err[3] = 1; end
    end
  endtask
  task automatic sb_long(input logic [5:0] dt, input logic [1:0] vc, input int wc, input bit corr, input bit bad_crc);
    begin
      e_dt = {vc, dt}; e_wc = 16'(wc);
      if (corr) e_err[3] = 1;
      if (bad_crc) begin e_irq = 1; e_err[0] = 1; end
      else begin
        e_irq = 0; e_lc++; e_len = wc > LB ? LB : wc;
        for (int i = 0; i < LB; i++) if (i < e_len) e_line[i] = pay[i];
      end
    end
  endtask
  task automatic sb_ecc_drop; begin e_irq = 1; e_err[1] = 1; end endtask
  // burst cut after cut bits: a header complete by then was accepted
  task automatic sb_abort(input int cut, input logic [7:0] di, input logic [15:0] wc);
    begin e_err[2] = 1; if (cut >= 32) begin e_dt = di; e_wc = wc; end end
  endtask

  task automatic check(input string tag);
    bit bad;
    begin
      if (frame_cnt !== 16'(e_fc) || line_cnt !== 16'(e_lc) || irq !== e_irq ||
          frame_active !== e_act || err_flags !== e_err || lb_len !== 16'(e_len) ||
          last_dt !== e_dt || last_wc !== e_wc) begin
        errors++;
        $display("ERROR: %s fc=%0d/%0d lc=%0d/%0d irq=%b/%b act=%b/%b err=%h/%h len=%0d/%0d dt=%h/%h wc=%0d/%0d",
                 tag, frame_cnt, e_fc, line_cnt, e_lc, irq, e_irq, frame_active, e_act,
                 err_flags, e_err, lb_len, e_len, last_dt, e_dt, last_wc, e_wc);
      end
      bad = 0;
      for (int i = 0; i < e_len; i++) begin
        lb_addr = 9'(i); #1;
        if (lb_rdata !== e_line[i] && !bad) begin
          errors++; bad = 1; $display("ERROR: %s line[%0d]=%h exp %h", tag, i, lb_rdata, e_line[i]);
        end
      end
    end
  endtask

  // one good long packet in its own burst
  task automatic line(input logic [5:0] dt, input int wc);
    begin
      for (int i = 0; i < wc; i++) pay[i] = $urandom;
      add_long(dt, 2'd0, wc, 0, 0, 0); send($urandom_range(0, 12), -1, 4);
      sb_long(dt, 2'd0, wc, 0, 0);
    end
  endtask
  task automatic short(input logic [5:0] dt, input logic [15:0] d);
    begin add_short(dt, 2'd1, d, 0, 0); send(3, -1, 4); sb_short(dt, 2'd1, d, 0); end
  endtask

  initial begin
    nb = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);
    check("reset");

    // frame with lines of several sizes
    short(6'h00, 16'h0001); check("FS");
    line(6'h2B, 16);  check("RAW8 16");
    line(6'h2B, 1);   check("RAW8 1");
    line(6'h24, 0);   check("WC 0");
    line(6'h2B, LB);  check("full line buffer");
    line(6'h2C, LB + 8); check("past line buffer");
    line(6'h1E, 300); check("YUV 300");
    short(6'h02, 16'h0007); check("LS");
    short(6'h03, 16'h0007); check("LE does not count a line");
    short(6'h08, 16'hBEEF); check("generic short");
    short(6'h01, 16'h0001); check("FE");

    // every single-bit header error is corrected; ECC-byte bit errors kept
    short(6'h00, 16'h0002);
    for (int b = 0; b < 24; b++) begin
      for (int i = 0; i < 8; i++) pay[i] = $urandom;
      add_long(6'h2B, 2'd2, 8, 24'h1 << b, 0, 0); send(1, -1, 2);
      sb_long(6'h2B, 2'd2, 8, 1, 0);
      check($sformatf("header bit %0d corrected", b));
    end
    for (int b = 0; b < 6; b++) begin
      add_short(6'h08, 2'd0, 16'(b), 0, 8'h1 << b); send(2, -1, 3);
      sb_short(6'h08, 2'd0, 16'(b), 1);
      check($sformatf("ECC bit %0d", b));
    end
    // FS with a corrected header starts the frame with only flag 3 set
    add_short(6'h00, 2'd0, 16'h0003, 24'h000400, 0); send(0, -1, 1);
    sb_short(6'h00, 2'd0, 16'h0003, 1); check("FS corrected");

    // double errors: dropped + irq; good packet clears irq; FS clears flags
    add_long(6'h2B, 2'd0, 8, 24'h000011, 0, 0); send(2, -1, 2);
    sb_ecc_drop(); check("double header error");
    add_short(6'h08, 2'd0, 16'h0, 0, 8'h03); send(2, -1, 2);
    sb_ecc_drop(); check("double ECC-byte error");
    line(6'h2B, 12); check("recover");
    for (int i = 0; i < 8; i++) pay[i] = $urandom;
    add_long(6'h2B, 2'd0, 8, 0, 0, 1); send(2, -1, 2);
    sb_long(6'h2B, 2'd0, 8, 0, 1); check("bad CRC keeps the previous line");
    short(6'h01, 16'h0); check("FE after errors");
    short(6'h00, 16'h0004); check("FS clears flags");

    // bursts that end inside a packet, at every stage
    for (int cut = 4; cut < 8 * (4 + 6 + 2); cut += 7) begin
      for (int i = 0; i < 6; i++) pay[i] = $urandom;
      add_long(6'h2B, 2'd0, 6, 0, 0, 0); send(1, cut, 0);
      sb_abort(cut, 8'h2B, 16'd6); check($sformatf("abort after %0d bits", cut));
    end
    add_short(6'h08, 2'd0, 16'h0, 0, 0); send(0, 16, 0);
    sb_abort(16, 8'h08, 16'h0); check("abort in short header");
    line(6'h2B, 6); check("recover after aborts");

    // several packets in one burst, then a trailer that holds a stray B8
    for (int i = 0; i < 20; i++) pay[i] = $urandom;
    add_short(6'h02, 2'd3, 16'h11, 0, 0); add(8'hB8);
    add_long(6'h2B, 2'd3, 20, 0, 0, 0); add(8'hB8);
    add_short(6'h03, 2'd3, 16'h11, 0, 0); add(8'h5A); add(8'hB8);
    add_short(6'h00, 2'd0, 16'h0, 0, 0);
    send(5, -1, 6);
    sb_short(6'h02, 2'd3, 16'h11, 0); sb_long(6'h2B, 2'd3, 20, 0, 0); sb_short(6'h03, 2'd3, 16'h11, 0);
    check("three packets in one burst, junk after");
    // sync preceded by HS-zero bits that are not a whole byte
    for (int lead = 0; lead < 16; lead++) begin
      add_short(6'h08, 2'd0, 16'(lead), 0, 0); send(lead, -1, 1);
      sb_short(6'h08, 2'd0, 16'(lead), 0);
      check($sformatf("lead %0d bits", lead));
    end
    // a burst with no sync at all
    @(negedge clk); rx_valid = 1;
    for (int i = 0; i < 40; i++) begin @(negedge clk); rx_bit = i[2] ^ i[0]; end
    @(negedge clk); rx_valid = 0; repeat (3) @(negedge clk);
    check("no sync");

    // every line-buffer bit through 1 and 0
    for (int i = 0; i < LB; i++) pay[i] = 8'hFF;
    add_long(6'h2B, 2'd0, LB, 0, 0, 0); send(0, -1, 1); sb_long(6'h2B, 2'd0, LB, 0, 0); check("all ones");
    for (int i = 0; i < LB; i++) pay[i] = 8'h00;
    add_long(6'h2B, 2'd0, LB, 0, 0, 0); send(0, -1, 1); sb_long(6'h2B, 2'd0, LB, 0, 0); check("all zeros");
    for (int i = 0; i < LB; i++) pay[i] = 8'hFF;
    add_long(6'h2B, 2'd0, LB, 0, 0, 0); send(0, -1, 1); sb_long(6'h2B, 2'd0, LB, 0, 0); check("all ones again");
    for (int i = 0; i < LB; i++) pay[i] = 8'h00;
    add_long(6'h2B, 2'd0, LB, 0, 0, 0); send(0, -1, 1); sb_long(6'h2B, 2'd0, LB, 0, 0); check("all zeros again");

    // random traffic
    for (int t = 0; t < 150; t++) begin
      int r, wc;
      logic [5:0] dt;
      logic [1:0] vc;
      r = $urandom_range(0, 9);
      vc = $urandom;
      if (r < 4) begin
        wc = ($urandom_range(0, 7) == 0) ? $urandom_range(0, 600) : $urandom_range(0, 64);
        dt = 6'h10 + 6'($urandom_range(0, 47));
        for (int i = 0; i < wc; i++) pay[i] = $urandom;
        add_long(dt, vc, wc, 0, 0, r == 0); send($urandom_range(0, 9), -1, $urandom_range(1, 8));
        sb_long(dt, vc, wc, 0, r == 0);
      end else if (r < 8) begin
        dt = $urandom_range(0, 15);
        add_short(dt, vc, 16'($urandom), 0, 0);
        sb_short(dt, vc, {bb[2], bb[1]}, 0);
        send($urandom_range(0, 9), -1, $urandom_range(1, 8));
      end else if (r == 8) begin
        wc = $urandom_range(1, 32);
        dt = 6'h2A;
        for (int i = 0; i < wc; i++) pay[i] = $urandom;
        add_long(dt, vc, wc, 24'h1 << $urandom_range(0, 23), 0, 0); send(2, -1, 2);
        sb_long(dt, vc, wc, 1, 0);
      end else begin
        wc = $urandom_range(1, 70);
        add_long(6'h2B, vc, 4, 0, 0, 0); send(2, wc, 0);
        sb_abort(wc, {vc, 6'h2B}, 16'd4);
      end
      check($sformatf("random %0d", t));
    end

`ifdef VERILATOR
    // counters wrap modulo 2^16: 65537 empty lines, then 65537 frames
    // (Verilator only: about 9M clocks)
    short(6'h00, 16'h0); check("FS before wrap");
    add_long(6'h2B, 2'd0, 0, 0, 0, 0);
    for (int i = 0; i < 65537; i++) begin
      for (int k = 0; k < 8; k++) begin @(negedge clk); rx_valid = 1; rx_bit = 8'hB8 >> k; end
      for (int j = 0; j < 6; j++)
        for (int k = 0; k < 8; k++) begin @(negedge clk); rx_bit = bb[j][k]; end
      @(negedge clk); rx_valid = 0; rx_bit = 0;
    end
    @(negedge clk);
    nb = 0;
    e_lc = 1; e_len = 0; e_dt = 8'h2B; e_wc = 0;
    check("line counter wrapped");
    add_short(6'h00, 2'd0, 16'h0, 0, 0);
    for (int i = 0; i < 65537; i++) begin
      for (int k = 0; k < 8; k++) begin @(negedge clk); rx_valid = 1; rx_bit = 8'hB8 >> k; end
      for (int j = 0; j < 4; j++)
        for (int k = 0; k < 8; k++) begin @(negedge clk); rx_bit = bb[j][k]; end
      @(negedge clk); rx_valid = 0; rx_bit = 0;
    end
    @(negedge clk);
    nb = 0;
    e_fc = (e_fc + 65537) % 65536; e_lc = 0; e_dt = 8'h00; e_wc = 0; e_err = 0;
    check("frame counter wrapped");
    // the largest long packet: WC = 65535
    begin
      logic [15:0] c;
      logic [7:0]  d;
      add_short(6'h2B, 2'd0, 16'hFFFF, 0, 0);
      for (int k = 0; k < 8; k++) begin @(negedge clk); rx_valid = 1; rx_bit = 8'hB8 >> k; end
      for (int j = 0; j < 4; j++)
        for (int k = 0; k < 8; k++) begin @(negedge clk); rx_bit = bb[j][k]; end
      c = 16'hFFFF;
      for (int i = 0; i < 65535; i++) begin
        d = 8'(i) ^ 8'(i >> 8);
        if (i < LB) e_line[i] = d;
        c = crc16(c, d);
        for (int k = 0; k < 8; k++) begin @(negedge clk); rx_bit = d[k]; end
      end
      for (int k = 0; k < 16; k++) begin @(negedge clk); rx_bit = c[k]; end
      @(negedge clk); rx_valid = 0; rx_bit = 0;
      repeat (3) @(negedge clk);
      nb = 0;
      e_lc++; e_len = LB; e_dt = 8'h2B; e_wc = 16'hFFFF; e_irq = 0;
      check("WC 65535");
    end
`endif

    // reset in the middle of a packet; the zero payload and its CRC hold no
    // B8 pattern, so the rest of the burst cannot fake a packet
    for (int i = 0; i < 64; i++) pay[i] = 8'h00;
    add_long(6'h2B, 2'd0, 64, 0, 0, 0);
    fork
      send(0, -1, 2);
      begin repeat (200) @(negedge clk); rst_n = 0; repeat (2) @(negedge clk); rst_n = 1; end
    join
    e_fc = 0; e_lc = 0; e_len = 0; e_irq = 0; e_act = 0; e_err = 0; e_dt = 0; e_wc = 0;
    check("reset mid-packet");
    line(6'h2B, 10); check("after reset");

    if (errors == 0) $display("TEST PASSED: CSI_2");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (300000) #1000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
