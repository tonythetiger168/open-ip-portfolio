// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of I2C_Host_top. The far end is the
// portfolio's own I2C_top target (address 0x50) on an open-drain SDA with a
// pull-up; a bus monitor decodes every START, STOP and bit independently of
// both and checks that SDA only changes while SCL is low (except START /
// STOP) and that SCL high and low times are at least PRESCALE + 1 clocks.
// - Writes: START + address 0x50/W, random bytes (the target's RX), STOP.
// - Reads: START + 0x50/R, random bytes from the target's TX register, ACK
//   on all but the last, NACK + STOP on the last.
// - Register-style transfer: write a byte, repeated START, read two bytes.
// - Another address (0x51): NACK in RX_ACK, nothing reaches the target.
// - PRESCALE 2..9, commands while busy ignored, BUS_HELD between START and
//   STOP, DONE once per command, the monitor's START / STOP counts.
`timescale 1ns/1ps
module I2C_Host_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction
  task automatic clks(input int n); repeat (n) @(negedge clk); endtask

  tri1         sda;
  wire         scl;
  logic [15:0] prescale = 3;
  logic        cmd_valid = 0, cmd_sta = 0, cmd_wr = 0, cmd_rd = 0, cmd_sto = 0, cmd_nack = 0;
  logic [7:0]  tx_data = 0;
  wire  [7:0]  rx_data;
  wire         rx_ack, busy, bus_held, done;
  I2C_Host_top dut (.*);

  logic [7:0]  t_tx = 0;
  wire  [7:0]  t_rx;
  wire         t_rx_valid, t_busy, t_irq;
  I2C_top #(.I2C_ADDR(7'h50)) tgt (.clk, .rst_n, .sda, .scl, .tx_byte(t_tx), .rx_byte(t_rx),
                                   .rx_valid(t_rx_valid), .busy(t_busy), .irq(t_irq));

  int n_done = 0;
  always @(posedge clk) if (rst_n) n_done += done;
  logic [7:0] t_got [$];
  always @(posedge clk) if (rst_n && t_rx_valid) t_got.push_back(t_rx);

  // ---------------------------------------------------------- bus monitor
  int  n_start = 0, n_stop = 0, n_bits = 0;
  logic sda_d = 1, scl_d = 1;
  int  t_scl = 0, last_scl_edge = 0;
  logic [8:0] mon_sh;                 // bits since the last START / ACK
  logic [8:0] mon_bytes [$];          // 8 data bits + ACK bit, as seen on the wire
  int  mon_n = 0;
  always @(posedge clk) begin
    logic s;
    s = (sda !== 1'b0);
    if (rst_n) begin
      if (scl && scl_d && s != sda_d) begin
        if (!s) begin n_start++; mon_n = 0; end else n_stop++;
      end
      if (scl != scl_d) begin
        if (t_scl - last_scl_edge < prescale + 1 && last_scl_edge != 0)
          fail($sformatf("SCL %s for %0d clocks (PRESCALE %0d)", scl ? "low" : "high", t_scl - last_scl_edge, prescale));
        last_scl_edge = t_scl;
      end
      if (scl && !scl_d) begin
        mon_sh = {mon_sh[7:0], s}; mon_n++;
        if (mon_n == 9) begin mon_bytes.push_back(mon_sh); mon_n = 0; end
      end
    end
    sda_d = s; scl_d = scl; t_scl++;
  end

  // ---------------------------------------------------------- commands
  task automatic cmd(input bit sta, wr, rd, sto, nack, input logic [7:0] d);
    int nd0, t;
    bit bh0;
    @(negedge clk);
    bh0 = bus_held;
    cmd_sta = sta; cmd_wr = wr; cmd_rd = rd; cmd_sto = sto; cmd_nack = nack; tx_data = d;
    cmd_valid = 1; nd0 = n_done;
    @(negedge clk); cmd_valid = 0;
    if (!busy && (sta || wr || rd || (sto && bh0))) fail("busy low after a command");
    if ($urandom % 3 == 0) begin                 // a command while busy is ignored
      clks(2); cmd_sta = 1; cmd_sto = 1; cmd_valid = 1; @(negedge clk); cmd_valid = 0;
    end
    t = 0;
    while (busy && t < 20000) begin @(negedge clk); t++; end
    clks(1);
    if (n_done != nd0 + 1) fail($sformatf("%0d DONE pulses for one command", n_done - nd0));
    if (bus_held !== (sto ? 1'b0 : (sta ? 1'b1 : bus_held))) fail("BUS_HELD");
  endtask
  // the target's TX byte may change only between a byte's last bit and the
  // ACK clock: load the next one as the host enters its ACK bit
  logic [7:0] rd_bytes [$];
  always @(posedge clk) if (rst_n && dut.st == 3'd3 && dut.q == 2'd0 && dut.qcnt == dut.prescale && dut.rd_q)
    if (rd_bytes.size() > 1) begin logic [7:0] nb; nb = rd_bytes[1]; t_tx <= nb; end

  task automatic write_xfer(input logic [6:0] addr, input int n);
    logic [7:0] d [$];
    int ms;
    t_got.delete(); ms = mon_bytes.size();
    cmd(1, 1, 0, 0, 0, {addr, 1'b0});
    if (rx_ack !== (addr != 7'h50)) fail($sformatf("address %h: RX_ACK %b", addr, rx_ack));
    for (int i = 0; i < n; i++) begin
      begin logic [7:0] r; r = $urandom; d.push_back(r); end
      cmd(0, 1, 0, i == n - 1, 0, d[i]);
      if (rx_ack !== (addr != 7'h50)) fail($sformatf("byte %0d: RX_ACK %b", i, rx_ack));
    end
    if (addr == 7'h50) begin
      if (t_got.size() != n) fail($sformatf("target got %0d of %0d bytes", t_got.size(), n));
      else for (int i = 0; i < n; i++) begin
        logic [7:0] a, b;
        a = t_got[i]; b = d[i];
        if (a !== b) fail($sformatf("target byte %0d: %h, sent %h", i, a, b));
      end
    end else if (t_got.size() != 0) fail("a byte reached the target at another address");
    // the wire: address byte, then the data bytes, each with its ACK bit
    begin
      logic [8:0] w, e;
      logic       nak;
      nak = (addr != 7'h50);
      w = mon_bytes[ms]; e = {addr, 1'b0, nak};
      if (w !== e) fail($sformatf("wire address byte %h, expected %h", w, e));
      for (int i = 0; i < n; i++) begin
        logic [7:0] di;
        di = d[i]; w = mon_bytes[ms + 1 + i]; e = {di, nak};
        if (w !== e) fail($sformatf("wire byte %0d: %h, expected %h", i, w, e));
      end
    end
  endtask

  task automatic read_xfer(input int n, input bit restart);
    rd_bytes.delete();
    for (int i = 0; i < n; i++) begin logic [7:0] r; r = $urandom; rd_bytes.push_back(r); end
    @(negedge clk); t_tx = rd_bytes[0];
    if (restart) begin
      cmd(1, 1, 0, 0, 0, 8'hA0);
      cmd(0, 1, 0, 0, 0, 8'h10);                    // register index
    end
    cmd(1, 1, 0, 0, 0, 8'hA1);
    if (rx_ack !== 1'b0) fail("read address not acknowledged");
    for (int i = 0; i < n; i++) begin
      cmd(0, 0, 1, i == n - 1, i == n - 1, 8'h00);
      begin
        logic [7:0] e;
        e = rd_bytes[0];
        if (rx_data !== e) fail($sformatf("read byte %0d: %h, expected %h", i, rx_data, e));
      end
      void'(rd_bytes.pop_front());
    end
  endtask

  initial begin
    int s0, p0;
    clks(3); rst_n = 1; clks(5);
    s0 = 0; p0 = 0;
    for (int k = 0; k < 10; k++) begin
      prescale = 2 + $urandom % 8;
      write_xfer(7'h50, 1 + $urandom % 6); s0++; p0++;
      read_xfer(1 + $urandom % 5, 0);      s0++; p0++;
      read_xfer(2, 1);                     s0 += 2; p0++;
      if (k % 3 == 0) begin
        write_xfer(7'h51, 1);              s0++; p0++;
        cmd(0, 0, 0, 1, 0, 8'h00);         // STOP with the bus free: nothing on the wire
      end
    end
    // a command with no flags only pulses DONE
    cmd(0, 0, 0, 0, 0, 8'h00);
    clks(20);
    if (n_start != s0) fail($sformatf("monitor saw %0d STARTs, expected %0d", n_start, s0));
    if (n_stop != p0) fail($sformatf("monitor saw %0d STOPs, expected %0d", n_stop, p0));
    if (bus_held) fail("BUS_HELD at the end");
    $display("I2C_Host: %0d STARTs, %0d STOPs, %0d bytes on the wire", n_start, n_stop, mon_bytes.size());
    if (errors == 0) $display("TEST PASSED: I2C_Host");
    else $display("TEST FAILED: I2C_Host (%0d errors)", errors);
    $finish;
  end
  initial begin #50ms; fail("timeout"); $display("TEST FAILED: timeout"); $finish; end
endmodule
