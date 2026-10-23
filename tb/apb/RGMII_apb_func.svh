// SPDX-License-Identifier: Apache-2.0
// RGMII-specific part of tb/RGMII_apb_tb.sv. The TB runs tx_clk (its own
// clock, not a multiple of PCLK), checks the nibbles on txd / tx_ctl at
// both tx_clk edges, and drives rx_clk / rx_ctl / rxd as DDR nibble pairs.
// Covered through the registers: TX bytes sent in order (a write while
// the FIFO is full dropped), every RX ring entry read back, bytes with
// rx_ctl low in either half dropped, STATUS counting captures (and
// wrapping), READ, a partial write dropped with PSLVERR.
initial begin tx_clk = 0; rx_clk = 1; rx_ctl = 0; rxd = 0; end
bit tx_run = 1;
always #7 if (tx_run) tx_clk = ~tx_clk;
logic [7:0] tx_exp [$];
// tx_ctl and the high nibble follow the rising edge, the low nibble the
// falling edge: look just after each edge
bit tx_hi_ok = 0;
always @(posedge tx_clk) begin
  #1;
  tx_hi_ok = 0;
  if (PRESETN && tx_ctl) begin
    if (tx_exp.size() == 0) fail($sformatf("txd %h with nothing sent", txd));
    else if (txd !== tx_exp[0][7:4]) fail($sformatf("txd high nibble %h, expected %h", txd, tx_exp[0][7:4]));
    else tx_hi_ok = 1;
  end
end
always @(negedge tx_clk) begin
  #1;
  if (PRESETN && tx_hi_ok) begin
    if (!tx_ctl) fail("tx_ctl dropped mid-byte");
    if (txd !== tx_exp[0][3:0]) fail($sformatf("txd low nibble %h, expected %h", txd, tx_exp[0][3:0]));
    void'(tx_exp.pop_front());
  end
  tx_hi_ok = 0;
end
// one received byte: the high nibble before an rx_clk falling edge, the
// low nibble before the next rising edge, rx_ctl for each half
task automatic rx_byte(input logic [7:0] d, input bit c_hi, input bit c_lo);
  rxd = d[7:4]; rx_ctl = c_hi;
  cycles(2);
  rx_clk = 0; cycles(2);
  rxd = d[3:0]; rx_ctl = c_lo;
  cycles(2);
  rx_clk = 1; cycles(2);
  rxd = $urandom; rx_ctl = 0;
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
    if (k % 7 == 6) rx_byte(d, 0, 1);                   // not captured
    else if (k % 7 == 3) rx_byte(d, 1, 0);              // not captured
    else begin rx_byte(d, 1, 1); ring[n % 16] = d; n++; end
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
  for (int k = 0; k < 16; k++) rx_byte(8'hFF, 1, 1);
  for (int k = 0; k < 16; k++) rx_byte(8'h00, 1, 1);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  rd(A_RX3);
  cycles(2);
  if (irq) fail("irq with READ masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_READ);
endtask
