// SPDX-License-Identifier: Apache-2.0
// D_PHY-specific part of tb/D_PHY_apb_tb.sv. The data lane is looped back
// to the receive lane through an injection mux, so the TB can also drive
// the receive lane itself.
// Checked: HS bursts of 0 to 12 bytes written through HS_TX at the lane
// rate and the bytes decoded back (in RX: the first one, the rest dropped
// as RX_OVF), the SoT and sync on the wires, LPDT of 0 to 5 bytes through
// LPDT with the command in RX_ESC, ULPS (STATUS.rx_ulps until
// CMD.esc_release), trigger reset, unknown escape commands, requests
// queued while busy; injected HS and LPDT bursts read through RX at the
// lane rate; injected grammar violations with CMD.irq_clear.
// Covered through the registers: HS_SENT, ESC_DONE, ERROR and the stream
// interrupts, masked, raising irq and cleared.
logic       inj = 0;
logic [1:0] i_lp = 2'b11;
logic       i_hs_p = 0, i_hs_n = 1, i_hs_en = 0;
always @* {r_lp_p, r_lp_n, r_hs_p, r_hs_n, r_hs_en} =
  inj ? {i_lp, i_hs_p, i_hs_n, i_hs_en} : {d_lp_p, d_lp_n, d_hs_p, d_hs_n, d_hs_en};

// decoded bytes and commands, seen at the core
logic [7:0] rxq [$];
logic [7:0] cmdq [$];
always @(posedge PCLK) begin
  if (dut.c_rx_data_valid) rxq.push_back(dut.c_rx_data);
  if (dut.c_rx_esc_valid) cmdq.push_back(dut.c_rx_esc_cmd);
end
logic [7:0] sent [$];
task automatic expect_rx;
  if (rxq.size() != sent.size()) fail($sformatf("%0d bytes decoded, %0d sent", rxq.size(), sent.size()));
  else foreach (sent[i]) if (rxq[i] !== sent[i]) fail($sformatf("byte %0d = %h, sent %h", i, rxq[i], sent[i]));
endtask
task automatic irq_wait(input int b);
  int t;
  t = 0;
  rd(A_IRQ_STATUS);
  while (!rdv[b] && t < 300) begin rd(A_IRQ_STATUS); t++; end
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
// RX after a burst: the first byte held, later ones dropped
task automatic rx_first(input int n);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_RX_OVF] !== (n > 1)) fail($sformatf("RX_OVF %b after %0d bytes", rdv[IRQ_RX_OVF], n));
  if (rdv[IRQ_ERROR]) fail("ERROR on a clean burst");
  if (n > 0) rd_exp(A_RX, sent[0]);
  rd(A_FLAGS);
  if (rdv[FLAG_RX_AVAIL]) fail("RX still holds a byte");
  wr(A_IRQ_STATUS, IRQ_ALL);
  rxq.delete();
