// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for ARM_Serial_Wire_Debug_top v2.0 (SW-DP)
//  * A host BFM drives SWCLK (random high / low times from the 4-clk
//    minimum upwards, random phase to clk) and SWDIO (pull-up when nobody
//    drives); it builds every packet bit by bit from the protocol, retries
//    on WAIT and checks ACK, read data and read parity.
//  * An AP model (1024-word memory, programmable latency, error injection)
//    answers ap_req; a power controller acknowledges the power-up requests.
//  * The TB keeps its own model of the DP registers (sticky flags, READOK,
//    ORUNDETECT, TURNROUND, SELECT, RDBUFF, RESEND) and checks every DP
//    read and every AP request against it.
//  * Scenarios: lockout at power-on, line reset (and the JTAG-to-SWD
//    sequence), DPIDR first, protocol errors (request parity, stop, park,
//    other first packet), posted AP reads with RDBUFF and RESEND, WAIT on a
//    slow AP (AP access and RDBUFF), AP errors (STICKYERR, FAULT), write
//    data parity (WDATAERR), overrun detection (data phases after WAIT /
//    FAULT, STICKYORUN), DAPABORT, every TURNROUND, every DP bank, line
//    reset inside a packet, reset in the middle of a packet.
// ============================================================================
`timescale 1ns/1ps
module ARM_Serial_Wire_Debug_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction

  // ---------------- pins ----------------
  logic swclk = 0, h_oe = 1, h_out = 0;
  wire  swdio_out, swdio_oe;
  wire  line = swdio_oe ? swdio_out : (h_oe ? h_out : 1'b1);
  logic cdbgpwrupack = 0, csyspwrupack = 0;
  wire  cdbgpwrupreq, csyspwrupreq;
  wire        ap_req, ap_busy, ap_write, ap_abort;
  wire [7:0]  ap_sel;
  wire [5:0]  ap_addr;
  wire [31:0] ap_wdata;
  logic       ap_done = 0, ap_err = 0;
  logic [31:0] ap_rdata = 0;
  wire  lockout, line_reset, proto_err, ack_wait, ack_fault;

  localparam logic [31:0] ID = 32'h0010_1001;
  ARM_Serial_Wire_Debug_top #(.DPIDR(ID)) dut (
    .clk(clk), .rst_n(rst_n), .swclk(swclk), .swdio_in(line), .swdio_out(swdio_out),
    .swdio_oe(swdio_oe), .cdbgpwrupreq(cdbgpwrupreq), .cdbgpwrupack(cdbgpwrupack),
    .csyspwrupreq(csyspwrupreq), .csyspwrupack(csyspwrupack),
    .ap_req(ap_req), .ap_busy(ap_busy), .ap_write(ap_write), .ap_sel(ap_sel), .ap_addr(ap_addr), .ap_wdata(ap_wdata),
    .ap_done(ap_done), .ap_rdata(ap_rdata), .ap_err(ap_err), .ap_abort(ap_abort),
    .lockout(lockout), .line_reset(line_reset), .proto_err(proto_err),
    .ack_wait(ack_wait), .ack_fault(ack_fault));

  // ---------------- TB model of the DP ----------------
  logic        m_orun = 0, m_sorun = 0, m_serr = 0, m_readok = 0, m_wderr = 0;
  logic [1:0]  m_trn = 0;
  logic [7:0]  m_apsel = 0;
  logic [3:0]  m_apbank = 0, m_dpbank = 0;
  logic [31:0] m_rdbuf = 0, m_last = 0;
  logic        m_cdbg = 0, m_csys = 0;
  function automatic logic [31:0] m_ctrl();
    return {csyspwrupack, m_csys, cdbgpwrupack, m_cdbg, 20'h0, m_wderr, m_readok, m_serr, 1'b0,
            2'b00, m_sorun, m_orun};
  endfunction

  // ---------------- power controller: acknowledges after a few clocks ----------------
  logic [3:0] pw_d = 0, ps_d = 0;
  always @(negedge clk) begin
    pw_d = {pw_d[2:0], cdbgpwrupreq}; ps_d = {ps_d[2:0], csyspwrupreq};
    cdbgpwrupack = pw_d[3]; csyspwrupack = ps_d[3];
  end

  // ---------------- AP model ----------------
  logic [31:0] mem [0:1023];
  int          ap_lat = 0;                // clocks from ap_req to ap_done
  bit          ap_err_next = 0;
  bit          ap_pend = 0;
  int          ap_cnt;
  int          n_ap = 0, n_abort = 0;
  bit          e_valid = 0;               // expected request
  logic        e_write;
  logic [7:0]  e_sel;
  logic [5:0]  e_addr;
  logic [31:0] e_wdata;
  function automatic int idx_of(input logic [7:0] s, input logic [5:0] a);
    return int'({s[3:0] ^ s[7:4], a});
  endfunction
  always @(negedge clk) begin
    ap_done = 0; ap_err = 0; ap_rdata = $urandom;   // only valid with ap_done
    if (ap_abort) begin n_abort++; ap_pend = 0; end
    if (ap_req || ap_pend) begin
      if (ap_req) begin
        if (ap_pend) fail("AP request while one is in progress");
        ap_pend = 1; ap_cnt = ap_lat;
        if (!e_valid) fail("unexpected AP request");
        else if (ap_write !== e_write || ap_sel !== e_sel || ap_addr !== e_addr
                 || (e_write && ap_wdata !== e_wdata))
          fail($sformatf("AP request w%0d sel %h addr %h data %h, expected w%0d %h %h %h",
                         ap_write, ap_sel, ap_addr, ap_wdata, e_write, e_sel, e_addr, e_wdata));
        e_valid = 0;
      end
      if (ap_cnt == 0) begin
        if (ap_write) begin if (!ap_err_next) mem[idx_of(ap_sel, ap_addr)] = ap_wdata; end
        else begin
          ap_rdata = ap_err_next ? {$urandom} : mem[idx_of(ap_sel, ap_addr)];
          m_rdbuf = ap_rdata; m_readok = !ap_err_next;
        end
        if (ap_err_next) m_serr = 1;
        ap_err = ap_err_next; ap_err_next = 0;
        ap_done = 1; ap_pend = 0; n_ap++;
      end else ap_cnt--;
    end
  end

  // ---------------- host BFM ----------------
  int lo_min = 41, lo_max = 120, hi_min = 41, hi_max = 120;   // ns
  task automatic hcyc(input logic drv, input logic v, output logic smp);
    swclk = 0; h_oe = drv; h_out = v;
    #($urandom_range(lo_max, lo_min) + 0.1 * $urandom_range(9, 0));
    swclk = 1; smp = line;
    #($urandom_range(hi_max, hi_min) + 0.1 * $urandom_range(9, 0));
  endtask
  task automatic idle(input int n);
    logic s;
    for (int i = 0; i < n; i++) hcyc(1, 0, s);
  endtask
  task automatic ones(input int n);
    logic s;
    for (int i = 0; i < n; i++) hcyc(1, 1, s);
  endtask
  task automatic lreset;
    lreset_n(50);
  endtask
  task automatic lreset_n(input int n);
    ones(n); idle(2);
  endtask

  localparam logic [2:0] OK = 3'b001, WAIT = 3'b010, FAULT = 3'b100, NONE = 3'b111;
  int n_ok = 0, n_wait = 0, n_fault = 0, n_none = 0;
  bit no_idle = 0;                             // no idle cycles after a packet
  logic [2:0]  ack;
  logic [31:0] rd;
  // one packet; ack bits in sampling order (bit 0 first)
  task automatic xfer(input logic ap, input logic rn, input logic [1:0] a, input logic [31:0] wd);
    xfer_f(ap, rn, a, wd, 0, 0, 0, 0);
  endtask
  task automatic xfer_f(input logic ap, input logic rn, input logic [1:0] a, input logic [31:0] wd,
                        input bit f_par, input bit f_stop, input bit f_park, input bit f_wpar);
    logic        s;
    logic [32:0] d;
    int          trn;
    trn = int'(m_trn) + 1;
    hcyc(1, 1, s); hcyc(1, ap, s); hcyc(1, rn, s); hcyc(1, a[0], s); hcyc(1, a[1], s);
    hcyc(1, ap ^ rn ^ a[0] ^ a[1] ^ f_par, s); hcyc(1, f_stop, s); hcyc(1, !f_park, s);
    for (int i = 0; i < trn; i++) hcyc(0, 0, s);
    for (int i = 0; i < 3; i++) begin hcyc(0, 0, s); ack[i] = s; end
    rd = 'x;
    if (ack == OK || ((ack == WAIT || ack == FAULT) && m_orun)) begin
      if (rn) begin
        for (int i = 0; i < 33; i++) begin hcyc(0, 0, s); d[i] = s; end
        rd = d[31:0];
        if (^d !== 1'b0) fail("read data parity");
        for (int i = 0; i < trn; i++) hcyc(0, 0, s);
      end else begin
        for (int i = 0; i < trn; i++) hcyc(0, 0, s);
        for (int i = 0; i < 32; i++) hcyc(1, wd[i], s);
        hcyc(1, ^wd ^ f_wpar, s);
      end
    end else for (int i = 0; i < trn; i++) hcyc(0, 0, s);
    case (ack)
      OK: n_ok++;
      WAIT: n_wait++;
      FAULT: n_fault++;
      NONE: n_none++;
      default: fail($sformatf("ACK %b", ack));
    endcase
    if ((ack == WAIT || ack == FAULT) && m_orun) m_sorun = 1;
    if (!no_idle) idle($urandom_range(2, 0));
  endtask

  // ---- DP / AP accesses checked against the TB model
  task automatic expect_ack(input logic [2:0] e, input string what);
    if (ack !== e) fail($sformatf("%s: ACK %b, expected %b", what, ack, e));
  endtask
  task automatic dp_rd(input logic [1:0] a, input logic [31:0] e, input string what);
    xfer(0, 1, a, 0);
    expect_ack(OK, what);
    if (ack == OK && rd !== e) fail($sformatf("%s: read %h, expected %h", what, rd, e));
  endtask
  task automatic dp_wr(input logic [1:0] a, input logic [31:0] d);
    dp_wr_f(a, d, 0);
  endtask
  task automatic dp_wr_f(input logic [1:0] a, input logic [31:0] d, input bit f_wpar);
    xfer_f(0, 0, a, d, 0, 0, 0, f_wpar);
    expect_ack(OK, "DP write");
    if (f_wpar) m_wderr = 1;
    else case (a)
      2'd0: begin
        if (d[2]) m_serr = 0;
        if (d[3]) m_wderr = 0;
        if (d[4]) m_sorun = 0;
      end
      2'd1: if (m_dpbank == 0) begin m_orun = d[0]; m_cdbg = d[28]; m_csys = d[30]; end
            else if (m_dpbank == 1) m_trn = d[9:8];
      2'd2: begin m_apsel = d[31:24]; m_apbank = d[7:4]; m_dpbank = d[3:0]; end
      default: ;
    endcase
  endtask
  // wait for the AP to finish (bounded)
  task automatic ap_idle;
    int g;
    g = 0;
    while ((ap_busy || e_valid) && g < 100_000) begin @(negedge clk); g++; end
    if (g >= 100_000) fail("AP request never completed");
  endtask
  // AP write, retried on WAIT; expects OK, or FAULT with a sticky flag set
  task automatic ap_wr(input logic [1:0] a, input logic [31:0] d);
    ap_wr_f(a, d, 0);
  endtask
  task automatic ap_wr_f(input logic [1:0] a, input logic [31:0] d, input bit f_wpar);
    bit sticky;
    int w;
    w = 0;
    do begin
      sticky = m_serr || m_sorun || m_wderr;
      e_write = 1; e_sel = m_apsel; e_addr = {m_apbank, a}; e_wdata = d;
      e_valid = !sticky && !f_wpar;               // the request comes at the end of the packet
      xfer_f(1, 0, a, d, 0, 0, 0, f_wpar);
      if (ack != OK) e_valid = 0;
      w++;
    end while (ack == WAIT && !m_orun && w < 1000);
    if (sticky) expect_ack(FAULT, "AP write with a sticky flag");
    else if (ack == OK) begin
      if (f_wpar) m_wderr = 1;
      else if (e_valid) fail("AP write: no request");
    end else if (!(ack == WAIT && m_orun)) fail($sformatf("AP write: ACK %b", ack));
  endtask
  // AP read (posted): returns the previous result; then RDBUFF has the new one
  task automatic ap_rd(input logic [1:0] a, output logic [31:0] got);
    bit sticky;
    int w;
    logic [31:0] e;
    w = 0;
    if (!m_orun && ap_busy && !ap_write) ap_idle();  // RDBUFF still changing
    do begin
      sticky = m_serr || m_sorun || m_wderr;
      e = m_rdbuf;
      e_write = 0; e_sel = m_apsel; e_addr = {m_apbank, a};
      e_valid = !sticky;                          // the request comes with the ACK
      xfer(1, 1, a, 0);
      if (ack != OK) e_valid = 0;
      w++;
    end while (ack == WAIT && !m_orun && w < 1000);
    got = rd;
    if (sticky) expect_ack(FAULT, "AP read with a sticky flag");
    else if (ack == OK) begin
      if (rd !== e) fail($sformatf("AP read: posted data %h, expected %h", rd, e));
      if (e_valid) fail("AP read: no request");
      m_last = e;
    end else if (!(ack == WAIT && m_orun)) fail($sformatf("AP read: ACK %b", ack));
  endtask
  // RDBUFF, retried on WAIT
  task automatic rdbuff(output logic [31:0] got);
    int w;
    w = 0;
    do begin xfer(0, 1, 2'd3, 0); w++; end while (ack == WAIT && w < 1000);
    expect_ack(OK, "RDBUFF");
    if (rd !== m_rdbuf) fail($sformatf("RDBUFF %h, expected %h", rd, m_rdbuf));
    m_last = m_rdbuf; got = rd;
  endtask
  task automatic check_ctrl(input string what);
    logic [3:0] b;
    b = m_dpbank;
    if (b != 0) dp_wr(2'd2, {m_apsel, 16'h0, m_apbank, 4'd0});
    dp_rd(2'd1, m_ctrl(), what);
    if (b != 0) dp_wr(2'd2, {m_apsel, 16'h0, m_apbank, b});
  endtask
  // select an AP and bank, keep DPBANKSEL
  task automatic sel(input logic [7:0] s, input logic [3:0] bank);
    dp_wr(2'd2, {s, 16'h0, bank, m_dpbank});
  endtask

  // ---------------- scenarios ----------------
  logic [31:0] d, g;
  logic [1:0]  aa;
  logic        s;
  initial begin
    for (int i = 0; i < 1024; i++) mem[i] = $urandom;
    #33 rst_n = 1;
    #50;

    // 1. locked out from reset: no answer until a line reset
    if (!lockout) fail("not locked out after reset");
    idle(4);
    xfer(0, 1, 2'd0, 0); expect_ack(NONE, "before line reset");
    // JTAG-to-SWD select sequence, then line reset; a first packet that is
    // not a DPIDR read is a protocol error
    ones(56); begin for (int i = 0; i < 16; i++) hcyc(1, 16'hE79E >> i, s); end
    lreset_n(60);
    if (lockout) fail("locked out after line reset");
    xfer(0, 1, 2'd1, 0); expect_ack(NONE, "CTRL/STAT read as first packet");
    if (!lockout) fail("no lockout after a protocol error");
    xfer(0, 1, 2'd0, 0); expect_ack(NONE, "DPIDR read while locked out");
    lreset();
    xfer(0, 0, 2'd0, 32'h1E); expect_ack(NONE, "write as first packet");
    lreset();
    xfer(1, 1, 2'd0, 0); expect_ack(NONE, "AP read as first packet");
    lreset();
    dp_rd(2'd0, ID, "DPIDR");
    dp_rd(2'd0, ID, "DPIDR again");
    check_ctrl("CTRL/STAT after reset");

    // 2. power-up handshake
    dp_wr(2'd1, 32'h5000_0000);
    idle(4); check_ctrl("power-up requested");
    if (!(cdbgpwrupack && csyspwrupack)) fail("power-up not acknowledged");

    // 3. AP traffic: random APs, banks and data; all-ones / all-zeros words
    for (int i = 0; i < 60; i++) begin
      sel($urandom, $urandom);
      aa = $urandom;
      case (i % 6)
        0: d = 32'hFFFF_FFFF;
        1: d = 32'h0;
        default: d = $urandom;
      endcase
      ap_wr(aa, d);
      ap_rd(aa, g);
      ap_idle(); dp_rd(2'd2, m_last, "RESEND after an AP read");
      rdbuff(g);
      if (g !== d) fail($sformatf("AP readback %h, expected %h", g, d));
      dp_rd(2'd2, g, "RESEND");
    end
    // reads back to back: each returns the previous one
    sel(8'hA5, 4'h3);
    ap_rd(2'd0, g); ap_rd(2'd1, g); ap_rd(2'd2, g); ap_rd(2'd3, g); rdbuff(g);
    check_ctrl("after AP traffic");

    // 4. a slow AP: WAIT on AP accesses and on RDBUFF
    ap_lat = 3000;
    ap_wr(2'd1, 32'hCAFE_0001);
    ap_wr(2'd2, 32'hCAFE_0002);              // first try gets WAIT
    ap_rd(2'd1, g);
    rdbuff(g);                                // WAIT, then the data
    if (g !== 32'hCAFE_0001) fail("slow AP: read back");
    dp_rd(2'd0, ID, "DPIDR while the AP is busy");
    ap_lat = 0;
    if (n_wait == 0) fail("no WAIT seen");

    // 5. AP error: STICKYERR, FAULT on AP accesses, DP still works
    ap_err_next = 1; ap_wr(2'd0, 32'h1234_5678); ap_idle();
    check_ctrl("STICKYERR");
    ap_wr(2'd0, 32'h1);
    ap_rd(2'd0, g);
    rdbuff(g);
    dp_wr(2'd0, 32'h4);                       // STKERRCLR
    check_ctrl("STICKYERR cleared");
    ap_err_next = 1; ap_rd(2'd2, g); ap_idle();
    check_ctrl("read error: READOK 0");
    dp_wr(2'd0, 32'h4);
    ap_rd(2'd2, g); ap_idle(); check_ctrl("READOK 1");

    // 6. write data parity: WDATAERR, the write is dropped
    dp_wr_f(2'd1, {1'b0, m_csys, 1'b0, m_cdbg, 27'h0, 1'b1}, 1);
    check_ctrl("WDATAERR from a DP write");
    ap_wr(2'd3, 32'h0BAD_0BAD);               // FAULT
    dp_wr(2'd0, 32'h8);                       // WDERRCLR
    ap_wr_f(2'd3, 32'h0BAD_0BAD, 1);
    check_ctrl("WDATAERR from an AP write");
    dp_wr(2'd0, 32'h8);
    ap_rd(2'd3, g); rdbuff(g);
    if (g === 32'h0BAD_0BAD) fail("AP write with a parity error was not dropped");

    // 7. overrun detection: data phases after WAIT / FAULT, STICKYORUN
    dp_wr(2'd1, {1'b0, m_csys, 1'b0, m_cdbg, 27'h0, 1'b1});
    check_ctrl("ORUNDETECT on");
    ap_lat = 3000;
    ap_wr(2'd0, 32'h7777_0000);
    ap_wr(2'd1, 32'h7777_0001);               // WAIT with a data phase: STICKYORUN
    check_ctrl("STICKYORUN after a write");
    ap_rd(2'd1, g);                           // FAULT with a data phase
    ap_idle();
    dp_wr(2'd0, 32'h10);                      // ORUNERRCLR
    ap_rd(2'd0, g);                           // starts a slow read
    ap_rd(2'd0, g);                           // WAIT on a read: data phase of zeros
    if (g !== 0) fail("read data after WAIT in overrun mode");
    check_ctrl("STICKYORUN after a read");
    ap_idle();
    dp_wr(2'd0, 32'h10);
    check_ctrl("STICKYORUN cleared, ORUNDETECT on");
    dp_wr(2'd1, {1'b0, m_csys, 1'b0, m_cdbg, 28'h0});
    ap_lat = 0;
    check_ctrl("overrun detection off");

    // 8. DAPABORT drops a slow AP access
    ap_lat = 100_000;
    ap_wr(2'd2, 32'hABCD_EF01);
    dp_wr(2'd0, 32'h1);
    @(negedge clk);
    if (ap_busy || n_abort == 0) fail("DAPABORT did not drop the AP access");
    e_valid = 0;
    dp_wr(2'd0, 32'h1);                       // nothing in progress
    ap_lat = 0;
    ap_rd(2'd2, g); rdbuff(g);

    // 9. every TURNROUND and every DP bank
    for (int t = 1; t < 4; t++) begin
      dp_wr(2'd2, {m_apsel, 16'h0, m_apbank, 4'd1});
      dp_wr(2'd1, {22'h0, 2'(t), 8'h00});
      dp_rd(2'd1, {22'h0, 2'(t), 8'h00}, "DLCR");
      dp_rd(2'd0, ID, "DPIDR with a longer turnaround");
      ap_wr(2'(t), 32'h5A5A_0000 | t); ap_rd(2'(t), g); rdbuff(g);
      if (g !== (32'h5A5A_0000 | t)) fail("readback with a longer turnaround");
    end
    for (int b = 2; b < 16; b++) begin
      dp_wr(2'd2, {m_apsel, 16'h0, m_apbank, 4'(b)});
      dp_rd(2'd1, 0, "reserved DP bank");
      dp_wr(2'd1, 32'hFFFF_FFFF);             // ignored
    end
    dp_wr(2'd2, {m_apsel, 16'h0, m_apbank, 4'd1});
    dp_wr(2'd1, 32'h0);
    dp_wr(2'd2, {m_apsel, 16'h0, m_apbank, 4'd0});
    dp_wr(2'd3, 32'hFFFF_FFFF);               // ignored
    check_ctrl("after bank sweep");

    // 10. protocol errors, each followed by a line reset
    xfer_f(0, 1, 2'd0, 0, 1, 0, 0, 0); expect_ack(NONE, "request parity"); lreset(); dp_rd(2'd0, ID, "after parity");
    xfer_f(0, 1, 2'd0, 0, 0, 1, 0, 0); expect_ack(NONE, "stop bit"); lreset(); dp_rd(2'd0, ID, "after stop");
    xfer_f(0, 1, 2'd0, 0, 0, 0, 1, 0); expect_ack(NONE, "park bit"); lreset(); dp_rd(2'd0, ID, "after park");
    // a request cut short by a line reset
    begin hcyc(1, 1, s); hcyc(1, 0, s); hcyc(1, 1, s); end
    lreset(); dp_rd(2'd0, ID, "line reset after a cut request");
    // a write to ABORT whose data runs into a line reset: 11 zeros, then
    // ones (data 0xFFFFF800, parity 1: no effect); the ones go on as a
    // bad request and a line reset
    begin
      hcyc(1, 1, s); hcyc(1, 0, s); hcyc(1, 0, s); hcyc(1, 0, s); hcyc(1, 0, s); hcyc(1, 0, s);
      hcyc(1, 0, s); hcyc(1, 1, s);
      hcyc(0, 0, s); for (int i = 0; i < 3; i++) hcyc(0, 0, s); hcyc(0, 0, s);
      for (int i = 0; i < 11; i++) hcyc(1, 0, s);
    end
    lreset_n(80); dp_rd(2'd0, ID, "line reset after a write");
    // ones the target drives do not count towards a line reset: RDBUFF
    // 0xFFFF8000 ends in 18 driven ones; 1 turnaround + 31 host ones make
    // a bad request (locked out), not a line reset
    ap_wr(2'd0, 32'hFFFF_8000); ap_rd(2'd0, g); ap_idle();
    no_idle = 1; xfer(0, 1, 2'd3, 0); no_idle = 0;
    expect_ack(OK, "RDBUFF 0xFFFF8000");
    if (rd !== 32'hFFFF_8000) fail("RDBUFF 0xFFFF8000");
    ones(31); idle(2); xfer(0, 1, 2'd0, 0); expect_ack(NONE, "driven ones");
    lreset(); dp_rd(2'd0, ID, "after driven ones");
    // 49 ones are not a line reset (they make a bad request: locked out)
    idle(2); ones(49); idle(2); xfer(0, 1, 2'd0, 0); expect_ack(NONE, "after 49 ones");
    lreset(); dp_rd(2'd0, ID, "after 49 ones");
    lreset_n(50); dp_rd(2'd0, ID, "50 ones");
    // one idle cycle then a 1 after the line reset: still in reset
    ones(50); begin hcyc(1, 0, s); hcyc(1, 1, s); hcyc(1, 0, s); end
    xfer(0, 1, 2'd0, 0); expect_ack(NONE, "packet after an interrupted idle");
    lreset(); dp_rd(2'd0, ID, "after an interrupted idle");

    // 11. the fastest SWCLK, then a slow one
    lo_min = 40; lo_max = 40; hi_min = 40; hi_max = 40;
    for (int i = 0; i < 6; i++) begin
      d = $urandom; ap_wr(2'd0, d); ap_rd(2'd0, g); rdbuff(g);
      if (g !== d) fail("fast SWCLK readback");
    end
    lo_min = 300; lo_max = 900; hi_min = 300; hi_max = 900;
    d = $urandom; ap_wr(2'd1, d); ap_rd(2'd1, g); rdbuff(g);
    if (g !== d) fail("slow SWCLK readback");
    lo_min = 41; lo_max = 120; hi_min = 41; hi_max = 120;

    // 11b. AP select 0xFF, alternating data written and read back
    dp_wr(2'd2, 32'hFF00_0000);
    for (int i = 0; i < 2; i++) begin
      d = i == 0 ? 32'h5555_5555 : 32'hAAAA_AAAA;
      ap_wr(2'(i), d); ap_rd(2'(i), g); rdbuff(g);
      if (g !== d) fail("pattern readback");
    end
    dp_wr(2'd2, 32'h0);

    // 12. power down, reset in the middle of a packet
    dp_wr(2'd1, 32'h0); idle(6); check_ctrl("powered down");
    fork
      xfer(0, 1, 2'd0, 0);
      begin #600; rst_n = 0; #100; rst_n = 1; end
    join
    m_orun = 0; m_sorun = 0; m_serr = 0; m_readok = 0; m_wderr = 0; m_trn = 0; m_apsel = 0;
    m_apbank = 0; m_dpbank = 0; m_rdbuf = 0; m_last = 0; m_cdbg = 0; m_csys = 0; e_valid = 0;
    idle(2);
    if (!lockout) fail("not locked out after reset");
    lreset(); dp_rd(2'd0, ID, "after reset"); check_ctrl("after reset");

    $display("ok %0d wait %0d fault %0d none %0d ap %0d abort %0d", n_ok, n_wait, n_fault, n_none,
             n_ap, n_abort);
    if (errors == 0) $display("TEST PASSED: ARM_Serial_Wire_Debug");
    else $display("TEST FAILED: ARM_Serial_Wire_Debug (%0d errors)", errors);
    $finish;
  end
  initial begin #50ms; $display("TEST FAILED: ARM_Serial_Wire_Debug (timeout)"); $finish; end
endmodule
