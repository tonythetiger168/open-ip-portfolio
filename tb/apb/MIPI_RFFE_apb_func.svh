// IP part of MIPI_RFFE_apb_tb: an RFFE master model with a shadow register
// file predicting every read (register 0, register and extended accesses,
// broadcast and other slaves' traffic); parity errors, unsupported commands
// and the SSC that clears them through PROTO.
  localparam int HALF = 100;               // half SCLK period (10 PCLK)
  localparam logic [3:0] USID = 4'h5;
  pulldown (sdata);                        // bus keeper
  logic m_oe = 1, m_val = 0;
  assign sdata = m_oe ? m_val : 1'bz;
  initial sclk = 0;
  logic [7:0] smem [0:31];
  logic [7:0] rd_got [0:15];

  task automatic m_idle(input int halves);
    sclk = 0; m_oe = 1; m_val = 0; #(HALF * halves);
  endtask
  task automatic m_ssc;
    sclk = 0; m_oe = 1; m_val = 0; #HALF;
    m_val = 1; #(2 * HALF);
    m_val = 0; #HALF;
  endtask
  task automatic m_bit(input logic b);
    sclk = 1; m_oe = 1; m_val = b; #HALF; sclk = 0; #HALF;
  endtask
  task automatic m_bp;
    sclk = 1; m_oe = 1; m_val = 0; #HALF; sclk = 0; m_oe = 0; #HALF;
  endtask
  task automatic m_cmd(input logic [3:0] sa, input logic [7:0] c, input bit perr);
    logic [12:0] f;
    f = {sa, c, ~^{sa, c} ^ perr};
    for (int i = 12; i >= 0; i--) m_bit(f[i]);
  endtask
  task automatic m_frm(input logic [7:0] d, input bit perr);
    logic [8:0] f;
    f = {d, ~^d ^ perr};
    for (int i = 8; i >= 0; i--) m_bit(f[i]);
  endtask
  task automatic s_frames(input int nfr, input bit expect_drive);
    logic [8:0] f;
    m_oe = 0;
    for (int k = 0; k < nfr; k++) begin
      for (int i = 8; i >= 0; i--) begin sclk = 1; #HALF; f[i] = sdata; sclk = 0; #HALF; end
      rd_got[k] = f[8:1];
      if (expect_drive && ^f !== 1'b1) fail($sformatf("read frame %0d parity", k));
    end
    sclk = 1; #(HALF / 2);
    if (expect_drive && sdata !== 1'b0) fail("slave bus park");
    #(HALF / 2); sclk = 0; #HALF;
    m_oe = 1; m_val = 0;
  endtask

  task automatic reg0_write(input logic [3:0] sa, input logic [6:0] d);
    m_ssc; m_cmd(sa, {1'b1, d}, 0); m_bp; m_idle(2);
    if (sa == USID || sa == 0) smem[0] = {1'b0, d};
  endtask
  task automatic reg_write(input logic [3:0] sa, input logic [4:0] a, input logic [7:0] d,
                           input bit cperr, input bit dperr);
    m_ssc; m_cmd(sa, {3'b010, a}, cperr); m_frm(d, dperr); m_bp; m_idle(2);
    if ((sa == USID || sa == 0) && !cperr && !dperr) smem[a] = d;
  endtask
  task automatic reg_read(input logic [3:0] sa, input logic [4:0] a);
    bit me;
    me = (sa == USID);
    m_ssc; m_cmd(sa, {3'b011, a}, 0); m_bp; s_frames(1, me); m_idle(2);
    if (me && rd_got[0] !== smem[a]) fail($sformatf("read reg %0d got %h exp %h", a, rd_got[0], smem[a]));
    if (!me && rd_got[0] !== 8'h00) fail("other-SA read answered");
  endtask
  task automatic ext_write(input logic [3:0] sa, input int n, input logic [7:0] a,
                           input logic [7:0] seed, input int bad_frame);
    m_ssc; m_cmd(sa, {4'b0000, 4'(n - 1)}, 0);
    m_frm(a, bad_frame == 0);
    if (bad_frame != 0) for (int k = 0; k < n; k++) m_frm(seed + 8'(k * 37), bad_frame == k + 1);
    m_bp; m_idle(2);
    if (sa == USID || sa == 0)
      for (int k = 0; k < n; k++)
        if (bad_frame != 0 && (bad_frame < 0 || k + 1 < bad_frame) && a + k < 32)
          smem[a + k] = seed + 8'(k * 37);
  endtask
  task automatic ext_read(input logic [3:0] sa, input int n, input logic [7:0] a);
    bit me;
    me = (sa == USID);
    m_ssc; m_cmd(sa, {4'b0010, 4'(n - 1)}, 0); m_frm(a, 0);
    if (me) begin
      m_bp; s_frames(n, 1);
      for (int k = 0; k < n; k++)
        if (rd_got[k] !== ((a + k) < 32 ? smem[a + k] : 8'h00)) fail($sformatf("ext read %0d+%0d got %h", a, k, rd_got[k]));
    end else m_bp;
    m_idle(2);
  endtask

  // PROTO after a sequence: cleared, then read back (held until the next SSC)
  task automatic proto_is(input bit v, input string what);
    wr(A_IRQ_STATUS, IRQ_ALL);
    rd(A_IRQ_STATUS);
    if (rdv[IRQ_PROTO] !== v) fail($sformatf("PROTO=%b after %s", rdv[IRQ_PROTO], what));
  endtask

  task automatic ip_func;
    for (int i = 0; i < 32; i++) smem[i] = 8'h00;
    rd_exp(A_FLAGS, 0);
    m_idle(4);
    for (int a = 0; a < 32; a++) reg_write(USID, 5'(a), 8'(a * 7 + 1), 0, 0);
    for (int a = 0; a < 32; a++) reg_read(USID, 5'(a));
    proto_is(0, "good traffic");
    reg0_write(USID, 7'h55); reg_read(USID, 5'd0);
    reg0_write(4'h0, 7'h2A); reg_read(USID, 5'd0);
    reg_write(4'h0, 5'd9, 8'hB9, 0, 0); reg_read(USID, 5'd9);
    reg_write(4'h6, 5'd9, 8'h11, 0, 0); reg0_write(4'h9, 7'h7F);
    reg_read(4'h6, 5'd9);
    ext_write(4'hA, 4, 8'd0, 8'h40, -1);
    ext_read(4'hA, 2, 8'd0);
    proto_is(0, "other slaves");
    ext_write(USID, 5, 8'd2, 8'h10, -1);   ext_read(USID, 5, 8'd2);
    ext_write(USID, 16, 8'd16, 8'h80, -1); ext_read(USID, 16, 8'd16);
    ext_write(USID, 2, 8'hF0, 8'hE0, -1);  ext_read(USID, 2, 8'hFE);
    proto_is(0, "extended traffic");
    // errors (masked first)
    reg_write(USID, 5'd4, 8'h44, 1, 0); proto_is(1, "command parity");
    if (irq) fail("masked PROTO drives the pin");
    reg_read(USID, 5'd4); proto_is(0, "next SSC");
    wr(A_IRQ_ENABLE, IRQ_ALL);
    reg_write(USID, 5'd4, 8'h45, 0, 1); proto_is(1, "data parity");
    if (!irq) fail("PROTO drives the pin");
    ext_write(USID, 3, 8'd5, 8'h70, 0); proto_is(1, "address parity");
    ext_write(USID, 3, 8'd5, 8'h70, 2); proto_is(1, "ext data parity");
    m_ssc; m_cmd(USID, 8'h30, 0); m_bp; m_idle(2);
    proto_is(1, "unsupported command");
    reg_read(USID, 5'd5); proto_is(0, "clean sequence");
    if (irq) fail("irq after clear");
    // an SSC in the middle of a sequence restarts the slave
    m_ssc; m_cmd(USID, {3'b010, 5'd7}, 0); m_bit(1); m_bit(0);
    m_idle(1);
    reg_read(USID, 5'd6);
    proto_is(0, "aborted by SSC");
    // PROTO pending into reset
    m_ssc; m_cmd(USID, 8'h30, 0); m_bp; m_idle(2);
    proto_is(1, "pending");
  endtask
