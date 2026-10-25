// SPDX-License-Identifier: Apache-2.0
// ATB-specific part of tb/ATB_apb_tb.sv. The TB is the ATB master source on
// atvalid / atdata / atid / atlast and afvalid, and checks atready / afready.
// Covered through the registers: beats captured in order and read back from
// every entry (all data bits both ways), STATUS counting to full, a beat
// held off while full, LAST from atlast, the ATID of the last frame end in STATUS (all bits both ways), a flush request with a new ATID emptying the buffer and stalling atready for that clock, one with the current ATID changing nothing, reset emptying the buffer,
// LAST masked and left pending into reset.
initial begin atvalid = 0; atdata = 0; atlast = 0; atid = 0; afvalid = 0; end
logic [31:0] cap [0:15];
int n = 0;
bit took;
// one beat offered from a falling edge until accepted or for hold clocks
task automatic beat(input logic [31:0] d, input bit last, input int hold = 4);
  int t;
  atvalid = 1; atdata = d; atlast = last;
  atid = b_id;
  took = 0; t = 0;
  while (!took && t < hold) begin
    #1;
    if (atready) begin took = 1; @(posedge PCLK); end
    @(negedge PCLK); t++;
  end
  atvalid = 0; atdata = $urandom; atlast = $urandom;
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
  rd_exp(A_STATUS, 32'(lid) << 5 | 16);
  beat(32'h1234_5678, 1, 6);                               // held off: full
  if (took) begin fail("beat accepted while full"); n--; end
  if (irq) fail("LAST from a refused beat");
  rd_all();
endtask
task automatic reset_core;
  PRESETN = 0; cycles(2); PRESETN = 1; cycles(2);
  n = 0; cur = 0; lid = 0;
  rd_exp(A_STATUS, 0);
endtask
// ATB: the ID on beats, the current ID, the ID of the last frame end
logic [6:0] b_id = 0;
logic [6:0] cur = 0, lid = 0;
always @(posedge PCLK) if (PRESETN) begin
  if (afready !== 1'b1) fail("afready low");
  if (atvalid && atready && atlast) lid <= atid;
end
// a flush request for one clock, a beat offered alongside
task automatic flush(input logic [6:0] id);
  afvalid = 1; atid = id; atvalid = 1; atdata = $urandom; atlast = 1;
  #1;
  if (!afready) fail("afready low on a flush");
  if (atready !== (id == cur && n < 16)) fail($sformatf("atready %b on a flush to %h (current %h)", atready, id, cur));
  if (atready) begin cap[n % 16] = atdata; n++; lid = id; end
  @(posedge PCLK);
  @(negedge PCLK);
  afvalid = 0; atvalid = 0; atid = $urandom;
  if (id != cur) begin n = 0; cur = id; end
  cycles(1);
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd_exp(A_STATUS, 32'(lid) << 5 | n);
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
    rd_exp(A_STATUS, 32'(lid) << 5 | n);
  end
  rd_exp(A_IRQ_STATUS, 0);
  // flushes: the current ID (a beat goes through), new IDs (bits both ways)
  flush(0);
  flush(7'h7F);
  b_id = 7'h7F; beat({$urandom}, 1); irq_expect(IRQ_LAST);
  rd_exp(A_STATUS, 32'(lid) << 5 | n);
  flush(7'h00);
  b_id = 7'h00; beat({$urandom}, 1); irq_expect(IRQ_LAST);
  flush(7'h2A);
  b_id = 7'h55; beat({$urandom}, 1); irq_expect(IRQ_LAST);   // an ID other than the current one
  rd_exp(A_STATUS, 32'(lid) << 5 | n);
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
