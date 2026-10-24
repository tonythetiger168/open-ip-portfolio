// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for MIPI_SPMI_top -- SPMI master model.
// The master drives SDATA on SCLK rising edges and samples slave data on
// falling edges; SSC is an SDATA high pulse with SCLK low; every frame has
// odd parity; the bus has a weak keeper to 0 while nobody drives it.
// After every write the master releases SDATA for the response cycle and
// expects ACK only for a clean write addressed to this slave, then the
// slave's bus park. A shadow register file predicts every read. Covered:
// register 0 write, register write/read, extended and extended-long
// write/read (all byte counts, auto-increment, addresses past the file and
// above 255, 16-bit address wrap), reset/sleep/shutdown/wakeup, broadcast, other slaves'
// traffic, command/address/data parity errors, unsupported commands, an SSC
// that aborts a sequence, and a reset while the slave drives the bus.
`timescale 1ns/1ps
module MIPI_SPMI_tb;
  localparam int HALF = 100;             // half SCLK period (10 clk)
  localparam logic [3:0] USID = 4'h5;

  logic clk = 0, rst_n = 0;
  logic m_sclk = 0;
  tri0  sdata;                           // bus keeper
  logic m_oe = 1, m_val = 0;
  assign sdata = m_oe ? m_val : 1'bz;
  logic irq;
  int   errors = 0;

  MIPI_SPMI_top #(.USID(USID)) dut (.clk(clk), .rst_n(rst_n), .sclk(m_sclk), .sdata(sdata), .irq(irq));
  always #5 clk = ~clk;

  logic [7:0] smem [0:31];
  logic [7:0] rd_got [0:15];

  // ---------------- master primitives ----------------
  task automatic m_idle(input int halves);
    begin m_sclk = 0; m_oe = 1; m_val = 0; #(HALF * halves); end
  endtask
  task automatic m_ssc;
    begin
      m_sclk = 0; m_oe = 1; m_val = 0; #HALF;
      m_val = 1; #(2 * HALF);
      m_val = 0; #HALF;
    end
  endtask
  task automatic m_bit(input logic b);
    begin m_sclk = 1; m_oe = 1; m_val = b; #HALF; m_sclk = 0; #HALF; end
  endtask
  task automatic m_bp;                   // master bus park
    begin m_sclk = 1; m_oe = 1; m_val = 0; #HALF; m_sclk = 0; m_oe = 0; #HALF; end
  endtask
  task automatic m_cmd(input logic [3:0] sa, input logic [7:0] c, input bit perr);
    logic [12:0] f;
    begin
      f = {sa, c, ~^{sa, c} ^ perr};
      for (int i = 12; i >= 0; i--) m_bit(f[i]);
    end
  endtask
  task automatic m_frm(input logic [7:0] d, input bit perr);
    logic [8:0] f;
    begin
      f = {d, ~^d ^ perr};
      for (int i = 8; i >= 0; i--) m_bit(f[i]);
    end
  endtask
  // slave park check: SDATA driven low in the high phase, released after
  task automatic s_park(input bit expect_drive);
    begin
      m_sclk = 1; #(HALF / 2);
      if (expect_drive && (sdata !== 1'b0 || dut.drv_en !== 1'b1)) begin
        errors++; $display("ERROR: slave bus park not driven low");
      end
      if (!expect_drive && dut.drv_en !== 1'b0) begin errors++; $display("ERROR: unexpected slave drive"); end
      #(HALF / 2); m_sclk = 0; #HALF;
      if (dut.drv_en !== 1'b0) begin errors++; $display("ERROR: slave did not release SDATA"); end
      m_oe = 1; m_val = 0;
    end
  endtask
  // write response cycle: ACK (1) expected or keeper 0 (NACK / none)
  task automatic s_ack(input bit expect_ack, input string what);
    logic b;
    begin
      m_oe = 0;
      m_sclk = 1; #HALF; b = sdata; m_sclk = 0; #HALF;
      if (b !== expect_ack) begin errors++; $display("ERROR: %s response %b exp %b", what, b, expect_ack); end
      s_park(expect_ack);
    end
  endtask
  // read nfr slave frames after the bus park, then the slave's park cycle
  task automatic s_frames(input int nfr, input bit expect_drive);
    logic [8:0] f;
    begin
      m_oe = 0;
      for (int k = 0; k < nfr; k++) begin
        for (int i = 8; i >= 0; i--) begin
          m_sclk = 1; #HALF;
          f[i] = sdata;
          m_sclk = 0; #HALF;
        end
        rd_got[k] = f[8:1];
        if (expect_drive && ^f !== 1'b1) begin errors++; $display("ERROR: read frame %0d parity", k); end
      end
      s_park(expect_drive);
    end
  endtask

  function automatic logic [7:0] sread(input int a);
    return a < 32 ? smem[a] : 8'h00;
  endfunction

  // ---------------- sequences ----------------
  task automatic reg0_write(input logic [3:0] sa, input logic [6:0] d, input bit cperr);
    begin
      m_ssc; m_cmd(sa, {1'b1, d}, cperr); s_ack(sa == USID && !cperr, "reg0 write"); m_idle(2);
      if ((sa == USID || sa == 0) && !cperr) smem[0] = {1'b0, d};
    end
  endtask
  task automatic reg_write(input logic [3:0] sa, input logic [4:0] a, input logic [7:0] d,
                           input bit cperr, input bit dperr);
    begin
      m_ssc; m_cmd(sa, {3'b010, a}, cperr); m_frm(d, dperr);
      s_ack(sa == USID && !cperr && !dperr, "reg write"); m_idle(2);
      if ((sa == USID || sa == 0) && !cperr && !dperr) smem[a] = d;
    end
  endtask
  task automatic reg_read(input logic [3:0] sa, input logic [4:0] a);
    bit me;
    begin
      me = (sa == USID);
      m_ssc; m_cmd(sa, {3'b011, a}, 0); m_bp; s_frames(1, me); m_idle(2);
      if (me && rd_got[0] !== smem[a]) begin
        errors++; $display("ERROR: read reg %0d got %h exp %h", a, rd_got[0], smem[a]);
      end
      if (!me && rd_got[0] !== 8'h00) begin errors++; $display("ERROR: other-SA read answered"); end
    end
  endtask
  // extended write; lng selects the long form (16-bit address, 1..8 bytes)
  // bad_frame: -1 none, 0 address (high byte when long), k data frame k
  task automatic ext_write(input logic [3:0] sa, input bit lng, input int n, input logic [15:0] a,
                           input logic [7:0] seed, input int bad_frame);
    bit ok;
    begin
      m_ssc;
      if (lng) begin m_cmd(sa, {5'b00110, 3'(n - 1)}, 0); m_frm(a[15:8], bad_frame == 0); end
      else m_cmd(sa, {4'b0000, 4'(n - 1)}, 0);
      m_frm(a[7:0], bad_frame == 0 && !lng);
      for (int k = 0; k < n; k++) m_frm(seed + 8'(k * 37), bad_frame == k + 1);
      ok = bad_frame < 0;
      s_ack(sa == USID && ok, "ext write"); m_idle(2);
      if (sa == USID || sa == 0)
        for (int k = 0; k < n; k++)
          if (bad_frame != 0 && (bad_frame < 0 || k + 1 < bad_frame) && 16'(a + k) < 32)
            smem[16'(a + k)] = seed + 8'(k * 37);
    end
  endtask
  task automatic ext_read(input logic [3:0] sa, input bit lng, input int n, input logic [15:0] a);
    bit me;
    begin
      me = (sa == USID);
      m_ssc;
      if (lng) begin m_cmd(sa, {5'b00111, 3'(n - 1)}, 0); if (me) m_frm(a[15:8], 0); end
      else m_cmd(sa, {4'b0010, 4'(n - 1)}, 0);
      if (me) begin
        m_frm(a[7:0], 0);
        m_bp; s_frames(n, 1);
        for (int k = 0; k < n; k++)
          if (rd_got[k] !== sread(int'(16'(a + k)))) begin
            errors++; $display("ERROR: ext read %0d+%0d got %h", a, k, rd_got[k]);
          end
      end else begin m_frm(a[7:0], 0); m_bp; end
      m_idle(2);
    end
  endtask
  // command-only sequence (reset, sleep, ...): never answered
  task automatic m_only(input logic [3:0] sa, input logic [7:0] c, input bit perr);
    begin
      m_ssc; m_cmd(sa, c, perr); s_ack(0, "command"); m_idle(2);
      if (c == 8'h10 && !perr && (sa == USID || sa == 0)) for (int i = 0; i < 32; i++) smem[i] = 8'h00;
    end
  endtask

  task automatic expect_irq(input bit v, input string what);
    begin
      #(HALF);
      if (irq !== v) begin errors++; $display("ERROR: irq=%b after %s", irq, what); end
    end
  endtask

  task automatic compare_all;
    for (int i = 0; i < 32; i++)
      if (dut.mem[i] !== smem[i]) begin
        errors++; $display("ERROR: reg %0d = %h exp %h", i, dut.mem[i], smem[i]);
      end
  endtask

  initial begin
    for (int i = 0; i < 32; i++) smem[i] = 8'h00;
    repeat (5) @(negedge clk);
    rst_n = 1;
    m_idle(4);
    if (irq !== 1'b0 || dut.drv_en !== 1'b0) begin errors++; $display("ERROR: reset state"); end

    // register write / read, all 32 addresses
    for (int a = 0; a < 32; a++) reg_write(USID, 5'(a), 8'(a * 7 + 1), 0, 0);
    for (int a = 0; a < 32; a++) reg_read(USID, 5'(a));
    expect_irq(0, "good traffic");

    // register 0 write, own and broadcast; broadcast register write
    reg0_write(USID, 7'h55, 0); reg_read(USID, 5'd0);
    reg0_write(4'h0, 7'h2A, 0); reg_read(USID, 5'd0);
    reg_write(4'h0, 5'd9, 8'hB9, 0, 0); reg_read(USID, 5'd9);

    // other slaves' traffic is ignored silently
    reg_write(4'h6, 5'd9, 8'h11, 0, 0); reg0_write(4'h9, 7'h7F, 0);
    reg_read(4'h6, 5'd9);
    ext_write(4'hA, 0, 4, 16'd0, 8'h40, -1);
    ext_write(4'hA, 1, 4, 16'd0, 8'h40, -1);
    ext_read(4'hA, 0, 2, 16'd0);
    ext_read(4'hA, 1, 2, 16'd0);
    m_only(4'h7, 8'h10, 0);
    m_ssc; m_cmd(4'h0, {3'b011, 5'd9}, 0); m_bp; s_frames(1, 0); m_idle(2);  // no broadcast read
    ext_read(4'h0, 0, 2, 16'd0);                                             // nor ext read
    ext_read(4'h0, 1, 2, 16'd0);                                             // nor long read
    expect_irq(0, "other slaves");
    compare_all();

    // extended write / read: 1, 5, 16 bytes; across the end of the file
    ext_write(USID, 0, 1, 16'd20, 8'h01, -1);  ext_read(USID, 0, 1, 16'd20);
    ext_write(USID, 0, 5, 16'd2, 8'h10, -1);   ext_read(USID, 0, 5, 16'd2);
    ext_write(USID, 0, 16, 16'd16, 8'h80, -1); ext_read(USID, 0, 16, 16'd16);
    ext_write(USID, 0, 4, 16'd30, 8'hC0, -1);  ext_read(USID, 0, 4, 16'd30);
    ext_write(USID, 0, 2, 16'hF0, 8'hE0, -1);  ext_read(USID, 0, 2, 16'hFE);
    ext_write(4'h0, 0, 3, 16'd11, 8'h33, -1);  ext_read(USID, 0, 3, 16'd11);
    // long form: 16-bit address, 1..8 bytes
    ext_write(USID, 1, 1, 16'd7, 8'h5A, -1);    ext_read(USID, 1, 1, 16'd7);
    ext_write(USID, 1, 8, 16'd24, 8'h21, -1);   ext_read(USID, 1, 8, 16'd24);
    ext_write(USID, 1, 8, 16'hFFFC, 8'h99, -1); ext_read(USID, 1, 8, 16'hFFFC);
    ext_write(USID, 1, 3, 16'h0100, 8'h77, -1); ext_read(USID, 1, 3, 16'h0100);
    ext_write(USID, 1, 4, 16'h801E, 8'h66, -1); ext_read(USID, 1, 4, 16'h001E);
    ext_write(4'h0, 1, 2, 16'd3, 8'hA5, -1);    ext_read(USID, 1, 2, 16'd3);
    ext_read(USID, 1, 8, 16'h7FFF); ext_read(USID, 0, 16, 16'h00FF);
    expect_irq(0, "extended traffic");
    compare_all();

    // reset / sleep / shutdown / wakeup
    m_only(USID, 8'h11, 0); m_only(USID, 8'h12, 0); m_only(4'h0, 8'h13, 0);
    expect_irq(0, "power commands");
    compare_all();
    m_only(USID, 8'h10, 0); compare_all();
    for (int a = 0; a < 32; a++) reg_write(USID, 5'(a), 8'(a * 13 + 5), 0, 0);
    m_only(4'h0, 8'h10, 0); compare_all();
    reg_write(USID, 5'd1, 8'h3C, 0, 0); reg_read(USID, 5'd1);

    // parity errors and unsupported commands: aborted + irq until next SSC
    reg_write(USID, 5'd4, 8'h44, 1, 0); expect_irq(1, "command parity");
    reg_read(USID, 5'd4); expect_irq(0, "next SSC");
    reg_write(USID, 5'd4, 8'h45, 0, 1); expect_irq(1, "data parity");
    reg0_write(USID, 7'h11, 1); expect_irq(1, "reg0 command parity");
    ext_write(USID, 0, 3, 16'd5, 8'h70, 0);  expect_irq(1, "address parity");
    ext_write(USID, 0, 3, 16'd5, 8'h70, 2);  expect_irq(1, "ext data parity");
    ext_write(USID, 1, 3, 16'd5, 8'h70, 0);  expect_irq(1, "long address-high parity");
    m_ssc; m_cmd(USID, 8'h31, 0); m_frm(8'd0, 0); m_frm(8'd5, 1); s_ack(0, "long addr lo"); m_idle(2);
    expect_irq(1, "long address-low parity");
    ext_write(4'h0, 1, 3, 16'd5, 8'h70, 3);  expect_irq(1, "broadcast long data parity");
    m_ssc; m_cmd(USID, 8'h21, 0); m_frm(8'd0, 1); m_bp; m_idle(2);
    expect_irq(1, "ext read address parity");
    m_only(USID, 8'h10, 1); expect_irq(1, "reset command parity");
    compare_all();
    for (int c = 8'h14; c < 8'h20; c++) begin
      m_only(USID, 8'(c), 0); expect_irq(1, "unsupported command");
    end
    m_only(4'h0, 8'h15, 0); expect_irq(1, "unsupported broadcast command");
    m_only(4'h3, 8'h15, 1); expect_irq(1, "parity on another slave's command");
    m_only(4'h3, 8'h15, 0); expect_irq(0, "another slave's command");
    reg_read(USID, 5'd5); expect_irq(0, "clean sequence");
    compare_all();

    // an SSC in the middle of a sequence restarts the slave
    m_ssc; for (int i = 0; i < 6; i++) m_bit(i[0]);
    reg_write(USID, 5'd6, 8'h66, 0, 0);
    m_ssc; m_cmd(USID, {3'b010, 5'd7}, 0); m_bit(1); m_bit(0);
    m_idle(1);
    reg_read(USID, 5'd6);
    m_ssc; m_cmd(USID, 8'h00, 0); for (int i = 0; i < 4; i++) m_bit(1);     // abort in ADDR
    m_ssc; m_cmd(USID, 8'h01, 0); m_frm(8'd12, 0); for (int i = 0; i < 3; i++) m_bit(0);  // in WDATA
    m_ssc; m_cmd(USID, 8'h32, 0); m_frm(8'd0, 0); m_bit(1);                // between long addr frames
    reg_read(USID, 5'd12);
    // SDATA pulses that are not an SSC (SCLK rises before SDATA falls)
    m_sclk = 0; m_oe = 1; m_val = 1; #HALF; m_sclk = 1; #HALF; m_val = 0; #HALF; m_sclk = 0; #HALF;
    m_idle(2);
    if (dut.state !== 3'd0) begin errors++; $display("ERROR: SDATA pulse with SCLK high taken as SSC"); end
    compare_all();

    // reset while the slave drives read data, and while it drives ACK
    m_ssc; m_cmd(USID, {3'b011, 5'd1}, 0); m_bp; m_oe = 0;
    for (int i = 0; i < 4; i++) begin m_sclk = 1; #HALF; m_sclk = 0; #HALF; end
    @(negedge clk) rst_n = 0;
    #(HALF);
    if (dut.drv_en !== 1'b0) begin errors++; $display("ERROR: drive kept through reset"); end
    m_idle(1);
    rst_n = 1;
    for (int i = 0; i < 32; i++) smem[i] = 8'h00;
    m_idle(2);
    reg_read(USID, 5'd1);
    m_ssc; m_cmd(USID, {1'b1, 7'h3}, 0); m_oe = 0; m_sclk = 1; #HALF;
    @(negedge clk) rst_n = 0;
    #(HALF);
    if (dut.drv_en !== 1'b0) begin errors++; $display("ERROR: ACK kept through reset"); end
    m_idle(1);
    rst_n = 1;
    for (int i = 0; i < 32; i++) smem[i] = 8'h00;
    m_idle(2);
    compare_all();

    // every register bit to 1 and back to 0
    for (int a = 0; a < 32; a++) reg_write(USID, 5'(a), 8'hFF, 0, 0);
    compare_all();
    for (int a = 0; a < 32; a++) reg_write(USID, 5'(a), 8'h00, 0, 0);
    compare_all();

    // random traffic
    for (int t = 0; t < 200; t++) begin
      int r, n;
      logic [3:0] sa;
      bit lng;
      r = $urandom_range(0, 10);
      sa = ($urandom_range(0, 7) == 0) ? 4'($urandom) : USID;
      lng = $urandom_range(0, 1);
      n = lng ? $urandom_range(1, 8) : $urandom_range(1, 16);
      case (r)
        0, 1: reg_write(sa, 5'($urandom), 8'($urandom), $urandom_range(0, 9) == 0, $urandom_range(0, 9) == 0);
        2, 3: reg_read(sa, 5'($urandom));
        4:    reg0_write(sa, 7'($urandom), $urandom_range(0, 9) == 0);
        5, 6: ext_write(sa, lng, n, 16'($urandom_range(0, 40)), 8'($urandom),
                        ($urandom_range(0, 7) == 0) ? $urandom_range(lng ? 1 : 0, n) : -1);
        7:    m_only(sa, 8'($urandom_range(16'h11, 16'h13)), 0);
        default: ext_read(sa, lng, n, 16'($urandom_range(0, 40)));
      endcase
    end
    // data patterns written and read back
    for (int k = 0; k < 4; k++) begin
      reg_write(USID, 5'(8 + k), k == 0 ? 8'h00 : k == 1 ? 8'hFF : k == 2 ? 8'h55 : 8'hAA, 0, 0);
      reg_read(USID, 5'(8 + k));
    end
    compare_all();

    if (errors == 0) $display("TEST PASSED: MIPI_SPMI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (400000) #1000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
