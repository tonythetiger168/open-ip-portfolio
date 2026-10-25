// SPDX-License-Identifier: Apache-2.0
// GMII-specific part of tb/GMII_apb_tb.sv. The TB runs tx_clk (its own
// clock, not a multiple of PCLK), checks the bytes on txd / tx_en, and
// drives rx_clk / rx_dv / rxd.
// Covered through the registers: TX bytes sent in order (a write while
// the FIFO is full dropped), every RX ring entry read back, STATUS
// counting captures (and wrapping), READ, a partial write dropped with
// PSLVERR.
initial begin tx_clk = 0; rx_clk = 0; rx_dv = 0; rxd = 0; rx_er = 0; end
bit tx_run = 1;
always #7 if (tx_run) tx_clk = ~tx_clk;
logic [7:0] tx_exp [$];
// txd and tx_en change together on tx_clk: look just after the edge
always @(posedge tx_clk) begin
  #1;
  if (PRESETN && tx_en) begin
  if (tx_exp.size() == 0) fail($sformatf("txd %h with nothing sent", txd));
  else if (txd !== tx_exp[0]) fail($sformatf("txd %h, expected %h", txd, tx_exp[0]));
  if (tx_exp.size() != 0) void'(tx_exp.pop_front());
  end
end
// one received byte: rxd / rx_dv set, then an rx_clk rising edge
task automatic rx_byte(input logic [7:0] d, input bit dv);
  rxd = d; rx_dv = dv; rx_er = $urandom;
  cycles(2);
  rx_clk = 1; cycles(2);
  rx_clk = 0; rxd = $urandom; rx_dv = $urandom; cycles(1);
  rx_dv = 0;
endtask
task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask

task automatic ip_func;
  logic [7:0] ring [0:15];
  int n;
  rd_exp(A_FLAGS, 0);
  rd_exp(A_TX, 0);                                       // write-only: reads 0
  wr(A_STATUS, 32'hFF);                                  // read-only: ignored
  wr(A_RX0, 32'hFF); wr(A_RX1, 32'hFF); wr(A_RX2, 32'hFF); wr(A_RX3, 32'hFF);
  wr(A_RX4, 32'hFF); wr(A_RX5, 32'hFF); wr(A_RX6, 32'hFF); wr(A_RX7, 32'hFF);
  wr(A_RX8, 32'hFF); wr(A_RX9, 32'hFF); wr(A_RX10, 32'hFF); wr(A_RX11, 32'hFF);
  wr(A_RX12, 32'hFF); wr(A_RX13, 32'hFF); wr(A_RX14, 32'hFF); wr(A_RX15, 32'hFF);
  apb(1, A_TX, 32'h12, 4'h2);                            // partial: dropped
  if (!rerr) fail("no PSLVERR on a partial write to TX");
  rd_exp(A_STATUS, 0);
  // reading before any capture: no READ
  rd(A_RX5);
  cycles(2);
  rd_exp(A_IRQ_STATUS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // TX: bytes in order
  for (int k = 0; k < 24; k++) begin : b_tx
    logic [7:0] d;
    d = k == 0 ? 8'hFF : k == 1 ? 8'h00 : 8'($urandom);
    tx_exp.push_back(d);
    wr(A_TX, d);
  end
  cycles(40);
  if (tx_exp.size() != 0) fail("TX bytes not sent");
  // TX full: tx_clk stopped, 8 bytes fill the FIFO, the 9th is dropped
  tx_run = 0;
  cycles(10);
  for (int k = 0; k < 8; k++) begin tx_exp.push_back(8'(k * 37)); wr(A_TX, k * 37); end
  wr(A_TX, 8'hEE);                                      // dropped
  tx_run = 1;
  cycles(60);
  if (tx_exp.size() != 0) fail("TX bytes not sent after the FIFO was full");
  // RX: 40 bytes (the count wraps), with frames of rx_dv low between
  n = 0;
  for (int k = 0; k < 40; k++) begin : b_rx
    logic [7:0] d;
    d = k == 0 ? 8'hFF : k == 1 ? 8'h00 : 8'($urandom);
    if (k % 7 == 6) rx_byte(d, 0);                      // not captured
    else begin rx_byte(d, 1); ring[n % 16] = d; n++; end
    if (k % 5 == 4 || k == 39) begin
      cycles(2);
      rd_exp(A_STATUS, n % 32);
    end
  end
  for (int i = 0; i < 16; i++) begin
    case (i)
      0: rd_exp(A_RX0, ring[0]);   1: rd_exp(A_RX1, ring[1]);   2: rd_exp(A_RX2, ring[2]);   3: rd_exp(A_RX3, ring[3]);
      4: rd_exp(A_RX4, ring[4]);   5: rd_exp(A_RX5, ring[5]);   6: rd_exp(A_RX6, ring[6]);   7: rd_exp(A_RX7, ring[7]);
      8: rd_exp(A_RX8, ring[8]);   9: rd_exp(A_RX9, ring[9]);   10: rd_exp(A_RX10, ring[10]); 11: rd_exp(A_RX11, ring[11]);
      12: rd_exp(A_RX12, ring[12]); 13: rd_exp(A_RX13, ring[13]); 14: rd_exp(A_RX14, ring[14]); default: rd_exp(A_RX15, ring[15]);
    endcase
  end
  irq_expect(IRQ_READ);
  // all ring bits both ways
  for (int k = 0; k < 16; k++) rx_byte(8'hFF, 1);
  for (int k = 0; k < 16; k++) rx_byte(8'h00, 1);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  rd(A_RX3);
  cycles(2);
  if (irq) fail("irq with READ masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_READ);
endtask
