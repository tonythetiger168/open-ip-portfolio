// SPDX-License-Identifier: Apache-2.0
// Wishbone-specific part of tb/Wishbone_apb_tb.sv. The TB is the Wishbone
// host: pipelined cycles (a request every clock that stall_o allows, with
// gaps) and classic cycles (each strobe held until its acknowledge).
// Every acknowledge is checked in order against the requests taken and a
// model of the memory: ACK or ERR, read data, SEL byte lanes, the hole
// (reads 0, writes dropped), the wait state of the slow window, nothing
// acknowledged twice or without a request.
// Covered through the registers: ERR (held by the core until reset: a
// write-1 does not clear it), masked, left pending into reset.
initial begin cyc_i = 0; stb_i = 0; we_i = 0; adr_i = 0; dat_i = 0; sel_i = 0; cti_i = 0; end
logic [31:0] mdl [0:255];
bit          use_fix = 0;
logic [31:0] wfix;
typedef logic [68:0] req_t;                              // {we, address, data, sel}
req_t pend [$];
int   n_resp = 0;
// responses, in order
always @(posedge PCLK) if (PRESETN && (ack_o || err_o)) begin : b_resp
  req_t r;
  logic [31:0] e, a, d;
  logic [3:0]  sl;
  if (ack_o && err_o) fail("ack_o and err_o together");
  if (pend.size() == 0) fail("an acknowledge with no request");
  else begin
    r = pend.pop_front();
    {a, d, sl} = r[67:0];
    n_resp++;
    if (err_o !== (a >= 32'h800)) fail($sformatf("err_o %b for %h", err_o, a));
    if (!r[68]) begin
      e = a < 32'h400 ? mdl[a[9:2]] : 32'h0;
      if (dat_o !== e) fail($sformatf("read %h = %h, expected %h", a, dat_o, e));
    end else if (a < 32'h400)
      for (int k = 0; k < 4; k++) if (sl[k]) mdl[a[9:2]][8*k +: 8] = d[8*k +: 8];
  end
end
function automatic req_t mk(input bit we, input logic [31:0] a, input bit full);
  req_t r;
  r = {we, a, use_fix ? wfix : 32'($urandom), full ? 4'hF : 4'($urandom)};
  return r;
endfunction
task automatic drive(input req_t r);
  {we_i, adr_i, dat_i, sel_i} = r;
endtask
task automatic wait_done(input int n);
  int t;
  t = 0;
  while (n_resp < n && t < 100) begin @(negedge PCLK); t++; end
  if (t == 100) fail("acknowledges missing");
  #1;
  if (pend.size() != 0) fail("requests not acknowledged");
endtask
// a pipelined cycle of n requests
task automatic pipe(input int n, input logic [31:0] lo, input logic [31:0] span, input bit full = 0, input bit gaps = 1);
  int want;
  want = n_resp + n;
  @(negedge PCLK);
  cyc_i = 1; cti_i = 3'b001 + 3'($urandom % 7);
  for (int k = 0; k < n; k++) begin : b_req
    req_t r;
    r = mk($urandom, lo + 32'($urandom % span) * 4, full);
    drive(r); stb_i = 1;
    #1; while (stall_o) begin @(negedge PCLK); #1; end
    pend.push_back(r);
    @(negedge PCLK);
    stb_i = 0; we_i = $urandom; adr_i = $urandom; dat_i = $urandom; sel_i = $urandom;
    if (gaps) repeat ($urandom % 2) @(negedge PCLK);
  end
  wait_done(want);
  cyc_i = 0; cti_i = $urandom;
endtask
// a classic cycle: each strobe held until its acknowledge
task automatic classic(input int n, input logic [31:0] lo, input logic [31:0] span);
  int want;
  @(negedge PCLK);
  cyc_i = 1; cti_i = 3'b000;
  for (int k = 0; k < n; k++) begin : b_req
    req_t r;
    r = mk($urandom, lo + 32'($urandom % span) * 4, 0);
    want = n_resp + 1;
    drive(r); stb_i = 1;
    pend.push_back(r);
    @(negedge PCLK);
    while (n_resp < want) @(negedge PCLK);
    if (k % 2) begin stb_i = 0; @(negedge PCLK); end      // strobe dropped between
  end
  stb_i = 0;
  wait_done(n_resp);
  cyc_i = 0;
endtask
// one request alone: answered 1 clock after it is taken, 3 in the slow window
task automatic one(input bit we, input logic [31:0] a, input bit full = 1);
  int want, c;
  @(negedge PCLK);
  cyc_i = 1; cti_i = 3'b111;
  begin : b_one
    req_t r;
    r = mk(we, a, full);
    drive(r); stb_i = 1;
    #1; while (stall_o) begin @(negedge PCLK); #1; end
    pend.push_back(r);
  end
  want = n_resp + pend.size();
  @(negedge PCLK);
  stb_i = 0;
  c = 0;
  while (n_resp < want && c < 10) begin @(negedge PCLK); c++; end
  if (c != (a < 32'h400 && a[9] ? 3 : 1)) fail($sformatf("%h answered %0d clocks after it was taken", a, c));
  wait_done(want);
  cyc_i = 0;
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // the whole memory written, then read back, back to back
  for (int i = 0; i < 256; i++) one(1, 32'(i * 4));
  @(negedge PCLK);
  cyc_i = 1; cti_i = 3'b010;
  for (int i = 0; i < 256; i++) begin
    drive(mk(0, 32'(i * 4), 0)); stb_i = 1;
    #1; while (stall_o) begin @(negedge PCLK); #1; end
    pend.push_back(mk(0, 32'(i * 4), 0));
    @(negedge PCLK);
  end
  stb_i = 0;
  wait_done(n_resp + pend.size());
  cyc_i = 0;
  // all data bits both ways
  use_fix = 1;
  wfix = 32'hFFFF_FFFF; one(1, 32'h204); one(0, 32'h204);
  wfix = 32'h0;         one(1, 32'h204); one(0, 32'h204);
  use_fix = 0;
  // pipelined and classic cycles over the memory and the hole
  for (int k = 0; k < 12; k++) begin
    pipe(8, 32'h0, 512);
    pipe(6, 32'h1F0, 8, 0, 0);
    classic(4, 32'h0, 512);
  end
  rd_exp(A_IRQ_STATUS, 0);
  // ERR: the reserved region, every upper address bit
  one(1, 32'hFFFF_FFFC);
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
  if (!irq) fail("irq low with ERR set");
  wr(A_IRQ_STATUS, IRQ_ALL);                            // held by the core
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
  one(0, 32'h800);
  pipe(8, 32'h3E0, 600);
  classic(3, 32'h7F0, 8);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  cycles(2);
  if (irq) fail("irq with ERR masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
endtask
