// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for SMBus_top (SMBus 3.x target, PMBus 1.3).
// The TB is the SMBus host: an open-drain bit-level driver (wired-AND bus
// with the target's scl_o / sda_o and a second ARA responder) that waits
// out clock stretching. A transaction model of the target (command table,
// PEC, STATUS_CML fault rules, WRITE_PROTECT, SMBALERT# / ARA) predicts
// every ACK / NACK and every byte read. Monitors check the bus timing:
// SDA changes only while SCL is low and at least HOLD clocks after SCL
// fell, each stretch lasts STRETCH clocks, smbalert_n follows the model.
`timescale 1ns/1ps
module SMBus_tb;
  localparam logic [6:0] ADDR = 7'h5A;
  localparam int FILT = 3, HOLD = 4, STRETCH = 8, TIMEOUT = 3000;
  localparam logic [7:0] ARA = 8'h19;
  int Q = 30;                           // quarter SCL period, clocks

  logic clk = 0, rst_n = 0;
  logic scl_m = 1, sda_m = 1, sda_c = 1;   // host and the other ARA responder
  logic scl_g = 1, sda_g = 1;              // glitch injection (0 pulls low)
  wire  scl_o, sda_o, smbalert_n;
  wire  scl = scl_m & scl_o & scl_g;
  wire  sda = sda_m & sda_o & sda_c & sda_g;
  wire [7:0] operation, on_off_config;
  wire [15:0] vout_command;
  logic [15:0] read_vout = 16'h0000;
  logic vout_ov = 0;
  wire irq_cml, irq_upd, irq_to;
  int errors = 0;

  SMBus_top #(.ADDR(ADDR), .FILT(FILT), .HOLD(HOLD), .STRETCH(STRETCH), .TIMEOUT(TIMEOUT)) dut (.*);
  always #5 clk = ~clk;

  task automatic fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endtask
  task automatic clocks(input int n); repeat (n) @(posedge clk); endtask

  // ------------------------------ model ------------------------------
  logic [7:0]  m_op = 8'h80, m_oo = 8'h1E, m_wp = 8'h00, m_cml = 8'h00;
  logic [15:0] m_vout = 0;
  bit          m_ov = 0, m_aack = 0;
  int          n_upd = 0, n_cmlev = 0, n_to = 0;
  function automatic int wlen(input logic [7:0] c);
    case (c) 8'h01, 8'h02, 8'h10: return 1; 8'h03: return 0; 8'h21: return 2; default: return -1; endcase
  endfunction
  function automatic int rlen(input logic [7:0] c);
    case (c)
      8'h01, 8'h02, 8'h10, 8'h19, 8'h20, 8'h78, 8'h7E, 8'h98: return 1;
      8'h21, 8'h79, 8'h8B: return 2;
      8'h99: return 5;
      default: return -1;
    endcase
  endfunction
  function automatic bit prot(input logic [7:0] c);
    if (m_wp == 8'h80) return c != 8'h10 && c != 8'h03;
    if (m_wp == 8'h40) return c != 8'h10 && c != 8'h03 && c != 8'h01;
    return 0;
  endfunction
  function automatic logic [7:0] crc8(input logic [7:0] c, input logic [7:0] b);
    logic [7:0] x;
    x = c ^ b;
    for (int k = 0; k < 8; k++) x = x[7] ? ((x << 1) ^ 8'h07) : (x << 1);
    return x;
  endfunction
  function automatic logic [7:0] sbyte();
    return {1'b0, !m_op[7], m_ov, 3'b000, m_cml != 0, 1'b0};
  endfunction
  function automatic logic [7:0] rval(input logic [7:0] c, input int i);
    logic [15:0] w;
    case (c)
      8'h01: w = m_op; 8'h02: w = m_oo; 8'h10: w = m_wp; 8'h19: w = 16'h00B0; 8'h20: w = 16'h0017;
      8'h21: w = m_vout; 8'h78: w = sbyte(); 8'h79: w = {m_ov, 7'h0, sbyte()}; 8'h7E: w = m_cml;
      8'h8B: w = read_vout; 8'h98: w = 16'h0033;
      default: begin   // 8'h99 MFR_ID
        case (i) 0: return 8'd4; 1: return "O"; 2: return "I"; 3: return "P"; default: return "F"; endcase
      end
    endcase
    return i == 0 ? w[7:0] : w[15:8];
  endfunction
  function automatic bit alert(); return (m_cml != 0 || m_ov) && !m_aack; endfunction
  task automatic cml_set(input int b);
    m_cml[b] = 1; m_aack = 0; n_cmlev++;
  endtask

  // ------------------------------ bus BFM ------------------------------
  task automatic wait_q(input int n = 1); repeat (n * Q) @(posedge clk); endtask
  task automatic scl_high();               // release SCL and wait out stretching
    scl_m = 1;
    @(posedge clk);
    while (scl !== 1'b1) @(posedge clk);
  endtask
  // the byte after a START is an address: once ACKed, the target stretches SCL
  int n_stretch = 0;
  bit adr = 0;
  task automatic start_c();
    adr = 1;
    sda_m = 1; scl_high(); wait_q();
    sda_m = 0; wait_q();
    scl_m = 0; wait_q();
  endtask
  task automatic rstart_c();
    adr = 1;
    sda_m = 1; wait_q();
    scl_high(); wait_q();
    sda_m = 0; wait_q();
    scl_m = 0; wait_q();
  endtask
  task automatic stop_c();
    sda_m = 0; wait_q();
    scl_high(); wait_q();
    sda_m = 1; wait_q(2);
  endtask
  // one bit: the host drives b (1 releases), returns what the bus carried
  task automatic bit_c(input bit b, output bit r, input bit c = 1);
    sda_m = b; sda_c = c; wait_q();
    scl_high(); wait_q();
    r = sda; wait_q();
    scl_m = 0; wait_q();
    sda_c = 1;
  endtask
  task automatic wbyte(input logic [7:0] v, output bit ack);
    bit r;
    int s0;
    for (int i = 7; i >= 0; i--) bit_c(v[i], r);
    s0 = n_stretch;
    bit_c(1, r);
    ack = !r;
    if (n_stretch - s0 != ((STRETCH != 0 && adr && ack) ? 1 : 0))
      fail($sformatf("%0d stretches after %s byte %h, ack %b", n_stretch - s0, adr ? "address" : "data", v, ack));
    adr = 0;
  endtask
  // reads a byte while another responder sends cv (1s: none)
  task automatic rbyte(output logic [7:0] v, input bit host_ack, input logic [7:0] cv = 8'hFF);
    bit r;
    for (int i = 7; i >= 0; i--) begin bit_c(1, r, cv[i]); v[i] = r; end
    bit_c(!host_ack, r);
  endtask

  // ------------------------------ transactions ------------------------------
  // write: cmd plus data bytes d[0..n-1]; pec 0 none, 1 good, 2 bad
  task automatic pm_write(input logic [7:0] c, input int n, input logic [7:0] d0 = 0,
                          input logic [7:0] d1 = 0, input logic [7:0] d2 = 0, input int pec = 0,
                          input logic [6:0] a = ADDR);
    logic [7:0] b [0:5];
    int nb, k;
    bit ack, e, drop;
    logic [7:0] crc, rc;
    b[0] = {a, 1'b0}; b[1] = c; b[2] = d0; b[3] = d1; b[4] = d2; nb = 2 + n;
    crc = crc8(crc8(0, b[0]), c);
    for (int i = 2; i < 2 + n; i++) crc = crc8(crc, b[i]);
    if (pec != 0) begin b[nb] = (pec == 1) ? crc : ~crc; nb++; end
    start_c();
    drop = 0; rc = 0;
    for (int i = 0; i < nb; i++) begin
      wbyte(b[i], ack);
      e = 0;
      if (drop) e = 0;
      else if (i == 0) begin e = (a == ADDR); drop = !e; end
      else if (i == 1) begin e = (wlen(c) >= 0 || rlen(c) >= 0); if (!e) begin cml_set(7); drop = 1; end end
      else begin
        k = i - 2;
        if (wlen(c) < 0 || k > wlen(c) || (k == 0 && prot(c)) ||
            (k == 0 && c == 8'h10 && !(b[i] == 8'h80 || b[i] == 8'h40 || b[i] == 8'h20 || b[i] == 8'h00))) begin
          cml_set(6); drop = 1;
        end else if (k < wlen(c)) e = 1;
        else if (b[i] == rc) e = 1;
        else begin cml_set(5); drop = 1; end
      end
      if (ack !== e) fail($sformatf("write %h byte %0d (%h): ack %b, expected %b", c, i, b[i], ack, e));
      rc = crc8(rc, b[i]);
    end
    stop_c();
    // the model applies the write at STOP, from the bytes on the wire: a
    // PEC sent after too few data bytes is just another data byte
    if (!drop && nb >= 2 && wlen(c) >= 0) begin
      if (nb - 2 >= wlen(c)) begin
        case (c)
          8'h01: begin m_op = b[2]; n_upd++; end
          8'h02: begin m_oo = b[2]; n_upd++; end
          8'h03: begin m_cml = 0; m_ov = vout_ov; m_aack = 0; end
          8'h10: m_wp = b[2];
          8'h21: begin m_vout = {b[3], b[2]}; n_upd++; end
          default: ;
        endcase
      end else cml_set(6);
    end
    clocks(4);
    check_regs();
  endtask

  // read: n bytes, the host ACKs all but the last (past the PEC: 0xFF)
  task automatic pm_read(input logic [7:0] c, input int n,
                         input logic [6:0] a = ADDR, input bit rbit = 1, input int extra = 0);
    bit ack, e, ok, r;
    logic [7:0] crc, v, x;
    start_c();
    wbyte({ADDR, 1'b0}, ack);
    if (!ack) fail("read: address NACKed");
    wbyte(c, ack);
    e = (wlen(c) >= 0 || rlen(c) >= 0);
    if (ack !== e) fail($sformatf("read %h: command ack %b, expected %b", c, ack, e));
    if (!e) cml_set(7);
    rstart_c();
    wbyte({a, rbit}, ack);
    ok = e && a == ADDR && rbit && rlen(c) >= 0;
    if (e && a == ADDR && rbit && rlen(c) < 0) cml_set(7);
    if (ack !== ok) fail($sformatf("read %h: address ack %b, expected %b", c, ack, ok));
    crc = crc8(crc8(crc8(0, {ADDR, 1'b0}), c), {a, rbit});
    if (ok) begin
      for (int i = 0; i < n; i++) begin
        rbyte(v, i < n - 1);
        x = (i < rlen(c)) ? rval(c, i) : (i == rlen(c)) ? crc : 8'hFF;
        if (v !== x) fail($sformatf("read %h byte %0d = %h, expected %h", c, i, v, x));
        if (i < rlen(c)) crc = crc8(crc, x);
      end
      // a host that keeps clocking after its NACK finds SDA released
      for (int i = 0; i < extra; i++) begin bit_c(1, r); if (!r) fail("SDA driven after the host NACK"); end
    end
    stop_c();
    clocks(4);
    check_regs();
  endtask

  // Alert Response Address; cv: the other responder's address byte (FF: none)
  task automatic ara_read(input bit pec, input logic [7:0] cv = 8'hFF);
    bit ack, e;
    logic [7:0] v, x;
    start_c();
    wbyte(ARA, ack);
    e = alert();                       // (the other responder's ACK is not modelled)
    if (ack !== e) fail($sformatf("ARA ack %b, expected %b", ack, e));
    if (ack) begin
      rbyte(v, pec, cv);
      // the other responder (cv) always has the lower address and wins
      x = (cv != 8'hFF) ? cv : {ADDR, 1'b0};
      if (v !== x) fail($sformatf("ARA returned %h, expected %h", v, x));
      // this target releases SMBALERT# only if its whole address went out
      if (cv == 8'hFF) m_aack = 1;
      if (pec) begin
        rbyte(v, 0);
        if (cv == 8'hFF && v !== crc8(crc8(0, ARA), {ADDR, 1'b0})) fail("ARA PEC");
      end
    end
    stop_c();
    clocks(4);
    check_regs();
  endtask

  task automatic check_regs();
    if (operation !== m_op || on_off_config !== m_oo || vout_command !== m_vout)
      fail($sformatf("outputs op %h oo %h vout %h, expected %h %h %h",
                     operation, on_off_config, vout_command, m_op, m_oo, m_vout));
    if ({dut.cml[3:1], 3'b000, dut.cml[0], 1'b0} !== m_cml) fail($sformatf("STATUS_CML %b, expected %h", dut.cml, m_cml));
    if (smbalert_n !== !alert()) fail($sformatf("SMBALERT# %b, expected %b", smbalert_n, !alert()));
  endtask

  // ------------------------------ monitors ------------------------------
  int t_fall = 0, cyc = 0, n_irq_cml = 0, n_irq_upd = 0, n_irq_to = 0;
  logic sda_o_q = 1, scl_o_q = 1;
  int t_scl_o = 0;
  bit timing_on = 1;
  always @(posedge clk) begin
    cyc++;
    if (rst_n) begin
      if (dut.fall) t_fall = cyc;
      // SDA from the target moves only while the filtered SCL is low, and
      // HOLD clocks or more after it fell
      if (sda_o !== sda_o_q && timing_on && dut.active) begin
        if (dut.scl_f !== 1'b0) fail("target changed SDA while SCL high");
        else if (cyc - t_fall < HOLD) fail($sformatf("SDA hold %0d clocks", cyc - t_fall));
      end
      if (scl_o_q && !scl_o) begin t_scl_o = cyc; n_stretch++; end
      if (!scl_o_q && scl_o && cyc - t_scl_o != STRETCH && timing_on)
        fail($sformatf("stretch of %0d clocks", cyc - t_scl_o));
      n_irq_cml += irq_cml; n_irq_upd += irq_upd; n_irq_to += irq_to;
    end
    sda_o_q = sda_o; scl_o_q = scl_o;
  end

  // ------------------------------ test ------------------------------
  logic [7:0] v;
  bit ack;
  initial begin
    clocks(3);
    if (scl_o !== 1 || sda_o !== 1 || smbalert_n !== 1) fail("bus released in reset");
    rst_n = 1;
    clocks(5);

    // ---- every command read back at reset values ----
    pm_read(8'h98, 2);                       // PMBUS_REVISION + PEC
    pm_read(8'h01, 1);  pm_read(8'h02, 1);  pm_read(8'h10, 1);
    pm_read(8'h19, 1);  pm_read(8'h20, 2);  pm_read(8'h21, 2);
    pm_read(8'h78, 1);  pm_read(8'h79, 3);  pm_read(8'h7E, 2);
    read_vout = 16'hA55A; pm_read(8'h8B, 3);
    pm_read(8'h99, 6);                       // block read: count, "OIPF", PEC
    pm_read(8'h99, 8);                       // the host keeps ACKing: 0xFF after the PEC

    // ---- writes with and without PEC ----
    pm_write(8'h21, 2, 8'hE4, 8'h0C, 0, 1);  // VOUT_COMMAND with PEC
    pm_read(8'h21, 3);
    pm_write(8'h21, 2, 8'h01, 8'h80);        // without PEC
    pm_write(8'h01, 1, 8'h00);               // OPERATION off: STATUS_BYTE OFF
    pm_read(8'h78, 1);
    pm_write(8'h01, 1, 8'h80, 0, 0, 1);
    pm_write(8'h02, 1, 8'h17);
    pm_write(8'h21, 2, 8'hFF, 8'hFF); pm_read(8'h21, 2);
    pm_write(8'h21, 2, 8'h00, 8'h00); pm_read(8'h21, 2);
    pm_write(8'h21, 2, 8'h55, 8'hAA); pm_write(8'h21, 2, 8'hAA, 8'h55);
    pm_write(8'h01, 1, 8'h7F); pm_write(8'h02, 1, 8'hFF); pm_read(8'h01, 1); pm_read(8'h78, 1);
    pm_write(8'h01, 1, 8'h80); pm_write(8'h02, 1, 8'h00); pm_write(8'h02, 1, 8'h1E);
    // a long write: 2 data bytes, the PEC, then 15 more bytes (NACKed, CML[6])
    begin : long_write
      logic [7:0] crc;
      start_c();
      wbyte({ADDR, 1'b0}, ack); if (!ack) fail("long write: address");
      wbyte(8'h21, ack);        if (!ack) fail("long write: command");
      wbyte(8'h11, ack); wbyte(8'h22, ack);
      crc = crc8(crc8(crc8(crc8(0, {ADDR, 1'b0}), 8'h21), 8'h11), 8'h22);
      wbyte(crc, ack);          if (!ack) fail("long write: PEC");
      for (int i = 0; i < 15; i++) begin wbyte(8'(i * 17), ack); if (ack) fail("long write: extra byte ACKed"); end
      stop_c();
      cml_set(6); clocks(4); check_regs();
      pm_write(8'h03, 0);
    end
    pm_read(8'h99, 17);                      // a long read: data, PEC, then 0xFF
    pm_read(8'h20, 1, ADDR, 1, 10);          // extra clocks after the host NACK
    if (smbalert_n !== 1) fail("SMBALERT# without a fault");

    // ---- faults ----
    pm_write(8'h21, 2, 8'h12, 8'h34, 0, 2);  // bad PEC: CML[5]
    pm_read(8'h7E, 1); pm_read(8'h78, 1); pm_read(8'h79, 2);
    pm_write(8'h03, 0);                      // CLEAR_FAULTS
    pm_write(8'h55, 0);                      // unsupported command: CML[7]
    pm_write(8'h03, 0, 0, 0, 0, 1);          // CLEAR_FAULTS with PEC
    pm_write(8'h01, 2, 8'h80, 8'h12);        // one byte too many: CML[6]
    pm_write(8'h03, 0);
    pm_write(8'h01, 1, 8'h40, 0, 0, 1);
    pm_write(8'h01, 2, 8'h40, 8'h00);        // wrong PEC
    pm_write(8'h03, 0);
    pm_write(8'h01, 3, 8'h40, crc8(crc8(crc8(0, {ADDR, 1'b0}), 8'h01), 8'h40), 8'h12);  // a byte after the PEC
    pm_write(8'h03, 0);
    pm_write(8'h21, 1, 8'h77);               // too few bytes: CML[6] at STOP
    pm_write(8'h03, 0);
    pm_write(8'h8B, 1, 8'h00);               // write to a read-only command: CML[6]
    pm_write(8'h03, 0);
    pm_read(8'h03, 1);                       // read of a write-only command: CML[7]
    pm_write(8'h03, 0);
    pm_read(8'h55, 1);                       // unsupported command in a read
    pm_write(8'h03, 0);
    pm_read(8'h01, 1, 7'h20);                // repeated START to another address
    pm_read(8'h01, 1, ADDR, 0);              // repeated START with the write bit
    pm_write(8'h01, 1, 8'h80, 0, 0, 0, 7'h20);   // another target's write
    if (m_cml != 0) fail("faults from transfers for other targets");

    // ---- WRITE_PROTECT ----
    pm_write(8'h10, 1, 8'h33);               // invalid value: CML[6]
    pm_write(8'h03, 0);
    pm_write(8'h10, 1, 8'h80);
    pm_write(8'h01, 1, 8'h00);               // protected
    pm_write(8'h21, 2, 8'h00, 8'h01);        // protected
    pm_write(8'h03, 0);                      // always allowed
    pm_write(8'h10, 1, 8'h40);
    pm_write(8'h01, 1, 8'h00);               // allowed at 0x40
    pm_write(8'h02, 1, 8'h00);               // protected at 0x40
    pm_write(8'h03, 0);
    pm_write(8'h10, 1, 8'h20);
    pm_write(8'h02, 1, 8'h1F); pm_write(8'h21, 2, 8'h34, 8'h12); pm_write(8'h01, 1, 8'h80);
    pm_write(8'h10, 1, 8'h00, 0, 0, 1);
    pm_read(8'h10, 2);

    // ---- SMBALERT# and the Alert Response Address ----
    ara_read(0);                             // no alert: ARA NACKed
    pm_write(8'h55, 0);                      // fault: alert
    ara_read(1);                             // ARA with PEC: alert released
    ara_read(0);                             // released: NACKed
    @(negedge clk); vout_ov = 1; clocks(3); vout_ov = 0; m_ov = 1; m_aack = 0;   // away from the clock edge
    check_regs();
    pm_read(8'h79, 2); pm_read(8'h78, 1);
    // another target with a lower address wins the arbitration
    ara_read(0, {7'h20, 1'b0});
    if (smbalert_n !== 0) fail("SMBALERT# released after a lost arbitration");
    ara_read(0);                             // now this target answers
    pm_write(8'h03, 0);                      // CLEAR_FAULTS also clears OV
    @(negedge clk); vout_ov = 1; clocks(3);
    pm_write(8'h03, 0);                      // still asserted: OV stays latched
    vout_ov = 0;
    pm_write(8'h03, 0);

    // ---- glitches shorter than FILT clocks are ignored ----
    begin : glitches
      bit r;
      start_c();
      wbyte({ADDR, 1'b0}, ack);
      wbyte(8'h01, ack);
      // OPERATION = 0x80, sent with an SCL spike before its first bit and an
      // SDA spike (a false START) while SCL is high in that bit
      sda_m = 1; wait_q();
      scl_m = 1; repeat (FILT - 1) @(posedge clk); scl_m = 0;
      wait_q();
      scl_high(); clocks(5);
      sda_g = 0; repeat (FILT - 1) @(posedge clk); sda_g = 1;
      wait_q(); scl_m = 0; wait_q();
      for (int i = 6; i >= 0; i--) bit_c(1'b0, r);
      bit_c(1, r);
      if (r !== 1'b0) fail("byte with spikes NACKed");
      stop_c();
      m_op = 8'h80; n_upd++;
      clocks(4); check_regs();
    end

    // ---- tTIMEOUT: SCL held low in a transfer ----
    begin : timeout
      int t0;
      start_c();
      wbyte({ADDR, 1'b0}, ack);
      t0 = n_irq_to;
      repeat (TIMEOUT + 20) @(posedge clk);
      if (n_irq_to - t0 != 1 || dut.active) fail("no timeout");
      m_cml[1] = 1; m_aack = 0; n_cmlev++;
      timing_on = 0; scl_m = 1; clocks(10); sda_m = 1; clocks(Q * 2); timing_on = 1;
      check_regs();
      pm_read(8'h7E, 1);
      pm_write(8'h03, 0);
    end

    // ---- random transfers ----
    for (int t = 0; t < 120; t++) begin
      int r;
      logic [7:0] c;
      r = $urandom_range(99);
      case ($urandom_range(12))
        0: c = 8'h01; 1: c = 8'h02; 2: c = 8'h03; 3: c = 8'h10; 4: c = 8'h19; 5: c = 8'h20;
        6: c = 8'h21; 7: c = 8'h78; 8: c = 8'h79; 9: c = 8'h7E; 10: c = 8'h8B; 11: c = 8'h99;
        default: c = $urandom;
      endcase
      read_vout = $urandom;
      if (c == 8'h10) begin
        logic [7:0] w;
        case ($urandom_range(4)) 0: w = 8'h80; 1: w = 8'h40; 2: w = 8'h20; 3: w = 8'h00; default: w = $urandom; endcase
        pm_write(c, 1, w, 0, 0, $urandom_range(2));
      end else if (r < 50) pm_write(c, $urandom_range(3), $urandom, $urandom, $urandom, $urandom_range(2));
      else if (r < 90) pm_read(c, $urandom_range(1, 7));
      else if (r < 95) ara_read($urandom_range(1));
      else begin @(negedge clk); vout_ov = 1; clocks(2); vout_ov = 0; if (!m_ov) m_aack = 0; m_ov = 1; clocks(2); check_regs(); end
      if ($urandom_range(7) == 0) pm_write(8'h03, 0);
    end

    // ---- a slow host (100 kHz-like) and reset mid-transfer ----
    Q = 120;
    pm_write(8'h21, 2, 8'h5A, 8'hA5, 0, 1); pm_read(8'h21, 3);
    Q = 30;
    start_c(); wbyte({ADDR, 1'b0}, ack); wbyte(8'h21, ack);
    rst_n = 0; clocks(3);
    if (scl_o !== 1 || sda_o !== 1 || smbalert_n !== 1 || operation !== 8'h80 || vout_command !== 0)
      fail("reset values");
    m_op = 8'h80; m_oo = 8'h1E; m_vout = 0; m_wp = 0; m_cml = 0; m_ov = 0; m_aack = 0;
    rst_n = 1; stop_c(); clocks(4);
    pm_read(8'h21, 2);

    if (n_irq_upd != n_upd) fail($sformatf("irq_upd %0d, expected %0d", n_irq_upd, n_upd));
    if (n_irq_to != 1) fail($sformatf("irq_to %0d", n_irq_to));
    if (n_irq_cml < 10) fail($sformatf("irq_cml only %0d", n_irq_cml));
    $display("SMBus: %0d updates, %0d CML events, %0d stretches", n_upd, n_cmlev, n_stretch);
    if (errors == 0) $display("TEST PASSED: SMBus");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #300ms;
    $display("TIMEOUT"); $finish;
  end
endmodule
