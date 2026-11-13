// SPDX-License-Identifier: Apache-2.0
// AXI_Async_Bridge-specific part of tb/AXI_Async_Bridge_apb_tb.sv. PCLK is
// s_clk; m_clk runs at 14 ns here, and m_rst_n follows PRESETN (both sides
// reset together). The core TB (tb/AXI_Async_Bridge_tb.sv) has the clock-
// ratio and full / empty phases.
// - 300 random beats per channel (AW, W, AR from the s side; B, R from the
//   m side) with random gaps and READY, against a scoreboard per channel;
//   then the s side stops taking B / R until both FIFOs are full.
// - RESP_ERR: error responses in the random traffic latch it (masked: irq
//   low); W1C; enabled, one SLVERR B raises irq; W1C; a DECERR R is left
//   pending into the final reset.
logic m_clk_r = 0;
always #7 m_clk_r = ~m_clk_r;
assign m_clk   = m_clk_r;
assign m_rst_n = PRESETN;

localparam int IDW = 8;
logic [IDW+44:0] q_aw [$], q_ar [$];
logic [36:0]     q_w [$];
logic [IDW+1:0]  q_b [$];
logic [IDW+34:0] q_r [$];
int rdy = 70, srdy = 70, gap = 20;            // srdy: READY rate of the s-side B / R consumers
bit force_err = 0;                       // B / R producers: 0 random resp, else this resp
logic [1:0] err_resp = 2'b10;

initial begin
  s_awid = 0; s_awaddr = 0; s_awlen = 0; s_awsize = 0; s_awburst = 0; s_awvalid = 0;
  s_wdata = 0; s_wstrb = 0; s_wlast = 0; s_wvalid = 0; s_bready = 0;
  s_arid = 0; s_araddr = 0; s_arlen = 0; s_arsize = 0; s_arburst = 0; s_arvalid = 0; s_rready = 0;
  m_awready = 0; m_wready = 0; m_arready = 0;
  m_bid = 0; m_bresp = 0; m_bvalid = 0; m_rid = 0; m_rdata = 0; m_rresp = 0; m_rlast = 0; m_rvalid = 0;
end

