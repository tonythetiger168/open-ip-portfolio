// SPDX-License-Identifier: Apache-2.0
// TileLink__TL_UL_TL_C_-specific part of tb/TileLink__TL_UL_TL_C__apb_tb.sv.
// The TB is the TL-UL host: requests on A (held until a_ready, back to
// back or with gaps) while d_ready is driven at random; every D beat is
// checked in order against a model of the memory: opcode, size, source,
// data, d_error for each illegal field, PutPartialData lanes.
// Covered through the registers: ERR (held by the core until reset: a
// write-1 does not clear it), masked, left pending into reset.
initial begin
  a_valid = 0; a_opcode = 0; a_param = 0; a_size = 0; a_source = 0; a_address = 0; a_mask = 0; a_data = 0;
  d_ready = 0;
end
logic [31:0] mdl [0:63];
logic [45:0] dexp [$];                                   // {opcode, size, source, error, data}
int  p_dr = 70;                                          // d_ready probability
always @(negedge PCLK) d_ready = $urandom % 100 < p_dr;
always @(posedge PCLK) if (PRESETN && d_valid && d_ready) begin : b_d
  logic [45:0] e;
  if (dexp.size() == 0) fail("a D beat with no request");
  else begin
    e = dexp.pop_front();
    if ({d_opcode, d_size, d_source, d_error, d_data} !== {2'b00, e[45], e[44:42], e[41:34], e[33], e[31:0]})
      fail($sformatf("D %0d/%0d/%h/%b/%h, expected %0d/%0d/%h/%b/%h", d_opcode, d_size, d_source, d_error, d_data,
                     e[45], e[44:42], e[41:34], e[33], e[31:0]));
  end
end
// one request; gap: idle clocks after it
task automatic tl(input logic [2:0] op, input logic [31:0] a, input logic [3:0] m, input logic [31:0] d,
                  input logic [2:0] sz = 2, input logic [2:0] pr = 0, input int gap = 0);
  bit err;
  logic [31:0] r;
  @(negedge PCLK);
  a_valid = 1; a_opcode = op; a_param = pr; a_size = sz; a_source = $urandom; a_address = a; a_mask = m; a_data = d;
  #1; while (!a_ready) begin @(negedge PCLK); #1; end
  err = !(op == 0 || op == 1 || op == 4) || sz != 2 || a[1:0] != 0 || a >= 32'h100 ||
        (op == 1 ? m == 0 : m != 4'hF) || pr != 0;
  r = op == 4 && !err ? mdl[a[7:2]] : 32'h0;
  if (!err && op != 4) for (int k = 0; k < 4; k++) if (m[k]) mdl[a[7:2]][8*k +: 8] = d[8*k +: 8];
  dexp.push_back({op == 4, sz, a_source, err, 1'b0, r});
  @(posedge PCLK);                                       // taken; the next request may follow at once
  #1;
  a_valid = 0;
  a_opcode = $urandom; a_param = $urandom; a_size = $urandom; a_source = $urandom;
  a_address = $urandom; a_mask = $urandom; a_data = $urandom;
  repeat (gap) @(negedge PCLK);
endtask
task automatic drain;
  int t;
  t = 0;
  while (dexp.size() != 0 && t < 50) begin @(negedge PCLK); t++; end
  if (dexp.size() != 0) fail("D beats missing");
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int i = 0; i < 64; i++) tl(0, 32'(i * 4), 4'hF, {$urandom});
  tl(0, 32'h40, 4'hF, 32'hFFFF_FFFF); tl(4, 32'h40, 4'hF, 0);
  tl(0, 32'h40, 4'hF, 32'h0);         tl(4, 32'h40, 4'hF, 0);
  for (int k = 0; k < 200; k++) begin : b_mix
    int c;
    logic [3:0] m;
    c = $urandom % 3;
    m = 4'($urandom % 15) + 4'd1;
    tl(c == 0 ? 3'd0 : c == 1 ? 3'd1 : 3'd4, 32'($urandom % 64) * 4, c == 1 ? m : 4'hF, {$urandom}, 2, 0, $urandom % 2);
  end
  p_dr = 100;
  for (int k = 0; k < 20; k++) tl(4, 32'($urandom % 64) * 4, 4'hF, 0);
  p_dr = 70;
  drain();
  rd_exp(A_IRQ_STATUS, 0);
  // d_error: opcode, size, alignment, range (every upper bit), mask, param
  tl(3'd2, 32'h0, 4'hF, 0);
  drain();
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
  if (!irq) fail("irq low with ERR set");
  wr(A_IRQ_STATUS, IRQ_ALL);                            // held by the core
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
  for (int op = 0; op < 8; op++) tl(3'(op), 32'h4, 4'hF, {$urandom});
  tl(3'd4, 32'h4, 4'hF, 0, 3'd7); tl(3'd0, 32'h4, 4'hF, 0, 3'd0);
  tl(3'd0, 32'h6, 4'hF, 0); tl(3'd4, 32'h5, 4'hF, 0);
  tl(3'd0, 32'hFFFF_FFFC, 4'hF, 0); tl(3'd4, 32'h100, 4'hF, 0);
  tl(3'd1, 32'h8, 4'h0, 0); tl(3'd0, 32'h8, 4'h7, 0); tl(3'd4, 32'h8, 4'h1, 0);
  tl(3'd4, 32'h8, 4'hF, 0, 2, 3'd7);
  tl(3'd4, 32'h8, 4'hF, 0);
  drain();
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  cycles(2);
  if (irq) fail("irq with ERR masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
endtask
