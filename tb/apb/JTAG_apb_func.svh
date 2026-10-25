// IP part of JTAG_apb_tb: the TB is the debugger on the JTAG pins (IDCODE,
// USER and BYPASS scans); each USER update raises USER_UPDATE in PCLK.
  initial begin tck = 0; tms = 1; tdi = 0; trst_n = 0; end   // test reset until ip_func
  logic tdo_s;

  // one TCK cycle (300 ns): TMS / TDI change while TCK is low
  task automatic jcyc(input logic tms_v, input logic tdi_v);
    tms = tms_v; tdi = tdi_v;
    #100 tdo_s = tdo; tck = 1'b1;
    #100 tck = 1'b0;
    #100;
  endtask

  task automatic goto_rti;
    for (int i = 0; i < 5; i++) jcyc(1'b1, 1'b0);
    jcyc(1'b0, 1'b0);
  endtask

  task automatic load_ir(input logic [3:0] op);
    jcyc(1, 0); jcyc(1, 0); jcyc(0, 0); jcyc(0, 0);
    jcyc(0, op[0]); jcyc(0, op[1]); jcyc(0, op[2]); jcyc(1, op[3]);
    jcyc(1, 0); jcyc(0, 0);
  endtask

  task automatic scan_dr(input int n, input logic [31:0] din, output logic [31:0] dout);
    jcyc(1, 0); jcyc(0, 0); jcyc(0, 0);
    dout = 0;
    for (int k = 0; k < n; k++) begin jcyc(k == n - 1, din[k]); dout[k] = tdo_s; end
    jcyc(1, 0); jcyc(0, 0);
  endtask

  task automatic ip_func;
    logic [31:0] d;
    logic [7:0]  u;
    rd_exp(A_FLAGS, 0);                                 // no streams: always 0
    trst_n = 1;
    goto_rti();
    // IDCODE after Test-Logic-Reset, no update event
    scan_dr(32, 0, d);
    if (d !== 32'h1CAF_0001) fail($sformatf("IDCODE %h", d));
    cycles(4);
    rd_exp(A_IRQ_STATUS, 0);
    // USER write: USER_UPDATE (masked), read back with a second scan
    u = 8'hA5;
    load_ir(4'b0010);
    scan_dr(8, {24'h0, u}, d);
    cycles(4);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_USER_UPDATE);
    if (irq) fail("masked irq drives the pin");
    wr(A_IRQ_STATUS, IRQ_ALL);
    rd_exp(A_IRQ_STATUS, 0);
    wr(A_IRQ_ENABLE, IRQ_ALL);
    for (int i = 0; i < 4; i++) begin
      scan_dr(8, {24'h0, ~u}, d);
      if (d[7:0] !== u) fail($sformatf("USER read %h, expected %h", d[7:0], u));
      u = ~u;
      cycles(4);
      rd_exp(A_IRQ_STATUS, 1 << IRQ_USER_UPDATE);
      if (!irq) fail("USER_UPDATE drives the pin");
      wr(A_IRQ_STATUS, IRQ_ALL);
      if (irq) fail("irq after clear");
    end
    // BYPASS: one-bit delay, no update event
    load_ir(4'b1111);
    scan_dr(8, 32'h0000_00B6, d);
    if (d[7:0] !== 8'h6C) fail($sformatf("BYPASS %h", d[7:0]));   // captured 0, then TDI one clock late
    cycles(4);
    rd_exp(A_IRQ_STATUS, 0);
    // trst_n: back to IDCODE
    trst_n = 0; #300; trst_n = 1;
    goto_rti();
    scan_dr(32, 0, d);
    if (d !== 32'h1CAF_0001) fail("IDCODE after trst_n");
    // a USER update left pending into reset
    load_ir(4'b0010);
    scan_dr(8, 32'h3C, d);
    if (d[7:0] !== 8'h00) fail("USER cleared by trst_n");
    scan_dr(8, 32'hC3, d);                              // an even update count (see the doc note)
    if (d[7:0] !== 8'h3C) fail("USER after trst_n");
    cycles(4);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_USER_UPDATE);
  endtask
