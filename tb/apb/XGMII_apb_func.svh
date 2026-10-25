// SPDX-License-Identifier: Apache-2.0
// XGMII-specific part of tb/XGMII_apb_tb.sv. The TB runs tx_clk (its own
// clock, not a multiple of PCLK), checks the columns on txd / txc, and
// drives rx_clk / rxc / rxd.
// Covered through the registers: TX bytes packed into columns in order,
// partial columns of 1, 2 and 3 bytes pushed by EOF, an EOF with nothing
// held, a byte and an EOF dropped while the FIFO is full, every RX ring
// entry read back with control lanes anywhere in a column skipped, STATUS
// counting captures (and wrapping), READ, a partial write dropped with
// PSLVERR.
initial begin tx_clk = 0; rx_clk = 0; rxc = 4'hF; rxd = 32'h0707_0707; end
bit tx_run = 1;
always #7 if (tx_run) tx_clk = ~tx_clk;
logic [35:0] tx_exp [$];                                 // {txc, txd}
logic [7:0]  pk [$];                                     // bytes held in the packer
// txd / txc change on the tx_clk rising edge: look just after it
always @(posedge tx_clk) begin : b_txchk
  logic [35:0] e;
  #1;
  if (PRESETN && txc != 4'hF) begin
    if (tx_exp.size() == 0) fail($sformatf("column %h/%h with nothing sent", txc, txd));
    else begin
      e = tx_exp[0];
      if ({txc, txd} !== e) fail($sformatf("column %h/%h, expected %h/%h", txc, txd, e[35:32], e[31:0]));
      void'(tx_exp.pop_front());
    end
  end else if (PRESETN && txd !== 32'h0707_0707) fail($sformatf("idle column with txd %h", txd));
end
// the column the packer's bytes make
function automatic logic [35:0] col();
  logic [35:0] c;
  c = {4'b1110, 32'h0707_0707};
  for (int i = 0; i < pk.size(); i++) begin
    c[32 + i] = 0;
    c[8*i +: 8] = pk[i];
  end
  return c;
endfunction
task automatic tx_b(input logic [7:0] d);
  pk.push_back(d);
  if (pk.size() == 4) begin tx_exp.push_back(col()); pk.delete(); end
  wr(A_TX, d);
endtask
task automatic tx_eof;
  if (pk.size() != 0) begin tx_exp.push_back(col()); pk.delete(); end
  wr(A_EOF, $urandom);
endtask
// one received column: rxd / rxc set, then an rx_clk rising edge
logic [7:0] ring [0:15];
int n = 0;
task automatic rx_col(input logic [31:0] d, input logic [3:0] c);
  rxd = d; rxc = c;
  for (int i = 0; i < 4; i++) if (!c[i]) begin ring[n % 16] = d[8*i +: 8]; n++; end
  cycles(2);
  rx_clk = 1; cycles(2);
  rx_clk = 0; rxd = {$urandom}; rxc = $urandom; cycles(1);
endtask
task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
task automatic rd_ring;
  for (int i = 0; i < 16; i++) begin
    case (i)
      0: rd_exp(A_RX0, ring[0]);   1: rd_exp(A_RX1, ring[1]);   2: rd_exp(A_RX2, ring[2]);   3: rd_exp(A_RX3, ring[3]);
      4: rd_exp(A_RX4, ring[4]);   5: rd_exp(A_RX5, ring[5]);   6: rd_exp(A_RX6, ring[6]);   7: rd_exp(A_RX7, ring[7]);
      8: rd_exp(A_RX8, ring[8]);   9: rd_exp(A_RX9, ring[9]);   10: rd_exp(A_RX10, ring[10]); 11: rd_exp(A_RX11, ring[11]);
      12: rd_exp(A_RX12, ring[12]); 13: rd_exp(A_RX13, ring[13]); 14: rd_exp(A_RX14, ring[14]); default: rd_exp(A_RX15, ring[15]);
    endcase
  end
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  rd_exp(A_TX, 0); rd_exp(A_EOF, 0);                     // write-only: read 0
  wr(A_STATUS, 32'hFF);                                  // read-only: ignored
  wr(A_RX0, 32'hFF); wr(A_RX1, 32'hFF); wr(A_RX2, 32'hFF); wr(A_RX3, 32'hFF);
  wr(A_RX4, 32'hFF); wr(A_RX5, 32'hFF); wr(A_RX6, 32'hFF); wr(A_RX7, 32'hFF);
  wr(A_RX8, 32'hFF); wr(A_RX9, 32'hFF); wr(A_RX10, 32'hFF); wr(A_RX11, 32'hFF);
  wr(A_RX12, 32'hFF); wr(A_RX13, 32'hFF); wr(A_RX14, 32'hFF); wr(A_RX15, 32'hFF);
  apb(1, A_TX, 32'h12, 4'h2);                            // partial: dropped
  if (!rerr) fail("no PSLVERR on a partial write to TX");
  rd_exp(A_STATUS, 0);
  tx_eof();                                              // nothing held: nothing sent
  // reading before any capture: no READ
  rd(A_RX5);
  cycles(2);
  rd_exp(A_IRQ_STATUS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // TX: frames of every length mod 4, all byte values both ways
  for (int f = 0; f < 12; f++) begin
    for (int k = 0; k < 4 + f; k++) tx_b(f == 0 ? 8'hFF : f == 1 ? 8'h00 : 8'($urandom));
    tx_eof();
    cycles(10);
  end
  cycles(30);
  if (tx_exp.size() != 0) fail("TX columns not sent");
  // TX full: tx_clk stopped, 4 columns fill the FIFO, three bytes held,
  // the fourth dropped, an EOF dropped
  tx_run = 0;
  cycles(10);
  for (int k = 0; k < 19; k++) tx_b(8'(k * 37));
  wr(A_TX, 8'hEE);                                       // dropped: the packer keeps 3
  wr(A_EOF, 0);                                          // dropped
  tx_run = 1;
  cycles(60);
  tx_b(8'h5A);                                           // completes the held column
  cycles(30);
  if (tx_exp.size() != 0) fail("TX columns not sent after the FIFO was full");
  // RX: data and control lanes in every arrangement, the count wraps
  for (int k = 0; k < 40; k++) begin
    rx_col({$urandom}, 4'(k));
    if (k % 5 == 4) begin cycles(2); rd_exp(A_STATUS, n % 32); end
  end
  rd_ring();
  irq_expect(IRQ_READ);
  // all ring bits both ways
  for (int k = 0; k < 4; k++) rx_col(32'hFFFF_FFFF, 0);
  rd_ring();
  for (int k = 0; k < 4; k++) rx_col(32'h0, 0);
  rd_ring();
  wr(A_IRQ_STATUS, IRQ_ALL);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  rd(A_RX3);
  cycles(2);
  if (irq) fail("irq with READ masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_READ);
endtask
