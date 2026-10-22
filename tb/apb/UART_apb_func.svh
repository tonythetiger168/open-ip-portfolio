// SPDX-License-Identifier: Apache-2.0
// UART-specific part of tb/UART_apb_tb.sv: rxd follows txd (loopback) unless
// loop = 0, then the TB drives rxd itself. Bytes go out through TXDATA and
// come back on RXDATA; overflow on both streams, a framing error, every
// interrupt bit masked, enabled and cleared one by one.
bit   loop = 1;
logic drv  = 1;
assign rxd = loop ? txd : drv;
localparam int UBIT = 48;                   // clk per bit: 50 MHz / 1 MBd

task automatic u_frame(input logic [7:0] d, input logic stop);
  drv = 0; cycles(UBIT);
  for (int i = 0; i < 8; i++) begin drv = d[i]; cycles(UBIT); end
  drv = stop; cycles(UBIT);
  drv = 1;
endtask

localparam logic [31:0] AV = 32'h1 << FLAG_RXDATA_AVAIL;

task automatic echo(input logic [7:0] d);
  wr(A_TXDATA, d);
  rd_exp(A_TXDATA, {24'h0, d});
  poll(A_FLAGS, AV, AV, 3000);
  rd_exp(A_RXDATA, {24'h0, d});
  rd_exp(A_FLAGS, 0);
endtask

task automatic ip_func;
  logic [7:0] a, b, c;
  rd_exp(A_RXDATA, 0);                      // empty: reads the reset value, no pop
  // ---- phase A, all interrupts masked: set every IRQ_STATUS bit
  echo(8'hA5);
  cycles(UBIT);                             // TX finishes its stop bit
  a = $urandom; b = $urandom; c = $urandom;
  wr(A_TXDATA, a);                          // taken at once: core idle
  wr(A_TXDATA, b);                          // held: core busy
  rd_exp(A_FLAGS, 32'h1 << FLAG_TXDATA_FULL);
  wr(A_TXDATA, c);                          // dropped
  rd_exp(A_TXDATA, {24'h0, b});
  poll(A_FLAGS, AV, AV, 3000);
  rd_exp(A_RXDATA, {24'h0, a});
  poll(A_FLAGS, AV, AV, 3000);
  rd_exp(A_RXDATA, {24'h0, b});
  // pop RXDATA in the very clock the next byte is captured
  cycles(UBIT);
  wr(A_IRQ_STATUS, IRQ_ALL);
  a = $urandom; b = $urandom;
  wr(A_TXDATA, a);
  wr(A_TXDATA, b);
  poll(A_FLAGS, AV, AV, 3000);
  cycles(UBIT);
  while (!(dut.u_core.rstate == 2'd3 && dut.u_core.rsub == 4'd15 && dut.u_core.tick16 && dut.u_core.rxd_s))
    @(negedge PCLK);
  apb_now(0, A_RXDATA, 0, 0);               // access phase sees rx_valid
  if (rdv !== {24'h0, a}) fail("pop at capture: first byte");
  rd_exp(A_FLAGS, AV);
  rd_exp(A_RXDATA, {24'h0, b});
  rd_exp(A_IRQ_STATUS, (32'h1 << IRQ_CORE) | (32'h1 << IRQ_TXDATA_DONE) | (32'h1 << IRQ_RXDATA_AVAIL));
  cycles(UBIT);
  wr(A_TXDATA, 8'h00);                      // TX overflow again: one more TXDATA_OVF
  wr(A_TXDATA, 8'h00);
  wr(A_TXDATA, 8'h00);
  poll(A_FLAGS, AV, AV, 3000); rd(A_RXDATA);
  poll(A_FLAGS, AV, AV, 3000); rd(A_RXDATA);
  // RX overflow: two bytes arrive, none read
  cycles(UBIT);
  a = $urandom; b = $urandom;
  wr(A_TXDATA, a);
  wr(A_TXDATA, b);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_RXDATA_OVF, 32'h1 << IRQ_RXDATA_OVF, 6000);
  rd_exp(A_FLAGS, AV);
  rd_exp(A_RXDATA, {24'h0, a});             // the second byte was dropped
  rd_exp(A_FLAGS, 0);
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
  if (irq !== 0) fail("irq with all interrupts masked");
  // enable, check the pin, clear: one bit at a time
  for (int i = 0; i < 5; i++) begin
    wr(A_IRQ_ENABLE, 32'h1 << i);
    if (irq !== 1) fail($sformatf("irq bit %0d does not reach the pin", i));
    wr(A_IRQ_STATUS, 32'h1 << i);
    if (irq !== 0) fail($sformatf("irq bit %0d not cleared", i));
  end
  rd_exp(A_IRQ_STATUS, 0);
  // ---- phase B, all enabled: loopback of 00, FF and random bytes
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int i = 0; i < 40; i++) begin
    echo(i == 0 ? 8'h00 : i == 1 ? 8'hFF : 8'($urandom));
    if (irq !== 1) fail("irq after a received byte");
    wr(A_IRQ_STATUS, IRQ_ALL);
    if (irq !== 0) fail("irq after W1C");
  end
  // framing error from the line: CORE only, no data
  loop = 0;
  cycles(10);
  u_frame(8'h3C, 1'b0);
  cycles(2 * UBIT);
  rd_exp(A_IRQ_STATUS, 32'h1 << IRQ_CORE);
  rd_exp(A_FLAGS, 0);
  u_frame(8'hC3, 1'b1);                     // a good frame from the line
  cycles(UBIT);
  rd_exp(A_RXDATA, 32'hC3);
  loop = 1;
  // CORE stays pending into the final reset
endtask
