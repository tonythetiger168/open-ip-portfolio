// SPDX-License-Identifier: Apache-2.0
// SPMI-specific part of tb/SPMI_apb_tb.sv. The TB is the bus master: SCLK
// with each phase 4 PCLK clocks, SDATA open drain with a pullup.
// Checked: register writes arriving in RX with their address and
// acknowledged, register reads returning TX, another slave address or an
// unknown command ignored (no ACK, nothing driven), STATUS.busy.
// Covered through the registers: WRITE, RX_AVAIL, RX_OVF, RX read in the
// clock a write lands, every interrupt masked and left pending into reset.
pullup (sdata);
logic m_low = 0;
assign sdata = m_low ? 1'b0 : 1'bz;
initial sclk = 0;
localparam int H = 4;
task automatic s_ssc;
  m_low = 0; cycles(H);
  sclk = 1; cycles(H);
  m_low = 1; cycles(H);
  sclk = 0; cycles(H);
endtask
task automatic s_bit(input bit b, output bit s);
  m_low = !b; cycles(H);
  sclk = 1; cycles(H);
  s = sdata === 1'b1;
  sclk = 0;
endtask
task automatic s_byte(input logic [7:0] d);
  bit s;
  for (int i = 7; i >= 0; i--) s_bit(d[i], s);
endtask
task automatic s_rbyte(output logic [7:0] d);
  bit s;
  for (int i = 7; i >= 0; i--) begin s_bit(1, s); d[i] = s; end
endtask
// one more clock with SDATA released: the target lets go on its fall
task automatic s_end;
  bit s;
  s_bit(1, s);
  m_low = 0;
endtask
task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
task automatic reg_wr(input logic [3:0] sa, input logic [7:0] a, input logic [7:0] d, input bit chk = 1);
  bit ack;
  s_ssc();
  s_byte({sa, 4'h0});
  s_byte(a);
  if (chk && sa == 5) rd_exp(A_STATUS, 1);
  s_byte(d);
  s_bit(1, ack);
  if (ack == (sa == 5)) fail($sformatf("write ACK %0s", ack ? "missing" : "where none is due"));
  s_end();
  if (chk && sa == 5) begin
    rd_exp(A_STATUS, 0);
    rd_exp(A_FLAGS, 32'(1) << FLAG_RX_AVAIL);
    rd_exp(A_RX, {a, d});
  end
endtask
task automatic reg_rd(input logic [7:0] a, input logic [7:0] t);
  logic [7:0] r;
  wr(A_TX, t);
  s_ssc();
  s_byte({4'h5, 4'h1});
  s_byte(a);
  s_rbyte(r);
  if (r !== t) fail($sformatf("register read %h, expected %h", r, t));
  s_end();
  if (sdata !== 1'b1) fail("SDATA held after a read");
  rd_exp(A_STATUS, 0);
endtask

task automatic ip_func;
  logic [7:0] r;
  rd_exp(A_FLAGS, 0);
  rd_exp(A_STATUS, 0);
  rd_exp(A_RX, 0);                                       // empty
  wr(A_IRQ_ENABLE, IRQ_ALL);
  reg_wr(5, 8'hFF, 8'h00);
  irq_expect(IRQ_WRITE);
  irq_expect(IRQ_RX_AVAIL);
  reg_wr(5, 8'h00, 8'hFF);
  reg_rd(8'hFF, 8'h00); reg_rd(8'h00, 8'hFF);
  for (int k = 0; k < 8; k++) begin reg_wr(5, $urandom, $urandom); reg_rd($urandom, $urandom); end
  // another slave address, an unknown command: ignored
  reg_wr(4'h4, 8'h12, 8'h34); reg_wr(4'h7, 8'h12, 8'h34);   // each address bit flipped
  reg_wr(4'h1, 8'h12, 8'h34); reg_wr(4'hD, 8'h12, 8'h34);
  s_ssc(); s_byte({4'h5, 4'h7}); s_byte(8'h12); s_rbyte(r); s_end();
  if (r !== 8'hFF) fail("an unknown command drove SDATA");
  rd_exp(A_STATUS, 0);
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // RX read in the clock a write lands: RX full, the read started at
  // every offset from the data byte's last SCLK rise
  for (int off = 0; off < 6; off++) begin : b_race
    bit ack;
    reg_wr(5, 8'h01, 8'h02, 0);
    s_ssc(); s_byte(8'h50); s_byte(8'h03);
    fork
      s_byte(8'h04);
      begin repeat (8) @(posedge sclk); repeat (off) @(negedge PCLK); apb_now(0, A_RX, 0, 0); end
    join
    s_bit(1, ack); s_end();
    rd(A_FLAGS);
    while (rdv[FLAG_RX_AVAIL]) begin rd(A_RX); rd(A_FLAGS); end
  end
  wr(A_IRQ_STATUS, IRQ_ALL);
  // RX full: the second write is dropped
  reg_wr(5, 8'h21, 8'h22, 0); reg_wr(5, 8'h23, 8'h24, 0);
  irq_expect(IRQ_RX_OVF);
  rd_exp(A_RX, 16'h2122);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  reg_wr(5, 8'h31, 8'h32, 0); reg_wr(5, 8'h33, 8'h34, 0);
  cycles(2);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