endtask
task automatic hs_burst(input int n, input bit rnd = 1);
  int k;
  logic [7:0] b;
  sent.delete(); rxq.delete();
  wr(A_CMD, 1);
  no_idle = 1;
  k = 0;
  while (k < n) begin
    rd(A_FLAGS);
    if (!rdv[FLAG_HS_TX_FULL]) begin
      b = rnd ? 8'($urandom) : (k % 2 ? 8'hFF : 8'h00);
      wr(A_HS_TX, {$urandom, b} & 32'hFFFF_FFFF);
      sent.push_back(b); k++;
    end
  end
  no_idle = 0;
  irq_wait(IRQ_HS_SENT);
  cycles(3);
  expect_rx();
  rx_first(n);
endtask
task automatic esc(input logic [7:0] c);
  wr(A_ESC, c);
  wr(A_CMD, 2);
endtask
task automatic lpdt(input int n, input bit underrun = 0);
  int k;
  logic [7:0] b;
  sent.delete(); rxq.delete(); cmdq.delete();
  esc(8'h87);
  no_idle = 1;
  k = 0;
  while (k < n) begin
    rd(A_FLAGS);
    if (!rdv[FLAG_LPDT_FULL]) begin
      b = $urandom;
      wr(A_LPDT, {23'd0, k == n - 1 && !underrun, b});
      sent.push_back(b); k++;
    end
  end
  no_idle = 0;
  irq_wait(IRQ_ESC_DONE);
  cycles(3);
  expect_rx();
  if (cmdq.size() != 1 || cmdq[0] !== 8'h87) fail("LPDT command not decoded");
  rd_exp(A_RX_ESC, 8'h87);
  rx_first(n);
  cmdq.delete();
endtask

// empty RX and RX_ESC
task automatic drain;
  logic [31:0] f;
  rd(A_FLAGS);
  f = rdv;
  if (f[FLAG_RX_AVAIL]) rd(A_RX);
  if (f[FLAG_RX_ESC_AVAIL]) rd(A_RX_ESC);
endtask
// receive lane injection
task automatic sym(input logic [1:0] lp, input int n = 1);
  repeat (n) begin @(negedge PCLK); i_lp = lp; i_hs_en = 0; end
endtask
task automatic hsbit(input logic b, input int n_ = -1);
  @(negedge PCLK); i_hs_en = 1; i_hs_p = b; i_hs_n = (n_ < 0) ? !b : n_[0];
endtask
task automatic hsbyte(input logic [7:0] v); for (int i = 0; i < 8; i++) hsbit(v[i]); endtask
task automatic lpbyte(input logic [7:0] v); for (int i = 0; i < 8; i++) sym(v[i] ? 2'b10 : 2'b00); endtask
task automatic esc_entry; sym(2'b10); sym(2'b00); sym(2'b01); sym(2'b00); endtask
task automatic hs_entry; sym(2'b01); sym(2'b00); hsbit(0); endtask
task automatic inj_err;
  sym(2'b11, 2);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_ERROR]) fail("no ERROR for an injected violation");
  wr(A_CMD, 8);
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_ERROR]) fail("ERROR after CMD.irq_clear");
  drain();
  wr(A_IRQ_STATUS, IRQ_ALL);
  rxq.delete(); cmdq.delete();
endtask
// injected HS burst of n bytes, RX read at the lane rate alongside
logic [7:0] got [$];
logic [7:0] lastb, gotb;
bit         go, drv;
task automatic inj_hs_read(input int n);
  got.delete();
  sent.delete();
  for (int i = 0; i < n; i++) sent.push_back(8'($urandom));
  drv = 1;
  fork
    begin
      hs_entry(); hsbyte(8'hB8);
      for (int i = 0; i < n; i++) begin lastb = sent[i]; hsbyte(lastb); end
      hsbit(!lastb[7]); sym(2'b11, 3);
      drv = 0;
    end
    begin
      no_idle = 1;
      go = 1;
      while (go) begin
        rd(A_FLAGS);
        if (rdv[FLAG_RX_AVAIL]) begin rd(A_RX); gotb = rdv[7:0]; got.push_back(gotb); end
        else if (!drv) go = 0;
        if (got.size() == 1 && drv && n > 2) begin rd(A_STATUS); if (!rdv[0]) fail("STATUS.rx_hs_active low in a burst"); end
      end
      no_idle = 0;
    end
  join
  if (got.size() != n) fail($sformatf("%0d bytes read of %0d", got.size(), n));
  else foreach (sent[i]) if (got[i] !== sent[i]) fail($sformatf("RX byte %0d %h, expected %h", i, got[i], sent[i]));
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_RX_OVF] || rdv[IRQ_ERROR]) fail($sformatf("IRQ_STATUS %h after an injected burst", rdv));
  wr(A_IRQ_STATUS, IRQ_ALL);
  rxq.delete();
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rd_exp(A_FLAGS, 0);
  rd_exp(A_STATUS, 0);
  rd(A_RX); rd(A_RX_ESC);                   // read empty
  // HS bursts
  hs_burst(2, 0);
  hs_burst(0);
  hs_burst(1);
  for (int i = 0; i < 4; i++) hs_burst(1 + $urandom % 12);
  hs_burst(4, 0);
  // two requests: the second queued behind the first
  sent.delete();
  wr(A_CMD, 1);
  wr(A_CMD, 1);
  cycles(60);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_HS_SENT]) fail("no burst");
  wr(A_IRQ_STATUS, IRQ_ALL);
  rxq.delete();
  // a write to HS_TX while full
  wr(A_HS_TX, 1); wr(A_HS_TX, 2); wr(A_HS_TX, 3);
  irq_wait(IRQ_HS_TX_OVF);
  wr(A_CMD, 1);
  irq_wait(IRQ_HS_SENT);
  cycles(5);
  rd(A_FLAGS);
  if (rdv[FLAG_RX_AVAIL]) rd(A_RX);
  wr(A_IRQ_STATUS, IRQ_ALL);
  rxq.delete();
  // LPDT
  lpdt(0);
  lpdt(1);
  lpdt(3);
  lpdt(5);
  lpdt(2, 1);                               // no last: ends by underrun
  wr(A_LPDT, 0); wr(A_LPDT, 0); wr(A_LPDT, 32'h100);
  irq_wait(IRQ_LPDT_OVF);
  esc(8'h87);
  irq_wait(IRQ_ESC_DONE);
  cycles(5);
  drain();
  wr(A_IRQ_STATUS, IRQ_ALL);
  rxq.delete(); cmdq.delete();
  // ULPS until released, trigger reset
  esc(8'h78);
  cycles(20);
  rd_exp(A_STATUS, 2);
  cycles(20);
  rd_exp(A_STATUS, 2);
  wr(A_CMD, 4);
  irq_wait(IRQ_ESC_DONE);
  rd_exp(A_STATUS, 0);
  rd_exp(A_RX_ESC, 8'h78);
  esc(8'h46);
  irq_wait(IRQ_ESC_DONE);
  rd_exp(A_RX_ESC, 8'h46);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_ERROR]) fail("ERROR after ULPS / trigger");
  wr(A_IRQ_STATUS, IRQ_ALL);
  // unknown commands
  for (int i = 0; i < 3; i++) begin
    esc(i == 0 ? 8'h00 : i == 1 ? 8'hFF : 8'h5A);
    irq_wait(IRQ_ERROR);
    wr(A_CMD, 8);
    rd(A_FLAGS);
    if (rdv[FLAG_RX_ESC_AVAIL]) rd(A_RX_ESC);
    wr(A_IRQ_STATUS, IRQ_ALL);
  end
  // HS and escape requested together: HS first
  wr(A_ESC, 8'h46);
  wr(A_CMD, 3);
  cycles(80);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_HS_SENT] || !rdv[IRQ_ESC_DONE]) fail($sformatf("IRQ_STATUS %h after HS + escape", rdv));
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd(A_FLAGS);
  if (rdv[FLAG_RX_ESC_AVAIL]) rd(A_RX_ESC);
  rxq.delete(); cmdq.delete();
  // receive lane driven by the TB
  @(negedge PCLK) inj = 1;
  sym(2'b11, 2);
  for (int n = 1; n <= 5; n++) inj_hs_read(n);
  for (int i = 0; i < 2; i++) inj_hs_read(1);
  // RX patterns: all ones / all zeros, both paths
  for (int i = 0; i < 4; i++) begin
    hs_entry(); hsbyte(8'hB8); hsbyte(i % 2 ? 8'hFF : 8'h00); hsbit(0); sym(2'b11);
    rd_exp(A_RX, i % 2 ? 8'hFF : 8'h00);
    esc_entry(); lpbyte(8'h87); lpbyte(i % 2 ? 8'h00 : 8'hFF); sym(2'b01); sym(2'b10); sym(2'b11);
    rd_exp(A_RX, i % 2 ? 8'h00 : 8'hFF);
    rd_exp(A_RX_ESC, 8'h87);
  end
  wr(A_IRQ_STATUS, IRQ_ALL);
  // RX and RX_ESC popped in the clock the next value is captured, at every
  // offset (values not checked)
  for (int o = 0; o < 10; o++) begin
    fork
      begin hs_entry(); hsbyte(8'hB8); hsbyte(8'h12); hsbyte(8'h34); hsbyte(8'h56); hsbit(1); sym(2'b11, 2); end
      begin
        @(posedge PCLK); while (!dut.c_rx_data_valid) @(posedge PCLK);
        repeat (o) @(negedge PCLK);
        @(negedge PCLK);
        apb_now(0, A_RX, 0, 0);
      end
    join
    drain();
  end
  for (int o = 0; o < 18; o++) begin
    fork
      repeat (2) begin esc_entry(); lpbyte(8'h87); sym(2'b01); sym(2'b10); sym(2'b11); end
      begin
        @(posedge PCLK); while (!dut.c_rx_esc_valid) @(posedge PCLK);
        repeat (o) @(negedge PCLK);
        @(negedge PCLK);
        apb_now(0, A_RX_ESC, 0, 0);
      end
    join
    drain();
  end
  wr(A_IRQ_STATUS, IRQ_ALL);
  // RX_ESC full: the next command dropped
  repeat (2) begin esc_entry(); lpbyte(8'h87); sym(2'b01); sym(2'b10); sym(2'b11); end
  irq_wait(IRQ_RX_ESC_OVF);
  rd_exp(A_RX_ESC, 8'h87);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // violations
  sym(2'b00); inj_err();                                    // LP-00 from stop
  sym(2'b01); sym(2'b01); sym(2'b10); inj_err();            // HS request
  hs_entry(); hsbyte(8'hB9); inj_err();                     // bad sync
  hs_entry(); hsbyte(8'hB8); hsbit(1); hsbit(0, 0); inj_err();   // invalid level
  sym(2'b10); sym(2'b01); inj_err();                        // escape entry
  esc_entry(); lpbyte(8'h5A); inj_err();                    // unknown command
  esc_entry(); lpbyte(8'h87); sym(2'b11); inj_err();        // LP-11 in LPDT
  esc_entry(); lpbyte(8'h78); sym(2'b11); inj_err();        // ULPS stop
  inj = 0;
  cycles(3);
  rxq.delete(); cmdq.delete();
  // masked: left pending into reset
  wr(A_IRQ_ENABLE, 0);
  wr(A_HS_TX, 8'h11); wr(A_HS_TX, 8'h22); wr(A_HS_TX, 8'h33);
  wr(A_CMD, 1);
  wr(A_LPDT, 0); wr(A_LPDT, 0); wr(A_LPDT, 32'h100);
  esc(8'h87);
  cycles(100);
  esc(8'h00);
  cycles(60);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
