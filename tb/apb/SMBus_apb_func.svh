// SPDX-License-Identifier: Apache-2.0
// SMBus-specific part of tb/SMBus_apb_tb.sv. The TB is the SMBus host on
// a wired-AND bus with the target's open-drain outputs (waiting out clock
// stretching): PMBus writes and reads with PEC, checked against the
// registers (VOUT, CTRL from the host's writes; READ_VOUT from TELEMETRY;
// STATUS_BYTE from FAULT), SMBALERT# and the Alert Response Address.
// Covered through the registers: CML, UPD and TO, each raised on its own,
// cleared with a write-1, masked, and left pending into reset.
logic scl_m = 1, sda_m = 1;
always @* begin scl = scl_m & scl_o; sda = sda_m & sda_o; end
localparam int QQ = 30;
function automatic logic [7:0] crc8(input logic [7:0] c, input logic [7:0] b);
  logic [7:0] x;
  x = c ^ b;
  for (int k = 0; k < 8; k++) x = x[7] ? ((x << 1) ^ 8'h07) : (x << 1);
  return x;
endfunction
task automatic q(input int n = 1); repeat (n * QQ) @(negedge PCLK); endtask
task automatic s_high(); scl_m = 1; @(negedge PCLK); while (scl !== 1'b1) @(negedge PCLK); endtask
task automatic s_start(); sda_m = 1; s_high(); q(); sda_m = 0; q(); scl_m = 0; q(); endtask
task automatic s_rstart(); sda_m = 1; q(); s_high(); q(); sda_m = 0; q(); scl_m = 0; q(); endtask
task automatic s_stop(); sda_m = 0; q(); s_high(); q(); sda_m = 1; q(2); endtask
task automatic s_bit(input bit b, output bit r);
  sda_m = b; q(); s_high(); q(); r = sda; q(); scl_m = 0; q();
endtask
task automatic s_wbyte(input logic [7:0] v, input bit exp_ack);
  bit r;
  for (int i = 7; i >= 0; i--) s_bit(v[i], r);
  s_bit(1, r);
  if (r !== !exp_ack) fail($sformatf("SMBus byte %h: ACK %b, expected %b", v, !r, exp_ack));
endtask
task automatic s_rbyte(output logic [7:0] v, input bit ack);
  bit r;
  for (int i = 7; i >= 0; i--) begin s_bit(1, r); v[i] = r; end
  s_bit(!ack, r);
endtask
// write cmd with n data bytes and a PEC (good unless bad_pec)
task automatic s_write(input logic [7:0] c, input int n, input logic [15:0] d, input bit bad_pec = 0,
                       input bit exp_ok = 1);
  logic [7:0] crc;
  s_start();
  s_wbyte(8'hB4, 1); s_wbyte(c, exp_ok);
  crc = crc8(crc8(0, 8'hB4), c);
  for (int i = 0; i < n; i++) begin s_wbyte(d[8*i +: 8], exp_ok); crc = crc8(crc, d[8*i +: 8]); end
  if (exp_ok) s_wbyte(bad_pec ? ~crc : crc, !bad_pec);
  s_stop();
  cycles(4);
endtask
// read cmd: n data bytes and the PEC, compared with e
task automatic s_read(input logic [7:0] c, input int n, input logic [15:0] e);
  logic [7:0] crc, v;
  s_start();
  s_wbyte(8'hB4, 1); s_wbyte(c, 1);
  s_rstart();
  s_wbyte(8'hB5, 1);
  crc = crc8(crc8(crc8(0, 8'hB4), c), 8'hB5);
  for (int i = 0; i < n; i++) begin
    s_rbyte(v, 1);
    if (v !== e[8*i +: 8]) fail($sformatf("PMBus read %h byte %0d = %h, expected %h", c, i, v, e[8*i +: 8]));
    crc = crc8(crc, v);
  end
  s_rbyte(v, 0);
  if (v !== crc) fail($sformatf("PMBus read %h: PEC %h, expected %h", c, v, crc));
  s_stop();
  cycles(4);
endtask
task automatic s_ara(input bit exp_ack);
  logic [7:0] v;
  s_start();
  s_wbyte(8'h19, exp_ack);
  if (exp_ack) begin
    s_rbyte(v, 0);
    if (v !== 8'hB4) fail($sformatf("ARA returned %h", v));
  end
  s_stop();
  cycles(4);
endtask
task automatic irq_case(input int bitn);
  rd_exp(A_IRQ_STATUS, 32'(1) << bitn);
  if (!irq) fail("irq low with a status bit set");
  wr(A_IRQ_STATUS, 32'(1) << bitn);
  rd_exp(A_IRQ_STATUS, 0);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rd_exp(A_CTRL, 32'h1E80);
  // host writes reach VOUT / CTRL, every bit both ways
  s_write(8'h21, 2, 16'hFFFF); rd_exp(A_VOUT, 32'hFFFF); irq_case(IRQ_UPD);
  s_write(8'h21, 2, 16'h0000); rd_exp(A_VOUT, 32'h0000);
  s_write(8'h21, 2, 16'hA55A); rd_exp(A_VOUT, 32'hA55A);
  s_write(8'h01, 1, 16'h00FF); s_write(8'h02, 1, 16'h00FF); rd_exp(A_CTRL, 32'hFFFF);
  s_write(8'h01, 1, 16'h0000); s_write(8'h02, 1, 16'h0000); rd_exp(A_CTRL, 32'h0000);
  s_write(8'h01, 1, 16'h0080); s_write(8'h02, 1, 16'h001E); rd_exp(A_CTRL, 32'h1E80);
  irq_case(IRQ_UPD);
  // TELEMETRY is what READ_VOUT returns
  wr(A_TELEMETRY, 32'hFFFF); s_read(8'h8B, 2, 16'hFFFF);
  wr(A_TELEMETRY, 32'h0000); s_read(8'h8B, 2, 16'h0000);
  wr(A_TELEMETRY, 32'h3C5A); s_read(8'h8B, 2, 16'h3C5A);
  s_read(8'h21, 2, 16'hA55A);
  rd_exp(A_IRQ_STATUS, 0);
  // a bad PEC: CML, SMBALERT#, cleared by ARA
  s_write(8'h21, 2, 16'h1234, 1);
  irq_case(IRQ_CML);
  if (smbalert_n !== 0) fail("SMBALERT# high after a fault");
  s_ara(1);
  if (smbalert_n !== 1) fail("SMBALERT# low after the ARA");
  s_read(8'h7E, 1, 16'h0020);
  s_write(8'h03, 0, 0);
  s_read(8'h7E, 1, 16'h0000);
  // FAULT: VOUT_OV latched in STATUS_BYTE, SMBALERT#
  wr(A_FAULT, 1);
  cycles(2);
  if (smbalert_n !== 0) fail("SMBALERT# high after VOUT_OV");
  s_read(8'h78, 1, 16'h0020);
  s_write(8'h03, 0, 0);
  if (smbalert_n !== 1) fail("SMBALERT# low after CLEAR_FAULTS");
  rd_exp(A_IRQ_STATUS, 0);
  // bus timeout
  s_start(); s_wbyte(8'hB4, 1);
  repeat (3100) @(negedge PCLK);
  rd_exp(A_IRQ_STATUS, (32'(1) << IRQ_TO) | (32'(1) << IRQ_CML));   // STATUS_CML[1] too
  wr(A_IRQ_STATUS, 32'(1) << IRQ_TO);
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_CML);
  wr(A_IRQ_STATUS, IRQ_ALL);
  s_high(); q();
  s_write(8'h03, 0, 0);
  // masked, then left pending into reset
  wr(A_IRQ_ENABLE, 0);
  s_write(8'h21, 2, 16'h0101);
  if (irq) fail("irq with UPD masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_UPD);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low after unmasking UPD");
endtask
