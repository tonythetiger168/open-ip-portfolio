// IP part of USB2_apb_tb: the host model of the core TB (tokens, data and
// handshakes on dp/dm at bit level with NRZI, bit stuffing, CRC5 / CRC16 and
// EOP; device packets decoded and checked). Enumeration, the EP1 counter with
// toggles and retransmits, protocol STALLs, every receive-error class through
// IRQ_STATUS.RXERR (held until a good token; masked and on the irq pin), a bus
// reset and PRESETN while the device transmits; the chirp handshake in
// STATUS.HS_MODE (high speed, late, short and missing host chirps), 64-byte
// packets and the device_qualifier in high speed, SOF tracking in FRAME.
  localparam int BC = 4;                         // PCLK per bit time
  logic h_oe = 0, h_dp = 1, h_dm = 0;
  assign dp = h_oe ? h_dp : 1'bz;
  assign dm = h_oe ? h_dm : 1'bz;
  pullup   pu_dp (dp);                           // device pull-up on D+
  pulldown pd_dm (dm);                           // host pull-down on D-

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
  function automatic logic [7:0] desc(input logic q, input int i);
    if (q)
      case (i)
        0: desc = 8'h0A;  1: desc = 8'h06;  3: desc = 8'h02;
        7: desc = dut.c_hs_mode ? 8'h08 : 8'h40;  8: desc = 8'h01;
        default: desc = 8'h00;
      endcase
    else
    case (i)
      0: desc = 8'h12;  1: desc = 8'h01;  3: desc = 8'h02;  7: desc = dut.c_hs_mode ? 8'h40 : 8'h08;
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
    @(negedge PCLK); h_oe = 1; h_dp = lvl; h_dm = !lvl;
    repeat (BC - 1) @(negedge PCLK);
  endtask

  task automatic eop;
    @(negedge PCLK); h_oe = 1; h_dp = 0; h_dm = 0;
    repeat (2 * BC - 1) @(negedge PCLK);
    @(negedge PCLK); h_dp = 1; h_dm = 0;
    repeat (BC - 1) @(negedge PCLK);
    @(negedge PCLK); h_oe = 0;
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
    repeat (2 * BC) @(negedge PCLK);
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
  logic [7:0] r_buf [0:31];
  int         r_n;               // payload bytes (data packets)
  bit         r_crc_ok;

  task automatic rx_pkt(input int timeout = 200);
    int   t, nb, ones, nd;
    logic prev, b;
    logic [7:0] d [0:31];
    logic [15:0] c;
    t = 0; r_pid = NONE; r_n = 0; r_crc_ok = 0;
    while (!(dp === 1'b0 && dm === 1'b1) && t < timeout * BC) begin @(posedge PCLK); t++; end
    if (t < timeout * BC) begin
      repeat (BC / 2) @(posedge PCLK);
      prev = 1; nb = 0; ones = 0; nd = 0;
      for (int i = 0; i < 32; i++) d[i] = 0;
      while (!(dp === 1'b0 && dm === 1'b0)) begin
        b = (dp == prev); prev = dp;
        if (nb >= 8) begin
          if (ones == 6) ones = 0;               // stuffed bit
          else begin
            if (nd < 256) d[nd / 8][nd % 8] = b;
            nd++;
            ones = b ? ones + 1 : 0;
          end
        end
        nb++;
        repeat (BC) @(posedge PCLK);
      end
      while (!(dp === 1'b1 && dm === 1'b0)) @(posedge PCLK);    // EOP J
      while (dut.u_core.tx_oe) @(posedge PCLK);
      r_pid = d[0][3:0];
      if (d[0][7:4] != ~d[0][3:0]) fail("device PID check");
      if (r_pid == DATA0 || r_pid == DATA1) begin
        r_n = nd / 8 - 3;
        c = 16'hFFFF;
        for (int i = 0; i < r_n; i++) begin r_buf[i] = d[1+i]; c = crc16(c, d[1+i]); end
        r_crc_ok = {d[r_n+2], d[r_n+1]} == ~c;
        if (!r_crc_ok) fail("device CRC16");
      end
      repeat (2 * BC) @(negedge PCLK);
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
        default: repeat (40 * BC) @(negedge PCLK);       // let the device time out
      endcase
  endtask

  task automatic out_tx(input logic [3:0] ep, input logic [3:0] pid, input int n,
                        input logic [3:0] expect_);
    token(OUT, A, ep);
    data(pid, n);
    rx_pkt(); expect_pid(expect_, "out");
  endtask

  // control read: GET_DESCRIPTOR(device) with wLength
  task automatic get_desc(input int wlen, input bit q = 0);
    logic [63:0] s;                  // SETUP bytes, byte 0 at [7:0]
    int got, total;
    s = pack8(8'h80, 8'h06, 8'h00, q ? 8'h06 : 8'h01, 8'h00, 8'h00, 8'(wlen), 8'(wlen >> 8));
    setup8(s);
    total = (wlen > (q ? 10 : 18)) ? (q ? 10 : 18) : wlen;
    got = 0;
    do begin
      in_tx(0);
      expect_pid(h_t0 ? DATA1 : DATA0, "descriptor toggle");
      for (int i = 0; i < r_n; i++)
        if (r_buf[i] !== desc(q, got + i)) fail($sformatf("descriptor byte %0d", got + i));
      got += r_n; h_t0 = !h_t0;
    end while (r_n == (dut.c_hs_mode ? 64 : 8) && got < total);
    if (dut.c_hs_mode && total > 8 && r_n != total) fail("high-speed descriptor not one packet");
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

  // bus reset; then the device chirps K. mode: 0 = host answers K J K J K J
  // (high speed), 1 = no host chirps (full speed), 2 = chirps too short,
  // 3 = only two pairs then idle J (the idle J completes the third pair),
  // 4 = host answers late (within the listen window), K J K J K J
  task automatic bus_reset(input int mode = 1);
    int t;
    @(negedge PCLK); h_oe = 1; h_dp = 0; h_dm = 0;
    repeat (40 * BC) @(negedge PCLK);
    h_oe = 0;                                       // release: pull-up J
    t = 0;
    while (!(dp === 1'b0 && dm === 1'b1) && t < 50) begin @(negedge PCLK); t++; end
    if (t >= 50) fail("no device chirp K");
    t = 0;
    while (dp === 1'b0 && dm === 1'b1) begin @(negedge PCLK); t++; end
    if (t != 64) fail($sformatf("device chirp K lasted %0d PCLK", t));
    repeat ((mode == 4) ? 300 : 3) @(negedge PCLK);
    case (mode)
      0, 3, 4: for (int i = 0; i < ((mode == 3) ? 5 : 6); i++) begin
        h_oe = 1; h_dp = i % 2; h_dm = !(i % 2);
        repeat (20) @(negedge PCLK);
      end
      2: for (int i = 0; i < 24; i++) begin
        h_oe = 1; h_dp = i % 2; h_dm = !(i % 2);
        repeat (10) @(negedge PCLK);
      end
      default: ;
    endcase
    h_oe = 0;
    if (mode == 0 || mode == 3 || mode == 4) begin
      repeat (25) @(negedge PCLK);
      if (!dut.c_hs_mode) fail("high-speed handshake");
    end else begin
      repeat (600) @(negedge PCLK);
      if (dut.c_hs_mode) fail("full-speed fallback");
    end
    repeat (4 * BC) @(negedge PCLK);
    A = 0; h_t1 = 0;
  endtask

  task automatic sof(input logic [10:0] fn, input logic [2:0] exp_uf, input bit bad = 0);
    logic [31:0] f0;
    f0 = {18'h0, dut.c_uframe, dut.c_frame_no};
    token(SOF, fn[6:0], fn[10:7], bad);
    rd_exp(A_FRAME, bad ? f0 : {18'h0, exp_uf, fn});
  endtask


  // a receive error: RXERR is held while the core flag is; a good token to
  // the device clears the flag, then the w1c clears the bit
  task automatic rx_err(input bit en, input string what);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_RXERR);
    if (dut.c_irq !== 1'b1) fail({what, ": core flag"});
    if (irq !== en) fail({what, ": irq pin vs enable"});
    wr(A_IRQ_STATUS, 1 << IRQ_RXERR);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_RXERR);                  // still held
    ep1_read();
    if (dut.c_irq !== 1'b0) fail({what, ": good token did not clear the flag"});
    wr(A_IRQ_STATUS, 1 << IRQ_RXERR);
    rd_exp(A_IRQ_STATUS, 0);
    if (irq !== 1'b0) fail({what, ": irq pin after clear"});
  endtask

  logic [63:0] s;                  // SETUP bytes, byte 0 at [7:0]
  task automatic ip_func;
    for (int i = 0; i < 64; i++) dbuf[i] = 8'h00;
    rd_exp(A_FLAGS, 0);
    h_t0 = 0; h_t1 = 0;

    // ---------------- default state
    in_tx(1); expect_pid(NAK, "ep1 before configuration");
    in_tx(0); expect_pid(STALL, "ep0 IN without request");
    in_tx(5); expect_pid(STALL, "IN to missing endpoint");
    out_tx(1, DATA0, 2, STALL);
    token(SOF, 7'h55, 4'hA);
    rx_pkt(20); expect_pid(NONE, "SOF answered");

    // ---------------- enumeration
    get_desc(64);
    get_desc(18);
    get_desc(5);
    get_desc(13);
    set_addr(7'h2A);
    token(IN, 7'h00, 0); rx_pkt(20); expect_pid(NONE, "old address answered");
    get_desc(18);
    set_addr(7'h55);
    get_cfg(0);
    ctl_write(8'h00, 8'h09, 16'h0001, 16'h0);       // SET_CONFIGURATION 1
    get_cfg(1);

    // ---------------- EP1 counter
    cnt_exp = 0; h_t1 = 0;
    ep1_read(); ep1_read();
    ep1_read(1);                                      // no ACK: resend same data
    ep1_read(2);                                      // host NAK: resend
    ep1_read();
    ctl_write(8'h40, 8'h01, 16'hBEEF, 16'hDEAD);      // vendor preset
    cnt_exp = 32'hDEAD_BEEF;
    ep1_read(); ep1_read();

    // ---------------- protocol stall (no RXERR)
    s = pack8(8'h80, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00);   // GET_STATUS
    setup8(s);
    in_tx(0); expect_pid(STALL, "unsupported request IN");
    out_tx(0, DATA1, 0, STALL);
    rd_exp(A_IRQ_STATUS, 0);

    // ---------------- receive errors, masked
    token(IN, A, 1, 1); rx_pkt(20); expect_pid(NONE, "bad CRC5 IN");
    rx_err(0, "bad CRC5");
    token(OUT, A, 0); data(DATA0, 2, 1); rx_pkt(20); expect_pid(NONE, "bad CRC16");
    rx_err(0, "bad CRC16");
    // ---------------- receive errors on the irq pin
    wr(A_IRQ_ENABLE, 1 << IRQ_RXERR);
    f_nostuff = 1; token(IN, 7'h7F, 4'hF); rx_pkt(20);  // 6+ ones unstuffed
    rx_err(1, "stuff error in token");
    token(OUT, A, 0); for (int i = 0; i < 4; i++) dbuf[i] = 8'hFF;
    f_nostuff = 1; data(DATA1, 4); rx_pkt(20); expect_pid(NONE, "stuff error in data");
    rx_err(1, "stuff error in data");
    f_cut = 20; token(IN, A, 1); rx_pkt(20);
    rx_err(1, "truncated token");
    // bad sync and bad PIDs drop the packet without RXERR
    f_badsync = 1; token(IN, A, 1); rx_pkt(20); expect_pid(NONE, "bad sync");
    pk[0] = 8'h3F; pk[1] = 8'h00; pk_n = 2; tx_pkt();
    rx_pkt(20); expect_pid(NONE, "bad PID");
    rd_exp(A_IRQ_STATUS, 0);
    wr(A_IRQ_ENABLE, 0);

    // ---------------- SOF tracking (full speed): every frame_no / uframe bit
    for (int i = 0; i < 9; i++) sof(11'h7FF, 3'(i));
    sof(11'h000, 0); sof(11'h000, 1);
    for (int i = 0; i < 4; i++) sof(11'($urandom), 0);
    sof(11'h123, 0, 1);
    rx_err(0, "bad SOF");
    rd_exp(A_STATUS, 0);

    // ---------------- bus reset: speed detection
    bus_reset(2);                                   // short chirps: full speed
    rd_exp(A_STATUS, 0);
    bus_reset(1);                                   // no chirps: full speed
    get_desc(10, 1);
    bus_reset(4);                                   // late host chirps: high speed
    rd_exp(A_STATUS, 1);
    bus_reset(0);                                   // high speed
    rd_exp(A_STATUS, 1);
    in_tx(1); expect_pid(NAK, "ep1 after reset to high speed");
    get_desc(64);
    get_desc(64, 1);
    set_addr(7'h33);
    ctl_write(8'h00, 8'h09, 16'h0001, 16'h0);
    for (int i = 0; i < 9; i++) sof(11'h2AA, 3'(i));
    ctl_write(8'h40, 8'h01, 16'h1234, 16'h5678);
    cnt_exp = 32'h5678_1234; h_t1 = 0;
    ep1_read();

    // ---------------- bus reset (leaves high speed)
    bus_reset(1);
    rd_exp(A_STATUS, 0);
    in_tx(1); expect_pid(NAK, "ep1 after bus reset");
    get_desc(18);
    set_addr(7'h01);
    ctl_write(8'h00, 8'h09, 16'h0001, 16'h0);

    // ---------------- PRESETN while the device transmits
    token(IN, A, 1);
    while (!dut.u_core.tx_oe) @(negedge PCLK);
    repeat (10) @(negedge PCLK);
    PRESETN = 0; @(negedge PCLK); PRESETN = 1;
    repeat (20 * BC) @(negedge PCLK);
    check_reset_values();
    rd_exp(A_STATUS, 0); rd_exp(A_FRAME, 0);
    A = 0; h_t0 = 0; h_t1 = 0;
    in_tx(1); expect_pid(NAK, "after reset");

    // leave RXERR pending (masked) for the final reset
    token(IN, A, 1, 1); rx_pkt(20);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_RXERR);
  endtask
