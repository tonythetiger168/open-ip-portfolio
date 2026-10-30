// SPDX-License-Identifier: Apache-2.0
// IP part of MIPI_SPMI_apb_tb: an SPMI master model with a shadow register
// file predicting every read and every write response (register 0,
// register, extended short and long accesses, broadcast and other slaves'
// traffic, reset / sleep / shutdown / wakeup); parity errors, unsupported
// commands and the SSC that clears them through PROTO.
  localparam int HALF = 100;               // half SCLK period (10 PCLK)
  localparam logic [3:0] USID = 4'h5;
  pulldown (sdata);                        // bus keeper
  logic m_oe = 1, m_val = 0;
  assign sdata = m_oe ? m_val : 1'bz;
  initial sclk = 0;
  logic [7:0] smem [0:31];
  logic [7:0] rd_got [0:15];

  // ---------------- master primitives ----------------
  task automatic m_idle(input int halves);
    begin sclk = 0; m_oe = 1; m_val = 0; #(HALF * halves); end
  endtask
  task automatic m_ssc;
    begin
      sclk = 0; m_oe = 1; m_val = 0; #HALF;
      m_val = 1; #(2 * HALF);
      m_val = 0; #HALF;
    end
  endtask
  task automatic m_bit(input logic b);
    begin sclk = 1; m_oe = 1; m_val = b; #HALF; sclk = 0; #HALF; end
  endtask
  task automatic m_bp;                   // master bus park
    begin sclk = 1; m_oe = 1; m_val = 0; #HALF; sclk = 0; m_oe = 0; #HALF; end
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
      sclk = 1; #(HALF / 2);
      if (expect_drive && (sdata !== 1'b0 || dut.u_core.drv_en !== 1'b1)) fail("slave bus park not driven low");
      if (!expect_drive && dut.u_core.drv_en !== 1'b0) fail("unexpected slave drive");
      #(HALF / 2); sclk = 0; #HALF;
      if (dut.u_core.drv_en !== 1'b0) fail("slave did not release SDATA");
      m_oe = 1; m_val = 0;
    end
  endtask
  // write response cycle: ACK (1) expected or keeper 0 (NACK / none)
  task automatic s_ack(input bit expect_ack, input string what);
    logic b;
    begin
      m_oe = 0;
      sclk = 1; #HALF; b = sdata; sclk = 0; #HALF;
      if (b !== expect_ack) fail($sformatf("%s response %b exp %b", what, b, expect_ack));
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
          sclk = 1; #HALF;
          f[i] = sdata;
          sclk = 0; #HALF;
        end
        rd_got[k] = f[8:1];
        if (expect_drive && ^f !== 1'b1) fail($sformatf("read frame %0d parity", k));
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
      if (me && rd_got[0] !== smem[a]) fail($sformatf("read reg %0d got %h exp %h", a, rd_got[0], smem[a]));
      if (!me && rd_got[0] !== 8'h00) fail("other-SA read answered");
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
          if (rd_got[k] !== sread(int'(16'(a + k)))) fail($sformatf("ext read %0d+%0d got %h", a, k, rd_got[k]));
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

  task automatic proto_is(input bit v, input string what);
    wr(A_IRQ_STATUS, IRQ_ALL);
    rd(A_IRQ_STATUS);
    if (rdv[IRQ_PROTO] !== v) fail($sformatf("PROTO=%b after %s", rdv[IRQ_PROTO], what));
  endtask

  task automatic compare_all;
    for (int i = 0; i < 32; i++)
      if (dut.u_core.mem[i] !== smem[i]) fail($sformatf("reg %0d = %h exp %h", i, dut.u_core.mem[i], smem[i]));
  endtask

  task automatic ip_func;
    for (int i = 0; i < 32; i++) smem[i] = 8'h00;
    rd_exp(A_FLAGS, 0);
    m_idle(4);
    for (int a = 0; a < 32; a++) reg_write(USID, 5'(a), 8'(a * 7 + 1), 0, 0);
    for (int a = 0; a < 32; a++) reg_read(USID, 5'(a));
    proto_is(0, "good traffic");
    reg0_write(USID, 7'h55, 0); reg_read(USID, 5'd0);
    reg0_write(4'h0, 7'h2A, 0); reg_read(USID, 5'd0);
    reg_write(4'h0, 5'd9, 8'hB9, 0, 0); reg_read(USID, 5'd9);
    reg_write(4'h6, 5'd9, 8'h11, 0, 0); reg0_write(4'h9, 7'h7F, 0);
    reg_read(4'h6, 5'd9);
    ext_write(4'hA, 1, 4, 16'd0, 8'h40, -1);
    ext_read(4'hA, 0, 2, 16'd0);
    m_only(4'h7, 8'h10, 0);
    proto_is(0, "other slaves");
    ext_write(USID, 0, 5, 16'd2, 8'h10, -1);   ext_read(USID, 0, 5, 16'd2);
    ext_write(USID, 0, 16, 16'd16, 8'h80, -1); ext_read(USID, 0, 16, 16'd16);
    ext_write(USID, 1, 8, 16'hFFFC, 8'h99, -1); ext_read(USID, 1, 8, 16'hFFFC);
    ext_write(USID, 1, 4, 16'h801E, 8'h66, -1); ext_read(USID, 1, 4, 16'h001E);
    proto_is(0, "extended traffic");
    compare_all();
    m_only(USID, 8'h11, 0); m_only(4'h0, 8'h13, 0);
    proto_is(0, "power commands");
    m_only(USID, 8'h10, 0); compare_all();
    // errors (masked first)
    reg_write(USID, 5'd4, 8'h44, 1, 0); proto_is(1, "command parity");
    if (irq) fail("masked PROTO drives the pin");
    reg_read(USID, 5'd4); proto_is(0, "next SSC");
    wr(A_IRQ_ENABLE, IRQ_ALL);
    reg_write(USID, 5'd4, 8'h45, 0, 1); proto_is(1, "data parity");
    if (!irq) fail("PROTO drives the pin");
    ext_write(USID, 1, 3, 16'd5, 8'h70, 0);  proto_is(1, "long address-high parity");
    ext_write(USID, 0, 3, 16'd5, 8'h70, 2);  proto_is(1, "ext data parity");
    m_only(USID, 8'h15, 0); proto_is(1, "unsupported command");
    reg_read(USID, 5'd5); proto_is(0, "clean sequence");
    if (irq) fail("irq after clear");
    compare_all();
    // an SSC in the middle of a sequence restarts the slave
    m_ssc; m_cmd(USID, {3'b010, 5'd7}, 0); m_bit(1); m_bit(0);
    m_idle(1);
    reg_read(USID, 5'd6);
    proto_is(0, "aborted by SSC");
    m_only(USID, 8'h15, 0);
    proto_is(1, "pending into reset");
  endtask
