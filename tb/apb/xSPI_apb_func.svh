// SPDX-License-Identifier: Apache-2.0
// xSPI-specific part of tb/xSPI_apb_tb.sv. The TB is the xSPI host: CS#,
// CK and one byte per CK edge on DQ, data captured on DQS edges. A page is
// programmed, read back and erased; STATUS follows WEL / WIP, the latency
// setting and the last error.
// Covered through the registers: CMD, DONE and ERR, each raised on its
// own, cleared with a write-1, raised while masked, and ERR left pending
// into reset.
logic [7:0] h_dq = 0;
logic       h_oe = 0;
initial begin ck = 0; csn = 1; end
always @* dq_i = dq_oe ? dq_o : h_oe ? h_dq : 8'hFF;
logic [7:0] x_tx [0:127];
logic [7:0] x_rx [0:127];
int         x_nrx = 0;
logic       dqs_q = 0;
always @(posedge PCLK) begin
  if (dqs_oe && dqs_o !== dqs_q) begin x_rx[x_nrx] = dq_o; x_nrx++; end
  dqs_q = dqs_o;
end
task automatic x_edge(input bit drive, input logic [7:0] b);
  h_oe = drive; if (drive) h_dq = b;
  @(negedge PCLK);
  ck = !ck;
  cycles(2);
endtask
// nd driven bytes from x_tx, then nr edges with DQ released
task automatic x_frame(input int nd, input int nr);
  x_nrx = 0;
  csn = 0; cycles(2);
  for (int i = 0; i < nd; i++) x_edge(1, x_tx[i]);
  for (int i = 0; i < nr; i++) x_edge(0, 0);
  h_oe = 0; cycles(2);
  csn = 1; cycles(3);
endtask
task automatic x_hdr(input logic [7:0] c, input logic [31:0] a = 0);
  x_tx[0] = c; x_tx[1] = ~c;
  x_tx[2] = a[31:24]; x_tx[3] = a[23:16]; x_tx[4] = a[15:8]; x_tx[5] = a[7:0];
endtask
task automatic x_cmd(input logic [7:0] c); x_hdr(c); x_frame(2, 0); endtask
// read n bytes at latency 8 and compare with e(k) = b0 + k * step
task automatic x_read(input logic [7:0] c, input logic [31:0] a, input int n,
                      input logic [7:0] b0, input logic [7:0] step);
  x_hdr(c, a); x_frame(6, 16 + n);
  if (x_nrx != n) fail($sformatf("xSPI read %h: %0d bytes, expected %0d", c, x_nrx, n));
  for (int k = 0; k < n && k < x_nrx; k++)
    if (x_rx[k] !== 8'(b0 + k * step)) fail($sformatf("xSPI read %h byte %0d = %h, expected %h", c, k, x_rx[k], 8'(b0 + k * step)));
endtask
task automatic x_status(input logic [1:0] sr_e, input logic [4:0] dm, input logic [2:0] ec);
  rd_exp(A_STATUS, {22'h0, ec, dm, sr_e});
endtask

task automatic irq_case(input int bitn);
  rd_exp(A_IRQ_STATUS, 32'(1) << bitn);
  if (!irq) fail("irq low with a status bit set");
  wr(A_IRQ_STATUS, 32'(1) << bitn);
  rd_exp(A_IRQ_STATUS, 0);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  x_status(2'b00, 5'd8, 3'd0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // CMD: WREN sets WEL
  x_cmd(8'h06);                 irq_case(IRQ_CMD);
  x_status(2'b10, 5'd8, 3'd0);
  // chip erase: busy, then DONE with WEL and WIP cleared
  x_cmd(8'h60);
  rd_exp(A_STATUS, {22'h0, 3'd0, 5'd8, 2'b11});
  poll(A_STATUS, 32'h3, 32'h0, 200);
  rd_exp(A_IRQ_STATUS, (32'(1) << IRQ_CMD) | (32'(1) << IRQ_DONE));
  wr(A_IRQ_STATUS, IRQ_ALL);
  x_read(8'hEE, 32'h40, 8, 8'hFF, 8'h00);
  // program a counting pattern and read it back
  x_cmd(8'h06);
  x_hdr(8'h12, 32'h40);
  for (int k = 0; k < 16; k++) x_tx[6 + k] = 8'(8'h10 + k);
  x_frame(22, 0);
  poll(A_STATUS, 32'h3, 32'h0, 200);
  wr(A_IRQ_STATUS, IRQ_ALL);
  x_read(8'hEE, 32'h40, 16, 8'h10, 8'h01);
  x_read(8'h9F, 32'h0, 2, 8'h4F, 8'h09);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // ERR: a bad extension, then a write without WEL
  x_hdr(8'h06); x_tx[1] = 8'h06; x_frame(2, 0);
  x_status(2'b00, 5'd8, 3'd1);  irq_case(IRQ_ERR);
  x_cmd(8'h60);
  x_status(2'b00, 5'd8, 3'd4);  irq_case(IRQ_ERR);
  // the latency setting
  x_cmd(8'h06); x_hdr(8'h81); x_tx[6] = 8'h1F; x_tx[7] = 8'h00; x_frame(8, 0);
  x_status(2'b00, 5'd31, 3'd4);
  x_cmd(8'h06); x_hdr(8'h81); x_tx[6] = 8'h17; x_tx[7] = 8'h00; x_frame(8, 0);
  x_status(2'b00, 5'd23, 3'd4);
  wr(A_IRQ_STATUS, IRQ_ALL);
  x_cmd(8'h66); x_cmd(8'h99);
  x_status(2'b00, 5'd8, 3'd4);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // masked: pending, irq low; then left pending into reset
  wr(A_IRQ_ENABLE, 0);
  x_cmd(8'h06); x_cmd(8'h60);                   // CMD, then DONE
  poll(A_STATUS, 32'h3, 32'h0, 200);
  if (irq) fail("irq with CMD and DONE masked");
  rd_exp(A_IRQ_STATUS, (32'(1) << IRQ_CMD) | (32'(1) << IRQ_DONE));
  wr(A_IRQ_STATUS, IRQ_ALL);
  x_cmd(8'h01);
  cycles(2);
  if (irq) fail("irq with ERR masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low after unmasking ERR");
endtask
