// SPDX-License-Identifier: Apache-2.0
// Shared IP part of tb/DDR4_AXI_apb_tb.sv and tb/LPDDR4_AXI_apb_tb.sv (define
// DDR_AXI_APB_LP 1 for LPDDR4). AXI4 bursts through the pass-through
// subordinate port against a byte model of the aliasing array, then the
// N_RD / N_WR / N_RMW / N_ERR counters and the ERR interrupt through the
// registers.
// - Model: DDR4 keeps 256 columns of 16 bits (bytes alias above 512); LPDDR4
//   two channels of 256 (above 1 KB, channel = address bit 9), and a write
//   to column 0xF0 is an MR7 write that leaves the array alone.
// - 300 random bursts: INCR (1..256 beats), FIXED, WRAP (2..16), AxSIZE 0..2,
//   random strobes, random IDs, addresses over the whole 32-bit space (rows
//   and the trace address get every bit), no 4 KB crossing.
// - SLVERR: AxSIZE 3..7 writes / reads, first with ERR masked (latched, irq low),
//   then enabled (irq high), W1C; ERR left pending into the final reset.
// - Counters (Verilator only, about 6M clocks): 65536 + more reads, halfword
//   writes and SLVERR reads, so every bit of the 16-bit counters toggles and
//   wraps; the counts are compared modulo 2^16.
`ifndef DDR_AXI_APB_LP
`define DDR_AXI_APB_LP 0
`endif
initial begin
  s_awid = 0; s_awaddr = 0; s_awlen = 0; s_awsize = 2; s_awburst = 1; s_awvalid = 0;
  s_wdata = 0; s_wstrb = 0; s_wlast = 0; s_wvalid = 0; s_bready = 0;
  s_arid = 0; s_araddr = 0; s_arlen = 0; s_arsize = 2; s_arburst = 1; s_arvalid = 0; s_rready = 0;
end
localparam int MB = `DDR_AXI_APB_LP ? 1024 : 512;            // distinct bytes
logic [7:0] mdl [0:MB - 1];
int n_rd = 0, n_wr = 0, n_rmw = 0, n_err = 0;
function automatic int midx(input logic [31:0] a);
  midx = `DDR_AXI_APB_LP ? int'(a[9:0]) : int'(a[8:0]);
endfunction
function automatic bit mr7(input logic [31:0] a);                // LPDDR4 MR7 column
  mr7 = `DDR_AXI_APB_LP && a[8:1] == 8'hF0;
endfunction
function automatic logic [31:0] baddr(input logic [31:0] a, input int sz, input int bt,
                                      input int len, input int n);
  logic [31:0] nb, al, wm, x;
  nb = 32'd1 << sz; al = a & ~(nb - 1);
  if (bt == 0 || n == 0) baddr = a;
  else if (bt == 1) baddr = al + 32'(n) * nb;
  else begin
    wm = 32'(len + 1) * nb - 1;
    x = al + 32'(n) * nb;
    baddr = (a & ~wm) | (x & wm);
  end
