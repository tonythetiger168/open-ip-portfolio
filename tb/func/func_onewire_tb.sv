// SPDX-License-Identifier: Apache-2.0
// func_onewire_tb.sv -- clock-exact functional test for _1_Wire_top, ported
// from open-vip-portfolio. Run: make -f Makefile._1_Wire func
//
// _1_Wire_tb.sv checks presence, byte transfers and glitch rejection with
// generous timing windows. This test measures the slave's timing in clocks
// (US = 10 clocks per microsecond) and checks the edges of every window:
//   * reset-pulse threshold (> 480 us low), presence pulse length (121 us),
//     read-slot bit-0 hold time (41 us), write-slot sample point (30 us,
//     the middle of the 15..60 us window the master holds a 0);
//   * a reset pulse recognised mid-transaction while waiting for a write
//     slot and while sending a read byte;
//   * no activity after reset release on an idle bus, rx_valid/irq as a
//     one-clock pulse, LSB-first data in both directions.
`timescale 1ns/1ps
module func_onewire_tb;
  localparam int US = 10;
  int checks = 0, fails = 0;

  logic clk = 1'b0, rst_n = 1'b0, m_low = 1'b0;
  tri1  dq;
  logic [7:0] tx_byte = 8'h00, rx_byte;
  logic rx_valid, busy, irq;

  _1_Wire_top #(.US(US)) u_dut (.*);

  always #5 clk = ~clk;
  assign dq = m_low ? 1'b0 : 1'bz;

  task automatic chk(input bit ok, input string msg);
    checks++;
    if (!ok) begin fails++; $display("  [FAIL] %s", msg); end
  endtask

  task automatic clocks(input int n); repeat (n) @(negedge clk); endtask

  int rxv_pulses = 0, irq_bad = 0;
  always @(negedge clk) begin
    rxv_pulses += rx_valid;
    if (irq !== rx_valid) irq_bad++;
  end

  // master low for n clocks, then release; returns the number of clocks the
  // slave then holds the line low (presence / read bit 0) within `win`
  int slave_low;
  task automatic low_then_watch(input int n, input int win);
    @(negedge clk); m_low = 1'b1;
    clocks(n);
    m_low = 1'b0;
    slave_low = 0;
    for (int i = 0; i < win; i++) begin
      @(negedge clk);
      if (dq === 1'b0) slave_low++;
    end
  endtask

  task automatic bus_reset(output bit presence);
    low_then_watch(600 * US, 300 * US);
    presence = (slave_low > 0);
  endtask

  task automatic write_bit(input bit b);
    @(negedge clk); m_low = 1'b1;
    clocks(b ? 2 * US : 60 * US);
    m_low = 1'b0;
    clocks((b ? 78 : 20) * US);
  endtask
  task automatic write_byte(input [7:0] v);
    for (int i = 0; i < 8; i++) write_bit(v[i]);
  endtask

  task automatic read_bit(output bit b, output int held);
    low_then_watch(2 * US, 78 * US);
    held = slave_low;
    b = (held == 0);
  endtask

  initial begin
    bit p;
    int held, th;
    bit [7:0] rb;

    clocks(3);
    rst_n = 1'b1;
    begin
      bit quiet;
      quiet = 1;
      for (int i = 0; i < 20; i++) begin
        @(negedge clk);
        if (busy !== 1'b0 || dq !== 1'b1) quiet = 0;
      end
      chk(quiet, "idle bus after reset release: slave never busy, line released");
    end
    chk(rx_byte === 8'h00 && rx_valid === 1'b0, "reset clears rx_byte / rx_valid");

    // reset-pulse threshold: shortest low time that gets a presence pulse
    th = -1;
    for (int n = 480 * US - 2; n <= 480 * US + 6 && th < 0; n++) begin
      low_then_watch(n, 200 * US);
      if (slave_low > 0) th = n;
      clocks(200 * US);
    end
    $display("  reset threshold = %0d clocks", th);
    // timer must exceed 480 us, plus the two-flop input synchroniser
    chk(th == 480 * US + 3, $sformatf("reset pulse recognised from 480 us + 3 clocks (%0d)", th));

    bus_reset(p);
    chk(p, "presence pulse after a 600 us reset");
    chk(slave_low == 120 * US + 1, $sformatf("presence pulse lasts 120 us + 1 clock (%0d)", slave_low));
    chk(busy === 1'b1, "slave busy waiting for a command after presence");

    // write a command byte LSB-first; rx_valid is a one-clock pulse
    rxv_pulses = 0;
    tx_byte = 8'hA6;
    write_byte(8'h3C);
    chk(rx_byte == 8'h3C, $sformatf("command byte received LSB-first (%h)", rx_byte));
    chk(rxv_pulses == 1, $sformatf("rx_valid pulses once per byte for one clock (%0d)", rxv_pulses));

    // read the response byte; bit-0 hold time is exact
    begin
      int h0;
      h0 = -1;
      for (int i = 0; i < 8; i++) begin
        bit b;
        read_bit(b, held);
        rb[i] = b;
        if (!b && h0 < 0) h0 = held;
      end
      chk(rb == 8'hA6, $sformatf("response byte sent LSB-first (%h)", rb));
      // after 8 read slots the slave expects the next command, no bus reset
      write_byte(8'h96);
      chk(rx_byte == 8'h96 && rxv_pulses == 2, "next command byte accepted right after the read phase");
      // R_DRIVE holds until its timer exceeds 40 us; the master released after 2 us
      chk(h0 == 38 * US + 3, $sformatf("read-slot 0 bit held 40 us from the falling edge (%0d clocks after release)", h0));
    end

    // write-slot sample point (30 us): low a few clocks past it reads as 0,
    // a release a few clocks before it reads as 1
    tx_byte = 8'h00;
    bus_reset(p);
    for (int i = 0; i < 8; i++) begin
      @(negedge clk); m_low = 1'b1;
      clocks(i[0] ? 30 * US - 4 : 30 * US + 4);
      m_low = 1'b0;
      clocks(70 * US);
    end
    chk(rx_byte == 8'hAA, $sformatf("write slot sampled at 30 us (%h)", rx_byte));

    // reset pulse while the slave sends a read byte
    tx_byte = 8'h00;                       // every bit 0: slave drives
    bus_reset(p);
    write_byte(8'hF0);
    read_bit(rb[0], held);
    chk(rb[0] == 0, "slave sending read data");
    bus_reset(p);
    chk(p, "reset pulse recognised while sending a read byte");
    write_byte(8'h5A);
    chk(rx_byte == 8'h5A, "command after the mid-read reset starts at bit 0");

    // reset pulse while waiting for a write slot, after 3 bits
    tx_byte = 8'hFF;
    bus_reset(p);
    write_bit(1); write_bit(0); write_bit(1);
    bus_reset(p);
    chk(p, "reset pulse recognised in the middle of a command byte");
    write_byte(8'hC3);
    chk(rx_byte == 8'hC3, "bit counter restarts after the mid-byte reset");

    // a short low pulse while idle is a glitch
    rst_n = 1'b0; clocks(2); rst_n = 1'b1; clocks(5);
    low_then_watch(100 * US, 200 * US);
    chk(slave_low == 0 && busy === 1'b0, "100 us low pulse is ignored");

    // random command / response bytes
    begin
      int bad;
      bad = 0;
      for (int t = 0; t < 6; t++) begin
        bit [7:0] c, r;
        c = $urandom; r = $urandom;
        tx_byte = r;
        bus_reset(p);
        write_byte(c);
        for (int i = 0; i < 8; i++) read_bit(rb[i], held);
        if (!p || rx_byte != c || rb != r) bad++;
      end
      chk(bad == 0, $sformatf("6 random command/response exchanges (%0d bad)", bad));
    end
    chk(irq_bad == 0, "irq mirrors rx_valid");

    if (fails == 0) $display("TEST PASSED: _1_Wire_func (%0d checks)", checks);
    else            $display("TEST FAILED: %0d of %0d checks", fails, checks);
    $finish;
  end
endmodule
