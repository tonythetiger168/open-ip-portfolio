// SPDX-License-Identifier: Apache-2.0
// SPI_Host-specific part of tb/SPI_Host_apb_tb.sv: the portfolio's SPI_top
// target (mode 0) on chip select 0. Through the registers: a transaction of
// four frames with DIV 3 (the target receives the bytes sent, RX_DATA is
// the target's TX byte each time), STATUS.busy during a frame, the DONE
// interrupt per frame, CS released at the end. All four modes are checked
// in tb/SPI_Host_tb.sv.
logic       t_wen = 0;
logic [7:0] t_wdata = 0;
wire  [7:0] t_rx;
wire        t_irq, t_miso;
SPI_top tgt (.clk(PCLK), .rst_n(PRESETN), .sclk, .mosi, .miso(t_miso), .csn(csn[0]), .wen(t_wen),
             .waddr(4'd0), .wdata(t_wdata), .ren(1'b0), .raddr(4'd0), .rdata(t_rx), .irq(t_irq));
assign miso = (t_miso === 1'bz) ? 1'b0 : t_miso;
task automatic ip_func;
  wr(A_DIV, 3);
  wr(A_IRQ_ENABLE, 1);
  wr(A_CFG, 32'b0100);                                   // CS0, mode 0
  if (csn !== 2'b10) fail($sformatf("csn %b with CS = 01", csn));
  for (int i = 0; i < 4; i++) begin
    logic [7:0] d, r;
    int k;
    d = $urandom;
    r = (i == 0) ? 8'hFF : (i == 1) ? 8'h00 : (i == 2) ? 8'hA5 : 8'h5A;   // every RX bit both ways
    @(negedge PCLK); t_wen = 1; t_wdata = r; @(negedge PCLK); t_wen = 0;
    wr(A_TX_DATA, {24'd0, d});
    wr(A_CMD, 1);
    rd(A_STATUS); if (rdv[0] !== 1'b1) fail("STATUS.busy low during a frame");
    k = 0;
    while (!irq && k < 2000) begin @(negedge PCLK); k++; end
    if (!irq) fail("no DONE interrupt");
    rd_exp(A_IRQ_STATUS, 1); wr(A_IRQ_STATUS, 1);
    rd_exp(A_RX_DATA, {24'd0, r});
    cycles(3);
    if (t_rx !== d) fail($sformatf("target got %h, sent %h", t_rx, d));
  end
  // one more frame with DONE masked: latched, irq low, left pending into the final reset
  wr(A_IRQ_ENABLE, 0);
  wr(A_TX_DATA, 32'h3C); wr(A_CMD, 1);
  poll(A_IRQ_STATUS, 1, 1, 2000);
  if (irq !== 1'b0) fail("irq high with DONE masked");
  rd_exp(A_FLAGS, 0);
  wr(A_CFG, 0);
  if (csn !== 2'b11) fail("CS not released");
  wr(A_DIV, 9);
endtask