endfunction
function automatic logic [3:0] lanes(input logic [31:0] a, input int sz);
  logic [3:0] m;
  m = (sz == 0) ? 4'b0001 : (sz == 1) ? 4'b0011 : 4'b1111;
  lanes = m << (a[1:0] & ~2'((1 << sz) - 1));
endfunction
task automatic wburst(input logic [31:0] a, input int len, input int sz, input int bt,
                      output logic [1:0] resp);
  logic [3:0] id;
  id = $urandom;
  @(negedge PCLK);
  s_awid = id; s_awaddr = a; s_awlen = 8'(len); s_awsize = 3'(sz); s_awburst = 2'(bt); s_awvalid = 1;
  @(posedge PCLK); while (!s_awready) @(posedge PCLK);
  @(negedge PCLK); s_awvalid = 0;
  for (int n = 0; n <= len; n++) begin
    logic [31:0] ba, d;
    logic [3:0]  st;
    ba = baddr(a, sz, bt, len, n); d = $urandom;
    st = 4'($urandom) & lanes(ba, sz);
    if ($urandom % 3 == 0 || sz == 0) st = lanes(ba, sz);
    s_wdata = d; s_wstrb = st; s_wlast = (n == len); s_wvalid = 1;
    @(posedge PCLK); while (!s_wready) @(posedge PCLK);
    if (sz <= 2) begin
      for (int h = 0; h < 2; h++)
        if (st[2 * h +: 2] == 2'b01 || st[2 * h +: 2] == 2'b10) n_rmw++;
      for (int b = 0; b < 4; b++)
        if (st[b] && !mr7({ba[31:2], 2'(b)})) mdl[midx({ba[31:2], 2'(b)})] = d[8 * b +: 8];
    end
    @(negedge PCLK);
  end
  s_wvalid = 0; s_wlast = 0; s_bready = 1;
  @(posedge PCLK); while (!s_bvalid) @(posedge PCLK);
  resp = s_bresp;
  if (s_bid !== id) fail("BID mismatch");
  n_wr++; if (resp == 2'b10) n_err++;            // every burst counts, errors too
  @(negedge PCLK); s_bready = 0;
endtask
task automatic rburst(input logic [31:0] a, input int len, input int sz, input int bt,
                      input bit chk, output logic [1:0] resp);
  logic [3:0] id;
  id = $urandom;
  @(negedge PCLK);
  s_arid = id; s_araddr = a; s_arlen = 8'(len); s_arsize = 3'(sz); s_arburst = 2'(bt); s_arvalid = 1;
  @(posedge PCLK); while (!s_arready) @(posedge PCLK);
  @(negedge PCLK); s_arvalid = 0; s_rready = 1;
  for (int n = 0; n <= len; n++) begin
    logic [31:0] ba;
    logic [3:0]  ln;
    @(posedge PCLK); while (!s_rvalid) @(posedge PCLK);
    ba = baddr(a, sz, bt, len, n); ln = lanes(ba, sz);
    if (s_rid !== id) fail("RID mismatch");
    if (s_rlast !== (n == len)) fail($sformatf("RLAST on beat %0d of %0d", n, len + 1));
    resp = s_rresp;
    if (chk && sz <= 2) for (int b = 0; b < 4; b++)
      if (ln[b] && s_rdata[8 * b +: 8] !== mdl[midx({ba[31:2], 2'(b)})])
        fail($sformatf("read %h byte %0d: %h, expected %h", ba, b, s_rdata[8 * b +: 8], mdl[midx({ba[31:2], 2'(b)})]));
    @(negedge PCLK);
  end
  s_rready = 0;
  n_rd++; if (resp == 2'b10) n_err++;
endtask
task automatic rnd_burst(input bit wr_it);
  int sz, bt, len;
  logic [31:0] a;
  logic [1:0]  r;
  sz = $urandom % 3; bt = $urandom % 3;
  len = (bt == 2) ? (2 << ($urandom % 4)) - 1 : ($urandom % 4 == 0) ? $urandom % 256 : $urandom % 16;
  a = $urandom & ~((32'd1 << sz) - 1);
  if (bt == 1 && 32'(a[11:0]) + 32'((len + 1) << sz) > 32'd4096) a[11:0] = 12'h0;
  if (wr_it) wburst(a, len, sz, bt, r); else rburst(a, len, sz, bt, 1, r);
  if (r != 2'b00) fail($sformatf("%s burst response %0d", wr_it ? "write" : "read", r));
endtask
task automatic ip_func;
  logic [1:0] r;
  begin                                                  // full-strobe pass so every byte is known
    for (int i = 0; i < MB; i += 64) begin
      @(negedge PCLK);
      s_awid = 4'($urandom); s_awaddr = 32'(i); s_awlen = 15; s_awsize = 2; s_awburst = 1; s_awvalid = 1;
      @(posedge PCLK); while (!s_awready) @(posedge PCLK);
      @(negedge PCLK); s_awvalid = 0;
      for (int n = 0; n < 16; n++) begin
        logic [31:0] d;
        d = $urandom;
        s_wdata = d; s_wstrb = 4'hF; s_wlast = (n == 15); s_wvalid = 1;
        @(posedge PCLK); while (!s_wready) @(posedge PCLK);
        for (int b = 0; b < 4; b++) if (!mr7(32'(i + 4 * n + b))) mdl[midx(32'(i + 4 * n + b))] = d[8 * b +: 8];
        @(negedge PCLK);
      end
      s_wvalid = 0; s_wlast = 0; s_bready = 1;
      @(posedge PCLK); while (!s_bvalid) @(posedge PCLK);
      @(negedge PCLK); s_bready = 0; n_wr++;
    end
  end
  if (`DDR_AXI_APB_LP) begin                             // MR7 column: whatever the array held
    rburst(32'h1E0, 0, 1, 1, 0, r);
    mdl[midx(32'h1E0)] = s_rdata[7:0]; mdl[midx(32'h1E1)] = s_rdata[15:8];
    rburst(32'h3E0, 0, 1, 1, 0, r);
    mdl[midx(32'h3E0)] = s_rdata[7:0]; mdl[midx(32'h3E1)] = s_rdata[15:8];
  end
  for (int k = 0; k < 300; k++) rnd_burst($urandom % 2);
  rd_exp(A_N_RD, 32'(n_rd & 16'hFFFF)); rd_exp(A_N_WR, 32'(n_wr & 16'hFFFF));
  rd_exp(A_N_RMW, 32'(n_rmw & 16'hFFFF)); rd_exp(A_N_ERR, 0);
  rd_exp(A_FLAGS, 0);
  // AxSIZE 3: SLVERR; ERR masked first, then enabled
  wburst(32'h0, 0, 7, 1, r);
  if (r != 2'b10) fail("no SLVERR on an AxSIZE 7 write");
  rd_exp(A_IRQ_STATUS, 32'h1);
  if (irq !== 1'b0) fail("irq high with ERR masked");
  wr(A_IRQ_STATUS, 32'h1);
  wr(A_IRQ_ENABLE, 32'h1);
  rburst(32'h0, 1, 3, 1, 0, r);
  if (r != 2'b10) fail("no SLVERR on an AxSIZE 3 read");
  rd_exp(A_IRQ_STATUS, 32'h1);
  if (irq !== 1'b1) fail("irq low with ERR pending and enabled");
  wr(A_IRQ_STATUS, 32'h1); rd_exp(A_IRQ_STATUS, 0);
  if (irq !== 1'b0) fail("irq still high after W1C");
  rburst(32'h4, 0, 2, 1, 1, r);                         // the erroring write changed nothing
  rd_exp(A_N_ERR, 32'(n_err));
`ifdef VERILATOR
  for (int k = 0; k < 65540; k++) begin
    logic [31:0] a;
    a = {$urandom % 2 ? 22'h3FFFFF : 22'h0, 10'(4 * ($urandom % (MB / 4)))};
    rburst(a, 0, 2, 1, 1, r);
    wburst(a + 32'($urandom % 4), 0, 0, 1, r);           // one byte: a read-modify-write
    rburst(a, 0, 3 + $urandom % 5, 1, 0, r);                // AxSIZE 3..7: SLVERR
  end
  rd_exp(A_N_RD, 32'(n_rd & 16'hFFFF)); rd_exp(A_N_WR, 32'(n_wr & 16'hFFFF));
  rd_exp(A_N_RMW, 32'(n_rmw & 16'hFFFF)); rd_exp(A_N_ERR, 32'(n_err & 16'hFFFF));
`endif
  rburst(32'h0, 0, 3, 1, 0, r);                          // ERR left pending into the final reset
endtask
