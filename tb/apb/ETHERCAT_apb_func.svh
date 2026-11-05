// SPDX-License-Identifier: Apache-2.0
// EtherCAT-specific part of tb/ETHERCAT_apb_tb.sv. The station address, the
// FMMUs and the process RAM are written and read back through MEM_ADDR /
// MEM_WDATA / CMD / MEM_RDATA; frames driven on rx_dv / rx_d (APRD, FPWR,
// LRD through an FMMU, 255 empty APRW datagrams, a bad FCS, a non-EtherCAT
// frame) are checked on tx_d and through the FRAME reports, including the
// report kept when a second one arrives unread. Every interrupt bit is
// masked, enabled and cleared.
initial begin rx_dv = 0; rx_d = 0; end

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

// ---- ESC memory through the registers
task automatic esc_wr(input logic [15:0] a, input logic [7:0] d);
  wr(A_MEM_ADDR, a); wr(A_MEM_WDATA, d); wr(A_CMD, 32'h1);
endtask
task automatic esc_rd_exp(input logic [15:0] a, input logic [7:0] e);
  wr(A_MEM_ADDR, a); wr(A_CMD, 32'h2);
  rd_exp(A_MEM_RDATA, e);
endtask

// ---- frames
logic [7:0] fb [0:4095];
int         fbn;
function automatic logic [31:0] crc_upd(input logic [31:0] c, input logic [7:0] d);
  c ^= {24'd0, d};
  for (int k = 0; k < 8; k++) c = c[0] ? (c >> 1) ^ 32'hEDB88320 : c >> 1;
  return c;
endfunction
task automatic f_put(input logic [7:0] b); fb[fbn] = b; fbn++; endtask
task automatic f_eth(input logic [15:0] et = 16'h88A4);
  fbn = 0;
  for (int i = 0; i < 6; i++) f_put(8'hFF);
  for (int i = 0; i < 6; i++) f_put(8'h10 + 8'(i));
  f_put(et[15:8]); f_put(et[7:0]);
  f_put(8'h00); f_put(8'h10);                       // EtherCAT header (length not checked)
endtask
task automatic f_dg(input logic [7:0] cmd, input logic [15:0] adp, input logic [15:0] ado, input int len,
                    input bit more, input logic [7:0] fill = 8'h00);
  f_put(cmd); f_put(8'h00); f_put(adp[7:0]); f_put(adp[15:8]); f_put(ado[7:0]); f_put(ado[15:8]);
  f_put(len[7:0]); f_put({more, 4'b0000, len[10:8]}); f_put(8'h00); f_put(8'h00);
  for (int i = 0; i < len; i++) f_put(fill);
  f_put(8'h00); f_put(8'h00);
endtask
// drive the frame with its FCS (broken if bad); tx octets land in tq
logic [7:0] tq [0:4095];
int         tqn = 0;
always @(negedge PCLK) if (tx_dv) begin tq[tqn % 4096] = tx_d; tqn++; end
task automatic f_send(input bit bad = 0);
  logic [31:0] c;
  c = '1;
  for (int i = 0; i < fbn; i++) c = crc_upd(c, fb[i]);
  c = ~c ^ (bad ? 32'h1 : 32'h0);
  for (int i = 0; i < 4; i++) f_put(c[8 * i +: 8]);
  tqn = 0;
  for (int i = 0; i < fbn; i++) begin @(negedge PCLK) rx_dv = 1; rx_d = fb[i]; end
  @(negedge PCLK) rx_dv = 0; rx_d = 8'h00;
  repeat (8) @(negedge PCLK);
  if (tqn != fbn) fail($sformatf("%0d octets forwarded, %0d sent", tqn, fbn));
endtask
// the frame report
task automatic report_exp(input bit ok, input bit ecat, input logic [7:0] dg, input logic [7:0] wkc,
                          input string what);
  rd(A_FLAGS);
  if (!rdv[FLAG_FRAME_AVAIL]) fail($sformatf("%s: no frame report", what));
  rd_exp(A_FRAME, {14'd0, wkc, dg, ecat, ok});
  rd(A_FLAGS);
  if (rdv[FLAG_FRAME_AVAIL]) fail($sformatf("%s: report not freed", what));
endtask

task automatic ip_func;
  // station address, FMMU 0 (logical 0x0001_0000, 4 octets -> 0x1000, read / write), RAM
  esc_wr(16'h0010, 8'h34); esc_wr(16'h0011, 8'h12);
  esc_rd_exp(16'h0010, 8'h34); esc_rd_exp(16'h0011, 8'h12);
  esc_wr(16'h0602, 8'h01); esc_wr(16'h0604, 8'h04); esc_wr(16'h0609, 8'h10);
  esc_wr(16'h060B, 8'h03); esc_wr(16'h060C, 8'h01);
  esc_rd_exp(16'h060B, 8'h03); esc_rd_exp(16'h0600, 8'h00);
  for (int i = 0; i < 8; i++) esc_wr(16'h1000 + 16'(i), i[0] ? 8'hFF : 8'h00);
  for (int i = 0; i < 8; i++) esc_rd_exp(16'h1000 + 16'(i), i[0] ? 8'hFF : 8'h00);
  esc_rd_exp(16'h2000, 8'h00);                      // unmapped
  wr(A_IRQ_STATUS, IRQ_ALL);

  // APRD of the RAM: data read into the frame, ADP + 1, WKC + 1
  f_eth(); f_dg(8'd1, 16'h0000, 16'h1000, 8, 0); f_send();
  for (int i = 0; i < 8; i++)
    if (tq[26 + i] !== (i[0] ? 8'hFF : 8'h00)) fail($sformatf("APRD octet %0d = %h", i, tq[26 + i]));
  if (tq[18] !== 8'h01 || tq[34] !== 8'h01) fail("APRD ADP / WKC");
  irq_bit(IRQ_FRAME_AVAIL, "FRAME_AVAIL");
  report_exp(1, 1, 8'd1, 8'd1, "APRD");
  // FPWR to this station, then the RAM through the host port
  f_eth(); f_dg(8'd5, 16'h1234, 16'h1004, 4, 0, 8'hA5); f_send();
  report_exp(1, 1, 8'd1, 8'd1, "FPWR");
  for (int i = 0; i < 4; i++) esc_rd_exp(16'h1004 + 16'(i), 8'hA5);
  // LRD through FMMU 0
  f_eth(); f_dg(8'd10, 16'h0000, 16'h0001, 4, 0); f_send();
  if (tq[26] !== 8'h00 || tq[27] !== 8'hFF || tq[29] !== 8'hFF) fail("LRD data");
  report_exp(1, 1, 8'd1, 8'd1, "LRD");
  // 255 empty APRW datagrams: 255 datagrams, the WKC sum saturates
  f_eth();
  for (int i = 0; i < 255; i++) f_dg(8'd3, 16'h0000, 16'h1000, 0, i != 254);
  f_send();
  report_exp(1, 1, 8'd255, 8'd255, "255 datagrams");
  // a bad FCS is forwarded inverted
  f_eth(); f_dg(8'd0, 16'h0000, 16'h0000, 2, 0); f_send(1);
  report_exp(0, 1, 8'd1, 8'd0, "bad FCS");
  // a second report while the first is unread: overflow, the first is kept
  f_eth(16'h0800); f_send();
  f_eth(); f_dg(8'd1, 16'h0000, 16'h1000, 1, 0); f_send();
  irq_bit(IRQ_FRAME_OVF, "FRAME_OVF");
  report_exp(1, 0, 8'd0, 8'd0, "not EtherCAT");
  // a report arriving while the previous one is being read
  f_eth(); f_dg(8'd1, 16'h0000, 16'h1000, 1, 0); f_send();
  wr(A_IRQ_STATUS, IRQ_ALL);
  fork
    begin f_eth(); f_dg(8'd2, 16'h0000, 16'h1001, 1, 0, 8'h00); f_send(); end
    begin
      // setup phase as rx_dv falls: the access phase is the clock of fr_done
      @(negedge rx_dv);
      PSEL = 1; PENABLE = 0; PWRITE = 0; PADDR = A_FRAME; PSTRB = 0;
      @(negedge PCLK) PENABLE = 1;
      #1 if (PRDATA !== {14'd0, 8'd1, 8'd1, 1'b1, 1'b1}) fail("report read with a new one arriving");
      @(posedge PCLK) #1 PSEL = 0; PENABLE = 0;
    end
  join
  report_exp(1, 1, 8'd1, 8'd1, "report replaced during its read");
  rd(A_IRQ_STATUS); if (rdv[IRQ_FRAME_OVF]) fail("overflow with a read in that clock");
  esc_rd_exp(16'h1001, 8'h00);
  rd(A_FRAME);                                      // empty: no side effect (the checker checks the data)
  rd(A_FLAGS); if (rdv[FLAG_FRAME_AVAIL]) fail("FRAME read while empty");
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask
