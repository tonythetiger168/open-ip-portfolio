// SPDX-License-Identifier: Apache-2.0
// QSPI_XIP-specific part of tb/QSPI_XIP_apb_tb.sv: the behavioural NOR flash
// of tb/spi_nor_model.svh on the pins. Through the registers and the
// pass-through AXI window: JEDEC ID by the command port (PC_DONE interrupt,
// STATUS.busy), XIP reads in quad and single mode checked against the
// flash array, XIP_CMDS / XIP_BEATS (consecutive bursts share one read
// command), write enable + page program + read status, AXI write SLVERR.
// Random bursts, WRAP / FIXED, narrow sizes, RREADY stalls and erase are in
// tb/QSPI_XIP_tb.sv.
pullup (io[0]); pullup (io[1]); pullup (io[2]); pullup (io[3]);
spi_nor_model flash (.sclk, .csn, .io);
initial begin
  s_awid = 0; s_awaddr = 0; s_awlen = 0; s_awsize = 2; s_awburst = 1; s_awvalid = 0;
  s_wdata = 0; s_wstrb = 4'hF; s_wlast = 0; s_wvalid = 0; s_bready = 0;
  s_arid = 0; s_araddr = 0; s_arlen = 0; s_arsize = 2; s_arburst = 1; s_arvalid = 0; s_rready = 0;
  for (int i = 0; i < 65536; i++) flash.mem[i] = $urandom;
end
function automatic logic [31:0] fword(input logic [31:0] a);
  logic [15:0] w;
  w = {a[15:2], 2'b00};
  fword = {flash.mem[w + 16'd3], flash.mem[w + 16'd2], flash.mem[w + 16'd1], flash.mem[w]};
endfunction
int nbeats = 0;
int unsigned apb_now_cyc = 0;
always @(posedge PCLK) apb_now_cyc++;
task automatic xip(input logic [31:0] a, input int len);
  logic [3:0] id;
  int t0;
  id = $urandom;
  @(negedge PCLK);
  s_arid = id; s_araddr = a; s_arlen = 8'(len); s_arsize = 2; s_arburst = 1; s_arvalid = 1;
  t0 = apb_now_cyc;
  @(posedge PCLK); while (!s_arready) @(posedge PCLK);
  @(negedge PCLK); s_arvalid = 0; s_rready = 1;
  for (int n = 0; n <= len; n++) begin
    @(posedge PCLK); while (!s_rvalid) @(posedge PCLK);
    if (s_rdata !== fword(a + 32'(4 * n))) fail($sformatf("XIP %h: %h, expected %h", a + 32'(4 * n), s_rdata, fword(a + 32'(4 * n))));
    if (s_rid !== id || s_rlast !== (n == len) || s_rresp !== 2'b00) fail("R channel ID / LAST / RESP");
    nbeats++;
  end
  $display("LAT apb QSPI_XIP R %0d", apb_now_cyc - t0);
  @(negedge PCLK); s_rready = 0;
endtask
task automatic fcmd(input logic [7:0] c, input bit ha, input logic [23:0] a, input int nwr,
                    input logic [31:0] wd, input int nrd);
  int k;
  wr(A_PC_ADDR, {8'd0, a}); wr(A_PC_WDATA, wd);
  wr(A_PC_CTRL, {18'd0, 3'(nrd), 3'(nwr), ha, c});
  wr(A_CMD, 1);
  k = 0;
  while (!irq && k < 20000) begin @(negedge PCLK); k++; end
  if (!irq) fail($sformatf("no PC_DONE for command %h", c));
  rd_exp(A_STATUS, 0);
  rd_exp(A_IRQ_STATUS, 1); wr(A_IRQ_STATUS, 1);
endtask
task automatic ip_func;
  logic [31:0] old, pd;
  wr(A_IRQ_ENABLE, 1);
  wr(A_CFG, 32'h101);                                   // QUAD, DIV 1
  wr(A_PC_CTRL, {18'd0, 3'd3, 3'd0, 1'b0, 8'h9F}); wr(A_CMD, 1);
  rd(A_STATUS); if (rdv[0] !== 1'b1) fail("STATUS.busy low after CMD.pc_start");
  poll(A_STATUS, 1, 0, 2000);
  rd_exp(A_PC_RDATA, 32'h0018_40EF);
  rd_exp(A_IRQ_STATUS, 1); wr(A_IRQ_STATUS, 1);
  xip(32'h0000_0400, 7); xip(32'h0000_0420, 3);         // one read command
  rd_exp(A_XIP_CMDS, 1);
  wr(A_CFG, 32'h002);                                   // single, DIV 2
  xip(32'h0000_8000, 15); xip(32'h0000_1234 & ~32'h3, 0);
  rd_exp(A_XIP_CMDS, 3);
  rd_exp(A_XIP_BEATS, 32'(nbeats));
  fcmd(8'h06, 0, 0, 0, 0, 0);
  fcmd(8'h05, 0, 0, 0, 0, 1);
  rd(A_PC_RDATA); if (rdv[1] !== 1'b1) fail("WEL low after write enable");
  old = fword(32'h0000_8010); pd = $urandom;
  fcmd(8'h02, 1, 24'h008010, 4, pd, 0);
  if (fword(32'h0000_8010) !== (old & pd)) fail("page program did not reach the array");
  xip(32'h0000_8010, 0);
  fcmd(8'h05, 0, 0, 0, 0, 1);
  rd(A_PC_RDATA); if (rdv[1] !== 1'b0) fail("WEL high after page program");
  // AXI write: SLVERR
  @(negedge PCLK); s_awvalid = 1;
  @(posedge PCLK); while (!s_awready) @(posedge PCLK);
  @(negedge PCLK); s_awvalid = 0; s_wvalid = 1; s_wlast = 1;
  @(posedge PCLK); while (!s_wready) @(posedge PCLK);
  @(negedge PCLK); s_wvalid = 0; s_wlast = 0; s_bready = 1;
  @(posedge PCLK); while (!s_bvalid) @(posedge PCLK);
  if (s_bresp !== 2'b10) fail("AXI write not SLVERR");
  @(negedge PCLK); s_bready = 0;
  if (flash.errors != 0) fail($sformatf("%0d flash model errors", flash.errors));
  wr(A_IRQ_ENABLE, 0); wr(A_CFG, 32'h101); wr(A_PC_CTRL, 0); wr(A_PC_ADDR, 0); wr(A_PC_WDATA, 0);
endtask
