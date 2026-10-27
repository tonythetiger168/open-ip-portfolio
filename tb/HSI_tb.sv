// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for HSI_top v2.0
//  * Two endpoints (0, 1) cross-connected: DATA / FLAG, READY, WAKE. Each
//    side has a transmit host (random channels and data) and a receive host
//    with random back-pressure; every frame is checked in order at the
//    other side (channel bits masked to cfg_chbits).
//  * Line checks on both transmit pairs: at most one line changes per
//    clock, and inside a frame changes are cfg_div + 1 clocks apart.
//  * A BFM can take over the lines into endpoint 1 for what a compliant
//    transmitter never does: frames while READY is low (overflow), stray
//    zeros, both lines changing at once, a frame that stops (timeout),
//    breaks of exact and short length.
//  * Scenarios: every cfg_chbits value (0..7) and several bit times, flow
//    control with a slow receiver, receiver disabled and re-enabled, WAKE
//    forced, breaks both ways, reset in the middle of a frame.
// ============================================================================
`timescale 1ns/1ps
module HSI_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    if (errors < 40) $display("ERROR: %s @%0t (chbits %0d div %0d)", m, $time, cfg_chbits, cfg_div);
  endfunction

  // ---------------- endpoints ----------------
  logic [7:0]  cfg_div = 4;
  logic [2:0]  cfg_chbits = 4;
  logic [1:0]  cfg_rx_en = 2'b11, cfg_wake = 0;
  logic [1:0]  txq_valid = 0, rxq_ready = 0, tx_brk = 0;
  logic [3:0]  txq_ch [0:1];
  logic [31:0] txq_data [0:1];
  wire  [1:0]  tx_data, tx_flag, tx_wake, rx_ready_out, txq_ready, tx_busy, tx_done, rxq_valid;
  wire  [1:0]  rx_break, err_overflow, err_stray, err_ds, err_timeout;
  wire  [3:0]  rxq_ch [0:1];
  wire  [31:0] rxq_data [0:1];
  // lines into each side (1 may come from the BFM)
  logic        bfm_on = 0, b_d = 0, b_f = 0;
  wire  [1:0]  rx_d = {bfm_on ? b_d : tx_data[0], tx_data[1]};
  wire  [1:0]  rx_f = {bfm_on ? b_f : tx_flag[0], tx_flag[1]};

  for (genvar s = 0; s < 2; s++) begin : g_ep
    HSI_top u (
      .clk, .rst_n, .tx_data(tx_data[s]), .tx_flag(tx_flag[s]), .tx_ready_in(rx_ready_out[1 - s]),
      .tx_wake(tx_wake[s]), .rx_data(rx_d[s]), .rx_flag(rx_f[s]), .rx_ready_out(rx_ready_out[s]),
      .rx_wake(tx_wake[1 - s]), .cfg_div, .cfg_chbits, .cfg_rx_en(cfg_rx_en[s]), .cfg_wake(cfg_wake[s]),
      .txq_valid(txq_valid[s]), .txq_ready(txq_ready[s]), .txq_ch(txq_ch[s]), .txq_data(txq_data[s]),
      .tx_brk(tx_brk[s]), .tx_busy(tx_busy[s]), .tx_done(tx_done[s]),
      .rxq_valid(rxq_valid[s]), .rxq_ready(rxq_ready[s]), .rxq_ch(rxq_ch[s]), .rxq_data(rxq_data[s]),
      .rx_break(rx_break[s]), .err_overflow(err_overflow[s]), .err_stray(err_stray[s]), .err_ds(err_ds[s]),
      .err_timeout(err_timeout[s]));
  end

  // ---------------- hosts and scoreboards ----------------
  // expected frames at side s: {ch, data}
  logic [35:0] exq [0:1][0:4095];
  int          exh [0:1], ext [0:1], n_rx [0:1], n_tx [0:1];
  int          slow [0:1];               // receive back-pressure, percent of clocks not ready
  int          evc [0:1][0:4];           // events seen: break, overflow, stray, ds, timeout
  bit          allow_ev = 0, pp_force = 0;
  int          chm;
  always_comb chm = (1 << (cfg_chbits > 4 ? 4 : cfg_chbits)) - 1;

  task automatic send(input int s, input logic [3:0] ch, input logic [31:0] d);
    @(negedge clk);
    while (!txq_ready[s]) @(negedge clk);
    txq_valid[s] = 1; txq_ch[s] = ch; txq_data[s] = d;
    exq[1 - s][ext[1 - s] % 4096] = {4'(ch & 4'(chm)), d}; ext[1 - s]++;
    n_tx[s]++;
    @(negedge clk);
    txq_valid[s] = 0; txq_ch[s] = $urandom; txq_data[s] = $urandom;
  endtask

  for (genvar s = 0; s < 2; s++) begin : g_host
    always @(negedge clk) if (rst_n) begin
      // ready is decided here; the pop happens at the next posedge
      rxq_ready[s] = ($urandom % 100) >= slow[s] || (s == 1 && pp_force && g_ep[1].u.last);
      if (rxq_valid[s] && rxq_ready[s]) begin
        n_rx[s]++;
            if (exh[s] == ext[s]) fail($sformatf("side %0d: unexpected frame %h", s, {rxq_ch[s], rxq_data[s]}));
        else begin
          if ({rxq_ch[s], rxq_data[s]} !== exq[s][exh[s] % 4096])
            fail($sformatf("side %0d: frame %h, expected %h", s, {rxq_ch[s], rxq_data[s]}, exq[s][exh[s] % 4096]));
          exh[s]++;
        end
      end
      if (rx_break[s]) evc[s][0]++;
      if (err_overflow[s]) evc[s][1]++;
      if (err_stray[s]) evc[s][2]++;
      if (err_ds[s]) evc[s][3]++;
      if (err_timeout[s]) evc[s][4]++;
      if (!allow_ev && (err_overflow[s] || err_stray[s] || err_ds[s] || err_timeout[s]))
        fail($sformatf("side %0d: unexpected receive error %b", s, {err_overflow[s], err_stray[s], err_ds[s], err_timeout[s]}));
    end
    // line checks
    logic dq, fq;
    int   since;
    always @(negedge clk) if (!rst_n) begin dq = 0; fq = 0; since = 0; end else begin
      if (tx_data[s] != dq && tx_flag[s] != fq) fail($sformatf("side %0d: DATA and FLAG changed together", s));
      if (tx_data[s] != dq || tx_flag[s] != fq) begin
        if (since != 0 && since < cfg_div + 1) fail($sformatf("side %0d: bit of %0d clocks", s, since));
        since = 1;
      end else if (since != 0) since++;
      if (!tx_busy[s]) since = 0;
      dq = tx_data[s]; fq = tx_flag[s];
    end
  end

  task automatic cycles(input int n); repeat (n) @(negedge clk); endtask
  task automatic quiet(input int limit);
    int g;
    g = 0;
    while ((tx_busy != 0 || !txq_ready[0] || !txq_ready[1] || exh[0] != ext[0] || exh[1] != ext[1]) && g < limit) begin
      @(negedge clk); g++;
    end
    if (g >= limit) for (int s = 0; s < 2; s++) $display("DBG s%0d ts=%0d hold=%0d rdy=%0d fn=%0d rs=%0d rcnt=%0d rdyout=%0d wake=%0d", s,
      s ? g_ep[1].u.ts : g_ep[0].u.ts, s ? g_ep[1].u.hold : g_ep[0].u.hold, s ? g_ep[1].u.rdy_s2 : g_ep[0].u.rdy_s2,
      s ? g_ep[1].u.fn : g_ep[0].u.fn, s ? g_ep[1].u.rs : g_ep[0].u.rs, s ? g_ep[1].u.rcnt : g_ep[0].u.rcnt, rx_ready_out[s], tx_wake[s]);
    if (g >= limit) fail($sformatf("link did not go quiet (%0d / %0d frames missing)", ext[0] - exh[0], ext[1] - exh[1]));
    exh[0] = ext[0]; exh[1] = ext[1];
    cycles(20);
  endtask
  task automatic traffic(input int n);
    fork
      for (int i = 0; i < n; i++) begin send(0, $urandom, $urandom); cycles($urandom % 50); end
      for (int i = 0; i < n; i++) begin send(1, $urandom, $urandom); cycles($urandom % 50); end
    join
  endtask

  // ---------------- BFM into endpoint 1 ----------------
  task automatic b_bit(input bit v);
    if (v != b_d) b_d = v; else b_f = !b_f;
    repeat (cfg_div + 1) @(negedge clk);
  endtask
  task automatic b_frame(input logic [3:0] ch, input logic [31:0] d, input int nbits, input bit exp);
    int cb;
    cb = cfg_chbits > 4 ? 4 : cfg_chbits;
    if (exp) begin exq[1][ext[1] % 4096] = {4'(ch & 4'(chm)), d}; ext[1]++; end
    b_bit(1);
    for (int i = cb - 1; i >= 0; i--) b_bit(ch[i]);
    for (int i = 31; i >= 0 && 32 - i <= nbits; i--) b_bit(d[i]);
  endtask
  // endpoint 0 sends a break first, so DATA is 0 at both hand-overs; the BFM
  // hands back after a break of its own with the lines equal to endpoint 0's
  task automatic b_take;
    @(negedge clk) tx_brk[0] = 1; @(negedge clk) tx_brk[0] = 0;
    while (tx_busy[0]) @(negedge clk);
    cycles(10);
    b_d = tx_data[0]; b_f = tx_flag[0]; bfm_on = 1;
  endtask
  task automatic b_give;
    repeat (40) b_bit(0);
    if (b_f != tx_flag[0]) b_bit(0);
    cycles(10);
    bfm_on = 0;
  endtask

  // ---------------- scenarios ----------------
  initial begin
    for (int s = 0; s < 2; s++) begin
      exh[s] = 0; ext[s] = 0; n_rx[s] = 0; n_tx[s] = 0; slow[s] = 0; txq_ch[s] = 0; txq_data[s] = 0;
      for (int e = 0; e < 5; e++) evc[s][e] = 0;
    end
    #22 rst_n = 1;
    cycles(5);

    // 1. every channel-bit setting and several bit times
    for (int c = 0; c < 8; c++) begin
      cfg_chbits = c; cfg_div = 3 + 5 * (c % 3);
      traffic(20);
      quiet(100_000);
    end
    // all channels and data patterns at 4 channel bits
    cfg_chbits = 4; cfg_div = 3;
    for (int ch = 0; ch < 16; ch++) begin send(0, ch, 32'hFFFF_FFFF); send(1, ch, 32'h0); end
    send(0, 15, 32'hAAAA_AAAA); send(0, 0, 32'h5555_5555);
    quiet(100_000);
    // largest bit time
    cfg_div = 255; send(0, 9, $urandom); send(1, 6, $urandom); quiet(100_000);
    cfg_div = 5;

    // 2. flow control: slow receivers fill their FIFOs
    slow[0] = 97; slow[1] = 95;
    traffic(30);
    quiet(500_000);
    slow[0] = 0; slow[1] = 0;
    // a receiver that stops: its FIFO fills, READY holds the transmitter
    slow[1] = 100;
    for (int i = 0; i < 5; i++) send(0, i, $urandom);
    cycles(3000);
    if (g_ep[1].u.fn != 4 || txq_ready[0]) fail("FIFO not full with a frame held back");
    slow[1] = 0;
    quiet(10_000);
    // receiver disabled: the transmitter waits
    cfg_rx_en[1] = 0;
    send(0, 3, 32'h1234_5678);
    cycles(500);
    if (!tx_wake[0] || tx_busy[0] || txq_ready[0]) fail("frame did not wait for READY");
    cfg_rx_en[1] = 1;
    quiet(10_000);
    // WAKE forced
    cfg_wake = 2'b11; cycles(50); cfg_wake = 0;

    // 3. breaks both ways, and a frame right after
    for (int s = 0; s < 2; s++) begin
      @(negedge clk) tx_brk[s] = 1; @(negedge clk) tx_brk[s] = 0;
      send(s, 5, 32'hCAFE_F00D);
      quiet(10_000);
    end
    // a break requested while a frame is being sent
    send(0, 7, 32'h0BAD_CAFE);
    while (!tx_busy[0]) @(negedge clk);
    @(negedge clk) tx_brk[0] = 1; @(negedge clk) tx_brk[0] = 0;
    quiet(10_000);
    // a break requested while a frame waits for READY goes first (a frame
    // before it ends the zero run of the last break)
    send(0, 9, 32'h9999_0000);
    quiet(10_000);
    cfg_rx_en[1] = 0;
    send(0, 8, 32'h8888_0000);
    cycles(20);
    @(negedge clk) tx_brk[0] = 1; @(negedge clk) tx_brk[0] = 0;
    cycles(300);
    cfg_rx_en[1] = 1;
    quiet(10_000);
    if (evc[1][0] != 3 || evc[0][0] != 1) fail($sformatf("breaks seen %0d / %0d", evc[0][0], evc[1][0]));

    // 4. BFM: protocol errors into endpoint 1
    allow_ev = 1;
    cfg_div = 4; cfg_chbits = 2;
    b_take();
    b_frame(4'h1, 32'h1111_1111, 32, 1);
    repeat (5) b_bit(0);                             // stray zeros
    b_frame(4'h2, 32'h2222_2222, 32, 1);
    b_bit(0);                                        // one stray zero
    b_frame(4'h1, 32'h0000_0001, 32, 1);
    repeat (34) b_bit(0);                            // one zero short of a break
    b_frame(4'h2, 32'h0000_0002, 32, 1);
    repeat (35) b_bit(0);                            // break (33 + 2)
    b_frame(4'h3, 32'h3333_3333, 32, 1);
    b_d = !b_d; b_f = !b_f; repeat (cfg_div + 1) @(negedge clk);   // both lines change
    repeat (34) b_bit(0);
    b_frame(4'h0, 32'h4444_4444, 10, 0);             // stops: timeout
    cycles(40);
    b_bit(1); b_bit(0); cycles(40);                  // stops in the channel bits
    b_bit(1); b_bit(1);
    b_d = !b_d; b_f = !b_f; cycles(40);              // both lines change in a frame, then stops
    repeat (70) b_bit(0);                            // a long break: the zero count saturates
    // overflow: frames while READY is low
    slow[1] = 100;
    for (int i = 0; i < 5; i++) b_frame(4'(i), $urandom, 32, i < 4);
    pp_force = 1;                                    // full FIFO, popped as the last bit lands
    b_frame(4'h5, 32'h5555_0005, 32, 1);
    cycles(10);
    pp_force = 0;
    cycles(20);
    slow[1] = 0;
    b_give();
    quiet(10_000);
    if (evc[1][1] != 1 || evc[1][2] != 3 || evc[1][3] != 2 || evc[1][4] != 3)
      fail($sformatf("events: overflow %0d stray %0d ds %0d timeout %0d", evc[1][1], evc[1][2], evc[1][3], evc[1][4]));
    allow_ev = 0;

    // 5. reset in the middle of a frame
    cfg_div = 10;
    send(0, 1, 32'hDEAD_BEEF);
    while (!tx_busy[0]) @(negedge clk);
    cycles(100);
    rst_n = 0; cycles(2);
    exh[0] = ext[0]; exh[1] = ext[1];
    rst_n = 1; cycles(5);
    send(1, 2, 32'h0F0F_0F0F); send(0, 3, 32'hF0F0_F0F0);
    quiet(10_000);
    // data patterns both ways
    send(0, 4'h0, 32'h0000_0000); send(1, 4'hF, 32'h0000_0000);
    send(0, 4'h5, 32'hFFFF_FFFF); send(1, 4'hA, 32'hFFFF_FFFF);
    send(0, 4'h6, 32'h5555_5555); send(1, 4'h9, 32'hAAAA_AAAA);
    quiet(10_000);

    $display("frames %0d / %0d", n_rx[0], n_rx[1]);
    if (errors == 0) $display("TEST PASSED: HSI");
    else $display("TEST FAILED: HSI (%0d errors)", errors);
    $finish;
  end
  initial begin #100ms; $display("TEST FAILED: HSI (timeout)"); $finish; end
endmodule