task automatic p_aw(input int n);
  logic [IDW+44:0] v;
  for (int k = 0; k < n; k++) begin
    @(negedge PCLK); s_awvalid = 0;
    while ($urandom_range(0, 99) < gap) @(negedge PCLK);
    v = {IDW'($urandom), 32'($urandom), 8'($urandom), 3'($urandom), 2'($urandom)};
    {s_awid, s_awaddr, s_awlen, s_awsize, s_awburst} = v; s_awvalid = 1;
    while (!s_awready) @(negedge PCLK);
    @(posedge PCLK); q_aw.push_back(v);
  end
  @(negedge PCLK); s_awvalid = 0;
endtask
task automatic p_w(input int n);
  logic [36:0] v;
  for (int k = 0; k < n; k++) begin
    @(negedge PCLK); s_wvalid = 0;
    while ($urandom_range(0, 99) < gap) @(negedge PCLK);
    v = {32'($urandom), 4'($urandom), 1'($urandom)};
    {s_wdata, s_wstrb, s_wlast} = v; s_wvalid = 1;
    while (!s_wready) @(negedge PCLK);
    @(posedge PCLK); q_w.push_back(v);
  end
  @(negedge PCLK); s_wvalid = 0;
endtask
task automatic p_ar(input int n);
  logic [IDW+44:0] v;
  for (int k = 0; k < n; k++) begin
    @(negedge PCLK); s_arvalid = 0;
    while ($urandom_range(0, 99) < gap) @(negedge PCLK);
    v = {IDW'($urandom), 32'($urandom), 8'($urandom), 3'($urandom), 2'($urandom)};
    {s_arid, s_araddr, s_arlen, s_arsize, s_arburst} = v; s_arvalid = 1;
    while (!s_arready) @(negedge PCLK);
    @(posedge PCLK); q_ar.push_back(v);
  end
  @(negedge PCLK); s_arvalid = 0;
endtask
task automatic p_b(input int n);
  logic [IDW+1:0] v;
  for (int k = 0; k < n; k++) begin
    @(negedge m_clk); m_bvalid = 0;
    while ($urandom_range(0, 99) < gap) @(negedge m_clk);
    v = {IDW'($urandom), force_err ? err_resp : 2'($urandom)};
    {m_bid, m_bresp} = v; m_bvalid = 1;
    while (!m_bready) @(negedge m_clk);
    @(posedge m_clk); q_b.push_back(v);
  end
  @(negedge m_clk); m_bvalid = 0;
endtask
task automatic p_r(input int n);
  logic [IDW+34:0] v;
  for (int k = 0; k < n; k++) begin
    @(negedge m_clk); m_rvalid = 0;
    while ($urandom_range(0, 99) < gap) @(negedge m_clk);
    v = {IDW'($urandom), 32'($urandom), force_err ? err_resp : 2'($urandom), 1'($urandom)};
    {m_rid, m_rdata, m_rresp, m_rlast} = v; m_rvalid = 1;
    while (!m_rready) @(negedge m_clk);
    @(posedge m_clk); q_r.push_back(v);
  end
  @(negedge m_clk); m_rvalid = 0;
endtask

// consumers: random READY, each beat must be the next one sent on its channel
initial forever begin
  @(negedge m_clk); m_awready = $urandom_range(0, 99) < rdy;
  if (m_awvalid && m_awready) begin
    @(posedge m_clk);
    if (q_aw.size() == 0 || {m_awid, m_awaddr, m_awlen, m_awsize, m_awburst} !== q_aw[0]) fail("AW beat out of order");
    if (q_aw.size() != 0) void'(q_aw.pop_front());
  end
end
initial forever begin
  @(negedge m_clk); m_wready = $urandom_range(0, 99) < rdy;
  if (m_wvalid && m_wready) begin
    @(posedge m_clk);
    if (q_w.size() == 0 || {m_wdata, m_wstrb, m_wlast} !== q_w[0]) fail("W beat out of order");
    if (q_w.size() != 0) void'(q_w.pop_front());
  end
end
initial forever begin
  @(negedge m_clk); m_arready = $urandom_range(0, 99) < rdy;
  if (m_arvalid && m_arready) begin
    @(posedge m_clk);
    if (q_ar.size() == 0 || {m_arid, m_araddr, m_arlen, m_arsize, m_arburst} !== q_ar[0]) fail("AR beat out of order");
    if (q_ar.size() != 0) void'(q_ar.pop_front());
  end
end
initial forever begin
  @(negedge PCLK); s_bready = $urandom_range(0, 99) < srdy;
  if (s_bvalid && s_bready) begin
    @(posedge PCLK);
    if (q_b.size() == 0 || {s_bid, s_bresp} !== q_b[0]) fail("B beat out of order");
    if (q_b.size() != 0) void'(q_b.pop_front());
  end
end
initial forever begin
  @(negedge PCLK); s_rready = $urandom_range(0, 99) < srdy;
  if (s_rvalid && s_rready) begin
    @(posedge PCLK);
    if (q_r.size() == 0 || {s_rid, s_rdata, s_rresp, s_rlast} !== q_r[0]) fail("R beat out of order");
    if (q_r.size() != 0) void'(q_r.pop_front());
  end
end

task automatic drain;
  int t;
  t = 0;
  while ((q_aw.size() || q_w.size() || q_ar.size() || q_b.size() || q_r.size()) && t < 20000) begin
    @(posedge PCLK); t++;
  end
  if (t >= 20000) fail("the bridge did not drain");
  cycles(4);
endtask

task automatic ip_func;
  fork p_aw(300); p_w(300); p_ar(300); p_b(300); p_r(300); join
  drain();
  // the s side stops taking B / R: both FIFOs fill and M_BREADY / M_RREADY drop
  srdy = 0;
  fork
    p_b(12); p_r(12);
    begin cycles(300); srdy = 70; end
  join
  drain();
  rd_exp(A_FLAGS, 0);
  // the random responses included SLVERR / DECERR: RESP_ERR latched, masked
  rd_exp(A_IRQ_STATUS, 32'h1);
  if (irq !== 1'b0) fail("irq high with RESP_ERR masked");
  wr(A_IRQ_STATUS, 32'h1); rd_exp(A_IRQ_STATUS, 0);
  wr(A_IRQ_ENABLE, 32'h1);
  // OKAY responses only: nothing latched
  force_err = 1; err_resp = 2'b00;
  fork p_b(4); p_r(4); join
  drain();
  rd_exp(A_IRQ_STATUS, 0);
  if (irq !== 1'b0) fail("irq high after OKAY responses");
  // one SLVERR B: irq
  err_resp = 2'b10;
  p_b(1); drain();
  rd_exp(A_IRQ_STATUS, 32'h1);
  if (irq !== 1'b1) fail("irq low with RESP_ERR pending and enabled");
  wr(A_IRQ_STATUS, 32'h1); rd_exp(A_IRQ_STATUS, 0);
  if (irq !== 1'b0) fail("irq still high after W1C");
  // a DECERR R left pending into the final reset
  err_resp = 2'b11;
  p_r(1); drain();
  rd_exp(A_IRQ_STATUS, 32'h1);
  force_err = 0;
endtask
