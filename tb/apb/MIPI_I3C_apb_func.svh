// SPDX-License-Identifier: Apache-2.0
// IP part of MIPI_I3C_apb_tb: an I3C controller model plus a second
// (competing) open-drain target on the bus. Legacy I2C register access,
// ENTDAA (lost arbitration, parity error, success), RSTDAA, GETPID, unknown
// CCC, IBIs requested through CMD (held, NACKed and retried, lost), and the
// dynamic address in STATUS.
  localparam int HALF = 60;                // half SCL period, ns
  localparam logic [6:0]  SADDR = 7'h3C;
  localparam logic [47:0] PID   = 48'h0123_4567_89AB;
  localparam logic [7:0]  BCR   = 8'h06, DCR = 8'h5A;
  pullup (sda);
  logic m_od_low = 0, o_od = 0;
  assign sda = m_od_low ? 1'b0 : 1'bz;
  assign sda = o_od ? 1'b0 : 1'bz;
  initial scl = 1;

  task automatic check(input logic c, input string m);
    if (!c) fail(m);
  endtask
  // PROTO: clear, then read back (the core holds the level until a START)
  task automatic proto_is(input logic e, input string m);
    wr(A_IRQ_STATUS, IRQ_ALL);
    rd(A_IRQ_STATUS);
    if (rdv[IRQ_PROTO] !== e) fail({"PROTO: ", m});
  endtask
  task automatic status_is(input logic v, input logic [6:0] a, input string m);
    rd(A_STATUS);
    if (rdv !== {24'h0, v, v ? a : rdv[6:0]}) fail($sformatf("STATUS %h: %s", rdv, m));
  endtask

  task automatic m_start;
    m_od_low = 0; scl = 1; #HALF;
    m_od_low = 1;          #HALF;
    scl = 0;               #HALF;
  endtask
  task automatic m_stop;
    m_od_low = 1; scl = 0; #HALF;
    scl = 1;               #HALF;
    m_od_low = 0;          #(2*HALF);
  endtask
  task automatic m_wbit(input logic b);
    scl = 0; m_od_low = ~b; #HALF;
    scl = 1;                #HALF;
    scl = 0;                #HALF;
  endtask
  task automatic m_rbit(output logic b);
    m_od_low = 0;
    scl = 0; #HALF;
    scl = 1; #(HALF/2);
    b = sda; #(HALF/2);
    scl = 0; #HALF;
  endtask
  task automatic m_wbyte(input logic [7:0] d, output logic ack);
    for (int i = 7; i >= 0; i--) m_wbit(d[i]);
    m_od_low = 0; #HALF;
    scl = 1;      #(HALF/2);
    ack = (sda === 1'b0); #(HALF/2);
    scl = 0;      #HALF;
  endtask
  task automatic m_rbyte(output logic [7:0] d, input logic nack);
    logic b;
    for (int i = 7; i >= 0; i--) begin m_rbit(b); d[i] = b; end
    m_wbit(nack);
  endtask

  logic       ack;
  logic [7:0] rb;
  logic [7:0] model [0:15];
  logic [6:0] cur_dyn;

  task automatic wr_regs(input logic [6:0] a, input logic [3:0] p, input int n, input logic [7:0] seed);
    logic [7:0] v;
    m_start;
    m_wbyte({a, 1'b0}, ack); check(ack, "write address ACK");
    m_wbyte({4'h0, p}, ack); check(ack, "pointer ACK");
    for (int i = 0; i < n; i++) begin
      v = seed ^ 8'(i * 37);
      m_wbyte(v, ack); check(ack, "data ACK");
      model[4'(p + i)] = v;
    end
    m_stop;
  endtask

  task automatic rd_regs(input logic [6:0] a, input logic [3:0] p, input int n);
    m_start;
    m_wbyte({a, 1'b0}, ack); check(ack, "write address ACK");
    m_wbyte({4'h0, p}, ack); check(ack, "pointer ACK");
    m_start;
    m_wbyte({a, 1'b1}, ack); check(ack, "read address ACK");
    for (int i = 0; i < n; i++) begin
      m_rbyte(rb, i == n - 1);
      check(rb == model[4'(p + i)], $sformatf("register %0d read %h exp %h", 4'(p + i), rb, model[4'(p + i)]));
    end
    m_stop;
  endtask

  task automatic entdaa_round(input logic [63:0] other, input logic [6:0] addr, input logic bad_par,
                              output logic took);
    logic [63:0] got;
    logic b;
    m_start;
    m_wbyte({7'h7E, 1'b1}, ack);
    took = 0;
    if (ack) begin
      for (int i = 63; i >= 0; i--) begin
        m_od_low = 0; scl = 0;
        o_od = other != 0 && !other[i];
        #HALF; scl = 1; #(HALF/2); b = sda; #(HALF/2); scl = 0;
        got[i] = b;
      end
      o_od = 0;
      if (other == 0) check(got == {PID, BCR, DCR}, "ENTDAA 64-bit answer");
      m_wbyte({addr, ~(^addr) ^ bad_par}, ack);
      took = ack && other == 0 && !bad_par;
    end
  endtask

  task automatic ccc(input logic [7:0] code, input logic exp_ack);
    m_start;
    m_wbyte({7'h7E, 1'b0}, ack); check(ack, "7E/W ACK");
    m_wbyte(code, ack); check(ack == exp_ack, $sformatf("CCC %h ACK", code));
  endtask

  task automatic full_entdaa(input logic [6:0] addr);
    logic took;
    ccc(8'h07, 1);
    entdaa_round(0, addr, 0, took);
    check(took, "ENTDAA address taken");
    entdaa_round(0, addr, 0, took);
    check(!took, "second 7E/R NACKed");
    proto_is(0, "nothing left is silent");
    m_stop;
    cur_dyn = addr;
    status_is(1, addr, "dynamic address");
  endtask

  task automatic ibi_serve(input logic nack, input logic [6:0] beat, output logic [7:0] data,
                           output logic seen);
    logic [7:0] hdr;
    logic b;
    int t;
    t = 0;
    while (sda !== 1'b0 && t < 400) begin #10; t++; end
    seen = sda === 1'b0;
    data = 0;
    if (seen) begin
      #HALF; scl = 0; #HALF;
      for (int i = 7; i >= 0; i--) begin
        m_od_low = 0; scl = 0;
        if (beat != 0 && i > 0) m_od_low = !beat[i - 1];
        #HALF; scl = 1; #(HALF/2); b = sda; #(HALF/2); scl = 0;
        hdr[i] = b;
      end
      m_od_low = 0;
      if (beat == 0) check(hdr == {cur_dyn, 1'b1}, "IBI arbitration header");
      m_wbit(nack || beat != 0);
      if (!nack && beat == 0) m_rbyte(data, 1);
      m_stop;
    end
  endtask

  task automatic ibi(input logic [7:0] d);
    wr(A_IBI, d);
    wr(A_CMD, 1);
  endtask

  task automatic ip_func;
    logic took, seen;
    for (int i = 0; i < 16; i++) model[i] = 0;
    check(sda === 1'b1, "bus idle");
    status_is(0, 0, "no dynamic address");
    rd_exp(A_STATUS, 0);
    rd_exp(A_FLAGS, 0);
    rd_exp(A_CMD, 0);
    wr(A_STATUS, 32'hFF);                               // read-only: ignored
    rd_exp(A_STATUS, 0);
    rw_test(A_IBI, 32'hFF, 0);
    // ---- legacy I2C on the static address ----
    wr_regs(SADDR, 4'd0, 16, 8'hA5);
    rd_regs(SADDR, 4'd0, 16);
    wr_regs(SADDR, 4'd14, 4, 8'h00);
    rd_regs(SADDR, 4'd13, 5);
    proto_is(0, "clean transfers");
    // pointer out of range: NACK, PROTO until the next START (masked)
    m_start; m_wbyte({SADDR, 1'b0}, ack); m_wbyte(8'h10, ack);
    check(!ack, "pointer 0x10 NACKed"); m_stop;
    proto_is(1, "bad pointer");
    check(!irq, "masked PROTO drives the pin");
    m_start; proto_is(0, "START clears it");
    m_wbyte({7'h11, 1'b0}, ack); check(!ack, "other address NACKed"); m_stop;
    wr(A_IRQ_ENABLE, IRQ_ALL);
    m_start; m_wbyte({7'h7E, 1'b1}, ack); check(!ack, "7E/R NACK"); m_stop;
    proto_is(1, "7E/R outside ENTDAA");
    check(irq, "PROTO drives the pin");
    ccc(8'h55, 0); m_stop;
    proto_is(1, "unknown CCC");
    // IBI requested before any dynamic address: held
    ibi(8'hC3);
    #1000; check(sda === 1'b1, "no IBI without a dynamic address");
    // ---- ENTDAA: lost arbitration, bad parity, success ----
    ccc(8'h07, 1);
    proto_is(0, "ENTDAA start");
    entdaa_round({PID ^ 48'h1, BCR, DCR} & ~64'h0000_0000_0100_0000, 7'h11, 0, took);
    check(!took, "ENTDAA lost to the other target");
    status_is(0, 0, "no address after the lost round");
    entdaa_round(0, 7'h2A, 1, took);
    check(!took, "ENTDAA parity error");
    proto_is(1, "parity error");
    entdaa_round(0, 7'h2A, 0, took);
    check(took, "ENTDAA after the retries");
    entdaa_round(0, 7'h2A, 0, took);
    check(!took, "nothing left");
    m_stop;
    cur_dyn = 7'h2A;
    status_is(1, 7'h2A, "dynamic address 2A");
    // ---- the held IBI goes out now ----
    ibi_serve(0, 0, rb, seen);
    check(seen && rb == 8'hC3, "held IBI delivered");
    // ---- transfers on the dynamic address ----
    wr_regs(7'h2A, 4'd3, 3, 8'h3C);
    rd_regs(7'h2A, 4'd3, 3);
    // ---- GETPID ----
    ccc(8'h8C, 1);
    m_start; m_wbyte({7'h2A, 1'b1}, ack); check(ack, "GETPID read ACK");
    for (int i = 0; i < 8; i++) begin
      m_rbyte(rb, i == 7);
      check(rb == (i < 6 ? PID[47 - 8 * i -: 8] : PID[7:0]), $sformatf("PID byte %0d", i));
    end
    m_stop;
    // ---- IBI: NACKed and retried, then arbitration lost ----
    ibi(8'h96);
    ibi_serve(1, 0, rb, seen); check(seen, "IBI NACKed");
    proto_is(0, "IBI NACK");
    ibi_serve(0, 0, rb, seen); check(seen && rb == 8'h96, "IBI retried and delivered");
    ibi(8'h69);
    ibi_serve(0, 7'h05, rb, seen); check(seen, "IBI arbitration");
    proto_is(1, "IBI arbitration lost");
    #2000; check(sda === 1'b1, "lost IBI is dropped");
    // ---- RSTDAA, new dynamic addresses (every bit both ways) ----
    ccc(8'h06, 1); m_stop;
    status_is(0, 0, "RSTDAA");
    full_entdaa(7'h55);
    ccc(8'h06, 1); m_stop;
    full_entdaa(7'h2A);
    ibi(8'hFF);
    ibi_serve(0, 0, rb, seen); check(seen && rb == 8'hFF, "IBI FF");
    // ---- PROTO left pending into reset ----
    m_start; m_wbyte({7'h7E, 1'b1}, ack); m_stop;
    proto_is(1, "pending into reset");
  endtask
