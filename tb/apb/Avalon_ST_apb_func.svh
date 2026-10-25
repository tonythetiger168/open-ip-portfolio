// SPDX-License-Identifier: Apache-2.0
// Avalon_ST-specific part of tb/Avalon_ST_apb_tb.sv. The TB is the Avalon-ST source source on
// av_valid / av_data / av_eop, and checks av_ready.
// Covered through the registers: beats captured in order and read back from
// every entry (all data bits both ways), STATUS counting to full, a beat
// held off while full, LAST from av_eop, reset emptying the buffer,
// LAST masked and left pending into reset.
initial begin av_valid = 0; av_data = 0; av_eop = 0; end
logic [31:0] cap [0:15];
int n = 0;
bit took;
// one beat offered from a falling edge until accepted or for hold clocks
task automatic beat(input logic [31:0] d, input bit last, input int hold = 4);
  int t;
  av_valid = 1; av_data = d; av_eop = last;
  took = 0; t = 0;
  while (!took && t < hold) begin
    #1;
    if (av_ready) begin took = 1; @(posedge PCLK); end
    @(negedge PCLK); t++;
  end
  av_valid = 0; av_data = $urandom; av_eop = $urandom;
  if (took) begin cap[n % 16] = d; n++; end
endtask
task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
task automatic rd_all;
  for (int i = 0; i < 16; i++) begin
    if (i < n) case (i)
      0: rd_exp(A_D0, cap[0]);   1: rd_exp(A_D1, cap[1]);   2: rd_exp(A_D2, cap[2]);   3: rd_exp(A_D3, cap[3]);
      4: rd_exp(A_D4, cap[4]);   5: rd_exp(A_D5, cap[5]);   6: rd_exp(A_D6, cap[6]);   7: rd_exp(A_D7, cap[7]);
      8: rd_exp(A_D8, cap[8]);   9: rd_exp(A_D9, cap[9]);   10: rd_exp(A_D10, cap[10]); 11: rd_exp(A_D11, cap[11]);
      12: rd_exp(A_D12, cap[12]); 13: rd_exp(A_D13, cap[13]); 14: rd_exp(A_D14, cap[14]); default: rd_exp(A_D15, cap[15]);
    endcase
  end
endtask
task automatic fill(input logic [31:0] d, input bit rnd);
  while (n < 16) begin
    beat(rnd ? {$urandom} : d, 0);
    if (!took) fail("beat refused with room");
  end
  rd_exp(A_STATUS, 16);
  beat(32'h1234_5678, 1, 6);                               // held off: full
  if (took) begin fail("beat accepted while full"); n--; end
  if (irq) fail("LAST from a refused beat");
  rd_all();
endtask
task automatic reset_core;
  PRESETN = 0; cycles(2); PRESETN = 1; cycles(2);
  n = 0;
  rd_exp(A_STATUS, 0);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  rd_exp(A_STATUS, 0);
  wr(A_STATUS, 32'hFF);                                    // read-only: ignored
  wr(A_D0, 32'hFF); wr(A_D1, 32'hFF); wr(A_D2, 32'hFF); wr(A_D3, 32'hFF);
  wr(A_D4, 32'hFF); wr(A_D5, 32'hFF); wr(A_D6, 32'hFF); wr(A_D7, 32'hFF);
  wr(A_D8, 32'hFF); wr(A_D9, 32'hFF); wr(A_D10, 32'hFF); wr(A_D11, 32'hFF);
  wr(A_D12, 32'hFF); wr(A_D13, 32'hFF); wr(A_D14, 32'hFF); wr(A_D15, 32'hFF);
  rd_exp(A_STATUS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // beats with gaps and a frame end
  for (int k = 0; k < 6; k++) begin
    beat({$urandom}, k == 4);
    if (!took) fail("beat refused with room");
    if (k == 4) irq_expect(IRQ_LAST);
    cycles(k % 3);
    rd_exp(A_STATUS, n);
  end
  rd_exp(A_IRQ_STATUS, 0);
  fill(0, 1);
  // every data bit both ways
  reset_core();
  wr(A_IRQ_ENABLE, IRQ_ALL);
  fill(32'hFFFF_FFFF, 0);
  reset_core();
  fill(32'h0, 0);
  reset_core();
  // masked, left pending into reset
  beat(32'hA5A5_5A5A, 1);
  cycles(2);
  if (irq) fail("irq with LAST masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_LAST);
  rd_all();
endtask
