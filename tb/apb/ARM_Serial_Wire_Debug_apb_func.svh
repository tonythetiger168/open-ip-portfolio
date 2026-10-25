// SPDX-License-Identifier: Apache-2.0
// SWD-specific part of tb/ARM_Serial_Wire_Debug_apb_tb.sv. A host BFM
// (debugger) drives SWCLK / SWDIO; the TB plays the access ports through
// the registers: it takes each request from APREQ and answers it through
// APRESP while the debugger retries on WAIT. Covered: line reset, DPIDR,
// the power-up handshake through PWR and STATUS, AP writes and posted reads
// with random APs, banks and data, AP errors (FAULT, STICKYERR), WAIT,
// DAPABORT, protocol errors, APREQ overflow, APREQ popped in the very clock
// the next request is captured, every interrupt bit masked, enabled and
// cleared one by one.
logic h_oe = 1, h_out = 0;
assign swdio_in = swdio_oe ? swdio_out : (h_oe ? h_out : 1'b1);
initial swclk = 0;
int   trn_h = 1;

task automatic hcyc(input logic drv, input logic v, output logic smp);
  swclk = 0; h_oe = drv; h_out = v;
  #($urandom_range(80, 41) + 0.1 * $urandom_range(9, 0));
  swclk = 1; smp = swdio_in;
  #($urandom_range(80, 41) + 0.1 * $urandom_range(9, 0));
endtask
task automatic h_idle(input int n);
  logic s;
  for (int i = 0; i < n; i++) hcyc(1, 0, s);
endtask
task automatic lreset;
  logic s;
  for (int i = 0; i < 52; i++) hcyc(1, 1, s);
  h_idle(2);
endtask

localparam logic [2:0] OK = 3'b001, WAIT = 3'b010, FAULT = 3'b100, NONE = 3'b111;
logic [2:0]  ack;
logic [31:0] h_rd;
task automatic xfer(input logic ap, input logic rn, input logic [1:0] a, input logic [31:0] wd,
                    input bit f_par);
  logic        s;
  logic [32:0] d;
  hcyc(1, 1, s); hcyc(1, ap, s); hcyc(1, rn, s); hcyc(1, a[0], s); hcyc(1, a[1], s);
  hcyc(1, ap ^ rn ^ a[0] ^ a[1] ^ f_par, s); hcyc(1, 0, s); hcyc(1, 1, s);
  for (int i = 0; i < trn_h; i++) hcyc(0, 0, s);
  for (int i = 0; i < 3; i++) begin hcyc(0, 0, s); ack[i] = s; end
  h_rd = 'x;
  if (ack == OK) begin
    if (rn) begin
      for (int i = 0; i < 33; i++) begin hcyc(0, 0, s); d[i] = s; end
      h_rd = d[31:0];
      if (^d !== 1'b0) fail("read data parity");
      for (int i = 0; i < trn_h; i++) hcyc(0, 0, s);
    end else begin
      for (int i = 0; i < trn_h; i++) hcyc(0, 0, s);
      for (int i = 0; i < 32; i++) hcyc(1, wd[i], s);
      hcyc(1, ^wd, s);
    end
  end else for (int i = 0; i < trn_h; i++) hcyc(0, 0, s);
  h_idle(2);
endtask
task automatic dp_rd(input logic [1:0] a, input logic [31:0] e, input string what);
  xfer(0, 1, a, 0, 0);
  if (ack !== OK || h_rd !== e) fail($sformatf("%s: ACK %b data %h, expected %h", what, ack, h_rd, e));
endtask
task automatic dp_wr(input logic [1:0] a, input logic [31:0] d);
  xfer(0, 0, a, d, 0);
  if (ack !== OK) fail($sformatf("DP write %0d: ACK %b", a, ack));
endtask
// AP access retried on WAIT; returns the final ACK in `ack`
task automatic ap_x(input logic rn, input logic [1:0] a, input logic [31:0] wd);
  int w;
  w = 0;
  do begin xfer(1, rn, a, wd, 0); w++; end while (ack == WAIT && w < 200);
endtask

// ---- software access port
logic [31:0] sw_mem [0:1023];
logic [7:0]  cur_sel;
logic [3:0]  cur_bank;
// take one request, check it, answer it
task automatic serve(input logic e_wr, input logic [1:0] a, input logic [31:0] e_wd, input bit err);
  logic [31:0] q0, q1;
  int          ix;
  poll(A_FLAGS, 32'h1 << FLAG_APREQ_AVAIL, 32'h1 << FLAG_APREQ_AVAIL, 20_000);
  rd(A_APREQ0); q0 = rdv;
  rd(A_APREQ1); q1 = rdv;                     // pops
  if (q1 !== {17'h0, cur_bank, a, cur_sel, e_wr} || (e_wr && q0 !== e_wd))
    fail($sformatf("APREQ %h %h, expected %h %h", q1, q0, {17'h0, cur_bank, a, cur_sel, e_wr}, e_wd));
  ix = int'({cur_sel[3:0] ^ cur_sel[7:4], cur_bank, a});
  if (e_wr && !err) sw_mem[ix] = q0;
  wr(A_APRESP0, err ? $urandom : sw_mem[ix]);
  wr(A_APRESP1, {31'h0, err});
endtask
// a whole AP write / read with the software answering in parallel
task automatic ap_write(input logic [1:0] a, input logic [31:0] d, input bit err);
  fork ap_x(0, a, d); serve(1, a, d, err); join
  if (ack !== OK) fail($sformatf("AP write: ACK %b", ack));
endtask
task automatic ap_read(input logic [1:0] a, input bit err);   // posted: start the read
  fork ap_x(1, a, 0); serve(0, a, 0, err); join
  if (ack !== OK) fail($sformatf("AP read: ACK %b", ack));
endtask
task automatic rdbuff_exp(input logic [31:0] e);
  ap_x_dp_rdbuff();
  if (ack !== OK || h_rd !== e) fail($sformatf("RDBUFF: ACK %b data %h, expected %h", ack, h_rd, e));
endtask
task automatic ap_x_dp_rdbuff;
  int w;
  w = 0;
  do begin xfer(0, 1, 2'd3, 0, 0); w++; end while (ack == WAIT && w < 200);
endtask
task automatic select(input logic [7:0] s, input logic [3:0] b);
  cur_sel = s; cur_bank = b;
  dp_wr(2'd2, {s, 16'h0, b, 4'h0});
endtask

`define B(N) (32'h1 << IRQ_``N)
// IRQ_STATUS must read m; then every set bit alone: enable, pin, clear
task automatic walk(input logic [31:0] m, input string what);
  rd(A_IRQ_STATUS);
  if (rdv !== m) fail($sformatf("%s: IRQ_STATUS %h, expected %h", what, rdv, m));
  if (irq !== 0) fail("irq with all interrupts masked");
  for (int i = 0; i < 7; i++)
    if (m[i]) begin
      wr(A_IRQ_ENABLE, 32'h1 << i);
      if (irq !== 1) fail($sformatf("irq bit %0d does not reach the pin", i));
      wr(A_IRQ_STATUS, 32'h1 << i);
      if (irq !== 0) fail($sformatf("irq bit %0d not cleared", i));
    end
  wr(A_IRQ_ENABLE, 0);
  rd_exp(A_IRQ_STATUS, 0);
endtask

task automatic ip_func;
  logic [31:0] d, prev;
  logic [1:0]  a;
  logic [31:0] q;
  for (int i = 0; i < 1024; i++) sw_mem[i] = $urandom;
  rd_exp(A_STATUS, 32'h2);                    // locked out
  rd_exp(A_APREQ1, 0);                        // empty: reset value, no pop
  h_idle(3);
  lreset();
  dp_rd(2'd0, 32'h0010_1001, "DPIDR");
  walk(`B(LINE_RESET), "line reset");

  // ---- power-up handshake: requests in STATUS, acknowledges from PWR
  dp_wr(2'd1, 32'h5000_0000);
  rd_exp(A_STATUS, 32'hC);
  dp_rd(2'd1, 32'h5000_0000, "power-up requested");
  wr(A_PWR, 3);
  dp_rd(2'd1, 32'hF000_0000, "power-up acknowledged");

  // ---- AP traffic: random APs, banks and data
  prev = 'x;
  for (int i = 0; i < 24; i++) begin
    select($urandom, $urandom);
    a = $urandom;
    case (i % 4)
      0: d = 32'hFFFF_FFFF;
      1: d = 32'h0;
      default: d = $urandom;
    endcase
    ap_write(a, d, 0);
    ap_read(a, 0);
    rdbuff_exp(d);
  end
  rd_exp(A_IRQ_STATUS, `B(APREQ_AVAIL));
  wr(A_IRQ_STATUS, IRQ_ALL);

  // ---- WAIT: a second AP access while the software has not answered
  select(8'h3C, 4'h5);
  fork
    begin xfer(1, 0, 2'd1, 32'h1111_2222, 0); xfer(1, 0, 2'd2, 32'h3333_4444, 0); end
  join
  if (ack !== WAIT) fail("no WAIT while the AP access is pending");
  rd_exp(A_STATUS, 32'hD);                    // busy, power requests
  serve(1, 2'd1, 32'h1111_2222, 0);
  walk(`B(WAIT) | `B(APREQ_AVAIL), "WAIT");

  // ---- AP error: STICKYERR, then FAULT
  ap_write(2'd0, 32'h5555_AAAA, 1);
  dp_rd(2'd1, 32'hF000_0060, "STICKYERR");
  ap_x(0, 2'd0, 32'h1);
  if (ack !== FAULT) fail("no FAULT with STICKYERR");
  dp_wr(2'd0, 32'h4);
  walk(`B(FAULT) | `B(APREQ_AVAIL), "FAULT");
  ap_read(2'd0, 1);                           // read error: READOK 0
  dp_rd(2'd1, 32'hF000_0020, "read error");
  dp_wr(2'd0, 32'h4);
  wr(A_IRQ_STATUS, IRQ_ALL);

  // ---- DAPABORT: the software never answers; a late answer is ignored
  xfer(1, 0, 2'd3, 32'h7777_7777, 0);
  if (ack !== OK) fail("AP write before the abort");
  dp_wr(2'd0, 32'h1);
  rd_exp(A_STATUS, 32'hC);
  rd(A_APREQ1);                               // drop the aborted request
  wr(A_APRESP1, 0);                           // nothing in progress: ignored
  rd_exp(A_STATUS, 32'hC);
  walk(`B(ABORT) | `B(APREQ_AVAIL), "abort");

  // ---- APREQ overflow: answered without reading APREQ, then a second request
  fork xfer(1, 0, 2'd0, 32'hAAAA_0001, 0); begin
    poll(A_STATUS, 32'h1, 32'h1, 20_000); wr(A_APRESP1, 0); end join
  fork xfer(1, 0, 2'd0, 32'hAAAA_0002, 0); begin
    poll(A_STATUS, 32'h1, 32'h1, 20_000); wr(A_APRESP1, 0); end join
  walk(`B(APREQ_AVAIL) | `B(APREQ_OVF), "APREQ overflow");
  rd(A_APREQ0);
  if (rdv !== 32'hAAAA_0001) fail("APREQ overflow: first request not kept");
  rd(A_APREQ1);

  // ---- pop APREQ in the very clock the next request is captured
  fork xfer(1, 0, 2'd1, 32'hBBBB_0001, 0); begin
    poll(A_STATUS, 32'h1, 32'h1, 20_000); wr(A_APRESP1, 0); end join
  rd_exp(A_APREQ0, 32'hBBBB_0001);            // left in APREQ
  wr(A_IRQ_STATUS, IRQ_ALL);
  fork
    xfer(1, 1, 2'd2, 0, 0);
    begin
      while (!(dut.u_core.st == 4 && dut.u_core.rise && dut.u_core.k3 == 1)) @(negedge PCLK);
      apb_now(0, A_APREQ1, 0, 0);             // access phase sees ap_req
      if (rdv !== {17'h0, cur_bank, 2'd1, cur_sel, 1'b1}) fail("pop at capture: first request");
    end
  join
  walk(`B(APREQ_AVAIL), "pop at capture");
  serve(0, 2'd2, 0, 0);

  // ---- protocol error and recovery
  xfer(0, 1, 2'd0, 0, 1);
  if (ack !== NONE) fail("answer to a bad request");
  rd_exp(A_STATUS, 32'hE);                    // locked out
  lreset();
  dp_rd(2'd0, 32'h0010_1001, "DPIDR after a protocol error");
  walk(`B(PROTO_ERR) | `B(LINE_RESET), "protocol error");
  // power down; leave a request pending for the final reset
  dp_wr(2'd1, 0);
  wr(A_PWR, 0);
  xfer(1, 0, 2'd0, 32'h1, 0);
endtask
