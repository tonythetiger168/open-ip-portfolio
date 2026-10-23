// SPDX-License-Identifier: Apache-2.0
// CSI_2-specific part of tb/CSI_2_apb_tb.sv. The TB is the camera
// transmitter on rx_bit / rx_valid (HS-zero lead-in, B8 sync, packets,
// trailer), with the header ECC and CRC-16 computed here; a scoreboard
// predicts STATUS, COUNTS, LAST and the readable line, all read through
// the registers.
// Checked: FS / FE / generic short packets, long packets of 0..520 bytes
// (past the line buffer), corrected header and ECC-byte bits, double
// errors (dropped), a bad CRC (previous line kept), bursts cut inside a
// packet, several packets in one burst, line bytes through LB_ADDR /
// LB_DATA (all ones, all zeros, random), random traffic; under Verilator
// the 16-bit counters wrapping and a 65535-byte packet.
// Covered through the registers: ERROR from a bad CRC and an
// uncorrectable header, held until a good packet, masked, raising irq and
// cleared.
localparam int LB = 512;
initial begin rx_bit = 0; rx_valid = 0; end
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

// burst builder
logic [7:0] bb [0:2047];
int         nb = 0;
logic [7:0] pay [0:1023];
task automatic add(input logic [7:0] b); bb[nb] = b; nb++; endtask
task automatic add_short(input logic [5:0] dt, input logic [1:0] vc, input logic [15:0] d,
                         input logic [23:0] hx, input logic [7:0] ex);
  logic [23:0] h;
  h = {d, vc, dt};
  add(h[7:0] ^ hx[7:0]); add(h[15:8] ^ hx[15:8]); add(h[23:16] ^ hx[23:16]);
  add({2'b00, ecc24(h)} ^ ex);
endtask
task automatic add_long(input logic [5:0] dt, input logic [1:0] vc, input int wc,
                        input logic [23:0] hx, input logic [7:0] ex, input bit bad_crc);
  logic [15:0] c;
  add_short(dt, vc, 16'(wc), hx, ex);
  c = 16'hFFFF;
  for (int i = 0; i < wc; i++) begin add(pay[i]); c = crc16(c, pay[i]); end
  if (bad_crc) c = c ^ 16'h0040;
  add(c[7:0]); add(c[15:8]);
endtask
// lead HS-zero bits, B8, the bytes (cut after cut_bits bits when >= 0), trailer
task automatic send(input int lead, input int cut_bits, input int trail);
  int sent;
  logic last;
  sent = 0; last = 0;
  for (int i = 0; i < lead; i++) begin @(negedge PCLK); rx_valid = 1; rx_bit = 0; end
  for (int i = 0; i < 8; i++) begin @(negedge PCLK); rx_valid = 1; rx_bit = 8'hB8 >> i; end
  for (int k = 0; k < nb; k++)
    for (int i = 0; i < 8; i++)
      if (cut_bits < 0 || sent < cut_bits) begin
        @(negedge PCLK); rx_valid = 1; rx_bit = bb[k][i]; last = rx_bit; sent++;
      end
  for (int i = 0; i < trail; i++) begin @(negedge PCLK); rx_bit = ~last; end
  @(negedge PCLK); rx_valid = 0; rx_bit = 0;
  repeat (4) @(negedge PCLK);
  nb = 0;
endtask

// scoreboard
int          e_fc = 0, e_lc = 0, e_len = 0;
logic        e_irq = 0, e_act = 0;
logic [3:0]  e_err = 0;
logic [7:0]  e_dt = 0;
logic [15:0] e_wc = 0;
logic [7:0]  e_line [0:LB-1];
task automatic sb_short(input logic [5:0] dt, input logic [1:0] vc, input logic [15:0] d, input bit corr);
  e_dt = {vc, dt}; e_wc = d; e_irq = 0;
  if (dt == 6'h00) begin e_fc++; e_lc = 0; e_act = 1; e_err = {corr, 3'b000}; end
  else begin if (dt == 6'h01) e_act = 0; if (corr) e_err[3] = 1; end
endtask
task automatic sb_long(input logic [5:0] dt, input logic [1:0] vc, input int wc, input bit corr, input bit bad_crc);
  e_dt = {vc, dt}; e_wc = 16'(wc);
  if (corr) e_err[3] = 1;
  if (bad_crc) begin e_irq = 1; e_err[0] = 1; end
  else begin
    e_irq = 0; e_lc++; e_len = wc > LB ? LB : wc;
    for (int i = 0; i < LB; i++) if (i < e_len) e_line[i] = pay[i];
  end
endtask
// check through the registers; step: every step-th line byte (1: all)
task automatic check(input string tag, input int step = 0);
  int i;
  rd_exp(A_STATUS, {11'd0, 16'(e_len), e_err, e_act});
  rd_exp(A_COUNTS, {16'(e_lc), 16'(e_fc)});
  rd_exp(A_LAST, {8'd0, e_wc, e_dt});
  // ERROR: held by the core while an error stands, so a clear does not hold
  if (e_irq) rd_exp(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd_exp(A_IRQ_STATUS, e_irq ? IRQ_ALL : 0);
  if (step > 0) begin
    i = 0;
    while (i < e_len) begin
      wr(A_LB_ADDR, i);
      rd_exp(A_LB_DATA, e_line[i]);
      i = (i + step < e_len || i == e_len - 1) ? i + step : e_len - 1;
    end
  end
endtask
task automatic line(input logic [5:0] dt, input int wc, input int step = 0);
  for (int i = 0; i < wc; i++) pay[i] = $urandom;
  add_long(dt, 2'd0, wc, 0, 0, 0); send($urandom_range(0, 12), -1, 4);
  sb_long(dt, 2'd0, wc, 0, 0);
  check("line", step);
endtask
task automatic short(input logic [5:0] dt, input logic [15:0] d);
  add_short(dt, 2'd1, d, 0, 0); send(3, -1, 4); sb_short(dt, 2'd1, d, 0);
  check("short");
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rd_exp(A_FLAGS, 0);
  check("reset");
  short(6'h00, 16'h0001);                  // FS
  line(6'h2B, 16, 1);
  line(6'h2B, 1, 1);
  line(6'h24, 0);
  line(6'h2C, LB + 8, 23);
  line(6'h1E, 300, 41);
  line(6'h2B, 200, 33);                  // lb_len bits 6, 7
  line(6'h24, 0);
  short(6'h02, 16'h0007);
  short(6'h08, 16'hBEEF);
  short(6'h01, 16'h0001);                  // FE
  // corrected header and ECC-byte bits
  short(6'h00, 16'h0002);
  for (int b = 0; b < 24; b += 5) begin
    for (int i = 0; i < 8; i++) pay[i] = $urandom;
    add_long(6'h2B, 2'd2, 8, 24'h1 << b, 0, 0); send(1, -1, 2);
    sb_long(6'h2B, 2'd2, 8, 1, 0);
    check("header bit corrected");
  end
  add_short(6'h08, 2'd0, 16'h5, 0, 8'h20); send(2, -1, 3);
  sb_short(6'h08, 2'd0, 16'h5, 1);
  check("ECC bit");
  // FS with a corrected header: the frame starts with only flag 3 set
  add_short(6'h00, 2'd0, 16'h0003, 24'h000400, 0); send(0, -1, 1);
  sb_short(6'h00, 2'd0, 16'h0003, 1);
  check("FS corrected");
  // uncorrectable header: dropped, ERROR held until a good packet
  add_long(6'h2B, 2'd0, 8, 24'h000011, 0, 0); send(2, -1, 2);
  e_irq = 1; e_err[1] = 1;
  check("double header error");
  line(6'h2B, 12, 1);                      // releases ERROR
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd_exp(A_IRQ_STATUS, 0);
  // bad CRC: the previous line stays readable
  for (int i = 0; i < 8; i++) pay[i] = $urandom;
  add_long(6'h2B, 2'd0, 8, 0, 0, 1); send(2, -1, 2);
  sb_long(6'h2B, 2'd0, 8, 0, 1);
  check("bad CRC", 1);
  if (!irq) fail("irq low with ERROR set and enabled");
  short(6'h00, 16'h0004);                  // FS clears the flags and ERROR
  wr(A_IRQ_STATUS, IRQ_ALL);
  // bursts cut inside a packet
  for (int cut = 4; cut < 96; cut += 23) begin
    for (int i = 0; i < 6; i++) pay[i] = $urandom;
    add_long(6'h2B, 2'd0, 6, 0, 0, 0); send(1, cut, 0);
    e_err[2] = 1; if (cut >= 32) begin e_dt = 8'h2B; e_wc = 6; end
    check("cut burst");
  end
  // three packets in one burst, junk after
  for (int i = 0; i < 20; i++) pay[i] = $urandom;
  add_short(6'h02, 2'd3, 16'h11, 0, 0); add(8'hB8);
  add_long(6'h2B, 2'd3, 20, 0, 0, 0); add(8'hB8);
  add_short(6'h03, 2'd3, 16'h11, 0, 0); add(8'h5A); add(8'hB8);
  add_short(6'h00, 2'd0, 16'h0, 0, 0);
  send(5, -1, 6);
  sb_short(6'h02, 2'd3, 16'h11, 0); sb_long(6'h2B, 2'd3, 20, 0, 0); sb_short(6'h03, 2'd3, 16'h11, 0);
  check("three packets", 1);
  // random traffic
  for (int t = 0; t < 60; t++) begin
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
      for (int i = 0; i < wc; i++) pay[i] = $urandom;
      add_long(6'h2A, vc, wc, 24'h1 << $urandom_range(0, 23), 0, 0); send(2, -1, 2);
      sb_long(6'h2A, vc, wc, 1, 0);
    end else begin
      wc = $urandom_range(1, 70);
      add_long(6'h2B, vc, 4, 0, 0, 0); send(2, wc, 0);
      e_err[2] = 1; if (wc >= 32) begin e_dt = {vc, 6'h2B}; e_wc = 4; end
    end
    check("random", t % 8 == 0 ? 7 : 0);
  end
`ifdef VERILATOR
  // counters wrap modulo 2^16: 65537 empty lines, then 65537 frames, then
  // the largest long packet (Verilator only: about 9M clocks)
  short(6'h00, 16'h0);
  add_long(6'h2B, 2'd0, 0, 0, 0, 0);
  for (int i = 0; i < 65537; i++) begin
    for (int k = 0; k < 8; k++) begin @(negedge PCLK); rx_valid = 1; rx_bit = 8'hB8 >> k; end
    for (int j = 0; j < 6; j++)
      for (int k = 0; k < 8; k++) begin @(negedge PCLK); rx_bit = bb[j][k]; end
    @(negedge PCLK); rx_valid = 0; rx_bit = 0;
  end
  @(negedge PCLK);
  nb = 0;
  e_lc = 1; e_len = 0; e_dt = 8'h2B; e_wc = 0;
  check("line counter wrapped");
  add_short(6'h00, 2'd0, 16'h0, 0, 0);
  for (int i = 0; i < 65537; i++) begin
    for (int k = 0; k < 8; k++) begin @(negedge PCLK); rx_valid = 1; rx_bit = 8'hB8 >> k; end
    for (int j = 0; j < 4; j++)
      for (int k = 0; k < 8; k++) begin @(negedge PCLK); rx_bit = bb[j][k]; end
    @(negedge PCLK); rx_valid = 0; rx_bit = 0;
  end
  @(negedge PCLK);
  nb = 0;
  e_fc = (e_fc + 65537) % 65536; e_lc = 0; e_dt = 8'h00; e_wc = 0; e_err = 0;
  check("frame counter wrapped");
  begin
    logic [15:0] c;
    logic [7:0]  d;
    add_short(6'h2B, 2'd0, 16'hFFFF, 0, 0);
    for (int k = 0; k < 8; k++) begin @(negedge PCLK); rx_valid = 1; rx_bit = 8'hB8 >> k; end
    for (int j = 0; j < 4; j++)
      for (int k = 0; k < 8; k++) begin @(negedge PCLK); rx_bit = bb[j][k]; end
    c = 16'hFFFF;
    for (int i = 0; i < 65535; i++) begin
      d = 8'(i) ^ 8'(i >> 8);
      if (i < LB) e_line[i] = d;
      c = crc16(c, d);
      for (int k = 0; k < 8; k++) begin @(negedge PCLK); rx_bit = d[k]; end
    end
    for (int k = 0; k < 16; k++) begin @(negedge PCLK); rx_bit = c[k]; end
    @(negedge PCLK); rx_valid = 0; rx_bit = 0;
    repeat (3) @(negedge PCLK);
    nb = 0;
    e_lc++; e_len = LB; e_dt = 8'h2B; e_wc = 16'hFFFF; e_irq = 0;
    check("WC 65535", 97);
  end
`endif
  // line bytes all ones then all zeros, every 8th byte read
  for (int i = 0; i < LB; i++) pay[i] = 8'hFF;
  add_long(6'h2B, 2'd0, LB, 0, 0, 0); send(0, -1, 1); sb_long(6'h2B, 2'd0, LB, 0, 0); check("all ones", 64);
  for (int i = 0; i < LB; i++) pay[i] = 8'h00;
  add_long(6'h2B, 2'd0, LB, 0, 0, 0); send(0, -1, 1); sb_long(6'h2B, 2'd0, LB, 0, 0); check("all zeros", 64);
  // masked: left pending into reset
  wr(A_IRQ_ENABLE, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  for (int i = 0; i < 4; i++) pay[i] = $urandom;
  add_long(6'h2B, 2'd0, 4, 0, 0, 1); send(2, -1, 2);
  cycles(3);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
