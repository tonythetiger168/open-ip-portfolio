// SPDX-License-Identifier: Apache-2.0
// I2C_Host-specific part of tb/I2C_Host_apb_tb.sv: the portfolio's I2C_top
// target (address 0x50) on the bus with a pull-up. Through the registers:
// a write of three bytes (the target receives them, RX.rx_ack = 0), a read
// of two bytes with ACK then NACK + STOP (RX.rx_data = the target's TX
// byte), another address (RX.rx_ack = 1), STATUS.bus_held, the DONE
// interrupt per command. Bus timing and repeated START are checked in
// tb/I2C_Host_tb.sv.
pullup (sda);
logic [7:0] t_tx = 8'h5C;
wire  [7:0] t_rx;
wire        t_rx_valid, t_busy, t_irq;
I2C_top #(.I2C_ADDR(7'h50)) tgt (.clk(PCLK), .rst_n(PRESETN), .sda, .scl, .tx_byte(t_tx), .rx_byte(t_rx),
                                 .rx_valid(t_rx_valid), .busy(t_busy), .irq(t_irq));
logic [7:0] got [$];
always @(posedge PCLK) if (PRESETN && t_rx_valid) got.push_back(t_rx);
localparam logic [31:0] C_V = 1, C_STA = 2, C_WR = 4, C_RD = 8, C_STO = 16, C_NACK = 32;
task automatic icmd(input logic [31:0] c, input logic [7:0] d);
  int k;
  if (c & C_WR) wr(A_TX_DATA, {24'd0, d});
  wr(A_CMD, C_V | c);
  k = 0;
  while (!irq && k < 5000) begin @(negedge PCLK); k++; end
  if (!irq) fail("no DONE interrupt");
  rd_exp(A_IRQ_STATUS, 1); wr(A_IRQ_STATUS, 1);
endtask
task automatic ip_func;
  logic [7:0] d [3];
  wr(A_PRESCALE, 4);
  wr(A_IRQ_ENABLE, 1);
  for (int i = 0; i < 3; i++) d[i] = $urandom;
  icmd(C_STA | C_WR, 8'hA0);
  rd(A_RX); if (rdv[8] !== 1'b0) fail("address 0x50 not acknowledged");
  rd(A_STATUS); if (rdv[1] !== 1'b1) fail("STATUS.bus_held low after START");
  icmd(C_WR, d[0]); icmd(C_WR, d[1]); icmd(C_WR | C_STO, d[2]);
  rd(A_STATUS); if (rdv[1] !== 1'b0) fail("STATUS.bus_held high after STOP");
  if (got.size() != 3) fail($sformatf("target received %0d bytes", got.size()));
  else for (int i = 0; i < 3; i++) begin
    logic [7:0] g;
    g = got[i];
    if (g !== d[i]) fail($sformatf("target byte %0d: %h, sent %h", i, g, d[i]));
  end
  icmd(C_STA | C_WR, 8'hA1);
  icmd(C_RD, 8'h00);
  rd(A_RX); if (rdv[7:0] !== 8'h5C) fail($sformatf("read %h", rdv[7:0]));
  icmd(C_RD | C_NACK | C_STO, 8'h00);
  rd(A_RX); if (rdv[7:0] !== 8'h5C) fail($sformatf("read %h", rdv[7:0]));
  icmd(C_STA | C_WR | C_STO, 8'hA2);                      // address 0x51
  rd(A_RX); if (rdv[8] !== 1'b1) fail("address 0x51 acknowledged");
  wr(A_IRQ_ENABLE, 0); wr(A_PRESCALE, 32'h63);
endtask
