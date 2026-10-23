// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for USB_top (USB 1.1 FS device, EP0 + EP1 IN)
// The TB is the host: it drives tokens / data / handshakes on dp/dm at bit
// level (NRZI, bit stuffing, CRC5 / CRC16, EOP) and decodes the device's
// answers. Covered: enumeration (GET_DESCRIPTOR in 8-byte packets, short and
// zero-length packets, SET_ADDRESS taking effect after the status stage,
// SET/GET_CONFIGURATION), EP1 counter (NAK until configured, preset by the
// vendor request, increment on ACK only, DATA0/1 toggling, retransmit on lost
// ACK), protocol STALLs, duplicate data, every receive error class (CRC5,
// CRC16, stuffing, PID check, sync, truncation), ACK timeout, host NAK, bus
// reset and reset mid-packet.
// Under Verilator the bound checker (tb/cov/USB_sva.sv) predicts the device's
// line drive on every clock.
// ============================================================================
`timescale 1ns/1ps
module USB_tb;
  localparam int BC = 4;                         // clk per bit time (DUT default)

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // bus: device pull-up on D+, host pull-down on D-
  tri1  dp;
  tri0  dm;
  logic h_oe = 0, h_dp = 1, h_dm = 0;
  assign dp = h_oe ? h_dp : 1'bz;
  assign dm = h_oe ? h_dm : 1'bz;
  wire  irq;

  USB_top #(.BIT_CLKS(BC)) dut (.clk(clk), .rst_n(rst_n), .dp(dp), .dm(dm), .irq(irq));

  int errors = 0;
  task automatic fail(input string s);
    errors++; $display("ERROR: %s @%0t", s, $time);
  endtask

  localparam logic [3:0] OUT = 4'h1, IN = 4'h9, SOF = 4'h5, SETUP = 4'hD, DATA0 = 4'h3,
                         DATA1 = 4'hB, ACK = 4'h2, NAK = 4'hA, STALL = 4'hE, NONE = 4'h0;

  function automatic logic [4:0] crc5(input logic [10:0] v);
    logic [4:0] c;
    c = 5'h1F;
    for (int i = 0; i < 11; i++) c = (c[0] ^ v[i]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
    crc5 = ~c;
  endfunction
  function automatic logic [15:0] crc16(input logic [15:0] c, input logic [7:0] d);
    for (int k = 0; k < 8; k++) c = (c[0] ^ d[k]) ? ((c >> 1) ^ 16'hA001) : (c >> 1);
    crc16 = c;
  endfunction
  function automatic logic [7:0] desc(input int i);
    case (i)
      0: desc = 8'h12;  1: desc = 8'h01;  3: desc = 8'h02;  7: desc = 8'h08;
      8: desc = 8'h09;  9: desc = 8'h12; 10: desc = 8'h01; 13: desc = 8'h01;
      17: desc = 8'h01;
      default: desc = 8'h00;
    endcase
  endfunction

  // ------------------------------------------------------------------
  // host transmitter
  // ------------------------------------------------------------------
  logic [7:0] pk [0:63];        // packet bytes after SYNC (PID first)
  int         pk_n;
  // fault modes for the next packet
  int         f_cut = -1;       // SE0 after this many line bits
  bit         f_nostuff = 0;    // no bit stuffing -> stuff error at receiver
  bit         f_badsync = 0;
  logic       lvl;

  task automatic line_bit(input logic b);
    if (!b) lvl = !lvl;
    @(negedge clk); h_oe = 1; h_dp = lvl; h_dm = !lvl;
    repeat (BC - 1) @(negedge clk);
  endtask

  task automatic eop;
    @(negedge clk); h_oe = 1; h_dp = 0; h_dm = 0;
    repeat (2 * BC - 1) @(negedge clk);
    @(negedge clk); h_dp = 1; h_dm = 0;
    repeat (BC - 1) @(negedge clk);
    @(negedge clk); h_oe = 0;
  endtask

  task automatic tx_pkt;
    int ones, nbits;
    logic b;
    lvl = 1; ones = 0; nbits = 0;
    for (int k = 0; k < 8 && nbits != f_cut; k++) begin
      line_bit(f_badsync ? (k >= 6) : (k == 7)); nbits++;
    end
    for (int i = 0; i < pk_n && nbits != f_cut; i++)
      for (int k = 0; k < 8 && nbits != f_cut; k++) begin
        b = pk[i][k];
        line_bit(b); nbits++;
        ones = b ? ones + 1 : 0;
        if (ones == 6 && !f_nostuff && nbits != f_cut) begin line_bit(0); nbits++; ones = 0; end
      end
    eop();
    f_cut = -1; f_nostuff = 0; f_badsync = 0;
    repeat (2 * BC) @(negedge clk);
  endtask

  task automatic token(input logic [3:0] pid, input logic [6:0] a, input logic [3:0] ep,
                       input bit bad_crc = 0);
    logic [10:0] v;
    logic [4:0]  c;
    v = {ep, a};
    c = crc5(v) ^ (bad_crc ? 5'h01 : 5'h00);
    pk[0] = {~pid, pid}; pk[1] = v[7:0]; pk[2] = {c, v[10:8]}; pk_n = 3;
    tx_pkt();
  endtask

  logic [7:0] dbuf [0:63];      // data payload to send
  task automatic data(input logic [3:0] pid, input int n, input bit bad_crc = 0);
    logic [15:0] c;
    c = 16'hFFFF;
    pk[0] = {~pid, pid};
    for (int i = 0; i < n; i++) begin pk[1+i] = dbuf[i]; c = crc16(c, dbuf[i]); end
    c = ~c ^ (bad_crc ? 16'h0100 : 16'h0);
    pk[1+n] = c[7:0]; pk[2+n] = c[15:8]; pk_n = n + 3;
    tx_pkt();
  endtask

  task automatic hshake(input logic [3:0] pid);
    pk[0] = {~pid, pid}; pk_n = 1;
    tx_pkt();
  endtask

  // ------------------------------------------------------------------
  // host receiver: wait for a device packet, decode it
  // ------------------------------------------------------------------
  logic [3:0] r_pid;
  logic [7:0] r_buf [0:15];
  int         r_n;               // payload bytes (data packets)
  bit         r_crc_ok;

  task automatic rx_pkt(input int timeout = 200);
    int   t, nb, ones, nd;
    logic prev, b;
    logic [7:0] d [0:15];
    logic [15:0] c;
    t = 0; r_pid = NONE; r_n = 0; r_crc_ok = 0;
    while (!(dp === 1'b0 && dm === 1'b1) && t < timeout * BC) begin @(posedge clk); t++; end
    if (t < timeout * BC) begin
      repeat (BC / 2) @(posedge clk);
      prev = 1; nb = 0; ones = 0; nd = 0;
      for (int i = 0; i < 16; i++) d[i] = 0;
      while (!(dp === 1'b0 && dm === 1'b0)) begin
        b = (dp == prev); prev = dp;
        if (nb >= 8) begin
          if (ones == 6) ones = 0;               // stuffed bit
          else begin
            if (nd < 128) d[nd / 8][nd % 8] = b;
            nd++;
            ones = b ? ones + 1 : 0;
          end
        end
        nb++;
        repeat (BC) @(posedge clk);
      end
      while (!(dp === 1'b1 && dm === 1'b0)) @(posedge clk);    // EOP J
      while (dut.tx_oe) @(posedge clk);
      r_pid = d[0][3:0];
      if (d[0][7:4] != ~d[0][3:0]) fail("device PID check");
      if (r_pid == DATA0 || r_pid == DATA1) begin
        r_n = nd / 8 - 3;
        c = 16'hFFFF;
        for (int i = 0; i < r_n; i++) begin r_buf[i] = d[1+i]; c = crc16(c, d[1+i]); end
        r_crc_ok = {d[r_n+2], d[r_n+1]} == ~c;
        if (!r_crc_ok) fail("device CRC16");
      end
      repeat (2 * BC) @(negedge clk);
    end
  endtask

  task automatic expect_pid(input logic [3:0] p, input string s);
    if (r_pid !== p) fail($sformatf("%s: device PID %h exp %h", s, r_pid, p));
  endtask

  // ------------------------------------------------------------------
  // transactions
  // ------------------------------------------------------------------
  logic [6:0] A = 0;             // current device address
  logic       h_t0, h_t1;        // expected device IN toggles (EP0 / EP1)

  function automatic logic [63:0] pack8(input logic [7:0] b0, b1, b2, b3, b4, b5, b6, b7);
    pack8 = {b7, b6, b5, b4, b3, b2, b1, b0};
  endfunction

  task automatic setup8(input logic [63:0] b, input logic [3:0] expect_ = ACK);
    token(SETUP, A, 0);
    for (int i = 0; i < 8; i++) dbuf[i] = b[8*i +: 8];
    data(DATA0, 8);
    rx_pkt(); expect_pid(expect_, "setup");
    h_t0 = 1;
  endtask

  // IN on ep; ack_mode 0 = ACK, 1 = none (timeout), 2 = NAK
  task automatic in_tx(input logic [3:0] ep, input int ack_mode = 0);
    token(IN, A, ep);
    rx_pkt();
    if (r_pid == DATA0 || r_pid == DATA1)
      case (ack_mode)
        0: hshake(ACK);
        2: hshake(NAK);
        default: repeat (40 * BC) @(negedge clk);       // let the device time out
      endcase
  endtask

  task automatic out_tx(input logic [3:0] ep, input logic [3:0] pid, input int n,
                        input logic [3:0] expect_);
    token(OUT, A, ep);
    data(pid, n);
    rx_pkt(); expect_pid(expect_, "out");
  endtask

  // control read: GET_DESCRIPTOR(device) with wLength
  task automatic get_desc(input int wlen);
    logic [63:0] s;                  // SETUP bytes, byte 0 at [7:0]
    int got, total;
    s = pack8(8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'(wlen), 8'(wlen >> 8));
    setup8(s);
    total = (wlen > 18) ? 18 : wlen;
    got = 0;
    do begin
      in_tx(0);
      expect_pid(h_t0 ? DATA1 : DATA0, "descriptor toggle");
      for (int i = 0; i < r_n; i++)
        if (r_buf[i] !== desc(got + i)) fail($sformatf("descriptor byte %0d", got + i));
      got += r_n; h_t0 = !h_t0;
    end while (r_n == 8 && got < total);
    if (got != total) fail($sformatf("descriptor length %0d exp %0d", got, total));
    out_tx(0, DATA1, 0, ACK);                       // status stage
  endtask

  // control write without data stage + IN status (ZLP)
  task automatic ctl_write(input logic [7:0] bm, input logic [7:0] rq, input logic [15:0] val,
                           input logic [15:0] idx);
    logic [63:0] s;                  // SETUP bytes, byte 0 at [7:0]
    s = pack8(bm, rq, val[7:0], val[15:8], idx[7:0], idx[15:8], 8'h00, 8'h00);
    setup8(s);
    in_tx(0);
    expect_pid(DATA1, "status ZLP");
    if (r_n != 0) fail("status stage not zero length");
  endtask

  task automatic set_addr(input logic [6:0] a);
    ctl_write(8'h00, 8'h05, {9'h0, a}, 16'h0);
    A = a;
  endtask

  task automatic get_cfg(input logic exp_v);
    logic [63:0] s;                  // SETUP bytes, byte 0 at [7:0]
    s = pack8(8'h80, 8'h08, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00);
    setup8(s);
    in_tx(0);
    expect_pid(DATA1, "get_configuration");
    if (r_n != 1 || r_buf[0] !== {7'h0, exp_v}) fail("get_configuration value");
    out_tx(0, DATA1, 0, ACK);
  endtask

  logic [31:0] cnt_exp;
  task automatic ep1_read(input int ack_mode = 0);
    in_tx(1, ack_mode);
    expect_pid(h_t1 ? DATA1 : DATA0, "ep1 toggle");
    if (r_n != 4 || {r_buf[3], r_buf[2], r_buf[1], r_buf[0]} !== cnt_exp)
      fail($sformatf("ep1 counter %h exp %h", {r_buf[3], r_buf[2], r_buf[1], r_buf[0]}, cnt_exp));
    if (ack_mode == 0) begin h_t1 = !h_t1; cnt_exp++; end
  endtask

  task automatic bus_reset;
    @(negedge clk); h_oe = 1; h_dp = 0; h_dm = 0;
    repeat (40 * BC) @(negedge clk);
    h_dp = 1;
    repeat (BC) @(negedge clk);
    h_oe = 0;
    repeat (4 * BC) @(negedge clk);
    A = 0; h_t1 = 0;
  endtask

  task automatic expect_irq(input logic v, input string s);
    if (irq !== v) fail($sformatf("%s: irq=%b exp %b", s, irq, v));
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [63:0] s;                  // SETUP bytes, byte 0 at [7:0]
  initial begin
    for (int i = 0; i < 64; i++) dbuf[i] = 8'h00;
    repeat (4) @(negedge clk);
    if (irq || dut.tx_oe) fail("reset state");
    rst_n = 1;
    repeat (10) @(negedge clk);
    h_t0 = 0; h_t1 = 0;

    // ---------------- default state
    in_tx(1); expect_pid(NAK, "ep1 before configuration");
    in_tx(0); expect_pid(STALL, "ep0 IN without request");
    in_tx(5); expect_pid(STALL, "IN to missing endpoint");
    out_tx(1, DATA0, 2, STALL);
    token(SOF, 7'h55, 4'hA);                          // SOF ignored
    rx_pkt(20); expect_pid(NONE, "SOF answered");

    // ---------------- enumeration
    get_desc(64);
    get_desc(18);
    get_desc(8);
    get_desc(5);
    get_desc(13);
    for (int i = 0; i < 4; i++) get_desc(1 + $urandom % 30);
    set_addr(7'h2A);
    token(IN, 7'h00, 0); rx_pkt(20); expect_pid(NONE, "old address answered");
    get_desc(18);
    set_addr(7'h55);
    get_cfg(0);
    ctl_write(8'h00, 8'h09, 16'h0001, 16'h0);       // SET_CONFIGURATION 1
    get_cfg(1);

    // ---------------- EP1 counter
    cnt_exp = 0; h_t1 = 0;
    ep1_read(); ep1_read(); ep1_read();
    ep1_read(1);                                      // no ACK: resend same data
    ep1_read(2);                                      // host NAK: resend
    ep1_read();
    for (int r = 0; r < 4; r++) begin                 // vendor preset, all bits
      logic [31:0] v;
      v = (r == 0) ? 32'hFFFF_FFFF : (r == 1) ? 32'h0 : $urandom;
      ctl_write(8'h40, 8'h01, v[15:0], v[31:16]);
      cnt_exp = v;
      ep1_read(); ep1_read();
    end
    // a counter value whose packet ends in six 1s: stuff bit right before EOP
    for (int k = 0; k < 2; k++) begin
      logic [31:0] v;
      logic [15:0] c;
      do begin
        v = $urandom; c = 16'hFFFF;
        for (int i = 0; i < 4; i++) c = crc16(c, v[8*i +: 8]);
      end while (c[15:9] != 7'b0000001);           // last byte ~c[15:8] = 111111 0 x
      ctl_write(8'h40, 8'h01, v[15:0], v[31:16]);
      cnt_exp = v;
      ep1_read();
    end
    ctl_write(8'h40, 8'h01, 16'hFFFF, 16'hFFFF);
    cnt_exp = 32'hFFFF_FFFF;
    ep1_read(); ep1_read();                           // wraps to 0

    // ---------------- protocol stalls / duplicates
    s = pack8(8'h80, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00);   // GET_STATUS
    setup8(s);
    in_tx(0); expect_pid(STALL, "unsupported request IN");
    out_tx(0, DATA1, 0, STALL);
    for (int i = 0; i < 8; i++) begin                 // random unsupported requests
      s = {$urandom, $urandom};
      s[7:0] = (i % 2) ? 8'h00 : 8'h80;
      if (s[15:8] == 8'h05 || s[15:8] == 8'h06 || s[15:8] == 8'h08 || s[15:8] == 8'h09)
        s[15:8] = 8'h0C;
      setup8(s);
      in_tx(0); expect_pid(STALL, "random request");
    end
    s = pack8(8'h00, 8'h09, 8'h02, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00);   // config 2: bad
    setup8(s); in_tx(0); expect_pid(STALL, "set_configuration 2");
    s = pack8(8'h00, 8'h05, 8'h80, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00);   // address 128: bad
    setup8(s); in_tx(0); expect_pid(STALL, "set_address 128");
    // SETUP with 7 bytes: stalled
    token(SETUP, A, 0);
    for (int i = 0; i < 7; i++) dbuf[i] = 8'h00;
    data(DATA0, 7); rx_pkt(); expect_pid(ACK, "short setup acked");
    in_tx(0); expect_pid(STALL, "short setup");
    // control read then OUT status sent twice (second is a duplicate)
    s = pack8(8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h04, 8'h00);
    setup8(s);
    in_tx(0); expect_pid(DATA1, "desc 4");
    out_tx(0, DATA1, 0, ACK);
    out_tx(0, DATA1, 0, ACK);                         // duplicate: acked, ignored
    out_tx(0, DATA0, 0, ACK);
    // long OUT data packet (dlen saturates)
    for (int i = 0; i < 40; i++) dbuf[i] = 8'($urandom);
    out_tx(0, DATA1, 36, ACK);
    // SETUP data with DATA1 PID: acked, ignored
    token(SETUP, A, 0);
    for (int i = 0; i < 8; i++) dbuf[i] = 8'($urandom);
    data(DATA1, 8); rx_pkt(); expect_pid(ACK, "setup DATA1");
    in_tx(0); expect_pid(STALL, "after ignored setup");
    // SETUP to EP1 is stalled
    token(SETUP, A, 1); for (int i = 0; i < 8; i++) dbuf[i] = 0;
    data(DATA0, 8); rx_pkt(); expect_pid(STALL, "setup to ep1");
    // data without a token is ignored
    data(DATA0, 2); rx_pkt(20); expect_pid(NONE, "stray data");

    // ---------------- receive errors
    token(IN, A, 1, 1); rx_pkt(20); expect_pid(NONE, "bad CRC5 IN");
    expect_irq(1, "bad CRC5");
    ep1_read(); expect_irq(0, "irq cleared by good token");
    token(OUT, A, 0, 1); rx_pkt(20); expect_irq(1, "bad CRC5 OUT");
    ep1_read();
    token(OUT, A, 0); data(DATA0, 2, 1); rx_pkt(20); expect_pid(NONE, "bad CRC16");
    expect_irq(1, "bad CRC16");
    ep1_read();
    f_nostuff = 1; token(IN, 7'h7F, 4'hF); rx_pkt(20);  // 6+ ones unstuffed
    expect_irq(1, "stuff error in token");
    ep1_read();
    token(OUT, A, 0); for (int i = 0; i < 4; i++) dbuf[i] = 8'hFF;
    f_nostuff = 1; data(DATA1, 4); rx_pkt(20); expect_pid(NONE, "stuff error in data");
    ep1_read();
    pk[0] = 8'h3F; pk[1] = 8'h00; pk_n = 2; tx_pkt();           // PID check fails
    rx_pkt(20); expect_pid(NONE, "bad PID");                     // (six 1s + stuff bit)
    f_nostuff = 1; pk[0] = 8'hFF; pk_n = 1; tx_pkt();             // stuff error in PID
    rx_pkt(20); expect_pid(NONE, "bad PID 2");
    pk[0] = 8'h00; pk_n = 1; tx_pkt();
    rx_pkt(20); expect_pid(NONE, "bad PID 3");
    f_badsync = 1; token(IN, A, 1); rx_pkt(20); expect_pid(NONE, "bad sync");
    f_cut = 5; token(IN, A, 1); rx_pkt(20); expect_pid(NONE, "SE0 in sync");
    f_cut = 12; token(IN, A, 1); rx_pkt(20); expect_pid(NONE, "SE0 in PID");
    f_cut = 20; token(IN, A, 1); rx_pkt(20); expect_irq(1, "truncated token");
    ep1_read();
    token(OUT, A, 0); f_cut = 20; data(DATA1, 2); rx_pkt(20);
    token(OUT, A, 0); data(DATA1, 0); rx_pkt();                  // recover
    hshake(ACK); hshake(NAK); hshake(STALL);                     // ignored when idle
    // tokens to other addresses, random endpoints (token field toggles)
    for (int i = 0; i < 12; i++) begin
      token((i % 3 == 0) ? IN : (i % 3 == 1) ? OUT : SETUP, 7'($urandom) | 7'h01 ^ A,
            4'($urandom));
      rx_pkt(10);
    end
    // while waiting for an ACK, another packet arrives
    token(IN, A, 1); rx_pkt();
    token(IN, A, 1); rx_pkt();
    hshake(ACK);
    cnt_exp++; h_t1 = !h_t1;
    ep1_read();

    // ---------------- descriptor reads that end with a zero-length packet
    s = pack8(8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h08, 8'h00);
    setup8(s);
    in_tx(0); in_tx(0);
    if (r_n != 0) fail("ZLP after full descriptor");
    out_tx(0, DATA1, 0, ACK);
    for (int i = 0; i < 6; i++) get_desc(1 + $urandom % 18);

    // ---------------- bus reset
    bus_reset();
    in_tx(1); expect_pid(NAK, "ep1 after bus reset");
    get_desc(18);
    set_addr(7'h01);
    ctl_write(8'h00, 8'h09, 16'h0001, 16'h0);
    ctl_write(8'h00, 8'h09, 16'h0000, 16'h0);         // back to unconfigured
    get_cfg(0);
    ctl_write(8'h00, 8'h09, 16'h0001, 16'h0);
    for (int a = 0; a < 7; a++) set_addr(7'h1 << a);  // all address bits
    set_addr(7'h7F); set_addr(7'h00);

    // ---------------- reset while the device transmits
    token(IN, A, 1);
    while (!dut.tx_oe) @(negedge clk);
    repeat (10) @(negedge clk);
    rst_n = 0; @(negedge clk); rst_n = 1;
    repeat (20 * BC) @(negedge clk);
    A = 0; h_t0 = 0; h_t1 = 0;
    in_tx(1); expect_pid(NAK, "after reset");

    if (errors == 0) $display("TEST PASSED: USB");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #40_000_000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
