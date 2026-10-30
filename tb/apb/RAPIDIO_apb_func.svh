// SPDX-License-Identifier: Apache-2.0
// RapidIO-specific part of tb/RAPIDIO_apb_tb.sv. The CARs and the base
// device ID are set through the registers (CMD.id_load), memory is written
// and read through MEM_ADDR / MEM_WDATA / CMD / MEM_RDATA, and packets driven
// on rx_valid / rx_data / rx_last (NREAD, NWRITE, a maintenance read, a
// doorbell, a CRC error) are checked on tx_* and through RX_REP and DOORBELL.
// Our doorbell goes out with OB_CTRL / OB_INFO / CMD.ob_start and its
// response is read from OB_DONE. A report kept when a second one arrives
// unread, and a report read in the clock a new one arrives, are covered;
// every interrupt bit is masked, enabled and cleared.
initial begin rx_valid = 0; rx_data = 0; rx_last = 0; end

task automatic irq_bit(input int b, input string what);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ %s not set", what));
  wr(A_IRQ_ENABLE, 0);
  @(negedge PCLK); if (irq !== 0) fail($sformatf("irq with IRQ_ENABLE = 0 (%s)", what));
  wr(A_IRQ_ENABLE, 32'd1 << b);
  @(negedge PCLK); if (irq !== 1) fail($sformatf("irq not raised by %s", what));
  wr(A_IRQ_STATUS, 32'd1 << b);
  wr(A_IRQ_ENABLE, 0);
  rd(A_IRQ_STATUS); if (rdv[b]) fail($sformatf("IRQ %s not cleared", what));
endtask

// ---- memory through the registers
task automatic m_wr(input logic [9:0] a, input logic [7:0] d);
  wr(A_MEM_ADDR, a); wr(A_MEM_WDATA, d); wr(A_CMD, 32'h2);
endtask
task automatic m_rd_exp(input logic [9:0] a, input logic [7:0] e);
  wr(A_MEM_ADDR, a); wr(A_CMD, 32'h4);
  rd_exp(A_MEM_RDATA, e);
endtask

// ---- packets: content in ct, CRCs and pad added by p_send
logic [7:0] ct [0:511];
int         cn;
logic [7:0] pk [0:1023];
int         pn;
function automatic logic [15:0] crc_upd(input logic [15:0] c, input logic [7:0] d);
  for (int i = 7; i >= 0; i--) c = {c[14:0], 1'b0} ^ ((c[15] ^ d[i]) ? 16'h1021 : 16'h0);
  return c;
endfunction
task automatic c_put(input logic [7:0] b); ct[cn] = b; cn++; endtask
// header with 8-bit IDs to our 8-bit ID 0x12 from 0x77
task automatic c_hdr(input logic [3:0] ft, input logic [1:0] prio = 0);
  cn = 0;
  c_put(8'h00); c_put({prio, 2'b00, ft}); c_put(8'h12); c_put(8'h77);
endtask
// build pk from ct (early CRC, final CRC, pad); bad flips the final CRC
task automatic p_build(input bit bad = 0);
  logic [15:0] c;
  pn = 0; c = 16'hFFFF;
  for (int i = 0; i < cn; i++) begin
    if (i == 80) begin
      pk[pn] = c[15:8]; pk[pn + 1] = c[7:0]; pn += 2;
      c = crc_upd(c, pk[pn - 2]); c = crc_upd(c, pk[pn - 1]);
    end
    pk[pn] = ct[i]; pn++;
    c = crc_upd(c, i == 0 ? {6'd0, ct[0][1:0]} : ct[i]);
  end
  c ^= bad ? 16'h0001 : 16'h0;
  pk[pn] = c[15:8]; pk[pn + 1] = c[7:0]; pn += 2;
  if (pn % 4 != 0) begin pk[pn] = 0; pk[pn + 1] = 0; pn += 2; end
endtask
// tx capture: the last packet sent
logic [7:0] tq [0:1023];
int         tqn = 0, tpn = 0, n_tx = 0;
always @(negedge PCLK) if (tx_valid) begin
  tq[tpn] = tx_data; tpn++;
  if (tx_last) begin tqn = tpn; tpn = 0; n_tx++; end
end
task automatic p_drive;
  for (int i = 0; i < pn; i++) begin
    @(negedge PCLK) rx_valid = 1; rx_data = pk[i]; rx_last = i == pn - 1;
  end
  @(negedge PCLK) rx_valid = 0; rx_last = 0;
endtask
task automatic p_send(input bit bad = 0, input bit expect_tx = 0);
  int t0;
  t0 = n_tx;
  p_build(bad); p_drive();
  for (int k = 0; k < 400 && expect_tx && n_tx == t0; k++) @(negedge PCLK);
  repeat (4) @(negedge PCLK);
  if (expect_tx && n_tx != t0 + 1) fail("no response sent");
  if (!expect_tx && n_tx != t0) fail("unexpected packet sent");
endtask
// the response in tq must be the content r[0..rn-1] with CRCs and pad
logic [7:0] xr [0:511];
int         xn;
task automatic resp_exp(input string what);
  for (int i = 0; i < xn; i++) ct[i] = xr[i];
  cn = xn; p_build();
  if (tqn != pn) fail($sformatf("%s: response of %0d octets, expected %0d", what, tqn, pn));
  else begin
    int bad;
    bad = -1;
    for (int i = 0; i < pn; i++) if (bad < 0 && tq[i] !== pk[i]) bad = i;
    if (bad >= 0) fail($sformatf("%s: octet %0d = %h, expected %h", what, bad, tq[bad], pk[bad]));
  end
endtask
task automatic x_hdr(input logic [3:0] ft, input logic [3:0] tty, input logic [3:0] st, input logic [7:0] tid);
  xn = 0;
  xr[0] = 0; xr[1] = {2'b01, 2'b00, ft}; xr[2] = 8'h77; xr[3] = 8'h12; xr[4] = {tty, st}; xr[5] = tid; xn = 6;
  if (ft == 4'd8) begin xr[6] = 8'hFF; xr[7] = 0; xr[8] = 0; xr[9] = 0; xn = 10; end
endtask
task automatic rep_exp(input logic [2:0] why, input logic [3:0] ft, input string what);
  rd(A_FLAGS);
  if (!rdv[FLAG_RX_REP_AVAIL]) fail($sformatf("%s: no report", what));
  rd_exp(A_RX_REP, {25'd0, ft, why});
  rd(A_FLAGS);
  if (rdv[FLAG_RX_REP_AVAIL]) fail($sformatf("%s: report not freed", what));
endtask

// drive pk and read register a in the clock the packet's report lands
task automatic read_on_arrival(input logic [11:0] a, input logic [31:0] e, input string what);
  fork
    p_drive();
    begin
      // access phase in the clock of the report (two clocks after rx_last)
      @(negedge rx_last);
      PSEL = 1; PENABLE = 0; PWRITE = 0; PADDR = a; PSTRB = 0;
      @(negedge PCLK) PENABLE = 1;
      #1 if (PRDATA !== e) fail($sformatf("%s: read %h = %h, expected %h", what, a, PRDATA, e));
      @(posedge PCLK) #1 PSEL = 0; PENABLE = 0;
    end
  join
  repeat (60) @(negedge PCLK);
endtask

task automatic ip_func;
  // CARs and the base device ID
  wr(A_DEV_ID_CAR, 32'h0001_0074); wr(A_DEV_INFO_CAR, 32'h0000_0010); wr(A_ASM_ID_CAR, 32'h1234_5678);
  wr(A_ASM_INFO_CAR, 32'h0100_0000); wr(A_PE_FEAT_CAR, 32'h8000_0011);
  wr(A_BASE_ID_CFG, 32'h0012_ABCD); wr(A_CMD, 32'h1);
  rd_exp(A_BASE_ID, 32'h0012_ABCD);
  rd_exp(A_STATUS, 0);
  for (int i = 0; i < 16; i++) m_wr(10'h100 + 10'(i), 8'(16 * i + i));
  for (int i = 0; i < 16; i++) m_rd_exp(10'h100 + 10'(i), 8'(16 * i + i));
  wr(A_IRQ_STATUS, IRQ_ALL);

  // NREAD of one double-word at 0x108
  c_hdr(4'd2); c_put(8'h48); c_put(8'h31); c_put(0); c_put(0); c_put(8'h01); c_put(8'h08);
  p_send(0, 1);
  x_hdr(4'd13, 4'd8, 4'd0, 8'h31);
  for (int i = 0; i < 8; i++) begin xr[xn] = 8'(16 * (8 + i) + 8 + i); xn++; end
  resp_exp("NREAD");
  irq_bit(IRQ_RX_REP_AVAIL, "RX_REP_AVAIL");
  rep_exp(3'd0, 4'd2, "NREAD");
  // NWRITE of one double-word at 0x200
  c_hdr(4'd5); c_put(8'h4B); c_put(8'h32); c_put(0); c_put(0); c_put(8'h02); c_put(8'h00);
  for (int i = 0; i < 8; i++) c_put(8'hF0 + 8'(i));
  p_send();
  rep_exp(3'd0, 4'd5, "NWRITE");
  for (int i = 0; i < 8; i++) m_rd_exp(10'h200 + 10'(i), 8'hF0 + 8'(i));
  // maintenance read of the device identity CAR
  c_hdr(4'd8); c_put(8'h08); c_put(8'h33); c_put(0); c_put(0); c_put(0); c_put(8'h00);
  p_send(0, 1);
  x_hdr(4'd8, 4'd2, 4'd0, 8'h33);
  xr[xn] = 8'h00; xr[xn + 1] = 8'h01; xr[xn + 2] = 8'h00; xr[xn + 3] = 8'h74;
  for (int i = 4; i < 8; i++) xr[xn + i] = 0;
  xn += 8;
  resp_exp("maintenance read");
  rep_exp(3'd0, 4'd8, "maintenance read");
  // a doorbell in: DOORBELL report and a DONE response
  c_hdr(4'd10); c_put(0); c_put(8'h34); c_put(8'hBE); c_put(8'hEF);
  p_send(0, 1);
  x_hdr(4'd13, 4'd0, 4'd0, 8'h34);
  resp_exp("doorbell response");
  irq_bit(IRQ_DOORBELL_AVAIL, "DOORBELL_AVAIL");
  rd(A_FLAGS); if (!rdv[FLAG_DOORBELL_AVAIL]) fail("no doorbell");
  rd_exp(A_DOORBELL0, {8'd0, 8'h34, 16'hBEEF});
  rd(A_FLAGS); if (!rdv[FLAG_DOORBELL_AVAIL]) fail("doorbell freed by its first word");
  rd_exp(A_DOORBELL1, 32'h0000_0077);
  rd(A_FLAGS); if (rdv[FLAG_DOORBELL_AVAIL]) fail("doorbell not freed");
  rep_exp(3'd0, 4'd10, "doorbell");
  // a CRC error
  c_hdr(4'd2); c_put(8'h48); c_put(8'h35); c_put(0); c_put(0); c_put(8'h08); c_put(8'h00);
  p_send(1);
  rep_exp(3'd1, 4'd2, "CRC error");

  // our doorbell: sent, busy until the response, OB_DONE
  wr(A_OB_CTRL, {7'd0, 1'b0, 8'h5A, 16'h0066}); wr(A_OB_INFO, 32'h0000_C0DE);
  begin
    int t0;
    t0 = n_tx;
    wr(A_CMD, 32'h8);
    rd(A_STATUS); if (!rdv[0]) fail("STATUS.ob_busy not set");
    while (n_tx == t0) @(negedge PCLK);
  end
  xn = 0;
  xr[0] = 0; xr[1] = 8'h0A; xr[2] = 8'h66; xr[3] = 8'h12; xr[4] = 0; xr[5] = 8'h5A; xr[6] = 8'hC0; xr[7] = 8'hDE; xn = 8;
  resp_exp("our doorbell");
  cn = 0; c_put(0); c_put(8'h0D); c_put(8'h12); c_put(8'h66); c_put(8'h07); c_put(8'h5A);
  p_send();
  rep_exp(3'd0, 4'd13, "doorbell ERROR response");
  irq_bit(IRQ_OB_DONE_AVAIL, "OB_DONE_AVAIL");
  rd(A_FLAGS); if (!rdv[FLAG_OB_DONE_AVAIL]) fail("no OB_DONE");
  rd_exp(A_OB_DONE, 32'h7);
  rd(A_FLAGS); if (rdv[FLAG_OB_DONE_AVAIL]) fail("OB_DONE not freed");
  rd_exp(A_STATUS, 0);
  // a second doorbell and response unread: OB_DONE overflow, the first kept
  for (int k = 0; k < 2; k++) begin
    wr(A_OB_CTRL, {7'd0, 1'b1, 8'(k), 16'hA0A0}); wr(A_OB_INFO, k);
    wr(A_CMD, 32'h8);
    repeat (40) @(negedge PCLK);
    cn = 0; c_put(0); c_put(8'h1D); c_put(8'hAB); c_put(8'hCD); c_put(8'hA0); c_put(8'hA0); c_put(8'(k + 3)); c_put(8'(k));
    p_send();
  end
  irq_bit(IRQ_OB_DONE_OVF, "OB_DONE_OVF");
  rd_exp(A_OB_DONE, 32'd3);
  rd(A_OB_DONE);                                         // empty: no side effect (the checker checks the data)
  rd(A_FLAGS); if (rdv[FLAG_OB_DONE_AVAIL]) fail("OB_DONE read while empty");
  // two doorbells in unread: DOORBELL overflow, the first kept
  for (int k = 0; k < 2; k++) begin
    c_hdr(4'd10); c_put(0); c_put(8'h40 + 8'(k)); c_put(8'(k)); c_put(8'(k)); p_send(0, 1);
  end
  irq_bit(IRQ_DOORBELL_OVF, "DOORBELL_OVF");
  rd_exp(A_DOORBELL0, {8'd0, 8'h40, 16'h0000});
  rd_exp(A_DOORBELL1, 32'h0000_0077);
  // RX_REP: the reports of the packets above overflowed; drain, then a report
  // read in the clock a new one arrives
  irq_bit(IRQ_RX_REP_OVF, "RX_REP_OVF");
  rd(A_RX_REP);
  wr(A_IRQ_STATUS, IRQ_ALL);
  c_hdr(4'd2); c_put(8'h48); c_put(8'h36); c_put(0); c_put(0); c_put(8'h08); c_put(8'h00);
  p_send(1);
  fork
    begin
      c_hdr(4'd2); c_put(8'h48); c_put(8'h37); c_put(0); c_put(0); c_put(8'h08); c_put(8'h00);
      p_build(1); p_drive();
    end
    begin
      // access phase in the clock rx_rep is set (two clocks after rx_last)
      @(negedge rx_last);
      PSEL = 1; PENABLE = 0; PWRITE = 0; PADDR = A_RX_REP; PSTRB = 0;
      @(negedge PCLK) PENABLE = 1;
      #1 if (PRDATA !== {25'd0, 4'd2, 3'd1}) fail("report read with a new one arriving");
      @(posedge PCLK) #1 PSEL = 0; PENABLE = 0;
    end
  join
  repeat (4) @(negedge PCLK);
  rep_exp(3'd1, 4'd2, "report replaced during its read");
  rd(A_IRQ_STATUS); if (rdv[IRQ_RX_REP_OVF]) fail("overflow with a read in that clock");
  // more report codes: not for this endpoint, unsupported ftype
  c_hdr(4'd2); ct[2] = 8'h13; c_put(8'h48); c_put(8'h38); c_put(0); c_put(0); c_put(8'h01); c_put(8'h00);
  p_send();
  rep_exp(3'd2, 4'd2, "not for this endpoint");
  c_hdr(4'd1); c_put(8'h00); c_put(8'h39);
  p_send();
  rep_exp(3'd4, 4'd1, "unsupported ftype");
  // doorbells with 16-bit IDs: all ones, then all zeros
  for (int k = 0; k < 2; k++) begin
    logic [7:0] v;
    v = k ? 8'h00 : 8'hFF;
    cn = 0; c_put(0); c_put(8'h1A); c_put(8'hAB); c_put(8'hCD); c_put(v); c_put(v);
    c_put(0); c_put(v); c_put(v); c_put(v);
    p_send(0, 1);
    rd_exp(A_DOORBELL0, {8'd0, v, v, v});
    rd_exp(A_DOORBELL1, {16'd0, v, v});
    rep_exp(3'd0, 4'd10, "doorbell, 16-bit IDs");
  end
  // our doorbell with a user status response
  wr(A_OB_CTRL, {7'd0, 1'b0, 8'h5B, 16'h0066}); wr(A_OB_INFO, 0);
  wr(A_CMD, 32'h8);
  repeat (40) @(negedge PCLK);
  cn = 0; c_put(0); c_put(8'h0D); c_put(8'h12); c_put(8'h66); c_put(8'h0F); c_put(8'h5B);
  p_send();
  rd_exp(A_OB_DONE, 32'hF);
  rep_exp(3'd0, 4'd13, "user status response");
  // a doorbell read out in the clock the next one arrives; then a read while empty
  c_hdr(4'd10); c_put(0); c_put(8'h50); c_put(8'h12); c_put(8'h34); p_send(0, 1);
  c_hdr(4'd10); c_put(0); c_put(8'h51); c_put(8'h56); c_put(8'h78); p_build();
  read_on_arrival(A_DOORBELL1, 32'h0000_0077, "doorbell replaced during its read");
  rd_exp(A_DOORBELL0, {8'd0, 8'h51, 16'h5678});
  rd_exp(A_DOORBELL1, 32'h0000_0077);
  rd(A_DOORBELL1);                                       // empty: no side effect
  rd(A_FLAGS); if (rdv[FLAG_DOORBELL_AVAIL]) fail("DOORBELL read while empty");
  // OB_DONE read out in the clock the next one arrives
  for (int k = 0; k < 2; k++) begin
    wr(A_OB_CTRL, {7'd0, 1'b0, 8'h60 + 8'(k), 16'h0066}); wr(A_OB_INFO, 0);
    wr(A_CMD, 32'h8);
    repeat (40) @(negedge PCLK);
    cn = 0; c_put(0); c_put(8'h0D); c_put(8'h12); c_put(8'h66); c_put(8'(k + 1)); c_put(8'h60 + 8'(k));
    if (k == 0) p_send();
    else begin p_build(); read_on_arrival(A_OB_DONE, 32'd1, "OB_DONE replaced during its read"); end
  end
  rd_exp(A_OB_DONE, 32'd2);
  rd(A_FLAGS); if (rdv[FLAG_OB_DONE_AVAIL]) fail("OB_DONE not freed");
  wr(A_IRQ_STATUS, IRQ_ALL);
  for (int i = 0; i < 6; i++) rd(A_RX_REP);
  // base device ID all ones, all zeros, back
  wr(A_BASE_ID_CFG, 32'hFFFF_FFFF); wr(A_CMD, 32'h1); rd_exp(A_BASE_ID, 32'h00FF_FFFF);
  wr(A_BASE_ID_CFG, 32'h0);         wr(A_CMD, 32'h1); rd_exp(A_BASE_ID, 32'h0);
  wr(A_BASE_ID_CFG, 32'h0012_ABCD); wr(A_CMD, 32'h1); rd_exp(A_BASE_ID, 32'h0012_ABCD);
  rd(A_RX_REP);                                          // empty
  rd(A_FLAGS); if (rdv[FLAG_RX_REP_AVAIL]) fail("RX_REP read while empty");
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask
